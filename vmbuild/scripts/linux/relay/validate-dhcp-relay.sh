#!/bin/bash
# validate-dhcp-relay.sh — independently validate live relay readiness.
set -euo pipefail

: "${EXPECTED_MAPPINGS_B64:?EXPECTED_MAPPINGS_B64 is required}"
: "${MANAGEMENT_IP:?MANAGEMENT_IP is required}"
: "${MANAGEMENT_MAC:?MANAGEMENT_MAC is required}"
CONFIG_PATH=/etc/memlabs-dhcp-relay.conf
UNIT_NAME=memlabs-dhcp-relay.service
EXPECTED_FILE=$(mktemp)
trap 'rm -f "$EXPECTED_FILE"' EXIT
printf '%s' "$EXPECTED_MAPPINGS_B64" | base64 -d > "$EXPECTED_FILE"
normalize_mac() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ':-'; }

MGMT_IF=''
for path in /sys/class/net/*/address; do
    [ -f "$path" ] || continue
    if [ "$(normalize_mac "$(cat "$path")")" = "$(normalize_mac "$MANAGEMENT_MAC")" ]; then
        MGMT_IF=$(basename "$(dirname "$path")")
        break
    fi
done
[ -n "$MGMT_IF" ] || { echo "relay management MAC is absent" >&2; exit 3; }
ip -4 -o address show dev "$MGMT_IF" | awk '{print $4}' | grep -qx "$MANAGEMENT_IP/24" || { echo "management IP/MAC mismatch" >&2; exit 3; }
[ "$(ip -4 route show default | wc -l)" -eq 1 ] || { echo "default route count is not one" >&2; exit 3; }
ip -4 route show default | grep -q " dev $MGMT_IF\( \|$\)" || { echo "management MAC does not own default route" >&2; exit 3; }
[ -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ] || { echo "cloud-init network regeneration is not disabled" >&2; exit 3; }
! grep -R -Eq 'name:[[:space:]]*["'\'']?e\*["'\'']?' /etc/netplan || { echo "broad e* netplan matcher remains" >&2; exit 3; }
[ "$(sysctl -n net.ipv4.ip_forward)" = 0 ] || { echo "IP forwarding is enabled" >&2; exit 3; }
/usr/sbin/dnsmasq --test --conf-file="$CONFIG_PATH"
systemctl is-enabled --quiet "$UNIT_NAME"
systemctl is-active --quiet "$UNIT_NAME"
ss -H -lunp | grep -Eq '(^|[[:space:]])[^[:space:]]*:67[[:space:]]' || { echo "UDP/67 is not listening" >&2; exit 3; }

EXPECTED_COUNT=0
while IFS='|' read -r expected_mac expected_ip expected_target extra; do
    [ -z "${expected_mac}${expected_ip}${expected_target}${extra}" ] && continue
    [ -z "$extra" ] || { echo "malformed expected mapping" >&2; exit 2; }
    IFACE=''
    for path in /sys/class/net/*/address; do
        [ -f "$path" ] || continue
        if [ "$(normalize_mac "$(cat "$path")")" = "$(normalize_mac "$expected_mac")" ]; then
            IFACE=$(basename "$(dirname "$path")")
            break
        fi
    done
    [ -n "$IFACE" ] || { echo "expected relay MAC $expected_mac is absent" >&2; exit 3; }
    ip -4 -o address show dev "$IFACE" | awk '{print $4}' | grep -qx "$expected_ip/24" || { echo "$IFACE does not own exactly $expected_ip/24" >&2; exit 3; }
    [ "$(grep -Fxc "dhcp-relay=$expected_ip,$expected_target" "$CONFIG_PATH")" -eq 1 ] || { echo "mapping $expected_ip -> $expected_target is not present exactly once" >&2; exit 3; }
    EXPECTED_COUNT=$((EXPECTED_COUNT + 1))
done < "$EXPECTED_FILE"

[ "$(grep -c '^dhcp-relay=' "$CONFIG_PATH")" -eq "$EXPECTED_COUNT" ] || { echo "stale or duplicate relay declarations exist" >&2; exit 3; }
if journalctl -u "$UNIT_NAME" -b --no-pager 2>/dev/null | grep -Eqi 'failed to create listening socket|failed to bind|cannot bind|exiting on receipt of fatal'; then
    echo "relay journal contains a startup/bind failure in this boot" >&2
    exit 3
fi
echo "DHCP_RELAY_CONFIGURATION_READY mappings=$EXPECTED_COUNT management=$MGMT_IF/$MANAGEMENT_IP"
