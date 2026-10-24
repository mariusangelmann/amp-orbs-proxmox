#!/usr/bin/env bash
# Record this Proxmox VE node's update status in the orb pool's comment.
#
# The orb provider reads the comment (its token can read the pool, nothing
# more) and warns in the thread's setup log and to the agent in the orb when
# the host needs a reboot or has kernel and hypervisor updates. Run as root
# by the amp-orbs-host-status timer; safe to run by hand.
set -euo pipefail

POOL=${POOL:-amp-orbs}
REFRESH=${REFRESH:-1}                # 0 = use the apt lists as they are

[ "$(id -u)" = 0 ] || { echo "run as root on the Proxmox VE host" >&2; exit 1; }

if [ "$REFRESH" = 1 ]; then
	apt-get update -qq >/dev/null 2>&1 || echo "warning: apt-get update failed; using cached package lists" >&2
fi

running=$(uname -r)
newest=$(find /lib/modules -mindepth 1 -maxdepth 1 -name '*-pve' -printf '%f\n' | sort -V | tail -1)
reboot=""
if [ -n "$newest" ] && [ "$newest" != "$running" ] &&
	[ "$(printf '%s\n%s\n' "$running" "$newest" | sort -V | tail -1)" = "$newest" ]; then
	reboot=$newest
fi

# Packages a full upgrade would install or upgrade.
mapfile -t pending < <(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | awk '/^Inst /{print $2}')
security=()
for pkg in "${pending[@]}"; do
	case "$pkg" in
	proxmox-kernel-* | pve-qemu-kvm | qemu-server | pve-firmware | *-microcode) security+=("$pkg") ;;
	esac
done

security_list=$(printf '%s, ' "${security[@]}")
security_list=${security_list%, }

comment="Amp orbs (amp-orbs-proxmox)
host-status-checked: $(date -u +%Y-%m-%dT%H:%M:%SZ)
host-node: $(hostname)
host-kernel: $running
host-reboot-required: $reboot
host-updates: ${#pending[@]}
host-security-updates: $security_list"
pveum pool modify "$POOL" --comment "$comment"
echo "$comment"
