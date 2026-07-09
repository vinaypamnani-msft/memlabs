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
# memlabs_set_dc_dns is provided by lib/set-dc-dns.sh (Get-LinuxScript
# -IncludeSetDcDns) -- the single source of truth for the DC-DNS config, shared
# with the Phase 2 Set-LinuxVmsDcDns flip. Doing it here (not via the baked
# /usr/local/sbin/memlabs-set-dns helper) means a '-StartPhase 3' re-run
# self-heals an already-deployed box regardless of its baked helper version.
memlabs_set_dc_dns "$DC_IP" "$DOMAIN" || true

# Wait up to 20 minutes for the DC's A record to resolve (DC DSC may
# still be coming up when cloud-init runs).
for i in {1..80}; do
    if getent hosts "$DOMAIN" >/dev/null 2>&1; then break; fi
    echo "[memlabs-realm-join] waiting for DNS on $DOMAIN (attempt $i/80)"
    sleep 15
done

realm discover "$DOMAIN" || true

# Retry the join up to 5 times in case the DC accepts auth but hasn't
# fully replicated. Run with -v so adcli's underlying KDC/LDAP messages (the
# ACTUAL reason) reach stdout/stderr -- realmd otherwise collapses every
# failure to an opaque "Failed to join the domain" plus a journalctl
# REALMD_OPERATION pointer the host can't see.
JOINED=0
for i in {1..5}; do
    if echo "$ADMIN_PWD" | realm join -v -U "$ADMIN_USER" "$DOMAIN" --install=/; then
        JOINED=1
        break
    fi
    echo "[memlabs-realm-join] attempt $i failed, retry in 30s"
    sleep 30
done

if [ "$JOINED" != "1" ]; then
    # Surface the real failure that realmd hid behind REALMD_OPERATION. Run
    # adcli directly (-v, --stdin-password) for the explicit message -- e.g.
    # "Invalid credentials", "Insufficient permissions to modify computer
    # account", "Couldn't set computer password", "already exists" -- and tail
    # the realmd journal. These land in the Phase 3 build log so the actual
    # cause is diagnosable without shelling into the box.
    echo "[memlabs-realm-join] ERROR: all join attempts failed -- capturing detailed diagnostics"
    echo "[memlabs-realm-join] --- adcli join -v (direct) ---"
    echo "$ADMIN_PWD" | adcli join -v --domain "$DOMAIN" --login-user "$ADMIN_USER" --stdin-password 2>&1 || true
    echo "[memlabs-realm-join] --- realmd journal (last 80) ---"
    journalctl -b _COMM=realmd --no-pager 2>/dev/null | tail -80 || true
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
