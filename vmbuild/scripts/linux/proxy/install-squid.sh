#!/bin/bash
# install-squid.sh — Install and configure Squid forward proxy.
#
# Required variables (set by caller before sourcing):
#   CONF_B64  — base64-encoded squid.conf content
#
# Idempotent: skips apt whenever every required package is already installed.
# Reports PROXY_READY on success.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Package-present path works for both a newly rebaked image (Squid deliberately
# disabled) and a configured Proxy rerun. An older image takes the unchanged
# apt fallback, so current code can deploy either image generation.
PACKAGES_PRESENT=1
for pkg in squid ufw python3-flask; do
    if ! dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed; then
        PACKAGES_PRESENT=0
        break
    fi
done

echo "[install-squid] Starting (PACKAGES_PRESENT=$PACKAGES_PRESENT)"

if [ "$PACKAGES_PRESENT" = "1" ]; then
    echo "[install-squid] Package-present path; zero apt invocations"
else
    # Snapshot packaging state up front so any failure below can be
    # root-caused from the log: dpkg DB already corrupt on arrival? another
    # apt/dpkg/unattended-upgrades run or cloud-init first-boot install still
    # in progress? disk full? (Diagnostic only — never fails the install.)
    preflight_apt_state || true

    # Verify DNS + network before apt operations.  apt-get hangs indefinitely
    # if DNS is broken (systemd-resolved misconfigured, no upstream forwarder).
    echo "[install-squid] Checking DNS and network connectivity..."
    DNS_OK=0
    for attempt in 1 2 3; do
        if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
            DNS_OK=1
            break
        fi
        echo "[install-squid] DNS probe $attempt/3 failed; waiting 10s..." >&2
        # If systemd-resolved is broken, try adding a public fallback
        if [ "$attempt" = "2" ]; then
            echo "[install-squid] Adding 8.8.8.8 as fallback DNS..." >&2
            if command -v resolvectl >/dev/null 2>&1; then
                resolvectl dns eth0 8.8.8.8 2>/dev/null || true
            fi
            # Direct fallback if resolvectl doesn't help
            if ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
                echo "nameserver 8.8.8.8" >> /etc/resolv.conf 2>/dev/null || true
            fi
        fi
        sleep 10
    done
    if [ "$DNS_OK" = "0" ]; then
        echo "[install-squid] ERROR: Cannot resolve archive.ubuntu.com after 3 attempts" >&2
        echo "[install-squid] DNS config:" >&2
        resolvectl status 2>/dev/null | head -20 >&2 || cat /etc/resolv.conf >&2
        exit 1
    fi
    echo "[install-squid] DNS OK"

    # Kill unattended-upgrades if running — it holds the dpkg lock for minutes.
    systemctl stop unattended-upgrades.service 2>/dev/null || true
    pkill -9 -x unattended-upgr 2>/dev/null || true
    echo "[install-squid] Running apt-get update..."
    wait_for_apt_lock
    apt_retry apt-get update -y

    # Bring the packaging tooling current FIRST, in an isolated transaction.
    # On a stale base image, 'apt-get install squid' drags in an upgrade of
    # debconf/apt-utils/dpkg/apt as a side effect. Upgrading debconf inside a
    # large mixed transaction is the fragile operation that wedges here:
    #   E: Cannot get debconf version. Is debconf installed?
    #   debconf: apt-extracttemplates failed: 25600
    # (apt-extracttemplates, from apt-utils, queries the debconf version during
    # pre-configuration; while debconf itself is mid-upgrade that query fails).
    # Doing it alone keeps the transaction tiny, lets recover_dpkg heal any
    # wedge, and leaves debconf/apt-utils current so the squid install below no
    # longer upgrades them.
    echo "[install-squid] Bringing packaging tooling current (debconf/apt-utils/dpkg)..."
    apt_retry apt-get install -y --only-upgrade debconf debconf-i18n apt apt-utils dpkg

    echo "[install-squid] Installing squid, ufw, python3-flask..."
    apt_retry apt-get install -y squid ufw python3-flask
    echo "[install-squid] Packages installed"
    # Flush the freshly-written dpkg status DB to the VHDX now. dpkg keeps the
    # previous good copy as status-old; syncing here guarantees BOTH the new
    # status and status-old are durably on disk, so if the VM is later hard-
    # reset (bake/last-resort TurnOff) repair_dpkg_status has a parseable backup
    # to restore -- the exact recovery that failed when neither copy was flushed.
    sync || true
fi

install -d -m 0755 /etc/squid

# Create empty blocklist if it doesn't exist so Squid doesn't fail on start.
[ -f /etc/squid/blocklist.txt ] || touch /etc/squid/blocklist.txt
chmod 0644 /etc/squid/blocklist.txt

# Deploy squid.conf from base64 payload.
NEW_CONF=$(mktemp)
echo "$CONF_B64" | base64 -d > "$NEW_CONF"
chmod 0644 "$NEW_CONF"

if [ -f /etc/squid/squid.conf ] && cmp -s "$NEW_CONF" /etc/squid/squid.conf; then
    rm -f "$NEW_CONF"
    echo "[install-squid] Config unchanged"
else
    mv "$NEW_CONF" /etc/squid/squid.conf
    echo "[install-squid] Config deployed"
fi

echo "[install-squid] Enabling and restarting squid service..."
systemctl enable squid >/dev/null 2>&1 || true
systemctl restart squid
echo "[install-squid] squid service restarted (rc=$?)"

# Show squid service status for diagnostics
systemctl --no-pager status squid 2>&1 | head -15 || true

# Open 3128 in ufw (no-op if already allowed)
command -v ufw >/dev/null 2>&1 && ufw allow 3128/tcp || true

# Self-test: wait up to 120s for Squid to start listening.
# On a busy host with 25+ VMs, systemd can take 60+ seconds to fully start squid.
echo "[install-squid] Waiting for squid to listen on :3128..."
for i in $(seq 1 120); do
    if ss -ltn 'sport = :3128' 2>/dev/null | grep -q ':3128'; then
        echo "[install-squid] squid listening on :3128 after ${i}s"
        echo "PROXY_READY"
        exit 0
    fi
    sleep 1
done

# Not listening after 120s. Before failing, check if squid is still actively
# starting up (cache.log growing, squid process alive). If so, give it
# another 120s — on a very busy host the initial cache/swap build can be slow.
echo "[install-squid] squid not listening after 120s; checking if still starting up..."
SQUID_PID=$(pgrep -x squid 2>/dev/null || true)
CACHE_LOG="/var/log/squid/cache.log"
if [ -n "$SQUID_PID" ] && [ -f "$CACHE_LOG" ]; then
    PREV_SIZE=$(stat -c%s "$CACHE_LOG" 2>/dev/null || echo 0)
    echo "[install-squid] squid PID=$SQUID_PID, cache.log size=$PREV_SIZE; extending wait..."
    for i in $(seq 1 120); do
        if ss -ltn 'sport = :3128' 2>/dev/null | grep -q ':3128'; then
            echo "[install-squid] squid listening on :3128 after $((120 + i))s (extended wait)"
            echo "PROXY_READY"
            exit 0
        fi
        # Every 15s, check if the log is still growing or squid is still alive
        if [ $((i % 15)) -eq 0 ]; then
            CUR_SIZE=$(stat -c%s "$CACHE_LOG" 2>/dev/null || echo 0)
            SQUID_PID=$(pgrep -x squid 2>/dev/null || true)
            if [ -z "$SQUID_PID" ]; then
                echo "[install-squid] squid process died during extended wait"
                break
            fi
            if [ "$CUR_SIZE" = "$PREV_SIZE" ]; then
                echo "[install-squid] cache.log stalled at ${CUR_SIZE} bytes (squid may be stuck)"
                break
            fi
            echo "[install-squid] cache.log growing ($PREV_SIZE -> $CUR_SIZE bytes), squid PID=$SQUID_PID; still waiting..."
            PREV_SIZE=$CUR_SIZE
        fi
        sleep 1
    done
else
    echo "[install-squid] squid not running (PID='$SQUID_PID') or no cache.log; cannot extend wait"
fi

echo "[install-squid] squid NOT listening on :3128"
echo "[install-squid] Squid error log (last 30 lines):"
tail -30 /var/log/squid/cache.log 2>/dev/null || echo "(no cache.log found)"
echo "[install-squid] journalctl squid (last 20 lines):"
journalctl -u squid --no-pager -n 20 2>/dev/null || echo "(no journal entries)"
exit 1
