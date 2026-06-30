#!/bin/bash
# 04-dhcp-watchdog.sh — Install DHCP watchdog service.
# systemd-networkd's default DHCP retry is not aggressive enough under
# heavy host load (25+ VMs booting). This oneshot service runs after
# networkd, checks for an IPv4 address, and restarts networkd with
# retries until DHCP succeeds.
set -euo pipefail

cat > /usr/local/bin/memlabs-dhcp-watchdog << 'WATCHDOG'
#!/bin/bash
# memlabs-dhcp-watchdog: retry systemd-networkd DHCP if no IPv4 address.
MAX_RETRIES=10
RETRY_INTERVAL=15
INITIAL_WAIT=30

# Wait for networkd to have a chance to acquire a lease on its own.
sleep $INITIAL_WAIT

for i in $(seq 1 $MAX_RETRIES); do
    if ip -4 addr show scope global | grep -q 'inet '; then
        logger -t memlabs-dhcp-watchdog "IPv4 address found on attempt $i"
        exit 0
    fi
    logger -t memlabs-dhcp-watchdog "No IPv4 address (attempt $i/$MAX_RETRIES), restarting systemd-networkd"
    systemctl restart systemd-networkd
    sleep $RETRY_INTERVAL
done
logger -t memlabs-dhcp-watchdog "FAILED: no IPv4 address after $MAX_RETRIES retries"
exit 1
WATCHDOG
chmod 0755 /usr/local/bin/memlabs-dhcp-watchdog

cat > /etc/systemd/system/memlabs-dhcp-watchdog.service << 'SVCUNIT'
[Unit]
Description=MemLabs DHCP Watchdog (retry networkd DHCP)
After=systemd-networkd.service cloud-init-local.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/memlabs-dhcp-watchdog
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SVCUNIT

systemctl daemon-reload
systemctl enable memlabs-dhcp-watchdog.service
echo "=== DHCP watchdog service installed ==="
