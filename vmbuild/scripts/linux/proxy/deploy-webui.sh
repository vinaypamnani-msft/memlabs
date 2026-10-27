#!/bin/bash
# deploy-webui.sh — Deploy the Proxy Admin Flask web UI.
#
# Required variables (set by caller before sourcing):
#   APP_B64  — base64-encoded proxy-admin.py content
#   SVC_B64  — base64-encoded proxy-admin.service content
#
# Idempotent: only restarts if files changed.
# Reports WEBUI_READY on success.
set -euo pipefail

install -d -m 0755 /opt/memlabs/proxy-admin

NEW_APP=$(mktemp)
echo "$APP_B64" | base64 -d > "$NEW_APP"

APP_CHANGED=0
if [ -f /opt/memlabs/proxy-admin/app.py ] && cmp -s "$NEW_APP" /opt/memlabs/proxy-admin/app.py; then
    rm -f "$NEW_APP"
else
    mv "$NEW_APP" /opt/memlabs/proxy-admin/app.py
    chmod 0755 /opt/memlabs/proxy-admin/app.py
    APP_CHANGED=1
fi

NEW_SVC=$(mktemp)
echo "$SVC_B64" | base64 -d > "$NEW_SVC"

SVC_CHANGED=0
if [ -f /etc/systemd/system/memlabs-proxy-admin.service ] && cmp -s "$NEW_SVC" /etc/systemd/system/memlabs-proxy-admin.service; then
    rm -f "$NEW_SVC"
else
    mv "$NEW_SVC" /etc/systemd/system/memlabs-proxy-admin.service
    chmod 0644 /etc/systemd/system/memlabs-proxy-admin.service
    systemctl daemon-reload
    SVC_CHANGED=1
fi

systemctl enable memlabs-proxy-admin >/dev/null 2>&1 || true

if [ "$APP_CHANGED" = "1" ] || [ "$SVC_CHANGED" = "1" ] || ! systemctl is-active --quiet memlabs-proxy-admin; then
    systemctl restart memlabs-proxy-admin
fi

# Open 8443 in ufw
command -v ufw >/dev/null 2>&1 && ufw allow 8443/tcp || true

# Self-test: wait up to 10s for the web UI to start listening
for i in $(seq 1 10); do
    if ss -ltn 'sport = :8443' 2>/dev/null | grep -q ':8443'; then
        echo WEBUI_READY
        exit 0
    fi
    sleep 1
done
echo 'proxy-admin not listening on 8443'
exit 1
