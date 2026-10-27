#!/bin/bash
# 01-system-updates.sh — apt-get update + dist-upgrade
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
wait_for_apt_lock
echo "=== apt-get update ==="
apt_retry apt-get update
echo "=== apt-get dist-upgrade ==="
apt_retry apt-get dist-upgrade -y
echo "=== System updates complete ==="
