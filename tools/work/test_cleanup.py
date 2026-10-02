"""Isolated checks for cleanup failure modes 53-62 in README.md.

Real temporary repositories: a local bare remote, a primary clone, and linked
task worktrees under the configured root. GitHub is a fake `gh` (WORK_GH) that
answers `pr list` from a JSON file of pull requests and records every call. A
merged pull request here is a squash merge that GitHub reports; the base branch
never contains the task head, as after a real squash merge.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

import claim as claims
import cleanup

REMOTE = "origin"
BASE = "main"

FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps(args) + "\\n")
    state = json.load(open(os.environ["FAKE_GH_STATE"]))
    def arg(name):
        return args[args.index(name) + 1] if name in args else None
    if args[:2] == ["pr", "list"]:
        if arg("--head") in state.get("failing", []):
            print("fake gh: HTTP 502", file=sys.stderr)
            sys.exit(1)
        wanted = (arg("--state") or "open").upper()
        pulls = [p for p in state["pulls"] if p["headRefName"] == arg("--head")
                 and (wanted == "ALL" or p["state"] == wanted)]
        fields = arg("--json").split(",")
        print(json.dumps([{k: p[k] for k in fields} for p in pulls]))
        sys.exit(0)
    print("fake gh: unhandled " + " ".join(args), file=sys.stderr)
    sys.exit(1)
    """
)

CONFIG = {
    "claim": {"remote": REMOTE, "baseBranch": BASE, "worktreeRoot": "../worktrees"},
    "cleanup": {
        "regenerableIgnored": ["**/node_modules/**", "**/build/**", "**/*.pyc"],
        "releaseCommands": [],
    },
}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class CleanupFixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.remote = self.tmp / "remote.git"
        git(self.tmp, "init", "-q", "--bare", "-b", BASE, str(self.remote))
        self.repo = self.tmp / "repo"
        git(self.tmp, "clone", "-q", str(self.remote), str(self.repo))
        git(self.repo, "config", "user.name", "Agent")
        git(self.repo, "config", "user.email", "agent@example.invalid")
        self.write(self.repo, ".gitignore", "node_modules/\nbuild/\n*.pyc\n*.secret\n")
        self.write(self.repo, "README.md", "one\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        git(self.repo, "push", "-q", REMOTE, f"HEAD:{BASE}")
        self.root = self.tmp / "worktrees"

        # Every release command appends the directory it ran in, so a test can
        # tell which worktrees were touched.
        self.released = self.tmp / "released"
        self.config = json.loads(json.dumps(CONFIG))
        self.config["cleanup"]["releaseCommands"] = [
            {"name": "release", "command": f"pwd -P >> {self.released}", "timeoutSeconds": 10},
        ]
        self.state_path = self.tmp / "state.json"
        self.gh_log = self.tmp / "gh.jsonl"
        self.pulls = []
        self.save_pulls()
        fake = self.tmp / "gh"
        fake.write_text(FAKE_GH.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        fake.chmod(0o755)
        env = {"WORK_GH": str(fake), "FAKE_GH_STATE": str(self.state_path), "FAKE_GH_LOG": str(self.gh_log)}
        saved = {key: os.environ.get(key) for key in [*env, "PATH"]}
        os.environ.update(env)
        self.addCleanup(self._restore, saved)
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)

    @staticmethod
    def _restore(saved: dict) -> None:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def write(repo: Path, relative: str, content: str) -> None:
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self, repo: Path, relative: str, content: str) -> str:
        self.write(repo, relative, content)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", f"change {relative}")
        return git(repo, "rev-parse", "HEAD")

    # --------------------------------------------------------------- tasks

    def task(self, number: int, merged: bool = True, directory=None, with_config: bool = False, **pull) -> tuple:
        """A claimed, committed and pushed task worktree; with merged, GitHub reports its PR merged at its head.

        with_config commits the fixture's work.json, so the CLI can run from inside the worktree.
        """
        branch = f"feat/{number}-task"
        claims.create_claim(self.repo, REMOTE, BASE, branch, number, "session-a")
        git(self.repo, "fetch", "-q", REMOTE)
        path = directory or self.root / f"{number}-task"
        # As `work start` does: the branch tracks its remote claim branch.
        git(self.repo, "worktree", "add", "-q", "--track", "-b", branch, str(path), f"{REMOTE}/{branch}")
        if with_config:
            head = self.commit(path, ".github/work.json", json.dumps(self.config))
        else:
            head = self.commit(path, f"src/{number}.txt", "work\n")
        git(path, "push", "-q", REMOTE, f"HEAD:refs/heads/{branch}")
        if merged:
            self.add_pull(branch, head, **pull)
        return path, branch, head

    def add_pull(self, branch: str, head: str, **fields) -> None:
        pull = {"number": 100 + len(self.pulls), "headRefName": branch, "headRefOid": head, "baseRefName": BASE,
                "isCrossRepository": False, "state": "MERGED", "url": "https://example.invalid/pull"}
        pull.update(fields)
        self.pulls.append(pull)
        self.save_pulls()

    def save_pulls(self, failing=()) -> None:
        """failing: branches whose `gh pr list` exits non-zero."""
        self.state_path.write_text(json.dumps({"pulls": self.pulls, "failing": list(failing)}))

    # ------------------------------------------------------------- observe

    def cleanup(self, cwd: Path, all_worktrees: bool = False, dry_run: bool = False) -> tuple:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                code = cleanup.run(cleanup.Gh(cwd), cwd, self.config, all_worktrees, dry_run)
            except cleanup.CleanupError as error:
                print(f"work: {error}")
                code = 1
        return code, out.getvalue()

    def released_in(self) -> list:
        return self.released.read_text().splitlines() if self.released.exists() else []

    def registered(self) -> list:
        return [line[len("worktree "):] for line in git(self.repo, "worktree", "list", "--porcelain").splitlines()
                if line.startswith("worktree ")]

    def local_branch(self, branch: str) -> str:
        return subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/heads/{branch}"], cwd=self.repo,
                              capture_output=True, text=True).stdout.strip()

    def remote_branch(self, branch: str) -> str:
        line = git(self.repo, "ls-remote", REMOTE, f"refs/heads/{branch}")
        return line.split()[0] if line else ""

    def assert_removed(self, path: Path, branch: str) -> None:
        self.assertFalse(path.exists())
        self.assertNotIn(str(path), self.registered())
        self.assertEqual(self.local_branch(branch), "")
        self.assertEqual(self.remote_branch(branch), "")
        self.assertEqual(self.branch_settings(branch), "")

    def branch_settings(self, branch: str) -> str:
        return subprocess.run(["git", "config", "--get-regexp", f"^branch\\.{branch}\\."], cwd=self.repo,
                              capture_output=True, text=True).stdout.strip()

    def run_cli(self, script: str, cwd: Path) -> subprocess.CompletedProcess:
        """Run a bash script with $CLI set to the real `work` entry point."""
        cli = Path(__file__).resolve().parent / "cli.py"
        return subprocess.run(["bash", "-c", f"CLI='{sys.executable} {cli}'\n{script}"], cwd=cwd,
                              capture_output=True, text=True, timeout=120)

    def assert_kept(self, path: Path, branch: str, head: str, remote=None) -> None:
        """Untouched: registered, both branches where they were, and no release command ran there."""
        self.assertTrue(path.is_dir())
        self.assertIn(str(path), self.registered())
        self.assertEqual(self.local_branch(branch), head)
        self.assertEqual(self.remote_branch(branch), remote or head)
        self.assertNotIn(str(path), self.released_in())


class MergedRemovalTests(CleanupFixture):
    # Failure mode 61: assert_removed also checks the branch's tracking settings are gone.
    def test_a_squash_merged_task_is_released_and_removed_with_both_branches(self):
        path, branch, head = self.task(7)
        self.assertNotEqual(self.branch_settings(branch), "")
        self.write(path, "node_modules/pkg/index.js", "x\n")  # regenerable, ignored
        self.write(path, "app/build/out.o", "x\n")
        # A squash merge: the base branch never contains the task head.
        self.assertNotEqual(subprocess.run(["git", "merge-base", "--is-ancestor", head, f"{REMOTE}/{BASE}"],
                                           cwd=self.repo).returncode, 0)
        code, out = self.cleanup(path)
        self.assertEqual(code, 0, out)
        self.assertEqual(self.released_in(), [str(path)])
        self.assert_removed(path, branch)
        self.assertEqual(git(self.repo, "rev-parse", "--abbrev-ref", "HEAD"), BASE)
        self.assertTrue((self.repo / "README.md").exists())

    # Failure mode 55: the owner's shell sits in the worktree it cleans up and
    # stays its parent, as when an agent runs `work cleanup` after `land`.
    def test_the_owner_runs_it_from_inside_the_worktree(self):
        path, branch, _ = self.task(7, with_config=True)
        shell = self.run_cli("$CLI cleanup; echo shell-cwd=$PWD", path)
        self.assertEqual(shell.returncode, 0, shell.stdout + shell.stderr)
        self.assertIn(f"shell-cwd={path}", shell.stdout)
        self.assertIn("removed:", shell.stdout)
        self.assert_removed(path, branch)


class UnmergedTests(CleanupFixture):
    # Failure mode 53.
    def test_work_that_github_does_not_report_merged_at_the_local_head_is_kept(self):
        cases = {
            "no pull request": {"merged": False},
            "open": {"state": "OPEN"},
            "closed unmerged": {"state": "CLOSED"},
            "fork with the same head name": {"isCrossRepository": True},
            "merged into another base": {"baseRefName": "release"},
        }
        for number, (name, pull) in enumerate(cases.items(), start=10):
            with self.subTest(case=name):
                path, branch, head = self.task(number, **pull)
                code, out = self.cleanup(path)
                self.assertEqual(code, 1, out)
                self.assert_kept(path, branch, head)

    def test_a_pull_request_merged_at_an_earlier_head_does_not_cover_later_commits(self):
        path, branch, merged_head = self.task(7)
        later = self.commit(path, "src/later.txt", "after the merge\n")
        code, out = self.cleanup(path)
        self.assertEqual(code, 1, out)
        self.assertIn(merged_head[:12], out)
        self.assert_kept(path, branch, later, remote=merged_head)

    def test_an_older_merged_pull_request_does_not_hide_the_one_at_the_head(self):
        path, branch, head = self.task(7)
        self.pulls.insert(0, dict(self.pulls[0], number=99, headRefOid="0" * 40))
        self.save_pulls()
        code, out = self.cleanup(path)
        self.assertEqual(code, 0, out)
        self.assert_removed(path, branch)


class LocalDataTests(CleanupFixture):
    # Failure mode 54.
    def test_uncommitted_untracked_or_valuable_ignored_files_keep_the_worktree(self):
        cases = {
            "modified": lambda p: self.write(p, "src/10.txt", "edited\n"),
            "staged": lambda p: (self.write(p, "src/staged.txt", "x\n"), git(p, "add", "src/staged.txt")),
            "untracked": lambda p: self.write(p, "notes.txt", "x\n"),
            "ignored, not regenerable": lambda p: self.write(p, "keys/prod.secret", "x\n"),
            "ignored inside an untracked directory": lambda p: self.write(p, "scratch/a.secret", "x\n"),
        }
        for number, (name, make) in enumerate(cases.items(), start=10):
            with self.subTest(case=name):
                path, branch, head = self.task(number)
                make(path)
                code, out = self.cleanup(path)
                self.assertEqual(code, 1, out)
                self.assert_kept(path, branch, head)
                if "ignored" in name:
                    self.assertIn(".secret", out)

    def test_an_operation_in_progress_or_a_lock_keeps_the_worktree(self):
        def marker(name, directory=False):
            def make(path):
                target = Path(git(path, "rev-parse", "--path-format=absolute", "--git-path", name))
                if directory:
                    target.mkdir()
                else:
                    target.write_text(git(path, "rev-parse", "HEAD") + "\n")
            return make

        cases = {
            "merge": marker("MERGE_HEAD"),
            "rebase": marker("rebase-merge", directory=True),
            "cherry-pick": marker("CHERRY_PICK_HEAD"),
            "revert": marker("REVERT_HEAD"),
            "bisect": marker("BISECT_LOG"),
            "locked": lambda p: git(self.repo, "worktree", "lock", "--reason", "in use", str(p)),
        }
        for number, (name, make) in enumerate(cases.items(), start=10):
            with self.subTest(case=name):
                path, branch, head = self.task(number)
                make(path)
                code, out = self.cleanup(path)
                self.assertEqual(code, 1, out)
                self.assertIn(name, out)
                self.assert_kept(path, branch, head)


class ProcessTests(CleanupFixture):
    # Failure mode 55.
    def test_another_process_working_inside_keeps_the_worktree(self):
        path, branch, head = self.task(7)
        sleeper = subprocess.Popen(["sleep", "60"], cwd=path)
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        code, out = self.cleanup(self.repo, all_worktrees=True)
        self.assertIn(str(sleeper.pid), out)
        self.assert_kept(path, branch, head)

    def test_an_ancestor_working_inside_another_worktree_keeps_it_under_all(self):
        # The shell sits in `held` and starts `--all` from `started`: only `started` exempts its ancestors.
        held, held_branch, held_head = self.task(7)
        started, started_branch, _ = self.task(8, with_config=True)
        shell = self.run_cli(f"(cd '{started}' && exec $CLI cleanup --all); echo shell-pid=$$", held)
        out = shell.stdout + shell.stderr
        self.assertEqual(shell.returncode, 0, out)
        shell_pid = out.rsplit("shell-pid=", 1)[1].strip()
        self.assertIn(f"pid {shell_pid} (bash)", out)
        self.assert_kept(held, held_branch, held_head)
        self.assert_removed(started, started_branch)

    def test_a_failing_lsof_proves_nothing(self):
        path, branch, head = self.task(7)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "lsof").write_text("#!/bin/sh\necho 'lsof: kernel says no' >&2\nexit 1\n")
        (bin_dir / "lsof").chmod(0o755)
        os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ['PATH']}"
        code, out = self.cleanup(path)
        self.assertEqual(code, 1, out)
        self.assertIn("lsof", out)
        self.assert_kept(path, branch, head)


class ScopeTests(CleanupFixture):
    # Failure mode 56.
    def test_the_primary_checkout_is_never_cleaned_up(self):
        branch = "feat/7-task"
        claims.create_claim(self.repo, REMOTE, BASE, branch, 7, "session-a")
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "checkout", "-q", "--track", "-b", branch, f"{REMOTE}/{branch}")
        head = git(self.repo, "rev-parse", "HEAD")
        self.add_pull(branch, head)
        # Also when a mistaken root contains the primary checkout.
        for root in ("../worktrees", ".."):
            with self.subTest(root=root):
                self.config["claim"]["worktreeRoot"] = root
                for all_worktrees in (False, True):
                    code, out = self.cleanup(self.repo, all_worktrees=all_worktrees)
                    self.assertTrue(self.repo.is_dir())
                    self.assertEqual(self.local_branch(branch), head)
                    self.assertEqual(self.remote_branch(branch), head)
                    self.assertEqual(self.released_in(), [])
                self.assertEqual(code, 0, out)
                code, out = self.cleanup(self.repo)
                self.assertEqual(code, 1, out)
                self.assertIn("primary checkout", out)

    def test_all_removes_only_done_worktrees_under_the_root_and_names_every_other(self):
        done, done_branch, _ = self.task(7)
        busy, busy_branch, busy_head = self.task(8, merged=False)
        outside, outside_branch, outside_head = self.task(9, directory=self.tmp / "elsewhere")
        detached = self.root / "detached"
        git(self.repo, "worktree", "add", "-q", "--detach", str(detached), BASE)
        plain = self.root / "plain"
        git(self.repo, "worktree", "add", "-q", "-b", "scratch", str(plain), BASE)
        self.add_pull("scratch", git(self.repo, "rev-parse", BASE))  # merged, but not a task's claim branch

        code, out = self.cleanup(busy, all_worktrees=True)
        self.assertEqual(code, 0, out)
        self.assert_removed(done, done_branch)
        self.assertEqual(self.released_in(), [str(done)])
        self.assert_kept(busy, busy_branch, busy_head)
        self.assert_kept(outside, outside_branch, outside_head)
        for tree in (detached, plain):
            self.assertIn(str(tree), self.registered())
        self.assertEqual(self.local_branch("scratch"), git(self.repo, "rev-parse", BASE))
        for name in ("worktrees/8-task", "worktrees/detached", "worktrees/plain", "1 worktree outside"):
            self.assertIn(name, out)
        self.assertNotIn("elsewhere", out)
        self.assertNotIn(str(self.tmp), out)

    def test_a_worktree_outside_the_root_is_refused(self):
        path, branch, head = self.task(9, directory=self.tmp / "elsewhere")
        code, out = self.cleanup(path)
        self.assertEqual(code, 1, out)
        self.assert_kept(path, branch, head)


class ErrorTests(CleanupFixture):
    # Failure mode 62.
    def test_an_error_on_one_worktree_keeps_it_and_the_rest_are_still_decided(self):
        broken, broken_branch, broken_head = self.task(7)
        done, done_branch, _ = self.task(8)
        busy, busy_branch, busy_head = self.task(9, merged=False)
        self.save_pulls(failing=[broken_branch])
        code, out = self.cleanup(self.repo, all_worktrees=True)
        self.assertEqual(code, 0, out)
        self.assertIn("HTTP 502", out)
        self.assert_kept(broken, broken_branch, broken_head)
        self.assert_removed(done, done_branch)
        self.assert_kept(busy, busy_branch, busy_head)
        self.assertIn("worktrees/9-task", out)


class ReleaseTests(CleanupFixture):
    # Failure mode 57.
    def test_a_failing_release_command_keeps_the_worktree(self):
        path, branch, head = self.task(7)
        self.config["cleanup"]["releaseCommands"].append(
            {"name": "simulator", "command": "echo lane still leased; exit 73", "timeoutSeconds": 10})
        code, out = self.cleanup(path)
        self.assertEqual(code, 1, out)
        self.assertIn("simulator", out)
        self.assertIn("lane still leased", out)
        self.assertTrue(path.is_dir())
        self.assertEqual(self.local_branch(branch), head)
        self.assertEqual(self.remote_branch(branch), head)

    def test_a_hanging_release_command_is_killed_at_its_timeout(self):
        path, branch, head = self.task(7)
        pid_file = self.tmp / "pid"
        self.config["cleanup"]["releaseCommands"] = [
            {"name": "hang", "command": f"sleep 60 & echo $! > {pid_file}; wait", "timeoutSeconds": 1}]
        started = time.monotonic()
        code, out = self.cleanup(path)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(code, 1, out)
        self.assertIn("hang", out)
        self.assertTrue(path.is_dir())
        self.assertEqual(self.local_branch(branch), head)
        grandchild = int(pid_file.read_text())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(grandchild, signal.SIGKILL)
            self.fail("the release command's process group outlived its timeout")


class MovedBranchTests(CleanupFixture):
    # Failure mode 58.
    def test_a_remote_branch_pushed_to_after_the_merge_is_kept(self):
        path, branch, head = self.task(7)
        other = self.tmp / "other"
        git(self.tmp, "clone", "-q", "-b", branch, str(self.remote), str(other))
        git(other, "config", "user.name", "Agent")
        git(other, "config", "user.email", "agent@example.invalid")
        moved = self.commit(other, "src/more.txt", "more\n")
        git(other, "push", "-q", REMOTE, f"HEAD:refs/heads/{branch}")
        code, out = self.cleanup(path)
        self.assertEqual(code, 0, out)
        self.assertFalse(path.exists())
        self.assertEqual(self.local_branch(branch), "")
        self.assertEqual(self.remote_branch(branch), moved)
        self.assertIn("kept", out)


class RecheckTests(CleanupFixture):
    # Failure mode 59.
    def test_work_done_while_release_commands_run_keeps_the_worktree(self):
        cases = {
            "commit": "git commit -q --allow-empty -m late",
            "new file": "echo late > late.txt",
        }
        for number, (name, command) in enumerate(cases.items(), start=10):
            with self.subTest(case=name):
                path, branch, head = self.task(number)
                self.config["cleanup"]["releaseCommands"] = [
                    {"name": "late", "command": command, "timeoutSeconds": 10}]
                code, out = self.cleanup(path)
                self.assertEqual(code, 1, out)
                self.assertTrue(path.is_dir())
                self.assertEqual(self.remote_branch(branch), head)
                self.assertEqual(self.local_branch(branch), git(path, "rev-parse", "HEAD"))


class DryRunTests(CleanupFixture):
    # Failure mode 60.
    def test_a_dry_run_reports_and_changes_nothing(self):
        path, branch, head = self.task(7)
        busy, busy_branch, busy_head = self.task(8, merged=False)
        for all_worktrees in (False, True):
            with self.subTest(all=all_worktrees):
                code, out = self.cleanup(path, all_worktrees=all_worktrees, dry_run=True)
                self.assertEqual(code, 0, out)
                self.assertIn("would remove", out)
                self.assertEqual(self.released_in(), [])
                self.assert_kept(path, branch, head)
                self.assert_kept(busy, busy_branch, busy_head)


if __name__ == "__main__":
    unittest.main()
