"""Isolated checks for land and steward failure modes 32-42, 64-66, 71-78 in README.md.

The stacked-claim cases (75-78) also drive `start`, since a claim's base is set there.

Real temporary repositories with a local bare remote. GitHub is a fake `gh`
(WORK_GH) that keeps pull request, check, status, issue and Project state in a
JSON file, merges on the bare remote as a squash, and records every call.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import contextlib
import errno
import hashlib
import io
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
import zlib
from pathlib import Path

import acceptance
import claim as claims
import dashboard
import land
import start
from gh import Gh
from repo_template import clone_with_identity, copy_template

REMOTE = "origin"
BASE = "main"
NUMBER = 7
BRANCH = "feat/7-add-the-widget"
SESSION = "session-a"
REPO = "acme/widget"
STATUSES = ["Proposed", "Ready", "In progress", "In review", "Needs you", "Blocked", "Done"]
# The fixture's acceptance registry: two journeys and the report each one leaves,
# shaped exactly like the declaration a real `.github/work.json` holds.
PAIR = "pair-and-chat"
WRONG_CODE = "wrong-code"
REPORT_PATH = "results/latest-ui/report.json"

# The stand-in for a registered journey: it writes the report its spec names into
# the evidence directory land hands the run, records every step it took, and can
# be made to run long enough for land's bound or an interrupt to reach it, so
# every report field and every stop path land owns is reachable from a test.
FAKE_JOURNEY = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, signal, subprocess, sys, time
    from pathlib import Path
    journey = sys.argv[1]
    spec = json.loads(Path(os.environ["FAKE_ACCEPTANCE_SPEC"]).read_text()).get(journey, {})
    runs = Path(os.environ["FAKE_ACCEPTANCE_RUNS"])

    def note(what):
        with runs.open("a") as handle:
            handle.write(f"{journey} {what}\\n")

    note("started")
    if spec.get("exit"):
        sys.exit(spec["exit"])
    if spec.get("signal_parent"):
        # The journey signals land's own process the way a terminal Ctrl-C does,
        # then winds down on its own. It replaces its shell (`exec` in the
        # fixture's command), so its parent is land's process.
        time.sleep(spec.get("signal_after", 0.3))
        os.kill(os.getppid(), signal.SIGINT)
        time.sleep(spec.get("wound_down_after", 1.0))
        note("wound down")
    if spec.get("trap_sigint"):
        def wind_down(*_):
            note("cleanup")
            sys.exit(130)
        signal.signal(signal.SIGINT, wind_down)
    if spec.get("handler_signal"):
        os.kill(os.getppid(), signal.SIGUSR2)
    if spec.get("delay_ready"):
        signal.pause()
    if spec.get("ready_signal"):
        # The parent test forces timeout only after SIGINT is known to be handled.
        os.kill(os.getppid(), signal.SIGUSR1)
    if spec.get("sleep"):
        time.sleep(spec["sleep"])
        note("wound down")
    if spec.get("report", True):
        # The same relative report path the registry declares (REPORT_PATH).
        report_dir = Path(os.environ["FAKE_ACCEPTANCE_EVIDENCE"]) / "results/latest-ui"
        report_dir.mkdir(parents=True, exist_ok=True)
        revision = spec.get("revision", "HEAD")
        if revision == "HEAD":
            revision = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                                      check=True).stdout.strip()
        report = {
            "schema": "tron.ios-e2e-ui-journey.v1",
            "journey": spec.get("journey", journey),
            "journey_status": spec.get("status", 0),
            "journey_seconds": spec.get("seconds", 9),
            "evidence_complete": spec.get("evidence_complete", True),
            "source": {"revision": revision, "dirty": spec.get("dirty", False),
                       "source_fingerprint": spec.get("fingerprint", "ab" * 32)},
            "artifacts": [{"path": "Journeys.xcresult", "kind": "tree-sha256", "sha256": "cd" * 32}],
        }
        (report_dir / "report.json").write_text(spec.get("raw") or json.dumps(report, indent=2, sort_keys=True) + "\\n")
        note(f"report {revision}")
    """
)

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
                              "headRefName": p["headRefName"], "baseRefName": p.get("base") or state["base"],
                              "isCrossRepository": p.get("fork", False),
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
        if "/actions/runs" in api:
            if state.get("failRuns"):
                fail("gh: Bad Gateway (HTTP 502)")
            if api.endswith("/cancel"):
                if state.get("failCancel"):
                    fail("gh: Bad Gateway (HTTP 502)")
                state.setdefault("cancelled", []).append(api)
            else:
                done({"workflow_runs": state.get("runs", [])})
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
        wanted = (arg("--state") or "open").upper()
        pulls = [p for p in state["pulls"] if p["state"] == wanted and p["headRefName"] == arg("--head")]
        done([{"number": p["number"], "title": p["title"], "body": p["body"], "isCrossRepository": p.get("fork", False),
               "headRefOid": head_of(p), "baseRefName": p.get("base") or state["base"],
               "mergeCommit": p["mergeCommit"], "url": "https://github.com/%s/pull/%d" % (repo, p["number"])}
              for p in pulls])
    if command == ["pr", "create"]:
        number = 100 + len(state["pulls"])
        state["pulls"].append({"number": number, "headRefName": arg("--head"), "title": arg("--title"),
                               "base": arg("--base"), "body": stdin, "state": "OPEN", "headRefOid": None,
                               "mergeCommit": None})
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
              "mergeable": state.get("mergeable", "MERGEABLE"),
              "baseRefName": p.get("base") or state["base"], "statusCheckRollup": contexts(sha)})
    if command == ["pr", "merge"]:
        p = pull(args[2])
        if p["state"] != "OPEN":
            fail("pull request is not open")
        head = ref(p["headRefName"])
        if arg("--match-head-commit") != head:
            fail("Head branch was modified. Review and try the merge again.")
        if state.get("mergeNoop"):
            done("")
        # A squash onto the pull request's own base, as GitHub merges it.
        target = p.get("base") or state["base"]
        base = ref(target)
        tree = git("merge-tree", "--write-tree", base, head).splitlines()[0]
        commit = git("commit-tree", tree, "-p", base, "-m", arg("--subject") + "\\n\\n" + arg("--body"))
        git("update-ref", "refs/heads/" + target, commit, base)
        p.update(state="MERGED", headRefOid=head, mergeCommit={"oid": commit}, squash=[arg("--subject"), arg("--body")])
        number = re.search(r"#(\\d+)", p["body"]).group(1)
        # GitHub applies `Closes #N` only to merges into the default branch.
        if state.get("closeAnyway") or (state.get("closeOnMerge") and target == state["base"]
                                        and ("Closes #" + number) in p["body"]):
            state["issues"][number]["state"] = "CLOSED"
        for reopened in state.get("reopenOnMerge", []):
            state["issues"][reopened]["state"] = "OPEN"
        if state.get("pushAfterMerge"):
            git("update-ref", "refs/heads/" + p["headRefName"], state["pushAfterMerge"])
        if state.get("deleteOnMerge"):
            git("update-ref", "-d", "refs/heads/" + p["headRefName"])
        done("")
    if args[0] == "issue":
        # failIssue: issue subcommands GitHub refuses, as an outage after the merge would.
        if args[1] in state.get("failIssue", []):
            fail("gh: Bad Gateway (HTTP 502)")
        issue = state["issues"][args[2]]
        if args[1] == "close":
            issue["state"] = "CLOSED"
            if arg("--comment"):
                issue["comments"].append(arg("--comment"))
        elif args[1] == "reopen":
            issue["state"] = "OPEN"
        elif args[1] == "comment":
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


@contextlib.contextmanager
def _owned_test_processes(disable_automatic_maintenance: bool = True):
    saved = {key: value for key, value in os.environ.items() if key.startswith("GIT_CONFIG_")}
    for key in tuple(os.environ):
        if key.startswith("GIT_CONFIG_"):
            os.environ.pop(key)
    if disable_automatic_maintenance:
        os.environ.update({"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "gc.auto",
                           "GIT_CONFIG_VALUE_0": "0", "GIT_CONFIG_KEY_1": "maintenance.auto",
                           "GIT_CONFIG_VALUE_1": "false"})
    original_popen = subprocess.Popen
    processes = []

    def owned_popen(*args, **kwargs):
        process = original_popen(*args, **kwargs)
        processes.append(process)
        return process

    subprocess.Popen = owned_popen
    try:
        yield
    finally:
        subprocess.Popen = original_popen
        try:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        finally:
            for key in tuple(os.environ):
                if key.startswith("GIT_CONFIG_"):
                    os.environ.pop(key)
            os.environ.update(saved)


def _release_child_and_close(release_child, process_owner, fifo_descriptors):
    try:
        release_child()
    finally:
        try:
            process_owner.__exit__(None, None, None)
        finally:
            for fd in fifo_descriptors:
                os.close(fd)


class GitMaintenanceCleanupTests(unittest.TestCase):
    def test_child_release_failure_still_restores_process_owner_and_closes_fifos(self):
        temporary = tempfile.TemporaryDirectory()
        with temporary:
            fifo = Path(temporary.name) / "cleanup.fifo"
            os.mkfifo(fifo)
            fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            original_popen = subprocess.Popen
            original_git_config = os.environ.get("GIT_CONFIG_COUNT")
            owner = _owned_test_processes()
            owner.__enter__()

            def fail_release():
                raise RuntimeError("injected child-release failure")

            with self.assertRaisesRegex(RuntimeError, "injected child-release failure"):
                _release_child_and_close(fail_release, owner, (fd,))

            self.assertIs(subprocess.Popen, original_popen)
            self.assertEqual(os.environ.get("GIT_CONFIG_COUNT"), original_git_config)
            with self.assertRaises(OSError):
                os.fstat(fd)

    def _auto_gc_cleanup(self, disable_automatic_maintenance: bool):
        temporary_directory = tempfile.TemporaryDirectory()
        temporary = temporary_directory.name
        with temporary_directory:
            process_owner = _owned_test_processes(disable_automatic_maintenance)
            process_owner.__enter__()
            owner_closed = False

            def close_process_owner():
                nonlocal owner_closed
                if not owner_closed:
                    owner_closed = True
                    process_owner.__exit__(None, None, None)

            original_cleanup = temporary_directory.cleanup
            cleanup_body = None

            def owned_cleanup():
                if cleanup_body is None:
                    close_process_owner()
                    original_cleanup()
                else:
                    cleanup_body()

            temporary_directory.cleanup = owned_cleanup
            root = Path(temporary)
            remote = root / "remote.git"
            subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
            subprocess.run(["git", "config", "gc.auto", "1"], cwd=remote, check=True)
            subprocess.run(["git", "config", "maintenance.auto", "true"], cwd=remote, check=True)
            subprocess.run(["git", "config", "core.hooksPath", str(remote / "hooks")],
                           cwd=remote, check=True)
            # The owned writer waits until cleanup has enumerated remote.git, then writes before rmdir.
            objects = remote / "objects"
            for index in range(7001):
                content = f"loose-object-{index}".encode()
                data = f"blob {len(content)}\0".encode() + content
                oid = hashlib.sha1(data).hexdigest()
                object_path = objects / oid[:2] / oid[2:]
                object_path.parent.mkdir(parents=True, exist_ok=True)
                object_path.write_bytes(zlib.compress(data))

            ready, trigger = (root / name for name in ("ready", "trigger"))
            for fifo in (ready, trigger):
                os.mkfifo(fifo)
            writer = root / "writer.py"
            writer.write_text(
                f"#!{sys.executable}\n"
                "import pathlib, sys\n"
                "remote = pathlib.Path(sys.argv[1])\n"
                "trigger = pathlib.Path(sys.argv[2])\n"
                "with trigger.open('rb') as wait_handle:\n"
                "    wait_handle.read(1)\n"
                "(remote / 'late-writer').write_text('concurrent child\\n')\n")
            writer.chmod(0o755)
            hook = remote / "hooks" / "pre-auto-gc"
            hook.write_text(
                f"#!{sys.executable}\n"
                "import os\n"
                f"fd = os.open({str(ready)!r}, os.O_WRONLY)\n"
                "os.write(fd, b'hook')\n"
                "os.close(fd)\n")
            hook.chmod(0o755)
            ready_fd = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
            trigger_fd = os.open(trigger, os.O_RDWR | os.O_NONBLOCK)
            child_started = False
            child_released = False
            writer_process = None
            original_scandir = shutil.os.scandir

            def release_child():
                nonlocal child_released
                if child_released:
                    return
                child_released = True
                os.write(trigger_fd, b"x")
                try:
                    writer_process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    writer_process.terminate()
                    try:
                        writer_process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        writer_process.kill()
                        writer_process.wait()
                    raise AssertionError("Git's background hook writer did not terminate")
                finally:
                    if writer_process.poll() is None:
                        writer_process.terminate()
                        try:
                            writer_process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            writer_process.kill()
                            writer_process.wait()

            class CleanupScandir:
                def __init__(self, iterator):
                    self.iterator = iterator
                    self.triggered = False

                def __enter__(self):
                    self.iterator.__enter__()
                    return self

                def __exit__(self, *args):
                    return self.iterator.__exit__(*args)

                def __iter__(self):
                    return self

                def __next__(self):
                    try:
                        return next(self.iterator)
                    except StopIteration:
                        if not self.triggered:
                            self.triggered = True
                            release_child()
                            close_process_owner()
                        raise

            def cleanup_scandir(path):
                iterator = original_scandir(path)
                if isinstance(path, int) and os.fstat(path).st_ino == remote.stat().st_ino:
                    return CleanupScandir(iterator)
                return iterator

            cleanup_error = None

            def controlled_cleanup():
                nonlocal cleanup_error
                if child_started:
                    shutil.os.scandir = cleanup_scandir
                if not child_started:
                    close_process_owner()
                try:
                    original_cleanup()
                except OSError as error:
                    cleanup_error = error
                finally:
                    shutil.os.scandir = original_scandir
                    if child_started and not child_released:
                        _release_child_and_close(release_child, process_owner, (ready_fd, trigger_fd))
                        owner_closed = True
                    else:
                        try:
                            close_process_owner()
                        finally:
                            for fd in (ready_fd, trigger_fd):
                                os.close(fd)
                if Path(temporary).exists():
                    shutil.rmtree(temporary)

            cleanup_body = controlled_cleanup
            try:
                effective_auto = subprocess.run(["git", "config", "--get", "gc.auto"],
                                                cwd=root, capture_output=True, text=True)
                effective_maintenance = subprocess.run(["git", "config", "--get", "maintenance.auto"],
                                                       cwd=root, capture_output=True, text=True)
                if disable_automatic_maintenance:
                    self.assertEqual(effective_auto.stdout.strip(), "0")
                    self.assertEqual(effective_maintenance.stdout.strip(), "false")
                else:
                    self.assertEqual(effective_auto.returncode, 1)
                    self.assertEqual(effective_maintenance.returncode, 1)
                if not disable_automatic_maintenance:
                    writer_process = subprocess.Popen(
                        [sys.executable, str(writer), str(remote), str(trigger)],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        start_new_session=True)
                    child_started = True
                subprocess.run(["git", "-c", "gc.autoDetach=false", "--git-dir", str(remote),
                                "gc", "--auto"], cwd=root, check=True, capture_output=True)
                if disable_automatic_maintenance:
                    readable, _, _ = select.select([ready_fd], [], [], 0.1)
                    self.assertFalse(readable, "automatic GC unexpectedly ran its writer hook")
                else:
                    readable, _, _ = select.select([ready_fd], [], [], 10)
                    self.assertTrue(readable, "eligible Git auto-GC did not run its hook")
                    self.assertEqual(os.read(ready_fd, 4), b"hook")
            except OSError as error:
                cleanup_error = error
        return cleanup_error

    def test_auto_gc_writer_racing_temporary_directory_cleanup_is_prevented(self):
        control_error = self._auto_gc_cleanup(disable_automatic_maintenance=False)
        self.assertIsNotNone(control_error)
        self.assertEqual(control_error.errno, errno.ENOTEMPTY)
        self.assertEqual(Path(control_error.filename).name, "remote.git")
        self.assertIsNone(self._auto_gc_cleanup(disable_automatic_maintenance=True))


def _build_land_template(root: Path) -> str:
    """The history every LandFixture copies: a remote with the base branch, and a clone holding the claim.

    Returns the claim's SHA, which the copies keep.
    """
    remote = root / "remote.git"
    git(root, "init", "-q", "--bare", "-b", BASE, str(remote))
    seed = clone_with_identity(remote, root / "seed")
    LandFixture.write(seed, "README.md", "one\n")
    LandFixture.write(seed, "app/a.txt", "one\n")
    git(seed, "add", "-A")
    git(seed, "commit", "-q", "-m", "base")
    git(seed, "push", "-q", REMOTE, f"HEAD:{BASE}")
    repo = clone_with_identity(remote, root / "repo")
    claim_sha = claims.create_claim(repo, REMOTE, BASE, BRANCH, NUMBER, SESSION).sha
    git(repo, "fetch", "-q", REMOTE)
    git(repo, "checkout", "-q", "-b", BRANCH, "--track", f"{REMOTE}/{BRANCH}")
    LandFixture.write(repo, "app/a.txt", "two\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "change app/a.txt")
    return claim_sha


_land_template_root: Path
_land_template_claim_sha: str


def setUpModule():
    # Built once per module with git maintenance off; each LandFixture copies it.
    global _land_template_root, _land_template_claim_sha
    template = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(template.cleanup)
    _land_template_root = Path(template.name).resolve()
    with _owned_test_processes():
        _land_template_claim_sha = _build_land_template(_land_template_root)


class LandFixture(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        process_owner = _owned_test_processes()
        process_owner.__enter__()
        self.addCleanup(process_owner.__exit__, None, None, None)
        self.tmp = Path(self._tmp.name).resolve()
        self.remote = self.tmp / "remote.git"
        self.seed = self.tmp / "seed"
        self.repo = self.tmp / "repo"
        copy_template(_land_template_root, self.tmp, [self.seed, self.repo], REMOTE, self.remote)
        self.claim_sha = _land_template_claim_sha

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

        # The acceptance registry's journeys are real commands, so the fixture's
        # are scripts that write the report each test asks for.
        self.acceptance_spec = self.tmp / "acceptance-reports.json"
        self.acceptance_runs = self.tmp / "acceptance-runs.txt"
        journey_script = self.tmp / "journey"
        journey_script.write_text(FAKE_JOURNEY.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        journey_script.chmod(0o755)
        self.config["acceptance"] = {
            "evidenceEnv": "FAKE_ACCEPTANCE_EVIDENCE",
            "journeys": {name: {"journey": name, "command": f"exec {journey_script} {{journey}}",
                                "report": REPORT_PATH, "timeoutSeconds": 60}
                         for name in (PAIR, WRONG_CODE)},
        }
        self.spec({PAIR: {}, WRONG_CODE: {}})

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
        env = {"WORK_GH": str(fake), "FAKE_GH_STATE": str(self.state_path), "FAKE_GH_LOG": str(self.gh_log),
               "FAKE_ACCEPTANCE_SPEC": str(self.acceptance_spec),
               "FAKE_ACCEPTANCE_RUNS": str(self.acceptance_runs)}
        saved = {key: os.environ.get(key) for key in env}
        os.environ.update(env)
        self.addCleanup(self._restore, saved)
        self.sleeps = []
        self.now = 0.0

    @staticmethod
    def _restore_git_config(saved: dict) -> None:
        for key in tuple(os.environ):
            if key.startswith("GIT_CONFIG_"):
                os.environ.pop(key)
        os.environ.update(saved)

    @staticmethod
    def _restore(saved: dict) -> None:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _clone(self, name: str) -> Path:
        return clone_with_identity(self.remote, self.tmp / name)

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

    def writes(self, since: int = 0) -> list:
        out = []
        for call in self.calls()[since:]:
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

    # ------------------------------------------------------- acceptance

    def spec(self, reports: dict) -> None:
        """What each fake journey's report says; a journey absent from it passes at HEAD."""
        self.acceptance_spec.write_text(json.dumps(
            {journey: {"revision": "HEAD", "journey": journey, **values}
             for journey, values in reports.items()}))

    def journey_timeout(self, journey: str, seconds: int) -> None:
        self.config["acceptance"]["journeys"][journey]["timeoutSeconds"] = seconds

    def journey_runs(self) -> list:
        """Every step the fake journeys recorded, in order."""
        if not self.acceptance_runs.exists():
            return []
        return self.acceptance_runs.read_text().splitlines()

    def passing_report(self, journey: str, head: str) -> dict:
        """A report land would accept, for a run that did not write it."""
        return {"schema": "tron.ios-e2e-ui-journey.v1", "journey": journey, "journey_status": 0,
                "journey_seconds": 9, "evidence_complete": True,
                "source": {"revision": head, "dirty": False, "source_fingerprint": "ab" * 32},
                "artifacts": []}

    def acceptance_evidence(self, head: str) -> Path:
        """The evidence directory land gives the journeys of one head."""
        return Path(git(self.repo, "rev-parse", "--absolute-git-dir")) / "work" / "acceptance" / head

    def kept_report(self, journey: str, head: str) -> bytes:
        return (self.acceptance_evidence(head) / f"{journey}.report.json").read_bytes()

    def assert_nothing_published(self) -> None:
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.merges(), [])
        self.assertEqual(self.remote_head(), self.claim_sha)
        self.assertEqual(self.issue()["state"], "OPEN")

    # ------------------------------------------------------------------ land

    # Waiting runs on a fake clock that only sleeping advances.
    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def clock(self) -> float:
        return self.now

    def land(self, session: str = SESSION, title=None, summary=True, validation=None, irreducible=None,
             acceptance=None, sleep=None) -> int:
        return land.land(Gh(self.repo), self.repo, self.config, session, title,
                         self.summary if summary else None, validation, irreducible, acceptance,
                         sleep=sleep or self.sleep, clock=self.clock)


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


class TypeSpecificPullBodyTests(LandFixture):
    """The public CLI must reject malformed bug evidence before writing or opening a PR."""

    BUG_SUMMARY = "## Repro\n\nThe regression is reproduced.\n\n## Cause\n\nThe cause is identified.\n\n## Fix\n\nThe fix is described.\n"

    def cli_land(self, summary: str, labels=None, summary_file=True, existing_body=None, merged=False):
        self.set_state(issues={str(NUMBER): {**self.issue(), "labels": labels or ["task"]}})
        config_path = self.repo / ".github" / "work.json"
        if not config_path.exists():
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config = json.loads(json.dumps(self.config))
            config["verify"]["checks"][0]["paths"].append(".github/**")
            config_path.write_text(json.dumps(config))
            git(self.repo, "add", ".github/work.json")
            git(self.repo, "commit", "-q", "-m", "fixture work configuration")
        if existing_body is not None:
            pull = {"number": 100, "headRefName": BRANCH, "title": "feat: Add the widget",
                    "base": BASE, "body": existing_body, "state": "MERGED" if merged else "OPEN",
                    "headRefOid": git(self.repo, "rev-parse", "HEAD"),
                    "mergeCommit": {"oid": git(self.repo, "rev-parse", "HEAD")} if merged else None}
            self.set_state(pulls=[pull])
        path = self.tmp / "cli-summary.md"
        path.write_text(summary)
        command = [sys.executable, str(Path(__file__).with_name("cli.py")), "land", "--session", SESSION]
        if summary_file:
            command += ["--summary-file", str(path)]
        result = subprocess.run(command, cwd=self.repo, env=os.environ.copy(), capture_output=True, text=True)
        return result

    def assert_rejected_without_publication(self, summary: str):
        before = len(self.calls())
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Repro", result.stderr)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def assert_existing_body_rejected_without_publication(self, summary: str, merged=False):
        body = chr(10).join(("Closes #7", "", "## Summary", "", summary,
                             "## Verification", "", "Generated.", ""))
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=body, merged=merged)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_missing_bug_sections_are_refused_before_any_publication(self):
        self.assert_rejected_without_publication("## Repro\n\nShown.\n\n## Cause\n\nKnown.\n")

    def test_empty_bug_section_is_refused_before_any_publication(self):
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\n   ")
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\n<!-- pending -->\n")

    def test_heading_depth_and_fenced_heading_text_do_not_count(self):
        self.assert_rejected_without_publication(
            "### Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(
            "```md\n## Repro\n```\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_reordered_bug_sections_are_refused(self):
        self.assert_rejected_without_publication(
            "## Cause\n\nKnown.\n\n## Repro\n\nShown.\n\n## Fix\n\nDone.\n")

    def test_verification_heading_cannot_be_confused_with_summary_content(self):
        self.assert_rejected_without_publication(
            self.BUG_SUMMARY + "\n## Verification\n\nThis would shadow generated evidence.\n")

    def test_sibling_heading_ends_a_required_section(self):
        self.assert_rejected_without_publication(
            "## Repro\n\n## Notes\n\nNotes are not reproduction evidence.\n\n"
            "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_empty_fenced_block_is_not_meaningful_content(self):
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n## Cause\n\n```text\n```\n\n## Fix\n\nDone.\n")

    def test_html_comments_cannot_supply_required_sections(self):
        self.assert_rejected_without_publication(
            "<!--\n## Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n-->\n")

    def test_commented_duplicate_heading_does_not_satisfy_or_duplicate_a_section(self):
        summary = ("## Repro\n\nThe behavior reproduces.\n<!-- ## Repro -->\n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_unclosed_fence_and_duplicate_summary_wrapper_are_refused(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n```md\nexample\n")
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n## Summary\n\nconflicting wrapper\n")

    def test_unclosed_html_comment_is_refused_before_generated_verification(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n<!-- unclosed comment")

    def test_fence_trailer_text_is_not_a_closing_delimiter(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n```md\n```not-a-closing-fence\n")

    def test_nonbreaking_space_is_not_a_fence_closer(self):
        summary = ("## Repro\n\n```text\nfailure\n```\u00a0\n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(summary)

    def test_ascii_space_fence_trailer_is_valid(self):
        summary = ("## Repro\n\n```text\nfailure\n``` \n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_ascii_tab_fence_trailer_is_valid(self):
        summary = ("## Repro\n\n```text\nfailure\n```" + "\t" + "\n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_unicode_line_separators_cannot_create_required_sections(self):
        summary = ("## Repro\u2028\u2028Failure.\u2028\u2028## Cause\u2028\u2028Known.\u2028\u2028"
                   "## Fix\u2028\u2028Done.\n")
        self.assert_rejected_without_publication(summary)

    def test_unicode_line_separators_are_rejected_when_adopting_open_pr(self):
        summary = ("## Repro\u2028\u2028Failure.\u2028\u2028## Cause\u2028\u2028Known.\u2028\u2028"
                   "## Fix\u2028\u2028Done.\n")
        self.assert_existing_body_rejected_without_publication(summary)

    def test_unicode_line_separators_are_rejected_on_merged_resume(self):
        summary = ("## Repro\u2028\u2028Failure.\u2028\u2028## Cause\u2028\u2028Known.\u2028\u2028"
                   "## Fix\u2028\u2028Done.\n")
        self.assert_existing_body_rejected_without_publication(summary, merged=True)

    def test_adjacent_hashes_are_not_atx_closing_sequences(self):
        summary = "## Repro###\n\nFailure.\n\n## Cause###\n\nKnown.\n\n## Fix###\n\nDone.\n"
        self.assert_rejected_without_publication(summary)

    def test_adjacent_hashes_are_rejected_when_adopting_open_pr(self):
        summary = "## Repro###\n\nFailure.\n\n## Cause###\n\nKnown.\n\n## Fix###\n\nDone.\n"
        self.assert_existing_body_rejected_without_publication(summary)

    def test_adjacent_hashes_are_rejected_on_merged_resume(self):
        summary = "## Repro###\n\nFailure.\n\n## Cause###\n\nKnown.\n\n## Fix###\n\nDone.\n"
        self.assert_existing_body_rejected_without_publication(summary, merged=True)

    def test_atx_closing_hashes_with_preceding_space_remain_valid(self):
        summary = ("## Repro ###\n\nFailure.\n\n## Cause ##\n\nKnown.\n\n"
                   "## Fix #\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_unclosed_preformatted_block_is_refused_before_generated_verification(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n<pre>\n")

    def test_closed_preformatted_block_allows_generated_verification(self):
        result = self.cli_land(self.BUG_SUMMARY + "\n<pre>\nLiteral evidence.\n</pre>\n",
                               labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_unclosed_preformatted_block_is_refused_in_adopted_body(self):
        body = ("Closes #7\n\n## Summary\n\n" + self.BUG_SUMMARY +
                "\n## Verification\n\nGenerated.\n\n<pre>\n")
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=body)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_preformatted_html_headings_cannot_supply_required_sections(self):
        summary = ("## Repro\n\nFailure.\n\n<pre>\n## Cause\n\nKnown.\n\n"
                   "## Fix\n\nDone.\n</pre>\n")
        self.assert_rejected_without_publication(summary)

    def test_preformatted_html_headings_are_rejected_when_adopting_open_pr(self):
        summary = ("## Repro\n\nFailure.\n\n<pre>\n## Cause\n\nKnown.\n\n"
                   "## Fix\n\nDone.\n</pre>\n")
        self.assert_existing_body_rejected_without_publication(summary)

    def test_preformatted_html_headings_are_rejected_on_merged_resume(self):
        summary = ("## Repro\n\nFailure.\n\n<pre>\n## Cause\n\nKnown.\n\n"
                   "## Fix\n\nDone.\n</pre>\n")
        self.assert_existing_body_rejected_without_publication(summary, merged=True)

    def test_four_space_and_tab_fence_markers_are_code_not_closers(self):
        self.assert_rejected_without_publication(
            "## Repro\n\n```text\nfailure\n    ```\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(
            "## Repro\n\n```text\nfailure\n\t```\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_four_space_or_tab_indented_headings_do_not_count(self):
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n    ## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n\t## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_one_to_three_space_headings_and_fences_are_valid(self):
        summary = (" ## Repro\n\n ```text\nfailure output\n ```\n\n"
                   "  ## Cause\n\n  ```text\nThe parser boundary was wrong.\n  ```\n\n"
                   "   ## Fix\n\n   ```text\nThe boundary was corrected.\n   ```\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_heading_shaped_code_output_counts_as_meaningful_evidence(self):
        summary = ("## Repro\n\n```text\n# Actual failing output\n```\n\n"
                   "## Cause\n\nThe cause is known.\n\n## Fix\n\nThe fix is applied.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_balanced_html_comment_keeps_generated_verification_visible(self):
        summary = ("<!-- evidence context\nnot a heading: ## Verification\n-->\n"
                   + self.BUG_SUMMARY)
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_nonempty_fenced_evidence_and_harmless_comments_are_valid(self):
        summary = ("<!-- issue evidence -->\n## Repro\n\n```text\nexpected failure\n```\n\n"
                   "## Cause\n\nThe parser lost the boundary.\n\n<!-- note -->\n## Fix\n\nRestore it.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_valid_bug_summary_lands_through_cli_with_generated_verification(self):
        result = self.cli_land(self.BUG_SUMMARY, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        body = self.state()["pulls"][0]["body"]
        for heading in ("## Repro", "## Cause", "## Fix", "## Verification"):
            self.assertIn(heading, body)

    def test_nonbug_summary_remains_unchanged_through_cli(self):
        result = self.cli_land("Adds the widget.\n", labels=["task", "kind:feature"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Adds the widget.", self.state()["pulls"][0]["body"])

    def test_adopting_valid_bug_pr_ignores_verification_example_in_fenced_code(self):
        summary = (" ## Repro\n\n   ```text\nfailure\n   ```\n\n  ## Cause\n\nKnown.\n\n"
                   "   ## Fix\n\nDone.\n\n   ```md\n## Verification\n   ```\n")
        body = ("Closes #7\n\n## Summary\n\n" + summary
                + "\n## Verification\n\nGenerated.\n")
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False, existing_body=body)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("   ```md\n## Verification\n   ```", self.state()["pulls"][0]["body"])

    def test_adopting_open_bug_pr_with_confusing_verification_heading_is_refused(self):
        malformed_body = ("Closes #7\n\n## Summary\n\n" + self.BUG_SUMMARY
                          + "\n## Verification\n\nExisting check text.\n\n## Verification\n\nGenerated.\n")
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=malformed_body)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_merged_bug_resume_validates_the_merged_body(self):
        malformed_body = "Closes #7\n\n## Summary\n\n## Repro\n\nShown.\n\n## Verification\n\nGenerated.\n"
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=malformed_body, merged=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])

    def test_merged_bug_resume_preserves_fenced_headings_and_maintainer_handoff(self):
        summary = (" ## Repro\n\n   ```text\n# Output\n   ```\n\n  ## Cause\n\nKnown.\n\n"
                   "   ## Fix\n\nDone.\n\n   ```md\n\n## Verification\n\n## Maintainer validation\n\n"
                   "Not the handoff.\n   ```\n")
        body = ("Refs #7\n\n## Summary\n\n" + summary + "\n## Verification\n\nGenerated receipt.\n"
                "\n## Maintainer validation\n\nIrreducible: physical device\n\nRun the stated check.\n")
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=body, merged=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.issue()["state"], "OPEN")
        self.assertEqual(self.issue()["status"], "Needs you")
        self.assertIn("Run the stated check.", self.issue()["comments"][-1])
        self.assertNotIn("Not the handoff.", self.issue()["comments"][-1])


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

    def test_scope_skipped_required_check_is_satisfied(self):
        # CI skips a required job whose inputs the change does not touch.
        self.set_state(checks={"policy": "SKIPPED"})
        self.land()
        self.assertEqual(len(self.merges()), 1)

    def test_cancelled_required_check_stops_without_merging(self):
        self.set_state(checks={"policy": "CANCELLED"})
        with self.assertRaises(land.LandError) as raised:
            self.land()
        self.assertIn("policy: cancelled", str(raised.exception))
        self.assertEqual(self.merges(), [])

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

    # Failure mode 80.
    def test_conflicting_pull_request_stops_at_the_first_poll_without_merging(self):
        # Hosted CI never runs on a conflicting pull request, so its checks stay pending forever.
        self.set_state(mergeable="CONFLICTING", pendingViews=10 ** 6)
        with self.assertRaises(land.LandError) as raised:
            self.land()
        self.assertIn("conflicts", str(raised.exception))
        self.assertIn(f"merge {REMOTE}/{BASE} into the branch", str(raised.exception))
        self.assertEqual(self.sleeps, [])
        self.assertEqual(self.merges(), [])
        self.assertEqual(self.issue()["state"], "OPEN")

    def test_unknown_mergeability_keeps_waiting_then_merges(self):
        # GitHub reports UNKNOWN while it computes mergeability; that is not a conflict.
        self.set_state(mergeable="UNKNOWN", pendingViews=3)
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
                handoff = field == "validation"
                with self.assertRaises(land.LandError) as raised:
                    self.land(title="FORBIDDEN title" if field == "title" else None,
                              validation="FORBIDDEN action" if handoff else None,
                              irreducible="a physical device" if handoff else None)
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
        self.land(validation="Restart the dev Gateway, then check its status.",
                  irreducible="a physical device")
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


class StaleRunTests(LandFixture):
    # Failure mode 66.
    def workflow_run(self, run_id: int, sha: str, event: str = "pull_request", status: str = "queued",
                     branch: str = "") -> dict:
        return {"id": run_id, "head_sha": sha, "event": event, "status": status,
                "head_branch": branch or git(self.repo, "branch", "--show-current")}

    def cancelled(self) -> list:
        return self.state().get("cancelled", [])

    def land_output(self) -> str:
        text = io.StringIO()
        with contextlib.redirect_stdout(text):
            self.assertEqual(self.land(), 0)
        return text.getvalue()

    def assert_finished(self) -> None:
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))
        self.assertEqual(self.remote_head(), "")

    def test_only_the_merged_heads_pull_request_runs_are_cancelled(self):
        head = git(self.repo, "rev-parse", "HEAD")
        self.set_state(runs=[
            self.workflow_run(1, head),
            self.workflow_run(2, head, status="in_progress"),
            self.workflow_run(3, head, status="completed"),
            self.workflow_run(4, head, event="push"),
            self.workflow_run(5, "a" * 40),
            self.workflow_run(6, head, branch="feat/other-pull-at-the-same-commit"),
        ])
        text = self.land_output()
        self.assertEqual(self.cancelled(), [f"repos/{REPO}/actions/runs/1/cancel",
                                            f"repos/{REPO}/actions/runs/2/cancel"])
        self.assertIn(f"ci:       run 1 for {head[:12]} cancelled", text)
        self.assertIn(f"ci:       run 2 for {head[:12]} cancelled", text)
        for untouched in ("run 3", "run 4", "run 5", "run 6"):
            self.assertNotIn(untouched, text)
        self.assert_finished()

    def test_a_refused_cancellation_warns_but_land_still_succeeds(self):
        head = git(self.repo, "rev-parse", "HEAD")
        self.set_state(runs=[self.workflow_run(1, head)], failCancel=True)
        text = self.land_output()
        self.assertIn(f"warning:  CI run 1 for {head[:12]} was not cancelled", text)
        self.assertEqual(self.cancelled(), [])
        self.assert_finished()

    def test_a_refused_run_list_warns_but_land_still_succeeds(self):
        self.set_state(runs=[], failRuns=True)
        text = self.land_output()
        self.assertIn("warning:  CI runs for", text)
        self.assertEqual(self.cancelled(), [])
        self.assert_finished()


class HandoffTests(LandFixture):
    # Failure modes 40 and 73.
    IRREDUCIBLE = "the user's real X consent page"

    def test_action_text_label_and_status_reach_the_issue(self):
        action = "Run `scripts/example restart`, then check:\n\n- status names this branch"
        self.land(validation=action, irreducible=self.IRREDUCIBLE)
        issue = self.issue()
        self.assertIn(action, issue["comments"][-1])
        self.assertIn(f"Irreducible: {self.IRREDUCIBLE}", issue["comments"][-1])
        self.assertIn("needs-user-validation", issue["labels"])
        self.assertEqual((issue["state"], issue["status"]), ("OPEN", "Needs you"))
        pull = self.state()["pulls"][0]
        self.assertTrue(pull["body"].startswith("Refs #7\n"))
        self.assertIn(action, pull["body"])
        self.assertIn(f"Irreducible: {self.IRREDUCIBLE}", pull["body"])

    def test_a_handoff_that_names_no_irreducible_part_is_refused(self):
        cases = {"validation without its irreducible part": (dict(validation="Restart the Gateway."),
                                                              "--irreducible"),
                 "an irreducible part without validation": (dict(irreducible="a physical device"),
                                                            "--needs-user-validation"),
                 "a blank irreducible part": (dict(validation="Restart the Gateway.", irreducible="  "),
                                               "--irreducible"),
                 "a blank validation text": (dict(validation="\t\n", irreducible="a physical device"),
                                             "--needs-user-validation")}
        for name, (kwargs, named) in cases.items():
            with self.subTest(case=name):
                with self.assertRaises(land.LandError) as raised:
                    self.land(**kwargs)
                self.assertIn(named, str(raised.exception))
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_a_blank_handoff_is_no_handoff_at_all(self):
        # Both values blank means neither flag named anything, so land lands as
        # it does without them.
        self.assertEqual(self.land(validation="   ", irreducible="\t"), 0)
        pull = self.state()["pulls"][0]
        self.assertTrue(pull["body"].startswith("Closes #7\n"))
        self.assertNotIn("Maintainer validation", pull["body"])
        self.assertEqual(self.issue()["state"], "CLOSED")

    def test_a_failure_after_the_merge_keeps_the_action_text(self):
        action = "Run `scripts/example restart`, then check that status names this branch."
        self.set_state(failIssue=["comment"])
        with self.assertRaises(land.LandError) as raised:
            self.land(validation=action, irreducible=self.IRREDUCIBLE)
        pull = self.state()["pulls"][0]
        self.assertEqual(pull["state"], "MERGED")
        # The pull request body was on GitHub before the merge.
        self.assertIn(action, pull["body"])
        self.assertIn(action, str(raised.exception))
        self.assertIn("#100", str(raised.exception))
        self.assertFalse(any(action in comment for comment in self.issue()["comments"]))


class AcceptanceLandingTests(LandFixture):
    # Failure modes 71 and 72.
    def test_a_passing_journey_reaches_the_pull_request_as_its_report_digest(self):
        self.assertEqual(self.land(acceptance=PAIR), 0)
        head = git(self.repo, "rev-parse", "HEAD")
        digest = hashlib.sha256(self.kept_report(PAIR, head)).hexdigest()
        body = self.state()["pulls"][0]["body"]
        self.assertIn("### Acceptance journeys", body)
        self.assertIn(f"report sha256 `{digest}`", body)
        self.assertIn(PAIR, body)
        self.assertIn(f"source `{head}`", body)
        self.assertNotIn(str(self.tmp), body)
        # The registered journey is what the command received and what the report names.
        self.assertEqual(self.journey_runs(), [f"{PAIR} started", f"{PAIR} report {head}"])
        self.assertEqual(len(self.merges()), 1)
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))

    def test_each_journey_is_checked_against_the_report_its_own_run_left(self):
        # Both runs share the head's evidence directory, so the second one
        # replaces the report path the first one left behind.
        self.spec({PAIR: {}, WRONG_CODE: {"revision": self.claim_sha}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=f"{PAIR},{WRONG_CODE}")
        self.assertIn(WRONG_CODE, str(raised.exception))
        self.assert_nothing_published()

    def test_a_report_from_another_head_is_refused(self):
        self.spec({PAIR: {"revision": self.claim_sha}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn(self.claim_sha[:12], str(raised.exception))
        self.assertIn(git(self.repo, "rev-parse", "HEAD")[:12], str(raised.exception))
        self.assert_nothing_published()

    def test_a_report_that_is_not_from_a_completed_clean_run_is_refused(self):
        cases = {"a dirty run": ({"dirty": True}, "ran from a dirty worktree"),
                 "incomplete evidence": ({"evidence_complete": False}, "did not leave complete evidence"),
                 "a failed journey": ({"status": 1}, "reported status 1"),
                 "an unreadable report": ({"raw": "not json"}, "unreadable report"),
                 "no source fingerprint": ({"fingerprint": ""}, "names no source fingerprint"),
                 "a report for another journey": ({"journey": "TronMobileUITests/Other/x"},
                                                  "not the registered journey")}
        for name, (spec, message) in cases.items():
            with self.subTest(case=name):
                self.spec({PAIR: spec})
                with self.assertRaises(acceptance.AcceptanceError) as raised:
                    self.land(acceptance=PAIR)
                self.assertIn(message, str(raised.exception))
        self.assert_nothing_published()

    def test_a_journey_that_writes_no_report_is_refused(self):
        # A fresh evidence directory: no earlier run's report is there to be
        # taken for this run's.
        self.spec({PAIR: {"report": False}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("left no report", str(raised.exception))
        self.assert_nothing_published()

    def test_a_report_an_earlier_run_left_is_refused(self):
        # The declared path resolves to a file this run did not write. The
        # planted report is one land would otherwise accept, so only the run's
        # own write can qualify it.
        head = git(self.repo, "rev-parse", "HEAD")
        stale = self.acceptance_evidence(head) / REPORT_PATH
        stale.parent.mkdir(parents=True)
        stale.write_text(json.dumps(self.passing_report(PAIR, head)))
        self.spec({PAIR: {"report": False}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("left no new report", str(raised.exception))
        self.assert_nothing_published()

    def test_a_journey_command_that_fails_is_refused(self):
        self.spec({PAIR: {"exit": 3}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("failed (exit 3)", str(raised.exception))
        self.assert_nothing_published()

    def _journey_wait_seam(self, ready, *, force_not_ready=False, handler_installed=None):
        popen = acceptance.subprocess.Popen
        self.controlled_journeys = []

        def spawn(*args, **kwargs):
            process = popen(*args, **kwargs)
            wait = process.wait

            def wait_for_bound(timeout=None):
                if timeout != 1:
                    return wait(timeout=timeout)
                self.controlled_journeys.append(process)
                if force_not_ready:
                    if handler_installed is not None:
                        handler_installed.wait(timeout=5)
                    readiness_failed = True
                else:
                    readiness_failed = not ready.wait(timeout=5)
                if readiness_failed:
                    try:
                        process.send_signal(signal.SIGINT)
                    except ProcessLookupError:
                        pass
                    try:
                        wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        wait()
                    raise AssertionError("journey did not become ready before the test bound")
                raise subprocess.TimeoutExpired(process.args, timeout)

            process.wait = wait_for_bound
            return process

        return popen, spawn

    def test_a_journey_that_passes_its_bound_is_interrupted_and_winds_down_itself(self):
        self.journey_timeout(PAIR, 1)
        self.spec({PAIR: {"sleep": 60, "trap_sigint": True, "ready_signal": True, "report": False}})
        ready = threading.Event()
        previous_handler = signal.getsignal(signal.SIGUSR1)
        signal.signal(signal.SIGUSR1, lambda *_: ready.set())
        popen, wait_seam = self._journey_wait_seam(ready)
        try:
            acceptance.subprocess.Popen = wait_seam
            with self.assertRaises(acceptance.AcceptanceError) as raised:
                self.land(acceptance=PAIR)
        finally:
            acceptance.subprocess.Popen = popen
            signal.signal(signal.SIGUSR1, previous_handler)
        message = str(raised.exception)
        self.assertIn("passed its 1s bound", message)
        self.assertIn("interrupted (exit 130)", message)
        # SIGINT reached the journey and its own wind-down ran; land never killed it.
        self.assertIn(f"{PAIR} cleanup", self.journey_runs())
        self.assertNotIn(f"{PAIR} wound down", self.journey_runs())
        [journey_process] = self.controlled_journeys
        self.assertEqual(journey_process.returncode, 130)
        self.assert_nothing_published()

    def test_a_journey_readiness_failure_stops_and_joins_the_exact_child(self):
        self.journey_timeout(PAIR, 1)
        self.spec({PAIR: {"sleep": 60, "trap_sigint": True, "handler_signal": True,
                          "delay_ready": True, "ready_signal": True, "report": False}})
        ready = threading.Event()
        handler_installed = threading.Event()
        previous_ready_handler = signal.getsignal(signal.SIGUSR1)
        previous_installed_handler = signal.getsignal(signal.SIGUSR2)
        signal.signal(signal.SIGUSR1, lambda *_: ready.set())
        signal.signal(signal.SIGUSR2, lambda *_: handler_installed.set())
        popen, wait_seam = self._journey_wait_seam(ready, force_not_ready=True,
                                                   handler_installed=handler_installed)
        try:
            acceptance.subprocess.Popen = wait_seam
            with self.assertRaisesRegex(AssertionError, "did not become ready"):
                self.land(acceptance=PAIR)
        finally:
            acceptance.subprocess.Popen = popen
            signal.signal(signal.SIGUSR1, previous_ready_handler)
            signal.signal(signal.SIGUSR2, previous_installed_handler)
        [journey_process] = self.controlled_journeys
        self.assertIsNotNone(journey_process.returncode)
        self.assertFalse(ready.is_set(), "a late readiness signal survived child cleanup")
        if handler_installed.is_set():
            self.assertEqual(journey_process.returncode, 130)
            self.assertIn(f"{PAIR} cleanup", self.journey_runs())
        else:
            self.assertEqual(journey_process.returncode, -signal.SIGINT)
        self.assert_nothing_published()

    def test_an_interrupted_land_waits_for_the_journey_to_wind_down(self):
        # The journey signals land's process the way a terminal interrupt does and
        # then winds down on its own. land must wait for that wind-down and
        # re-raise; the interrupt path of subprocess.run would kill it instead.
        # A backgrounded verify inherits SIGINT ignored (POSIX gives an
        # asynchronous job in a non-interactive shell SIG_IGN), so this test
        # listens for the interrupt it delivers either way: its subject is
        # land's own handler path, not the shell's disposition.
        inherited = signal.getsignal(signal.SIGINT)
        if inherited is signal.SIG_IGN:
            signal.signal(signal.SIGINT, signal.default_int_handler)
        self.addCleanup(signal.signal, signal.SIGINT, inherited)
        self.spec({PAIR: {"signal_parent": True, "report": False}})
        with self.assertRaises(KeyboardInterrupt):
            self.land(acceptance=PAIR)
        self.assertIn(f"{PAIR} wound down", self.journey_runs())
        self.assert_nothing_published()

    def test_the_journeys_run_against_the_head_that_is_pushed_after_a_base_move(self):
        before = git(self.repo, "rev-parse", "HEAD")
        moved = self.base_commit("lib/new.txt", "from base\n")
        self.set_state(pendingViews=1, baseMoves={"1": moved})
        self.assertEqual(self.land(acceptance=PAIR), 0)
        head = git(self.repo, "rev-parse", "HEAD")
        self.assertNotEqual(head, before)
        # Round 1 proved the head it ran against; round 2 proved the head that
        # was verified, pushed and cited, which is where its evidence lives.
        self.assertIn(f"{PAIR} report {before}", self.journey_runs())
        self.assertIn(f"{PAIR} report {head}", self.journey_runs())
        body = self.state()["pulls"][0]["body"]
        digest = hashlib.sha256(self.kept_report(PAIR, head)).hexdigest()
        self.assertIn(f"source `{head}`", body)
        self.assertIn(f"report sha256 `{digest}`", body)
        [merge] = self.merges()
        self.assertEqual(merge[merge.index("--match-head-commit") + 1], head)

    def test_a_report_the_scrub_refuses_stops_before_any_github_write(self):
        self.spec({PAIR: {"fingerprint": "FORBIDDEN fingerprint"}})
        with self.assertRaises(land.LandError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("acceptance evidence", str(raised.exception))
        self.assert_nothing_published()

    def test_an_unknown_journey_id_is_refused_with_the_registered_ids(self):
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=f"{PAIR},typo")
        message = str(raised.exception)
        self.assertIn("typo", message)
        self.assertIn(WRONG_CODE, message)
        self.assert_nothing_published()
        self.assertFalse(self.acceptance_evidence(git(self.repo, "rev-parse", "HEAD")).exists())

    def test_an_empty_journey_id_is_refused(self):
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=f"{PAIR},")
        self.assertIn("comma-separated", str(raised.exception))
        self.assert_nothing_published()

    def test_a_repository_without_a_usable_registry_refuses(self):
        journeys = self.config["acceptance"]["journeys"]
        cases = {"no acceptance section": (None, "registers no acceptance journeys"),
                 "no journeys": ({"evidenceEnv": "FAKE_ACCEPTANCE_EVIDENCE", "journeys": {}},
                                 "registers no acceptance journeys"),
                 "no evidence variable": ({"journeys": journeys}, "evidenceEnv")}
        for name, (section, named) in cases.items():
            with self.subTest(case=name):
                if section is None:
                    self.config.pop("acceptance", None)
                else:
                    self.config["acceptance"] = section
                with self.assertRaises(acceptance.AcceptanceError) as raised:
                    self.land(acceptance=PAIR)
                self.assertIn(named, str(raised.exception))
        self.assert_nothing_published()


class ResumeTests(LandFixture):
    # Failure mode 65.
    ACTION = "Run `scripts/example restart`, then check that status names this branch."
    IRREDUCIBLE = "the maintainer's own route to the Gateway"

    def stopped_after_merge(self, failing: list, validation=None) -> None:
        """Land until GitHub reports MERGED, then stop as an outage would."""
        self.set_state(failIssue=failing)
        with self.assertRaises(land.LandError):
            self.land(validation=validation, irreducible=self.IRREDUCIBLE if validation else None)
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.set_state(failIssue=[])
        self.before = len(self.calls())
        self.runs = self.counts.read_text().count("run")

    def assert_nothing_redone(self) -> None:
        later = self.writes(since=self.before)
        for redone in ("pr create", "pr edit", "pr merge"):
            self.assertNotIn(redone, later)
        self.assertFalse([write for write in later if "/statuses/" in write or "/comments" in write], later)
        self.assertEqual(self.counts.read_text().count("run"), self.runs, "no check ran again")

    def test_rerun_closes_the_issue_even_when_github_deleted_the_branch(self):
        self.set_state(deleteOnMerge=True)
        self.stopped_after_merge(["close"])
        self.assertEqual(self.issue()["state"], "OPEN")
        self.assertEqual(self.land(summary=False), 0)
        merge = self.state()["pulls"][0]["mergeCommit"]["oid"]
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))
        self.assertIn(merge[:12], self.issue()["comments"][-1])
        self.assertEqual(self.remote_head(), "")
        self.assert_nothing_redone()

    def test_rerun_deletes_the_branch_at_the_merged_head(self):
        self.stopped_after_merge(["close"])
        self.assertEqual(self.remote_head(), git(self.repo, "rev-parse", "HEAD"))
        self.assertEqual(self.land(), 0)
        self.assertEqual(self.remote_head(), "")
        self.assert_nothing_redone()

    def test_rerun_hands_off_once_with_the_merged_text(self):
        # The handoff comment was posted; adding the label failed.
        self.stopped_after_merge(["edit"], validation=self.ACTION)
        self.assertEqual(self.land(summary=False), 0)
        issue = self.issue()
        self.assertEqual(sum(self.ACTION in comment for comment in issue["comments"]), 1)
        self.assertIn("needs-user-validation", issue["labels"])
        self.assertEqual((issue["state"], issue["status"]), ("OPEN", "Needs you"))
        self.assert_nothing_redone()

    def test_rerun_with_the_same_text_finishes_the_handoff(self):
        self.stopped_after_merge(["comment"], validation=self.ACTION)
        self.assertEqual(self.land(validation=self.ACTION, irreducible=self.IRREDUCIBLE), 0)
        self.assertEqual(sum(self.ACTION in comment for comment in self.issue()["comments"]), 1)
        self.assertEqual(self.issue()["status"], "Needs you")
        self.assert_nothing_redone()

    def test_rerun_after_a_finished_handoff_keeps_the_maintainers_close(self):
        self.assertEqual(self.land(validation=self.ACTION, irreducible=self.IRREDUCIBLE), 0)
        self.set_state(issues={str(NUMBER): dict(self.issue(), state="CLOSED", status="Done")})
        before = len(self.calls())
        self.assertEqual(self.land(summary=False), 0)
        self.assertEqual(self.writes(since=before), [])
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))

    def test_rerun_after_a_finished_land_keeps_the_maintainers_reopen(self):
        self.assertEqual(self.land(), 0)
        self.set_state(issues={str(NUMBER): dict(self.issue(), state="OPEN", status="Ready")})
        before = len(self.calls())
        self.assertEqual(self.land(summary=False), 0)
        self.assertEqual(self.writes(since=before), [])
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("OPEN", "Ready"))

    def test_rerun_refusals(self):
        self.stopped_after_merge(["close"])
        cases = {
            "another session": dict(session="session-b"),
            "validation the merge did not ask for": dict(validation=self.ACTION, irreducible=self.IRREDUCIBLE),
        }
        for name, kwargs in cases.items():
            with self.subTest(case=name):
                with self.assertRaises(land.LandError):
                    self.land(**kwargs)
        self.assertEqual(self.writes(since=self.before), [])
        self.assertEqual(self.issue()["state"], "OPEN")
        self.assertEqual(self.remote_head(), git(self.repo, "rev-parse", "HEAD"))

    def test_a_contradicting_validation_text_is_refused(self):
        self.stopped_after_merge(["comment"], validation=self.ACTION)
        with self.assertRaises(land.LandError):
            self.land(validation="Something else entirely.", irreducible=self.IRREDUCIBLE)
        self.assertFalse(any(self.ACTION in comment for comment in self.issue()["comments"]))

    def test_a_merge_at_an_older_head_or_from_a_fork_is_not_resumed(self):
        head = git(self.repo, "rev-parse", "HEAD")
        fork = {"number": 90, "headRefName": BRANCH, "title": "fork", "body": "Closes #7\n", "state": "MERGED",
                "fork": True, "headRefOid": head, "mergeCommit": {"oid": head}}
        older = dict(fork, number=91, fork=False, headRefOid=self.claim_sha)
        self.set_state(pulls=[fork, older])
        self.assertEqual(self.land(), 0)
        self.assertIn("pr create", self.writes())
        [merge] = self.merges()
        self.assertEqual(merge[2], "102")


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


class StewardHandoffTests(StewardFixture):
    # Failure mode 64.
    ACTION = "Restart the dev Gateway, then check that status names this branch."

    def body(self, keyword: str, action) -> str:
        receipt = {"head": self.head, "base": {"ref": BASE, "sha": self.head}, "required": ["policy"],
                   "checks": {"policy": {"exitCode": 0, "seconds": 1, "carriedFrom": None}}}
        # A summary heading with the section's name is not the validation text.
        summary = "Adds the widget.\n\n## Maintainer validation\n\nNot this."
        return land.pull_body(keyword, NUMBER, summary, receipt, action)

    def with_body(self, body: str) -> None:
        pulls = self.state()["pulls"]
        pulls[0]["body"] = body
        self.set_state(pulls=pulls)

    def test_validation_handoff_is_landed_with_its_exact_text(self):
        self.with_body(self.body("Refs", self.ACTION).replace("\n", "\r\n"))
        self.assertEqual(self.steward_land(), 0)
        pull = self.state()["pulls"][0]
        self.assertEqual(pull["squash"][1], "Refs #7")
        issue = self.issue()
        self.assertIn(self.ACTION, issue["comments"][-1])
        self.assertNotIn("Not this.", issue["comments"][-1])
        self.assertIn("needs-user-validation", issue["labels"])
        self.assertEqual((issue["state"], issue["status"]), ("OPEN", "Needs you"))
        self.assertEqual(self.remote_head(), "")

    def test_handoff_without_usable_text_is_refused_before_the_merge(self):
        cases = {
            "no section": "Refs #7\n",
            "empty section": self.body("Refs", ""),
            "closes and asks for validation": self.body("Closes", self.ACTION),
            "text the scrub refuses": self.body("Refs", "FORBIDDEN action"),
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                self.with_body(body)
                with self.assertRaises(land.LandError):
                    self.steward_land()
        self.assertEqual(self.merges(), [])
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


class MediaLandingTests(LandFixture):
    def manifest(self):
        import base64
        folder = self.tmp / 'capture'
        folder.mkdir()
        (folder / 'screen.png').write_bytes(base64.b64decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
        path = folder / 'manifest.json'
        path.write_text(json.dumps({'head': git(self.repo, 'rev-parse', 'HEAD'),
                                    'artifacts': [{'path': 'screen.png'}]}))
        return path

    def test_initial_pull_body_links_private_media(self):
        manifest = self.manifest()
        self.assertEqual(land.land(Gh(self.repo), self.repo, self.config, SESSION, None,
                                  self.summary, None, sleep=self.sleep, clock=self.clock,
                                  evidence_manifest=manifest), 0)
        body = self.state()['pulls'][0]['body']
        self.assertIn('../../widget-evidence/', body)
        self.assertIn('/media/', body)
        self.assertNotIn('screen.png', body)

    def test_base_merge_refuses_stale_media_even_without_repeating_flag(self):
        import verify
        manifest = self.manifest()
        verify.verify(self.repo, self.config, manifest)
        self.advance_base('lib/new.txt', 'base\n')
        with self.assertRaisesRegex(verify.VerifyError, 'head|recapture'):
            self.land()
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.merges(), [])


HELD_NUMBER = 9
HELD = "feat/9-hold-the-thing"
HELD_SESSION = "session-h"


class StackedFixture(LandFixture):
    """#7 (BRANCH) is claimed on HELD, #9's claim branch, which itself lands into main."""

    def setUp(self):
        super().setUp()
        self.held = self._clone("held")
        claims.create_claim(self.held, REMOTE, BASE, HELD, HELD_NUMBER, HELD_SESSION)
        git(self.held, "fetch", "-q", REMOTE)
        git(self.held, "checkout", "-q", "-b", HELD, "--track", f"{REMOTE}/{HELD}")
        self.commit(self.held, "lib/held.txt", "held\n")
        git(self.held, "push", "-q", REMOTE, f"HEAD:{HELD}")
        # Claim #7 again, this time on the held branch.
        git(self.repo, "push", "-q", REMOTE, f":refs/heads/{BRANCH}")
        git(self.repo, "checkout", "-q", "--detach")
        git(self.repo, "branch", "-q", "-D", BRANCH)
        self.claim_sha = claims.create_claim(self.repo, REMOTE, HELD, BRANCH, NUMBER, SESSION).sha
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "checkout", "-q", "-b", BRANCH, "--track", f"{REMOTE}/{BRANCH}")
        self.commit(self.repo, "app/a.txt", "two\n")
        self.add_issue(HELD_NUMBER, "[Task]: Hold the thing", status="Needs you")

    def add_issue(self, number: int, title: str, status: str = "Ready", state: str = "OPEN") -> None:
        issues = self.state()["issues"]
        issues[str(number)] = {"title": title, "state": state, "labels": ["task"], "status": status,
                               "inProject": True, "comments": []}
        self.set_state(issues=issues)

    def remote_file(self, branch: str, relative: str) -> str:
        git(self.repo, "fetch", "-q", REMOTE)
        shown = subprocess.run(["git", "show", f"{REMOTE}/{branch}:{relative}"], cwd=self.repo,
                               capture_output=True, text=True)
        return shown.stdout.strip() if shown.returncode == 0 else ""

    def receipt_checks(self, head: str) -> list:
        work = Path(git(self.repo, "rev-parse", "--absolute-git-dir")) / "work" / "receipts"
        return sorted(json.loads((work / f"{head}.json").read_text())["checks"])

    def close_issue(self, number: int) -> None:
        issues = self.state()["issues"]
        issues[str(number)]["state"] = "CLOSED"
        self.set_state(issues=issues)

    def reopen_issue(self, number: int) -> None:
        issues = self.state()["issues"]
        issues[str(number)]["state"] = "OPEN"
        self.set_state(issues=issues)

    def land_held(self) -> int:
        return land.land(Gh(self.held), self.held, self.config, HELD_SESSION, None, self.summary, None,
                         sleep=self.sleep, clock=self.clock)


class StackedLandTests(StackedFixture):
    # Failure mode 75: verify diffs against, land merges from, opens its pull
    # request into, merges into and reports the claim's own base, never main.
    def test_a_stacked_claim_verifies_against_and_lands_into_its_base(self):
        main_move = self.advance_base("lib/main-only.txt", "main\n")
        git(self.held, "pull", "-q", "--no-rebase", REMOTE, HELD)
        self.commit(self.held, "lib/later.txt", "later\n")
        git(self.held, "push", "-q", REMOTE, f"HEAD:{HELD}")
        self.assertEqual(self.land(), 0)
        [merge] = self.merges()
        head = merge[merge.index("--match-head-commit") + 1]
        pull = self.state()["pulls"][0]
        self.assertEqual((pull["base"], pull["state"]), (HELD, "MERGED"))
        self.assertIn(f"`{REMOTE}/{HELD}`", pull["body"])
        # Only #7's own change is in its diff: the held branch's paths need no check.
        self.assertEqual(self.receipt_checks(head), ["app", "policy"])
        self.assertNotEqual(subprocess.run(["git", "merge-base", "--is-ancestor", main_move, head],
                                           cwd=self.repo).returncode, 0, "main's move reached the stacked claim")
        self.assertEqual(self.remote_file(HELD, "app/a.txt"), "two")
        self.assertEqual(self.remote_file(HELD, "lib/later.txt"), "later")
        self.assertEqual(self.remote_file(BASE, "app/a.txt"), "one")
        # GitHub's "Closes #7" does not apply off the default branch; land closes it and names the base.
        issue = self.issue()
        self.assertEqual((issue["state"], issue["status"]), ("CLOSED", "Done"))
        self.assertTrue(issue["comments"][-1].startswith("Landed in #100 as"), issue["comments"][-1])
        self.assertIn(f"into `{HELD}`", issue["comments"][-1])
        self.assertEqual(self.remote_head(), "")

    # Failure mode 75: a land stopped after its merge into the base resumes.
    def test_a_stacked_land_stopped_after_its_merge_resumes(self):
        self.set_state(failIssue=["close"])
        with self.assertRaises(land.LandError):
            self.land()
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.set_state(failIssue=[])
        self.assertEqual(self.land(summary=False), 0)
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))
        self.assertEqual(len(self.merges()), 1)

    # Failure mode 77: a base is not landed while an open claim is stacked on it;
    # a stacked claim whose issue is closed no longer counts.
    def test_a_base_with_an_open_stacked_claim_does_not_land(self):
        with self.assertRaises(land.LandError) as raised:
            self.land_held()
        self.assertIn(f"#{NUMBER}", str(raised.exception))
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.merges(), [])
        issues = self.state()["issues"]
        issues[str(NUMBER)]["state"] = "CLOSED"
        self.set_state(issues=issues)
        self.assertEqual(self.land_held(), 0)
        self.assertEqual(self.state()["pulls"][-1]["base"], BASE)
        self.assertEqual(self.remote_file(BASE, "lib/held.txt"), "held")

    # Failure mode 77: a claim stacked while its base waits for checks stops the merge.
    def test_a_claim_stacked_during_the_wait_stops_the_merge(self):
        self.close_issue(NUMBER)
        self.set_state(pendingViews=1)

        def stacked_meanwhile(seconds: float) -> None:
            self.sleep(seconds)
            self.reopen_issue(NUMBER)

        with self.assertRaises(land.LandError) as raised:
            land.land(Gh(self.held), self.held, self.config, HELD_SESSION, None, self.summary, None,
                      sleep=stacked_meanwhile, clock=self.clock)
        self.assertIn(f"#{NUMBER}", str(raised.exception))
        self.assertEqual(self.merges(), [])
        self.assertNotEqual(self.remote_head(HELD), "")

    # Failure mode 77: a claim stacked after the merge keeps its base branch.
    def test_a_claim_stacked_after_the_merge_keeps_its_base_branch(self):
        self.close_issue(NUMBER)
        self.set_state(reopenOnMerge=[str(NUMBER)])
        self.assertEqual(self.land_held(), 0)
        self.assertEqual(self.state()["pulls"][-1]["state"], "MERGED")
        self.assertNotEqual(self.remote_head(HELD), "", "the base of an open claim was deleted")

    # Failure mode 78: a pull request retargeted during the wait is not merged.
    def test_a_pull_request_retargeted_during_the_wait_is_not_merged(self):
        self.set_state(pendingViews=1)

        def retargeted_meanwhile(seconds: float) -> None:
            self.sleep(seconds)
            pulls = self.state()["pulls"]
            pulls[0]["base"] = BASE
            self.set_state(pulls=pulls)

        with self.assertRaises(land.LandError) as raised:
            self.land(sleep=retargeted_meanwhile)
        self.assertIn(HELD, str(raised.exception))
        self.assertEqual(self.merges(), [])
        self.assertEqual(self.remote_file(BASE, "app/a.txt"), "one")

    # Failure mode 78: an open pull request into another base is never merged.
    def test_an_open_pull_request_into_another_base_is_refused(self):
        self.set_state(pulls=[{"number": 100, "headRefName": BRANCH, "title": "feat: Add the widget",
                               "body": "Closes #7\n", "base": BASE, "state": "OPEN", "headRefOid": None,
                               "mergeCommit": None}])
        with self.assertRaises(land.LandError) as raised:
            self.land()
        self.assertIn(HELD, str(raised.exception))
        self.assert_nothing_published()


class StackedStewardTests(StackedFixture):
    def open_pull(self, base: str) -> str:
        git(self.repo, "push", "-q", REMOTE, f"HEAD:{BRANCH}")
        head = git(self.repo, "rev-parse", "HEAD")
        self.set_state(pulls=[{"number": 100, "headRefName": BRANCH, "title": "feat: Add the widget",
                               "body": "Closes #7\n", "base": base, "state": "OPEN", "headRefOid": None,
                               "mergeCommit": None}],
                       statuses={head: {"test/verify": "SUCCESS"}})
        return head

    def steward_land(self) -> int:
        clone = self._clone("steward")
        return land.steward(Gh(clone), clone, self.config, NUMBER)

    # Failure mode 75: the steward checks and merges against the claim's base.
    def test_a_stacked_pull_request_lands_into_its_base(self):
        self.open_pull(HELD)
        self.assertEqual(self.steward_land(), 0)
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.assertEqual(self.remote_file(HELD, "app/a.txt"), "two")
        self.assertEqual(self.remote_file(BASE, "app/a.txt"), "one")

    def test_steward_lands_valid_bug_body_with_fenced_evidence_and_handoff(self):
        self.open_pull(HELD)
        issues = self.state()["issues"]
        issues[str(NUMBER)]["labels"] = ["task", "kind:bug"]
        pulls = self.state()["pulls"]
        summary = (" ## Repro\n\n   ```text\nfailed case\n   ```\n\n  ## Cause\n\nCause.\n\n"
                   "   ## Fix\n\nFix.\n")
        pulls[0]["body"] = ("Refs #7\n\n## Summary\n\n" + summary
                             + "\n## Verification\n\nGenerated.\n\n## Maintainer validation\n\n"
                             "Irreducible: physical device\n\nRun the check.\n")
        self.set_state(issues=issues, pulls=pulls)
        self.assertEqual(self.steward_land(), 0)
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.assertIn("Run the check.", self.issue()["comments"][-1])

    def test_steward_refuses_a_bug_pull_request_with_missing_evidence_sections(self):
        self.open_pull(HELD)
        issues = self.state()["issues"]
        issues[str(NUMBER)]["labels"] = ["task", "kind:bug"]
        pulls = self.state()["pulls"]
        pulls[0]["body"] = "Closes #7\n\n## Summary\n\n## Repro\n\nShown.\n\n## Verification\n\nGenerated.\n"
        self.set_state(issues=issues, pulls=pulls)
        with self.assertRaises(land.LandError) as raised:
            self.steward_land()
        self.assertIn("Cause", str(raised.exception))
        self.assertEqual(self.merges(), [])

    # Failure mode 78.
    def test_a_pull_request_into_another_base_is_refused(self):
        self.open_pull(BASE)
        with self.assertRaises(land.LandError) as raised:
            self.steward_land()
        self.assertIn(HELD, str(raised.exception))
        self.assertEqual(self.merges(), [])

    # Failure mode 77.
    def test_a_base_with_an_open_stacked_claim_is_not_landed(self):
        git(self.held, "push", "-q", REMOTE, f"HEAD:{HELD}")
        head = git(self.held, "rev-parse", "HEAD")
        self.set_state(pulls=[{"number": 100, "headRefName": HELD, "title": "feat: Hold the thing",
                               "body": "Closes #9\n", "base": BASE, "state": "OPEN", "headRefOid": None,
                               "mergeCommit": None}],
                       statuses={head: {"test/verify": "SUCCESS"}})
        clone = self._clone("steward")
        with self.assertRaises(land.LandError) as raised:
            land.steward(Gh(clone), clone, self.config, HELD_NUMBER)
        self.assertIn(f"#{NUMBER}", str(raised.exception))
        self.assertEqual(self.merges(), [])


class StackedStartTests(StackedFixture):
    def start(self, number: int, base=None) -> None:
        if not hasattr(self, "primary"):
            self.primary = self._clone("primary")
        start.run(Gh(self.primary), self.primary, self.config, number, SESSION, base)

    def claims_of(self, number: int) -> list:
        return claims.existing_claims(self.held, REMOTE, BASE, number)

    # Failure mode 75: start bases the claim on the fetched base tip and records it.
    def test_a_claim_starts_from_an_open_claim_branch_and_records_it(self):
        self.add_issue(8, "[Task]: Stack the next thing")
        self.start(8, base=HELD)
        [claim] = self.claims_of(8)
        self.assertEqual((claim.session, claim.base), (SESSION, HELD))
        held_tip = git(self.held, "rev-parse", "HEAD")
        self.assertEqual(git(self.held, "rev-parse", f"{claim.sha}^"), held_tip)
        self.assertIn(f"`{HELD}`", self.state()["issues"]["8"]["comments"][-1])

    # Failure mode 76: only the configured base or an open issue's claim branch is a base.
    def test_an_ineligible_base_is_refused_before_any_claim(self):
        self.add_issue(8, "[Task]: Stack the next thing")
        self.add_issue(10, "[Task]: Manual branch")
        self.add_issue(11, "[Task]: Finished", state="CLOSED")
        git(self.seed, "push", "-q", REMOTE, f"{REMOTE}/{BASE}:refs/heads/release")
        git(self.seed, "push", "-q", REMOTE, f"{REMOTE}/{BASE}:refs/heads/feat/10-manual")
        claims.create_claim(self.held, REMOTE, BASE, "feat/11-finished", 11, HELD_SESSION)
        for base in ("release", "feat/12-missing", "feat/10-manual", "feat/11-finished", "feat/8-itself"):
            with self.subTest(base=base):
                with self.assertRaises(claims.ClaimError):
                    self.start(8, base=base)
                self.assertEqual(self.claims_of(8), [])
        self.assertEqual(self.writes(), [])

    # Failure mode 76: a claim's base is fixed for its life.
    def test_a_resumed_claim_keeps_its_base(self):
        with self.assertRaises(claims.ClaimError):
            self.start(NUMBER, base=BASE)
        self.start(NUMBER)
        [claim] = self.claims_of(NUMBER)
        self.assertEqual(claim.base, HELD)


if __name__ == "__main__":
    unittest.main()
