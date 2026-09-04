#!/bin/bash
# proxy-client.sh — Configure a Linux VM to route HTTP/HTTPS traffic through
# the lab Squid forward proxy. Mirrors Set-WindowsClientProxy for Windows.
#
# Injected variables (prepended by Get-LinuxScript):
#   PROXY_URL  e.g. http://10.0.1.2:3128   (Squid listener)
#   NO_PROXY   e.g. localhost,127.0.0.1,::1,.adatum.com,10.0.1.2,10.0.1.0/24,10.0.1.1
#
# Sets, idempotently:
#   /etc/environment                     -> system-wide http(s)_proxy for services/PAM
#   /etc/apt/apt.conf.d/00-memlabs-proxy -> apt Acquire proxy
#   /etc/profile.d/memlabs-proxy.sh      -> interactive-shell exports
#   snap proxy (if snapd present)        -> Edge/Intune snaps on LinuxClient
#
# Emits PROXY_READY on success so the host-side dispatcher can confirm.
set -euo pipefail
echo "[memlabs-proxy-client] start: $(date -Is)"

: "${PROXY_URL:?PROXY_URL must be set}"
: "${NO_PROXY:?NO_PROXY must be set}"

BEGIN_MARK="# >>> memlabs-proxy >>>"
END_MARK="# <<< memlabs-proxy <<<"

# ── /etc/environment ─────────────────────────────────────────────────────
# Replace any prior memlabs-managed block, then append the current one.
# systemd services and PAM sessions read /etc/environment at startup/login.
touch /etc/environment
# Use | as sed's alternate address delimiter because each marker starts with #.
sed -i "\|^${BEGIN_MARK}$|,\|^${END_MARK}$|d" /etc/environment
{
    echo "${BEGIN_MARK}"
    echo "http_proxy=\"${PROXY_URL}\""
    echo "https_proxy=\"${PROXY_URL}\""
    echo "ftp_proxy=\"${PROXY_URL}\""
    echo "HTTP_PROXY=\"${PROXY_URL}\""
    echo "HTTPS_PROXY=\"${PROXY_URL}\""
    echo "FTP_PROXY=\"${PROXY_URL}\""
    echo "no_proxy=\"${NO_PROXY}\""
    echo "NO_PROXY=\"${NO_PROXY}\""
    echo "${END_MARK}"
} >> /etc/environment
echo "[memlabs-proxy-client] wrote /etc/environment proxy block"

# ── apt proxy ────────────────────────────────────────────────────────────
# apt does NOT read environment proxies; it needs its own Acquire config.
cat > /etc/apt/apt.conf.d/00-memlabs-proxy <<EOF
// Managed by memlabs proxy-client.sh -- changes will be overwritten.
Acquire::http::Proxy "${PROXY_URL}";
Acquire::https::Proxy "${PROXY_URL}";
EOF
echo "[memlabs-proxy-client] wrote /etc/apt/apt.conf.d/00-memlabs-proxy"

# ── interactive shells ───────────────────────────────────────────────────
# /etc/environment is not sourced by non-login/interactive shells in all
# cases; profile.d guarantees exports for SSH/RDP terminal sessions.
cat > /etc/profile.d/memlabs-proxy.sh <<EOF
# Managed by memlabs proxy-client.sh -- changes will be overwritten.
export http_proxy="${PROXY_URL}"
export https_proxy="${PROXY_URL}"
export ftp_proxy="${PROXY_URL}"
export HTTP_PROXY="${PROXY_URL}"
export HTTPS_PROXY="${PROXY_URL}"
export FTP_PROXY="${PROXY_URL}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
EOF
chmod 0644 /etc/profile.d/memlabs-proxy.sh
echo "[memlabs-proxy-client] wrote /etc/profile.d/memlabs-proxy.sh"

# ── snap proxy (LinuxClient: Edge + Intune are snaps) ────────────────────
if command -v snap >/dev/null 2>&1; then
    # snapd may not be fully up yet on a fresh boot; best-effort.
    snap set system proxy.http="${PROXY_URL}" 2>/dev/null || echo "[memlabs-proxy-client] snap proxy.http set skipped (snapd not ready)"
    snap set system proxy.https="${PROXY_URL}" 2>/dev/null || echo "[memlabs-proxy-client] snap proxy.https set skipped (snapd not ready)"
    echo "[memlabs-proxy-client] configured snap system proxy"
fi

echo "[memlabs-proxy-client] done: $(date -Is)"
echo "PROXY_READY"
