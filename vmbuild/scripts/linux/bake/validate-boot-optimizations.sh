#!/bin/bash
# validate-boot-optimizations.sh — Assert the boot-time work actually landed.
#
# Runs for BOTH variants, before the variant-specific validation.
#
# Everything checked here was applied by an earlier step with a sed or a
# systemctl call. A sed that quietly matched nothing, or a mask that failed on a
# unit name that changed between releases, leaves no trace -- it is invisible
# until somebody profiles a deployed VM months later. That is exactly how the
# current image came to boot in 161s when the bake VM boots in 10s. The bake
# runs about once a year, so a silent miss here costs a year.
set -uo pipefail

FAIL=0
ERRORS=""
CHECKS=0
fail() { ERRORS="${ERRORS}  $1\n"; FAIL=1; }

GRUB_FILE=/etc/default/grub
[ -f "$GRUB_FILE" ] || { echo "=== VALIDATION FAILED ==="; echo "  $GRUB_FILE missing - nothing could be checked."; exit 1; }

# ── Kernel command line ──────────────────────────────────────────────────
# Kept as one self-contained function reading $GRUB_FILE so the offline test
# (temp/test-bake-grub-e2e.sh) can lift it verbatim and run it against what
# bake/03b-maintenance-prevention.sh actually produces. If these two ever drift
# the bake dies here, 20+ minutes in.
assert_grub_cmdline() {
    CHECKS=$((CHECKS + 1))
    if ! grep -q 'console=ttyS0,115200n8' "$GRUB_FILE"; then
        fail "serial console has no baud rate in ${GRUB_FILE} (defaults to 9600 and throttles every boot)"
    fi

    # ttyS0 must be the LAST console= entry, or /dev/console is the video
    # console and the host-side serial tap sees no userspace output at all. A
    # plain grep for the baud passes in that case, so this is not redundant.
    CHECKS=$((CHECKS + 1))
    LAST_CONSOLE="$(sed -n 's|^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$|\1|p' "$GRUB_FILE" | tail -1 | tr ' ' '\n' | grep '^console=' | tail -1)"
    if [ "$LAST_CONSOLE" != "console=ttyS0,115200n8" ]; then
        fail "last console= is '${LAST_CONSOLE}', expected console=ttyS0,115200n8 (the last one owns /dev/console)"
    fi

    CHECKS=$((CHECKS + 1))
    if grep -q 'fsck.mode=force' "$GRUB_FILE"; then
        fail "fsck.mode=force present (forces a full fsck on EVERY boot, not just a dirty one)"
    fi

    CHECKS=$((CHECKS + 1))
    if grep -q 'data=journal' "$GRUB_FILE"; then
        fail "rootflags=data=journal present (roughly doubles write traffic)"
    fi

    CHECKS=$((CHECKS + 1))
    if ! grep -q '^GRUB_RECORDFAIL_TIMEOUT=' "$GRUB_FILE"; then
        fail "GRUB_RECORDFAIL_TIMEOUT unset (after an unclean shutdown grub waits for a keypress forever)"
    fi
}
assert_grub_cmdline

# The cmdline is only real once update-grub has written grub.cfg.
CHECKS=$((CHECKS + 1))
if [ -f /boot/grub/grub.cfg ]; then
    grep -q 'console=ttyS0,115200n8' /boot/grub/grub.cfg \
        || fail "grub.cfg does not contain the new console setting (update-grub did not run after the edit)"
else
    fail "/boot/grub/grub.cfg missing - cannot confirm the cmdline was generated"
fi

# ── sshd must be unable to stay down ─────────────────────────────────────
CHECKS=$((CHECKS + 1))
[ -f /etc/systemd/system/ssh.service.d/memlabs-restart.conf ] \
    || fail "MISSING: ssh.service Restart=always drop-in"

CHECKS=$((CHECKS + 1))
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if [ ! -x "$SSHD_BIN" ]; then
    fail "sshd binary not found - the configuration was NOT validated"
elif ! "$SSHD_BIN" -t 2>/dev/null; then
    fail "sshd rejects its own configuration - no VM from this image could be reached"
fi

CHECKS=$((CHECKS + 1))
systemctl is-enabled ssh.service >/dev/null 2>&1 || fail "NOT enabled: ssh.service"

CHECKS=$((CHECKS + 1))
systemctl is-enabled memlabs-sshd-watchdog.timer >/dev/null 2>&1 \
    || fail "NOT enabled: memlabs-sshd-watchdog.timer"

CHECKS=$((CHECKS + 1))
[ -x /usr/local/sbin/memlabs-sshd-watchdog ] || fail "MISSING or not executable: /usr/local/sbin/memlabs-sshd-watchdog"

# ── Trimmed services must actually be masked ─────────────────────────────
# 'absent' is a pass: masking a unit the image never shipped is not required.
for u in motd-news.service motd-news.timer ModemManager.service wpa_supplicant.service \
         kerneloops.service apport.service avahi-daemon.service nmbd.service; do
    if systemctl list-unit-files "$u" --no-legend --no-pager 2>/dev/null | grep -q .; then
        CHECKS=$((CHECKS + 1))
        state="$(systemctl is-enabled "$u" 2>/dev/null || echo unknown)"
        [ "$state" = "masked" ] || fail "${u} is '${state}', expected masked"
    fi
done

# ── Kernel-exact Hyper-V tools match the kernel that will actually boot ──
# Not $(uname -r): step 01's dist-upgrade installs a newer kernel and nothing
# reboots the bake VM, so the running kernel is on its way out. A mismatch here
# means hv_kvp_daemon exits on every deployed VM and the host never learns the
# guest IP.
CHECKS=$((CHECKS + 1))
TARGET_KERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)"
if [ -z "$TARGET_KERNEL" ]; then
    fail "no /boot/vmlinuz-* found - cannot confirm the HV tools match the boot kernel"
else
    for pkg in "linux-tools-${TARGET_KERNEL}" "linux-cloud-tools-${TARGET_KERNEL}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || fail "MISSING ${pkg} (deployed VMs boot ${TARGET_KERNEL}; running kernel here is $(uname -r))"
    done
fi

# A gate that ran zero checks must not report a pass.
if [ "$CHECKS" -eq 0 ]; then
    echo "=== VALIDATION FAILED ==="
    echo "  NOTHING WAS CHECKED."
    exit 1
fi

if [ $FAIL -ne 0 ]; then
    echo "=== BOOT OPTIMIZATION VALIDATION FAILED (${CHECKS} checks run) ==="
    printf "$ERRORS"
    echo "Current kernel cmdline settings:"
    grep -E '^GRUB_CMDLINE_LINUX(_DEFAULT)?=|^GRUB_TIMEOUT|^GRUB_RECORDFAIL' "$GRUB_FILE" | sed 's/^/  /'
    exit 1
fi
echo "=== Boot optimizations verified (${CHECKS} checks, kernel ${TARGET_KERNEL}) ==="
