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
import release  # noqa: E402
import handoff  # noqa: E402
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
    boot.add_argument("--prune", action="store_true",
                      help="with --apply: also delete drifted labels, fields and options no open issue uses")
    boot.add_argument("--report", type=Path, help="write the result as JSON to this path")
    begin = commands.add_parser("start", help="claim an issue and create its branch and worktree")
    begin.add_argument("issue", type=int, help="issue number")
    begin.add_argument("--session", help="claiming session identity (default: WORK_SESSION_ID, PI_SESSION_ID)")
    begin.add_argument("--integration", action="store_true", help="explicitly claim an epic as an integration branch")
    begin.add_argument("--base", metavar="REMOTE-BRANCH", help="start from this branch on the configured remote")
    transfer = commands.add_parser("handoff", help="transfer a claim after authoritative owner settlement proof")
    transfer.add_argument("issue", type=int)
    transfer.add_argument("--session", help="new owner session (default: WORK_SESSION_ID, PI_SESSION_ID)")
    transfer.add_argument("--reason", required=True, help="concise reason recorded in the public audit comment")
    transfer.add_argument("--force-maintainer", action="store_true", help="override unknown owner state after exact interactive confirmation (including missing legacy owner)")
    recovery = commands.add_parser("recover", help="publish an exact settled-owner descendant candidate as unverified work")
    recovery.add_argument("issue", type=int)
    recovery.add_argument("--expected-local", required=True, help="full unpublished candidate commit ID")
    recovery.add_argument("--expected-remote", required=True, help="full remote ancestor commit ID")
    recovery.add_argument("--reason", required=True, help="concise public recovery audit reason")
    giveup = commands.add_parser("release", help="give up a stale claim on an open issue after preserving its work")
    giveup.add_argument("issue", type=int, nargs="?")
    giveup.add_argument("--reason", help="concise reason recorded in the public audit comment")
    giveup.add_argument("--stale", action="store_true",
                        help=f"release every claim idle over {release.STALE_HOURS}h whose owner is absent or settled")
    giveup.add_argument("--dry-run", action="store_true", help="with --stale: list what would be released")
    giveup.add_argument("--force-maintainer", action="store_true",
                        help="release a legacy owner no Gateway reports (real terminal and exact confirmation)")
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
    create_issue.add_argument("--kind", help="declared kind: label (required for a task)")
    create_issue.add_argument("--area", action="append", help="declared area: label; repeat for each (one required for a task)")
    create_issue.add_argument("--status", choices=("Ready", "Blocked"), help="Project Status (default Ready)")
    create_issue.add_argument("--priority", choices=("P0", "P1", "P2", "P3"))
    create_issue.add_argument("--exit-by", metavar="YYYY-MM-DD",
                              help="for an issue that waits for a recurrence: the date after which it closes as not planned")
    edit_issue = issue_commands.add_parser("edit", help="replace an issue's title and/or body (for example its remaining scope)")
    edit_issue.add_argument("issue", type=int)
    edit_issue.add_argument("--title")
    edit_issue.add_argument("--body-file", type=Path, help="Markdown body; not logged")
    labels_issue = issue_commands.add_parser("labels", help="add/remove only labels declared by the repository")
    labels_issue.add_argument("issue", type=int)
    labels_issue.add_argument("--add", action="append", default=[])
    labels_issue.add_argument("--remove", action="append", default=[])
    close_issue = issue_commands.add_parser("close", help="comment, close and set Status Done")
    close_issue.add_argument("issue", type=int)
    close_issue.add_argument("--reason", required=True, choices=("completed", "not_planned"))
    close_issue.add_argument("--comment-file", required=True, type=Path, help="Markdown closing comment; not logged")
    reopen_issue = issue_commands.add_parser("reopen", help="post the stated reason, reopen and restore Status")
    reopen_issue.add_argument("issue", type=int)
    reopen_issue.add_argument("--comment-file", required=True, type=Path,
                              help="Markdown reason for reopening (required, posted publicly); not logged")
    parent_issue = issue_commands.add_parser("parent", help="link a task under an epic")
    parent_issue.add_argument("issue", type=int)
    parent_issue.add_argument("--epic", required=True, type=int)
    parent_issue.add_argument("--replace-parent", action="store_true",
                              help="move the task from its current epic to this one")
    blocker_issue = issue_commands.add_parser("block", help="add a native blocked-by relationship")
    blocker_issue.add_argument("issue", type=int)
    blocker_issue.add_argument("--blocked-by", required=True, type=int)
    project = commands.add_parser("project", help="work-Project membership and classification")
    project_commands = project.add_subparsers(dest="project_command", required=True)
    project_add = project_commands.add_parser("add", help="add an issue to the configured work Project")
    project_add.add_argument("issue", type=int)
    project_set = project_commands.add_parser("set", help="assign a Status and/or Priority")
    project_set.add_argument("issue", type=int)
    project_set.add_argument("--status", choices=("Ready", "Blocked"))
    project_set.add_argument("--priority", choices=("P0", "P1", "P2", "P3"))
    landing = commands.add_parser("land", help="merge the base in, verify, push, squash-merge, close the issue")
    landing.add_argument("--summary-file", required=True, type=Path,
                         help="Markdown; becomes the pull request body verbatim")
    landing.add_argument("--title", help="pull request title (default: '<type>: <branch slug>'; kept when a PR exists)")
    landing.add_argument("--tests", action="append", default=[], metavar="COMMAND",
                         help="integration or E2E command to run on the merged tree; repeat for each")
    landing.add_argument("--ready", action="store_true",
                         help="mark a draft pull request ready for review, after verify and publication, before the merge")
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
            if args.prune and not args.apply:
                parser.error("--prune requires --apply")
            return bootstrap.run(Gh(root), root, config, args.apply, args.report, args.prune)
        if args.command == "start":
            return start.run(Gh(root), Path.cwd(), config, args.issue, args.session,
                             args.integration, args.base)
        if args.command == "handoff":
            return handoff.run(Gh(root), Path.cwd(), config, args.issue, args.session, args.force_maintainer, args.reason)
        if args.command == "recover":
            return handoff.recover(Gh(root), Path.cwd(), config, args.issue, args.expected_local, args.expected_remote, args.reason)
        if args.command == "release":
            if args.stale:
                if args.issue is not None or args.reason or args.force_maintainer:
                    parser.error("release --stale takes no issue, --reason or --force-maintainer")
                return release.sweep(Gh(root), Path.cwd(), config, args.dry_run)
            if args.issue is None or not args.reason or args.dry_run:
                parser.error("release needs <issue> and --reason (or --stale [--dry-run])")
            return release.run(Gh(root), Path.cwd(), config, args.issue, args.reason, args.force_maintainer)
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
                tracking.create_issue(gh, root, config, args.title, args.body_file, args.type, args.kind,
                                      args.area, args.status, args.priority, args.exit_by)
                return 0
            if args.issue_command == "edit":
                tracking.edit_issue(gh, root, config, args.issue, args.title, args.body_file)
                return 0
            if args.issue_command == "labels":
                tracking.set_labels(gh, config, args.issue, args.add, args.remove)
                return 0
            if args.issue_command == "close":
                tracking.close_issue(gh, root, config, args.issue, args.reason, args.comment_file)
                return 0
            if args.issue_command == "reopen":
                tracking.reopen_issue(gh, root, config, args.issue, args.comment_file)
                return 0
            if args.issue_command == "parent":
                tracking.add_parent(gh, root, config, args.issue, args.epic, args.replace_parent)
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
            return land.land(Gh(root), root, config, args.title, args.summary_file, args.tests, args.dry_run, args.ready)
        if args.command == "cleanup":
            return cleanup.run(Gh(root), Path.cwd(), config, args.all, args.dry_run)
    except (GhError, bootstrap.BootstrapError, claim.ClaimError, handoff.HandoffError, release.ReleaseError, verify.VerifyError, dashboard.DashboardError,
            land.LandError, warm.WarmError, cleanup.CleanupError, tracking.TrackingError, FileNotFoundError,
            json.JSONDecodeError) as error:
        print(f"work: {error}", file=sys.stderr)
        return 1
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
