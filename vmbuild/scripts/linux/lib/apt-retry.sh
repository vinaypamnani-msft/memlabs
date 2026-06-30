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
    # Recover from any interrupted dpkg state before proceeding
    dpkg --configure -a 2>/dev/null || true
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
        # Recover interrupted dpkg between retries
        dpkg --configure -a 2>/dev/null || true
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
