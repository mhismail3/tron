#!/usr/bin/env python3
"""CLI tests for `scripts/tron home-layout` (docs/tron-home.md).

The real repository's registry and source must check clean. The other case
copies the shipped tool into a disposable Git repository with a small registry:
`check` refuses an entry whose owner is not a module, an unregistered Tron-home
literal in a script and a literal Gateway join; it ignores tests.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
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
    "internal": entry(), "internal/pi-subagents": entry(subtree=True),
    "agent": entry(),
}


class Fixture:
    def __init__(self, base: Path):
        self.repo = base / "repo"
        (self.repo / "tools/home-layout").mkdir(parents=True)
        shutil.copy2(ROOT / TOOL, self.repo / TOOL)
        shutil.copytree(ROOT / "tools/ownership", self.repo / "tools/ownership", ignore=shutil.ignore_patterns("tests", "__pycache__"))
        self.write("fixture.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        self.write(REGISTRY, json.dumps({"version": 1, "paths": PATHS}))
        self.git("init", "-q", "-b", "main")

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


class HomeLayoutTests(unittest.TestCase):
    def setUp(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="home-layout-"))
        self.addCleanup(shutil.rmtree, self.base, True)

    def test_the_shipped_registry_and_source_check_clean(self) -> None:
        result = subprocess.run(["python3", str(ROOT / TOOL), "check"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_check_refuses_unregistered_literals_outside_tests(self) -> None:
        fixture = Fixture(self.base)
        fixture.write(REGISTRY, json.dumps({"version": 1, "paths": {**PATHS, "logs": entry("repo/missing")}}))
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


if __name__ == "__main__":
    unittest.main()
