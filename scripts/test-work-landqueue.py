#!/usr/bin/env python3
"""Concurrent landings through the real `work land` CLI and its land queue (#1108).

Three task branches, each verified on its own, land at the same time against a local
bare remote. A fake `gh` (this file, run as WORK_GH) answers GitHub's pull request API
and performs each squash merge for real on the bare remote, the way GitHub would merge
a pull request whose base moved. Proven: every branch lands; no landing loops back,
because only the queue's turn holder merges; landings never overlap; the second and
third landings each merge the landing before them into their branch before verifying;
a `high` ticket lands before earlier `normal` ones; `work queue` shows the queue. The
test holds the turn itself while the three queue, so the order is deterministic.
Evidence: test-results/work-landqueue.json.
"""
from __future__ import annotations

import fcntl
import json
import os
import shutil
import shlex
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
        # Real gate/land entrypoints with a small catalog: content-equivalent passes
        # must survive unrelated main moves, but opaque inputs and source stamps may not.
        shutil.copytree(ROOT / "tools/work", repo / "tools/work", ignore=shutil.ignore_patterns("__pycache__"))
        policy = Path("packages/gateway/src/tron-home-environment-policy.mjs")
        (repo / policy).parent.mkdir(parents=True)
        shutil.copy(ROOT / policy, repo / policy)
        (repo / "area-a").mkdir()
        (repo / "area-b").mkdir()
        (repo / "area-a/base").write_text("1\n")
        (repo / "area-b/base").write_text("1\n")
        (repo / ".gitignore").write_text("product.json\n")
        probe = "import os; from pathlib import Path; p=Path(os.environ['PROBE_TRACE']); p.open('a').write(Path.cwd().name + ':' + '{name}' + '\\n')"
        steps = []
        for name, inputs, scope in (("a", ["area-a"], "worktree"), ("b", ["area-b"], "worktree"),
                                    ("unknown", ["."], "worktree"), ("product", ["area-a"], "source")):
            code = probe.format(name=name)
            if name == "product":
                code += "; import subprocess; Path('product.json').write_text(subprocess.check_output(['git','rev-parse','HEAD'],text=True))"
            steps.append({"id": name, "trigger": {"always": True}, "command": "python3 -c " + shlex.quote(code), "tier": "L1",
                          "inputs": inputs, "cacheScope": scope, "budgetSeconds": 5, "timeoutSeconds": 10,
                          "class": "light", "expectedRssMb": 10, "pass": "exit 0", "unlocks": "land"})
        (repo / "tools/work/gate-catalog.json").write_text(json.dumps({"version": 1, "steps": steps}))
        env["PROBE_TRACE"] = str(temporary / "executed.txt")
        git(repo, "add", "-A", env=env)
        git(repo, "commit", "-qm", "base", env=env)
        subprocess.run(["git", "init", "-q", "--bare", "--initial-branch=main", str(remote)], check=True)
        git(repo, "remote", "add", "origin", str(remote), env=env)
        git(repo, "push", "-q", "origin", "main", env=env)
        state_path.write_text(json.dumps({"root": str(temporary), "remote": str(remote), "pulls": {}, "merges": []}))
        summary = temporary / "summary.md"
        summary.write_text("Land through the queue.\n")

        branches = ["feat-a", "feat-b", "feat-c"]
        worktrees, original_heads = {}, {}
        for branch in branches:
            worktree = temporary / branch
            git(repo, "worktree", "add", "-q", "-b", branch, str(worktree), "origin/main", env=env)
            (worktree / f"{branch}.txt").write_text(f"{branch}\n")
            (worktree / ("area-b" if branch == "feat-a" else "area-a") / branch).write_text("2\n")
            git(worktree, "add", "-A", env=env)
            git(worktree, "commit", "-qm", branch, env=env)
            git(worktree, "push", "-q", "origin", f"HEAD:refs/heads/{branch}", env=env)
            worktrees[branch] = worktree
            original_heads[branch] = git(worktree, "rev-parse", "HEAD", env=env)
            before = subprocess.run([sys.executable, str(worktree / "tools/work/gate.py"), "run"],
                                    cwd=worktree, env=env, capture_output=True, text=True, timeout=30)
            assert before.returncode == 0, before.stdout + before.stderr
        baseline = Path(env["PROBE_TRACE"]).read_text().splitlines()
        assert len(baseline) == 12, baseline
        Path(env["PROBE_TRACE"]).write_text("")

        # A landing already holds the turn (this process), so all three queue behind it;
        # feat-c arrives last but is raised, so it lands first, then feat-a and feat-b by arrival.
        sys.path.insert(0, str(CLI.parent))
        import landqueue
        processes = {}
        with landqueue.turn(repo, "in-flight", "0" * 40, report=open(os.devnull, "w")):
            for branch in branches:
                extra = ["--priority", "high"] if branch == "feat-c" else []
                processes[branch] = subprocess.Popen([sys.executable, str(worktrees[branch] / "tools/work/cli.py"), "land", "--summary-file", str(summary), *extra],
                                                     cwd=worktrees[branch], env=env, stdout=subprocess.PIPE,
                                                     stderr=subprocess.STDOUT, text=True)
                deadline = time.monotonic() + 60
                while sum(t["branch"] == branch for t in landqueue.tickets(repo)) == 0:
                    assert time.monotonic() < deadline and processes[branch].poll() is None, f"{branch} never queued"
                    time.sleep(0.1)
            listing = subprocess.run([sys.executable, str(CLI), "queue"], cwd=repo, env=env, capture_output=True,
                                     text=True).stdout
        outputs = {branch: process.communicate(timeout=240)[0] for branch, process in processes.items()}
        evidence["queue"] = listing
        evidence["outputs"] = outputs
        executions = Path(env["PROBE_TRACE"]).read_text().splitlines()
        evidence["verificationExecutions"] = {"baseline": baseline, "landings": executions}
        assert not [row for row in executions if row.startswith("feat-c:")], executions
        assert {row for row in executions if row.startswith("feat-a:")} == {"feat-a:a", "feat-a:unknown", "feat-a:product"}, executions
        assert {row for row in executions if row.startswith("feat-b:")} == {"feat-b:a", "feat-b:b", "feat-b:unknown", "feat-b:product"}, executions
        records = [json.loads(path.read_text()) for path in (repo / ".git/work/gate/results/b").glob("*.json")]
        reused = [record for record in records if record["worktree"] == "feat-a"]
        assert len(reused) == 1 and reused[0]["head"] == original_heads["feat-a"], reused
        current = git(worktrees["feat-a"], "rev-parse", "HEAD", env=env)
        assert current != reused[0]["head"]
        evidence["reusedProvenance"] = {"receiptHead": reused[0]["head"], "integratedHead": current}
        for branch in ("feat-a", "feat-b"):
            assert (worktrees[branch] / "product.json").read_text().strip() == git(worktrees[branch], "rev-parse", "HEAD", env=env)
        for branch, process in processes.items():
            assert process.returncode == 0, f"{branch} did not land:\n{outputs[branch]}"
            assert "moved before the merge" not in outputs[branch], f"{branch} looped back:\n{outputs[branch]}"
        assert "landing now: in-flight" in listing and listing.index("feat-c") < listing.index("feat-a") < listing.index("feat-b"), listing
        state = json.loads(state_path.read_text())
        order = [merge["branch"] for merge in state["merges"]]
        evidence["mergeOrder"] = order
        assert order == ["feat-c", "feat-a", "feat-b"], f"priority, then arrival: {order}"
        for later in ("feat-a", "feat-b"):
            assert "merged origin/main" in outputs[later], f"{later} merged the landing before it:\n{outputs[later]}"
        events = [json.loads(line) for line in (repo / ".git/work/land/events.jsonl").read_text().splitlines()]
        evidence["events"] = events
        assert not [e for e in events if e["event"] == "loop-back"], "no landing loops back"
        turns = {e["branch"]: e for e in events if e["event"] == "turn"}
        merged = {e["branch"]: e for e in events if e["event"] == "merged"}
        assert turns["feat-a"]["at"] >= merged["feat-c"]["at"] and turns["feat-b"]["at"] >= merged["feat-a"]["at"], events
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
