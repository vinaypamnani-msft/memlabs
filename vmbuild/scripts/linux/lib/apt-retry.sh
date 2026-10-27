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
# preflight_apt_state
#   Snapshot the packaging state BEFORE an install so failures can be
#   root-caused from the captured output: is the dpkg DB already corrupt on
#   arrival? Is another apt/dpkg/unattended-upgrades run (or cloud-init's
#   first-boot package install) still in progress and holding the lock? Is the
#   disk full (ENOSPC truncates the status DB)? Purely diagnostic — never
#   fails the caller.
# ---------------------------------------------------------------------------
preflight_apt_state() {
    echo "[preflight] ===== apt/dpkg state before install ====="
    echo "[preflight] uptime: $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
    # Disk first — ENOSPC (guest or host-backed) truncates the status DB, and
    # this must be captured even if the process list below is truncated.
    echo "[preflight] disk: $(df -h / /var 2>/dev/null | awk 'NR>1{printf "%s %s used %s avail; ",$6,$5,$4}')"
    local st=/var/lib/dpkg/status
    echo "[preflight] status size: $(stat -c%s "$st" 2>/dev/null || echo '?')B; status-old: $(stat -c%s "${st}-old" 2>/dev/null || echo 'none')B"
    if dpkg-query -W >/dev/null 2>&1; then
        echo "[preflight] dpkg DB: OK ($(dpkg-query -f '${Package}\n' -W 2>/dev/null | wc -l) pkgs installed)"
    else
        echo "[preflight] dpkg DB: UNREADABLE/CORRUPT (would need repair_dpkg_status)"
    fi
    local audit
    audit=$(dpkg --audit 2>/dev/null | head -20 || true)
    if [ -n "$audit" ]; then echo "[preflight] dpkg --audit (broken/half-configured):"; echo "$audit"; else echo "[preflight] dpkg --audit: clean"; fi
    if command -v cloud-init >/dev/null 2>&1; then
        echo "[preflight] cloud-init status: $(cloud-init status 2>/dev/null | tr '\n' ' ' || echo '?')"
    fi
    if command -v fuser >/dev/null 2>&1; then
        local holder; holder=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null || true)
        if [ -n "$holder" ]; then echo "[preflight] dpkg lock-frontend held by PID(s):$holder"; else echo "[preflight] dpkg lock-frontend: free"; fi
    fi
    # Process list LAST — it can be multi-line and is the most likely to be
    # truncated in captured output, so keep the single-line facts above it.
    echo "[preflight] apt/dpkg/unattended/cloud-init processes:"
    ps -eo pid,ppid,etimes,cmd 2>/dev/null | grep -E 'apt-get|aptitude|dpkg|unattended-upgr|packagekit|cloud-init' | grep -v grep | head -8 || echo "  (none running)"
    echo "[preflight] =========================================="
    return 0
}

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
    # Prefer memlabs' known-good snapshot, then dpkg's own previous copy, then
    # the dated backups (newest first).
    for cand in "${MEMLABS_DPKG_GOOD:-/var/backups/memlabs-dpkg-status.good}" \
                /var/lib/dpkg/status-old \
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
# dpkg status DB consistency guard + known-good snapshot
#   These lab VMs are hard-powered-off without warning (nightly ~02:00), which
#   truncates /var/lib/dpkg/status. Keep a trusted, PARSEABLE copy at
#   /var/backups/memlabs-dpkg-status.good and refresh it after every consistent
#   apt op. apt_retry checks the DB BEFORE and AFTER each op, logs the facts to
#   /var/log/memlabs-dpkg-guard.log for diagnosis, and restores from the
#   known-good copy (or dpkg's status-old / /var/backups) if it is corrupt.
# ---------------------------------------------------------------------------
MEMLABS_DPKG_GOOD=${MEMLABS_DPKG_GOOD:-/var/backups/memlabs-dpkg-status.good}
MEMLABS_DPKG_GUARD_LOG=${MEMLABS_DPKG_GUARD_LOG:-/var/log/memlabs-dpkg-guard.log}

_dpkg_guard_log() {
    local msg="[dpkg-guard $(date -Is 2>/dev/null)] $*"
    echo "$msg" >&2
    { echo "$msg" >> "$MEMLABS_DPKG_GUARD_LOG"; } 2>/dev/null || true
}

# 0 if the status DB parses (dpkg-query can read it), non-zero if corrupt.
dpkg_status_ok() {
    dpkg-query -W >/dev/null 2>&1
}

# One-line snapshot of the DB state for the diagnosis log.
dpkg_status_facts() {
    local st=/var/lib/dpkg/status sz cnt good
    sz=$(stat -c%s "$st" 2>/dev/null || echo '?')
    if dpkg-query -W >/dev/null 2>&1; then cnt=$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l); else cnt='UNREADABLE'; fi
    good=$([ -s "$MEMLABS_DPKG_GOOD" ] && stat -c%s "$MEMLABS_DPKG_GOOD" 2>/dev/null || echo none)
    echo "status=${sz}B pkgs=${cnt} status-old=$(stat -c%s /var/lib/dpkg/status-old 2>/dev/null || echo none)B known-good=${good}B"
}

# Snapshot the current status as known-good ONLY when it parses. Atomic write +
# sync so the snapshot itself survives a hard power-off. Creates it if absent.
dpkg_save_known_good() {
    if dpkg_status_ok; then
        if cp -a /var/lib/dpkg/status "${MEMLABS_DPKG_GOOD}.tmp" 2>/dev/null \
           && mv -f "${MEMLABS_DPKG_GOOD}.tmp" "$MEMLABS_DPKG_GOOD" 2>/dev/null; then
            sync 2>/dev/null || true
            return 0
        fi
        rm -f "${MEMLABS_DPKG_GOOD}.tmp" 2>/dev/null || true
    fi
    return 1
}

# Restore status from the most-trusted parseable source, best first: our
# known-good snapshot, then dpkg's status-old, then dated /var/backups copies.
# Verifies each candidate parses before keeping it.
dpkg_restore_known_good() {
    local cand
    for cand in "$MEMLABS_DPKG_GOOD" /var/lib/dpkg/status-old \
                $(ls -1t /var/backups/dpkg.status /var/backups/dpkg.status.0 2>/dev/null); do
        [ -s "$cand" ] || continue
        cp -a /var/lib/dpkg/status "/var/lib/dpkg/status.broken.$(date +%s 2>/dev/null)" 2>/dev/null || true
        if cp -a "$cand" /var/lib/dpkg/status 2>/dev/null && dpkg-query -W >/dev/null 2>&1; then
            sync 2>/dev/null || true
            _dpkg_guard_log "restored status DB from $cand ($(stat -c%s "$cand" 2>/dev/null)B)"
            return 0
        fi
    done
    for cand in $(ls -1t /var/backups/dpkg.status.*.gz 2>/dev/null); do
        if zcat "$cand" > /var/lib/dpkg/status 2>/dev/null && dpkg-query -W >/dev/null 2>&1; then
            sync 2>/dev/null || true
            _dpkg_guard_log "restored status DB from $cand"
            return 0
        fi
    done
    _dpkg_guard_log "ERROR: no parseable status backup (known-good/status-old/var-backups all bad)"
    return 1
}

# ---------------------------------------------------------------------------
# rebuild_dpkg_status
#   LAST-RESORT recovery when /var/lib/dpkg/status is corrupt AND no parseable
#   backup exists anywhere (known-good / status-old / /var/backups all bad) --
#   exactly the dead-end a VM hits if it's truncated before any known-good was
#   ever saved. Reconstructs a USABLE status DB from on-disk metadata:
#     * installed package names come from /var/lib/dpkg/info/*.list
#     * each package's control stanza is recovered from the apt Packages lists
#       (/var/lib/apt/lists/*_Packages), repo-only fields stripped and stamped
#       'Status: install ok installed'; packages not in any list get a minimal
#       synthetic stanza.
#   Not byte-perfect, but produces a PARSEABLE status apt/dpkg can use so
#   subsequent installs (e.g. samba) proceed. Never leaves status worse than
#   found (restores the pre-rebuild copy if the reconstruction doesn't parse).
#   Returns 0 if the rebuilt DB parses.
# ---------------------------------------------------------------------------
rebuild_dpkg_status() {
    _dpkg_guard_log "rebuild_dpkg_status: reconstructing status from on-disk metadata"
    local infodir=/var/lib/dpkg/info wanted new arch lists p cnt
    wanted=$(mktemp) || return 1
    new=$(mktemp) || { rm -f "$wanted"; return 1; }
    # Installed package base names (drop directory, .list suffix, and :arch).
    ls "$infodir"/*.list 2>/dev/null | sed 's#.*/##; s/\.list$//; s/:.*//' | sort -u > "$wanted"
    if [ ! -s "$wanted" ]; then
        _dpkg_guard_log "rebuild_dpkg_status: no /var/lib/dpkg/info/*.list found -- cannot rebuild"
        rm -f "$wanted" "$new"; return 1
    fi
    arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    lists=$(ls /var/lib/apt/lists/*_Packages 2>/dev/null)
    # Single pass over the apt Packages lists: emit a status stanza for each
    # wanted package (strip repo-only fields, force 'Status: install ok installed').
    if [ -n "$lists" ]; then
        awk -v wf="$wanted" '
            BEGIN{ while((getline n < wf)>0) want[n]=1; RS=""; FS="\n" }
            {
                pkg=""
                for(i=1;i<=NF;i++){ if($i ~ /^Package: /){ pkg=substr($i,10); break } }
                if(pkg=="" || !(pkg in want) || seen[pkg]) next
                seen[pkg]=1
                for(i=1;i<=NF;i++){
                    if($i ~ /^(Filename|Size|MD5sum|SHA1|SHA256|SHA512|Description-md5|Task|Supported):/) continue
                    print $i
                }
                print "Status: install ok installed"
                print ""
            }
        ' $lists >> "$new" 2>/dev/null
    fi
    # Wanted packages NOT found in any Packages list -> minimal synthetic stanza.
    awk 'BEGIN{RS="";FS="\n"} { for(i=1;i<=NF;i++) if($i ~ /^Package: /){ print substr($i,10); break } }' "$new" 2>/dev/null | sort -u > "${new}.got"
    comm -23 "$wanted" "${new}.got" 2>/dev/null | while read -r p; do
        [ -n "$p" ] || continue
        printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nSection: misc\nArchitecture: %s\nVersion: 0\nMaintainer: memlabs\nDescription: recovered by memlabs rebuild_dpkg_status\n\n' "$p" "$arch" >> "$new"
    done
    rm -f "${new}.got"
    # Swap in the rebuild and verify it parses; restore the pre-rebuild copy if
    # it doesn't (so we're never worse off than the corrupt DB we started with).
    cp -a /var/lib/dpkg/status "/var/lib/dpkg/status.prerebuild.$$" 2>/dev/null || true
    if cp -f "$new" /var/lib/dpkg/status 2>/dev/null && dpkg-query -W >/dev/null 2>&1; then
        sync 2>/dev/null || true
        cnt=$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)
        _dpkg_guard_log "rebuild_dpkg_status: OK -- rebuilt status with ${cnt} packages"
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold >/dev/null 2>&1 || true
        dpkg_save_known_good
        rm -f "$wanted" "$new" "/var/lib/dpkg/status.prerebuild.$$"
        return 0
    fi
    cp -f "/var/lib/dpkg/status.prerebuild.$$" /var/lib/dpkg/status 2>/dev/null || true
    rm -f "$wanted" "$new" "/var/lib/dpkg/status.prerebuild.$$"
    _dpkg_guard_log "rebuild_dpkg_status: reconstruction did NOT parse -- left status unchanged"
    return 1
}

# Check DB consistency; log facts; restore + refresh known-good as needed.
#   $1 = phase label (PRE/POST/...), $2 = command description
dpkg_guard_check() {
    local phase="${1:-CHECK}" desc="${2:-}"
    if dpkg_status_ok; then
        _dpkg_guard_log "${phase} OK ${desc}: $(dpkg_status_facts)"
        dpkg_save_known_good
        return 0
    fi
    _dpkg_guard_log "${phase} CORRUPT ${desc}: $(dpkg_status_facts) -- restoring"
    # Restore order: trusted backups first, then reconstruct from on-disk
    # metadata as a last resort when no parseable backup exists.
    dpkg_restore_known_good || repair_dpkg_status || rebuild_dpkg_status || true
    if dpkg_status_ok; then
        _dpkg_guard_log "${phase} RECOVERED ${desc}: $(dpkg_status_facts)"
        dpkg_save_known_good
        return 0
    fi
    _dpkg_guard_log "${phase} STILL-CORRUPT ${desc}: $(dpkg_status_facts)"
    return 1
}

# ---------------------------------------------------------------------------
# apt_retry <command> [args...]
#   Retries up to 3 times with exponential backoff (10/20/30s).
#   Runs dpkg --configure -a between retries to recover from
#   interrupted dpkg state. Sets NEEDRESTART_SUSPEND=1 to prevent
#   the Ubuntu needrestart dpkg hook from querying D-Bus (which
#   fails over SSH and causes false exit codes).
#   Guards the dpkg status DB BEFORE and AFTER the operation: checks
#   consistency, logs facts for diagnosis, and restores from the known-good
#   snapshot if a hard power-off truncated it.
# ---------------------------------------------------------------------------
apt_retry() {
    local max=3 attempt=0 rc=0
    # PRE: verify/repair the DB and refresh (or create) the known-good snapshot
    # from the current good state before we touch it. '|| true' so a still-bad
    # DB never aborts a caller running under 'set -e'.
    dpkg_guard_check "PRE" "$*" || true
    while [ $attempt -lt $max ]; do
        attempt=$((attempt + 1))
        if NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive "$@"; then
            # POST: verify the DB survived the op; restore + refresh if needed.
            dpkg_guard_check "POST" "$* (attempt $attempt)" || true
            return 0
        fi
        rc=$?
        echo "[apt_retry] attempt $attempt/$max failed (rc=$rc), waiting $((attempt * 10))s..." >&2
        sleep $((attempt * 10))
        # Recover interrupted/wedged dpkg+debconf state between retries
        recover_dpkg || true
    done
    # Failure path: still verify the DB so a truncated one gets restored.
    dpkg_guard_check "POST-FAIL" "$*" || true
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
