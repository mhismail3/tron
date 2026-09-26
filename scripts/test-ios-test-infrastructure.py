#!/usr/bin/env python3
"""Hardware-free fixtures for the iOS test simulator, lease, and process owner."""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SIMULATOR = ROOT / "scripts/ios-test-simulator.py"
PROCESS = ROOT / "scripts/ios-test-process.py"
LOCK = ROOT / "scripts/ios-test-lock.py"
IDENTITY = ROOT / "scripts/ios-test-build-identity.py"
RUNNER = ROOT / "scripts/tron-ios-test"
RUNTIME_ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
UDID_A = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"


class SimulatorFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.inventory_path = self.root / "inventory.json"
        self.marker = self.root / "simulator.json"
        self.development = self.root / "development-udid"
        self.fake_xcrun = self.root / "xcrun"
        self.fake_xcrun.write_text(
            """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
path = Path(os.environ['FAKE_SIMCTL_INVENTORY'])
doc = json.loads(path.read_text())
args = sys.argv[1:]
assert args[0] == 'simctl', args
args = args[1:]
if args == ['list', '--json']:
    print(json.dumps(doc)); raise SystemExit(0)
command = args[0]
if command == 'create':
    _, name, device_type, runtime = args
    existing = sum(len(values) for values in doc['devices'].values())
    udid = f'{existing + 1:08X}-0000-0000-0000-{existing + 1:012X}'
    doc['devices'].setdefault(runtime, []).append({
        'name': name, 'udid': udid, 'state': 'Shutdown',
        'isAvailable': True, 'deviceTypeIdentifier': device_type,
    })
    path.write_text(json.dumps(doc)); print(udid); raise SystemExit(0)
if command in ('boot', 'shutdown', 'delete'):
    udid = args[1]
    if command == 'shutdown' and os.environ.get('FAKE_DEVELOPMENT_ON_SHUTDOWN'):
        Path(os.environ['FAKE_DEVELOPMENT_ON_SHUTDOWN']).write_text(udid + '\\n')
    found = False
    for runtime, devices in doc['devices'].items():
        for device in list(devices):
            if device['udid'] != udid: continue
            found = True
            if command == 'boot': device['state'] = 'Booted'
            elif command == 'shutdown': device['state'] = 'Shutdown'
            else: devices.remove(device)
    if not found: print('missing device', file=sys.stderr); raise SystemExit(2)
    path.write_text(json.dumps(doc)); raise SystemExit(0)
if command == 'bootstatus':
    raise SystemExit(0)
print('unexpected simctl arguments: ' + repr(args), file=sys.stderr)
raise SystemExit(2)
"""
        )
        self.fake_xcrun.chmod(0o755)
        self.write_inventory()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_inventory(self, *, runtimes: list[dict[str, object]] | None = None, devices: dict[str, list[dict[str, object]]] | None = None) -> None:
        value = {
            "runtimes": runtimes if runtimes is not None else [{
                "identifier": RUNTIME_ID, "name": "iOS 26.2", "platform": "iOS",
                "version": "26.2", "buildversion": "23C54", "isAvailable": True,
            }],
            "devicetypes": [{"identifier": TYPE_ID, "name": "iPhone 17 Pro", "isAvailable": True}],
            "devices": devices if devices is not None else {RUNTIME_ID: []},
        }
        self.inventory_path.write_text(json.dumps(value))

    def command(self, action: str, *, name: str = "Tron iOS Tests") -> list[str]:
        return [
            sys.executable, str(SIMULATOR), action,
            "--marker", str(self.marker), "--runtime", "26.2",
            "--device-type", "iPhone 17 Pro", "--name", name,
            "--development-state", str(self.development),
        ]

    def invoke(self, action: str, *, name: str = "Tron iOS Tests", development_on_shutdown: bool = False) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update({"TRON_IOS_XCRUN": str(self.fake_xcrun), "FAKE_SIMCTL_INVENTORY": str(self.inventory_path)})
        if development_on_shutdown:
            environment["FAKE_DEVELOPMENT_ON_SHUTDOWN"] = str(self.development)
        return subprocess.run(self.command(action, name=name), env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def owned_marker(self, udid: str = UDID_A, *, runtime: str = RUNTIME_ID, name: str = "Tron iOS Tests") -> dict[str, object]:
        return {
            "schema": "tron.ios-test-simulator.v1", "owner": "tron-ios-test",
            "udid": udid, "name": name, "runtime_identifier": runtime,
            "runtime_version": "26.2", "runtime_build": "23C54",
            "device_type_identifier": TYPE_ID, "device_type_name": "iPhone 17 Pro",
            "ephemeral": False,
        }

    def device(self, udid: str, *, runtime: str = RUNTIME_ID, name: str = "Tron iOS Tests", state: str = "Shutdown") -> tuple[str, dict[str, object]]:
        return runtime, {
            "name": name, "udid": udid, "state": state, "isAvailable": True,
            "deviceTypeIdentifier": TYPE_ID,
        }

    def test_provision_and_delete_preserve_unrelated_simulators(self) -> None:
        _, unrelated = self.device(UDID_A, name="Unrelated Simulator")
        self.write_inventory(devices={RUNTIME_ID: [unrelated]})

        provision = self.invoke("provision")
        self.assertEqual(provision.returncode, 0, provision.stderr)
        owned_udid = provision.stdout.strip()
        self.assertNotEqual(owned_udid, UDID_A)
        self.assertEqual(json.loads(self.marker.read_text())["udid"], owned_udid)
        devices = json.loads(self.inventory_path.read_text())["devices"][RUNTIME_ID]
        self.assertEqual({device["udid"] for device in devices}, {UDID_A, owned_udid})
        self.assertEqual(next(device for device in devices if device["udid"] == owned_udid)["state"], "Booted")

        delete = self.invoke("delete")
        self.assertEqual(delete.returncode, 0, delete.stderr)
        self.assertFalse(self.marker.exists())
        self.assertEqual(json.loads(self.inventory_path.read_text())["devices"][RUNTIME_ID], [unrelated])

    def test_unavailable_or_unowned_destination_fails_before_mutation(self) -> None:
        with self.subTest("missing pinned runtime"):
            self.write_inventory(runtimes=[])
            result = self.invoke("provision")
            self.assertEqual(result.returncode, 66)
            self.assertIn("expected one available iOS 26.2 runtime", result.stderr)
            self.assertFalse(self.marker.exists())

        with self.subTest("unmarked name collision"):
            _, collision = self.device(UDID_A)
            self.write_inventory(devices={RUNTIME_ID: [collision]})
            result = self.invoke("provision")
            self.assertEqual(result.returncode, 66)
            self.assertIn("refusing to adopt 1 unmarked", result.stderr)
            self.assertEqual(json.loads(self.inventory_path.read_text())["devices"][RUNTIME_ID], [collision])
            self.assertFalse(self.marker.exists())

    def test_stale_marker_recovers_only_when_ownership_is_still_proven(self) -> None:
        old_runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
        with self.subTest("owned runtime drift"):
            _, stale = self.device(UDID_A, runtime=old_runtime)
            self.write_inventory(devices={old_runtime: [stale], RUNTIME_ID: []})
            self.marker.write_text(json.dumps(self.owned_marker(runtime=old_runtime)))
            result = self.invoke("provision")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(result.stdout.strip(), UDID_A)
            self.assertEqual(json.loads(self.inventory_path.read_text())["devices"][old_runtime], [])

        with self.subTest("missing owned device"):
            self.write_inventory()
            self.marker.write_text(json.dumps(self.owned_marker()))
            result = self.invoke("provision")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(result.stdout.strip(), UDID_A)

        with self.subTest("runtime drift with changed identity"):
            _, changed = self.device(UDID_A, runtime=old_runtime, name="Changed Identity")
            self.write_inventory(devices={old_runtime: [changed], RUNTIME_ID: []})
            self.marker.write_text(json.dumps(self.owned_marker(runtime=old_runtime)))
            result = self.invoke("provision")
            self.assertEqual(result.returncode, 66)
            self.assertEqual(json.loads(self.inventory_path.read_text())["devices"][old_runtime], [changed])

    def test_development_udid_is_never_accepted(self) -> None:
        _, device = self.device(UDID_A)
        self.write_inventory(devices={RUNTIME_ID: [device]})
        self.marker.write_text(json.dumps(self.owned_marker()))
        self.development.write_text(UDID_A + "\n")
        result = self.invoke("validate")
        self.assertEqual(result.returncode, 66)
        self.assertIn("Development simulator", result.stderr)

    def test_direct_delete_refuses_development_overlap_before_delete(self) -> None:
        _, device = self.device(UDID_A, state="Booted")
        self.write_inventory(devices={RUNTIME_ID: [device]})
        self.marker.write_text(json.dumps(self.owned_marker()))
        self.development.unlink(missing_ok=True)
        result = self.invoke("delete", development_on_shutdown=True)
        self.assertEqual(result.returncode, 66)
        self.assertIn("remembered Development", result.stderr)
        after = json.loads(self.inventory_path.read_text())["devices"][RUNTIME_ID]
        self.assertEqual(len(after), 1)
        self.assertEqual(after[0]["udid"], UDID_A)
        self.assertEqual(after[0]["state"], "Shutdown")
        self.assertTrue(self.marker.exists())

    def test_stale_recovery_refuses_development_overlap_before_delete(self) -> None:
        old_runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
        _, device = self.device(UDID_A, runtime=old_runtime, state="Booted")
        self.write_inventory(devices={old_runtime: [device], RUNTIME_ID: []})
        self.marker.write_text(json.dumps(self.owned_marker(runtime=old_runtime)))
        self.development.unlink(missing_ok=True)
        result = self.invoke("provision", development_on_shutdown=True)
        self.assertEqual(result.returncode, 66)
        self.assertIn("remembered Development", result.stderr)
        after = json.loads(self.inventory_path.read_text())["devices"][old_runtime]
        self.assertEqual(len(after), 1)
        self.assertEqual(after[0]["udid"], UDID_A)
        self.assertEqual(after[0]["state"], "Shutdown")
        self.assertTrue(self.marker.exists())

    def test_empty_or_unreadable_development_marker_fails_closed(self) -> None:
        _, device = self.device(UDID_A)
        self.write_inventory(devices={RUNTIME_ID: [device]})
        self.marker.write_text(json.dumps(self.owned_marker()))
        for value in ("", "not-a-udid\n", "-" * 36, UDID_A + "\nextra\n"):
            with self.subTest(value=value):
                self.development.write_text(value)
                before = self.inventory_path.read_text()
                result = self.invoke("delete")
                self.assertEqual(result.returncode, 66)
                self.assertIn("Development simulator marker", result.stderr)
                self.assertEqual(self.inventory_path.read_text(), before)
                self.assertTrue(self.marker.exists())
        self.development.unlink()
        self.development.mkdir()
        before = self.inventory_path.read_text()
        result = self.invoke("delete")
        self.assertEqual(result.returncode, 66)
        self.assertIn("unreadable", result.stderr)
        self.assertEqual(self.inventory_path.read_text(), before)
        self.assertTrue(self.marker.exists())

    def test_cleanup_requires_marker_and_current_identity_ownership(self) -> None:
        with self.subTest("changed simulator identity"):
            _, changed = self.device(UDID_A, name="Changed Identity")
            self.write_inventory(devices={RUNTIME_ID: [changed]})
            self.marker.write_text(json.dumps(self.owned_marker()))
            result = self.invoke("delete")
            self.assertEqual(result.returncode, 66)
            self.assertIn("refusing to delete", result.stderr)
            self.assertEqual(json.loads(self.inventory_path.read_text())["devices"][RUNTIME_ID], [changed])

        with self.subTest("foreign marker"):
            _, device = self.device(UDID_A)
            self.write_inventory(devices={RUNTIME_ID: [device]})
            marker = self.owned_marker()
            marker["owner"] = "foreign"
            self.marker.write_text(json.dumps(marker))
            result = self.invoke("delete")
            self.assertEqual(result.returncode, 66)
            self.assertIn("refusing unowned simulator marker", result.stderr)
            self.assertEqual(json.loads(self.inventory_path.read_text())["devices"][RUNTIME_ID], [device])


class RunnerFixture(unittest.TestCase):
    """Exercise the production runner with only synthetic xcode/simctl tools."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.xcrun = self.bin / "xcrun"
        self.xcrun.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
inventory_path = Path(os.environ['FAKE_SIMULATOR_INVENTORY'])
doc = json.loads(inventory_path.read_text()) if inventory_path.exists() else {'devices': {}}
if args[:2] == ['simctl', 'list'] and args[2:] == ['--json']:
    print(json.dumps(doc)); raise SystemExit(0)
if args[:2] == ['simctl', 'list']:
    print('== Runtimes ==\\niOS 26.5 - com.apple.CoreSimulator.SimRuntime.iOS-26-5'); raise SystemExit(0)
if args[:1] == ['simctl'] and args[1:2] == ['create']:
    _, name, device_type, runtime = args[1:]
    udid = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
    doc.setdefault('devices', {}).setdefault(runtime, []).append({'name': name, 'udid': udid, 'state': 'Shutdown', 'isAvailable': True, 'deviceTypeIdentifier': device_type})
    inventory_path.write_text(json.dumps(doc)); print(udid); raise SystemExit(0)
if args[:1] == ['simctl'] and args[1:2] in (['boot'], ['shutdown'], ['delete']):
    command, udid = args[1:3]
    for devices in doc.get('devices', {}).values():
        for device in list(devices):
            if device.get('udid') == udid:
                if command == 'delete': devices.remove(device)
                else: device['state'] = 'Booted' if command == 'boot' else 'Shutdown'
    inventory_path.write_text(json.dumps(doc)); raise SystemExit(0)
if args[:2] == ['simctl', 'bootstatus']:
    raise SystemExit(0)
if args[:2] == ['xcresulttool', 'get']:
    if os.environ.get('FAKE_SUMMARY_MODE') == 'extract-failure': raise SystemExit(9)
    if os.environ.get('FAKE_SUMMARY_MODE') == 'missing': raise SystemExit(9)
    print(os.environ.get('FAKE_SUMMARY', '{}')); raise SystemExit(0)
print('unexpected xcrun arguments', args, file=sys.stderr); raise SystemExit(2)
""")
        self.xcrun.chmod(0o755)
        self.simulator_inventory = self.root / "simulator.json"
        self.simulator_inventory.write_text(json.dumps({
            "runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5", "platform": "iOS", "buildversion": "23C54", "isAvailable": True}],
            "devicetypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro", "isAvailable": True}],
            "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": []},
        }))
        xcodebuild = self.bin / "xcodebuild"
        xcodebuild.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ \"${1:-}\" == -version ]]; then echo 'Xcode 26.6'; exit 0; fi
bundle=''
for ((i=1; i<=$#; i++)); do
  if [[ \"${!i}\" == -resultBundlePath ]]; then j=$((i + 1)); bundle=\"${!j}\"; fi
done
if [[ \" $* \" == *' test-without-building '* ]]; then
  if [[ \"${FAKE_RUNNER_MODE:-success}\" != missing-bundle && -n \"$bundle\" ]]; then mkdir -p \"$bundle\"; fi
  if [[ \"${FAKE_RUNNER_MODE:-success}\" == timeout ]]; then sleep 30; fi
  exit \"${FAKE_XCODE_STATUS:-0}\"
fi
if [[ \" $* \" == *' build-for-testing '* ]]; then
  for ((i=1; i<=$#; i++)); do
    if [[ \"${!i}\" == -derivedDataPath ]]; then j=$((i + 1)); mkdir -p \"${!j}/Build/Products\"; fi
  done
  exit 0
fi
exit 0
""")
        xcodebuild.chmod(0o755)
        xcodegen = self.bin / "xcodegen"
        xcodegen.write_text("#!/usr/bin/env bash\necho 2.45.3\n")
        xcodegen.chmod(0o755)
        presets = self.bin / "share/xcodegen/SettingPresets/Platforms"
        presets.mkdir(parents=True)
        (self.bin / "share/xcodegen/SettingPresets/base.yml").write_text("base\n")
        (presets / "iOS.yml").write_text("ios\n")
        (presets / "macOS.yml").write_text("mac\n")
        self.derived = self.root / "derived"
        self.results = self.root / "results"
        self.state = self.root / "state"
        (self.derived / "Build/Products").mkdir(parents=True)
        # Mirror what the runner's owned_directory installs before any build.
        (self.derived / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
        self.write_products_identity()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def source_identity(self, worktree: Path = ROOT) -> dict[str, object]:
        completed = subprocess.run(
            [sys.executable, str(IDENTITY), "show", "--worktree", str(worktree)],
            check=True, text=True, stdout=subprocess.PIPE,
        )
        return json.loads(completed.stdout)

    def write_products_identity(self, value: dict[str, object] | None = None) -> None:
        subprocess.run(
            [sys.executable, str(IDENTITY), "write", "--worktree", str(ROOT), "--derived-data", str(self.derived)],
            check=True, text=True, input=json.dumps(value if value is not None else self.source_identity()),
            stdout=subprocess.DEVNULL,
        )

    def invoke(
        self, *, command: str = "run", home: Path | None = None,
        summary: str = '{"passedTests":1,"failedTests":0,"skippedTests":0,"totalTestCount":1}',
        mode: str = "success", xcode_status: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update({
            "PATH": f"{self.bin}:{environment['PATH']}",
            "TRON_IOS_XCRUN": str(self.xcrun),
            "FAKE_SIMULATOR_INVENTORY": str(self.simulator_inventory),
            "TRON_IOS_SIMULATOR_STATE_DIR": str(self.root / "development-state"),
            "TRON_IOS_TEST_STATE_DIR": str(self.state),
            "TRON_IOS_TEST_DERIVED_DATA": str(self.derived),
            "TRON_IOS_TEST_RESULTS_DIR": str(self.results),
            "TRON_IOS_TEST_FOCUSED_TIMEOUT_SECONDS": "0.4",
            "TRON_IOS_TEST_FOCUSED_NO_OUTPUT_SECONDS": "1",
            "TRON_IOS_TEST_LOCK_HELD": "0",
            "FAKE_SUMMARY": summary,
            "FAKE_SUMMARY_MODE": mode,
            "FAKE_RUNNER_MODE": mode,
            "FAKE_XCODE_STATUS": str(xcode_status),
        })
        if home is not None:
            # Exercise the runner's own defaults under a synthetic HOME.
            environment.pop("TRON_IOS_TEST_DERIVED_DATA", None)
            environment.pop("TRON_IOS_TEST_RESULTS_DIR", None)
            environment["HOME"] = str(home)
        return subprocess.run([str(RUNNER), command], env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def latest_metadata(self) -> dict[str, object]:
        return json.loads(((self.results / "latest").resolve() / "metadata.json").read_text())

    def test_summary_validation_requires_real_passing_count(self) -> None:
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.invoke(summary='{"passedTests":2,"failedTests":0,"skippedTests":1,"totalTestCount":3}')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.invoke(summary='{"passedTests":0,"failedTests":0,"skippedTests":1,"totalTestCount":1}')
        self.assertEqual(result.returncode, 65, result.stderr)
        result = self.invoke(summary='{"passedTests":0,"failedTests":0,"skippedTests":0,"totalTestCount":0}')
        self.assertEqual(result.returncode, 65, result.stderr)
        result = self.invoke(summary='not-json')
        self.assertEqual(result.returncode, 65, result.stderr)

    def test_summary_extraction_failure_is_not_success(self) -> None:
        result = self.invoke(mode="extract-failure")
        self.assertEqual(result.returncode, 65, result.stderr)
        latest = (self.results / "latest").resolve()
        summary = json.loads((latest / "summary.json").read_text())
        self.assertEqual(summary["error"], "xcresult summary extraction failed")
        self.assertTrue((latest / "summary-extraction.log").exists())
        result = self.invoke(mode="missing-bundle")
        self.assertEqual(result.returncode, 65, result.stderr)
        latest = (self.results / "latest").resolve()
        self.assertEqual(json.loads((latest / "summary.json").read_text())["error"], "xcresult result bundle is missing")

    def test_process_failure_and_timeout_take_precedence(self) -> None:
        result = self.invoke(summary='{"passedTests":1,"failedTests":0,"skippedTests":0,"totalTestCount":1}', xcode_status=7)
        self.assertEqual(result.returncode, 65, result.stderr)
        result = self.invoke(mode="timeout")
        self.assertEqual(result.returncode, 75, result.stderr)

    def test_run_refuses_products_stamped_for_another_worktree(self) -> None:
        foreign = self.source_identity()
        foreign["worktree"] = "/private/tmp/tron-foreign"
        foreign["worktree_key"] = "tron-foreign-0123456789ab"
        (self.derived / "build-identity.json").write_text(json.dumps(foreign))
        result = self.invoke()
        self.assertEqual(result.returncode, 74, result.stderr)
        self.assertIn("refusing to run", result.stderr)
        self.assertIn("/private/tmp/tron-foreign", result.stderr)
        self.assertIn(str(ROOT), result.stderr)

    def test_run_refuses_products_from_a_changed_source_state(self) -> None:
        build = self.source_identity()
        build["revision"] = "0" * 40
        build["source_fingerprint"] = "0" * 64
        (self.derived / "build-identity.json").write_text(json.dumps(build))
        result = self.invoke()
        self.assertEqual(result.returncode, 74, result.stderr)
        self.assertIn("revision 000000000", result.stderr)
        self.assertIn(str(self.source_identity()["revision"])[:9], result.stderr)
        self.assertIn("source fingerprint 000000000000", result.stderr)

    def test_run_refuses_products_without_identity(self) -> None:
        (self.derived / "build-identity.json").unlink()
        result = self.invoke()
        self.assertEqual(result.returncode, 74, result.stderr)
        self.assertIn("carry no build identity", result.stderr)
        self.assertIn("before running tests", result.stderr)

    def test_build_stamps_products_and_records_source_in_metadata(self) -> None:
        (self.derived / "build-identity.json").unlink()
        result = self.invoke(command="build")
        self.assertEqual(result.returncode, 0, result.stderr)
        stamp = json.loads((self.derived / "build-identity.json").read_text())
        self.assertEqual(stamp["schema"], "tron.ios-test-build-identity.v1")
        self.assertEqual(stamp["worktree"], str(ROOT))
        self.assertEqual(stamp, self.source_identity())
        metadata = self.latest_metadata()
        self.assertEqual(metadata["source"], stamp)
        self.assertEqual(metadata["source"]["revision"], subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip())
        self.assertIsInstance(metadata["source"]["dirty"], bool)

    def test_run_records_the_source_it_verified(self) -> None:
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.latest_metadata()["source"], self.source_identity())

    def test_default_products_directory_is_scoped_to_this_worktree(self) -> None:
        home = self.root / "home"
        result = self.invoke(command="status", home=home)
        self.assertEqual(result.returncode, 0, result.stderr)
        key = subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(ROOT)],
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        expected = home / "Library/Developer/Tron/ios/test-derived-data" / key
        self.assertIn(f"Test products directory: {expected}", result.stdout)
        self.assertIn(f"Worktree: {ROOT}", result.stdout)

    def test_clean_removes_only_this_worktrees_products(self) -> None:
        sibling = self.derived.parent / "sibling-products"
        (sibling / "Build/Products").mkdir(parents=True)
        (sibling / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
        result = self.invoke(command="clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.derived.exists())
        self.assertTrue(sibling.exists())


class BuildIdentityFixture(unittest.TestCase):
    """Exercise the products identity owner against real git states."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.worktree = self.root / "worktree"
        self.worktree.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "tests@tron.invalid")
        self.git("config", "user.name", "Tron Tests")
        (self.worktree / "Source.swift").write_text("let value = 1\n")
        self.git("add", "Source.swift")
        self.git("commit", "-q", "-m", "initial")
        self.derived = self.root / "products"
        (self.derived / "Build/Products").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.worktree), *arguments],
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()

    def identity(self, worktree: Path | None = None) -> dict[str, object]:
        completed = subprocess.run(
            [sys.executable, str(IDENTITY), "show", "--worktree", str(worktree or self.worktree)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def stamp(self, value: dict[str, object]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(IDENTITY), "write", "--worktree", str(self.worktree), "--derived-data", str(self.derived)],
            text=True, input=json.dumps(value), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def verify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(IDENTITY), "verify", "--worktree", str(self.worktree), "--derived-data", str(self.derived)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_directory_key_is_stable_and_unique_per_worktree(self) -> None:
        first = subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(self.worktree)],
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        self.assertEqual(first, self.identity()["worktree_key"])
        self.assertNotIn("/", first)
        other = self.root / "worktree"  # same path, no trailing component change
        self.assertEqual(first, subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(other / ".")],
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip())
        second = subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(self.root / "another-worktree")],
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        self.assertNotEqual(first, second)

    def test_identity_tracks_tracked_and_untracked_content(self) -> None:
        clean = self.identity()
        self.assertFalse(clean["dirty"])
        self.assertEqual(clean, self.identity())
        self.assertEqual(self.stamp(clean).returncode, 0)
        self.assertEqual(self.verify().returncode, 0, self.verify().stderr)

        (self.worktree / "Source.swift").write_text("let value = 2\n")
        edited = self.identity()
        self.assertTrue(edited["dirty"])
        self.assertNotEqual(edited["source_fingerprint"], clean["source_fingerprint"])
        refused = self.verify()
        self.assertEqual(refused.returncode, 1)
        self.assertIn("refusing to run", refused.stderr)
        self.assertIn("clean", refused.stderr)
        self.assertIn("dirty", refused.stderr)

        # An untracked source file changes the products too, including its content.
        self.git("checkout", "--", "Source.swift")
        added = self.worktree / "NewTests.swift"
        added.write_text("let added = 1\n")
        with_untracked = self.identity()
        self.assertTrue(with_untracked["dirty"])
        added.write_text("let added = 2\n")
        self.assertNotEqual(self.identity()["source_fingerprint"], with_untracked["source_fingerprint"])

    def test_verify_refuses_missing_or_foreign_identity(self) -> None:
        missing = self.verify()
        self.assertEqual(missing.returncode, 1)
        self.assertIn("carry no build identity", missing.stderr)

        foreign = self.identity()
        foreign["worktree"] = "/private/tmp/tron-foreign"
        foreign["worktree_key"] = "tron-foreign-ffffffffffff"
        (self.derived / "build-identity.json").write_text(json.dumps(foreign))
        mismatched = self.verify()
        self.assertEqual(mismatched.returncode, 1)
        self.assertIn("/private/tmp/tron-foreign", mismatched.stderr)
        self.assertIn(str(self.worktree.resolve()), mismatched.stderr)

    def test_write_rejects_a_foreign_worktree_document(self) -> None:
        document = self.identity()
        document["worktree"] = "/private/tmp/elsewhere"
        result = self.stamp(document)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not this worktree", result.stderr)
        self.assertFalse((self.derived / "build-identity.json").exists())

    def test_identity_requires_the_worktree_top_level(self) -> None:
        nested = self.worktree / "packages"
        nested.mkdir()
        result = subprocess.run(
            [sys.executable, str(IDENTITY), "show", "--worktree", str(nested)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the top level of a worktree", result.stderr)


class ProcessFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, child: list[str], *, overall: float = 5, no_output: float = 2, artifact: Path | None = None) -> list[str]:
        return [
            sys.executable, str(PROCESS), "--log", str(self.root / "full.log"),
            "--evidence-dir", str(self.root / "evidence"),
            "--overall-seconds", str(overall), "--no-output-seconds", str(no_output),
            "--term-grace-seconds", "0.2", "--artifact", str(artifact or self.root / "result.xcresult"),
            "--", *child,
        ]

    def test_silence_timeout_preserves_artifact_and_kills_process_group(self) -> None:
        artifact = self.root / "partial.xcresult"
        pid_path = self.root / "descendant.pid"
        child = (
            "import signal,subprocess,sys,time; from pathlib import Path; "
            f"artifact=Path({str(artifact)!r}); artifact.mkdir(); (artifact/'partial').write_text('evidence'); "
            "descendant=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)']); "
            f"Path({str(pid_path)!r}).write_text(str(descendant.pid)); "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"
        )
        result = subprocess.run(self.command([sys.executable, "-c", child], overall=5, no_output=0.4, artifact=artifact))
        self.assertEqual(result.returncode, 124)
        timeout = json.loads((self.root / "evidence/timeout.json").read_text())
        self.assertEqual(timeout["reason"], "no-output")
        self.assertTrue(timeout["artifact_exists"])
        self.assertEqual(timeout["artifact_files"][0]["path"], "partial")
        self.assertTrue((artifact / "partial").exists())

        pid = int(pid_path.read_text())
        deadline = time.time() + 2
        while time.time() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, stdout=subprocess.PIPE).stdout.strip()
            self.assertTrue(stat.startswith("Z") or not stat, f"descendant still alive: {pid} {stat}")


class LockFixture(unittest.TestCase):
    def test_concurrent_owner_fails_and_release_allows_next_owner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "lease.lock"
            first = subprocess.Popen([
                sys.executable, str(LOCK), "--lock", str(lock), "--",
                sys.executable, "-c", "import time; time.sleep(30)",
            ])
            deadline = time.time() + 3
            while time.time() < deadline:
                if lock.exists() and lock.read_text().strip():
                    break
                time.sleep(0.02)
            self.assertTrue(lock.exists() and lock.read_text().strip())
            second = subprocess.run([
                sys.executable, str(LOCK), "--lock", str(lock), "--",
                sys.executable, "-c", "pass",
            ], stderr=subprocess.PIPE, text=True)
            self.assertEqual(second.returncode, 73)
            self.assertIn("already leased", second.stderr)
            first.send_signal(signal.SIGTERM)
            first.wait(timeout=5)
            third = subprocess.run([
                sys.executable, str(LOCK), "--lock", str(lock), "--",
                sys.executable, "-c", "pass",
            ])
            self.assertEqual(third.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
