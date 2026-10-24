"""Run dispatch.py the way `amp orb provider` does, against tests/fake_pve.py.

    python3 -m unittest discover -s tests
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import fake_pve  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DISPATCH = ROOT / "provider" / "dispatch.py"
CHECK_KERNEL = ROOT / "host" / "check-kernel.sh"
IMAGE = "us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest"

# (release, safe?) -- includes cases a naive comparison gets wrong: a higher
# ABI on an older patch level, and newer series with lower patch/ABI numbers.
KERNELS = [
    ("7.0.14-23-pve", False),
    ("7.0.14-24-pve", True),
    ("7.0.15-1-pve", True),
    ("7.0.9-30-pve", False),
    ("6.17.2-1-pve", False),
    ("6.8.12-9-pve", False),
    ("7.1.0-1-pve", True),
    ("8.0.1-1-pve", True),
    ("6.12.113", False),
]


class DispatchTest(unittest.TestCase):
    def setUp(self):
        self.state, self.server = fake_pve.serve()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.state.add_vm(9000, "amp-orb-base-202610240000", template=True,
                          description=f"managed-by: amp-orbs-proxmox\nimage: {IMAGE}")
        self.lock = tempfile.NamedTemporaryFile()
        self.addCleanup(self.lock.close)

    def dispatch(self, operation, orb_id="amp-T-1", **extra):
        env = {
            "PATH": os.environ["PATH"],
            "PVE_API_URL": f"http://127.0.0.1:{self.server.server_port}",
            "PVE_TOKEN_ID": "amp-orbs@pve!provider",
            "PVE_TOKEN_SECRET": "secret",
            "PVE_NODE": "pve",
            "ORB_LOCK_FILE": self.lock.name,
            "ORB_POLL_SECONDS": "0",
            "ORB_OPERATION": operation,
            "ORB_ID": orb_id,
            "ORB_IMAGE": IMAGE,
            **extra,
        }
        if operation == "spawn":
            env.setdefault("ORB_TOKEN", "orb-token")
        return subprocess.run([sys.executable, "-I", str(DISPATCH)], env=env,
                              capture_output=True, text=True, timeout=60)

    def orbs(self):
        return {vm["name"]: vm for vm in self.state.vms.values() if vm["name"].startswith("orb-")}

    def test_vulnerable_kernel_blocks_new_orbs(self):
        self.state.kernel = "7.0.14-23-pve"
        result = self.dispatch("spawn")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CVE-2026-99999", result.stdout)
        self.assertEqual(self.orbs(), {})
        self.assertEqual(self.state.exec_log, [])

    def test_vulnerable_kernel_blocks_resume_but_not_pause_or_delete(self):
        self.assertEqual(self.dispatch("spawn").returncode, 0)
        self.assertEqual(self.dispatch("pause").returncode, 0)
        (orb,) = self.orbs().values()
        self.assertEqual(orb["lock"], "suspended")

        self.state.kernel = "6.17.2-1-pve"  # e.g. rebooted into an old kernel
        self.assertNotEqual(self.dispatch("spawn").returncode, 0)
        self.assertEqual(orb["status"], "stopped")
        self.assertEqual(orb["lock"], "suspended")

        # Stopping and removing orbs reduces exposure, so it keeps working.
        self.assertEqual(self.dispatch("delete").returncode, 0)
        self.assertEqual(self.orbs(), {})

    def test_fixed_kernel_spawns_orb(self):
        result = self.dispatch("spawn")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (orb,) = self.orbs().values()
        self.assertEqual(orb["status"], "running")
        self.assertIn("ORB_TOKEN=orb-token", self.state.exec_log[-1]["stdin"])

    def test_pause_hibernates_and_spawn_resumes_the_same_vm(self):
        self.assertEqual(self.dispatch("spawn").returncode, 0)
        (orb,) = self.orbs().values()
        for _ in range(2):  # every job must be safe to repeat
            result = self.dispatch("pause")
            self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((orb["status"], orb["lock"]), ("stopped", "suspended"))
        for _ in range(2):
            result = self.dispatch("spawn", ORB_TOKEN="second-token")
            self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.orbs()), 1)
        # Resumed from RAM, not rebooted, and bootstrap got the new token.
        self.assertEqual((orb["status"], orb["lock"], orb["boots"]), ("running", None, 1))
        self.assertIn("ORB_TOKEN=second-token", self.state.exec_log[-1]["stdin"])
        for _ in range(2):
            self.assertEqual(self.dispatch("delete").returncode, 0)
        self.assertEqual(self.orbs(), {})

    def test_project_snapshot_is_saved_on_pause_and_used_by_new_orbs(self):
        self.assertEqual(self.dispatch("spawn", orb_id="amp-T-1").returncode, 0)
        result = self.dispatch("pause", orb_id="amp-T-1", ORB_SNAPSHOT_ID="snap-1")
        self.assertEqual(result.returncode, 0, result.stdout)
        snaps = [vm for vm in self.state.vms.values() if vm["name"].startswith("amp-snap-")]
        self.assertEqual(len(snaps), 1)
        snap = snaps[0]
        self.assertTrue(snap["template"])
        self.assertTrue(snap["full"])  # independent of the orb it came from
        # The machine ID was reset before the copy so clones get their own.
        self.assertIn("/etc/machine-id", " ".join(self.state.exec_log[-1]["command"]))
        self.assertEqual(self.dispatch("spawn", orb_id="amp-T-1").returncode, 0)

        self.assertEqual(self.dispatch("spawn", orb_id="amp-T-2", ORB_SNAPSHOT_ID="snap-1").returncode, 0)
        self.assertEqual(self.dispatch("spawn", orb_id="amp-T-3", ORB_SNAPSHOT_ID="unknown").returncode, 0)
        sources = {vm["description"].split("orb-id: ")[1].split("\n")[0]: vm["cloned_from"]
                   for vm in self.orbs().values()}
        self.assertEqual(sources, {"amp-T-1": 9000, "amp-T-2": snap["vmid"], "amp-T-3": 9000})

    def test_vmids_used_by_invisible_vms_are_skipped(self):
        self.state.foreign_vmids = {20000, 20001}
        self.assertEqual(self.dispatch("spawn").returncode, 0)
        self.assertEqual([vm["vmid"] for vm in self.orbs().values()], [20002])

    def test_kernel_verdicts_match_between_dispatch_and_host_script(self):
        sys.path.insert(0, str(DISPATCH.parent))
        import dispatch
        for release, safe in KERNELS:
            with self.subTest(release=release):
                self.assertEqual(dispatch.kernel_problem(release) is None, safe)
                script = subprocess.run(["bash", str(CHECK_KERNEL), release], capture_output=True)
                self.assertEqual(script.returncode == 0, safe)


if __name__ == "__main__":
    unittest.main()
