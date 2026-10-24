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
- **Update warnings.** A host timer records pending reboots and kernel and hypervisor
  updates in the pool comment. The provider passes them to the setup log and to the
  agent in each orb, so you hear about them in your threads. It needs no extra
  token permissions, because listing updates through the API would require
  `Sys.Modify` on the node.
- **A scoped API token.** The provider's token (`amp-orbs@pve!provider`) can manage VMs
  in the `amp-orbs` pool, use the configured storage and bridge, and read this node's
  status. It cannot touch other VMs or their disks and backups, change host settings,
  or log in to the host. It can list the storage's contents and read its ISO and
  container template files, and `Sys.Audit` on the node also lets it read every
  user's task logs and the node's system report. If the
  provider container is compromised, the attacker gets that much and the Amp provider
  token, so keep the container updated and rotate tokens with `ROTATE=1
  host/setup-access.sh` and **Settings → Orbs**.
- **No inbound connections.** Neither the provider nor the orbs need open ports. Amp
  never connects in.

## Building the template

`host/build-template.sh` never runs anything from the orb image on the host, and
the host never mounts the disk it builds. The host only downloads the image
(`skopeo` checks every layer against its digest) and flattens its layers into a tar
file (`umoci`, which does not follow links out of the tree). Creating the
filesystem, unpacking the tar into it, and running the image's own `apt` to add a
kernel and boot loader all happen inside throwaway libguestfs VMs, which are
`guestfish` and `virt-customize`. A malicious image therefore has to escape a KVM
VM, the same boundary that contains orbs. Proxmox treats the finished disk file as
untrusted when it imports it.

To build exactly the image you reviewed, pin it by digest:
`IMAGE=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb@sha256:… host/build-template.sh`.
The template's description records the digest of every build.

## What orbs share

- **Project snapshots are shared.** A snapshot is a copy of one thread's orb, and
  every later thread in that project, including other members' threads, starts from
  it. Anything the first orb left on disk, from tools and caches to a backdoor planted
  by a compromised agent, carries over. Amp-hosted orbs work the same way. Delete a
  project's snapshots with `amp projects snapshots delete <project>` if you suspect one.
- **Paused orbs are on disk.** A hibernated orb's state file contains its whole RAM,
  including tokens held by running processes, unencrypted on your storage. Encrypt the
  storage if that matters.

## Network

### Isolated network (the default)

`install.sh` puts orbs on a network of their own unless you choose `bridge`:

- **`host/create-orb-network.sh`** creates an SDN zone `amporbs` with the vnet
  `ampnet` (10.77.0.0/24), with DHCP and DNS from the host's dnsmasq and NAT to the
  internet.
- **`host/orb-firewall.sh`**, run by `amp-orbs-firewall.service` before any guest
  starts, loads nftables rules of its own (`inet amp_orbs` and `bridge amp_orbs`). They
  work whether or not the Proxmox firewall is enabled, and they only drop traffic:
  - to the host, everything except DHCP and DNS from the vnet, so the web UI, SSH,
    and other services are unreachable on every host address;
  - forwarded, all private, CGNAT (Tailscale), link-local, loopback, and multicast
    destinations, so orbs cannot reach your LAN or VPNs, plus all IPv6 from orbs and
    any connection opened toward an orb from outside;
  - bridged traffic between orbs, so one orb cannot reach or ARP-spoof another.

**It fails closed.** The host-status timer runs 30 seconds after boot and every 6
hours, and records whether both tables are loaded. With `ORB_REQUIRE_FIREWALL=1`,
which `install.sh` sets in isolated mode, the provider refuses to start or resume
orbs unless the host has reported the rules as active since it last booted.

Check it from an orb's Terminal: `curl -m5 https://ampcode.com` works, while
`curl -m5 -k https://10.77.0.1:8006` and any LAN address time out. On the host,
`nft list table inet amp_orbs` shows counters for what was dropped.

Orbs still need DNS. dnsmasq on the host forwards it to the host's resolvers, so
orbs can resolve internal names that those resolvers know about.

Keep the provider container on a network that can reach the Proxmox API
(`PROVIDER_BRIDGE`, default `vmbr0`). Orbs never need the API, and they cannot reach
the container either.

### Bridge mode

With `ORB_NETWORK=bridge`, orbs sit on a bridge such as `vmbr0`, which usually means
**on your LAN**. From there an orb can reach other machines, your router, the Proxmox
web UI and SSH, and anything a VPN or Tailscale on that network exposes. Because the
agent is root in the orb, it can also send spoofed ARP replies and intercept other
devices' traffic. `orb-firewall.sh` does not apply. If you need bridge mode, use a
dedicated VLAN (`VLAN=<tag>`) that only routes to the internet, or the Proxmox
firewall:

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

If the host has a public or other non-private address, add `OUT DROP -dest <that
address>` as well. Then build the template with `FIREWALL=1`; every orb inherits its
firewall file. The rules only apply once the firewall is **enabled at the datacenter
level**, which also applies the datacenter's input policy to the host itself. Make
sure your SSH and web UI access stays allowed before you turn it on, or you can lock
yourself out. ARP spoofing on the LAN is still possible in this mode.

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
