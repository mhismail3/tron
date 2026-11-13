#!/usr/bin/env python3
"""CLI tests for `scripts/tron home-layout` (docs/tron-home.md).

The real repository's registry and source must check clean. The other cases
copy the shipped tool into a disposable Git repository with a small registry:
`check` refuses an entry whose owner is not a module, the version 1 field shape,
a rebuildable subtree with no prune rule, an unregistered Tron-home literal
(Stable or Debug home, shell variable, wrapped Gateway join, Swift chain); it
ignores tests. `audit` and migration planning are read-only; apply and rollback run only against
disposable homes.
"""

from __future__ import annotations

import hashlib
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
        for module in ("runtime_layout.py", "runtime_rewrites.py", "terminal_layout.py"):
            shutil.copy2(ROOT / "tools/home-layout" / module, self.repo / "tools/home-layout" / module)
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
        return subprocess.run(["python3", "-B", str(self.repo / TOOL), *args], cwd=self.repo, capture_output=True, text=True,
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
        self.assertIn("SESSION_EXPORT_MAX_ITEM_BYTES = 2 * 1_024 * 1_024 * 1_024;", source)
        self.assertEqual(paths["state/exports"]["prune"], {"maxAge": "30m", "maxEntries": 8, "maxBytes": 4 * 1024 ** 3,
                                                             "when": "2 GiB per item; 4 readers, 1 production"})

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

    def test_check_requires_exact_external_owner_names(self) -> None:
        fixture = Fixture(self.base)
        for owner in ("pi-sdk-typo", "pi-subagentsOld", "extensionX", "extension", "extension "):
            with self.subTest(owner=owner):
                fixture.write(REGISTRY, registry({**PATHS, "logs": entry(owner, **{"class": "log"})}))
                result = fixture.run("check")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(f"logs: owner {owner} is not a module", result.stdout)
        for owner in ("pi-sdk", "pi-subagents", "extension pi-web-access", "extension @scope/package"):
            with self.subTest(owner=owner):
                fixture.write(REGISTRY, registry({**PATHS, "logs": entry(owner, **{"class": "log"})}))
                result = fixture.run("check")
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_check_sees_debug_homes_shell_variables_wrapped_joins_and_swift_chains(self) -> None:
        fixture = Fixture(self.base)
        fixture.write("scripts/dev", '#!/bin/bash\nSTATE_DIR="$HOME/.tron-dev/gateway"\nPID_FILE="$STATE_DIR/bogus.pid"\n'
                      'DEVICES="$STATE_DIR/devices.json"\nLEASE="$STATE_DIR/lease-$id.lock"\n'
                      'NESTED="$PID_FILE/child"\nrm -f "${STATE_DIR}/gate"\n'
                      'ROOT_HOME="$HOME/.tron-dev"\ncat "$ROOT_HOME/bogus/root.json" "$ROOT_HOME/gateway/devices.json"\n'
                      'UDID="${OVERRIDE:-$HOME/.tron/gateway}/bogus-default"\n'
                      'STATE_DIR=/tmp/elsewhere\ntouch "$STATE_DIR/not-a-home-path"\n')
        fixture.write("scripts/inspect.sh", 'cat "$HOME/.tron-dev/bogus/state.json" "$HOME/.tron-dev/gateway/devices.json"\n')
        fixture.write("packages/gateway/src/worktrees.ts", 'this.root = join(resolve(tronHome), "gateway", "worktrees");\n'
                      'const other = path.join(path.resolve(options.tronHome), "gateway", "devices.json");\n'
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
        self.assertIn("scripts/dev:9: bogus/root.json is not in", result.stdout)
        self.assertIn("scripts/dev:10: gateway/bogus-default is not in", result.stdout)
        self.assertNotIn("not-a-home-path", result.stdout)
        self.assertIn("packages/gateway/src/worktrees.ts:2: resolve Tron-home paths with tronHomePath()", result.stdout)
        self.assertIn("scripts/inspect.sh:1: bogus/state.json is not in", result.stdout)
        self.assertIn("packages/gateway/src/worktrees.ts:1: resolve Tron-home paths with tronHomePath()", result.stdout)
        self.assertIn("packages/mac-app/Sources/Paths.swift:2: gateway/bogus.json is not in", result.stdout)
        self.assertEqual(len(result.stdout.strip().splitlines()), 10, result.stdout)

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
                        [{"from": "gateway", "to": "state"}, {"from": "gateway", "to": "other"}], [{"from": "/gateway", "to": "state"}],
                        [{"from": "gateway", "to": "state"}, {"from": "internal", "to": "state"}],
                        [{"from": "gateway", "to": "gateway/inside"}]):
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

    def test_maintenance_index_requires_an_owner_and_rule_for_each_entry(self) -> None:
        maintenance = self.base / "maintenance"
        (maintenance / "backups/2026-01-01-only-copy").mkdir(parents=True)
        (maintenance / "replace").mkdir()
        (maintenance / "README.md").write_text(
            "| Entry | Former name | Owner | Created | End-of-life rule |\n"
            "| --- | --- | --- | --- | --- |\n"
            "| replace | unchanged | mac-app/replace | 2026-01-01 | owner prunes superseded sets |\n"
            "| backups | unchanged | maintainer | 2026-01-01 | review each copy |\n"
            "| backups/2026-01-01-only-copy | old | | 2026-01-01 | |\n")
        args = ("audit", "--home", str(self.home), "--json", "--maintenance", str(maintenance))
        result = self.fixture.run(*args)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["findings"], [
            {"path": "maintenance/backups/2026-01-01-only-copy", "reasons": ["maintenance_index"]}])
        readme = maintenance / "README.md"
        readme.write_text(readme.read_text().replace("| old | | 2026-01-01 | |", "| old | maintainer | 2026-01-01 | explicit approval after release proof |"))
        before = snapshot(maintenance)
        result = self.fixture.run(*args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(snapshot(maintenance, contents_first=False), before)
        valid = readme.read_text()
        readme.write_text(valid + "\nUnrelated table\n\n| Name | Detail | Other |\n| replace | | |\n")
        self.assertEqual(self.fixture.run(*args).returncode, 0)
        readme.write_text(valid + "| replace | old | duplicate | 2026-01-01 | duplicate rule |\n")
        self.assertEqual(json.loads(self.fixture.run(*args).stdout)["findings"], [
            {"path": "maintenance/replace", "reasons": ["maintenance_index"]}])
        (maintenance / "legacy").mkdir()
        readme.write_text(valid + "\nUnrelated table\n\n| Name | Note | Owner | Extra | Rule |\n| legacy | x | someone | y | z |\n")
        self.assertEqual(json.loads(self.fixture.run(*args).stdout)["findings"], [
            {"path": "maintenance/legacy", "reasons": ["maintenance_index"]}])
        readme.unlink()
        self.assertEqual(self.fixture.run(*args).returncode, 1)

    def test_registered_debug_fifo_is_allowed_but_regular_files_and_other_fifos_are_not(self) -> None:
        paths = {**PATHS, "gateway/child-start.gate": entry(**{"class": "scratch", "type": "fifo"})}
        self.fixture.write(REGISTRY, registry(paths))
        (self.home / "gateway").mkdir()
        gate = self.home / "gateway/child-start.gate"
        os.mkfifo(gate)
        self.assertEqual(self.audit()[0], 0)
        gate.unlink()
        gate.touch()
        self.assertEqual(self.audit()[1]["findings"], [{"path": "gateway/child-start.gate", "reasons": ["expected_fifo"]}])
        os.mkfifo(self.home / "other-fifo")
        self.assertIn({"path": "other-fifo", "reasons": ["unknown", "unsafe_type"]}, self.audit()[1]["findings"])

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

    def use_recovery_registry(self) -> None:
        declaration = json.loads((ROOT / REGISTRY).read_text())
        declaration["retired"] = [row for row in declaration["retired"] if row["to"].startswith("~/")]
        self.fixture.write(REGISTRY, json.dumps(declaration))

    def migrate(self, *args: str, home: Path | None = None) -> tuple[int, dict]:
        result = self.fixture.run("migrate", "--home", str(home or self.home), *args, env={"HOME": str(self.user)})
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_dry_run_plans_every_retired_move_and_changes_nothing(self) -> None:
        before = snapshot(self.user)
        code, report = self.migrate("--dry-run")
        self.assertEqual(code, 0, report)
        self.assertEqual((report["state"], report["blockers"], report["errors"]), ("not_started", [], []))
        self.assertEqual(report["user_home"], str(self.user))
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
        (self.home / "blocked").write_text("x")
        (self.home / "occupied").write_text("a file where a folder is needed")
        self.fixture.write(REGISTRY, registry(PATHS, [*self.RETIRED, {"from": "moved", "to": "~/.tron-maintenance/backups/moved"},
                                                      {"from": "blocked", "to": "occupied/blocked"}]))
        before = snapshot(self.user)
        code, report = self.migrate("--dry-run")
        self.assertEqual(code, 1)
        self.assertEqual(report["blockers"], ["gateway_running"])
        self.assertEqual({row["from"]: (row["state"], row["refusals"]) for row in report["moves"]}, {
            "gateway": ("conflict", ["destination_exists"]),
            "backup-1": ("pending", ["unsafe_type", "symlink_component"]),
            "mac-terminal": ("pending", []),
            "moved": ("pending", ["symlink_component"]),
            "blocked": ("pending", ["parent_not_directory"])})
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

    def test_two_homes_share_destinations_without_claiming_each_others_moves(self) -> None:
        self.use_recovery_registry()
        stable = self.home
        debug = self.user / ".tron-dev"
        debug.mkdir()
        (debug / "gateway/proof-traffic").mkdir(parents=True)
        (debug / "gateway/proof-traffic/only-copy").write_text("debug")
        (stable / "gateway/home").mkdir()
        (stable / "gateway/home/chapter-reseals.jsonl").write_text("stable")
        shared = self.user / "Workspace/workspace-backups/x-library-20261111T1425"
        shared.mkdir(parents=True)
        (shared / "only-copy").write_text("shared")
        for home in (debug, stable):
            code, report = self.migrate("--apply", home=home)
            self.assertEqual(code, 0, report)
        self.assertEqual(self.migrate("--rollback", home=stable)[0], 0)
        self.assertEqual((stable / "gateway/home/chapter-reseals.jsonl").read_text(), "stable")
        self.assertFalse((debug / "gateway/proof-traffic").exists())
        self.assertFalse(shared.exists())
        self.assertEqual(self.migrate("--rollback", home=debug)[0], 0)
        self.assertEqual((debug / "gateway/proof-traffic/only-copy").read_text(), "debug")
        self.assertEqual((shared / "only-copy").read_text(), "shared")
        for home in (debug, stable):
            self.assertEqual(self.migrate("--apply", home=home)[0], 0)
        self.assertEqual(self.migrate("--rollback", home=debug)[0], 0)
        self.assertTrue(shared.exists())
        self.assertFalse((stable / "gateway/home/chapter-reseals.jsonl").exists())
        self.assertEqual(self.migrate("--rollback", home=stable)[0], 0)
        self.assertEqual((stable / "gateway/home/chapter-reseals.jsonl").read_text(), "stable")

    def test_forward_apply_journals_a_source_that_appears_after_its_first_apply(self) -> None:
        retired = [self.RETIRED[1], {"from": "late-backup", "to": "~/.tron-maintenance/backups/late-backup"}]
        self.fixture.write(REGISTRY, registry(PATHS, retired))
        self.assertEqual(self.migrate("--apply")[0], 0)
        (self.home / "late-backup").mkdir(mode=0o700)
        (self.home / "late-backup/only-copy").write_text("late")
        self.assertEqual(self.migrate("--dry-run")[0], 0)
        code, report = self.migrate("--apply")
        self.assertEqual(code, 0, report)
        self.assertFalse((self.home / "late-backup").exists())
        self.assertEqual(self.migrate("--status")[1]["state"], "applied")
        self.assertEqual(self.migrate("--rollback")[0], 0)
        self.assertEqual((self.home / "late-backup/only-copy").read_text(), "late")

    def test_a_crashed_home_retains_the_only_claim_on_a_shared_pending_move(self) -> None:
        self.use_recovery_registry()
        (self.home / "gateway/home").mkdir()
        (self.home / "gateway/home/chapter-reseals.jsonl").write_text("stable")
        debug = self.user / ".tron-dev"
        (debug / "gateway/proof-traffic").mkdir(parents=True)
        shared = self.user / "Workspace/workspace-backups/x-library-20261111T1425"
        shared.mkdir(parents=True)
        (shared / "only-copy").write_text("shared")
        runner = self.base / "crash-before-rename.py"
        runner.write_text(
            "import importlib.util, os\n"
            f"spec = importlib.util.spec_from_file_location('layout', {str(self.fixture.repo / TOOL)!r})\n"
            "layout = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = layout\nspec.loader.exec_module(layout)\n"
            "def rename(source, destination): os._exit(86)\n"
            "layout.rename_exclusive = rename\n"
            f"layout.main(['migrate', '--home', {str(self.home)!r}, '--apply'])\n")
        result = subprocess.run(["python3", "-B", str(runner)], env={**os.environ, "HOME": str(self.user)}, capture_output=True)
        self.assertEqual(result.returncode, 86, result.stderr)
        for lock in (self.home / "agent/.tron-gateway-runtime.lock.lock", debug / "agent/.tron-gateway-runtime.lock.lock"):
            lock.rmdir()
        for mode in ("--dry-run", "--apply"):
            before = snapshot(self.user)
            code, report = self.migrate(mode, home=debug)
            self.assertEqual(code, 1, report)
            self.assertIn("move_owned_by_other_home", json.dumps(report))
            self.assertEqual(snapshot(self.user, contents_first=False), before)
        self.assertEqual(self.migrate("--apply")[0], 0)
        self.assertEqual(self.migrate("--apply", home=debug)[0], 0)
        self.assertEqual(self.migrate("--rollback", home=debug)[0], 0)
        self.assertFalse(shared.exists())
        self.assertEqual(self.migrate("--rollback")[0], 0)
        self.assertEqual((shared / "only-copy").read_text(), "shared")

    def test_rollback_does_not_create_a_journal_removed_during_lock_acquisition(self) -> None:
        self.fixture.write(REGISTRY, registry(PATHS, [self.RETIRED[1]]))
        self.assertEqual(self.migrate("--apply")[0], 0)
        runner = self.base / "remove-journal.py"
        runner.write_text(
            "import contextlib, importlib.util\n"
            "from pathlib import Path\n"
            f"spec = importlib.util.spec_from_file_location('layout', {str(self.fixture.repo / TOOL)!r})\n"
            "layout = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = layout\nspec.loader.exec_module(layout)\n"
            "original = layout.runtime_lock\n"
            "@contextlib.contextmanager\ndef acquire(path):\n"
            "    with original(path) as guard:\n"
            f"        for journal in Path({str(self.user / '.tron-maintenance/layout-v2')!r}).glob('*.json'): journal.unlink()\n"
            "        yield guard\n"
            "layout.runtime_lock = acquire\n"
            f"raise SystemExit(layout.main(['migrate', '--home', {str(self.home)!r}, '--rollback']))\n")
        result = subprocess.run(["python3", "-B", str(runner)], env={**os.environ, "HOME": str(self.user)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("no_journal", result.stdout)
        self.assertEqual(list((self.user / ".tron-maintenance/layout-v2").glob("*.json")), [])

    def test_rollback_releases_each_claim_durably_for_the_other_home(self) -> None:
        self.use_recovery_registry()
        for crash_after in (0, 1, 2):
            with self.subTest(crash_after=crash_after):
                self.user = self.base / f"rollback-user-{crash_after}"
                self.home = self.user / ".tron"
                (self.home / "gateway/home").mkdir(parents=True)
                (self.home / "gateway/home/chapter-reseals.jsonl").write_text("stable")
                debug = self.user / ".tron-dev"
                (debug / "gateway/proof-traffic").mkdir(parents=True)
                shared = self.user / "Workspace/workspace-backups/x-library-20261111T1425"
                shared.mkdir(parents=True)
                (shared / "only-copy").write_text("shared")
                self.assertEqual(self.migrate("--apply", home=debug)[0], 0)
                if crash_after:
                    runner = self.base / "rollback-crash.py"
                    runner.write_text(
                        "import importlib.util, os\n"
                        f"spec = importlib.util.spec_from_file_location('layout', {str(self.fixture.repo / TOOL)!r})\n"
                        "layout = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = layout\nspec.loader.exec_module(layout)\n"
                        "original = layout.rename_exclusive\ncount = 0\n"
                        "def rename(source, destination):\n"
                        "    global count\n    original(source, destination)\n    count += 1\n"
                        f"    if count == {crash_after}: os._exit(86)\n"
                        "layout.rename_exclusive = rename\n"
                        f"layout.main(['migrate', '--home', {str(debug)!r}, '--rollback'])\n")
                    result = subprocess.run(["python3", "-B", str(runner)], env={**os.environ, "HOME": str(self.user)}, capture_output=True)
                    self.assertEqual(result.returncode, 86, result.stderr)
                    (debug / "agent/.tron-gateway-runtime.lock.lock").rmdir()
                    if crash_after == 1:
                        code, report = self.migrate("--apply")
                        self.assertEqual(code, 1, report)
                        self.assertIn("move_owned_by_other_home", json.dumps(report))
                    else:
                        self.assertEqual(self.migrate("--apply")[0], 0)
                self.assertEqual(self.migrate("--rollback", home=debug)[0], 0)
                if crash_after == 2:
                    self.assertFalse(shared.exists(), "other home's claimed move was inverted by this rollback")
                self.assertEqual(self.migrate("--apply")[0], 0)
                self.assertFalse(shared.exists())
                self.assertEqual(self.migrate("--rollback")[0], 0)
                self.assertEqual((shared / "only-copy").read_text(), "shared")
                self.assertEqual(self.migrate("--rollback", home=debug)[0], 0)

    def test_ctime_only_changes_during_locking_preserve_the_move_identity(self) -> None:
        self.fixture.write(REGISTRY, registry(PATHS, [self.RETIRED[1]]))
        source = self.home / "backup-1"
        original_inode = source.stat().st_ino
        runner = self.base / "ctime.py"
        runner.write_text(
            "import contextlib, importlib.util, os\n"
            f"spec = importlib.util.spec_from_file_location('layout', {str(self.fixture.repo / TOOL)!r})\n"
            "layout = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = layout\nspec.loader.exec_module(layout)\n"
            "original = layout.runtime_lock\n"
            "@contextlib.contextmanager\ndef acquire(path):\n"
            "    with original(path) as guard:\n"
            f"        os.chmod({str(source)!r}, 0o700)\n"
            "        yield guard\n"
            "layout.runtime_lock = acquire\n"
            f"raise SystemExit(layout.main(['migrate', '--home', {str(self.home)!r}, '--apply']))\n")
        result = subprocess.run(["python3", "-B", str(runner)], env={**os.environ, "HOME": str(self.user)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        destination = self.user / ".tron-maintenance/backups/2026-01-01-one"
        self.assertEqual(destination.stat().st_ino, original_inode)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)

    def test_apply_resume_and_rollback_preserve_identity_and_new_writes(self) -> None:
        self.fixture.write(REGISTRY, registry(PATHS, [self.RETIRED[1]]))
        before = (self.home / "backup-1").stat()
        code, report = self.migrate("--apply")
        self.assertEqual(code, 0, report)
        destination = self.user / ".tron-maintenance/backups/2026-01-01-one"
        self.assertFalse((self.home / "backup-1").exists())
        self.assertEqual(destination.stat().st_ino, before.st_ino)
        self.assertEqual(destination.stat().st_mode, before.st_mode)
        (destination / "new-after-move").write_text("new data")
        self.assertEqual(self.migrate("--apply")[0], 0)
        self.assertFalse((self.home / "agent/.tron-gateway-runtime.lock.lock").exists())
        self.assertFalse((self.user / ".tron-dev/agent/.tron-gateway-runtime.lock.lock").exists())
        code, report = self.migrate("--rollback")
        self.assertEqual(code, 0, report)
        self.assertEqual((self.home / "backup-1/new-after-move").read_text(), "new data")
        self.assertEqual((self.home / "backup-1").stat().st_ino, before.st_ino)
        self.assertFalse(destination.exists())
        self.assertEqual(self.migrate("--rollback")[0], 0)

    def test_a_crash_after_each_rename_resumes_without_replaying_a_move(self) -> None:
        for crash_after in (1, 2):
            with self.subTest(crash_after=crash_after):
                home = self.user / f"installation-{crash_after}"
                home.mkdir()
                for name in ("backup-a", "backup-b"):
                    (home / name).mkdir(mode=0o700)
                    (home / name / "only-copy").write_text(name)
                retired = [{"from": name, "to": f"~/.tron-maintenance/backups/{crash_after}-{name}"} for name in ("backup-a", "backup-b")]
                self.fixture.write(REGISTRY, registry(PATHS, retired))
                runner = self.base / "crash.py"
                runner.write_text(
                    "import importlib.util, os\n"
                    f"spec = importlib.util.spec_from_file_location('layout', {str(self.fixture.repo / TOOL)!r})\n"
                    "layout = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = layout\nspec.loader.exec_module(layout)\n"
                    "original = layout.rename_exclusive\ncount = 0\n"
                    "def rename(source, destination):\n"
                    "    global count\n    original(source, destination)\n    count += 1\n"
                    f"    if count == {crash_after}: os._exit(86)\n"
                    "layout.rename_exclusive = rename\n"
                    f"layout.main(['migrate', '--home', {str(home)!r}, '--apply'])\n")
                identities = {name: (home / name).stat().st_ino for name in ("backup-a", "backup-b")}
                result = subprocess.run(["python3", "-B", str(runner)], env={**os.environ, "HOME": str(self.user)}, capture_output=True)
                self.assertEqual(result.returncode, 86, result.stderr)
                for lock in (home / "agent/.tron-gateway-runtime.lock.lock", self.user / ".tron-dev/agent/.tron-gateway-runtime.lock.lock"):
                    self.assertTrue(lock.is_dir())
                    lock.rmdir()
                code, report = self.migrate("--apply", home=home)
                self.assertEqual(code, 0, report)
                self.assertEqual(self.migrate("--rollback", home=home)[0], 0)
                for name, inode in identities.items():
                    self.assertEqual((home / name).stat().st_ino, inode)
                    self.assertEqual((home / name / "only-copy").read_text(), name)

    def test_rollback_requires_a_journal_and_refuses_a_replaced_destination(self) -> None:
        self.fixture.write(REGISTRY, registry(PATHS, [self.RETIRED[1]]))
        self.assertEqual(self.migrate("--rollback")[0], 1)
        self.assertEqual(self.migrate("--apply")[0], 0)
        destination = self.user / ".tron-maintenance/backups/2026-01-01-one"
        destination.rename(destination.with_name("preserved"))
        destination.mkdir()
        code, report = self.migrate("--rollback")
        self.assertEqual(code, 1, report)
        self.assertTrue(destination.is_dir())
        self.assertFalse((self.home / "backup-1").exists())

    def test_apply_keeps_runtime_locks_fresh_during_a_slow_rename(self) -> None:
        self.fixture.write(REGISTRY, registry(PATHS, [self.RETIRED[1]]))
        runner = self.base / "slow.py"
        runner.write_text(
            "import importlib.util, os, time\n"
            f"spec = importlib.util.spec_from_file_location('layout', {str(self.fixture.repo / TOOL)!r})\n"
            "layout = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = layout\nspec.loader.exec_module(layout)\n"
            "original = layout.rename_exclusive\n"
            "def rename(source, destination):\n"
            f"    lock = {str(self.home / 'agent/.tron-gateway-runtime.lock.lock')!r}\n"
            "    stale = time.time() - 600\n    os.utime(lock, (stale, stale))\n"
            "    deadline = time.monotonic() + 15\n"
            "    while os.stat(lock).st_mtime < stale + 1 and time.monotonic() < deadline: time.sleep(0.05)\n"
            "    if os.stat(lock).st_mtime < stale + 1: raise RuntimeError('runtime lock heartbeat missing')\n"
            "    original(source, destination)\n"
            "layout.rename_exclusive = rename\n"
            f"raise SystemExit(layout.main(['migrate', '--home', {str(self.home)!r}, '--apply']))\n")
        result = subprocess.run(["python3", "-B", str(runner)], env={**os.environ, "HOME": str(self.user)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_journal_binding_unsafe_journals_and_unowned_destinations_refuse_in_plans_too(self) -> None:
        self.fixture.write(REGISTRY, registry(PATHS, [self.RETIRED[1]]))
        self.assertEqual(self.migrate("--apply")[0], 0)
        path = next((self.user / ".tron-maintenance/layout-v2").glob("*.json"))
        original = path.read_text()
        for failure in ("journal_contract_changed", "unsafe_journal", "invalid_journal", "move_identity_changed"):
            with self.subTest(failure=failure):
                path.write_text(original)
                path.chmod(0o600)
                value = json.loads(original)
                if failure == "journal_contract_changed":
                    value["registry"] = "a" * 64
                elif failure == "unsafe_journal":
                    path.chmod(0o644)
                elif failure == "invalid_journal":
                    value["moves"][0]["destination"] = str(self.user / "not-the-recorded-destination")
                else:
                    value["moves"][0]["identity"]["inode"] += 1
                path.write_text(json.dumps(value))
                for mode in ("--dry-run", "--apply", "--rollback"):
                    before = snapshot(self.user)
                    code, report = self.migrate(mode)
                    self.assertEqual(code, 1, report)
                    self.assertIn(failure, json.dumps(report))
                    self.assertEqual(snapshot(self.user, contents_first=False), before)
        path.write_text(original)
        path.chmod(0o600)
        path.unlink()
        path.parent.rmdir()
        before = snapshot(self.user)
        for mode in ("--dry-run", "--apply"):
            code, report = self.migrate(mode)
            self.assertEqual(code, 1, report)
            self.assertIn("unowned_destination", json.dumps(report))
            self.assertEqual(snapshot(self.user, contents_first=False), before)

    def test_stale_selected_home_lock_refuses_without_mutation(self) -> None:
        lock = self.home / "agent/.tron-gateway-runtime.lock.lock"
        lock.mkdir(parents=True)
        stale = time.time() - 600
        os.utime(lock, (stale, stale))
        before = snapshot(self.user)
        for mode in ("--apply", "--rollback"):
            code, report = self.migrate(mode)
            self.assertEqual(code, 1, report)
            self.assertIn("runtime_lock_present", report["blockers"])
            self.assertEqual(snapshot(self.user, contents_first=False), before)

    def test_a_source_removed_during_the_rename_cannot_be_reported_applied(self) -> None:
        self.fixture.write(REGISTRY, registry(PATHS, [self.RETIRED[1]]))
        runner = self.base / "vanish.py"
        runner.write_text(
            "import importlib.util, shutil\n"
            f"spec = importlib.util.spec_from_file_location('layout', {str(self.fixture.repo / TOOL)!r})\n"
            "layout = importlib.util.module_from_spec(spec)\nimport sys\nsys.modules[spec.name] = layout\nspec.loader.exec_module(layout)\n"
            "def rename(source, destination): shutil.rmtree(source)\n"
            "layout.rename_exclusive = rename\n"
            f"raise SystemExit(layout.main(['migrate', '--home', {str(self.home)!r}, '--apply']))\n")
        result = subprocess.run(["python3", "-B", str(runner)], env={**os.environ, "HOME": str(self.user)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotEqual(json.loads(result.stdout)["state"], "applied")
        self.assertIn("move_identity_changed", result.stdout)

    def test_debug_runtime_lock_refuses_all_modes_without_mutations(self) -> None:
        lock = self.user / ".tron-dev/agent/.tron-gateway-runtime.lock.lock"
        lock.mkdir(parents=True)
        before = snapshot(self.user)
        for mode in ("--dry-run", "--apply", "--rollback"):
            code, report = self.migrate(mode)
            self.assertEqual(code, 1, report)
            self.assertIn("debug_gateway_running", report["blockers"])
            self.assertEqual(snapshot(self.user, contents_first=False), before)

    def test_the_shipped_registry_declares_slice_b_moves(self) -> None:
        result = subprocess.run(["python3", str(ROOT / TOOL), "migrate", "--home", str(self.home), "--status"],
                                cwd=ROOT, capture_output=True, text=True, env={**os.environ, "HOME": str(self.user)})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "not_started")
        moves = json.loads(result.stdout)["moves"]
        self.assertEqual(len([row for row in moves if row["to"].startswith("~/")]), 14)
        self.assertTrue(any(row["from"].endswith("x-library-20261111T1425") for row in moves))

    def test_unreadable_homes_and_ambiguous_modes_are_errors(self) -> None:
        link = self.base / "linked-home"
        link.symlink_to(self.home, target_is_directory=True)
        ancestor = self.base / "linked-user"
        ancestor.symlink_to(self.user, target_is_directory=True)
        for home in (self.base / "missing", link, ancestor / self.home.name):
            with self.subTest(home=home):
                code, report = self.migrate("--dry-run", home=home)
                self.assertEqual(code, 2)
                self.assertEqual(report["errors"][0]["reason"], "home_unavailable")
                self.assertEqual(report["moves"], [])
        before = snapshot(self.user)
        for arguments in ([], ["--dry-run", "--status"], ["--dry-run", "--apply"]):
            result = self.fixture.run("migrate", "--home", str(self.home), *arguments, env={"HOME": str(self.user)})
            self.assertEqual(result.returncode, 2, arguments)
            self.assertEqual(result.stdout, "")
        self.assertEqual(snapshot(self.user, contents_first=False), before)


class RuntimeMigrationTests(unittest.TestCase):
    def sdk_process(self, action: str, base: Path, home: Path) -> subprocess.Popen:
        temporary = base / "tmp"
        temporary.mkdir(exist_ok=True)
        return subprocess.Popen([str(ROOT / "scripts/tron-node"), "exec", "node", str(ROOT / "tools/home-layout/tests/sdk-runtime-fixture.mjs"), action, str(ROOT), str(base), str(home)], stdout=subprocess.PIPE, stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                env={**os.environ, "HOME": str(home.parent), "TMPDIR": str(temporary), "PI_CODING_AGENT_DIR": str(home / "agent"), "PI_SUBAGENTS_TEMP_ROOT": str(home / ("internal/subagents" if action in {"create", "hold", "old"} else "state/subagents"))}, start_new_session=True)

    def sdk(self, action: str, base: Path, home: Path) -> dict:
        process = self.sdk_process(action, base, home)
        output, error = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, output + error)
        return json.loads(output)

    def test_actual_gateway_and_migrator_share_locks_and_fence_a_startup_race(self) -> None:
        with tempfile.TemporaryDirectory(prefix="home-layout-gateway-race-") as temporary:
            base = Path(temporary).resolve()
            fixture = Fixture(base)
            fixture.write(REGISTRY, (ROOT / REGISTRY).read_text())
            home = base / "user/.tron"
            home.mkdir(parents=True)
            self.sdk("create", base, home)
            core = fixture.repo / TOOL
            source = core.read_text()
            anchor = "            completed = migration(home, root)"
            self.assertEqual(source.count(anchor), 1)
            core.write_text(source.replace(anchor, '            print("held", flush=True)\n            os.read(0, 1)\n' + anchor))
            fixture.git("add", "-A")
            holder = subprocess.Popen(["python3", "-B", str(core), "migrate", "--home", str(home), "--apply"], cwd=fixture.repo, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**os.environ, "HOME": str(home.parent)})
            try:
                self.assertEqual(holder.stdout.readline().strip(), "held")
                before = {str(path.relative_to(home)): path.read_bytes() for path in home.rglob("*") if path.is_file()}
                refused = self.sdk("probe", base, home)
                self.assertEqual(refused["code"], 1, refused["output"])
                self.assertIn("Another Tron Gateway already owns a canonical session directory", refused["output"])
                after = {str(path.relative_to(home)): path.read_bytes() for path in home.rglob("*") if path.is_file()}
                diagnostics = after.pop("logs/gateway.jsonl")
                records = [json.loads(line) for line in diagnostics.splitlines()]
                self.assertEqual([row["event"] for row in records], ["gateway.fatal-startup"])
                (ROOT / "test-results/home-layout-runtime-process.json").write_text(json.dumps({"heldLease": refused, "diagnostics": records}, indent=2))
                self.assertEqual(after, before)
            finally:
                output, error = holder.communicate("release", timeout=30)
                self.assertEqual(holder.returncode, 0, output + error)
                core.write_text(source)
            journal = Path(json.loads(output)["journal"])
            serving = self.sdk_process("serve", base, home)
            try:
                ready = json.loads(serving.stdout.readline())
                self.assertTrue(ready.get("ready"), ready)
                journal_before = journal.read_bytes()
                refused = fixture.run("migrate", "--home", str(home), "--dry-run", env={"HOME": str(home.parent)})
                self.assertNotEqual(refused.returncode, 0, refused.stdout + refused.stderr)
                self.assertIn("gateway_running", json.loads(refused.stdout)["blockers"])
                self.assertEqual(journal.read_bytes(), journal_before)
            finally:
                output, error = serving.communicate("release", timeout=30)
                self.assertEqual(serving.returncode, 0, output + error)
                self.assertEqual(json.loads(output)["code"], 0, output)
            racing = self.sdk_process("race", base, home)
            try:
                ready = json.loads(racing.stdout.readline())
                self.assertTrue(ready.get("ready"), ready)
                rolled_back = fixture.run("migrate", "--home", str(home), "--rollback", env={"HOME": str(home.parent)})
                self.assertEqual(rolled_back.returncode, 0, rolled_back.stdout + rolled_back.stderr)
                before_release = {str(path.relative_to(home)): path.read_bytes() for path in home.rglob("*") if path.is_file()}
            finally:
                output, error = racing.communicate("release", timeout=30)
                self.assertEqual(racing.returncode, 0, output + error)
            refused = json.loads(output)
            self.assertEqual(refused["code"], 1, refused["output"])
            self.assertIn("home-layout migrate", refused["output"])
            after_release = {str(path.relative_to(home)): path.read_bytes() for path in home.rglob("*") if path.is_file()}
            previous_log = before_release.pop("logs/gateway.jsonl")
            current_log = after_release.pop("logs/gateway.jsonl")
            self.assertTrue(current_log.startswith(previous_log))
            self.assertEqual([json.loads(line)["event"] for line in current_log[len(previous_log):].splitlines()], ["gateway.fatal-startup"])
            (ROOT / "test-results/home-layout-runtime-process.json").write_text(json.dumps({"heldLease": "refused", "startupRace": refused}, indent=2))
            self.assertEqual(after_release, before_release)

    def release_dead_fixture_locks(self, fixture: Fixture, home: Path) -> None:
        blocked = fixture.run("migrate", "--home", str(home), "--apply", env={"HOME": str(home.parent)})
        self.assertEqual(blocked.returncode, 1, blocked.stdout + blocked.stderr)
        self.assertIn("gateway_running", json.loads(blocked.stdout)["blockers"])
        for lock in (home / "agent/.tron-gateway-runtime.lock.lock", home.parent / ".tron-dev/agent/.tron-gateway-runtime.lock.lock"):
            lock.rmdir()

    def test_crashes_resume_forward_and_inverse_without_restoring_runtime_bodies(self) -> None:
        with tempfile.TemporaryDirectory(prefix="home-layout-crash-sdk-") as temporary:
            base = Path(temporary).resolve()
            fixture = Fixture(base)
            fixture.write(REGISTRY, (ROOT / REGISTRY).read_text())
            home = base / "user/.tron"
            home.mkdir(parents=True)
            sdk = self.sdk("create", base, home)
            runtime = fixture.repo / "tools/home-layout/runtime_layout.py"
            source = runtime.read_text()
            points = {
                "reserved": "            phase[key] = saved\n            l.write_journal(journal_path, journal)",
                "cloned": "            clone(l, path, destination)",
                "rewritten": "                os.replace(temporary, path)",
                "stamped-before-receipt": "        l.write_journal(stamp, {\"version\": 2})",
            }
            for name, anchor in points.items():
                with self.subTest(point=name):
                    self.assertEqual(source.count(anchor), 1)
                    indentation = len(anchor.splitlines()[-1]) - len(anchor.splitlines()[-1].lstrip())
                    runtime.write_text(source.replace(anchor, anchor + "\n" + " " * indentation + "os._exit(91)"))
                    crashed = fixture.run("migrate", "--home", str(home), "--apply", env={"HOME": str(home.parent)})
                    self.assertEqual(crashed.returncode, 91, crashed.stdout + crashed.stderr)
                    self.release_dead_fixture_locks(fixture, home)
                    runtime.write_text(source)
                    resumed = fixture.run("migrate", "--home", str(home), "--apply", env={"HOME": str(home.parent)})
                    self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
                    self.sdk("append", base, home)
                    content = next((home / "agent/sessions").rglob(Path(sdk["session"]).name)).read_bytes().split(b"\n", 1)[1]
                    anchor = points["rewritten"]
                    runtime.write_text(source.replace(anchor, anchor + "\n                os._exit(92)"))
                    crashed = fixture.run("migrate", "--home", str(home), "--rollback", env={"HOME": str(home.parent)})
                    self.assertEqual(crashed.returncode, 92, crashed.stdout + crashed.stderr)
                    self.assertEqual(json.loads((home / "state/layout.json").read_text()), {"version": 2, "migrating": True})
                    self.release_dead_fixture_locks(fixture, home)
                    runtime.write_text(source)
                    resumed = fixture.run("migrate", "--home", str(home), "--rollback", env={"HOME": str(home.parent)})
                    self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
                    self.sdk("old", base, home)
                    self.assertEqual((home / sdk["session"]).read_bytes().split(b"\n", 1)[1], content)

    def test_observed_process_close_is_required_before_a_run_can_move(self) -> None:
        with tempfile.TemporaryDirectory(prefix="home-layout-live-sdk-") as temporary:
            base = Path(temporary).resolve()
            fixture = Fixture(base)
            fixture.write(REGISTRY, (ROOT / REGISTRY).read_text())
            home = base / "user/.tron"
            home.mkdir(parents=True)
            tmp = base / "tmp"
            tmp.mkdir()
            process = self.sdk_process("hold", base, home)
            try:
                ready = process.stdout.readline()
                self.assertTrue(ready, process.stderr.read() if not ready else "")
                manifest = json.loads(ready)
                self.assertIn("runId", manifest)
                before = snapshot(home)
                result = fixture.run("migrate", "--home", str(home), "--dry-run", env={"HOME": str(home.parent)})
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)["errors"][0]["reason"], "subagent_process_unsettled")
                self.assertEqual(snapshot(home, contents_first=False), before)
            finally:
                if process.poll() is None:
                    output, error = process.communicate("release\n", timeout=30)
                    self.assertEqual(process.returncode, 0, output + error)
            handoff = home / manifest["asyncDir"] / "handoff.json"
            self.sdk("handoff-pending", base, home)
            before = snapshot(home)
            result = fixture.run("migrate", "--home", str(home), "--dry-run", env={"HOME": str(home.parent)})
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)["errors"][0]["reason"], "subagent_handoff_unsettled")
            self.assertEqual(snapshot(home, contents_first=False), before)
            self.sdk("handoff-complete", base, home)
            completed = handoff.read_text()
            result = fixture.run("migrate", "--home", str(home), "--apply", env={"HOME": str(home.parent)})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.sdk("open", base, home)
            self.assertEqual((home / manifest["asyncDir"].replace("internal/subagents/", "state/subagents/") / "handoff.json").read_text(), completed)

    def test_non_object_settings_refuse_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="home-layout-settings-") as temporary:
            fixture = Fixture(Path(temporary).resolve())
            fixture.write(REGISTRY, (ROOT / REGISTRY).read_text())
            home = Path(temporary).resolve() / "user/.tron"
            (home / "agent").mkdir(parents=True)
            (home / "agent/settings.json").write_text("[]")
            before = snapshot(home.parent)
            result = fixture.run("migrate", "--home", str(home), "--dry-run", env={"HOME": str(home.parent)})
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)["errors"][0]["reason"], "invalid_settings_document")
            self.assertEqual(snapshot(home.parent, contents_first=False), before)

    def test_offline_runtime_move_rewrites_only_owned_fields_and_carries_new_data_back(self) -> None:
        with tempfile.TemporaryDirectory(prefix="home-layout-runtime-") as temporary:
            base = Path(temporary).resolve()
            fixture = Fixture(base)
            home = base / "user/.tron"
            home.mkdir(parents=True)
            paths = {
                "agent": entry(**{"class": "keep"}), "agent/sessions": entry(subtree=True),
                "agent/trust.json": entry(), "agent/missions": entry(subtree=True),
                "state": entry(**{"class": "keep"}, container=True), "state/layout.json": entry(),
                "state/home": entry(container=True), "state/home/workspace": entry(subtree=True),
                "state/home/tasks": entry(subtree=True), "state/uploads": entry(subtree=True),
                "state/settings": entry(container=True), "state/settings/observed.json": entry(),
                "state/subagents": entry(subtree=True), "state/mac-terminal": entry(subtree=True),
                "state/mac-terminal.lock": entry(**{"class": "scratch"}, container=True),
                "mac-terminal.lock": entry(**{"class": "scratch"}, container=True),
                "cache": entry(**{"class": "rebuild"}, container=True), "cache/network.json": entry(),
                "workspace": entry(**{"class": "keep"}, container=True), "workspace/builds": entry(container=True),
                "workspace/builds/ios-ota": entry(subtree=True),
                "internal": entry(**{"class": "scratch"}, container=True),
            }
            retired = [{"from": "gateway/network.json", "to": "cache/network.json"},
                       {"from": "gateway", "to": "state"},
                       {"from": "internal/subagents", "to": "state/subagents"},
                       {"from": "mac-terminal", "to": "state/mac-terminal"},
                       {"from": "ios-builds", "to": "workspace/builds/ios-ota"}]
            fixture.write(REGISTRY, registry(paths, retired))
            old_cwd = str(home / "gateway/home/workspace")
            new_cwd = str(home / "state/home/workspace")
            encode = lambda value: "--" + value.lstrip("/").replace("/", "-") + "--"
            sdk = self.sdk("create", base, home)
            old_session = home / sdk["session"]
            _, body = old_session.read_bytes().split(b"\n", 1)
            records = {
                "gateway/network.json": {"host": "fixture"},
                "gateway/settings/observed.json": {"version": 1, "stores": {"trust": {"digest": hashlib.sha256(json.dumps({old_cwd: True}).encode()).hexdigest(), "values": {"permissions.projectTrust\u0000" + json.dumps({"project": old_cwd}, separators=(",", ":")): {"key": "permissions.projectTrust", "qualifiers": {"project": old_cwd}, "value": True}}, "tron": {}, "outside": {}}}},
                "gateway/uploads/one/metadata.json": {"path": str(home / "gateway/uploads/one/file")},
                "gateway/uploads/two/metadata.json": {"path": new_cwd + "/preexisting-new-prefix"},
                "gateway/home/tasks/one.json": {"target": {"cwd": old_cwd}, "brief": "history quotes " + old_cwd},
                "agent/trust.json": {old_cwd: True},
                "agent/missions/one.json": {"runs": [{"asyncDir": str(home / sdk["asyncDir"])}], "notes": old_cwd},
            }
            for relative, value in records.items():
                path = home / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(value))
            for relative, data in {
                "gateway/uploads/one/file": b"upload", "gateway/home/workspace/only-copy": b"workspace",
                "mac-terminal/ssh_host_ed25519_key": b"host-key",
                "mac-terminal/sshd_config": f"HostKey {home}/mac-terminal/ssh_host_ed25519_key\n".encode(),
                "ios-builds/latest.plist": b"unchanged install URL :8443/builds/one/manifest.plist",
            }.items():
                path = home / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            original = {str(p.relative_to(home)): p.read_bytes() for p in home.rglob("*") if p.is_file()}
            host_inode = (home / "mac-terminal/ssh_host_ed25519_key").stat().st_ino
            def migrate(mode):
                result = fixture.run("migrate", "--home", str(home), mode, env={"HOME": str(home.parent)})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return json.loads(result.stdout)
            before = snapshot(home.parent)
            plan = migrate("--dry-run")
            self.assertEqual(snapshot(home.parent, contents_first=False), before)
            self.assertGreaterEqual(len(plan["rewrites"]), 8)
            applied = migrate("--apply")
            journal = json.loads(Path(applied["journal"]).read_text())
            self.assertTrue(any(row["kind"] == "session" for row in journal["layouts"][str(home)]["rewrites"].values()))
            backup = next((home.parent / ".tron-maintenance/backups").rglob(old_session.name))
            backup_bytes = backup.read_bytes()
            backup.write_bytes(backup_bytes + b"body corruption after unchanged header\n")
            tampered_before = snapshot(home)
            refused = fixture.run("migrate", "--home", str(home), "--apply", env={"HOME": str(home.parent)})
            self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
            self.assertEqual(json.loads(refused.stdout)["errors"][0]["reason"], "rewrite_backup_changed")
            tampered_after = snapshot(home, contents_first=False)
            normalize_lease_parent = lambda records: {key: value[:6] + (None, None, None) + value[9:] if key == "agent" else value for key, value in records.items()}
            self.assertEqual(normalize_lease_parent(tampered_after), normalize_lease_parent(tampered_before))
            backup.write_bytes(backup_bytes)
            session = home / "agent/sessions" / encode(new_cwd) / old_session.name
            header, preserved = session.read_bytes().split(b"\n", 1)
            self.assertEqual(json.loads(header)["cwd"], new_cwd)
            self.assertEqual(preserved, body)
            self.assertEqual(json.loads((home / "state/layout.json").read_text()), {"version": 2})
            for root in ("gateway", "mac-terminal", "ios-builds"):
                self.assertEqual((home / root).read_text(), "retired by layout 2; merge main\n")
            self.assertEqual((home / "state/mac-terminal/ssh_host_ed25519_key").stat().st_ino, host_inode)
            upload = json.loads((home / "state/uploads/one/metadata.json").read_text())
            self.assertEqual(Path(upload["path"]).read_bytes(), b"upload")
            mission = json.loads((home / "agent/missions/one.json").read_text())
            self.assertEqual(mission["runs"][0]["asyncDir"], str(home / sdk["asyncDir"].replace("internal/subagents/", "state/subagents/")))
            self.assertEqual(mission["notes"], old_cwd)
            self.assertEqual(json.loads((home / "agent/trust.json").read_text()), {new_cwd: True})
            self.sdk("append", base, home)
            appended = session.read_bytes().split(b"\n", 1)[1][len(body):]
            (home / "state/home/workspace/new-only-copy").write_text("new workspace data")
            migrate("--rollback")
            for relative, data in original.items():
                expected = data + appended if relative == str(old_session.relative_to(home)) else data
                self.assertEqual((home / relative).read_bytes(), expected, relative)
            self.sdk("old", base, home)
            self.assertEqual((home / "gateway/home/workspace/new-only-copy").read_text(), "new workspace data")
            self.assertFalse((home / "state").exists())
            self.assertEqual((home / "mac-terminal/ssh_host_ed25519_key").stat().st_ino, host_inode)


if __name__ == "__main__":
    unittest.main()
