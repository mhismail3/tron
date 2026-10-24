#!/usr/bin/env python3
"""XcodeGen admission through the real verifier and private executable/preset files.

No tools are installed or projects generated. Tests leave a regenerable unittest
log through the caller; each real process and file fixture is scoped to one case.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
VERIFIER = ROOT / "scripts/verify-ci-toolchain.sh"
PIN = next(line.split("=", 1)[1].strip('"\'')
           for line in (ROOT / "config/ci-toolchain.env").read_text().splitlines()
           if line.startswith("TRON_CI_XCODEGEN_VERSION="))


class XcodeGenAdmissionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tron-xcodegen-pin-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "bin").mkdir()
        self.presets = self.root / "share/xcodegen/SettingPresets"
        (self.presets / "Platforms").mkdir(parents=True)
        for name in ("base.yml", "Platforms/iOS.yml", "Platforms/macOS.yml"):
            (self.presets / name).write_text("{}\n")

    def probe(self, response, exit_code=0):
        executable = self.root / "bin/xcodegen"
        executable.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(response)
                              + f"\nexit {exit_code}\n")
        executable.chmod(0o700)
        return subprocess.run(
            ["bash", str(VERIFIER), "xcodegen"], capture_output=True, text=True, timeout=30,
            env=dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"]))

    def test_only_the_exact_version_response_is_admitted(self):
        for response, accepted in ((f"Version: {PIN}", True),
                                   (f"Version: 1{PIN}", False),
                                   (f"Version: {PIN}.1", False),
                                   (f"Version: {PIN}-beta.1", False),
                                   ("Version: 99.0.0", False),
                                   (f"Version: 99.0.0\nVersion: {PIN}", False)):
            with self.subTest(response=response):
                completed = self.probe(response)
                self.assertEqual(completed.returncode == 0, accepted, completed.stderr)

    def test_a_failed_version_probe_is_not_admitted(self):
        completed = self.probe(f"Version: {PIN}", exit_code=23)
        self.assertNotEqual(completed.returncode, 0, completed.stderr)

    def test_each_missing_required_preset_is_refused(self):
        for name in ("base.yml", "Platforms/iOS.yml", "Platforms/macOS.yml"):
            with self.subTest(preset=name):
                path = self.presets / name
                path.unlink()
                try:
                    completed = self.probe(f"Version: {PIN}")
                    self.assertNotEqual(completed.returncode, 0, completed.stderr)
                    self.assertIn("setting presets are incomplete", completed.stderr)
                finally:
                    path.write_text("{}\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
