#!/usr/bin/env bash
# Install the Amp orb provider on a Debian or Ubuntu machine (the provider
# container that host/create-provider-ct.sh creates, or any small VM that
# can reach the Proxmox API and ampcode.com).
#
# Usage: install-provider.sh [path/to/provider.env]
#
# Installs the Amp CLI for a dedicated `amp-orbs` user, the dispatch program
# to /opt/amp-orbs-pve, the config to /etc/amp-orbs-pve/provider.env, and
# the amp-orb-provider service plus a daily snapshot cleanup timer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
env_src=${1:-}
conf_dir=/etc/amp-orbs-pve
home=/var/lib/amp-orbs

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

echo "==> Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends python3 curl ca-certificates bash >/dev/null

echo "==> User amp-orbs"
id amp-orbs >/dev/null 2>&1 || useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin amp-orbs

echo "==> Amp CLI"
if [ ! -x "$home/.local/bin/amp" ] && [ ! -x "$home/.amp/bin/amp" ]; then
	su -s /bin/bash amp-orbs -c 'curl -fsSL https://ampcode.com/install.sh | bash' </dev/null
fi
amp_bin=""
for candidate in "$home/.local/bin/amp" "$home/.amp/bin/amp"; do
	if [ -x "$candidate" ]; then amp_bin=$candidate; break; fi
done
[ -n "$amp_bin" ] || { echo "the Amp CLI did not install" >&2; exit 1; }
ln -sf "$amp_bin" /usr/local/bin/amp

echo "==> Dispatch program"
install -d /opt/amp-orbs-pve
install -m 0755 "$here/dispatch.py" /opt/amp-orbs-pve/dispatch.py
install -m 0755 "$here/amp-orbs-pve" /usr/local/bin/amp-orbs-pve

echo "==> Config"
install -d -m 0750 -g amp-orbs "$conf_dir"
if [ -n "$env_src" ]; then
	install -m 0640 -g amp-orbs "$env_src" "$conf_dir/provider.env"
elif [ ! -e "$conf_dir/provider.env" ]; then
	install -m 0640 -g amp-orbs "$here/provider.env.example" "$conf_dir/provider.env"
	echo "    edit $conf_dir/provider.env before starting the service"
fi
[ -e "$here/pve-root-ca.pem" ] && install -m 0644 "$here/pve-root-ca.pem" "$conf_dir/pve-root-ca.pem"

echo "==> Services"
install -m 0644 "$here"/systemd/amp-orb-provider.service "$here"/systemd/amp-orbs-gc.service \
	"$here"/systemd/amp-orbs-gc.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable amp-orb-provider.service amp-orbs-gc.timer >/dev/null

if grep -q '^AMP_ORB_PROVIDER_TOKEN=aop_' "$conf_dir/provider.env"; then
	systemctl restart amp-orb-provider.service amp-orbs-gc.timer
	echo "==> Started. Logs: journalctl -fu amp-orb-provider"
else
	echo "==> Installed. Set AMP_ORB_PROVIDER_TOKEN in $conf_dir/provider.env, then:"
	echo "    systemctl start amp-orb-provider amp-orbs-gc.timer"
fi
