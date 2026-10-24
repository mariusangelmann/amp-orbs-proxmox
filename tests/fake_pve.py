"""A small in-memory imitation of the Proxmox VE API for testing dispatch.py.

It models the rules dispatch.py relies on: linked clones only from
templates, hibernated VMs carry the 'suspended' lock and resume on start,
running or locked VMs cannot be cloned or deleted, templates used by linked
clones cannot be deleted, and the guest agent only answers while running.
Tasks complete immediately; failures surface through the task status, like
Proxmox workers do.
"""

import itertools
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NODE = "pve"


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.vms = {}
        self.tasks = {}
        self.execs = {}
        self.exec_log = []
        self.foreign_vmids = set()  # VMIDs that exist but are invisible to the token
        self.kernel = "7.0.14-24-pve"  # running kernel reported by /nodes/{node}/status
        self.task_ids = itertools.count(1)
        self.pids = itertools.count(100)
        self.clock = itertools.count(1)

    def add_vm(self, vmid, name, template=False, description="", pool="amp-orbs", status="stopped"):
        self.vms[vmid] = {
            "vmid": vmid,
            "name": name,
            "pool": pool,
            "template": 1 if template else 0,
            "status": status,
            "lock": None,
            "description": description,
            "base": None,  # template vmid for linked clones
            "boots": 0,
            "config": {"cores": 2, "memory": 4096, "balloon": 1024},
            "seq": next(self.clock),
        }
        return self.vms[vmid]


class ApiFailure(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _params(self):
            parsed = urllib.parse.urlparse(self.path)
            params = urllib.parse.parse_qs(parsed.query)
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                params.update(urllib.parse.parse_qs(self.rfile.read(length).decode()))
            return parsed.path, params

        def _reply(self, status, data=None, message=None):
            body = json.dumps({"data": data, "message": message}).encode()
            self.send_response(status, message)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _handle(self, method):
            if not self.headers.get("Authorization", "").startswith("PVEAPIToken=amp-orbs@pve!provider="):
                return self._reply(401, message="authentication failure")
            path, params = self._params()
            one = {k: v[0] for k, v in params.items()}
            prefix = "/api2/json"
            assert path.startswith(prefix), path
            path = path[len(prefix):]
            try:
                with state.lock:
                    data = route(state, method, path, one, params)
                self._reply(200, data)
            except ApiFailure as err:
                self._reply(err.status, message=str(err))

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

        def do_PUT(self):
            self._handle("PUT")

        def do_DELETE(self):
            self._handle("DELETE")

    return Handler


def task(state, ok=True, error=""):
    upid = f"UPID:{NODE}:0000:{next(state.task_ids):08X}:task:"
    state.tasks[upid] = "OK" if ok else error
    return upid


def run(state, fn):
    """Run fn as a worker task: errors become a failed task, not an HTTP error."""
    try:
        fn()
        return task(state)
    except ApiFailure as err:
        return task(state, ok=False, error=str(err))


def route(state, method, path, p, raw):
    parts = path.strip("/").split("/")
    if path == "/version":
        return {"version": "9.2.0"}
    if path == "/access/permissions":
        privs = [
            "VM.Allocate", "VM.Clone", "VM.Audit", "VM.PowerMgmt", "VM.Config.Disk",
            "VM.Config.CPU", "VM.Config.Memory", "VM.Config.Options", "VM.GuestAgent.Unrestricted",
        ]
        return {p["path"]: {priv: 1 for priv in privs}}
    if path == "/cluster/resources":
        return [
            {
                "type": "qemu", "vmid": vm["vmid"], "name": vm["name"], "node": NODE,
                "status": vm["status"], "template": vm["template"], "pool": vm["pool"],
                **({"lock": vm["lock"]} if vm["lock"] else {}),
            }
            for vm in state.vms.values()
        ]
    if path == "/cluster/nextid":
        vmid = int(p["vmid"])
        if vmid in state.vms or vmid in state.foreign_vmids:
            raise ApiFailure(400, f"VM {vmid} already exists")
        return vmid
    if path == f"/nodes/{NODE}/status":
        return {
            "kversion": f"Linux {state.kernel} #1 SMP PREEMPT_DYNAMIC PMX",
            "current-kernel": {"sysname": "Linux", "release": state.kernel, "machine": "x86_64"},
        }
    if parts[:2] == ["nodes", NODE] and parts[2] == "tasks":
        upid = urllib.parse.unquote(parts[3])
        return {"status": "stopped", "exitstatus": state.tasks[upid]}
    if parts[:3] != ["nodes", NODE, "qemu"]:
        raise ApiFailure(501, f"not implemented: {method} {path}")

    vmid = int(parts[3])
    vm = state.vms.get(vmid)
    if vm is None:
        raise ApiFailure(500, f"Configuration file 'nodes/{NODE}/qemu-server/{vmid}.conf' does not exist")
    rest = "/".join(parts[4:])

    def check_lock():
        if vm["lock"]:
            raise ApiFailure(500, f"VM is locked ({vm['lock']})")

    if method == "GET" and rest == "config":
        return {**vm["config"], "name": vm["name"], "description": vm["description"]}
    if method == "PUT" and rest == "config":
        check_lock()
        vm["config"].update({k: int(v) for k, v in p.items()})
        return None
    if method == "GET" and rest == "status/current":
        qmp = "paused" if vm.get("paused") else vm["status"]
        return {"status": vm["status"], "qmpstatus": qmp, **({"lock": vm["lock"]} if vm["lock"] else {})}
    if method == "POST" and rest == "clone":
        def clone():
            full = p.get("full") == "1"
            if not vm["template"] and not full:
                raise ApiFailure(500, "Linked clone feature is not supported for drive 'scsi0'")
            check_lock()
            if not vm["template"] and vm["status"] == "running":
                raise ApiFailure(500, "clone of a running VM is not modelled")
            newid = int(p["newid"])
            if newid in state.vms or newid in state.foreign_vmids:
                raise ApiFailure(500, f"VM {newid} already exists")
            new = state.add_vm(newid, p["name"], description=p.get("description", ""), pool=p.get("pool"))
            new["config"] = dict(vm["config"])
            new["base"] = None if full else vmid
            new["cloned_from"] = vmid
            new["full"] = full
        return run(state, clone)
    if method == "POST" and rest == "template":
        def template():
            check_lock()
            if vm["status"] != "stopped":
                raise ApiFailure(500, "you can't convert a running VM to a template")
            vm["template"] = 1
        return run(state, template)
    if method == "POST" and rest == "status/start":
        def start():
            if vm["template"]:
                raise ApiFailure(500, "you can't start a vm if it's a template")
            if vm["lock"] and vm["lock"] != "suspended":
                raise ApiFailure(500, f"VM is locked ({vm['lock']})")
            if vm["status"] == "running":
                raise ApiFailure(500, f"VM {vmid} already running")
            if vm["lock"] == "suspended":
                vm["lock"] = None  # resume from the saved RAM state
            else:
                vm["boots"] += 1
            vm["status"] = "running"
        return run(state, start)
    if method == "POST" and rest == "status/suspend":
        def suspend():
            check_lock()
            if vm["status"] != "running":
                raise ApiFailure(500, f"VM {vmid} not running")
            assert p.get("todisk") == "1", "dispatch should hibernate, not suspend to RAM"
            vm["status"] = "stopped"
            vm["lock"] = "suspended"
        return run(state, suspend)
    if method == "POST" and rest == "status/resume":
        vm["paused"] = False
        return task(state)
    if method == "POST" and rest in ("status/shutdown", "status/stop"):
        def stop():
            check_lock()
            if vm["status"] != "running":
                raise ApiFailure(500, f"VM {vmid} not running")
            vm["status"] = "stopped"
        return run(state, stop)
    if method == "DELETE" and rest == "":
        def destroy():
            if vm["lock"] and vm["lock"] != "suspended":
                raise ApiFailure(500, f"VM is locked ({vm['lock']})")
            if vm["status"] == "running":
                raise ApiFailure(500, f"VM {vmid} is running - destroy failed")
            if vm["template"] and any(o["base"] == vmid for o in state.vms.values()):
                raise ApiFailure(500, "base volume is still in use by linked cloned")
            del state.vms[vmid]
        return run(state, destroy)
    if method == "POST" and rest == "agent/ping":
        if vm["status"] != "running":
            raise ApiFailure(500, f"VM {vmid} is not running")
        return {}
    if method == "POST" and rest == "agent/exec":
        if vm["status"] != "running":
            raise ApiFailure(500, f"VM {vmid} is not running")
        pid = next(state.pids)
        state.execs[pid] = vmid
        state.exec_log.append({"vmid": vmid, "command": raw["command"], "stdin": p.get("input-data", "")})
        return {"pid": pid}
    if method == "GET" and rest == "agent/exec-status":
        return {"exited": 1, "exitcode": 0, "out-data": "started amp orb bootstrap in unit amp-orb-bootstrap-1\n"}
    raise ApiFailure(501, f"not implemented: {method} {path}")


def serve():
    state = State()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return state, server
