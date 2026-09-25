#!/usr/bin/env python3
"""Exercise the real privacy guard in disposable Git repos, never the user's index."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
# Independent known-bad input, split so fixtures don't themselves ship the identity.
DEVELOPER_WORD = "m" + "oose"
NEEDLE = "/Users/" + DEVELOPER_WORD


class PersonalInfoGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tron-privacy-guard-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.guard = self.root / "scripts/personal-info-guard.sh"
        self.guard.parent.mkdir()
        shutil.copyfile(ROOT / "scripts/personal-info-guard.sh", self.guard)
        self.git = shutil.which("git")
        # Hook/alternate-index variables must never redirect this fixture to a
        # caller's repository. User Git config is not part of the test input.
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.run_git("init", "--quiet")

    def run_git(self, *args):
        return subprocess.run([self.git, *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True, timeout=10)

    def put(self, relative, content, staged=False):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        if staged:
            self.run_git("add", "-f", "--", relative)
        return path

    def check_guard(self, expected, staged=False, env=None):
        result = subprocess.run(
            ["bash", str(self.guard), *(["--staged"] if staged else [])],
            cwd=self.root, env=self.env if env is None else env, capture_output=True, text=True, timeout=15,
        )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, expected, output)
        if expected:
            self.assertNotIn("✅ OK", output)
        return output

    def test_clean_repo_and_guard_itself_pass(self):
        self.run_git("add", "scripts/personal-info-guard.sh")
        self.put("new-root/clean.txt", "Generic product diagnostics")
        self.check_guard(0)
        self.check_guard(0, staged=True)

    def test_all_tracked_roots_are_scanned(self):
        for relative in (
            "packages/gateway/fixture.ts", "packages/push-relay/fixture.ts",
            "config/fixture.env", ".agents/fixture.md", ".pi/fixture.md",
            "new-client/fixture.swift", "root-fixture.txt",
        ):
            with self.subTest(path=relative):
                path = self.put(relative, NEEDLE, staged=True)
                try:
                    self.check_guard(1)
                finally:
                    path.write_text("generic")
                    self.run_git("add", "--", relative)

    def test_untracked_input_is_scanned_before_commit(self):
        for relative in ("packages/gateway/untracked.ts", ".agents/untracked.md", "future-root/new.txt"):
            with self.subTest(path=relative):
                path = self.put(relative, NEEDLE)
                try:
                    self.check_guard(1)
                finally:
                    path.unlink()

    def test_tracked_input_is_not_hidden_by_ignore_rules_or_retired_allowlists(self):
        self.put(".gitignore", "generated/\nnode_modules/\n")
        for relative in ("generated/source.txt", "node_modules/owned-source.txt"):
            with self.subTest(path=relative):
                path = self.put(relative, NEEDLE, staged=True)
                try:
                    self.check_guard(1)
                    self.check_guard(1, staged=True)
                finally:
                    path.write_text("generic")
                    self.run_git("add", "-f", "--", relative)

    def test_staged_blobs_not_worktree_are_the_commit_authority(self):
        path = self.put("packages/gateway/fixture.ts", NEEDLE, staged=True)
        path.write_text("generic")
        self.check_guard(1, staged=True)
        self.check_guard(0)
        self.run_git("add", "--", "packages/gateway/fixture.ts")
        path.write_text(NEEDLE)
        self.check_guard(0, staged=True)
        self.check_guard(1)

    def test_staged_pathspecs_are_literal_and_nul_safe(self):
        for relative in ("packages/gateway/[fixture].ts", "packages/gateway/line\nbreak.ts", "space dir/:(glob)*.txt", "-leading.txt"):
            with self.subTest(path=relative):
                path = self.put(relative, NEEDLE, staged=True)
                try:
                    self.check_guard(1, staged=True)
                finally:
                    path.write_text("generic")
                    self.run_git("add", "--", relative)
        self.check_guard(0, staged=True)

    def test_removed_worktree_file_does_not_hide_staged_blob(self):
        path = self.put("packages/gateway/removed.ts", NEEDLE, staged=True)
        path.unlink()
        self.check_guard(1, staged=True)

    def test_bare_identity_word_boundaries_are_portable(self):
        path = self.put("packages/gateway/fixture.ts", "(" + DEVELOPER_WORD + ")", staged=True)
        self.check_guard(1)
        self.check_guard(1, staged=True)
        path.write_text("prefix" + DEVELOPER_WORD + "suffix")
        self.check_guard(0)

    def test_git_errors_fail_closed(self):
        for operation, staged in (("grep", True), ("diff", True), ("ls-files", False)):
            with self.subTest(operation=operation):
                self.put("packages/gateway/clean.ts", "generic", staged=True)
                shim = self.put("bin/git", '#!/bin/sh\nif [ "$1" = "' + operation + '" ]; then echo "controlled git failure" >&2; exit 42; fi\nexec "' + self.git + '" "$@"\n')
                shim.chmod(0o700)
                env = {**self.env, "PATH": str(shim.parent) + os.pathsep + self.env["PATH"]}
                output = self.check_guard(2, staged=staged, env=env)
                self.assertIn("failed", output)


if __name__ == "__main__":
    unittest.main()
