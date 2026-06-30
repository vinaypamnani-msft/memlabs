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
echo "=== Maintenance-mode prevention configured ==="
