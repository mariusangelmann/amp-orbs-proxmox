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
#
# Once an install works (the provider container passes `amp-orbs-pve check`),
# rerunning it configures instead: it shows the current settings, asks what to
# change, and reruns only the steps that change needs. The Proxmox API token is
# kept, and so is the Amp token unless you enter a new one. Run
# `./install.sh --reinstall` to run every step again; each is safe to repeat.
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

reinstall=0
case "${1:-}" in
"") ;;
--reinstall) reinstall=1 ;;
*) echo "usage: $0 [--reinstall]" >&2; exit 1 ;;
esac

[ "$(id -u)" = 0 ] || { echo "run as root on the Proxmox VE host" >&2; exit 1; }
command -v pveversion >/dev/null || { echo "this is not a Proxmox VE node" >&2; exit 1; }
"$here/host/check-kernel.sh"

export CT_HOSTNAME=${CT_HOSTNAME:-amp-orb-provider}
TOKEN_FILE=${TOKEN_FILE:-/root/.amp-orbs-pve-token}

newest_template() { # newest finished amp-orb-base-* template
	local id base=""
	for id in $(qm list | awk '$2 ~ /^amp-orb-base-/ {print $2, $1}' | sort | cut -d' ' -f2); do
		qm config "$id" | grep -q '^template: 1' && base=$id
	done
	echo "$base"
}

ask_network() { # ask_network [mode [bridge zone vlan]] (defaults)
	cat <<'NETWORK'

Orb network:
  isolated  a NAT network of their own. Orbs reach the internet but not this host,
            your LAN, your VPN or Tailscale, or each other. Recommended.
  bridge    an existing bridge such as vmbr0. Orbs sit on that network as root
            and can reach and attack everything on it.
NETWORK
	ask ORB_NETWORK "Orb network (isolated or bridge)" "${1:-isolated}"
	case "$ORB_NETWORK" in
	isolated)
		export VNET=${VNET:-ampnet} ZONE=${ZONE:-amporbs}
		export BRIDGE=$VNET SDN_ZONE=$ZONE VLAN=""
		;;
	bridge)
		ask BRIDGE "Bridge or SDN vnet for orbs (needs DHCP and internet access)" "${2:-vmbr0}"
		ask SDN_ZONE "SDN zone of that vnet (localnetwork for a plain bridge)" "${3:-localnetwork}"
		ask VLAN "VLAN tag for orbs (empty for none)" "${4:-}"
		echo "warning: orbs will be on '$BRIDGE' with no isolation; see docs/security.md" >&2
		;;
	*) echo "ORB_NETWORK must be 'isolated' or 'bridge'" >&2; exit 1 ;;
	esac
}

setup_network() {
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
	elif [ -f /etc/default/amp-orbs-firewall ]; then
		systemctl disable --now amp-orbs-firewall.service >/dev/null 2>&1 || true
		rm -f /etc/default/amp-orbs-firewall
	fi
}

provider_env() { # managed provider.env lines, passed to create-provider-ct.sh
	local require_firewall=0
	[ "$ORB_NETWORK" = isolated ] && require_firewall=1
	export EXTRA_ENV="${EXTRA_ENV:+$EXTRA_ENV
}ORB_REQUIRE_FIREWALL=$require_firewall
ORB_CORES=$CORES
ORB_MEMORY_MB=$MEMORY_MB${ORB_MAX_RUNNING:+
ORB_MAX_RUNNING=$ORB_MAX_RUNNING}"
}

# Earlier versions let orbs balloon down to 1 GB. Proxmox starts a VM at that
# minimum, and Amp sizes an orb's command memory limit from the RAM it sees at
# boot, so such orbs ran out of memory with the host's RAM free. Give this
# node's templates and orbs in the pool all of their RAM; hibernated orbs get it
# when they resume.
disable_ballooning() {
	local id conf memory balloon skiplock
	ballooning_fixed=0
	for id in $(pvesh get /pools --poolid "$POOL" --output-format json | perl -MJSON::PP -0ne '
		for my $p (@{ decode_json($_) }) {
			print "$_->{vmid}\n" for grep { $_->{type} eq "qemu" } @{ $p->{members} || [] }
		}'); do
		conf=$(qm config "$id" 2>/dev/null) || continue # on another node
		memory=$(sed -n 's/^memory: //p' <<<"$conf")
		balloon=$(sed -n 's/^balloon: //p' <<<"$conf")
		[ -n "$memory" ] && [ -n "$balloon" ] && [ "$balloon" != 0 ] && [ "$balloon" -lt "$memory" ] || continue
		skiplock=()
		case "$(sed -n 's/^lock: //p' <<<"$conf")" in
		"") ;;
		suspended) skiplock=(--skiplock 1) ;; # hibernated: same RAM, only the balloon target changes
		*) echo "warning: VM $id is locked; set its balloon to $memory later with qm set" >&2; continue ;;
		esac
		qm set "$id" --balloon "$memory" "${skiplock[@]}" >/dev/null
		ballooning_fixed=$((ballooning_fixed + 1))
	done
	[ "$ballooning_fixed" = 0 ] || echo "==> Turned off ballooning for $ballooning_fixed orb VMs and templates"
}

ask_amp_token() { # ask_amp_token "prompt" ["hint"]
	if [ -z "${AMP_ORB_PROVIDER_TOKEN:-}" ] && [ -t 0 ]; then
		echo
		[ -z "${2:-}" ] || echo "$2"
		read -r -s -p "$1" AMP_ORB_PROVIDER_TOKEN
		echo
	fi
	export AMP_ORB_PROVIDER_TOKEN=${AMP_ORB_PROVIDER_TOKEN:-}
}

# An install worked if its provider container passes `amp-orbs-pve check`
# (API access, permissions, kernel, and a base template).
ct=$(pct list | awk -v h="$CT_HOSTNAME" 'NR>1 && $NF==h {print $1; exit}')
installed=0
if [ "$reinstall" = 0 ] && [ -n "$ct" ] && [ -s "$TOKEN_FILE" ] &&
	pct status "$ct" | grep -q running &&
	pct exec "$ct" -- /usr/local/bin/amp-orbs-pve check >/dev/null 2>&1; then
	installed=1
fi

if [ "$installed" = 1 ]; then
	# Read the current settings from what is installed.
	base=$(newest_template)
	tconf=$(qm config "$base")
	penv=$(pct exec "$ct" -- grep -E '^(PVE_POOL|ORB_CORES|ORB_MEMORY_MB|ORB_MAX_RUNNING)=' \
		/etc/amp-orbs-pve/provider.env || true)
	penv_get() { sed -n "s/^$1=//p" <<<"$penv"; }
	vnet_zone() { pvesh get "/cluster/sdn/vnets/$1" --output-format json 2>/dev/null |
		sed -n 's/.*"zone":"\([^"]*\)".*/\1/p'; }

	cur_bridge=$(sed -n 's/^net0:.*[:,]bridge=\([^,]*\).*/\1/p' <<<"$tconf")
	cur_vlan=$(sed -n 's/^net0:.*,tag=\([^,]*\).*/\1/p' <<<"$tconf")
	cur_zone=$(vnet_zone "$cur_bridge")
	cur_network=bridge
	if [ "$(sed -n 's/^VNET=//p' /etc/default/amp-orbs-firewall 2>/dev/null)" = "$cur_bridge" ]; then
		cur_network=isolated
	fi
	[ -n "$cur_zone" ] || cur_zone=localnetwork
	cur_storage=$(sed -n 's/^scsi0: \([^:]*\):.*/\1/p' <<<"$tconf")
	cur_disk=$(sed -n 's/^scsi0:.*,size=\([^,]*\).*/\1/p' <<<"$tconf")
	cur_cores=$(penv_get ORB_CORES)
	[ -n "$cur_cores" ] || cur_cores=$(sed -n 's/^cores: //p' <<<"$tconf")
	cur_memory=$(penv_get ORB_MEMORY_MB)
	[ -n "$cur_memory" ] || cur_memory=$(sed -n 's/^memory: //p' <<<"$tconf")
	cur_max=$(penv_get ORB_MAX_RUNNING)
	export POOL=${POOL:-$(penv_get PVE_POOL)}
	POOL=${POOL:-amp-orbs}
	# The container keeps its network; create-provider-ct.sh needs it for the API address.
	PROVIDER_BRIDGE=$(pct config "$ct" | sed -n 's/^net0:.*[:,]bridge=\([^,]*\).*/\1/p')
	export CT_ID=$ct PROVIDER_BRIDGE

	cat <<EOF
Amp self-hosted orbs are already installed on this host (provider container $ct).
Current settings:
  Orb network       $cur_network ($cur_bridge${cur_vlan:+, VLAN $cur_vlan})
  Orb disk storage  $cur_storage
  Orb size          $cur_cores vCPUs, $cur_memory MB RAM, $cur_disk disk
  Max running orbs  ${cur_max:-0} (0 = no limit)
Press Enter to keep a value. ./install.sh --reinstall runs the full install again.
EOF
	if [ "$cur_network" = isolated ]; then
		VNET=${VNET:-$cur_bridge} ZONE=${ZONE:-$cur_zone}
		ask_network isolated
	else
		ask_network bridge "$cur_bridge" "$cur_zone" "$cur_vlan"
	fi
	ask STORAGE "Storage for orb disks" "$cur_storage"
	ask CORES "vCPUs per orb" "$cur_cores"
	ask MEMORY_MB "RAM per orb in MB" "$cur_memory"
	ask DISK_SIZE "Disk per orb (thin-provisioned)" "$cur_disk"
	ask ORB_MAX_RUNNING "Max running orbs (0 = no limit)" "${cur_max:-0}"
	ask_amp_token "New Amp orb provider token (empty keeps the current one): "

	disable_ballooning
	network_changed=0 storage_changed=0 template_changed=0 provider_changed=0
	# The provider predates the fix too: update its dispatch program.
	[ "$ballooning_fixed" = 0 ] || provider_changed=1
	[ "$ORB_NETWORK|$BRIDGE|$VLAN" = "$cur_network|$cur_bridge|$cur_vlan" ] || network_changed=1
	[ "$network_changed" = 1 ] || [ "$SDN_ZONE" = "$cur_zone" ] || network_changed=1
	[ "$STORAGE" = "$cur_storage" ] || storage_changed=1
	if [ "$network_changed" = 1 ] || [ "$storage_changed" = 1 ] || [ "$DISK_SIZE" != "$cur_disk" ]; then
		template_changed=1
	fi
	if [ "$template_changed" = 1 ] || [ -n "$AMP_ORB_PROVIDER_TOKEN" ] ||
		[ "$CORES|$MEMORY_MB|$ORB_MAX_RUNNING" != "$cur_cores|$cur_memory|${cur_max:-0}" ]; then
		provider_changed=1
	fi
	if [ "$provider_changed" = 0 ]; then
		echo
		echo "Nothing changed. To update the provider after git pull, run host/create-provider-ct.sh."
		exit 0
	fi

	[ "$network_changed" = 0 ] || setup_network
	# New storage or network needs permissions for the provider's existing
	# user; setup-access.sh keeps the API token because $TOKEN_FILE exists.
	if [ "$network_changed" = 1 ] || [ "$storage_changed" = 1 ]; then
		"$here/host/setup-access.sh"
	fi
	if [ "$template_changed" = 1 ]; then
		echo "==> Building a new base template; existing orbs keep theirs"
		"$here/host/build-template.sh"
	fi
	provider_env
	"$here/host/create-provider-ct.sh"
	echo
	echo "Done. New orbs use the new settings; running orbs keep theirs."
	exit 0
fi

default_storage=$(pvesm status --content images --enabled 1 | awk 'NR==2 {print $1}')
cat <<'EOF'
Amp self-hosted orbs on Proxmox VE
Each orb is a VM cloned from a template; pausing hibernates it to disk.
Press Enter to accept a default.

EOF
ask STORAGE "Storage for orb disks" "${default_storage:-local}"
ask_network
ask PROVIDER_BRIDGE "Bridge for the provider container (must reach this host and ampcode.com)" vmbr0
ask CORES "vCPUs per orb" 2
ask MEMORY_MB "RAM per orb in MB" 4096
ask DISK_SIZE "Disk per orb (thin-provisioned)" 32G
ask_amp_token "Amp orb provider token (aop_live_..., empty to set later): " \
	"Create a provider in Amp: Settings -> Orbs -> Add Orb Provider, and copy its token."
export POOL=${POOL:-amp-orbs}

setup_network
provider_env

"$here/host/setup-access.sh"

echo "==> Host update status timer"
install -m 0755 "$here/host/host-status.sh" /usr/local/sbin/amp-orbs-host-status
install -m 0644 "$here/host/systemd/amp-orbs-host-status.service" \
	"$here/host/systemd/amp-orbs-host-status.timer" /etc/systemd/system/
echo "POOL=$POOL" >/etc/default/amp-orbs-host-status
systemctl daemon-reload
systemctl enable --now amp-orbs-host-status.timer >/dev/null
/usr/local/sbin/amp-orbs-host-status >/dev/null || echo "warning: the first host status check failed" >&2

base=$(newest_template)
if [ -n "$base" ] && ! qm config "$base" | grep -Eq "^net0:.*bridge=$BRIDGE(,|$)"; then
	echo "==> The newest base template uses another network; building a new one"
	REBUILD_TEMPLATE=1
fi
if [ "${REBUILD_TEMPLATE:-0}" = 1 ] || [ -z "$base" ]; then
	"$here/host/build-template.sh"
else
	echo "==> A base template exists; skipping the build (REBUILD_TEMPLATE=1 builds a new one)"
fi
disable_ballooning

"$here/host/create-provider-ct.sh"

cat <<EOF

Done. Next:
  * In Amp, start a thread with Orb -> Self-Hosted -> your provider, or run
      amp -ox "hello" --orb-provider <provider name>
  * Provider logs:   pct exec \$(pct list | awk '/amp-orb-provider/ {print \$1}') -- journalctl -fu amp-orb-provider
  * List orbs:       pct exec <ct id> -- /usr/local/bin/amp-orbs-pve list
  * Change settings later: rerun ./install.sh
EOF
if [ -z "$AMP_ORB_PROVIDER_TOKEN" ]; then
	echo "  * No Amp token yet: rerun with AMP_ORB_PROVIDER_TOKEN=aop_live_... ./install.sh"
fi
