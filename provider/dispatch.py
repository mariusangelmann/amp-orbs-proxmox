#!/usr/bin/env python3
"""Amp self-hosted orb dispatch program for Proxmox VE.

`amp orb provider` runs this once per job with ORB_OPERATION set to spawn,
pause, or delete. Every orb is a QEMU VM cloned from a template in a
dedicated pool. Pausing hibernates the VM (RAM is written to disk), so
processes keep running when the orb resumes. The program talks to Proxmox
only through its HTTPS API with a scoped API token, and uses only the
Python standard library.

Run without ORB_OPERATION for operator commands:

    dispatch.py check    verify API access, permissions, and templates
    dispatch.py list     list orbs, snapshots, and base templates
    dispatch.py gc       delete old project snapshots and unused base templates
"""

import argparse
import base64
import fcntl
import hashlib
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

ORB_PREFIX = "orb-"
SNAP_PREFIX = "amp-snap-"
BASE_PREFIX = "amp-orb-base-"
MARKER = "managed-by: amp-orbs-proxmox"


# First host kernel that fixes CVE-2026-99999 "PwnEscape" (PSA-2026-00068-1), a
# guest-to-host KVM escape: proxmox-kernel-7.0.14-24-pve. Proxmox does not patch
# EOL series, so older series stay vulnerable; newer series include the fix.
FIRST_FIXED_KERNEL = (7, 0, 14, 24)
KERNEL_ADVISORY = "CVE-2026-99999 (PwnEscape, PSA-2026-00068-1), fixed in proxmox-kernel-7.0.14-24-pve"


def kernel_problem(release):
    """Return why the host kernel `release` (uname -r) is unsafe, or None if it is safe."""
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)-(\d+)-pve", release or "")
    if not match:
        return f"kernel {release!r} is not a recognized Proxmox VE kernel"
    if tuple(map(int, match.groups())) < FIRST_FIXED_KERNEL:
        return f"kernel {release} is older than 7.0.14-24-pve"
    return None


def env_line(key, value):
    """KEY=value for a systemd EnvironmentFile; refuses values that could add lines."""
    if not value or re.search(r"[\x00-\x1f\x7f]", value):
        raise ValueError(f"{key} is empty or contains control characters")
    return f"{key}={value}"


def guest_text(text, limit=2000):
    """Output from inside an orb is untrusted: drop control characters, cap the length."""
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "?", (text or "").strip())
    return text if len(text) <= limit else text[:limit] + " [truncated]"


def log(message):
    print(f"[amp-orbs-pve] {message}", flush=True)


class Config:
    def __init__(self, env):
        def need(name):
            value = env.get(name)
            if not value:
                raise SystemExit(f"{name} is not set (see provider.env.example)")
            return value

        self.api_url = need("PVE_API_URL").rstrip("/")
        self.token_id = need("PVE_TOKEN_ID")
        self.token_secret = need("PVE_TOKEN_SECRET")
        self.node = need("PVE_NODE")
        self.pool = env.get("PVE_POOL", "amp-orbs")
        self.ca_file = env.get("PVE_CA_FILE") or None
        self.tls_insecure = env.get("PVE_TLS_INSECURE") == "1"
        self.vmid_min = int(env.get("ORB_VMID_MIN", "20000"))
        self.vmid_max = int(env.get("ORB_VMID_MAX", "29999"))
        self.clone_mode = env.get("ORB_CLONE", "linked")
        self.pause_mode = env.get("ORB_PAUSE", "hibernate")
        self.state_storage = env.get("ORB_STATE_STORAGE") or None
        self.cores = env.get("ORB_CORES") or None
        self.memory_mb = env.get("ORB_MEMORY_MB") or None
        self.balloon_mb = env.get("ORB_BALLOON_MB") or None
        self.max_running = int(env.get("ORB_MAX_RUNNING", "0"))
        # Set by install.sh for the isolated network: refuse orbs unless the
        # host reports its orb firewall rules loaded since its last boot.
        self.require_firewall = env.get("ORB_REQUIRE_FIREWALL") == "1"
        self.lock_file = env.get("ORB_LOCK_FILE", "/tmp/amp-orbs-pve.lock")
        self.poll = float(env.get("ORB_POLL_SECONDS", "1"))
        if self.clone_mode not in ("linked", "full"):
            raise SystemExit("ORB_CLONE must be 'linked' or 'full'")
        if self.pause_mode not in ("hibernate", "shutdown"):
            raise SystemExit("ORB_PAUSE must be 'hibernate' or 'shutdown'")


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


class Api:
    def __init__(self, cfg):
        self.cfg = cfg
        if cfg.tls_insecure:
            self.ctx = ssl._create_unverified_context()
        else:
            self.ctx = ssl.create_default_context(cafile=cfg.ca_file)
            if cfg.ca_file:
                # The cluster CA is private to this cluster; node certificates
                # often lack the IP or name used to reach the API.
                self.ctx.check_hostname = False
                # Python 3.13 rejects CAs without a key usage extension, and
                # the Proxmox cluster CA has none. Signatures are still checked.
                self.ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)

    def call(self, method, path, params=None):
        url = f"{self.cfg.api_url}/api2/json{path}"
        body = None
        items = []
        for key, value in (params or {}).items():
            if value is None:
                continue
            for item in value if isinstance(value, list) else [value]:
                items.append((key, str(item)))
        if method == "GET" or method == "DELETE":
            if items:
                url += "?" + urllib.parse.urlencode(items)
        else:
            body = urllib.parse.urlencode(items).encode()
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header(
            "Authorization", f"PVEAPIToken={self.cfg.token_id}={self.cfg.token_secret}"
        )
        try:
            with urllib.request.urlopen(request, context=self.ctx, timeout=60) as resp:
                return json.load(resp).get("data")
        except urllib.error.HTTPError as err:
            detail = err.reason
            try:
                payload = json.load(err)
                if payload.get("errors"):
                    detail = f"{detail} {json.dumps(payload['errors'])}"
                elif payload.get("message"):
                    detail = payload["message"]
            except Exception:
                pass
            raise ApiError(err.code, str(detail).strip()) from None

    def get(self, path, **params):
        return self.call("GET", path, params)

    def post(self, path, **params):
        return self.call("POST", path, params)

    def put(self, path, **params):
        return self.call("PUT", path, params)

    def delete(self, path, **params):
        return self.call("DELETE", path, params)

    def wait_task(self, upid, timeout=290):
        node = upid.split(":")[1]
        path = f"/nodes/{node}/tasks/{urllib.parse.quote(upid, safe='')}/status"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.get(path)
            if status.get("status") == "stopped":
                exit_status = status.get("exitstatus", "")
                if exit_status != "OK" and not exit_status.startswith("WARNINGS"):
                    raise RuntimeError(f"task {upid} failed: {exit_status}")
                return
            time.sleep(self.cfg.poll)
        raise TimeoutError(f"task {upid} did not finish within {timeout}s")


def orb_name(orb_id):
    name = re.sub(r"[^a-z0-9-]+", "-", orb_id.lower()).strip("-")
    name = ORB_PREFIX + name
    if len(name) > 63:
        name = ORB_PREFIX + hashlib.sha256(orb_id.encode()).hexdigest()[:40]
    return name


def snapshot_name(snapshot_id):
    return SNAP_PREFIX + hashlib.sha256(snapshot_id.encode()).hexdigest()[:24]


def describe(**fields):
    lines = [MARKER] + [f"{key}: {value}" for key, value in fields.items() if value]
    return "\n".join(lines)


def parse_description(text):
    fields = {}
    for line in (text or "").splitlines():
        key, sep, value = line.partition(": ")
        if sep:
            fields[key.strip()] = value.strip()
    return fields


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Orbs:
    def __init__(self, cfg, api):
        self.cfg = cfg
        self.api = api

    # Discovery -------------------------------------------------------------

    def resources(self):
        vms = self.api.get("/cluster/resources", type="vm") or []
        return [vm for vm in vms if vm.get("type") == "qemu" and vm.get("pool") == self.cfg.pool]

    def find(self, name):
        matches = [vm for vm in self.resources() if vm.get("name") == name]
        if len(matches) > 1:
            ids = ", ".join(str(vm["vmid"]) for vm in matches)
            raise RuntimeError(f"several VMs in pool {self.cfg.pool} are named {name}: {ids}")
        return matches[0] if matches else None

    def config(self, vm):
        return self.api.get(f"/nodes/{vm['node']}/qemu/{vm['vmid']}/config")

    def fields(self, vm):
        return parse_description(self.config(vm).get("description"))

    def base_template(self, image):
        bases = sorted(
            (vm for vm in self.resources() if vm.get("template") and vm["name"].startswith(BASE_PREFIX)),
            key=lambda vm: vm["name"],
            reverse=True,
        )
        if not bases:
            raise RuntimeError(
                f"no base template ({BASE_PREFIX}*) in pool {self.cfg.pool}; "
                "run host/build-template.sh on the Proxmox host"
            )
        for vm in bases:
            if image and self.fields(vm).get("image") == image:
                return vm
        if image:
            log(f"no base template built from {image}; using newest template {bases[0]['name']}")
        return bases[0]

    def vm_path(self, vm):
        return f"/nodes/{vm['node']}/qemu/{vm['vmid']}"

    def status(self, vm):
        return self.api.get(f"{self.vm_path(vm)}/status/current")

    def ensure_safe_host(self, node):
        """Refuse to run guests on a node that would not contain them."""
        status = self.api.get(f"/nodes/{node}/status")
        release = self.ensure_safe_kernel(node, status)
        if self.cfg.require_firewall:
            self.ensure_firewall(node, status)
        return release

    def ensure_firewall(self, node, status):
        fields = self.pool_fields()
        boot = time.time() - float(status.get("uptime") or 0)
        try:
            checked = datetime.strptime(fields.get("host-status-checked", ""), "%Y-%m-%dT%H:%M:%SZ")
            checked = checked.replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            checked = 0
        state = fields.get("host-orb-firewall") or "unknown"
        if fields.get("host-node") != node or checked < boot - 5:
            state = "not reported since the node booted"
        if state != "active":
            raise RuntimeError(
                f"refusing to run orbs on node {node}: its orb firewall is {state}, so orbs could "
                "reach your LAN and the host. Check `systemctl status amp-orbs-firewall` and run "
                "amp-orbs-host-status on the host (it runs 30 seconds after boot)"
            )

    def ensure_safe_kernel(self, node, status=None):
        """Refuse to run guests on a node whose running kernel allows a KVM escape."""
        status = status or self.api.get(f"/nodes/{node}/status")
        release = (status.get("current-kernel") or {}).get("release")
        if not release:
            # Older releases only report "Linux <release> #1 SMP ...".
            release = ((status.get("kversion") or "").split() + ["", ""])[1]
        problem = kernel_problem(release)
        if problem:
            raise RuntimeError(
                f"refusing to run orbs on node {node}: {problem}. Orbs are untrusted guests and "
                f"this kernel allows them to escape to the host ({KERNEL_ADVISORY}). "
                "Install the fixed proxmox-kernel and reboot the node"
            )
        return release

    def pool_fields(self):
        """The host status host/host-status.sh keeps in the pool comment."""
        pools = self.api.get("/pools", poolid=self.cfg.pool) or []
        return parse_description((pools[0] if pools else {}).get("comment"))

    def host_warnings(self, node):
        """Maintenance warnings from the host status."""
        try:
            fields = self.pool_fields()
        except ApiError as err:
            log(f"could not read the host status: {err}")
            return []
        checked = fields.get("host-status-checked")
        if not checked:
            log("no host status yet; install the amp-orbs-host-status timer on the host (install.sh does)")
            return []
        warnings = []
        try:
            age = time.time() - datetime.strptime(checked, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc).timestamp()
        except ValueError:
            age = float("inf")
        if age > HOST_STATUS_MAX_AGE:
            warnings.append(
                f"The host's update status was last checked at {checked}, so it may be missing "
                "security updates (is the amp-orbs-host-status timer running?)."
            )
        if fields.get("host-node") and fields["host-node"] != node:
            return warnings  # the status describes another node
        if fields.get("host-reboot-required"):
            warnings.append(
                f"Kernel {fields['host-reboot-required']} is installed but the host still runs "
                f"{fields.get('host-kernel', 'an older kernel')}; reboot the host to use it."
            )
        if fields.get("host-security-updates"):
            warnings.append(
                f"Kernel and hypervisor updates are available: {fields['host-security-updates']}."
            )
        if fields.get("host-updates", "0") not in ("", "0"):
            warnings.append(f"{fields['host-updates']} package updates are available in total.")
        return warnings

    def host_notice(self, node):
        """Log host warnings and return guidance for the agent in the orb ("" if none)."""
        warnings = self.host_warnings(node)
        for warning in warnings:
            log(f"WARNING: Proxmox host {node}: {warning}")
        if not warnings:
            return ""
        items = "\n".join(f"- {warning}" for warning in warnings)
        return HOST_NOTICE.format(node=node, items=items)

    # VM lifecycle helpers --------------------------------------------------

    def allocate_and_clone(self, source, name, full, description):
        # Read-only so the lock works no matter which user created the file.
        with os.fdopen(os.open(self.cfg.lock_file, os.O_RDONLY | os.O_CREAT, 0o644)) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            used = {vm["vmid"] for vm in self.api.get("/cluster/resources", type="vm") or []}
            for vmid in range(self.cfg.vmid_min, self.cfg.vmid_max + 1):
                if vmid in used:
                    continue
                try:
                    # Confirms the ID is free cluster-wide, including VMs this
                    # token cannot see.
                    self.api.get("/cluster/nextid", vmid=vmid)
                except ApiError:
                    continue
                upid = self.api.post(
                    f"{self.vm_path(source)}/clone",
                    newid=vmid,
                    name=name,
                    pool=self.cfg.pool,
                    full=1 if full else 0,
                    description=description,
                )
                self.api.wait_task(upid)
                return {"vmid": vmid, "node": source["node"], "name": name}
        raise RuntimeError(f"no free VMID between {self.cfg.vmid_min} and {self.cfg.vmid_max}")

    def start(self, vm):
        self.api.wait_task(self.api.post(f"{self.vm_path(vm)}/status/start"))

    def shutdown(self, vm):
        upid = self.api.post(f"{self.vm_path(vm)}/status/shutdown", timeout=120, forceStop=1)
        self.api.wait_task(upid, timeout=200)

    def hibernate(self, vm):
        upid = self.api.post(
            f"{self.vm_path(vm)}/status/suspend", todisk=1, statestorage=self.cfg.state_storage
        )
        self.api.wait_task(upid)

    def wait_agent(self, vm, timeout=180):
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.api.post(f"{self.vm_path(vm)}/agent/ping")
                return
            except ApiError:
                if time.monotonic() > deadline:
                    raise TimeoutError(f"guest agent in VM {vm['vmid']} did not answer within {timeout}s")
                time.sleep(self.cfg.poll)

    def guest_exec(self, vm, command, stdin, timeout=60):
        result = self.api.post(f"{self.vm_path(vm)}/agent/exec", command=command, **{"input-data": stdin})
        pid = result["pid"]
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.api.get(f"{self.vm_path(vm)}/agent/exec-status", pid=pid)
            if status.get("exited"):
                output = (status.get("out-data") or "") + (status.get("err-data") or "")
                if status.get("exitcode", 0) != 0:
                    raise RuntimeError(f"command in VM {vm['vmid']} failed: {guest_text(output)}")
                return output
            time.sleep(self.cfg.poll)
        raise TimeoutError(f"command in VM {vm['vmid']} did not finish within {timeout}s")

    def is_hibernated(self, vm):
        return vm.get("lock") == "suspended"

    # Operations ------------------------------------------------------------

    def spawn(self, env):
        orb_id = env["ORB_ID"]
        name = orb_name(orb_id)
        vm = self.find(name)
        if vm is None:
            if self.cfg.max_running:
                running = [
                    v for v in self.resources()
                    if v["name"].startswith(ORB_PREFIX) and v.get("status") == "running"
                ]
                if len(running) >= self.cfg.max_running:
                    raise RuntimeError(
                        f"{len(running)} orbs are running (ORB_MAX_RUNNING={self.cfg.max_running}); "
                        "pause or archive a thread and try again"
                    )
            source = None
            snapshot_id = env.get("ORB_SNAPSHOT_ID")
            if snapshot_id:
                source = self.find(snapshot_name(snapshot_id))
                if source:
                    log(f"creating {name} from project snapshot {source['name']} ({source['vmid']})")
            if source is None:
                source = self.base_template(env.get("ORB_IMAGE"))
                log(f"creating {name} from base template {source['name']} ({source['vmid']})")
            self.ensure_safe_host(source["node"])  # the clone runs on its source's node
            vm = self.allocate_and_clone(
                source,
                name,
                full=self.cfg.clone_mode == "full",
                description=describe(**{"orb-id": orb_id, "source": source["name"], "created": now_iso()}),
            )
            overrides = {
                "cores": self.cfg.cores,
                "memory": self.cfg.memory_mb,
                "balloon": self.cfg.balloon_mb,
            }
            if any(overrides.values()):
                self.api.put(f"{self.vm_path(vm)}/config", **overrides)
            self.start(vm)
        else:
            if self.fields(vm).get("orb-id") != orb_id:
                raise RuntimeError(f"VM {vm['vmid']} is named {name} but belongs to another orb")
            self.ensure_safe_host(vm["node"])
            state = self.status(vm)
            if state.get("status") == "running" and state.get("qmpstatus") == "paused":
                # Suspended to RAM (for example by hand): resume in place.
                self.api.wait_task(self.api.post(f"{self.vm_path(vm)}/status/resume"))
            elif state.get("status") != "running":
                log(f"{'resuming' if self.is_hibernated(vm) else 'starting'} {name} ({vm['vmid']})")
                self.start(vm)
            else:
                log(f"{name} ({vm['vmid']}) is already running")

        self.wait_agent(vm)
        notice = self.host_notice(vm["node"])
        stdin = [
            str(int(time.time())),
            name,
            base64.b64encode(notice.encode()).decode() if notice else "",
            env_line("ORB_TOKEN", env.get("ORB_TOKEN")),
        ]
        if env.get("AMP_URL"):
            stdin.append(env_line("AMP_URL", env["AMP_URL"]))
        output = self.guest_exec(vm, ["/bin/bash", "-c", BOOTSTRAP_SCRIPT], "\n".join(stdin) + "\n")
        log(f"{name} ({vm['vmid']}): {guest_text(output)}")

    def pause(self, env):
        name = orb_name(env["ORB_ID"])
        vm = self.find(name)
        if vm is None:
            log(f"{name} does not exist; nothing to pause")
            return
        snapshot_id = env.get("ORB_SNAPSHOT_ID")
        if snapshot_id:
            self.save_snapshot(vm, snapshot_id, env.get("ORB_IMAGE"))
            return
        state = self.status(vm)
        if state.get("status") != "running":
            log(f"{name} ({vm['vmid']}) is already {'hibernated' if self.is_hibernated(vm) else 'stopped'}")
        elif self.cfg.pause_mode == "hibernate":
            log(f"hibernating {name} ({vm['vmid']})")
            self.hibernate(vm)
        else:
            log(f"shutting down {name} ({vm['vmid']})")
            self.shutdown(vm)

    def save_snapshot(self, vm, snapshot_id, image):
        snap = snapshot_name(snapshot_id)
        if self.find(snap):
            log(f"project snapshot {snap} already exists")
        else:
            # A clean shutdown gives a consistent disk; hibernated VMs are
            # locked and cannot be cloned.
            if self.is_hibernated(vm):
                self.ensure_safe_host(vm["node"])
                self.start(vm)
            if self.status(vm).get("status") == "running":
                # Clones of the snapshot must not share a machine ID: systemd
                # derives the DHCP client ID from it, so they would fight over
                # one IP address. An empty file makes the next boot create one.
                self.wait_agent(vm)
                self.guest_exec(vm, ["/bin/sh", "-c", RESET_MACHINE_ID], None)
                log(f"shutting down {vm['name']} ({vm['vmid']}) to copy its disk")
                self.shutdown(vm)
            log(f"saving project snapshot {snap} from {vm['name']} ({vm['vmid']})")
            copy = self.allocate_and_clone(
                vm,
                snap,
                full=True,
                description=describe(**{
                    "snapshot-id": snapshot_id,
                    "image": image,
                    "source": vm["name"],
                    "created": now_iso(),
                }),
            )
            self.api.post(f"{self.vm_path(copy)}/template")
        if self.status(vm).get("status") == "running":
            self.shutdown(vm)

    def delete(self, env):
        name = orb_name(env["ORB_ID"])
        vm = self.find(name)
        if vm is None:
            log(f"{name} does not exist; nothing to delete")
            return
        if self.status(vm).get("status") == "running":
            self.api.wait_task(self.api.post(f"{self.vm_path(vm)}/status/stop"))
        log(f"deleting {name} ({vm['vmid']})")
        upid = self.api.delete(self.vm_path(vm), purge=1, **{"destroy-unreferenced-disks": 1})
        self.api.wait_task(upid)

    # Operator commands -----------------------------------------------------

    def list(self):
        rows = []
        for vm in sorted(self.resources(), key=lambda vm: vm["vmid"]):
            if not vm["name"].startswith((ORB_PREFIX, SNAP_PREFIX, BASE_PREFIX)):
                continue
            state = "template" if vm.get("template") else vm.get("status", "?")
            if self.is_hibernated(vm):
                state = "hibernated"
            fields = self.fields(vm)
            detail = fields.get("orb-id") or fields.get("image") or ""
            rows.append(f"{vm['vmid']:>6}  {state:<11} {vm['name']:<48} {detail}")
        print("\n".join(rows) if rows else f"no managed VMs in pool {self.cfg.pool}")

    def gc(self, snapshot_days, apply):
        cutoff = time.time() - snapshot_days * 86400
        bases = sorted(
            (vm for vm in self.resources() if vm.get("template") and vm["name"].startswith(BASE_PREFIX)),
            key=lambda vm: vm["name"],
        )
        candidates = [(vm, "older base template") for vm in bases[:-1]]
        for vm in self.resources():
            if not (vm.get("template") and vm["name"].startswith(SNAP_PREFIX)):
                continue
            created = self.fields(vm).get("created")
            try:
                ts = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
            except (TypeError, ValueError):
                continue
            if ts < cutoff:
                candidates.append((vm, f"project snapshot older than {snapshot_days} days"))
        for vm, reason in candidates:
            if not apply:
                print(f"would delete {vm['vmid']} {vm['name']} ({reason})")
                continue
            try:
                self.api.wait_task(self.api.delete(self.vm_path(vm), purge=1))
                print(f"deleted {vm['vmid']} {vm['name']} ({reason})")
            except (ApiError, RuntimeError) as err:
                # Templates that linked clones still use cannot be removed.
                print(f"kept {vm['vmid']} {vm['name']}: {err}")
        if not apply and candidates:
            print("run again with --yes to delete; templates still used by linked clones are kept")

    def check(self):
        version = self.api.get("/version")
        log(f"connected to Proxmox VE {version.get('version')} at {self.cfg.api_url}")
        perms = self.api.get("/access/permissions", path=f"/pool/{self.cfg.pool}") or {}
        granted = set((perms.get(f"/pool/{self.cfg.pool}") or {}).keys())
        if "VM.Monitor" in granted:
            granted.add("VM.GuestAgent.Unrestricted")  # Proxmox VE 8 name
        missing = sorted(REQUIRED_POOL_PRIVS - granted)
        if missing:
            raise SystemExit(f"token lacks privileges on /pool/{self.cfg.pool}: {', '.join(missing)}")
        release = self.ensure_safe_host(self.cfg.node)
        log(f"node {self.cfg.node} runs kernel {release}, which is not affected by {KERNEL_ADVISORY.split(' (')[0]}")
        for warning in self.host_warnings(self.cfg.node):
            log(f"WARNING: {warning}")
        base = self.base_template(None)
        log(f"pool {self.cfg.pool} OK; newest base template {base['name']} ({base['vmid']}) on {base['node']}")


REQUIRED_POOL_PRIVS = {
    "VM.Allocate",
    "VM.Clone",
    "VM.Audit",
    "VM.PowerMgmt",
    "VM.Config.Disk",
    "VM.Config.CPU",
    "VM.Config.Memory",
    "VM.Config.Options",
    "VM.GuestAgent.Unrestricted",
}

HOST_STATUS_MAX_AGE = 2 * 86400

# Written to /etc/ampcode/AGENTS.md in the orb, which Amp always loads.
HOST_NOTICE = """## Host maintenance notice

This orb runs on a self-hosted Proxmox VE node ({node}) that needs maintenance:

{items}

At the start of your first reply in this thread, tell the user in one or two
sentences, so the host's owner can update it. Mention it once, not in every
reply. Do not try to fix it: the host is not reachable from this orb, and it is
not part of the user's task.
"""

RESET_MACHINE_ID = ": > /etc/machine-id && rm -f /var/lib/dbus/machine-id"

# Runs as root inside the orb through the QEMU guest agent. Reads the host
# clock, the hostname, and the job's environment from stdin, then starts
# `amp orb bootstrap` as `user` in its own transient systemd unit so it
# outlives the guest agent call.
BOOTSTRAP_SCRIPT = r"""
set -euo pipefail
IFS= read -r epoch
IFS= read -r name
IFS= read -r notice
# Host maintenance notice for the agent, in a marked block of the system-wide
# guidance file, so other guidance there is kept.
guidance=/etc/ampcode/AGENTS.md
begin='<!-- amp-orbs-proxmox:host-notice -->'
end='<!-- /amp-orbs-proxmox:host-notice -->'
if [ -f "$guidance" ]; then
  sed -i "\|^$begin\$|,\|^$end\$|d" "$guidance"
fi
if [ -n "$notice" ]; then
  install -d -m 0755 /etc/ampcode
  { echo "$begin"; base64 -d <<<"$notice"; echo "$end"; } >>"$guidance"
fi
if [ -f "$guidance" ] && [ ! -s "$guidance" ]; then rm -f "$guidance"; fi
# The guest clock is stale after resuming from hibernation; TLS needs it.
date -u -s "@$epoch" >/dev/null || true
hostnamectl hostname "$name" 2>/dev/null || hostname "$name" || true
install -d -m 0755 /run/amp-orb
umask 077
cat > /run/amp-orb/bootstrap.env
chown user:user /run/amp-orb/bootstrap.env
props=(-p WorkingDirectory=/home/user -p EnvironmentFile=/run/amp-orb/bootstrap.env)
if [ -r /etc/amp-orb/image.env ]; then
  props=(-p EnvironmentFile=/etc/amp-orb/image.env "${props[@]}")
fi
unit="amp-orb-bootstrap-$(date +%s)-$$"
systemd-run --quiet --collect --unit="$unit" --uid=user --gid=user "${props[@]}" \
  --setenv=HOME=/home/user --setenv=USER=user --setenv=LOGNAME=user \
  /bin/bash -lc 'exec amp orb bootstrap'
echo "started amp orb bootstrap in unit $unit (journalctl -u $unit)"
"""


def main():
    env = os.environ
    operation = env.get("ORB_OPERATION")
    cfg = Config(env)
    orbs = Orbs(cfg, Api(cfg))
    if operation:
        if operation not in ("spawn", "pause", "delete"):
            raise SystemExit(f"unknown ORB_OPERATION {operation!r}")
        started = time.monotonic()
        try:
            getattr(orbs, operation)(env)
        except Exception as err:
            log(f"{operation} {env.get('ORB_ID')} failed: {err}")
            sys.exit(1)
        log(f"{operation} {env.get('ORB_ID')} done in {time.monotonic() - started:.1f}s")
        return

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="verify API access, permissions, and templates")
    sub.add_parser("list", help="list orbs, snapshots, and base templates")
    gc = sub.add_parser("gc", help="delete old project snapshots and unused base templates")
    gc.add_argument("--snapshot-days", type=int, default=14)
    gc.add_argument("--yes", action="store_true", help="delete instead of printing what would be deleted")
    args = parser.parse_args()
    if args.command == "check":
        orbs.check()
    elif args.command == "list":
        orbs.list()
    else:
        orbs.gc(args.snapshot_days, args.yes)


if __name__ == "__main__":
    main()
