#!/bin/bash
# boot-profile.sh — Collect authoritative boot-time evidence from a running
# Linux lab VM.
#
# Answers "why did this VM take so long to boot" with numbers instead of
# inference: systemd's own per-unit accounting, cloud-init's per-module
# accounting, the kernel command line actually in force, and the enabled-unit
# inventory that determines what future boots will pay for.
#
# Every section prints its own header AND an explicit marker when it could not
# be collected, so a missing section is never silently read as "nothing to
# report". Sections are independent: one unavailable tool must not abort the
# rest, so this deliberately does NOT `set -e`.
#
# Output is plain text on stdout, consumed by tools/Get-LinuxBootProfile.ps1.

section() { printf '\n===== %s =====\n' "$1"; }
# Run a command, or say plainly that the measurement did not happen.
try() {
    local what="$1"; shift
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "NOT COLLECTED: '$1' is not installed - $what was not measured."
        return
    fi
    if ! "$@" 2>&1; then
        echo "NOT COLLECTED: '$*' failed (rc=$?) - $what was not measured."
    fi
}

section "IDENTITY"
echo "hostname:   $(hostname -f 2>/dev/null || hostname)"
echo "collected:  $(date -Is)"
echo "uptime:     $(uptime -p 2>/dev/null)"
echo "kernel:     $(uname -r)"
echo "boot id:    $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
echo "os:         $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"

section "KERNEL COMMAND LINE"
# The console= entry here decides whether printk blocks the whole boot: a
# console with no baud (console=ttyS0) keeps the UART's existing rate, which on
# an uninitialised 16550 is 9600 - and printk to a registered console is
# synchronous, so the kernel waits on every byte.
cat /proc/cmdline
echo
if grep -qE 'console=ttyS[0-9]+(\s|$)' /proc/cmdline; then
    echo "WARNING: serial console has NO baud rate -> defaults to 9600; every printk blocks the boot."
elif grep -qE 'console=ttyS[0-9]+,[0-9]+' /proc/cmdline; then
    echo "OK: serial console baud is set explicitly."
else
    echo "INFO: no serial console on the kernel command line."
fi
if grep -q 'fsck.mode=force' /proc/cmdline; then
    echo "WARNING: fsck.mode=force -> a FULL fsck runs on EVERY boot, not just when the fs is dirty."
fi
if grep -q 'data=journal' /proc/cmdline; then
    echo "WARNING: rootflags=data=journal -> full data journaling, roughly 2x write traffic."
fi

section "SYSTEMD BOOT TOTALS"
try "boot totals" systemd-analyze time

section "SYSTEMD BLAME (slowest 40 units)"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze blame --no-pager 2>&1 | head -40
else
    echo "NOT COLLECTED: systemd-analyze missing."
fi

section "SYSTEMD CRITICAL CHAIN"
try "critical chain" systemd-analyze critical-chain --no-pager

section "SYSTEMD CRITICAL CHAIN (ssh + cloud-init)"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze critical-chain --no-pager ssh.service cloud-init.target 2>&1
else
    echo "NOT COLLECTED: systemd-analyze missing."
fi

section "FAILED UNITS"
# A failed unit that others order after is worth far more boot time than its
# own runtime, so this must be read alongside the blame list.
failed_count=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | wc -l)
echo "failed unit count: ${failed_count}"
systemctl list-units --state=failed --no-pager --no-legend 2>&1

section "ENABLED SERVICES (what every future boot pays for)"
enabled_count=$(systemctl list-unit-files --state=enabled --type=service --no-legend --no-pager 2>/dev/null | wc -l)
echo "enabled service count: ${enabled_count}"
systemctl list-unit-files --state=enabled --type=service --no-pager --no-legend 2>&1 | sort

section "ENABLED TIMERS AND SOCKETS"
systemctl list-unit-files --state=enabled --type=timer,socket --no-pager --no-legend 2>&1 | sort

section "MASKED UNITS (already suppressed)"
systemctl list-unit-files --state=masked --no-pager --no-legend 2>&1 | sort

section "BOOT-COST CANDIDATES PRESENT ON THIS IMAGE"
# Named explicitly so the report says which of these actually exist here rather
# than leaving the reader to guess from the blame list.
for u in snapd.service snapd.seeded.service snapd.socket snapd.apparmor.service \
         lxd-installer.socket ModemManager.service wpa_supplicant.service \
         avahi-daemon.service avahi-daemon.socket kerneloops.service apport.service \
         motd-news.service motd-news.timer udisks2.service packagekit.service \
         secureboot-db.service e2scrub_reap.service nmbd.service \
         unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
         NetworkManager-wait-online.service systemd-networkd-wait-online.service \
         cloud-init.service ssh.service; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || echo "absent")
    active=$(systemctl is-active "$u" 2>/dev/null || echo "-")
    printf '  %-42s enabled=%-12s active=%s\n' "$u" "$state" "$active"
done

section "CLOUD-INIT STATUS"
try "cloud-init status" cloud-init status --long

section "CLOUD-INIT BLAME (slowest modules)"
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init analyze blame 2>&1 | head -30
else
    echo "NOT COLLECTED: cloud-init missing."
fi

section "CLOUD-INIT BOOT RECORD"
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init analyze boot 2>&1
else
    echo "NOT COLLECTED: cloud-init missing."
fi

section "SSHD HEALTH"
echo "-- is ssh.service enabled/active --"
echo "enabled: $(systemctl is-enabled ssh.service 2>&1)"
echo "active:  $(systemctl is-active ssh.service 2>&1)"
echo "-- ssh.socket (socket activation delays the listener until first connect) --"
echo "enabled: $(systemctl is-enabled ssh.socket 2>&1)"
echo "active:  $(systemctl is-active ssh.socket 2>&1)"
echo "-- listeners on 22 --"
ss -tlnp 2>/dev/null | grep -E ':22\b' || echo "NOTHING LISTENING ON TCP/22"
echo "-- host keys present in the image --"
ls -l /etc/ssh/ssh_host_*_key 2>/dev/null || echo "NO HOST KEYS (sshd will generate them at first boot - slow and failure-prone)"
echo "-- sshd config sanity --"
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if [ -x "$SSHD_BIN" ]; then "$SSHD_BIN" -t 2>&1 && echo "sshd config parses"; else echo "NOT COLLECTED: sshd binary not found."; fi
echo "-- recent sshd journal --"
journalctl -u ssh.service -u ssh.socket --no-pager -n 40 2>&1 | tail -40

section "SLOWEST GAPS IN THIS BOOT'S KERNEL LOG"
# Consecutive dmesg timestamps more than 1s apart: names what the kernel sat on.
if command -v dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null | awk '
        match($0, /^\[[ ]*[0-9]+\.[0-9]+\]/) {
            t = substr($0, RSTART+1, RLENGTH-2) + 0
            if (prev != "" && t - prev >= 1.0)
                printf "%8.2fs gap after %6.2fs : %s\n", t - prev, prev, substr(prevline, RLENGTH+2)
            prev = t; prevline = $0
        }' | sort -rn | head -20
    echo "(empty above = no kernel gap >= 1s)"
else
    echo "NOT COLLECTED: dmesg missing."
fi

section "DISK AND MEMORY"
df -h / 2>&1
free -m 2>&1

printf '\n===== END OF BOOT PROFILE =====\n'
