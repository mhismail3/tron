#!/usr/bin/env python3
"""Entry point for the work tooling (README.md)."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import acceptance  # noqa: E402
import bootstrap  # noqa: E402
import claim  # noqa: E402
import cleanup  # noqa: E402
import comments  # noqa: E402
import tracking  # noqa: E402
import dashboard  # noqa: E402
import issues  # noqa: E402
import land  # noqa: E402
import start  # noqa: E402
import verify  # noqa: E402
import warm  # noqa: E402
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
    begin.add_argument("--base", help="start from, and later land into, this open issue's claim branch "
                                      "instead of the configured base; fixed for the claim's life")
    check = commands.add_parser("verify", help="run the checks the branch diff requires and write a receipt")
    check.add_argument("--jobs", type=int, metavar="N",
                       help="maximum concurrent checks (default: CPU/RAM bounded; 1 runs sequentially)")
    check.add_argument("--post", action="store_true",
                       help="publish the receipt: evidence comment, private logs, commit status")
    check.add_argument("--evidence-manifest", type=Path,
                       help="head-bound JSON manifest of reviewed screenshots/short recordings (private only)")
    board = commands.add_parser("dashboard", help="read-only view of all work, fetched live")
    board.add_argument("--html", type=Path, help="write a self-contained HTML dashboard to this path")
    board.add_argument("--json", type=Path, help="write the dashboard model as JSON to this path")
    comment = commands.add_parser("comment", help="post a privacy-checked public issue comment through the audited GitHub boundary")
    comment.add_argument("issue", type=int, help="positive issue number")
    comment.add_argument("--body-file", required=True, type=Path, help="Markdown file to post; payloads are not logged")
    issue = commands.add_parser("issue", help="typed issue filing, classification and relationship mutations")
    issue_commands = issue.add_subparsers(dest="issue_command", required=True)
    create_issue = issue_commands.add_parser("create", help="file a task or epic with declared labels")
    create_issue.add_argument("--title", required=True)
    create_issue.add_argument("--body-file", required=True, type=Path)
    create_issue.add_argument("--type", choices=("task", "epic"), default="task")
    create_issue.add_argument("--kind")
    create_issue.add_argument("--visibility")
    create_issue.add_argument("--area", action="append", help="declared area label; repeat for each affected area")
    labels_issue = issue_commands.add_parser("labels", help="add/remove only labels declared by the repository")
    labels_issue.add_argument("issue", type=int)
    labels_issue.add_argument("--add", action="append", default=[])
    labels_issue.add_argument("--remove", action="append", default=[])
    parent_issue = issue_commands.add_parser("parent", help="link a task under an epic")
    parent_issue.add_argument("issue", type=int)
    parent_issue.add_argument("--epic", required=True, type=int)
    blocker_issue = issue_commands.add_parser("block", help="add a native blocked-by relationship")
    blocker_issue.add_argument("issue", type=int)
    blocker_issue.add_argument("--blocked-by", required=True, type=int)
    project = commands.add_parser("project", help="typed work-Project membership and classification mutations")
    project_commands = project.add_subparsers(dest="project_command", required=True)
    project_add = project_commands.add_parser("add", help="add an issue to the configured work Project")
    project_add.add_argument("issue", type=int)
    project_set = project_commands.add_parser("set", help="assign an unclaimed work status and/or priority")
    project_set.add_argument("issue", type=int)
    project_set.add_argument("--status", choices=("Proposed", "Ready", "Needs you", "Blocked"))
    project_set.add_argument("--priority", choices=("P0", "P1", "P2", "P3"))
    corpus = commands.add_parser("issues", help="print every open issue as a bounded JSON corpus for related-issue checks")
    corpus.add_argument("--closed", action="store_true", help="also include recently updated closed issues")
    corpus.add_argument("--closed-limit", type=int, default=200, metavar="N",
                        help=f"closed issues to include with --closed (default 200, max {issues.CLOSED_LIMIT_MAX})")
    landing = commands.add_parser("land", help="update, verify, open the pull request, wait for checks, merge")
    landing.add_argument("--title", help="pull request title (default: '<type>: <issue title>' or the current one)")
    landing.add_argument("--summary-file", type=Path, help="Markdown for the Summary section (required to open)")
    landing.add_argument("--needs-user-validation", metavar="TEXT",
                        help="exact maintainer-only action and check; the issue stays open as Needs you")
    landing.add_argument("--irreducible", metavar="PART",
                        help="the part no acceptance journey can prove; required with --needs-user-validation")
    landing.add_argument("--acceptance", metavar="JOURNEY_ID[,JOURNEY_ID]",
                        help="run these registered acceptance journeys and require their reports for this head")
    landing.add_argument("--session", help="claiming session identity (default: WORK_SESSION_ID, PI_SESSION_ID)")
    landing.add_argument("--evidence-manifest", type=Path,
                         help="head-bound media manifest; recapture if merging the base changes the head")
    stewardship = commands.add_parser("steward", help="report open claim pull requests; --land one whose owner is gone")
    stewardship.add_argument("--land", type=int, metavar="ISSUE",
                         help="merge this issue's pull request if its head is verified, green and up to date")
    tidy = commands.add_parser("cleanup", help="remove this task worktree and its branches once its PR merged")
    tidy.add_argument("--all", action="store_true", help="every worktree under the worktree root; list the rest")
    tidy.add_argument("--dry-run", action="store_true", help="report the decisions and change nothing")
    args = parser.parse_args(argv)

    root = repository_root()
    config_path = root / ".github" / "work.json"
    try:
        config = json.loads(config_path.read_text())
        if args.command == "bootstrap":
            return bootstrap.run(Gh(root), root, config, args.apply, args.report)
        if args.command == "start":
            return start.run(Gh(root), Path.cwd(), config, args.issue, args.session, args.base)
        if args.command == "verify":
            receipt = verify.verify(root, config, args.evidence_manifest, jobs=args.jobs)
            print(f"receipt:  {verify.receipt_path(root, receipt['head'])}")
            print(f"result:   {'passed' if receipt['passed'] else 'FAILED'} for {receipt['head']}")
            if args.post:
                print(f"posted:   {verify.post(Gh(root), root, config, receipt)}")
            return 0 if receipt["passed"] else 1
        if args.command == "dashboard":
            return dashboard.run(Gh(root), Path.cwd(), config, args.html, args.json)
        if args.command == "issues":
            return issues.run(Gh(root), config, args.closed_limit if args.closed else 0)
        if args.command == "comment":
            return comments.post(Gh(root), root, config, args.issue, args.body_file)
        if args.command == "issue":
            gh = Gh(root)
            if args.issue_command == "create":
                tracking.create_issue(gh, root, config, args.title, args.body_file,
                                     args.type, args.kind, args.visibility, args.area)
                return 0
            if args.issue_command == "labels":
                tracking.set_labels(gh, config, args.issue, args.add, args.remove)
                return 0
            if args.issue_command == "parent":
                tracking.add_parent(gh, root, config, args.issue, args.epic)
                return 0
            if args.issue_command == "block":
                tracking.add_blocker(gh, root, config, args.issue, args.blocked_by)
                return 0
        if args.command == "project":
            gh = Gh(root)
            if args.project_command == "add":
                tracking.add_project_item(gh, root, config, args.issue)
                return 0
            if args.project_command == "set":
                tracking.set_project_fields(gh, root, config, args.issue, args.status, args.priority)
                return 0
        if args.command == "land":
            return land.land(Gh(root), root, config, args.session, args.title, args.summary_file,
                             args.needs_user_validation, args.irreducible, args.acceptance,
                             evidence_manifest=args.evidence_manifest)
        if args.command == "steward":
            return land.steward(Gh(root), root, config, args.land)
        if args.command == "cleanup":
            return cleanup.run(Gh(root), Path.cwd(), config, args.all, args.dry_run)
    except (GhError, bootstrap.BootstrapError, claim.ClaimError, verify.VerifyError, dashboard.DashboardError, issues.IssuesError,
            land.LandError, acceptance.AcceptanceError, warm.WarmError, cleanup.CleanupError,
            tracking.TrackingError, FileNotFoundError,
            json.JSONDecodeError) as error:
        print(f"work: {error}", file=sys.stderr)
        return 1
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
