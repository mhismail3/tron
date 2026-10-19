#!/usr/bin/env python3
"""Real CLI/Git regressions: claim coordination never discards a worker's checkout."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
# Reuse the release journey's public API fixtures, not work-tool internals.
sys.path.insert(0, str(ROOT / "scripts"))
import importlib.util
spec = importlib.util.spec_from_file_location("release_journey", ROOT / "scripts/test-work-release.py")
journey = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journey)


def run():
    artifact = ROOT / "test-results/work-coordination.json"
    artifact.parent.mkdir(exist_ok=True)
    evidence = []
    selected = sys.argv[1:]
    if not selected:
        # Each journey owns a fresh Git remote: a landed claim must not seed
        # another case's checkpoint with its historical ownership trailers.
        try:
            for case in ("self-release", "published-release", "handoff", "landed-release", "checkpoint-start"):
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()), case], timeout=120)
                evidence.extend(json.loads(artifact.read_text()))
                if result.returncode:
                    raise SystemExit(result.returncode)
        finally:
            artifact.write_text(json.dumps(evidence, indent=2) + "\n")
        return
    server = None
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-coordination-") as scratch:
            root = Path(scratch)
            repo, home, tmp = (root / name for name in ("repo", "home", "tmp"))
            for path in (repo, home, tmp):
                path.mkdir()
            state, gh = root / "state.json", root / "gh"
            gh.write_text(journey.GH)
            gh.chmod(0o755)
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "WORK_GH": str(gh),
                   "FIXTURE": str(state), "WORK_SESSION_ID": journey.LIVE,
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            def git(*args, cwd=repo):
                return subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()
            def call(name, *args):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), *args],
                                        cwd=repo, env=env, capture_output=True, text=True, timeout=90)
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                assert result.returncode == 0, evidence[-1]
                return result
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (repo / ".github").mkdir()
            config = json.loads((ROOT / ".github/work.json").read_text())
            config["cleanup"]["releaseCommands"] = []
            (repo / ".github/work.json").write_text(json.dumps(config))
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            (repo / "tracked.txt").write_text("base\n")
            git("add", ".")
            git("commit", "-m", "base")
            git("init", "--bare", str(root / "remote.git"))
            git("remote", "add", "origin", str(root / "remote.git"))
            git("push", "origin", "main")
            credential = home / ".tron/gateway/local-auth.json"
            credential.parent.mkdir(parents=True)
            credential.write_text(json.dumps({"version": 2, "bearerToken": journey.TOKEN, "purpose": "local-wrapper-health", "lastUpdated": "2025-01-01T00:00:00.000Z"}))
            credential.chmod(0o600)
            port = root / "port"
            server = subprocess.Popen([str(ROOT / "scripts/tron-node"), "exec", "node", "-e", journey.GATEWAY],
                env={**env, "WS_MODULE": str(ROOT / "packages/gateway/node_modules/ws"), "FIXTURE_TOKEN": journey.TOKEN, "PORT_FILE": str(port)}, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 10
            while not port.exists() and time.monotonic() < deadline and server.poll() is None:
                time.sleep(.05)
            assert port.exists(), "fixture Gateway did not listen"
            env.update(TRON_GATEWAY_HOST="127.0.0.1", TRON_GATEWAY_PORT=port.read_text())
            for name in ("self-release", "published-release", "handoff", "landed-release", "checkpoint-start"):
                if selected and name not in selected:
                    continue
                state.write_text(json.dumps({"gatewayCalls": [], "gateway": {"sessions": [{"id": journey.LIVE, "phase": "running"}], "tasks": [], "statuses": {}}, "gh": {
                    "state": "OPEN", "status": "In progress", "comments": [], "writes": [], "failComment": False}}))
                branch = "feat/41-fixture"
                path = root / "tron-worktrees/41-fixture"
                if name == "landed-release":
                    landed = git("commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m",
                                 f"claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: {journey.LIVE}\nWork-Claim-Base: main\n")
                    git("update-ref", "refs/heads/main", landed)
                    git("push", "origin", "main", f"{landed}:refs/heads/{branch}")
                    call(name, "release", "41", "--reason", "already landed, no local checkout")
                    assert not git("ls-remote", "origin", f"refs/heads/{branch}")
                    assert git("rev-parse", "main") == landed
                    continue
                if name == "checkpoint-start":
                    git("push", "origin", "main:refs/heads/experiment/41-checkpoint")
                    checkpoint = git("ls-remote", "origin", "refs/heads/experiment/41-checkpoint").split()[0]
                    git("push", "origin", f"main:refs/heads/{branch}")
                    call(name, "start", "41")
                    assert git("ls-remote", "origin", "refs/heads/experiment/41-checkpoint").split()[0] == checkpoint
                    assert git("ls-remote", "origin", f"refs/heads/{branch}").split()[0] == checkpoint
                    # A real second owner remains protected: start is not implicit takeover.
                    env["WORK_SESSION_ID"] = "other-worker"
                    refused = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "start", "41"],
                                             cwd=repo, env=env, capture_output=True, text=True, timeout=90)
                    assert refused.returncode and "already claimed" in refused.stderr, refused.stderr
                    evidence.append({"case": "start preserves real foreign owner", "exit": refused.returncode, "stderr": refused.stderr})
                    break
                git("branch", "-f", branch, "main")
                git("worktree", "add", str(path), branch)
                git("commit", "--allow-empty", "-m", f"claim\n\nWork-Claim-Issue: 41\nWork-Claim-Session: {journey.LIVE}\nWork-Claim-Base: main\n", cwd=path)
                if name == "published-release":
                    (path / "published.txt").write_text("published work\n")
                    git("add", ".", cwd=path)
                    git("commit", "-m", "work, not an empty claim", cwd=path)
                git("push", "origin", branch)
                (path / "tracked.txt").write_text("unstaged\n")
                (path / "staged.txt").write_text("staged\n")
                git("add", "staged.txt", cwd=path)
                (path / "untracked.txt").write_text("untracked\n")
                head = git("rev-parse", "HEAD", cwd=path)
                before = git("status", "--porcelain", cwd=path), (path / "tracked.txt").read_bytes(), git("diff", "--cached", cwd=path)
                if name == "handoff":
                    call(name, "handoff", "41", "--session", "successor", "--reason", "explicit transfer, preserve checkout")
                    assert git("rev-parse", "HEAD^", cwd=path) == head
                    assert git("rev-parse", "HEAD^{tree}", cwd=path) == git("rev-parse", f"{head}^{{tree}}", cwd=path)
                else:
                    call(name, "release", "41", "--reason", "park work and release coordination")
                    assert not git("ls-remote", "origin", f"refs/heads/{branch}")
                    assert git("rev-parse", "HEAD", cwd=path) == head
                    common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"))
                    manifests = list((common / "work/releases").glob("41-*/manifest.json"))
                    assert manifests
                    manifest = json.loads(manifests[-1].read_text())
                    bundle = manifests[-1].parent / "claim.bundle"
                    git("bundle", "verify", str(bundle))
                    assert git("show", f"{manifest['snapshot']}:untracked.txt") == "untracked"
                assert path.is_dir() and before == (git("status", "--porcelain", cwd=path), (path / "tracked.txt").read_bytes(), git("diff", "--cached", cwd=path))
                assert (path / "untracked.txt").read_text() == "untracked\n"
                evidence[-1]["preservedHead"] = head
                if name == "self-release":
                    restarted = call("release then start preserves parked work", "start", "41")
                    assert "feat/41-fixture-2" in restarted.stdout, restarted.stdout
                    assert git("rev-parse", "HEAD", cwd=path) == head
                    assert before == (git("status", "--porcelain", cwd=path), (path / "tracked.txt").read_bytes(), git("diff", "--cached", cwd=path))
                    git("push", "origin", ":refs/heads/feat/41-fixture-2")
                    git("worktree", "remove", str(root / "tron-worktrees/41-fixture-2"))
                    git("branch", "-D", "feat/41-fixture-2")
                if git("ls-remote", "origin", f"refs/heads/{branch}"):
                    git("push", "origin", f":refs/heads/{branch}")
                git("worktree", "remove", "--force", str(path))
                git("branch", "-D", branch)
            print(f"Passed coordination journeys; evidence: {artifact}")
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            server.stderr.close()
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    run()
