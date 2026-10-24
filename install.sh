#!/usr/bin/env bash
# One-shot installer for Amp self-hosted orbs on Proxmox VE.
#
# Run as root on a Proxmox VE node from a checkout of this repository:
#
#   git clone https://github.com/mariusangelmann/amp-orbs-proxmox
#   cd amp-orbs-proxmox && ./install.sh
#
# It asks for a few settings (or reads them from the environment), then
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
ask BRIDGE "Bridge or SDN vnet for orbs (needs DHCP and internet access)" vmbr0
ask SDN_ZONE "SDN zone of that vnet (localnetwork for a plain bridge)" localnetwork
ask VLAN "VLAN tag for orbs (empty for none)" ""
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

"$here/host/setup-access.sh"

echo "==> Host update status timer"
install -m 0755 "$here/host/host-status.sh" /usr/local/sbin/amp-orbs-host-status
install -m 0644 "$here/host/systemd/amp-orbs-host-status.service" \
	"$here/host/systemd/amp-orbs-host-status.timer" /etc/systemd/system/
echo "POOL=$POOL" >/etc/default/amp-orbs-host-status
systemctl daemon-reload
systemctl enable --now amp-orbs-host-status.timer >/dev/null
/usr/local/sbin/amp-orbs-host-status >/dev/null || echo "warning: the first host status check failed" >&2

if [ "${REBUILD_TEMPLATE:-0}" = 1 ] || ! qm list | awk '{print $2}' | grep -q '^amp-orb-base-'; then
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
  * List orbs:       pct exec <ct id> -- amp-orbs-pve list
EOF
if [ -z "$AMP_ORB_PROVIDER_TOKEN" ]; then
	echo "  * No Amp token yet: rerun with AMP_ORB_PROVIDER_TOKEN=aop_live_... ./install.sh"
fi
