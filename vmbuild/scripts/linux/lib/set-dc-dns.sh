#!/bin/bash
# lib/set-dc-dns.sh -- shared helper: point the guest's resolver at the domain DC.
#
# Defines memlabs_set_dc_dns <dc-ip> <domain>. This is the SINGLE SOURCE OF TRUTH
# for the memlabs DC-DNS config, shared by:
#   * roles/realm-join.sh   (Phase 1 cloud-init seed + Phase 3 SSH dispatch)
#   * Set-LinuxVmsDcDns     (Phase 2 post-DC "flip Linux VMs onto the DC" step)
# Both pull it in via Get-LinuxScript (-IncludeSetDcDns), so the DNS logic lives
# in exactly one place instead of being duplicated in bash AND a PS here-string.
#
# It is deliberately NOT the baked /usr/local/sbin/memlabs-set-dns seed helper:
# that helper is frozen into the cloud-init seed at VM-CREATION time, so an
# existing VM keeps whatever (possibly pre-routing-domain) version it was born
# with. realm-join.sh / Set-LinuxVmsDcDns are re-pushed fresh every run, so
# writing the config from here means a re-run self-heals an already-deployed box.
#
# Writes two things:
#   1) netplan drop-in  -- DC first on the link (persists across reboot; the DC
#      forwards external names, public DNS kept as belt-and-braces fallback).
#   2) systemd-resolved routing-domain drop-in -- '~<domain>' tied to DNS=<DC> is
#      a MORE-SPECIFIC route than the link's '.' default, forcing EVERY AD query
#      (incl. the _msdcs SRV zone) to the DC only while everything else still uses
#      the link's (public) DNS. This is the authoritative fix: netplan MERGES
#      nameserver lists (public DNS can end up ahead of the DC) and the lab AD
#      domain often collides with a REAL internet domain (e.g. contoso.com) whose
#      public resolvers answer AD queries with wrong (Azure) IPs while SRV NXDOMAINs.
memlabs_set_dc_dns() {
    local dc_ip="$1" domain="$2"

    cat > /etc/netplan/60-memlabs-dc-dns.yaml <<EOF
network:
  version: 2
  ethernets:
    primary:
      nameservers:
        addresses: [$dc_ip, 1.1.1.1, 8.8.8.8]
        search: [$domain]
EOF
    chmod 600 /etc/netplan/60-memlabs-dc-dns.yaml
    netplan apply || true

    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/memlabs-dc-route.conf <<EOF
[Resolve]
DNS=$dc_ip
Domains=~$domain
EOF
    chmod 644 /etc/systemd/resolved.conf.d/memlabs-dc-route.conf
    systemctl restart systemd-resolved || true

    echo "[memlabs-set-dns] DNS: $(resolvectl dns 2>/dev/null | grep -v '^$' | head -3)"
    echo "[memlabs-set-dns] AD route: $(resolvectl domain 2>/dev/null | grep -i "$domain" || echo '(routing domain pending)')"
}
