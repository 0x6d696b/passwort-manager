#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run this installer as root (sudo).' >&2; exit 1; }
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install -o root -g root -m 0755 "$directory/pi-firewall.sh" /usr/local/sbin/private-vault-firewall
install -o root -g root -m 0644 "$directory/private-vault-firewall.service" /etc/systemd/system/private-vault-firewall.service
install -d -o root -g root -m 0755 /etc/systemd/system/docker.service.d
install -o root -g root -m 0644 "$directory/docker-firewall.conf" /etc/systemd/system/docker.service.d/private-vault-firewall.conf
systemctl daemon-reload
systemctl enable private-vault-firewall.service
if systemctl is-active --quiet private-vault-firewall.service; then
    systemctl reload private-vault-firewall.service
else
    systemctl start private-vault-firewall.service
fi
printf '%s\n' 'HTTPS firewall installed. Docker and existing containers were not restarted.'
