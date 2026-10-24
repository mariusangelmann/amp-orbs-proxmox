# Security

Treat every orb as an untrusted machine. An orb runs commands chosen by an AI
agent, and code from repositories, packages, and the web. Prompt injection, malicious
dependencies, or a careless command can all run with root inside the orb, because
`user` has passwordless sudo, which Amp requires. Plan for what an orb can reach.

## What protects the host

- **The VM boundary.** Orbs are QEMU/KVM VMs, not containers, so a root user inside an
  orb is still separated from the host by the hypervisor.
- **The kernel check.** Escapes through that boundary do happen. CVE-2026-99999
  ("PwnEscape", Proxmox advisory PSA-2026-00068-1) let a guest read and write host kernel
  memory through crafted network packets. It is fixed in `proxmox-kernel-7.0.14-24-pve`,
  and Proxmox does not patch older kernel series. The installer
  ([`host/check-kernel.sh`](../host/check-kernel.sh)) and the dispatch program check the
  **running** kernel, which you can see with `uname -r`. They refuse to start orbs on
  any kernel older than that. An installed but not yet booted kernel does not count,
  so reboot after a kernel update. Kernels newer than 7.0.14-24 pass. If a later
  advisory needs a higher minimum, raise `FIRST_FIXED_KERNEL` in
  `provider/dispatch.py` and the same version in `host/check-kernel.sh`.
- **A scoped API token.** The provider's token (`amp-orbs@pve!provider`) can manage VMs
  in the `amp-orbs` pool, use the configured storage and bridge, and read node status.
  It cannot touch other VMs, change host settings, or log in to the host. If the
  provider container is compromised, the attacker gets that much and the Amp provider
  token, so keep the container updated and rotate tokens with `ROTATE=1
  host/setup-access.sh` and **Settings → Orbs**.
- **No inbound connections.** Neither the provider nor the orbs need open ports. Amp
  never connects in.

## Network

By default orbs use the bridge you chose, usually `vmbr0`, which means they sit
**on your LAN**. From there an orb can reach other machines, your router, the
Proxmox web UI and SSH, and anything a VPN or Tailscale on that network exposes. For
anything beyond a home lab, isolate them.

### 1. Put orbs on their own network

Use a separate VLAN with internet access and no route into the LAN, by setting
`VLAN=<tag>` in the installer. Or create the NAT network that ships with this repo:

```sh
host/create-orb-network.sh        # SDN zone "amporbs", vnet "ampnet", 10.77.0.0/24, DHCP + SNAT
BRIDGE=ampnet SDN_ZONE=amporbs FIREWALL=1 ./install.sh
```

NAT hides the orbs from the LAN, but the orbs can still open connections into it
through the host. Step 2 closes that.

Keep the provider container on a network that can reach the Proxmox API
(`PROVIDER_BRIDGE`, default `vmbr0`). Orbs never need the API.

### 2. Block private ranges with the Proxmox firewall

Create a security group in **Datacenter → Firewall → Security Group**, or in
`/etc/pve/firewall/cluster.fw`:

```
[group amp-orbs]
# Allow DNS to your resolver first if it has a private address, e.g.:
# OUT ACCEPT -dest 192.168.1.1 -p udp -dport 53
# OUT ACCEPT -dest 192.168.1.1 -p tcp -dport 53
OUT DROP -dest 10.0.0.0/8
OUT DROP -dest 172.16.0.0/12
OUT DROP -dest 192.168.0.0/16
OUT DROP -dest 100.64.0.0/10   # CGNAT, used by Tailscale
OUT DROP -dest 169.254.0.0/16
OUT DROP -dest fc00::/7
```

Then build the template with `FIREWALL=1`. The template gets a firewall file that
enables the firewall and applies the `amp-orbs` group, and every orb and project
snapshot inherits it, because Proxmox copies a VM's firewall file when it is cloned.

The firewall only filters VM traffic once it is **enabled at the datacenter level**
(**Datacenter → Firewall → Options → Firewall: Yes**). Enabling it also applies the
datacenter's default input policy to the host itself. Make sure the host's own
rules still allow your SSH and web UI access, from the `management` IP set or
`local_network`, before you turn it on, or you can lock yourself out.

Test it from an orb's Terminal: `curl -m5 https://ampcode.com` should work, and
`curl -m5 -k https://<host ip>:8006` should time out.

### 3. Allow the outbound traffic Amp needs

Orbs and the provider need outbound HTTPS and WSS to `ampcode.com`,
`static.ampcode.com`, `tunnel.ampcode.com`, `storage.googleapis.com`, and your Git host.
Proxies must allow long-lived connections. See
[What Leaves Your Network](https://ampcode.com/docs/orbs/self-hosted#what-leaves-your-network).

## Data

Repository checkouts, build output, and hibernation state, which includes everything
in the orb's RAM such as tokens loaded into processes, stay on your Proxmox storage.
What the agent reads and the command output it sees go to Amp with the thread.
Deleting a thread deletes its orb, but project snapshots stay until `amp-orbs-pve gc`
removes them.
