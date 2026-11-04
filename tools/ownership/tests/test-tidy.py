#!/usr/bin/env python3
"""CLI tests for `scripts/tron tidy` (tools/ownership/README.md, "Workspace hygiene").

Each case builds a disposable primary checkout with a bare origin, linked worktrees in the
sibling `<repo>-worktrees/` directory and ignored residue, copies the real `scripts/tron`
and `tools/ownership/*.py`, and runs the command as a worker would:

1. The report names untracked files, ignored paths with no named writer (including empty
   ignored directories Git does not list), bytecode, scratch older than 7 days and
   evidence older than 14 days (by the newest file inside), orphan worktree directories,
   tooling no code names, and a pre-commit hook that differs from install-hooks.sh.
2. A report run deletes nothing.
3. `--prune` removes only expired scratch/evidence, bytecode, branches merged into
   origin/main (not merely into a local, unpushed main) that no worktree has checked out (printing the restore command) and merged
   worktrees with no local files, no process inside and no HEAD activity for 3 days.
   Unmerged work, ignored local files such as `.env.local`, a live process, recent
   activity, residue and orphan directories are kept.
4. Without `lsof` no worktree is pruned, and a `.scratch` symlink to a directory outside
   the checkout is neither aged nor pruned.

The last run's output is kept in `test-results/tidy-cli/` for review.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "test-results" / "tidy-cli"
DAY = 86400
IGNORE = ".scratch/\ntest-results/\n__pycache__/\n.env.local\njunk/\ntmp/\n*.log\n"


def age(path: Path, days: float) -> None:
    stamp = time.time() - days * DAY
    os.utime(path, (stamp, stamp), follow_symlinks=False)


class Fixture:
    def __init__(self, base: Path):
        self.base = base
        self.origin = base / "origin.git"
        self.repo = base / "repo"
        self.trees = base / "repo-worktrees"
        home = base / "home"
        home.mkdir()
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        self.processes: list[subprocess.Popen] = []
        self.git(base, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.git(base, "init", "-q", "-b", "main", str(self.repo))
        for relative in ("scripts/tron", "scripts/install-hooks.sh"):
            self.copy(relative)
        for tool in (ROOT / "tools/ownership").glob("*.py"):
            self.copy(str(tool.relative_to(ROOT)))
        self.write(".gitignore", IGNORE)
        self.write("scripts/used.sh", "#!/bin/bash\n# Fixture helper another script calls.\n")
        self.write("scripts/caller.sh", "#!/bin/bash\n# Fixture caller.\nbash scripts/used.sh\n")
        self.write("scripts/unused.sh", "#!/bin/bash\n# Fixture helper nothing calls.\n")
        self.commit(self.repo, "base")
        self.git(self.repo, "remote", "add", "origin", str(self.origin))
        self.git(self.repo, "push", "-q", "origin", "main")
        self.git(self.repo, "fetch", "-q", "origin")

    def copy(self, relative: str) -> None:
        target = self.repo / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)

    def git(self, cwd: Path, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=cwd, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, content: str = "x\n", root: Path | None = None) -> Path:
        target = (root or self.repo) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return target

    def commit(self, cwd: Path, message: str, days_old: float = 0) -> None:
        self.git(cwd, "add", "-A")
        when = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - days_old * DAY))
        subprocess.run(["git", "commit", "-q", "--no-verify", "-m", message], cwd=cwd, check=True, capture_output=True,
                       env={**self.env, "GIT_COMMITTER_DATE": when, "GIT_AUTHOR_DATE": when})

    def worktree(self, name: str, *, merged: bool, idle_days: float) -> Path:
        path = self.trees / name
        self.git(self.repo, "worktree", "add", "-q", "-b", name, str(path), "main")
        self.write(f"{name}.txt", name, root=path)
        self.commit(path, name)
        if merged:
            self.git(self.repo, "merge", "-q", "--no-ff", "--no-edit", name)
            self.git(self.repo, "push", "-q", "origin", "main")
            self.git(self.repo, "fetch", "-q", "origin")
        gitdir = Path(self.git(path, "rev-parse", "--absolute-git-dir"))
        for name_ in ("HEAD", "logs/HEAD"):
            age(gitdir / name_, idle_days)
        return path

    def branch(self, name: str, *, merged: bool, days_old: float = 0) -> str:
        self.git(self.repo, "branch", name, "main")
        self.git(self.repo, "checkout", "-q", name)
        self.write(f"{name}.txt", name)
        self.commit(self.repo, name, days_old)
        sha = self.git(self.repo, "rev-parse", "HEAD")
        self.git(self.repo, "checkout", "-q", "main")
        if merged:
            self.git(self.repo, "merge", "-q", "--no-ff", "--no-edit", name)
            self.git(self.repo, "push", "-q", "origin", "main")
            self.git(self.repo, "fetch", "-q", "origin")
        return sha

    def live(self, path: Path) -> None:
        self.processes.append(subprocess.Popen(["sleep", "120"], cwd=path))

    def tidy(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        result = subprocess.run([str(self.repo / "scripts/tron"), "tidy", *args], cwd=self.repo,
                                env=env or self.env, capture_output=True, text=True, check=False)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron tidy {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        return result

    def close(self) -> None:
        for process in self.processes:
            process.kill()
            process.wait()


class TidyCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-tidy-")
        self.f = Fixture(Path(self.temp.name).resolve())
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.f.close)

    def report(self, *args: str, env: dict | None = None) -> dict:
        result = self.f.tidy("--json", *args, env=env)
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        return json.loads(result.stdout)


class ReportTests(TidyCase):
    def residue(self) -> None:
        f = self.f
        f.write("notes.txt")
        f.write("junk/thing")
        (f.repo / "tmp").mkdir()
        f.write("app.log")
        f.write("tools/ownership/__pycache__/x.pyc")
        age(f.write(".scratch/old.js"), 10)
        f.write(".scratch/new.js")
        old_dir = f.write(".scratch/olddir/fresh.md").parent
        age(old_dir, 30)
        age(f.write("test-results/run-1/report.json"), 20)
        age(f.repo / "test-results/run-1", 20)
        age(f.write("test-results/run-2/report.json"), 10)
        (f.trees / "orphan").mkdir(parents=True)

    def test_report_names_each_kind_of_drift_and_deletes_nothing(self) -> None:
        f = self.f
        self.residue()
        before = sorted(str(p) for p in f.base.rglob("*"))
        result = f.tidy()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        out = result.stdout
        repo = str(f.repo)
        self.assertIn(f"tidy: untracked: {repo}/notes.txt — commit it with an owner, move it to .scratch/, or delete it", out)
        for residue in ("junk", "tmp", "app.log"):
            self.assertIn(f"tidy: residue: {repo}/{residue} — ignored path with no named writer", out)
        self.assertIn(f"tidy: bytecode: {repo}/tools/ownership/__pycache__", out)
        self.assertIn(f"tidy: expired: {repo}/.scratch/old.js", out)
        self.assertIn(f"tidy: expired: {repo}/test-results/run-1", out)
        for kept in (".scratch/new.js", ".scratch/olddir", "test-results/run-2"):
            self.assertNotIn(f"tidy: expired: {repo}/{kept}", out)
        self.assertIn(f"tidy: orphan_worktree_dirs: {f.trees}/orphan — not a registered worktree", out)
        self.assertIn("tidy: dead_tooling: scripts/unused.sh — no code, config or test names it", out)
        self.assertNotIn("tidy: dead_tooling: scripts/used.sh", out)
        self.assertIn("tidy: hook:", out)
        self.assertEqual(before, sorted(str(p) for p in f.base.rglob("*")))

    def test_managed_hook_is_not_reported(self) -> None:
        f = self.f
        subprocess.run(["bash", "scripts/install-hooks.sh"], cwd=f.repo, env=f.env, check=True, capture_output=True)
        self.assertEqual(self.report()["hook"], [])


class PruneTests(TidyCase):
    def setUp(self) -> None:
        super().setUp()
        f = self.f
        self.idle = f.worktree("merged-idle", merged=True, idle_days=5)
        self.local = f.worktree("merged-local", merged=True, idle_days=5)
        f.write(".env.local", "TOKEN=fixture\n", root=self.local)
        self.busy = f.worktree("merged-live", merged=True, idle_days=5)
        f.live(self.busy)
        self.recent = f.worktree("merged-recent", merged=True, idle_days=0.5)
        self.unmerged = f.worktree("unmerged", merged=False, idle_days=20)
        self.done = f.branch("done", merged=True)
        self.wip = f.branch("wip", merged=False)
        f.branch("local-only", merged=False, days_old=20)  # merged into this checkout's main, never pushed
        f.git(f.repo, "merge", "-q", "--no-ff", "--no-edit", "local-only")
        age(f.write(".scratch/old.js"), 10)
        f.write(".scratch/new.js")
        f.write("tools/ownership/__pycache__/x.pyc")
        f.write("junk/thing")
        (f.trees / "orphan").mkdir()

    def test_prune_removes_only_what_main_already_has(self) -> None:
        f = self.f
        result = f.tidy("--prune")
        out = result.stdout + result.stderr
        self.assertFalse(self.idle.exists(), out)
        self.assertIn(f"tidy: pruned worktree {self.idle} (branch merged-idle is on main)", out)
        for kept in (self.local, self.busy, self.recent, self.unmerged, f.trees / "orphan", f.repo / "junk/thing",
                     f.repo / ".scratch/new.js"):
            self.assertTrue(kept.exists(), f"{kept} was removed\n{out}")
        self.assertTrue((self.local / ".env.local").exists())
        self.assertFalse((f.repo / ".scratch/old.js").exists(), out)
        self.assertFalse((f.repo / "tools/ownership/__pycache__").exists(), out)
        branches = f.git(f.repo, "branch", "--format=%(refname:short)").splitlines()
        self.assertNotIn("done", branches)
        self.assertIn(f"tidy: pruned branch done (restore: git branch done {self.done})", out)
        for kept in ("wip", "local-only", "unmerged", "merged-local", "merged-live", "merged-recent"):
            self.assertIn(kept, branches)
        self.assertIn("tidy: branches: ", out)

    def test_a_symlinked_scratch_directory_is_never_followed(self) -> None:
        f = self.f
        outside = f.base / "outside"
        age(f.write("old.txt", root=outside), 30)
        (f.repo / ".scratch").rename(f.base / "scratch-moved")
        (f.repo / ".scratch").symlink_to(outside, target_is_directory=True)
        result = f.tidy("--prune")
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        self.assertIn("item(s) need a decision", result.stdout)
        self.assertTrue((outside / "old.txt").exists(), result.stdout + result.stderr)
        self.assertNotIn("old.txt", result.stdout)

    def test_without_lsof_no_worktree_is_pruned(self) -> None:
        f = self.f
        tools = {str(Path(shutil.which(name)).parent) for name in ("git", "python3", "bash")}
        path = ":".join(sorted(tools - {"/usr/sbin"}) + ["/usr/bin", "/bin"])
        self.assertIsNone(shutil.which("lsof", path=path))
        result = f.tidy("--prune", env={**f.env, "PATH": path})
        self.assertTrue(self.idle.exists(), result.stdout + result.stderr)
        self.assertIn("tidy: lsof is unavailable; no worktree is pruned", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
