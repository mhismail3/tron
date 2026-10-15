#!/usr/bin/env python3
"""`work release` journeys through the real CLI, Git, owner-status helper, a Gateway WebSocket fixture and a gh fixture.

Run from the repository root after `npm run build` in packages/gateway. Evidence: test-results/work-release.json.
"""
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

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "fixture-local-token-with-at-least-32-bytes"
ABSENT = "01a00000-0000-7000-8000-000000000001"
LIVE = "01a00000-0000-7000-8000-000000000002"
FILE_ONLY = "01a00000-0000-7000-8000-000000000003"
IDLE = "01a00000-0000-7000-8000-000000000004"
SETTLED = "01a00000-0000-7000-8000-000000000005"

# The Gateway: session.list rows, Home task pages and statuses from the state file; `stall` never answers a method.
GATEWAY = r'''
const fs = require("node:fs"); const http = require("node:http");
const WebSocket = require(process.env.WS_MODULE);
const statePath = process.env.FIXTURE;
const server = http.createServer(); const wss = new WebSocket.Server({ server });
wss.on("connection", (socket, request) => {
  if (request.headers.authorization !== `Bearer ${process.env.FIXTURE_TOKEN}`) return socket.close(1008);
  socket.on("message", raw => {
    const frame = JSON.parse(raw.toString());
    if (frame.type === "hello") return socket.send(JSON.stringify({type:"hello", protocolVersion:8, minProtocolVersion:8}));
    const state = JSON.parse(fs.readFileSync(statePath, "utf8")).gateway;
    const calls = JSON.parse(fs.readFileSync(statePath, "utf8")); calls.gatewayCalls.push(frame.method);
    fs.writeFileSync(statePath, JSON.stringify(calls));
    if (state.stall === frame.method) return;
    if (state.delay && state.delay.method === frame.method) return setTimeout(() => answer(frame, state), state.delay.ms);
    answer(frame, state);
  });
  const answer = (frame, state) => {
    let result;
    if (frame.method === "session.list") result = {sessions: frame.params.archived === "only" ? [] : state.sessions, listRevision: 1, projectionToken: "p"};
    else if (frame.method === "home.taskList") result = {items: state.tasks, counts: {active: 0, finished: state.tasks.length}};
    else if (frame.method === "home.taskStatus") result = state.statuses[frame.params.taskId];
    else return socket.send(JSON.stringify({type:"response", id:frame.id, ok:false, error:{code:"invalid_request", message:frame.method}}));
    socket.send(JSON.stringify({type:"response", id:frame.id, ok:true, result}));
  };
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(process.env.PORT_FILE, String(server.address().port)));
'''

# gh: repository identity, issue state, comments (optionally failing once), the Project item and its Status.
GH = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FIXTURE"]; state = json.load(open(path)); args = sys.argv[1:]; out = None
gh = state["gh"]
if args[:2] == ["repo", "view"]: print("fixture/project"); sys.exit(0)
if args[:2] == ["issue", "view"]: out = {"state": gh["state"], "comments": [{"createdAt": t} for t in gh.get("commentTimes", [])]}
elif args[:2] == ["api", "graphql"]:
    req = json.load(sys.stdin); query = req["query"]
    if "mutation" in query:
        gh["status"] = "Ready" if req["variables"]["option"] == "ready" else "?"; gh["writes"].append("status")
        out = {"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "item"}}}}
    else:
        out = {"data": {"repository": {"issue": {"id": "issue", "number": 41, "state": gh["state"], "title": "Fixture",
            "url": "https://example.invalid/issues/41", "labels": {"nodes": []}, "blockedBy": {"nodes": []},
            "comments": {"nodes": [{"body": b} for b in gh["comments"]]},
            "projectItems": {"nodes": [{"id": "item", "project": {"id": "project", "title": "Tron", "field": {"id": "status",
                "options": [{"id": "progress", "name": "In progress"}, {"id": "ready", "name": "Ready"}]}},
                "fieldValueByName": {"name": gh["status"]}}]}}}}}
elif args[:1] == ["api"]: print("\n".join(gh["comments"])); sys.exit(0)
elif args[:2] == ["issue", "comment"]:
    if gh.get("failComment"):
        gh["failComment"] = False; json.dump(state, open(path, "w")); sys.exit("fixture: comment failed once")
    gh["comments"].append(sys.stdin.read()); gh["writes"].append("comment")
else: sys.exit("unexpected gh: " + repr(args))
json.dump(state, open(path, "w")); print(json.dumps(out))
'''


def run() -> None:
    evidence = []
    artifact = ROOT / "test-results/work-release.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    helper = ROOT / "packages/gateway/dist/client/work-owner-status.js"
    if not helper.is_file():
        raise SystemExit("build packages/gateway first (npm run build)")
    server = None
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-release-") as scratch:
            root = Path(scratch)
            repo, remote, home, tmp = root / "repo", root / "remote.git", root / "home", root / "tmp"
            for directory in (repo, home, tmp):
                directory.mkdir()
            sessions = home / ".tron/agent/sessions"
            (sessions / "--fixture--").mkdir(parents=True)
            credential = home / ".tron/gateway/local-auth.json"
            credential.parent.mkdir(parents=True)
            credential.write_text(json.dumps({"version": 2, "bearerToken": TOKEN, "purpose": "local-wrapper-health",
                                              "lastUpdated": "2025-01-01T00:00:00.000Z"}))
            credential.chmod(0o600)
            state, gh, marker = root / "state.json", root / "gh", root / "release-commands.log"
            gh.write_text(GH)
            gh.chmod(0o755)
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "WORK_GH": str(gh), "FIXTURE": str(state),
                   "WORK_SESSION_ID": "releasing-session", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "PYTHONDONTWRITEBYTECODE": "1", "TRON_GATEWAY_HOST": "127.0.0.1", "RELEASE_MARKER": str(marker)}
            env.pop("PI_CODING_AGENT_DIR", None)

            def git(cwd: Path, *args: str) -> str:
                return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()

            def load() -> dict:
                return json.loads(state.read_text())

            def fixture(sessions_listed=(), tasks=(), statuses=None, stall=None, fail_comment=False, delay=None,
                        comment_times=()) -> None:
                state.write_text(json.dumps({"gatewayCalls": [], "gateway": {
                    "sessions": list(sessions_listed), "tasks": list(tasks), "statuses": statuses or {}, "stall": stall, "delay": delay},
                    "gh": {"state": "OPEN", "status": "In progress", "comments": [], "writes": [], "failComment": fail_comment,
                           "commentTimes": list(comment_times)}}))

            # A fixture repository with the real work configuration; release commands only record that they ran.
            git(repo, "init", "-b", "main")
            git(repo, "config", "user.name", "Fixture")
            git(repo, "config", "user.email", "fixture@example.invalid")
            config = json.loads((ROOT / ".github/work.json").read_text())
            config["cleanup"]["releaseCommands"] = [{"name": "fixture", "command": 'echo ran >> "$RELEASE_MARKER"', "timeoutSeconds": 30}]
            (repo / ".github").mkdir()
            (repo / ".github/work.json").write_text(json.dumps(config, indent=1))
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            (repo / ".gitignore").write_text("progress.md\nnode_modules/\n")
            (repo / "tracked.txt").write_text("base\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "base")
            git(root, "init", "--bare", str(remote))
            git(repo, "remote", "add", "origin", str(remote))
            git(repo, "push", "-q", "origin", "main")
            branch = "feat/41-fixture"
            worktree = root / "tron-worktrees/41-fixture"

            def claim(owner: str, content_commit: bool = False, age_hours: float = 0) -> None:
                if worktree.exists():
                    git(repo, "worktree", "remove", "--force", str(worktree))
                git(repo, "branch", "-f", branch, "main")
                git(repo, "worktree", "add", "-q", str(worktree), branch)
                stamp = f"@{int(time.time() - age_hours * 3600)} +0000"
                subprocess.run(["git", "commit", "-q", "--allow-empty", "-m",
                                f"chore: claim #41\n\nWork-Claim-Issue: 41\nWork-Claim-Session: {owner}\nWork-Claim-Base: main\n"],
                               cwd=worktree, env={**env, "GIT_COMMITTER_DATE": stamp, "GIT_AUTHOR_DATE": stamp},
                               check=True, capture_output=True)
                if content_commit:
                    (worktree / "published.txt").write_text("published\n")
                    git(worktree, "add", "published.txt")
                    git(worktree, "commit", "-q", "-m", "published work")
                git(worktree, "push", "-q", "--force", "-u", "origin", branch)

            def call(*args: str):
                return subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), *args], cwd=repo, env=env,
                                      capture_output=True, text=True, timeout=90)

            def snapshot():
                return (git(repo, "for-each-ref", "--format=%(refname) %(objectname)"),
                        git(remote, "for-each-ref", "--format=%(refname) %(objectname)"),
                        git(worktree, "status", "--porcelain", "--untracked-files=all", "--ignored"),
                        load()["gh"]["writes"])

            def refused(name: str, expected: str, owner: str, **gateway):
                claim(owner)
                fixture(**gateway)
                before = snapshot()
                started = time.monotonic()
                result = call("release", "41", "--reason", "stale claim")
                evidence.append({"case": name, "exit": result.returncode, "stderr": result.stderr.strip(),
                                 "seconds": round(time.monotonic() - started, 1), "gatewayCalls": load()["gatewayCalls"]})
                assert result.returncode and expected in result.stderr, result.stderr
                assert "claim left unchanged" in result.stderr, result.stderr
                assert snapshot() == before, f"{name} changed refs, the worktree or GitHub"
                return result

            port_file = root / "port"
            server = subprocess.Popen(["node", "-e", GATEWAY], env={**env, "WS_MODULE": str(ROOT / "packages/gateway/node_modules/ws"),
                                      "FIXTURE_TOKEN": TOKEN, "PORT_FILE": str(port_file)}, stderr=subprocess.PIPE)
            fixture()
            deadline = time.monotonic() + 10
            while not port_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            env["TRON_GATEWAY_PORT"] = port_file.read_text()
            (sessions / "--fixture--" / f"2026-01-01T00-00-00-000Z_{IDLE}.jsonl").write_text("{}\n")
            idle_row = {"id": IDLE, "phase": "idle"}

            refused("live owner refused", "is live", LIVE,
                    sessions_listed=[idle_row, {"id": LIVE, "phase": "running", "activeSince": "2026-01-01T00:00:00Z"}])
            refused("live Home task owner refused", "is live", "home-worker",
                    sessions_listed=[idle_row], tasks=[{"taskId": "task-1", "lifecycle": "active", "sessionId": "home-worker"}])
            refused("idle existing session is indeterminate", "is indeterminate", IDLE, sessions_listed=[idle_row])
            # A delegated child or Home chapter is absent from the user listing but has a file: not absent.
            child = sessions / "--fixture--" / f"2026-01-01T00-00-00-000Z_{IDLE}" / FILE_ONLY
            child.mkdir(parents=True)
            refused("unlisted session with a file is indeterminate", "delegated session or Home chapter", FILE_ONLY, sessions_listed=[idle_row])
            result = refused("non-Gateway owner id is indeterminate", "not a Gateway session id", "manual-owner",
                             sessions_listed=[idle_row])
            # The session root is trusted only when it holds every listed idle session.
            refused("unverifiable session root is indeterminate", "not the Gateway's", ABSENT,
                    sessions_listed=[idle_row, {"id": "01a00000-0000-7000-8000-0000000000ff", "phase": "idle"}])
            result = refused("Home task list timeout is indeterminate", "did not answer within the 20s owner-status deadline",
                             "manual-owner", sessions_listed=[idle_row], stall="home.taskList")
            assert evidence[-1]["seconds"] < 45, "owner status did not bound itself"
            claim(ABSENT, content_commit=True)
            fixture(sessions_listed=[idle_row])
            published = call("release", "41", "--reason", "stale claim")
            evidence.append({"case": "published work on the claim branch refused", "exit": published.returncode, "stderr": published.stderr.strip()})
            assert published.returncode and "not claim-only" in published.stderr, published.stderr

            # Dirty work is preserved, then the claim is released; a failed audit comment resumes on retry.
            claim(ABSENT)
            (worktree / "local.txt").write_text("unpublished commit\n")
            git(worktree, "add", "local.txt")
            git(worktree, "commit", "-q", "-m", "unpublished local commit")
            (worktree / "tracked.txt").write_text("unstaged edit\n")
            (worktree / "staged.txt").write_text("staged\n")
            git(worktree, "add", "staged.txt")
            (worktree / "untracked.bin").write_bytes(b"untracked\x00bytes")
            (worktree / "progress.md").write_text("ignored progress note\n")
            (worktree / "node_modules").mkdir()
            (worktree / "node_modules/regenerable.js").write_text("regenerable\n")
            local_head, remote_head = git(worktree, "rev-parse", "HEAD"), git(worktree, "rev-parse", "HEAD~1")
            config["cleanup"]["regenerableIgnored"] = ["**/node_modules/**"]
            (repo / ".github/work.json").write_text(json.dumps(config, indent=1))
            git(repo, "commit", "-qam", "fixture regenerable")
            git(repo, "push", "-q", "origin", "main")
            fixture(sessions_listed=[idle_row], fail_comment=True)
            first = call("release", "41", "--reason", "stale claim")
            evidence.append({"case": "audit comment failure after the remote release", "exit": first.returncode,
                             "stdout": first.stdout.strip(), "stderr": first.stderr.strip()})
            assert first.returncode and "comment failed once" in first.stderr, first.stderr
            assert branch not in git(remote, "for-each-ref", "--format=%(refname)"), "remote claim was not released"
            assert worktree.exists(), "worktree removed before the audit"
            retry = call("release", "41", "--reason", "stale claim")
            gh_state = load()["gh"]
            evidence.append({"case": "dirty claim released after preservation; retry resumes", "exit": retry.returncode,
                             "stdout": retry.stdout.strip(), "stderr": retry.stderr.strip(), "gh": gh_state})
            assert retry.returncode == 0, retry.stderr
            assert not worktree.exists() and not git(repo, "branch", "--list", branch)
            assert gh_state["state"] == "OPEN" and gh_state["status"] == "Ready"
            assert len(gh_state["comments"]) == 1 and remote_head in gh_state["comments"][0] and ABSENT in gh_state["comments"][0]
            assert "/Users/" not in gh_state["comments"][0] and str(root) not in gh_state["comments"][0]
            assert marker.read_text() == "ran\n"
            preserved = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")) / f"work/releases/41-{remote_head[:12]}"
            manifest = json.loads((preserved / "manifest.json").read_text())
            assert manifest["phase"] == "released" and manifest["localHead"] == local_head and manifest["ownerState"] == "absent"
            restored = root / "restored"
            git(root, "clone", "-q", str(remote), str(restored))
            git(restored, "fetch", "-q", str(preserved / "claim.bundle"), "refs/work-release/*:refs/work-release/*")
            namespace = f"refs/work-release/41/{remote_head[:12]}"
            assert git(restored, "rev-parse", f"{namespace}/head") == local_head
            assert git(restored, "rev-parse", f"{namespace}/remote") == remote_head
            git(restored, "checkout", "-q", f"{namespace}/worktree")
            for name, content in [("tracked.txt", b"unstaged edit\n"), ("staged.txt", b"staged\n"), ("local.txt", b"unpublished commit\n"),
                                  ("untracked.bin", b"untracked\x00bytes"), ("progress.md", b"ignored progress note\n")]:
                assert (restored / name).read_bytes() == content, name
            assert not (restored / "node_modules").exists(), "regenerable output was bundled"
            records = [json.loads(line) for line in (preserved.parent / "log.jsonl").read_text().splitlines()]
            assert records[-1]["issue"] == 41 and records[-1]["remoteHead"] == remote_head
            again = call("release", "41", "--reason", "stale claim")
            assert again.returncode and "nothing to release" in again.stderr and len(load()["gh"]["comments"]) == 1
            evidence.append({"case": "repeat release after success is a no-op refusal", "exit": again.returncode, "stderr": again.stderr.strip()})

            # A settled Home task owner releases a clean claim, although each Home task page takes 5s (the real
            # Stable Gateway took 6.3s per 50-row page; the former 4s per-request cap refused every owner).
            settled = {"taskId": "task-2", "operationId": "operation", "sessionId": SETTLED, "lifecycle": "terminal",
                       "terminalEvidence": {"outcome": "final", "reason": "explicit-report", "sessionId": SETTLED},
                       "subagents": {"started": 0, "stoppedAtEnd": 0}, "subagentRuns": {"total": 0, "runs": []}, "ownerSettlement": None}
            (sessions / "--fixture--" / f"2026-01-01T00-00-00-000Z_{SETTLED}.jsonl").write_text("{}\n")
            claim(SETTLED)
            fixture(sessions_listed=[idle_row, {"id": SETTLED, "phase": "idle"}],
                    tasks=[{"taskId": "task-2", "lifecycle": "terminal", "sessionId": SETTLED}], statuses={"task-2": settled},
                    delay={"method": "home.taskList", "ms": 5000})
            clean = call("release", "41", "--reason", "owner finished without landing")
            evidence.append({"case": "settled Home task owner released through a 5s Home task page", "exit": clean.returncode, "stdout": clean.stdout.strip(),
                             "stderr": clean.stderr.strip(), "gatewayCalls": load()["gatewayCalls"]})
            assert clean.returncode == 0 and "settled" in clean.stdout, clean.stderr
            assert not worktree.exists() and branch not in git(remote, "for-each-ref", "--format=%(refname)")

            # The stale sweep (#991) releases only claims idle for more than 72 h whose owner is absent.
            def sweep(name: str):
                result = call("release", "--stale")
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout.strip(),
                                 "stderr": result.stderr.strip()})
                assert result.returncode == 0, result.stderr
                return result

            def untouched(name: str, owner: str, age_hours: float, expect: str, **gateway):
                claim(owner, age_hours=age_hours)
                (worktree / "draft.txt").write_text("in-progress edit\n")
                fixture(**gateway)
                before = snapshot()
                result = sweep(name)
                assert expect in result.stdout and "releasing" not in result.stdout, result.stdout
                assert snapshot() == before, f"{name} changed refs, the worktree or GitHub"

            untouched("stale sweep keeps a recent absent-owner claim", ABSENT, 2, "released 0, kept 0",
                      sessions_listed=[idle_row])
            untouched("stale sweep keeps an absent-owner claim with a recent issue comment", ABSENT, 100,
                      "released 0, kept 0", sessions_listed=[idle_row],
                      comment_times=[time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))])
            untouched("stale sweep keeps an idle live owner", LIVE, 100, "is live",
                      sessions_listed=[idle_row, {"id": LIVE, "phase": "running", "activeSince": "2026-01-01T00:00:00Z"}])
            untouched("stale sweep keeps an idle resumable session", IDLE, 100, "is indeterminate", sessions_listed=[idle_row])
            untouched("stale sweep keeps a settled Home task owner's claim", SETTLED, 100, "is settled",
                      sessions_listed=[idle_row, {"id": SETTLED, "phase": "idle"}],
                      tasks=[{"taskId": "task-2", "lifecycle": "terminal", "sessionId": SETTLED}], statuses={"task-2": settled})

            claim(ABSENT, age_hours=100)
            stale_head = git(worktree, "rev-parse", "HEAD")
            (worktree / "draft.txt").write_text("in-progress edit\n")
            (worktree / "tracked.txt").write_text("stale unstaged edit\n")
            fixture(sessions_listed=[idle_row])
            result = sweep("stale sweep releases an idle absent-owner claim after preserving dirty files")
            assert "released 1 (#41)" in result.stdout, result.stdout
            assert not worktree.exists() and branch not in git(remote, "for-each-ref", "--format=%(refname)")
            gh_state = load()["gh"]
            assert gh_state["status"] == "Ready" and len(gh_state["comments"]) == 1 and "idle 4.2 days" in gh_state["comments"][0]
            stale_saved = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")) / f"work/releases/41-{stale_head[:12]}"
            restored_stale = root / "restored-stale"
            git(root, "clone", "-q", str(remote), str(restored_stale))
            git(restored_stale, "fetch", "-q", str(stale_saved / "claim.bundle"), "refs/work-release/*:refs/work-release/*")
            git(restored_stale, "checkout", "-q", f"refs/work-release/41/{stale_head[:12]}/worktree")
            assert (restored_stale / "draft.txt").read_bytes() == b"in-progress edit\n"
            assert (restored_stale / "tracked.txt").read_bytes() == b"stale unstaged edit\n"

            # A maintainer releases a legacy owner no Gateway knows, only from a real terminal with the exact phrase;
            # a Gateway-shaped idle session can be resumed, so force never releases it.
            claim(IDLE)
            fixture(sessions_listed=[idle_row])
            before = snapshot()
            forced = call("release", "41", "--reason", "legacy owner", "--force-maintainer")
            evidence.append({"case": "force never releases a resumable Gateway session", "exit": forced.returncode,
                             "stderr": forced.stderr.strip()})
            assert forced.returncode and "is indeterminate" in forced.stderr and snapshot() == before, forced.stderr
            claim("legacy-owner")
            fixture(sessions_listed=[idle_row])
            before = snapshot()
            forced = call("release", "41", "--reason", "legacy owner", "--force-maintainer")
            evidence.append({"case": "force requires a real terminal", "exit": forced.returncode, "stderr": forced.stderr.strip()})
            assert forced.returncode and "interactive terminal" in forced.stderr and snapshot() == before, forced.stderr

            def terminal(answer: bytes):
                pid, descriptor = pty.fork()
                if pid == 0:
                    os.chdir(repo)
                    os.execve(sys.executable, [sys.executable, str(ROOT / "tools/work/cli.py"), "release", "41",
                                               "--reason", "legacy owner", "--force-maintainer"], env)
                output, deadline = b"", time.monotonic() + 60
                while time.monotonic() < deadline and b"> " not in output:
                    if select.select([descriptor], [], [], 1)[0]:
                        try:
                            output += os.read(descriptor, 4096)
                        except OSError:
                            break
                os.write(descriptor, answer)
                while time.monotonic() < deadline:
                    if select.select([descriptor], [], [], 1)[0]:
                        try:
                            output += os.read(descriptor, 4096)
                        except OSError:
                            pass
                    waited, status = os.waitpid(pid, os.WNOHANG)
                    if waited:
                        break
                else:
                    os.kill(pid, 9)
                    _, status = os.waitpid(pid, 0)
                os.close(descriptor)
                return os.waitstatus_to_exitcode(status), output.decode(errors="replace")

            code, output = terminal(b"RELEASE #41 FROM unknown\n")
            evidence.append({"case": "force refuses a confirmation naming another owner", "exit": code, "output": output[-600:]})
            assert code and "did not match" in output and snapshot()[1:] == before[1:], output
            code, output = terminal(b"RELEASE #41 FROM legacy-owner\n")
            evidence.append({"case": "maintainer releases a legacy owner after exact confirmation", "exit": code, "output": output[-600:]})
            assert code == 0 and "released #41" in output, output
            assert not worktree.exists() and branch not in git(remote, "for-each-ref", "--format=%(refname)")
            assert "legacy-owner" in load()["gh"]["comments"][-1]
            print(f"Passed {len(evidence)} release journeys; evidence: {artifact}")
    finally:
        if server:
            server.terminate()
            server.wait(timeout=5)
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    run()
