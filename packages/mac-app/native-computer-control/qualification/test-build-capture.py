#!/usr/bin/env python3
"""The capture builder's owned command cleanup, through the real `build_capture.run` and a real child.

#2407: macOS answers killpg on a group whose members all exited but whose leader is not yet reaped
with EPERM, not ESRCH. A command that exits between the cleanup's liveness check and its signal must
leave the original outcome (here the build's timeout) intact, never a PermissionError. Each spy only
holds that window open: it ends the command, waits until it is a zombie, then returns the real answer.

Run: python3 packages/mac-app/native-computer-control/qualification/test-build-capture.py
"""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("build_capture", HERE / "build_capture.py")
build_capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_capture)
REAL_POLL, REAL_WAIT = subprocess.Popen.poll, subprocess.Popen.wait
COMMAND = [sys.executable, "-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"]


def end_unreaped(process):
    """Kill the command and hold until it is a zombie: exited, its group empty, its leader unreaped."""
    os.kill(process.pid, signal.SIGKILL)
    deadline = time.monotonic() + 60
    while not subprocess.run(["ps", "-o", "stat=", "-p", str(process.pid)], capture_output=True,
                             text=True).stdout.startswith("Z"):
        if time.monotonic() > deadline:
            raise AssertionError("the command never exited")
        time.sleep(0.02)


class OwnedCleanup(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.log = Path(temporary.name) / "build.log"
        self.windows = []

    def test_a_command_that_exits_before_the_terminate_keeps_the_timeout(self):
        """Window before the SIGTERM: the real poll still sees the command running, then it exits."""
        def poll(process):
            result = REAL_POLL(process)
            if result is None and not self.windows:
                end_unreaped(process)
                self.windows.append("terminate")
            return result

        with mock.patch.object(subprocess.Popen, "poll", poll), self.assertRaises(subprocess.TimeoutExpired):
            build_capture.run(COMMAND, self.log, timeout=0.5)
        self.assertEqual(self.windows, ["terminate"])

    def test_a_command_that_exits_before_the_kill_keeps_the_timeout(self):
        """Window before the SIGKILL: the command ignores SIGTERM, so the bounded wait times out; it
        exits just as that wait gives up."""
        def wait(process, timeout=None):
            if timeout == 5 and not self.windows:
                end_unreaped(process)
                self.windows.append("kill")
                raise subprocess.TimeoutExpired(process.args, timeout)
            return REAL_WAIT(process, timeout)

        with mock.patch.object(subprocess.Popen, "wait", wait), self.assertRaises(subprocess.TimeoutExpired):
            build_capture.run(COMMAND, self.log, timeout=0.5)
        self.assertEqual(self.windows, ["kill"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
