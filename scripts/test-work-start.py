#!/usr/bin/env python3
"""Exercise claim creation, guarded admission and handoff through real CLI/Git processes."""
from __future__ import annotations

import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from datetime import datetime, timedelta

ROOT = Path(__file__).resolve().parents[1]


def fixture_gh():
    path = Path(os.environ["WORK_START_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[1:]
    response = None
    if args[:2] == ["repo", "view"]:
        print("fixture/project")
        return
    if args[:2] == ["issue", "view"]:
        print(json.dumps({"state": state["state"]}))
        return
    if args[:1] == ["api"] and args[1:2] != ["graphql"]:
        print("\n".join(state["comments"]))
        return
    if args[:2] == ["api", "graphql"]:
        req = json.load(sys.stdin)
        query = req["query"]
        if "mutation" in query:
            state["status"] = "In progress"
            state["writes"].append("status")
            response = {"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "item"}}}}
        elif "query($owner" in query:
            response = {"data": {"repository": {"issue": {
                "id": "issue", "number": req["variables"]["number"], "state": state["state"], "title": "Canonical owners for epic",
                "url": "https://example.invalid/issues/841", "labels": {"nodes": [{"name": x} for x in state["labels"]]},
                "blockedBy": {"nodes": state["blockers"]}, "comments": {"nodes": [{"body": b} for b in state["comments"]]},
                "projectItems": {"nodes": [{"id": "item", "project": {"id": "project", "title": "Tron",
                    "field": {"id": "status", "options": [{"id": "progress", "name": "In progress"}]}},
                    "fieldValueByName": {"name": state["status"]}}]}}}}}
        elif "query($project" in query:
            response = {"data": {"node": {"items": {"pageInfo": {"hasNextPage": False}, "nodes": []}}}}
        else:
            raise AssertionError(query)
    elif args[:2] == ["issue", "comment"]:
        state["comments"].append(sys.stdin.read())
        state["writes"].append("comment")
    else:
        raise AssertionError(args)
    path.write_text(json.dumps(state))
    print(json.dumps(response))


def run():
    artifact = ROOT / "test-results/work-start.json"
    artifact.parent.mkdir(exist_ok=True)
    evidence = []
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-start-") as td:
            root = Path(td)
            repo, home, tmp = (root / name for name in ("repo", "home", "tmp"))
            for directory in (repo, home, tmp):
                directory.mkdir()
            state_path = root / "github.json"
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "WORK_GH": str(Path(__file__).resolve()),
                   "WORK_SESSION_ID": "fixture-owner", "WORK_START_FIXTURE": str(state_path),
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "TRON_HEAVY_DIR": str(root / "heavy")}
            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, env=env, check=True, text=True, capture_output=True).stdout.strip()
            def state(**changes):
                value = json.loads(state_path.read_text())
                value.update(changes)
                state_path.write_text(json.dumps(value))
                return value
            def call(*args):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), *args], cwd=repo,
                                        env=env, capture_output=True, text=True, timeout=30)
                evidence.append({"args": list(args), "exit": result.returncode,
                                 "stdout": result.stdout, "stderr": result.stderr})
                return result
            def refused(expected, *args):
                before = git("ls-remote", "--heads", "origin"), state()["writes"]
                result = call(*args)
                assert result.returncode and expected in result.stderr, evidence[-1]
                assert before == (git("ls-remote", "--heads", "origin"), state()["writes"])
                return result
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (repo / ".github").mkdir()
            shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            git("add", ".")
            git("commit", "-m", "main base")
            git("init", "--bare", str(root / "remote.git"))
            git("remote", "add", "origin", str(root / "remote.git"))
            git("push", "origin", "main")
            git("checkout", "-b", "integration-base")
            (repo / "integration.txt").write_text("preserve integration contents\n")
            git("add", ".")
            git("commit", "-m", "integration base")
            base_head = git("rev-parse", "HEAD")
            git("push", "origin", "integration-base")
            git("checkout", "main")
            state_path.write_text(json.dumps({"state": "OPEN", "status": "Ready", "labels": ["epic"],
                                              "blockers": [], "comments": [], "writes": []}))
            refused("epic", "start", "841")
            state(state="CLOSED")
            refused("closed", "start", "841", "--integration")
            state(state="OPEN", blockers=[{"number": 42, "state": "OPEN"}])
            refused("blocked", "start", "841", "--integration")
            state(blockers=[], labels=["epic", "excluded-fixture"])
            config_path = repo / ".github/work.json"
            config = json.loads(config_path.read_text())
            config["claim"]["excludeLabels"].append("excluded-fixture")
            config_path.write_text(json.dumps(config))
            refused("excluded-fixture", "start", "841", "--integration")
            state(labels=["epic"])
            refused("invalid base", "start", "841", "--integration", "--base", "../bad")
            refused("git fetch", "start", "841", "--integration", "--base", "missing-base")
            refused("repo-relative", "start", "841", "--integration", "--area", "../outside")
            original_scrub = config["verify"]["scrubCommand"]
            config["verify"]["scrubCommand"] = "exit 17"
            config_path.write_text(json.dumps(config))
            refused("privacy guard", "start", "841", "--integration", "--base", "integration-base", "--area", "tools/work")
            config["verify"]["scrubCommand"] = original_scrub
            config_path.write_text(json.dumps(config))
            accepted = call("start", "841", "--integration", "--base", "integration-base",
                            "--area", "tools/work", "--area", "scripts", "--area", "tools/work/")
            assert accepted.returncode == 0, evidence[-1]
            branch = "integration/841-canonical-owners-for-epic"
            worktree = root / "tron-worktrees/841-canonical-owners-for-epic"
            assert worktree.is_dir() and (worktree / "integration.txt").read_text() == "preserve integration contents\n"
            head = git("rev-parse", branch)
            assert git("rev-parse", f"{head}^") == base_head
            receipt = git("show", "-s", "--format=%B", head)
            assert "Work-Claim-Session: fixture-owner" in receipt and "Work-Claim-Base: integration-base" in receipt
            assert len(state()["comments"]) == 1 and "Base: `integration-base`" in state()["comments"][0]
            area_line = next(line for line in receipt.splitlines() if line.startswith("Work-Claim-Areas: "))
            assert json.loads(area_line.split(": ", 1)[1]) == ["scripts", "tools/work"]
            assert "tools/work" in state()["comments"][0] and "scripts" in state()["comments"][0]
            refused("cannot change", "start", "841", "--area", "packages/ios-app")
            resumed = call("start", "841")
            assert resumed.returncode == 0 and "from integration-base" in resumed.stdout, evidence[-1]
            assert git("rev-parse", branch) == head and len(state()["comments"]) == 1
            refused("cannot resume", "start", "841", "--base", "main")
            git("checkout", "integration-base")
            git("commit", "--allow-empty", "-m", "base advances after creation")
            git("push", "origin", "integration-base")
            git("checkout", "main")
            env["WORK_SESSION_ID"] = "successor"
            refused("already claimed", "start", "841", "--integration")
            # The fixture alone types confirmation, never a real claim or live owner.
            master, slave = pty.openpty()
            process = subprocess.Popen([sys.executable, str(ROOT / "tools/work/cli.py"), "handoff", "841",
                                        "--force-maintainer", "--reason", "fixture transfer"], cwd=repo,
                                       env=env, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            transcript = b""
            sent = False
            try:
                deadline = time.monotonic() + 30
                while process.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], .1)[0]:
                        try:
                            transcript += os.read(master, 65536)
                        except OSError:
                            break
                        if not sent and b"Type exactly: HANDOFF #841 FROM fixture-owner" in transcript:
                            os.write(master, b"HANDOFF #841 FROM fixture-owner\n")
                            sent = True
                process.wait(timeout=5)
                evidence.append({"case": "fixture TTY handoff", "exit": process.returncode, "output": transcript.decode()})
                assert sent and process.returncode == 0, evidence[-1]
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
            transfer = git("rev-parse", branch)
            assert git("rev-parse", f"{transfer}^") == head
            assert git("rev-parse", f"{transfer}^{{tree}}") == git("rev-parse", f"{head}^{{tree}}")
            resumed = call("start", "841")
            assert resumed.returncode == 0 and "from integration-base" in resumed.stdout, evidence[-1]
            assert f"work:handoff commit={transfer}" in "\n".join(state()["comments"])
            successor_comment = state()["comments"][-1]
            assert f"Base: `integration-base` at `{base_head}`" in successor_comment, successor_comment
            assert "tools/work" in successor_comment and "scripts" in successor_comment, successor_comment
            assert git("rev-parse", branch) == transfer
            evidence.append({"case": "handoff preserves base and successor admission", "head": transfer})
            # A legacy branch without metadata is not adopted by integration creation.
            git("checkout", "-b", "feat/842-legacy")
            git("push", "origin", "feat/842-legacy")
            git("checkout", "main")
            refused("unknown", "start", "842", "--integration")
            # Local-only manual branches also cannot be silently adopted.
            git("branch", "integration/844-canonical-owners-for-epic")
            refused("local branch", "start", "844", "--integration")
            # The ordinary non-epic path still creates an owned task branch.
            state(labels=[])
            ordinary = call("start", "843", "--area", "tools/work/nested")
            assert ordinary.returncode == 0 and "feat/843-" in ordinary.stdout, evidence[-1]
            assert "overlap #841" in ordinary.stdout and "overlap unknown: #842" in ordinary.stdout, evidence[-1]
            disjoint = call("start", "845", "--area", "tools/workshop")
            assert disjoint.returncode == 0 and "overlap #841" not in disjoint.stdout, evidence[-1]
            assert "overlap #843" not in disjoint.stdout and "overlap unknown: #842" in disjoint.stdout, evidence[-1]
            # Canonical but damaged creation receipts remain unknown, not disjoint.
            for number, damaged in ((846, "not-json"), (847, "false")):
                message = f"claim\n\nWork-Claim-Issue: {number}\nWork-Claim-Session: successor\nWork-Claim-Base: main\nWork-Claim-Areas: {damaged}\n"
                bad = git("commit-tree", git("rev-parse", "HEAD^{tree}"), "-p", "HEAD", "-m", message)
                git("push", "origin", f"{bad}:refs/heads/feat/{number}-unreadable")
                refused("unknown/unreadable", "start", str(number), "--area", "tools/work")
            locker = subprocess.Popen([sys.executable, "-c",
                "import pathlib,sys; sys.path.insert(0,sys.argv[1]); import landqueue; "
                "\nwith landqueue.turn(pathlib.Path(sys.argv[2]), 'fixture/landing', 'f'*40, report=sys.stderr):\n"
                " print('holding', flush=True); sys.stdin.readline()",
                str(ROOT / "tools/work"), str(repo)], env=env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert select.select([locker.stdout], [], [], 5)[0], "land holder did not acquire"
                assert locker.stdout.readline().strip() == "holding"
                snapshot = call("status", "--area", "tools/work", "--json")
                assert snapshot.returncode == 0, evidence[-1]
                view = json.loads(snapshot.stdout)
                assert view["land"] == {"running": 1, "waiting": 0}, view
                assert {row["issue"] for row in view["advice"]["overlapping"]} == {841, 843}, view
                assert {row["issue"] for row in view["advice"]["unknown"]} == {842, 846, 847}, view
                assert "reuse unknown" in view["digest"] and "unknown (no recorded waits)" in view["digest"], view
                lock = repo / ".git/work/land/queue/head.lock"
                receipt = lock.read_text()
                try:
                    lock.write_text("{")  # Interrupt the holder's metadata publication, not its flock.
                    unreadable = call("status", "--json")
                    assert unreadable.returncode == 0, evidence[-1]
                    assert json.loads(unreadable.stdout)["land"] == {"running": None, "waiting": None}, evidence[-1]
                finally:
                    lock.write_text(receipt)
                metrics = repo / ".git/work/gate/metrics.jsonl"
                metrics.parent.mkdir(parents=True, exist_ok=True)
                metrics.write_text('{"at":"invalid-time","shard":"fixture"}\n')
                try:
                    partial = call("status", "--json")
                    assert partial.returncode == 0, evidence[-1]
                    partial_view = json.loads(partial.stdout)
                    assert partial_view["land"] == {"running": 1, "waiting": 0}, partial_view
                    assert partial_view["digest"] is None and partial_view["digestError"], partial_view
                finally:
                    metrics.unlink()
            finally:
                try:
                    locker.communicate("\n", timeout=5)
                except subprocess.TimeoutExpired:
                    locker.terminate(); locker.communicate(timeout=5)
            assert locker.returncode == 0
            released = call("status", "--json")
            assert released.returncode == 0 and json.loads(released.stdout)["land"] == {"running": 0, "waiting": 0}, evidence[-1]
            midnight = datetime.fromisoformat(json.loads(released.stdout)["sampledAt"]).replace(hour=0, minute=0, second=0, microsecond=0)
            receipts = [{"at": (midnight - timedelta(hours=1)).isoformat(), "ran": 1, "reused": 0},
                        {"at": midnight.isoformat(), "ran": 0, "reused": 9}]
            (repo / ".git/work/gate/runs.jsonl").write_text("".join(json.dumps(row) + "\n" for row in receipts))
            daily = call("status", "--json")
            assert daily.returncode == 0, evidence[-1]
            daily_view = json.loads(daily.stdout)
            end = datetime.fromisoformat(daily_view["sampledAt"]).replace(hour=0, minute=0, second=0, microsecond=0)
            cohort = [row for row in receipts if end - timedelta(days=1) <= datetime.fromisoformat(row["at"]) < end]
            rate = sum(row["reused"] for row in cohort) / sum(row["ran"] + row["reused"] for row in cohort)
            assert f"reuse {rate:.0%}" in daily_view["digest"], daily_view
            assert datetime.fromisoformat(daily_view["window"][1]) == end - timedelta(microseconds=1), daily_view
            same = subprocess.run([sys.executable, str(ROOT / "tools/work/gate.py"), "report", "--since", daily_view["window"][0],
                                   "--until", daily_view["window"][1], "--digest"], cwd=repo, env=env, capture_output=True, text=True, timeout=20)
            assert same.returncode == 0 and same.stdout.strip() == daily_view["digest"], same.stdout + same.stderr
            git("worktree", "remove", str(worktree))
            git("worktree", "remove", str(root / "tron-worktrees/843-canonical-owners-for-epic"))
            git("worktree", "remove", str(root / "tron-worktrees/845-canonical-owners-for-epic"))
        print(f"Passed integration start journeys; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    fixture_gh() if "WORK_START_FIXTURE" in os.environ else run()
