#!/usr/bin/env python3
"""Real timeout-wrapper CLI: diagnostics stay with its owned process group."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
PROCESS = ROOT / "scripts/ios-test-process.py"


class TimeoutEvidenceTests(unittest.TestCase):
    def capture(self, foreign_name: str | None = None, padding: int = 0) -> dict:
        with tempfile.TemporaryDirectory(prefix="tron-process-evidence-") as temporary:
            root = Path(temporary)
            binary = root / "bin"
            binary.mkdir()
            pid_file = root / "owned.pid"
            foreign = subprocess.Popen(["/bin/sleep", "25"])
            try:
                ps = binary / "ps"
                ps.write_text(
                    f"#!{sys.executable}\n"
                    "from pathlib import Path\n"
                    f"pid = int(Path({str(pid_file)!r}).read_text())\n"
                    f"print(f'{{pid}} {os.getpid()} {{pid}} S 00:01 fixture-owned ' + 'x' * {padding})\n"
                    + (f"print('{foreign.pid} {os.getpid()} {os.getpgrp()} S 00:01 {foreign_name} FOREIGN-FIXTURE')\n" if foreign_name else "")
                )
                ps.chmod(0o755)
                holder = "import os,time;from pathlib import Path;Path(%r).write_text(str(os.getpid()));print('owned',flush=True);time.sleep(25)" % str(pid_file)
                result = subprocess.run(
                    [sys.executable, str(PROCESS), "--log", str(root / "run.log"),
                     "--evidence-dir", str(root / "evidence"), "--overall-seconds", "0.5",
                     "--no-output-seconds", "2", "--term-grace-seconds", "0.2", "--",
                     sys.executable, "-u", "-c", holder],
                    env=dict(os.environ, PATH=str(binary) + os.pathsep + os.environ.get("PATH", "")),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
                )
                self.assertEqual(result.returncode, 124, result.stderr)
                receipt = json.loads((root / "evidence/process.json").read_text())
                timeout = json.loads((root / "evidence/timeout.json").read_text())
                self.assertEqual(receipt["timeout_reason"], "overall")
                self.assertEqual(receipt["exit_code"], -signal.SIGTERM)
                owned = int(pid_file.read_text())
                self.assertEqual(timeout["process_group"], owned)
                self.assertNotEqual(os.getpgid(foreign.pid), owned)
                self.assertIsNone(foreign.poll(), "wrapper signalled an unrelated fixture")
                with self.assertRaises(ProcessLookupError):
                    os.kill(owned, 0)
                return {
                    "tree": (root / "evidence/process-tree.txt").read_bytes(),
                    "samples": sorted(path.name for path in (root / "evidence").glob("sample-*.txt")),
                    "owned": owned,
                }
            finally:
                foreign.terminate()
                try:
                    foreign.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    foreign.kill()
                    foreign.wait()

    def test_foreign_named_processes_never_enter_owned_diagnostics(self) -> None:
        for name in ("testmanagerd", "TronMobile", "xcodebuild"):
            with self.subTest(command=name):
                evidence = self.capture(foreign_name=name)
                with self.subTest(boundary="retained process tree"):
                    self.assertNotIn(b"FOREIGN-FIXTURE", evidence["tree"])
                    self.assertIn(str(evidence["owned"]).encode(), evidence["tree"])
                if Path("/usr/bin/sample").exists():
                    with self.subTest(boundary="system sample admission"):
                        self.assertEqual(evidence["samples"], ["sample-0-test-host.txt"])

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS process birth and sample")
    def test_stale_readiness_cannot_signal_a_new_owned_incarnation(self) -> None:
        specification = importlib.util.spec_from_file_location("ios_process_evidence", PROCESS)
        owner = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(owner)
        with tempfile.TemporaryDirectory(prefix="tron-stale-readiness-") as temporary:
            root = Path(temporary)
            executable = root / "owned-sleep"
            subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(executable)],
                           input="#include <unistd.h>\nint main(void) { sleep(25); return 0; }\n",
                           text=True, check=True, timeout=20, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env={**os.environ, "HOME": str(root), "TMPDIR": str(root)})
            previous = subprocess.Popen([str(executable), "25"])
            try:
                stale_birth = owner.process_birth(previous.pid)
            finally:
                previous.terminate()
                previous.wait(timeout=5)
            current = subprocess.Popen([str(executable), "25"])
            try:
                birth = owner.process_birth(current.pid)
                self.assertNotEqual(birth, stale_birth)
                owner.atomic_json(root / "ready.json", {
                    "pid": current.pid, "launch": "previous-launch", "process_birth": stale_birth,
                })
                owner.capture_app_process(root, current.pid, owner.executable_path(current.pid), root,
                                          owner.bounded_command)
                receipt = json.loads((root / "app-capture.json").read_text())
                self.assertIsNone(current.poll(), "stale readiness sent default-terminating SIGUSR2")
                self.assertEqual(receipt["signal"], "not-sent")
                self.assertIn("another process incarnation", receipt["error"])
                self.assertEqual(receipt["process_birth"], birth)
                self.assertEqual(receipt.get("sample"), "captured", receipt)
                sample = (root / "app-main-thread.sample.txt").read_text()
                self.assertRegex(sample, rf"Process:.*\[{current.pid}\]")
                self.assertFalse((root / "request.json").exists())
                print("STALE_READINESS_CAPTURE " + json.dumps(receipt, sort_keys=True), flush=True)
                print(sample[:4096], flush=True)
            finally:
                if current.poll() is None:
                    current.terminate()
                current.wait(timeout=5)

    def test_retained_owned_process_tree_is_bounded(self) -> None:
        evidence = self.capture(padding=96_000)
        self.assertGreater(len(evidence["tree"]), 0)
        self.assertLessEqual(len(evidence["tree"]), 64 * 1024)
        self.assertIn(str(evidence["owned"]).encode(), evidence["tree"])


if __name__ == "__main__":
    unittest.main(defaultTest="TimeoutEvidenceTests")
