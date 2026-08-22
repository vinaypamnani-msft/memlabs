#!/bin/bash
# validate-server.sh — Validate server bake artifacts.
# Checks base packages, HV services, DHCP watchdog.
set -euo pipefail
FAIL=0
ERRORS=""

for pkg in linux-tools-virtual linux-cloud-tools-virtual qemu-guest-agent openssh-server; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        ERRORS="${ERRORS}  MISSING package: $pkg\n"
        FAIL=1
    fi
done

if ! systemctl is-enabled hv-kvp-daemon.service >/dev/null 2>&1; then
    ERRORS="${ERRORS}  NOT enabled: hv-kvp-daemon.service\n"
    FAIL=1
fi

if [ ! -f /usr/local/bin/memlabs-dhcp-watchdog ]; then
    ERRORS="${ERRORS}  MISSING: /usr/local/bin/memlabs-dhcp-watchdog\n"
    FAIL=1
fi

if ! systemctl is-enabled memlabs-dhcp-watchdog.service >/dev/null 2>&1; then
    ERRORS="${ERRORS}  NOT enabled: memlabs-dhcp-watchdog.service\n"
    FAIL=1
fi

# Kernel cmdline, sshd hardening and the service trim are asserted by
# bake/validate-boot-optimizations.sh, which runs for both variants.

if [ $FAIL -ne 0 ]; then
    echo "=== VALIDATION FAILED ==="
    printf "$ERRORS"
    exit 1
fi
echo "=== Validation passed: all packages installed, services enabled ==="
