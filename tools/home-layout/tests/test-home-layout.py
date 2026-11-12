#!/usr/bin/env python3
"""CLI tests for `scripts/tron home-layout` (docs/tron-home.md).

The real repository's registry and source must check clean. The other cases
copy the shipped tool into a disposable Git repository with a small registry:
`check` refuses an entry whose owner is not a module, the version 1 field shape,
a rebuildable subtree with no prune rule, an unregistered Tron-home literal
(Stable or Debug home, shell variable, wrapped Gateway join, Swift chain); it
ignores tests. `audit` and `migrate` run against disposable homes and never
change them.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = "tools/home-layout/home_layout.py"
REGISTRY = "packages/gateway/src/foundation/tron-home-layout.json"


def entry(owner: str = "repo/fixture", **fields: object) -> dict:
    return {"owner": owner, **fields}


def registry(paths: dict, retired: list | None = None) -> str:
    return json.dumps({"version": 2, "paths": paths, "retired": retired or []})


PATHS = {
    "gateway": entry(**{"class": "keep"}), "gateway/devices.json": entry(credential=True),
    "workspace": entry(**{"class": "keep"}), "workspace/files": entry(subtree=True),
    "workspace/files/Profile.json": entry(), "workspace/state": entry(), "workspace/state/profile": entry(subtree=True),
    "internal": entry(**{"class": "scratch"}),
    "internal/pi-subagents": entry(subtree=True, prune={"when": "replaced on install"}),
    "agent": entry(**{"class": "keep"}),
}


class Fixture:
    def __init__(self, base: Path):
        self.repo = base / "repo"
        (self.repo / "tools/home-layout").mkdir(parents=True)
        shutil.copy2(ROOT / TOOL, self.repo / TOOL)
        shutil.copytree(ROOT / "tools/ownership", self.repo / "tools/ownership", ignore=shutil.ignore_patterns("tests", "__pycache__"))
        self.write("fixture.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        self.write(REGISTRY, registry(PATHS))
        self.git("init", "-q", "-b", "main")

    def write(self, relative: str, text: str) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True,
                       env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})

    def run(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess[str]:
        self.git("add", "-A")
        return subprocess.run(["python3", str(self.repo / TOOL), *args], cwd=self.repo, capture_output=True, text=True,
                              env={**os.environ, **(env or {})})


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
        self.assertEqual(paths["gateway/exports"]["prune"], {"maxAge": "30m", "maxEntries": 8, "maxBytes": 4 * 1024 ** 3})

    def test_check_refuses_unregistered_literals_outside_tests(self) -> None:
        fixture = Fixture(self.base)
        fixture.write(REGISTRY, registry({**PATHS, "logs": entry("repo/missing", **{"class": "log"})}))
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

    def test_check_sees_debug_homes_shell_variables_wrapped_joins_and_swift_chains(self) -> None:
        fixture = Fixture(self.base)
        fixture.write("scripts/dev", '#!/bin/bash\nSTATE_DIR="$HOME/.tron-dev/gateway"\nPID_FILE="$STATE_DIR/bogus.pid"\n'
                      'DEVICES="$STATE_DIR/devices.json"\nLEASE="$STATE_DIR/lease-$id.lock"\n'
                      'NESTED="$PID_FILE/child"\nrm -f "${STATE_DIR}/gate"\n')
        fixture.write("scripts/inspect.sh", 'cat "$HOME/.tron-dev/bogus/state.json" "$HOME/.tron-dev/gateway/devices.json"\n')
        fixture.write("packages/gateway/src/worktrees.ts", 'this.root = join(resolve(tronHome), "gateway", "worktrees");\n'
                      'const config = join(installRoot(tronHome), "configs");\n'
                      'const store = join(dirname(tronHome), ".tron-maintenance", "replace");\n')
        fixture.write("packages/mac-app/Sources/Paths.swift",
                      'static func bearer(profile: Profile) -> URL {\n'
                      '    tronHome(profile: profile).appendingPathComponent("gateway", isDirectory: true)\n'
                      '        .appendingPathComponent("bogus.json", isDirectory: false)\n'
                      '}\n'
                      'let devices = tronHome(profile: profile).appendingPathComponent("gateway", isDirectory: true)\n'
                      '    .appendingPathComponent("devices.json", isDirectory: false)\n'
                      'let named = tronHome.appendingPathComponent("gateway").appendingPathComponent("\\(name).json")\n'
                      'let quit = tronHome.deletingLastPathComponent().appendingPathComponent(".tron-maintenance/replace/quit")\n')
        result = fixture.run("check")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("scripts/dev:3: gateway/bogus.pid is not in", result.stdout)
        self.assertIn("scripts/dev:6: gateway/bogus.pid/child is not in", result.stdout)
        self.assertIn("scripts/dev:7: gateway/gate is not in", result.stdout)
        self.assertIn("scripts/inspect.sh:1: bogus/state.json is not in", result.stdout)
        self.assertIn("packages/gateway/src/worktrees.ts:1: resolve Tron-home paths with tronHomePath()", result.stdout)
        self.assertIn("packages/mac-app/Sources/Paths.swift:2: gateway/bogus.json is not in", result.stdout)
        self.assertEqual(len(result.stdout.strip().splitlines()), 7, result.stdout)

    def test_check_refuses_the_version_1_shape_and_rebuildable_subtrees_without_a_prune_rule(self) -> None:
        fixture = Fixture(self.base)
        legacy = {"owner": "repo/fixture", "writer": "gateway", "life": "durable", "rebuild": "none", "backup": True,
                  "secret": None, "retention": "single document", "view": "system"}
        fixture.write(REGISTRY, json.dumps({"version": 1, "paths": {"gateway": legacy}}))
        result = fixture.run("check")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("registry version must be 2", result.stdout)
        cases = {
            "unknown field(s) life, rebuild, retention, secret, view, writer": {"gateway": {**legacy, "class": "keep"}},
            "gateway: a top-level entry states its class": {"gateway": entry()},
            "cache: a rebuild subtree states its prune rule": {"cache": entry(**{"class": "rebuild"}, subtree=True)},
            "workspace/scratch: a scratch subtree states its prune rule":
                {"workspace": entry(**{"class": "keep"}), "workspace/scratch": entry(**{"class": "scratch"}, subtree=True)},
            "cache: prune needs a bound": {"cache": entry(**{"class": "rebuild"}, subtree=True, prune={"by": "nobody"})},
            "cache: prune.maxAge is a count and a unit": {"cache": entry(**{"class": "rebuild"}, subtree=True, prune={"maxAge": "soon"})},
            "cache: prune.keepNewest must be a positive integer": {"cache": entry(**{"class": "rebuild"}, subtree=True, prune={"keepNewest": 0})},
            "gateway: class must be one of": {"gateway": entry(**{"class": "durable"})},
            "gateway/devices.json: credential is true or absent": {"gateway": entry(**{"class": "keep"}), "gateway/devices.json": entry(credential="yes")},
        }
        for message, paths in cases.items():
            with self.subTest(message=message):
                fixture.write(REGISTRY, registry(paths))
                result = fixture.run("check")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(message, result.stdout)
        for retired in ([{"from": "gateway"}], [{"from": "gateway", "to": "../state"}], [{"from": "gateway", "to": "gateway"}],
                        [{"from": "gateway", "to": "state"}, {"from": "gateway", "to": "other"}], [{"from": "/gateway", "to": "state"}]):
            with self.subTest(retired=retired):
                fixture.write(REGISTRY, registry(PATHS, retired))
                result = fixture.run("check")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("retired: ", result.stdout)
        fixture.write(REGISTRY, registry({**PATHS, "cache": entry(**{"class": "rebuild"}, subtree=True, prune={"keepNewest": 5, "maxAge": "14d"})},
                                         [{"from": "gateway", "to": "state"}, {"from": "old-backup", "to": "~/.tron-maintenance/backups/old"}]))
        result = fixture.run("check")
        self.assertEqual(result.returncode, 0, result.stdout)


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
        paths["logs"] = entry(**{"class": "log"}, container=True)
        paths["logs/event-*.json"] = entry()
        self.fixture.write(REGISTRY, registry(paths))

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
        (self.home / "gateway/devices.json").chmod(0o600)
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

    def test_rows_carry_class_and_backup_and_an_exposed_credential_is_a_finding(self) -> None:
        (self.home / "gateway").mkdir()
        devices = self.home / "gateway/devices.json"
        devices.write_text("SECRET_SENTINEL_DO_NOT_DISCLOSE")
        devices.chmod(0o600)
        (self.home / "internal/pi-subagents").mkdir(parents=True)
        (self.home / "logs").mkdir()
        (self.home / "logs/event-a.json").touch()
        code, report = self.audit()
        self.assertEqual((code, report["findings"]), (0, []))
        rows = {item["path"]: (item["class"], item["backup"]) for item in report["entries"]}
        self.assertEqual(rows, {"gateway": ("keep", True), "gateway/devices.json": ("keep", True), "internal": ("scratch", False),
                                "internal/pi-subagents": ("scratch", False), "logs": ("log", False), "logs/event-a.json": ("log", False)})
        devices.chmod(0o640)
        code, report = self.audit()
        self.assertEqual(code, 1)
        self.assertEqual(report["findings"], [{"path": "gateway/devices.json", "reasons": ["credential_mode"]}])
        self.assertNotIn("SECRET_SENTINEL", json.dumps(report))

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
        valid = entry(**{"class": "keep"})
        for value in ([], {"version": 1, "paths": {}}, {"version": 2, "paths": []}, {"version": 2, "paths": {"x": None}},
                      {"version": 2, "paths": {"x": {"class": "keep"}}},
                      {"version": 2, "paths": {"../escape": valid}},
                      {"version": 2, "paths": {"/absolute": valid}},
                      {"version": 2, "paths": {"x": {**valid, "writer": "gateway"}}},
                      {"version": 2, "paths": {"x": valid}, "retired": [{"from": "x"}]},
                      {"version": 2, "paths": {"x": {**valid, "container": "yes"}}}):
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


class MigrateTests(unittest.TestCase):
    RETIRED = [{"from": "gateway", "to": "state"},
               {"from": "backup-1", "to": "~/.tron-maintenance/backups/2026-01-01-one"},
               {"from": "mac-terminal", "to": "state/mac-terminal"}]

    def setUp(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="home-layout-migrate-")).resolve()
        self.addCleanup(shutil.rmtree, self.base, True)
        self.fixture = Fixture(self.base)
        self.user = self.base / "user"
        self.home = self.user / ".tron"
        (self.home / "gateway").mkdir(parents=True, mode=0o700)
        (self.home / "gateway/devices.json").write_text("SECRET_SENTINEL_DO_NOT_DISCLOSE")
        (self.home / "backup-1").mkdir()
        (self.home / "backup-1/only-copy").write_bytes(b"unique recovery")
        self.fixture.write(REGISTRY, registry(PATHS, self.RETIRED))

    def migrate(self, *args: str, home: Path | None = None) -> tuple[int, dict]:
        result = self.fixture.run("migrate", "--home", str(home or self.home), *args, env={"HOME": str(self.user)})
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_dry_run_plans_every_retired_move_and_changes_nothing(self) -> None:
        before = snapshot(self.user)
        code, report = self.migrate("--dry-run")
        self.assertEqual(code, 0, report)
        self.assertEqual((report["state"], report["blockers"], report["errors"]), ("not_started", [], []))
        self.assertEqual(len(report["source"]["manifest_sha256"]), 64)
        gateway, backup, terminal = report["moves"]
        self.assertEqual((gateway["state"], gateway["refusals"]), ("pending", []))
        self.assertEqual((gateway["source"], gateway["destination"]), (str(self.home / "gateway"), str(self.home / "state")))
        self.assertEqual((gateway["identity"]["type"], gateway["identity"]["inode"]), ("directory", (self.home / "gateway").lstat().st_ino))
        self.assertEqual((backup["state"], backup["destination"]),
                         ("pending", str(self.user / ".tron-maintenance/backups/2026-01-01-one")))
        self.assertEqual((terminal["state"], terminal["identity"], terminal["refusals"]), ("absent", None, []))
        self.assertNotIn("SECRET_SENTINEL", json.dumps(report))
        self.assertEqual(snapshot(self.user, contents_first=False), before)

    def test_dry_run_names_what_an_apply_would_refuse(self) -> None:
        (self.home / "state").mkdir()
        (self.base / "elsewhere").mkdir()
        shutil.rmtree(self.home / "backup-1")
        (self.home / "backup-1").symlink_to(self.base / "elsewhere", target_is_directory=True)
        (self.home / "mac-terminal").mkdir()
        (self.home / "moved").write_text("x")
        (self.user / ".tron-maintenance").symlink_to(self.base / "elsewhere", target_is_directory=True)
        lock = self.home / "agent/.tron-gateway-runtime.lock.lock"
        lock.mkdir(parents=True)
        self.fixture.write(REGISTRY, registry(PATHS, [*self.RETIRED, {"from": "moved", "to": "~/.tron-maintenance/backups/moved"}]))
        before = snapshot(self.user)
        code, report = self.migrate("--dry-run")
        self.assertEqual(code, 1)
        self.assertEqual(report["blockers"], ["gateway_running"])
        self.assertEqual({row["from"]: (row["state"], row["refusals"]) for row in report["moves"]}, {
            "gateway": ("conflict", ["destination_exists"]),
            "backup-1": ("pending", ["unsafe_type", "symlink_component"]),
            "mac-terminal": ("pending", []),
            "moved": ("pending", ["symlink_component"])})
        self.assertEqual(report["state"], "conflict")
        self.assertEqual(snapshot(self.user, contents_first=False), before)
        stale = time.time() - 600
        os.utime(lock, (stale, stale))
        code, report = self.migrate("--dry-run")
        self.assertEqual((code, report["blockers"]), (1, []))

    def test_dry_run_refuses_a_destination_on_another_volume(self) -> None:
        runner = self.base / "other-volume.py"
        runner.write_text(
            "import os, runpy, sys\n"
            f"target = {str(self.home)!r}\n"
            "original = os.lstat\n"
            "def lstat(path, *args, **kwargs):\n"
            "    info = original(path, *args, **kwargs)\n"
            "    if str(path) != target:\n"
            "        return info\n"
            "    return os.stat_result((info.st_mode, info.st_ino, info.st_dev + 1, info.st_nlink, info.st_uid, info.st_gid,\n"
            "                           info.st_size, info.st_atime, info.st_mtime, info.st_ctime))\n"
            "os.lstat = lstat\n"
            f"sys.argv = [{TOOL!r}, 'migrate', '--home', {str(self.home)!r}, '--dry-run']\n"
            f"runpy.run_path({str(self.fixture.repo / TOOL)!r}, run_name='__main__')\n"
        )
        self.fixture.git("add", "-A")
        result = subprocess.run(["python3", str(runner)], capture_output=True, text=True, env={**os.environ, "HOME": str(self.user)})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual({row["from"]: row["refusals"] for row in report["moves"]},
                         {"gateway": ["cross_volume"], "backup-1": [], "mac-terminal": []})

    def test_status_tells_not_started_partly_applied_applied_and_conflict(self) -> None:
        def status() -> tuple[int, str, dict]:
            code, report = self.migrate("--status")
            self.assertEqual(set(report["moves"][0]), {"from", "to", "state"})
            return code, report["state"], {row["from"]: row["state"] for row in report["moves"]}
        self.assertEqual(status(), (1, "not_started", {"gateway": "pending", "backup-1": "pending", "mac-terminal": "absent"}))
        (self.home / "gateway").rename(self.home / "state")
        self.assertEqual(status(), (1, "partly_applied", {"gateway": "done", "backup-1": "pending", "mac-terminal": "absent"}))
        (self.user / ".tron-maintenance/backups").mkdir(parents=True)
        (self.home / "backup-1").rename(self.user / ".tron-maintenance/backups/2026-01-01-one")
        self.assertEqual(status(), (0, "applied", {"gateway": "done", "backup-1": "done", "mac-terminal": "absent"}))
        (self.home / "gateway").mkdir()
        self.assertEqual(status()[:2], (1, "conflict"))
        self.fixture.write(REGISTRY, registry(PATHS))
        self.assertEqual(self.migrate("--status")[1]["state"], "nothing_declared")
        self.assertEqual(self.migrate("--dry-run")[0], 0)

    def test_the_shipped_registry_declares_no_move_yet(self) -> None:
        result = subprocess.run(["python3", str(ROOT / TOOL), "migrate", "--home", str(self.home), "--status"],
                                cwd=ROOT, capture_output=True, text=True, env={**os.environ, "HOME": str(self.user)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "nothing_declared")

    def test_unreadable_homes_are_errors_and_no_effectful_mode_exists(self) -> None:
        link = self.base / "linked-home"
        link.symlink_to(self.home, target_is_directory=True)
        for home in (self.base / "missing", link):
            with self.subTest(home=home):
                code, report = self.migrate("--dry-run", home=home)
                self.assertEqual(code, 2)
                self.assertEqual(report["errors"][0]["reason"], "home_unavailable")
                self.assertEqual(report["moves"], [])
        before = snapshot(self.user)
        for arguments in (["--apply"], ["--rollback"], [], ["--dry-run", "--status"], ["--dry-run", "--apply"]):
            result = self.fixture.run("migrate", "--home", str(self.home), *arguments, env={"HOME": str(self.user)})
            self.assertEqual(result.returncode, 2, arguments)
            self.assertEqual(result.stdout, "")
        self.assertEqual(snapshot(self.user, contents_first=False), before)


if __name__ == "__main__":
    unittest.main()
