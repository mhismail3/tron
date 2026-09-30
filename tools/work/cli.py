#!/usr/bin/env python3
"""Entry point for the work tooling (README.md)."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bootstrap  # noqa: E402
import claim  # noqa: E402
import start  # noqa: E402
from gh import Gh, GhError  # noqa: E402


def repository_root() -> Path:
    output = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    ).stdout.strip()
    return Path(output)


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="work", description="GitHub-tracked parallel agent work")
    commands = parser.add_subparsers(dest="command", required=True)
    boot = commands.add_parser("bootstrap", help="plan or apply labels and the tracking Project")
    boot.add_argument("--apply", action="store_true", help="converge GitHub to .github/work.json")
    boot.add_argument("--report", type=Path, help="write the result as JSON to this path")
    begin = commands.add_parser("start", help="claim an issue and create its branch and worktree")
    begin.add_argument("issue", type=int, help="issue number")
    begin.add_argument("--session", help="claiming session identity (default: WORK_SESSION_ID, PI_SESSION_ID)")
    args = parser.parse_args(argv)

    root = repository_root()
    config_path = root / ".github" / "work.json"
    try:
        config = json.loads(config_path.read_text())
        if args.command == "bootstrap":
            return bootstrap.run(Gh(root), root, config, args.apply, args.report)
        if args.command == "start":
            return start.run(Gh(root), Path.cwd(), config, args.issue, args.session)
    except (GhError, bootstrap.BootstrapError, claim.ClaimError, FileNotFoundError, json.JSONDecodeError) as error:
        print(f"work: {error}", file=sys.stderr)
        return 1
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
