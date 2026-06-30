#!/bin/bash
# firefox.sh — Install Firefox from Mozilla's deb repo (not snap shim)
# and wire it as the system default browser.
set -euo pipefail
echo "[memlabs-firefox] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

# Idempotency: skip if the Mozilla deb version of Firefox is already installed.
# Check both binary exists and the Mozilla apt repo is configured (to
# distinguish from the Ubuntu snap shim).
if command -v firefox >/dev/null 2>&1 && [ -f /etc/apt/sources.list.d/mozilla.list ]; then
    echo "[memlabs-firefox] already installed (Mozilla deb); skipping."
    exit 0
fi

# Firefox: the Ubuntu 'firefox' package is a snap shim that takes 30s+ to
# first-launch. Use the real Mozilla deb instead, pinned high so apt prefers
# it over the transitional snap stub.
install -d -m 0755 /etc/apt/keyrings
MOZ_KEY=$(mktemp)
wget_retry --timeout=30 -qO "$MOZ_KEY" https://packages.mozilla.org/apt/repo-signing-key.gpg
cp "$MOZ_KEY" /etc/apt/keyrings/packages.mozilla.org.asc
rm -f "$MOZ_KEY"

echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' \
    > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
    > /etc/apt/preferences.d/mozilla

wait_for_apt_lock
apt_retry apt-get update
apt_retry apt-get install -y firefox

# Wire firefox as the system-wide x-www-browser / gnome-www-browser so
# xfce4-web-browser (which calls xdg-open -> x-www-browser) opens it.
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/firefox 200 || true
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/firefox 200 || true
update-alternatives --set x-www-browser /usr/bin/firefox || true
update-alternatives --set gnome-www-browser /usr/bin/firefox || true

# Tell XDG that firefox handles http/https/text-html system-wide.
install -d -m 0755 /etc/xdg
cat > /etc/xdg/mimeapps.list <<'MIMEEOF'
[Default Applications]
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
text/html=firefox.desktop
MIMEEOF

echo "[memlabs-firefox] done: $(date -Is)"
