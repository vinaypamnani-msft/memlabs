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

# Full DATA journaling on the root fs (data=journal): an unannounced hard
# power-off then leaves file DATA crash-consistent (old-or-new complete, never
# truncated) -- not just metadata. This is the strong fix for the routine
# nightly hard shutoffs that were truncating /var/lib/dpkg/status.
#
# Set via rootflags= on the kernel cmdline (GRUB_CMDLINE_LINUX, always applied)
# because the root data= mode can ONLY be chosen at the initial mount -- a
# later fstab remount cannot change it. Safe on a fast_commit-enabled fs: the
# kernel simply does not use fast_commit under data=journal (no feature-bit
# clearing / initramfs hook needed, so no unattended-boot brick risk). commit=1
# flushes the journal every 1s. Tradeoff (per kernel docs): data=journal
# disables delayed allocation + O_DIRECT and roughly doubles write traffic --
# acceptable on the few small Linux lab VMs; the win is surviving the nightly
# plug-pulls. To revert: remove 'rootflags=data=journal,commit=1' from
# /etc/default/grub and run update-grub.
if ! grep -q 'rootflags=data=journal' "$GRUB_FILE"; then
    if grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE"; then
        sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 rootflags=data=journal,commit=1"/' "$GRUB_FILE"
    else
        echo 'GRUB_CMDLINE_LINUX="rootflags=data=journal,commit=1"' >> "$GRUB_FILE"
    fi
    update-grub
    echo "root fs: enabled data=journal,commit=1 via rootflags (full data journaling)"
fi

# Make a hard hang SAY something. These VMs log
# "NMI watchdog: Perf NMI watchdog permanently disabled" at boot because the
# synthetic CPU exposes no PMU, so the hardware lockup detector is never armed
# and a frozen kernel produces total silence -- ZZ-TOFU froze mid-systemd on
# 2026-08-16 and 08-17 and printed nothing at all, on any channel, ever.
#
#   softlockup_panic=1   the SOFT lockup detector is timer-based, so unlike the
#                        NMI one it still works without a PMU. Panic => backtrace.
#   unknown_nmi_panic=1  makes a host-injected NMI (tools/Debug-VmHungGuest.ps1)
#                        produce a full trace instead of a one-line "received
#                        for unknown reason".
#   panic=0              halt on panic instead of rebooting, so the trace stays
#                        on the console for a screenshot.
#
# This has to be BAKED: the hang happens on first boot, long before any
# cloud-init runcmd could edit grub, and a cmdline change needs a reboot anyway.
# Cost when nothing is wrong: nothing. Cost when something is: a named function
# instead of a blank screen.
if ! grep -q 'softlockup_panic=1' "$GRUB_FILE"; then
    if grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE"; then
        sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 softlockup_panic=1 unknown_nmi_panic=1 panic=0"/' "$GRUB_FILE"
    else
        echo 'GRUB_CMDLINE_LINUX="softlockup_panic=1 unknown_nmi_panic=1 panic=0"' >> "$GRUB_FILE"
    fi
    update-grub
    echo "lockup detection: softlockup_panic=1 unknown_nmi_panic=1 panic=0 (no PMU here, so the NMI watchdog cannot arm itself)"
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
# Context: these lab VMs can be hard-powered-off WITHOUT WARNING (e.g. nightly
# host maintenance around 02:00). A plug-pull mid apt/dpkg write can truncate
# /var/lib/dpkg/status ("end of file after field name ''"). Since the hard
# resets are routine and unavoidable here, harden the guest to lose as little
# as possible. Cheap, no-boot-risk levers only:
#
#  * noatime -- no access-time write on every read (less metadata churn).
#  * commit=1 -- flush the ext4 journal every 1s instead of the 5s default, so
#    a reset loses at most ~1s of journalled metadata.
#  * Write barriers stay ON (ext4 default barrier=1 -- what makes the journal
#    commit durable across a reset). We deliberately do NOT add
#    nobarrier/barrier=0 -- that would DEFEAT durability. Documented so nobody
#    "optimizes" it away.
#
# We intentionally do NOT switch data=journal (2x write amplification, needs
# fast_commit off + a rootflags/initramfs change with unattended-boot risk) or
# disable fast_commit -- the dirty-writeback sysctls below give most of the
# resilience for none of that risk. See the SMB/dpkg design notes.
if [ -f /etc/fstab ]; then
    cp -a /etc/fstab /etc/fstab.memlabs.bak 2>/dev/null || true
    # Idempotent: for the ext4 root ('/') add noatime and commit=1 only if not
    # already present. Only the matched line is rewritten.
    awk 'BEGIN{OFS="\t"}
         ($2=="/" && $3=="ext4"){
             opts=$4
             if(opts !~ /(^|,)noatime(,|$)/) opts=opts",noatime"
             if(opts !~ /(^|,)commit=/)      opts=opts",commit=1"
             $4=opts
         }
         {print}' /etc/fstab > /etc/fstab.new 2>/dev/null && mv /etc/fstab.new /etc/fstab || rm -f /etc/fstab.new
    mount -o remount / 2>/dev/null || true
    echo "root fs: ensured noatime,commit=1 (barriers left ON by default)"
fi

# Shrink the dirty-page writeback window so an unannounced hard power-off loses
# far less unflushed data: flush dirty pages to the VHDX within ~1-2s instead of
# the ~30s default, and start background writeback earlier. This is the cheap,
# no-boot-risk resilience lever (vs data=journal's write amplification). Also
# written by cloud-init so already-deployed VMs get it without a rebake.
cat > /etc/sysctl.d/90-memlabs-durability.conf << 'EOF'
# Flush dirty data quickly so an unannounced hard power-off loses little.
vm.dirty_writeback_centisecs = 100
vm.dirty_expire_centisecs = 200
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
EOF
sysctl -p /etc/sysctl.d/90-memlabs-durability.conf 2>/dev/null || true
echo "durability sysctls applied (fast dirty-page writeback)"

echo "=== Maintenance-mode prevention configured ==="
