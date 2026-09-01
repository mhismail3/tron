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

    def invoke(self, action: str, *, name: str = "Tron iOS Tests") -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update({"TRON_IOS_XCRUN": str(self.fake_xcrun), "FAKE_SIMCTL_INVENTORY": str(self.inventory_path)})
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

    def test_output_and_nonzero_exit_are_preserved(self) -> None:
        child = "print('complete-output', flush=True); raise SystemExit(7)"
        result = subprocess.run(self.command([sys.executable, "-c", child]), text=True, stdout=subprocess.PIPE)
        self.assertEqual(result.returncode, 7)
        self.assertIn("complete-output", result.stdout)
        self.assertIn("complete-output", (self.root / "full.log").read_text())

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

    def test_continuous_output_still_hits_overall_deadline(self) -> None:
        child = "import time\nwhile True:\n print('tick', flush=True); time.sleep(.05)"
        result = subprocess.run(self.command([sys.executable, "-c", child], overall=0.4, no_output=1), stdout=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 124)
        timeout = json.loads((self.root / "evidence/timeout.json").read_text())
        self.assertEqual(timeout["reason"], "overall")

    def test_interrupt_is_forwarded_and_returns_conventional_exit(self) -> None:
        signal_path = self.root / "signal.txt"
        child = (
            "import signal,time; from pathlib import Path; "
            f"p=Path({str(signal_path)!r}); "
            "signal.signal(signal.SIGINT, lambda *_: (p.write_text('INT'), exit(0))); print('ready', flush=True); time.sleep(30)"
        )
        process = subprocess.Popen(self.command([sys.executable, "-c", child]), stdout=subprocess.PIPE, text=True)
        assert process.stdout is not None
        self.assertEqual(process.stdout.readline().strip(), "ready")
        process.send_signal(signal.SIGINT)
        self.assertEqual(process.wait(timeout=5), 130)
        process.stdout.close()
        self.assertEqual(signal_path.read_text(), "INT")


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
