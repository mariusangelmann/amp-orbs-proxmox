#!/usr/bin/env bash
# Confine orbs on the isolated network (host/create-orb-network.sh) to the
# internet. Loads two nftables tables of its own, so it works whether or not
# the Proxmox VE firewall is enabled, and only ever drops traffic:
#
#   * to the host: only DHCP and DNS from the vnet's dnsmasq are allowed, so
#     orbs cannot reach the web UI, SSH, or any other host service on any of
#     the host's addresses;
#   * forwarded: no private, CGNAT (Tailscale), link-local, or multicast
#     destinations, so orbs cannot reach your LAN or VPNs, and no IPv6;
#     nothing outside may open connections to orbs;
#   * bridged: orbs cannot talk to each other.
#
# Run by amp-orbs-firewall.service at boot. `orb-firewall.sh --remove`
# unloads the rules. Safe to rerun.
set -euo pipefail

VNET=${VNET:-ampnet}

[ "$(id -u)" = 0 ] || { echo "run as root on the Proxmox VE host" >&2; exit 1; }
command -v nft >/dev/null || { echo "nft not found; apt install nftables" >&2; exit 1; }

if [ "${1:-}" = --remove ]; then
	for family in inet bridge; do
		nft list table "$family" amp_orbs >/dev/null 2>&1 && nft delete table "$family" amp_orbs
	done
	echo "==> Removed the amp_orbs rules"
	exit 0
fi

# One transaction: the old rules are replaced, never briefly absent. The
# empty declarations make the deletes work when the tables don't exist yet.
nft -f - <<EOF
table inet amp_orbs
delete table inet amp_orbs
table bridge amp_orbs
delete table bridge amp_orbs

table inet amp_orbs {
	set blocked4 {
		type ipv4_addr
		flags interval
		elements = {
			0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
			172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3
		}
	}

	chain input {
		type filter hook input priority filter - 10; policy accept;
		iifname "$VNET" ct state established,related accept
		iifname "$VNET" udp dport 67 accept
		iifname "$VNET" meta l4proto { tcp, udp } th dport 53 accept
		iifname "$VNET" counter drop
	}

	chain forward {
		type filter hook forward priority filter - 10; policy accept;
		iifname "$VNET" meta nfproto ipv6 counter drop
		iifname "$VNET" ip daddr @blocked4 counter drop
		oifname "$VNET" ct state established,related accept
		oifname "$VNET" counter drop
	}
}

table bridge amp_orbs {
	chain forward {
		type filter hook forward priority filter - 10; policy accept;
		meta ibrname "$VNET" meta obrname "$VNET" counter drop
	}
}
EOF
echo "==> Loaded the amp_orbs rules for $VNET (nft list table inet amp_orbs)"
