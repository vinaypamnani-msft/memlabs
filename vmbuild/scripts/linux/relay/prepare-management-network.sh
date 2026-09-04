#!/bin/bash
# prepare-management-network.sh — hand cloud-init networking to a MAC-bound
# netplan profile before a DHCPRelay VM receives any hot-added NIC.
set -euo pipefail

: "${MANAGEMENT_MAC:?MANAGEMENT_MAC is required}"
: "${MANAGEMENT_IP:?MANAGEMENT_IP is required}"
: "${MANAGEMENT_GATEWAY:?MANAGEMENT_GATEWAY is required}"
: "${DNS_SERVERS:=1.1.1.1, 8.8.8.8}"
: "${DNS_SEARCH:=}"

normalize_mac() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ':-'; }
WANT_MAC=$(normalize_mac "$MANAGEMENT_MAC")
MANAGEMENT_IF=''
for path in /sys/class/net/*/address; do
    [ -f "$path" ] || continue
    if [ "$(normalize_mac "$(cat "$path")")" = "$WANT_MAC" ]; then
        MANAGEMENT_IF=$(basename "$(dirname "$path")")
        break
    fi
done
if [ -z "$MANAGEMENT_IF" ]; then
    echo "[relay-network] ERROR: management MAC $MANAGEMENT_MAC is not present in the guest" >&2
    exit 3
fi
if ! ip -4 -o address show dev "$MANAGEMENT_IF" | awk '{print $4}' | grep -qx "$MANAGEMENT_IP/24"; then
    echo "[relay-network] ERROR: $MANAGEMENT_IF does not own expected $MANAGEMENT_IP/24" >&2
    exit 3
fi

DEFAULTS_BEFORE=$(ip -4 route show default | wc -l)
if [ "$DEFAULTS_BEFORE" -ne 1 ] || ! ip -4 route show default | grep -q " dev $MANAGEMENT_IF\( \|$\)"; then
    echo "[relay-network] ERROR: expected one default route on $MANAGEMENT_IF" >&2
    ip -4 route show >&2
    exit 3
fi

SEARCH_YAML=''
if [ -n "$DNS_SEARCH" ]; then SEARCH_YAML="        search: [$DNS_SEARCH]"; fi
CANDIDATE=$(mktemp /etc/netplan/39-memlabs-primary-candidate.XXXXXX.yaml)
trap 'rm -f "$CANDIDATE"' EXIT
cat > "$CANDIDATE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    primary:
      match:
        macaddress: $(cat "/sys/class/net/$MANAGEMENT_IF/address")
      set-name: $MANAGEMENT_IF
      optional: true
      dhcp4: false
      addresses: [$MANAGEMENT_IP/24]
      routes:
        - to: default
          via: $MANAGEMENT_GATEWAY
      nameservers:
        addresses: [$DNS_SERVERS]
$SEARCH_YAML
EOF
chmod 0600 "$CANDIDATE"

# Validate the replacement while the original broad profile still exists. Only
# after generation succeeds may cloud-init's generated ownership be removed.
netplan generate
mv "$CANDIDATE" /etc/netplan/40-memlabs-primary.yaml
trap - EXIT
mkdir -p /etc/cloud/cloud.cfg.d /var/lib/memlabs
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network:
  config: disabled
EOF
chmod 0644 /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
rm -f /etc/netplan/50-cloud-init.yaml

# Older seeds wrote a second broad match in this file. The MAC-bound primary
# profile already carries DNS; systemd-resolved's AD routing-domain drop-in is
# separate and remains intact.
if grep -Eq 'name:[[:space:]]*["'\'']?e\*["'\'']?' /etc/netplan/60-memlabs-dc-dns.yaml 2>/dev/null; then
    rm -f /etc/netplan/60-memlabs-dc-dns.yaml
fi

netplan generate
netplan apply
if ! ip -4 -o address show dev "$MANAGEMENT_IF" | awk '{print $4}' | grep -qx "$MANAGEMENT_IP/24"; then
    echo "[relay-network] ERROR: management address was lost after netplan apply" >&2
    exit 4
fi
if [ "$(ip -4 route show default | wc -l)" -ne 1 ] || ! ip -4 route show default | grep -q " dev $MANAGEMENT_IF\( \|$\)"; then
    echo "[relay-network] ERROR: default route ownership changed after netplan apply" >&2
    ip -4 route show >&2
    exit 4
fi
if grep -R -Eq 'name:[[:space:]]*["'\'']?e\*["'\'']?' /etc/netplan; then
    echo "[relay-network] ERROR: broad e* netplan matcher remains" >&2
    grep -R -n -E 'name:[[:space:]]*["'\'']?e\*["'\'']?' /etc/netplan >&2 || true
    exit 4
fi
printf '1\n' > /var/lib/memlabs/relay-network-schema
chmod 0644 /var/lib/memlabs/relay-network-schema
echo "[relay-network] management profile ready: $MANAGEMENT_IF $MANAGEMENT_IP/24 via $MANAGEMENT_GATEWAY MAC=$(cat "/sys/class/net/$MANAGEMENT_IF/address")"
