# Troubleshooting

Start with these:

```sh
pct enter <provider ctid>
amp-orbs-pve check                  # API, permissions, kernel, template
journalctl -u amp-orb-provider -n 200
amp-orbs-pve list
```

Spawn output also appears in the thread's setup log in Amp.

## `refusing to run orbs on node …: kernel … is older than 7.0.14-24-pve`

The node's **running** kernel is affected by CVE-2026-99999, a KVM escape. Install
updates (`apt update && apt full-upgrade`), make sure `proxmox-kernel-7.0` is at least
7.0.14-24, and **reboot**. `proxmox-boot-tool kernel list` shows which kernel boots
next, in case one is pinned. See [security.md](security.md).

## `refusing to run orbs on node …: its orb firewall is …`

In isolated mode, the provider starts orbs only after the host reports that its orb
firewall rules are loaded since the last boot. On the host:

```sh
systemctl status amp-orbs-firewall      # did the rules load?
nft list table inet amp_orbs            # are they there?
amp-orbs-host-status                    # report the state now (also runs 30 s after boot)
```

## The template build fails in guestfish or virt-customize

The build runs in small libguestfs VMs. `LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
host/build-template.sh` shows what happens inside them, and `libguestfs-test-tool`
checks the setup. They need `/dev/kvm` and network access for `apt`.

## `no base template (amp-orb-base-*) in pool amp-orbs`

The template build failed or ran with a different `POOL`. Run `host/build-template.sh`
on the host and read its output.

## `token lacks privileges on /pool/amp-orbs`

Rerun `host/setup-access.sh` with the same `POOL`, `STORAGE`, `BRIDGE`, and `SDN_ZONE`
as the installer. If spawn fails with `403` on `/storage/…` or `/sdn/…`, the orbs use a
storage or bridge the token was not granted.

## `guest agent in VM … did not answer`

The orb did not boot, or it has no network so systemd waited. Open the VM's console
(**>_ Console**, or `qm terminal <vmid>` for the serial console) and check
`systemctl status qemu-guest-agent`. A template built from a broken image boots to an
emergency shell; rebuild it.

## The orb starts but the thread never connects

Inside the orb, which you can reach through the console:

```sh
journalctl -u 'amp-orb-bootstrap-*' -n 100
ip -br a; resolvectl status; curl -sSI https://ampcode.com | head -1
```

Usually DNS, DHCP, or outbound HTTPS is blocked on the orb's bridge, VLAN, or firewall.
If the clock is wrong, TLS fails. The bootstrap sets it from the host on every spawn,
so check the host's time.

## `cannot clone`, `VM is locked (suspended)`, or snapshot saves fail

A hibernated VM cannot be cloned. The dispatch program resumes it and shuts it down
first, which needs the guest agent. If a VM is stuck with a lock after a crash, clear
it on the host with `qm unlock <vmid>`. Delete a broken orb with `qm destroy <vmid> --purge`;
the next message in its thread creates a new one, and Amp sets it up again.

## Disk fills up

Every hibernated orb keeps a state file as large as its RAM, and every project snapshot
is a full copy. Run `amp-orbs-pve gc` to see what cleanup would remove. Archive or
delete old threads, which pauses or deletes their orbs, or set `ORB_PAUSE=shutdown` to
stop saving RAM.

## Reporting bugs

For problems in this repository, open a GitHub issue with the provider log lines and
your `pveversion -v` output. Remove tokens first. If the cause is on Amp's side,
[send a bug report](https://ampcode.com/docs/support/reporting-bugs) from the thread.
