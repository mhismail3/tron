"""Regression tests for fail-closed worktree warming in warm.py."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import Optional
from unittest.mock import patch

import warm


class WarmWorktreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.primary = self.root / "primary"
        self.worktree = self.root / "worktree"
        self.primary.mkdir()
        self.worktree.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def package(self, root: Path, lock: Optional[bytes] = None) -> Path:
        package = root / "packages/gateway"
        package.mkdir(parents=True)
        content = lock or json.dumps({"lockfileVersion": 3, "packages": {
            "": {}, "node_modules/example": {"version": "1.0.0"}}}).encode()
        (package / "package-lock.json").write_bytes(content)
        return package

    def installed(self, package: Path) -> Path:
        modules = package / "node_modules"
        modules.mkdir()
        (modules / "installed.txt").write_text("independent install")
        (modules / ".package-lock.json").write_bytes((package / "package-lock.json").read_bytes())
        return modules

    def test_matching_lockfile_clones_modules_without_sharing_mutations(self) -> None:
        source = self.installed(self.package(self.primary))
        destination = self.package(self.worktree)
        install = unittest.mock.Mock()

        warm.seed_node_modules(self.primary, self.worktree, install=install)

        seeded = destination / "node_modules"
        self.assertEqual((seeded / "installed.txt").read_text(), "independent install")
        (seeded / "installed.txt").write_text("changed in worker")
        self.assertEqual((source / "installed.txt").read_text(), "independent install")
        install.assert_not_called()

    def test_lockfile_mismatch_runs_npm_ci_instead_of_copying(self) -> None:
        source = self.installed(self.package(self.primary))
        destination = self.package(self.worktree, b'{"lockfileVersion":3,"packages":{"":"{}"}}')
        calls: list[Path] = []

        def install(package: Path) -> None:
            calls.append(package)
            modules = package / "node_modules"
            modules.mkdir()
            (modules / "fresh-install.txt").write_text("npm ci")

        warm.seed_node_modules(self.primary, self.worktree, install=install)

        self.assertEqual(calls, [destination])
        self.assertTrue((destination / "node_modules/fresh-install.txt").is_file())
        self.assertFalse((destination / "node_modules/installed.txt").exists())
        self.assertTrue((source / "installed.txt").is_file())

    def test_clone_failure_cleans_partial_target_then_runs_npm_ci(self) -> None:
        self.installed(self.package(self.primary))
        destination = self.package(self.worktree)
        calls: list[Path] = []

        def fail_clone(_source: Path, target: Path) -> None:
            target.mkdir()
            (target / "partial").touch()
            raise OSError("clonefile unavailable")

        def install(package: Path) -> None:
            calls.append(package)
            self.installed(package)

        with patch.object(warm, "_clone_tree", fail_clone):
            warm.seed_node_modules(self.primary, self.worktree, install=install)

        self.assertEqual(calls, [destination])
        self.assertFalse((destination / "node_modules/partial").exists())
        self.assertTrue((destination / "node_modules/installed.txt").is_file())

    def test_missing_primary_install_uses_npm_ci(self) -> None:
        destination = self.package(self.worktree)
        calls: list[Path] = []

        def install(package: Path) -> None:
            calls.append(package)
            self.installed(package)

        warm.seed_node_modules(self.primary, self.worktree, install=install)

        self.assertEqual(calls, [destination])
        self.assertTrue((destination / "node_modules/installed.txt").is_file())

    def test_empty_primary_node_modules_is_not_mistaken_for_a_completed_install(self) -> None:
        self.package(self.primary).joinpath("node_modules").mkdir()
        destination = self.package(self.worktree)
        calls: list[Path] = []

        def install(package: Path) -> None:
            calls.append(package)
            self.installed(package)

        warm.seed_node_modules(self.primary, self.worktree, install=install)

        self.assertEqual(calls, [destination])
        self.assertTrue((destination / "node_modules/.package-lock.json").is_file())

    def test_ios_cache_copies_only_supported_cache_directories(self) -> None:
        primary_products = self.root / "ios" / "primary"
        worktree_products = self.root / "ios" / "worktree"
        (primary_products / "ModuleCache.noindex").mkdir(parents=True)
        (primary_products / "ModuleCache.noindex/module.pcm").write_text("cache")
        (primary_products / "SDKStatCaches.noindex").mkdir()
        (primary_products / "Build/Products").mkdir(parents=True)
        (primary_products / "Build/Products/Tron.app").write_text("must not share")

        warm.seed_ios_build_cache(primary_products, worktree_products)

        self.assertEqual((worktree_products / "ModuleCache.noindex/module.pcm").read_text(), "cache")
        self.assertTrue((worktree_products / "SDKStatCaches.noindex").is_dir())
        self.assertFalse((worktree_products / "Build").exists())
        (worktree_products / "ModuleCache.noindex/module.pcm").write_text("worker cache")
        self.assertEqual((primary_products / "ModuleCache.noindex/module.pcm").read_text(), "cache")


if __name__ == "__main__":
    unittest.main()
