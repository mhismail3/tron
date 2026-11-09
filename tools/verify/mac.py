#!/usr/bin/env python3
"""Build and run the Mac integration tests (TronMacIntegrationTests) under an owned temporary HOME and TMPDIR.

`scripts/tron test mac [Class or Class/method ...]` runs those tests, or the whole target. `verify`'s
`mac` group and `verify --batch`'s Mac integration lane both run this one command."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = "TronMacIntegrationTests"
PROJECT = ["-project", "packages/mac-app/TronMac.xcodeproj", "-scheme", "TronMac", "-configuration", "Debug",
           "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "packages/mac-app/build/DerivedData"]


def main(classes: list[str]) -> int:
    if any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?", name) for name in classes):
        print(f"mac tests: test classes or Class/method only, got {' '.join(classes)}", file=sys.stderr)
        return 64
    for command in ([str(ROOT / "scripts/tron"), "mac", "generate"],
                    [str(ROOT / "scripts/tron-xcodebuild"), "build-for-testing", *PROJECT, "-showBuildTimingSummary"]):
        code = subprocess.run(command, cwd=ROOT).returncode
        if code:
            return code
    # The tests write app state under HOME and TMPDIR: never the user's.
    scratch = Path(tempfile.mkdtemp(prefix="tron-mac-tests-"))
    try:
        (scratch / "home").mkdir(mode=0o700)
        (scratch / "tmp").mkdir(mode=0o700)
        only = [f"-only-testing:{TARGET}/{name}" for name in classes]
        return subprocess.run(["xcodebuild", "test-without-building", *PROJECT, *only], cwd=ROOT,
                              env={**os.environ, "HOME": str(scratch / "home"), "TMPDIR": str(scratch / "tmp")}).returncode
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
