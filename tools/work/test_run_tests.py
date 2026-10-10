"""Isolated checks for run_tests.py, the work-tooling test runner (README.md, "Tron's check set").

Failure modes: a failing module leaves the run green; its output is hidden; an interrupt leaves
a module or a descendant it started running. The runner is copied beside fixture modules and
run as a script, so it selects exactly those modules. Oracles are the exit status and printed
results, and the process table after an interrupt; no test asserts on elapsed time.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().with_name("run_tests.py")

PASSING = """import unittest


class PassingTests(unittest.TestCase):
    def test_passes(self):
        self.assertTrue(True)
"""

FAILING = """import unittest


class FailingTests(unittest.TestCase):
    def test_fails(self):
        self.assertEqual("fixture-expected", "fixture-actual")
"""

# The module starts a grandchild in its own process group, then reports both pids through
# the file named by HOLD_PIDS, so the test knows the processes exist before it interrupts.
HOLDING = """import os
import subprocess
import sys
import time
import unittest


class HoldingTests(unittest.TestCase):
    def test_holds_with_a_descendant(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
        with open(os.environ["HOLD_PIDS"], "w") as handle:
            handle.write(f"{os.getpid()}\\n{child.pid}\\n")
        time.sleep(600)
"""


def _pid_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


class RunTestsTests(unittest.TestCase):
    def fixture(self, modules: dict) -> Path:
        temporary = tempfile.TemporaryDirectory(prefix="run-tests-fixture-")
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        (directory / "run_tests.py").write_text(RUNNER.read_text())
        for name, source in modules.items():
            (directory / f"{name}.py").write_text(source)
        return directory

    def test_a_failing_module_fails_the_run_and_its_full_output_is_shown(self):
        fixture = self.fixture({"test_pass": PASSING, "test_fail": FAILING})
        result = subprocess.run([sys.executable, str(fixture / "run_tests.py")], cwd=fixture,
                                env={**os.environ, "WORK_TEST_JOBS": "2"},
                                capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("test_pass: passed", result.stdout)
        self.assertIn("test_fail: FAILED (exit 1)", result.stdout)
        self.assertIn("===== test_fail: full output =====", result.stdout)
        self.assertIn("'fixture-expected' != 'fixture-actual'", result.stdout)
        self.assertNotIn("===== test_pass", result.stdout)

    def test_interrupt_retires_a_running_module_and_the_descendants_it_started(self):
        fixture = self.fixture({"test_hold": HOLDING})
        pids_file = fixture / "pids.txt"
        runner = subprocess.Popen(
            [sys.executable, str(fixture / "run_tests.py")], cwd=fixture,
            env={**os.environ, "WORK_TEST_JOBS": "1", "HOLD_PIDS": str(pids_file)},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        module_pid = child_pid = None

        def release():
            # Failsafe only: reclaims what this test started if the runner did not retire it.
            for pid in (module_pid, child_pid):
                if pid is not None and not _pid_gone(pid):
                    os.kill(pid, signal.SIGKILL)
            if runner.poll() is None:
                os.killpg(runner.pid, signal.SIGKILL)
                runner.wait()

        self.addCleanup(release)
        # Event: the module has started its descendant. Waiting on the file is not timing.
        self.wait_for(lambda: pids_file.exists() and pids_file.read_text().count("\n") == 2)
        module_pid, child_pid = (int(line) for line in pids_file.read_text().split())

        runner.send_signal(signal.SIGINT)
        code = runner.wait(timeout=300)

        self.assertEqual(code, 128 + signal.SIGINT)
        self.wait_for(lambda: _pid_gone(module_pid) and _pid_gone(child_pid))

    def wait_for(self, condition, attempts: int = 6000):
        # Bounded poll of an observable event; the bound only stops a hung test.
        for _ in range(attempts):
            if condition():
                return
            time.sleep(0.01)
        self.fail("expected event did not occur")


if __name__ == "__main__":
    unittest.main()
