#!/usr/bin/env python3
"""Execute the shipped Git skill's Integrate block against real remotes and conflicts."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SKILL = ROOT / ".agents/skills/tron-work/SKILL.md"


class GitSkill(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tron-git-skill-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {**os.environ, "HOME": str(self.root / "home"), "TMPDIR": str(self.root),
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.remote, self.repo, self.task = (self.root / name for name in ("remote.git", "repo", "task"))
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.root, "clone", str(self.remote), str(self.repo))
        self.commit(self.repo, "file", "base\n")
        self.git(self.repo, "push", "origin", "main")
        self.git(self.repo, "worktree", "add", "-b", "task", str(self.task))

    def git(self, cwd, *args):
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def commit(self, repo, path, content):
        (repo / path).write_text(content)
        self.git(repo, "add", path)
        self.git(repo, "commit", "-m", "change " + path)

    def skill(self, heading):
        match = re.search(r"^## " + re.escape(heading) + r"\n.*?```bash\n(.*?)```", SKILL.read_text(), re.M | re.S)
        self.assertIsNotNone(match, f"Missing executable skill block: {heading}")
        return subprocess.run(["bash", "-e", "-c", match[1]], cwd=self.task, env=self.env,
                              capture_output=True, text=True, timeout=15)


    def test_conflict_keeps_unpublished_head_and_remote(self):
        self.commit(self.task, "file", "worker\n")
        head = self.git(self.task, "rev-parse", "HEAD")
        self.commit(self.repo, "file", "concurrent\n")
        self.git(self.repo, "push", "origin", "main")
        before = self.git(self.remote, "rev-parse", "main")
        result = self.skill("Integrate")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.task, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(self.remote, "rev-parse", "main"), before)
        self.assertIn("<<<<<<<", (self.task / "file").read_text())

    def test_uncommitted_and_untracked_work_is_not_discarded(self):
        self.commit(self.task, "worker", "worker\n")
        (self.task / "file").write_text("uncommitted\n")
        (self.task / "untracked").write_text("keep\n")
        before = self.git(self.task, "status", "--porcelain")
        result = self.skill("Integrate")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.task, "status", "--porcelain"), before)
        self.assertEqual((self.task / "file").read_text(), "uncommitted\n")
        self.assertEqual((self.task / "untracked").read_text(), "keep\n")

    def test_fetch_snapshot_does_not_need_siblings_tracking_ref_lock(self):
        self.commit(self.task, "worker", "worker\n")
        other = self.root / "other"
        self.git(self.root, "clone", str(self.remote), str(other))
        self.commit(other, "concurrent", "another worker\n")
        self.git(other, "push", "origin", "main")
        tracked = self.git(self.task, "rev-parse", "origin/main")
        lock = Path(self.git(self.task, "rev-parse", "--path-format=absolute", "--git-path", "refs/remotes/origin/main.lock"))
        lock.write_text("sibling owns this lock\n")
        result = self.skill("Integrate")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.task, "rev-parse", "origin/main"), tracked)
        self.assertEqual(lock.read_text(), "sibling owns this lock\n")
        self.assertEqual(self.git(self.task, "show", "HEAD:concurrent"), "another worker")
        self.assertNotEqual(self.git(self.task, "rev-parse", "--git-path", "FETCH_HEAD"),
                            self.git(self.repo, "rev-parse", "--git-path", "FETCH_HEAD"))


    def test_retired_commands_are_not_executable_aliases(self):
        for command in ("dashboard", "status", "land", "review-export"):
            with self.subTest(command=command):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), command, "--help"],
                                        cwd=self.task, env=self.env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__":
    unittest.main()
