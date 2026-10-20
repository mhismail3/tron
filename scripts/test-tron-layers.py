#!/usr/bin/env python3
"""CLI tests for `scripts/tron layers` (tools/layers/README.md).

Each case builds a disposable Git repository with the real `scripts/tron`,
`tools/layers`, `tools/ownership`, the real Gateway `tsconfig.json` and a link to
the repository's installed Gateway `node_modules`, so the pinned TypeScript
compiler resolves the import graph exactly as it does for the Gateway:

1. Declared downward edges pass; undeclared edges are reported, including
   type-only and dynamic imports; `--update` writes the first baseline.
2. Known-bad mutations fail: an upward import (with its two-way pair) and a
   re-export reaching upward. A move-only split that adds file edges within a
   baselined pair passes: edge counts are reported, never ratcheted.
3. The baseline only shrinks: `--update` refuses to add violations, a fixed
   violation must be tightened, and a baseline larger than the base revision's
   fails.
4. A missing compiler or an ownership violation is an error (exit 2), never clean.
5. iOS: real index stores compiled by `swiftc -index-store-path` and stamped by
   `scripts/ios-test-build-identity.py` give declared, upward, undeclared and
   two-way references, ignore units of files no longer tracked, pass a split
   inside a baselined pair, fail a new unindexed file, and refuse a stale stamp or a dirty tree.

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
          "tools/layers/layers.py", "tools/layers/swift_index.py", "tools/ownership/ownership.py",
          "scripts/ios-test-build-identity.py", "packages/gateway/tsconfig.json")
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
        self.git("commit", "-q", "--allow-empty", "-m", "root")  # the base revision exists before any baseline
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

    def baseline(self, package: str = "gateway") -> dict:
        return json.loads((self.path / f"packages/{package}/layer-baseline.json").read_text())

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
        self.assertEqual(self.repo.baseline()["violations"], ["undeclared gateway/feature -> gateway/contracts",
                                                              "undeclared gateway/main -> gateway/feature"])
        self.assertNotIn("unindexed", self.repo.baseline())
        self.assertIn("no violation beyond the baseline", self.run_ok()[-1])

    def test_split_inside_a_baselined_pair_passes(self) -> None:
        self.baselined()
        r = self.repo
        # Move-only split of feature.ts: both halves keep the baselined feature -> contracts reference.
        r.write("packages/gateway/src/feature/feature.ts", ('import { run } from "../kernel/run.js";\n'
                                                           'import type { Shape } from "../contracts/types.js";\n'
                                                           'import { size } from "./size.js";\n'
                                                           "export const feature = (s: Shape) => run() + size(s);\n"))
        r.write("packages/gateway/src/feature/size.ts", 'import type { Shape } from "../contracts/types.js";\n'
                                                       "export const size = (s: Shape) => s.size;\n")
        lines = self.run_ok()
        self.assertIn("5 module pairs from 7 file edges", lines[-1])
        self.assertIn("no violation beyond the baseline", lines[-1])

    def test_known_bad_upward_and_reexport_fail(self) -> None:
        self.baselined()
        r = self.repo
        r.write("packages/gateway/src/util/bad.ts", 'import { run } from "../kernel/run.js";\nexport const b = run;\n')
        r.write("packages/gateway/src/contracts/index.ts", 'export * from "../kernel/run.js";\n')
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
        self.assertIn("improved, tighten the baseline (scripts/tron layers gateway --update): undeclared gateway/main -> "
                      "gateway/feature [1 -> 0]", self.run_ok(code=1))
        self.run_ok("--update")
        self.assertEqual(r.baseline()["violations"], ["undeclared gateway/feature -> gateway/contracts"])
        self.run_ok()
        # A hand-grown baseline fails against the base revision's.
        data = r.baseline()
        data["violations"].append("upward gateway/util (L0) -> gateway/kernel (L2)")
        r.write("packages/gateway/layer-baseline.json", json.dumps(data))
        lines = self.run_ok(code=1)
        self.assertIn("baseline grew against main: upward gateway/util (L0) -> gateway/kernel (L2) [0 -> 1]", lines)
        # Deleting the baseline cannot re-bless violations, and an unknown base fails closed.
        (r.path / "packages/gateway/layer-baseline.json").unlink()
        r.write("packages/gateway/src/util/bad.ts", 'import { run } from "../kernel/run.js";\nexport const b = run;\n')
        rebuilt = r.layers("--update")
        self.assertEqual(rebuilt.returncode, 2)
        self.assertIn("is missing but main has one; restore it", rebuilt.stderr)
        self.assertFalse((r.path / "packages/gateway/layer-baseline.json").exists())
        for args in (("--update",), ()):
            unknown = subprocess.run([str(r.path / "scripts/tron"), "layers", "--base", "nope", *args], cwd=r.path,
                                     env=r.env, capture_output=True, text=True)
            self.assertEqual(unknown.returncode, 2)
            self.assertIn("base nope not found", unknown.stderr)


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


IOS_MODULES = {
    "Core/Models/core.module.json": {"layer": "L1", "owns": ["**"]},
    "Sources/State/state.module.json": {"layer": "L2", "owns": ["**"], "dependsOn": ["ios-app/core"]},
    "Sources/UI/Chat/chat.module.json": {"layer": "L4", "owns": ["**"], "dependsOn": ["ios-app/state", "ios-app/core"]},
    "ProfilingTests/profiling.module.json": {"layer": "L5", "owns": ["**"]},
}
IOS_SOURCES = {
    "Core/Models/Model.swift": "public struct Model { public init() {}\n public var size = 1 }\n",
    "Core/Models/Model+Grow.swift": "extension Model { func grown() -> Int { size + 1 } }\n",
    "Sources/State/Store.swift": "final class Store { let model = Model()\n func total() -> Int { model.grown() } }\n",
    "Sources/UI/Chat/ChatView.swift": "struct ChatView { let store = Store()\n var size: Int { store.total() } }\n",
    "ProfilingTests/Probe.swift": "struct Probe {}\n",  # owned, but not compiled by the "test build"
}


class IosCase(LayersCase):
    """A disposable iOS package indexed by swiftc and stamped like a scripts/tron-ios-test build."""

    def setUp(self) -> None:
        super().setUp()
        r = self.repo
        self.products = Path(self.temp.name) / "products"
        r.env["TRON_IOS_TEST_DERIVED_DATA"] = str(self.products)
        r.manifest("packages/ios-app/package.module.json", {"layer": "L5", "owns": ["*.json"]})
        for relative, data in IOS_MODULES.items():
            r.manifest(f"packages/ios-app/{relative}", data)
        for relative, text in IOS_SOURCES.items():
            r.write(f"packages/ios-app/{relative}", text)
        self.build()

    def build(self) -> None:
        """Commit, compile every non-profiling Swift file into one index store, then stamp it."""
        r = self.repo
        r.git("add", "-A")
        if subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=r.path).returncode:
            r.git("commit", "-q", "-m", "ios change")
        sources = sorted(str(p) for p in (r.path / "packages/ios-app").rglob("*.swift") if "ProfilingTests" not in p.parts)
        subprocess.run(["xcrun", "swiftc", "-module-name", "App", "-parse-as-library", "-emit-library",
                        "-o", str(self.products / "App.dylib"), "-index-store-path",
                        str(self.products / "Index.noindex/DataStore"), *sources],
                       check=True, capture_output=True, cwd=r.path)
        identity = subprocess.run(["python3", "scripts/ios-test-build-identity.py", "show", "--worktree", str(r.path)],
                                  cwd=r.path, env=r.env, check=True, capture_output=True, text=True).stdout
        subprocess.run(["python3", "scripts/ios-test-build-identity.py", "write", "--worktree", str(r.path),
                        "--derived-data", str(self.products)], input=identity, cwd=r.path, env=r.env,
                       check=True, capture_output=True, text=True)

    def ios(self, *args: str, code: int = 0) -> list[str]:
        result = self.repo.layers("ios", *args)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return (result.stdout + result.stderr).splitlines()


class IosTests(IosCase):
    def test_index_edges_coverage_gaps_and_known_bad_references(self) -> None:
        r = self.repo
        lines = self.ios("--update")
        self.assertEqual(r.baseline("ios-app")["violations"], [])
        self.assertEqual(r.baseline("ios-app")["unindexed"], {"ios-app/profiling": 1})
        self.assertIn("1 unindexed Swift file(s) in 1 module(s)", lines[-1])
        r.git("add", "-A")
        r.git("commit", "-q", "-m", "ios baseline")
        self.build()  # restamp at the baseline commit
        self.assertIn("no violation beyond the baseline", self.ios()[-1])
        # Known-bad: State reaches up into Chat; a renamed file leaves a stale unit behind.
        r.write("packages/ios-app/Sources/State/Leak.swift", "struct Leak { let view = ChatView() }\n")
        r.git("mv", "packages/ios-app/Core/Models/Model+Grow.swift", "packages/ios-app/Core/Models/Growth.swift")
        r.write("packages/ios-app/ProfilingTests/Second.swift", "struct Second {}\n")
        self.build()
        problems = [line for line in self.ios(code=1) if not line.startswith("layers:")]
        self.assertEqual(problems, [
            "new violation: two-way ios-app/chat <-> ios-app/state [1 edge(s), e.g. "
            "packages/ios-app/Sources/UI/Chat/ChatView.swift -> packages/ios-app/Sources/State/Store.swift]",
            "new violation: undeclared ios-app/state -> ios-app/chat [1 edge(s), e.g. "
            "packages/ios-app/Sources/State/Leak.swift -> packages/ios-app/Sources/UI/Chat/ChatView.swift]",
            "new violation: upward ios-app/state (L2) -> ios-app/chat (L4) [1 edge(s), e.g. "
            "packages/ios-app/Sources/State/Leak.swift -> packages/ios-app/Sources/UI/Chat/ChatView.swift]",
            "grew: unindexed ios-app/profiling [1 -> 2 file(s)]",
        ])

    def test_split_inside_a_baselined_pair_passes(self) -> None:
        r = self.repo
        r.manifest("packages/ios-app/Sources/UI/Chat/chat.module.json", {"layer": "L4", "owns": ["**"],
                                                                         "dependsOn": ["ios-app/state"]})
        r.write("packages/ios-app/Sources/UI/Chat/ChatView.swift", "struct ChatView { let store = Store()\n"
                " var size: Int { store.total() + Model().size }\n func extra() -> Int { Model().size } }\n")
        self.build()
        self.ios("--update")
        self.assertEqual(r.baseline("ios-app")["violations"], ["undeclared ios-app/chat -> ios-app/core"])
        r.git("add", "-A")
        r.git("commit", "-q", "-m", "ios baseline")
        r.git("checkout", "-q", "-b", "slice")
        # Move-only split of ChatView.swift: both files now reference Core's Model (1 -> 2 chat -> core edges).
        r.write("packages/ios-app/Sources/UI/Chat/ChatView.swift",
                "struct ChatView { let store = Store()\n var size: Int { store.total() + Model().size } }\n")
        r.write("packages/ios-app/Sources/UI/Chat/ChatView+Extra.swift",
                "extension ChatView { func extra() -> Int { Model().size } }\n")
        self.build()
        lines = self.ios()
        self.assertIn("no violation beyond the baseline", lines[-1])

    def test_stale_stamp_and_dirty_tree_are_refused_never_read(self) -> None:
        r = self.repo
        r.write("packages/ios-app/Sources/State/Later.swift", "struct Later {}\n")
        r.git("add", "-A")
        r.git("commit", "-q", "-m", "after the build")
        stale = self.ios(code=2)
        self.assertTrue(any("stale index: built from revision" in line and "run scripts/tron-ios-test build" in line
                            for line in stale), stale)
        self.build()
        r.write("packages/ios-app/Sources/State/Draft.swift", "struct Draft {}\n")
        dirty = self.ios(code=2)
        self.assertTrue(any("uncommitted or untracked changes" in line for line in dirty), dirty)
        (r.path / "packages/ios-app/Sources/State/Draft.swift").unlink()
        shutil.rmtree(self.products / "Index.noindex")
        missing = self.ios(code=2)
        self.assertTrue(any("has no index store" in line for line in missing), missing)


NODE = node_binary()

if __name__ == "__main__":
    unittest.main(verbosity=2)
