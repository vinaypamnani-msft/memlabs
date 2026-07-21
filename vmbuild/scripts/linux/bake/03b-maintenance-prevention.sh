#!/bin/bash
# 03b-maintenance-prevention.sh — Prevent maintenance-mode boot on fsck failure.
# Configure GRUB to auto-repair and systemd to never drop to emergency mode.
set -euo pipefail

# Add fsck.mode=force fsck.repair=yes to kernel command line
GRUB_FILE="/etc/default/grub"
if ! grep -q 'fsck.repair=yes' "$GRUB_FILE"; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 fsck.mode=force fsck.repair=yes"/' "$GRUB_FILE"
    # Also add to GRUB_CMDLINE_LINUX if GRUB_CMDLINE_LINUX_DEFAULT doesn't exist
    if ! grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB_FILE"; then
        sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 fsck.mode=force fsck.repair=yes"/' "$GRUB_FILE"
    fi
    update-grub
fi

# Tell systemd to never drop to emergency/rescue on failure — just reboot
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/no-emergency.conf << 'EOF'
[Manager]
DefaultTimeoutStartSec=180s
DefaultTimeoutStopSec=90s
EOF

# Override emergency.service to just reboot instead of prompting
mkdir -p /etc/systemd/system/emergency.service.d
cat > /etc/systemd/system/emergency.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/systemctl reboot
EOF

systemctl daemon-reload

# ── Root filesystem durability tuning ────────────────────────────────────
# Context: a hard power-off (Stop-VM -TurnOff) of a VM mid apt/dpkg write can
# truncate /var/lib/dpkg/status ("end of file after field name ''"). The real
# fix is host-side (don't plug-pull a live guest). Here we only apply the cheap,
# safe guest-side hardening:
#
#  * noatime -- stop writing an access-time stamp on every file read. Fewer
#    metadata writes => a narrower dirty-writeback window on a busy host. This
#    is a write-churn/perf tweak, NOT the corruption fix, but it's free.
#
#  * Write barriers stay ON. ext4 mounts barrier=1 by default, which is what
#    makes the journal commit durable across a reset. We deliberately do NOT
#    add nobarrier/barrier=0 anywhere -- that would DEFEAT durability. (Left as
#    the default; documented here so nobody "optimizes" it away.)
#
# We intentionally do NOT switch data=journal (heavy write amplification, and
# incompatible with fast_commit) or disable the fast_commit feature (can't be
# toggled on a mounted root fs; needs an offline tune2fs/initramfs hook, and on
# 24.04's 6.8 kernel fast_commit is mature) -- see the SMB/dpkg design notes.
if [ -f /etc/fstab ]; then
    cp -a /etc/fstab /etc/fstab.memlabs.bak 2>/dev/null || true
    # Idempotent: add ',noatime' to the ext4 root ('/') mount options only if
    # it isn't already there. Only the matched line is rewritten.
    awk 'BEGIN{OFS="\t"} ($2=="/" && $3=="ext4" && $4 !~ /(^|,)noatime(,|$)/){$4=$4",noatime"} {print}' \
        /etc/fstab > /etc/fstab.new 2>/dev/null && mv /etc/fstab.new /etc/fstab || rm -f /etc/fstab.new
    mount -o remount,noatime / 2>/dev/null || true
    echo "root fs: ensured noatime (barriers left ON by default)"
fi

echo "=== Maintenance-mode prevention configured ==="
