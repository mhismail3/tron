#!/usr/bin/env python3
"""Real script boundary: stale generated inputs are not a passing/skipped matrix."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class GeneratedPayloadPrecondition(unittest.TestCase):
    def test_stale_runtime_is_a_precondition_and_strict_verification_still_refuses(self):
        with tempfile.TemporaryDirectory(prefix="tron-payload-precondition-") as temporary:
            root = Path(temporary).resolve()
            repo = root / "repo"
            scripts = repo / "packages/mac-app/scripts"
            resources = repo / "packages/mac-app/Sources/Resources"
            payload = resources / "Gateway"
            app = resources / "Library/LoginItems/Tron Agent.app"
            helper = app / "Contents/MacOS/tron"
            scripts.mkdir(parents=True)
            (repo / "config").mkdir()
            for name in ("test-gateway-payload-verifier.sh", "verify-gateway-payload.sh"):
                shutil.copy2(ROOT / "packages/mac-app/scripts" / name, scripts / name)
            (repo / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/validate-push-service-config.sh", repo / "scripts")
            shutil.copy2(ROOT / "config/ci-toolchain.env", repo / "config")
            shutil.copy2(ROOT / ".node-version", repo)
            for name in ("app/dist", "app/scripts", "app/node_modules", "runtime/bin-arm64",
                         "runtime/bin-x64", "runtime/xcodegen/bin", "runtime/xcodegen/share/xcodegen/SettingPresets"):
                (payload / name).mkdir(parents=True, exist_ok=True)
            for name in ("app/dist/index.js", "app/package.json", "app/package-lock.json",
                         "app/PushService.xcconfig", "app/scripts/ensure-node-pty-helper.mjs",
                         "app/scripts/gateway-payload-deploy.mjs", "app/pi-subagents-pin.json",
                         "app/scripts/check-pi-subagents.mjs", "app/scripts/install-pi-subagents.mjs",
                         "runtime/node-arm64", "runtime/node-x64", "runtime/npm-arm64/bin/npm-cli.js",
                         "runtime/npm-x64/bin/npm-cli.js", "runtime/xcodegen/bin/xcodegen",
                         "runtime/xcodegen/share/xcodegen/SettingPresets/base.yml"):
                path = payload / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            (payload / "manifest.json").write_text('{"channel":"dev"}\n')
            (payload / "app/PushService.xcconfig").write_text("TRON_PUSH_SERVICE_ORIGIN =\n")
            # Deliberately invalid bytes reach the real pinned checksum check.
            # The helper/app leaves are synthetic and must never be executed:
            # this is failure-path coverage, not a positive payload fixture.
            (payload / "runtime/node-arm64").write_bytes(b"stale runtime bytes\n")
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\nexit 99\n")
            helper.chmod(0o755)
            for path in sorted(payload.rglob("*"), reverse=True):
                path.chmod(0o555 if path.is_dir() else 0o444)
            payload.chmod(0o555)
            home, scratch = root / "home", root / "tmp"
            home.mkdir()
            scratch.mkdir()
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(scratch)}

            def snapshot():
                return [(str(path.relative_to(resources)), stat.S_IMODE(path.stat().st_mode),
                         hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
                        for path in sorted(resources.rglob("*"))]

            before = snapshot()
            try:
                matrix = subprocess.run([str(scripts / "test-gateway-payload-verifier.sh")],
                                        env=env, text=True, capture_output=True, timeout=30)
                strict = subprocess.run([str(scripts / "verify-gateway-payload.sh"), str(payload), str(helper), "dev"],
                                        env=env, text=True, capture_output=True, timeout=30)
                report = {"matrixExit": matrix.returncode, "matrixError": matrix.stderr,
                          "strictExit": strict.returncode, "strictError": strict.stderr,
                          "generatedInputsUnchanged": snapshot() == before,
                          "scratchEntries": [path.name for path in scratch.iterdir()]}
                output = ROOT / "test-results/gateway-payload-precondition/report.json"
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps(report, indent=2) + "\n")
                self.assertEqual(strict.returncode, 78, strict.stdout + strict.stderr)
                self.assertIn("Node arm64 runtime checksum mismatch", strict.stderr)
                self.assertEqual(matrix.returncode, 2, matrix.stdout + matrix.stderr)
                self.assertIn("generated-input precondition", matrix.stderr)
                self.assertIn("bundle-gateway.sh", matrix.stderr)
                self.assertIn("Node arm64 runtime checksum mismatch", matrix.stderr)
                self.assertTrue(report["generatedInputsUnchanged"])
                self.assertEqual(report["scratchEntries"], [])
            finally:
                # The test owns only this temporary immutable source tree.
                for path in resources.rglob("*"):
                    if path.is_dir():
                        path.chmod(0o755)
                payload.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
