#!/usr/bin/env python3
"""CLI tests for `scripts/tron home-layout` (docs/tron-home.md).

The real repository's registry and source must check clean. Every other case
copies the shipped tool into a disposable Git repository with a small registry
and a disposable Tron home, so no real home is read or written:

1. `check` refuses an entry whose owner is not a module, an unregistered
   Tron-home literal in a script and a literal Gateway join; it ignores tests.
2. `audit` lists only on-disk entries the registry does not cover.
3. `prune` plans dead and expired entries, never a registered file; `--apply`
   needs the plan's digest and, when any candidate changed since, deletes nothing.
4. `migrate` refuses a live runtime lock but takes over a stale one, replaces
   an interrupted backup with a complete copy before moving, is idempotent,
   releases the lock, and `--rollback` restores the original place.
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
TOOL = "tools/home-layout/home_layout.py"
REGISTRY = "packages/gateway/src/foundation/tron-home-layout.json"


def entry(owner: str = "repo/fixture", subtree: bool = False, retention: str | None = "single document") -> dict:
    value = {"owner": owner, "writer": "gateway", "life": "durable", "rebuild": "none", "backup": True,
             "secret": None, "retention": retention, "view": "system"}
    return {**value, "subtree": True} if subtree else value


PATHS = {
    "gateway": entry(), "gateway/devices.json": entry(),
    "workspace": entry(), "workspace/files": entry(subtree=True, retention=None),
    "workspace/files/Profile.json": entry(), "workspace/state": entry(), "workspace/state/profile": entry(subtree=True),
    "internal": entry(), "internal/pi-subagents": entry(subtree=True), "gateway/layout-migration": entry(subtree=True),
    "agent": entry(),
}


class Fixture:
    def __init__(self, base: Path, retired: list[dict] | None = None):
        self.repo = base / "repo"
        self.home = base / "home"
        (self.repo / "tools/home-layout").mkdir(parents=True)
        shutil.copy2(ROOT / TOOL, self.repo / TOOL)
        shutil.copytree(ROOT / "tools/ownership", self.repo / "tools/ownership", ignore=shutil.ignore_patterns("tests", "__pycache__"))
        self.write("fixture.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        self.write(REGISTRY, json.dumps({"version": 1, "retired": retired or [], "paths": PATHS}))
        self.write("packages/gateway/pi-subagents-pin.json", json.dumps({"version": "1.0.0"}))
        self.git("init", "-q", "-b", "main")
        self.home.mkdir()

    def write(self, relative: str, text: str) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True,
                       env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        self.git("add", "-A")
        return subprocess.run(["python3", str(self.repo / TOOL), *args], cwd=self.repo, capture_output=True, text=True)

    def touch(self, relative: str, text: str = "x", age_days: float = 0) -> Path:
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        stamp = time.time() - age_days * 86_400
        os.utime(path, (stamp, stamp))
        return path


class HomeLayoutTests(unittest.TestCase):
    def setUp(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="home-layout-"))
        self.addCleanup(shutil.rmtree, self.base, True)

    def test_the_shipped_registry_and_source_check_clean(self) -> None:
        result = subprocess.run(["python3", str(ROOT / TOOL), "check"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_check_refuses_unregistered_literals_outside_tests(self) -> None:
        fixture = Fixture(self.base)
        fixture.write(REGISTRY, json.dumps({"version": 1, "retired": [], "paths": {**PATHS, "logs": entry("repo/missing")}}))
        fixture.write("scripts/publish.sh", 'out="$HOME/.tron/bogus/cache"\nok="$HOME/.tron/gateway/devices.json"\n')
        fixture.write("scripts/test-publish.sh", 'out="$HOME/.tron/bogus/cache"\n')
        fixture.write("packages/gateway/src/store.ts", 'const path = join(options.tronHome, "gateway", "devices.json");\n')
        fixture.write("packages/mac-app/Sources/Paths.swift", 'let a = TronPaths.tronHome.appendingPathComponent("bogus")\n'
                      'let b = home.appendingPathComponent("gateway/unknown.json")\n'
                      'let c = homeDirectory.appendingPathComponent("Library")\n')
        result = fixture.run("check")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("scripts/publish.sh:1: bogus/cache is not in", result.stdout)
        self.assertIn("packages/gateway/src/store.ts:1: resolve Tron-home paths with tronHomePath()", result.stdout)
        self.assertIn("logs: owner repo/missing is not a module", result.stdout)
        self.assertIn("packages/mac-app/Sources/Paths.swift:1: bogus is not in", result.stdout)
        self.assertIn("packages/mac-app/Sources/Paths.swift:2: gateway/unknown.json is not in", result.stdout)
        self.assertNotIn("Paths.swift:3", result.stdout)
        self.assertNotIn("test-publish.sh", result.stdout)
        self.assertNotIn("publish.sh:2", result.stdout)

    def test_audit_lists_only_unregistered_entries(self) -> None:
        fixture = Fixture(self.base)
        fixture.touch("gateway/devices.json")
        fixture.touch("gateway/old-index.json")
        fixture.touch("workspace/files/notes/a.md")
        fixture.touch("stray.json")
        result = fixture.run("audit", "--home", str(fixture.home))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual([line for line in result.stdout.splitlines() if line.startswith("unregistered")],
                         ["unregistered gateway/old-index.json", "unregistered stray.json"])

    def test_prune_plans_dead_and_expired_entries_and_applies_only_the_reviewed_plan(self) -> None:
        fixture = Fixture(self.base)
        fixture.touch("gateway/devices.json")
        dead = fixture.touch("gateway/old-index.json")
        old = fixture.touch("workspace/files/old-run/log.txt", age_days=40)
        os.utime(old.parent, (old.stat().st_mtime, old.stat().st_mtime))
        fixture.touch("workspace/files/recent/log.txt", age_days=1)
        profile = fixture.touch("workspace/files/Profile.json", age_days=400)
        fixture.touch("internal/pi-subagents/0.9.0/index.js")
        fixture.touch("internal/pi-subagents/1.0.0/index.js")
        plan = self.base / "plan.json"
        planned = fixture.run("prune", "--home", str(fixture.home), "--files-older-than", "30", "--plan", str(plan))
        self.assertEqual(planned.returncode, 0, planned.stderr)
        paths = [row["path"] for row in json.loads(plan.read_text())["candidates"]]
        self.assertEqual(sorted(paths), ["gateway/old-index.json", "internal/pi-subagents/0.9.0", "workspace/files/old-run"])
        digest = planned.stdout.rsplit("--confirm ", 1)[1].strip()

        refused = fixture.run("prune", "--apply", str(plan), "--confirm", "0" * 64)
        self.assertEqual(refused.returncode, 1)
        self.assertTrue(dead.exists())

        fixture.touch("workspace/files/old-run/new.txt")
        changed = fixture.run("prune", "--apply", str(plan), "--confirm", digest)
        self.assertEqual(changed.returncode, 1)
        self.assertIn("workspace/files/old-run changed since the plan", changed.stderr)
        self.assertTrue(dead.exists(), "a refused apply deletes nothing, not even rows planned before the changed one")

        (fixture.home / "workspace/files/old-run/new.txt").unlink()
        os.utime(fixture.home / "workspace/files/old-run", (old.stat().st_mtime, old.stat().st_mtime))
        applied = fixture.run("prune", "--apply", str(plan), "--confirm", digest)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertFalse(dead.exists())
        self.assertFalse((fixture.home / "workspace/files/old-run").exists())
        self.assertFalse((fixture.home / "internal/pi-subagents/0.9.0").exists())
        self.assertTrue((fixture.home / "internal/pi-subagents/1.0.0").exists())
        self.assertTrue((fixture.home / "workspace/files/recent/log.txt").exists())
        self.assertTrue(profile.exists())

    def test_migrate_backs_up_moves_is_idempotent_and_rolls_back(self) -> None:
        fixture = Fixture(self.base, retired=[{"from": "workspace/files/Profile.json", "to": "workspace/state/profile/Profile.json"}])
        PATHS_WITHOUT = dict(PATHS)
        del PATHS_WITHOUT["workspace/files/Profile.json"]
        fixture.write(REGISTRY, json.dumps({"version": 1, "retired": [
            {"from": "workspace/files/Profile.json", "to": "workspace/state/profile/Profile.json"}], "paths": PATHS_WITHOUT}))
        fixture.touch("workspace/files/Profile.json", "profile-v2")
        moved = fixture.home / "workspace/state/profile/Profile.json"
        backup = fixture.home / "gateway/layout-migration/backup/workspace/files/Profile.json"
        fixture.touch("gateway/layout-migration/backup/workspace/files/Profile.json", "partial")  # an interrupted earlier copy

        lock = fixture.home / "agent/.tron-gateway-runtime.lock.lock"
        lock.mkdir(parents=True)
        running = fixture.run("migrate", "--home", str(fixture.home))
        self.assertEqual(running.returncode, 1)
        self.assertIn("stop Tron before migrating", running.stderr)
        self.assertTrue((fixture.home / "workspace/files/Profile.json").exists())
        stale = time.time() - 120
        os.utime(lock, (stale, stale))  # a dead Gateway's lock is no longer refreshed

        first = fixture.run("migrate", "--home", str(fixture.home))
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertFalse(lock.exists(), "the migration releases the runtime lock it held")
        self.assertEqual(moved.read_text(), "profile-v2")
        self.assertFalse((fixture.home / "workspace/files/Profile.json").exists())
        self.assertEqual(backup.read_text(), "profile-v2")
        again = fixture.run("migrate", "--home", str(fixture.home))
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn("moved", again.stdout)
        self.assertEqual(fixture.run("audit", "--home", str(fixture.home)).returncode, 0, fixture.run("audit", "--home", str(fixture.home)).stdout)

        back = fixture.run("migrate", "--home", str(fixture.home), "--rollback")
        self.assertEqual(back.returncode, 0, back.stderr)
        self.assertEqual((fixture.home / "workspace/files/Profile.json").read_text(), "profile-v2")
        self.assertFalse(moved.exists())


if __name__ == "__main__":
    unittest.main()
