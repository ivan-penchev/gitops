#!/bin/bash
# Install the USB drive backup on the Proxmox host. Run as root:
#   curl -fsSL https://raw.githubusercontent.com/ivan-penchev/gitops/main/host/backup/install.sh | bash
set -euo pipefail
BASE=https://raw.githubusercontent.com/ivan-penchev/gitops/${REF:-main}/host/backup

apt-get install -y -qq sanoid >/dev/null
# The sanoid package brings a timer we don't use.
systemctl disable --now sanoid.timer 2>/dev/null || true

for f in usb-drive tank-backup; do
  curl -fsSL "$BASE/$f" -o "/usr/local/sbin/$f"; chmod 755 "/usr/local/sbin/$f"
done
for u in usb-drive-off.service tank-backup.service tank-backup.timer; do
  curl -fsSL "$BASE/$u" -o "/etc/systemd/system/$u"
done
[ -e /etc/default/tank-backup ] || curl -fsSL "$BASE/tank-backup.default" -o /etc/default/tank-backup

systemctl daemon-reload
systemctl enable --quiet usb-drive-off.service tank-backup.timer
echo "installed. settings: /etc/default/tank-backup"
