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
# A pull request projection GitHub has not caught up on yet.
STALE = "f" * 40


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
            observed = STALE if state["stale_forever"] else state["actual_head"]
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
        if state.get("advance_on_patch"):
            # Main moves while the head is being published; the projection is stale once.
            advance_main(state)
            response = pull(7, STALE)
        elif state.get("remote_unavailable_on_patch"):
            # Lose only this fixture's remote transport after publication, not its data.
            git(state, "remote", "set-url", "origin", str(Path(state["root"]) / "unavailable.git"))
            response = pull(7, actual)
        elif state["foreign_on_patch"]:
            foreign_commit(state)
            response = pull(7, git(state, "rev-parse", f"refs/heads/{state['branch']}"))
        elif state["stale_forever"]:
            response = pull(7, STALE)
        else:
            response = pull(7, actual)
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
    subprocess.run(["git", "-C", str(clone), "commit", "-m", "advance main"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(clone), "push", "origin", "main"], check=True, capture_output=True)
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


def wait_for_main_check(repo: Path, env: dict) -> None:
    """Each merge starts the post-merge check in the background; join it before the fixture goes."""
    lock = repo / ".git/work/main/check.lock"
    waiter = repo / ".git/work/main/waiter.lock"
    import fcntl, time
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        busy = False
        for path in (waiter, lock):
            if path.exists():
                with path.open("a+") as handle:
                    try:
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        fcntl.flock(handle, fcntl.LOCK_UN)
                    except BlockingIOError:
                        busy = True
        if not busy:
            time.sleep(0.5)  # a runner just spawned may not hold its lock yet
            if not any(_held(path) for path in (waiter, lock)):
                return
        time.sleep(0.2)
    raise AssertionError("the post-merge check did not finish")


def _held(path: Path) -> bool:
    import fcntl
    if not path.exists():
        return False
    with path.open("a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def review_export(repo: Path, root: Path, env: dict, evidence: list) -> None:
    """A reviewer in a separate clone can reconstruct exactly the committed tree."""
    def git(cwd, *args):
        return subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True, check=True).stdout.strip()
    author, reviewer, patch = root / "author", root / "reviewer", root / "review.patch"
    git(repo, "worktree", "add", "-b", "feat/review-evidence", str(author), "origin/main")
    (author / "review.txt").write_text("committed review evidence\n")
    (author / "binary.bin").write_bytes(bytes(range(256)))
    git(author, "add", "review.txt", "binary.bin")
    git(author, "commit", "-m", "review candidate")
    head, tree = git(author, "rev-parse", "HEAD"), git(author, "rev-parse", "HEAD^{tree}")
    command = [sys.executable, str(ROOT / "tools/work/cli.py"), "review-export", "--output", str(patch)]
    exported = subprocess.run(command, cwd=author, env=env, capture_output=True, text=True, timeout=20)
    assert exported.returncode == 0, exported.stdout + exported.stderr
    assert f"Head: {head}" in patch.read_text() and f"Tree: {tree}" in patch.read_text()
    git(root, "clone", str(repo), str(reviewer))
    base = git(author, "merge-base", "origin/main", "HEAD")
    git(reviewer, "checkout", "--detach", base)
    git(reviewer, "apply", "--index", str(patch))
    assert git(reviewer, "write-tree") == tree, "export must reconstruct the exact committed tree, including binary content"
    assert (reviewer / "binary.bin").read_bytes() == bytes(range(256))
    original = patch.read_bytes()
    refused = subprocess.run(command, cwd=author, env=env, capture_output=True, text=True)
    assert refused.returncode != 0 and patch.read_bytes() == original, "never overwrite an existing review artifact"
    (author / "review.txt").write_text("uncommitted change\n")
    dirty = subprocess.run([*command[:-1], str(root / "dirty.patch")], cwd=author, env=env, capture_output=True, text=True)
    assert dirty.returncode != 0 and not (root / "dirty.patch").exists()
    assert (author / "review.txt").read_text() == "uncommitted change\n"
    git(author, "checkout", "--", "review.txt")
    invalid = subprocess.run([*command[:-1], str(root / "invalid.patch"), "--base", "no-such-ref"],
                             cwd=author, env=env, capture_output=True, text=True)
    assert invalid.returncode != 0 and not (root / "invalid.patch").exists()
    evidence.append({"case": "committed review export reconstructs its tree in an independent clone; dirty and invalid base refuse",
                     "head": head, "tree": tree, "base": base, "stdout": exported.stdout})
    git(repo, "worktree", "remove", str(author))


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
            policy = Path("packages/gateway/src/tron-home-environment-policy.mjs")
            (repo / policy).parent.mkdir(parents=True)
            shutil.copy(ROOT / policy, repo / policy)
            catalog = json.loads((ROOT / "tools/work/gate-catalog.json").read_text())
            catalog.pop("ciSteps", None)
            catalog["steps"] = [step for step in catalog["steps"] if step["id"] in ("repo.privacy", "repo.whitespace")]
            catalog["steps"].append({"id": "scoped", "trigger": {"always": True},
                "command": 'sleep 0.2; echo scoped >> "$SCOPED_TRACE"', "inputs": [".node-version"],
                "budgetSeconds": 5, "timeoutSeconds": 10, "class": "light", "expectedRssMb": 10,
                "pass": "exit 0", "tier": "L1", "unlocks": "land"})
            catalog_path = root / "catalog.json"
            catalog_path.write_text(json.dumps(catalog))
            env.update(TRON_GATE_CATALOG=str(catalog_path), SCOPED_TRACE=str(root / "scoped-trace"))
            run_git("add", ".github/work.json", "scripts", ".node-version", "packages")
            run_git("commit", "-m", "fixture base")
            # The remote HEAD is part of this fixture, not the caller's Git defaults.
            subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(remote)], check=True, capture_output=True)
            run_git("remote", "add", "origin", str(remote))
            run_git("push", "origin", "main")
            run_git("checkout", "-b", "feature")
            run_git("commit", "--allow-empty", "-m", "feature change")
            run_git("push", "origin", "HEAD:refs/heads/feature")
            review_export(repo, root, env, evidence)
            state = {"root": str(root), "repo": str(repo), "remote": str(remote), "branch": "feature", "patch_count": 0,
                     "first_head": run_git("rev-parse", "HEAD"), "actual_head": "", "merge_sha": None,
                     "foreign_on_patch": False, "stale_forever": False, "advance_on_patch": True, "events": [], "draft": False,
                     "ready_refused": False, "ready_ignored": False, "sub_issue_pages": [[]]}
            (root / "github.json").write_text(json.dumps(state))
            summary = root / "summary.md"
            summary.write_text("Safely publish the verified head.\n")
            command = [sys.executable, str(ROOT / "tools/work/cli.py"), "land", "--summary-file", str(summary)]
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=90)
            evidence.append({"case": "main advanced during publication; the head still merges cleanly, so it lands "
                             "without re-verifying or merging main into the branch", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode == 0, evidence[-1]
            state = json.loads((root / "github.json").read_text())
            assert state["patch_count"] == 1 and state["merge_sha"] == state["actual_head"]
            assert "merged: " in result.stdout
            # The land ledger (#1103) records each step with its owner session and the verified counts.
            ledger_path = repo / ".git/work/land/events.jsonl"
            rows = [json.loads(line) for line in ledger_path.read_text().splitlines()]
            events = [row["event"] for row in rows]
            evidence.append({"case": "land ledger records the landing", "events": rows})
            assert events == ["start", "verified", "merged", "finished"], events
            verified = [row for row in rows if row["event"] == "verified"]
            assert verified[0]["ok"] is True and (verified[0]["ran"], verified[0]["reused"]) == (3, 0), verified
            assert verified[0]["receipt"] == run_git("rev-parse", "HEAD^{tree}"), verified
            assert rows[-2]["head"] == state["merge_sha"] and all(row["session"] == "fixture-owner" for row in rows), rows
            assert rows[-2]["mainSyncs"] == 0 and rows[-2]["mergeWaitSeconds"] < 5, rows[-2]
            assert (root / "scoped-trace").read_text().splitlines() == ["scoped"]
            def sync_report():
                readback = subprocess.run([sys.executable, str(ROOT / "tools/work/gate.py"), "report", "--since", "1h", "--json"],
                                          cwd=repo, env=env, capture_output=True, text=True, timeout=20)
                assert readback.returncode == 0, readback.stderr
                return json.loads(readback.stdout)["landing"]["mainSyncs"]
            assert sync_report() == {"measured": 1, "unmeasured": 0, "twoOrMore": 0, "toolLandingsShareTwoOrMore": 0.0}
            wait_for_main_check(repo, env)

            # Recreate the published feature branch and verify that a genuine remote move refuses.
            # Separate journey uses a fresh fixture to retain the first boundary's merge evidence.
            evidence.append({"case": "publication used exact current remote SHA", "merged_sha": state["merge_sha"],
                             "published_sha": state["actual_head"]})

            # A second independent branch moves remotely during publication and must not merge.
            run_git("checkout", "-b", "feature-foreign", "origin/main")
            run_git("commit", "--allow-empty", "-m", "foreign-control")
            run_git("push", "origin", "HEAD:refs/heads/feature-foreign")
            state.update({"branch": "feature-foreign", "patch_count": 0, "first_head": run_git("rev-parse", "HEAD"),
                          "actual_head": "", "merge_sha": None, "foreign_on_patch": True, "advance_on_patch": False})
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
                          "actual_head": "", "merge_sha": None, "foreign_on_patch": False,
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
                          "stale_forever": False, "remote_unavailable_on_patch": True})
            (root / "github.json").write_text(json.dumps(state))
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=90)
            evidence.append({"case": "remote observation failure refuses with uncertainty", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode != 0 and "could not confirm remote branch" in result.stderr, evidence[-1]
            assert "publication state is uncertain" in result.stderr
            assert json.loads((root / "github.json").read_text())["merge_sha"] is None

            # Draft and epic journeys. Each branch is published once without a base advance,
            # so the recorded events are exactly the land writes under test.
            # The unavailable-remote journey repointed origin at a missing path; restore it for these cases.
            run_git("remote", "set-url", "origin", str(remote))

            def land_case(branch: str, extra: list, **overrides) -> tuple:
                run_git("checkout", "-b", branch, "origin/main")
                run_git("commit", "--allow-empty", "-m", f"{branch} change")
                run_git("push", "origin", f"HEAD:refs/heads/{branch}")
                case = {"root": str(root), "repo": str(repo), "remote": str(remote), "branch": branch,
                        "patch_count": 0, "first_head": run_git("rev-parse", "HEAD"), "actual_head": "",
                        "merge_sha": None, "foreign_on_patch": False, "stale_forever": False,
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
            (repo / "untracked").unlink()
            wait_for_main_check(repo, env)
        print(f"Passed {len(evidence)} real-CLI land publication and ready/epic assertions; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("WORK_LAND_FIXTURE") and sys.argv[1:2] in (["api"], ["repo"], ["pr"]):
        fixture_gh()
    else:
        run()
