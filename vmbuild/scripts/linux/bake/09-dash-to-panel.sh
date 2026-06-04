#!/bin/bash
# 09-dash-to-panel.sh — Install dash-to-panel GNOME extension
set -euo pipefail
EXT_UUID="dash-to-panel@jderose9.github.com"
SHELL_VER=$(gnome-shell --version 2>/dev/null | grep -oP '[\d.]+' | cut -d. -f1) || true
if [ -z "$SHELL_VER" ]; then
    echo "ERROR: could not detect GNOME Shell version" >&2
    exit 1
fi
echo "GNOME Shell version: $SHELL_VER"

# Download extension metadata and extract download URL
EXT_JSON=$(mktemp)
wget_retry --timeout=30 -qO "$EXT_JSON" "https://extensions.gnome.org/extension-info/?uuid=${EXT_UUID}&shell_version=${SHELL_VER}"
DL_URL=$(python3 -c "import sys,json; print(json.load(open(sys.argv[1]))['download_url'])" "$EXT_JSON" 2>/dev/null) || true
rm -f "$EXT_JSON"

if [ -z "$DL_URL" ]; then
    echo "ERROR: could not resolve dash-to-panel download URL for GNOME Shell ${SHELL_VER}" >&2
    exit 1
fi
echo "Downloading from: https://extensions.gnome.org${DL_URL}"
wget_retry --timeout=60 -qO /tmp/dash-to-panel.zip "https://extensions.gnome.org${DL_URL}"
install -d -m 0755 "/usr/share/gnome-shell/extensions/${EXT_UUID}"
unzip -o /tmp/dash-to-panel.zip -d "/usr/share/gnome-shell/extensions/${EXT_UUID}/"
chmod -R a+rX "/usr/share/gnome-shell/extensions/${EXT_UUID}"
rm -f /tmp/dash-to-panel.zip
echo "=== dash-to-panel installed (GNOME Shell ${SHELL_VER}) ==="
