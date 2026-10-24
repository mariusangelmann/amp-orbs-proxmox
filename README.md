# amp-orbs-proxmox

Run [Amp self-hosted orbs](https://ampcode.com/docs/orbs/self-hosted) on Proxmox VE.

Each orb is a QEMU VM, cloned in a second or two from a template built from Amp's
orb image. When a thread goes idle, the orb **hibernates**: Proxmox writes its RAM to
disk and stops it. The next message resumes it with every process still running,
so Terminal sessions, portal services, and Desktop apps survive a pause, just like
Amp-hosted orbs. Idle orbs use no CPU or RAM.

> [!WARNING]
> **AI-generated, private project, not for enterprise use.**
> The code and documentation in this repository were generated with Claude Opus 5.5,
> an AI model by Anthropic, through Amp. Review it yourself before you run it. This is
> a personal hobby project shared as is. It is not affiliated with, endorsed by, or supported
> by Amp, Anthropic, or Proxmox. It has no warranty, support, or security response
> process, so do not use it in production, for enterprise workloads, or anywhere
> data or compliance matters. If you are on an Amp Enterprise plan, use
> [Amp's supported setup](https://ampcode.com/docs/orbs/self-hosted) instead.

> **No guarantees.** This project runs code written by AI agents on your hardware.
> Read [docs/security.md](docs/security.md) before you use it, and use it at your own risk.

```
┌──────────────────────── Proxmox VE host ────────────────────────┐
│                                                                 │
│  ┌──────────────────────┐   Proxmox API    ┌─────────────────┐  │
│  │ provider container   │  (token scoped   │ orb VMs         │  │
│  │  amp orb provider    │──to one pool)───▶│ cloned from the │  │
│  │  └─ dispatch.py      │                  │ base template   │  │
│  └──────────┬───────────┘                  └────────┬────────┘  │
└─────────────┼───────────────────────────────────────┼───────────┘
              │ jobs: spawn, pause, delete            │ amp orb bootstrap
              ▼                                       ▼
        ┌─────────────────────────────────────────────────┐
        │ ampcode.com      (outbound HTTPS only)          │
        └─────────────────────────────────────────────────┘
```

## How it works

`amp orb provider` connects out to Amp and runs [`provider/dispatch.py`](provider/dispatch.py)
for every job. The dispatch program talks only to the Proxmox API, with a token that
can manage VMs in one pool and nothing else.

| Job | What happens on Proxmox |
| --- | --- |
| `spawn`, new orb | Linked clone of the project snapshot (if Amp names one and it exists) or of the newest base template, then start. |
| `spawn`, existing orb | Resume from hibernation, or start it if it was shut down. |
| (every `spawn`) | Through the QEMU guest agent: set the clock and hostname, then start `amp orb bootstrap` as `user` in a transient systemd unit. |
| `pause` | Hibernate (`qm suspend --todisk`). With `ORB_SNAPSHOT_ID`: shut down cleanly and save a full copy as a project snapshot template. |
| `delete` | Stop and destroy the VM and its disks. |

Every job is safe to repeat. Orbs are found by name (`orb-<orb id>`) in the pool,
so the provider keeps no local state and can be rebuilt at any time.

Before the provider starts or resumes any orb, it checks the node's **running kernel**
and refuses to start on kernels affected by
[CVE-2026-99999 "PwnEscape"](https://forum.proxmox.com/threads/kvm-escape-cve-2026-99999.187102),
a guest-to-host KVM escape. You need `proxmox-kernel-7.0.14-24-pve` or later. Pausing
and deleting orbs keep working. See [docs/security.md](docs/security.md).

## Requirements

- Proxmox VE 9 (8 works but cannot pass the kernel check, because its kernels are no longer patched).
- Running kernel `7.0.14-24-pve` or later. Check it with `uname -r`.
- An x86-64 host with hardware virtualization.
- A bridge where orbs get an address from DHCP and can reach the internet, or the
  isolated network that [`host/create-orb-network.sh`](host/create-orb-network.sh) creates.
- About 15 GB free in `/var/tmp` to build the template, and disk for the orbs (see Sizing).
- An Amp workspace (individuals can create one for free).

## Quick start

1. **Create the provider in Amp.** Workspace **Settings → Orbs → Add Orb Provider**, name
   it (for example `proxmox`), and copy the `aop_live_…` token. It is shown once.

2. **Install on the Proxmox host** as root:

   ```sh
   git clone https://github.com/mariusangelmann/amp-orbs-proxmox
   cd amp-orbs-proxmox
   ./install.sh
   ```

   The installer asks for storage, bridge, VLAN, and orb size, and for the Amp token. Then it:
   1. checks the running kernel ([`host/check-kernel.sh`](host/check-kernel.sh));
   2. creates the `amp-orbs` pool, a role, the `amp-orbs@pve` user, and an API token
      ([`host/setup-access.sh`](host/setup-access.sh));
   3. builds the base template from Amp's orb image, which takes a few minutes
      ([`host/build-template.sh`](host/build-template.sh));
   4. creates a small Debian container (1 vCPU, 512 MB) that runs `amp orb provider` as a
      systemd service and verifies its API access
      ([`host/create-provider-ct.sh`](host/create-provider-ct.sh)).

   To run it without prompts, set the answers in the environment, for example
   `STORAGE=local BRIDGE=vmbr0 AMP_ORB_PROVIDER_TOKEN=aop_live_… ./install.sh </dev/null`.

3. **Start a thread.** In the composer, open **Orb**, choose your provider under
   **Self-Hosted**, and send a prompt. From the CLI:

   ```sh
   amp -ox "hello" --orb-provider proxmox
   ```

   To make it the workspace default, select it in **Settings → Orbs**.

## Configuration

The installer's answers go to the template (cores, memory, disk, network) and to
`/etc/amp-orbs-pve/provider.env` in the provider container. All provider settings are in
[`provider/provider.env.example`](provider/provider.env.example). The most useful ones:

| Setting | Default | Meaning |
| --- | --- | --- |
| `ORB_PAUSE` | `hibernate` | `shutdown` saves the RAM-sized state file per paused orb, but processes stop on pause. |
| `ORB_CLONE` | `linked` | `full` copies the whole disk for each orb: slower, but independent of the template. |
| `ORB_MAX_RUNNING` | `0` (no limit) | Refuse new orbs while this many run, to protect the host's RAM. |
| `ORB_CORES`, `ORB_MEMORY_MB`, `ORB_BALLOON_MB` | template values | Size of new orbs. |
| `ORB_STATE_STORAGE` | VM disk storage | Where hibernation state goes. |

After editing, run `systemctl restart amp-orb-provider` in the container. To change the
template itself, rebuild it (see Updating).

### Sizing

The default orb has 2 vCPUs and 4 GB RAM, with ballooning down to 1 GB, and a 32 GB thin disk.

- **RAM:** only running orbs use RAM. Size `ORB_MAX_RUNNING` so the running orbs fit.
- **Disk:** a linked clone starts at a few hundred MB and grows with what the agent
  installs. Each hibernated orb also keeps a state file about as large as its RAM.
  The template is about 5 GB, and each project snapshot is a full copy.
- **Storage type:** any storage works. On directory storage such as `local`, disks are
  qcow2 so that linked clones work. ZFS or LVM-thin clones and snapshots are faster,
  but you don't need to switch.

## Operations

Run these inside the provider container (`pct enter <ctid>`):

```sh
journalctl -fu amp-orb-provider   # provider and dispatch log
amp-orbs-pve check                # API access, permissions, kernel, template
amp-orbs-pve list                 # orbs, snapshots, base templates
amp-orbs-pve gc                   # what cleanup would delete; add --yes to delete
```

A daily timer runs `amp-orbs-pve gc --yes`. It deletes project snapshots older than 14
days and base templates that are not the newest. Templates that linked clones still
use are kept.

Inside an orb, `journalctl -u 'amp-orb-bootstrap-*'` shows the bootstrap log. You can
also open the orb's console in the Proxmox UI.

### Updating

- **Amp's orb image:** rerun `host/build-template.sh` with the same settings. New orbs
  use the newest template, existing orbs keep theirs, and `gc` removes old templates
  once no orb uses them. The Amp CLI inside orbs updates itself.
- **This repository:** `git pull`, then rerun `host/create-provider-ct.sh` to update the
  dispatch program. Your settings and the Amp token are kept.
- **Proxmox kernel:** install updates and reboot as usual. Orbs on a node do not
  start again until it runs a kernel that passes the check.

## Limitations

- **One node.** New orbs run on the node that holds the template, and project
  snapshots stay on the node where they were taken. Clusters work if the template and
  snapshots live on shared storage, but this is not tested.
- **x86-64 only.** The template uses Amp's x64 image.
- **Network trust.** Orbs get whatever network access the bridge gives them. See
  [docs/security.md](docs/security.md).
- **Hibernation clock.** After a resume, the provider resets the guest clock and
  `systemd-timesyncd` keeps it accurate, but programs that measured time across the
  pause see a jump.

## Development

```sh
python3 -m unittest discover -s tests   # dispatch.py against a fake Proxmox API
shellcheck -x install.sh host/*.sh provider/*.sh provider/amp-orbs-pve
```

The tests run `dispatch.py` as a subprocess, the same way `amp orb provider` does,
against [`tests/fake_pve.py`](tests/fake_pve.py). That fake models the Proxmox rules the
dispatch program depends on, such as the hibernation lock and linked clones. Changes
to how VMs are built or booted still need a test on a real host.

See also [docs/troubleshooting.md](docs/troubleshooting.md).

## License

[MIT](LICENSE). The software is provided as is, without warranty of any kind.
It was generated with Claude Opus 5.5 and is not intended for enterprise use (see the
notice at the top).
