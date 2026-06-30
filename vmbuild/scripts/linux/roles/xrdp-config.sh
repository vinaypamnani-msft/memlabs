#!/bin/bash
# xrdp-config.sh — Configure xrdp sessions, xfce4 panel defaults,
# disable screen lock/screensaver, enable xrdp + firewall.
set -euo pipefail
echo "[memlabs-rdp-config] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

# xrdp drops privs to 'xrdp'; it needs to read the snakeoil key to TLS the handshake.
adduser xrdp ssl-cert || true

# Default XDG session for vmbuildadmin and root.
install -d -o vmbuildadmin -g vmbuildadmin -m 0755 /home/vmbuildadmin
echo 'xfce4-session' > /home/vmbuildadmin/.xsession
chown vmbuildadmin:vmbuildadmin /home/vmbuildadmin/.xsession
chmod 0644 /home/vmbuildadmin/.xsession
echo 'xfce4-session' > /root/.xsession
chmod 0644 /root/.xsession

# Pre-seed default xfce4 panel config so the "Welcome to the first start of
# the panel" dialog never fires. Over xrdp it renders behind the desktop or
# auto-dismisses with an empty panel, leaving a blank blue screen.
if [ -d /etc/xdg/xfce4/panel ]; then
    for UHOME in /home/vmbuildadmin /root; do
        install -d -o "$(stat -c '%U' "$UHOME")" -g "$(stat -c '%G' "$UHOME")" -m 0700 "$UHOME/.config"
        cp -rn /etc/xdg/xfce4 "$UHOME/.config/"
        chown -R "$(stat -c '%U' "$UHOME"):$(stat -c '%G' "$UHOME")" "$UHOME/.config/xfce4"
    done
fi

# Disable screen lock, screensaver, and idle blank (lab VM, not production).
# xfce4-screensaver, light-locker, and xfce4-power-manager all race to lock.
apt-get remove -y light-locker xfce4-screensaver 2>/dev/null || true
for UHOME in /home/vmbuildadmin /root; do
    UNAME=$(stat -c '%U' "$UHOME")
    UGRP=$(stat -c '%G' "$UHOME")
    XCONF="$UHOME/.config/xfce4/xfconf/xfce-perchannel-xml"
    install -d -o "$UNAME" -g "$UGRP" -m 0700 "$XCONF"

    # Power manager: never blank / sleep / suspend
    cat > "$XCONF/xfce4-power-manager.xml" << 'XFCEPM'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="inactivity-on-ac" type="uint" value="0"/>
  </property>
</channel>
XFCEPM
    chown "$UNAME:$UGRP" "$XCONF/xfce4-power-manager.xml"

    # Session: no auto-lock on idle
    cat > "$XCONF/xfce4-session.xml" << 'XFCESESS'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="LockCommand" type="string" value=""/>
  </property>
</channel>
XFCESESS
    chown "$UNAME:$UGRP" "$XCONF/xfce4-session.xml"
done

ufw allow 3389/tcp || true
systemctl enable --now xrdp || true
systemctl enable --now xrdp-sesman || true

echo "[memlabs-rdp-config] done: $(date -Is)"
