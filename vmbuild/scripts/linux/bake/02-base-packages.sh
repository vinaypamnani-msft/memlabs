#!/bin/bash
# 02-base-packages.sh — Install Hyper-V tools, qemu-guest-agent, openssh, samba
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
wait_for_apt_lock
# samba is baked (not left to cloud-init's first-boot 'packages:' install) so
# smbd is guaranteed present on every deployed Linux VM. First-boot apt on a
# heavily contended host (esp. the Proxy: Ubuntu Server + squid/webui apt churn)
# could otherwise leave the first-boot samba install racing/failing, and
# cloud-init's 'systemctl enable --now smbd || true' swallows it -- stranding
# TCP 445 down. Baking it here mirrors how openssh/qemu-guest-agent are made
# reliable; cloud-init still writes smb.conf + sets smbpasswd + enables smbd.
apt_retry apt-get install -y linux-tools-virtual linux-cloud-tools-virtual qemu-guest-agent openssh-server samba
echo "=== Base packages installed ==="
