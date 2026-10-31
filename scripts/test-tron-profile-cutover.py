#!/usr/bin/env python3
"""The supported maintainer entrypoint exists without touching Stable."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ProfileCutoverCommand(unittest.TestCase):
    def test_supported_entrypoint(self):
        result = subprocess.run([ROOT / 'scripts/tron', 'profile', 'cutover', '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('--rollback', result.stdout)
        self.assertIn('--apply', result.stdout)

if __name__ == '__main__':
    unittest.main()
