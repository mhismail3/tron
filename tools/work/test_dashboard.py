"""Isolated checks for dashboard failure modes 20-31 and 42 in README.md.

Inputs are GitHub-shaped responses in the form the dashboard's queries return
them (recorded from the live API, including a deleted-content Project item and
`gh`'s NOT_FOUND output), plus the Git facts the dashboard reads. The GitHub
boundary is a recording stand-in for `gh`, never a stand-in for the
dashboard's own functions. `RunTests` drives `run` end to end against real
local Git and a stand-in `gh` executable.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from claim import create_claim
from dashboard import build, fetch_github, render_html, render_text, run
from gh import Gh, GhError

REPO = "owner/repo"
NOW = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)
PARENT = "/Users/someone/Workspace"
ROOT = PARENT + "/repo-worktrees"

CONFIG = {
    "project": {
        "title": "Work",
        "fields": [
            {"name": "Status", "type": "single_select", "options": [
                {"name": n} for n in ("Proposed", "Ready", "In progress", "In review", "Needs you", "Blocked", "Done")
            ]},
            # Declared order is the priority order; it deliberately differs
            # from the alphabetical order of the names.
            {"name": "Priority", "type": "single_select", "options": [
                {"name": "Urgent"}, {"name": "Normal"}, {"name": "Later"},
            ]},
            {"name": "Epic rank", "type": "number"},
        ],
    },
    "claim": {
        "remote": "origin", "baseBranch": "main", "worktreeRoot": "../repo-worktrees",
        "readyStatus": "Ready", "claimedStatus": "In progress", "statusField": "Status",
        "claimedStatuses": ["In progress", "In review", "Needs you"], "activeStatuses": ["In progress", "In review"],
        "excludeLabels": ["epic"], "softCap": 2,
    },
    "dashboard": {
        "needsYouStatus": "Needs you", "blockedStatus": "Blocked", "epicLabel": "epic",
        "needsYouLabels": ["needs-decision"], "regressionLabel": "regression",
        "priorityField": "Priority", "rankField": "Epic rank", "verifyContext": "ci/verify",
    },
}


def iso(hours_ago: float) -> str:
    return (NOW - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def issue(number, title=None, state="OPEN", labels=(), parent=None, sub=(0, 0), blocked_by=(),
          comment_hours_ago=None, repo=REPO):
    return {
        "__typename": "Issue",
        "number": number,
        "title": title or f"Issue {number}",
        "url": f"https://github.com/{repo}/issues/{number}",
        "state": state,
        "repository": {"nameWithOwner": repo},
        "labels": {"nodes": [{"name": label} for label in labels]},
        "parent": {"number": parent} if parent else None,
        "subIssuesSummary": {"total": sub[1], "completed": sub[0]},
        "blockedBy": {"nodes": [{"number": n, "state": s} for n, s in blocked_by]},
        "comments": {"nodes": [{"createdAt": iso(comment_hours_ago)}] if comment_hours_ago is not None else []},
    }


def item(content, status=None, priority=None, rank=None, kind="ISSUE"):
    return {
        "id": f"PVTI_{content['number'] if content and 'number' in content else 'x'}",
        "type": kind,
        "status": {"name": status} if status else None,
        "priority": {"name": priority} if priority else None,
        "rank": {"number": rank} if rank is not None else None,
        "content": content,
    }


# Recorded verbatim from the live Project: the issue was deleted before its
# item was removed, and GitHub refuses to delete or archive the item.
GHOST = {"id": "PVTI_lAHOAM0rvM4BlL66zg9sR80", "type": "REDACTED", "status": None, "priority": None,
         "rank": None, "content": None}


def pull(number, head, rollup="SUCCESS", verify=None, comment_hours_ago=None, fork=False):
    return {
        "number": number, "title": f"PR {number}", "url": f"https://github.com/{REPO}/pull/{number}",
        "isDraft": False, "headRefName": head, "isCrossRepository": fork,
        "comments": {"nodes": [{"createdAt": iso(comment_hours_ago)}] if comment_hours_ago is not None else []},
        "commits": {"nodes": [{"commit": {
            "oid": "a" * 40,
            "statusCheckRollup": {"state": rollup} if rollup else None,
            "status": {"context": {"state": verify}} if verify else None,
        }}]},
    }


def claim(branch, session="session-a", pushed_hours_ago=1.0):
    return {"branch": branch, "sha": "b" * 40, "session": session, "committed_at": iso(pushed_hours_ago)}


def snapshot(items=(), labeled=(), pulls=(), states=None, claims=(), worktrees=()):
    return {
        "repository": REPO,
        "project_items": list(items),
        "labeled_issues": list(labeled),
        "pull_requests": list(pulls),
        "issue_states": states or {},
        "claims": list(claims),
        "worktrees": list(worktrees),
        "worktree_root": ROOT,
        "checkout_parent": PARENT,
    }


def model_of(**kwargs):
    return build(snapshot(**kwargs), CONFIG, NOW)


class EscapingTests(unittest.TestCase):
    # Failure mode 20.
    HOSTILE = '<script>alert(1)</script>"><img src=x onerror=alert(2)>'

    def test_github_text_is_escaped_and_nothing_external_loads(self):
        hostile_issue = issue(7, title=self.HOSTILE, labels=["needs-decision", "<b>label</b>"])
        hostile_issue["url"] = "javascript:alert(3)"
        model = model_of(
            items=[item(hostile_issue, status="In progress"), item(issue(8, title=self.HOSTILE), status="Ready")],
            claims=[claim("feat/7-<svg-onload=x>")],
            pulls=[pull(9, "feat/7-<svg-onload=x>")],
        )
        page = render_html(model)
        for raw in ("<script", "<img", "<svg", "<b>label", "javascript:"):
            self.assertNotIn(raw, page)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", page)
        self.assertIn("&lt;svg-onload=x&gt;", page)
        # Self-contained: no stylesheet, script, image or font fetches.
        self.assertIsNone(re.search(r"<link|<[^>]*\bsrc=|@import|url\(", page, re.IGNORECASE))


class GhostItemTests(unittest.TestCase):
    # Failure mode 21.
    def test_items_without_usable_content_are_ignored_and_counted(self):
        model = model_of(items=[
            GHOST,
            dict(GHOST, id="PVTI_ghost2"),
            item({"__typename": "DraftIssue"}, status="Ready", kind="DRAFT_ISSUE"),
            item({"__typename": "PullRequest", "number": 5}, status="Ready", kind="PULL_REQUEST"),
            item(issue(6, repo="other/repo"), status="Ready"),
            item(issue(1), status="Ready"),
        ])
        self.assertEqual([entry["number"] for entry in model["ready"]], [1])
        self.assertEqual(model["ignored_items"], 5)
        render_html(model)
        render_text(model)


class StaleTests(unittest.TestCase):
    # Failure mode 22.
    def stale_numbers(self, pushed, issue_comment=None, pr_comment=None):
        model = model_of(
            items=[item(issue(3, comment_hours_ago=issue_comment), status="In progress")],
            claims=[claim("feat/3-x", pushed_hours_ago=pushed)],
            pulls=[pull(4, "feat/3-x", comment_hours_ago=pr_comment)],
        )
        return [entry["number"] for entry in model["stale"]]

    def test_latest_of_push_and_comments_counts(self):
        self.assertEqual(self.stale_numbers(pushed=100, issue_comment=1), [])
        self.assertEqual(self.stale_numbers(pushed=100, issue_comment=90, pr_comment=2), [])
        self.assertEqual(self.stale_numbers(pushed=2, issue_comment=100), [])
        self.assertEqual(self.stale_numbers(pushed=49, issue_comment=60, pr_comment=50), [3])

    def test_threshold_is_48_hours(self):
        self.assertEqual(self.stale_numbers(pushed=47.9), [])
        self.assertEqual(self.stale_numbers(pushed=48.1), [3])

    def test_stale_claim_stays_in_progress(self):
        model = model_of(items=[item(issue(3), status="In progress")], claims=[claim("feat/3-x", pushed_hours_ago=200)])
        self.assertEqual([entry["number"] for entry in model["in_progress"]], [3])
        self.assertTrue(model["in_progress"][0]["stale"])


class ForkPullTests(unittest.TestCase):
    # Failure mode 29.
    def test_fork_pull_request_with_the_claim_branch_name_is_ignored(self):
        model = model_of(
            items=[item(issue(3), status="In progress")],
            claims=[claim("feat/3-x", pushed_hours_ago=100)],
            # The fork's PR is older (wins by number) and freshly commented.
            pulls=[pull(4, "feat/3-x", rollup="FAILURE", comment_hours_ago=1, fork=True),
                   pull(6, "feat/3-x", rollup="SUCCESS", comment_hours_ago=90)],
        )
        row = model["in_progress"][0]
        self.assertEqual((row["pr"]["number"], row["pr"]["checks"]), (6, "SUCCESS"))
        self.assertEqual([entry["number"] for entry in model["stale"]], [3])

    def test_fork_pull_request_alone_is_no_pull_request(self):
        model = model_of(items=[item(issue(3), status="In progress")], claims=[claim("feat/3-x")],
                         pulls=[pull(4, "feat/3-x", fork=True)])
        self.assertIsNone(model["in_progress"][0]["pr"])


class DisagreementTests(unittest.TestCase):
    # Failure modes 23 and 42.
    def test_each_kind_is_reported(self):
        model = model_of(
            items=[
                item(issue(1), status="Ready"),         # claimed but still Ready
                item(issue(2), status="In progress"),   # In progress without a claim
                item(issue(3), status="In progress"),   # two claim branches
                item(issue(4), status="In progress"),   # consistent
                item(issue(5), status="In review"),     # consistent: landing
                item(issue(6), status="Needs you"),     # consistent: waiting on the maintainer mid-claim
                item(issue(7), status="Needs you"),     # consistent: merged, branch deleted, awaiting validation
                item(issue(8), status="In review"),     # In review without a claim
            ],
            claims=[claim("feat/1-a"), claim("feat/3-b"), claim("fix/3-a", session="session-b"), claim("feat/4-d"),
                    claim("feat/5-e"), claim("feat/6-f")],
        )
        kinds = sorted((d["number"], d["kind"]) for d in model["disagreements"])
        self.assertEqual(kinds, [(1, "claim-without-claimed-status"), (2, "active-without-claim"),
                                 (3, "multiple-claims"), (8, "active-without-claim")])
        self.assertEqual([row["number"] for row in model["in_progress"]], [2, 3, 4, 5, 8])
        self.assertEqual(model["soft_cap"]["in_progress"], 5)

    def test_claim_of_issue_outside_the_project_disagrees(self):
        model = model_of(claims=[claim("feat/5-e")], states={5: "OPEN"})
        self.assertEqual([(d["number"], d["kind"]) for d in model["disagreements"]],
                         [(5, "claim-without-claimed-status")])

    def test_in_progress_row_uses_the_winning_claim(self):
        model = model_of(items=[item(issue(3), status="In progress")],
                         claims=[claim("feat/3-b", session="loser"), claim("feat/3-a", session="winner")])
        row = model["in_progress"][0]
        self.assertEqual((row["branch"], row["session"]), ("feat/3-a", "winner"))


class ReadyOrderTests(unittest.TestCase):
    # Failure mode 24.
    def test_epic_rank_then_declared_priority_then_unblocked(self):
        model = model_of(items=[
            item(issue(100, labels=["epic"]), status="In progress", rank=2),
            item(issue(200, labels=["epic"]), status="In progress", rank=1),
            item(issue(11, parent=100), status="Ready", priority="Urgent"),
            item(issue(21, parent=200), status="Ready", priority="Normal"),
            item(issue(22, parent=200, blocked_by=[(5, "OPEN")]), status="Ready", priority="Urgent"),
            item(issue(23, parent=200, blocked_by=[(6, "CLOSED")]), status="Ready", priority="Urgent"),
            # The parent epic's rank wins over the task's own.
            item(issue(24, parent=200), status="Ready", priority="Later", rank=9),
            item(issue(30), status="Ready", priority="Urgent", rank=1),
            item(issue(40), status="Ready", priority="Urgent"),
            item(issue(41), status="Ready"),
        ])
        self.assertEqual([entry["number"] for entry in model["ready"]], [23, 30, 22, 21, 24, 11, 40, 41])
        self.assertEqual(model["ready"][2]["open_blockers"], [5])
        self.assertEqual([entry["number"] for entry in model["epics"]], [200, 100])


class OrphanTests(unittest.TestCase):
    # Failure modes 25 and 26.
    def test_orphans_and_live_work(self):
        model = model_of(
            items=[item(issue(1), status="In progress"), item(issue(2, state="CLOSED"), status="Done")],
            claims=[claim("feat/1-live"), claim("feat/2-done"), claim("fix/77-gone")],
            states={77: "MISSING"},
            worktrees=[
                {"path": ROOT + "/1-live", "branch": "feat/1-live"},
                {"path": ROOT + "/2-done", "branch": "feat/2-done"},
                {"path": ROOT + "/side", "branch": "feat/side-work"},
                {"path": ROOT + "/detached", "branch": None},
                {"path": ROOT + "/3-local", "branch": "feat/3-local"},
                {"path": PARENT + "/repo", "branch": "main"},
                {"path": "/private/tmp/elsewhere", "branch": "feat/9-tmp"},
            ],
        )
        self.assertEqual(sorted(o["path"] for o in model["orphans"]["worktrees"]),
                         ["repo-worktrees/2-done", "repo-worktrees/3-local", "repo-worktrees/detached",
                          "repo-worktrees/side"])
        self.assertEqual(sorted(o["branch"] for o in model["orphans"]["branches"]), ["feat/2-done", "fix/77-gone"])
        self.assertEqual(model["in_progress"][0]["worktree"], "repo-worktrees/1-live")
        rendered = render_html(model) + render_text(model) + json.dumps(model)
        self.assertNotIn(PARENT, rendered)
        self.assertNotIn("/private/tmp", rendered)


class NeedsYouTests(unittest.TestCase):
    # Failure mode 27.
    def test_label_or_status_and_only_open(self):
        model = model_of(
            items=[
                item(issue(1), status="Needs you"),
                item(issue(2, labels=["needs-decision"]), status="Ready"),
                item(issue(3, state="CLOSED"), status="Needs you"),
            ],
            labeled=[issue(2, labels=["needs-decision"]), issue(4, labels=["needs-decision"]),
                     issue(5, labels=["regression"])],
        )
        self.assertEqual([entry["number"] for entry in model["needs_you"]], [1, 2, 4])
        self.assertEqual([entry["number"] for entry in model["regressions"]], [5])


class FakeGh:
    """Replays recorded GraphQL pages keyed by connection and cursor."""

    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def graphql(self, query, missing_ok=False, **variables):
        self.calls.append(query)
        if "projectsV2(" in query:
            return {"repository": {"projectsV2": {"nodes": [{"id": "P1", "title": "Work", "closed": False}]}}}
        if "issueOrPullRequest" in query:
            return {"repository": {alias: {"__typename": "Issue", "state": "CLOSED"}
                                   for alias in re.findall(r"(n\d+): issueOrPullRequest", query)}}
        key = "items" if "items(" in query else "pullRequests" if "pullRequests(" in query else "issues"
        page = self.pages[key][variables.get("cursor")]
        if key == "items":
            return {"node": {"items": page}}
        return {"repository": {key: page}}


def page(nodes, next_cursor=None):
    return {"pageInfo": {"hasNextPage": next_cursor is not None, "endCursor": next_cursor}, "nodes": nodes}


class PaginationTests(unittest.TestCase):
    # Failure mode 28.
    def test_every_page_is_read_in_bounded_calls(self):
        gh = FakeGh({
            "items": {None: page([item(issue(n), status="Ready") for n in range(1, 101)], "c1"),
                      "c1": page([item(issue(101), status="Ready"), GHOST])},
            "pullRequests": {None: page([pull(500, "feat/1-a")], "p1"), "p1": page([pull(501, "feat/2-b")])},
            "issues": {None: page([issue(300, labels=["regression"])], "l1"),
                       "l1": page([issue(301, labels=["regression"])])},
        })
        github = fetch_github(gh, "owner", "repo", CONFIG, claim_numbers=[1, 900, 901])
        self.assertEqual(len(github["project_items"]), 102)
        self.assertEqual([p["number"] for p in github["pull_requests"]], [500, 501])
        self.assertEqual([i["number"] for i in github["labeled_issues"]], [300, 301])
        # Only claim numbers the other reads did not return are looked up.
        self.assertEqual(github["issue_states"], {900: "CLOSED", 901: "CLOSED"})
        # Project lookup, 2 item pages, 2 label pages, 2 PR pages, 1 state query.
        self.assertEqual(len(gh.calls), 8)


# A stand-in `gh` executable answering like the real CLI: `api graphql` prints
# the response and exits 1 when it carries errors, with NOT_FOUND paths as
# recorded from the live API.
FAKE_GH = """
import json, os, re, sys
fixture = json.load(open(os.environ["FAKE_GH_FIXTURE"]))
if sys.argv[1:3] == ["repo", "view"]:
    print("owner/repo")
    sys.exit(0)
query = json.load(sys.stdin)["query"]
def page(nodes):
    return {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}
errors = []
if "projectsV2(" in query:
    data = {"repository": {"projectsV2": {"nodes": [{"id": "P1", "title": "Work"}]}}}
elif "issueOrPullRequest" in query:
    if fixture["repository_missing"]:
        data = {"repository": None}
        errors.append({"type": "NOT_FOUND", "path": ["repository"],
                       "message": "Could not resolve to a Repository with the name 'owner/repo'."})
    else:
        data = {"repository": {}}
        for alias in re.findall(r"(n\\d+): issueOrPullRequest", query):
            state = fixture["states"].get(alias[1:])
            data["repository"][alias] = {"__typename": "Issue", "state": state} if state else None
            if not state:
                errors.append({"type": "NOT_FOUND", "path": ["repository", alias],
                               "message": "Could not resolve to an issue or pull request."})
elif "items(" in query:
    data = {"node": {"items": page(fixture["items"])}}
elif "pullRequests(" in query:
    data = {"repository": {"pullRequests": page([])}}
else:
    data = {"repository": {"issues": page([])}}
print(json.dumps(dict(data=data, **({"errors": errors} if errors else {}))))
if errors:
    print("gh: " + errors[0]["message"], file=sys.stderr)
    sys.exit(1)
"""


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


class RunTests(unittest.TestCase):
    """Failure modes 30 and 31, through `run` with real Git and a stand-in `gh`."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        remote = self.root / "remote.git"
        git(self.root, "init", "-q", "--bare", "-b", "main", str(remote))
        self.repo = self.root / "repo"
        git(self.root, "clone", "-q", str(remote), str(self.repo))
        git(self.repo, "config", "user.name", "Agent")
        git(self.repo, "config", "user.email", "agent@example.invalid")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")
        git(self.repo, "push", "-q", "origin", "HEAD:main")
        create_claim(self.repo, "origin", "main", "feat/1-live", 1, "session-a")
        # Worktrees on claim-style branches; only feat/1-live has a remote branch.
        for branch in ("feat/1-live", "feat/3-local", "feat/4-gone", "feat/5-closed"):
            path = self.root / "repo-worktrees" / branch.split("/")[1]
            git(self.repo, "worktree", "add", "-q", "-b", branch, str(path), "main")
        self.script = self.root / "gh"
        self.script.write_text(f"#!{sys.executable}\n" + FAKE_GH)
        self.script.chmod(0o755)

    def tearDown(self):
        self._tmp.cleanup()

    def run_dashboard(self, repository_missing=False):
        fixture = self.root / "fixture.json"
        fixture.write_text(json.dumps({
            "repository_missing": repository_missing,
            # Issue 3 exists but is not in the Project; issue 4 does not exist.
            "states": {"3": "OPEN", "5": "CLOSED"},
            "items": [item(issue(1), status="In progress")],
        }))
        out = self.root / "out.json"
        env = {"WORK_GH": str(self.script), "FAKE_GH_FIXTURE": str(fixture)}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(io.StringIO()):
            run(Gh(self.repo), self.repo, CONFIG, None, out)
        return out.read_text()

    def test_orphan_worktree_reasons_use_the_real_issue_state(self):
        output = self.run_dashboard()
        model = json.loads(output)
        self.assertEqual(sorted((o["path"], o["reason"]) for o in model["orphans"]["worktrees"]), [
            ("repo-worktrees/3-local", "no remote claim branch for #3"),
            ("repo-worktrees/4-gone", "issue #4 does not exist"),
            ("repo-worktrees/5-closed", "issue #5 is closed"),
        ])
        row = model["in_progress"][0]
        self.assertEqual((row["branch"], row["session"], row["worktree"]),
                         ("feat/1-live", "session-a", "repo-worktrees/1-live"))
        self.assertNotIn(str(self.root), output)

    def test_missing_repository_fails_the_run(self):
        with self.assertRaises(GhError):
            self.run_dashboard(repository_missing=True)


if __name__ == "__main__":
    unittest.main()
