#!/usr/bin/env python3
"""Guards scripts/tron version on the real tree: the mirrors VERSION.env names are in sync, and the
helper's own self-test (field derivation, asset names, refused aliases and invalid versions) passes.

A removal probe found tron-version silent: its self-test existed but nothing ran it.
"""
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def tron(*args: str) -> subprocess.CompletedProcess:
    # The self-test also checks the pinned Node, so it runs with that Node first on PATH.
    return subprocess.run([str(ROOT / "scripts/tron-node"), "exec", str(ROOT / "scripts/tron"), "version", *args],
                          cwd=ROOT, capture_output=True, text=True, timeout=120)


class VersionHelperTests(unittest.TestCase):
    def test_the_mirrors_are_in_sync_with_version_env(self):
        result = tron("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Version mirrors are in sync", result.stdout)

    def test_the_helpers_self_test_passes(self):
        result = tron("test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Version helper tests passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
