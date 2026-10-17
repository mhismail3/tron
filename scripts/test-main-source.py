#!/usr/bin/env python3
"""Source selection runs a real fetched Git tree, never a check receipt or dirty caller."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="tron-source-test-") as directory:
        root = Path(directory)
        env = {**os.environ, "HOME": str(root), "TMPDIR": str(root), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Fixture",
               "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_NAME": "Fixture",
               "GIT_COMMITTER_EMAIL": "fixture@example.invalid", "SOURCE_REPORT": str(root / "report")}
        def git(cwd, *args):
            return subprocess.check_output(["git", *args], cwd=cwd, env=env, stderr=subprocess.PIPE, text=True).strip()
        remote, repo = root / "remote.git", root / "repo"
        git(root, "init", "--bare", "--initial-branch=main", str(remote))
        git(root, "clone", str(remote), str(repo))
        (repo / "scripts").mkdir()
        script = repo / "scripts/tron-ios-device"
        script.write_text('#!/bin/sh\ngit rev-parse HEAD > "$SOURCE_REPORT"\nprintf "%s\\n" "$TRON_MAIN_SOURCE_ROOT" >> "$SOURCE_REPORT"\nmkdir generated\nexit "${BUILD_STATUS:-0}"\n')
        script.chmod(0o755)
        git(repo, "add", "."); git(repo, "commit", "-m", "main source"); git(repo, "push", "origin", "main")
        main_sha = git(repo, "rev-parse", "HEAD")
        git(repo, "checkout", "-b", "worker")
        script.write_text('#!/bin/sh\nexit 99\n')
        (repo / "untracked").write_text("keep")
        before = git(repo, "status", "--porcelain")
        for status in (0, 7):
            result = subprocess.run([sys.executable, ROOT / "scripts/run-main-source.py", "--root", repo,
                                     "--", "scripts/tron-ios-device", "install"], env={**env, "BUILD_STATUS": str(status)},
                                    text=True, capture_output=True, timeout=15)
            assert result.returncode == status, result.stdout + result.stderr
            report = (root / "report").read_text().splitlines()
            assert report[0] == main_sha and not Path(report[1]).exists(), report
            assert git(repo, "status", "--porcelain") == before
            assert len(git(repo, "worktree", "list", "--porcelain").split("worktree ")) == 2
        resolved = subprocess.check_output([sys.executable, ROOT / "scripts/run-main-source.py", "--root", repo], env=env, text=True).strip()
        assert resolved == main_sha
        artifact = ROOT / "test-results/main-source.json"
        artifact.parent.mkdir(exist_ok=True)
        artifact.write_text(json.dumps({"revision": main_sha, "cases": ["success", "failure cleanup", "dirty caller preserved", "no receipts", "read-only source resolution"]}, indent=2) + "\n")
        print(f"Passed fetched-main source journey; evidence: {artifact}")


if __name__ == "__main__":
    main()
