#!/bin/bash
# 03-enable-base-services.sh — Enable Hyper-V and guest agent services
set -euo pipefail
systemctl daemon-reload
systemctl enable qemu-guest-agent.service
systemctl enable hv-kvp-daemon.service
systemctl enable hv-vss-daemon.service
# Enable smbd from the baked image so it starts on every deployed VM. cloud-init
# overwrites /etc/samba/smb.conf and restarts smbd with the real config.
systemctl enable smbd.service || true
# Install kernel-exact HV tools if the meta-package version doesn't match
# the running kernel (can happen if dist-upgrade bumped the kernel).
dpkg -s "linux-cloud-tools-$(uname -r)" >/dev/null 2>&1 \
  || apt_retry apt-get install -y "linux-tools-$(uname -r)" "linux-cloud-tools-$(uname -r)"
echo "=== Base services enabled ==="
