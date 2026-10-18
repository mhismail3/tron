#!/usr/bin/env python3
"""Exercise work tracking through the real CLI, Git and a process-level gh fixture."""
from __future__ import annotations

import json
import os
import signal
import socket
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OPTIONS = {"done": "Done", "ready": "Ready", "in-progress": "In progress"}


def fixture_gh() -> None:
    path = Path(os.environ["WORK_CLOSE_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[1:]
    page = {"hasNextPage": False, "endCursor": None}
    response = None
    write = None
    response_error = None
    if args[:2] == ["repo", "view"]:
        response = {"id": "repo", "nameWithOwner": "fixture/project", "owner": {"login": "fixture"}}
    elif args[:2] == ["api", "graphql"]:
        request = json.load(sys.stdin)
        query = request["query"]
        if "addProjectV2ItemById" in query:
            write = "project-add"
            response = {"data": {"addProjectV2ItemById": {"item": {"id": "item"}}}}
        elif "mutation" in query:
            if state.pop("fail_status_once", False):
                path.write_text(json.dumps(state))
                print("fixture status transport failure", file=sys.stderr)
                sys.exit(1)
            state["status"] = OPTIONS[request["variables"]["option"]]
            write = "status"
            response = {"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "item"}}}}
            partial = state.pop("partial_status_once", None)
            if partial:
                # The write committed before a response-field error; GraphQL
                # non-null propagation can erase even the whole data object.
                response_error = "forbidden response field" + (" (HTTP 403)" if partial == "null-data" else "")
                response["errors"] = [{"type": "FORBIDDEN", "message": response_error}]
                if partial == "null-data":
                    response["data"] = None
        elif "repositoryOwner" in query:
            response = {"data": {"repositoryOwner": {"id": "owner", "projectsV2": {
                "pageInfo": page, "nodes": [{"id": "project", "title": "Tron",
                    "repositories": {"nodes": [{"id": "repo"}]}, "fields": {"nodes": [
                        {"id": "status", "name": "Status", "options": [
                            {"id": option, "name": label} for option, label in OPTIONS.items()]}]}}]}}}}
        elif "projectItems" in query:
            response = {"data": {"node": {"projectItems": {"pageInfo": page, "nodes": [
                {"id": "item", "project": {"id": "project", "title": "Tron"}}]}}}}
    elif args[:3] == ["api", "-X", "POST"] and args[3].endswith("/issues"):
        created = json.load(sys.stdin)
        state.setdefault("created", []).append(created)
        write = "create"
        response = {"number": 77, "node_id": "created-issue", **created}
    elif args[:3] == ["api", "-X", "PATCH"]:
        state["edited"] = json.load(sys.stdin)
        write = "edit"
        response = {"number": 41}
    elif args[:3] == ["api", "-X", "GET"]:
        response = {"number": 41, "node_id": "issue", "state": state["state"],
                    "labels": [{"name": state.get("label", "epic")} ]}
    elif args[:3] == ["api", "--paginate", "--slurp"]:
        if "/sub_issues" in args[3]:
            if state.get("fail_children"):
                print("fixture children unavailable", file=sys.stderr)
                sys.exit(1)
            response = state["child_pages"]
        elif args[3].endswith("/comments"):
            response = [[{"body": body} for body in state["comments"]]]
    elif args[:2] == ["issue", "comment"]:
        if state.pop("reject_comment_once", False):
            path.write_text(json.dumps(state))
            print("HTTP 403: forbidden", file=sys.stderr)
            sys.exit(1)
        state["comments"].append(sys.stdin.read())
        write = "comment"
    elif args[:2] == ["issue", "close"]:
        state["state"] = "closed"
        state["reason"] = args[args.index("--reason") + 1]
        write = "close"
    elif args[:2] == ["issue", "reopen"]:
        state["state"] = "open"
        write = "reopen"
    else:
        raise AssertionError(f"Unexpected fixture gh invocation: {args}")
    if write:
        state["writes"].append(write)
    path.write_text(json.dumps(state))
    barrier = state.get("hold_comment") if write == "comment" else None
    if barrier:
        # Signal after the service accepted the comment, while the CLI's audit
        # attempt is durable but its terminal result is still outstanding.
        with socket.create_connection(("127.0.0.1", barrier["port"]), timeout=60) as peer:
            peer.sendall((barrier["tag"] + "\n").encode())
            if peer.recv(1) != b"1":
                raise RuntimeError("fixture comment barrier closed before release")
    print(json.dumps(response))
    if response_error:
        print(f"GraphQL: {response_error}", file=sys.stderr)
        sys.exit(1)


def run() -> None:
    evidence = []
    artifact = ROOT / "test-results" / "work-close.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-close-") as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            home, tmp = root / "home", root / "tmp"
            home.mkdir()
            tmp.mkdir()
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp),
                   "WORK_GH": str(Path(__file__).resolve()), "WORK_SESSION_ID": "fixture-owner",
                   "WORK_CLOSE_FIXTURE": str(root / "github.json"), "PYTHONDONTWRITEBYTECODE": "1",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}

            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, env=env, check=True,
                                      text=True, capture_output=True).stdout.strip()

            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("commit", "--allow-empty", "-m", "fixture base")
            remote = root / "remote.git"
            git("init", "--bare", str(remote))
            git("remote", "add", "origin", str(remote))
            git("push", "origin", "main")
            (repo / ".github").mkdir()
            shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            comment = root / "close.md"
            comment.write_text("Verified all linked tasks are finished.\n")
            state_path = Path(env["WORK_CLOSE_FIXTURE"])

            def reset(**updates):
                state = {"state": "open", "comments": [], "writes": [], "status": "Ready",
                         "child_pages": [[{"number": 42, "state": "closed"}]]}
                state.update(updates)
                state_path.write_text(json.dumps(state))

            def close(name, success, reason="completed"):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "issue", "close", "41",
                                         "--reason", reason, "--comment-file", str(comment)],
                                        cwd=repo, env=env, capture_output=True, text=True, timeout=30)
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                assert (result.returncode == 0) == success, evidence[-1]
                return json.loads(state_path.read_text()), result.stderr

            def audit_outcome(operation):
                records = [json.loads(line) for line in (repo / ".git/work/github-writes.jsonl").read_text().splitlines()]
                attempt = next(row for row in reversed(records) if row["event"] == "attempt" and row["operation"] == operation)
                return next(row["status"] for row in reversed(records) if row["event"] == "result" and row["id"] == attempt["id"])

            reset()
            state, _ = close("completed epic", True)
            assert audit_outcome("graphql.mutation") == "succeeded"
            assert state["state"] == "closed" and state["status"] == "Done"
            assert state["writes"] == ["comment", "close", "status"]
            state, _ = close("same close is idempotent", True)
            assert len(state["comments"]) == 1 and state["writes"].count("close") == 1

            # Ordinary checkpoints are supported without claim/session trailers.
            # Closing is tracking only: preserve the published ref and unpublished work.
            git("checkout", "-b", "experiment/41-checkpoint")
            (repo / "result.txt").write_text("Published result.\n")
            git("add", "result.txt")
            git("commit", "-m", "Save experiment result")
            published = git("rev-parse", "HEAD")
            git("push", "origin", "experiment/41-checkpoint")
            (repo / "result.txt").write_text("Unpublished follow-up.\n")
            git("commit", "-am", "Preserve follow-up")
            local = git("rev-parse", "HEAD")
            (repo / "result.txt").write_text("Uncommitted continuation.\n")
            reset(label="kind:bug")
            state, _ = close("ordinary checkpoint without claim marker closes", True)
            assert state["state"] == "closed" and state["status"] == "Done"
            assert state["writes"] == ["comment", "close", "status"]
            assert git("ls-remote", "origin", "refs/heads/experiment/41-checkpoint").split()[0] == published
            assert git("rev-parse", "HEAD") == local
            assert (repo / "result.txt").read_text() == "Uncommitted continuation.\n"
            git("push", "origin", "--delete", "experiment/41-checkpoint")
            (repo / "result.txt").write_text("Unpublished follow-up.\n")
            git("checkout", "main")

            # Claims already landed by plain Git do not gate closure either.
            git("checkout", "-b", "feat/41-landed")
            git("commit", "--allow-empty", "-m", "claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: fixture-owner\nWork-Claim-Base: main")
            git("push", "origin", "HEAD:refs/heads/feat/41-landed", "HEAD:main")
            reset()
            state, _ = close("owner closes after plain push to main", True)
            assert state["state"] == "closed"
            git("push", "origin", "--delete", "feat/41-landed")
            git("checkout", "main")

            reset(child_pages=[[{"number": 42, "state": "closed"}], [{"number": 143, "state": "open"}]])
            state, error = close("open child on later page", False)
            assert "#143" in error and not state["writes"]
            state, _ = close("not-planned cannot bypass open children", False, "not_planned")
            assert not state["writes"]

            reset(fail_children=True)
            state, _ = close("child read fails closed", False)
            assert not state["writes"]

            reset(reject_comment_once=True)
            state, _ = close("known single-write REST rejection", False)
            assert not state["writes"] and not state["comments"]
            assert audit_outcome("issue.comment") == "failed"
            evidence[-1]["auditOutcome"] = audit_outcome("issue.comment")

            for partial in ("partial-data", "null-data"):
                reset(partial_status_once=partial)
                state, error = close(f"GraphQL committed before error ({partial})", False)
                assert "forbidden response field" not in error, "opaque GitHub reply was exposed"
                outcome = audit_outcome("graphql.mutation")
                evidence[-1].update({"remoteStatus": state["status"], "auditOutcome": outcome})
                assert state["state"] == "closed" and state["status"] == "Done"
                assert outcome == "uncertain", evidence[-1]
                state, _ = close(f"explicit recovery after GraphQL error ({partial})", True)
                assert state["status"] == "Done" and len(state["comments"]) == 1
                assert state["writes"].count("close") == 1
                assert audit_outcome("graphql.mutation") == "succeeded"

            reset(fail_status_once=True)
            state, _ = close("partial status failure", False)
            assert state["state"] == "closed" and state["status"] == "Ready"
            state, _ = close("retry finishes partial close", True)
            assert state["status"] == "Done" and len(state["comments"]) == 1

            reset(label="kind:bug", child_pages=[[{"number": 42, "state": "open"}]])
            state, _ = close("ordinary task unchanged", True)
            assert state["state"] == "closed"

            reset()
            git("checkout", "-b", "feat/41-foreign")
            git("commit", "--allow-empty", "-m", "Claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: other-owner")
            git("push", "origin", "feat/41-foreign")
            git("checkout", "main")
            foreign = git("rev-parse", "feat/41-foreign")
            state, _ = close("another session's claim does not gate closure", True)
            assert state["state"] == "closed" and state["status"] == "Done"
            assert git("ls-remote", "origin", "refs/heads/feat/41-foreign").split()[0] == foreign
            assert git("rev-parse", "feat/41-foreign") == foreign

            reset(state="closed")
            state, _ = close("already closed elsewhere still accepts evidence and Status Done", True)
            assert state["writes"] == ["comment", "status"] and state["status"] == "Done"
            state, _ = close("repeat externally closed completion is idempotent", True)
            assert len(state["comments"]) == 1 and "close" not in state["writes"]

            audit_path = repo / ".git/work/github-writes.jsonl"
            linked = root / "audit-linked"
            git("worktree", "add", "-b", "audit-linked", str(linked), "main")
            for relative in (".github/work.json", "scripts/personal-info-guard.sh"):
                target = linked / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(repo / relative, target)

            for mode in ("concurrent", "reservation"):
                healthy = audit_path.read_bytes()
                if mode == "reservation":
                    # Use measured production record sizes, not a mocked cap or
                    # reserve. There is space for one result, but not two pairs.
                    free = 2 * (attempt_bytes + result_bytes) - 32
                    padding = 16 * 1024 * 1024 - free - len(healthy)
                    audit_path.write_bytes(healthy[:-1] + b" " * padding + b"\n")
                start_size = audit_path.stat().st_size
                detail = {"case": f"{mode} comments across linked worktrees"}
                evidence.append(detail)
                jobs, peers, states = {}, {}, {}
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    listener.listen(2)
                    listener.settimeout(60)

                    def launch(tag, directory, held):
                        state_file = root / f"{mode}-{tag}.json"
                        states[tag] = state_file
                        state_file.write_text(json.dumps({"comments": [], "writes": [],
                            "hold_comment": {"port": listener.getsockname()[1], "tag": tag} if held else None}))
                        body_file = root / f"{mode}-{tag}.md"
                        body_file.write_text(f"Audit comment {mode}-{tag}.\n")
                        jobs[tag] = subprocess.Popen([sys.executable, str(ROOT / "tools/work/cli.py"),
                            "comment", "41" if tag == "A" else "42", "--body-file", str(body_file)],
                            cwd=directory, env={**env, "WORK_CLOSE_FIXTURE": str(state_file),
                                                "WORK_SESSION_ID": f"fixture-{tag}"},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)

                    def arrived(tag):
                        peer, _ = listener.accept()
                        peers[tag] = peer
                        peer.settimeout(60)
                        with peer.makefile("rb") as stream:
                            assert stream.readline(64) == (tag + "\n").encode()

                    def finish(tag):
                        output, error = jobs[tag].communicate(timeout=60)
                        detail[tag] = {"exit": jobs[tag].returncode, "stderr": error}
                        return jobs[tag].returncode, error

                    try:
                        launch("A", repo, True)
                        arrived("A")
                        first_pending = audit_path.read_bytes()
                        launch("B", linked, mode == "concurrent")
                        if mode == "concurrent":
                            arrived("B")
                            lines = audit_path.read_bytes()[start_size:].splitlines(keepends=True)
                            pending = [json.loads(line) for line in lines]
                            detail["pendingAttempts"] = len(pending)
                            assert len(pending) == 2 and all(row["event"] == "attempt" for row in pending), detail
                            assert pending[0]["id"] != pending[1]["id"]
                            # Reverse completion order must not confuse receipt ownership.
                            peers["B"].sendall(b"1")
                            assert finish("B")[0] == 0, detail
                            interim = [json.loads(line) for line in audit_path.read_bytes()[start_size:].splitlines()]
                            assert len(interim) == 3 and interim[-1]["id"] == pending[1]["id"]
                        else:
                            code, error = finish("B")
                            detail["refusedRemoteWrites"] = json.loads(states["B"].read_text())["writes"]
                            assert code != 0 and "audit is full" in error, detail
                            assert not detail["refusedRemoteWrites"]
                            assert audit_path.read_bytes() == first_pending, "refusal altered outstanding history"
                        peers["A"].sendall(b"1")
                        assert finish("A")[0] == 0, detail
                        lines = audit_path.read_bytes()[start_size:].splitlines(keepends=True)
                        rows = [json.loads(line) for line in lines]
                        attempts = [row["id"] for row in rows if row["event"] == "attempt"]
                        results = [row for row in rows if row["event"] == "result"]
                        assert [row["id"] for row in results] == list(reversed(attempts))
                        assert all(row["status"] == "succeeded" for row in results)
                        assert len(rows) == (4 if mode == "concurrent" else 2)
                        assert b"Audit comment" not in b"".join(lines), "comment body entered private audit"
                        assert audit_path.stat().st_size <= 16 * 1024 * 1024
                        if mode == "concurrent":
                            attempt_bytes, result_bytes = len(lines[0]), len(lines[2])
                        for tag in ("A", "B") if mode == "concurrent" else ("A",):
                            remote = json.loads(states[tag].read_text())
                            assert remote["writes"] == ["comment"] and len(remote["comments"]) == 1
                        detail["resultCount"] = len(results)
                    finally:
                        for peer in peers.values():
                            try:
                                peer.sendall(b"1")
                            except OSError:
                                pass
                            peer.close()
                        # Each CLI has a fresh process group: timeout cleanup
                        # must join its gh child too, not orphan a held request.
                        for job in jobs.values():
                            try:
                                job.communicate(timeout=10)
                            except subprocess.TimeoutExpired:
                                os.killpg(job.pid, signal.SIGKILL)
                                job.communicate(timeout=10)
                        detail["allJobsJoined"] = all(job.poll() is not None for job in jobs.values())
                        detail["finalBytes"] = audit_path.stat().st_size
                        if mode == "reservation":
                            # Only this fixture restores its seed; production
                            # must retain its result, never rotate to make room.
                            audit_path.write_bytes(healthy)

            # Audit admission is a real on-disk boundary, not a mocked Gh method.
            # Repeated complete history fills the documented cap; a torn suffix
            # comes directly from a record the production CLI already wrote.
            commands = (
                ("close", ["issue", "close", "41", "--reason", "completed", "--comment-file", str(comment)]),
                ("labels", ["issue", "labels", "41", "--add", "area:ios"]),
                ("Project", ["project", "set", "41", "--status", "Ready"]),
            )
            for failure, cause in (("full", "audit is full"), ("torn", "unreadable record")):
                healthy = audit_path.read_bytes()
                refused_history = healthy * ((16 * 1024 * 1024) // len(healthy) + 1) if failure == "full" else healthy[:-2]
                audit_path.write_bytes(refused_history)
                for operation, arguments in commands:
                    reset(label="kind:bug")
                    result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), *arguments],
                                            cwd=repo, env=env, capture_output=True, text=True, timeout=30)
                    state = json.loads(state_path.read_text())
                    preserved = audit_path.read_bytes() == refused_history
                    evidence.append({"case": f"{failure} audit refuses {operation} before dispatch",
                                     "exit": result.returncode, "stderr": result.stderr,
                                     "historyBytes": len(refused_history), "historyPreserved": preserved,
                                     "remoteWrites": state["writes"]})
                    assert result.returncode != 0 and not state["writes"], evidence[-1]
                    assert state["state"] == "open" and state["status"] == "Ready" and not state["comments"]
                    assert preserved, evidence[-1]
                    assert cause in result.stderr, evidence[-1]
                # Only the fixture owner restores its input. The CLI must never
                # truncate/rotate history or silently recover a refused audit.
                audit_path.write_bytes(healthy)
                reset(label="kind:bug")
                state, _ = close(f"explicit recovery with readable audit after {failure}", True)
                assert state["state"] == "closed" and state["status"] == "Done" and len(state["comments"]) == 1

            # Filing (#992, #994): a task is classified and on the Project in one command; every
            # refusal happens before any GitHub write.
            body = root / "issue.md"

            def create(name, success, *extra, title="Composer drops a chip", text="The chip is replaced.\n"):
                body.write_text(text)
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "issue", "create",
                                         "--title", title, "--body-file", str(body), *extra],
                                        cwd=repo, env=env, capture_output=True, text=True, timeout=30)
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                assert (result.returncode == 0) == success, evidence[-1]
                return json.loads(state_path.read_text()), result.stderr

            reset()
            state, error = create("task without a kind refused", False, "--area", "area:ios")
            assert "--kind" in error and not state["writes"]
            state, error = create("task without an area refused", False, "--kind", "kind:bug")
            assert "--area" in error and not state["writes"]
            state, error = create("undeclared label refused", False, "--kind", "kind:bug", "--area", "area:nowhere")
            assert "not a declared area" in error and not state["writes"]
            state, error = create("template title prefix refused", False, "--kind", "kind:bug", "--area", "area:ios",
                                  title="[Task]: Composer drops a chip")
            assert "prefix" in error and not state["writes"]
            state, error = create("wait-for-recurrence issue without an exit refused", False, "--kind", "kind:bug",
                                  "--area", "area:gateway", text="Not reproducible; keep open until the next failure.\n")
            assert "--exit-by" in error and not state["writes"]
            state, _ = create("classified task filed onto the Project", True, "--kind", "kind:bug", "--area", "area:ios",
                              "--area", "area:gateway", "--exit-by", "2099-01-31",
                              text="Not reproducible; keep open until the next failure.\n")
            filed = state["created"][-1]
            assert filed["labels"] == ["kind:bug", "area:ios", "area:gateway"], filed
            assert "Exit by: 2099-01-31." in filed["body"] and state["status"] == "Ready"
            assert state["writes"] == ["create", "project-add", "status"], state["writes"]
            reset()
            state, _ = create("epic filed with the epic label only", True, "--type", "epic")
            assert state["created"][-1]["labels"] == ["epic"] and state["writes"] == ["create", "project-add", "status"]
            reset()
            body.write_text("## Remaining\nOnly the iOS half is left.\n")
            edited = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "issue", "edit", "41",
                                     "--body-file", str(body)], cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            evidence.append({"case": "body edited to the remaining scope", "exit": edited.returncode, "stderr": edited.stderr})
            state = json.loads(state_path.read_text())
            assert edited.returncode == 0 and state["edited"] == {"body": "## Remaining\nOnly the iOS half is left.\n"}
            assert state["writes"] == ["edit"]

            reason = root / "reopen.md"
            git("push", "origin", "--delete", "feat/41-foreign")

            def reopen(name, success):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "issue", "reopen", "41",
                                         "--comment-file", str(reason)],
                                        cwd=repo, env=env, capture_output=True, text=True, timeout=30)
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                assert (result.returncode == 0) == success, evidence[-1]
                return json.loads(state_path.read_text()), result.stderr

            # An issue closed by mistake (for example by a PR's closing keyword) reopens only with a stated reason.
            reset(state="closed", status="Done", label="kind:bug")
            reason.write_text("  \n")
            state, error = reopen("reopen without a reason refused", False)
            assert "must not be empty" in error and not state["writes"]
            reason.write_text("Closed by a closing keyword in an unrelated PR; the bug is unfixed.\n")
            state, _ = reopen("unclaimed reopen", True)
            assert state["state"] == "open" and state["status"] == "Ready"
            assert state["writes"] == ["comment", "reopen", "status"]
            assert "unrelated PR" in state["comments"][0] and "<!-- work:reopen digest=" in state["comments"][0]
            state, _ = reopen("same reopen is idempotent", True)
            assert len(state["comments"]) == 1 and state["writes"].count("reopen") == 1

            reset(label="kind:bug")
            state, error = reopen("open issue it did not reopen refused", False)
            assert "is open" in error and not state["writes"]

            # A claim survives the mistaken close: reopening returns the issue to its owner, In progress.
            reset(state="closed", status="Done", label="kind:bug", fail_status_once=True)
            git("push", "origin", "feat/41-foreign")
            state, _ = reopen("partial status failure", False)
            assert state["state"] == "open" and state["status"] == "Done"
            state, _ = reopen("retry finishes claimed reopen", True)
            assert state["status"] == "In progress" and len(state["comments"]) == 1
            assert state["writes"] == ["comment", "reopen", "status"]
            audit = (repo / ".git/work/github-writes.jsonl").read_text()
            assert '"issue.reopen"' in audit and "unrelated PR" not in audit
        print(f"Passed {len(evidence)} real-CLI work-tracking journeys; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("WORK_CLOSE_FIXTURE") and sys.argv[1:2] in (["api"], ["repo"], ["issue"]):
        fixture_gh()
    else:
        run()
