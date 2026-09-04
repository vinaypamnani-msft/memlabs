#!/bin/bash
# configure-client-interface.sh — apply one MAC-bound relay-facing /24.
set -euo pipefail

: "${CLIENT_MAC:?CLIENT_MAC is required}"
: "${CLIENT_IP:?CLIENT_IP is required}"
: "${CLIENT_NETWORK:?CLIENT_NETWORK is required}"

normalize_mac() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ':-'; }
WANT_MAC=$(normalize_mac "$CLIENT_MAC")
CLIENT_IF=''
for path in /sys/class/net/*/address; do
    [ -f "$path" ] || continue
    if [ "$(normalize_mac "$(cat "$path")")" = "$WANT_MAC" ]; then
        CLIENT_IF=$(basename "$(dirname "$path")")
        break
    fi
done
if [ -z "$CLIENT_IF" ]; then
    echo "[relay-interface] ERROR: client MAC $CLIENT_MAC is not present in the guest" >&2
    exit 3
fi

SAFE_NETWORK=$(printf '%s' "$CLIENT_NETWORK" | tr '.' '-')
TARGET="/etc/netplan/70-memlabs-relay-$SAFE_NETWORK.yaml"
CANDIDATE=$(mktemp "/etc/netplan/69-memlabs-relay-$SAFE_NETWORK-candidate.XXXXXX.yaml")
trap 'rm -f "$CANDIDATE"' EXIT
cat > "$CANDIDATE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    relay-$SAFE_NETWORK:
      match:
        macaddress: $(cat "/sys/class/net/$CLIENT_IF/address")
      set-name: $CLIENT_IF
      dhcp4: false
      optional: true
      addresses: [$CLIENT_IP/24]
EOF
chmod 0600 "$CANDIDATE"
netplan generate

CHANGED=1
if [ -f "$TARGET" ] && cmp -s "$CANDIDATE" "$TARGET"; then CHANGED=0; fi
if [ "$CHANGED" -eq 1 ]; then mv "$CANDIDATE" "$TARGET"; else rm -f "$CANDIDATE"; fi
trap - EXIT
netplan generate
if [ "$CHANGED" -eq 1 ]; then netplan apply; fi

if ! ip -4 -o address show dev "$CLIENT_IF" | awk '{print $4}' | grep -qx "$CLIENT_IP/24"; then
    echo "[relay-interface] ERROR: $CLIENT_IF does not own exactly $CLIENT_IP/24" >&2
    exit 4
fi
if ip -4 route show default | grep -q " dev $CLIENT_IF\( \|$\)"; then
    echo "[relay-interface] ERROR: relay-facing interface $CLIENT_IF owns a default route" >&2
    exit 4
fi
if [ "$(ip -4 route show default | wc -l)" -ne 1 ]; then
    echo "[relay-interface] ERROR: expected exactly one default route after apply" >&2
    ip -4 route show >&2
    exit 4
fi
echo "RELAY_INTERFACE_READY=$CLIENT_IF|$CLIENT_IP|$(cat "/sys/class/net/$CLIENT_IF/address")|changed=$CHANGED"
