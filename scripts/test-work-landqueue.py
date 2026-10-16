#!/usr/bin/env python3
"""Concurrent landings through the real `work land` CLI and its land queue (#1108).

Three task branches, each verified on its own, land at the same time against a local
bare remote. A fake `gh` (this file, run as WORK_GH) answers GitHub's pull request API
and performs each squash merge for real on the bare remote, the way GitHub would merge
a pull request whose base moved. Proven: every branch lands; no landing loops back,
because only the queue's turn holder merges; landings never overlap; the second and
third landings each merge the landing before them into their branch before verifying;
a `high` ticket lands before an earlier `normal` one; `work queue` shows the queue.
Evidence: test-results/work-landqueue.json.
"""
from __future__ import annotations

import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "tools" / "work" / "cli.py"


def fake_gh() -> None:
    """GitHub's pull request API over a bare remote, enough for `work land`."""
    state_path = Path(os.environ["LANDQUEUE_STATE"])
    with open(str(state_path) + ".lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(state_path.read_text())
        args, response = sys.argv[1:], None
        remote = state["remote"]

        def head_of(branch: str) -> str:
            out = subprocess.run(["git", "ls-remote", remote, f"refs/heads/{branch}"], capture_output=True, text=True).stdout
            return out.split()[0]

        if args[:2] == ["repo", "view"]:
            print("fixture/project")
            return
        if args[:2] == ["pr", "list"]:
            response = []
        elif args[:3] == ["api", "-X", "GET"] and "pulls?state=open" in args[3]:
            branch = args[3].split("head=")[1].split("%3A")[-1].split(":")[-1]
            response = [p for p in state["pulls"].values() if p["branch"] == branch and p["state"] == "open"]
        elif args[:3] == ["api", "-X", "POST"] and args[3].endswith("/pulls"):
            request = json.load(sys.stdin)
            number = str(len(state["pulls"]) + 1)
            state["pulls"][number] = {"number": int(number), "branch": request["head"], "title": request["title"],
                                      "state": "open", "draft": False, "node_id": f"PR_{number}"}
            response = state["pulls"][number]
        elif args[:3] == ["api", "-X", "PATCH"] and "/pulls/" in args[3]:
            request = json.load(sys.stdin)
            pull = state["pulls"][args[3].rsplit("/", 1)[1]]
            pull["title"] = request.get("title", pull["title"])
            response = pull
        elif args[:3] == ["api", "-X", "GET"] and "/pulls/" in args[3]:
            response = state["pulls"][args[3].rsplit("/", 1)[1]]
        elif args[:3] == ["api", "-X", "PUT"] and args[3].endswith("/merge"):
            request = json.load(sys.stdin)
            pull = state["pulls"][args[3].split("/")[-2]]
            assert head_of(pull["branch"]) == request["sha"], "merge of a head that is not the published one"
            clone = Path(state["root"]) / f"merger-{pull['number']}"
            run = lambda *a: subprocess.run(["git", "-C", str(clone), *a], check=True, capture_output=True, text=True)  # noqa: E731
            subprocess.run(["git", "clone", "-q", remote, str(clone)], check=True, capture_output=True)
            run("config", "user.name", "Fixture")
            run("config", "user.email", "fixture@example.invalid")
            run("merge", "--squash", f"origin/{pull['branch']}")
            run("commit", "-qm", request["commit_title"])
            run("push", "-q", "origin", "HEAD:main")
            sha = run("rev-parse", "HEAD").stdout.strip()
            shutil.rmtree(clone)
            pull["state"] = "merged"
            state["merges"].append({"branch": pull["branch"], "at": time.time()})
            response = {"sha": sha}
        else:
            raise AssertionError(f"unexpected fake gh call: {args}")
        if isinstance(response, dict) and "branch" in response:
            response = {**response, "head": {"sha": head_of(response["branch"]), "repo": {"full_name": "fixture/project"}}}
        elif isinstance(response, list):
            response = [{**p, "head": {"sha": head_of(p["branch"]), "repo": {"full_name": "fixture/project"}}} for p in response]
        state_path.write_text(json.dumps(state))
    print(json.dumps(response))


def git(cwd: Path, *args: str, env: dict) -> str:
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def run() -> None:
    evidence: dict = {}
    artifact = ROOT / "test-results" / "work-landqueue.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="tron-landqueue-"))
    try:
        repo, remote, state_path = temporary / "repo", temporary / "remote.git", temporary / "github.json"
        home = temporary / "home"
        home.mkdir()
        env = {**os.environ, "HOME": str(home), "TMPDIR": str(temporary), "TRON_HEAVY_DIR": str(temporary / "heavy"),
               "WORK_GH": str(Path(__file__).resolve()), "LANDQUEUE_STATE": str(state_path), "WORK_SESSION_ID": "fixture",
               "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main", env=env)
        git(repo, "config", "user.name", "Fixture", env=env)
        git(repo, "config", "user.email", "fixture@example.invalid", env=env)
        (repo / ".github").mkdir()
        shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
        (repo / "scripts").mkdir()
        for name in ("personal-info-guard.sh", "tron-node"):
            shutil.copy(ROOT / "scripts" / name, repo / "scripts" / name)
        shutil.copy(ROOT / ".node-version", repo / ".node-version")
        git(repo, "add", "-A", env=env)
        git(repo, "commit", "-qm", "base", env=env)
        subprocess.run(["git", "init", "-q", "--bare", "--initial-branch=main", str(remote)], check=True)
        git(repo, "remote", "add", "origin", str(remote), env=env)
        git(repo, "push", "-q", "origin", "main", env=env)
        state_path.write_text(json.dumps({"root": str(temporary), "remote": str(remote), "pulls": {}, "merges": []}))
        summary = temporary / "summary.md"
        summary.write_text("Land through the queue.\n")

        branches = ["feat-a", "feat-b", "feat-c"]
        worktrees = {}
        for branch in branches:
            worktree = temporary / branch
            git(repo, "worktree", "add", "-q", "-b", branch, str(worktree), "origin/main", env=env)
            (worktree / f"{branch}.txt").write_text(f"{branch}\n")
            git(worktree, "add", "-A", env=env)
            git(worktree, "commit", "-qm", branch, env=env)
            git(worktree, "push", "-q", "origin", f"HEAD:refs/heads/{branch}", env=env)
            worktrees[branch] = worktree

        # feat-a takes the turn first; feat-b and feat-c queue behind it, and feat-c is raised.
        processes = {}
        for branch in branches:
            extra = ["--priority", "high"] if branch == "feat-c" else []
            processes[branch] = subprocess.Popen([sys.executable, str(CLI), "land", "--summary-file", str(summary), *extra],
                                                 cwd=worktrees[branch], env=env, stdout=subprocess.PIPE,
                                                 stderr=subprocess.STDOUT, text=True)
            time.sleep(1.5 if branch == "feat-a" else 0.3)
        listing = subprocess.run([sys.executable, str(CLI), "queue"], cwd=repo, env=env, capture_output=True, text=True).stdout
        outputs = {branch: process.communicate(timeout=240)[0] for branch, process in processes.items()}
        evidence["queue"] = listing
        evidence["outputs"] = outputs
        for branch, process in processes.items():
            assert process.returncode == 0, f"{branch} did not land:\n{outputs[branch]}"
            assert "moved before the merge" not in outputs[branch], f"{branch} looped back:\n{outputs[branch]}"
        assert "landing now: feat-a" in listing, listing
        state = json.loads(state_path.read_text())
        order = [merge["branch"] for merge in state["merges"]]
        evidence["mergeOrder"] = order
        assert order == ["feat-a", "feat-c", "feat-b"], f"priority, then arrival: {order}"
        for later in ("feat-c", "feat-b"):
            assert "merged origin/main" in outputs[later], f"{later} merged the landing before it:\n{outputs[later]}"
        events = [json.loads(line) for line in (repo / ".git/work/land/events.jsonl").read_text().splitlines()]
        evidence["events"] = events
        assert not [e for e in events if e["event"] == "loop-back"], "no landing loops back"
        turns = {e["branch"]: e for e in events if e["event"] == "turn"}
        merged = {e["branch"]: e for e in events if e["event"] == "merged"}
        assert turns["feat-c"]["at"] >= merged["feat-a"]["at"] and turns["feat-b"]["at"] >= merged["feat-c"]["at"], events
        tree = git(repo, "ls-tree", "--name-only", "origin/main", env={**env}) if git(repo, "fetch", "-q", "origin", env=env) == "" else ""
        assert all(f"{branch}.txt" in tree for branch in branches), tree
        print(f"Passed land queue journey: merge order {order}, 0 loop-backs; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2, default=str) + "\n")
        shutil.rmtree(temporary, ignore_errors=True)


if __name__ == "__main__":
    if os.environ.get("LANDQUEUE_STATE") and len(sys.argv) > 1:
        fake_gh()
    else:
        run()
