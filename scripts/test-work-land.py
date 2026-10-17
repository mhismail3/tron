#!/usr/bin/env python3
"""Real Git boundary: independent landing, conflicts, races, and no check/gh owner."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Landing(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tron-plain-land-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {**os.environ, "HOME": str(self.root / "home"), "TMPDIR": str(self.root),
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.remote, self.repo = self.root / "remote.git", self.root / "repo"
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.root, "clone", str(self.remote), str(self.repo))
        (self.repo / "file").write_text("base\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "base")
        self.git(self.repo, "push", "origin", "main")
        for directory in ("scripts", "tools/work", ".github"):
            (self.repo / directory).mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / "scripts/tron", self.repo / "scripts/tron")
        # Copy executable work tooling, not a parallel landing implementation.
        for path in (ROOT / "tools/work").glob("*.py"):
            shutil.copy(path, self.repo / "tools/work" / path.name)
        (self.repo / ".github/work.json").write_text('{"claim":{"remote":"origin","baseBranch":"main"}}')
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "tooling")
        self.git(self.repo, "push", "origin", "main")
        self.git(self.repo, "worktree", "add", "-b", "task", str(self.root / "task"))
        self.task = self.root / "task"

    def git(self, cwd, *args, ok=True):
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def commit(self, repo, path, text):
        (repo / path).write_text(text)
        self.git(repo, "add", path)
        self.git(repo, "commit", "-m", "change " + path)

    def land(self, *args):
        return subprocess.run([str(self.task / "scripts/tron"), "work", "land", *args], cwd=self.task,
                              env=self.env, text=True, capture_output=True, timeout=15)

    def test_merges_new_main_and_pushes_without_tests_receipts_or_github(self):
        self.commit(self.task, "worker", "worker\n")
        self.commit(self.repo, "concurrent", "another worker\n")
        self.git(self.repo, "push", "origin", "main")
        landed = self.land()
        self.assertEqual(landed.returncode, 0, landed.stdout + landed.stderr)
        tip = self.git(self.remote, "rev-parse", "main")
        self.assertEqual(tip, self.git(self.task, "rev-parse", "HEAD"))
        self.assertEqual(self.git(self.remote, "show", "main:worker"), "worker")
        self.assertEqual(self.git(self.remote, "show", "main:concurrent"), "another worker")
        self.assertFalse((self.repo / ".git/work/gate").exists())
        self.assertFalse((self.repo / ".git/work/land").exists())

    def test_conflict_preserves_work_and_does_not_push(self):
        self.commit(self.task, "file", "worker\n")
        self.commit(self.repo, "file", "concurrent\n")
        self.git(self.repo, "push", "origin", "main")
        before = self.git(self.remote, "rev-parse", "main")
        result = self.land()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.remote, "rev-parse", "main"), before)
        self.assertIn("<<<<<<<", (self.task / "file").read_text())

    def test_dirty_work_refuses_and_dry_run_does_not_merge_or_push(self):
        self.commit(self.task, "worker", "worker\n")
        before = self.git(self.remote, "rev-parse", "main")
        result = self.land("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.remote, "rev-parse", "main"), before)
        (self.task / "untracked").write_text("keep")
        self.assertNotEqual(self.land().returncode, 0)
        self.assertEqual((self.task / "untracked").read_text(), "keep")

    def test_push_race_is_not_force_pushed_or_retried(self):
        self.commit(self.task, "worker", "worker\n")
        # A receive hook commits another worker's main just before our push.
        # update-ref changes the expected old OID, so Git's own CAS refuses us.
        old = self.git(self.remote, "rev-parse", "main")
        tree = self.git(self.remote, "rev-parse", "main^{tree}")
        rival = subprocess.run(["git", "commit-tree", tree, "-p", old, "-m", "rival"], cwd=self.remote,
                               env=self.env, capture_output=True, text=True, check=True).stdout.strip()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text(f'#!/bin/sh\nenv -u GIT_QUARANTINE_PATH git update-ref refs/heads/main {rival} {old}\n')
        hook.chmod(0o755)
        result = self.land()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.remote, "rev-parse", "main"), rival)
        self.assertEqual(self.git(self.task, "show", "HEAD:worker"), "worker")


if __name__ == "__main__":
    unittest.main()
