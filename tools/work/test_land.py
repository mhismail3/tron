"""Isolated checks for land and steward failure modes 32-42 in README.md.

Real temporary repositories with a local bare remote. GitHub is a fake `gh`
(WORK_GH) that keeps pull request, check, status, issue and Project state in a
JSON file, merges on the bare remote as a squash, and records every call.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import claim as claims
import dashboard
import land
import start
from gh import Gh

REMOTE = "origin"
BASE = "main"
NUMBER = 7
BRANCH = "feat/7-add-the-widget"
SESSION = "session-a"
REPO = "acme/widget"
STATUSES = ["Proposed", "Ready", "In progress", "In review", "Needs you", "Blocked", "Done"]

FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, re, subprocess, sys
    args = sys.argv[1:]
    reads_stdin = "--input" in args or ("--body-file" in args and args[args.index("--body-file") + 1] == "-")
    stdin = sys.stdin.read() if reads_stdin else ""
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps({"args": args, "stdin": stdin}) + "\\n")
    path = os.environ["FAKE_GH_STATE"]
    state = json.load(open(path))
    repo = state["repo"]
    env = dict(os.environ, GIT_AUTHOR_NAME="GitHub", GIT_AUTHOR_EMAIL="gh@example.invalid",
               GIT_COMMITTER_NAME="GitHub", GIT_COMMITTER_EMAIL="gh@example.invalid")

    def git(*a):
        return subprocess.run(["git", "--git-dir", state["remote"], *a], capture_output=True, text=True,
                              check=True, env=env).stdout.strip()

    def ref(branch):
        out = subprocess.run(["git", "--git-dir", state["remote"], "rev-parse", "-q", "--verify",
                              "refs/heads/" + branch], capture_output=True, text=True)
        return out.stdout.strip() or None

    def arg(name):
        return args[args.index(name) + 1] if name in args else None

    def done(output=None):
        json.dump(state, open(path, "w"))
        if output is not None:
            print(output if isinstance(output, str) else json.dumps(output))
        sys.exit(0)

    def fail(message):
        json.dump(state, open(path, "w"))
        print(message, file=sys.stderr)
        sys.exit(1)

    def pull(number):
        return next(p for p in state["pulls"] if p["number"] == int(number))

    def head_of(p):
        return ref(p["headRefName"]) if p["state"] == "OPEN" else p["headRefOid"]

    def contexts(sha):
        pending = state["views"] <= state.get("pendingViews", 0) and state.get("pendingViews", 0) > 0
        nodes = [{"__typename": "CheckRun", "name": name, "status": "IN_PROGRESS" if pending else "COMPLETED",
                  "conclusion": None if pending else conclusion}
                 for name, conclusion in state["checks"].items()]
        nodes += [{"__typename": "StatusContext", "context": c, "state": s}
                  for c, s in state["statuses"].get(sha, {}).items()]
        return nodes

    def issue_node(number):
        issue = state["issues"][str(number)]
        options = [{"id": "opt-" + s, "name": s} for s in state["statusNames"]]
        items = [{"id": "item-" + str(number),
                  "project": {"id": "project", "title": state["project"], "field": {"id": "field", "options": options}},
                  "fieldValueByName": {"name": issue["status"]} if issue["status"] else None}] if issue["inProject"] else []
        return {"id": "I_" + str(number), "number": number, "state": issue["state"], "title": issue["title"],
                "url": "https://github.com/%s/issues/%d" % (repo, number),
                "labels": {"nodes": [{"name": l} for l in issue["labels"]]}, "blockedBy": {"nodes": []},
                "comments": {"nodes": [{"body": b} for b in issue["comments"]]}, "projectItems": {"nodes": items}}

    command = args[:2]
    if command == ["repo", "view"]:
        done(repo)
    if command == ["api", "graphql"]:
        request = json.loads(stdin)
        query, variables = request["query"], request["variables"]
        if "updateProjectV2ItemFieldValue" in query:
            state["issues"][variables["item"].split("-", 1)[1]]["status"] = variables["option"][len("opt-"):]
            done({"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": variables["item"]}}}})
        if "issue(number:" in query:
            done({"data": {"repository": {"issue": issue_node(variables["number"])}}})
        if "pullRequests(" in query:
            nodes = []
            for p in state["pulls"]:
                if p["state"] != "OPEN":
                    continue
                sha = head_of(p)
                nodes.append({"number": p["number"], "title": p["title"], "body": p["body"],
                              "url": "https://github.com/%s/pull/%d" % (repo, p["number"]),
                              "headRefName": p["headRefName"], "isCrossRepository": p.get("fork", False),
                              "reviewThreads": {"nodes": [{"isResolved": r} for r in p.get("threads", [])]},
                              "commits": {"nodes": [{"commit": {
                                  "oid": sha, "committedDate": "2026-09-30T00:00:00Z",
                                  "statusCheckRollup": {"contexts": {"nodes": contexts(sha)}}}}]}})
            done({"data": {"repository": {"pullRequests": {
                "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}})
        if "items(" in query:
            nodes = [{"fieldValueByName": {"name": i["status"]} if i["status"] else None,
                      "content": {"__typename": "Issue", "state": i["state"], "repository": {"nameWithOwner": repo},
                                  "labels": {"nodes": [{"name": l} for l in i["labels"]]}}}
                     for i in state["issues"].values() if i["inProject"]]
            done({"data": {"node": {"items": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                              "nodes": nodes}}}})
        fail("fake gh: unknown query")
    if args[0] == "api":
        method, api = args[args.index("-X") + 1], args[3]
        body = json.loads(stdin) if stdin else None
        if "/statuses/" in api:
            state["statuses"].setdefault(api.rsplit("/", 1)[1], {})[body["context"]] = body["state"].upper()
            done("{}")
        if method == "GET" and api == "repos/%s-evidence" % repo:
            done({"private": True})
        if method == "GET" and "/contents/" in api:
            fail("gh: Not Found (HTTP 404)")
        if api.endswith("/comments"):
            number = api.split("/")[-2]
            target = state["issues"].get(number)
            if target is not None:
                target["comments"].append(body["body"])
            done({"html_url": "https://example.invalid/comment"})
        done("{}")
    if command == ["pr", "list"]:
        pulls = [p for p in state["pulls"] if p["state"] == "OPEN" and p["headRefName"] == arg("--head")]
        if arg("--jq") == ".[].number":
            done("\\n".join(str(p["number"]) for p in pulls))
        done([{"number": p["number"], "title": p["title"], "body": p["body"], "isCrossRepository": p.get("fork", False),
               "url": "https://github.com/%s/pull/%d" % (repo, p["number"])} for p in pulls])
    if command == ["pr", "create"]:
        number = 100 + len(state["pulls"])
        state["pulls"].append({"number": number, "headRefName": arg("--head"), "title": arg("--title"),
                               "body": stdin, "state": "OPEN", "headRefOid": None, "mergeCommit": None})
        done("https://github.com/%s/pull/%d" % (repo, number))
    if command == ["pr", "edit"]:
        p = pull(args[2])
        p["title"], p["body"] = arg("--title"), stdin
        done("")
    if command == ["pr", "view"]:
        p = pull(args[2])
        state["views"] += 1
        move = state.get("baseMoves", {}).get(str(state["views"]))
        if move:
            git("update-ref", "refs/heads/" + state["base"], move)
        sha = head_of(p)
        done({"state": p["state"], "headRefOid": sha, "mergeCommit": p["mergeCommit"],
              "statusCheckRollup": contexts(sha)})
    if command == ["pr", "merge"]:
        p = pull(args[2])
        if p["state"] != "OPEN":
            fail("pull request is not open")
        head = ref(p["headRefName"])
        if arg("--match-head-commit") != head:
            fail("Head branch was modified. Review and try the merge again.")
        if state.get("mergeNoop"):
            done("")
        base = ref(state["base"])
        tree = git("merge-tree", "--write-tree", base, head).splitlines()[0]
        commit = git("commit-tree", tree, "-p", base, "-m", arg("--subject") + "\\n\\n" + arg("--body"))
        git("update-ref", "refs/heads/" + state["base"], commit, base)
        p.update(state="MERGED", headRefOid=head, mergeCommit={"oid": commit}, squash=[arg("--subject"), arg("--body")])
        number = re.search(r"#(\\d+)", p["body"]).group(1)
        if state.get("closeAnyway") or (state.get("closeOnMerge") and ("Closes #" + number) in p["body"]):
            state["issues"][number]["state"] = "CLOSED"
        if state.get("pushAfterMerge"):
            git("update-ref", "refs/heads/" + p["headRefName"], state["pushAfterMerge"])
        if state.get("deleteOnMerge"):
            git("update-ref", "-d", "refs/heads/" + p["headRefName"])
        done("")
    if args[0] == "issue":
        issue = state["issues"][args[2]]
        if args[1] == "close":
            issue["state"] = "CLOSED"
            if arg("--comment"):
                issue["comments"].append(arg("--comment"))
        elif args[1] == "reopen":
            issue["state"] = "OPEN"
        elif args[1] == "comment":
            if state.get("failIssueComment"):
                fail("gh: Bad Gateway (HTTP 502)")
            issue["comments"].append(stdin)
        elif args[1] == "edit":
            issue["labels"].append(arg("--add-label"))
        done("")
    fail("fake gh: unhandled " + " ".join(args))
    """
)

CONFIG = {
    "project": {"title": "Work"},
    "claim": {
        "remote": REMOTE, "baseBranch": BASE, "worktreeRoot": "../worktrees", "readyStatus": "Ready",
        "claimedStatus": "In progress", "claimedStatuses": ["In progress", "In review", "Needs you"],
        "activeStatuses": ["In progress", "In review"], "statusField": "Status", "excludeLabels": ["epic"],
        "softCap": 6, "branchTypes": [], "defaultBranchType": "feat",
    },
    "verify": {
        "prelude": "", "statusContext": "test/verify", "scrubCommand": "! grep -q FORBIDDEN",
        "evidenceRepositorySuffix": "-evidence", "excerptLines": 5, "checks": [],
    },
    "land": {
        "requiredChecks": ["policy"], "reviewStatus": "In review", "doneStatus": "Done",
        "userValidationLabel": "needs-user-validation", "waitSeconds": 60, "pollSeconds": 10, "maxRounds": 3,
    },
    "dashboard": {"needsYouStatus": "Needs you"},
}

# gh subcommands that change GitHub; everything else only reads.
_WRITES = {("pr", "create"), ("pr", "edit"), ("pr", "merge"), ("issue", "close"), ("issue", "reopen"),
           ("issue", "comment"), ("issue", "edit")}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class LandFixture(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.remote = self.tmp / "remote.git"
        git(self.tmp, "init", "-q", "--bare", "-b", BASE, str(self.remote))
        self.seed = self._clone("seed")
        self.write(self.seed, "README.md", "one\n")
        self.write(self.seed, "app/a.txt", "one\n")
        git(self.seed, "add", "-A")
        git(self.seed, "commit", "-q", "-m", "base")
        git(self.seed, "push", "-q", REMOTE, f"HEAD:{BASE}")
        self.repo = self._clone("repo")
        self.claim_sha = claims.create_claim(self.repo, REMOTE, BASE, BRANCH, NUMBER, SESSION).sha
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "checkout", "-q", "-b", BRANCH, "--track", f"{REMOTE}/{BRANCH}")
        self.commit(self.repo, "app/a.txt", "two\n")

        self.counts = self.tmp / "counts"
        self.fail_flag = self.tmp / "fail"
        self.config = json.loads(json.dumps(CONFIG))
        self.config["verify"]["checks"] = [
            {"name": "app", "paths": ["app/**"], "command": f"echo run >> {self.counts} && ! test -e {self.fail_flag}"},
            {"name": "lib", "paths": ["lib/**"], "command": "true"},
            {"name": "policy", "paths": [], "always": True, "command": "true"},
        ]
        self.summary = self.tmp / "summary.md"
        self.summary.write_text("Adds the widget.\n")

        self.state_path = self.tmp / "state.json"
        self.gh_log = self.tmp / "gh.jsonl"
        self.set_state(
            repo=REPO, remote=str(self.remote), base=BASE, project="Work", statusNames=STATUSES,
            issues={str(NUMBER): {"title": "[Task]: Add the widget", "state": "OPEN", "labels": ["task"],
                                  "status": "In progress", "inProject": True, "comments": []}},
            pulls=[], statuses={}, checks={"policy": "SUCCESS"}, views=0,
        )
        fake = self.tmp / "gh"
        fake.write_text(FAKE_GH.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        fake.chmod(0o755)
        env = {"WORK_GH": str(fake), "FAKE_GH_STATE": str(self.state_path), "FAKE_GH_LOG": str(self.gh_log)}
        saved = {key: os.environ.get(key) for key in env}
        os.environ.update(env)
        self.addCleanup(self._restore, saved)
        self.sleeps = []
        self.now = 0.0

    @staticmethod
    def _restore(saved: dict) -> None:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _clone(self, name: str) -> Path:
        path = self.tmp / name
        git(self.tmp, "clone", "-q", str(self.remote), str(path))
        git(path, "config", "user.name", "Agent")
        git(path, "config", "user.email", "agent@example.invalid")
        return path

    @staticmethod
    def write(repo: Path, relative: str, content: str) -> None:
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self, repo: Path, relative: str, content: str) -> str:
        self.write(repo, relative, content)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", f"change {relative}")
        return git(repo, "rev-parse", "HEAD")

    def base_commit(self, relative: str, content: str) -> str:
        """A new base-branch commit, stored on the remote but not yet on the base branch."""
        git(self.seed, "fetch", "-q", REMOTE)
        git(self.seed, "checkout", "-q", "--detach", f"{REMOTE}/{BASE}")
        sha = self.commit(self.seed, relative, content)
        git(self.seed, "push", "-q", REMOTE, f"{sha}:refs/heads/pending-{sha[:8]}")
        return sha

    def advance_base(self, relative: str, content: str) -> str:
        sha = self.base_commit(relative, content)
        git(self.seed, "push", "-q", REMOTE, f"{sha}:refs/heads/{BASE}")
        return sha

    # ------------------------------------------------------------ fake GitHub

    def state(self) -> dict:
        return json.loads(self.state_path.read_text())

    def set_state(self, **values) -> None:
        state = self.state() if self.state_path.exists() else {}
        state.update(values)
        self.state_path.write_text(json.dumps(state))

    def calls(self) -> list:
        if not self.gh_log.exists():
            return []
        return [json.loads(line) for line in self.gh_log.read_text().splitlines()]

    def writes(self) -> list:
        out = []
        for call in self.calls():
            args = call["args"]
            if tuple(args[:2]) in _WRITES:
                out.append(" ".join(args[:2]))
            elif args[:2] == ["api", "graphql"]:
                if "mutation" in call["stdin"]:
                    out.append("graphql mutation")
            elif args[0] == "api" and args[args.index("-X") + 1] != "GET":
                out.append(f"api {args[args.index('-X') + 1]} {args[3]}")
        return out

    def merges(self) -> list:
        return [c["args"] for c in self.calls() if c["args"][:2] == ["pr", "merge"]]

    def remote_head(self, branch: str = BRANCH) -> str:
        line = git(self.repo, "ls-remote", REMOTE, f"refs/heads/{branch}")
        return line.split()[0] if line else ""

    def issue(self) -> dict:
        return self.state()["issues"][str(NUMBER)]

    # ------------------------------------------------------------------ land

    # Waiting runs on a fake clock that only sleeping advances.
    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def clock(self) -> float:
        return self.now

    def land(self, session: str = SESSION, title=None, summary=True, validation=None, sleep=None) -> int:
        return land.land(Gh(self.repo), self.repo, self.config, session, title,
                         self.summary if summary else None, validation, sleep=sleep or self.sleep, clock=self.clock)


class ClaimOwnerTests(LandFixture):
    # Failure mode 32.
    def test_another_sessions_claim_is_refused_before_any_github_write(self):
        with self.assertRaises(land.LandError) as raised:
            self.land(session="session-b")
        self.assertIn(SESSION, str(raised.exception))
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_a_branch_that_is_not_a_claim_is_refused(self):
        git(self.repo, "checkout", "-q", "-b", "scratch")
        with self.assertRaises(land.LandError):
            self.land()
        self.assertEqual(self.writes(), [])


class TreeStateTests(LandFixture):
    # Failure mode 33.
    def test_dirty_detached_or_mid_operation_trees_are_refused(self):
        git_dir = Path(git(self.repo, "rev-parse", "--absolute-git-dir"))
        head = git(self.repo, "rev-parse", "HEAD")
        cases = {
            "untracked": lambda: self.write(self.repo, "new.txt", "x\n"),
            "modified": lambda: self.write(self.repo, "app/a.txt", "dirty\n"),
            "merge": lambda: (git_dir / "MERGE_HEAD").write_text(head + "\n"),
            "rebase": lambda: (git_dir / "rebase-merge").mkdir(),
            "cherry-pick": lambda: (git_dir / "CHERRY_PICK_HEAD").write_text(head + "\n"),
            "detached": lambda: git(self.repo, "checkout", "-q", "--detach"),
        }
        for name, make in cases.items():
            with self.subTest(case=name):
                make()
                with self.assertRaises(land.LandError):
                    self.land()
                git(self.repo, "checkout", "-q", "-f", BRANCH)
                git(self.repo, "clean", "-qfd")
                for leftover in ("MERGE_HEAD", "CHERRY_PICK_HEAD"):
                    (git_dir / leftover).unlink(missing_ok=True)
                if (git_dir / "rebase-merge").exists():
                    (git_dir / "rebase-merge").rmdir()
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_closed_issue_or_missing_summary_is_refused(self):
        with self.assertRaises(land.LandError):
            self.land(summary=False)
        issues = self.state()["issues"]
        issues[str(NUMBER)]["state"] = "CLOSED"
        self.set_state(issues=issues)
        with self.assertRaises(land.LandError):
            self.land()
        self.assertEqual(self.writes(), [])


class ReceiptTests(LandFixture):
    # Failure mode 34.
    def test_failing_receipt_stops_before_push_post_or_pull_request(self):
        self.fail_flag.write_text("")
        with self.assertRaises(land.LandError):
            self.land()
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_merge_names_the_verified_and_pushed_head(self):
        self.assertEqual(self.land(), 0)
        head = git(self.repo, "rev-parse", "HEAD")
        [merge] = self.merges()
        self.assertEqual(merge[merge.index("--match-head-commit") + 1], head)
        self.assertEqual(self.state()["statuses"][head]["test/verify"], "SUCCESS")
        pull = self.state()["pulls"][0]
        self.assertEqual(pull["state"], "MERGED")
        self.assertEqual(pull["title"], "feat: Add the widget")
        self.assertEqual(pull["squash"], ["feat: Add the widget (#7)", "Closes #7"])
        self.assertTrue(pull["body"].startswith("Closes #7\n"))
        self.assertIn("Adds the widget.", pull["body"])
        self.assertIn(f"`{head}`", pull["body"])
        git(self.repo, "fetch", "-q", REMOTE)
        self.assertEqual(git(self.repo, "show", f"{REMOTE}/{BASE}:app/a.txt"), "two")

    def test_a_head_moved_by_someone_else_is_never_merged(self):
        other = self._clone("other")

        def push_elsewhere(seconds):
            if not self.sleeps:
                git(other, "fetch", "-q", REMOTE)
                git(other, "checkout", "-q", "-B", BRANCH, f"{REMOTE}/{BRANCH}")
                moved = self.commit(other, "app/other.txt", "x\n")
                git(other, "push", "-q", REMOTE, f"HEAD:{BRANCH}")
                # Even a head that is green in its own right is not the one land verified.
                statuses = self.state()["statuses"]
                statuses[moved] = {"test/verify": "SUCCESS"}
                self.set_state(statuses=statuses)
            self.sleep(seconds)

        self.set_state(pendingViews=1)
        with self.assertRaises(land.LandError) as raised:
            self.land(sleep=push_elsewhere)
        self.assertIn("timed out", str(raised.exception))
        self.assertEqual(self.merges(), [])


class RequiredCheckTests(LandFixture):
    # Failure mode 35.
    def test_failed_required_check_stops_and_is_named(self):
        self.set_state(checks={"policy": "FAILURE", "optional": "SUCCESS"})
        with self.assertRaises(land.LandError) as raised:
            self.land()
        self.assertIn("a required check failed", str(raised.exception))
        self.assertIn("policy: failure", str(raised.exception))
        self.assertEqual(self.sleeps, [])
        self.assertEqual(self.merges(), [])
        self.assertEqual(self.issue()["state"], "OPEN")

    def test_pending_or_missing_required_check_times_out_without_merging(self):
        for checks, pending in (({"policy": "SUCCESS"}, 10 ** 6), ({"other": "SUCCESS"}, 0)):
            with self.subTest(checks=checks):
                self.set_state(checks=checks, pendingViews=pending)
                with self.assertRaises(land.LandError) as raised:
                    self.land()
                self.assertIn("timed out", str(raised.exception))
        self.assertEqual(self.merges(), [])

    def test_waits_through_pending_checks_then_merges(self):
        self.set_state(pendingViews=3)
        self.assertEqual(self.land(), 0)
        self.assertEqual(len(self.sleeps), 3)
        self.assertEqual(len(self.merges()), 1)


class BaseMoveTests(LandFixture):
    # Failure mode 36.
    def test_base_move_during_the_wait_starts_another_round(self):
        moved = self.base_commit("lib/new.txt", "from base\n")
        self.set_state(pendingViews=1, baseMoves={"1": moved})
        self.assertEqual(self.land(), 0)
        head = git(self.repo, "rev-parse", "HEAD")
        subprocess.run(["git", "merge-base", "--is-ancestor", moved, head], cwd=self.repo, check=True)
        [merge] = self.merges()
        self.assertEqual(merge[merge.index("--match-head-commit") + 1], head)
        self.assertEqual(self.writes().count("pr create"), 1)
        self.assertEqual(self.writes().count("pr edit"), 1)
        self.assertIn(f"`{head}`", self.state()["pulls"][0]["body"])
        self.assertEqual(self.counts.read_text().count("run"), 1, "the unchanged check was carried, not rerun")

    def test_rounds_are_bounded(self):
        self.config["land"]["maxRounds"] = 2
        # Each round's single view moves the base again.
        chained = {}
        git(self.seed, "fetch", "-q", REMOTE)
        parent = git(self.seed, "rev-parse", f"{REMOTE}/{BASE}")
        for view in ("1", "2"):
            git(self.seed, "checkout", "-q", "--detach", parent)
            parent = self.commit(self.seed, f"lib/{view}.txt", "x\n")
            git(self.seed, "push", "-q", REMOTE, f"{parent}:refs/heads/chain-{view}")
            chained[view] = parent
        self.set_state(baseMoves=chained)
        with self.assertRaises(land.LandError) as raised:
            self.land()
        self.assertIn("moved", str(raised.exception))
        self.assertEqual(self.merges(), [])

    def test_conflict_stops_with_the_merge_left_for_the_agent(self):
        self.advance_base("app/a.txt", "conflicting\n")
        with self.assertRaises(land.LandError) as raised:
            self.land()
        self.assertIn("app/a.txt", str(raised.exception))
        git_dir = Path(git(self.repo, "rev-parse", "--absolute-git-dir"))
        self.assertTrue((git_dir / "MERGE_HEAD").exists())
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.remote_head(), self.claim_sha)


class PublicTextTests(LandFixture):
    # Failure mode 37.
    def test_personal_data_in_any_public_text_is_refused_before_any_github_write(self):
        for field in ("summary", "title", "validation"):
            with self.subTest(field=field):
                self.summary.write_text("FORBIDDEN summary\n" if field == "summary" else "Fine.\n")
                with self.assertRaises(land.LandError) as raised:
                    self.land(title="FORBIDDEN title" if field == "title" else None,
                              validation="FORBIDDEN action" if field == "validation" else None)
                self.assertIn(field, str(raised.exception))
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.remote_head(), self.claim_sha)


class IssueOutcomeTests(LandFixture):
    # Failure mode 38.
    def test_issue_github_left_open_is_closed_with_the_pull_request_and_commit(self):
        self.land()
        issue = self.issue()
        merge = self.state()["pulls"][0]["mergeCommit"]["oid"]
        self.assertEqual((issue["state"], issue["status"]), ("CLOSED", "Done"))
        self.assertIn("#100", issue["comments"][-1])
        self.assertIn(merge[:12], issue["comments"][-1])

    def test_issue_github_closed_is_left_closed_and_done(self):
        self.set_state(closeOnMerge=True)
        self.land()
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))
        self.assertNotIn("issue close", self.writes())

    def test_validation_keeps_the_issue_open_even_when_github_closes_it(self):
        self.set_state(closeAnyway=True)
        self.land(validation="Restart the dev Gateway, then check its status.")
        pull = self.state()["pulls"][0]
        self.assertTrue(pull["body"].startswith("Refs #7\n"))
        self.assertNotIn("Closes #7", pull["body"])
        self.assertEqual(pull["squash"][1], "Refs #7")
        self.assertEqual(self.issue()["state"], "OPEN")


class BranchDeletionTests(LandFixture):
    # Failure mode 39.
    def test_branch_is_deleted_after_the_merge(self):
        self.land()
        self.assertEqual(self.remote_head(), "")
        calls = [" ".join(c["args"][:2]) for c in self.calls()]
        self.assertIn("pr merge", calls)

    def test_merge_github_did_not_perform_keeps_the_branch(self):
        self.set_state(mergeNoop=True)
        with self.assertRaises(land.LandError):
            self.land()
        self.assertEqual(self.remote_head(), git(self.repo, "rev-parse", "HEAD"))

    def test_branch_moved_after_the_merge_is_kept(self):
        other = self.commit(self.seed, "other.txt", "x\n")
        git(self.seed, "push", "-q", REMOTE, f"{other}:refs/heads/elsewhere")
        self.set_state(pushAfterMerge=other)
        self.assertEqual(self.land(), 0)
        self.assertEqual(self.remote_head(), other)

    def test_branch_moved_between_the_check_and_the_delete_is_kept(self):
        other = self.commit(self.seed, "other.txt", "x\n")
        git(self.seed, "push", "-q", REMOTE, f"{other}:refs/heads/elsewhere")
        # A receive-pack wrapper moves the branch once the pull request is merged:
        # after land has read the branch, before the delete push connects.
        wrapper = self.tmp / "receive-pack"
        wrapper.write_text(textwrap.dedent(f"""\
            #!{sys.executable}
            import json, os, subprocess, sys
            state = json.load(open(os.environ["FAKE_GH_STATE"]))
            if state["pulls"] and state["pulls"][0]["state"] == "MERGED":
                subprocess.run(["git", "--git-dir", {str(self.remote)!r}, "update-ref",
                                "refs/heads/{BRANCH}", {other!r}], check=True)
            os.execvp("git", ["git", "receive-pack", *sys.argv[1:]])
            """))
        wrapper.chmod(0o755)
        git(self.repo, "config", f"remote.{REMOTE}.receivepack", str(wrapper))
        self.assertEqual(self.land(), 0)
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.assertEqual(self.remote_head(), other)

    def test_branch_github_already_deleted_is_fine(self):
        self.set_state(deleteOnMerge=True)
        self.assertEqual(self.land(), 0)
        self.assertEqual(self.remote_head(), "")


class HandoffTests(LandFixture):
    # Failure mode 40.
    def test_action_text_label_and_status_reach_the_issue(self):
        action = "Run `scripts/example restart`, then check:\n\n- status names this branch"
        self.land(validation=action)
        issue = self.issue()
        self.assertIn(action, issue["comments"][-1])
        self.assertIn("needs-user-validation", issue["labels"])
        self.assertEqual((issue["state"], issue["status"]), ("OPEN", "Needs you"))

    def test_a_failure_after_the_merge_keeps_the_action_text(self):
        action = "Run `scripts/example restart`, then check that status names this branch."
        self.set_state(failIssueComment=True)
        with self.assertRaises(land.LandError) as raised:
            self.land(validation=action)
        pull = self.state()["pulls"][0]
        self.assertEqual(pull["state"], "MERGED")
        # The pull request body was on GitHub before the merge.
        self.assertIn(action, pull["body"])
        self.assertIn(action, str(raised.exception))
        self.assertIn("#100", str(raised.exception))
        self.assertFalse(any(action in comment for comment in self.issue()["comments"]))


class StewardFixture(LandFixture):
    def setUp(self):
        super().setUp()
        git(self.repo, "push", "-q", REMOTE, f"HEAD:{BRANCH}")
        self.head = git(self.repo, "rev-parse", "HEAD")
        self.set_state(
            pulls=[{"number": 100, "headRefName": BRANCH, "title": "feat: Add the widget", "body": "Closes #7\n",
                    "state": "OPEN", "headRefOid": None, "mergeCommit": None, "threads": [False, True]}],
            statuses={self.head: {"test/verify": "SUCCESS"}},
        )
        # The owner's worktree is gone: the steward works from another clone.
        self.steward_repo = self._clone("steward")
        self.counts.unlink(missing_ok=True)

    def steward_land(self) -> int:
        return land.steward(Gh(self.steward_repo), self.steward_repo, self.config, NUMBER)


class StewardTests(StewardFixture):
    # Failure mode 41.
    def test_green_up_to_date_pull_request_is_landed_without_running_checks(self):
        self.assertEqual(self.steward_land(), 0)
        [merge] = self.merges()
        self.assertEqual(merge[merge.index("--match-head-commit") + 1], self.head)
        self.assertFalse(self.counts.exists())
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))
        self.assertEqual(self.remote_head(), "")

    def test_refusals(self):
        state = self.state()
        cases = {
            "verify missing": dict(statuses={}),
            "verify failed": dict(statuses={self.head: {"test/verify": "FAILURE"}}),
            "check red": dict(checks={"policy": "FAILURE"}),
            "check pending": dict(pendingViews=10 ** 6),
            "validation handoff": dict(pulls=[dict(state["pulls"][0], body="Refs #7\n")]),
            "closes another issue": dict(pulls=[dict(state["pulls"][0], body="Closes #70\n")]),
        }
        for name, change in cases.items():
            with self.subTest(case=name):
                self.set_state(**change)
                with self.assertRaises(land.LandError):
                    self.steward_land()
                self.state_path.write_text(json.dumps(state))
        self.advance_base("lib/new.txt", "x\n")
        with self.assertRaises(land.LandError):
            self.steward_land()
        self.assertEqual(self.merges(), [])
        self.assertEqual(self.writes(), [])

    def test_owner_worktree_ahead_of_the_pull_request_is_refused(self):
        self.commit(self.repo, "app/a.txt", "unpushed\n")
        with self.assertRaises(land.LandError):
            land.steward(Gh(self.repo), self.repo, self.config, NUMBER)
        self.assertEqual(self.merges(), [])

    def test_report_lists_the_pull_request_without_writing(self):
        rows = land.steward_rows(Gh(self.steward_repo), self.steward_repo, self.config)
        [row] = rows
        self.assertEqual((row["issue"], row["pr"], row["checks"], row["unresolved"]), (NUMBER, 100, "success", 1))
        self.assertEqual(row["session"], SESSION)
        self.assertEqual(self.writes(), [])


class ClaimedStatusTests(LandFixture):
    # Failure mode 42.
    def test_resumed_start_keeps_a_claim_in_review(self):
        primary = self._clone("primary")
        issues = self.state()["issues"]
        issues[str(NUMBER)]["status"] = "In review"
        self.set_state(issues=issues)
        start.run(Gh(primary), primary, self.config, NUMBER, SESSION)
        self.assertEqual(self.issue()["status"], "In review")
        self.assertNotIn("graphql mutation", self.writes())

    def test_start_and_dashboard_count_the_soft_cap_alike(self):
        cases = [  # (state, labels, status, repository)
            ("OPEN", [], "In progress", REPO), ("OPEN", [], "In review", REPO), ("OPEN", [], "Needs you", REPO),
            ("CLOSED", [], "In progress", REPO), ("OPEN", ["epic"], "In progress", REPO),
            ("OPEN", [], "In progress", "other/repo"), ("OPEN", [], "Ready", REPO),
        ]
        start_nodes, board_items = [None], [{"id": "ghost", "status": {"name": "In progress"}, "content": None}]
        for number, (state, labels, status, repository) in enumerate(cases, 1):
            content = {"__typename": "Issue", "number": number, "title": "t", "url": "https://x", "state": state,
                       "repository": {"nameWithOwner": repository},
                       "labels": {"nodes": [{"name": label} for label in labels]}, "parent": None,
                       "subIssuesSummary": {"total": 0, "completed": 0}, "blockedBy": {"nodes": []},
                       "comments": {"nodes": []}}
            start_nodes.append({"fieldValueByName": {"name": status}, "content": content})
            board_items.append({"id": str(number), "status": {"name": status}, "priority": None, "rank": None,
                                "content": content})
        start_nodes[0] = {"fieldValueByName": {"name": "In progress"}, "content": None}

        class PagedGh:
            def graphql(self, query, **variables):
                return {"node": {"items": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                           "nodes": start_nodes}}}

        board_config = {
            "project": {"title": "Work", "fields": [
                {"name": "Priority", "options": []},
                {"name": self.config["claim"]["statusField"], "options": [{"name": "In progress"}]},
            ]},
            "claim": self.config["claim"],
            "dashboard": {"needsYouStatus": "Needs you", "blockedStatus": "Blocked", "epicLabel": "epic",
                          "needsYouLabels": [], "regressionLabel": "regression", "priorityField": "Priority",
                          "kindPrefix": "kind:", "visibilityPrefix": "visibility:", "areaPrefix": "area:",
                          "ideaLabel": "kind:idea", "recentDays": 14},
        }
        snapshot = {"repository": REPO, "project_items": board_items, "labeled_issues": [], "pull_requests": [],
                    "issue_states": {}, "claims": [], "worktrees": [], "worktree_root": "/w", "checkout_parent": "/"}
        from datetime import datetime, timezone
        model = dashboard.build(snapshot, board_config, datetime(2026, 10, 1, tzinfo=timezone.utc))
        counted = start.count_active(PagedGh(), "project", self.config["claim"], REPO)
        self.assertEqual(counted, 2)
        self.assertEqual(model["soft_cap"]["in_progress"], counted)


if __name__ == "__main__":
    unittest.main()
