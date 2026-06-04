#!/bin/bash
# 02-base-packages.sh — Install Hyper-V tools, qemu-guest-agent, openssh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
wait_for_apt_lock
apt_retry apt-get install -y linux-tools-virtual linux-cloud-tools-virtual qemu-guest-agent openssh-server
echo "=== Base packages installed ==="
