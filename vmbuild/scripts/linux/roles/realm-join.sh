#!/bin/bash
# realm-join.sh — Install realmd/sssd and join the lab AD domain.
#
# Required variables (set by caller before sourcing):
#   DOMAIN     — AD domain FQDN (lowercase), e.g. adatum.com
#   DC_IP      — IP address of the domain controller
#   ADMIN_USER — AD admin username for realm join
#   ADMIN_PWD  — AD admin password (single-quote-safe)
#
# Used by both cloud-init seed (Phase 1) and Phase 3 role config.
set -euo pipefail
echo "[memlabs-realm-join] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

# Idempotency: skip if already joined to the target domain.
if command -v realm >/dev/null 2>&1 && realm list 2>/dev/null | grep -qi "$DOMAIN"; then
    echo "[memlabs-realm-join] already joined to $DOMAIN; skipping."
    exit 0
fi

wait_for_apt_lock
apt_retry apt-get update
apt_retry apt-get install -y realmd sssd sssd-tools adcli krb5-user packagekit \
    samba-common-bin oddjob oddjob-mkhomedir libnss-sss libpam-sss

# Point resolver at the DC so realm discover can find AD SRV records.
#
# This is written INLINE (not via the baked /usr/local/sbin/memlabs-set-dns
# helper) on purpose: that helper is laid down by the cloud-init seed at VM
# CREATION time, so an existing VM keeps whatever version it was born with.
# realm-join.sh, by contrast, is re-pushed fresh on every Phase 3 run, so
# doing the DNS config here means a '-StartPhase 3' re-run self-heals an
# already-deployed box (older helper) instead of re-running the old broken
# resolver setup. The routing domain below is the authoritative fix.
configure_dc_dns() {
    # 1) netplan drop-in: DC first on the link (persists across reboot; the DC
    #    forwards external names, public DNS kept as belt-and-braces fallback).
    cat > /etc/netplan/60-memlabs-dc-dns.yaml <<EOF
network:
  version: 2
  ethernets:
    primary:
      match:
        name: "e*"
      nameservers:
        addresses: [$DC_IP, 1.1.1.1, 8.8.8.8]
        search: [$DOMAIN]
EOF
    chmod 600 /etc/netplan/60-memlabs-dc-dns.yaml
    netplan apply || true

    # 2) systemd-resolved routing domain: '~<domain>' tied to DNS=<DC> is a
    #    MORE-SPECIFIC route than the link's '.' default, forcing EVERY AD
    #    query (incl. the _msdcs SRV zone) to the DC only, while everything
    #    else still uses the link's (public) DNS. This is the authoritative
    #    fix: netplan MERGES nameserver lists (public DNS can end up ahead of
    #    the DC) and the lab AD domain often collides with a REAL internet
    #    domain (e.g. contoso.com) whose public resolvers answer AD queries
    #    with wrong (Azure) IPs while the SRV lookups NXDOMAIN.
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/memlabs-dc-route.conf <<EOF
[Resolve]
DNS=$DC_IP
Domains=~$DOMAIN
EOF
    chmod 644 /etc/systemd/resolved.conf.d/memlabs-dc-route.conf
    systemctl restart systemd-resolved || true

    echo "[memlabs-realm-join] DNS: $(resolvectl dns 2>/dev/null | grep -v '^$' | head -3)"
    echo "[memlabs-realm-join] AD route: $(resolvectl domain 2>/dev/null | grep -i "$DOMAIN" || echo '(routing domain pending)')"
}
configure_dc_dns || true

# Wait up to 20 minutes for the DC's A record to resolve (DC DSC may
# still be coming up when cloud-init runs).
for i in {1..80}; do
    if getent hosts "$DOMAIN" >/dev/null 2>&1; then break; fi
    echo "[memlabs-realm-join] waiting for DNS on $DOMAIN (attempt $i/80)"
    sleep 15
done

realm discover "$DOMAIN" || true

# Retry the join up to 5 times in case the DC accepts auth but hasn't
# fully replicated.
JOINED=0
for i in {1..5}; do
    if echo "$ADMIN_PWD" | realm join -U "$ADMIN_USER" "$DOMAIN" --install=/; then
        JOINED=1
        break
    fi
    echo "[memlabs-realm-join] attempt $i failed, retry in 30s"
    sleep 30
done

if [ "$JOINED" != "1" ]; then
    echo "[memlabs-realm-join] ERROR: all join attempts failed"
    exit 1
fi

# Allow login as plain "user" (not "user@domain") and auto-create home dirs.
realm permit --realm "$DOMAIN" --all || true
sed -i 's/^use_fully_qualified_names = .*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf || true
sed -i 's|^fallback_homedir = .*|fallback_homedir = /home/%u|' /etc/sssd/sssd.conf || true
pam-auth-update --enable mkhomedir || true
systemctl restart sssd || true

# Domain Admins -> sudo NOPASSWD.
echo '%domain\ admins ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/memlabs-domain-admins
chmod 0440 /etc/sudoers.d/memlabs-domain-admins

echo "[memlabs-realm-join] done: $(date -Is)"
