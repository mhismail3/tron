#!/usr/bin/env python3
"""Build and run the Mac integration tests (TronMacIntegrationTests) under an owned temporary HOME and TMPDIR.

`scripts/tron test mac [Class or Class/method ...]` runs those tests, or the whole target. `verify`'s
`mac` group and `verify --batch`'s Mac integration lane both run this one command. `--signing-preflight`
only reads the keychain: it fails unless it holds a Mac development identity for the team that
`packages/mac-app/project.yml` configures, the identity Xcode needs for the signed build."""
from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

import ledger

ROOT = Path(__file__).resolve().parents[2]
TARGET = "TronMacIntegrationTests"
PREFLIGHT_FLAG = "--signing-preflight"
PROJECT_CONFIG = ROOT / "packages/mac-app/project.yml"
DEVELOPMENT_TEAM = re.compile(r"^\s*DEVELOPMENT_TEAM:\s*([A-Z0-9]{10})\s*$", re.M)
DEVELOPMENT_IDENTITY = re.compile(r'^\s+\d+\) ([0-9A-F]{40}) "(?:Apple Development|Mac Development): [^"\n]*"', re.M)
CERTIFICATE = re.compile(r"SHA-1 hash: ([0-9A-F]{40})\n(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)", re.S)
PROJECT = ["-project", "packages/mac-app/TronMac.xcodeproj", "-scheme", "TronMac", "-configuration", "Debug",
           "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "packages/mac-app/build/DerivedData"]


def security(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["security", *args], capture_output=True, text=True)


def certificate_team(pem: str) -> str | None:
    subject = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"], input=pem, capture_output=True, text=True).stdout
    found = re.search(r"\bOU=([A-Z0-9]{10})\b", subject)
    return found.group(1) if found else None


def signing_preflight() -> int:
    identities = security("find-identity", "-v", "-p", "codesigning")
    certificates = security("find-certificate", "-a", "-Z", "-p")
    for result in (identities, certificates):
        if result.returncode:
            print(f"mac signing preflight: security exited {result.returncode}: {result.stderr.strip()}", file=sys.stderr)
            return 1
    team = DEVELOPMENT_TEAM.search(PROJECT_CONFIG.read_text())
    if team is None:
        print(f"mac signing preflight: {PROJECT_CONFIG.relative_to(ROOT)} names no DEVELOPMENT_TEAM", file=sys.stderr)
        return 1
    pems = dict(CERTIFICATE.findall(certificates.stdout))
    teams = [certificate_team(pems[digest]) for digest in DEVELOPMENT_IDENTITY.findall(identities.stdout) if digest in pems]
    if team.group(1) not in teams:
        print(f"mac signing preflight: no valid Apple Development or Mac Development identity whose certificate belongs to team "
              f"{team.group(1)} (OU) is in the keychain search list; Xcode cannot sign TronMac (\"No signing certificate ... found\"), "
              "so the Mac tests cannot run on this host", file=sys.stderr)
        return 1
    print("mac signing preflight: a development identity for the configured team is in the keychain", flush=True)
    return 0


def main(classes: list[str]) -> int:
    if classes == [PREFLIGHT_FLAG]:
        return signing_preflight()
    if any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?", name) for name in classes):
        print(f"mac tests: test classes or Class/method only, got {' '.join(classes)}", file=sys.stderr)
        return 64
    if (code := signing_preflight()):
        return code
    for command in ([str(ROOT / "scripts/tron"), "mac", "generate"],
                    [str(ROOT / "scripts/tron-xcodebuild"), "build-for-testing", *PROJECT, "-showBuildTimingSummary"]):
        code = subprocess.run(command, cwd=ROOT).returncode
        if code:
            return code
    scratch = Path(tempfile.mkdtemp(prefix="tron-mac-tests-"))
    try:
        (scratch / "home").mkdir(mode=0o700)
        (scratch / "tmp").mkdir(mode=0o700)
        only = [f"-only-testing:{TARGET}/{name}" for name in classes]
        return ledger.execute('swift', ['xcodebuild', 'test-without-building', *PROJECT, *only,
                                       '-resultBundlePath', str(scratch / 'TestResults.xcresult')],
                              env={"HOME": str(scratch / "home"), "TMPDIR": str(scratch / "tmp")}, cwd=ROOT)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
