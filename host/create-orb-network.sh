#!/usr/bin/env bash
# Optional: create an isolated network for orbs with Proxmox VE SDN.
#
# Creates a Simple zone with a vnet whose subnet gets DHCP (dnsmasq) and
# source NAT through the host, so orbs reach the internet without sitting
# on your LAN. Afterwards use BRIDGE=$VNET SDN_ZONE=$ZONE with the other
# scripts. Requires Proxmox VE 8.1 or later. Safe to rerun.
#
# NAT alone does not stop orbs from reaching your LAN or the host;
# host/orb-firewall.sh does (install.sh sets both up).
set -euo pipefail

ZONE=${ZONE:-amporbs}                # max 8 characters
VNET=${VNET:-ampnet}                 # max 8 characters
SUBNET=${SUBNET:-10.77.0.0/24}
GATEWAY=${GATEWAY:-10.77.0.1}
DHCP_START=${DHCP_START:-10.77.0.100}
DHCP_END=${DHCP_END:-10.77.0.250}

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run as root on the Proxmox VE host" >&2; exit 1; }

if ! command -v dnsmasq >/dev/null; then
	log "Installing dnsmasq for SDN DHCP"
	apt-get update -qq && apt-get install -y -qq dnsmasq
	systemctl disable --now dnsmasq
fi

changed=0
log "Zone $ZONE"
if ! pvesh get "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
	pvesh create /cluster/sdn/zones --type simple --zone "$ZONE" --dhcp dnsmasq --ipam pve
	changed=1
fi

log "Vnet $VNET"
if ! pvesh get "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1; then
	pvesh create /cluster/sdn/vnets --vnet "$VNET" --zone "$ZONE" --alias "Amp orbs"
	changed=1
fi

log "Subnet $SUBNET"
subnet_id="$ZONE-${SUBNET/\//-}"
if ! pvesh get "/cluster/sdn/vnets/$VNET/subnets/$subnet_id" >/dev/null 2>&1; then
	pvesh create "/cluster/sdn/vnets/$VNET/subnets" --type subnet --subnet "$SUBNET" \
		--gateway "$GATEWAY" --snat 1 --dhcp-range "start-address=$DHCP_START,end-address=$DHCP_END"
	changed=1
fi

# Applying reloads the host's network configuration, so only do it when needed.
if [ "$changed" = 1 ] || ! ip link show "$VNET" >/dev/null 2>&1; then
	log "Applying SDN configuration"
	pvesh set /cluster/sdn
else
	log "SDN configuration is already applied"
fi
for _ in $(seq 30); do
	ip link show "$VNET" >/dev/null 2>&1 && break
	sleep 1
done
ip link show "$VNET" >/dev/null 2>&1 || { echo "vnet $VNET did not appear; check Datacenter -> SDN" >&2; exit 1; }
log "Done. Use BRIDGE=$VNET SDN_ZONE=$ZONE for setup-access.sh and build-template.sh"
