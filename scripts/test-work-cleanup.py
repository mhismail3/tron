#!/usr/bin/env python3
"""Plain-git landed work is cleaned only when its issue is closed and its tree clean."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/work"))
import cleanup


class ClosedIssue:
    def run(self, *args):
        assert args[:2] == ("issue", "view"), args
        return '{"state":"CLOSED"}'


def run():
    evidence = []
    with tempfile.TemporaryDirectory(prefix="tron-work-cleanup-") as temporary:
        root = Path(temporary)
        repo, remote, worktree = root / "repo", root / "remote.git", root / "tree"
        env = {**os.environ, "HOME": str(root), "TMPDIR": str(root), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": "/dev/null"}
        def git(cwd, *args):
            return subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                                  capture_output=True, text=True).stdout.strip()
        git(root, "init", "--bare", str(remote))
        git(root, "clone", str(remote), str(repo))
        git(repo, "checkout", "-b", "main")
        git(repo, "config", "user.name", "Fixture")
        git(repo, "config", "user.email", "fixture@example.invalid")
        (repo / "tracked").write_text("base\n")
        git(repo, "add", "."); git(repo, "commit", "-m", "base")
        git(repo, "push", "origin", "main")
        branch = "feat/41-fixture"
        git(repo, "worktree", "add", "-b", branch, str(worktree))
        (worktree / "tracked").write_text("candidate\n")
        git(worktree, "commit", "-am", "candidate")
        git(worktree, "push", "origin", branch)
        git(worktree, "push", "origin", "HEAD:main")
        head = git(worktree, "rev-parse", "HEAD")
        tree = cleanup.Worktree(worktree, head, branch, None, False)
        settings = cleanup.Settings(repo, root, "origin", "main", [], [], repo)
        (worktree / "untracked").write_text("preserve")
        done, reasons = cleanup._blockers(ClosedIssue(), tree, settings)
        assert done is not None and any("untracked" in reason for reason in reasons), reasons
        assert (worktree / "untracked").read_text() == "preserve"
        (worktree / "untracked").unlink()
        done, reasons = cleanup._blockers(ClosedIssue(), tree, settings)
        assert done is not None and not reasons, reasons
        ok, detail = cleanup._remove(ClosedIssue(), tree, settings, done)
        assert ok and not worktree.exists(), detail
        assert git(repo, "ls-remote", "--heads", "origin", branch) == ""
        assert git(repo, "rev-parse", "origin/main") == head
        evidence.append({"case": "plain push, closed issue, dirty preservation, exact branch cleanup", "head": head})
    artifact = ROOT / "test-results/work-cleanup.json"
    artifact.parent.mkdir(exist_ok=True)
    artifact.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Passed plain-git cleanup journey; evidence: {artifact}")


if __name__ == "__main__":
    run()
