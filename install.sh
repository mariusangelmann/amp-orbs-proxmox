#!/usr/bin/env bash
# One-shot installer for Amp self-hosted orbs on Proxmox VE.
#
# Run as root on a Proxmox VE node from a checkout of this repository:
#
#   git clone https://github.com/mariusangelmann/amp-orbs-proxmox
#   cd amp-orbs-proxmox && ./install.sh
#
# It asks for a few settings (or reads them from the environment), then
#   0. creates the isolated orb network and its firewall, unless you choose an
#      existing bridge          (host/create-orb-network.sh, host/orb-firewall.sh)
#   1. creates the pool, role, user, and API token   (host/setup-access.sh)
#      and a timer that records host updates          (host/host-status.sh)
#   2. builds the orb VM template                     (host/build-template.sh)
#   3. creates the provider container and starts it   (host/create-provider-ct.sh)
# Rerun it to update; each step is safe to repeat.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

ask() { # ask VAR "question" default
	local var=$1 question=$2 default=${3:-} answer
	if [ -n "${!var:-}" ]; then return; fi
	if [ -t 0 ]; then
		read -r -p "$question [${default}]: " answer
		printf -v "$var" '%s' "${answer:-$default}"
	else
		printf -v "$var" '%s' "$default"
	fi
	export "${var?}"
}

[ "$(id -u)" = 0 ] || { echo "run as root on the Proxmox VE host" >&2; exit 1; }
command -v pveversion >/dev/null || { echo "this is not a Proxmox VE node" >&2; exit 1; }
"$here/host/check-kernel.sh"

default_storage=$(pvesm status --content images --enabled 1 | awk 'NR==2 {print $1}')
cat <<'EOF'
Amp self-hosted orbs on Proxmox VE
Each orb is a VM cloned from a template; pausing hibernates it to disk.
Press Enter to accept a default.

EOF
ask STORAGE "Storage for orb disks" "${default_storage:-local}"
cat <<'NETWORK'

Orb network:
  isolated  a NAT network of their own. Orbs reach the internet but not this host,
            your LAN, your VPN or Tailscale, or each other. Recommended.
  bridge    an existing bridge such as vmbr0. Orbs sit on that network as root
            and can reach and attack everything on it.
NETWORK
ask ORB_NETWORK "Orb network (isolated or bridge)" isolated
case "$ORB_NETWORK" in
isolated)
	export VNET=${VNET:-ampnet} ZONE=${ZONE:-amporbs}
	export BRIDGE=$VNET SDN_ZONE=$ZONE VLAN=""
	;;
bridge)
	ask BRIDGE "Bridge or SDN vnet for orbs (needs DHCP and internet access)" vmbr0
	ask SDN_ZONE "SDN zone of that vnet (localnetwork for a plain bridge)" localnetwork
	ask VLAN "VLAN tag for orbs (empty for none)" ""
	echo "warning: orbs will be on '$BRIDGE' with no isolation; see docs/security.md" >&2
	;;
*) echo "ORB_NETWORK must be 'isolated' or 'bridge'" >&2; exit 1 ;;
esac
ask PROVIDER_BRIDGE "Bridge for the provider container (must reach this host and ampcode.com)" vmbr0
ask CORES "vCPUs per orb" 2
ask MEMORY_MB "RAM per orb in MB" 4096
ask DISK_SIZE "Disk per orb (thin-provisioned)" 32G
if [ -z "${AMP_ORB_PROVIDER_TOKEN:-}" ] && [ -t 0 ]; then
	echo
	echo "Create a provider in Amp: Settings -> Orbs -> Add Orb Provider, and copy its token."
	read -r -s -p "Amp orb provider token (aop_live_..., empty to set later): " AMP_ORB_PROVIDER_TOKEN
	echo
fi
export AMP_ORB_PROVIDER_TOKEN=${AMP_ORB_PROVIDER_TOKEN:-}
export POOL=${POOL:-amp-orbs}

if [ "$ORB_NETWORK" = isolated ]; then
	"$here/host/create-orb-network.sh"
	echo "==> Orb firewall"
	command -v nft >/dev/null || { apt-get update -qq && apt-get install -y -qq nftables; }
	install -m 0755 "$here/host/orb-firewall.sh" /usr/local/sbin/amp-orbs-firewall
	install -m 0644 "$here/host/systemd/amp-orbs-firewall.service" /etc/systemd/system/
	echo "VNET=$VNET" >/etc/default/amp-orbs-firewall
	systemctl daemon-reload
	systemctl enable amp-orbs-firewall.service >/dev/null
	systemctl restart amp-orbs-firewall.service
	require_firewall=1
else
	if [ -f /etc/default/amp-orbs-firewall ]; then
		systemctl disable --now amp-orbs-firewall.service >/dev/null 2>&1 || true
		rm -f /etc/default/amp-orbs-firewall
	fi
	require_firewall=0
fi
export EXTRA_ENV="${EXTRA_ENV:+$EXTRA_ENV
}ORB_REQUIRE_FIREWALL=$require_firewall"

"$here/host/setup-access.sh"

echo "==> Host update status timer"
install -m 0755 "$here/host/host-status.sh" /usr/local/sbin/amp-orbs-host-status
install -m 0644 "$here/host/systemd/amp-orbs-host-status.service" \
	"$here/host/systemd/amp-orbs-host-status.timer" /etc/systemd/system/
echo "POOL=$POOL" >/etc/default/amp-orbs-host-status
systemctl daemon-reload
systemctl enable --now amp-orbs-host-status.timer >/dev/null
/usr/local/sbin/amp-orbs-host-status >/dev/null || echo "warning: the first host status check failed" >&2

base=""
for id in $(qm list | awk '$2 ~ /^amp-orb-base-/ {print $2, $1}' | sort | cut -d' ' -f2); do
	qm config "$id" | grep -q '^template: 1' && base=$id # newest finished template
done
if [ -n "$base" ] && ! qm config "$base" | grep -Eq "^net0:.*bridge=$BRIDGE(,|$)"; then
	echo "==> The newest base template uses another network; building a new one"
	REBUILD_TEMPLATE=1
fi
if [ "${REBUILD_TEMPLATE:-0}" = 1 ] || [ -z "$base" ]; then
	"$here/host/build-template.sh"
else
	echo "==> A base template exists; skipping the build (REBUILD_TEMPLATE=1 builds a new one)"
fi

"$here/host/create-provider-ct.sh"

cat <<EOF

Done. Next:
  * In Amp, start a thread with Orb -> Self-Hosted -> your provider, or run
      amp -ox "hello" --orb-provider <provider name>
  * Provider logs:   pct exec \$(pct list | awk '/amp-orb-provider/ {print \$1}') -- journalctl -fu amp-orb-provider
  * List orbs:       pct exec <ct id> -- /usr/local/bin/amp-orbs-pve list
EOF
if [ -z "$AMP_ORB_PROVIDER_TOKEN" ]; then
	echo "  * No Amp token yet: rerun with AMP_ORB_PROVIDER_TOKEN=aop_live_... ./install.sh"
fi
