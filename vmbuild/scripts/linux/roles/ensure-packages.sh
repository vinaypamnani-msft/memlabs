#!/bin/bash
# ensure-packages.sh — Install the first-boot package set ONLY when something is
# actually missing.
#
# Replaces cloud-init's 'packages:' module for the deploy path. That module
# unconditionally runs `apt-get update` (package_update) and then an install
# transaction, so a fully-baked image still pays a network round trip plus a
# large apt/dpkg disk transaction on EVERY first boot. That transaction is the
# biggest single chunk of a Linux first boot and it lands exactly while Phase 1
# is copying every other VM's base image -- the contention that timed ZZ-TOFU
# out on 2026-08-16. Once bake/02-base-packages.sh ships the full set this is a
# handful of `dpkg -s` calls and first boot does NO apt at all.
#
# Same detect-and-skip shape as roles/ensure-samba.sh, and it heals a
# corrupt/truncated /var/lib/dpkg/status before installing for the same reason.
#
# Requires the apt-retry.sh helpers (Get-LinuxScript -IncludeAptRetry):
#   wait_for_apt_lock / recover_dpkg / apt_retry
# Expects MEMLABS_PACKAGES: space-separated package list.
# Emits PACKAGES_OK / PACKAGES_INSTALLED / PACKAGES_FAILED as the final line.
#
# NOTE: intentionally does NOT 'set -e' -- the recovery helpers return non-zero
# on transient conditions and we want to press on to the install/verify steps.
export DEBIAN_FRONTEND=noninteractive

if [ -z "${MEMLABS_PACKAGES// /}" ]; then
    echo "[ensure-packages] no packages requested; nothing to do"
    echo "PACKAGES_OK"
    exit 0
fi

wanted_count=$(echo "$MEMLABS_PACKAGES" | wc -w)
missing=""
for p in $MEMLABS_PACKAGES; do
    dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done

if [ -z "${missing// /}" ]; then
    echo "[ensure-packages] all ${wanted_count} package(s) already present; skipping apt entirely"
    echo "PACKAGES_OK"
    exit 0
fi

echo "[ensure-packages] missing of ${wanted_count}:${missing}"
wait_for_apt_lock 300 || true
# Heal a corrupt/truncated dpkg status DB before the install. Without this,
# apt-get aborts with "end of file after field name ''" / dpkg rc 2.
recover_dpkg || true
apt_retry apt-get update -y || true
# A rebuilt status DB is APPROXIMATE, so apt can see pre-existing broken deps
# and refuse to install anything new. Reconcile first, then install with
# --fix-broken. On a healthy box the fix-broken pass is a no-op.
apt_retry apt-get install -f -y || true

install_missing() {
    # shellcheck disable=SC2086
    apt_retry apt-get install -y --fix-broken $missing
}

if install_missing; then
    sync || true
    echo "PACKAGES_INSTALLED"
    exit 0
fi

echo "[ensure-packages] install failed; one more fix-broken pass + retry" >&2
apt_retry apt-get install -f -y || true
if install_missing; then
    sync || true
    echo "PACKAGES_INSTALLED"
    exit 0
fi

# Report which ones actually failed rather than the original wanted list.
still=""
for p in $missing; do
    dpkg -s "$p" >/dev/null 2>&1 || still="$still $p"
done
echo "[ensure-packages] ERROR: could not install:${still}" >&2
echo "PACKAGES_FAILED"
exit 1
