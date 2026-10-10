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
import cleanup  # noqa: E402
import comments  # noqa: E402
import dashboard  # noqa: E402
import land  # noqa: E402
import start  # noqa: E402
import tracking  # noqa: E402
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
    check = commands.add_parser("verify", help="run the local checks the branch diff requires")
    check.add_argument("--tests", action="append", default=[], metavar="COMMAND",
                       help="integration or E2E command to run from the repository root; repeat for each")
    board = commands.add_parser("dashboard", help="read-only view of all work, fetched live")
    board.add_argument("--html", type=Path, help="write a self-contained HTML dashboard to this path")
    board.add_argument("--json", type=Path, help="write the dashboard model as JSON to this path")
    comment = commands.add_parser("comment", help="post a privacy-checked public issue comment")
    comment.add_argument("issue", type=int, help="positive issue number")
    comment.add_argument("--body-file", required=True, type=Path, help="Markdown file to post; payloads are not logged")
    issue = commands.add_parser("issue", help="issue filing, classification and relationship mutations")
    issue_commands = issue.add_subparsers(dest="issue_command", required=True)
    create_issue = issue_commands.add_parser("create", help="file a task or epic")
    create_issue.add_argument("--title", required=True)
    create_issue.add_argument("--body-file", required=True, type=Path)
    create_issue.add_argument("--type", choices=("task", "epic"), default="task")
    create_issue.add_argument("--kind", help="declared kind label (optional)")
    create_issue.add_argument("--visibility", help="declared visibility label (optional)")
    create_issue.add_argument("--area", action="append", help="declared area label; repeat for each (optional)")
    labels_issue = issue_commands.add_parser("labels", help="add/remove only labels declared by the repository")
    labels_issue.add_argument("issue", type=int)
    labels_issue.add_argument("--add", action="append", default=[])
    labels_issue.add_argument("--remove", action="append", default=[])
    close_issue = issue_commands.add_parser("close", help="comment, close and set Status Done")
    close_issue.add_argument("issue", type=int)
    close_issue.add_argument("--reason", required=True, choices=("completed", "not_planned"))
    close_issue.add_argument("--comment-file", required=True, type=Path, help="Markdown closing comment; not logged")
    parent_issue = issue_commands.add_parser("parent", help="link a task under an epic")
    parent_issue.add_argument("issue", type=int)
    parent_issue.add_argument("--epic", required=True, type=int)
    blocker_issue = issue_commands.add_parser("block", help="add a native blocked-by relationship")
    blocker_issue.add_argument("issue", type=int)
    blocker_issue.add_argument("--blocked-by", required=True, type=int)
    project = commands.add_parser("project", help="work-Project membership and classification")
    project_commands = project.add_subparsers(dest="project_command", required=True)
    project_add = project_commands.add_parser("add", help="add an issue to the configured work Project")
    project_add.add_argument("issue", type=int)
    project_set = project_commands.add_parser("set", help="assign a Status and/or Priority")
    project_set.add_argument("issue", type=int)
    project_set.add_argument("--status", choices=("Proposed", "Ready", "Blocked"))
    project_set.add_argument("--priority", choices=("P0", "P1", "P2", "P3"))
    landing = commands.add_parser("land", help="merge the base in, verify, push, squash-merge, close the issue")
    landing.add_argument("--summary-file", required=True, type=Path,
                         help="Markdown; becomes the pull request body verbatim")
    landing.add_argument("--title", help="pull request title (default: '<type>: <branch slug>'; kept when a PR exists)")
    landing.add_argument("--tests", action="append", default=[], metavar="COMMAND",
                         help="integration or E2E command to run on the merged tree; repeat for each")
    landing.add_argument("--dry-run", action="store_true",
                         help="verify the merged tree, then stop before any push or GitHub write")
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
            return start.run(Gh(root), Path.cwd(), config, args.issue, args.session)
        if args.command == "verify":
            base_ref = f"{config['claim']['remote']}/{config['claim']['baseBranch']}"
            return 0 if verify.verify(root, config, args.tests, base_ref) else 1
        if args.command == "dashboard":
            return dashboard.run(Gh(root), Path.cwd(), config, args.html, args.json)
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
            if args.issue_command == "close":
                tracking.close_issue(gh, root, config, args.issue, args.reason, args.comment_file)
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
            return land.land(Gh(root), root, config, args.title, args.summary_file, args.tests, args.dry_run)
        if args.command == "cleanup":
            return cleanup.run(Gh(root), Path.cwd(), config, args.all, args.dry_run)
    except (GhError, bootstrap.BootstrapError, claim.ClaimError, verify.VerifyError, dashboard.DashboardError,
            land.LandError, warm.WarmError, cleanup.CleanupError, tracking.TrackingError, FileNotFoundError,
            json.JSONDecodeError) as error:
        print(f"work: {error}", file=sys.stderr)
        return 1
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
