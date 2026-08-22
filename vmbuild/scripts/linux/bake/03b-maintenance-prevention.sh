#!/bin/bash
# 03b-maintenance-prevention.sh — Prevent maintenance-mode boot on fsck failure.
# Configure GRUB to auto-repair and systemd to never drop to emergency mode.
set -euo pipefail

# ── Kernel cmdline helpers ───────────────────────────────────────────────
# One sed per setting had grown a near-duplicate 8-line block per parameter,
# and gave no way to REMOVE a parameter -- so a setting baked by an older copy
# of this script could never be taken back off.
GRUB_FILE="/etc/default/grub"

_grub_get() {
    sed -n "s|^$1=\"\(.*\)\"$|\1|p" "$GRUB_FILE" | tail -1
}

_grub_rewrite() {
    local var="$1" newval="$2"
    # sed delimiter is | because values contain / (root=/dev/...).
    if grep -q "^${var}=" "$GRUB_FILE"; then
        sed -i "s|^${var}=.*|${var}=\"${newval}\"|" "$GRUB_FILE"
    else
        echo "${var}=\"${newval}\"" >> "$GRUB_FILE"
    fi
}

# _strip_tokens <cmdline> <regex> -- delete every space-delimited word matching
# <regex>. Loops to fixpoint because sed matches non-overlapping: on
# "console=tty1 console=ttyS0" a single pass consumes the space BETWEEN them,
# so the second token is left behind. One pass silently half-worked.
_strip_tokens() {
    local cur=" $1 " prev=''
    while [ "$cur" != "$prev" ]; do
        prev="$cur"
        cur="$(echo "$cur" | sed -e "s| $2 | |g")"
    done
    echo "$cur" | tr -s ' ' | sed -e 's|^ ||' -e 's| $||'
}

# grub_set_param VAR token [replaces_regex]
# Adds `token`, first deleting any word matching `replaces_regex`, so a re-run
# or a conflicting older value never leaves both. Idempotent.
grub_set_param() {
    local var="$1" token="$2" drop="${3:-}"
    local cur; cur="$(_grub_get "$var")"
    [ -n "$drop" ] && cur="$(_strip_tokens "$cur" "$drop")"
    case " $cur " in
        *" $token "*) ;;
        *) cur="$cur $token" ;;
    esac
    cur="$(echo "$cur" | tr -s ' ' | sed -e 's|^ ||' -e 's| $||')"
    _grub_rewrite "$var" "$cur"
}

grub_drop_param() {
    local var="$1" drop="$2"
    local cur; cur="$(_grub_get "$var")"
    _grub_rewrite "$var" "$(_strip_tokens "$cur" "$drop")"
}

grub_set_kv() {
    if grep -q "^$1=" "$GRUB_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$GRUB_FILE"; else echo "$1=$2" >> "$GRUB_FILE"; fi
}

echo "=== cmdline before ==="
grep -E '^GRUB_CMDLINE_LINUX(_DEFAULT)?=' "$GRUB_FILE" || true

# ── 1. Serial console baud — the biggest single boot-time win ────────────
# The stock cloud image ships `console=ttyS0` with NO baud rate. The kernel then
# keeps whatever rate the UART is already at, which on an uninitialised 16550 is
# 9600 -- and printk to a registered console is SYNCHRONOUS, so the kernel
# blocks on every byte it prints.
#
# Measured on this image, from the guest's own systemd accounting recovered
# from /var/log/syslog (vmbuild\logs\linux-diag\PL-PITA):
#     bake VM,     COM1 not wired    1.315s kernel +   9.252s userspace =  10.6s
#     deployed VM, COM1 -> pipe     55.080s kernel + 106.128s userspace = 161.2s
# and in 15 of 15 captured boots the kernel goes silent for 13-28s immediately
# after `printk: legacy console [ttyS0] enabled` while it flushes the ~10KB
# early backlog. One whole boot pushed 557KB to the console: ~580s at 9600 baud,
# ~48s at 115200.
#
# So: keep the serial console (it is the only view into an early-boot hang) but
# make it 12x faster, and stop sending debug-level chatter to it.
#
# ORDER MATTERS: with several console= arguments the kernel gives /dev/console
# -- and therefore all init/cloud-init output -- to the LAST one. ttyS0 must
# stay last or the serial tap goes deaf to userspace. Both entries are dropped
# and re-appended in order so the result never depends on what was there.
grub_drop_param GRUB_CMDLINE_LINUX_DEFAULT 'console=[^ ]*'
grub_set_param GRUB_CMDLINE_LINUX_DEFAULT 'console=tty1'
grub_set_param GRUB_CMDLINE_LINUX_DEFAULT 'console=ttyS0,115200n8'
# loglevel=4 = KERN_WARNING and above reaches the console. The ring buffer and
# journald still record everything, so dmesg / journalctl -k lose nothing --
# only the synchronous UART writes are cut.
grub_set_param GRUB_CMDLINE_LINUX_DEFAULT 'loglevel=4' 'loglevel=[0-9]*'
echo "console: ttyS0 pinned to 115200n8 and kept last, console loglevel 4 (dmesg/journal keep everything)"

# ── 2. fsck: repair without prompting, but do NOT force a full pass ──────
# fsck.repair=yes is what actually prevents the "Give root password for
# maintenance" prompt. fsck.mode=force additionally runs a COMPLETE fsck of the
# root filesystem on EVERY boot even when it is clean -- pure added latency and
# added I/O for VMs already losing an SSH-readiness race to host contention.
# fsck.mode=auto (the default) still checks and repairs whenever the fs is
# dirty, i.e. exactly the hard-power-off case this was added for.
grub_set_param GRUB_CMDLINE_LINUX_DEFAULT 'fsck.mode=auto' 'fsck.mode=[a-z]*'
grub_set_param GRUB_CMDLINE_LINUX_DEFAULT 'fsck.repair=yes' 'fsck.repair=[a-z]*'
echo "fsck: mode=auto repair=yes (repairs a dirty fs unattended; no forced pass on a clean one)"

# ── 3. Root filesystem journaling mode ───────────────────────────────────
# Explicitly NOT data=journal. It roughly doubles write traffic and disables
# delayed allocation, and these VMs already lose SSH-readiness races to host
# I/O contention -- it would buy crash-consistency by worsening the very
# contention that causes the failures. commit=1 in fstab plus the
# dirty-writeback sysctls below give most of the resilience for none of the
# write amplification. Dropped here rather than merely "not added" so an image
# baked from an older copy of this script gets the setting taken back off.
grub_drop_param GRUB_CMDLINE_LINUX 'rootflags=data=journal[^ ]*'

# ── 4. Make a hard hang SAY something ────────────────────────────────────
# These VMs log
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
grub_set_param GRUB_CMDLINE_LINUX 'softlockup_panic=1' 'softlockup_panic=[0-9]*'
grub_set_param GRUB_CMDLINE_LINUX 'unknown_nmi_panic=1' 'unknown_nmi_panic=[0-9]*'
grub_set_param GRUB_CMDLINE_LINUX 'panic=0' 'panic=[0-9]*'
echo "lockup detection: softlockup_panic=1 unknown_nmi_panic=1 panic=0 (no PMU here, so the NMI watchdog cannot arm itself)"

# ── 5. Trust the CPU RNG so early userspace never blocks on entropy ──────
grub_set_param GRUB_CMDLINE_LINUX 'random.trust_cpu=on' 'random.trust_cpu=[a-z]*'

# ── 6. Boot menu waits ───────────────────────────────────────────────────
# GRUB_RECORDFAIL_TIMEOUT is the important one: without it an unclean shutdown
# makes grub wait for a keypress FOREVER on the next boot, and an unattended VM
# never comes back -- precisely the failure this script exists to prevent.
grub_set_kv GRUB_TIMEOUT 1
grub_set_kv GRUB_RECORDFAIL_TIMEOUT 1
echo "grub: timeout 1s, recordfail timeout 1s (an unclean shutdown must not wait for a keypress)"

echo "=== cmdline after ==="
grep -E '^GRUB_CMDLINE_LINUX(_DEFAULT)?=|^GRUB_TIMEOUT|^GRUB_RECORDFAIL' "$GRUB_FILE" || true
update-grub

# Fail the bake rather than ship an image whose console throttles every boot. A
# silently-unapplied sed is invisible until someone measures a deployed VM
# months later -- which is exactly how the current image shipped.
if ! grep -q 'console=ttyS0,115200n8' "$GRUB_FILE"; then
    echo "ERROR: console baud was not applied to $GRUB_FILE" >&2
    exit 1
fi
if grep -q 'fsck.mode=force' "$GRUB_FILE"; then
    echo "ERROR: fsck.mode=force is still present in $GRUB_FILE" >&2
    exit 1
fi
if grep -q 'data=journal' "$GRUB_FILE"; then
    echo "ERROR: rootflags=data=journal is still present in $GRUB_FILE" >&2
    exit 1
fi

# Tell systemd to never drop to emergency/rescue on failure — just reboot.
# DefaultTimeoutStopSec 90s -> 30s: shutdown waits are pure dead time, and
# cloud-init reboots the VM once during first boot, so this is paid twice.
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/no-emergency.conf << 'EOF'
[Manager]
DefaultTimeoutStartSec=180s
DefaultTimeoutStopSec=30s
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
