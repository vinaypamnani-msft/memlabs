#!/bin/bash
# xrdp-packages.sh — Install xrdp + xfce4 desktop packages.
set -euo pipefail
echo "[memlabs-rdp-packages] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

# Idempotency: skip if xrdp and xfce4-session are already installed.
if command -v xrdp >/dev/null 2>&1 && command -v xfce4-session >/dev/null 2>&1; then
    echo "[memlabs-rdp-packages] already installed (xrdp + xfce4); skipping."
    exit 0
fi

wait_for_apt_lock
apt_retry apt-get update
apt_retry apt-get install -y \
    xrdp xorgxrdp xfce4 xfce4-goodies dbus-x11 xorg \
    apt-transport-https ca-certificates gnupg wget

echo "[memlabs-rdp-packages] done: $(date -Is)"
