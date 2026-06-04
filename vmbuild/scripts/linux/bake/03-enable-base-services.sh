#!/bin/bash
# 03-enable-base-services.sh — Enable Hyper-V and guest agent services
set -euo pipefail
systemctl daemon-reload
systemctl enable qemu-guest-agent.service
systemctl enable hv-kvp-daemon.service
systemctl enable hv-vss-daemon.service
# Install kernel-exact HV tools if the meta-package version doesn't match
# the running kernel (can happen if dist-upgrade bumped the kernel).
dpkg -s "linux-cloud-tools-$(uname -r)" >/dev/null 2>&1 \
  || apt_retry apt-get install -y "linux-tools-$(uname -r)" "linux-cloud-tools-$(uname -r)"
echo "=== Base services enabled ==="
