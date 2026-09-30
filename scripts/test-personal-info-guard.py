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

    def check_text(self, text, expected):
        result = subprocess.run(["bash", str(self.guard), "--stdin"], cwd=self.root, env=self.env,
                                input=text, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_stdin_text_uses_the_same_needles(self):
        # Text posted to public GitHub is outside the repository inventory.
        self.check_text("Checks passed in <repo> and ~/Workspace\n", 0)
        for text in (NEEDLE + "/Workspace/x", "line one\nby " + DEVELOPER_WORD + "\n",
                     "github.com/" + DEVELOPER_WORD, "mh" + "ismail3/tron"):
            with self.subTest(text=text):
                self.check_text("clean first line\n" + text, 1)

    def test_stdin_ignores_the_repository(self):
        self.put("packages/gateway/fixture.ts", NEEDLE, staged=True)
        self.check_text("generic evidence", 0)

    def test_git_errors_fail_closed(self):
        for operation, staged in (("grep", True), ("diff", True), ("ls-files", False)):
            with self.subTest(operation=operation):
                self.put("packages/gateway/clean.ts", "generic", staged=True)
                shim = self.put("bin/git", '#!/bin/sh\nif [ "$1" = "' + operation + '" ]; then echo "controlled git failure" >&2; exit 42; fi\nexec "' + self.git + '" "$@"\n')
                shim.chmod(0o700)
                env = {**self.env, "PATH": str(shim.parent) + os.pathsep + self.env["PATH"]}
                output = self.check_guard(2, staged=staged, env=env)
                self.assertIn("failed", output)


class PreCommitHookInstallTests(unittest.TestCase):
    """scripts/install-hooks.sh must arm the one shared pre-commit hook from any worktree.

    Failure modes:
    1. Run from a linked worktree, where `.git` is a file, the installer fails or
       writes hooks Git never reads, so that worktree commits unguarded.
    2. The hook lands in a per-worktree location, so the main checkout and other
       linked worktrees commit unguarded.
    3. A relative hooks path resolves against the caller's directory instead of
       the repository, so running the installer from elsewhere misplaces the hook.
    4. `core.hooksPath` redirects Git's hooks, possibly to a directory that does
       not exist yet, and the installer fails or writes where Git never looks.
    """

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tron-hook-install-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.main = self.base / "main"
        self.linked = self.base / "linked"
        self.git = shutil.which("git")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        (self.main / "scripts").mkdir(parents=True)
        for script in ("install-hooks.sh", "personal-info-guard.sh"):
            shutil.copy2(ROOT / "scripts" / script, self.main / "scripts" / script)
        self.run_git(self.main, "init", "--quiet")
        self.run_git(self.main, "add", "scripts")
        self.run_git(self.main, "commit", "--quiet", "--no-verify", "-m", "fixture")
        self.run_git(self.main, "worktree", "add", "--quiet", "-b", "linked", str(self.linked))

    def run_git(self, cwd, *args, check=True):
        return subprocess.run([self.git, *args], cwd=cwd, env=self.env, check=check,
                              capture_output=True, text=True, timeout=30)

    def install_from(self, checkout, cwd):
        result = subprocess.run(["bash", str(checkout / "scripts/install-hooks.sh")], cwd=cwd,
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_commit_guarded(self, checkout, name):
        head = self.run_git(checkout, "rev-parse", "HEAD").stdout
        (checkout / f"{name}.txt").write_text(NEEDLE)
        self.run_git(checkout, "add", "--", f"{name}.txt")
        rejected = self.run_git(checkout, "commit", "-m", "leak", check=False)
        self.assertNotEqual(rejected.returncode, 0, rejected.stdout + rejected.stderr)
        self.assertIn("personal-info offender", rejected.stdout + rejected.stderr)
        self.assertEqual(self.run_git(checkout, "rev-parse", "HEAD").stdout, head)
        (checkout / f"{name}.txt").write_text("generic")
        self.run_git(checkout, "add", "--", f"{name}.txt")
        accepted = self.run_git(checkout, "commit", "-m", "clean", check=False)
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
        self.assertIn("✅ OK", accepted.stdout + accepted.stderr)

    def test_linked_worktree_install_guards_every_worktree(self):
        self.install_from(self.linked, self.linked)
        self.assert_commit_guarded(self.linked, "linked")
        self.assert_commit_guarded(self.main, "main")

    def test_install_from_outside_the_repository_targets_the_repository(self):
        outside = self.base / "outside"
        outside.mkdir()
        self.install_from(self.main, outside)
        self.assertFalse((outside / ".git").exists())
        self.assert_commit_guarded(self.main, "main")
        self.assert_commit_guarded(self.linked, "linked")

    def test_configured_hooks_path_receives_the_hook(self):
        hooks = self.base / "configured-hooks"
        self.run_git(self.main, "config", "core.hooksPath", str(hooks))
        self.install_from(self.linked, self.linked)
        self.assertTrue((hooks / "pre-commit").is_file())
        self.assert_commit_guarded(self.main, "main")


if __name__ == "__main__":
    unittest.main()
