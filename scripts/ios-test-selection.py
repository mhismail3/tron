#!/usr/bin/env python3
"""Select conservative iOS tests from a Git diff."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts/ios-test-selection.json"


def matches(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix)


def select(paths: list[str], manifest: dict) -> tuple[bool, list[str], str]:
    tests: set[str] = set()
    ios_paths = [path for path in paths if path.startswith("packages/ios-app/") or path in {
        ".github/workflows/ci.yml", "scripts/ios-ci-test.sh",
        "scripts/ios-test-selection.py", "scripts/ios-test-selection.json",
    }]
    if not ios_paths:
        return False, [], "no iOS changes"
    for path in ios_paths:
        if any(matches(path, prefix) for prefix in manifest["full_suite_paths"]):
            return True, [], f"full-suite contract changed: {path}"
        matched = False
        for concern in manifest["concerns"]:
            if any(matches(path, prefix) for prefix in concern["paths"]):
                matched = True
                tests.update(concern["tests"])
        if not matched:
            return True, [], f"unmapped iOS path: {path}"
    return False, sorted(tests), "mapped concern tests"


def load_manifest() -> dict:
    manifest = json.loads(MANIFEST.read_text())
    if manifest.get("schema") != "tron.ios-test-selection.v1":
        raise ValueError("unsupported iOS selection manifest")
    return manifest


def self_test() -> None:
    manifest = load_manifest()
    full, tests, _ = select(["README.md"], manifest)
    assert not full and not tests
    full, tests, _ = select(["packages/ios-app/Sources/Engine/Transport/Socket.swift"], manifest)
    assert not full and "TronMobileTests/WebSocketRequestTransportTests" in tests
    full, tests, _ = select(["packages/ios-app/Sources/Session/WorkerKernel/ArtifactInboxViewModel.swift"], manifest)
    assert not full and "TronMobileTests/ArtifactInboxViewModelTests" in tests
    full, tests, _ = select(["packages/ios-app/Sources/Support/Notifications/NotificationLocalStore.swift"], manifest)
    assert not full and "TronMobileTests/NotificationLocalStoreTests" in tests
    full, tests, _ = select(["packages/ios-app/Sources/UI/NewArea/View.swift"], manifest)
    assert full and not tests
    full, tests, _ = select(["packages/ios-app/project.yml"], manifest)
    assert full and not tests
    full, tests, _ = select(["packages/ios-app/Tests/AnyTests.swift"], manifest)
    assert full and not tests
    print("iOS test selection self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("base", nargs="?", default="origin/main")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--format", choices=("args", "json", "lines"), default="args")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    subprocess.run(["git", "cat-file", "-e", f"{args.base}^{{commit}}"], cwd=ROOT, check=True)
    paths = subprocess.check_output(
        ["git", "diff", "--name-only", "--no-renames", f"{args.base}...HEAD"],
        cwd=ROOT, text=True,
    ).splitlines()
    full, tests, reason = select(paths, load_manifest())
    if args.format == "json":
        print(json.dumps({"full": full, "tests": tests, "reason": reason}, sort_keys=True))
    elif args.format == "lines":
        mode = "full" if full else ("none" if reason == "no iOS changes" else "focused")
        print(mode)
        print(reason)
        print("\n".join(tests))
    elif full:
        print("")
    else:
        print(" ".join(f"-only-testing:{test}" for test in tests))


if __name__ == "__main__":
    main()
