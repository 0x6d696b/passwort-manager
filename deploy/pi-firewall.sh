#!/bin/sh
# Managed profile: Pi eth0=192.168.178.33, trusted LAN=192.168.178.0/24.
# Use iptables-nft on this host; never edit Docker's nftables tables directly.
set -eu
iptables_bin=${PV_IPTABLES:-/usr/sbin/iptables}
chain=PV_PI_HTTPS

guard() {
    "$iptables_bin" -w 5 "$1" DOCKER-USER -p tcp -m conntrack \
        --ctdir ORIGINAL --ctorigdst 192.168.178.33 --ctorigdstport 443 \
        -m comment --comment private-vault-update -j DROP
}
hook() {
    "$iptables_bin" -w 5 "$1" DOCKER-USER -p tcp -m conntrack \
        --ctdir ORIGINAL --ctorigdst 192.168.178.33 --ctorigdstport 443 \
        -m comment --comment private-vault-https -j "$chain"
}

case "${1:-apply}" in
    apply)
        # Create the hook before Docker starts on boot; preserve all existing rules.
        "$iptables_bin" -w 5 -N DOCKER-USER 2>/dev/null || "$iptables_bin" -w 5 -L DOCKER-USER -n >/dev/null
        "$iptables_bin" -w 5 -N "$chain" 2>/dev/null || "$iptables_bin" -w 5 -L "$chain" -n >/dev/null
        guard -C >/dev/null 2>&1 || guard -I
        # Only our own chain is flushed. Leave the scoped guard if an update fails.
        "$iptables_bin" -w 5 -F "$chain"
        "$iptables_bin" -w 5 -A "$chain" -i eth0 -s 192.168.178.0/24 -j RETURN
        "$iptables_bin" -w 5 -A "$chain" -j DROP
        while hook -C >/dev/null 2>&1; do hook -D; done
        hook -I
        "$iptables_bin" -w 5 -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || \
            "$iptables_bin" -w 5 -I FORWARD 1 -j DOCKER-USER
        while guard -C >/dev/null 2>&1; do guard -D; done
        ;;
    remove)
        # Rebind the proxy to loopback BEFORE removing LAN restrictions.
        while hook -C >/dev/null 2>&1; do hook -D; done
        while guard -C >/dev/null 2>&1; do guard -D; done
        if "$iptables_bin" -w 5 -L "$chain" -n >/dev/null 2>&1; then
            "$iptables_bin" -w 5 -F "$chain"
            "$iptables_bin" -w 5 -X "$chain"
        fi
        ;;
    *) echo 'usage: private-vault-firewall [apply|remove]' >&2; exit 2 ;;
esac
