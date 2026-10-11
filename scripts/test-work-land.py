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
    if args[:2] == ["repo", "view"]:
        print("fixture/project")
        return
    elif args[:2] == ["pr", "list"]:
        response = []
    elif args[:3] == ["api", "-X", "GET"]:
        endpoint = args[3]
        if "pulls?state=open" in endpoint:
            response = [{**pull(7, state["first_head"]), "head": {"sha": state["first_head"],
                          "repo": {"full_name": "fixture/project"}}, "title": "fixture"}]
        elif endpoint.endswith("/pulls/7"):
            observed = state["first_head"] if state["stale_forever"] else state["actual_head"]
            response = {"number": 7, "title": "fixture", "head": {"sha": observed}}
        else:
            raise AssertionError(args)
    elif args[:3] == ["api", "-X", "PATCH"]:
        request = json.load(sys.stdin)
        actual = git(state, "rev-parse", f"refs/heads/{state['branch']}")
        state["actual_head"] = actual
        state["patch_count"] += 1
        if state["patch_count"] == 1:
            # Advance main after the first publication. land must remerge and republish.
            advance_main(state)
            response = pull(7, state["first_head"])
        elif state["foreign_on_second_patch"]:
            foreign_commit(state)
            response = pull(7, git(state, "rev-parse", "refs/heads/feature"))
        elif state["stale_forever"]:
            response = pull(7, state["first_head"])
        else:
            response = pull(7, state["first_head"])
        state["last_title"] = request["title"]
    elif args[:3] == ["api", "-X", "PUT"]:
        request = json.load(sys.stdin)
        state["merge_sha"] = request["sha"]
        response = {"sha": "a" * 40}
    else:
        raise AssertionError(f"Unexpected fixture gh invocation: {args}")
    path.write_text(json.dumps(state))
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
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "WORK_GH": str(Path(__file__).resolve()),
                   "WORK_SESSION_ID": "fixture-owner", "WORK_LAND_FIXTURE": str(root / "github.json"),
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            def run_git(*args):
                return subprocess.run(["git", *args], cwd=repo, env=env, check=True, text=True, capture_output=True).stdout.strip()
            run_git("init", "-b", "main")
            run_git("config", "user.name", "Fixture")
            run_git("config", "user.email", "fixture@example.invalid")
            (repo / ".github").mkdir()
            shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            run_git("add", ".github/work.json", "scripts/personal-info-guard.sh")
            run_git("commit", "-m", "fixture base")
            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
            run_git("remote", "add", "origin", str(remote))
            run_git("push", "origin", "main")
            run_git("checkout", "-b", "feature")
            run_git("commit", "--allow-empty", "-m", "feature change")
            run_git("push", "origin", "HEAD:refs/heads/feature")
            state = {"root": str(root), "repo": str(repo), "remote": str(remote), "branch": "feature", "patch_count": 0,
                     "first_head": run_git("rev-parse", "HEAD"), "actual_head": "", "merge_sha": None,
                     "foreign_on_second_patch": False, "stale_forever": False}
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
        print(f"Passed {len(evidence)} real-CLI land publication assertions; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("WORK_LAND_FIXTURE") and sys.argv[1:2] in (["api"], ["repo"], ["pr"]):
        fixture_gh()
    else:
        run()
