#!/usr/bin/env python3
"""Process-level claim-handoff checks with real Git, Gateway WebSocket and gh fixtures."""
from __future__ import annotations
import json, os, pty, select, shutil, subprocess, sys, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
TOKEN = "fixture-local-token-with-at-least-32-bytes"

NODE_FIXTURE = r'''
const fs = require("node:fs");
const http = require("node:http");
const WebSocket = require(process.env.WS_MODULE);
const statePath = process.env.FIXTURE;
const state = () => JSON.parse(fs.readFileSync(statePath, "utf8"));
const server = http.createServer();
const wss = new WebSocket.Server({ server });
wss.on("connection", (socket, request) => {
  if (request.headers.authorization !== `Bearer ${process.env.FIXTURE_TOKEN}`) return socket.close(1008);
  socket.on("message", raw => {
    const frame = JSON.parse(raw.toString());
    if (frame.type === "hello") {
      socket.send(JSON.stringify({type:"hello", protocolVersion:7, minProtocolVersion:7}));
    } else if (frame.type === "request") {
      const current = state(); current.calls.push({method:frame.method, params:frame.params});
      fs.writeFileSync(statePath, JSON.stringify(current));
      let result;
      if (frame.method === "home.taskList") {
        const page = current.pages[frame.params.cursor || "first"] || {items:[]};
        result = page;
      } else if (frame.method === "home.taskStatus") result = current.statuses[frame.params.taskId];
      else throw new Error(`unexpected method ${frame.method}`);
      socket.send(JSON.stringify({type:"response", id:frame.id, ok:true, result}));
    }
  });
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(process.env.PORT_FILE, String(server.address().port)));
process.on("SIGTERM", () => { wss.close(() => server.close(() => process.exit(0))); setTimeout(() => process.exit(0), 1000).unref(); });
'''


def run():
    evidence=[]; artifact=ROOT/"test-results/work-handoff.json"; artifact.parent.mkdir(parents=True,exist_ok=True)
    server=None
    try:
      with tempfile.TemporaryDirectory(prefix="tron-work-handoff-") as d:
        root=Path(d); repo=root/"repo"; repo.mkdir(); home=root/"home"; home.mkdir(); tmp=root/"tmp"; tmp.mkdir()
        tron_home=home/".tron"; (tron_home/"gateway").mkdir(parents=True)
        credential=tron_home/"gateway/local-auth.json"
        credential.write_text(json.dumps({"version":2,"bearerToken":TOKEN,"purpose":"local-wrapper-health","lastUpdated":"2025-01-01T00:00:00.000Z"}))
        credential.chmod(0o600)
        remote=root/"remote.git"; state=root/"gateway.json"; gh=root/"gh"; port_file=root/"port"
        gh.write_text('#!/usr/bin/env python3\nimport json,os,sys\np=os.environ["FIXTURE"]; s=json.load(open(p)); a=sys.argv[1:]\nif a[:2]==["repo","view"]: print(json.dumps({"nameWithOwner":"fixture/project","owner":{"login":"fixture"}}))\nelif a[:3]==["issue","view","41"]: print(json.dumps({"state":"OPEN","comments":s["comments"]}))\nelif a[:1]==["api"]: print("\\n".join(s["comments"]))\nelif a[:2]==["issue","comment"]: s["comments"].append(sys.stdin.read()); s["writes"].append("comment"); json.dump(s,open(p,"w"))\nelse: raise SystemExit("unexpected gh: "+repr(a))\n')
        gh.chmod(0o755)
        env={**os.environ,"HOME":str(home),"TMPDIR":str(tmp),"WORK_GH":str(gh),"FIXTURE":str(state),"WORK_SESSION_ID":"new-owner","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":os.devnull,"PYTHONDONTWRITEBYTECODE":"1","TRON_GATEWAY_HOST":"127.0.0.1"}
        def git(cwd,*args): return subprocess.run(["git",*args],cwd=cwd,env=env,check=True,capture_output=True,text=True).stdout.strip()
        git(repo,"init","-b","main"); git(repo,"config","user.name","Fixture"); git(repo,"config","user.email","fixture@example.invalid")
        (repo/".github").mkdir(); shutil.copy(ROOT/".github/work.json",repo/".github/work.json")
        (repo/"scripts").mkdir(); shutil.copy(ROOT/"scripts/personal-info-guard.sh",repo/"scripts/personal-info-guard.sh")
        git(repo,"add",".github/work.json"); git(repo,"commit","-m","base")
        git(remote.parent,"init","--bare",str(remote)); git(repo,"remote","add","origin",str(remote)); git(repo,"push","origin","main")
        git(repo,"checkout","-b","feat/41-fixture"); git(repo,"commit","--allow-empty","-m","Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner")
        git(repo,"push","-u","origin","feat/41-fixture"); git(repo,"checkout","main")
        worktree=repo.parent/"tron-worktrees"/"41-fixture"; worktree.parent.mkdir()
        git(repo,"worktree","add",str(worktree),"feat/41-fixture")
        (worktree/"tracked.txt").write_text("committed\n"); git(worktree,"add","tracked.txt"); git(worktree,"commit","-m","tracked fixture")
        git(worktree,"push")
        (worktree/"tracked.txt").write_text("unstaged bytes\n"); (worktree/"staged.txt").write_text("staged bytes\n")
        git(worktree,"add","staged.txt"); (worktree/"untracked.txt").write_bytes(b"untracked\x00bytes")
        cli=ROOT/"tools/work/cli.py"
        def call(*args,input=None): return subprocess.run([sys.executable,str(cli),*args],cwd=worktree if worktree.exists() else repo,env=env,input=input,capture_output=True,text=True,timeout=30)
        def fixture(pages=None,statuses=None):
            state.write_text(json.dumps({"comments":[],"writes":[],"calls":[],"pages":pages or {"first":{"items":[]}},"statuses":statuses or {}}))
        ws=root/"gateway-fixture.js"; ws.write_text(NODE_FIXTURE)
        gateway_env={**env,"WS_MODULE":str(ROOT/"packages/gateway/node_modules/ws"),"FIXTURE_TOKEN":TOKEN,"PORT_FILE":str(port_file)}
        server=subprocess.Popen(["node",str(ws)],env=gateway_env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        deadline=time.monotonic()+10
        while not port_file.exists() and time.monotonic()<deadline:
            if server.poll() is not None: raise RuntimeError("WebSocket fixture exited: "+server.stderr.read().decode())
            time.sleep(.02)
        if not port_file.exists(): raise RuntimeError("WebSocket fixture did not bind")
        env["TRON_GATEWAY_PORT"]=port_file.read_text()
        before_head=git(worktree,"rev-parse","HEAD")

        def refuse_snapshot():
            refs=git(repo,"for-each-ref","--format=%(refname) %(objectname)").splitlines()
            gitdir=Path(git(worktree,"rev-parse","--git-common-dir")); gitdir=(worktree/gitdir).resolve() if not gitdir.is_absolute() else gitdir
            work_dir=gitdir/"work"
            important={str(p.relative_to(gitdir)):p.read_bytes() for p in work_dir.rglob("*") if p.is_file()} if work_dir.exists() else {}
            comment_state=json.loads(state.read_text())
            dirty={name:(worktree/name).read_bytes() for name in ["tracked.txt","staged.txt","untracked.txt"]}
            index=(gitdir/"index").read_bytes()
            return refs,important,comment_state,index,dirty
        def assert_refused(name, setup, expected):
            setup(); before=refuse_snapshot(); r=call("handoff","41","--session","new-owner","--reason","owner settled")
            after=refuse_snapshot(); data=json.loads(state.read_text())
            evidence.append({"case":name,"exit":r.returncode,"stderr":r.stderr.strip(),"gatewayCalls":data["calls"]})
            assert r.returncode and expected in r.stderr, r.stderr
            assert before[:2]==after[:2] and before[3:]==after[3:], "refusal changed refs, lock/index, or dirty bytes"
            assert before[2]["writes"]==after[2]["writes"] and before[2]["comments"]==after[2]["comments"], "refusal wrote audit"
            return data

        data=assert_refused("active-only owner refused without task status",lambda:fixture({"first":{"items":[{"taskId":"active","lifecycle":"active"}]}},{"active":{}}),"refusing handoff")
        assert [c["method"] for c in data["calls"]]==["home.taskList"]
        terminal=lambda i:{"taskId":i,"lifecycle":"terminal"}
        settled={"sessionId":"old-owner","lifecycle":"terminal","terminalEvidence":{"outcome":"final","reason":"explicit-report","sessionId":"old-owner"},"subagents":{"started":0,"stoppedAtEnd":0},"subagentRuns":{"total":0,"runs":[]}}
        data=assert_refused("malformed or missing terminal evidence refuses",lambda:fixture({"first":{"items":[terminal("bad"),terminal("missing")]}},{"bad":{**settled,"terminalEvidence":None}}),"refusing handoff")
        assert [c["params"].get("taskId") for c in data["calls"] if c["method"]=="home.taskStatus"]==["bad"]

        # stoppedAtEnd=0 is a naturally finished subagent set, not indeterminate.
        git(repo,"worktree","remove","--force",str(worktree)); git(repo,"worktree","add",str(worktree),"feat/41-fixture")
        fixture({"first":{"items":[terminal("natural")] }},{"natural":{**settled,"subagents":{"started":2,"stoppedAtEnd":0}}})
        natural=call("handoff","41","--session","new-owner","--reason","naturally settled")
        evidence.append({"case":"started2 stoppedAtEnd0 naturally finished accepted","exit":natural.returncode,"stderr":natural.stderr.strip()})
        assert natural.returncode==0,natural.stderr
        natural_head=git(worktree,"rev-parse","HEAD"); natural_state=json.loads(state.read_text())
        retry=call("handoff","41","--session","new-owner","--reason","retry ignored")
        assert retry.returncode==0 and git(worktree,"rev-parse","HEAD")==natural_head
        assert git(worktree,"rev-parse","refs/heads/feat/41-fixture")==natural_head
        assert len(json.loads(state.read_text())["writes"])==1
        evidence.append({"case":"repeat owner is idempotent, one audit, unchanged head/ref","exit":retry.returncode})

        # Existing override guards and confirmed PTY takeover remain represented.
        git(repo,"worktree","remove","--force",str(worktree)); git(repo,"checkout","main"); git(repo,"checkout","-B","feat/41-fixture")
        git(repo,"commit","--allow-empty","-m","Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner"); git(repo,"push","--force","-u","origin","feat/41-fixture")
        git(repo,"checkout","main"); git(repo,"worktree","add",str(worktree),"feat/41-fixture")
        fixture(); r=call("handoff","41","--session","new-owner","--reason","owner settled")
        evidence.append({"case":"unknown owner refused without writes","exit":r.returncode,"stderr":r.stderr.strip()}); assert r.returncode and "unknown" in r.stderr
        r=call("handoff","41","--session","new-owner","--reason","owner settled","--force-maintainer")
        evidence.append({"case":"force requires TTY","exit":r.returncode,"stderr":r.stderr.strip()}); assert r.returncode and "interactive terminal" in r.stderr
        git(worktree,"commit","--allow-empty","-m","Claim retry\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner"); git(worktree,"push","--force-with-lease")
        fixture(); pid,terminal_fd=pty.fork()
        if pid==0:
            os.chdir(worktree); os.execve(sys.executable,[sys.executable,str(cli),"handoff","41","--session","new-owner","--reason","fixture takeover","--force-maintainer"],env)
        output=b""; deadline=time.monotonic()+30
        while time.monotonic()<deadline and b"> " not in output:
            ready,_,_=select.select([terminal_fd],[],[],1)
            if ready:
                try: output+=os.read(terminal_fd,4096)
                except OSError: break
        os.write(terminal_fd,b"HANDOFF #41 FROM old-owner\n")
        while time.monotonic()<deadline:
            ready,_,_=select.select([terminal_fd],[],[],1)
            if ready:
                try: output+=os.read(terminal_fd,4096)
                except OSError: break
            waited,status=os.waitpid(pid,os.WNOHANG)
            if waited: break
        else: os.kill(pid,9); _,status=os.waitpid(pid,0)
        code=os.waitstatus_to_exitcode(status); evidence.append({"case":"TTY force takeover succeeds with audit","exit":code,"output":output.decode(errors="replace")[-1000:]}); assert code==0
        comments=json.loads(state.read_text())["comments"]; handed=git(worktree,"rev-parse","HEAD")
        assert len(comments)==1 and "old-owner" in comments[0] and "new-owner" in comments[0] and handed in comments[0]
        writes_before=len(json.loads(state.read_text())["writes"]); retry=call("handoff","41","--session","new-owner","--reason","ignored retry reason")
        assert retry.returncode==0 and len(json.loads(state.read_text())["writes"])==writes_before
        evidence.append({"case":"repeat same transition adds no audit writes","exit":retry.returncode})
        git(repo,"worktree","remove","--force",str(worktree)); r=call("handoff","41","--session","new-owner","--reason","owner settled")
        evidence.append({"case":"missing worktree refuses without recreation","exit":r.returncode,"stderr":r.stderr.strip()}); assert r.returncode and "worktree is missing" in r.stderr and not worktree.exists()
        # Regression case: the matching finished owner is behind another terminal
        # row and a page boundary. The current helper returns on that unrelated row.
        git(repo,"checkout","main"); git(repo,"checkout","-B","feat/41-fixture")
        git(repo,"commit","--allow-empty","-m","Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner"); git(repo,"push","--force","-u","origin","feat/41-fixture")
        git(repo,"checkout","main"); git(repo,"worktree","add",str(worktree),"feat/41-fixture")
        unrelated={**settled,"sessionId":"someone-else","terminalEvidence":{**settled["terminalEvidence"],"sessionId":"someone-else"}}
        fixture({"first":{"items":[{"taskId":"busy","lifecycle":"active"},terminal("unrelated")],"nextCursor":"later"},"later":{"items":[terminal("owner")] }},{"unrelated":unrelated,"owner":settled})
        refs_before=git(repo,"for-each-ref","--format=%(refname) %(objectname)").splitlines()
        ref=call("handoff","41","--session","new-owner","--reason","settled owner"); data=json.loads(state.read_text())
        evidence.append({"case":"matching finished owner behind unrelated terminal row and later page transfers without force","exit":ref.returncode,"stderr":ref.stderr.strip(),"gatewayCalls":data["calls"]})
        if ref.returncode==0:
            assert [c["method"] for c in data["calls"]]==["home.taskList","home.taskList","home.taskStatus"]
            handed=git(worktree,"rev-parse","HEAD"); assert git(worktree,"rev-parse","origin/feat/41-fixture")==handed
            assert len(data["writes"])==1 and "old-owner" in data["comments"][0] and "new-owner" in data["comments"][0]
            assert {line.split()[0] for line in refs_before} <= {line.split()[0] for line in git(repo,"for-each-ref","--format=%(refname) %(objectname)").splitlines()}
        else:
            raise AssertionError(ref.stderr)
        print(f"Passed {len(evidence)} handoff journeys; evidence: {artifact}")
    finally:
      if server is not None:
        server.terminate()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
      artifact.write_text(json.dumps(evidence,indent=2)+"\n")
if __name__=="__main__": run()
