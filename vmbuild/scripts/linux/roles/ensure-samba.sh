#!/bin/bash
# ensure-samba.sh — Idempotently ensure Samba (smbd) is installed, enabled, and
# listening on TCP 445. Shared by cloud-init first boot AND the Phase 11 SMB
# self-heal so both paths use identical, dpkg-recovery-backed logic.
#
# Detect-and-skip: if smbd is already present (a future baked image, or a prior
# run) the apt install is skipped. Otherwise samba is installed AFTER healing a
# corrupt/truncated dpkg status DB -- the #1 reason 'apt-get install samba'
# fails on a stressed host is a truncated /var/lib/dpkg/status left by an
# ungraceful reboot ("dpkg: error: ... end of file after field name ''"), which
# the shared recover_dpkg/repair_dpkg_status helpers restore from backup.
#
# Requires the apt-retry.sh helpers (Get-LinuxScript -IncludeAptRetry):
#   wait_for_apt_lock / recover_dpkg / repair_dpkg_status / apt_retry
# Emits SMBD_LISTENING (rc 0) or SMBD_DOWN (rc 1) as the final line.
#
# NOTE: intentionally does NOT 'set -e' -- the recovery helpers return non-zero
# on transient conditions (lock timeout, partial recovery) and we want to press
# on to the install/enable/verify steps regardless.
export DEBIAN_FRONTEND=noninteractive

if command -v smbd >/dev/null 2>&1 || dpkg -s samba >/dev/null 2>&1; then
    echo "[ensure-samba] samba already present; ensuring smbd enabled + running"
else
    echo "[ensure-samba] samba not installed; healing dpkg then installing"
    wait_for_apt_lock 300 || true
    # Heal a corrupt/truncated dpkg status DB before the install. Without this,
    # apt-get aborts with "end of file after field name ''" / dpkg rc 2 and
    # smbd.service never gets created.
    recover_dpkg || true
    apt_retry apt-get update -y || true
    # A last-resort rebuild_dpkg_status (fired by the guard when no parseable
    # backup exists) reconstructs an APPROXIMATE status DB -- versions/states
    # come from the apt lists, not the lost status -- so apt's dependency solver
    # can see pre-existing "broken" deps and refuse to install anything new
    # ("... but it is not going to be installed"). Reconcile with a fix-broken
    # pass, then install samba with --fix-broken so apt is allowed to pull and
    # repair whatever the rebuild left inconsistent. On a healthy box the
    # fix-broken pass is a no-op.
    apt_retry apt-get install -f -y || true
    if ! apt_retry apt-get install -y --fix-broken samba; then
        echo "[ensure-samba] samba install failed; one more fix-broken pass + retry" >&2
        apt_retry apt-get install -f -y || true
        apt_retry apt-get install -y --fix-broken samba \
            || echo "[ensure-samba] ERROR: samba install failed even after dpkg recovery + fix-broken" >&2
    fi
    # Flush the freshly-written dpkg status DB (and its status-old backup) to
    # the VHDX so a later hard reset leaves a recoverable dpkg database.
    sync || true
fi

# Enable + (re)start smbd regardless of the install path above.
systemctl reset-failed smbd 2>/dev/null || true
systemctl enable --now smbd 2>/dev/null || true
systemctl restart smbd 2>/dev/null || true

# Confirm the listener came up (give smbd a few seconds to bind :445).
for _i in 1 2 3 4 5; do
    if ss -ltn 'sport = :445' 2>/dev/null | grep -q ':445'; then
        echo "SMBD_LISTENING"
        exit 0
    fi
    sleep 3
done
echo "SMBD_DOWN"
systemctl --no-pager status smbd 2>&1 | tail -15 || true
exit 1
