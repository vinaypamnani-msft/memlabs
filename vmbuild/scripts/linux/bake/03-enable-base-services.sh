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
# Install kernel-exact HV tools for the kernel the DEPLOYED VM will boot.
#
# Not $(uname -r): step 01's dist-upgrade routinely installs a newer kernel, and
# nothing reboots the bake VM before this point, so $(uname -r) is the kernel
# that is on its way out. The 2026-05-30 bake proved it -- dpkg.log shows the
# dist-upgrade pulling in 6.8.0-124 at 18:03:56 and this step then installing
# linux-cloud-tools-6.8.0-117 at 18:04:23, tools for a kernel no deployed VM
# would ever run. Deployed VMs boot the NEWEST installed kernel, so target that.
#
# Without the matching binary hv_kvp_daemon exits immediately, the host never
# learns the guest's IP, and the deploy path has to pull the right package over
# the internet during first boot -- the exact apt round trip the bake exists to
# remove.
TARGET_KERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)"
if [ -z "$TARGET_KERNEL" ]; then
    echo "ERROR: no /boot/vmlinuz-* found; cannot determine the kernel to install HV tools for." >&2
    exit 1
fi
echo "running kernel: $(uname -r) / kernel deployed VMs will boot: ${TARGET_KERNEL}"
dpkg -s "linux-cloud-tools-${TARGET_KERNEL}" >/dev/null 2>&1 \
  || apt_retry apt-get install -y "linux-tools-${TARGET_KERNEL}" "linux-cloud-tools-${TARGET_KERNEL}"

# Verify rather than assume: a missing kernel-exact package here is invisible
# until a deployed VM fails to report its IP hours into a build.
for pkg in "linux-tools-${TARGET_KERNEL}" "linux-cloud-tools-${TARGET_KERNEL}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || { echo "ERROR: ${pkg} is not installed." >&2; exit 1; }
done
echo "=== Base services enabled (HV tools match ${TARGET_KERNEL}) ==="
