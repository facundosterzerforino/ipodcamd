#!/usr/bin/env bash
# Copies the .deb to a jailbroken iOS 6 device and installs it. Usage: scripts/install.sh <device-ip> [path/to/deb]
# iOS 6's OpenSSH only offers old algorithms, so they are re-enabled for this one connection.
set -euo pipefail
IP="${1:?usage: install.sh <device-ip> [deb]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB="${2:-$(ls "$ROOT"/build/ipodcamd_*_iphoneos-arm.deb | head -1)}"
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa
          -o KexAlgorithms=+diffie-hellman-group-exchange-sha1,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
          -o Ciphers=+aes128-cbc,aes256-cbc -o MACs=+hmac-sha1)
echo "installing $DEB on root@$IP (you will be asked for the root password)"
ssh "${SSH_OPTS[@]}" "root@$IP" 'cat > /var/root/ipodcamd.deb && dpkg -i /var/root/ipodcamd.deb' < "$DEB"
