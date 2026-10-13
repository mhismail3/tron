#!/usr/bin/env python3
"""Exercise merged-worktree cleanup and retained evidence with real temporary Git repositories."""
from __future__ import annotations
import json, os, subprocess, sys, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/work"))
import cleanup


def run() -> None:
    evidence = []
    artifact = ROOT / "test-results/work-cleanup.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tron-work-cleanup-") as temp:
        root = Path(temp); repo = root / "repo"; repo.mkdir(); remote = root / "remote.git"
        def git(cwd: Path, *args: str) -> str:
            return subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True, check=True).stdout.strip()
        git(repo, "init", "-b", "main"); git(repo, "config", "user.name", "Fixture"); git(repo, "config", "user.email", "fixture@example.invalid")
        (repo / "tracked").write_text("base\n"); git(repo, "add", "tracked"); git(repo, "commit", "-m", "base")
        git(root, "init", "--bare", str(remote)); git(repo, "remote", "add", "origin", str(remote)); git(repo, "push", "-u", "origin", "main")
        branch = "feat/41-fixture"; git(repo, "checkout", "-b", branch)
        (repo / "tracked").write_text("candidate\n"); git(repo, "commit", "-am", "candidate"); head = git(repo, "rev-parse", "HEAD"); git(repo, "push", "-u", "origin", branch); git(repo, "checkout", "main")
        tree_path = root / "worktree"; git(repo, "worktree", "add", str(tree_path), branch)
        private_git = Path(git(tree_path, "rev-parse", "--path-format=absolute", "--git-dir"))
        source = private_git / "work/logs" / head[:12]; source.mkdir(parents=True); (source / "test.log").write_text("exact-head evidence\n")
        common = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")); old = common / "work/logs/old-head"; old.mkdir(parents=True); os.utime(old, (time.time()-31*86400, time.time()-31*86400))
        tree = cleanup.Worktree(tree_path, head, branch, None, False)
        settings = cleanup.Settings(repo, root, "origin", "main", [], [], repo)
        ok, detail = cleanup._remove(None, tree, settings, cleanup.Done("PR #41 merged", False))
        destination = common / "work/logs" / head[:12]
        assert ok and not tree_path.exists() and (destination / "test.log").read_text() == "exact-head evidence\n", detail
        assert str(destination) in detail and not old.exists(), detail
        assert git(repo, "ls-remote", "--heads", "origin", branch) == ""
        evidence.append({"case":"merged-head logs retained in common Git dir, old evidence pruned, worktree and remote branch removed", "head":head, "destination":str(destination), "detail":detail})
    artifact.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Passed merged cleanup evidence journey; evidence: {artifact}")

if __name__ == "__main__": run()
