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
import dashboard  # noqa: E402
import land  # noqa: E402
import start  # noqa: E402
import verify  # noqa: E402
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
    check = commands.add_parser("verify", help="run the checks the branch diff requires and write a receipt")
    check.add_argument("--post", action="store_true",
                       help="publish the receipt: evidence comment, private logs, commit status")
    board = commands.add_parser("dashboard", help="read-only view of all work, fetched live")
    board.add_argument("--html", type=Path, help="write a self-contained HTML dashboard to this path")
    board.add_argument("--json", type=Path, help="write the dashboard model as JSON to this path")
    landing = commands.add_parser("land", help="update, verify, open the pull request, wait for checks, merge")
    landing.add_argument("--title", help="pull request title (default: '<type>: <issue title>' or the current one)")
    landing.add_argument("--summary-file", type=Path, help="Markdown for the Summary section (required to open)")
    landing.add_argument("--needs-user-validation", metavar="TEXT",
                        help="exact maintainer-only action and check; the issue stays open as Needs you")
    landing.add_argument("--session", help="claiming session identity (default: WORK_SESSION_ID, PI_SESSION_ID)")
    stewardship = commands.add_parser("steward", help="report open claim pull requests; --land one whose owner is gone")
    stewardship.add_argument("--land", type=int, metavar="ISSUE",
                         help="merge this issue's pull request if its head is verified, green and up to date")
    args = parser.parse_args(argv)

    root = repository_root()
    config_path = root / ".github" / "work.json"
    try:
        config = json.loads(config_path.read_text())
        if args.command == "bootstrap":
            return bootstrap.run(Gh(root), root, config, args.apply, args.report)
        if args.command == "start":
            return start.run(Gh(root), Path.cwd(), config, args.issue, args.session)
        if args.command == "verify":
            receipt = verify.verify(root, config)
            print(f"receipt:  {verify.receipt_path(root, receipt['head'])}")
            print(f"result:   {'passed' if receipt['passed'] else 'FAILED'} for {receipt['head']}")
            if args.post:
                print(f"posted:   {verify.post(Gh(root), root, config, receipt)}")
            return 0 if receipt["passed"] else 1
        if args.command == "dashboard":
            return dashboard.run(Gh(root), Path.cwd(), config, args.html, args.json)
        if args.command == "land":
            return land.land(Gh(root), root, config, args.session, args.title, args.summary_file,
                             args.needs_user_validation)
        if args.command == "steward":
            return land.steward(Gh(root), root, config, args.land)
    except (GhError, bootstrap.BootstrapError, claim.ClaimError, verify.VerifyError, dashboard.DashboardError,
            land.LandError, FileNotFoundError, json.JSONDecodeError) as error:
        print(f"work: {error}", file=sys.stderr)
        return 1
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
