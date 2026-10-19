#!/usr/bin/env python3
"""Process-level claim-handoff checks with real Git, Gateway WebSocket and gh fixtures."""
from __future__ import annotations
import json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/work"))
import claim
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
      const protocol = Number(process.env.FIXTURE_PROTOCOL || 8);
      socket.send(JSON.stringify({type:"hello", protocolVersion:protocol, minProtocolVersion:protocol}));
    } else if (frame.type === "request") {
      const current = state(); current.calls.push({method:frame.method, params:frame.params});
      fs.writeFileSync(statePath, JSON.stringify(current));
      let result;
      if (frame.method === "session.list") result = {sessions: [], listRevision: 1, projectionToken: "fixture"};
      else if (frame.method === "home.taskList") {
        const page = current.pages[frame.params.cursor || "first"] || {items:[]};
        result = page;
      } else if (frame.method === "home.taskStatus") {
        const value = current.statuses[frame.params.taskId];
        if (Array.isArray(value)) {
          const index = current.calls.filter(call => call.method === frame.method && call.params.taskId === frame.params.taskId).length - 1;
          result = value[Math.min(index, value.length - 1)];
        } else result = value;
      }
      else throw new Error(`unexpected method ${frame.method}`);
      socket.send(JSON.stringify({type:"response", id:frame.id, ok:true, result}));
    }
  });
});
server.listen(0, process.env.FIXTURE_BIND_HOST || "127.0.0.1", () => fs.writeFileSync(process.env.PORT_FILE, String(server.address().port)));
process.on("SIGTERM", () => { wss.close(() => server.close(() => process.exit(0))); setTimeout(() => process.exit(0), 1000).unref(); });
'''


def run():
    evidence=[]; artifact=ROOT/"test-results/work-handoff.json"; artifact.parent.mkdir(parents=True,exist_ok=True)
    servers=[]
    try:
      with tempfile.TemporaryDirectory(prefix="tron-work-handoff-") as d:
        root=Path(d); repo=root/"repo"; repo.mkdir(); home=root/"home"; home.mkdir(); tmp=root/"tmp"; tmp.mkdir()
        tron_home=home/".tron"; (tron_home/"gateway").mkdir(parents=True)
        credential=tron_home/"gateway/local-auth.json"
        credential.write_text(json.dumps({"version":2,"bearerToken":TOKEN,"purpose":"local-wrapper-health","lastUpdated":"2025-01-01T00:00:00.000Z"}))
        credential.chmod(0o600)
        remote=root/"remote.git"; state=root/"gateway.json"; gh=root/"gh"; port_file=root/"port"
        gh.write_text('#!/usr/bin/env python3\nimport json,os,sys\np=os.environ["FIXTURE"]; s=json.load(open(p)); a=sys.argv[1:]\nif a[:2]==["issue","comment"] and os.environ.get("RECOVERY_FAIL_AUDIT") and not os.path.exists(os.environ["RECOVERY_FAIL_AUDIT"]): open(os.environ["RECOVERY_FAIL_AUDIT"],"w").close(); raise SystemExit("fixture audit failure")\nif a[:2]==["repo","view"]: print(json.dumps({"nameWithOwner":"fixture/project","owner":{"login":"fixture"}}))\nelif a[:3]==["issue","view","41"]: print(json.dumps({"state":"OPEN","comments":s["comments"]}))\nelif a[:1]==["api"]: print("\\n".join(s["comments"]))\nelif a[:2]==["issue","comment"]: s["comments"].append(sys.stdin.read()); s["writes"].append("comment"); json.dump(s,open(p,"w"))\nelse: raise SystemExit("unexpected gh: "+repr(a))\n')
        gh.chmod(0o755)
        git_bin=root/"git-bin"; git_bin.mkdir()
        real_git=shutil.which("git")
        if not real_git: raise RuntimeError("git executable unavailable")
        git_wrapper=git_bin/"git"
        fail_update_once=root/"fail-update-ref-once"
        git_wrapper.write_text(f'''#!/usr/bin/env python3
import os, sys, subprocess
from pathlib import Path
args = sys.argv[1:]
if args[:1] == ["push"] and os.environ.get("RECOVERY_REMOTE_RACE"):
    subprocess.run([{real_git!r}, "--git-dir", os.environ["RECOVERY_REMOTE"], "update-ref",
                    "refs/heads/feat/41-fixture", os.environ["RECOVERY_REMOTE_RACE"]], check=True)
if args[:1] == ["push"] and os.environ.get("RECOVERY_LOCAL_RACE"):
    result = subprocess.run([{real_git!r}, "update-ref", "refs/heads/feat/41-fixture",
                             os.environ["RECOVERY_LOCAL_RACE"]], capture_output=True)
    Path(os.environ["RECOVERY_RACE_RESULT"]).write_text(str(result.returncode))
marker = Path(os.environ["FAIL_UPDATE_REF_ONCE"])
if args[:1] == ["update-ref"] and not marker.exists():
    marker.write_text("failed\\n")
    print("fixture: update-ref failed once", file=sys.stderr)
    raise SystemExit(1)
os.execv({real_git!r}, [{real_git!r}, *args])
''')
        git_wrapper.chmod(0o755)
        env={**os.environ,"HOME":str(home),"TMPDIR":str(tmp),"WORK_GH":str(gh),"FIXTURE":str(state),"WORK_SESSION_ID":"new-owner","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":os.devnull,"PYTHONDONTWRITEBYTECODE":"1","TRON_GATEWAY_HOST":"127.0.0.1","FAIL_UPDATE_REF_ONCE":str(fail_update_once)}
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
        def call(*args,input=None,timeout=30): return subprocess.run([sys.executable,str(cli),*args],cwd=worktree if worktree.exists() else repo,env=env,input=input,capture_output=True,text=True,timeout=timeout)
        def fixture(pages=None,statuses=None):
            bound={key: ([{"taskId":key, **value} for value in values] if isinstance(values,list) else {"taskId":key, **values}) for key,values in (statuses or {}).items()}
            state.write_text(json.dumps({"comments":[],"writes":[],"calls":[],"pages":pages or {"first":{"items":[]}},"statuses":bound}))
        ws=root/"gateway-fixture.js"; ws.write_text(NODE_FIXTURE)
        gateway_env={**env,"WS_MODULE":str(ROOT/"packages/gateway/node_modules/ws"),"FIXTURE_TOKEN":TOKEN,"PORT_FILE":str(port_file)}
        def start_gateway(bind_host, output, protocol=8):
            output.unlink(missing_ok=True)
            process=subprocess.Popen(["node",str(ws)],env={**gateway_env,"FIXTURE_BIND_HOST":bind_host,"PORT_FILE":str(output),"FIXTURE_PROTOCOL":str(protocol)},stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            servers.append(process)
            deadline=time.monotonic()+10
            while not output.exists() and time.monotonic()<deadline:
                if process.poll() is not None: raise RuntimeError("WebSocket fixture exited: "+process.stderr.read().decode())
                time.sleep(.02)
            if not output.exists(): raise RuntimeError(f"WebSocket fixture did not bind {bind_host}")
            return output.read_text()
        env["TRON_GATEWAY_PORT"]=start_gateway("127.0.0.1", port_file)

        terminal=lambda i,session="old-owner":{"taskId":i,"lifecycle":"terminal","sessionId":session}
        settled={"operationId":"operation-natural","sessionId":"old-owner","lifecycle":"terminal","terminalEvidence":{"outcome":"final","reason":"explicit-report","sessionId":"old-owner"},"subagents":{"started":0,"stoppedAtEnd":0},"subagentRuns":{"total":0,"runs":[]},"ownerSettlement":None}
        def recovery_journeys():
            # Recovery is deliberately separate from handoff: it publishes an exact, clean
            # descendant candidate without rewriting history or implying acceptance.
            git(repo,"worktree","remove","--force",str(worktree))
            git(repo,"checkout","main"); git(repo,"checkout","-B","feat/41-fixture")
            git(repo,"commit","--allow-empty","-m","Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner")
            git(repo,"push","--force","-u","origin","feat/41-fixture")
            git(repo,"checkout","main"); git(repo,"worktree","add",str(worktree),"feat/41-fixture")
            (worktree/"candidate.txt").write_text("unpublished candidate bytes\n")
            git(worktree,"add","candidate.txt"); git(worktree,"commit","-m","unpublished candidate")
            candidate=git(worktree,"rev-parse","HEAD"); remote_expected=git(worktree,"rev-parse","refs/remotes/origin/feat/41-fixture")
            fixture({"first":{"items":[terminal("owner")]}},{"owner":settled})
            recovery_args=("recover","41","--expected-local",candidate,"--expected-remote",remote_expected,"--reason","recover settled clean candidate")
            bad_exact=call("recover","41","--expected-local","0"*40,"--expected-remote",remote_expected,"--reason",recovery_args[-1])
            evidence.append({"case":"recovery refuses mismatched exact local head","exit":bad_exact.returncode,"stderr":bad_exact.stderr.strip()})
            assert bad_exact.returncode and "expected local head" in bad_exact.stderr, bad_exact.stderr
            def settled_fixture(value=None):
                fixture({"first":{"items":[terminal("owner")]}},{"owner":value if value is not None else settled})
            def recovery_snapshot():
                return (git(worktree,"rev-parse","HEAD"), git(repo,"ls-remote","--heads","origin"),
                        git(worktree,"--no-optional-locks","status","--porcelain"),
                        (worktree/"candidate.txt").read_bytes(),
                        Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","index")).read_bytes())
            def refuse_recovery(name, expected, arguments=None):
                before=recovery_snapshot(); writes=json.loads(state.read_text())["writes"]
                result=call(*(arguments or recovery_args))
                evidence.append({"case":name,"exit":result.returncode,"stderr":result.stderr.strip()})
                assert result.returncode and expected in result.stderr, result.stderr
                assert recovery_snapshot()==before, name+" changed candidate, index or refs"
                assert json.loads(state.read_text())["writes"]==writes, name+" wrote an audit"
                assert not Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","index.lock")).exists()
                return result

            # Exercise skew through the real CLI with a built helper available.
            # Dependency metadata is restored even when the regression fails.
            pi_package=ROOT/"packages/gateway/node_modules/@earendil-works/pi-coding-agent/package.json"
            installed=pi_package.read_bytes()
            settled_fixture()
            try:
                package=json.loads(installed); package["version"]="0.0.0-fixture-skew"
                pi_package.write_text(json.dumps(package))
                skew=refuse_recovery("Pi dependency skew refuses with install command","installed Pi 0.0.0-fixture-skew")
                assert "lockfile pins" in skew.stderr and "scripts/tron-node exec npm --prefix packages/gateway ci" in skew.stderr, skew.stderr
            finally:
                pi_package.write_bytes(installed)

            # Ordinary handoff remains closed until the explicitly requested recovery.
            ordinary=call("handoff","41","--reason","still guarded")
            assert ordinary.returncode and "differs from remote" in ordinary.stderr
            evidence.append({"case":"ordinary handoff still refuses unpublished candidate","exit":ordinary.returncode})
            for name,value in [
                ("unknown owner", None),
                ("active owner", {**settled,"lifecycle":"active"}),
                ("remaining child", {**settled,"subagentRuns":{"total":1,"runs":[{}]}}),
                ("missing terminal evidence", {**settled,"terminalEvidence":None}),
                ("settlement changed during preparation", [settled,settled,{**settled,"lifecycle":"active"}]),
            ]:
                if value is None: fixture()
                else: settled_fixture(value)
                refuse_recovery(name,"refusing recovery" if name!="settlement changed during preparation" else "settlement changed")
            settled_fixture()
            (worktree/"candidate.txt").write_text("dirty bytes\n")
            refuse_recovery("dirty candidate refused","clean worktree")
            (worktree/"candidate.txt").write_text("unpublished candidate bytes\n")
            (worktree/"untracked").write_text("preserve untracked")
            refuse_recovery("untracked candidate refused","clean worktree")
            assert (worktree/"untracked").read_text()=="preserve untracked"; (worktree/"untracked").unlink()
            operation=Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","CHERRY_PICK_HEAD"))
            operation.write_text(remote_expected+"\n")
            refuse_recovery("unfinished Git operation refused","CHERRY_PICK_HEAD")
            assert operation.read_text()==remote_expected+"\n"; operation.unlink()
            lock=Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","HEAD.lock"))
            lock.write_text("foreign writer")
            refuse_recovery("foreign Git lock preserved","Git writer holds HEAD")
            assert lock.read_text()=="foreign writer"; lock.unlink()
            changed_claim=git(worktree,"commit-tree","HEAD^{tree}","-p",candidate,"-m",
                              "Claim replacement\n\nWork-Claim-Issue: 41\nWork-Claim-Session: other-owner")
            git(worktree,"update-ref","refs/heads/feat/41-fixture",changed_claim,candidate)
            refuse_recovery("changed local head refused","expected local head")
            refuse_recovery("different candidate claim refused","same known claim",
                            ("recover","41","--expected-local",changed_claim,"--expected-remote",remote_expected,"--reason","candidate changed"))
            git(worktree,"update-ref","refs/heads/feat/41-fixture",candidate,changed_claim)
            divergent=git(worktree,"commit-tree","HEAD^{tree}","-p","main","-m","divergent remote")
            # Copy the object to the fixture bare repository without updating the claim.
            git(worktree,"push","origin",divergent+":refs/heads/fixture-object")
            git(remote,"update-ref","refs/heads/feat/41-fixture",divergent,remote_expected)
            refuse_recovery("changed remote refused","expected remote head")
            refuse_recovery("divergent exact heads refused","not an ancestor",
                            ("recover","41","--expected-local",candidate,"--expected-remote",divergent,"--reason","divergence refused"))
            git(remote,"update-ref","refs/heads/feat/41-fixture",remote_expected,divergent)
            env["PATH"]=str(git_bin)+os.pathsep+env.get("PATH","")
            fail_update_once.write_text("handoff partial-update fixture already exercised\n")
            env["RECOVERY_REMOTE"]=str(remote); env["RECOVERY_REMOTE_RACE"]=divergent
            raced=call(*recovery_args)
            evidence.append({"case":"remote race at actual push rejected by exact lease","exit":raced.returncode,"stderr":raced.stderr.strip()})
            assert raced.returncode and "publication refused" in raced.stderr, raced.stderr
            assert git(remote,"rev-parse","refs/heads/feat/41-fixture")==divergent
            assert git(worktree,"rev-parse","HEAD")==candidate and not json.loads(state.read_text())["writes"]
            del env["RECOVERY_REMOTE_RACE"]
            git(remote,"update-ref","refs/heads/feat/41-fixture",remote_expected,divergent)
            env["RECOVERY_LOCAL_RACE"]=changed_claim; env["RECOVERY_RACE_RESULT"]=str(root/"local-race")
            env["RECOVERY_FAIL_AUDIT"]=str(root/"failed-audit-once")
            partial=call(*recovery_args)
            evidence.append({"case":"accepted candidate with failed audit is preserved","exit":partial.returncode,"stderr":partial.stderr.strip()})
            assert partial.returncode and "fixture audit failure" in partial.stderr, partial.stderr
            assert git(worktree,"rev-parse","HEAD")==candidate and git(remote,"rev-parse","refs/heads/feat/41-fixture")==candidate
            assert not json.loads(state.read_text())["writes"]
            recovered=call(*recovery_args); recovery_state=json.loads(state.read_text())
            evidence.append({"case":"settled clean descendant recovery publishes without acceptance","exit":recovered.returncode,"stdout":recovered.stdout.strip(),"stderr":recovered.stderr.strip()})
            assert recovered.returncode==0, recovered.stderr
            assert git(worktree,"rev-parse","refs/remotes/origin/feat/41-fixture")==candidate
            assert git(worktree,"rev-parse","HEAD")==candidate
            assert len(recovery_state["writes"])==1 and "unverified" in recovery_state["comments"][0].lower()
            assert int((root/"local-race").read_text())!=0, "concurrent Git writer escaped the candidate ref lock"
            del env["RECOVERY_LOCAL_RACE"]
            retry=call(*recovery_args)
            assert retry.returncode==0 and len(json.loads(state.read_text())["writes"])==1, retry.stderr
            evidence.append({"case":"exact recovery retry leaves candidate and one audit","exit":retry.returncode})
            # The unchanged former owner still must pass ordinary handoff admission.
            assert claim.existing_claims(repo,"origin","main",41)[0].session=="old-owner"
            transfer=call("handoff","41","--reason","candidate recovered and ready for review")
            assert transfer.returncode==0, transfer.stderr
            assert claim.existing_claims(repo,"origin","main",41)[0].session=="new-owner"
            git(worktree,"merge-base","--is-ancestor",candidate,"HEAD")
            assert (worktree/"candidate.txt").read_text()=="unpublished candidate bytes\n"
            evidence.append({"case":"ordinary handoff after recovery preserves candidate ancestry","exit":transfer.returncode,"head":git(worktree,"rev-parse","HEAD")})
            print(f"Passed {len(evidence)} handoff and recovery journeys; evidence: {artifact}")

        if "--recovery-only" in sys.argv:
            recovery_journeys()
            return

        # Reject an arbitrary literal before loading the local credential or opening a socket.
        fixture()
        unsafe_env={**env,"TRON_GATEWAY_HOST":"203.0.113.1"}
        unsafe=subprocess.run(["node",str(ROOT/"packages/gateway/dist/client/work-owner-status.js"),"old-owner"],cwd=ROOT,env=unsafe_env,capture_output=True,text=True,timeout=10)
        evidence.append({"case":"unassigned literal host rejected before socket", "exit":unsafe.returncode,"stderr":unsafe.stderr.strip()})
        assert unsafe.returncode and "requires localhost or an IP address assigned" in unsafe.stderr, unsafe.stderr
        assert not json.loads(state.read_text())["calls"], "untrusted host reached the Gateway fixture"

        # Exercise the same process helper against a fixture bound to an assigned non-loopback IP, when available.
        interfaces=json.loads(subprocess.check_output(["node","-e","console.log(JSON.stringify(require('node:os').networkInterfaces()))"],text=True))
        local_ip=next((entry["address"] for entries in interfaces.values() for entry in (entries or [])
                       if not entry["internal"] and entry["family"] in ("IPv4",4) and entry["address"] != "127.0.0.1"),None)
        if local_ip:
            local_port_file=root/"local-port"
            local_port=start_gateway(local_ip,local_port_file)
            local_env={**env,"TRON_GATEWAY_HOST":local_ip,"TRON_GATEWAY_PORT":local_port}
            local= subprocess.run(["node",str(ROOT/"packages/gateway/dist/client/work-owner-status.js"),"old-owner"],cwd=ROOT,env=local_env,capture_output=True,text=True,timeout=10)
            evidence.append({"case":"assigned interface host accepted by process helper", "exit":local.returncode,"stdout":local.stdout.strip(),"stderr":local.stderr.strip()})
            assert local.returncode==0 and json.loads(local.stdout)["state"]=="indeterminate", local.stderr
            assert json.loads(state.read_text())["calls"], "assigned interface fixture did not receive the query"
        mismatch_port_file=root/"mismatch-port"
        mismatch_port=start_gateway("127.0.0.1",mismatch_port_file,protocol=7)
        mismatch_env={**env,"TRON_GATEWAY_PORT":mismatch_port}
        mismatch=subprocess.run(["node",str(ROOT/"packages/gateway/dist/client/work-owner-status.js"),"old-owner"],cwd=ROOT,env=mismatch_env,capture_output=True,text=True,timeout=10)
        evidence.append({"case":"protocol mismatch has a distinct structured refusal","exit":mismatch.returncode,"stderr":mismatch.stderr.strip()})
        detail=json.loads(mismatch.stderr)
        assert mismatch.returncode==3 and detail=={"kind":"protocol_mismatch","gatewayProtocol":7,"helperProtocol":8}, mismatch.stderr

        before_head=git(worktree,"rev-parse","HEAD")

        def refuse_snapshot():
            refs=git(repo,"for-each-ref","--format=%(refname) %(objectname)").splitlines()
            gitdir=Path(git(worktree,"rev-parse","--git-common-dir")); gitdir=(worktree/gitdir).resolve() if not gitdir.is_absolute() else gitdir
            work_dir=gitdir/"work"
            important={str(p.relative_to(gitdir)):p.read_bytes() for p in work_dir.rglob("*") if p.is_file()} if work_dir.exists() else {}
            comment_state=json.loads(state.read_text())
            dirty={name:(worktree/name).read_bytes() for name in ["tracked.txt","staged.txt","untracked.txt"]}
            index_path=Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","index"))
            index=index_path.read_bytes()
            return refs,important,comment_state,index,dirty
        def assert_refused(name, setup, expected):
            setup(); before=refuse_snapshot()
            r=subprocess.run([str(ROOT/"scripts/tron-node"),"exec","node",str(ROOT/"packages/gateway/dist/client/work-owner-status.js"),"old-owner"],env=env,capture_output=True,text=True,timeout=30)
            after=refuse_snapshot(); data=json.loads(state.read_text())
            evidence.append({"case":name,"exit":r.returncode,"stderr":r.stderr.strip(),"gatewayCalls":data["calls"]})
            assert r.returncode==0 and json.loads(r.stdout)["state"] != "settled", r.stdout+r.stderr
            assert before[:2]==after[:2] and before[3:]==after[3:], "refusal changed refs, lock/index, or dirty bytes"
            assert before[2]["writes"]==after[2]["writes"] and before[2]["comments"]==after[2]["comments"], "refusal wrote audit"
            return data

        data=assert_refused("active-only owner refused without task status",lambda:fixture({"first":{"items":[{"taskId":"active","lifecycle":"active","sessionId":"old-owner"}]}},{"active":{}}),"is live")
        assert [c["method"] for c in data["calls"]]==["session.list","session.list","home.taskList"]
        terminal=lambda i,session="old-owner":{"taskId":i,"lifecycle":"terminal","sessionId":session}
        settled={"operationId":"operation-natural","sessionId":"old-owner","lifecycle":"terminal","terminalEvidence":{"outcome":"final","reason":"explicit-report","sessionId":"old-owner"},"subagents":{"started":0,"stoppedAtEnd":0},"subagentRuns":{"total":0,"runs":[]},"ownerSettlement":None}
        data=assert_refused("malformed or missing terminal evidence refuses",lambda:fixture({"first":{"items":[terminal("bad"),terminal("missing")]}},{"bad":{**settled,"terminalEvidence":None}}),"refusing handoff")
        assert [c["params"].get("taskId") for c in data["calls"] if c["method"]=="home.taskStatus"]==["bad"]
        merge_marker=Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","MERGE_HEAD"))
        head_before_merge=git(worktree,"rev-parse","HEAD")
        git(worktree,"stash","push","--include-untracked","-m","merge fixture setup")
        original_branch=git(worktree,"branch","--show-current")
        merge_base=git(worktree,"rev-parse","HEAD~1")
        git(worktree,"branch","fixture-merge-side",merge_base)
        git(worktree,"checkout","fixture-merge-side")
        git(worktree,"commit","--allow-empty","-m","merge-side-only")
        git(worktree,"checkout",original_branch)
        git(worktree,"merge","--no-commit","fixture-merge-side")
        assert merge_marker.is_file(), "real linked-worktree merge marker was not created"
        fixture({"first":{"items":[terminal("owner")]}},{"owner":settled})
        merge_ref=git(worktree,"rev-parse","HEAD")
        merge_result=call("handoff","41","--session","new-owner","--reason","owner settled")
        evidence.append({"case":"real linked-worktree merge in progress refuses","exit":merge_result.returncode,"stderr":merge_result.stderr.strip()})
        assert merge_result.returncode and "MERGE_HEAD" in merge_result.stderr, merge_result.stderr
        assert git(worktree,"rev-parse","HEAD")==merge_ref
        git(worktree,"merge","--abort")
        git(worktree,"reset","--hard",head_before_merge)
        git(worktree,"stash","pop")
        common=Path(git(worktree,"rev-parse","--path-format=absolute","--git-common-dir"))
        assert not (common/"work"/"handoff.lock").exists()

        # Terminal plus synthetic zero-live-run projection cannot settle an unknown outcome.
        no_proof={**settled,"taskId":"natural","operationId":"operation-natural",
          "terminalEvidence":{"outcome":"unknown","reason":"no-report","sessionId":"old-owner"},
          "subagents":{"started":1,"stoppedAtEnd":0}}
        assert_refused("unknown no-report without canonical receipts refuses",lambda:fixture({"first":{"items":[terminal("natural")]}},{"natural":no_proof}),"refusing handoff")

        # Unknown work outcome can settle owner lifecycle only with bound canonical receipts.
        dirty_before={name:(worktree/name).read_bytes() for name in ["tracked.txt","staged.txt","untracked.txt"]}
        index_before=Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","index")).read_bytes()
        unknown_terminal={**settled,"terminalEvidence":{"outcome":"unknown","reason":"no-report","sessionId":"old-owner"},
          "operationId":"operation-natural","subagents":{"started":1,"stoppedAtEnd":1},
          "ownerSettlement":{"taskId":"natural","sessionId":"old-owner","operationId":"operation-natural",
            "markerEntryId":"marker-one","terminalEntryId":"terminal-one","settlementEntryId":"settlement-one","stoppedAtEnd":1}}
        for label, mutate in [
          ("proof session mismatch", lambda value: value["ownerSettlement"].update(sessionId="other-session")),
          ("proof operation mismatch", lambda value: value["ownerSettlement"].update(operationId="other-operation")),
          ("proof task mismatch", lambda value: value["ownerSettlement"].update(taskId="other-task")),
          ("status task mismatch", lambda value: value.update(taskId="other-task")),
          ("missing settlement proof", lambda value: value.update(ownerSettlement=None)),
          ("failed settlement proof", lambda value: value["ownerSettlement"].update(stoppedAtEnd=None)),
          ("malformed receipt identity", lambda value: value["ownerSettlement"].update(terminalEntryId="")),
          ("ambiguous receipt identities", lambda value: value["ownerSettlement"].update(terminalEntryId="marker-one")),
          ("unexpected proof field", lambda value: value["ownerSettlement"].update(unverified=True)),
          ("contradictory settlement counts", lambda value: value["ownerSettlement"].update(stoppedAtEnd=0)),
          ("remaining live children", lambda value: value.update(subagentRuns={"total":1,"runs":[{}]})),
          ("unknown lifecycle", lambda value: value.update(lifecycle="unknown")),
          ("status became active", lambda value: value.update(lifecycle="active")),
        ]:
            invalid=json.loads(json.dumps(unknown_terminal)); mutate(invalid)
            assert_refused(label,lambda invalid=invalid:fixture({"first":{"items":[terminal("natural")]}},{"natural":invalid}),"refusing handoff")
        for reason in ["detached-work-outlived-task","deadline-stop-failed","report-stop-failed","task-stop-failed","admission-refused","evidence-unavailable","cold-evidence-unavailable"]:
            invalid=json.loads(json.dumps(unknown_terminal)); invalid["terminalEvidence"]["reason"]=reason
            assert_refused(f"reason-specific exclusion: {reason}",lambda invalid=invalid:fixture({"first":{"items":[terminal("natural")]}},{"natural":invalid}),"refusing handoff")
        for label, mutate in [
          ("lifecycle race", lambda value: value.update(lifecycle="active")),
          ("operation race", lambda value: (value.update(operationId="replacement"), value["ownerSettlement"].update(operationId="replacement"))),
          ("session race", lambda value: value.update(sessionId="replacement")),
          ("settlement race", lambda value: value["ownerSettlement"].update(settlementEntryId="replacement")),
        ]:
            raced=json.loads(json.dumps(unknown_terminal)); mutate(raced)
            data=assert_refused(label,lambda raced=raced:fixture({"first":{"items":[terminal("natural")]}},{"natural":[unknown_terminal,raced]}),"refusing handoff")
            assert len([c for c in data["calls"] if c["method"]=="home.taskStatus"])==2
        for label, value in [
          ("naturally finished ordinary children", {**settled,"subagents":{"started":2,"stoppedAtEnd":0}}),
          ("no-report canonical settlement with zero task-end stops", {**unknown_terminal,"subagents":{"started":1,"stoppedAtEnd":0},"ownerSettlement":{**unknown_terminal["ownerSettlement"],"stoppedAtEnd":0}}),
          # Reconciled from the canonical file after the operation ended, every async run proven ended (#1166).
          ("failed live settlement reconciled", {**unknown_terminal,"terminalEvidence":{"outcome":"unknown","reason":"settlement-failed","sessionId":"old-owner"},"ownerSettlement":None}),
          ("cold reconciliation without a report", {**unknown_terminal,"terminalEvidence":{"outcome":"unknown","reason":"cold-no-report","sessionId":"old-owner"},"ownerSettlement":None}),
        ]:
            fixture({"first":{"items":[terminal("natural")]}},{"natural":value})
            result=subprocess.run(["node",str(ROOT/"packages/gateway/dist/client/work-owner-status.js"),"old-owner"],cwd=ROOT,env=env,capture_output=True,text=True,timeout=30)
            evidence.append({"case":label,"exit":result.returncode,"stdout":result.stdout.strip()})
            assert result.returncode==0 and json.loads(result.stdout)["state"]=="settled", result.stderr
        fixture({"first":{"items":[terminal("natural")] }},{"natural":unknown_terminal})
        env["PATH"]=str(git_bin)+os.pathsep+env.get("PATH","")
        natural=call("handoff","41","--session","new-owner","--reason","naturally settled")
        evidence.append({"case":"remote accepted but update-ref failed once","exit":natural.returncode,"stderr":natural.stderr.strip()})
        assert natural.returncode and "update-ref" in natural.stderr and fail_update_once.exists(), natural.stderr
        assert not json.loads(state.read_text())["writes"]
        natural=call("handoff","41","--session","new-owner","--reason","naturally settled")
        evidence.append({"case":"accepted remote recovered on retry","exit":natural.returncode,"stderr":natural.stderr.strip()})
        assert natural.returncode==0,natural.stderr
        natural_head=git(worktree,"rev-parse","HEAD"); natural_state=json.loads(state.read_text())
        assert Path(git(worktree,"rev-parse","--path-format=absolute","--git-path","index")).read_bytes()==index_before
        assert {name:(worktree/name).read_bytes() for name in dirty_before}==dirty_before
        retry=call("handoff","41","--session","new-owner","--reason","retry ignored")
        assert retry.returncode==0 and git(worktree,"rev-parse","HEAD")==natural_head
        assert git(worktree,"rev-parse","refs/heads/feat/41-fixture")==natural_head
        assert len(json.loads(state.read_text())["writes"])==1
        evidence.append({"case":"repeat owner is idempotent, one audit, unchanged head/ref","exit":retry.returncode})

        git(repo,"worktree","remove","--force",str(worktree)); r=call("handoff","41","--session","new-owner","--reason","owner settled")
        evidence.append({"case":"missing worktree refuses without recreation","exit":r.returncode,"stderr":r.stderr.strip()}); assert r.returncode and "worktree is missing" in r.stderr and not worktree.exists()
        # Regression case: the matching finished owner is behind another terminal
        # row and a page boundary. The current helper returns on that unrelated row.
        git(repo,"checkout","main"); git(repo,"checkout","-B","feat/41-fixture")
        git(repo,"commit","--allow-empty","-m","Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner"); git(repo,"push","--force","-u","origin","feat/41-fixture")
        git(repo,"checkout","main"); git(repo,"worktree","add",str(worktree),"feat/41-fixture")
        unrelated={**settled,"sessionId":"someone-else","terminalEvidence":{**settled["terminalEvidence"],"sessionId":"someone-else"}}
        fixture({"first":{"items":[{"taskId":"busy","lifecycle":"active","sessionId":"someone-else"},terminal("unrelated","someone-else")],"nextCursor":"later"},"later":{"items":[terminal("owner")] }},{"unrelated":unrelated,"owner":settled})
        ref=subprocess.run([str(ROOT/"scripts/tron-node"),"exec","node",str(ROOT/"packages/gateway/dist/client/work-owner-status.js"),"old-owner"],env=env,capture_output=True,text=True,timeout=30)
        data=json.loads(state.read_text())
        evidence.append({"case":"matching settled owner found behind unrelated terminal row and later page","exit":ref.returncode,"stdout":ref.stdout,"gatewayCalls":data["calls"]})
        assert ref.returncode==0 and json.loads(ref.stdout)["state"]=="settled", ref.stderr

        # A legacy helper emitted a bare verdict that the CLI could not parse. A stale
        # source stamp must cause the real work CLI to rebuild it before settled-owner
        # evidence is consumed, then complete the ordinary audited handoff.
        helper=ROOT/"packages/gateway/dist/client/work-owner-status.js"
        stamp=ROOT/"packages/gateway/dist/.work-owner-status-source"
        original_outputs={}
        for path in (helper,stamp):
            try:
                metadata=path.stat()
                original_outputs[path]=(path.read_bytes(),metadata.st_mode & 0o7777)
            except FileNotFoundError:
                original_outputs[path]=None
        try:
            helper.write_text('process.stdout.write("settled\\n");\n')
            stamp.write_text("stale-source-tree\n")
            git(repo,"worktree","remove","--force",str(worktree))
            git(repo,"checkout","main"); git(repo,"checkout","-B","feat/41-fixture")
            git(repo,"commit","--allow-empty","-m","Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: old-owner")
            git(repo,"push","--force","-u","origin","feat/41-fixture")
            git(repo,"checkout","main"); git(repo,"worktree","add",str(worktree),"feat/41-fixture")
            fixture({"first":{"items":[terminal("owner")]}},{"owner":settled})
            stale_started=time.monotonic()
            recovery_journeys()
            evidence.append({"case":"stale helper rebuilt before exact-candidate recovery","elapsedSeconds":round(time.monotonic()-stale_started,3),"stamp":stamp.read_text().strip()})
            assert 'process.stdout.write("settled\\n")' not in helper.read_text(), "legacy helper was not replaced"
        finally:
            for path,original in original_outputs.items():
                if original is None:
                    path.unlink(missing_ok=True)
                else:
                    contents,mode=original
                    path.write_bytes(contents)
                    path.chmod(mode)

    finally:
      for process in servers:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
      artifact.write_text(json.dumps(evidence,indent=2)+"\n")
if __name__=="__main__": run()
