#!/usr/bin/env python3
"""Integration test for `scripts/tron proof bootstrap|doctor` (tools/proof/README.md).

One sequential journey through the real CLI with an isolated cache (XDG_CACHE_HOME in a temp dir) and a
clean environment (env -i, PATH=/usr/bin:/bin, so no other dafny, z3 or dotnet is reachable):

1. doctor on the clean cache fails: "pinned Dafny missing".
2. bootstrap installs the pinned archive and passes; doctor then reports the pinned Dafny and Z3 versions.
3. The pinned wrapper verifies a true fixture (also on the alternate bundled Z3), translates it with the
   one-core cap, and rejects a false law.
4. A one-byte tamper of the installed tree is rejected by doctor and by bootstrap.

The release archive is copied from the user's cache when present (bootstrap re-checks its digest);
otherwise bootstrap downloads it (needs network).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
PIN = dict(line.split("=", 1) for line in (ROOT / "tools/proof/dafny.pin").read_text().splitlines()
           if line and not line.startswith("#"))
ARCHIVE = PIN["DAFNY_URL"].rsplit("/", 1)[1]


class ProofToolchainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="tron-proof-test."))
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        self.cache = self.base / "cache"
        self.env = {"HOME": str(self.base / "home"), "PATH": "/usr/bin:/bin", "TMPDIR": str(self.base),
                    "XDG_CACHE_HOME": str(self.cache)}
        (self.base / "home").mkdir()
        user_archive = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / "Library/Caches") / "tron-proof/cache" / ARCHIVE
        if user_archive.is_file():
            (self.cache / "tron-proof/cache").mkdir(parents=True)
            shutil.copyfile(user_archive, self.cache / "tron-proof/cache" / ARCHIVE)

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["/usr/bin/env", "-i", *[f"{k}={v}" for k, v in self.env.items()],
                               str(ROOT / "scripts/tron"), "proof", *args],
                              capture_output=True, text=True, timeout=900)

    def dafny(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["/usr/bin/env", "-i", *[f"{k}={v}" for k, v in self.env.items()],
                               str(self.cache / "tron-proof/bin/dafny"), *args],
                              capture_output=True, text=True, timeout=300)

    def test_bootstrap_doctor_verify_and_tamper(self) -> None:
        for tool in ("dafny", "z3", "dotnet"):
            found = subprocess.run(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "/bin/sh", "-c", f"command -v {tool}"],
                                   capture_output=True, text=True)
            self.assertNotEqual(found.returncode, 0, f"{tool} reachable on the clean PATH: {found.stdout}")

        missing = self.run_cli("doctor")
        self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
        self.assertIn("pinned Dafny missing", missing.stderr)

        installed = self.run_cli("bootstrap")
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        doctor = self.run_cli("doctor")
        self.assertEqual(doctor.returncode, 0, doctor.stdout + doctor.stderr)
        self.assertIn(f"dafny {PIN['DAFNY_VERSION']}+{PIN['DAFNY_COMMIT']}", doctor.stdout)
        self.assertIn(f"Z3 {PIN['Z3_VERSION']}", doctor.stdout)

        holds = self.dafny("verify", str(FIXTURES / "holds.dfy"))
        self.assertEqual(holds.returncode, 0, holds.stdout + holds.stderr)
        self.assertIn("1 verified, 0 errors", holds.stdout)
        alternate = self.cache / f"tron-proof/dafny-{PIN['DAFNY_VERSION']}/z3/bin/z3-{PIN['Z3_ALT_VERSION']}"
        portable = self.dafny("verify", "--solver-path", str(alternate), str(FIXTURES / "holds.dfy"))
        self.assertEqual(portable.returncode, 0, portable.stdout + portable.stderr)
        translated = self.dafny("translate", "js", str(FIXTURES / "holds.dfy"), "-o", str(self.base / "holds"))
        self.assertEqual(translated.returncode, 0, translated.stdout + translated.stderr)
        self.assertNotIn("was not matched", translated.stdout + translated.stderr)
        false_law = self.dafny("verify", str(FIXTURES / "false-law.dfy"))
        self.assertNotEqual(false_law.returncode, 0, false_law.stdout)
        self.assertIn("0 verified, 1 error", false_law.stdout)

        with open(self.cache / f"tron-proof/dafny-{PIN['DAFNY_VERSION']}/DafnyPrelude.bpl", "a") as prelude:
            prelude.write("x\n")
        for mode in ("doctor", "bootstrap"):
            tampered = self.run_cli(mode)
            self.assertEqual(tampered.returncode, 1, f"{mode} accepted a tampered tree: {tampered.stdout}")
            self.assertIn("tree digest mismatch", tampered.stderr)


if __name__ == "__main__":
    unittest.main()
