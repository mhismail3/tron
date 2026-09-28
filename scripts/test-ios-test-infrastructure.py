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
# The runner fixture's synthetic Mac pins its own runtime/device type.
RUNNER_RUNTIME_ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
RUNNER_TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
UDID_A = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
UDID_B = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
UDID_C = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
UDID_D = "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"


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
if args[:1] == ['simctl']:
    log = os.environ.get('FAKE_SIMCTL_LOG')
    if log:
        with open(log, 'a', encoding='utf-8') as handle: handle.write(' '.join(args[1:]) + '\\n')
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
        self.simulator_inventory = self.root / "simulator-inventory.json"
        self.simulator_inventory.write_text(json.dumps({
            "runtimes": [{"identifier": RUNNER_RUNTIME_ID, "version": "26.5", "platform": "iOS", "buildversion": "23C54", "isAvailable": True}],
            "devicetypes": [{"identifier": RUNNER_TYPE_ID, "name": "iPhone 17 Pro", "isAvailable": True}],
            "devices": {RUNNER_RUNTIME_ID: []},
        }))
        self.simctl_log = self.root / "simctl.log"
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
        extra_args: list[str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update({
            "PATH": f"{self.bin}:{environment['PATH']}",
            "TRON_IOS_XCRUN": str(self.xcrun),
            "FAKE_SIMULATOR_INVENTORY": str(self.simulator_inventory),
            "FAKE_SIMCTL_LOG": str(self.simctl_log),
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
        return subprocess.run(
            [str(RUNNER), command, *(extra_args or [])],
            env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def device_entry(self, udid: str) -> dict[str, object]:
        document = json.loads(self.simulator_inventory.read_text())
        for devices in document["devices"].values():
            for device in devices:
                if device["udid"] == udid:
                    return device
        raise AssertionError(f"no such simulator in the synthetic inventory: {udid}")

    def owned_udid(self) -> str:
        return json.loads((self.state / "simulator.json").read_text())["udid"]

    def simctl_calls(self, command: str) -> list[str]:
        try:
            lines = self.simctl_log.read_text().splitlines()
        except FileNotFoundError:
            return []
        return [line for line in lines if line.split(" ", 1)[0] == command]

    def write_orphan_lane(self, udid: str, *, name: str = "Tron iOS Tests", directory: str = "orphan-lane") -> Path:
        """A booted owned simulator in another lane, with no process holding it."""
        lane = self.root / directory
        lane.mkdir(parents=True, exist_ok=True)
        (lane / "simulator.json").write_text(json.dumps({
            "schema": "tron.ios-test-simulator.v1", "owner": "tron-ios-test", "udid": udid,
            "name": name, "runtime_identifier": RUNNER_RUNTIME_ID, "runtime_version": "26.5",
            "runtime_build": "23C54", "device_type_identifier": RUNNER_TYPE_ID,
            "device_type_name": "iPhone 17 Pro", "ephemeral": False,
        }))
        document = json.loads(self.simulator_inventory.read_text())
        document["devices"][RUNNER_RUNTIME_ID].append({
            "name": name, "udid": udid, "state": "Booted", "isAvailable": True,
            "deviceTypeIdentifier": RUNNER_TYPE_ID,
        })
        self.simulator_inventory.write_text(json.dumps(document))
        return lane

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

    def test_run_releases_the_owned_simulator_when_the_command_ends(self) -> None:
        """SIM-1: a run leaves no owned simulator booted, whatever its outcome.

        Failure modes: a passing run, a run whose tests fail, and a run killed by
        its own process deadline could each leave the booted simulator behind.
        """
        owner = ["--only-testing", "TronMobileTests/StubTests"]
        outcomes = (
            ("success", {}, 0),
            ("test failure", {"xcode_status": 7}, 65),
            ("process timeout", {"mode": "timeout"}, 75),
        )
        for label, options, expected in outcomes:
            with self.subTest(outcome=label):
                result = self.invoke(extra_args=owner, **options)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(self.device_entry(self.owned_udid())["state"], "Shutdown")
        self.assertEqual(len(self.simctl_calls("shutdown")), len(outcomes))

    def test_keep_booted_is_reused_by_the_next_run_in_the_lane(self) -> None:
        """SIM-1: --keep-booted serves a test-fix loop and still releases at the end.

        Failure modes: a keep-booted lease could release the simulator it was
        asked to keep; a later run in the lane could boot a second simulator
        instead of reusing it; and a release could be skipped afterwards.
        """
        owner = ["--only-testing", "TronMobileTests/StubTests"]
        first = self.invoke(extra_args=["--keep-booted", *owner])
        self.assertEqual(first.returncode, 0, first.stderr)
        udid = self.owned_udid()
        self.assertEqual(self.device_entry(udid)["state"], "Booted")
        self.assertEqual(len(self.simctl_calls("create")), 1)

        second = self.invoke(extra_args=owner)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.owned_udid(), udid)
        self.assertEqual(len(self.simctl_calls("create")), 1)
        self.assertEqual(len(self.simctl_calls("boot")), 1)
        self.assertEqual(self.device_entry(udid)["state"], "Shutdown")

    def test_a_command_releases_other_lanes_orphans_first(self) -> None:
        """SIM-2: every simulator-using command sweeps, and only orphans.

        Failure modes: the orphan of a killed holder could survive the next
        command; a booted simulator with no ownership marker could be touched;
        and this command's own simulator must still be released at its end.
        """
        orphan = self.write_orphan_lane("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", name="Tron iOS Tests (lane b)")
        document = json.loads(self.simulator_inventory.read_text())
        document["devices"][RUNNER_RUNTIME_ID].append({
            "name": "Unowned Simulator", "udid": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            "state": "Booted", "isAvailable": True, "deviceTypeIdentifier": RUNNER_TYPE_ID,
        })
        self.simulator_inventory.write_text(json.dumps(document))

        result = self.invoke(extra_args=["--only-testing", "TronMobileTests/StubTests"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shut down Tron iOS Tests (lane b)", result.stdout)
        self.assertEqual(self.device_entry("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")["state"], "Shutdown")
        self.assertEqual(self.device_entry("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")["state"], "Booted")
        self.assertEqual(self.device_entry(self.owned_udid())["state"], "Shutdown")
        self.assertTrue(orphan.exists())


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


class OwnedLaneFixture(unittest.TestCase):
    """Synthetic xcrun/simctl for the owners that release booted simulators.

    Failure modes these fixtures make observable, written before the owners:

    1. A command that ends (success, failure, deadline or signal) leaves the
       simulator it booted running.
    2. A release that hangs or fails holds the lease, or replaces the command's
       own exit status with its own.
    3. A keep-booted lane is released anyway, or is kept without the lease
       recording the intent and what it found.
    4. A sweep releases a lane a live process holds, a lane whose marker no
       longer matches its device, a simulator with no marker, or the remembered
       Development simulator.
    5. Two sweeps racing double-release, fail, or leave one of them waiting.
    6. A command starts while its lane is being swept.
    7. A holder killed with SIGKILL leaves a stale lease that hides the orphan.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.xcrun = self.bin / "xcrun"
        self.xcrun.write_text("""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path

inventory_path = Path(os.environ['FAKE_SIMCTL_INVENTORY'])
arguments = sys.argv[1:]
assert arguments[0] == 'simctl', arguments
arguments = arguments[1:]
log = os.environ.get('FAKE_SIMCTL_LOG')
if log:
    with open(log, 'a', encoding='utf-8') as handle: handle.write(' '.join(arguments) + '\\n')
if arguments == ['list', '--json']:
    print(json.dumps(json.loads(inventory_path.read_text()))); raise SystemExit(0)
command = arguments[0] if arguments else ''
udid = arguments[1] if len(arguments) > 1 else ''
if command in ('boot', 'shutdown'):
    if command == 'shutdown':
        delay = float(os.environ.get('FAKE_SHUTDOWN_DELAY_SECONDS') or 0)
        if delay:
            started = os.environ.get('FAKE_SHUTDOWN_STARTED')
            if started: Path(started).write_text(udid + '\\n')
            time.sleep(delay)
    document = json.loads(inventory_path.read_text())
    found = [device for devices in document['devices'].values() for device in devices if device['udid'] == udid]
    if not found:
        print('no such simulator: ' + udid, file=sys.stderr); raise SystemExit(2)
    for device in found:
        device['state'] = 'Booted' if command == 'boot' else 'Shutdown'
    inventory_path.write_text(json.dumps(document)); raise SystemExit(0)
print('unexpected simctl arguments: ' + repr(arguments), file=sys.stderr)
raise SystemExit(2)
""")
        self.xcrun.chmod(0o755)
        self.inventory_path = self.root / "inventory.json"
        self.log_path = self.root / "simctl.log"
        self.development_marker = self.root / "development/ios-simulator-udid"
        self.discovery_root = self.root / "lanes"
        self.state = self.discovery_root / "ios-test"
        self.state.mkdir(parents=True)
        self.inventory_path.write_text(json.dumps({"devices": {RUNTIME_ID: []}}))
        self.environment = os.environ.copy()
        self.environment.update({
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "TRON_IOS_XCRUN": str(self.xcrun),
            "FAKE_SIMCTL_INVENTORY": str(self.inventory_path),
            "FAKE_SIMCTL_LOG": str(self.log_path),
            "TRON_IOS_TEST_STATE_DIR": str(self.state),
            "TRON_IOS_TEST_DISCOVERY_ROOT": str(self.discovery_root),
            "TRON_IOS_SIMULATOR_STATE_DIR": str(self.development_marker.parent),
            "TRON_IOS_TEST_SHUTDOWN_TIMEOUT_SECONDS": "2",
            "TRON_IOS_TEST_SWEEP_DEADLINE_SECONDS": "30",
        })
        self.holders: list[subprocess.Popen[str]] = []

    def tearDown(self) -> None:
        for holder in self.holders:
            holder.kill()
            holder.wait(timeout=5)
            self.close_pipes(holder)
        self.temporary.cleanup()

    def close_pipes(self, process: subprocess.Popen[str]) -> None:
        for pipe in (process.stdout, process.stderr):
            if pipe is not None:
                pipe.close()

    def inventory(self) -> dict[str, object]:
        return json.loads(self.inventory_path.read_text())

    def device_entry(self, udid: str) -> dict[str, object]:
        for devices in self.inventory()["devices"].values():
            for device in devices:
                if device["udid"] == udid:
                    return device
        raise AssertionError(f"no such simulator in the synthetic inventory: {udid}")

    def update_device(self, udid: str, **fields: object) -> None:
        document = self.inventory()
        for devices in document["devices"].values():
            for device in devices:
                if device["udid"] == udid:
                    device.update(fields)
        self.inventory_path.write_text(json.dumps(document))

    def owned_lane(self, name: str = "ios-test", udid: str = UDID_A, *, present: bool = True) -> Path:
        """One lane: its ownership marker, and its booted device in the inventory."""
        lane = self.discovery_root / name
        lane.mkdir(parents=True, exist_ok=True)
        (lane / "simulator.json").write_text(json.dumps({
            "schema": "tron.ios-test-simulator.v1", "owner": "tron-ios-test", "udid": udid,
            "name": "Tron iOS Tests", "runtime_identifier": RUNTIME_ID, "runtime_version": "26.2",
            "runtime_build": "23C54", "device_type_identifier": TYPE_ID,
            "device_type_name": "iPhone 17 Pro", "ephemeral": False,
        }))
        if present:
            document = self.inventory()
            for devices in document["devices"].values():
                devices[:] = [device for device in devices if device["udid"] != udid]
            document["devices"][RUNTIME_ID].append({
                "name": "Tron iOS Tests", "udid": udid, "state": "Booted", "isAvailable": True,
                "deviceTypeIdentifier": TYPE_ID,
            })
            self.inventory_path.write_text(json.dumps(document))
        return lane

    def wait_for(self, path: Path, timeout: float = 10) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if path.exists() and path.read_text().strip():
                return
            time.sleep(0.05)
        self.fail(f"timed out waiting for {path}")

    def hold_lease(self, lane: Path) -> subprocess.Popen[str]:
        """A live process holding a lane's lease, as a running command does."""
        holder = subprocess.Popen(
            [
                sys.executable, "-c",
                "import fcntl, sys, time; handle = open(sys.argv[1], 'a+');"
                " fcntl.flock(handle, fcntl.LOCK_EX); print('held', flush=True); time.sleep(60)",
                str(lane / "lease.lock"),
            ],
            text=True, stdout=subprocess.PIPE,
        )
        self.holders.append(holder)
        assert holder.stdout is not None
        self.assertEqual(holder.stdout.readline().strip(), "held")
        return holder

    def shutdown_targets(self) -> list[str]:
        try:
            lines = self.log_path.read_text().splitlines()
        except FileNotFoundError:
            return []
        return [line.split(" ", 1)[1] for line in lines if line.startswith("shutdown ")]

    def reap(self, *, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(RUNNER), "reap"], env=environment or self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )


class ReleaseFixture(OwnedLaneFixture):
    """SIM-1: the lease holder releases the lane's simulator when it ends."""

    def locker_arguments(self, *command: str, marker: Path | None = None, keep_booted: bool = False) -> list[str]:
        marker = marker if marker is not None else self.state / "simulator.json"
        arguments = [
            sys.executable, str(LOCK), "--lock", str(marker.parent / "lease.lock"),
            "--marker", str(marker), "--development-state", str(self.development_marker),
        ]
        if keep_booted:
            arguments.append("--keep-booted")
        return [*arguments, "--", *command]

    def run_locker(self, *command: str, marker: Path | None = None, keep_booted: bool = False) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.locker_arguments(*command, marker=marker, keep_booted=keep_booted),
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )

    def test_a_finished_command_releases_the_simulator_it_used(self) -> None:
        """Failure mode 1: success, failure and deadline all leave nothing booted."""
        for status in (0, 7, 75):
            with self.subTest(status=status):
                self.owned_lane("ios-test", UDID_A)
                completed = self.run_locker(sys.executable, "-c", f"raise SystemExit({status})")
                self.assertEqual(completed.returncode, status, completed.stderr)
                self.assertEqual(completed.stderr, "")
                self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")
                self.assertEqual(self.shutdown_targets(), [UDID_A])
                self.log_path.unlink()

    def test_a_signalled_holder_still_releases_the_simulator(self) -> None:
        """Failure mode 1: SIGINT, SIGTERM and SIGHUP release the simulator."""
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signum):
                lane = self.owned_lane("ios-test", UDID_A)
                holder = subprocess.Popen(
                    self.locker_arguments(sys.executable, "-c", "import time; time.sleep(30)"),
                    env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
                self.wait_for(lane / "lease.lock")
                holder.send_signal(signum)
                _, stderr = holder.communicate(timeout=30)
                self.close_pipes(holder)
                self.assertEqual(holder.returncode, 128 + signum, stderr)
                self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")

    def test_keep_booted_is_recorded_and_released_by_the_next_command(self) -> None:
        """Failure mode 3: the intent is recorded, then the next command releases."""
        lane = self.owned_lane("ios-test", UDID_A)
        self.update_device(UDID_A, state="Shutdown")
        boot_and_copy = (
            "import os, shutil, subprocess, sys;"
            " subprocess.check_call([os.environ['TRON_IOS_XCRUN'], 'simctl', 'boot', sys.argv[3]]);"
            " shutil.copyfile(sys.argv[1], sys.argv[2])"
        )
        first_metadata = self.root / "first-lease.json"
        first = self.run_locker(
            sys.executable, "-c", boot_and_copy,
            str(lane / "lease.lock"), str(first_metadata), UDID_A,
            keep_booted=True,
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        recorded = json.loads(first_metadata.read_text())["simulator"]
        self.assertEqual(recorded["keep_booted"], True)
        self.assertEqual(recorded["booted_when_leased"], False)
        self.assertEqual(recorded["marker"], str(lane / "simulator.json"))
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")

        second_metadata = self.root / "second-lease.json"
        second = self.run_locker(
            sys.executable, "-c", "import shutil, sys; shutil.copyfile(sys.argv[1], sys.argv[2])",
            str(lane / "lease.lock"), str(second_metadata),
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        reused = json.loads(second_metadata.read_text())["simulator"]
        self.assertEqual(reused["keep_booted"], False)
        self.assertEqual(reused["booted_when_leased"], True)
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")

    def test_a_hung_release_is_bounded_and_keeps_the_command_status(self) -> None:
        """Failure mode 2: a hung shutdown warns, ends bounded, keeps the status."""
        self.owned_lane("ios-test", UDID_A)
        self.environment.update({"FAKE_SHUTDOWN_DELAY_SECONDS": "30", "TRON_IOS_TEST_SHUTDOWN_TIMEOUT_SECONDS": "1"})
        started = time.monotonic()
        completed = self.run_locker(sys.executable, "-c", "raise SystemExit(65)")
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(completed.returncode, 65, completed.stderr)
        self.assertIn("could not release the iOS test simulator", completed.stderr)
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")

    def test_a_simulator_already_shut_down_is_a_quiet_success(self) -> None:
        """Failure mode 2: releasing is idempotent, so nothing is reported."""
        self.owned_lane("ios-test", UDID_A)
        self.update_device(UDID_A, state="Shutdown")
        completed = self.run_locker(sys.executable, "-c", "pass")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(self.shutdown_targets(), [])


class SweepFixture(OwnedLaneFixture):
    """SIM-2: the sweep and `scripts/tron-ios-test reap` release orphans only."""

    def test_reap_releases_only_owned_orphans(self) -> None:
        """Failure modes 4 and 5: orphans go, everything else stays, twice over."""
        self.owned_lane("lane-a", UDID_A)
        self.owned_lane("lane-b", UDID_B)
        self.update_device(UDID_B, state="Shutdown")
        self.owned_lane("lane-c", UDID_C, present=False)  # its simulator is gone
        document = self.inventory()
        document["devices"][RUNTIME_ID].append({
            "name": "Unowned Simulator", "udid": UDID_D, "state": "Booted", "isAvailable": True,
            "deviceTypeIdentifier": TYPE_ID,
        })
        self.inventory_path.write_text(json.dumps(document))

        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shut down Tron iOS Tests", result.stdout)
        self.assertEqual(self.shutdown_targets(), [UDID_A])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_B)["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_D)["state"], "Booted")

        again = self.reap()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(again.stdout, "")
        self.assertEqual(self.shutdown_targets(), [UDID_A])

    def test_reap_skips_a_lane_a_live_process_holds(self) -> None:
        """Failure mode 4: a held lane is never shut down."""
        held = self.owned_lane("lane-a", UDID_A)
        self.owned_lane("lane-b", UDID_B)
        self.hold_lease(held)
        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")
        self.assertEqual(self.device_entry(UDID_B)["state"], "Shutdown")
        self.assertEqual(self.shutdown_targets(), [UDID_B])

    def test_reap_reports_a_hung_release_and_recovers_on_the_next_run(self) -> None:
        """Failure modes 4 and 5: a stuck shutdown is bounded, reported, retried."""
        self.owned_lane("lane-a", UDID_A)
        environment = {
            **self.environment,
            "FAKE_SHUTDOWN_DELAY_SECONDS": "30",
            "TRON_IOS_TEST_SHUTDOWN_TIMEOUT_SECONDS": "1",
        }
        started = time.monotonic()
        result = self.reap(environment=environment)
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("could not release", result.stderr)
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")

        self.assertEqual(self.reap().returncode, 0)
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")

    def test_concurrent_sweeps_release_each_simulator_once(self) -> None:
        """Failure mode 5: the second sweep skips what the first holds."""
        self.owned_lane("lane-a", UDID_A)
        started = self.root / "shutdown-started"
        environment = {
            **self.environment,
            "FAKE_SHUTDOWN_DELAY_SECONDS": "2",
            "FAKE_SHUTDOWN_STARTED": str(started),
            "TRON_IOS_TEST_SHUTDOWN_TIMEOUT_SECONDS": "30",
        }
        first = subprocess.Popen(
            [str(RUNNER), "reap"], env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.wait_for(started)
        second = self.reap(environment=environment)
        _, first_stderr = first.communicate(timeout=30)
        self.close_pipes(first)
        self.assertEqual(first.returncode, 0, first_stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, "")
        self.assertEqual(self.shutdown_targets(), [UDID_A])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")

    def test_a_command_cannot_start_while_its_lane_is_swept(self) -> None:
        """Failure mode 6: the command fails busy instead of adopting the device."""
        self.owned_lane("ios-test", UDID_A)
        started = self.root / "shutdown-started"
        environment = {
            **self.environment,
            "FAKE_SHUTDOWN_DELAY_SECONDS": "3",
            "FAKE_SHUTDOWN_STARTED": str(started),
            "TRON_IOS_TEST_SHUTDOWN_TIMEOUT_SECONDS": "30",
        }
        sweep = subprocess.Popen(
            [str(RUNNER), "reap"], env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.wait_for(started)
        command = subprocess.run(
            [str(RUNNER), "run", "--only-testing", "TronMobileTests/StubTests"],
            env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )
        _, stderr = sweep.communicate(timeout=30)
        self.close_pipes(sweep)
        self.assertEqual(command.returncode, 73, command.stderr)
        self.assertIn("already leased", command.stderr)
        self.assertEqual(sweep.returncode, 0, stderr)
        self.assertEqual(self.shutdown_targets(), [UDID_A])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")

    def test_reap_skips_a_changed_identity_and_the_development_simulator(self) -> None:
        """Failure mode 4: a renamed device and the Development one are left alone."""
        self.owned_lane("lane-a", UDID_A)
        self.update_device(UDID_A, name="Renamed Simulator")
        self.owned_lane("development-lane", UDID_B)
        self.development_marker.parent.mkdir(parents=True, exist_ok=True)
        self.development_marker.write_text(UDID_B + "\n")

        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("identity does not match", result.stderr)
        self.assertIn("Development simulator", result.stderr)
        self.assertEqual(self.shutdown_targets(), [])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")
        self.assertEqual(self.device_entry(UDID_B)["state"], "Booted")

    def test_a_holder_killed_with_sigkill_leaves_the_orphan_to_the_sweep(self) -> None:
        """Failure mode 7: a stale lease must not hide the orphan."""
        holder = subprocess.Popen(
            [
                sys.executable, str(LOCK), "--lock", str(self.state / "lease.lock"),
                "--marker", str(self.state / "simulator.json"),
                "--development-state", str(self.development_marker),
                "--", sys.executable, "-c", "import time; time.sleep(3)",
            ],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.wait_for(self.state / "lease.lock")
        self.owned_lane("ios-test", UDID_A)
        holder.kill()
        holder.wait(timeout=10)
        self.close_pipes(holder)
        self.assertNotEqual((self.state / "lease.lock").read_text().strip(), "")
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")

        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.shutdown_targets(), [UDID_A])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")


if __name__ == "__main__":
    unittest.main(verbosity=2)
