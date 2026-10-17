#!/usr/bin/env python3
"""Landing without a queue (#1190, tools/work/README.md#landing) through the real CLI, Git
and a process-level GitHub fixture that really squash-merges into a bare remote.

1. Two disjoint branches, each checked on its own tree, land at the same time: neither
   runs a gate while landing (their receipts cover them) and both merge in seconds.
2. A semantic conflict (each branch passes alone, together they break) is caught by the
   post-merge check of main: landing stops, bisect names the later merge, a revert pull
   request merges, the culprit's issue is reopened with the failure, and landing resumes
   when the reverted main passes.
3. When the revert cannot merge, landing stays stopped and `work land` refuses loudly;
   `--repair-main` lands the fix and the next check reopens landing. A failure that also
   happens on the last main that passed (the check's environment) blames no merge.
4. A receipt is reused for the same tree after a message-only amend and refused after a
   content change.
5. A post-merge check killed mid-run resumes and reuses the shards that already passed.

Evidence: test-results/work-mainline.json (includes measured land-to-merge seconds).
"""
from __future__ import annotations

import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
PAGE = {"hasNextPage": False, "endCursor": None}
OPTIONS = {"done": "Done", "ready": "Ready", "in-progress": "In progress"}


# ---------------------------------------------------------------- GitHub fixture

def fixture_gh() -> None:
    path = Path(os.environ["MAINLINE_FIXTURE"])
    with open(str(path) + ".lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(path.read_text())
        output, refusal = _answer(state, sys.argv[1:])
        path.write_text(json.dumps(state))
    if refusal:
        print(f"gh: {refusal}", file=sys.stderr)
        sys.exit(1)
    if output is not None:
        print(output if isinstance(output, str) else json.dumps(output))


def _answer(state: dict, args: list):
    if args[:2] == ["repo", "view"]:
        return ("fixture/project" if "--jq" in args else
                {"id": "repo", "nameWithOwner": "fixture/project", "owner": {"login": "fixture"}}), None
    if args[:2] == ["pr", "list"]:
        branch = args[args.index("--head") + 1]
        return [{"number": p["number"], "headRefOid": p["head"]["sha"], "baseRefName": "main", "isCrossRepository": False}
                for p in state["pulls"].values() if p["head"]["ref"] == branch and p["merged"]], None
    if args[:2] == ["issue", "comment"]:
        state["comments"].append({"issue": int(args[2]), "body": sys.stdin.read()})
        return "", None
    if args[:2] == ["issue", "reopen"]:
        state["reopened"].append(int(args[2]))
        return "", None
    if args[:2] == ["api", "graphql"]:
        query = json.load(sys.stdin)["query"]
        if "mutation" in query:
            return {"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "item"}}}}, None
        if "repositoryOwner" in query:
            return {"data": {"repositoryOwner": {"id": "owner", "projectsV2": {"pageInfo": PAGE, "nodes": [
                {"id": "project", "title": "Tron", "repositories": {"nodes": [{"id": "repo"}]}, "fields": {"nodes": [
                    {"id": "status", "name": "Status", "options": [
                        {"id": key, "name": label} for key, label in OPTIONS.items()]}]}}]}}}}, None
        if "projectItems" in query:
            return {"data": {"node": {"projectItems": {"pageInfo": PAGE, "nodes": [
                {"id": "item", "project": {"id": "project", "title": "Tron"}}]}}}}, None
        return {"data": {"repository": {"id": "repo"}}}, None
    if args[:3] == ["api", "--paginate", "--slurp"]:
        return [[]], None
    method, endpoint = args[2], args[3]
    body = json.load(sys.stdin) if "--input" in args else None
    number = endpoint.rstrip("/").split("/")[-1]
    if "/issues/" in endpoint:
        issue = state["issues"].setdefault(number, {"number": int(number), "title": f"Fixture issue {number}",
                                                    "state": "open", "labels": [], "node_id": f"I_{number}"})
        if method == "PATCH":
            issue["state"] = body.get("state", issue["state"])
        return issue, None
    if method == "GET" and "pulls?state=open" in endpoint:
        branch = unquote(endpoint.split("head=fixture:")[1])
        return [_pull(p) for p in state["pulls"].values() if p["head"]["ref"] == branch and not p["merged"]], None
    if method == "POST" and endpoint.endswith("/pulls"):
        state["next"] += 1
        pull = {"number": state["next"], "title": body["title"], "body": body["body"], "merged": False,
                "head": {"ref": body["head"], "sha": _remote(state, f"refs/heads/{body['head']}")}}
        state["pulls"][str(pull["number"])] = pull
        return _pull(pull), None
    pull = state["pulls"].get(number if not endpoint.endswith("/merge") else endpoint.split("/")[-2])
    if method == "GET":
        return _pull(pull), None
    if method == "PATCH":
        pull.update(title=body["title"], body=body["body"])
        return _pull(pull), None
    if method == "PUT":
        if pull["head"]["ref"].startswith("revert/") and state.get("refuse_revert"):
            return None, "HTTP 405: Pull request is not mergeable"
        sha = _squash(state, pull, body)
        if sha is None:
            return None, "HTTP 405: Pull request is not mergeable"
        pull["merged"] = True
        state["merges"].append({"pull": pull["number"], "ref": pull["head"]["ref"], "sha": sha, "at": time.time()})
        return {"sha": sha, "merged": True}, None
    raise AssertionError(f"unexpected fixture gh invocation: {args}")


def _pull(pull: dict) -> dict:
    return {"number": pull["number"], "title": pull["title"], "draft": False, "node_id": f"PR_{pull['number']}",
            "head": {"sha": pull["head"]["sha"], "ref": pull["head"]["ref"],
                     "repo": {"full_name": "fixture/project"}}}


def _remote(state: dict, ref: str) -> str:
    return subprocess.run(["git", "--git-dir", state["remote"], "rev-parse", ref], capture_output=True, text=True,
                          check=True).stdout.strip()


def _squash(state: dict, pull: dict, body: dict):
    """GitHub's squash merge: the pull request's changes as one commit on the current main."""
    assert body["sha"] == _remote(state, f"refs/heads/{pull['head']['ref']}"), "merge names the published head"
    with tempfile.TemporaryDirectory() as temporary:
        clone = Path(temporary) / "clone"
        git = lambda *a: subprocess.run(["git", "-C", str(clone), *a], capture_output=True, text=True)  # noqa: E731
        subprocess.run(["git", "clone", "-q", state["remote"], str(clone)], check=True, capture_output=True)
        git("config", "user.name", "Fixture GitHub")
        git("config", "user.email", "github@example.invalid")
        git("fetch", "-q", "origin", pull["head"]["ref"])
        if git("merge", "--squash", "FETCH_HEAD").returncode:
            return None
        git("commit", "-q", "--allow-empty", "-m", body["commit_title"], "-m", body.get("commit_message", ""))
        if git("push", "-q", "origin", "HEAD:main").returncode:
            return None
        return git("rev-parse", "HEAD").stdout.strip()


# ---------------------------------------------------------------- journeys

CHECK = """import pathlib, sys
mode = pathlib.Path("config.txt").read_text().split("=")[1].strip()
usage = pathlib.Path("usage.txt")
if usage.exists() and usage.read_text().split("=")[1].strip() != mode:
    sys.exit("usage.txt needs a mode the configuration does not set")
"""
SLOW = """import os, pathlib, sys, time
seconds = float(pathlib.Path(os.environ["MAINLINE_SLOW"]).read_text() or 0)
with open(os.environ["MAINLINE_TRACE"], "a") as trace:
    trace.write(f"{pathlib.Path.cwd().name}:start:{sys.argv[1]}\\n")
time.sleep(seconds)
with open(os.environ["MAINLINE_TRACE"], "a") as trace:
    trace.write(f"{pathlib.Path.cwd().name}:done:{sys.argv[1]}\\n")
"""


class Fixture:
    def __init__(self, base: Path):
        self.base = base
        self.repo, self.remote = base / "repo", base / "remote.git"
        self.state, self.trace, self.slow = base / "github.json", base / "trace", base / "slow"
        home, tmp = base / "home", base / "tmp"
        home.mkdir()
        tmp.mkdir()
        self.slow.write_text("0")
        catalog = {"version": 1, "codeExclude": ["**/*.md"], "steps": [
            {"id": "unit", "trigger": {"always": True, "code": True}, "command": "python3 check.py", "inputs": ["."],
             "budgetSeconds": 10, "timeoutSeconds": 30, "class": "light", "expectedRssMb": 10, "pass": "exit 0",
             "tier": "L1", "unlocks": "land"},
            # Passes only where the environment has what it needs, whatever the tree.
            {"id": "env", "trigger": {"always": True, "code": True},
             "command": "python3 -c 'import os,sys; sys.exit(os.path.exists(os.environ[\"MAINLINE_BROKEN\"]))'",
             "inputs": ["."], "budgetSeconds": 10, "timeoutSeconds": 30, "class": "light", "expectedRssMb": 10,
             "pass": "exit 0", "tier": "L1", "unlocks": "land"},
            {"id": "slow", "trigger": {"always": True, "code": True}, "command": "python3 slow.py {shard}", "shards": 3,
             "inputs": ["."], "budgetSeconds": 10, "timeoutSeconds": 30, "class": "light", "expectedRssMb": 10,
             "pass": "exit 0", "tier": "L1", "unlocks": "land"}]}
        (base / "catalog.json").write_text(json.dumps(catalog))
        self.env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "TRON_HEAVY_DIR": str(tmp / "heavy"),
                    "WORK_GH": str(Path(__file__).resolve()), "WORK_SESSION_ID": "fixture-owner",
                    "MAINLINE_FIXTURE": str(self.state), "MAINLINE_TRACE": str(self.trace),
                    "MAINLINE_SLOW": str(self.slow), "MAINLINE_BROKEN": str(base / "broken"),
                    "TRON_GATE_CATALOG": str(base / "catalog.json"),
                    "TRON_HEAVY_BUSY_CORES": "0", "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": os.devnull, "NVM_DIR": os.environ.get("NVM_DIR", str(Path.home() / ".nvm"))}
        self.env.pop("TRON_HEAVY_LEASE_HELD", None)
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        for name in (".github/work.json", "scripts/personal-info-guard.sh", "scripts/tron-node", ".node-version",
                     "packages/gateway/src/tron-home-environment-policy.mjs"):
            (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / name, self.repo / name)
        # The post-merge check runs main's own tooling, so the fixture's main carries it.
        shutil.copytree(ROOT / "tools/work", self.repo / "tools/work", ignore=shutil.ignore_patterns("__pycache__"))
        (self.repo / "check.py").write_text(CHECK)
        (self.repo / "slow.py").write_text(SLOW)
        (self.repo / "config.txt").write_text("mode=safe\n")
        self.git("add", "-A")
        self.commit("fixture base")
        subprocess.run(["git", "init", "-q", "--bare", "--initial-branch=main", str(self.remote)], check=True)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-q", "origin", "main")
        self.state.write_text(json.dumps({"remote": str(self.remote), "pulls": {}, "next": 100, "issues": {},
                                          "merges": [], "comments": [], "reopened": []}))

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return subprocess.run(["git", *args], cwd=cwd or self.repo, env=self.env, check=True, text=True,
                              capture_output=True).stdout.strip()

    def commit(self, message: str, cwd: Path | None = None) -> None:
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", message,
                 cwd=cwd)

    def branch(self, name: str, files: dict, start: str = "origin/main") -> Path:
        """A task worktree with one commit, like `work start` gives a worker."""
        self.git("fetch", "-q", "origin")
        path = self.base / name.replace("/", "-")
        self.git("worktree", "add", "-q", "-b", name, str(path), start)
        for relative, text in files.items():
            (path / relative).write_text(text)
        self.git("add", "-A", cwd=path)
        self.commit(f"{name} change", cwd=path)
        return path

    def work(self, cwd: Path, *args: str, timeout: float = 120) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.repo / "tools/work/cli.py"), *args], cwd=cwd, env=self.env,
                              capture_output=True, text=True, timeout=timeout)

    def gate(self, cwd: Path, *args: str, timeout: float = 120) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.repo / "tools/work/gate.py"), *args], cwd=cwd, env=self.env,
                              capture_output=True, text=True, timeout=timeout)

    def land(self, cwd: Path, *extra: str) -> subprocess.CompletedProcess:
        summary = self.base / "summary.md"
        summary.write_text("Fixture landing.\n")
        return self.work(cwd, "land", "--summary-file", str(summary), *extra)

    def main_state(self) -> dict:
        return json.loads((self.repo / ".git/work/main/state.json").read_text())

    def github(self) -> dict:
        return json.loads(self.state.read_text())

    def wait_for_check(self, timeout: float = 120) -> None:
        directory = self.repo / ".git/work/main"
        deadline = time.monotonic() + timeout
        settled = 0
        while time.monotonic() < deadline:
            busy = any(_held(directory / name) for name in ("check.lock", "waiter.lock"))
            settled = 0 if busy else settled + 1
            if settled >= 3:
                return
            time.sleep(0.3)
        raise AssertionError("the post-merge check did not finish:\n" + self.check_log())

    def check_log(self) -> str:
        path = self.repo / ".git/work/main/check.log"
        return path.read_text() if path.exists() else ""

    def tip(self) -> str:
        return subprocess.run(["git", "--git-dir", str(self.remote), "rev-parse", "main"], capture_output=True,
                              text=True, check=True).stdout.strip()


def _held(path: Path) -> bool:
    if not path.exists():
        return False
    with path.open("a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def disjoint(fx: Fixture, evidence: list) -> None:
    first = fx.branch("feat/910-alpha", {"alpha.txt": "alpha\n"})
    second = fx.branch("feat/911-beta", {"beta.txt": "beta\n"})
    # Each branch is checked once, on its own tree, before landing (in parallel, no lock).
    checks = [subprocess.Popen([sys.executable, str(fx.repo / "tools/work/gate.py"), "run"], cwd=path, env=fx.env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for path in (first, second)]
    assert all(check.wait(120) == 0 for check in checks), [check.stdout.read() for check in checks]
    started = time.monotonic()
    lands = [subprocess.Popen([sys.executable, str(fx.repo / "tools/work/cli.py"), "land", "--summary-file",
                               str(fx.base / "summary.md")], cwd=path, env=fx.env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) for path in (first, second)]
    (fx.base / "summary.md").write_text("Fixture landing.\n")
    results = [(land.wait(120), *land.communicate()) for land in lands]
    seconds = round(time.monotonic() - started, 1)
    evidence.append({"case": "two disjoint branches land at once, each on its receipt", "seconds": seconds,
                     "results": results})
    assert all(code == 0 for code, _, _ in results), results
    assert all("covers all 5 shards; nothing to run" in out for _, out, _ in results), results
    assert {m["ref"] for m in fx.github()["merges"]} == {"feat/910-alpha", "feat/911-beta"}
    rows = [json.loads(line) for line in (fx.repo / ".git/work/land/events.jsonl").read_text().splitlines()]
    merged = [row for row in rows if row["event"] == "merged"]
    assert len(merged) == 2 and all(row["mergeWaitSeconds"] < 10 for row in merged), merged
    fx.wait_for_check()
    assert fx.main_state()["lastPassed"] == fx.tip(), (fx.main_state(), fx.check_log())
    status = fx.gate(fx.repo, "status")
    evidence.append({"case": "status after the post-merge check", "stdout": status.stdout})
    assert status.returncode == 0 and "landing: open" in status.stdout and "(current)" in status.stdout, status.stdout
    evidence.append({"case": "land-to-merge seconds (both lands together)", "seconds": seconds,
                     "mergeWaitSeconds": [row["mergeWaitSeconds"] for row in merged]})


def semantic_conflict(fx: Fixture, evidence: list) -> None:
    # Cut from an older main, so its merged tree is new to the gate and its post-merge check takes time.
    unrelated = fx.branch("feat/920-unrelated", {"zeta.txt": "zeta\n"},
                          start=fx.git("rev-list", "--max-parents=0", "origin/main"))
    fast = fx.branch("feat/912-fast-mode", {"config.txt": "mode=fast\n"})
    usage = fx.branch("feat/913-requires-safe-mode", {"usage.txt": "needs=safe\n"})
    for path in (unrelated, fast, usage):
        alone = fx.gate(path, "run")
        assert alone.returncode == 0, alone.stdout  # each passes alone
    # The check of the first merge is still running while the next two land, so one run covers both.
    fx.slow.write_text("3")
    for path in (unrelated, fast, usage):
        landed = fx.land(path)
        assert landed.returncode == 0, landed.stdout + landed.stderr
    fx.slow.write_text("0")
    culprit = fx.tip()
    fx.wait_for_check(240)
    log = fx.check_log()
    events = [json.loads(line) for line in (fx.repo / ".git/work/main/events.jsonl").read_text().splitlines()]
    stops = [e for e in events if e["event"] == "stopped"]
    reverts = [e for e in events if e["event"] == "reverted"]
    github = fx.github()
    evidence.append({"case": "semantic conflict caught after merge, bisected, reverted", "events": events,
                     "comments": github["comments"], "reopened": github["reopened"], "log": log[-4000:]})
    assert stops and stops[-1]["culprit"] == culprit and stops[-1]["shard"] == "unit", stops
    starts = [e for e in events if e["event"] == "check-start" and e["to"] == culprit]
    bisects = [e for e in events if e["event"] == "bisect"]
    assert starts and starts[-1]["merges"] == 2, starts  # coalesced: both merges in one run
    assert [b["failed"] for b in bisects[-1:]] == [False], bisects  # the earlier merge passes alone on main
    assert reverts and any(m["ref"] == f"revert/{culprit[:12]}" for m in github["merges"]), github["merges"]
    assert github["reopened"] == [913] and "bisected" in github["comments"][-1]["body"], github
    state = fx.main_state()
    assert state["stopped"] is None and state["lastPassed"] == fx.tip(), (state, log)
    assert (subprocess.run(["git", "--git-dir", str(fx.remote), "show", "main:usage.txt"], capture_output=True).returncode
            != 0), "the revert removed the culprit's change"


def flagged(fx: Fixture, evidence: list) -> None:
    breaking = fx.branch("feat/914-breaks-alone-on-main", {"usage.txt": "needs=safe\n"})
    alone = fx.gate(breaking, "run")
    assert alone.returncode != 0  # main has mode=fast now, so this branch fails its own check...
    # ...but a branch checked against an older main can still break the newer one.
    old_base = fx.git("rev-list", "--max-parents=0", "origin/main")
    older = fx.branch("feat/915-checked-on-old-main", {"usage.txt": "needs=safe\n"}, start=old_base)
    assert fx.gate(older, "run").returncode == 0
    github = fx.github()
    github["refuse_revert"] = True
    fx.state.write_text(json.dumps(github))
    landed = fx.land(older)
    assert landed.returncode == 0, landed.stdout + landed.stderr
    fx.wait_for_check(240)
    state = fx.main_state()
    assert state["stopped"] and state["stopped"]["revert"]["state"] == "flagged", (state, fx.check_log())
    other = fx.branch("feat/916-unrelated", {"gamma.txt": "gamma\n"})
    refused = fx.land(other)
    evidence.append({"case": "landing refuses while main is broken and the revert could not merge",
                     "stderr": refused.stderr})
    assert refused.returncode != 0 and "landing is stopped" in refused.stderr and "--repair-main" in refused.stderr
    github = fx.github()
    github["refuse_revert"] = False
    fx.state.write_text(json.dumps(github))
    fix = fx.branch("feat/917-safe-mode-again", {"config.txt": "mode=safe\n"})
    repaired = fx.land(fix, "--repair-main")
    assert repaired.returncode == 0, repaired.stdout + repaired.stderr
    fx.wait_for_check(240)
    assert fx.main_state()["stopped"] is None, fx.check_log()
    # The waiting branch was cut from the broken main; it takes the fix, then lands.
    fx.git("fetch", "-q", "origin", cwd=other)
    fx.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "merge", "-q", "--no-edit",
           "origin/main", cwd=other)
    again = fx.land(other)
    evidence.append({"case": "--repair-main lands the fix; the next check reopens landing", "stdout": again.stdout})
    assert again.returncode == 0, again.stdout + again.stderr
    fx.wait_for_check(240)


def environment(fx: Fixture, evidence: list) -> None:
    """A shard that fails on main only because of the check's environment blames no merge:
    it fails on the last main that passed too, so nothing is reverted (#1211)."""
    old_base = fx.git("rev-list", "--max-parents=0", "origin/main")
    path = fx.branch("feat/921-innocent", {"eta.txt": "eta\n"}, start=old_base)
    assert fx.gate(path, "run").returncode == 0
    (fx.base / "broken").write_text("")  # the environment breaks after the branch check
    merges = len(fx.github()["merges"])
    landed = fx.land(path)
    assert landed.returncode == 0, landed.stdout + landed.stderr
    fx.wait_for_check(240)
    state, github = fx.main_state(), fx.github()
    evidence.append({"case": "an environment failure on main blames and reverts nothing", "stopped": state["stopped"],
                     "log": fx.check_log()[-2500:]})
    assert state["stopped"] and state["stopped"].get("predates") and state["stopped"]["culprit"] is None, state
    assert len(github["merges"]) == merges + 1 and 921 not in github["reopened"], github  # only the landing merged
    refused = fx.land(fx.branch("feat/922-waits", {"theta.txt": "theta\n"}))
    assert refused.returncode != 0 and "no merge is blamed" in refused.stderr, refused.stderr
    (fx.base / "broken").unlink()
    rerun = fx.gate(fx.repo, "main-check", timeout=120)
    assert rerun.returncode == 0 and fx.main_state()["stopped"] is None, rerun.stdout + fx.check_log()


def receipts(fx: Fixture, evidence: list) -> None:
    path = fx.branch("feat/918-receipt", {"delta.txt": "delta\n"})
    first = fx.land(path, "--dry-run")
    assert first.returncode == 0 and "nothing to run" not in first.stdout, first.stdout + first.stderr
    fx.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--amend", "-m",
           "reworded, same content", cwd=path)
    reused = fx.land(path, "--dry-run")
    assert reused.returncode == 0 and "covers all 5 shards; nothing to run" in reused.stdout, reused.stdout
    (path / "delta.txt").write_text("changed\n")
    fx.git("add", "-A", cwd=path)
    fx.commit("content change", cwd=path)
    changed = fx.land(path, "--dry-run")
    evidence.append({"case": "receipt reused after a no-op amend, refused after a content change",
                     "reused": reused.stdout, "changed": changed.stdout})
    assert changed.returncode == 0 and "nothing to run" not in changed.stdout and "gate: 5 shards" in changed.stdout


def resume(fx: Fixture, evidence: list) -> None:
    old_base = fx.git("rev-list", "--max-parents=0", "origin/main")
    path = fx.branch("feat/919-resume", {"epsilon.txt": "epsilon\n"}, start=old_base)
    assert fx.gate(path, "run").returncode == 0
    fx.trace.write_text("")
    fx.slow.write_text("1.5")
    landed = fx.land(path)
    assert landed.returncode == 0, landed.stdout + landed.stderr
    deadline = time.monotonic() + 60
    while "worktree:done:1" not in fx.trace.read_text():
        assert time.monotonic() < deadline, fx.check_log()
        time.sleep(0.2)
    runner = fx.main_state()["check"]["pid"]
    os.killpg(os.getpgid(runner), signal.SIGKILL)
    status = fx.gate(fx.repo, "status")
    assert "interrupted" in status.stdout, status.stdout
    fx.slow.write_text("0")
    rerun = fx.gate(fx.repo, "main-check", timeout=120)
    evidence.append({"case": "a killed post-merge check resumes with its passed shards", "status": status.stdout,
                     "rerun": rerun.stdout})
    assert rerun.returncode == 0, rerun.stdout + rerun.stderr
    log = fx.check_log() + rerun.stdout
    assert "slow#1/3: reused pass" in log and "unit: reused pass" in log, log
    assert fx.main_state()["lastPassed"] == fx.tip()


def build_sources(fx: Fixture, evidence: list) -> None:
    """Real build entrypoints refuse before device, signing or Debug lifecycle effects."""
    for name in ("config/ci-toolchain.env", "scripts/tron-ios-device", "scripts/tron-dev", "scripts/test-tron-mac-replace.py",
                 "scripts/tron_mac_replace.py", "scripts/tron_mac_replace_platform.py",
                 "scripts/tron_mac_replace_journal.py", "packages/gateway/package.json",
                 "packages/gateway/package-lock.json", "packages/gateway/src/version.ts"):
        target = fx.repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    fx.git("add", "-A")
    fx.commit("build entrypoints")
    installed = fx.git("rev-parse", "HEAD")
    (fx.repo / "first.txt").write_text("passed change")
    fx.git("add", "-A")
    fx.commit("passed main")
    passed = fx.git("rev-parse", "HEAD")
    (fx.repo / "second.txt").write_text("unchecked change")
    fx.git("add", "-A")
    fx.commit("unchecked main")
    head = fx.git("rev-parse", "HEAD")
    fx.git("push", "-q", "origin", "main")
    state = fx.repo / ".git/work/main/state.json"
    state.parent.mkdir(parents=True)
    state.write_text(json.dumps({"lastPassed": passed}))

    # The replace CLI uses a real payload directory and Git source history, but
    # --plan never launches or replaces anything (not even a fixture Gateway).
    app = fx.base / "Tron.app"
    payload = app / "Contents/Resources/Gateway"
    (payload / "app").mkdir(parents=True)
    import re
    version = (fx.repo / "packages/gateway/src/version.ts").read_text()
    protocol = re.search(r"export const PROTOCOL_VERSION = (\d+);", version)[1]
    minimum = re.search(r"export const MIN_PROTOCOL_VERSION = (\d+);", version)[1]
    (payload / "manifest.json").write_text(json.dumps({"sourceRevision": installed,
        "protocolVersion": protocol, "minProtocolVersion": minimum}))
    for name in ("package.json", "package-lock.json"):
        shutil.copy2(fx.repo / "packages/gateway" / name, payload / "app" / name)
    config = fx.base / "replace.json"
    config.write_text(json.dumps({"home": fx.env["HOME"], "installed": str(app), "label": "fixture",
                                 "port": 1}))
    def cli(*args):
        return subprocess.run(args, cwd=fx.repo, env=fx.env, capture_output=True, text=True, timeout=30)
    def replace_plan():
        return cli(sys.executable, str(fx.repo / "scripts/test-tron-mac-replace.py"),
                   "--fixture", str(config), "--plan", "--json")
    planned = replace_plan()
    assert planned.returncode == 0, planned.stderr
    result = json.loads(planned.stdout)
    assert result["revision"] == passed and result["path"] == "full", result
    source_build = (f"import {{buildSourcePayload}} from {json.dumps((ROOT / 'scripts/gateway-payload-deploy.mjs').as_uri())};"
                    "await buildSourcePayload({paths:{},config:{sourceRoot:process.cwd()}});")
    for command in ((str(fx.repo / "scripts/tron-ios-device"), "share", "--title", "fixture", "--notes", "fixture"),
                    (str(ROOT / "scripts/tron-node"), "exec", "node", "--input-type=module", "-e", source_build),
                    (str(fx.repo / "scripts/tron-dev"), "start"),
                    (str(fx.repo / "scripts/tron-dev"), "restart")):
        refused = cli(*command)
        assert refused.returncode != 0 and "last main that passed" in refused.stderr, refused
    assert not (Path(fx.env["HOME"]) / ".tron-dev").exists(), "refusal must precede Debug state writes"
    evidence.append({"check": "unchecked main: replace builds passed source; share and Debug refuse before effects", "pass": True})

    for invalid in (None, "{broken", "[]", json.dumps({"lastPassed": "missing"}),
                    json.dumps({"lastPassed": "f" * 40})):
        if invalid is None:
            state.unlink()
        else:
            state.write_text(invalid)
        refused = fx.gate(fx.repo, "build-source", "--require-current")
        assert refused.returncode != 0 and "cannot verify main build source" in refused.stderr, refused
        assert replace_plan().returncode != 0
    state.write_text(json.dumps({"lastPassed": passed}))
    fx.git("checkout", "-q", "--detach", head)
    assert fx.gate(fx.repo, "build-source", "--require-current").returncode != 0
    fx.git("checkout", "-q", "main")
    fx.git("update-ref", "-d", "refs/remotes/origin/main")
    assert fx.gate(fx.repo, "build-source", "--require-current").returncode != 0
    fx.git("update-ref", "refs/remotes/origin/main", head)
    fx.git("checkout", "-q", "--orphan", "unrelated")
    fx.commit("unrelated history")
    unrelated = fx.git("rev-parse", "HEAD")
    fx.git("checkout", "-q", "main")
    state.write_text(json.dumps({"lastPassed": unrelated}))
    assert fx.gate(fx.repo, "build-source", "--require-current").returncode != 0
    state.write_text(json.dumps({"lastPassed": head}))
    admitted = fx.gate(fx.repo, "build-source", "--require-current")
    assert admitted.returncode == 0 and json.loads(admitted.stdout)["revision"] == head, admitted
    assert json.loads(replace_plan().stdout)["path"] == "quick"
    (fx.repo / "second.txt").write_text("dirty main")
    assert fx.gate(fx.repo, "build-source", "--require-current").returncode != 0
    fx.git("checkout", "--", "second.txt")
    fx.git("checkout", "-q", "-b", "task")
    state.unlink()
    # Explicit branch iteration remains possible even without a main-check ledger.
    admitted = fx.gate(fx.repo, "build-source", "--require-current")
    assert admitted.returncode == 0 and json.loads(admitted.stdout)["revision"] == head, admitted
    assert json.loads(replace_plan().stdout)["revision"] == head
    evidence.append({"check": "missing or invalid main evidence and dirty main refuse; passed main and explicit branch admit", "pass": True})


def main() -> None:
    evidence: list = []
    artifact = ROOT / "test-results" / "work-mainline.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-build-sources-") as temporary:
            build_sources(Fixture(Path(temporary)), evidence)
        with tempfile.TemporaryDirectory(prefix="tron-work-mainline-") as temporary:
            fx = Fixture(Path(temporary))
            try:
                disjoint(fx, evidence)
                semantic_conflict(fx, evidence)
                flagged(fx, evidence)
                environment(fx, evidence)
                receipts(fx, evidence)
                resume(fx, evidence)
            finally:
                fx.wait_for_check(60)
        print(f"Passed {len(evidence)} landing and post-merge check journeys; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("MAINLINE_FIXTURE") and sys.argv[1:2] in (["api"], ["repo"], ["pr"], ["issue"]):
        fixture_gh()
    else:
        main()
