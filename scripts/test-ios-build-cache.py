#!/usr/bin/env python3
"""Shared iOS compilation cache journeys with real xcodebuild builds (#1077).

Each case builds a small XcodeGen project shaped like the app (worktree sources,
a local package in the worktree and a versioned remote package that SwiftPM checks
out into DerivedData) from two "worktrees" through scripts/ios-build-cache.py with
an isolated cache, then runs the built tool to prove what was compiled. A macOS
tool keeps each build to seconds; the cache settings do not depend on the platform.
Evidence: test-results/ios-build-cache.json.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "scripts" / "ios-build-cache.py"
REPORT = ROOT / "test-results" / "ios-build-cache.json"
SUMMARY = re.compile(r"ios-build-cache: (\d+) cache hits, (\d+) misses \((slot \d+|in place)")
RESULTS: list[dict] = []

PACKAGE = """// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "{name}", platforms: [.macOS(.v15)],
  products: [.library(name: "{name}", targets: ["{name}"])],{dependencies}
  targets: [.target(name: "{name}"{target_dependencies})])
"""


def run(argv: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=True, capture_output=True, text=True, **kwargs)


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.remote = root / "remote"
        self.environment = {**os.environ, "TRON_IOS_BUILD_CACHE_DIR": str(root / "cache")}
        self.environment.pop("TRON_IOS_BUILD_CACHE", None)
        self._make_remote()
        self.worktree("a")
        shutil.copytree(root / "a", root / "b", symlinks=True)

    def _make_remote(self) -> None:
        sources = self.remote / "Sources" / "Remote"
        sources.mkdir(parents=True)
        (self.remote / "Package.swift").write_text(PACKAGE.format(name="Remote", dependencies="", target_dependencies=""))
        self.tag_remote("1.0.0", "remote-1")

    def tag_remote(self, version: str, value: str) -> None:
        (self.remote / "Sources" / "Remote" / "Remote.swift").write_text(
            f'public func remoteValue() -> String {{ "{value}" }}\n')
        if not (self.remote / ".git").exists():
            run(["git", "init", "-q"], cwd=self.remote)
        run(["git", "add", "-A"], cwd=self.remote)
        run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", version], cwd=self.remote)
        run(["git", "tag", version], cwd=self.remote)

    def worktree(self, name: str) -> Path:
        tree = self.root / name
        (tree / "Sources").mkdir(parents=True)
        (tree / "Dep" / "Sources" / "Dep").mkdir(parents=True)
        self.pin_remote(name, "1.0.0")
        (tree / "Dep" / "Sources" / "Dep" / "Dep.swift").write_text(
            'import Remote\npublic func depValue() -> String { "dep-1 " + remoteValue() }\n')
        (tree / "Sources" / "main.swift").write_text('import Dep\nprint("tool-1 " + depValue())\n')
        (tree / "project.yml").write_text(
            "name: Fixture\npackages:\n  Dep:\n    path: Dep\ntargets:\n  Tool:\n    type: tool\n"
            "    platform: macOS\n    deploymentTarget: \"15.0\"\n    sources: [Sources]\n"
            "    dependencies:\n      - package: Dep\n")
        tools = os.environ.get("TRON_CI_TOOLS_DIR", str(ROOT / ".ci-tools"))
        path = f"{tools}/bin:{ROOT.parent / 'tron' / '.ci-tools' / 'bin'}:/opt/homebrew/bin:{os.environ['PATH']}"
        run(["xcodegen", "generate", "--quiet"], cwd=tree, env={**os.environ, "PATH": path})
        return tree

    def pin_remote(self, worktree: str, version: str) -> None:
        dependency = f'\n  dependencies: [.package(url: "file://{self.remote}", exact: "{version}")],'
        (self.root / worktree / "Dep" / "Package.swift").write_text(PACKAGE.format(
            name="Dep", dependencies=dependency,
            target_dependencies=', dependencies: [.product(name: "Remote", package: "remote")]'))

    def command(self, worktree: str, derived: str) -> list[str]:
        return [sys.executable, str(CACHE), "run", "--",
                "xcodebuild", "build", "-project", str(self.root / worktree / "Fixture.xcodeproj"), "-scheme", "Tool",
                "-derivedDataPath", str(self.root / derived),
                "-destination", "platform=macOS,arch=arm64",
                # Keep SwiftPM's repository cache inside the fixture.
                "-packageCachePath", str(self.root / "package-cache")]

    def build(self, worktree: str, derived: str, **environment: str) -> dict:
        started = time.monotonic()
        result = subprocess.run(self.command(worktree, derived), capture_output=True, text=True,
                                env={**self.environment, **environment})
        return self.outcome(worktree, derived, result.returncode, result.stdout, result.stderr, started)

    def outcome(self, worktree: str, derived: str, status: int, stdout: str, stderr: str, started: float) -> dict:
        match = SUMMARY.search(stderr)
        tool = self.root / derived / "Build" / "Products" / "Debug" / "Tool"
        output = run([str(tool)]).stdout.strip() if status == 0 and tool.exists() else None
        value = {"worktree": worktree, "derived": derived, "status": status, "output": output,
                 "hits": int(match.group(1)) if match else None, "misses": int(match.group(2)) if match else None,
                 "where": match.group(3) if match else None, "seconds": round(time.monotonic() - started, 1),
                 "warnings": [line for line in stderr.splitlines() if "WARNING" in line],
                 "stderr": [line for line in stderr.splitlines() if line.startswith("ios-build-cache:")]}
        if status != 0:
            value["log_tail"] = (stdout + stderr)[-3000:]
        return value

    def partition(self) -> Path:
        partitions = [p for p in (self.root / "cache" / "cas").iterdir() if p.is_dir()]
        assert len(partitions) == 1, partitions
        return partitions[0]


class SharedCompilationCache(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="tron-ios-build-cache-")
        self.addCleanup(self.directory.cleanup)
        self.fixture = Fixture(Path(self.directory.name))
        self.builds: list[dict] = []
        self.addCleanup(lambda: RESULTS.append({"case": self.id().split(".")[-1], "builds": self.builds}))

    def build(self, worktree: str, derived: str, **environment: str) -> dict:
        outcome = self.fixture.build(worktree, derived, **environment)
        self.builds.append(outcome)
        self.assertEqual(outcome["status"], 0, outcome)
        return outcome

    def test_worktrees_share_package_compiles_and_never_reuse_changed_sources(self) -> None:
        cold = self.build("a", "dd-a")
        self.assertEqual(cold["output"], "tool-1 dep-1 remote-1")
        self.assertEqual((cold["hits"], cold["where"]), (0, "slot 0"))
        self.assertGreater(cold["misses"], 0)

        # A second worktree with fresh DerivedData replays the remote package's
        # compiles; its own sources live at other paths and compile.
        warm = self.build("b", "dd-b")
        self.assertEqual(warm["output"], "tool-1 dep-1 remote-1")
        self.assertGreater(warm["hits"], 0)
        self.assertLess(warm["misses"], cold["misses"])

        # Changed sources in one worktree are compiled, not replayed, and do not
        # leak into the other worktree.
        tree = self.fixture.root / "b"
        (tree / "Sources" / "main.swift").write_text('import Dep\nprint("tool-2 " + depValue())\n')
        (tree / "Dep" / "Sources" / "Dep" / "Dep.swift").write_text(
            'import Remote\npublic func depValue() -> String { "dep-2 " + remoteValue() }\n')
        self.assertEqual(self.build("b", "dd-b")["output"], "tool-2 dep-2 remote-1")
        self.assertEqual(self.build("a", "dd-a")["output"], "tool-1 dep-1 remote-1")

        # The shared-path case: a new package version checks out at the same
        # DerivedData-relative path as the cached one, with different content.
        self.fixture.tag_remote("1.0.1", "remote-2")
        self.fixture.pin_remote("b", "1.0.1")
        fresh = self.build("b", "dd-b2")
        self.assertEqual(fresh["output"], "tool-2 dep-2 remote-2")
        self.assertEqual(self.build("a", "dd-a2")["output"], "tool-1 dep-1 remote-1")

    def test_corrupt_or_missing_cache_builds_loudly_and_correctly(self) -> None:
        self.build("a", "dd-a")
        store = self.fixture.partition() / "builtin"
        for path in store.rglob("*"):
            if path.is_file() and path.stat().st_size > 8192:
                with path.open("r+b") as handle:
                    handle.seek(4096)
                    handle.write(os.urandom(4096))
        corrupt = self.build("b", "dd-b")
        self.assertEqual(corrupt["output"], "tool-1 dep-1 remote-1")
        self.assertTrue(any("corrupt" in line for line in corrupt["warnings"]), corrupt)
        self.assertEqual(corrupt["hits"], 0)

        shutil.rmtree(self.fixture.root / "cache" / "cas")
        missing = self.build("a", "dd-a3")
        self.assertEqual(missing["output"], "tool-1 dep-1 remote-1")
        self.assertEqual(missing["hits"], 0)

    def test_concurrent_builds_share_the_cache_and_an_interrupted_build_is_recovered(self) -> None:
        self.build("a", "dd-seed")
        started = time.monotonic()
        processes = {name: subprocess.Popen(self.fixture.command(name, f"dd-{name}"), stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, text=True, env=self.fixture.environment)
                     for name in ("a", "b")}
        outcomes = {}
        for name, process in processes.items():
            stdout, stderr = process.communicate(timeout=600)
            outcomes[name] = self.fixture.outcome(name, f"dd-{name}", process.returncode, stdout, stderr, started)
            self.builds.append(outcomes[name])
        for outcome in outcomes.values():
            self.assertEqual(outcome["status"], 0, outcome)
            self.assertEqual(outcome["output"], "tool-1 dep-1 remote-1")
            self.assertGreater(outcome["hits"], 0)
        self.assertNotEqual(outcomes["a"]["where"], outcomes["b"]["where"])

        # A build killed while its DerivedData is parked in a slot: the owner's
        # next build takes it back instead of starting over.
        process = subprocess.Popen(self.fixture.command("a", "dd-a"), stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, env=self.fixture.environment, start_new_session=True)
        home = self.fixture.root / "dd-a"
        deadline = time.monotonic() + 60
        while home.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(home.exists(), "the build never moved its DerivedData into a slot")
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        slots = self.fixture.root / "cache" / "slots"
        self.assertTrue(list(slots.glob("*/owner.json")), "no owner record for the parked DerivedData")
        recovered = self.build("a", "dd-a")
        self.assertEqual(recovered["output"], "tool-1 dep-1 remote-1")
        self.assertIn("returning DerivedData left by an interrupted build", "\n".join(recovered["stderr"]))
        self.assertFalse(list(slots.glob("*/owner.json")))
        self.assertFalse(list(slots.glob("*/DerivedData")))


def write_report() -> None:
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({"schema": "tron.ios-build-cache-test.v1", "cases": RESULTS}, indent=2) + "\n")


if __name__ == "__main__":
    program = unittest.main(exit=False)
    write_report()
    sys.exit(not program.result.wasSuccessful())
