#!/bin/bash
# 08-desktop-config.sh — Desktop system configuration.
# Edge default browser, --password-store=basic, fixup scripts,
# PAM hooks for GNOME Keyring, polkit colord rule, dconf defaults.
set -euo pipefail

# --- Edge as default browser ---
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/microsoft-edge-stable 200
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/microsoft-edge-stable 200
update-alternatives --set x-www-browser /usr/bin/microsoft-edge-stable
update-alternatives --set gnome-www-browser /usr/bin/microsoft-edge-stable

# --- Edge --password-store=basic (suppress GNOME Keyring prompt) ---
if [ -f /usr/share/applications/microsoft-edge.desktop ]; then
    sed -i 's|Exec=/usr/bin/microsoft-edge-stable|Exec=/usr/bin/microsoft-edge-stable --password-store=basic|g' \
        /usr/share/applications/microsoft-edge.desktop
fi

# --- Edge fixup login script ---
cat > /etc/profile.d/memlabs-edge-fixup.sh << 'FIXUP'
#!/bin/bash
DESKTOP=/usr/share/applications/microsoft-edge.desktop
if [ -f "$DESKTOP" ] && grep -q 'Exec=/usr/bin/microsoft-edge-stable ' "$DESKTOP" \
   && ! grep -q '\-\-password-store=basic' "$DESKTOP"; then
    sudo sed -i 's|Exec=/usr/bin/microsoft-edge-stable|Exec=/usr/bin/microsoft-edge-stable --password-store=basic|g' \
        "$DESKTOP" 2>/dev/null
fi
if command -v dconf >/dev/null 2>&1; then
    FAVS=$(dconf read /org/gnome/shell/favorite-apps 2>/dev/null)
    if echo "$FAVS" | grep -q 'firefox.desktop'; then
        NEW=$(echo "$FAVS" | sed "s/'firefox.desktop'/'microsoft-edge.desktop'/g")
        dconf write /org/gnome/shell/favorite-apps "$NEW" 2>/dev/null
    fi
fi
FIXUP
chmod 0644 /etc/profile.d/memlabs-edge-fixup.sh

# --- Sudoers for Edge fixup ---
echo 'ALL ALL=(root) NOPASSWD: /usr/bin/sed -i s*Exec=/usr/bin/microsoft-edge-stable*Exec=/usr/bin/microsoft-edge-stable --password-store=basic* /usr/share/applications/microsoft-edge.desktop' \
    > /etc/sudoers.d/memlabs-edge-fixup
chmod 0440 /etc/sudoers.d/memlabs-edge-fixup

# --- XDG mimeapps (Edge as default handler) ---
install -d -m 0755 /etc/xdg
cat > /etc/xdg/mimeapps.list << 'MIMEEOF'
[Default Applications]
x-scheme-handler/http=microsoft-edge.desktop
x-scheme-handler/https=microsoft-edge.desktop
text/html=microsoft-edge.desktop
MIMEEOF

# --- PAM: auto-unlock GNOME Keyring on xrdp login ---
# microsoft-identity-broker (pulled in by intune-portal) stores Entra ID
# auth tokens in GNOME Keyring via libsecret / Secret Service D-Bus API.
# Without this, the keyring stays locked and enrollment fails.
if [ -f /etc/pam.d/xrdp-sesman ]; then
    if ! grep -q 'pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman; then
        sed -i '/^@include common-auth/a auth       optional     pam_gnome_keyring.so' \
            /etc/pam.d/xrdp-sesman
        sed -i '/^@include common-session/a session    optional     pam_gnome_keyring.so auto_start' \
            /etc/pam.d/xrdp-sesman
    fi
fi

# --- Polkit: allow colord without auth for xrdp ---
install -d -m 0755 /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-allow-colord.rules << 'RULES'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") == 0) {
        return polkit.Result.YES;
    }
});
RULES

# --- dconf: Windows-like GNOME defaults (system-wide) ---
install -d -m 0755 /etc/dconf/profile
printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user

install -d -m 0755 /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-memlabs-windows-like << 'DCONF'
[org/gnome/desktop/wm/preferences]
button-layout='appmenu:minimize,maximize,close'

[org/gnome/shell]
enabled-extensions=['dash-to-panel@jderose9.github.com', 'ding@rastersoft.com']
welcome-dialog-last-shown-version='99.0'
favorite-apps=['microsoft-edge.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.TextEditor.desktop']

[org/gnome/shell/extensions/dash-to-panel]
panel-positions='{"0":"BOTTOM"}'
panel-sizes='{"0":40}'
panel-element-positions='{"0":[{"element":"showAppsButton","visible":true,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"centerMonitor"},{"element":"centerBox","visible":false,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedBR"},{"element":"dateMenu","visible":true,"position":"stackedBR"},{"element":"systemMenu","visible":true,"position":"stackedBR"},{"element":"desktopButton","visible":true,"position":"stackedBR"}]}'
appicon-margin=4
appicon-padding=4
animate-appicon-hover=false
dot-style-focused='DASHES'
dot-style-unfocused='DOTS'
trans-use-custom-opacity=false
hide-overview-on-startup=true
show-apps-icon-file=''

[org/gnome/desktop/interface]
enable-hot-corners=false

[org/gnome/shell/extensions/ding]
show-home=true
show-trash=true

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false

[org/gnome/desktop/notifications]
show-banners=true
DCONF

dconf update

echo "=== Desktop system configuration complete ==="
