#!/usr/bin/env python3
"""Real timeout-wrapper CLI: diagnostics stay with its owned process group."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
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


class HostedIdleEvidenceTests(unittest.TestCase):
    controls_run: Path | None = None
    blocked_run: Path | None = None

    def read_json(self, path: Path) -> dict:
        return json.loads(path.read_text())

    def capture(self, root: Path, method: str) -> tuple[dict, dict, str]:
        summary = self.read_json(root / "summary.json")
        self.assertEqual((summary["passedTests"], summary["failedTests"], summary["skippedTests"], summary["totalTestCount"]),
                         (1, 0, 0, 1))
        evidence = root / "test-evidence"
        process = self.read_json(evidence / "process.json")
        self.assertEqual(process["exit_code"], 0)
        self.assertIsNone(process["timeout_reason"])
        self.assertIn(f"-only-testing:TronMobileUITests/TronIdleControlUITests/{method}", process["command"])
        trigger = self.read_json(evidence / "xctest-idle.json")
        self.assertEqual(trigger["classification"], "provisional-prolonged-xctest-idle")
        self.assertGreaterEqual(trigger["no_xctest_progress_seconds"], 15)
        self.assertFalse(trigger["actual_animation_warning_observed"])
        app = self.read_json(evidence / "app-capture.json")
        self.assertEqual(app["signal"], "sent")
        self.assertEqual(app.get("sample"), "captured", app)
        self.assertNotIn("error", app)
        self.assertGreater(app["process_birth"]["seconds"], 0)
        metadata = self.read_json(root / "metadata.json")
        self.assertEqual(hashlib.sha256(app["simulator"].encode()).hexdigest(), metadata["simulator_udid_sha256"])
        self.assertIn(f"/Devices/{app['simulator']}/data/Containers/Bundle/Application/", app["executable"])
        self.assertTrue(app["executable"].endswith("/TronMobile.app/TronMobile"))
        sample = (evidence / "app-main-thread.sample.txt").read_text()
        self.assertIn(f"Process:         TronMobile [{app['pid']}]", sample)
        self.assertIn("com.apple.main-thread", sample)
        self.assertLessEqual(len(sample.encode()), 256_000)
        log = (root / "test.log").read_text()
        self.assertIn(f"Terminate com.tron.mobile.testhost:{app['pid']}", log)
        return trigger, app, sample

    def test_animation_capture_and_unsampled_negative_controls(self) -> None:
        assert self.controls_run is not None
        root = self.controls_run
        trigger, app, _ = self.capture(root, "testActualXCTestIdleControls")
        log = (root / "test.log").read_text()
        controls = re.findall(r"XCTEST_IDLE_CONTROL kind=([\w-]+) elapsed=([0-9.]+)", log)
        self.assertEqual([kind for kind, _ in controls], ["baseline", "orb", "covered-orb", "swiftui", "uikit"])
        for kind, elapsed in controls[:-1]:
            self.assertLess(float(elapsed), 15, f"{kind} unexpectedly held XCTest idle")
        negative_log = log[:log.index("XCTEST_IDLE_CONTROL kind=swiftui")]
        last_negative_progress = float(re.findall(r"t =\s*([0-9.]+)s", negative_log)[-1])
        self.assertGreater(trigger["xctest_elapsed_seconds"], last_negative_progress)
        self.assertEqual(app["snapshot"], "received")
        snapshot = self.read_json(root / "test-evidence/app-animation-state.json")
        self.assertEqual((snapshot["pid"], snapshot["launch"], snapshot["request"]),
                         (app["pid"], app["launch"], app["request"]))
        self.assertEqual(snapshot["process_birth"], app["process_birth"])
        self.assertTrue(snapshot["mainThread"])
        self.assertFalse(snapshot["truncated"])
        self.assertTrue(snapshot["animationsEnabled"])
        self.assertEqual(snapshot["surfaceCoordinators"], [
            {"active": 1, "continuousAnimationAllowed": 1, "covered": 0, "mounted": 1,
             "activityCountLimit": 64, "activityCountsTruncated": 0},
        ])
        animations = [animation for layer in snapshot["animatedLayers"] for animation in layer["animations"]]
        self.assertTrue(any(animation["type"] == "CABasicAnimation" and animation["autoreverses"]
                            and animation["repeatCount"] > 1 and animation["duration"] == 0.8
                            for animation in animations), snapshot)

    def test_blocked_main_retains_unanswered_signal_and_external_sample(self) -> None:
        assert self.blocked_run is not None
        root = self.blocked_run
        _, app, sample = self.capture(root, "testBlockedMainThreadIdleCapture")
        self.assertEqual(app["snapshot"], "not-received-within-2s")
        self.assertFalse((root / "test-evidence/app-animation-state.json").exists())
        main_thread = re.split(r"\n\s+\d+ Thread_", sample.split("com.apple.main-thread", 1)[1], maxsplit=1)[0]
        self.assertRegex(main_thread, r"(?:sleep|Sleep)")
        self.assertIn("XCTEST_IDLE_CONTROL kind=blocked-main", (root / "test.log").read_text())


def run_hosted_idle() -> int:
    identity_command = [sys.executable, str(ROOT / "scripts/ios-test-build-identity.py"), "show", "--worktree", str(ROOT)]
    source = json.loads(subprocess.check_output(identity_command, timeout=10))
    runs = []
    for method in ("testActualXCTestIdleControls", "testBlockedMainThreadIdleCapture"):
        command = [str(ROOT / "scripts/tron-ios-test"), "checkpoint" if not runs else "run", "--only-testing",
                   f"TronMobileUITests/TronIdleControlUITests/{method}"]
        process = None
        completed = []
        cancelled = None
        invoked = int(time.time())

        def forward(signum, _frame):
            nonlocal cancelled
            cancelled = signum
            try:
                if process is not None:
                    os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass

        handlers = {number: signal.signal(number, forward) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=True)
            if cancelled is not None:
                forward(cancelled, None)
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="", flush=True)
                if line.startswith("iOS test run complete: "):
                    completed.append(Path(line.removeprefix("iOS test run complete: ").strip()).resolve())
            status = process.wait(timeout=5)
            if cancelled is not None:
                return 128 + cancelled
            if status:
                return status if status > 0 else 128 - status
        finally:
            if process is not None:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait(timeout=40)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
                    except ProcessLookupError:
                        pass
                process.stdout.close()
            for number, handler in handlers.items():
                signal.signal(number, handler)
        if len(completed) != 1 or completed[0] in runs:
            raise ValueError("idle owner requires one distinct completed run per invocation")
        directory = completed[0]
        metadata = json.loads((directory / "metadata.json").read_text())
        owner = json.loads((directory / "owner.json").read_text())
        if (metadata["source"] != source or Path(owner["worktree"]).resolve() != ROOT.resolve()
                or owner["command"] != command[1] or metadata["command"] != command[1]
                or owner["started_epoch_seconds"] < invoked):
            raise ValueError("idle evidence does not match this worktree's frozen source")
        runs.append(directory)
    if json.loads(subprocess.check_output(identity_command, timeout=10)) != source:
        raise ValueError("idle evidence source changed during validation")
    HostedIdleEvidenceTests.controls_run, HostedIdleEvidenceTests.blocked_run = runs
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(HostedIdleEvidenceTests)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--hosted-idle", action="store_true")
    parser.add_argument("--idle-controls-run", type=Path)
    parser.add_argument("--blocked-main-run", type=Path)
    arguments, remaining = parser.parse_known_args()
    if arguments.hosted_idle:
        if arguments.idle_controls_run or arguments.blocked_main_run or remaining:
            parser.error("--hosted-idle owns both isolated runs and takes no other arguments")
        raise SystemExit(run_hosted_idle())
    if arguments.idle_controls_run or arguments.blocked_main_run:
        HostedIdleEvidenceTests.controls_run = arguments.idle_controls_run
        HostedIdleEvidenceTests.blocked_run = arguments.blocked_main_run
        suite = unittest.TestSuite()
        if arguments.idle_controls_run:
            suite.addTest(HostedIdleEvidenceTests("test_animation_capture_and_unsampled_negative_controls"))
        if arguments.blocked_main_run:
            suite.addTest(HostedIdleEvidenceTests("test_blocked_main_retains_unanswered_signal_and_external_sample"))
        raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
    unittest.main(argv=[sys.argv[0], *remaining], defaultTest="TimeoutEvidenceTests")
