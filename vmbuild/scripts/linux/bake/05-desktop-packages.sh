#!/bin/bash
# 05-desktop-packages.sh — Install GNOME desktop, xrdp, and tools
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
wait_for_apt_lock
apt_retry apt-get install -y \
  ubuntu-desktop-minimal gdm3 network-manager xrdp xorgxrdp \
  gnome-tweaks dconf-cli unzip \
  apt-transport-https ca-certificates gnupg wget
echo "=== Desktop packages installed ==="
