#!/bin/bash
# cleanup.sh — Final cleanup + shutdown for bake.
# Removes bake user, disables unattended-upgrades, cleans cloud-init,
# shuts down so the VHDX is pristine.
set -euo pipefail
# Delete bake user so the VHDX ships with no stale credentials
userdel -r memlabs 2>/dev/null || true
# Disable unattended upgrades (avoids dpkg lock races on deployed VMs).
# stop+disable is not enough: apt-daily.timer re-triggers the service.
# Mask the service and disable the timers to prevent all auto-apt activity.
systemctl stop unattended-upgrades.service 2>/dev/null || true
systemctl disable unattended-upgrades.service 2>/dev/null || true
systemctl mask unattended-upgrades.service 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
# Mask the timers too (disable alone still lets a dependency pull them in).
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
# Clean cloud-init state so next boot re-runs with the deploy seed
cloud-init clean --logs --seed --machine-id || true
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/netplan/50-cloud-init.yaml
echo "=== Cleanup complete, shutting down ==="
shutdown -h now
