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

# AD account names in these labs are created lowercase, and the Kerberos AS-REQ
# matches the client principal case-sensitively -- an uppercased user yields
# "Client '<User>@<REALM>' not found in Kerberos database". Normalize the join
# user to lowercase so realm join / adcli always use the stored form (applies to
# the join, the stale-account delete, and the adcli-join diagnostic below).
ADMIN_USER="$(printf '%s' "$ADMIN_USER" | tr '[:upper:]' '[:lower:]')"

# Idempotency: skip if already joined to the target domain.
if command -v realm >/dev/null 2>&1 && realm list 2>/dev/null | grep -qi "$DOMAIN"; then
    echo "[memlabs-realm-join] already joined to $DOMAIN; skipping."
    exit 0
fi

wait_for_apt_lock
apt_retry apt-get update
apt_retry apt-get install -y realmd sssd sssd-ad sssd-tools adcli krb5-user packagekit \
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

# Join via Samba (net ads join) rather than the default adcli backend. adcli
# sets the machine account password over the Kerberos kpasswd protocol, which
# Windows Server 2025 rejects with "Couldn't set password for computer account
# ...: Message stream modified" -- a known W2025 interop issue. Samba's
# net ads join sets the password over SAMR/LDAP instead, which works (see MS
# Community Hub: "Problems to join Debian/Ubuntu machines to a domain").
#
# Retry up to 5 times in case the DC accepts auth but hasn't fully replicated.
# -v surfaces the underlying KDC/LDAP messages. The password is piped TWICE
# because realm's own kinit AND the net ads join it spawns each read one
# password line from stdin; an extra unread line is harmless.
JOINED=0
for i in {1..5}; do
    if printf '%s\n%s\n' "$ADMIN_PWD" "$ADMIN_PWD" | realm join -v --membership-software=samba -U "$ADMIN_USER" "$DOMAIN" --install=/; then
        JOINED=1
        break
    fi
    echo "[memlabs-realm-join] attempt $i failed, retry in 30s"
    sleep 30
done

if [ "$JOINED" != "1" ]; then
    # Fallback: if the join still fails, a stale/partial computer account can be
    # the cause. Delete any existing account for our NetBIOS name with the admin
    # creds (adcli delete-computer removes it over LDAP, not kpasswd) and retry
    # the samba join once so it is created fresh. The account name is the
    # hostname truncated to the 15-char NetBIOS limit (e.g. ps1-linuxclient2 ->
    # PS1-LINUXCLIENT); the delete is safe because the name is deterministic for
    # this VM and its DNS record already points here.
    NETBIOS="$(hostname -s | tr '[:lower:]' '[:upper:]' | cut -c1-15)"
    echo "[memlabs-realm-join] join failed; removing any stale computer account '$NETBIOS' and retrying fresh"
    echo "$ADMIN_PWD" | adcli delete-computer "$NETBIOS" --domain "$DOMAIN" --login-user "$ADMIN_USER" --stdin-password 2>&1 || true
    sleep 5
    if printf '%s\n%s\n' "$ADMIN_PWD" "$ADMIN_PWD" | realm join -v --membership-software=samba -U "$ADMIN_USER" "$DOMAIN" --install=/; then
        JOINED=1
        echo "[memlabs-realm-join] joined after removing stale computer account"
    fi
fi

if [ "$JOINED" != "1" ]; then
    # Surface the real failure realmd hides behind REALMD_OPERATION, PLUS the
    # environment context needed to root-cause a join failure from the Phase 3
    # build log alone (no shelling into the box). All best-effort (|| true).
    NETBIOS="$(hostname -s | tr '[:lower:]' '[:upper:]' | cut -c1-15)"
    echo "[memlabs-realm-join] ERROR: all join attempts failed -- capturing detailed diagnostics"
    echo "[memlabs-realm-join] context: domain=$DOMAIN dc=$DC_IP login-user=$ADMIN_USER netbios=$NETBIOS hostname=$(hostname -f 2>/dev/null)"
    echo "[memlabs-realm-join] --- clock (timedatectl) ---"
    timedatectl 2>&1 | grep -Ei 'Local time|Universal|synchronized|NTP' || true
    echo "[memlabs-realm-join] --- resolver (resolvectl) ---"
    resolvectl status 2>/dev/null | grep -Ei 'Current DNS|DNS Servers|DNS Domain' || true
    echo "[memlabs-realm-join] --- AD name resolution (getent hosts $DOMAIN) ---"
    getent hosts "$DOMAIN" 2>&1 || true
    echo "[memlabs-realm-join] --- adcli info ---"
    adcli info "$DOMAIN" 2>&1 | grep -Ei 'domain-name|domain-controller|realm|usable' || true
    echo "[memlabs-realm-join] --- realm discover ---"
    realm discover "$DOMAIN" 2>&1 | tail -25 || true
    echo "[memlabs-realm-join] --- adcli join -v (direct, login-user=$ADMIN_USER) ---"
    echo "$ADMIN_PWD" | adcli join -v --domain "$DOMAIN" --login-user "$ADMIN_USER" --stdin-password 2>&1 || true
    echo "[memlabs-realm-join] --- /etc/krb5.conf ---"
    sed -n '1,40p' /etc/krb5.conf 2>/dev/null || true
    echo "[memlabs-realm-join] --- klist -A ---"
    klist -A 2>&1 || true
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
