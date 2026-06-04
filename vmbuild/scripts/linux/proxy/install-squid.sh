#!/bin/bash
# install-squid.sh — Install and configure Squid forward proxy.
#
# Required variables (set by caller before sourcing):
#   CONF_B64  — base64-encoded squid.conf content
#
# Idempotent: skips apt if squid is already running on :3128.
# Reports PROXY_READY on success.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Fast-path: if squid is already installed, active, and listening on 3128,
# we still rewrite the config (subnets may have changed) and reload, but
# skip apt-get entirely. Saves ~30-60s on re-runs.
FAST_PATH=0
if command -v squid >/dev/null 2>&1 && systemctl is-active --quiet squid && \
   ss -ltn 'sport = :3128' 2>/dev/null | grep -q ':3128'; then
    FAST_PATH=1
fi

echo "[install-squid] Starting (FAST_PATH=$FAST_PATH)"

if [ "$FAST_PATH" = "0" ]; then
    echo "[install-squid] Running apt-get update..."
    wait_for_apt_lock
    apt_retry apt-get update -y
    echo "[install-squid] Installing squid, ufw, python3-flask..."
    apt_retry apt-get install -y squid ufw python3-flask
    echo "[install-squid] Packages installed"
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
