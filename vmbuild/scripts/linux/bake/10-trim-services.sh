#!/bin/bash
# 03c-trim-services.sh — Remove boot-time work these lab VMs never use.
#
# Every unit here was OBSERVED starting on a real memlabs boot (guest syslog in
# vmbuild\logs\linux-diag\PL-PITA and the serial captures in
# vmbuild\logs\linux-serial), with the per-unit cost systemd itself recorded:
#
#     motd-news         10.79s   HTTP fetch from motd.ubuntu.com at boot
#     snapd.seeded       4.32s
#     kerneloops         4.11s   crash-report uploader
#     nmbd               3.96s   NetBIOS name service (smbd is the one we use)
#     udisks2            2.81s   removable-media daemon
#     apport             2.67s   crash-report collector
#     ModemManager       1.88s   probes serial ports for modems
#     wpa_supplicant     1.92s   there is no wireless NIC in a Hyper-V VM
#     avahi-daemon       1.54s   mDNS
#     secureboot-db      1.17s   secure boot is disabled on these VMs
#
# None of it is used by a ConfigMgr lab guest, and several of them reach the
# network before the lab's DNS exists.
#
# Expects MEMLABS_BAKE_VARIANT: 'Server' or 'Desktop'.
#
# Deliberately NOT touched, and why -- so nobody "finishes the job" later:
#   packagekit             realmd shells out to it during domain join.
#   *-wait-online          cloud-init orders after network-online.target;
#                          disabling it lets cloud-init run before DHCP lands.
#                          The timeout is bounded below instead.
#   systemd-resolved       the whole DNS design depends on it.
#   unattended-upgrades / apt-daily*   already masked by bake/cleanup.sh.
set -uo pipefail

VARIANT="${MEMLABS_BAKE_VARIANT:-Server}"
echo "=== Trimming boot services (variant=${VARIANT}) ==="

# mask, not just disable: `disable` only drops the WantedBy symlink, so any
# other unit's Wants=/dbus activation can still pull the service back in.
mask_unit() {
    for u in "$@"; do
        if ! systemctl list-unit-files "$u" --no-legend --no-pager 2>/dev/null | grep -q .; then
            printf '  %-42s absent\n' "$u"
            continue
        fi
        systemctl stop "$u" >/dev/null 2>&1 || true
        if systemctl mask "$u" >/dev/null 2>&1; then
            printf '  %-42s MASKED\n' "$u"
        else
            printf '  %-42s mask FAILED\n' "$u"
        fi
    done
}

echo "-- no hardware behind these in a Hyper-V guest --"
mask_unit ModemManager.service wpa_supplicant.service secureboot-db.service

echo "-- crash reporting (uploads to Canonical; nothing here reads it) --"
mask_unit kerneloops.service apport.service apport-autoreport.service \
          apport-autoreport.timer apport-autoreport.path

echo "-- motd-news fetches http://motd.ubuntu.com at boot AND at every login --"
mask_unit motd-news.service motd-news.timer
# The timer is only half of it: /etc/update-motd.d/50-motd-news also runs from
# PAM on every ssh login, which is exactly the path memlabs uses constantly.
if [ -f /etc/default/motd-news ]; then
    sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
    grep -q '^ENABLED=' /etc/default/motd-news || echo 'ENABLED=0' >> /etc/default/motd-news
    echo "  /etc/default/motd-news ENABLED=0"
fi
chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null && echo "  50-motd-news made non-executable" || true

echo "-- mDNS / removable media / ext4 online-scrub: unused in a lab guest --"
mask_unit avahi-daemon.service avahi-daemon.socket udisks2.service \
          e2scrub_reap.service e2scrub_all.timer

echo "-- NetBIOS name service; memlabs uses smbd only (smbd stays enabled) --"
mask_unit nmbd.service

echo "-- snapd --"
if [ "$VARIANT" = "Server" ]; then
    # Server installs nothing from snap, so remove the package outright: masking
    # leaves the /snap mount units and the seeding work behind.
    if dpkg -s snapd >/dev/null 2>&1; then
        systemctl stop snapd.socket snapd.service >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd >/dev/null 2>&1 \
            && echo "  snapd PURGED (server has no snaps)" \
            || echo "  snapd purge FAILED - falling back to masking"
        rm -rf /var/cache/snapd /root/snap 2>/dev/null || true
    else
        echo "  snapd absent"
    fi
    mask_unit snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service \
              snapd.autoimport.service lxd-installer.socket
else
    # Desktop keeps the package: ubuntu-desktop-minimal depends on it and
    # purging would drag the metapackage out. Firefox comes from Mozilla's deb
    # repo (roles/firefox.sh), not the snap, so nothing here needs snapd at
    # boot -- only the boot-time units go.
    mask_unit snapd.seeded.service snapd.autoimport.service \
              snapd.core-fixup.service lxd-installer.socket
    echo "  snapd package kept (ubuntu-desktop-minimal depends on it)"
fi

# Bound the network-online wait instead of removing it. cloud-init orders after
# network-online.target, so the wait must stay -- but the stock 120s ceiling is
# 120s of dead boot whenever DHCP is slow, which on a contended host is often.
echo "-- bound the network-online wait (kept, not removed) --"
for wait_unit in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
    if systemctl list-unit-files "$wait_unit" --no-legend --no-pager 2>/dev/null | grep -q .; then
        mkdir -p "/etc/systemd/system/${wait_unit}.d"
        cat > "/etc/systemd/system/${wait_unit}.d/memlabs-timeout.conf" << 'EOF'
[Service]
# Any interface being up is enough; do not wait for every one to be configured.
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=20
EOF
        # NetworkManager's binary differs; only the timeout override applies there.
        if [ "$wait_unit" = "NetworkManager-wait-online.service" ]; then
            cat > "/etc/systemd/system/${wait_unit}.d/memlabs-timeout.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/nm-online -s -q --timeout=20
EOF
        fi
        printf '  %-42s timeout bounded to 20s\n' "$wait_unit"
    fi
done

systemctl daemon-reload

# ── Essential services must still be enabled ─────────────────────────────
# A trim that silently disables sshd bricks the lab: there is no other way in.
# At this point, however, current Ubuntu images may legitimately have
# ssh.service disabled while ssh.socket owns the live TCP/22 listener. Step 11
# immediately converts that transitional state to the always-enabled service
# and masks the socket. Requiring ssh.service to be enabled here rejects a
# reachable image before the step designed to normalize it can run. Prove the
# listener is live here; Step 11 and validate-boot-optimizations prove the
# persistent ssh.service end state.
#
# Only units that exist at THIS point in the bake are asserted. This step runs
# after the Desktop block, so gdm3/NetworkManager/xrdp are present on Desktop --
# but memlabs-dhcp-watchdog is created by step 04 which also already ran.
echo "=== Verifying essentials survived the trim ==="
ssh_service_state="$(systemctl is-enabled ssh.service 2>/dev/null || true)"
ssh_socket_state="$(systemctl is-enabled ssh.socket 2>/dev/null || true)"
[ -n "$ssh_service_state" ] || ssh_service_state="not-found"
[ -n "$ssh_socket_state" ] || ssh_socket_state="not-found"
printf '  %-42s %s\n' "ssh.service" "$ssh_service_state"
printf '  %-42s %s\n' "ssh.socket" "$ssh_socket_state"
BROKEN=""
if ss -H -ltn 'sport = :22' 2>/dev/null | grep -q .; then
    printf '  %-42s %s\n' "TCP/22 listener" "LISTENING (Step 11 will pin ssh.service)"
else
    printf '  %-42s %s\n' "TCP/22 listener" "MISSING"
    BROKEN=" ssh transport (no TCP/22 listener)"
fi

ESSENTIAL="hv-kvp-daemon.service qemu-guest-agent.service smbd.service memlabs-dhcp-watchdog.service"
if [ "$VARIANT" = "Desktop" ]; then
    ESSENTIAL="$ESSENTIAL gdm3.service NetworkManager.service xrdp.service"
fi
for u in $ESSENTIAL; do
    state="$(systemctl is-enabled "$u" 2>/dev/null || true)"
    [ -n "$state" ] || state="not-found"
    printf '  %-42s %s\n' "$u" "$state"
    case "$state" in
        enabled|enabled-runtime|static|indirect|alias|generated) ;;
        *) BROKEN="$BROKEN $u" ;;
    esac
done
if [ -n "${BROKEN// /}" ]; then
    echo "ERROR: the trim left these essential units unusable:$BROKEN" >&2
    exit 1
fi

echo "=== Service trim complete ==="
