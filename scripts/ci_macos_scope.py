#!/usr/bin/env python3
"""Select advisory hosted macOS jobs from available Git trees, fail-closed.

The workflow owns fetching its event's base. No merge-base is required: shallow
checkouts can compare two available trees, including deleted and renamed paths.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

JOBS = ("gateway", "ios", "pi-sdk-e2e", "mac")


def select(paths: list[str]) -> set[str]:
    if not paths:
        return set(JOBS)
    selected: set[str] = set()
    for path in paths:
        if "\n" in path or "\r" in path:
            return set(JOBS)
        # Shared workflow/toolchain inputs precede the known policy-only owners.
        if path.startswith((".github/workflows/", "packages/protocol-fixtures/", "config/")) or path in {
            ".node-version", "scripts/ci_macos_scope.py", "scripts/generate-xcode-project",
            "scripts/install-ci-tools.sh", "scripts/verify-ci-toolchain.sh", "scripts/tron",
        }:
            return set(JOBS)
        if path.startswith(("docs/", "tools/work/", ".agents/", ".github/")) or path in {
            "README.md", "CONTRIBUTING.md", "AGENTS.md",
        }:
            continue
        if path.endswith(".md") and path.startswith(("packages/gateway/", "packages/ios-app/",
                                                     "packages/mac-app/", "packages/push-relay/")):
            continue
        if path.startswith("packages/gateway/"):
            selected.update(("gateway", "pi-sdk-e2e", "mac"))
        elif path.startswith("packages/ios-app/"):
            selected.update(("ios", "pi-sdk-e2e"))
        elif path.startswith("packages/mac-app/"):
            selected.add("mac")
        elif path.startswith("packages/push-relay/"):
            continue
        elif path.startswith(("scripts/ios-", "scripts/tron-ios-", "scripts/test-ios-", "scripts/patch-ios-")):
            selected.update(("ios", "pi-sdk-e2e"))
        else:
            # New owners/scripts are not assumed irrelevant. Narrow only after
            # their consumers are known and covered by the CLI regressions.
            return set(JOBS)
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    selected = set(JOBS)
    reason = "explicit-full-run" if args.all else "missing-base"
    if not args.all and args.base and args.base.strip("0"):
        try:
            result = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z",
                                     args.base, args.head, "--"], capture_output=True, check=True)
            paths = [os.fsdecode(p) for p in result.stdout.split(b"\0") if p]
            selected = select(paths)
            reason = "classified-changed-paths" if paths else "empty-diff"
        except (OSError, subprocess.CalledProcessError):
            reason = "diff-unavailable"
    jobs = {job: job in selected for job in JOBS}
    if args.github_output:
        with args.github_output.open("a") as output:
            output.writelines(f"{job}={str(run).lower()}\n" for job, run in jobs.items())
    print(json.dumps({"jobs": jobs, "reason": reason}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
