#!/usr/bin/env python3
"""CLI tests for what `scripts/tron tidy` treats as owned, and whose files it never prunes.

Reuses the disposable checkout from test-tidy.py (real `scripts/tron`, real worktrees, a bare
origin) and runs the command as a worker would:

1. A detached-HEAD worktree belongs to the tool that made it (verify batch lanes, base
   checks): it is reported but never pruned, even when merged, clean and idle.
2. Scratch and evidence in a linked worktree with a live process, local changes or
   unknown ignored data are another worker's (as is every linked worktree when `lsof` is
   missing): they are not aged or pruned there; the primary checkout's still are.
3. Loose files in `.pi/` are agent workflow scratch (Pi's subagent tool writes them there):
   aged and pruned like `.scratch/`, never reported as residue; tracked `.pi/prompts/`
   stay untouched.
4. An ignored directory that holds a named writer's output (`packages/ios-app/build/`,
   written by `scripts/tron-ios-device`) is split: the writer's paths are known, the
   rest is residue.
5. A tracked file that `.gitignore` also matches is reported with its fix.
6. A merged, idle worktree whose regenerable Gateway payload `bundle-gateway.sh` sealed
   read-only (`chmod -R a-w`) is still pruned, not silently kept.

The last run's output is kept in `test-results/tidy-cli/` for review.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("tidy_fixture", Path(__file__).with_name("test-tidy.py"))
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
Fixture, age = FIXTURE.Fixture, FIXTURE.age


class ScopeCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-tidy-scope-")
        self.f = Fixture(Path(self.temp.name).resolve())
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.f.close)

    def report(self, *args: str) -> dict:
        result = self.f.tidy("--json", *args)
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        return json.loads(result.stdout)

    def detached(self, name: str, idle_days: float) -> Path:
        f = self.f
        path = f.trees / name
        f.git(f.repo, "worktree", "add", "-q", "--detach", str(path), "main")
        gitdir = Path(f.git(path, "rev-parse", "--absolute-git-dir"))
        for entry in ("HEAD", "logs/HEAD"):
            age(gitdir / entry, idle_days)
        return path


class OwnershipScopeTests(ScopeCase):
    def test_a_detached_worktree_is_never_pruned(self) -> None:
        lane = self.detached("batch-lane", idle_days=10)
        branchy = self.f.worktree("merged-idle", merged=True, idle_days=10)
        result = self.report("--prune")
        self.assertTrue(lane.exists(), json.dumps(result))
        self.assertFalse(branchy.exists(), json.dumps(result))
        row = next(w for w in result["worktrees"] if w["path"] == str(lane))
        self.assertTrue(row["merged"])

    def test_another_workers_scratch_and_evidence_are_left_alone(self) -> None:
        f = self.f
        live = f.worktree("live-work", merged=False, idle_days=0)
        dirty = f.worktree("dirty-work", merged=False, idle_days=0)
        idle = f.worktree("idle-work", merged=False, idle_days=0)
        f.write("notes-in-progress.txt", "draft\n", root=dirty)
        f.live(live)
        for tree in (f.repo, live, dirty, idle):
            age(f.write(".scratch/old.js", root=tree), 10)
            age(f.write("test-results/run/report.json", root=tree), 20)
            age(tree / "test-results/run", 20)
        result = self.report("--prune")
        for tree in (live, dirty):
            self.assertTrue((tree / ".scratch/old.js").exists(), f"{tree} lost scratch: {json.dumps(result)}")
            self.assertTrue((tree / "test-results/run").exists(), f"{tree} lost evidence: {json.dumps(result)}")
        for tree in (f.repo, idle):
            self.assertFalse((tree / ".scratch/old.js").exists(), f"{tree} kept scratch: {json.dumps(result)}")
            self.assertFalse((tree / "test-results/run").exists(), f"{tree} kept evidence: {json.dumps(result)}")

    def test_unknown_ignored_data_or_no_lsof_keeps_a_worktrees_scratch(self) -> None:
        f = self.f
        parked = f.worktree("parked-work", merged=False, idle_days=0)
        f.write("junk/data.bin", root=parked)  # ignored, no named writer: someone's local data
        age(f.write(".scratch/old.js", root=parked), 10)
        self.report("--prune")
        self.assertTrue((parked / ".scratch/old.js").exists())
        plain = f.worktree("plain-work", merged=False, idle_days=0)
        age(f.write(".scratch/old.js", root=plain), 10)
        tools = {str(Path(shutil.which(name)).parent) for name in ("git", "python3", "bash")}
        path = ":".join(sorted(tools - {"/usr/sbin"}) + ["/usr/bin", "/bin"])
        self.assertIsNone(shutil.which("lsof", path=path))
        result = f.tidy("--prune", env={**f.env, "PATH": path})
        self.assertTrue((plain / ".scratch/old.js").exists(), result.stdout + result.stderr)
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        self.assertIn("tidy: lsof is unavailable; no worktree is pruned", result.stdout)

    def test_pi_workflow_scripts_are_scratch(self) -> None:
        f = self.f
        f.write(".gitignore", (f.repo / ".gitignore").read_text() + ".pi/*\n!.pi/prompts/\n")
        prompt = f.write(".pi/prompts/audit.md", "# Prompt\n")
        f.commit(f.repo, "pi prompts")
        age(prompt, 30)
        old = f.write(".pi/2248-review.js", "// workflow\n")
        age(old, 10)
        new = f.write(".pi/2276-review.js", "// workflow\n")
        runs = f.write(".pi/subagents/artifacts/run.jsonl").parent.parent  # a directory is not a workflow script
        age(runs / "artifacts/run.jsonl", 60)
        result = self.report()
        self.assertIn(str(runs), result["residue"])
        self.assertNotIn(str(runs), result["expired"])
        self.assertNotIn(str(old), result["residue"])
        self.assertNotIn(str(new), result["residue"])
        self.assertIn(str(old), result["expired"])
        self.assertNotIn(str(new), result["expired"])
        self.report("--prune")
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())
        self.assertTrue(prompt.exists())
        self.assertTrue(runs.exists())

    def test_a_writers_output_inside_an_ignored_directory_is_known(self) -> None:
        f = self.f
        f.write(".gitignore", (f.repo / ".gitignore").read_text() + "packages/ios-app/build/\n")
        f.commit(f.repo, "ignore ios build")
        for owned in ("DerivedData/info.plist", "DerivedData-fast-debug/info.plist", "share/TronMobile.ipa"):
            f.write(f"packages/ios-app/build/{owned}")
        f.write("packages/ios-app/build/p99-captures/trace.json")
        result = self.report()
        build = f.repo / "packages/ios-app/build"
        self.assertIn(str(build / "p99-captures"), result["residue"])
        for owned in ("DerivedData", "DerivedData-fast-debug", "share"):
            self.assertNotIn(str(build / owned), result["residue"])
        self.assertNotIn(str(build), result["residue"])

    def test_a_tracked_file_the_ignore_rules_match_is_reported(self) -> None:
        f = self.f
        f.write("packages/relay/package-lock.json", "{}\n")
        f.git(f.repo, "add", "packages/relay/package-lock.json")
        f.commit(f.repo, "lockfile")
        f.write(".gitignore", (f.repo / ".gitignore").read_text() + "package-lock.json\n")
        f.commit(f.repo, "ignore lockfiles")
        result = f.tidy()
        self.assertIn("tidy: tracked_ignored: packages/relay/package-lock.json — tracked but matched by .gitignore; "
                      "add a !negation for it, or untrack it", result.stdout)
        f.write(".gitignore", (f.repo / ".gitignore").read_text() + "!packages/relay/package-lock.json\n")
        f.commit(f.repo, "negate")
        self.assertEqual(self.report()["tracked_ignored"], [])

    def test_a_sealed_read_only_payload_does_not_block_pruning(self) -> None:
        f = self.f
        f.write(".gitignore", (f.repo / ".gitignore").read_text() + "packages/mac-app/Sources/Resources/Gateway/\n")
        f.write("packages/mac-app/Sources/Resources/AppIcon.txt")
        f.commit(f.repo, "ignore the bundled payload")
        f.git(f.repo, "push", "-q", "origin", "main")
        f.git(f.repo, "fetch", "-q", "origin")
        tree = f.worktree("merged-sealed", merged=True, idle_days=10)
        payload = f.write("packages/mac-app/Sources/Resources/Gateway/app/dist/index.js", "payload", root=tree).parents[2]
        subprocess.run(["chmod", "-R", "a-w", payload], check=True)
        self.addCleanup(lambda: payload.exists() and subprocess.run(["chmod", "-R", "u+w", payload], check=True))
        result = self.f.tidy("--prune")
        self.assertFalse(tree.exists(), result.stdout + result.stderr)
        self.assertIn(f"tidy: pruned worktree {tree} (branch merged-sealed is on main)", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
