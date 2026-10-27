#!/bin/bash
# validate-desktop.sh — Validate all desktop bake artifacts.
# Checks packages, services, extension, dconf, PAM, default browser.
set -euo pipefail
FAIL=0
ERRORS=""

for pkg in linux-tools-virtual linux-cloud-tools-virtual qemu-guest-agent openssh-server \
           ubuntu-desktop-minimal gdm3 network-manager xrdp xorgxrdp \
           gnome-tweaks dconf-cli \
           microsoft-edge-stable intune-portal; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        ERRORS="${ERRORS}  MISSING package: $pkg\n"
        FAIL=1
    fi
done

for svc in hv-kvp-daemon gdm3 NetworkManager xrdp memlabs-dhcp-watchdog; do
    if ! systemctl is-enabled "${svc}.service" >/dev/null 2>&1; then
        ERRORS="${ERRORS}  NOT enabled: ${svc}.service\n"
        FAIL=1
    fi
done

if [ ! -d "/usr/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com" ]; then
    ERRORS="${ERRORS}  MISSING: dash-to-panel extension directory\n"
    FAIL=1
fi

if [ ! -f /usr/local/bin/memlabs-dhcp-watchdog ]; then
    ERRORS="${ERRORS}  MISSING: /usr/local/bin/memlabs-dhcp-watchdog\n"
    FAIL=1
fi

if [ ! -f "/etc/dconf/db/local" ]; then
    ERRORS="${ERRORS}  MISSING: compiled dconf database /etc/dconf/db/local\n"
    FAIL=1
fi

if [ -f /etc/pam.d/xrdp-sesman ] && ! grep -q 'pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman; then
    ERRORS="${ERRORS}  MISSING: pam_gnome_keyring.so in xrdp-sesman PAM config\n"
    FAIL=1
fi

if ! update-alternatives --query x-www-browser 2>/dev/null | grep -q 'microsoft-edge'; then
    ERRORS="${ERRORS}  NOT default: Edge not set as x-www-browser\n"
    FAIL=1
fi

if [ ! -f "/etc/polkit-1/rules.d/45-allow-colord.rules" ]; then
    ERRORS="${ERRORS}  MISSING: polkit colord rule\n"
    FAIL=1
fi

if [ $FAIL -ne 0 ]; then
    echo "=== VALIDATION FAILED ==="
    printf "$ERRORS"
    exit 1
fi
echo "=== Validation passed: all packages, services, and configs verified ==="
