#!/bin/bash
# 02-base-packages.sh — Install Hyper-V tools, qemu-guest-agent, openssh, samba,
# and the AD domain-join stack.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
wait_for_apt_lock
# samba is baked so smbd is guaranteed present on every deployed Linux VM once
# this image is rebuilt. Until then, the deploy path installs it at first boot
# (New-LinuxCloudInit's detect-and-install runcmd), which auto-skips when a
# baked image already ships it. Baking mirrors how openssh/qemu-guest-agent are
# made reliable and avoids the first-boot apt race that left TCP 445 down.
apt_retry apt-get install -y linux-tools-virtual linux-cloud-tools-virtual qemu-guest-agent openssh-server samba

# The realmd/sssd stack is what New-LinuxRealmJoinConfig passes as
# ExtraPackages, so on a joinDomain VM it is ~13 packages pulled at first boot
# by cloud-init -- the biggest apt transaction of the boot, running exactly
# while Phase 1 copies every other VM's base image. Baking it means
# roles/ensure-packages.sh finds everything present and skips apt entirely.
# Keep this list in sync with $extraPackages in Common.Linux.ps1.
echo "=== Domain-join stack (realmd/sssd) ==="
apt_retry apt-get install -y \
    realmd sssd sssd-ad sssd-tools adcli krb5-user packagekit \
    samba-common-bin oddjob oddjob-mkhomedir libnss-sss libpam-sss

# krb5-user ships a default /etc/krb5.conf and enables no realm; realm-join.sh
# rewrites it per-domain. Leave the service masked-off state alone -- sssd is
# configured and started by the join, not by the bake.
echo "=== Base packages installed ==="
