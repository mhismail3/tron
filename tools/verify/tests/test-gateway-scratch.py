#!/usr/bin/env python3
"""The Gateway test runner's scratch roots: a run killed outright leaves its root, and the next run
removes it; a live run's root and a root from a runner that predates the owner lock are kept.

Each case runs the shipped tools/verify/gateway.py and host_lock.py from a disposable copy whose
scratch parent and host lock point inside the case's temporary directory, with a stand-in Node and
Vitest, so the host's /tmp is never touched.
"""
from pathlib import Path
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
# Records its HOME; a run of held.test.ts then waits while the hold file exists, so a case can kill
# the runner mid-run or start a second run beside it.
FAKE_VITEST = """#!/usr/bin/env python3
import json, os, pathlib, sys, time
with open(os.environ["RUNS"], "a") as runs:
    runs.write(json.dumps({"home": os.environ["HOME"], "pid": os.getpid()}) + "\\n")
while sys.argv[-1] == "held.test.ts" and pathlib.Path(os.environ["RUNS"] + ".hold").exists():
    time.sleep(0.05)
"""


class ScratchReaper(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="tron-gateway-scratch-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.parent = self.base / "scratch"
        self.parent.mkdir()
        self.root = self.base / "repo"
        verify = self.root / "tools/verify"
        verify.mkdir(parents=True)
        gateway = (ROOT / "tools/verify/gateway.py").read_text()
        self.assertIn("SCRATCH_PARENT = '/tmp'", gateway)
        (verify / "gateway.py").write_text(gateway.replace("SCRATCH_PARENT = '/tmp'", f"SCRATCH_PARENT = {str(self.parent)!r}"))
        lock = (ROOT / "tools/verify/host_lock.py").read_text()
        self.assertIn("'/tmp/tron-full-gateway.lock'", lock)
        (verify / "host_lock.py").write_text(lock.replace("'/tmp/tron-full-gateway.lock'", repr(str(self.base / "full.lock"))))
        (self.root / "scripts").mkdir()
        node = self.root / "scripts/tron-node"
        node.write_text('#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
        vitest = self.root / "packages/gateway/node_modules/.bin/vitest"
        vitest.parent.mkdir(parents=True)
        vitest.write_text(FAKE_VITEST)
        for script in (node, vitest):
            script.chmod(0o755)
        self.runs = self.base / "runs.jsonl"
        self.env = {**os.environ, "RUNS": str(self.runs)}
        self.env.pop("TRON_FULL_GATEWAY_LOCK_HELD", None)

    def start(self, *, hold: bool) -> subprocess.Popen:
        if hold:
            Path(str(self.runs) + ".hold").touch()
        return subprocess.Popen([sys.executable, str(self.root / "tools/verify/gateway.py"),
                                 "held.test.ts" if hold else "x.test.ts"], env=self.env,
                                stderr=subprocess.PIPE, text=True, start_new_session=True)

    def homes(self) -> list[str]:
        return [json.loads(line)["home"] for line in self.runs.read_text().splitlines()] if self.runs.exists() else []

    def wait_for_runs(self, count: int) -> None:
        deadline = time.monotonic() + 30
        while len(self.homes()) < count:
            self.assertLess(time.monotonic(), deadline, "the runner never started Vitest")
            time.sleep(0.05)

    def test_a_killed_runs_scratch_is_removed_by_the_next_run(self) -> None:
        killed = self.start(hold=True)
        self.wait_for_runs(1)
        os.killpg(killed.pid, signal.SIGKILL)  # runner and Vitest together: nothing can clean up
        killed.wait()
        abandoned = Path(self.homes()[0]).parent
        self.assertTrue(abandoned.is_dir(), "a SIGKILLed run has nothing to clean up with")
        Path(str(self.runs) + ".hold").unlink()
        after = self.start(hold=False)
        _, errors = after.communicate(timeout=60)
        self.assertEqual(after.returncode, 0, errors)
        self.assertFalse(abandoned.exists(), errors)
        self.assertIn(f"removed abandoned scratch {abandoned}", errors)
        self.assertEqual(sorted(self.parent.iterdir()), [], "the run also removed its own scratch")

    def test_a_root_stays_owned_while_vitest_outlives_its_runner(self) -> None:
        orphaned = self.start(hold=True)
        self.wait_for_runs(1)
        os.kill(orphaned.pid, signal.SIGKILL)  # the runner only; its Vitest keeps the inherited lock
        orphaned.wait()
        owned = Path(self.homes()[0]).parent
        vitest = json.loads(self.runs.read_text().splitlines()[0])["pid"]
        try:
            second = subprocess.run([sys.executable, str(self.root / "tools/verify/gateway.py"), "y.test.ts"],
                                    env=self.env, capture_output=True, text=True, timeout=60)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertTrue(owned.is_dir(), "a root whose Vitest still runs was removed")
        finally:
            Path(str(self.runs) + ".hold").unlink(missing_ok=True)
        deadline = time.monotonic() + 30
        while True:  # the orphaned Vitest exits once released
            try:
                os.kill(vitest, 0)
            except ProcessLookupError:
                break
            self.assertLess(time.monotonic(), deadline, "the orphaned Vitest never exited")
            time.sleep(0.05)
        third = subprocess.run([sys.executable, str(self.root / "tools/verify/gateway.py"), "z.test.ts"],
                               env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertFalse(owned.exists(), third.stderr)

    def test_a_live_runs_scratch_and_a_lockless_root_are_kept(self) -> None:
        legacy = self.parent / "tron-gateway-tests-legacy"
        (legacy / "home").mkdir(parents=True)
        live = self.start(hold=True)
        self.wait_for_runs(1)
        owned = Path(self.homes()[0]).parent
        try:
            # A second run inside the holder's lock, as a batch lane runs; the first is still live.
            second = subprocess.run([sys.executable, str(self.root / "tools/verify/gateway.py"), "y.test.ts"],
                                    env={**self.env, "TRON_FULL_GATEWAY_LOCK_HELD": "1"}, capture_output=True,
                                    text=True, timeout=60)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertTrue(owned.is_dir(), second.stderr)
            self.assertTrue(legacy.is_dir(), second.stderr)
            self.assertNotIn("removed abandoned scratch", second.stderr)
        finally:
            Path(str(self.runs) + ".hold").unlink(missing_ok=True)
            live.communicate(timeout=60)
        self.assertEqual(live.returncode, 0)
        self.assertFalse(owned.exists())
        shutil.rmtree(legacy)


if __name__ == "__main__":
    unittest.main(verbosity=2)
