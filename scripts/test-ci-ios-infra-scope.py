#!/usr/bin/env python3
"""Failure modes: unrelated changes wastefully run iOS infrastructure; an unrecognized or iOS-owned path is skipped."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ci_ios_infra_scope import should_run

SCRIPT = Path(__file__).with_name("ci_ios_infra_scope.py")


class IOSInfrastructureScopeTests(unittest.TestCase):
    def test_docs_and_known_non_ios_changes_skip_infrastructure_suite(self):
        self.assertFalse(should_run(["README.md", "packages/gateway/src/transport/session-sync.ts"]))
        self.assertFalse(should_run(["scripts/tron-version"]))

    def test_ios_owned_paths_keep_infrastructure_suite(self):
        self.assertTrue(should_run(["packages/ios-app/Sources/UI/Settings/SettingsView.swift"]))
        self.assertTrue(should_run(["scripts/tron-ios-test"]))
        self.assertTrue(should_run(["scripts/ci_ios_infra_scope.py"]))
        self.assertTrue(should_run(["config/ci-toolchain.env"]))

    def test_unknown_and_empty_path_sets_fail_closed(self):
        self.assertTrue(should_run(["unclassified/new-file.xyz"]))
        self.assertTrue(should_run(["scripts/new-ios-infrastructure.py"]))
        self.assertTrue(should_run(["unclassified\nREADME.md"]))
        self.assertTrue(should_run([]))

    def test_path_file_uses_nul_delimiters_and_missing_file_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = Path(directory) / "paths.nul"
            paths.write_bytes(b"README.md\0packages/gateway/src/a.ts\0")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--paths-file", str(paths)],
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(result.stdout.strip(), "false")
            paths.write_bytes(b"unclassified\nREADME.md\0")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--paths-file", str(paths)],
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(result.stdout.strip(), "true")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--paths-file", str(paths / "missing")],
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(result.stdout.strip(), "true")


if __name__ == "__main__":
    unittest.main()
