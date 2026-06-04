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

if [ "$FAST_PATH" = "0" ]; then
    wait_for_apt_lock
    apt_retry apt-get update -y
    apt_retry apt-get install -y squid ufw python3-flask
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
else
    mv "$NEW_CONF" /etc/squid/squid.conf
fi

systemctl enable squid >/dev/null 2>&1 || true
systemctl restart squid

# Open 3128 in ufw (no-op if already allowed)
command -v ufw >/dev/null 2>&1 && ufw allow 3128/tcp || true

# Self-test: wait up to 15s for Squid to start listening.
for i in $(seq 1 15); do
    if ss -ltn 'sport = :3128' 2>/dev/null | grep -q ':3128'; then
        echo "PROXY_READY"
        exit 0
    fi
    sleep 1
done
echo "squid not listening on 3128 after 15s"
exit 1
