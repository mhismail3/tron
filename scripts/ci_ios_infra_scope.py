#!/usr/bin/env python3
"""Select the policy job's local iOS-runner infrastructure suite fail-closed."""
from __future__ import annotations

import argparse
import os
from pathlib import Path


IOS_OWNED_PREFIXES = (
    "packages/ios-app/",
    "scripts/ios-",
    "scripts/ios_",
    "scripts/test-ios-",
    "scripts/ci_ios_infra_scope.py",
    "scripts/tron-ios-test",
    "scripts/tron-ios-simulator",
    "scripts/ios-gateway-e2e-test",
    "scripts/tron-profile-ios",
    "scripts/ios-release-toolchain-doctor.sh",
    "scripts/install-ci-tools.sh",
    "scripts/verify-ci-toolchain.sh",
    "config/ci-toolchain.env",
    ".node-version",
    ".github/workflows/ci.yml",
)
KNOWN_NON_IOS_PREFIXES = (
    ".agents/",
    ".codex/",
    ".pi/",
    ".github/",
    "docs/",
    "packages/gateway/",
    "packages/mac-app/",
    "packages/protocol-fixtures/",
    "packages/push-relay/",
    "tools/",
)


def should_run(paths: list[str]) -> bool:
    """Unknown paths and empty input run the suite; only recognized non-iOS paths skip it."""
    if not paths:
        return True
    for path in paths:
        normalized = path.removeprefix("./")
        if "\n" in normalized or "\r" in normalized:
            return True
        if normalized.startswith(IOS_OWNED_PREFIXES):
            return True
        if normalized.startswith(KNOWN_NON_IOS_PREFIXES) or normalized.endswith(".md"):
            continue
        if normalized in {
            "README", "README.md", "CONTRIBUTING.md", "AGENTS.md",
            "scripts/tron-version",
        }:
            continue
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--paths-file", type=Path, required=True)
    args = parser.parse_args()
    try:
        paths = [os.fsdecode(path) for path in args.paths_file.read_bytes().split(b"\0") if path]
    except OSError:
        print("true")
        return 0
    print("true" if should_run(paths) else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
