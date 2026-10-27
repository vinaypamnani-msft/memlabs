#!/bin/bash
# client-config.sh — Per-user GNOME settings for LinuxClient VMs:
# .xsession for xrdp and per-user dconf fixups. Idempotent.
set -euo pipefail
echo "[memlabs-gnome] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

# --- .xsessionrc + .xsession: GNOME on X11 over xrdp ---------------------
# .xsessionrc is sourced by /etc/X11/Xsession BEFORE the session command
# runs, so env vars are available to gnome-session and all children.
# .xsession (non-executable, 0644) is read by Xsession's
# 50x11-common_determine-startup as the session command.
for UHOME in /home/vmbuildadmin /root; do
    UNAME=$(stat -c '%U' "$UHOME")
    UGRP=$(stat -c '%G' "$UHOME")

    cat > "$UHOME/.xsessionrc" << 'XSESSIONRC'
# memlabs: env vars for GNOME over xrdp (no hardware GPU)
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
# Mutter 46 refuses software renderers (llvmpipe) by default.
# xrdp has no GPU, so we must allow fallback drivers.
export MUTTER_ALLOW_FALLBACK_DRIVERS=1
export LIBGL_ALWAYS_SOFTWARE=1
XSESSIONRC
    chown "$UNAME:$UGRP" "$UHOME/.xsessionrc"
    chmod 0644 "$UHOME/.xsessionrc"

    # Session command — bare line, not executable, so Xsession runs it
    # via 'exec /bin/sh ~/.xsession' after all Xsession.d scripts.
    echo 'gnome-session --session=ubuntu' > "$UHOME/.xsession"
    chown "$UNAME:$UGRP" "$UHOME/.xsession"
    chmod 0644 "$UHOME/.xsession"
done

# --- Per-user fixup: replace Firefox with Edge in taskbar favorites -------
# System-wide dconf defaults (baked into the base image) only apply to keys
# the user hasn't set yet. Once a user logs in, GNOME writes per-user
# favorite-apps (including firefox.desktop from Ubuntu's default). Patch
# every existing user's dconf database so Edge replaces Firefox in the
# taskbar on next login.
for UHOME in /home/vmbuildadmin /root; do
    UNAME=$(stat -c '%U' "$UHOME" 2>/dev/null) || continue
    if [ -d "$UHOME/.config/dconf" ]; then
        su - "$UNAME" -c "
            export DCONF_PROFILE=/etc/dconf/profile/user
            CURRENT=\$(dconf read /org/gnome/shell/favorite-apps 2>/dev/null)
            if echo \"\$CURRENT\" | grep -q 'firefox.desktop'; then
                NEW=\$(echo \"\$CURRENT\" | sed \"s/'firefox.desktop'/'microsoft-edge.desktop'/g\")
                dconf write /org/gnome/shell/favorite-apps \"\$NEW\"
                echo '[memlabs-gnome] replaced firefox with edge in favorite-apps for $UNAME'
            elif [ -z \"\$CURRENT\" ] || [ \"\$CURRENT\" = \"@as []\" ]; then
                dconf write /org/gnome/shell/favorite-apps \"['microsoft-edge.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.TextEditor.desktop']\"
                echo '[memlabs-gnome] set favorite-apps with edge for $UNAME'
            fi
        " || true
    fi
done

echo "[memlabs-gnome] done: $(date -Is)"
