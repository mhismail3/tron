#!/usr/bin/env python3
"""Exercise work land head publication through the real CLI, Git and a process-level gh fixture."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def fixture_gh() -> None:
    path = Path(os.environ["WORK_LAND_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[1:]
    response = None
    refusal = None
    if args[:2] == ["repo", "view"]:
        print("fixture/project")
        return
    elif args[:2] == ["pr", "list"]:
        response = []
    elif args[:2] == ["api", "graphql"]:
        query = json.load(sys.stdin)["query"]
        assert "markPullRequestReadyForReview" in query, query
        state["events"].append("ready-mutation")
        if state["ready_refused"]:
            refusal = "GraphQL: Pull request is not in a state that can be marked ready"
        else:
            if not state["ready_ignored"]:
                state["draft"] = False
            response = {"data": {"markPullRequestReadyForReview": {"pullRequest": {"isDraft": state["draft"]}}}}
    elif args[:3] == ["api", "--paginate", "--slurp"]:
        assert args[3].endswith("/sub_issues?per_page=100"), args
        response = state["sub_issue_pages"]
    elif args[:3] == ["api", "-X", "GET"]:
        endpoint = args[3]
        if "pulls?state=open" in endpoint:
            response = [{**pull(7, state["first_head"]), "head": {"sha": state["first_head"],
                          "repo": {"full_name": "fixture/project"}}, "title": "fixture"}]
        elif endpoint.endswith("/pulls/7"):
            observed = state["first_head"] if state["stale_forever"] else state["actual_head"]
            response = {"number": 7, "title": "fixture", "head": {"sha": observed}}
        elif "/issues/" in endpoint:
            response = {"number": int(endpoint.rsplit("/", 1)[1]), "title": "Fixture claimed issue",
                        "state": "open", "labels": []}
        else:
            raise AssertionError(args)
    elif args[:3] == ["api", "-X", "PATCH"] and "/issues/" in args[3]:
        request = json.load(sys.stdin)
        state["events"].append("issue-patch")
        response = {"number": int(args[3].rsplit("/", 1)[1]), "state": request.get("state", "open")}
    elif args[:3] == ["api", "-X", "PATCH"]:
        request = json.load(sys.stdin)
        actual = git(state, "rev-parse", f"refs/heads/{state['branch']}")
        state["actual_head"] = actual
        state["patch_count"] += 1
        state["events"].append("pull-patch")
        if state["patch_count"] == 1:
            # Advance main after the first publication. land must remerge and republish.
            advance_main(state)
            response = pull(7, state["first_head"])
        elif state.get("remote_unavailable_on_second_patch"):
            # Lose only this fixture's remote transport after publication, not its data.
            git(state, "remote", "set-url", "origin", str(Path(state["root"]) / "unavailable.git"))
            response = pull(7, actual)
        elif state["foreign_on_second_patch"]:
            foreign_commit(state)
            response = pull(7, git(state, "rev-parse", "refs/heads/feature"))
        elif state["stale_forever"]:
            response = pull(7, state["first_head"])
        else:
            response = pull(7, state["first_head"])
        state["last_title"] = request["title"]
    elif args[:3] == ["api", "-X", "POST"] and args[3].endswith("/actions/workflows/ci.yml/dispatches"):
        request = json.load(sys.stdin)
        state["events"].append("ci-dispatch")
        state["dispatch_ref"] = request["ref"]
    elif args[:3] == ["api", "-X", "PUT"]:
        request = json.load(sys.stdin)
        state["events"].append("merge")
        if state["draft"]:
            # GitHub refuses a squash merge of a draft pull request.
            refusal = "HTTP 405: Pull request is still a draft"
        else:
            state["merge_sha"] = request["sha"]
            response = {"sha": "a" * 40}
    else:
        raise AssertionError(f"Unexpected fixture gh invocation: {args}")
    if isinstance(response, dict) and "head" in response:
        response = {**response, "draft": state["draft"], "node_id": "PR_fixture_7"}
    elif isinstance(response, list) and response and isinstance(response[0], dict) and "head" in response[0]:
        response = [{**item, "draft": state["draft"], "node_id": "PR_fixture_7"} for item in response]
    path.write_text(json.dumps(state))
    if refusal:
        print(f"gh: {refusal}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(response))


def pull(number: int, head: str) -> dict:
    return {"number": number, "title": "fixture", "head": {"sha": head}}


def git(state: dict, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=state["repo"], text=True, capture_output=True, check=True)
    return completed.stdout.strip()


def advance_main(state: dict) -> None:
    clone = Path(state["root"]) / f"advancer-{state['patch_count']}"
    subprocess.run(["git", "clone", "-q", state["remote"], str(clone)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(clone), "config", "user.name", "Fixture"], check=True)
    subprocess.run(["git", "-C", str(clone), "config", "user.email", "fixture@example.invalid"], check=True)
    (clone / "main-advance").write_text("advanced\n")
    subprocess.run(["git", "-C", str(clone), "add", "main-advance"], check=True)
    subprocess.run(["git", "-C", str(clone), "commit", "--allow-empty", "-m", "advance main"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(clone), "push", "origin", "main"], check=True, capture_output=True)
    state["first_head"] = git(state, "rev-parse", f"refs/heads/{state['branch']}")
    shutil.rmtree(clone)


def foreign_commit(state: dict) -> None:
    clone = Path(state["root"]) / "foreigner"
    subprocess.run(["git", "clone", "-q", state["remote"], str(clone)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(clone), "config", "user.name", "Fixture"], check=True)
    subprocess.run(["git", "-C", str(clone), "config", "user.email", "fixture@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(clone), "checkout", "-q", state["branch"]], check=True)
    (clone / "foreign").write_text("foreign\n")
    subprocess.run(["git", "-C", str(clone), "add", "foreign"], check=True)
    subprocess.run(["git", "-C", str(clone), "commit", "-m", "foreign push"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(clone), "push", "origin", state["branch"]], check=True, capture_output=True)


def run() -> None:
    evidence = []
    artifact = ROOT / "test-results" / "work-land.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-land-") as temporary:
            root = Path(temporary)
            repo, remote = root / "repo", root / "remote.git"
            repo.mkdir()
            home, tmp = root / "home", root / "tmp"
            home.mkdir()
            tmp.mkdir()
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "TRON_HEAVY_DIR": str(tmp / "heavy"), "WORK_GH": str(Path(__file__).resolve()),
                   "WORK_SESSION_ID": "fixture-owner", "WORK_LAND_FIXTURE": str(root / "github.json"),
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "NVM_DIR": os.environ.get("NVM_DIR", str(Path.home() / ".nvm"))}
            def run_git(*args):
                return subprocess.run(["git", *args], cwd=repo, env=env, check=True, text=True, capture_output=True).stdout.strip()
            run_git("init", "-b", "main")
            run_git("config", "user.name", "Fixture")
            run_git("config", "user.email", "fixture@example.invalid")
            (repo / ".github").mkdir()
            shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            shutil.copy(ROOT / "scripts/tron-node", repo / "scripts/tron-node")
            shutil.copy(ROOT / ".node-version", repo / ".node-version")
            run_git("add", ".github/work.json", "scripts", ".node-version")
            run_git("commit", "-m", "fixture base")
            # The remote HEAD is part of this fixture, not the caller's Git defaults.
            subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(remote)], check=True, capture_output=True)
            run_git("remote", "add", "origin", str(remote))
            run_git("push", "origin", "main")
            run_git("checkout", "-b", "feature")
            run_git("commit", "--allow-empty", "-m", "feature change")
            run_git("push", "origin", "HEAD:refs/heads/feature")
            state = {"root": str(root), "repo": str(repo), "remote": str(remote), "branch": "feature", "patch_count": 0,
                     "first_head": run_git("rev-parse", "HEAD"), "actual_head": "", "merge_sha": None,
                     "foreign_on_second_patch": False, "stale_forever": False, "events": [], "draft": False,
                     "ready_refused": False, "ready_ignored": False, "sub_issue_pages": [[]]}
            (root / "github.json").write_text(json.dumps(state))
            summary = root / "summary.md"
            summary.write_text("Safely publish the verified head.\n")
            command = [sys.executable, str(ROOT / "tools/work/cli.py"), "land", "--summary-file", str(summary)]
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=90)
            evidence.append({"case": "main advanced; stale PATCH projection corrected by PR read", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode == 0, evidence[-1]
            state = json.loads((root / "github.json").read_text())
            assert state["patch_count"] == 2 and state["merge_sha"] == state["actual_head"]
            assert "merged: " in result.stdout
            # The land ledger (#1103) records each step with its owner session and the verified counts.
            ledger_path = repo / ".git/work/land/events.jsonl"
            rows = [json.loads(line) for line in ledger_path.read_text().splitlines()]
            events = [row["event"] for row in rows]
            evidence.append({"case": "land ledger records the landing", "events": rows})
            assert events[0] == "start" and events[-2:] == ["merged", "finished"], events
            verified = [row for row in rows if row["event"] == "verified"]
            assert verified and all(row["ok"] is True and "ran" in row and "reused" in row for row in verified), verified
            assert rows[-2]["head"] == state["merge_sha"] and all(row["session"] == "fixture-owner" for row in rows), rows
            # Main advanced during publication: the loop-back and the second merge of main are recorded.
            assert events.count("loop-back") == 1 and "base-merged" in events, events
            assert rows[-2]["mainSyncs"] == 1, rows[-2]
            def sync_report():
                readback = subprocess.run([sys.executable, str(ROOT / "tools/work/gate.py"), "report", "--since", "1h", "--json"],
                                          cwd=repo, env=env, capture_output=True, text=True, timeout=20)
                assert readback.returncode == 0, readback.stderr
                return json.loads(readback.stdout)["landing"]["mainSyncs"]
            assert sync_report() == {"measured": 1, "unmeasured": 0, "twoOrMore": 0, "toolLandingsShareTwoOrMore": 0.0}
            original_ledger = ledger_path.read_text()
            try:
                legacy = [{key: value for key, value in row.items() if key != "mainSyncs"} for row in rows]
                ledger_path.write_text("".join(json.dumps(row) + "\n" for row in legacy))
                assert sync_report() == {"measured": 0, "unmeasured": 1, "twoOrMore": 0, "toolLandingsShareTwoOrMore": None}
            finally:
                ledger_path.write_text(original_ledger)

            # Recreate the published feature branch and verify that a genuine remote move refuses.
            # Separate journey uses a fresh fixture to retain the first boundary's merge evidence.
            evidence.append({"case": "publication used exact current remote SHA", "merged_sha": state["merge_sha"],
                             "published_sha": state["actual_head"]})

            # A second independent branch moves remotely during publication and must not merge.
            run_git("checkout", "-b", "feature-foreign", "origin/main")
            run_git("commit", "--allow-empty", "-m", "foreign-control")
            run_git("push", "origin", "HEAD:refs/heads/feature-foreign")
            state.update({"branch": "feature-foreign", "patch_count": 0, "first_head": run_git("rev-parse", "HEAD"),
                          "actual_head": "", "merge_sha": None, "foreign_on_second_patch": True})
            (root / "github.json").write_text(json.dumps(state))
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=90)
            evidence.append({"case": "foreign branch move is refused", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode != 0 and "branch moved after land pushed it" in result.stderr, evidence[-1]
            state = json.loads((root / "github.json").read_text())
            assert state["merge_sha"] is None
            failed = json.loads(ledger_path.read_text().splitlines()[-1])
            assert failed["event"] == "failed" and failed["branch"] == "feature-foreign" and "moved" in failed["detail"], failed

            run_git("checkout", "-b", "feature-uncertain", "origin/main")
            run_git("commit", "--allow-empty", "-m", "uncertain-control")
            run_git("push", "origin", "HEAD:refs/heads/feature-uncertain")
            state.update({"branch": "feature-uncertain", "patch_count": 0, "first_head": run_git("rev-parse", "HEAD"),
                          "actual_head": "", "merge_sha": None, "foreign_on_second_patch": False,
                          "stale_forever": True})
            (root / "github.json").write_text(json.dumps(state))
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=90)
            evidence.append({"case": "persistent stale PR projection reports uncertainty", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode != 0 and "publication state is uncertain" in result.stderr, evidence[-1]
            assert "someone else pushed" not in result.stderr
            assert json.loads((root / "github.json").read_text())["merge_sha"] is None

            run_git("checkout", "-b", "feature-unavailable", "origin/main")
            run_git("commit", "--allow-empty", "-m", "unavailable-control")
            run_git("push", "origin", "HEAD:refs/heads/feature-unavailable")
            state.update({"branch": "feature-unavailable", "patch_count": 0,
                          "first_head": run_git("rev-parse", "HEAD"), "actual_head": "", "merge_sha": None,
                          "stale_forever": False, "remote_unavailable_on_second_patch": True})
            (root / "github.json").write_text(json.dumps(state))
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=90)
            evidence.append({"case": "remote observation failure refuses with uncertainty", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode != 0 and "could not confirm remote branch" in result.stderr, evidence[-1]
            assert "publication state is uncertain" in result.stderr
            assert json.loads((root / "github.json").read_text())["merge_sha"] is None

            # Draft and epic journeys. Each branch is published once without a base advance (patch_count starts at 1),
            # so the recorded events are exactly the land writes under test.
            # The unavailable-remote journey repointed origin at a missing path; restore it for these cases.
            run_git("remote", "set-url", "origin", str(remote))

            def land_case(branch: str, extra: list, **overrides) -> tuple:
                run_git("checkout", "-b", branch, "origin/main")
                run_git("commit", "--allow-empty", "-m", f"{branch} change")
                run_git("push", "origin", f"HEAD:refs/heads/{branch}")
                case = {"root": str(root), "repo": str(repo), "remote": str(remote), "branch": branch,
                        "patch_count": 1, "first_head": run_git("rev-parse", "HEAD"), "actual_head": "",
                        "merge_sha": None, "foreign_on_second_patch": False, "stale_forever": False,
                        "events": [], "draft": False, "ready_refused": False, "ready_ignored": False,
                        "sub_issue_pages": [[]], **overrides}
                (root / "github.json").write_text(json.dumps(case))
                completed = subprocess.run([*command, *extra], cwd=repo, env=env, capture_output=True, text=True, timeout=90)
                return completed, json.loads((root / "github.json").read_text()), case["first_head"]

            completed, after, _ = land_case("feat/866-draft-refused", [], draft=True)
            evidence.append({"case": "draft without --ready refuses before merge", "exit": completed.returncode,
                             "stdout": completed.stdout, "stderr": completed.stderr, "events": after["events"]})
            assert completed.returncode != 0 and "--ready" in completed.stderr, evidence[-1]
            assert "merge" not in after["events"] and "ready-mutation" not in after["events"], evidence[-1]
            assert "issue-patch" not in after["events"] and after["draft"] is True, evidence[-1]

            completed, after, head = land_case("feature-ready", ["--ready"], draft=True)
            evidence.append({"case": "--ready marks the draft ready, then merges the verified head", "exit": completed.returncode,
                             "stdout": completed.stdout, "stderr": completed.stderr, "events": after["events"]})
            assert completed.returncode == 0 and "merged: " in completed.stdout, evidence[-1]
            assert after["events"].index("ready-mutation") < after["events"].index("merge"), evidence[-1]
            assert after["merge_sha"] == head and after["draft"] is False, evidence[-1]
            audit = (repo / ".git" / "work" / "github-writes.jsonl").read_text()
            assert '"operation":"graphql.mutation"' in audit, audit

            completed, after, _ = land_case("feature-ready-refused", ["--ready"], draft=True, ready_refused=True)
            evidence.append({"case": "refused ready mutation merges nothing", "exit": completed.returncode,
                             "stdout": completed.stdout, "stderr": completed.stderr, "events": after["events"]})
            assert completed.returncode != 0 and "refused to mark pull request #7 ready" in completed.stderr, evidence[-1]
            assert "merge" not in after["events"] and after["draft"] is True, evidence[-1]

            completed, after, _ = land_case("feature-ready-ignored", ["--ready"], draft=True, ready_ignored=True)
            evidence.append({"case": "ready mutation that leaves the PR draft merges nothing", "exit": completed.returncode,
                             "stdout": completed.stdout, "stderr": completed.stderr, "events": after["events"]})
            assert completed.returncode != 0 and "still a draft after marking it ready" in completed.stderr, evidence[-1]
            assert "merge" not in after["events"], evidence[-1]

            completed, after, head = land_case(
                "feat/867-epic-open-child", [], sub_issue_pages=[[{"number": 868, "state": "closed"}],
                                                                 [{"number": 869, "state": "open"}]])
            evidence.append({"case": "merge with an open sub-issue leaves the claimed issue open", "exit": completed.returncode,
                             "stdout": completed.stdout, "stderr": completed.stderr, "events": after["events"]})
            assert completed.returncode == 0 and "merged: " in completed.stdout, evidence[-1]
            assert "merge" in after["events"] and "issue-patch" not in after["events"], evidence[-1]
            assert ("issue:   left #867 open: sub-issues #869 remain open; "
                    "close each fulfilled one with work issue close, then the epic") in completed.stdout, evidence[-1]
            completed, after, head = land_case("feat/1032-publish", ["--publish-only"])
            assert completed.returncode == 0 and "published: PR #7" in completed.stdout, completed.stdout + completed.stderr
            assert after["events"] == ["pull-patch"] and after["merge_sha"] is None, after
            assert run_git("ls-remote", "--heads", "origin", "refs/heads/feat/1032-publish").split()[0] == head
            dispatch = [sys.executable, str(ROOT / "tools/work/cli.py"), "ci-dispatch"]
            completed = subprocess.run(dispatch, cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            after = json.loads((root / "github.json").read_text())
            assert completed.returncode == 0 and after["dispatch_ref"] == "feat/1032-publish", completed.stdout + completed.stderr
            assert after["events"] == ["pull-patch", "ci-dispatch"] and after["merge_sha"] is None, after
            evidence.append({"case": "publish-only leaves PR/branch/issue open; explicit dispatch is audited once", "head": head,
                             "stdout": completed.stdout, "events": after["events"]})
            run_git("commit", "--allow-empty", "-m", "unpublished")
            refused = subprocess.run(dispatch, cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            assert refused.returncode != 0 and "published first" in refused.stderr, refused.stderr
            assert json.loads((root / "github.json").read_text())["events"] == after["events"]
            (repo / "untracked").write_text("preserve")
            refused = subprocess.run(dispatch, cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            assert refused.returncode != 0 and "local changes" in refused.stderr, refused.stderr
            evidence.append({"case": "dispatch refuses unpublished or dirty task head before writes", "stderr": refused.stderr})
        print(f"Passed {len(evidence)} real-CLI land publication and ready/epic assertions; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("WORK_LAND_FIXTURE") and sys.argv[1:2] in (["api"], ["repo"], ["pr"]):
        fixture_gh()
    else:
        run()
