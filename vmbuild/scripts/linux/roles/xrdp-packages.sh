#!/bin/bash
# xrdp-packages.sh — Install xrdp + xfce4 desktop packages.
set -euo pipefail
echo "[memlabs-rdp-packages] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

wait_for_apt_lock
apt_retry apt-get update
apt_retry apt-get install -y \
    xrdp xorgxrdp xfce4 xfce4-goodies dbus-x11 xorg \
    apt-transport-https ca-certificates gnupg wget

echo "[memlabs-rdp-packages] done: $(date -Is)"
