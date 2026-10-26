#!/usr/bin/env bash
# Create the pool, role, user, and API token the orb provider uses.
#
# Run as root on a Proxmox VE node. Safe to rerun. The token secret is
# written to $TOKEN_FILE (mode 0600) because Proxmox shows it only once;
# rerunning keeps an existing token unless ROTATE=1.
set -euo pipefail

POOL=${POOL:-amp-orbs}
STORAGE=${STORAGE:-local}
STATE_STORAGE=${STATE_STORAGE:-}     # only if hibernation state goes elsewhere
BRIDGE=${BRIDGE:-vmbr0}              # Linux bridge or SDN vnet the orbs use
SDN_ZONE=${SDN_ZONE:-localnetwork}   # the vnet's zone; localnetwork for plain bridges
ROLE=${ROLE:-AmpOrbs}
PVE_USER=${PVE_USER:-amp-orbs@pve}
TOKEN_NAME=${TOKEN_NAME:-provider}
TOKEN_FILE=${TOKEN_FILE:-/root/.amp-orbs-pve-token}
ROTATE=${ROTATE:-0}

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root on the Proxmox VE host"
command -v pveum >/dev/null || die "pveum not found; run this on a Proxmox VE node"

major=$(pveversion | sed -n 's|^pve-manager/\([0-9]*\).*|\1|p')
[ "${major:-0}" -ge 8 ] || die "Proxmox VE 8 or later is required"
if [ "$major" -ge 9 ]; then
	agent_priv="VM.GuestAgent.Unrestricted VM.GuestAgent.Audit"
else
	agent_priv="VM.Monitor"
fi
privs="VM.Allocate VM.Clone VM.Audit VM.PowerMgmt VM.Config.Disk VM.Config.CPU \
VM.Config.Memory VM.Config.Options $agent_priv Datastore.AllocateSpace Datastore.Audit \
SDN.Use Pool.Audit"
privs=$(echo "$privs" | tr -s ' ' ',')

log "Pool $POOL"
pvesh get "/pools/$POOL" >/dev/null 2>&1 || pveum pool add "$POOL" --comment "Amp orbs"

log "Role $ROLE"
if pveum role list --output-format json | grep -q "\"roleid\":\"$ROLE\""; then
	pveum role modify "$ROLE" --privs "$privs"
else
	pveum role add "$ROLE" --privs "$privs"
fi

# Read-only node access so the provider can verify the running kernel
# before it starts any orb (see host/check-kernel.sh).
log "Role ${ROLE}NodeAudit"
if pveum role list --output-format json | grep -q "\"roleid\":\"${ROLE}NodeAudit\""; then
	pveum role modify "${ROLE}NodeAudit" --privs Sys.Audit
else
	pveum role add "${ROLE}NodeAudit" --privs Sys.Audit
fi

log "User $PVE_USER"
pveum user list --output-format json | grep -q "\"userid\":\"$PVE_USER\"" ||
	pveum user add "$PVE_USER" --comment "Amp orb provider"

log "Permissions"
pveum acl modify "/pool/$POOL" --users "$PVE_USER" --roles "$ROLE"
for s in $STORAGE $STATE_STORAGE; do
	pveum acl modify "/storage/$s" --users "$PVE_USER" --roles "$ROLE"
done
pveum acl modify "/sdn/zones/$SDN_ZONE/$BRIDGE" --users "$PVE_USER" --roles "$ROLE"
# Only this node: Sys.Audit also shows every user's task logs and the node report.
pveum acl delete /nodes --users "$PVE_USER" --roles "${ROLE}NodeAudit" 2>/dev/null || true
# Earlier versions granted it on /nodes/<full host name>, which is not a node.
[ "$(hostname)" = "$(uname -n | cut -d. -f1)" ] ||
	pveum acl delete "/nodes/$(hostname)" --users "$PVE_USER" --roles "${ROLE}NodeAudit" 2>/dev/null || true
# Proxmox names the node after the short host name (uname -n up to the first dot).
pveum acl modify "/nodes/$(uname -n | cut -d. -f1)" --users "$PVE_USER" --roles "${ROLE}NodeAudit"

log "API token $PVE_USER!$TOKEN_NAME"
has_token() { pveum user token list "$PVE_USER" --output-format json | grep -q "\"tokenid\":\"$TOKEN_NAME\""; }
if has_token && { [ "$ROTATE" = 1 ] || [ ! -s "$TOKEN_FILE" ]; }; then
	pveum user token remove "$PVE_USER" "$TOKEN_NAME"
fi
if ! has_token; then
	# privsep=0: the token has exactly the user's permissions above.
	secret=$(pveum user token add "$PVE_USER" "$TOKEN_NAME" --privsep 0 \
		--comment "amp orb provider" --output-format json |
		sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
	[ -n "$secret" ] || die "could not read the new token secret"
	(umask 077 && printf 'PVE_TOKEN_ID=%s!%s\nPVE_TOKEN_SECRET=%s\n' \
		"$PVE_USER" "$TOKEN_NAME" "$secret" >"$TOKEN_FILE")
	log "Token written to $TOKEN_FILE"
else
	log "Keeping existing token from $TOKEN_FILE (ROTATE=1 replaces it)"
fi
