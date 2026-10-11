#!/usr/bin/env python3
"""Process-level claim-handoff checks with real Git and an isolated gh fixture."""
from __future__ import annotations
import json, os, pty, select, shutil, subprocess, sys, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def run():
    evidence=[]
    artifact=ROOT/"test-results/work-handoff.json"; artifact.parent.mkdir(parents=True,exist_ok=True)
    try:
      with tempfile.TemporaryDirectory(prefix="tron-work-handoff-") as d:
        root=Path(d); repo=root/"repo"; repo.mkdir(); home=root/"home"; home.mkdir(); tmp=root/"tmp"; tmp.mkdir()
        remote=root/"remote.git"; state=root/"gh.json"; gh=root/"gh"
        gh.write_text('#!/usr/bin/env python3\nimport json,os,sys\np=os.environ["FIXTURE"]\ns=json.load(open(p))\na=sys.argv[1:]\nif a[:2]==["repo","view"]: print(json.dumps({"nameWithOwner":"fixture/project","owner":{"login":"fixture"}}))\nelif a[:3]==["issue","view","41"]: print(json.dumps({"state":"OPEN","comments":s["comments"]}))\nelif a[:1]==["api"]: print("\\n".join(s["comments"]))\nelif a[:2]==["issue","comment"]: s["comments"].append(sys.stdin.read()); s["writes"].append("comment"); json.dump(s,open(p,"w"))\nelse: raise SystemExit("unexpected gh: "+repr(a))\n')
        gh.chmod(0o755)
        env={**os.environ,"HOME":str(home),"TMPDIR":str(tmp),"WORK_GH":str(gh),"FIXTURE":str(state),"WORK_SESSION_ID":"new-owner","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":os.devnull,"PYTHONDONTWRITEBYTECODE":"1"}
        def git(cwd,*args): return subprocess.run(["git",*args],cwd=cwd,env=env,check=True,capture_output=True,text=True).stdout.strip()
        git(repo,"init","-b","main"); git(repo,"config","user.name","Fixture"); git(repo,"config","user.email","fixture@example.invalid")
        (repo/".github").mkdir(); shutil.copy(ROOT/".github/work.json",repo/".github/work.json")
        (repo/"scripts").mkdir(); shutil.copy(ROOT/"scripts/personal-info-guard.sh",repo/"scripts/personal-info-guard.sh")
        git(repo,"add",".github/work.json"); git(repo,"commit","-m","base")
        git(remote.parent,"init","--bare",str(remote)); git(repo,"remote","add","origin",str(remote)); git(repo,"push","origin","main")
        git(repo,"checkout","-b","feat/41-fixture"); git(repo,"commit","--allow-empty","-m","Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner")
        git(repo,"push","-u","origin","feat/41-fixture"); git(repo,"checkout","main")
        primary=repo.resolve(); worktree=repo.parent/"tron-worktrees"/"41-fixture"; worktree.parent.mkdir()
        git(repo,"worktree","add",str(worktree),"feat/41-fixture")
        (worktree/"dirty.txt").write_text("keep me\n")
        state.write_text(json.dumps({"comments":[],"writes":[]}))
        cli=ROOT/"tools/work/cli.py"
        def call(*args, input=None): return subprocess.run([sys.executable,str(cli),*args],cwd=worktree if worktree.exists() else repo,env=env,input=input,capture_output=True,text=True,timeout=30)
        before=git(worktree,"rev-parse","HEAD");
        r=call("handoff","41","--session","new-owner","--reason","owner settled")
        evidence.append({"case":"unknown owner refused without writes","exit":r.returncode,"stderr":r.stderr.strip()})
        assert r.returncode and "unknown" in r.stderr and git(worktree,"rev-parse","HEAD")==before and json.loads(state.read_text())["writes"]==[]
        r=call("handoff","41","--session","new-owner","--reason","owner settled","--force-maintainer")
        evidence.append({"case":"force requires TTY","exit":r.returncode,"stderr":r.stderr.strip()})
        assert r.returncode and "interactive terminal" in r.stderr and git(worktree,"rev-parse","HEAD")==before
        assert (worktree/"dirty.txt").read_text()=="keep me\n"
        # A real PTY is required for the maintainer-only override. This journey
        # exercises the CLI, Git push/ref CAS, public audit, dirty preservation,
        # and same-transition retry idempotency without contacting production.
        pid, terminal = pty.fork()
        if pid == 0:
            os.chdir(worktree)
            os.execve(sys.executable, [sys.executable, str(cli), "handoff", "41", "--session", "new-owner",
                "--reason", "fixture takeover", "--force-maintainer"], env)
        output = b""
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and b"> " not in output:
            ready, _, _ = select.select([terminal], [], [], 1)
            if ready:
                try: output += os.read(terminal, 4096)
                except OSError: break
        os.write(terminal, b"HANDOFF #41 FROM old-owner\n")
        while time.monotonic() < deadline:
            ready, _, _ = select.select([terminal], [], [], 1)
            if ready:
                try: output += os.read(terminal, 4096)
                except OSError: break
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited: break
        else:
            os.kill(pid, 9); _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status)
        evidence.append({"case":"TTY force takeover succeeds with audit", "exit":code, "output":output.decode(errors="replace")[-1000:]})
        assert code == 0, output.decode(errors="replace")
        handed = git(worktree,"rev-parse","HEAD")
        assert git(worktree,"rev-parse","origin/feat/41-fixture") == handed
        assert (worktree/"dirty.txt").read_text()=="keep me\n"
        comments=json.loads(state.read_text())["comments"]
        assert len(comments)==1 and "old-owner" in comments[0] and "new-owner" in comments[0] and "fixture takeover" in comments[0] and handed in comments[0]
        writes_before=len(json.loads(state.read_text())["writes"])
        retry=call("handoff","41","--session","new-owner","--reason","ignored retry reason")
        assert retry.returncode == 0, retry.stderr
        assert len(json.loads(state.read_text())["writes"]) == writes_before
        evidence.append({"case":"repeat same transition adds no audit writes", "exit":retry.returncode})
        git(repo,"worktree","remove","--force",str(worktree))
        r=call("handoff","41","--session","new-owner","--reason","owner settled")
        evidence.append({"case":"missing worktree refuses without recreation","exit":r.returncode,"stderr":r.stderr.strip()})
        assert r.returncode and "worktree is missing" in r.stderr and not worktree.exists()
        assert len(json.loads(state.read_text())["writes"]) == writes_before
        print(f"Passed {len(evidence)} handoff journeys; evidence: {artifact}")
    finally: artifact.write_text(json.dumps(evidence,indent=2)+"\n")
if __name__=="__main__": run()
