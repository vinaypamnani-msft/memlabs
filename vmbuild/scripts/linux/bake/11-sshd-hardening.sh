#!/bin/bash
# 03d-sshd-hardening.sh — Make sshd unable to stay down.
#
# SSH is the ONLY way memlabs reaches a Linux guest: no PSDirect, no WinRM. If
# sshd is not listening the VM is unreachable, Wait-LinuxVmReady burns its full
# budget, and Phase 1 fails after ~28 minutes with nothing to look at. Every
# change here targets a way sshd has actually been observed to be down:
#
#   * systemd gave up after 5 start attempts and never tried again
#   * the unit failed once early in boot and nothing retried it
#   * a config edit made sshd unparseable, so it never started again
#   * host keys were missing, so sshd exited immediately
#   * /run/sshd was missing ("Missing privilege separation directory")
#   * logins hung on a reverse-DNS lookup against a DC that does not exist yet
#
# The 5-minute cron watchdog written by cloud-init stays as a last resort, but
# 5 minutes is an eternity inside a boot window -- this makes systemd itself
# recover in seconds.
set -euo pipefail

echo "=== sshd hardening ==="

# ── 1. Never stop retrying ───────────────────────────────────────────────
# The default rate limiter (5 starts / 10s) makes systemd mark the unit failed
# and STOP, permanently, for the rest of the boot. StartLimitIntervalSec=0
# disables the limiter outright: for this service, retrying forever is strictly
# better than staying down, because down means the VM is unreachable.
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/memlabs-restart.conf << 'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3
# Generate any missing host key before starting. '-A' only creates types that
# are absent, so this is a no-op on every boot after the first, and it means a
# wiped /etc/ssh cannot leave sshd unable to start.
ExecStartPre=-/usr/bin/ssh-keygen -A
# sshd exits immediately if the privilege-separation directory is missing.
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
EOF
echo "  ssh.service: Restart=always, RestartSec=3, no start-rate limit, host keys ensured"

# ── 2. One listener, not two ─────────────────────────────────────────────
# Ubuntu ships both ssh.service and ssh.socket. If both end up enabled they
# fight over port 22 and which one wins depends on boot ordering -- and the
# socket-activated path defers sshd until the first connection, which races
# every readiness probe. Pin the always-listening service.
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl mask ssh.socket >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
echo "  ssh.socket masked; ssh.service enabled (a listener that is always up beats one that is activated)"

# ── 3. Config that cannot hang ───────────────────────────────────────────
# Ubuntu 24.04's sshd_config starts with `Include /etc/ssh/sshd_config.d/*.conf`
# and FIRST match wins, so a drop-in sorted early overrides the main file.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-memlabs.conf << 'EOF'
# UseDNS no: with it on, sshd reverse-resolves every client before accepting.
# Lab VMs point at a DC that may not exist yet, so that lookup blocks until it
# times out -- turning "sshd is up" into "sshd appears hung" for 30s a login.
UseDNS no

# GSSAPI negotiation reaches for Kerberos on domain-joined guests and stalls
# the same way when the KDC is not answering. memlabs authenticates by key.
GSSAPIAuthentication no

# Keep sessions from being reaped mid-command by an idle NAT/vSwitch, and make
# a genuinely dead peer disconnect promptly instead of holding a slot.
ClientAliveInterval 30
ClientAliveCountMax 6
TCPKeepAlive yes

# A slow contended boot can exceed the 2-minute default before the client
# finishes authenticating, which shows up as a spurious connection failure.
LoginGraceTime 120
MaxStartups 30:30:100

# memlabs connects with the cached ed25519 key; password auth stays on because
# the console/SMB accounts use it.
PubkeyAuthentication yes
EOF
echo "  /etc/ssh/sshd_config.d/10-memlabs.conf written"

# ── 4. Prove the config parses BEFORE shipping it ────────────────────────
# An unparseable sshd_config means sshd never starts again, on every VM built
# from this image, with no way in to fix it. Fail the bake instead.
# Absolute path: sshd lives in /usr/sbin, which is not always on PATH, and a
# `command not found` here must not be mistaken for a clean parse.
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if [ ! -x "$SSHD_BIN" ]; then
    echo "ERROR: sshd binary not found at ${SSHD_BIN}; cannot validate the configuration." >&2
    rm -f /etc/ssh/sshd_config.d/10-memlabs.conf
    exit 1
fi
if ! "$SSHD_BIN" -t; then
    echo "ERROR: sshd rejected the configuration; refusing to bake an image that cannot start sshd." >&2
    rm -f /etc/ssh/sshd_config.d/10-memlabs.conf
    exit 1
fi
echo "  ${SSHD_BIN} -t: configuration parses"

# ── 5. A watchdog that reacts in seconds, not 5 minutes ──────────────────
# cloud-init also installs a */5 cron entry. That is the right backstop for a
# long-running VM but far too slow during a boot window, where the whole
# SSH-readiness budget can be gone before the first cron tick.
cat > /usr/local/sbin/memlabs-sshd-watchdog << 'EOF'
#!/bin/bash
# Restart sshd if nothing is listening on tcp/22. Shared by the systemd timer
# below and the */5 cron entry cloud-init installs.
if ss -tln 2>/dev/null | grep -qE '(^|[^0-9.]):22[[:space:]]'; then
    exit 0
fi
logger -t memlabs-sshd-watchdog "tcp/22 not listening; restarting sshd"
systemctl reset-failed ssh.service 2>/dev/null || true
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
EOF
chmod 0755 /usr/local/sbin/memlabs-sshd-watchdog

cat > /etc/systemd/system/memlabs-sshd-watchdog.service << 'EOF'
[Unit]
Description=memlabs sshd listener watchdog
After=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/memlabs-sshd-watchdog
EOF

cat > /etc/systemd/system/memlabs-sshd-watchdog.timer << 'EOF'
[Unit]
Description=Check every 30s that sshd is listening

[Timer]
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable memlabs-sshd-watchdog.timer >/dev/null 2>&1
echo "  memlabs-sshd-watchdog.timer enabled (first check at 45s, then every 30s)"

# ── 6. Verify the end state rather than assuming it ──────────────────────
FAIL=0
for check in \
    "ssh.service:$(systemctl is-enabled ssh.service 2>&1)" \
    "memlabs-sshd-watchdog.timer:$(systemctl is-enabled memlabs-sshd-watchdog.timer 2>&1)"; do
    name="${check%%:*}"; state="${check#*:}"
    printf '  %-36s %s\n' "$name" "$state"
    case "$state" in enabled|enabled-runtime|static) ;; *) FAIL=1 ;; esac
done
if [ ! -x /usr/local/sbin/memlabs-sshd-watchdog ]; then
    echo "  ERROR: watchdog script is not executable" >&2
    FAIL=1
fi
if [ "$FAIL" -ne 0 ]; then
    echo "ERROR: sshd hardening did not reach the expected end state." >&2
    exit 1
fi

echo "=== sshd hardening complete ==="
