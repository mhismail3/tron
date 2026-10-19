#!/usr/bin/env python3
"""Source selection runs a real fetched Git tree, never a check receipt or dirty caller."""
import json
import os
from pathlib import Path
import shutil
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
        # The fetched leaf stands in for signing/build/publish only. The caller
        # below runs the real device entry point and real source/cleanup owner.
        script.write_text('''#!/bin/sh
set -eu
git rev-parse HEAD > "$SOURCE_REPORT"
printf "%s\\n" "$TRON_MAIN_SOURCE_ROOT" "$@" >> "$SOURCE_REPORT"
nested=packages/ios-app/build/DerivedData-fast-debug/SourcePackages/checkouts/generated
mkdir -p "$nested"
git -C "$nested" init -q
printf generated > "$nested/package"
git -C "$nested" add .
git -C "$nested" commit -q -m 'generated unpublished checkout'
exit "${BUILD_STATUS:-0}"
''')
        script.chmod(0o755)
        shutil.copy2(ROOT / "scripts/run-main-source.py", repo / "scripts/run-main-source.py")
        shutil.copytree(ROOT / "config", repo / "config")
        (repo / ".gitignore").write_text("packages/ios-app/build/\n")
        git(repo, "add", "."); git(repo, "commit", "-m", "main source"); git(repo, "push", "origin", "main")
        main_sha = git(repo, "rev-parse", "HEAD")
        git(repo, "checkout", "-b", "worker")
        shutil.copy2(ROOT / "scripts/tron-ios-device", script)
        (repo / "untracked").write_text("keep")
        # An existing caller-owned nested checkout is not this invocation's
        # generated output, even under the same ignored DerivedData path.
        user = repo / "packages/ios-app/build/DerivedData-fast-debug/SourcePackages/checkouts/user"
        user.mkdir(parents=True)
        git(user, "init", "-q")
        (user / "package").write_text("unpublished caller work")
        git(user, "add", "."); git(user, "commit", "-qm", "caller work")
        user_sha = git(user, "rev-parse", "HEAD")
        (user / "dirty").write_text("keep caller draft")
        before = git(repo, "status", "--porcelain")
        for operation in ("install", "share"):
            for status in (0, 7):
                result = subprocess.run([script, operation, "--fast-debug"],
                                        env={**env, "BUILD_STATUS": str(status)},
                                        text=True, capture_output=True, timeout=15)
                assert result.returncode == status, (operation, status, result.returncode, result.stdout, result.stderr)
                report = (root / "report").read_text().splitlines()
                assert report[0] == main_sha and not Path(report[1]).exists(), report
                assert report[2:] == [operation, "--fast-debug"], report
                assert git(repo, "status", "--porcelain") == before
                assert git(user, "rev-parse", "HEAD") == user_sha
                assert (user / "dirty").read_text() == "keep caller draft"
                registrations = git(repo, "worktree", "list", "--porcelain")
                assert len(registrations.split("worktree ")) == 2, registrations
        resolved = subprocess.check_output([sys.executable, ROOT / "scripts/run-main-source.py", "--root", repo], env=env, text=True).strip()
        assert resolved == main_sha
        artifact = ROOT / "test-results/main-source.json"
        artifact.parent.mkdir(exist_ok=True)
        artifact.write_text(json.dumps({"revision": main_sha, "cases": ["real install/share entry points", "success/failure nested-clone cleanup", "dirty caller and unpublished nested work preserved", "no receipts", "read-only source resolution"]}, indent=2) + "\n")
        print(f"Passed fetched-main source journey; evidence: {artifact}")


if __name__ == "__main__":
    main()
