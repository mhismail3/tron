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
import stat
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


def snapshot(root: Path, contents_first: bool = True) -> dict:
    paths = [root, *root.rglob("*")]
    bodies = {path: path.read_bytes() for path in paths if stat.S_ISREG(path.lstat().st_mode)} if contents_first else {}
    result = {}
    for path in paths:
        info = path.lstat()
        result[str(path.relative_to(root))] = (
            info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_size, info.st_atime_ns, info.st_mtime_ns, info.st_ctime_ns,
            bodies.get(path) if contents_first else path.read_bytes() if stat.S_ISREG(info.st_mode) else None,
        )
    return result


class HomeLayoutTests(unittest.TestCase):
    def setUp(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="home-layout-"))
        self.addCleanup(shutil.rmtree, self.base, True)

    def test_the_shipped_registry_and_source_check_clean(self) -> None:
        result = subprocess.run(["python3", str(ROOT / TOOL), "check"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_manifest_export_capacity_matches_the_shipped_owner(self) -> None:
        paths = json.loads((ROOT / REGISTRY).read_text())["paths"]
        source = (ROOT / "packages/gateway/src/sessions/session-export.ts").read_text()
        self.assertIn("SESSION_EXPORT_MAX_ITEMS = 8;", source)
        self.assertIn("SESSION_EXPORT_MAX_TOTAL_BYTES = 4 * 1_024 * 1_024 * 1_024;", source)
        self.assertIn("8 items, 4 GiB total", paths["gateway/exports"]["retention"])

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


class AuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="home-layout-audit-")).resolve()
        self.addCleanup(shutil.rmtree, self.base, True)
        self.fixture = Fixture(self.base)
        self.home = self.base / "custom installation"
        self.home.mkdir(mode=0o700)
        paths = {key: dict(value) for key, value in PATHS.items()}
        for key in ("gateway", "workspace", "workspace/files", "workspace/state", "internal", "agent"):
            paths[key]["container"] = True
        paths["logs"] = {**entry(), "container": True}
        paths["logs/event-*.json"] = entry()
        self.fixture.write(REGISTRY, json.dumps({"version": 1, "paths": paths}))

    def audit(self, *args: str, home: Path | None = None) -> tuple[int, dict]:
        result = self.fixture.run("audit", "--home", str(home or self.home), "--json", *args)
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_custom_home_lazy_absence_and_source_identity(self) -> None:
        code, report = self.audit()
        self.assertEqual(code, 0)
        self.assertTrue(report["complete"])
        self.assertFalse(report["truncated"])
        self.assertEqual(report["entries"], [])
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["home"], str(self.home))
        self.assertEqual(report["root"]["type"], "directory")
        self.assertEqual(len(report["source"]["manifest_sha256"]), 64)
        self.assertIn("revision", report["source"])

    def test_read_only_hidden_unknowns_secret_bodies_and_backup_preservation(self) -> None:
        (self.home / "gateway").mkdir()
        (self.home / "gateway/devices.json").write_text("SECRET_SENTINEL_DO_NOT_DISCLOSE")
        (self.home / ".hidden").write_text("SECRET_SENTINEL_DO_NOT_DISCLOSE")
        (self.home / "backup-20200101").mkdir()
        (self.home / "backup-20200101/only-copy").write_bytes(b"unique recovery")
        before = snapshot(self.home)
        code, report = self.audit()
        self.assertEqual(code, 1)
        self.assertTrue(report["complete"])
        self.assertEqual({item["path"] for item in report["findings"]}, {".hidden", "backup-20200101"})
        self.assertNotIn("SECRET_SENTINEL", json.dumps(report))
        self.assertEqual(snapshot(self.home, contents_first=False), before)

    def test_child_override_aggregate_and_opaque_owner_boundaries(self) -> None:
        (self.home / "workspace/files/topic").mkdir(parents=True)
        (self.home / "workspace/files/topic/not-registry-owned").write_text("document")
        (self.home / "workspace/files/Profile.json").write_text("private")
        (self.home / "workspace/state/unknown-owner").mkdir(parents=True)
        (self.home / "internal/pi-subagents/version").mkdir(parents=True)
        (self.home / "internal/pi-subagents/version/arbitrary").write_text("external")
        code, report = self.audit()
        self.assertEqual(code, 1)
        entries = {item["path"]: item for item in report["entries"]}
        self.assertEqual(entries["workspace/files/Profile.json"]["classification"], "registered")
        self.assertEqual(entries["workspace/files/Profile.json"]["registration"], "workspace/files/Profile.json")
        self.assertEqual(entries["workspace/files/topic"]["classification"], "delegated")
        self.assertTrue(entries["internal/pi-subagents"]["opaque"])
        self.assertNotIn("internal/pi-subagents/version", entries)
        self.assertNotIn("workspace/files/topic/not-registry-owned", entries)
        self.assertEqual([item["path"] for item in report["findings"]], ["workspace/state/unknown-owner"])

    def test_delegated_documents_do_not_inherit_the_boundary_directory_type(self) -> None:
        (self.home / "workspace/files").mkdir(parents=True)
        (self.home / "workspace/files/INDEX.md").write_text("document index")
        (self.home / "workspace/files/report.json").write_text("SECRET_SENTINEL_DO_NOT_DISCLOSE")
        before = snapshot(self.home)
        code, report = self.audit()
        self.assertEqual(code, 0)
        self.assertTrue(report["complete"])
        self.assertEqual(report["findings"], [])
        documents = [item for item in report["entries"] if item["type"] == "file"]
        self.assertEqual(len(documents), 2)
        self.assertTrue(all(item["classification"] == "delegated" for item in documents))
        self.assertNotIn("SECRET_SENTINEL", json.dumps(report))
        self.assertEqual(snapshot(self.home, contents_first=False), before)

    def test_child_override_fences_the_parent_delegation(self) -> None:
        (self.home / "workspace/files/Profile.json").mkdir(parents=True)
        (self.home / "workspace/files/Profile.json/not-a-profile").touch()
        code, report = self.audit()
        self.assertEqual(code, 1)
        self.assertEqual(report["findings"], [{"path": "workspace/files/Profile.json/not-a-profile", "reasons": ["unknown"]}])

    def test_component_patterns_do_not_admit_deeper_or_hidden_children(self) -> None:
        (self.home / "logs/event-good.json").mkdir(parents=True)
        (self.home / "logs/event-good.json/not-covered").write_text("x")
        (self.home / "logs/.hidden").touch()
        (self.home / "logs/event-ok.json").touch()
        code, report = self.audit()
        self.assertEqual(code, 1)
        entries = {item["path"]: item for item in report["entries"]}
        self.assertEqual(entries["logs/event-ok.json"]["classification"], "pattern")
        self.assertEqual(entries["logs/event-good.json/not-covered"]["classification"], "unknown")
        self.assertIn("logs/.hidden", {item["path"] for item in report["findings"]})

    def test_links_special_files_and_boundary_mismatches(self) -> None:
        target = self.base / "outside"
        target.mkdir()
        (target / "must-not-appear").write_text("SECRET_SENTINEL_DO_NOT_DISCLOSE")
        (self.home / "workspace").symlink_to(target, target_is_directory=True)
        (self.home / "internal").write_text("not a container")
        os.mkfifo(self.home / "pipe")
        code, report = self.audit()
        self.assertEqual(code, 1)
        self.assertTrue(report["complete"])
        self.assertEqual(len(report["findings"]), 3)
        self.assertNotIn("must-not-appear", json.dumps(report))
        self.assertNotIn("SECRET_SENTINEL", json.dumps(report))
        self.assertEqual({item["type"] for item in report["entries"]}, {"symlink", "file", "special"})
        link = self.base / "linked-home"
        link.symlink_to(self.home, target_is_directory=True)
        code, report = self.audit(home=link)
        self.assertEqual(code, 2)
        self.assertFalse(report["complete"])
        self.assertTrue(report["errors"])
        code, report = self.audit(home=link / "gateway")
        self.assertEqual(code, 2)
        self.assertFalse(report["complete"])

    def test_missing_root_and_truncated_scan_never_claim_clean(self) -> None:
        code, report = self.audit(home=self.base / "missing")
        self.assertEqual(code, 2)
        self.assertFalse(report["complete"])
        for index in range(4):
            (self.home / f"unknown-{index}").touch()
        code, report = self.audit("--max-entries", "2")
        self.assertEqual(code, 2)
        self.assertFalse(report["complete"])
        self.assertTrue(report["truncated"])
        self.assertEqual(len(report["entries"]), 2)

    def test_directory_replacement_and_enumeration_races_are_incomplete(self) -> None:
        for phase in ("open", "scandir"):
            with self.subTest(phase=phase):
                gateway = self.home / "gateway"
                gateway.mkdir(exist_ok=True)
                runner = self.base / "race.py"
                runner.write_text(
                    "import os, pathlib, runpy, sys\n"
                    f"target = {str(gateway)!r}\n"
                    f"phase = {phase!r}\n"
                    "original_open, original_scandir = os.open, os.scandir\n"
                    "fired = False\n"
                    "def race_open(path, flags, *args, **kwargs):\n"
                    "    global fired\n"
                    "    if phase == 'open' and path == 'gateway' and not fired:\n"
                    "        fired = True\n"
                    "        os.rename(target, target + '.saved')\n"
                    "        os.mkdir(target)\n"
                    "    return original_open(path, flags, *args, **kwargs)\n"
                    "def race_scandir(fd):\n"
                    "    global fired\n"
                    "    if phase == 'scandir' and not fired and os.fstat(fd).st_ino == os.stat(target).st_ino:\n"
                    "        fired = True\n"
                    "        os.rename(target, target + '.saved')\n"
                    "        os.mkdir(target)\n"
                    "    return original_scandir(fd)\n"
                    "os.open, os.scandir = race_open, race_scandir\n"
                    f"sys.argv = [{TOOL!r}, 'audit', '--home', {str(self.home)!r}, '--json']\n"
                    f"runpy.run_path({str(self.fixture.repo / TOOL)!r}, run_name='__main__')\n"
                )
                result = subprocess.run(["python3", str(runner)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                report = json.loads(result.stdout)
                self.assertFalse(report["complete"])
                self.assertTrue(report["errors"])
                expected = "directory_changed_before_open" if phase == "open" else "directory_replaced_or_changed"
                self.assertIn(expected, {item["reason"] for item in report["errors"]})
                shutil.rmtree(self.home / "gateway.saved")

    def test_malformed_source_returns_json_exit_two_without_home_traversal(self) -> None:
        runner = self.base / "malformed-source.py"
        runner.write_text(
            "import os, pathlib, runpy, sys\n"
            "original_open = os.open\n"
            "def forbid_directory_open(path, flags, *args, **kwargs):\n"
            "    if flags & os.O_DIRECTORY:\n"
            "        raise AssertionError('home traversal for malformed registry')\n"
            "    return original_open(path, flags, *args, **kwargs)\n"
            "os.open = forbid_directory_open\n"
            f"sys.argv = [{TOOL!r}, 'audit', '--home', {str(self.home)!r}, '--json']\n"
            f"runpy.run_path({str(self.fixture.repo / TOOL)!r}, run_name='__main__')\n"
        )
        incomplete = entry()
        del incomplete["owner"]
        for value in ([], {"version": 1, "paths": []}, {"version": 1, "paths": {"x": None}},
                      {"version": 1, "paths": {"x": incomplete}},
                      {"version": 1, "paths": {"../escape": entry()}},
                      {"version": 1, "paths": {"/absolute": entry()}},
                      {"version": 1, "paths": {"x": {**entry(), "container": "yes"}}}):
            with self.subTest(registry=value):
                self.fixture.write(REGISTRY, json.dumps(value))
                result = subprocess.run(["python3", str(runner)], capture_output=True, text=True)
                self.assertEqual(result.stderr, "", result.stderr)
                self.assertEqual(result.returncode, 2)
                report = json.loads(result.stdout)
                self.assertFalse(report["complete"])
                self.assertIsNone(report["root"])
                self.assertEqual(report["entries"], [])
                self.assertEqual(report["errors"][0]["reason"], "invalid_registry")

    def test_no_effectful_audit_options_exist(self) -> None:
        before = snapshot(self.home)
        for option in ("--apply", "--prune", "--quarantine", "--output"):
            result = self.fixture.run("audit", "--home", str(self.home), "--json", option)
            self.assertEqual(result.returncode, 2)
        self.assertEqual(snapshot(self.home, contents_first=False), before)


if __name__ == "__main__":
    unittest.main()
