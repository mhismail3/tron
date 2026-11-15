#!/usr/bin/env python3
"""tools/verify/mac.py's signing preflight, run as the real process (tools/verify/README.md).

Each case copies the real `mac.py` and `ledger.py` into a disposable repository whose `scripts/tron` and
`scripts/tron-xcodebuild` only record their calls, and puts a fixture `security` first on PATH. The fixture
answers `find-identity -v` and `find-certificate -a -Z -p` with the shapes Keychain prints; each certificate is
a throwaway self-signed one generated here, its key discarded. The cases check that the team is read from the
certificate's OU, never from the common name, and that a refused preflight generates and builds nothing.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TEAM = "TEAMFIXT01"
OTHER_TEAM = "OTHERTEAM1"
SECURITY = "#!/bin/sh\ncase \"$1\" in\n  find-identity) cat \"$FIXTURE_IDENTITY_LISTING\" ;;\n  find-certificate) cat \"$FIXTURE_CERTIFICATES\" ;;\n  *) exit 2 ;;\nesac\n"
RECORDER = "#!/bin/sh\necho \"$0 $*\" >> \"$FIXTURE_CALLS\"\n"


class MacPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-mac-preflight-")
        base = Path(self.temp.name)
        self.repo = base / "repo"
        (self.repo / "tools/verify").mkdir(parents=True)
        shutil.copy2(ROOT / "tools/verify/mac.py", self.repo / "tools/verify/mac.py")
        shutil.copy2(ROOT / "tools/verify/ledger.py", self.repo / "tools/verify/ledger.py")
        (self.repo / "packages/mac-app").mkdir(parents=True)
        (self.repo / "packages/mac-app/project.yml").write_text(
            f"settings:\n  base:\n    DEVELOPMENT_TEAM: {TEAM}\n    CODE_SIGN_STYLE: Automatic\n")
        (self.repo / "scripts").mkdir()
        for name in ("tron", "tron-xcodebuild"):
            (self.repo / "scripts" / name).write_text(RECORDER)
            (self.repo / "scripts" / name).chmod(0o755)
        fixtures = base / "fixtures"
        fixtures.mkdir()
        (fixtures / "security").write_text(SECURITY)
        (fixtures / "security").chmod(0o755)
        self.identities = base / "identities.txt"
        self.certificates = base / "certificates.txt"
        self.calls = base / "calls.txt"
        self.env = {**os.environ, "PATH": f"{fixtures}{os.pathsep}{os.environ['PATH']}", "HOME": str(base / "home"),
                    "TMPDIR": str(base), "FIXTURE_IDENTITY_LISTING": str(self.identities),
                    "FIXTURE_CERTIFICATES": str(self.certificates), "FIXTURE_CALLS": str(self.calls)}
        self.base = base

    def tearDown(self) -> None:
        self.temp.cleanup()

    def keychain(self, *identities: tuple[str, str, str]) -> None:
        rows, pems = [], []
        for number, (name, ou, digest) in enumerate(identities, 1):
            rows.append(f'  {number}) {digest} "{name}"')
            pem = self.base / f"cert-{digest}.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                            "-keyout", os.devnull, "-subj", f"/CN={name}/OU={ou}/O=Fixture", "-days", "1", "-out", str(pem)],
                           check=True, capture_output=True)
            pems.append(f"SHA-1 hash: {digest}\n{pem.read_text()}")
        self.identities.write_text("\n".join([*rows, f"     {len(identities)} valid identities found", ""]))
        self.certificates.write_text("".join(pems))

    def mac(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.repo / "tools/verify/mac.py"), *args], cwd=self.repo, env=self.env,
                              capture_output=True, text=True)

    def test_the_team_is_read_from_the_certificate_not_the_common_name(self) -> None:
        self.keychain((f"Apple Development: Fixture Developer ({TEAM})", OTHER_TEAM, "A" * 40),
                      ("Apple Distribution: Fixture Developer", TEAM, "B" * 40))
        preflight = self.mac("--signing-preflight")
        self.assertEqual(preflight.returncode, 1, preflight.stdout + preflight.stderr)
        self.assertIn(TEAM, preflight.stderr)
        run = self.mac("SubprocessTests")
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertFalse(self.calls.exists(), "a refused signing preflight must not generate or build the Mac app")

    def test_a_development_identity_whose_certificate_belongs_to_the_configured_team_passes_without_building(self) -> None:
        self.keychain((f"Apple Development: Fixture Developer ({OTHER_TEAM})", TEAM, "C" * 40))
        preflight = self.mac("--signing-preflight")
        self.assertEqual(preflight.returncode, 0, preflight.stdout + preflight.stderr)
        self.assertFalse(self.calls.exists(), "the preflight only reads the keychain; it must not generate or build")


if __name__ == "__main__":
    unittest.main()
