#!/usr/bin/env python3
"""XcodeGen and release-Xcode admission through the real verifier and private executable/preset files.

No tools are installed or projects generated. Tests leave a regenerable unittest
log through the caller; each real process and file fixture is scoped to one case.
"""
import os
from pathlib import Path
import shlex
import shutil
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


class ReleaseXcodeAdmissionTests(unittest.TestCase):
    """`release`: the manual iOS release's exact Xcode, build and SDK, from a copy of the verifier
    whose configuration names a private Xcode directory and private xcodebuild/xcrun."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tron-release-xcode-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "config").mkdir()
        (self.root / "bin").mkdir()
        (self.root / "scripts/verify-ci-toolchain.sh").write_text(VERIFIER.read_text())
        (self.root / ".node-version").write_text((ROOT / ".node-version").read_text())
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.developer.mkdir(parents=True)

    def admit(self, developer_dir, version="Xcode 26.6\nBuild version 17F113", sdk="26.5", first_launch=0, free_gb=1,
              machine="arm64", path=None):
        (self.root / "config/ci-toolchain.env").write_text(
            "TRON_RELEASE_IOS_XCODE_VERSION=26.6\nTRON_RELEASE_IOS_XCODE_BUILD=17F113\n"
            f"TRON_RELEASE_IOS_SDK_VERSION=26.5\nTRON_RELEASE_IOS_DEVELOPER_DIR={developer_dir}\n"
            f"TRON_RELEASE_IOS_MIN_FREE_GB={free_gb}\n")
        for name, body in (("xcodebuild", f'[[ $1 == -checkFirstLaunchStatus ]] && exit {first_launch}\n'
                                          f'[[ $DEVELOPER_DIR == {shlex.quote(str(developer_dir))} ]] || exit 9\n'
                                          f'printf %b {shlex.quote(version)}'),
                           ("xcrun", f"printf '%s\\n' {shlex.quote(sdk)}"),
                           ("uname", f'[[ $1 == -m ]] && echo {machine} || echo Darwin')):
            tool = self.root / "bin" / name
            tool.write_text(f"#!/bin/bash\n{body}\n")
            tool.chmod(0o700)
        search = path if path is not None else str(self.root / "bin") + os.pathsep + os.environ["PATH"]
        return subprocess.run(["/bin/bash", str(self.root / "scripts/verify-ci-toolchain.sh"), "release"], capture_output=True,
                              text=True, timeout=30, env=dict(os.environ, PATH=search))

    def path_without(self, missing):
        """The private tools plus links to every system tool the check uses, except `missing`."""
        system = self.root / "system"
        system.mkdir(exist_ok=True)
        for name in ("dirname", "sed", "awk", "df", "python3", "security", "codesign"):
            found = shutil.which(name)
            if name != missing and found and not (system / name).exists():
                (system / name).symlink_to(found)
        return str(self.root / "bin") + os.pathsep + str(system)

    def test_the_pinned_xcode_build_and_sdk_are_admitted(self):
        completed = self.admit(self.developer)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_each_mismatch_is_refused_and_named(self):
        beta = self.root / "Xcode-beta.app/Contents/Developer"
        beta.mkdir(parents=True)
        for kwargs, message in ((dict(developer_dir=beta), "release Xcode must not be a beta bundle"),
                                (dict(developer_dir=self.root / "Missing.app/Contents/Developer"), "release Xcode is not installed"),
                                (dict(developer_dir=self.developer, version="Xcode 26.6\nBuild version 17F999"),
                                 "release Xcode must be 26.6 (17F113); found: Xcode 26.6 Build version 17F999"),
                                (dict(developer_dir=self.developer, sdk="26.4"), "release iPhoneOS SDK must be 26.5; found: 26.4"),
                                (dict(developer_dir=self.developer, first_launch=1), "first-launch tasks or license acceptance"),
                                (dict(developer_dir=self.developer, free_gb=10 ** 9), "GB free beside the checkout"),
                                (dict(developer_dir=self.developer, free_gb=0), "must be a whole number of GB"),
                                (dict(developer_dir=self.developer, free_gb="abc"), "must be a whole number of GB"),
                                (dict(developer_dir=self.developer, machine="x86_64"), "a release archives on an Apple silicon Mac")):
            with self.subTest(message=message):
                completed = self.admit(**kwargs)
                self.assertEqual(completed.returncode, 1, completed.stderr)
                self.assertIn(message, completed.stderr)

    def test_each_missing_release_tool_is_named(self):
        for tool in ("python3", "security", "codesign"):
            with self.subTest(tool=tool):
                shutil.rmtree(self.root / "system", ignore_errors=True)
                completed = self.admit(self.developer, path=self.path_without(tool))
                self.assertEqual(completed.returncode, 1, completed.stderr)
                self.assertIn(f"release needs {tool}", completed.stderr)
        shutil.rmtree(self.root / "system", ignore_errors=True)
        completed = self.admit(self.developer, path=self.path_without(None))
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
