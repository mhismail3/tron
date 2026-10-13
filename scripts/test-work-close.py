#!/usr/bin/env python3
"""Exercise work issue close and reopen through the real CLI, Git and a process-level gh fixture."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OPTIONS = {"done": "Done", "ready": "Ready", "in-progress": "In progress"}


def fixture_gh() -> None:
    path = Path(os.environ["WORK_CLOSE_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[1:]
    page = {"hasNextPage": False, "endCursor": None}
    response = None
    write = None
    if args[:2] == ["repo", "view"]:
        response = {"id": "repo", "nameWithOwner": "fixture/project", "owner": {"login": "fixture"}}
    elif args[:2] == ["api", "graphql"]:
        request = json.load(sys.stdin)
        query = request["query"]
        if "mutation" in query:
            if state.pop("fail_status_once", False):
                path.write_text(json.dumps(state))
                print("fixture status transport failure", file=sys.stderr)
                sys.exit(1)
            state["status"] = OPTIONS[request["variables"]["option"]]
            write = "status"
            response = {"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "item"}}}}
        elif "repositoryOwner" in query:
            response = {"data": {"repositoryOwner": {"id": "owner", "projectsV2": {
                "pageInfo": page, "nodes": [{"id": "project", "title": "Tron",
                    "repositories": {"nodes": [{"id": "repo"}]}, "fields": {"nodes": [
                        {"id": "status", "name": "Status", "options": [
                            {"id": option, "name": label} for option, label in OPTIONS.items()]}]}}]}}}}
        elif "projectItems" in query:
            response = {"data": {"node": {"projectItems": {"pageInfo": page, "nodes": [
                {"id": "item", "project": {"id": "project", "title": "Tron"}}]}}}}
    elif args[:3] == ["api", "-X", "GET"]:
        response = {"number": 41, "node_id": "issue", "state": state["state"],
                    "labels": [{"name": state.get("label", "epic")} ]}
    elif args[:3] == ["api", "--paginate", "--slurp"]:
        if "/sub_issues" in args[3]:
            if state.get("fail_children"):
                print("fixture children unavailable", file=sys.stderr)
                sys.exit(1)
            response = state["child_pages"]
        elif args[3].endswith("/comments"):
            response = [[{"body": body} for body in state["comments"]]]
    elif args[:2] == ["issue", "comment"]:
        state["comments"].append(sys.stdin.read())
        write = "comment"
    elif args[:2] == ["issue", "close"]:
        state["state"] = "closed"
        state["reason"] = args[args.index("--reason") + 1]
        write = "close"
    elif args[:2] == ["issue", "reopen"]:
        state["state"] = "open"
        write = "reopen"
    else:
        raise AssertionError(f"Unexpected fixture gh invocation: {args}")
    if write:
        state["writes"].append(write)
    path.write_text(json.dumps(state))
    print(json.dumps(response))


def run() -> None:
    evidence = []
    artifact = ROOT / "test-results" / "work-close.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-close-") as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            home, tmp = root / "home", root / "tmp"
            home.mkdir()
            tmp.mkdir()
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp),
                   "WORK_GH": str(Path(__file__).resolve()), "WORK_SESSION_ID": "fixture-owner",
                   "WORK_CLOSE_FIXTURE": str(root / "github.json"), "PYTHONDONTWRITEBYTECODE": "1",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}

            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, env=env, check=True,
                                      text=True, capture_output=True).stdout.strip()

            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("commit", "--allow-empty", "-m", "fixture base")
            remote = root / "remote.git"
            git("init", "--bare", str(remote))
            git("remote", "add", "origin", str(remote))
            git("push", "origin", "main")
            (repo / ".github").mkdir()
            shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            comment = root / "close.md"
            comment.write_text("Verified all linked tasks are finished.\n")
            state_path = Path(env["WORK_CLOSE_FIXTURE"])

            def reset(**updates):
                state = {"state": "open", "comments": [], "writes": [], "status": "Ready",
                         "child_pages": [[{"number": 42, "state": "closed"}]]}
                state.update(updates)
                state_path.write_text(json.dumps(state))

            def close(name, success, reason="completed"):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "issue", "close", "41",
                                         "--reason", reason, "--comment-file", str(comment)],
                                        cwd=repo, env=env, capture_output=True, text=True, timeout=30)
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                assert (result.returncode == 0) == success, evidence[-1]
                return json.loads(state_path.read_text()), result.stderr

            reset()
            state, _ = close("completed epic", True)
            assert state["state"] == "closed" and state["status"] == "Done"
            assert state["writes"] == ["comment", "close", "status"]
            state, _ = close("same close is idempotent", True)
            assert len(state["comments"]) == 1 and state["writes"].count("close") == 1

            reset(child_pages=[[{"number": 42, "state": "closed"}], [{"number": 143, "state": "open"}]])
            state, error = close("open child on later page", False)
            assert "#143" in error and not state["writes"]
            state, _ = close("not-planned cannot bypass open children", False, "not_planned")
            assert not state["writes"]

            reset(fail_children=True)
            state, _ = close("child read fails closed", False)
            assert not state["writes"]

            reset(fail_status_once=True)
            state, _ = close("partial status failure", False)
            assert state["state"] == "closed" and state["status"] == "Ready"
            state, _ = close("retry finishes partial close", True)
            assert state["status"] == "Done" and len(state["comments"]) == 1

            reset(label="task", child_pages=[[{"number": 42, "state": "open"}]])
            state, _ = close("ordinary task unchanged", True)
            assert state["state"] == "closed"

            reset()
            git("checkout", "-b", "feat/41-foreign")
            git("commit", "--allow-empty", "-m", "Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: other-owner")
            git("push", "origin", "feat/41-foreign")
            git("checkout", "main")
            state, error = close("foreign claim refused", False)
            assert "another session" in error and not state["writes"]

            reason = root / "reopen.md"
            git("push", "origin", "--delete", "feat/41-foreign")

            def reopen(name, success):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "issue", "reopen", "41",
                                         "--comment-file", str(reason)],
                                        cwd=repo, env=env, capture_output=True, text=True, timeout=30)
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                assert (result.returncode == 0) == success, evidence[-1]
                return json.loads(state_path.read_text()), result.stderr

            # An issue closed by mistake (for example by a PR's closing keyword) reopens only with a stated reason.
            reset(state="closed", status="Done", label="task")
            reason.write_text("  \n")
            state, error = reopen("reopen without a reason refused", False)
            assert "must not be empty" in error and not state["writes"]
            reason.write_text("Closed by a closing keyword in an unrelated PR; the bug is unfixed.\n")
            state, _ = reopen("unclaimed reopen", True)
            assert state["state"] == "open" and state["status"] == "Ready"
            assert state["writes"] == ["comment", "reopen", "status"]
            assert "unrelated PR" in state["comments"][0] and "<!-- work:reopen digest=" in state["comments"][0]
            state, _ = reopen("same reopen is idempotent", True)
            assert len(state["comments"]) == 1 and state["writes"].count("reopen") == 1

            reset(label="task")
            state, error = reopen("open issue it did not reopen refused", False)
            assert "is open" in error and not state["writes"]

            # A claim survives the mistaken close: reopening returns the issue to its owner, In progress.
            reset(state="closed", status="Done", label="task", fail_status_once=True)
            git("push", "origin", "feat/41-foreign")
            state, _ = reopen("partial status failure", False)
            assert state["state"] == "open" and state["status"] == "Done"
            state, _ = reopen("retry finishes claimed reopen", True)
            assert state["status"] == "In progress" and len(state["comments"]) == 1
            assert state["writes"] == ["comment", "reopen", "status"]
            audit = (repo / ".git/work/github-writes.jsonl").read_text()
            assert '"issue.reopen"' in audit and "unrelated PR" not in audit
        print(f"Passed {len(evidence)} real-CLI close and reopen journeys; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("WORK_CLOSE_FIXTURE") and sys.argv[1:2] in (["api"], ["repo"], ["issue"]):
        fixture_gh()
    else:
        run()
