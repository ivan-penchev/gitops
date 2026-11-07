#!/usr/bin/env bash
# Only run after fail-closed preflight and checksum verification on a fresh guest.
set -e
export SKIP_INSTALL=true USER=root
source /opt/pihole-ansible/installer.sh
# Never invoke main, FTLinstall, clone_or_reset_repos, password or resolver helpers.
create_pihole_user
install -d -m 0755 -o pihole -g pihole /etc/pihole
installScripts
installConfigs
installDefaultBlocklists
# Render the pinned fresh logrotate template without the installer's migration logic.
install -o root -g root -m 0644 /etc/.pihole/advanced/Templates/logrotate /etc/logrotate.d/pihole
sed -i "s/# su #/su $(stat -c '%U %G' /var/log)/g" /etc/logrotate.d/pihole
