#!/bin/bash
# install-motd.sh — Install MOTD and squidlog helper on the Proxy VM.
#
# Required variables (set by caller before sourcing):
#   SQUIDLOG_B64  — base64-encoded squidlog script
#   PROXY_FQDN    — FQDN of this proxy VM (for the banner)
#
# Idempotent. Reports MOTD_READY on success.
set -euo pipefail

echo "[install-motd] Installing squidlog helper..."
echo "$SQUIDLOG_B64" | base64 -d > /usr/local/bin/squidlog
chmod 0755 /usr/local/bin/squidlog

echo "[install-motd] Writing MOTD..."

cat > /etc/motd <<EOF

  ╔══════════════════════════════════════════════════════════════╗
  ║              MemLabs Squid Proxy — ${PROXY_FQDN}
  ╠══════════════════════════════════════════════════════════════╣
  ║                                                              ║
  ║  View squid logs (colorized, columnar):                      ║
  ║    squidlog              Last 20 entries                     ║
  ║    squidlog microsoft    Filter on "microsoft"               ║
  ║    squidlog 172.19.77.10 Traffic from a specific VM          ║
  ║    squidlog 403          Show 403 responses                  ║
  ║    squidlog -f           Follow in real time                 ║
  ║    squidlog -f microsoft Follow + filter                     ║
  ║    squidlog -h           Full help + log field reference      ║
  ║                                                              ║
  ║  Raw log:  /var/log/squid/access.log                         ║
  ║  Config:   /etc/squid/squid.conf                             ║
  ║  Blocklist admin:  http://$(hostname -I | awk '{print $1}'):8443          ║
  ║                                                              ║
  ╚══════════════════════════════════════════════════════════════╝

EOF

# Disable Ubuntu's dynamic MOTD scripts so our static MOTD is the
# only thing shown. The dynamic scripts add noise (ads, update counts)
# that obscures the useful info above.
chmod -x /etc/update-motd.d/* 2>/dev/null || true

echo "MOTD_READY"
