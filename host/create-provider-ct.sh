#!/usr/bin/env bash
# Create (or update) a small Debian container that runs `amp orb provider`.
#
# Run as root on a Proxmox VE node after host/setup-access.sh. Rerun to
# update the dispatch program; the existing Amp provider token is kept
# unless AMP_ORB_PROVIDER_TOKEN is set.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")

CT_ID=${CT_ID:-}                     # default: existing amp-orb-provider CT or next free ID
CT_HOSTNAME=${CT_HOSTNAME:-amp-orb-provider}
CT_STORAGE=${CT_STORAGE:-}           # default: first storage that holds container disks
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}
PROVIDER_BRIDGE=${PROVIDER_BRIDGE:-vmbr0}
PROVIDER_VLAN=${PROVIDER_VLAN:-}
PROVIDER_IP=${PROVIDER_IP:-dhcp}     # or CIDR, e.g. 192.0.2.20/24 (then set PROVIDER_GW)
PROVIDER_GW=${PROVIDER_GW:-}
POOL=${POOL:-amp-orbs}
TOKEN_FILE=${TOKEN_FILE:-/root/.amp-orbs-pve-token}
PVE_API_URL=${PVE_API_URL:-}         # default: this host's address on PROVIDER_BRIDGE
AMP_ORB_PROVIDER_TOKEN=${AMP_ORB_PROVIDER_TOKEN:-}
EXTRA_ENV=${EXTRA_ENV:-}             # extra provider.env lines, e.g. "ORB_MAX_RUNNING=4"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root on the Proxmox VE host"
[ -s "$TOKEN_FILE" ] || die "$TOKEN_FILE is missing; run host/setup-access.sh first"

if [ -z "$CT_ID" ]; then
	CT_ID=$(pct list | awk -v h="$CT_HOSTNAME" 'NR>1 && $NF==h {print $1; exit}')
fi

arch=$(dpkg --print-architecture)

# An earlier version could pick a container template for another CPU
# architecture; such a container never starts. Replace it if we made it.
if [ -n "$CT_ID" ] && pct status "$CT_ID" >/dev/null 2>&1; then
	ct_arch=$(pct config "$CT_ID" | sed -n 's/^arch: //p')
	if [ -n "$ct_arch" ] && [ "$ct_arch" != "$arch" ]; then
		pct config "$CT_ID" | grep -q 'amp-orbs-proxmox' ||
			die "container $CT_ID ($CT_HOSTNAME) is $ct_arch, not $arch, and was not created by this script; set CT_ID"
		log "Replacing container $CT_ID: it is $ct_arch, but this host is $arch"
		pct stop "$CT_ID" >/dev/null 2>&1 || true
		pct destroy "$CT_ID" --purge
	fi
fi

if [ -z "$CT_ID" ] || ! pct status "$CT_ID" >/dev/null 2>&1; then
	[ -n "$CT_ID" ] || CT_ID=$(pvesh get /cluster/nextid)
	if [ -z "$CT_STORAGE" ]; then
		CT_STORAGE=$(pvesm status --content rootdir --enabled 1 | awk 'NR==2 {print $1}')
		[ -n "$CT_STORAGE" ] || die "no storage allows container disks; set CT_STORAGE"
	fi
	log "Fetching Debian container template"
	pveam update >/dev/null || true
	# Template names end in _<arch>.tar.*; pick the newest for this host's CPU.
	newest() { pveam available --section system | awk -v p="^$1_.*_${arch}[.]tar" '$2 ~ p {print $2}' | sort -V | tail -1; }
	tmpl=$(newest debian-13-standard)
	[ -n "$tmpl" ] || tmpl=$(newest debian-12-standard)
	[ -n "$tmpl" ] || die "no Debian container template for $arch available from pveam"
	pveam list "$TEMPLATE_STORAGE" | grep -q "$tmpl" || pveam download "$TEMPLATE_STORAGE" "$tmpl"

	net="name=eth0,bridge=$PROVIDER_BRIDGE,ip=$PROVIDER_IP"
	[ -n "$PROVIDER_GW" ] && net="$net,gw=$PROVIDER_GW"
	[ -n "$PROVIDER_VLAN" ] && net="$net,tag=$PROVIDER_VLAN"
	log "Creating container $CT_ID ($CT_HOSTNAME) on $CT_STORAGE"
	pct create "$CT_ID" "$TEMPLATE_STORAGE:vztmpl/$tmpl" --hostname "$CT_HOSTNAME" \
		--cores 1 --memory 512 --swap 512 --rootfs "$CT_STORAGE:4" --net0 "$net" \
		--unprivileged 1 --features nesting=1 --onboot 1 \
		--description "Runs amp orb provider for the $POOL pool (amp-orbs-proxmox)"
fi

pct status "$CT_ID" | grep -q running || pct start "$CT_ID"
log "Waiting for the container's network"
for _ in $(seq 60); do
	pct exec "$CT_ID" -- getent hosts ampcode.com >/dev/null 2>&1 && break
	sleep 2
done
pct exec "$CT_ID" -- getent hosts ampcode.com >/dev/null || die "container $CT_ID cannot resolve ampcode.com"

if [ -z "$PVE_API_URL" ]; then
	host_ip=$(ip -4 -o addr show dev "$PROVIDER_BRIDGE" | awk '{print $4}' | cut -d/ -f1 | head -1)
	[ -n "$host_ip" ] || die "this host has no IPv4 address on $PROVIDER_BRIDGE; set PVE_API_URL"
	PVE_API_URL="https://$host_ip:8006"
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 700 "$stage"
# Keep settings from an earlier install, such as the Amp token or ORB_* options.
pct exec "$CT_ID" -- cat /etc/amp-orbs-pve/provider.env >"$stage/old.env" 2>/dev/null || true
if [ -z "$AMP_ORB_PROVIDER_TOKEN" ]; then
	AMP_ORB_PROVIDER_TOKEN=$(sed -n 's/^AMP_ORB_PROVIDER_TOKEN=//p' "$stage/old.env")
fi
{
	echo "AMP_ORB_PROVIDER_TOKEN=$AMP_ORB_PROVIDER_TOKEN"
	echo "PVE_API_URL=$PVE_API_URL"
	cat "$TOKEN_FILE"
	echo "PVE_NODE=$(uname -n | cut -d. -f1)" # the Proxmox node name
	echo "PVE_POOL=$POOL"
	echo "PVE_CA_FILE=/etc/amp-orbs-pve/pve-root-ca.pem"
	if [ -n "$EXTRA_ENV" ]; then printf '%s\n' "$EXTRA_ENV"; fi
} >"$stage/new.env"
managed=$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$stage/new.env" | paste -sd'|')
{
	cat "$stage/new.env"
	grep -E '^[A-Z_]+=' "$stage/old.env" | grep -Ev "^($managed)=" || true
} >"$stage/provider.env"

log "Installing the provider in container $CT_ID"
dest=/root/amp-orbs-pve-install
pct exec "$CT_ID" -- rm -rf "$dest"
pct exec "$CT_ID" -- mkdir -p "$dest/systemd"
for f in dispatch.py amp-orbs-pve install-provider.sh provider.env.example \
	systemd/amp-orb-provider.service systemd/amp-orbs-gc.service systemd/amp-orbs-gc.timer; do
	pct push "$CT_ID" "$repo/provider/$f" "$dest/$f"
done
pct push "$CT_ID" /etc/pve/pve-root-ca.pem "$dest/pve-root-ca.pem"
pct push "$CT_ID" "$stage/provider.env" "$dest/provider.env" --perms 0600
pct exec "$CT_ID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 bash "$dest/install-provider.sh" "$dest/provider.env"
pct exec "$CT_ID" -- rm -rf "$dest"

log "Checking API access from the container"
# pct exec does not search /usr/local/bin, so use the full path.
pct exec "$CT_ID" -- /usr/local/bin/amp-orbs-pve check
