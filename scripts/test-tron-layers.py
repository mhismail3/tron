#!/usr/bin/env python3
"""CLI tests for `scripts/tron layers` (tools/layers/README.md).

Each case builds a disposable Git repository with the real `scripts/tron`,
`tools/layers`, `tools/ownership`, the real Gateway `tsconfig.json` and a link to
the repository's installed Gateway `node_modules`, so the pinned TypeScript
compiler resolves the import graph exactly as it does for the Gateway:

1. Declared downward edges pass; undeclared edges are reported, including
   type-only and dynamic imports; `--update` writes the first baseline.
2. Known-bad mutations fail: an upward import (with its two-way pair), a
   re-export reaching upward, and an extra edge in a baselined pair.
3. The baseline only shrinks: `--update` refuses to add violations, a fixed
   violation must be tightened, and a baseline larger than the base revision's
   fails.
4. A missing compiler or an ownership violation is an error (exit 2), never clean.

The last run's output is kept in `test-results/layers-cli/`.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "test-results" / "layers-cli"
COPIED = ("scripts/tron", "scripts/tron-node", ".node-version", "config/ci-toolchain.env",
          "tools/layers/layers.py", "tools/ownership/ownership.py", "packages/gateway/tsconfig.json")
MODULES = {
    "util": {"layer": "L0", "owns": ["**"]},
    "contracts": {"layer": "L1", "owns": ["**"]},
    "kernel": {"layer": "L2", "owns": ["**"], "dependsOn": ["gateway/util"]},
    "feature": {"layer": "L3", "owns": ["**"], "dependsOn": ["gateway/util", "gateway/kernel"]},
    "main": {"layer": "L5", "owns": ["**"], "dependsOn": ["gateway/kernel"]},
}
SOURCES = {
    "util/util.ts": "export const clamp = (n: number) => Math.max(0, n);\n",
    "contracts/types.ts": "export interface Shape { size: number }\n",
    "kernel/run.ts": 'import { clamp } from "../util/util.js";\nexport const run = () => clamp(1);\n',
    "feature/feature.ts": ('import { run } from "../kernel/run.js";\n'
                           'import type { Shape } from "../contracts/types.js";\n'
                           "export const feature = (s: Shape) => run() + s.size;\n"),
    "main/main.ts": 'import { run } from "../kernel/run.js";\nexport const start = async () => '
                    '{ run(); return (await import("../feature/feature.js")).feature; };\n',
}


def node_binary() -> str:
    return subprocess.run([str(ROOT / "scripts/tron-node"), "exec", "node", "-p", "process.execPath"],
                          capture_output=True, text=True, check=True).stdout.strip()


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        home = base / "home"
        home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base), "TRON_NODE_BIN": NODE,
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.git("init", "-q", "-b", "main")
        for relative in COPIED:
            (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, self.path / relative)
        os.symlink((ROOT / "packages/gateway/node_modules").resolve(), self.path / "packages/gateway/node_modules")
        self.write(".gitignore", "node_modules\n")
        self.manifest("tooling.module.json", {"layer": "L5", "owns": [
            ".gitignore", ".node-version", "config/**", "scripts/**", "tools/**", "tooling.module.json"]})
        self.manifest("packages/gateway/package.module.json", {"layer": "L5", "owns": ["*.json"]})
        for name, data in MODULES.items():
            self.manifest(f"packages/gateway/src/{name}/{name}.module.json", data)
        for relative, text in SOURCES.items():
            self.write(f"packages/gateway/src/{relative}", text)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, text: str) -> None:
        (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
        (self.path / relative).write_text(text)

    def manifest(self, relative: str, data: dict) -> None:
        self.write(relative, json.dumps(data))

    def baseline(self) -> dict:
        return json.loads((self.path / "packages/gateway/layer-baseline.json").read_text())["violations"]

    def layers(self, *args: str) -> subprocess.CompletedProcess:
        self.git("add", "-A")
        result = subprocess.run([str(self.path / "scripts/tron"), "layers", "--base", "main", *args],
                                cwd=self.path, env=self.env, capture_output=True, text=True)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron layers {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        return result


class LayersCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-layers-")
        self.repo = Repo(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_ok(self, *args: str, code: int = 0) -> list[str]:
        result = self.repo.layers(*args)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout.splitlines()

    def baselined(self) -> None:
        self.run_ok("--update")
        self.repo.git("add", "-A")
        self.repo.git("commit", "-q", "-m", "baseline")
        self.repo.git("checkout", "-q", "-b", "slice")


class BoundaryTests(LayersCase):
    def test_declared_edges_pass_and_undeclared_type_only_and_dynamic_edges_are_found(self) -> None:
        lines = self.run_ok(code=1)
        self.assertEqual([line for line in lines if not line.startswith("layers:")], [
            "new violation: undeclared gateway/feature -> gateway/contracts [1 edge(s), e.g. "
            "packages/gateway/src/feature/feature.ts -> packages/gateway/src/contracts/types.ts]",
            "new violation: undeclared gateway/main -> gateway/feature [1 edge(s), e.g. "
            "packages/gateway/src/main/main.ts -> packages/gateway/src/feature/feature.ts]",
        ])
        self.assertIn("5 module pairs from 5 file edges", lines[-1])
        self.run_ok("--update")
        self.assertEqual(self.repo.baseline(), {"undeclared gateway/feature -> gateway/contracts": 1,
                                                "undeclared gateway/main -> gateway/feature": 1})
        self.assertIn("no violation beyond the baseline", self.run_ok()[-1])

    def test_known_bad_upward_reexport_and_grown_pair_fail(self) -> None:
        self.baselined()
        r = self.repo
        r.write("packages/gateway/src/util/bad.ts", 'import { run } from "../kernel/run.js";\nexport const b = run;\n')
        r.write("packages/gateway/src/contracts/index.ts", 'export * from "../kernel/run.js";\n')
        r.write("packages/gateway/src/feature/more.ts", 'import type { Shape } from "../contracts/types.js";\n'
                                                       "export type More = Shape;\n")
        problems = [line for line in self.run_ok(code=1) if not line.startswith("layers:")]
        self.assertEqual(problems, [
            "new violation: two-way gateway/kernel <-> gateway/util [1 edge(s), e.g. "
            "packages/gateway/src/kernel/run.ts -> packages/gateway/src/util/util.ts]",
            "new violation: undeclared gateway/contracts -> gateway/kernel [1 edge(s), e.g. "
            "packages/gateway/src/contracts/index.ts -> packages/gateway/src/kernel/run.ts]",
            "new violation: undeclared gateway/util -> gateway/kernel [1 edge(s), e.g. "
            "packages/gateway/src/util/bad.ts -> packages/gateway/src/kernel/run.ts]",
            "new violation: upward gateway/contracts (L1) -> gateway/kernel (L2) [1 edge(s), e.g. "
            "packages/gateway/src/contracts/index.ts -> packages/gateway/src/kernel/run.ts]",
            "new violation: upward gateway/util (L0) -> gateway/kernel (L2) [1 edge(s), e.g. "
            "packages/gateway/src/util/bad.ts -> packages/gateway/src/kernel/run.ts]",
            "grew: undeclared gateway/feature -> gateway/contracts [1 -> 2 edge(s)]",
        ])


class BaselineTests(LayersCase):
    def test_baseline_never_grows_and_must_be_tightened(self) -> None:
        self.baselined()
        r = self.repo
        before = r.baseline()
        r.write("packages/gateway/src/util/bad.ts", 'import { run } from "../kernel/run.js";\nexport const b = run;\n')
        refused = r.layers("--update")
        self.assertEqual(refused.returncode, 2)
        self.assertIn("--update only removes fixed entries", refused.stderr)
        self.assertEqual(r.baseline(), before)
        (r.path / "packages/gateway/src/util/bad.ts").unlink()
        # Fix one baselined edge: the run fails until the baseline is tightened.
        r.write("packages/gateway/src/main/main.ts", 'import { run } from "../kernel/run.js";\nexport const start = run;\n')
        self.assertIn("improved, tighten the baseline (scripts/tron layers --update): undeclared gateway/main -> "
                      "gateway/feature [1 -> 0]", self.run_ok(code=1))
        self.run_ok("--update")
        self.assertEqual(r.baseline(), {"undeclared gateway/feature -> gateway/contracts": 1})
        self.run_ok()
        # A hand-grown baseline fails against the base revision's.
        data = json.loads((r.path / "packages/gateway/layer-baseline.json").read_text())
        data["violations"]["undeclared gateway/feature -> gateway/contracts"] = 3
        data["violations"]["upward gateway/util (L0) -> gateway/kernel (L2)"] = 1
        r.write("packages/gateway/layer-baseline.json", json.dumps(data))
        lines = self.run_ok(code=1)
        self.assertIn("baseline grew against main: undeclared gateway/feature -> gateway/contracts [1 -> 3]", lines)
        self.assertIn("baseline grew against main: upward gateway/util (L0) -> gateway/kernel (L2) [0 -> 1]", lines)


class ErrorTests(LayersCase):
    def test_missing_compiler_and_ownership_violations_are_errors_not_clean(self) -> None:
        r = self.repo
        r.write("packages/gateway/src/stray.ts", "export const x = 1;\n")
        result = r.layers()
        self.assertEqual(result.returncode, 2)
        self.assertIn("ownership has 1 violation(s)", result.stderr)
        (r.path / "packages/gateway/src/stray.ts").unlink()
        (r.path / "packages/gateway/node_modules").unlink()
        result = r.layers()
        self.assertEqual(result.returncode, 2)
        self.assertIn("install Gateway dependencies", result.stderr)
        self.assertNotIn("no violation", result.stdout)


NODE = node_binary()

if __name__ == "__main__":
    unittest.main(verbosity=2)
