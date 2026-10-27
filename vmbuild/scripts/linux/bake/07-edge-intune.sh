#!/bin/bash
# 07-edge-intune.sh — Install Microsoft Edge + Intune from Microsoft repos
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
wait_for_apt_lock

# Download GPG key to a temp file first (avoids pipefail masking wget errors)
install -d -m 0755 /etc/apt/keyrings
MS_KEY=$(mktemp)
wget_retry --timeout=30 -qO "$MS_KEY" https://packages.microsoft.com/keys/microsoft.asc
gpg --dearmor < "$MS_KEY" > /etc/apt/keyrings/microsoft.gpg
rm -f "$MS_KEY"

echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main' \
  > /etc/apt/sources.list.d/microsoft-edge.list
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main' \
  > /etc/apt/sources.list.d/microsoft-prod.list
apt_retry apt-get update
apt_retry apt-get install -y microsoft-edge-stable intune-portal
echo "=== Microsoft Edge + Intune installed ==="
