#!/bin/bash
# update-reservation.sh — atomically add/remove one reservation and reload dnsmasq.
set -euo pipefail

: "${RESERVATION_ACTION:?RESERVATION_ACTION is required}"
: "${RESERVATION_MAC:=}"
: "${RESERVATION_IP:=}"

CONFIG_PATH=/etc/memlabs-dhcp.conf
HOSTS_PATH=/etc/memlabs-dhcp-hosts.conf
LEASE_PATH=/var/lib/memlabs-dhcp/dnsmasq.leases
UNIT_NAME=memlabs-dhcp.service

[ -f "$CONFIG_PATH" ] || { echo "[dhcp-reservation] ERROR: $CONFIG_PATH is absent" >&2; exit 3; }
touch "$HOSTS_PATH"
CANDIDATE=$(mktemp /etc/memlabs-dhcp-hosts.XXXXXX)
trap 'rm -f "$CANDIDATE"' EXIT

python3 - "$HOSTS_PATH" "$CANDIDATE" "$RESERVATION_ACTION" "$RESERVATION_MAC" "$RESERVATION_IP" <<'PY'
import ipaddress
import pathlib
import re
import sys

source, target = map(pathlib.Path, sys.argv[1:3])
action, mac, ip = sys.argv[3:6]
mac = mac.lower().replace("-", ":")
if action not in {"add", "remove"}:
    raise SystemExit(f"[dhcp-reservation] ERROR: invalid action {action}")
if mac and not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", mac):
    raise SystemExit(f"[dhcp-reservation] ERROR: invalid MAC {mac}")
if ip:
    ip = str(ipaddress.ip_address(ip))
if action == "add" and (not mac or not ip):
    raise SystemExit("[dhcp-reservation] ERROR: add requires MAC and IP")

rows = []
for raw in source.read_text(encoding="utf-8").splitlines():
    row = raw.strip()
    if not row:
        continue
    parts = row.split(",")
    row_mac = parts[0].lower().replace("-", ":") if parts else ""
    row_ip = parts[1] if len(parts) > 1 else ""
    if (mac and row_mac == mac) or (ip and row_ip == ip):
        continue
    rows.append(row)
if action == "add":
    rows.append(f"{mac},{ip},infinite")
target.write_text("\n".join(sorted(set(rows))) + ("\n" if rows else ""), encoding="utf-8")
PY

chmod 0644 "$CANDIDATE"
/usr/sbin/dnsmasq --test --conf-file="$CONFIG_PATH"
BACKUP=$(mktemp /etc/memlabs-dhcp-hosts-backup.XXXXXX)
cp -a "$HOSTS_PATH" "$BACKUP"
LEASE_BACKUP=''
if [ -f "$LEASE_PATH" ]; then
    LEASE_BACKUP=$(mktemp /var/lib/memlabs-dhcp/dnsmasq-leases-backup.XXXXXX)
    cp -a "$LEASE_PATH" "$LEASE_BACKUP"
fi
ROLLBACK_ARMED=1
finish_update() {
    rc=$?
    trap - EXIT
    if [ "$ROLLBACK_ARMED" -eq 1 ]; then
        cp -a "$BACKUP" "$HOSTS_PATH"
        if [ -n "$LEASE_BACKUP" ]; then cp -a "$LEASE_BACKUP" "$LEASE_PATH"; fi
        systemctl restart "$UNIT_NAME" >/dev/null 2>&1 || true
        echo "[dhcp-reservation] ERROR: update failed; previous reservations restored" >&2
    fi
    rm -f "$BACKUP" "$LEASE_BACKUP" "$CANDIDATE"
    exit "$rc"
}
trap finish_update EXIT
mv "$CANDIDATE" "$HOSTS_PATH"
if [ "$RESERVATION_ACTION" = add ] && [ -s "$LEASE_PATH" ]; then
    systemctl stop "$UNIT_NAME"
    python3 - "$LEASE_PATH" "$RESERVATION_MAC" "$RESERVATION_IP" <<'PY'
import pathlib
import sys

lease_path = pathlib.Path(sys.argv[1])
reserved_mac = sys.argv[2].lower().replace("-", ":")
reserved_ip = sys.argv[3]
kept = []
for raw in lease_path.read_text(encoding="utf-8").splitlines():
    parts = raw.split()
    if len(parts) >= 3 and (parts[1].lower() == reserved_mac or parts[2] == reserved_ip):
        continue
    kept.append(raw)
lease_path.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")
PY
    systemctl start "$UNIT_NAME"
else
    systemctl reload "$UNIT_NAME"
fi
systemctl is-active --quiet "$UNIT_NAME"
if [ "$RESERVATION_ACTION" = add ]; then
    grep -Fqx "${RESERVATION_MAC,,},$RESERVATION_IP,infinite" "$HOSTS_PATH" || {
        echo "[dhcp-reservation] ERROR: reservation read-back failed" >&2
        exit 4
    }
fi
ROLLBACK_ARMED=0
trap - EXIT
rm -f "$BACKUP" "$LEASE_BACKUP"
echo "DHCP_RESERVATION_${RESERVATION_ACTION^^}ED mac=$RESERVATION_MAC ip=$RESERVATION_IP"
