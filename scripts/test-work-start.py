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
        elif "projectsV2(" in query:
            response = {"data": {"repository": {"projectsV2": {"nodes": [{"id": "project", "title": "Tron"}]}}}}
        elif "pullRequests(" in query:
            response = {"data": {"repository": {"pullRequests": {"pageInfo": {"hasNextPage": False}, "nodes": []}}}}
        elif "query($owner" in query:
            response = {"data": {"repository": {"issue": {
                "id": "issue", "number": req["variables"]["number"], "state": state["state"], "title": "Canonical owners for epic",
                "url": "https://example.invalid/issues/841", "labels": {"nodes": [{"name": x} for x in state["labels"]]},
                "blockedBy": {"nodes": state["blockers"]}, "comments": {"nodes": [{"body": b} for b in state["comments"]]},
                "projectItems": {"nodes": [{"id": "item", "project": {"id": "project", "title": "Tron",
                    "field": {"id": "status", "options": [{"id": "progress", "name": "In progress"}]}},
                    "fieldValueByName": {"name": state["status"]}}]}}}}}
        elif "query($project" in query:
            nodes = []
            for number, status, issue_state, labels in state.get("dashboard", []):
                nodes.append({"id": f"item-{number}", "status": {"name": status}, "priority": {"name": "P1"},
                    "content": {"__typename": "Issue", "number": number, "title": f"Dashboard fixture {number}",
                        "url": f"https://example.invalid/issues/{number}", "state": issue_state,
                        "createdAt": "2026-01-01T00:00:00Z", "closedAt": None, "body": "",
                        "repository": {"nameWithOwner": "fixture/project"},
                        "labels": {"nodes": [{"name": label} for label in labels]}, "parent": None,
                        "subIssuesSummary": {"total": 0, "completed": 0}, "blockedBy": {"nodes": []},
                        "comments": {"nodes": []}}})
            response = {"data": {"node": {"items": {"pageInfo": {"hasNextPage": False}, "nodes": nodes}}}}
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
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
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
            state(state="OPEN")
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
            # Read through the real CLI and Git claims, including retained closed
            # work. Project status is advisory, never proof that a worker is live.
            state(dashboard=[[841, "In progress", "OPEN", ["kind:bug"]],
                             [842, "Ready", "OPEN", ["kind:bug"]],
                             [843, "Blocked", "OPEN", ["kind:bug"]],
                             [944, "In progress", "CLOSED", ["kind:bug"]],
                             [845, "In progress", "OPEN", ["epic"]],
                             [846, "In progress", "OPEN", ["kind:bug"]]])
            git("push", "origin", f"{head}:refs/heads/fix/944-retained-closed")
            before = git("ls-remote", "--heads", "origin"), state()["writes"]
            board_json, board_html = root / "dashboard.json", root / "dashboard.html"
            shown = call("dashboard", "--json", str(board_json), "--html", str(board_html))
            assert shown.returncode == 0, evidence[-1]
            board = json.loads(board_json.read_text())
            assert [row["number"] for row in board["in_progress"]] == [841, 846], board
            assert board["in_progress"][0]["branch"] == branch and board["in_progress"][0]["worktree"], board
            assert board["in_progress"][1]["branch"] is None, board
            assert [row["number"] for row in board["ready"]] == [842], board
            assert [row["number"] for row in board["blocked"]] == [843], board
            assert [row["number"] for row in board["epics"]] == [845], board
            assert any(row["branch"] == "fix/944-retained-closed" for row in board["orphans"]["branches"]), board
            assert "Dashboard fixture 841" in board_html.read_text() and "#841 In progress" in shown.stdout
            assert before == (git("ls-remote", "--heads", "origin"), state()["writes"])
            evidence.append({"case": "dashboard reads live and retained claims without mutations", "model": board})
            git("push", "origin", ":refs/heads/fix/944-retained-closed")
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
            # Dependency links inform the worker; they never queue its claim.
            state(labels=[], blockers=[{"number": 42, "state": "OPEN"}])
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
            snapshot = call("status", "--area", "tools/work", "--json")
            assert snapshot.returncode == 0, evidence[-1]
            view = json.loads(snapshot.stdout)
            assert {row["issue"] for row in view["advice"]["overlapping"]} == {841, 843}, view
            assert {row["issue"] for row in view["advice"]["unknown"]} == {842, 846, 847}, view
            git("worktree", "remove", str(worktree))
            git("worktree", "remove", str(root / "tron-worktrees/843-canonical-owners-for-epic"))
            git("worktree", "remove", str(root / "tron-worktrees/845-canonical-owners-for-epic"))
        print(f"Passed integration start journeys; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    fixture_gh() if "WORK_START_FIXTURE" in os.environ else run()
