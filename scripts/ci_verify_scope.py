#!/usr/bin/env python3
"""Select hosted tooling checks with the path globs `scripts/tron work verify` uses.

The check names come from `.github/work.json`, and their `paths` are matched by
`tools/work/verify.py`, so CI and local verify cannot disagree about a path. Any
error, unknown name, missing or unresolvable base fails open: every requested
check is selected. A skipped check is silent coverage loss; a run only costs time.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "work"))

from verify import load_checks  # noqa: E402 - tools/work owns the glob semantics.


def changed_paths(base: str, head: str) -> list[str]:
    # No rename detection: a rename must count as both its old and new path.
    output = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", base, head, "--"],
                            capture_output=True, check=True).stdout
    return [os.fsdecode(path) for path in output.split(b"\0") if path]


def decide(names: list[str], base: str, head: str) -> tuple[dict[str, bool], str]:
    settings = json.loads((ROOT / ".github" / "work.json").read_text())
    checks = {check.name: check for check in load_checks(settings["verify"])}
    unknown = [name for name in names if name not in checks]
    if unknown:
        raise ValueError(f"unknown verify check(s): {', '.join(unknown)}")
    if not base or not base.strip("0"):
        return {name: True for name in names}, "missing-base"
    try:
        paths = changed_paths(base, head)
    except subprocess.CalledProcessError:
        return {name: True for name in names}, "diff-unavailable"
    return {name: any(checks[name].matches(path) for path in paths) for name in names}, \
        "classified-changed-paths"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("names", nargs="+", metavar="CHECK")
    args = parser.parse_args()
    try:
        selected, reason = decide(args.names, args.base, args.head)
    except Exception as error:  # Fail open at the classifier boundary; the reason is logged.
        print(f"verify-scope failed open: {error}", file=sys.stderr)
        selected, reason = {name: True for name in args.names}, "error"
    if args.github_output:
        with args.github_output.open("a") as output:
            output.writelines(f"{name}={str(run).lower()}\n" for name, run in selected.items())
    print(json.dumps({"checks": selected, "reason": reason}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
