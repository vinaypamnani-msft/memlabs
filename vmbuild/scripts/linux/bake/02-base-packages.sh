#!/bin/bash
# 02-base-packages.sh — Install Hyper-V tools, qemu-guest-agent, openssh, samba
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
wait_for_apt_lock
# samba is baked so smbd is guaranteed present on every deployed Linux VM once
# this image is rebuilt. Until then, the deploy path installs it at first boot
# (New-LinuxCloudInit's detect-and-install runcmd), which auto-skips when a
# baked image already ships it. Baking mirrors how openssh/qemu-guest-agent are
# made reliable and avoids the first-boot apt race that left TCP 445 down.
apt_retry apt-get install -y linux-tools-virtual linux-cloud-tools-virtual qemu-guest-agent openssh-server samba
echo "=== Base packages installed ==="
