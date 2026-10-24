#!/usr/bin/env bash
# Build a Proxmox VE VM template from the Amp orb OCI image.
#
# Run as root on a Proxmox VE node. The image's root filesystem is unpacked
# into a fresh disk, a kernel, systemd, GRUB, and the QEMU guest agent are
# added, and the disk is imported into a new VM that is converted to a
# template named amp-orb-base-<timestamp> in the orb pool.
#
# Every setting can be overridden through the environment; see the defaults
# below. Rerun to pick up a newer Amp image: new orbs use the newest
# template and existing orbs keep theirs.
set -euo pipefail

IMAGE=${IMAGE:-us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest}
STORAGE=${STORAGE:-local}            # VM disk storage
POOL=${POOL:-amp-orbs}
BRIDGE=${BRIDGE:-vmbr0}
VLAN=${VLAN:-}                       # optional VLAN tag
FIREWALL=${FIREWALL:-0}              # 1 = enable the PVE firewall for orbs
FIREWALL_GROUP=${FIREWALL_GROUP:-amp-orbs}  # security group applied to orbs
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-4096}
BALLOON_MB=${BALLOON_MB:-1024}       # the host may reclaim RAM down to this
DISK_SIZE=${DISK_SIZE:-32G}          # thin-provisioned
CPU_TYPE=${CPU_TYPE:-host}
KERNEL_PKG=${KERNEL_PKG:-linux-image-cloud-amd64}
VMID=${VMID:-}                       # default: first free ID from 9000
WORKDIR=${WORKDIR:-/var/tmp/amp-orb-build}

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root on the Proxmox VE host"
command -v qm >/dev/null || die "qm not found; run this on a Proxmox VE node"
"$(dirname "$0")/check-kernel.sh"
pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "storage '$STORAGE' does not exist"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge '$BRIDGE' does not exist"
pvesh get "/pools/$POOL" >/dev/null 2>&1 || die "pool '$POOL' does not exist; run host/setup-access.sh first"

need_pkgs=()
command -v skopeo >/dev/null || need_pkgs+=(skopeo)
command -v umoci >/dev/null || need_pkgs+=(umoci)
if [ ${#need_pkgs[@]} -gt 0 ]; then
	log "Installing ${need_pkgs[*]}"
	apt-get update -qq && apt-get install -y -qq "${need_pkgs[@]}"
fi

mkdir -p "$WORKDIR"
avail_gb=$(df -BG --output=avail "$WORKDIR" | tail -1 | tr -dc 0-9)
[ "$avail_gb" -ge 15 ] || die "need about 15 GB free in $WORKDIR (have ${avail_gb} GB); set WORKDIR"

oci="$WORKDIR/oci"
rootfs="$WORKDIR/rootfs"
raw="$WORKDIR/disk.raw"
mnt="$WORKDIR/mnt"
loop=""

cleanup() {
	set +e
	for m in dev/pts dev proc sys run; do mountpoint -q "$mnt/$m" && umount -l "$mnt/$m"; done
	mountpoint -q "$mnt" && umount "$mnt"
	[ -n "$loop" ] && losetup -d "$loop"
	rm -rf "$oci" "$rootfs" "$raw" "$mnt"
}
cleanup # leftovers from an interrupted run
trap cleanup EXIT

log "Pulling $IMAGE (pin a digest with IMAGE=...@sha256:... to build exactly that image)"
skopeo copy --override-os linux --override-arch amd64 "docker://$IMAGE" "oci:$oci:orb"
digest=$(skopeo inspect --format '{{.Digest}}' "oci:$oci:orb")
skopeo inspect --config "oci:$oci:orb" >"$WORKDIR/config.json"

log "Unpacking root filesystem"
umoci raw unpack --image "$oci:orb" "$rootfs"

log "Creating $DISK_SIZE disk"
truncate -s "$DISK_SIZE" "$raw"
printf 'label: dos\nstart=2048, type=83, bootable\n' | sfdisk -q "$raw"
loop=$(losetup -fP --show "$raw")
mkfs.ext4 -q -L amp-orb "${loop}p1"
mkdir -p "$mnt"
mount "${loop}p1" "$mnt"
cp -a "$rootfs/." "$mnt/"
rm -rf "$rootfs"

# The OCI config's environment (PATH with /opt/git and /opt/amp-wayland,
# LD_LIBRARY_PATH, NODE_OPTIONS, ...) only exists in container runtimes.
# Recreate it for login shells and for the bootstrap unit.
mkdir -p "$mnt/etc/amp-orb" "$mnt/etc/systemd/system.conf.d"
perl -MJSON::PP -e '
	local $/; my $c = decode_json(<STDIN>);
	for (@{ $c->{config}{Env} || [] }) { print "$_\n" }
' <"$WORKDIR/config.json" >"$mnt/etc/amp-orb/image.env"
sed -e 's/"/\\"/g' -e 's/^\([^=]*\)=\(.*\)$/export \1="\2"/' \
	"$mnt/etc/amp-orb/image.env" >"$mnt/etc/profile.d/00-amp-orb-image.sh"
image_path=$(sed -n 's/^PATH=//p' "$mnt/etc/amp-orb/image.env")
printf '[Manager]\nDefaultEnvironment="PATH=%s"\n' "$image_path" \
	>"$mnt/etc/systemd/system.conf.d/amp-orb.conf"

# The chroot runs the image's own programs as root on this host, so this
# trusts the image (see docs/security.md). Give it an empty /run rather than
# the host's, which holds the sockets of the host's systemd and D-Bus.
for m in dev dev/pts proc sys; do mkdir -p "$mnt/$m"; mount --bind "/$m" "$mnt/$m"; done
mkdir -p "$mnt/run"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$mnt/run"
rm -f "$mnt/etc/resolv.conf"
cp /etc/resolv.conf "$mnt/etc/resolv.conf"

log "Installing kernel, systemd, GRUB, and the guest agent"
cat >"$mnt/tmp/provision.sh" <<PROVISION
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	$KERNEL_PKG systemd-sysv systemd-resolved systemd-timesyncd udev dbus kmod \
	grub-pc qemu-guest-agent iproute2 e2fsprogs sudo
rm -f /usr/sbin/policy-rc.d

id user >/dev/null || { echo "the image has no 'user' account" >&2; exit 1; }
sudo -l -U user | grep -q NOPASSWD || echo 'user ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-user

cat > /etc/fstab <<'EOF'
LABEL=amp-orb / ext4 defaults,discard,errors=remount-ro 0 1
EOF

cat > /etc/systemd/network/20-orb.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
systemctl enable systemd-networkd systemd-resolved systemd-timesyncd

cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR=amp-orb
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=LABEL=amp-orb console=tty0 console=ttyS0,115200"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
EOF
grub-install --target=i386-pc --modules="part_msdos ext2" $loop
update-grub

# Let Amp's per-user services run without a login session.
mkdir -p /var/lib/systemd/linger
touch /var/lib/systemd/linger/user

# Every clone generates its own machine ID (and DHCP client ID) on first boot.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
echo amp-orb > /etc/hostname
apt-get clean
rm -rf /var/lib/apt/lists/*
PROVISION
chroot "$mnt" /bin/bash /tmp/provision.sh
rm -f "$mnt/tmp/provision.sh"
ln -sf /run/systemd/resolve/stub-resolv.conf "$mnt/etc/resolv.conf"

for m in dev/pts dev proc sys run; do umount -l "$mnt/$m"; done
umount "$mnt"
e2fsck -fy "${loop}p1" >/dev/null || [ $? -le 1 ]
losetup -d "$loop"
loop=""

if [ -z "$VMID" ]; then
	VMID=9000
	while qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1; do
		VMID=$((VMID + 1))
	done
fi
name="amp-orb-base-$(date -u +%Y%m%d%H%M)"
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

net="virtio,bridge=$BRIDGE,firewall=$FIREWALL"
[ -n "$VLAN" ] && net="$net,tag=$VLAN"

disk_opts="discard=on,ssd=1,iothread=1"
storage_type=$(pvesm status --storage "$STORAGE" | awk 'NR==2 {print $2}')
case "$storage_type" in
	dir | nfs | cifs | glusterfs) disk_opts="$disk_opts,format=qcow2" ;; # qcow2 enables linked clones
esac

log "Creating template $name (VMID $VMID) on $STORAGE"
qm create "$VMID" --name "$name" --pool "$POOL" \
	--description "managed-by: amp-orbs-proxmox
image: $IMAGE
digest: $digest
created: $created" \
	--ostype l26 --machine q35 --cpu "$CPU_TYPE" --cores "$CORES" \
	--memory "$MEMORY_MB" --balloon "$BALLOON_MB" \
	--agent enabled=1,fstrim_cloned_disks=1 --scsihw virtio-scsi-single \
	--net0 "$net" --serial0 socket --onboot 0
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$raw,$disk_opts" --boot order=scsi0 >/dev/null
if [ "$FIREWALL" = 1 ]; then
	# Clones copy this file, so every orb gets the rules (docs/security.md).
	group_rule=""
	if grep -q "^\[group $FIREWALL_GROUP\]" /etc/pve/firewall/cluster.fw 2>/dev/null; then
		group_rule="GROUP $FIREWALL_GROUP"
	else
		echo "warning: security group '$FIREWALL_GROUP' not found in cluster.fw; orbs get no extra rules" >&2
	fi
	printf '[OPTIONS]\nenable: 1\n\n[RULES]\n%s\n' "$group_rule" >"/etc/pve/firewall/$VMID.fw"
fi
qm template "$VMID"

log "Done: template $name (VMID $VMID) from $IMAGE@$digest"
