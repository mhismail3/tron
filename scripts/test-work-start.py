#!/usr/bin/env python3
"""Exercise explicit integration/custom-base creation through the real CLI and Git."""
from __future__ import annotations
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def fixture_gh():
    path = Path(os.environ["WORK_START_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[1:]
    response = None
    if args[:2] == ["repo", "view"]:
        response = "fixture/project"
        print(response)
        return
    if args[:2] == ["api", "graphql"]:
        req = json.load(sys.stdin); query = req["query"]
        if "mutation" in query:
            state["status"] = "In progress"
            state["writes"].append("status")
            response = {"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "item"}}}}
        elif "query($owner" in query:
            response = {"data": {"repository": {"issue": {
                "id": "issue", "number": 841, "state": state["state"], "title": "Canonical owners for epic",
                "url": "https://example.invalid/issues/841", "labels": {"nodes": [{"name": "epic"}]},
                "blockedBy": {"nodes": []}, "comments": {"nodes": [{"body": b} for b in state["comments"]]},
                "projectItems": {"nodes": [{"id": "item", "project": {"id": "project", "title": "Tron",
                    "field": {"id": "status", "options": [{"id": "progress", "name": "In progress"}] }},
                    "fieldValueByName": {"name": state["status"]}}]}}}}}
        elif "query($project" in query:
            response = {"data": {"node": {"items": {"pageInfo": {"hasNextPage": False}, "nodes": []}}}}
        else: raise AssertionError(query)
    elif args[:2] == ["issue", "comment"]:
        state["comments"].append(sys.stdin.read()); state["writes"].append("comment")
    else: raise AssertionError(args)
    path.write_text(json.dumps(state)); print(json.dumps(response))

def run():
    artifact = ROOT / "test-results/work-start.json"; artifact.parent.mkdir(exist_ok=True)
    evidence = []
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-start-") as td:
            root = Path(td); repo = root / "repo"; repo.mkdir(); home=root/"home"; home.mkdir(); tmp=root/"tmp"; tmp.mkdir()
            env={**os.environ,"HOME":str(home),"TMPDIR":str(tmp),"WORK_GH":str(Path(__file__).resolve()),
                 "WORK_SESSION_ID":"fixture-owner","WORK_START_FIXTURE":str(root/"github.json"),
                 "PYTHONDONTWRITEBYTECODE":"1","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":os.devnull}
            def git(*args): return subprocess.run(["git",*args],cwd=repo,env=env,check=True,text=True,capture_output=True).stdout.strip()
            git("init","-b","main"); git("config","user.name","Fixture"); git("config","user.email","fixture@example.invalid")
            git("commit","--allow-empty","-m","main base")
            remote=root/"remote.git"; git("init","--bare",str(remote)); git("remote","add","origin",str(remote)); git("push","origin","main")
            # An unrelated base verifies that the receipt does not falsely call it main.
            git("checkout","--orphan","integration-base"); git("commit","--allow-empty","-m","integration base"); git("push","origin","integration-base"); git("checkout","main")
            (repo/".github").mkdir(); shutil.copy(ROOT/".github/work.json",repo/".github/work.json")
            (repo/"scripts").mkdir(); shutil.copy(ROOT/"scripts/personal-info-guard.sh",repo/"scripts/personal-info-guard.sh")
            Path(env["WORK_START_FIXTURE"]).write_text(json.dumps({"state":"OPEN","status":"Ready","comments":[],"writes":[]}))
            def start(*opts):
                r=subprocess.run([sys.executable,str(ROOT/"tools/work/cli.py"),"start","841",*opts],cwd=repo,env=env,capture_output=True,text=True,timeout=30)
                evidence.append({"args":list(opts),"exit":r.returncode,"stdout":r.stdout,"stderr":r.stderr})
                return r
            # Prove the original CLI cannot make this claim: ordinary start refuses
            # the epic and its parser has no supported integration creation option.
            denied=start()
            assert denied.returncode != 0 and "epic" in denied.stderr, evidence[-1]
            baseline = root / "baseline"
            baseline.mkdir()
            archive=subprocess.run(["git","archive","049d88af9","tools/work"],cwd=ROOT,check=True,capture_output=True).stdout
            subprocess.run(["tar","-x","-C",str(baseline)],input=archive,check=True)
            old=subprocess.run([sys.executable,str(baseline/"tools/work/cli.py"),"start","841","--integration","--base","integration-base"],cwd=repo,env=env,capture_output=True,text=True,timeout=30)
            evidence.append({"case":"baseline explicit integration","exit":old.returncode,"stderr":old.stderr})
            assert old.returncode != 0 and "unrecognized arguments" in old.stderr, evidence[-1]
            accepted=start("--integration","--base","integration-base")
            assert accepted.returncode == 0, evidence[-1]
            state=json.loads(Path(env["WORK_START_FIXTURE"]).read_text())
            assert len(state["comments"]) == 1 and "Base: `integration-base`" in state["comments"][0]
            assert "integration/841-canonical-owners-for-epic" in accepted.stdout
            worktree=root / "tron-worktrees" / "841-canonical-owners-for-epic"
            # Root setting resolves relative to primary; remove through Git before temp cleanup.
            assert worktree.exists()
            git("worktree","remove","--force",str(worktree))
            claim=subprocess.run(["git","show","-s","--format=%B","origin/integration/841-canonical-owners-for-epic"],cwd=repo,env=env,text=True,capture_output=True,check=True).stdout
            assert "Work-Claim-Base: integration-base" in claim
            evidence.append({"case":"claim receipt","base":"integration-base","trailers":claim.splitlines()[-3:]})
        print(f"Passed integration start journeys; evidence: {artifact}")
    finally: artifact.write_text(json.dumps(evidence,indent=2)+"\n")
if __name__ == "__main__":
    fixture_gh() if "WORK_START_FIXTURE" in os.environ else run()
