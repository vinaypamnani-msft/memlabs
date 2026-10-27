#!/bin/bash
# 06-desktop-services.sh — Enable GDM3, NetworkManager, xrdp, firewall
set -euo pipefail
systemctl set-default graphical.target
systemctl enable gdm3.service
systemctl enable NetworkManager.service
systemctl enable xrdp.service
adduser xrdp ssl-cert || true
ufw allow 3389/tcp || true
echo "=== Desktop services enabled ==="
