#!/usr/bin/env bash
# Refuse to continue on a Proxmox VE host whose running kernel lets a KVM
# guest escape to the host. Orbs run code from AI agents and repositories,
# so treat every orb as an untrusted guest.
#
# CVE-2026-99999 "PwnEscape" (PSA-2026-00068-1) is fixed in
# proxmox-kernel-7.0.14-24-pve. Proxmox does not patch EOL kernel series,
# so every older kernel is refused; newer ones include the fix. Keep this in
# sync with FIRST_FIXED_KERNEL in
# provider/dispatch.py, which repeats the check before every orb start.
#
# Usage: check-kernel.sh [release]   (default: uname -r)
set -euo pipefail

release=${1:-$(uname -r)}
fail() {
	printf 'error: refusing to continue: %s.\n' "$1" >&2
	printf '       This kernel allows a KVM guest to escape to the host (CVE-2026-99999, PwnEscape).\n' >&2
	printf '       Install proxmox-kernel-7.0.14-24-pve or later, reboot, and run this again.\n' >&2
	exit 1
}

[[ $release =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)-pve$ ]] ||
	fail "kernel '$release' is not a recognized Proxmox VE kernel"
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]} abi=${BASH_REMATCH[4]}

# Compare (major, minor, patch, abi) with 7.0.14-24 component by component.
for pair in "$major 7" "$minor 0" "$patch 14" "$abi 24"; do
	read -r have want <<<"$pair"
	((have > want)) && break
	((have < want)) && fail "kernel $release is older than 7.0.14-24-pve"
done
echo "==> Kernel $release is not affected by CVE-2026-99999"
