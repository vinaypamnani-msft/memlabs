#!/bin/bash
# apt-retry.sh — shared retry helpers for apt and network operations.
#
# Provides three functions:
#   wait_for_apt_lock  — wait for dpkg/apt locks to be released
#   apt_retry          — run an apt command with retries + dpkg recovery
#   wget_retry         — run wget with retries
#
# Inlined into scripts by Get-LinuxScript -IncludeAptRetry.

# ---------------------------------------------------------------------------
# repair_dpkg_status
#   Detects and repairs a corrupt/truncated dpkg package database. On ext4 a
#   non-graceful reboot (host stress, unflushed writeback) can leave
#   /var/lib/dpkg/status zero-length, which surfaces as:
#       dpkg: error: parsing file '/var/lib/dpkg/status' near line 0:
#       end of file after field name ''
#   and makes dpkg think NOTHING is installed (apt then tries to reinstall the
#   entire base system). dpkg keeps the previous good copy as status-old and
#   the packaging cron keeps dated copies under /var/backups; restore the
#   first candidate that parses. Returns 0 if the DB is (now) readable.
# ---------------------------------------------------------------------------
repair_dpkg_status() {
    if dpkg-query -W >/dev/null 2>&1; then
        return 0    # status DB is readable — nothing to do (fast path)
    fi
    echo "[repair_dpkg_status] dpkg status DB is unreadable/corrupt; restoring from backup..." >&2
    local ts cand
    ts=$(date +%s)
    [ -f /var/lib/dpkg/status ] && \
        cp -a /var/lib/dpkg/status "/var/lib/dpkg/status.broken.$ts" 2>/dev/null || true
    # Prefer dpkg's own previous copy, then the dated backups (newest first).
    for cand in /var/lib/dpkg/status-old \
                $(ls -1t /var/backups/dpkg.status /var/backups/dpkg.status.0 2>/dev/null); do
        [ -s "$cand" ] || continue
        if cp -a "$cand" /var/lib/dpkg/status 2>/dev/null && dpkg-query -W >/dev/null 2>&1; then
            echo "[repair_dpkg_status] restored dpkg status from $cand" >&2
            sync
            return 0
        fi
    done
    # gzip'd dated backups (dpkg.status.1.gz, ...), newest first.
    for cand in $(ls -1t /var/backups/dpkg.status.*.gz 2>/dev/null); do
        if zcat "$cand" > /var/lib/dpkg/status 2>/dev/null && dpkg-query -W >/dev/null 2>&1; then
            echo "[repair_dpkg_status] restored dpkg status from $cand" >&2
            sync
            return 0
        fi
    done
    echo "[repair_dpkg_status] WARNING: no parseable dpkg status backup found" >&2
    return 1
}

# ---------------------------------------------------------------------------
# recover_dpkg
#   Recovers an interrupted or wedged dpkg/debconf state so a subsequent
#   apt-get can succeed.  A plain 'dpkg --configure -a' only fixes a cleanly
#   interrupted configure; it (and a reboot) cannot fix a corrupt debconf
#   database, whose signature is:
#       E: Cannot get debconf version. Is debconf installed?
#       debconf: apt-extracttemplates failed: 25600
#       E: Sub-process /usr/bin/dpkg returned an error code (2)
#   Returns 0 on the fast path (nothing to recover) so it is cheap to call
#   before every apt operation.
# ---------------------------------------------------------------------------
recover_dpkg() {
    # Free anything holding the dpkg/apt locks.
    systemctl stop unattended-upgrades.service 2>/dev/null || true
    pkill -9 -x unattended-upgr 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
          /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true

    # Step 0: repair a corrupt/truncated dpkg status DB before anything else —
    # every dpkg/apt command below fails to parse if status is zero-length.
    repair_dpkg_status || true

    # Step 1: recover any cleanly-interrupted configure. On a healthy system
    # with nothing pending this returns 0 immediately (fast path).
    if DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>&1; then
        return 0
    fi

    # Step 2: dpkg still failing. Probe debconf — if its database is wedged
    # (apt-extracttemplates / "Cannot get debconf version"), debconf-communicate
    # cannot start and exits non-zero. Reset the cache DB; debconf regenerates
    # config.dat/templates.dat from package templates on the next configure, so
    # this loses only stored answers (harmless on a non-interactive lab VM).
    if ! printf 'VERSION\n' | debconf-communicate >/dev/null 2>&1; then
        echo "[recover_dpkg] debconf database is wedged; resetting it..." >&2
        local ts; ts=$(date +%s)
        for f in config.dat templates.dat passwords.dat; do
            [ -f "/var/cache/debconf/$f" ] && \
                mv -f "/var/cache/debconf/$f" "/var/cache/debconf/$f.broken.$ts" 2>/dev/null || true
        done
    fi

    # Step 3: fix broken deps and reinstall the preconfigure tooling
    # (apt-extracttemplates lives in apt-utils), then configure again.
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>&1 || true
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y debconf apt-utils 2>&1 || true
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>&1 || true
}

# ---------------------------------------------------------------------------
# wait_for_apt_lock [max_seconds]
#   Waits up to max_seconds (default 300) for dpkg/apt locks to be released.
#   Runs dpkg --configure -a afterwards to recover interrupted state.
# ---------------------------------------------------------------------------
wait_for_apt_lock() {
    local max_wait=${1:-300} waited=0
    # Stop unattended-upgrades first — it's the #1 cause of held locks.
    # On deployed VMs the service should be masked, but belt-and-suspenders.
    systemctl stop unattended-upgrades.service 2>/dev/null || true
    pkill -9 -x unattended-upgr 2>/dev/null || true
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            echo "[wait_for_apt_lock] ERROR: locks not released after ${max_wait}s" >&2
            return 1
        fi
        if [ $((waited % 30)) -eq 0 ]; then
            echo "[wait_for_apt_lock] waiting for apt/dpkg locks (${waited}s/${max_wait}s)..." >&2
        fi
        sleep 5
        waited=$((waited + 5))
    done
    # Recover from any interrupted/wedged dpkg+debconf state before proceeding
    recover_dpkg || true
}

# ---------------------------------------------------------------------------
# apt_retry <command> [args...]
#   Retries up to 3 times with exponential backoff (10/20/30s).
#   Runs dpkg --configure -a between retries to recover from
#   interrupted dpkg state. Sets NEEDRESTART_SUSPEND=1 to prevent
#   the Ubuntu needrestart dpkg hook from querying D-Bus (which
#   fails over SSH and causes false exit codes).
# ---------------------------------------------------------------------------
apt_retry() {
    local max=3 attempt=0 rc=0
    while [ $attempt -lt $max ]; do
        attempt=$((attempt + 1))
        if NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive "$@"; then
            return 0
        fi
        rc=$?
        echo "[apt_retry] attempt $attempt/$max failed (rc=$rc), waiting $((attempt * 10))s..." >&2
        sleep $((attempt * 10))
        # Recover interrupted/wedged dpkg+debconf state between retries
        recover_dpkg || true
    done
    echo "[apt_retry] all $max attempts failed for: $*" >&2
    return $rc
}

# ---------------------------------------------------------------------------
# wget_retry [wget_args...]
#   Retries wget up to 3 times with backoff (5/10/15s).
# ---------------------------------------------------------------------------
wget_retry() {
    local max=3 attempt=0 rc=0
    while [ $attempt -lt $max ]; do
        attempt=$((attempt + 1))
        if wget "$@"; then
            return 0
        fi
        rc=$?
        echo "[wget_retry] attempt $attempt/$max failed (rc=$rc), retrying in $((attempt * 5))s..." >&2
        sleep $((attempt * 5))
    done
    echo "[wget_retry] all $max attempts failed" >&2
    return $rc
}
