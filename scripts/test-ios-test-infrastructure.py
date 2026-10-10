#!/usr/bin/env python3
"""Hardware-free fixtures for the iOS test simulator, lease, and process owner."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess as _subprocess
import sys
import tempfile
import threading
import time
from typing import Any
import unittest

ROOT = Path(__file__).resolve().parent.parent
SIMULATOR = ROOT / "scripts/ios-test-simulator.py"
PROCESS = ROOT / "scripts/ios-test-process.py"
LOCK = ROOT / "scripts/ios-test-lock.py"
IDENTITY = ROOT / "scripts/ios-test-build-identity.py"
RUNNER = ROOT / "scripts/tron-ios-test"
PROFILER = ROOT / "scripts/tron-profile-ios"
E2E = ROOT / "scripts/ios-gateway-e2e-test"
XCTESTRUN_FIXTURE_KEYS = [
    "TRON_E2E_CODE",
    "TRON_E2E_PI_VERSION",
    "TRON_E2E_PORT",
    "TRON_E2E_PROXY_TOKEN",
    "TRON_E2E_WORKSPACE",
]
DEVELOPMENT = ROOT / "scripts/tron-ios-simulator"
NODE_VERSION = (ROOT / ".node-version").read_text().strip()
XCODEGEN_VERSION = re.search(
    r"^TRON_CI_XCODEGEN_VERSION=(\S+)$", (ROOT / "config/ci-toolchain.env").read_text(), re.M,
).group(1)
RUNTIME_ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
# The runner fixture's synthetic Mac pins its own runtime/device type.
RUNNER_RUNTIME_ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
RUNNER_TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
UDID_A = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
UDID_B = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
UDID_C = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
UDID_D = "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
UDID_E = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
UDID_F = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
# One admission lock for the whole Mac: every lane's boot serializes on it.
ADMISSION_LOCK = ".ios-test-admission.lock"

# The owners read the Mac's memory pressure, its swap and its process table.
# These synthetic readers stand in for `memory_pressure`, `sysctl` and `ps`, so
# no fixture depends on this Mac's real memory state or on what it is running;
# a test writes one report value to steer one decision. The owners take the
# reader commands from the environment (TRON_IOS_MEMORY_PRESSURE,
# TRON_IOS_SYSCTL, TRON_IOS_PS), which is how a real Mac supplies them.
READER_SOURCES = {
    "memory_pressure": '''import os, sys
from pathlib import Path
values = Path(os.environ["FAKE_READER_VALUES"])
mode = os.environ.get("FAKE_MEMORY_MODE", "")
if mode == "unavailable":
    print("memory_pressure: not installed", file=sys.stderr)
    raise SystemExit(2)
percent = (values / "free-percent").read_text().strip() if (values / "free-percent").exists() else "90"
print("System-wide memory free percentage: " + percent + ("" if mode == "garbled" else "%"))
''',
    "sysctl": '''import os, sys
from pathlib import Path
values = Path(os.environ["FAKE_READER_VALUES"])
mode = os.environ.get("FAKE_SYSCTL_MODE", "")
key = sys.argv[-1]
if mode == "unavailable-swap" and key == "vm.swapusage":
    print("sysctl: vm.swapusage unavailable", file=sys.stderr)
    raise SystemExit(2)
if key == "hw.memsize":
    print((values / "physical-bytes").read_text().strip() if (values / "physical-bytes").exists() else "38654705664")
elif key == "vm.swapusage":
    used = (values / "swap-used-mb").read_text().strip() if (values / "swap-used-mb").exists() else "0"
    print("total = 16384.00M  used = " + used + "M  free = 0.00M  (encrypted)")
else:
    print("unexpected sysctl key: " + key, file=sys.stderr)
    raise SystemExit(2)
''',
    "ps": '''import os, sys
from pathlib import Path
if os.environ.get("FAKE_PS_MODE") == "unavailable":
    print("ps: not installed", file=sys.stderr)
    raise SystemExit(2)
values = Path(os.environ["FAKE_READER_VALUES"])
table = values / "process-table"
if table.exists():
    sys.stdout.write(table.read_text())
''',
}


def device_process(udid: str, elapsed: str = "00:05") -> str:
    """One ps line for a booted device's own init process."""
    return (
        f"65790 {elapsed} launchd_sim /Users/someone/Library/Developer/CoreSimulator/Devices/{udid}"
        "/data/var/run/launchd_bootstrap.plist\n"
    )


# Every Tron root a tool derives from the environment, plus HOME: one spelling of
# what the containment guard covers.
CONTAINMENT_VARIABLES = (
    "HOME",
    "TRON_IOS_TEST_STATE_DIR",
    "TRON_IOS_TEST_DISCOVERY_ROOT",
    "TRON_IOS_TEST_RESULTS_DIR",
    "TRON_IOS_TEST_DERIVED_DATA",
    "TRON_IOS_SIMULATOR_STATE_DIR",
    "TRON_IOS_SIMULATOR_DERIVED_DATA",
    "TRON_PROFILE_RESULTS_DIR",
    "TRON_PROFILE_IOS_DERIVED_DATA",
    "TRON_IOS_E2E_STATE_DIR",
    "TRON_IOS_E2E_DERIVED_DATA",
    # The Gateway E2E harness derives its default fixture and DerivedData from it.
    "TMPDIR",
)
_VARIABLE_LIST = ",\n        ".join(f'"{name}"' for name in CONTAINMENT_VARIABLES)
# Prepended to every synthetic tool, so even a script that a fixture launched by
# hand cannot quietly reach this Mac's state.
CONTAINMENT_GUARD = f'''import os, sys


def _containment_violations():
    root = os.environ.get("FAKE_CONTAINMENT_ROOT")
    if not root:
        return []
    root = os.path.realpath(root)
    escaped = []
    for name in (
        {_VARIABLE_LIST},
    ):
        value = os.environ.get(name)
        if not value:
            continue
        resolved = os.path.realpath(value)
        if resolved != root and not resolved.startswith(root + os.sep):
            escaped.append(name + "=" + value)
    return escaped


_escaped_roots = _containment_violations()
if _escaped_roots:
    _log = os.environ.get("FAKE_CONTAINMENT_LOG")
    if _log:
        with open(_log, "a", encoding="utf-8") as _handle:
            _handle.write("\\n".join(_escaped_roots) + "\\n")
    print(
        "refusing to serve a script whose environment escapes the test fixture: " + ", ".join(_escaped_roots),
        file=sys.stderr,
    )
    raise SystemExit(3)
'''

# Gates belong to the fixture process, not to the lease holder: the stale-lease
# regression deliberately kills only that holder while its test remains live.
# Teardown cannot help after SIGKILL, so fake tools retire themselves on owner
# death or directory removal, failing rather than continuing an install.
FIXTURE_GATE_SOURCE = '''import time
from pathlib import Path


def wait_for_fixture_gate(path):
    owner = int(os.environ["FAKE_FIXTURE_OWNER_PID"])
    while True:
        try:
            os.kill(owner, 0)
        except ProcessLookupError:
            raise SystemExit("fixture owner exited while the fake tool was gated")
        if not path.parent.is_dir():
            raise SystemExit("fixture gate directory disappeared")
        if path.exists():
            return
        time.sleep(0.05)
'''

# The proof `ContainedFixture.contained_environment` writes into every
# environment a fixture builds; a launcher that starts a process without it is
# running a tool against this Mac's own state.
CONTAINMENT_PROOF = "FAKE_CONTAINMENT_ROOT"


def containment_violation(environment: dict[str, str]) -> str | None:
    """Why `environment` is unsafe to hand to a process, or None when it is contained.

    HOME and every Tron root the environment names must resolve inside the
    fixture's own temporary directory. The synthetic tools refuse such an
    environment themselves, but they are not always started: `prune` and a
    sweep over marker-less state delete in Python, so the check has to sit where
    the process is created.
    """
    proof = environment.get(CONTAINMENT_PROOF)
    if not proof:
        return f"{CONTAINMENT_PROOF} is missing, so the environment is not a fixture's"
    root = os.path.realpath(proof)
    for name in CONTAINMENT_VARIABLES:
        value = environment.get(name)
        if not value:
            continue
        resolved = os.path.realpath(value)
        if resolved != root and not resolved.startswith(root + os.sep):
            return f"{name}={value}"
    return None


class ContainedSubprocess:
    """The one launcher: every process this module starts passes through here.

    Failure modes this launcher closes, written before the code: a fixture (or a
    caller added later) runs a Tron tool with HOME or a Tron state, lane,
    discovery, results or products root outside its own temporary directory, so
    a sweep, `clean` or `prune` reclaims this Mac's own state - the leak the
    SIM-5 commit had, where the sweep-level fixtures inherited the real HOME and
    their `reap` pruned the real results root. The guard used to live only
    inside the synthetic tools, which a disk-only `prune` never starts.

    `subprocess` at module level is this object, not the standard module, so a
    call site cannot reach `run`, `Popen` or `check_output` unguarded.
    """

    def run(self, command: list[str], **keywords: Any) -> Any:
        return self._launch("run", command, keywords)

    def Popen(self, command: list[str], **keywords: Any) -> Any:
        return self._launch("Popen", command, keywords)

    def check_output(self, command: list[str], **keywords: Any) -> Any:
        return self._launch("check_output", command, keywords)

    def _launch(self, name: str, command: list[str], keywords: dict[str, Any]) -> Any:
        environment = keywords.get("env")
        if environment is None:
            raise AssertionError(
                f"every process this module starts needs a contained environment; "
                f"{command[0] if command else command!r} was started without one"
            )
        violation = containment_violation(environment)
        if violation is not None:
            raise AssertionError(
                f"refusing to start {command[0] if command else command!r} with an environment outside "
                f"the test fixture: {violation}"
            )
        return getattr(_subprocess, name)(command, **keywords)

    def __getattr__(self, name: str) -> Any:
        """Everything else (`PIPE`, `CompletedProcess`, ...) is the standard module."""
        return getattr(_subprocess, name)


subprocess = ContainedSubprocess()


class ContainedFixture:
    """The base every fixture here inherits: no script can reach the real Mac.

    Failure mode the guard closes, written before the code: a fixture that runs a
    Tron tool without replacing HOME or the Tron roots, so the tool derives the
    real `~/.tron/internal` lane root or `~/Library/Developer/Tron/ios` results
    and products roots, and a sweep, `clean` or `prune` then reclaims this Mac's
    own state. That happened at the SIM-5 commit, where the sweep-level fixtures
    inherited the real HOME and their `reap` pruned the real results root; the
    negative control below is `ContainmentFixture`.

    So every fixture builds each script-under-test environment through
    `contained_environment` (or `run_script`): HOME and every Tron state, lane,
    discovery, results and products root point inside the fixture's own temporary
    directory, and the runner's per-worktree products path follows that HOME. The
    synthetic tool then refuses (exit 3, recorded in the fixture) to serve a
    script whose environment still names a root outside the fixture, so a fixture
    that forgets is an immediate failure rather than a real mutation.
    """

    contained_root: Path

    def containment_log(self, root: Path) -> Path:
        """Where the synthetic tools record an environment that escaped."""
        return root / "containment-violations"

    def contained_environment(self, root: Path) -> dict[str, str]:
        """This process's environment with every Tron root inside `root`.

        The proof this writes (`FAKE_CONTAINMENT_ROOT`) is what the module's one
        launcher requires: an environment that reaches a process without it is
        refused before it starts, and the synthetic tools refuse one that
        escapes the proof.

        TRON_IOS_TEST_DERIVED_DATA and TRON_IOS_TEST_DISCOVERY_ROOT are
        deliberately left unset: the tools derive that products path and the
        lane root from HOME and from the state directory, both of which are
        contained here, so a fixture that needs its own value sets the variable
        (and the synthetic tools still refuse a value that escapes).
        TRON_IOS_TEST_LANE and TRON_IOS_TEST_DEVICE_NAME are removed too: a
        lane a developer exported would select another lane than the one a
        case sets up, or conflict with its TRON_IOS_TEST_STATE_DIR.
        """
        self.contained_root = root
        home = root / "home"
        temporary = root / "tmp"
        temporary.mkdir(exist_ok=True)
        environment = os.environ.copy()
        environment.update({
            "HOME": str(home),
            "TRON_IOS_TEST_STATE_DIR": str(home / ".tron/internal/ios-test"),
            "TRON_IOS_TEST_RESULTS_DIR": str(home / "Library/Developer/Tron/ios/test-runs"),
            "TRON_IOS_SIMULATOR_STATE_DIR": str(home / ".tron/internal/run"),
            "TRON_IOS_SIMULATOR_DERIVED_DATA": str(home / "Library/Developer/Tron/ios/simulator-derived-data"),
            "TRON_PROFILE_RESULTS_DIR": str(home / "Library/Developer/Tron/profiles"),
            "TRON_PROFILE_IOS_DERIVED_DATA": str(home / "Library/Developer/Tron/ios/profile-derived-data"),
            "TRON_IOS_E2E_STATE_DIR": str(root / "e2e-state"),
            "TRON_IOS_E2E_DERIVED_DATA": str(root / "e2e-derived"),
            "TMPDIR": str(temporary),
            "FAKE_CONTAINMENT_ROOT": str(root),
            "FAKE_FIXTURE_OWNER_PID": str(os.getpid()),
            "FAKE_CONTAINMENT_LOG": str(self.containment_log(root)),
        })
        environment.pop("TRON_IOS_TEST_DERIVED_DATA", None)
        environment.pop("TRON_IOS_TEST_DISCOVERY_ROOT", None)
        environment.pop("TRON_IOS_TEST_LANE", None)
        environment.pop("TRON_IOS_TEST_DEVICE_NAME", None)
        return environment

    def run_script(self, command: list[str], root: Path, **kwargs: object) -> subprocess.CompletedProcess[str]:
        """Run one script under test with every Tron root inside `root`.

        A convenience over the module's launcher, which checks the environment
        either way.
        """
        return subprocess.run(command, env=self.contained_environment(root), **kwargs)  # type: ignore[arg-type]

    def synthetic_stub(self, path: Path, body: str) -> None:
        """Write one synthetic tool: shebang, containment guard, then its body."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/usr/bin/env python3\n" + CONTAINMENT_GUARD + body)
        path.chmod(0o755)

    def install_synthetic_xcodegen(self, root: Path) -> dict[str, str]:
        """A pinned-tool cache in the layout `scripts/install-ci-tools.sh` makes.

        Failure modes this closes (#113):

        1. The synthetic XcodeGen's setting presets sit where the toolchain
           verifier does not look (it reads `<cache>/bin/../share/xcodegen`), so
           every build-path case fails on a host with no XcodeGen of its own -
           the Linux CI runner.
        2. The fixture does not name its cache, so the project generator runs
           the host's real XcodeGen (the checkout's `.ci-tools` or Homebrew)
           and writes the checkout's real Xcode project.
        3. A runner resolves the host's XcodeGen ahead of the named cache for its
           own toolchain check, so on a developer Mac that check passes against
           the real tool and hides failure mode 1.
        4. A fixture whose command builds provides no XcodeGen at all, so it
           passes only where the host has one.

        Returns the environment that names this cache to the runners; every call
        the synthetic tool serves is recorded for `xcodegen_calls`.
        """
        cache = root / "ci-tools"
        self.synthetic_stub(cache / "bin/xcodegen", f"""from pathlib import Path
with open(Path(__file__).resolve().parents[1] / 'calls', 'a', encoding='utf-8') as handle:
    handle.write(' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['--version']:
    print('Version: {XCODEGEN_VERSION}')
""")
        presets = cache / "share/xcodegen/SettingPresets"
        (presets / "Platforms").mkdir(parents=True)
        for name in ("base.yml", "Platforms/iOS.yml", "Platforms/macOS.yml"):
            (presets / name).write_text("synthetic\n")
        return {"TRON_CI_TOOLS_DIR": str(cache)}

    def xcodegen_calls(self, root: Path) -> list[str]:
        """The arguments of every call the fixture's synthetic XcodeGen served."""
        try:
            return (root / "ci-tools/calls").read_text().splitlines()
        except FileNotFoundError:
            return []

    def close_pipes(self, process: subprocess.Popen[str]) -> None:
        """Close a killed helper's pipes so the fixture can be cleaned up."""
        for pipe in (process.stdout, process.stderr):
            if pipe is not None:
                pipe.close()

    def assert_no_containment_violations(self) -> None:
        """Fail the test if a script under test ran outside this fixture."""
        root = getattr(self, "contained_root", None)
        if root is None:
            return
        log = self.containment_log(root)
        if log.exists():
            self.fail("a script under test ran with state outside the fixture:\n" + log.read_text())


class SyntheticReaders(ContainedFixture):
    """Install the injectable readers every owner reads, per fixture."""

    readers: Path
    reader_values: Path

    def install_readers(self, root: Path) -> None:
        self.readers = root / "readers"
        self.readers.mkdir()
        self.reader_values = root / "reader-values"
        self.reader_values.mkdir()
        for name, source in READER_SOURCES.items():
            path = self.readers / name
            path.write_text("#!/usr/bin/env python3\n" + source)
            path.chmod(0o755)

    def reader_environment(self) -> dict[str, str]:
        return {
            "TRON_IOS_MEMORY_PRESSURE": str(self.readers / "memory_pressure"),
            "TRON_IOS_SYSCTL": str(self.readers / "sysctl"),
            "TRON_IOS_PS": str(self.readers / "ps"),
            "FAKE_READER_VALUES": str(self.reader_values),
        }

    def reader_value(self, name: str, value: str) -> None:
        """One report value for the next invocation through these readers."""
        (self.reader_values / name).write_text(value)


class SimulatorHarness(SyntheticReaders):
    """A synthetic simctl Mac, shared by the simulator-level fixtures."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.inventory_path = self.root / "inventory.json"
        self.marker = self.root / "simulator.json"
        self.development = self.root / "development-udid"
        self.fake_xcrun = self.root / "xcrun"
        self.install_readers(self.root)
        self.synthetic_stub(
            self.fake_xcrun, """import json, os, sys, time
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
    if command == 'boot':
        # A boot takes the Mac's memory: a case can make the reader report the
        # memory the boot consumed, which is what admission must see next.
        delay = float(os.environ.get('FAKE_BOOT_DELAY_SECONDS') or 0)
        if delay:
            time.sleep(delay)
        consumed = os.environ.get('FAKE_FREE_PERCENT_AFTER_BOOT')
        if consumed:
            (Path(os.environ['FAKE_READER_VALUES']) / 'free-percent').write_text(consumed + '\\n')
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
""",
        )
        self.write_inventory()

    def tearDown(self) -> None:
        try:
            self.assert_no_containment_violations()
        finally:
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
        return self.lane_command(action, self.marker, name=name)

    def lane_command(self, action: str, marker: Path, *, name: str = "Tron iOS Tests") -> list[str]:
        """One simulator command for one lane of this fixture, sharing the lane root."""
        return [
            sys.executable, str(SIMULATOR), action,
            "--marker", str(marker), "--runtime", "26.2",
            "--device-type", "iPhone 17 Pro", "--name", name,
            "--development-state", str(self.development),
            # The lane root stays inside the fixture, so a lane view can name the
            # default lane without ever walking a real lane directory.
            "--discovery-root", str(self.root), "--default-state-dir", str(self.root),
        ]

    def invoke(
        self, action: str, *, name: str = "Tron iOS Tests", development_on_shutdown: bool = False,
        override: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = self.contained_environment(self.root)
        environment.update({"TRON_IOS_XCRUN": str(self.fake_xcrun), "FAKE_SIMCTL_INVENTORY": str(self.inventory_path)})
        environment.update(self.reader_environment())
        if override is not None:
            environment.update(override)
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

class SimulatorFixture(SimulatorHarness, unittest.TestCase):
    """Exercise the simulator owner directly against a synthetic simctl."""

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


class AdmissionFixture(SimulatorHarness, unittest.TestCase):
    """SIM-4 memory admission, read before `simctl boot` only.

    Failure modes these cases target, written before the code:

    1. A boot proceeds while free memory is already below the reserve, so the
       boot's own footprint pushes the Mac deeper into swap.
    2. Swap in use refuses boots persistently: swap drains slowly, so a reading
       at the limit must be reported in the table, never a refusal (review P2-4).
    3. A refusal does not say what is booted, by which lane and worktree, and for
       how long, so an agent cannot tell what to release.
    4. An unavailable reader (missing, failing or unparsable) fails the boot
       instead of warning and admitting it, so a Mac or CI without these reports
       cannot run tests.
    5. The check runs for a lane whose simulator is already booted, where nothing
       is booted and a keep-booted loop must not be refused.
    6. The reserve breached by processes that are not Tron test simulators is
       reported as if the test tooling held the Mac's memory.
    7. Two starts read the Mac's memory before either has booted, so each admits
       a boot the other has not paid for yet (review P2-4).
    8. A boot that waits for the machine-wide admission lock waits forever, so a
       wedged boot blocks every other lane instead of being refused (review P2-4).
    """

    def device_states(self) -> dict[str, str]:
        document = json.loads(self.inventory_path.read_text())
        return {
            device["udid"]: device["state"]
            for devices in document["devices"].values()
            for device in devices
        }

    def test_a_boot_is_refused_when_free_memory_is_below_the_reserve(self) -> None:
        """Failure modes 1 and 6: the reserve refuses and says whose memory it is."""
        self.reader_value("free-percent", "5")
        result = self.invoke("provision")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("refusing to boot Tron iOS Tests", result.stderr)
        self.assertIn("free memory 1.8 GB of 36.0 GB is below the 8.0 GB reserve", result.stderr)
        # No owned lane is booted, so the shortage is not the test tooling's.
        self.assertIn("no owned lane is booted, so processes other than the iOS test tooling hold", result.stderr)
        self.assertEqual(set(self.device_states().values()), {"Shutdown"})

    def test_swap_in_use_is_reported_and_never_refuses_a_boot(self) -> None:
        """Failure mode 2: swap drains slowly, so a reading at the limit is
        information in the refusal table, not a refusal."""
        self.reader_value("swap-used-mb", "5000")
        self.reader_value("free-percent", "90")
        result = self.invoke("provision")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.device_states()[result.stdout.strip()], "Booted")
        self.assertNotIn("refusing", result.stderr)

        # The same reading is reported beside a refusal for free memory, in the
        # table every refused admission and `status --all` print.
        self.marker.unlink(missing_ok=True)
        self.write_inventory(devices={RUNTIME_ID: []})
        self.reader_value("free-percent", "5")
        refused = self.invoke("provision")
        self.assertEqual(refused.returncode, 73, refused.stderr)
        self.assertIn("swap in use 4.9 GB", refused.stderr)
        self.assertIn("free memory 1.8 GB", refused.stderr)
        self.assertEqual(set(self.device_states().values()), {"Shutdown"})

    def test_concurrent_boots_serialize_on_one_machine_wide_admission_lock(self) -> None:
        """Failure mode 7: two starts must not each read the memory the other has
        not consumed yet.

        The synthetic boot takes a moment and then reports the memory it
        consumed, so a start that reads before it must admit a boot the Mac can
        no longer afford - which is exactly what the admission lock prevents.
        """
        lanes = []
        devices = []
        for name, udid in (("one", UDID_A), ("two", UDID_B)):
            lane = self.root / f"ios-test-{name}"
            lane.mkdir(parents=True, exist_ok=True)
            marker = lane / "simulator.json"
            marker.write_text(json.dumps(self.owned_marker(udid, name=f"Tron iOS Tests ({name})")))
            _, device = self.device(udid, name=f"Tron iOS Tests ({name})")
            devices.append(device)
            lanes.append((marker, name))
        self.write_inventory(devices={RUNTIME_ID: devices})
        self.reader_value("free-percent", "90")
        environment = {
            **self.contained_environment(self.root),
            **self.reader_environment(),
            "TRON_IOS_XCRUN": str(self.fake_xcrun),
            "FAKE_SIMCTL_INVENTORY": str(self.inventory_path),
            "FAKE_BOOT_DELAY_SECONDS": "2",
            "FAKE_FREE_PERCENT_AFTER_BOOT": "5",
        }

        boots = [
            subprocess.Popen(self.lane_command("provision", marker, name=name),
                             env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for marker, name in lanes
        ]
        results = []
        for boot in boots:
            stdout, stderr = boot.communicate(timeout=60)
            self.close_pipes(boot)
            results.append((boot.returncode, stdout, stderr))

        statuses = sorted(status for status, _, _ in results)
        self.assertEqual(statuses, [0, 73], results)
        refused = [stderr for status, _, stderr in results if status == 73][0]
        self.assertIn("free memory", refused)
        self.assertIn("reserve", refused)
        # The boot that won the admission lock is booted, and the one that read
        # the memory it consumed booted nothing.
        self.assertEqual(sorted(self.device_states().values()), ["Booted", "Shutdown"], self.inventory_path.read_text())

    def test_a_boot_that_cannot_take_the_admission_lock_is_refused(self) -> None:
        """Failure mode 8: waiting for the machine-wide admission lock is bounded,
        and a held lock is refused with the shared 73 rather than hung on."""
        self.reader_value("free-percent", "90")
        lock = self.root / ADMISSION_LOCK
        holder = subprocess.Popen(
            [
                sys.executable, "-c",
                "import fcntl, sys, time; handle = open(sys.argv[1], 'a+');"
                " fcntl.flock(handle, fcntl.LOCK_EX); print('held', flush=True); time.sleep(60)",
                str(lock),
            ],
            env=self.contained_environment(self.root), text=True, stdout=subprocess.PIPE,
        )
        try:
            assert holder.stdout is not None
            self.assertEqual(holder.stdout.readline().strip(), "held")
            result = self.invoke("provision", override={"TRON_IOS_TEST_ADMISSION_WAIT_SECONDS": "1"})
        finally:
            holder.kill()
            holder.wait(timeout=10)
            holder.stdout.close()
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("admission", result.stderr)
        self.assertEqual(set(self.device_states().values()), {"Shutdown"})

    def test_the_refusal_names_the_booted_lane_its_worktree_and_uptime(self) -> None:
        """Failure mode 3: the refusal carries the table a caller can act on."""
        self.reader_value("free-percent", "5")
        self.reader_value("process-table", device_process(UDID_A, "01-16:05:07"))
        lane = self.root / "ios-test-probe"
        lane.mkdir()
        marker = self.owned_marker(UDID_A, name="Tron iOS Tests (probe)")
        marker["worktree"] = "/private/tmp/tron-probe-worktree"
        (lane / "simulator.json").write_text(json.dumps(marker))
        _, probe = self.device(UDID_A, name="Tron iOS Tests (probe)", state="Booted")
        self.write_inventory(devices={RUNTIME_ID: [probe]})

        result = self.invoke("provision")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("SIMULATOR", result.stderr)
        self.assertIn("lane probe", result.stderr)
        self.assertIn("/private/tmp/tron-probe-worktree", result.stderr)
        self.assertIn("1d 16h", result.stderr)
        self.assertNotIn("no owned lane is booted", result.stderr)
        self.assertEqual(self.device_states()[UDID_A], "Booted")

    def test_an_unavailable_reader_admits_the_boot_with_a_warning(self) -> None:
        """Failure mode 4: a missing, failing or unparsable reader never blocks."""
        cases = (
            ("missing memory pressure", {"FAKE_MEMORY_MODE": "unavailable"}, "1", "cannot read the Mac's free memory"),
            ("unparsable memory pressure", {"FAKE_MEMORY_MODE": "garbled"}, "1", "cannot read the Mac's free memory"),
            ("failing swap reader", {"FAKE_SYSCTL_MODE": "unavailable-swap"}, "90", "cannot read the Mac's swap in use"),
        )
        for label, environment, percent, expected in cases:
            with self.subTest(reader=label):
                self.marker.unlink(missing_ok=True)
                self.write_inventory(devices={RUNTIME_ID: []})
                self.reader_value("free-percent", percent)
                result = self.invoke("provision", override=environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stderr)
                self.assertNotIn("refusing", result.stderr)
                self.assertEqual(self.device_states()[result.stdout.strip()], "Booted")

    def test_an_already_booted_lane_is_reused_without_admission(self) -> None:
        """Failure mode 5: nothing is booted for a booted lane, so nothing is refused."""
        self.reader_value("free-percent", "1")
        self.marker.write_text(json.dumps(self.owned_marker()))
        _, booted = self.device(UDID_A, state="Booted")
        self.write_inventory(devices={RUNTIME_ID: [booted]})

        result = self.invoke("provision")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), UDID_A)
        self.assertEqual(self.device_states()[UDID_A], "Booted")
        self.assertNotIn("refusing", result.stderr)
        self.assertNotIn("warning", result.stderr)


class RunnerFixture(SyntheticReaders, unittest.TestCase):
    """Exercise the production runner with only synthetic xcode/simctl tools."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.install_readers(self.root)
        self.checkout = self.create_fixture_checkout()
        self.xcrun = self.bin / "xcrun"
        self.synthetic_stub(self.xcrun, """import json, os, sys
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
  if [[ -n \"${FAKE_XCODE_ENV_LOG:-}\" ]]; then
    printf '%s\\n' \\
      \"TRON_SOURCE_REVISION=${TEST_RUNNER_TRON_SOURCE_REVISION:-}\" \\
      \"TRON_SOURCE_DIRTY=${TEST_RUNNER_TRON_SOURCE_DIRTY:-}\" > \"$FAKE_XCODE_ENV_LOG\"
  fi
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
        cp = self.bin / "cp"
        cp.write_text("""#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
if args[:1] == ['-cR']:
    args = args[1:]
source, destination = map(Path, args[-2:])
clone = destination / source.name
if os.environ.get('FAKE_CP_FAIL'):
    clone.mkdir(parents=True, exist_ok=True)
    (clone / 'partial').write_text('partial clone')
    raise SystemExit(1)
shutil.copytree(source, clone)
""")
        cp.chmod(0o755)
        self.tools_environment = self.install_synthetic_xcodegen(self.root)
        self.derived = self.root / "derived"
        self.results = self.root / "results"
        self.state = self.root / "state"
        (self.derived / "Build/Products").mkdir(parents=True)
        # Mirror what the runner's owned_directory installs before any build.
        (self.derived / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
        self.write_products_identity()

    def tearDown(self) -> None:
        try:
            self.assert_no_containment_violations()
        finally:
            self.temporary.cleanup()

    def create_fixture_checkout(self) -> Path:
        """A git repository holding copies of the runner's tool sources, and nothing else.

        The runner stamps and verifies the identity of the checkout it runs from. The
        real checkout's identity depends on what its developer left untracked or
        ignored, and under this fixture's isolated HOME the developer's global
        ignores no longer apply, so a fixture that reads the real checkout depends on
        the machine it runs on. The fixture runs the tools from its own repository.
        """
        # Resolved: the identity owner records the real path, which macOS spells under /private.
        checkout = self.root.resolve() / "checkout"
        ignore = shutil.ignore_patterns("__pycache__")
        shutil.copytree(ROOT / "scripts", checkout / "scripts", ignore=ignore)
        shutil.copytree(ROOT / "config", checkout / "config", ignore=ignore)
        shutil.copy2(ROOT / ".node-version", checkout / ".node-version")
        shutil.copytree(ROOT / ".github/workflows", checkout / ".github/workflows", ignore=ignore)
        # The project generator runs in this directory; a file keeps it in the commit (Git
        # does not track empty directories).
        (checkout / "packages/ios-app").mkdir(parents=True)
        (checkout / "packages/ios-app/project.yml").write_text("name: TronMobile\n")
        environment = self.contained_environment(self.root)
        for arguments in (
            ("init", "-q"),
            ("config", "user.email", "tests@tron.invalid"),
            ("config", "user.name", "Tron Tests"),
            ("add", "--all"),
            ("commit", "-q", "-m", "fixture checkout"),
        ):
            subprocess.run(["git", "-C", str(checkout), *arguments], env=environment, check=True,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return checkout

    def source_identity(self, worktree: Path | None = None) -> dict[str, object]:
        completed = subprocess.run(
            [sys.executable, str(IDENTITY), "show", "--worktree", str(worktree or self.checkout)],
            env=self.contained_environment(self.root),
            check=True, text=True, stdout=subprocess.PIPE,
        )
        return json.loads(completed.stdout)

    def write_products_identity(self, value: dict[str, object] | None = None) -> None:
        subprocess.run(
            [sys.executable, str(IDENTITY), "write", "--worktree", str(self.checkout), "--derived-data", str(self.derived)],
            env=self.contained_environment(self.root),
            check=True, text=True, input=json.dumps(value if value is not None else self.source_identity()),
            stdout=subprocess.DEVNULL,
        )

    def invoke(
        self, *, command: str = "run", home: Path | None = None,
        summary: str = '{"passedTests":1,"failedTests":0,"skippedTests":0,"totalTestCount":1}',
        mode: str = "success", xcode_status: int = 0,
        extra_args: list[str] | None = None,
        lane: str | None = None, discovery_root: Path | None = None,
        override: dict[str, str] | None = None,
        runner_root: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = self.contained_environment(self.root)
        environment.update(self.reader_environment())
        environment.update({
            "PATH": f"{self.bin}:{environment['PATH']}",
            **self.tools_environment,
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
        if lane is not None:
            # A named lane replaces the pre-lane state-directory override and
            # lives under the lane root, never the real default lane.
            environment.pop("TRON_IOS_TEST_STATE_DIR", None)
            environment["TRON_IOS_TEST_LANE"] = lane
            environment.setdefault("TRON_IOS_TEST_DISCOVERY_ROOT", str(self.root))
        if discovery_root is not None:
            environment["TRON_IOS_TEST_DISCOVERY_ROOT"] = str(discovery_root)
        if override is not None:
            environment.update(override)
        if home is not None:
            # Exercise the runner's own defaults under a synthetic HOME.
            environment.pop("TRON_IOS_TEST_DERIVED_DATA", None)
            environment.pop("TRON_IOS_TEST_RESULTS_DIR", None)
            environment["HOME"] = str(home)
        return subprocess.run(
            [str((runner_root or self.checkout) / "scripts/tron-ios-test"), command, *(extra_args or [])],
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

    def write_lane(
        self, directory: str, udid: str, *, name: str = "Tron iOS Tests", state: str = "Booted",
        worktree: str | None = None, last_used: float | None = None, disk_bytes: int | None = None,
    ) -> Path:
        """One lane under the runner's root: ownership marker plus its device."""
        lane = self.root / directory
        lane.mkdir(parents=True, exist_ok=True)
        marker: dict[str, object] = {
            "schema": "tron.ios-test-simulator.v1", "owner": "tron-ios-test", "udid": udid,
            "name": name, "runtime_identifier": RUNNER_RUNTIME_ID, "runtime_version": "26.5",
            "runtime_build": "23C54", "device_type_identifier": RUNNER_TYPE_ID,
            "device_type_name": "iPhone 17 Pro", "ephemeral": False,
        }
        if worktree is not None:
            marker["worktree"] = worktree
        if last_used is not None:
            marker["last_used_epoch_seconds"] = int(last_used)
        (lane / "simulator.json").write_text(json.dumps(marker))
        device: dict[str, object] = {
            "name": name, "udid": udid, "state": state, "isAvailable": True,
            "deviceTypeIdentifier": RUNNER_TYPE_ID,
        }
        if disk_bytes is not None:
            device["dataPathSize"] = disk_bytes
        document = json.loads(self.simulator_inventory.read_text())
        document["devices"][RUNNER_RUNTIME_ID].append(device)
        self.simulator_inventory.write_text(json.dumps(document))
        return lane

    def write_orphan_lane(self, udid: str, *, name: str = "Tron iOS Tests", directory: str = "orphan-lane") -> Path:
        """A booted owned simulator in another lane, with no process holding it."""
        return self.write_lane(directory, udid, name=name)

    def latest_run(self) -> Path:
        """The run `status` names as this worktree's and lane's latest run."""
        status = self.invoke(command="status")
        self.assertEqual(status.returncode, 0, status.stderr)
        prefix = "Latest run: "
        for line in status.stdout.splitlines():
            if line.startswith(prefix) and line != f"{prefix}none":
                return Path(line[len(prefix):])
        raise AssertionError(f"no latest run in:\n{status.stdout}")

    def latest_metadata(self) -> dict[str, object]:
        return json.loads((self.latest_run() / "metadata.json").read_text())

    def test_ci_metrics_report_the_checkpoint_run(self) -> None:
        """W-21 (issue #101): the CI adapter's metrics name the run its checkpoint made.

        Failure mode: the adapter finds its run through a pointer the runner no
        longer keeps, or through another lane's or worktree's run, and uploads
        metrics with no run metadata or test summary - a green job whose
        artifact says nothing.
        """
        metrics = self.root / "ios-ci-metrics.json"
        environment = self.contained_environment(self.root)
        environment.update(self.reader_environment())
        environment.update({
            "PATH": f"{self.bin}:{environment['PATH']}",
            **self.tools_environment,
            "TRON_IOS_XCRUN": str(self.xcrun),
            "FAKE_SIMULATOR_INVENTORY": str(self.simulator_inventory),
            "TRON_IOS_SIMULATOR_STATE_DIR": str(self.root / "development-state"),
            "RUNNER_TEMP": str(self.root),
            "TRON_IOS_CI_DERIVED_DATA": str(self.derived),
            "TRON_IOS_CI_RESULTS_DIR": str(self.results),
            "TRON_IOS_CI_METRICS": str(metrics),
            "FAKE_SUMMARY": '{"passedTests":3,"failedTests":0,"skippedTests":0,"totalTestCount":3}',
        })
        result = subprocess.run(
            [str(self.checkout / "scripts/ios-ci-test.sh")], env=environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(metrics.read_text())
        self.assertEqual(value["exit_code"], 0)
        self.assertEqual(value["run"].get("command"), "checkpoint", value)
        self.assertEqual(value["run"].get("phase"), "complete", value)
        self.assertEqual(value["test_summary"].get("passedTests"), 3, value)
        self.assertEqual(sorted(value["processes"]), ["build", "test"], value)

    def test_summary_validation_reconciles_expected_failures(self) -> None:
        result = self.invoke(summary='{"passedTests":2,"failedTests":0,"skippedTests":1,"expectedFailures":3,"totalTestCount":6}')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.invoke(summary='{"passedTests":2,"failedTests":0,"skippedTests":1,"expectedFailures":3,"totalTestCount":7}')
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        result = self.invoke(summary='{"passedTests":0,"failedTests":0,"skippedTests":0,"expectedFailures":1,"totalTestCount":1}')
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)

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
        latest = self.latest_run()
        summary = json.loads((latest / "summary.json").read_text())
        self.assertEqual(summary["error"], "xcresult summary extraction failed")
        self.assertTrue((latest / "summary-extraction.log").exists())
        result = self.invoke(mode="missing-bundle")
        self.assertEqual(result.returncode, 65, result.stderr)
        latest = self.latest_run()
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
        self.assertIn(str(self.checkout), result.stderr)

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

    def primary_products(self) -> Path:
        common_dir = subprocess.run(
            ["git", "-C", str(self.checkout), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            env=self.contained_environment(self.root), check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        primary = Path(common_dir).parent
        key = subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(primary)],
            env=self.contained_environment(self.root), check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        return self.root / "home/Library/Developer/Tron/ios/test-derived-data" / key

    def add_runner_worktree(self) -> Path:
        runner_root = self.root / "runner-worktree"
        subprocess.run(
            ["git", "-C", str(self.checkout), "worktree", "add", "--detach", str(runner_root), "HEAD"],
            env=self.contained_environment(self.root), check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        subprocess.run(
            [sys.executable, str(IDENTITY), "write", "--worktree", str(runner_root),
             "--derived-data", str(self.derived)],
            env=self.contained_environment(self.root), check=True,
            input=json.dumps(self.source_identity(runner_root)), text=True,
            stdout=subprocess.DEVNULL,
        )
        return runner_root

    def remove_runner_worktree(self, runner_root: Path) -> None:
        subprocess.run(
            ["git", "-C", str(self.checkout), "worktree", "remove", "--force", str(runner_root)],
            env=self.contained_environment(self.root), check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_build_seeds_only_primary_compiler_caches_into_owned_products(self) -> None:
        # A temporary linked checkout ensures the runner has a distinct primary
        # checkout, even when this suite itself runs from an ordinary clone.
        runner_root = self.add_runner_worktree()
        try:
            primary = self.primary_products()
            primary.mkdir(parents=True)
            (primary / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
            (primary / "ModuleCache.noindex").mkdir(parents=True)
            (primary / "ModuleCache.noindex/module.pcm").write_text("primary module")
            (primary / "SDKStatCaches.noindex").mkdir()
            (primary / "SDKStatCaches.noindex/sdk.cache").write_text("primary SDK")
            (primary / "Build/Products/Foreign.app").mkdir(parents=True)
            result = self.invoke(command="build", runner_root=runner_root)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.derived / "ModuleCache.noindex/module.pcm").read_text(), "primary module")
            self.assertEqual((self.derived / "SDKStatCaches.noindex/sdk.cache").read_text(), "primary SDK")
            self.assertFalse((self.derived / "Build/Products/Foreign.app").exists())
            self.assertTrue((self.derived / "build-identity.json").is_file())
            (self.derived / "ModuleCache.noindex/module.pcm").write_text("worktree module")
            self.assertEqual((primary / "ModuleCache.noindex/module.pcm").read_text(), "primary module")

            (primary / "ModuleCache.noindex/module.pcm").write_text("primary rebuilt")
            result = self.invoke(command="build", runner_root=runner_root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.derived / "ModuleCache.noindex/module.pcm").read_text(), "worktree module")
        finally:
            self.remove_runner_worktree(runner_root)

    def test_run_does_not_seed_compiler_caches(self) -> None:
        primary = self.primary_products()
        primary.mkdir(parents=True)
        (primary / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
        (primary / "ModuleCache.noindex").mkdir(parents=True)
        (primary / "ModuleCache.noindex/module.pcm").write_text("primary module")

        result = self.invoke(command="run")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.derived / "ModuleCache.noindex").exists())

    def test_build_stays_cold_when_cache_clone_fails_and_removes_staging(self) -> None:
        runner_root = self.add_runner_worktree()
        try:
            primary = self.primary_products()
            primary.mkdir(parents=True)
            (primary / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
            (primary / "ModuleCache.noindex").mkdir(parents=True)
            (primary / "ModuleCache.noindex/module.pcm").write_text("primary module")

            result = self.invoke(command="build", override={"FAKE_CP_FAIL": "1"}, runner_root=runner_root)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.derived / "ModuleCache.noindex").exists())
            self.assertFalse(list(self.derived.glob(".tron-cache-seed.*")))
            self.assertTrue((self.derived / "build-identity.json").is_file())
        finally:
            self.remove_runner_worktree(runner_root)

    def test_build_stamps_products_and_records_source_in_metadata(self) -> None:
        (self.derived / "build-identity.json").unlink()
        result = self.invoke(command="build")
        self.assertEqual(result.returncode, 0, result.stderr)
        stamp = json.loads((self.derived / "build-identity.json").read_text())
        self.assertEqual(stamp["schema"], "tron.ios-test-build-identity.v1")
        self.assertEqual(stamp["worktree"], str(self.checkout))
        self.assertEqual(stamp, self.source_identity())
        metadata = self.latest_metadata()
        self.assertEqual(metadata["source"], stamp)
        self.assertEqual(metadata["source"]["revision"], subprocess.run(
            ["git", "-C", str(self.checkout), "rev-parse", "HEAD"], env=self.contained_environment(self.root),
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip())
        self.assertIsInstance(metadata["source"]["dirty"], bool)

    def test_build_generates_with_the_xcodegen_the_tools_cache_names(self) -> None:
        """#113 failure modes 2 and 3: every XcodeGen the build resolves is the fixture's."""
        result = self.invoke(command="build")
        self.assertEqual(result.returncode, 0, result.stderr)
        # The runner's own toolchain check, then the generator's check and run.
        self.assertEqual(self.xcodegen_calls(self.root), ["--version", "--version", "generate"])

    def test_run_records_the_source_it_verified(self) -> None:
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.latest_metadata()["source"], self.source_identity())

    def test_run_passes_the_source_revision_and_its_state_to_the_test_process(self) -> None:
        # The parity gate records the revision its frames came from and refuses a
        # tree that is not a clean commit, so both facts have to reach the hosted
        # process: a revision alone cannot reproduce frames from a dirty tree.
        log = self.root / "xcode-environment.log"
        result = self.invoke(override={"FAKE_XCODE_ENV_LOG": str(log)})
        self.assertEqual(result.returncode, 0, result.stderr)
        identity = self.source_identity()
        self.assertEqual(log.read_text().splitlines(), [
            f"TRON_SOURCE_REVISION={identity['revision']}",
            f"TRON_SOURCE_DIRTY={'true' if identity['dirty'] else 'false'}",
        ])

    def test_default_products_directory_is_scoped_to_this_worktree(self) -> None:
        home = self.root / "home"
        result = self.invoke(command="status", home=home)
        self.assertEqual(result.returncode, 0, result.stderr)
        key = subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(self.checkout)],
            env=self.contained_environment(self.root),
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        expected = home / "Library/Developer/Tron/ios/test-derived-data" / key
        self.assertIn(f"Test products directory: {expected}", result.stdout)
        self.assertIn(f"Worktree: {self.checkout}", result.stdout)

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

    # SIM-4 memory admission at the runner boundary. Failure modes this case
    # targets, written before the code:
    #
    # 1. The refusal's exit code is replaced by the runner's destination code,
    #    so a caller cannot tell "the Mac is full" from "the destination is
    #    broken".
    # 2. Provisioning boots first and admits afterwards, so the simulator this
    #    command refuses is already holding memory.
    def test_the_runner_keeps_the_admission_exit_and_boots_nothing(self) -> None:
        """Failure modes 1 and 2: exit 73 survives, and nothing was booted."""
        self.reader_value("free-percent", "5")
        result = self.invoke(extra_args=["--only-testing", "TronMobileTests/StubTests"])
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("refusing to boot Tron iOS Tests", result.stderr)
        self.assertIn("lane default", result.stderr)
        self.assertEqual(self.simctl_calls("boot"), [])
        self.assertEqual(self.device_entry(self.owned_udid())["state"], "Shutdown")

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

    # SIM-3 named lanes (runner level). Failure modes these two cases target,
    # written before the code:
    #
    # 1. Two lanes share a state directory, lease or device name, so a second
    #    lane adopts or collides with the first lane's simulator.
    # 2. The lane marker does not record the worktree that created the lane or
    #    the time it was last used, so a lane cannot be attributed or dated.
    # 3. `lane-remove` deletes the products of a worktree that still exists, or
    #    leaves the products of a worktree that no longer exists behind.
    def test_a_named_lane_provisions_its_own_simulator_and_records_its_use(self) -> None:
        """Failure modes 1 and 2: a separate lane, with its use recorded."""
        # The default lane's device name belongs to an unmarked simulator: a
        # named lane must neither collide with it nor adopt it.
        document = json.loads(self.simulator_inventory.read_text())
        document["devices"][RUNNER_RUNTIME_ID].append({
            "name": "Tron iOS Tests", "udid": UDID_D, "state": "Shutdown",
            "isAvailable": True, "deviceTypeIdentifier": RUNNER_TYPE_ID,
        })
        self.simulator_inventory.write_text(json.dumps(document))

        started = time.time()
        owner = ["--only-testing", "TronMobileTests/StubTests"]
        result = self.invoke(lane="alpha", extra_args=owner)
        self.assertEqual(result.returncode, 0, result.stderr)
        lane = self.root / "ios-test-alpha"
        marker = json.loads((lane / "simulator.json").read_text())
        self.assertEqual(marker["worktree"], str(self.checkout))
        self.assertGreaterEqual(marker["last_used_epoch_seconds"], int(started))
        self.assertLessEqual(marker["last_used_epoch_seconds"], int(time.time()) + 1)
        self.assertEqual(marker["name"], "Tron iOS Tests (alpha)")
        self.assertEqual(self.device_entry(marker["udid"])["name"], "Tron iOS Tests (alpha)")
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_D)["state"], "Shutdown")
        self.assertTrue((lane / "lease.lock").exists())
        self.assertFalse((self.state / "simulator.json").exists())
        self.assertFalse((self.state / "lease.lock").exists())
        self.assertFalse((self.root / "ios-test").exists())

        second = self.invoke(lane="alpha", extra_args=owner)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(self.simctl_calls("create")), 1)
        self.assertEqual(json.loads((lane / "simulator.json").read_text())["udid"], marker["udid"])

    # T-3: one lane's lease must cover every run on that lane's simulator.
    # Failure modes these two cases target, written before the code:
    #
    # 1. A lane named on the command line is not carried into the command the
    #    holder starts, so the command leases the named lane while provisioning
    #    the default lane's simulator, and a run on that simulator no longer
    #    serializes with the holder's lease.
    # 2. A descendant of a leased command that names another lane runs on that
    #    lane's simulator while holding no lease on it, because it inherits the
    #    holder's `TRON_IOS_TEST_LOCK_HELD` and skips the locker entirely.
    # 3. A state directory written with a trailing slash, `//` or `./` is
    #    refused as another lane's lease even though it is this lane's own.
    #
    # Failure mode 3 was added after the review of the first attempt, which
    # compared strings and refused every such spelling. The lane selector now
    # normalises the state directory before the inherited-lease check sees it,
    # so this case guards the outcome, not how the check compares paths.
    def test_a_lane_named_on_the_command_line_is_the_lane_that_provisions(self) -> None:
        """Failure mode 1: the holder's command keeps the lane it was given."""
        owner = ["--only-testing", "TronMobileTests/StubTests"]
        # The default lane lives under this fixture's HOME; nothing may appear
        # there for a command that named another lane.
        default_state = self.root / "home/.tron/internal/ios-test"
        result = self.invoke(
            extra_args=["--lane", "alpha", *owner],
            discovery_root=self.root,
            override={"TRON_IOS_TEST_STATE_DIR": ""},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lane = self.root / "ios-test-alpha"
        marker = json.loads((lane / "simulator.json").read_text())
        self.assertEqual(marker["name"], "Tron iOS Tests (alpha)")
        self.assertEqual(self.device_entry(marker["udid"])["name"], "Tron iOS Tests (alpha)")
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        self.assertTrue((lane / "lease.lock").exists())
        self.assertFalse(default_state.exists())
        self.assertFalse((self.state / "lease.lock").exists())

    def test_a_state_directory_spelled_differently_is_still_this_lanes_lease(self) -> None:
        """Failure mode 3: any spelling of this lane's state directory is its lease."""
        # Every leased command (build, run, checkpoint, prepare, diagnose,
        # clean) would be refused if one spelling reached the check as another
        # lane. `$TMPDIR` on macOS ends in `/`, so this is the common spelling.
        spellings = [
            f"{self.state}/",
            f"{self.state.parent}//{self.state.name}",
            f"{self.state.parent}/./{self.state.name}",
        ]
        for spelling in spellings:
            with self.subTest(spelling=spelling):
                result = self.invoke(
                    extra_args=["--only-testing", "TronMobileTests/StubTests"],
                    override={"TRON_IOS_TEST_STATE_DIR": spelling},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.state / "simulator.json").exists())
                self.device_entry(self.owned_udid())

    def test_an_inherited_lease_that_covers_another_lane_is_refused(self) -> None:
        """Failure mode 2: a command never runs on a lane its lease does not hold."""
        other = self.root / "ios-test-other/lease.lock"
        result = self.invoke(
            extra_args=["--only-testing", "TronMobileTests/StubTests"],
            override={"TRON_IOS_TEST_LOCK_HELD": "1", "TRON_IOS_TEST_LEASE_LOCK": str(other)},
        )
        self.assertEqual(result.returncode, 74, result.stderr)
        self.assertIn(str(other), result.stderr)
        self.assertIn(str(self.state / "lease.lock"), result.stderr)
        self.assertEqual(self.simctl_calls("create"), [])
        self.assertEqual(self.simctl_calls("boot"), [])
        self.assertFalse((self.state / "simulator.json").exists())

    def test_lane_remove_keeps_a_live_worktrees_products_and_reclaims_a_deleted_worktrees(self) -> None:
        """Failure mode 3: products follow the recorded worktree's existence."""
        home = self.root / "lane-home"
        products_root = home / "Library/Developer/Tron/ios/test-derived-data"
        live = self.root / "live-worktree"
        live.mkdir()
        gone = self.root / "gone-worktree"
        directories: dict[str, Path] = {}
        for worktree in (live, gone):
            key = subprocess.run(
                [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(worktree)],
                env=self.contained_environment(self.root),
                check=True, text=True, stdout=subprocess.PIPE,
            ).stdout.strip()
            directory = products_root / key
            (directory / "Build/Products").mkdir(parents=True)
            (directory / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
            directories[str(worktree)] = directory
        self.write_lane("ios-test-live", UDID_A, name="Tron iOS Tests (live)", worktree=str(live))
        self.write_lane("ios-test-gone", UDID_B, name="Tron iOS Tests (gone)", worktree=str(gone))

        kept = self.invoke(command="lane-remove", extra_args=["live"], home=home, discovery_root=self.root)
        self.assertEqual(kept.returncode, 0, kept.stderr)
        self.assertTrue(directories[str(live)].exists())
        self.assertIn(str(directories[str(live)]), kept.stdout)
        self.assertIn(str(live), kept.stdout)
        self.assertFalse((self.root / "ios-test-live").exists())

        reclaimed = self.invoke(command="lane-remove", extra_args=["gone"], home=home, discovery_root=self.root)
        self.assertEqual(reclaimed.returncode, 0, reclaimed.stderr)
        self.assertFalse(directories[str(gone)].exists())
        self.assertIn(str(gone), reclaimed.stdout)
        self.assertFalse((self.root / "ios-test-gone").exists())


class BuildIdentityFixture(ContainedFixture, unittest.TestCase):
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
        return self.git_in(self.worktree, *arguments)

    def git_in(self, repository: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(repository), *arguments],
            env=self.contained_environment(self.root),
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()

    def identity(self, worktree: Path | None = None) -> dict[str, object]:
        completed = self.run_script(
            [sys.executable, str(IDENTITY), "show", "--worktree", str(worktree or self.worktree)],
            self.root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def stamp(self, value: dict[str, object]) -> subprocess.CompletedProcess[str]:
        return self.run_script(
            [sys.executable, str(IDENTITY), "write", "--worktree", str(self.worktree), "--derived-data", str(self.derived)],
            self.root, text=True, input=json.dumps(value), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def verify(self) -> subprocess.CompletedProcess[str]:
        return self.run_script(
            [sys.executable, str(IDENTITY), "verify", "--worktree", str(self.worktree), "--derived-data", str(self.derived)],
            self.root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_directory_key_is_stable_and_unique_per_worktree(self) -> None:
        first = self.run_script(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(self.worktree)],
            self.root, check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        self.assertEqual(first, self.identity()["worktree_key"])
        self.assertNotIn("/", first)
        other = self.root / "worktree"  # same path, no trailing component change
        self.assertEqual(first, self.run_script(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(other / ".")],
            self.root, check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip())
        second = self.run_script(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(self.root / "another-worktree")],
            self.root, check=True, text=True, stdout=subprocess.PIPE,
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

    def test_a_nested_checkout_under_the_worktree_is_identified_by_its_own_state(self) -> None:
        """Failure modes this case targets, written before the code:

        1. Git lists an untracked nested repository as one `dir/` entry, so the
           identity read crashes on it, as it did under the ignored build root.
        2. The identity omits the nested checkout's commit, so a dependency moved
           to another revision keeps products that were built from the old one.
        3. The identity omits the nested checkout's own uncommitted or untracked
           content, so an edited dependency keeps stale products.
        """
        nested = self.worktree / "build/SourcePackages/checkouts/Dependency"
        nested.mkdir(parents=True)
        self.git_in(nested, "init", "-q")
        self.git_in(nested, "config", "user.email", "tests@tron.invalid")
        self.git_in(nested, "config", "user.name", "Tron Tests")
        (nested / "Dependency.swift").write_text("let dependency = 1\n")
        self.git_in(nested, "add", "Dependency.swift")
        self.git_in(nested, "commit", "-q", "-m", "initial")

        first = self.identity()
        self.assertTrue(first["dirty"])
        self.assertEqual(first, self.identity())

        (nested / "Dependency.swift").write_text("let dependency = 2\n")
        self.git_in(nested, "commit", "-q", "-am", "second")
        moved = self.identity()
        self.assertNotEqual(moved["source_fingerprint"], first["source_fingerprint"])

        (nested / "Scratch.swift").write_text("let scratch = 1\n")
        with_untracked = self.identity()
        self.assertNotEqual(with_untracked["source_fingerprint"], moved["source_fingerprint"])
        (nested / "Scratch.swift").write_text("let scratch = 2\n")
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
        result = self.run_script(
            [sys.executable, str(IDENTITY), "show", "--worktree", str(nested)],
            self.root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the top level of a worktree", result.stderr)


class ProcessFixture(ContainedFixture, unittest.TestCase):
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
        result = self.run_script(
            self.command([sys.executable, "-c", child], overall=5, no_output=0.4, artifact=artifact), self.root,
        )
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
            stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], env=self.contained_environment(self.root),
                                   text=True, stdout=subprocess.PIPE).stdout.strip()
            self.assertTrue(stat.startswith("Z") or not stat, f"descendant still alive: {pid} {stat}")


class LockFixture(ContainedFixture, unittest.TestCase):
    def test_concurrent_owner_fails_and_release_allows_next_owner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            self.root = Path(temporary)
            lock = self.root / "lease.lock"
            first = subprocess.Popen([
                sys.executable, str(LOCK), "--lock", str(lock), "--",
                sys.executable, "-c", "import time; time.sleep(30)",
            ], env=self.contained_environment(self.root))
            deadline = time.time() + 3
            while time.time() < deadline:
                if lock.exists() and lock.read_text().strip():
                    break
                time.sleep(0.02)
            self.assertTrue(lock.exists() and lock.read_text().strip())
            second = self.run_script([
                sys.executable, str(LOCK), "--lock", str(lock), "--",
                sys.executable, "-c", "pass",
            ], self.root, stderr=subprocess.PIPE, text=True)
            self.assertEqual(second.returncode, 73)
            self.assertIn("already leased", second.stderr)
            first.send_signal(signal.SIGTERM)
            first.wait(timeout=5)
            third = self.run_script([
                sys.executable, str(LOCK), "--lock", str(lock), "--",
                sys.executable, "-c", "pass",
            ], self.root)
            self.assertEqual(third.returncode, 0)


class OwnedLaneFixture(SyntheticReaders, unittest.TestCase):
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
        self.synthetic_stub(self.xcrun, """import fcntl, json, os, sys, time
from pathlib import Path

inventory_path = Path(os.environ['FAKE_SIMCTL_INVENTORY'])
arguments = sys.argv[1:]
if arguments[:2] == ['xcresulttool', 'get']:
    if arguments[2:4] == ['test-results', 'tests'] and os.environ.get('FAKE_TESTS_RESULT'):
        print(Path(os.environ['FAKE_TESTS_RESULT']).read_text()); raise SystemExit(0)
    # The runner's summary of a focused run: one executed, passing test, unless
    # a case asks for a different one (for example a skipped journey).
    print(os.environ.get('FAKE_SUMMARY') or '{"passedTests":1,"failedTests":0,"skippedTests":0,"totalTestCount":1}'); raise SystemExit(0)
assert arguments[0] == 'simctl', arguments
arguments = arguments[1:]
log = os.environ.get('FAKE_SIMCTL_LOG')
if log:
    with open(log, 'a', encoding='utf-8') as handle: handle.write(' '.join(arguments) + '\\n')
if arguments == ['list', '--json']:
    print(json.dumps(json.loads(inventory_path.read_text()))); raise SystemExit(0)
command = arguments[0] if arguments else ''
udid = arguments[1] if len(arguments) > 1 else ''
if command == 'list':
    # `simctl list` in text form: the toolchain check reads the runtimes and
    # scripts/tron-ios-simulator reads the devices.
    document = json.loads(inventory_path.read_text())
    for runtime in document.get('runtimes', []):
        print(f"{runtime.get('name')} - {runtime['identifier']}")
    for devices in document.get('devices', {}).values():
        for device in devices:
            print(f"    {device['name']} ({device['udid']}) ({device['state']})")
    raise SystemExit(0)
if command == 'create':
    _, name, device_type, runtime = arguments
    document = json.loads(inventory_path.read_text())
    existing = sum(len(devices) for devices in document['devices'].values())
    created = f'{existing + 1:08X}-0000-0000-0000-{existing + 1:012X}'
    document['devices'].setdefault(runtime, []).append({
        'name': name, 'udid': created, 'state': 'Shutdown',
        'isAvailable': True, 'deviceTypeIdentifier': device_type,
    })
    inventory_path.write_text(json.dumps(document)); print(created); raise SystemExit(0)
if command == 'bootstatus':
    raise SystemExit(0)
if command == 'terminate':
    raise SystemExit(0)
if command == 'uninstall':
    raise SystemExit(0)
if command == 'get_app_container':
    print('no such app container', file=sys.stderr); raise SystemExit(2)
if command in ('boot', 'shutdown'):
    if command == 'shutdown':
        probe = os.environ.get('FAKE_COMMAND_TREE_PROBE')
        if probe:
            # Was the command tree this release belongs to still alive? Its own
            # lock is free only once the whole tree has exited.
            keep = open(probe, 'a+')
            try:
                fcntl.flock(keep.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                outcome = 'released-after-the-command-tree-exited'
            except BlockingIOError:
                outcome = 'released-while-the-command-tree-lived'
            Path(os.environ['FAKE_COMMAND_TREE_PROBE_LOG']).write_text(outcome + '\\n')
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
if command == 'delete':
    document = json.loads(inventory_path.read_text())
    for devices in document['devices'].values():
        devices[:] = [device for device in devices if device['udid'] != udid]
    inventory_path.write_text(json.dumps(document)); raise SystemExit(0)
print('unexpected simctl arguments: ' + repr(arguments), file=sys.stderr)
raise SystemExit(2)
""")
        self.inventory_path = self.root / "inventory.json"
        self.log_path = self.root / "simctl.log"
        self.development_marker = self.root / "development/ios-simulator-udid"
        self.discovery_root = self.root / "lanes"
        self.state = self.discovery_root / "ios-test"
        self.state.mkdir(parents=True)
        self.home = self.root / "home"
        self.home.mkdir()
        self.inventory_path.write_text(json.dumps({
            # The repository-pinned runtime and device type the profiler and the
            # Gateway E2E harness provision with, plus this fixture's own.
            "runtimes": [
                {
                    "identifier": RUNTIME_ID, "name": "iOS 26.2", "platform": "iOS", "version": "26.2",
                    "buildversion": "23C54", "isAvailable": True,
                },
                {
                    "identifier": RUNNER_RUNTIME_ID, "name": "iOS 26.5", "platform": "iOS", "version": "26.5",
                    "buildversion": "23C54", "isAvailable": True,
                },
            ],
            "devicetypes": [{"identifier": TYPE_ID, "name": "iPhone 17 Pro", "isAvailable": True}],
            "devices": {RUNTIME_ID: [], RUNNER_RUNTIME_ID: []},
        }))
        self.environment = self.contained_environment(self.root)
        self.install_readers(self.root)
        self.environment.update(self.reader_environment())
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
            # The runner derives the shared results and products roots from HOME,
            # and every sweep prunes them. Without this HOME each `reap` here
            # would prune the Mac's real test roots; instead every root these
            # fixtures touch is a directory the temporary fixture owns.
            "HOME": str(self.home),
        })
        self.holders: list[subprocess.Popen[str]] = []

    def tearDown(self) -> None:
        for holder in self.holders:
            holder.kill()
            holder.wait(timeout=5)
            self.close_pipes(holder)
        try:
            self.assert_no_containment_violations()
        finally:
            self.temporary.cleanup()

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

    def owned_lane(
        self, name: str = "ios-test", udid: str = UDID_A, *, present: bool = True,
        worktree: str | None = None, last_used: float | None = None, disk_bytes: int | None = None,
        device_name: str = "Tron iOS Tests",
    ) -> Path:
        """One lane: its ownership marker, and its booted device in the inventory."""
        lane = self.discovery_root / name
        lane.mkdir(parents=True, exist_ok=True)
        marker: dict[str, object] = {
            "schema": "tron.ios-test-simulator.v1", "owner": "tron-ios-test", "udid": udid,
            "name": device_name, "runtime_identifier": RUNTIME_ID, "runtime_version": "26.2",
            "runtime_build": "23C54", "device_type_identifier": TYPE_ID,
            "device_type_name": "iPhone 17 Pro", "ephemeral": False,
        }
        if worktree is not None:
            marker["worktree"] = worktree
        if last_used is not None:
            marker["last_used_epoch_seconds"] = int(last_used)
        (lane / "simulator.json").write_text(json.dumps(marker))
        if present:
            device: dict[str, object] = {
                "name": device_name, "udid": udid, "state": "Booted", "isAvailable": True,
                "deviceTypeIdentifier": TYPE_ID,
            }
            if disk_bytes is not None:
                device["dataPathSize"] = disk_bytes
            document = self.inventory()
            for devices in document["devices"].values():
                devices[:] = [entry for entry in devices if entry["udid"] != udid]
            document["devices"][RUNTIME_ID].append(device)
            self.inventory_path.write_text(json.dumps(document))
        return lane

    def wait_for(self, path: Path, timeout: float = 10) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if path.exists() and path.read_text().strip():
                return
            time.sleep(0.05)
        self.fail(f"timed out waiting for {path}")

    def lock_holder(self, path: Path) -> bool:
        """Whether a live process holds `path`'s flock, probed without waiting."""
        with path.open("a+") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return False

    def wait_for_lock(self, path: Path, *, held: bool, timeout: float = 30) -> None:
        """Wait until a live process does (or no longer does) hold `path`'s flock."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.lock_holder(path) == held:
                return
            time.sleep(0.05)
        self.fail(f"{path} was never {'taken' if held else 'released'} within {timeout:g}s")

    def hold_lease(self, lane: Path, *, command: str | None = None) -> subprocess.Popen[str]:
        """A live process holding a lane's lease, as a running command does.

        With `command` it also records the lease metadata a real holder writes,
        so a caller can tell a live holder from stale metadata.
        """
        holder = subprocess.Popen(
            [
                sys.executable, "-c",
                "import fcntl, sys, time; handle = open(sys.argv[1], 'a+');"
                " fcntl.flock(handle, fcntl.LOCK_EX); print('held', flush=True); time.sleep(60)",
                str(lane / "lease.lock"),
            ],
            env=self.contained_environment(self.root), text=True, stdout=subprocess.PIPE,
        )
        self.holders.append(holder)
        assert holder.stdout is not None
        self.assertEqual(holder.stdout.readline().strip(), "held")
        if command is not None:
            (lane / "lease.lock").write_text(json.dumps({
                "schema": "tron.ios-test-lock.v1", "pid": holder.pid,
                "started_at_epoch_seconds": int(time.time()), "command": command,
                "lock_path": str(lane / "lease.lock"), "uid": os.getuid(),
            }))
        return holder

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

    def present(self, udid: str) -> bool:
        return any(device["udid"] == udid for devices in self.inventory()["devices"].values() for device in devices)

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
                self.owned_lane("ios-test", UDID_A)
                # Wait for the command itself, not for the lease file: the
                # holder records its own identity as soon as it holds the lease.
                command_started = self.root / f"command-started-{signum}"
                holder = subprocess.Popen(
                    self.locker_arguments(
                        sys.executable, "-c",
                        "import pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text('started\\n');"
                        " time.sleep(30)",
                        str(command_started),
                    ),
                    env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
                self.wait_for(command_started)
                holder.send_signal(signum)
                _, stderr = holder.communicate(timeout=30)
                self.close_pipes(holder)
                self.assertEqual(holder.returncode, 128 + signum, stderr)
                self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")

    def test_a_signal_to_the_holder_ends_the_whole_command_tree(self) -> None:
        """Failure mode 8: a signal to the holder must end everything the command
        started, and the release must wait for it.

        The holder used to forward the signal only to its direct child, the
        shell, which died at once, while the bounded process owner below it and
        the xcodebuild that owner runs in its own session kept going - so the
        release shut down the simulator under a live test. The chain here is the
        real one: bash runs scripts/ios-test-process.py in the foreground, and
        that owner runs a grandchild in its own session.
        """
        self.owned_lane("ios-test", UDID_A)
        tree_lock = self.root / "command-tree.lock"
        probe_log = self.root / "release-probe.log"
        grandchild = self.root / "grandchild.py"
        grandchild.write_text(
            "import fcntl, signal, sys, time\n"
            "lock = open(sys.argv[1], 'a+')\n"
            "fcntl.flock(lock.fileno(), fcntl.LOCK_EX)\n"
            # The interrupt must be killed, not politely asked: this is what
            # makes the process owner's own bounded termination the thing that
            # has to finish before the simulator is released.
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print('grandchild', flush=True)\n"
            "time.sleep(20)\n"
        )
        chain = self.root / "chain.sh"
        chain.write_text(
            "#!/bin/bash\n"
            "set -uo pipefail\n"
            f'python3 {PROCESS} --log {self.root}/chain.log --evidence-dir {self.root}/chain-evidence'\
            f' --overall-seconds 30 --no-output-seconds 30 --term-grace-seconds 1'\
            f' --artifact {self.root}/chain.xcresult -- {sys.executable} {grandchild} {tree_lock}\n'\
            'echo "the command ended with $?" >&2\n'
        )
        chain.chmod(0o755)
        environment = {
            **self.environment,
            "FAKE_COMMAND_TREE_PROBE": str(tree_lock),
            "FAKE_COMMAND_TREE_PROBE_LOG": str(probe_log),
        }

        holder = subprocess.Popen(
            self.locker_arguments(str(chain)), env=environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.wait_for_lock(tree_lock, held=True)
        holder.send_signal(signal.SIGTERM)
        _, stderr = holder.communicate(timeout=60)
        self.close_pipes(holder)

        self.assertEqual(holder.returncode, 128 + signal.SIGTERM, stderr)
        self.assertFalse(self.lock_holder(tree_lock), f"a grandchild survived the signal: {stderr}")
        self.assertEqual(probe_log.read_text().strip(), "released-after-the-command-tree-exited", stderr)
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown", stderr)

    def test_a_detached_child_does_not_keep_the_lane_leased(self) -> None:
        """Failure mode 9: the lease belongs to the command tree, so a process the
        command deliberately detaches must not hold it.

        `scripts/ios-gateway-e2e-test` keeps its Gateway fixture past the command
        that started it; if that Gateway inherited the lease, the lane would stay
        leased for as long as it runs and the next command would fail 73. The
        holder names the descriptor it passes (`TRON_IOS_TEST_LEASE_FD`), which is
        what lets a detached child close it.
        """
        self.owned_lane("ios-test", UDID_A)
        detached = self.root / "detached-still-running"
        script = self.root / "detach.sh"
        script.write_text(
            "#!/bin/bash\n"
            "set -uo pipefail\n"
            '( eval "exec ${TRON_IOS_TEST_LEASE_FD}>&-" ; exec python3 -c '
            "'import pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text(\"running\\n\"); time.sleep(5)' "
            '\"$1\" ) &\n'
        )
        script.chmod(0o755)

        completed = self.run_locker(str(script), str(detached))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.wait_for(detached)
        self.assertFalse(self.lock_holder(self.state / "lease.lock"), "a detached child kept the lease")
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
        """Failure modes 7 and 8: a stale lease must not hide the orphan, and the
        lease must live exactly as long as the command tree.

        The holder passes the lease's descriptor to its command, so a holder
        killed with SIGKILL cannot leave a live command whose simulator the
        sweep would shut down under it: the sweep skips while the command runs,
        and reclaims the orphan once it has exited.
        """
        command_ends = self.root / "orphan-command-ends"
        command_started = self.root / "orphan-command-started"
        holder = subprocess.Popen(
            [
                sys.executable, str(LOCK), "--lock", str(self.state / "lease.lock"),
                "--marker", str(self.state / "simulator.json"),
                "--development-state", str(self.development_marker),
                "--", sys.executable, "-c",
                "import pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text('running\\n'); time.sleep(6);"
                " pathlib.Path(sys.argv[2]).write_text('done\\n')",
                str(command_started), str(command_ends),
            ],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.wait_for(command_started)
        self.owned_lane("ios-test", UDID_A)
        holder.kill()
        holder.wait(timeout=10)
        self.close_pipes(holder)
        self.assertNotEqual((self.state / "lease.lock").read_text().strip(), "")
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")

        # The command the killed holder started still runs, and its lease is
        # what proves the lane is in use: releasing now would release the
        # simulator under a live test.
        busy = self.reap()
        self.assertEqual(busy.returncode, 0, busy.stderr)
        self.assertEqual(self.shutdown_targets(), [])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")

        self.wait_for(command_ends)
        self.wait_for_lock(self.state / "lease.lock", held=False)
        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.shutdown_targets(), [UDID_A])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")


class LaneHarness(OwnedLaneFixture):
    """SIM-3: `--lane`, `lanes`, `lane-remove` and lane expiry.

    Failure modes these cases target, written before the code:

    1. A lane name is not validated, so a lane (or `lane-remove`) escapes the
       lane root and state outside it is removed.
    2. The pre-lane overrides and `--lane` disagree and one is silently ignored.
    3. Two lanes share a state directory, device name or lease, so unrelated
       agents serialize on one simulator and one lane's removal touches another.
    4. `lanes` mutates state (creates a lease, removes an expired lane) or fails
       busy, or it hides the worktree, state, lease holder, last use or size.
    5. `lane-remove` removes a lane a live process holds or state with no
       ownership marker.
    6. The sweep expires a lane that is fresh, undated or held, or removes
       marker-less state, or leaves a lane unused past the TTL in place.
    7. A holder killed with SIGKILL leaves stale lease metadata that reads as a
       live holder and hides the lane from the list and from expiry.
    """

    def runner(self, *arguments: str, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(RUNNER), *arguments], env=environment or self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )

    def row(self, output: str, lane: str) -> str:
        """The `lanes` row for one lane, with trailing padding removed."""
        for line in output.splitlines():
            if line.split()[:1] == [lane]:
                return line
        raise AssertionError(f"no {lane!r} row in:\n{output}")

class LaneFixture(LaneHarness, unittest.TestCase):
    def test_lanes_lists_worktree_state_holder_last_use_and_disk(self) -> None:
        """Failure mode 4: every lane row reports its whole ownership state."""
        last_used = time.time() - 3600
        lane = self.owned_lane(
            "ios-test-alpha", UDID_A, worktree="/private/tmp/tron-alpha-worktree",
            last_used=last_used, disk_bytes=4_000_000_000,
        )
        self.owned_lane("ios-test-missing", UDID_B, present=False, last_used=time.time())
        holder = self.hold_lease(lane, command="run")

        result = self.runner("lanes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.discovery_root), result.stdout)
        alpha = self.row(result.stdout, "alpha")
        self.assertIn("/private/tmp/tron-alpha-worktree", alpha)
        self.assertIn("Booted", alpha)
        self.assertIn(f"pid {holder.pid} (run)", alpha)
        self.assertIn(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(last_used)), alpha)
        self.assertIn("3.7 GB", alpha)
        missing = self.row(result.stdout, "missing")
        self.assertIn("missing", missing)
        self.assertIn("idle", missing)
        default = self.row(result.stdout, "default")
        self.assertIn("not-provisioned", default)

    def test_lanes_is_read_only_and_never_takes_a_held_lease(self) -> None:
        """Failure mode 4: listing changes nothing, even with a holder present."""
        held_lane = self.owned_lane("ios-test-held", UDID_A)
        holder = self.hold_lease(held_lane, command="run")
        stale = self.owned_lane("ios-test-stale", UDID_B, last_used=time.time() - 8 * 24 * 3600)
        before = sorted(path.name for path in self.discovery_root.iterdir())

        result = self.runner("lanes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"pid {holder.pid} (run)", self.row(result.stdout, "held"))
        self.assertIsNone(holder.poll())
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")
        self.assertEqual(self.device_entry(UDID_B)["state"], "Booted")
        self.assertTrue(stale.exists())
        self.assertTrue((stale / "simulator.json").exists())
        self.assertEqual(sorted(path.name for path in self.discovery_root.iterdir()), before)
        self.assertFalse((self.state / "lease.lock").exists())
        self.assertFalse((stale / "lease.lock").exists())

    def test_a_named_lane_refuses_the_pre_lane_overrides_and_bad_names(self) -> None:
        """Failure modes 1 and 2: ambiguity and escapes fail instead of guessing."""
        environment = {**self.environment, "TRON_IOS_TEST_LANE": "alpha"}
        with_state = self.runner("lanes", environment=environment)
        self.assertEqual(with_state.returncode, 74, with_state.stderr)
        self.assertIn("TRON_IOS_TEST_STATE_DIR", with_state.stderr)

        environment.pop("TRON_IOS_TEST_STATE_DIR")
        environment["TRON_IOS_TEST_DEVICE_NAME"] = "Tron iOS Other"
        with_device = self.runner("lanes", environment=environment)
        self.assertEqual(with_device.returncode, 74, with_device.stderr)
        self.assertIn("TRON_IOS_TEST_DEVICE_NAME", with_device.stderr)

        environment.pop("TRON_IOS_TEST_DEVICE_NAME")
        conflicting = self.runner("lanes", "--lane", "beta", environment=environment)
        self.assertEqual(conflicting.returncode, 74, conflicting.stderr)
        self.assertIn("TRON_IOS_TEST_LANE", conflicting.stderr)
        agreed = self.runner("lanes", "--lane", "alpha", environment=environment)
        self.assertEqual(agreed.returncode, 0, agreed.stderr)

        for name in ("../escape", "a/b", ".", "-x"):
            with self.subTest(lane=name):
                environment["TRON_IOS_TEST_LANE"] = name
                invalid = self.runner("lanes", environment=environment)
                self.assertEqual(invalid.returncode, 74, invalid.stderr)
                self.assertIn("lane name", invalid.stderr)
        environment.pop("TRON_IOS_TEST_LANE")
        target = self.runner("lane-remove", "../escape")
        self.assertEqual(target.returncode, 74, target.stderr)
        self.assertIn("lane name", target.stderr)
        self.assertEqual(sorted(path.name for path in self.discovery_root.iterdir()), ["ios-test"])

    def test_lane_removal_refuses_a_directory_outside_the_lane_root(self) -> None:
        """Failure mode 1: a marker cannot make a lane command remove anything else."""
        outside = self.root / "outside-lane"
        outside.mkdir()
        marker = json.loads((self.owned_lane("ios-test-alpha", UDID_A) / "simulator.json").read_text())
        marker["udid"] = UDID_B
        (outside / "simulator.json").write_text(json.dumps(marker))

        result = subprocess.run(
            [
                sys.executable, str(SIMULATOR), "lane-remove",
                "--lane-dir", str(outside), "--discovery-root", str(self.discovery_root),
                "--default-state-dir", str(self.state),
                "--development-state", str(self.development_marker),
            ],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("outside the lane root", result.stderr)
        self.assertTrue((outside / "simulator.json").exists())

    def test_lane_remove_refuses_a_held_lane_and_keeps_its_device_and_state(self) -> None:
        """Failure mode 5: a live owner's lane is never removed."""
        lane = self.owned_lane("ios-test-alpha", UDID_A)
        holder = self.hold_lease(lane, command="run")

        result = self.runner("lane-remove", "alpha")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("alpha", result.stderr)
        self.assertIn(f"pid {holder.pid} (run)", result.stderr)
        self.assertTrue((lane / "simulator.json").exists())
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")

    def test_lane_remove_deletes_a_marker_owned_lane_and_keeps_marker_less_state(self) -> None:
        """Failure mode 5: only proven ownership is removed, and only once."""
        lane = self.owned_lane("ios-test-alpha", UDID_A)
        result = self.runner("lane-remove", "alpha")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("removed lane alpha", result.stdout)
        self.assertFalse(lane.exists())
        self.assertFalse(self.present(UDID_A))

        again = self.runner("lane-remove", "alpha")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("no such lane", again.stdout)

        marker_less = self.runner("lane-remove", "default")
        self.assertEqual(marker_less.returncode, 66, marker_less.stderr)
        self.assertIn("ownership marker", marker_less.stderr)
        self.assertTrue(self.state.exists())

    def test_lane_removal_refuses_a_directory_that_holds_another_lane(self) -> None:
        """Failure mode 8: a lane directory that contains another lane's marker
        is that lane's ancestor, so removing it would take the other lane's
        simulator state with it."""
        outer = self.owned_lane("ios-test-outer", UDID_A)
        inner = outer / "ios-test-inner"
        inner.mkdir()
        marker = json.loads((outer / "simulator.json").read_text())
        marker["udid"] = UDID_B
        (inner / "simulator.json").write_text(json.dumps(marker))

        result = self.runner("lane-remove", "outer")
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("another lane", result.stderr)
        self.assertTrue((outer / "simulator.json").exists())
        self.assertTrue((inner / "simulator.json").exists())
        self.assertTrue(self.present(UDID_A))

    def test_a_lane_the_sweep_cannot_remove_is_reported_and_does_not_stop_it(self) -> None:
        """Failure mode 8: removing a lane can fail on the file system (a file
        the sweep cannot delete, or a directory that disappeared under it), and
        the sweep must report that lane instead of dying on it."""
        old = time.time() - 8 * 24 * 3600
        blocked = self.owned_lane("ios-test-blocked", UDID_A, last_used=old)
        unremovable = blocked / "unremovable"
        unremovable.mkdir()
        (unremovable / "kept").write_text("kept\n")
        os.chmod(unremovable, 0o555)
        expired = self.owned_lane("ios-test-gone", UDID_B, last_used=old)
        try:
            result = self.reap()
        finally:
            os.chmod(unremovable, 0o755)

        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("could not remove lane", result.stderr)
        self.assertTrue(blocked.exists())
        self.assertFalse(expired.exists())
        self.assertFalse(self.present(UDID_B))

    def test_the_sweep_expires_lanes_unused_for_longer_than_the_ttl(self) -> None:
        """Failure mode 6: only a datable, unheld, unused lane is removed."""
        old = time.time() - 8 * 24 * 3600
        expired = self.owned_lane("ios-test-old", UDID_A, worktree=str(self.root / "gone-worktree"), last_used=old)
        fresh = self.owned_lane("ios-test-fresh", UDID_B, last_used=time.time() - 60)
        undated = self.owned_lane("ios-test-undated", UDID_C)
        held = self.owned_lane("ios-test-held", UDID_D, last_used=old)
        self.hold_lease(held)
        dead = self.owned_lane("ios-test-dead", UDID_E, present=False, last_used=old)
        # Marker-less state: a lone idle lease file would be an abandoned lane
        # the sweep reclaims (AbandonedLaneFixture), anything more is kept.
        marker_less = self.discovery_root / "ios-test-nomarker"
        marker_less.mkdir()
        (marker_less / "lease.lock").write_text("")
        (marker_less / "notes.txt").write_text("not the tooling's\n")

        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("removed lane old", result.stdout)
        self.assertFalse(expired.exists())
        self.assertFalse(dead.exists())
        self.assertFalse(self.present(UDID_A))
        self.assertFalse(self.present(UDID_E))
        self.assertTrue(fresh.exists())
        self.assertTrue(undated.exists())
        self.assertTrue(held.exists())
        self.assertTrue(marker_less.exists())
        self.assertTrue(self.state.exists())
        self.assertFalse((self.state / "simulator.json").exists())
        # The sweep still releases orphans; a held lane is never touched.
        self.assertEqual(self.device_entry(UDID_B)["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_C)["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_D)["state"], "Booted")

        again = self.reap()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn("removed lane", again.stdout)

    def test_a_lane_whose_holder_was_killed_is_listed_idle_and_expires(self) -> None:
        """Failure mode 7: stale lease metadata never reads as a live holder."""
        lane = self.owned_lane("ios-test-killed", UDID_A, last_used=time.time() - 8 * 24 * 3600)
        holder = subprocess.Popen(
            [
                sys.executable, str(LOCK), "--lock", str(lane / "lease.lock"),
                "--marker", str(lane / "simulator.json"),
                "--development-state", str(self.development_marker),
                "--", sys.executable, "-c", "import time; time.sleep(3)",
            ],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.wait_for(lane / "lease.lock")
        holder.kill()
        holder.wait(timeout=10)
        self.close_pipes(holder)
        # The holder's own command exits on its own and frees the lease, exactly
        # as a holder killed on a development Mac does; what is left is the
        # metadata of a process that is gone.
        self.wait_for_lock(lane / "lease.lock", held=False)
        self.assertIn("pid", (lane / "lease.lock").read_text())

        listed = self.runner("lanes")
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn("idle", self.row(listed.stdout, "killed"))

        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(lane.exists())
        self.assertFalse(self.present(UDID_A))


class ReclaimFixture(LaneHarness, unittest.TestCase):
    """SIM-5 scoped `clean` and `prune`, at the runner and command level.

    Failure modes these cases target, written before the code:

    1. `clean` removes the shared results root, deleting another worktree's or
       another lane's runs.
    2. `clean` leaves this worktree's own runs - including the ones a killed
       command left with no metadata - behind.
    3. `prune` deletes a run inside the retention window, or one of the newest 50
       runs of its worktree.
    4. `prune` keeps an unbounded pile of old runs of one busy worktree.
    5. `prune` deletes the products of a worktree that still exists, or keeps the
       products of a worktree that is gone.
    6. `prune` deletes inside a root that does not carry the runner's ownership
       marker (a caller's wrong root), fails a command because such a root
       exists, or `clean` skips such a root silently instead of refusing it.
    7. The sweep releases lanes but does not prune, so `reap` reclaims memory and
       leaves the disk behind.
    """

    def setUp(self) -> None:
        super().setUp()
        # The runner derives both roots from HOME, which this fixture owns.
        self.results_root = self.home / "Library/Developer/Tron/ios/test-runs"
        self.products_root = self.home / "Library/Developer/Tron/ios/test-derived-data"
        self.results_root.mkdir(parents=True)
        self.products_root.mkdir(parents=True)
        (self.results_root / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
        self.serial = 0

    def run_name(self, started: float) -> str:
        """A run directory name as the runner makes one: a UTC stamp and a suffix."""
        self.serial += 1
        return f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime(started))}-run.A{self.serial:05d}"

    def write_run(
        self, *, worktree: Path, lane: str = "default", started: float | None = None, name: str | None = None,
    ) -> Path:
        """A run directory with the owner the runner writes when it creates it."""
        started = time.time() if started is None else started
        run = self.results_root / (name or self.run_name(started))
        run.mkdir()
        (run / "owner.json").write_text(json.dumps({
            "schema": "tron.ios-test-run-owner.v1", "worktree": str(worktree),
            "worktree_key": "unused-by-prune", "lane": lane, "command": "run",
            "started_epoch_seconds": int(started),
        }))
        return run

    def write_legacy_run(self, *, worktree: Path, name: str) -> Path:
        """A run from before owner.json: only its metadata names the worktree."""
        run = self.results_root / name
        run.mkdir()
        (run / "metadata.json").write_text(json.dumps({
            "schema": "tron.ios-test-run.v1", "source": {"worktree": str(worktree)},
        }))
        return run

    def write_products(self, worktree: Path, *, stamped: bool = True) -> Path:
        key = subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(worktree)],
            env=self.contained_environment(self.root),
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        directory = self.products_root / key
        (directory / "Build/Products").mkdir(parents=True)
        (directory / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
        if stamped:
            (directory / "build-identity.json").write_text(json.dumps({
                "schema": "tron.ios-test-build-identity.v1", "worktree": str(worktree),
                "worktree_key": key, "revision": "0" * 40, "dirty": False,
                "source_fingerprint": "0" * 64,
            }))
        return directory

    def test_clean_removes_only_this_worktrees_lane_runs_and_products(self) -> None:
        """Failure modes 1 and 2: the shared root survives, this lane's runs do not."""
        mine = [self.write_run(worktree=ROOT) for _ in range(2)]
        legacy = self.write_legacy_run(worktree=ROOT, name="20260801T000000Z-run.LEGACY1")
        other_lane = self.write_run(worktree=ROOT, lane="alpha")
        other_worktree = self.root / "other-worktree"
        other_worktree.mkdir()
        foreign = self.write_run(worktree=other_worktree)
        products = self.write_products(ROOT)
        foreign_products = self.write_products(other_worktree)
        self.owned_lane("ios-test", UDID_A)

        result = self.runner("clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.results_root.exists())
        self.assertTrue((self.results_root / ".tron-ios-test-owned").exists())
        for run in (*mine, legacy):
            self.assertFalse(run.exists(), f"{run} should have been removed")
        self.assertTrue(other_lane.exists())
        self.assertTrue(foreign.exists())
        self.assertFalse(products.exists())
        self.assertTrue(foreign_products.exists())
        self.assertFalse(self.present(UDID_A))

    def test_prune_keeps_the_newest_50_of_a_worktree_and_anything_under_7_days(self) -> None:
        """Failure modes 3 and 4: both retention rules hold, per worktree."""
        now = time.time()
        young = [self.write_run(worktree=ROOT, started=now - 3600 * (index + 1)) for index in range(51)]
        old = [
            self.write_run(worktree=ROOT, started=now - 8 * 86400),
            self.write_run(worktree=ROOT, started=now - 9 * 86400),
        ]
        other_worktree = self.root / "other-worktree"
        other_worktree.mkdir()
        other = self.write_run(worktree=other_worktree, started=now - 30 * 86400)

        result = self.runner("prune")
        self.assertEqual(result.returncode, 0, result.stderr)
        # Beyond the newest 50 and past the window: removed.
        self.assertFalse(old[0].exists())
        self.assertFalse(old[1].exists())
        # Beyond the newest 50 but inside the window: kept.
        self.assertTrue(young[-1].exists())
        self.assertEqual(sum(1 for run in young if run.exists()), len(young))
        # Another worktree's only run is inside its own newest 50.
        self.assertTrue(other.exists())
        self.assertEqual(result.stdout.count("removed result run"), 2)

        again = self.runner("prune")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn("removed result run", again.stdout)

    def test_prune_deletes_the_products_of_a_deleted_worktree_only(self) -> None:
        """Failure mode 5: only a stamp naming a missing worktree proves no owner."""
        live = self.root / "live-worktree"
        live.mkdir()
        gone = self.root / "gone-worktree"
        unstamped = self.root / "unstamped-worktree"
        live_products = self.write_products(live)
        gone_products = self.write_products(gone)
        unstamped_products = self.write_products(unstamped, stamped=False)

        result = self.runner("prune")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(gone_products.exists())
        self.assertIn(str(gone), result.stdout)
        self.assertTrue(live_products.exists())
        self.assertTrue(unstamped_products.exists())

    def test_prune_leaves_a_root_without_the_ownership_marker_alone(self) -> None:
        """Failure mode 6: a caller's wrong results root costs it nothing."""
        unmarked = self.root / "unmarked-results"
        (unmarked / "20260101T000000Z-run.STALE1").mkdir(parents=True)
        environment = {**self.environment, "TRON_IOS_TEST_RESULTS_DIR": str(unmarked)}

        result = self.runner("prune", environment=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("without the runner's ownership marker", result.stderr)
        self.assertTrue((unmarked / "20260101T000000Z-run.STALE1").exists())
        # Every sweep prunes, so a sweep must not fail for the same reason.
        self.assertEqual(self.reap(environment=environment).returncode, 0)

    def test_clean_refuses_a_results_root_without_the_ownership_marker(self) -> None:
        """Failure mode 6: an explicit clean fails instead of silently skipping."""
        unmarked = self.root / "unmarked-results"
        (unmarked / "20260101T000000Z-run.STALE1").mkdir(parents=True)
        products = self.write_products(ROOT)
        environment = {**self.environment, "TRON_IOS_TEST_RESULTS_DIR": str(unmarked)}

        result = self.runner("clean", environment=environment)
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("ownership marker", result.stderr)
        self.assertTrue((unmarked / "20260101T000000Z-run.STALE1").exists())
        self.assertTrue(products.exists())

    def test_the_sweep_prunes_so_reap_reclaims_memory_and_disk(self) -> None:
        """Failure mode 7: one `reap` releases the orphan and prunes the runs."""
        self.owned_lane("ios-test", UDID_A)
        now = time.time()
        runs = [self.write_run(worktree=ROOT, started=now - 8 * 86400) for _ in range(52)]

        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")
        self.assertEqual(result.stdout.count("removed result run"), 2)
        self.assertEqual(sum(1 for run in runs if run.exists()), 50)

        again = self.reap()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn("removed result run", again.stdout)


class StatusFixture(LaneHarness, unittest.TestCase):
    """SIM-6 `status --all`: one view of everything that holds the Mac's memory.

    Failure modes these cases target, written before the code:

    1. A booted simulator is missing from the view, or one appears twice, so an
       agent cannot see what holds memory before its final response.
    2. The view cannot tell an owned lane from the Development simulator from an
       unowned simulator, or hides which process holds a lane's lease.
    3. Uptime is wrong, invented, or missing although the process table proves it,
       so "for how long" cannot be answered.
    4. Simulator.app is not listed (the 2026-09-27 incident's 4.5-day process), or
       its row claims an uptime while it is not running.
    5. The view mutates state - taking a lease, booting, shutting down or removing
       anything - so looking at the Mac changes it.
    6. The view takes each lane's lease to find out who holds it, so a command
       starting at that moment fails 73 as if the lane were busy (review P2-2).
    """

    def add_device(self, udid: str, *, name: str, state: str = "Booted", disk_bytes: int | None = None) -> None:
        """An unowned device: in the inventory, with no Tron ownership marker."""
        document = self.inventory()
        device: dict[str, object] = {
            "name": name, "udid": udid, "state": state, "isAvailable": True,
            "deviceTypeIdentifier": TYPE_ID,
        }
        if disk_bytes is not None:
            device["dataPathSize"] = disk_bytes
        document["devices"][RUNTIME_ID].append(device)
        self.inventory_path.write_text(json.dumps(document))

    def development_is(self, udid: str) -> None:
        self.development_marker.parent.mkdir(parents=True, exist_ok=True)
        self.development_marker.write_text(udid + "\n")

    def status_all(self, *, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return self.runner("status", "--all", environment=environment)

    def status_row(self, output: str, marker: str) -> str:
        """The one table row that contains `marker`, for example one owner."""
        matches = [line for line in output.splitlines() if marker in line]
        self.assertEqual(len(matches), 1, f"expected exactly one row containing {marker!r}:\n{output}")
        return matches[0]

    def test_a_command_starting_while_the_lane_view_runs_is_admitted(self) -> None:
        """Failure mode 6: a command that starts while the view probes the lanes
        is admitted, never refused busy."""
        live = self.recorded_holders(count=3)[0]

        view = subprocess.Popen(
            [str(RUNNER), "status", "--all"], env=self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        admitted = self.run_locker(sys.executable, "-c", "pass", marker=live / "simulator.json")
        _, stderr = view.communicate(timeout=60)
        self.close_pipes(view)

        self.assertEqual(view.returncode, 0, stderr)
        self.assertEqual(admitted.returncode, 0, admitted.stderr)

    def test_the_lane_view_never_takes_a_lane_lease_to_probe_it(self) -> None:
        """Failure mode 6, the deterministic half: while the views run, a process
        that asks for a lane's lease is always granted it - a holder record
        alone is what tells the view who holds a lane, so a lane whose recorded
        holder is gone still reads idle.

        Every lane carries a holder record, so each view probes every lane; the
        view is repeated because a probe that did lock a lane would hold it for
        only a moment.
        """
        lanes = self.recorded_holders(count=8)
        dead = self.owned_lane("ios-test-dead", UDID_B, present=False)
        finished = subprocess.Popen([sys.executable, "-c", "pass"], env=self.contained_environment(self.root),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        finished.wait(timeout=30)
        (dead / "lease.lock").write_text(json.dumps({
            "schema": "tron.ios-test-lock.v1", "pid": finished.pid,
            "started_at_epoch_seconds": int(time.time()), "command": "run",
            "lock_path": str(dead / "lease.lock"), "uid": os.getuid(),
        }))

        contended: list[float] = []
        stop = threading.Event()

        def contend() -> None:
            """Ask for a lane's lease in a loop, as a starting command does."""
            while not stop.is_set():
                with (lanes[0] / "lease.lock").open("a+") as handle:
                    try:
                        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        contended.append(time.monotonic())
                    else:
                        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

        worker = threading.Thread(target=contend, daemon=True)
        worker.start()
        try:
            views = [self.status_all() for _ in range(6)]
        finally:
            stop.set()
            worker.join(timeout=10)

        for result in views:
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(contended, [], "the lane view took a lane's lease while it probed it")
        self.assertIn(f"pid {os.getpid()} (run)", self.status_row(views[0].stdout, "lane l0"))
        self.assertIn("idle", self.status_row(views[0].stdout, "lane dead"))

    def recorded_holders(self, *, count: int) -> list[Path]:
        """Lanes whose lease files carry a holder record, as a real holder writes it.

        The record names this test process: it is live, and the synthetic process
        table dates it at the second the fixture asks, so a probe can prove the
        holder is that process without ever taking the lane's lease.
        """
        lanes = [self.owned_lane(f"ios-test-l{index}", UDID_A, present=False) for index in range(count)]
        record: dict[str, object] = {
            "schema": "tron.ios-test-lock.v1", "pid": os.getpid(),
            "started_at_epoch_seconds": int(time.time()), "command": "run",
            "lock_path": "", "uid": os.getuid(),
        }
        self.reader_value("process-table", f"{os.getpid()} 00:00 this test process\n")
        for lane in lanes:
            (lane / "lease.lock").write_text(json.dumps({**record, "lock_path": str(lane / "lease.lock")}))
        return lanes

    def test_status_all_lists_every_booted_simulator_once(self) -> None:
        """Failure modes 1 and 2: every booted device appears, labelled by owner."""
        self.owned_lane(
            "ios-test", UDID_A, worktree="/private/tmp/tron-lane-default", disk_bytes=3 << 30,
        )
        alpha = self.owned_lane(
            "ios-test-alpha", UDID_B, worktree="/private/tmp/tron-lane-alpha",
            device_name="Tron iOS Tests (alpha)",
        )
        self.update_device(UDID_B, state="Shutdown")
        holder = self.hold_lease(alpha, command="run")
        self.owned_lane("ios-test-missing", UDID_C, present=False, device_name="Tron iOS Tests (missing)")
        self.development_is(UDID_D)
        self.add_device(UDID_D, name="iPhone 17 Pro")
        self.add_device(UDID_E, name="Another Persons Simulator")
        self.add_device(UDID_F, name="Idle Unowned Simulator", state="Shutdown")

        result = self.status_all()
        self.assertEqual(result.returncode, 0, result.stderr)
        default = self.status_row(result.stdout, "lane default")
        self.assertIn("Tron iOS Tests", default)
        self.assertIn("Booted", default)
        self.assertIn("/private/tmp/tron-lane-default", default)
        self.assertIn("3.0 GB", default)
        self.assertIn("pid ", self.status_row(result.stdout, "lane alpha"))
        self.assertIn(f"pid {holder.pid} (run)", self.status_row(result.stdout, "lane alpha"))
        self.assertIn("Shutdown", self.status_row(result.stdout, "lane alpha"))
        self.assertIn("missing", self.status_row(result.stdout, "lane missing"))
        self.assertIn("/private/tmp/tron-lane-alpha", self.status_row(result.stdout, "lane alpha"))
        self.assertIn("iPhone 17 Pro", self.status_row(result.stdout, "development "))
        self.assertIn("Another Persons Simulator", self.status_row(result.stdout, "unowned"))
        # A simulator that holds no memory is not cluttering the view.
        self.assertNotIn("Idle Unowned Simulator", result.stdout)

    def test_status_all_takes_uptime_from_the_process_table(self) -> None:
        """Failure mode 3: a booted device's uptime is its boot process's age."""
        self.owned_lane("ios-test", UDID_A)
        self.owned_lane("ios-test-alpha", UDID_B, device_name="Tron iOS Tests (alpha)")
        self.update_device(UDID_B, state="Shutdown")
        self.reader_value("process-table", device_process(UDID_A, "01-16:05:07") + "not a ps line\n")

        result = self.status_all()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1d 16h", self.status_row(result.stdout, "lane default"))
        self.assertNotIn("1d 16h", self.status_row(result.stdout, "lane alpha"))

        unreadable = self.status_all(environment={**self.environment, "FAKE_PS_MODE": "unavailable"})
        self.assertEqual(unreadable.returncode, 0, unreadable.stderr)
        self.assertIn("cannot read the process table", unreadable.stderr)
        row = self.status_row(unreadable.stdout, "lane default")
        self.assertIn("Booted", row)
        self.assertNotIn("1d 16h", row)

    def test_status_all_always_shows_simulator_app(self) -> None:
        """Failure mode 4: the GUI app is listed, never with an invented uptime."""
        self.owned_lane("ios-test", UDID_A)
        self.reader_value(
            "process-table",
            device_process(UDID_A) + "2282 01-04:49:13 /Applications/Xcode.app/Contents/Developer"
            "/Applications/Simulator.app/Contents/MacOS/Simulator\n",
        )
        running = self.status_all()
        self.assertEqual(running.returncode, 0, running.stderr)
        running_row = self.status_row(running.stdout, "Simulator.app")
        self.assertNotIn("not running", running_row)
        self.assertIn("1d 4h", running_row)

        self.reader_value("process-table", "")
        idle = self.status_all()
        self.assertEqual(idle.returncode, 0, idle.stderr)
        idle_row = self.status_row(idle.stdout, "Simulator.app")
        self.assertIn("not running", idle_row)
        self.assertNotIn("1d 4h", idle_row)

    def test_status_all_changes_nothing(self) -> None:
        """Failure mode 5: looking at the Mac never takes, boots, shuts or removes."""
        self.owned_lane("ios-test", UDID_A, last_used=time.time() - 8 * 24 * 3600)
        before_lanes = sorted(path.name for path in self.discovery_root.iterdir())
        before_inventory = self.inventory_path.read_text()

        result = self.status_all()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(path.name for path in self.discovery_root.iterdir()), before_lanes)
        self.assertEqual(self.inventory_path.read_text(), before_inventory)
        self.assertFalse((self.state / "lease.lock").exists())
        mutations = [
            line for line in self.log_path.read_text().splitlines()
            if line.split()[:1] and line.split()[0] in ("boot", "shutdown", "delete", "erase", "create", "bootstatus")
        ]
        self.assertEqual(mutations, [])


class LifecycleHarness(LaneHarness):
    """Synthetic Mac for the tools that share one lane lifecycle (SIM-7)."""

    def add_device(self, udid: str, *, name: str, state: str = "Booted") -> None:
        """A device no Tron ownership marker claims."""
        document = self.inventory()
        document["devices"].setdefault(RUNNER_RUNTIME_ID, []).append({
            "name": name, "udid": udid, "state": state, "isAvailable": True,
            "deviceTypeIdentifier": TYPE_ID,
        })
        self.inventory_path.write_text(json.dumps(document))

    def simctl_commands(self) -> list[str]:
        """The simctl verb of every call the synthetic xcrun served."""
        try:
            lines = self.log_path.read_text().splitlines()
        except FileNotFoundError:
            return []
        return [line.split(" ", 1)[0] for line in lines]

    def wait_until_lane_booted(self, marker_path: Path, timeout: float = 30) -> str:
        """The UDID of the lane a running command booted, once it is Booted."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                marker = json.loads(marker_path.read_text())
                if self.device_entry(marker["udid"])["state"] == "Booted":
                    return marker["udid"]
            except (OSError, KeyError, json.JSONDecodeError):
                pass
            time.sleep(0.05)
        self.fail(f"no booted device for {marker_path} within {timeout:g}s")

    def status_row(self, output: str, owner: str) -> str:
        """The one `status --all` row carrying this owner marker."""
        matches = [line for line in output.splitlines() if owner in line]
        self.assertEqual(len(matches), 1, f"expected exactly one row containing {owner!r}:\n{output}")
        return matches[0]

    def install_fake_xcodebuild(self) -> None:
        """A synthetic xcodebuild that produces the E2E harness's xctestrun.

        `FAKE_BUILD_GATE` (a path) holds the build open until the file exists,
        so a case can kill the command that owns the lane while it is still
        building. `FAKE_XCODEBUILD_LOG` records every invocation as JSON, with
        the build's scheme/test plan and each target's patched fixture
        environment, so a case can prove which target the harness patched.
        """
        self.synthetic_stub(self.bin / "xcodebuild", FIXTURE_GATE_SOURCE + '''
import json, plistlib
arguments = sys.argv[1:]
if arguments[:1] == ["-version"]:
    print("Xcode 26.6"); raise SystemExit(0)
log = os.environ.get("FAKE_XCODEBUILD_LOG")
def record(value):
    if log:
        with open(log, "a", encoding="utf-8") as handle: handle.write(json.dumps(value) + "\\n")
def xctestrun_targets(path):
    document = plistlib.loads(Path(path).read_bytes())
    return {target["BlueprintName"]: sorted(target.get("EnvironmentVariables", {}))
            for configuration in document["TestConfigurations"]
            for target in configuration["TestTargets"]}
if "build-for-testing" in arguments:
    derived = Path(arguments[arguments.index("-derivedDataPath") + 1])
    products = derived / "Build/Products"
    products.mkdir(parents=True, exist_ok=True)
    scheme = arguments[arguments.index("-scheme") + 1]
    test_plan = arguments[arguments.index("-testPlan") + 1]
    # Xcode's real shape: the unit target omits IsUITestBundle (#497).
    targets = [{"BlueprintName": "TronMobileTests"}]
    if scheme == "Tron UI Validation":
        targets.append({"BlueprintName": "TronMobileUITests", "IsUITestBundle": True})
    record({"action": "build", "scheme": scheme, "test_plan": test_plan})
    with (products / (scheme + "_" + test_plan + "_iOS.xctestrun")).open("wb") as handle:
        plistlib.dump({"TestConfigurations": [{"IsEnabled": True, "TestTargets": targets}]}, handle)
    # The built hosted product, so a command that resets the lane's app state can
    # read the bundle identifier it must remove.
    app_plist = products / "Test-iphonesimulator/TronMobile.app/Info.plist"
    app_plist.parent.mkdir(parents=True, exist_ok=True)
    with app_plist.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.tron.mobile.testhost"}, handle)
    if os.environ.get("FAKE_BUILD_GATE"):
        wait_for_fixture_gate(Path(os.environ["FAKE_BUILD_GATE"]))
if "test-without-building" in arguments and "-resultBundlePath" in arguments:
    calls = os.environ.get("FAKE_XCODEBUILD_CALLS")
    test_filter = next((value.split(":", 1)[1] for value in arguments if value.startswith("-only-testing:")), "unknown")
    if calls:
        with open(calls, "a", encoding="utf-8") as handle: handle.write(test_filter + "\\n")
    record({"action": "run", "test_filter": test_filter,
            "targets": xctestrun_targets(arguments[arguments.index("-xctestrun") + 1]) if "-xctestrun" in arguments else None})
    invocation = Path(calls).read_text().splitlines() if calls and Path(calls).exists() else []
    failure = int(os.environ.get("FAKE_XCODEBUILD_FIRST_TEST_EXIT") or 0)
    if failure and len(invocation) == 1:
        if os.environ.get("FAKE_XCODEBUILD_FIRST_TEST_BUNDLE") == "1":
            Path(arguments[arguments.index("-resultBundlePath") + 1]).mkdir(parents=True, exist_ok=True)
        raise SystemExit(failure)
    bundle = Path(arguments[arguments.index("-resultBundlePath") + 1])
    bundle.mkdir(parents=True, exist_ok=True)
    (bundle / "Info.plist").write_text("fixture result bundle\\n")
''')


class ProfilerLifecycleFixture(LifecycleHarness, unittest.TestCase):
    """SIM-7: the iOS profiler joins the shared lane lifecycle.

    Failure modes these cases target, written before the code:

    1. The profiler leases the lane without its ownership marker, so the
       simulator it booted is never released when the run ends.
    2. The profiler does not run the shared sweep, so a lane a crash left booted
       is not reclaimed by it, and (or) a lane a live process holds is not
       skipped.
    3. The profiler's lane is not attributed to this worktree, so the lane
       tables cannot say whose lane it is.
    4. A boot the shared admission refuses (73) is reported as a destination
       failure, and (or) the profiler boots the simulator anyway.
    5. A signal to the profiler kills the lease holder instead of reaching it,
       so the lane's simulator is never released (review P1-1).
    """

    def setUp(self) -> None:
        super().setUp()
        # The profiler's products and reports are its own, and --no-build keeps
        # these cases free of xcodebuild: only its simulator path is exercised.
        self.environment = {
            **self.environment,
            "TRON_PROFILE_IOS_DERIVED_DATA": str(self.root / "profile-derived"),
            "TRON_PROFILE_RESULTS_DIR": str(self.root / "profile-results"),
        }

    def profile(self, *arguments: str, timeout: float = 120) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PROFILER), *arguments], env=self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )

    def lane_marker(self) -> dict[str, object]:
        return json.loads((self.state / "simulator.json").read_text())

    def test_the_profiler_releases_its_lane_and_sweeps_orphans(self) -> None:
        """Failure modes 1, 2 and 3: the run ends with nothing of its own booted."""
        self.owned_lane("ios-test-orphan", UDID_A, device_name="Tron iOS Tests (orphan)")
        self.owned_lane("ios-test-held", UDID_B, device_name="Tron iOS Tests (held)")
        self.hold_lease(self.discovery_root / "ios-test-held", command="run")

        # --no-build refuses before scenario products that were never built,
        # which is what makes this case hardware-free while still provisioning.
        result = self.profile("--scenario", "control", "--no-build")
        self.assertEqual(result.returncode, 74, result.stderr)

        marker = self.lane_marker()
        self.assertEqual(marker["worktree"], os.path.realpath(ROOT))
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_B)["state"], "Booted")
        self.assertIn("shut down", result.stdout)
        self.assertEqual(self.simctl_commands().count("delete"), 0)

    def test_a_signal_to_the_profiler_releases_the_lane_it_leased(self) -> None:
        """Failure mode 5: the profiler must hand its process over to the lease
        holder, not start it as a child it can kill.

        `subprocess.run` kills its child with SIGKILL when CPython raises
        KeyboardInterrupt, so the holder never reached its release. A lane that
        is already booted, and an orphan lane whose release is slow, keep the
        profiler inside the lease while the signal arrives.
        """
        self.owned_lane("ios-test", UDID_A)
        self.owned_lane("ios-test-orphan", UDID_B, device_name="Tron iOS Tests (orphan)")
        started = self.root / "shutdown-started"
        environment = {
            **self.environment,
            "FAKE_SHUTDOWN_DELAY_SECONDS": "5",
            "FAKE_SHUTDOWN_STARTED": str(started),
            "TRON_IOS_TEST_SHUTDOWN_TIMEOUT_SECONDS": "30",
        }

        process = subprocess.Popen(
            [str(PROFILER), "--scenario", "control", "--no-build"], env=environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            # The profiler leases the lane before its sweep: this is the sweep
            # releasing an orphan, so the profiler is inside the lease.
            self.wait_for(started)
            os.killpg(process.pid, signal.SIGINT)
            _, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 128 + signal.SIGINT, stderr)
            self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown", stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=30)
            self.close_pipes(process)

    def test_a_profiler_boot_the_mac_refuses_keeps_the_shared_exit(self) -> None:
        """Failure mode 4: the refusal stays 73 and nothing is booted."""
        self.reader_value("free-percent", "0")

        result = self.profile("--scenario", "control", "--no-build")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("reserve", result.stderr)
        self.assertNotIn("boot", self.simctl_commands())
        self.assertEqual(self.device_entry(self.lane_marker()["udid"])["state"], "Shutdown")


class GatewayE2EFixture(LifecycleHarness, unittest.TestCase):
    """SIM-7: the Gateway E2E harness joins the shared lane lifecycle.

    Failure modes these cases target, written before the code:

    1. The harness leases the lane without its ownership marker, so the
       simulator it booted is never released when the command ends.
    2. The harness does not run the shared sweep, so a lane booted by a crash is
       not reclaimed by it, and (or) a lane a live process holds is not skipped.
    3. The harness's lane is not attributed to this checkout, so `lane-remove`
       cannot reclaim the products of a worktree that no longer exists.
    4. A boot the shared admission refuses (73) is reported as a generic failure
       and the harness carries on building.
    5. A harness killed while it holds the lane leaves the lane booted, and the
       next Tron test tool does not reclaim it.
    6. `clean` deletes the remembered Development simulator when the lane's
       marker names it.

    W-16 (issue #98): the fixture and products are one worktree's, not one user's.

    7. Two worktrees resolve the same default fixture directory or DerivedData,
       so one worktree's `state.env`, Gateway pid, npm lock hash, logs and test
       products are another's, and unleased `status`/`logs` show its Gateway.
    8. The worktree-keyed default replaces an explicit TRON_IOS_E2E_STATE_DIR
       or TRON_IOS_E2E_DERIVED_DATA, which CI sets.
    9. `build` leaves products without the build identity of the source that
       produced them, so `run` cannot prove where they came from.
    10. `run` executes products that carry no identity, another worktree's
        identity or another source state's, or renews the Gateway fixture
        before it refuses them.
    11. `stop` or `clean` in one worktree removes another worktree's fixture or
        DerivedData.
    12. The harness finds its products with a BSD-only tool, so its build fails
        silently on the Linux CI runner that runs these cases (#113).
    13. The first focused XCTest case fails before creating an `.xcresult`, but a
        later case passes and overwrites the status to green. Failure-report
        extraction is optional evidence and must never decide whether the case
        sequence stops.
    14. A fixture or xctestrun setup command fails while the case callback runs
        in conditional context; errexit is disabled and successful XCTest work
        can mask the failed setup.
    15. A nested result-node list is recursively passed to itself instead of
        iterating its children, suppressing optional failure details.
    16. Shared-link ping/pong counts increment both at FIFO admission and actual
        forwarding, so reported frames do not match the observed event timeline.

    W-53 (issue #424): the real-UI lane reuses the same fixture, lane and lease.

    17. `run-ui` patches the hosted unit target (or no target at all), so the UI
        runner never receives the fixture environment, every journey skips for a
        missing fixture, and the cross-layer receipt is green.
    18. `run-ui` runs something other than the journeys it owns, or loses the
        `--only-testing` selection when the lease holder starts it again.
    19. A journey's evidence directory omits the result bundle, the Gateway's
        runtime log, the proxy's link statistics or the XCTest summary, or names
        a digest that does not match the bytes it claims to describe, or reports
        a status that is not the run's final one.
    20. The journey that backgrounds the app leaves no record of a retired
        connection and a new one in the Gateway's own log, or a journey that
        never connects is reported as having reconnected.
    21. `run-ui` leaves the lane's simulator booted, leaves the Gateway fixture it
        failed with running, or leaves the hosted app paired for the unit lane
        that shares this worktree's app.

    #445: the fixture and its fault proxy are not the parent Gateway's children.

    22. A shell spawned by the Stable or Debug Gateway carries that Gateway's
        environment, and the harness passes it to the fixture Gateway, which
        then runs with a foreign `TRON_GATEWAY_*` value (runtime epoch, channel,
        supervision, payload identity) or a foreign `PI_*` store path.
    23. The fault proxy inherits the same environment and hands its own `PATH`
        to the Gateway it restarts privately, so a leak survives the restart.
    24. The harness takes the fixture's Node from the caller's `PATH`, where a
        Gateway-spawned shell finds the parent's bundled runtime. That runtime
        has the pinned version and a sibling npm, so a version check accepts it,
        and its Team ID cannot dlopen the ad hoc-signed node-pty prebuild.
    25. The incompatible Node is only discovered when node-pty fails inside the
        fixture (`Failed to load native module`, which hides the dlopen cause),
        so the toolchain failure is attributed to the fixture and no signal
        names the real error.
    26. A fault proxy that exits during startup is reported only as a generic
        message, without its process status or the tail of its stderr.

    #706: a fixture Gateway is recognized by its own command line, and a start that
    fails that proof must not leave the process it spawned running.

    27. The fixture Gateway and fault proxy rewrite their process title to their
        command line, which the OS keeps within the process's original argv. A
        checkout at a long path overflows it, `ps` shows a truncated command, and a
        ready fixture is refused as not owned.
    28. A start that fails its owned-command proof, or never becomes ready, leaves
        the Gateway it spawned running: the harness refuses to signal a PID it cannot
        prove, and the start never retires the child it spawned itself.
    """

    def setUp(self) -> None:
        super().setUp()
        self.install_fake_xcodebuild()
        self.environment = {
            **self.environment,
            **self.install_synthetic_xcodegen(self.root),
            "TRON_IOS_E2E_STATE_DIR": str(self.root / "e2e-state"),
            "TRON_IOS_E2E_DERIVED_DATA": str(self.root / "e2e-derived"),
        }

    def e2e(
        self, *arguments: str, timeout: float = 180, harness: Path = E2E,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(harness), *arguments], env=environment or self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )

    def readiness_node_environment(self, environment: dict[str, str]) -> dict[str, str]:
        """Use test-owned readiness processes instead of requiring built Gateway dist.

        These actual-runner regressions stop before XCTest. Their only fixture
        contract is the enrollment/health and proxy-ready signals consumed while
        setting up a fresh case, so a clean checkout need not build production
        Gateway artifacts merely to test runner failure propagation. The one bin
        directory also carries `npm`, which the harness requires beside `node`
        before it installs the fixture Gateway.

        The wrapper is that complete pinned toolchain (`TRON_NODE_BIN` with a
        sibling `npm`) and carries its real Node, its sources, its records and its
        knobs itself: a fixture process starts under the harness's minimal
        environment (#445) and never sees this process's variables.
        """
        real_node = self.pinned_host_node(environment)
        binary = self.root / "fixture-node"
        binary.mkdir(exist_ok=True)
        gateway_source = binary / "fixture-gateway.cjs"
        gateway_source.write_text(f'''const fs = require("node:fs");
const http = require("node:http");
const logs = `${{process.env.TRON_DATA_DIR}}/logs`;
fs.mkdirSync(logs, {{ recursive: true }});
fs.appendFileSync(`${{logs}}/gateway.jsonl`, JSON.stringify({{ event: "gateway.started" }}) + "\\n");
// The Gateway's own record of the device connections a journey left behind, in the
// order the real Gateway writes them: each connection opens and closes under its
// own id, so a backgrounded journey's retire-then-reconnect is visible as a close
// before a different connection's open. The counts come from the case's knob file
// because a fixture process inherits no case environment (#445).
const knob = "{self.fixture_knob("connection-counts")}";
const connections = (fs.existsSync(knob) ? fs.readFileSync(knob, "utf8") : "2 1").trim().split(/\\s+/).map(Number);
for (let index = 0; index < Math.max(connections[0], connections[1]); index++) {{
  const connectionId = `fixture-connection-${{index + 1}}`;
  if (index < connections[0]) {{
    fs.appendFileSync(`${{logs}}/gateway.jsonl`, JSON.stringify({{ event: "connection.opened", connectionId }}) + "\\n");
  }}
  if (index < connections[1]) {{
    fs.appendFileSync(`${{logs}}/gateway.jsonl`, JSON.stringify({{ event: "connection.closed", connectionId }}) + "\\n");
  }}
}}
const enrollment = `${{process.env.TRON_DATA_DIR}}/gateway/enrollment.json`;
fs.writeFileSync(enrollment, JSON.stringify({{ code: "fixture-pairing-code" }}), {{ mode: 0o600 }});
const server = http.createServer((request, response) => {{
  response.writeHead(request.url === "/health" ? 200 : 404);
  response.end();
}});
server.listen(Number(process.env.TRON_GATEWAY_PORT), "127.0.0.1");
process.once("SIGTERM", () => server.close(() => process.exit(0)));
process.once("SIGINT", () => server.close(() => process.exit(0)));
''')
        proxy_source = binary / "fixture-proxy.cjs"
        proxy_source.write_text(f'''const fs = require("node:fs");
const http = require("node:http");
const controlFailure = "{self.fixture_knob("proxy-control-failure")}";
const startupFailure = "{self.fixture_knob("proxy-startup-failure")}";
if (fs.existsSync(startupFailure) && fs.readFileSync(startupFailure, "utf8").trim() === "1") {{
  console.error("fixture proxy startup failure evidence");
  process.exit(42);
}}
const server = http.createServer((request, response) => {{
  if (request.url === "/_fixture/control") {{
    // The harness reads the owned proxy's link statistics as journey evidence.
    if (fs.existsSync(controlFailure) && fs.readFileSync(controlFailure, "utf8").trim() === "1") {{
      response.writeHead(500); response.end(); return;
    }}
    response.writeHead(200, {{ "content-type": "application/json" }});
    response.end(JSON.stringify({{ schedule: "unshaped" }}));
    return;
  }}
  response.writeHead(404); response.end();
}});
server.listen(0, "127.0.0.1", () => {{
  fs.writeFileSync(process.env.TRON_E2E_PROXY_READY, JSON.stringify({{ port: server.address().port, pid: process.pid }}), {{ mode: 0o600 }});
}});
process.once("SIGTERM", () => server.close(() => process.exit(0)));
process.once("SIGINT", () => server.close(() => process.exit(0)));
''')
        record = binary / "record"
        record.mkdir(exist_ok=True)
        node = binary / "node"
        node.write_text(f'''#!/usr/bin/env bash
set -euo pipefail
case "${{1:-}}" in
  */packages/gateway/dist/index.js)
    /usr/bin/env >"{record}/gateway.env"
    echo "$$" >"{record}/gateway.pid"
    # The command line the process runs as is the owned command the harness checks for
    # (argv, not a title rewrite, so no path length can truncate it). A case may name
    # another command line through its knob, to exercise a refused start.
    argv0="node $1"
    if [[ -f "{self.fixture_knob("gateway-argv0")}" ]]; then argv0="$(<"{self.fixture_knob("gateway-argv0")}")"; fi
    exec -a "$argv0" "{real_node}" "{gateway_source}"
    ;;
  */ios-gateway-fault-proxy.mjs)
    /usr/bin/env >"{record}/proxy.env"
    exec -a "node $1" "{real_node}" "{proxy_source}"
    ;;
  */packages/gateway/*|*/ios-gateway-*.mjs|*.js|*.mjs|*.cjs)
    echo "unexpected Node fixture command: $*" >&2
    exit 70
    ;;
esac
exec "{real_node}" "$@"
''')
        node.chmod(0o755)
        # `npm` only has to satisfy the harness's same-bin-directory check and
        # the fixture install it performs; no case builds production Gateway
        # artifacts, and the checks under test stop before that build's output.
        npm = binary / "npm"
        npm.write_text("#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n")
        npm.chmod(0o755)
        result = dict(environment)
        result["PATH"] = f"{binary}:{environment['PATH']}"
        result["TRON_NODE_BIN"] = str(node)
        return result

    def fixture_knob(self, name: str) -> Path:
        """A file a fake fixture process reads its own configuration from.

        A fixture process starts under the harness's minimal environment (#445),
        so a case that steers the synthetic Gateway or proxy writes this knob
        before the harness starts it instead of exporting a variable.
        """
        path = self.root / "fixture-node/knobs" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def fixture_environment_record(self, environment: dict[str, str], name: str) -> dict[str, str]:
        """The environment one fixture process was handed, as `readiness_node_environment` records it."""
        path = Path(environment["TRON_NODE_BIN"]).parent / "record" / name
        self.assertTrue(path.is_file(), f"the fixture Node wrapper recorded no {name}")
        assignments = {}
        for line in path.read_text().splitlines():
            variable, _, value = line.partition("=")
            if variable:
                assignments[variable] = value
        return assignments

    def pinned_host_node(self, environment: dict[str, str]) -> str:
        """The real Node the synthetic fixture toolchain forwards to.

        A test process started from a Gateway-spawned shell has that Gateway's
        bundled runtime first on `PATH`: the very runtime #445 keeps out of a
        fixture, and one that cannot load this checkout's node-pty prebuild. So
        prefer the candidates the harness itself prefers, and use the first PATH
        entry only on a machine that has neither (hosted CI's setup-node).
        """
        candidates = [
            Path(os.environ.get("NVM_DIR", Path.home() / ".nvm")) / f"versions/node/v{NODE_VERSION}/bin/node",
            Path("/opt/homebrew/bin/node"),
            Path("/usr/local/bin/node"),
        ]
        for candidate in candidates:
            if not candidate.is_file():
                continue
            if subprocess.run(
                [str(candidate), "--version"], env=environment,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            ).stdout.strip() == f"v{NODE_VERSION}":
                return str(candidate)
        found = shutil.which("node", path=environment["PATH"])
        self.assertIsNotNone(found, "the pinned Node runtime is required by the E2E runner")
        return found

    def nvm_pinned_environment(self, environment: dict[str, str]) -> dict[str, str]:
        """The fixture toolchain selected the way a machine without TRON_NODE_BIN
        selects it: the pinned Node in nvm's own layout, and no TRON_NODE_BIN.
        """
        result = self.readiness_node_environment(environment)
        wrapper = Path(result.pop("TRON_NODE_BIN"))
        pinned = self.root / f"nvm/versions/node/v{NODE_VERSION}/bin"
        pinned.mkdir(parents=True)
        for name in ("node", "npm"):
            (pinned / name).symlink_to(wrapper.parent / name)
        result["NVM_DIR"] = str(self.root / "nvm")
        return result

    def default_roots_environment(self) -> dict[str, str]:
        """The harness's own defaults: no overrides, TMPDIR inside the fixture."""
        environment = dict(self.environment)
        environment.pop("TRON_IOS_E2E_STATE_DIR")
        environment.pop("TRON_IOS_E2E_DERIVED_DATA")
        return environment

    def second_worktree(self) -> Path:
        """Another checkout of the harness: the same scripts at another path."""
        other = self.root / "other-worktree"
        ignore = shutil.ignore_patterns("__pycache__")
        shutil.copytree(ROOT / "scripts", other / "scripts", ignore=ignore)
        shutil.copytree(ROOT / "config", other / "config", ignore=ignore)
        shutil.copy2(ROOT / ".node-version", other / ".node-version")
        return other

    def long_worktree(self) -> Path:
        """A checkout of the harness at a path longer than a fixture process's argv.

        Failure mode 27: the path is the one input that differs between a fixture
        that starts and one that is refused, so this makes it long on purpose. Only
        what `prepare` reads is copied: the scripts, the pinned toolchain files and
        the Gateway's manifests, not the Gateway or its dependencies.
        """
        worktree = self.root / ("long-" + "w" * 120) / ("tree-" + "x" * 120)
        ignore = shutil.ignore_patterns("__pycache__")
        shutil.copytree(ROOT / "scripts", worktree / "scripts", ignore=ignore)
        shutil.copytree(ROOT / "config", worktree / "config", ignore=ignore)
        shutil.copytree(ROOT / ".github/workflows", worktree / ".github/workflows")
        shutil.copy2(ROOT / ".node-version", worktree / ".node-version")
        (worktree / "packages/mac-app/scripts").mkdir(parents=True)
        for name in ("bundle-gateway.sh", "package-dmg.sh", "verify-gateway-payload.sh"):
            shutil.copy2(ROOT / "packages/mac-app/scripts" / name, worktree / "packages/mac-app/scripts" / name)
        (worktree / "packages/gateway").mkdir(parents=True)
        for name in ("package.json", "package-lock.json"):
            shutil.copy2(ROOT / "packages/gateway" / name, worktree / "packages/gateway" / name)
        return worktree

    def reported(self, output: str, label: str) -> Path:
        """The one path `status` reports under `label`."""
        values = [line.split(": ", 1)[1] for line in output.splitlines() if line.startswith(f"{label}: ")]
        self.assertEqual(len(values), 1, f"expected one {label!r} line:\n{output}")
        return Path(values[0])

    def worktree_key(self, worktree: Path) -> str:
        return subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(worktree)],
            env=self.environment, check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()

    def source_identity(self, worktree: Path = ROOT) -> dict[str, object]:
        identity_owner = worktree / "scripts/ios-test-build-identity.py"
        return json.loads(subprocess.run(
            [sys.executable, str(identity_owner), "show", "--worktree", str(worktree)],
            env=self.environment, check=True, text=True, stdout=subprocess.PIPE,
        ).stdout)

    def populate_fixture(self, fixture: Path, derived: Path) -> None:
        """What `prepare` and `build` leave: owned fixture state and products."""
        fixture.mkdir(parents=True, exist_ok=True)
        (fixture / ".tron-ios-e2e-owned").write_text("tron.ios-e2e-state.v1\n")
        for name in ("state.env", "gateway.log", "npm-lock.sha256"):
            (fixture / name).write_text(name + "\n")
        for name in ("tron", "agent", "home", "results"):
            (fixture / name).mkdir(exist_ok=True)
        (derived / "Build/Products").mkdir(parents=True, exist_ok=True)
        (derived / ".tron-ios-e2e-owned").write_text("tron.ios-e2e-derived.v1\n")

    def built_products(self, identity: dict[str, object] | None) -> Path:
        """Focused products in the override DerivedData, stamped with `identity`."""
        derived = self.root / "e2e-derived"
        products = derived / "Build/Products"
        products.mkdir(parents=True)
        (derived / ".tron-ios-e2e-owned").write_text("tron.ios-e2e-derived.v1\n")
        (products / "Tron Development_UnitTests_iOS.xctestrun").write_text("xctestrun\n")
        if identity is not None:
            (derived / "build-identity.json").write_text(json.dumps(identity))
        return derived

    def runnable_products(self, worktree: Path = ROOT) -> Path:
        """One valid test target for exercising the actual E2E run path."""
        derived = self.built_products(self.source_identity(worktree))
        xctestrun = derived / "Build/Products/Tron Development_UnitTests_iOS.xctestrun"
        with xctestrun.open("wb") as handle:
            plistlib.dump({
                "TestConfigurations": [{
                    "IsEnabled": True,
                    # Xcode's real shape: the unit target omits IsUITestBundle (#497).
                    "TestTargets": [{"BlueprintName": "TronMobileTests"}],
                }],
            }, handle)
        return derived

    def assert_no_fixture_renewed(self) -> None:
        state = self.root / "e2e-state"
        for name in ("state.env", "gateway.pid", "proxy.pid", "gateway.log", "tron", "home"):
            self.assertFalse((state / name).exists(), f"run renewed {name} before refusing its products")

    def ui_environment(self, **extra: str) -> dict[str, str]:
        """The fixture plus the xcodebuild record every real-UI case reads.

        The synthetic `node`/`npm`/Gateway carry the fixture contract the UI lane
        consumes: the enrollment code, a canonical Gateway runtime log and a
        fault proxy that answers the evidence read. No journey runs, and the
        production Gateway is never built.
        """
        environment = self.readiness_node_environment(dict(self.environment))
        environment.update({
            "FAKE_XCODEBUILD_CALLS": str(self.root / "ui-calls.txt"),
            "FAKE_XCODEBUILD_LOG": str(self.root / "ui-xcodebuild.jsonl"),
        })
        # A fixture process inherits no case environment (#445): the two knobs its
        # fakes read become the files the generated sources read.
        for variable, knob in (("FAKE_E2E_GATEWAY_CONNECTIONS", "connection-counts"),
                               ("FAKE_E2E_PROXY_CONTROL_FAILURE", "proxy-control-failure"),
                               ("FAKE_E2E_PROXY_STARTUP_FAILURE", "proxy-startup-failure")):
            if variable in extra:
                self.fixture_knob(knob).write_text(extra.pop(variable) + "\n")
        environment.update(extra)
        return environment

    def xcodebuild_invocations(self, environment: dict[str, str]) -> list[dict[str, Any]]:
        path = Path(environment["FAKE_XCODEBUILD_LOG"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def journey_evidence(self, output: str) -> list[Path]:
        """The evidence directory each journey of a `run-ui` line reported."""
        return [
            Path(line.rsplit("evidence: ", 1)[1])
            for line in output.splitlines()
            if line.startswith("Real-UI journey ")
        ]

    def owned_ui_journeys(self) -> list[str]:
        return [
            "TronMobileUITests/RealGatewayPairAndChatUITests/testInvitationLinkPairsCompletesSetupStreamsAndReconnectsAfterBackground",
            "TronMobileUITests/RealGatewayPairAndChatUITests/testWrongPairingCodeLinkIsRefusedAndThenTheFixtureLinkPairs",
        ]

    def hosted_app_resets(self) -> list[str]:
        """The simctl calls that reset the lane's hosted app state."""
        try:
            lines = self.log_path.read_text().splitlines()
        except FileNotFoundError:
            return []
        return [line for line in lines if line.startswith("uninstall ")]

    def test_proxy_startup_failure_reports_process_status_and_stderr_tail(self) -> None:
        """Failure mode 26: proxy startup failure retains its actionable cause."""
        environment = self.ui_environment(FAKE_E2E_PROXY_STARTUP_FAILURE="1")
        result = self.e2e("prepare", environment=environment)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("owned fault proxy exited (exit code 42)", result.stderr)
        self.assertIn("fixture proxy startup failure evidence", result.stderr)

    def test_a_gateway_started_from_a_long_worktree_path_is_recognized_as_owned(self) -> None:
        """Failure mode 27: a ready fixture Gateway at a long path is still this command's."""
        harness = self.long_worktree() / "scripts/ios-gateway-e2e-test"
        environment = self.readiness_node_environment(dict(self.environment))
        try:
            result = self.e2e("prepare", harness=harness, environment=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            status = self.e2e("status", harness=harness, environment=environment)
            self.assertIn("Gateway: running", status.stdout)
        finally:
            self.e2e("stop", harness=harness, environment=environment)

    def test_a_start_that_fails_the_owned_command_proof_retires_its_gateway(self) -> None:
        """Failure mode 28: the Gateway a refused start spawned is not left running.

        The fixture Gateway records its own pid, and the knob makes its command line
        something other than the owned one, so the start's proof fails on that process.
        """
        environment = self.readiness_node_environment(dict(self.environment))
        self.fixture_knob("gateway-argv0").write_text("not-the-owned-gateway\n")
        record = Path(environment["TRON_NODE_BIN"]).parent / "record/gateway.pid"
        try:
            result = self.e2e("prepare", environment=environment)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("does not match its owned command", result.stderr)
            pid = int(record.read_text())
            self.assertFalse(self.process_alive(pid), f"the refused start left Gateway pid {pid} running")
        finally:
            # Nothing this case starts may outlive it, whatever the start did.
            self.e2e("stop", environment=environment)
            if record.exists():
                self.kill_if_alive(int(record.read_text()))

    def kill_if_alive(self, pid: int) -> None:
        if self.process_alive(pid):
            os.kill(pid, signal.SIGKILL)

    def process_alive(self, pid: int) -> bool:
        """Whether `pid` is running; a zombie has ended, its parent has not yet reaped it."""
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="], env=self.contained_environment(self.root),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ).stdout.strip() not in ("", "Z")

    def test_run_ui_builds_the_ui_plan_and_patches_the_ui_target(self) -> None:
        """Failure modes 17 and 18: the UI runner, not the hosted unit runner,
        receives the fixture environment, and the command runs its own journeys."""
        environment = self.ui_environment()
        result = self.e2e("run-ui", environment=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        invocations = self.xcodebuild_invocations(environment)
        self.assertEqual(
            [entry for entry in invocations if entry["action"] == "build"],
            [{"action": "build", "scheme": "Tron UI Validation", "test_plan": "UIValidation"}],
        )
        runs = [entry for entry in invocations if entry["action"] == "run"]
        self.assertEqual([entry["test_filter"] for entry in runs], self.owned_ui_journeys())
        for entry in runs:
            self.assertEqual(entry["targets"].get("TronMobileUITests"), XCTESTRUN_FIXTURE_KEYS)
            self.assertEqual(entry["targets"].get("TronMobileTests"), [], "the unit target must carry no fixture environment")

    def test_run_ui_leaves_one_complete_evidence_bundle_per_journey(self) -> None:
        """Failure mode 19: every journey leaves the xcresult, the Gateway log,
        the proxy link statistics, the XCTest summary, the final status and the
        source revision, with digests that match the bytes on disk."""
        environment = self.ui_environment()
        result = self.e2e("run-ui", environment=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        directories = self.journey_evidence(result.stdout)
        self.assertEqual(len(directories), 2, result.stdout)
        expected_artifacts = ["Journeys.xcresult", "gateway.jsonl", "proxy-link-stats.json", "summary.json"]
        source = self.source_identity()
        for directory, journey in zip(directories, self.owned_ui_journeys()):
            with self.subTest(journey=journey):
                for name in (*expected_artifacts, "report.json", "report.sha256"):
                    self.assertTrue((directory / name).exists(), f"missing {name} in {directory}")
                report = json.loads((directory / "report.json").read_text())
                self.assertEqual(report["journey"], journey)
                self.assertEqual(report["journey_status"], 0)
                self.assertTrue(report["evidence_complete"])
                self.assertEqual(report["source"]["revision"], source["revision"])
                self.assertEqual(report["source"]["dirty"], bool(source["dirty"]))
                self.assertEqual(
                    report["gateway_connections"],
                    {"opened": 2, "closed": 1, "retired_before_reconnect": True},
                )
                self.assertEqual(report["source"]["source_fingerprint"], source["source_fingerprint"])
                artifacts = {artifact["path"]: artifact for artifact in report["artifacts"]}
                self.assertEqual(sorted(artifacts), sorted(expected_artifacts))
                for name, artifact in artifacts.items():
                    self.assertRegex(artifact["sha256"], r"^[0-9a-f]{64}$")
                    self.assertIn(artifact["kind"], ("file-sha256", "tree-sha256"))
                for name in ("gateway.jsonl", "proxy-link-stats.json", "summary.json"):
                    self.assertEqual(
                        artifacts[name]["sha256"],
                        hashlib.sha256((directory / name).read_bytes()).hexdigest(),
                        f"the report's digest for {name} must describe the bytes it names",
                    )
                bundle = directory / "Journeys.xcresult"
                tree = hashlib.sha256()
                for path in sorted((item for item in bundle.rglob("*") if item.is_file()),
                                   key=lambda item: item.relative_to(bundle).as_posix()):
                    tree.update(path.relative_to(bundle).as_posix().encode() + b"\0"
                                + hashlib.sha256(path.read_bytes()).hexdigest().encode() + b"\n")
                self.assertEqual(artifacts["Journeys.xcresult"]["sha256"], tree.hexdigest())
                self.assertEqual(
                    (directory / "report.sha256").read_text().split()[0],
                    hashlib.sha256((directory / "report.json").read_bytes()).hexdigest(),
                )

    def test_run_ui_fails_when_a_journey_artifact_cannot_be_captured(self) -> None:
        """Failure mode 19: a journey whose evidence is incomplete cannot pass.

        The proxy refuses the harness's link-statistics read. The journey's own
        XCTest run passed, so the report must carry the overridden final status
        and mark the evidence incomplete, and the command must fail."""
        journey = self.owned_ui_journeys()[0]
        environment = self.ui_environment(FAKE_E2E_PROXY_CONTROL_FAILURE="1")
        result = self.e2e("run-ui", "--only-testing", journey, environment=environment)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cannot read the fixture fault proxy's link statistics", result.stderr)
        directories = self.journey_evidence(result.stdout)
        self.assertEqual(len(directories), 1, result.stdout)
        report = json.loads((directories[0] / "report.json").read_text())
        self.assertEqual(report["journey_status"], 1, "the report must carry the final status")
        self.assertFalse(report["evidence_complete"])
        missing = [artifact["path"] for artifact in report["artifacts"] if artifact["kind"] == "missing"]
        self.assertEqual(missing, ["proxy-link-stats.json"])
        self.assertTrue((directories[0] / "Journeys.xcresult").is_dir())

    def test_run_ui_refuses_a_journey_that_never_connected(self) -> None:
        """Failure mode 20: the journey that backgrounds the app must leave the
        Gateway's own record of its connections."""
        journey = self.owned_ui_journeys()[0]
        environment = self.ui_environment(FAKE_E2E_GATEWAY_CONNECTIONS="1 0")
        result = self.e2e("run-ui", "--only-testing", journey, environment=environment)
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertIn("must leave at least 2", result.stderr)
        directories = self.journey_evidence(result.stdout)
        self.assertEqual(len(directories), 1, result.stdout)
        report = json.loads((directories[0] / "report.json").read_text())
        self.assertEqual(report["journey_status"], 65)
        self.assertEqual(report["gateway_connections"]["opened"], 1)

    def test_run_ui_refuses_a_journey_whose_socket_was_never_retired(self) -> None:
        """Failure mode 20: connections that never retire are not a background
        reconnect, however many of them opened."""
        journey = self.owned_ui_journeys()[0]
        environment = self.ui_environment(FAKE_E2E_GATEWAY_CONNECTIONS="2 0")
        result = self.e2e("run-ui", "--only-testing", journey, environment=environment)
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertIn("no close before a different open", result.stderr)
        directories = self.journey_evidence(result.stdout)
        report = json.loads((directories[0] / "report.json").read_text())
        self.assertEqual(report["gateway_connections"]["opened"], 2)
        self.assertFalse(report["gateway_connections"]["retired_before_reconnect"])

    def test_run_ui_releases_its_lane_and_leaves_current_products(self) -> None:
        """Failure mode 21: the lane is released when the command ends, the
        fixture it renewed is stopped on success too, the products it built belong
        to this worktree's current source state, and the hosted app it paired is
        returned to its unpaired launch state."""
        environment = self.ui_environment()
        result = self.e2e("run-ui", environment=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        marker = json.loads((self.state / "simulator.json").read_text())
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        status = self.e2e("status", environment=environment)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn("Gateway: stopped", status.stdout, "a passing run-ui must not leave its fixture running")
        self.assertIn("Fault proxy: stopped", status.stdout)
        products = [line for line in status.stdout.splitlines() if line.startswith("UI test products: ")]
        self.assertEqual(len(products), 1, status.stdout)
        self.assertIn("built from this worktree's current source state", products[0])
        self.assertEqual(
            self.hosted_app_resets(),
            [f"uninstall {marker['udid']} com.tron.mobile.testhost"],
            "the command must return the lane's hosted app to its unpaired state",
        )

    def test_run_ui_refuses_a_skipped_journey_and_keeps_its_evidence(self) -> None:
        """Failure mode 17: a journey that cannot reach its fixture skips, which
        is not a passing cross-layer receipt. The selected journey still leaves
        the evidence a reviewer needs, and a failed run still returns the lane's
        hosted app to its unpaired state and stops its fixture (failure mode 21)."""
        journey = self.owned_ui_journeys()[0]
        environment = self.ui_environment(
            FAKE_SUMMARY=json.dumps({"passedTests": 0, "failedTests": 0, "skippedTests": 1, "totalTestCount": 1}),
        )
        result = self.e2e("run-ui", "--only-testing", journey, environment=environment)
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertIn("skipped, missing, or failed", result.stderr)
        self.assertEqual(
            [entry["test_filter"] for entry in self.xcodebuild_invocations(environment) if entry["action"] == "run"],
            [journey],
            "the selected journey must survive the lease holder's re-exec",
        )
        directories = self.journey_evidence(result.stdout)
        self.assertEqual(len(directories), 1, result.stdout)
        report = json.loads((directories[0] / "report.json").read_text())
        self.assertEqual(report["journey_status"], 65)
        self.assertEqual(report["journey"], journey)
        marker = json.loads((self.state / "simulator.json").read_text())
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        status = self.e2e("status", environment=environment)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn("Gateway: stopped", status.stdout)
        self.assertIn("Fault proxy: stopped", status.stdout)
        self.assertEqual(len(self.hosted_app_resets()), 1, "a failed run must still reset the hosted app")

    def test_only_testing_refuses_a_selector_run_ui_does_not_own(self) -> None:
        """The journeys are `run-ui`'s alone — a selector for anything else, a
        missing owner, or a selector on another command is refused before
        anything is leased, built or renewed."""
        class_owner = "TronMobileUITests/RealGatewayPairAndChatUITests"
        unsupported = self.e2e("run-ui", "--only-testing", class_owner, environment=self.environment)
        self.assertEqual(unsupported.returncode, 1, unsupported.stdout + unsupported.stderr)
        self.assertIn(f"{class_owner} is not a real-UI journey this command owns", unsupported.stderr)
        foreign = self.e2e("run-ui", "--only-testing", "TronMobileUITests/TronSmokeUITests/testSomething", environment=self.environment)
        self.assertEqual(foreign.returncode, 1, foreign.stdout + foreign.stderr)
        self.assertIn("is not a real-UI journey this command owns", foreign.stderr)
        refused = self.e2e("run", "--only-testing", self.owned_ui_journeys()[0], environment=self.environment)
        self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
        self.assertIn("--only-testing applies to run-ui", refused.stderr)
        missing = self.e2e("run-ui", "--only-testing", environment=self.environment)
        self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
        self.assertIn("--only-testing requires an owner", missing.stderr)
        self.assertFalse((self.state / "simulator.json").exists(), "a refused selection must not lease or boot a lane")
        self.assert_no_fixture_renewed()

    def test_each_worktree_owns_its_default_fixture_and_products(self) -> None:
        """Failure modes 7 and 8: default roots follow the worktree; overrides win."""
        environment = self.default_roots_environment()
        other = self.second_worktree()
        here = self.e2e("status", environment=environment)
        there = self.e2e("status", harness=other / "scripts/ios-gateway-e2e-test", environment=environment)
        self.assertEqual(here.returncode, 0, here.stderr)
        self.assertEqual(there.returncode, 0, there.stderr)

        temporary = Path(environment["TMPDIR"])
        for output, worktree in ((here.stdout, ROOT), (there.stdout, other)):
            key = self.worktree_key(worktree)
            for label in ("Fixture", "DerivedData"):
                path = self.reported(output, label)
                self.assertEqual(path.parent, temporary, output)
                self.assertTrue(path.name.endswith(f"-{os.getuid()}-{key}"), output)
        self.assertNotEqual(self.reported(here.stdout, "Fixture"), self.reported(there.stdout, "Fixture"))
        self.assertNotEqual(self.reported(here.stdout, "DerivedData"), self.reported(there.stdout, "DerivedData"))

        overridden = self.e2e("status")
        self.assertEqual(overridden.returncode, 0, overridden.stderr)
        self.assertEqual(self.reported(overridden.stdout, "Fixture"), self.root / "e2e-state")
        self.assertEqual(self.reported(overridden.stdout, "DerivedData"), self.root / "e2e-derived")

    def test_stop_and_clean_touch_only_this_worktrees_fixture(self) -> None:
        """Failure mode 11: another worktree's fixture and products survive."""
        environment = self.default_roots_environment()
        other_harness = self.second_worktree() / "scripts/ios-gateway-e2e-test"
        there = self.e2e("status", harness=other_harness, environment=environment)
        self.assertEqual(there.returncode, 0, there.stderr)
        other_fixture = self.reported(there.stdout, "Fixture")
        other_derived = self.reported(there.stdout, "DerivedData")
        self.populate_fixture(other_fixture, other_derived)
        here = self.e2e("status", environment=environment)
        self.assertEqual(here.returncode, 0, here.stderr)
        own_fixture = self.reported(here.stdout, "Fixture")
        own_derived = self.reported(here.stdout, "DerivedData")
        self.populate_fixture(own_fixture, own_derived)

        stopped = self.e2e("stop", environment=environment)
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        self.assertFalse((own_fixture / "state.env").exists())
        self.assertFalse((own_fixture / "home").exists())
        self.assertTrue((own_derived / "Build/Products").is_dir())

        cleaned = self.e2e("clean", environment=environment)
        self.assertEqual(cleaned.returncode, 0, cleaned.stderr)
        self.assertFalse(own_fixture.exists())
        self.assertFalse(own_derived.exists())

        for name in ("state.env", "gateway.log", "npm-lock.sha256", "tron", "agent", "home", "results"):
            self.assertTrue((other_fixture / name).exists(), f"another worktree lost {name}")
        self.assertTrue((other_derived / "Build/Products").is_dir())

    def test_an_e2e_build_stamps_its_products_with_this_worktrees_identity(self) -> None:
        """Failure mode 9: the products name the source that built them."""
        result = self.e2e("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        stamp = json.loads((self.root / "e2e-derived/build-identity.json").read_text())
        self.assertEqual(stamp, self.source_identity())

    def clean_runner_checkout(self) -> Path:
        """A minimal committed checkout with scripts/config/manifest but no Gateway build."""
        worktree = self.root / "clean-worktree"
        ignore = shutil.ignore_patterns("__pycache__")
        shutil.copytree(ROOT / "scripts", worktree / "scripts", ignore=ignore)
        shutil.copytree(ROOT / "config", worktree / "config", ignore=ignore)
        gateway = worktree / "packages/gateway"
        gateway.mkdir(parents=True)
        for name in ("package.json", "package-lock.json"):
            shutil.copy2(ROOT / "packages/gateway" / name, gateway / name)
        # The canonical Node pin is part of a checkout: the harness resolves the
        # fixture's Node from it.
        shutil.copy2(ROOT / ".node-version", worktree / ".node-version")
        # Installed dependencies are not source: the checkout ignores them the
        # way the repository does, so a case can install a node-pty tree without
        # changing this worktree's build identity.
        (worktree / ".gitignore").write_text("node_modules/\n")

        subprocess.run(["git", "init", "--quiet"], cwd=worktree, env=self.environment, check=True)
        subprocess.run(
            ["git", "add", ".gitignore", ".node-version", "scripts", "config", "packages/gateway"],
            cwd=worktree, env=self.environment, check=True,
        )
        subprocess.run([
            "git", "-c", "user.name=E2E fixture", "-c", "user.email=e2e-fixture@invalid",
            "commit", "--quiet", "-m", "runner fixture",
        ], cwd=worktree, env=self.environment, check=True)
        self.assertFalse((gateway / "dist").exists())
        self.assertFalse((gateway / "node_modules").exists())
        return worktree

    def test_case_setup_failure_stops_actual_e2e_path_and_cleans_fixture(self) -> None:
        """Failure mode 14: a setup failure cannot be masked by later passing XCTest cases.

        The first actual runner patch invocation fails once; the second would
        succeed, so a conditional-context callback would continue to Xcode and
        turn the setup failure green. The run path must preserve 37, invoke no
        test case, and clean the fixture and its owned simulator lane.
        """
        worktree = self.clean_runner_checkout()
        harness = worktree / "scripts/ios-gateway-e2e-test"
        derived = self.runnable_products(worktree)
        calls = self.root / "actual-xcodebuild-calls.txt"
        patch_calls = self.root / "patch-calls.txt"
        failed_once = self.root / "patch-failed-once"
        fake_bin = self.root / "fake-python-bin"
        fake_bin.mkdir()
        fake_python = fake_bin / "python3"
        fake_python.write_text("""#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == *patch-ios-gateway-e2e-xctestrun.py ]]; then
    printf '%s\\n' "$argument" >>"$FAKE_PATCH_CALLS"
    if [[ ! -e "$FAKE_PATCH_FAILED_ONCE" ]]; then
      : >"$FAKE_PATCH_FAILED_ONCE"
      exit 37
    fi
  fi
done
exec "$FAKE_SYSTEM_PYTHON" "$@"
""")
        fake_python.chmod(0o755)
        environment = dict(self.environment)
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        environment.update({
            "FAKE_SYSTEM_PYTHON": sys.executable,
            "FAKE_PATCH_CALLS": str(patch_calls),
            "FAKE_PATCH_FAILED_ONCE": str(failed_once),
            "FAKE_XCODEBUILD_CALLS": str(calls),
        })
        environment = self.readiness_node_environment(environment)

        try:
            result = self.e2e("run", harness=harness, environment=environment, timeout=120)
            self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
            self.assertEqual(len(patch_calls.read_text().splitlines()), 1)
            self.assertFalse(calls.exists(), result.stdout + result.stderr)
            status = self.e2e("status", harness=harness, environment=environment)
            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertIn("Gateway: stopped", status.stdout)
            self.assertIn("Fault proxy: stopped", status.stdout)
            lane_states = [device["state"] for devices in self.inventory().get("devices", {}).values() for device in devices]
            self.assertEqual(lane_states, ["Shutdown"])
            self.assertTrue((derived / "Build/Products/Tron Development_UnitTests_iOS.xctestrun").is_file())
        finally:
            self.e2e("stop", harness=harness, environment=environment)

    def test_first_failed_actual_case_without_bundle_stops_before_later_case(self) -> None:
        """Failure mode 13: an absent `.xcresult` cannot let a later pass mask failure."""
        worktree = self.clean_runner_checkout()
        harness = worktree / "scripts/ios-gateway-e2e-test"
        self.runnable_products(worktree)
        calls = self.root / "actual-xcodebuild-calls.txt"
        environment = self.readiness_node_environment(self.environment)
        environment.update({
            "FAKE_XCODEBUILD_CALLS": str(calls),
            "FAKE_XCODEBUILD_FIRST_TEST_EXIT": "37",
        })

        try:
            result = self.e2e("run", harness=harness, environment=environment, timeout=120)
            self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
            self.assertEqual(calls.read_text().splitlines(), [
                "TronMobileTests/RealGatewayPiBoundaryTests/testStreamsReconnectsAndSettlesExtensionTools",
            ])
            latest = self.root / "e2e-state/results/latest"
            self.assertTrue(latest.is_symlink())
            self.assertFalse((latest / "FocusedE2E.xcresult").exists())
        finally:
            self.e2e("stop", harness=harness, environment=environment)

    def test_nested_failure_messages_are_extracted_without_changing_status(self) -> None:
        """Failure mode 15: list children are visited and extraction preserves XCTest status."""
        worktree = self.clean_runner_checkout()
        harness = worktree / "scripts/ios-gateway-e2e-test"
        self.runnable_products(worktree)
        calls = self.root / "actual-xcodebuild-calls.txt"
        failures = self.root / "nested-test-results.json"
        failures.write_text(json.dumps({"testNodes": [{"children": [{"nodeType": "Failure Message", "name": "nested assertion detail"}]}]}))
        environment = self.readiness_node_environment(self.environment)
        environment.update({
            "FAKE_XCODEBUILD_CALLS": str(calls),
            "FAKE_XCODEBUILD_FIRST_TEST_EXIT": "37",
            "FAKE_XCODEBUILD_FIRST_TEST_BUNDLE": "1",
            "FAKE_TESTS_RESULT": str(failures),
        })

        try:
            result = self.e2e("run", harness=harness, environment=environment, timeout=120)
            self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
            self.assertIn("failure: nested assertion detail", result.stdout)
            self.assertEqual(calls.read_text().splitlines(), [
                "TronMobileTests/RealGatewayPiBoundaryTests/testStreamsReconnectsAndSettlesExtensionTools",
            ])
        finally:
            self.e2e("stop", harness=harness, environment=environment)

    def test_fixture_gateway_and_fault_proxy_never_inherit_the_callers_gateway_environment(self) -> None:
        """Failure modes 22 and 23: the parent Gateway's environment stops at the harness."""
        worktree = self.clean_runner_checkout()
        harness = worktree / "scripts/ios-gateway-e2e-test"
        self.runnable_products(worktree)
        environment = self.readiness_node_environment(self.environment)
        environment.update({
            "TRON_GATEWAY_RUNTIME_EPOCH": "stable-epoch-sentinel",
            "TRON_GATEWAY_CHANNEL": "stable",
            "TRON_GATEWAY_SUPERVISED": "1",
            "TRON_GATEWAY_PAYLOAD_ROOT": "/Users/someone/.tron/gateway/payloads/stable",
            "PI_SESSION_ID": "stable-session-sentinel",
        })

        try:
            result = self.e2e("run", harness=harness, environment=environment, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        finally:
            self.e2e("stop", harness=harness, environment=environment)

        for name in ("gateway.env", "proxy.env"):
            recorded = self.fixture_environment_record(environment, name)
            for inherited in ("TRON_GATEWAY_RUNTIME_EPOCH", "TRON_GATEWAY_CHANNEL", "TRON_GATEWAY_SUPERVISED",
                              "TRON_GATEWAY_PAYLOAD_ROOT", "PI_SESSION_ID"):
                self.assertNotIn(inherited, recorded, f"{name} inherited {inherited} from the caller")
        # The fixture's own binding survives the scrub, on both processes: it is
        # what the Gateway needs to own its home, state, agent directory and
        # listener, and what the proxy uses to restart it privately. Its `PATH` is
        # the resolved Node directory plus the system directories and nothing else
        # - not this shell's, and not this shell's PATH appended to it.
        gateway = self.fixture_environment_record(environment, "gateway.env")
        fixture_root = self.root / "e2e-state"
        fixture_path = f"{Path(environment['TRON_NODE_BIN']).parent}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        self.assertEqual(gateway.get("PATH"), fixture_path)
        self.assertEqual(gateway.get("TRON_GATEWAY_HOST"), "127.0.0.1")
        self.assertEqual(gateway.get("TRON_GATEWAY_LAN_ENDPOINT"), "off")
        self.assertEqual(gateway.get("TRON_MACHINE_GROUP_ID"), "tron-ios-e2e")
        self.assertRegex(gateway.get("TRON_GATEWAY_PORT", ""), r"^[1-9][0-9]*$")
        self.assertEqual(os.path.realpath(gateway["TRON_DATA_DIR"]), os.path.realpath(fixture_root / "tron"))
        self.assertEqual(os.path.realpath(gateway["HOME"]), os.path.realpath(fixture_root / "home"))
        self.assertEqual(os.path.realpath(gateway["PI_CODING_AGENT_DIR"]), os.path.realpath(fixture_root / "agent"))
        self.assertTrue(gateway["PI_SUBAGENTS_TEMP_ROOT"].startswith(str(gateway["HOME"])))
        # The fixture never needs the user's SSH agent either.
        self.assertNotIn("SSH_AUTH_SOCK", gateway)
        proxy = self.fixture_environment_record(environment, "proxy.env")
        self.assertEqual(proxy.get("PATH"), fixture_path)
        self.assertEqual(proxy.get("TRON_E2E_GATEWAY_ENTRY"), str(worktree / "packages/gateway/dist/index.js"))

    def test_the_first_node_on_the_callers_path_never_runs_the_fixture(self) -> None:
        """Failure mode 24: an inherited `PATH` cannot choose the fixture's Node.

        The wrapper below is the parent Gateway's bundled runtime in miniature:
        it answers the repository's pinned version and owns a sibling npm, so a
        version check alone would accept it, and it cannot run the fixture. The
        fixture's own Node is the pinned Node in nvm's layout, which is how a
        machine without `TRON_NODE_BIN` reaches it, so only a resolver that
        prefers the caller's `PATH` over the pinned toolchain would use it.
        """
        worktree = self.clean_runner_checkout()
        harness = worktree / "scripts/ios-gateway-e2e-test"
        self.runnable_products(worktree)
        environment = self.nvm_pinned_environment(self.environment)
        bundled = self.root / "bundled-runtime"
        bundled.mkdir()
        invoked = self.root / "bundled-runtime-invocations"
        for name, body in (("node", f'''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"{invoked}"
if [[ "${{1:-}}" == "--version" ]]; then echo "v{NODE_VERSION}"; exit 0; fi
echo "Failed to load native module: pty.node, checked: build/Release, build/Debug, prebuilds/darwin-arm64" >&2
exit 1
'''), ("npm", "#!/bin/sh\nexit 0\n")):
            (bundled / name).write_text(body)
            (bundled / name).chmod(0o755)
        environment["PATH"] = f"{bundled}:{environment['PATH']}"

        try:
            result = self.e2e("run", harness=harness, environment=environment, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if invoked.exists():
                self.fail("the fixture ran under the first node on the caller's PATH: " + invoked.read_text())
        finally:
            self.e2e("stop", harness=harness, environment=environment)

    def test_a_node_that_cannot_load_the_gateways_native_modules_is_refused_by_name(self) -> None:
        """Failure mode 25: the toolchain failure is named before the fixture starts.

        The Gateway's Node must load the installed node-pty prebuild. The prebuild
        here is not a native module, so the load fails the way the bundled
        runtime's Team ID fails it; the harness must report the loader's own error
        and start nothing.
        """
        worktree = self.clean_runner_checkout()
        harness = worktree / "scripts/ios-gateway-e2e-test"
        self.runnable_products(worktree)
        prebuild = worktree / "packages/gateway/node_modules/node-pty/build/Release/pty.node"
        prebuild.parent.mkdir(parents=True)
        prebuild.write_text("not a native module\n")
        environment = self.readiness_node_environment(self.environment)
        # The platform's own loader text (`dlopen` on macOS, `invalid ELF header`
        # on Linux), produced by the same Node and the same file.
        loader = subprocess.run(
            [environment["TRON_NODE_BIN"], "-e",
             "try { require(process.argv[1]); } catch (error) { process.stdout.write(String(error.message)); }",
             str(prebuild)],
            env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertTrue(
            loader.stdout.strip(),
            f"the fixture Node reported no loader error for {prebuild}: {loader.stderr}",
        )

        try:
            result = self.e2e("run", harness=harness, environment=environment, timeout=120)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("cannot load the Gateway's node-pty native module", result.stderr)
            self.assertIn(environment["TRON_NODE_BIN"], result.stderr)
            self.assertIn(str(prebuild), result.stderr)
            self.assertIn(loader.stdout.strip(), result.stderr, "the loader's own error is not what the harness reported")
        finally:
            self.e2e("stop", harness=harness, environment=environment)
        self.assertFalse((self.root / "e2e-state/gateway.pid").exists(), "the refused run started a fixture")
        self.assertFalse(
            (Path(environment["TRON_NODE_BIN"]).parent / "record/gateway.env").exists(),
            "the refusal still started the fixture Gateway",
        )

    def test_run_refuses_products_not_built_from_this_worktree(self) -> None:
        """Failure mode 10: every unproven product set is refused before the
        Gateway fixture is renewed."""
        foreign = self.source_identity()
        foreign["worktree"] = "/private/tmp/tron-foreign"
        foreign["worktree_key"] = "tron-foreign-0123456789ab"
        stale = self.source_identity()
        stale["revision"] = "0" * 40
        stale["source_fingerprint"] = "0" * 64
        cases = (
            (foreign, ["refusing to run", "/private/tmp/tron-foreign", str(ROOT)]),
            (stale, ["refusing to run", "revision 000000000"]),
            (None, ["carry no build identity"]),
        )
        for identity, expected in cases:
            with self.subTest(expected=expected[-1]):
                derived = self.built_products(identity)
                try:
                    result = self.e2e("run")
                    self.assertEqual(result.returncode, 1, result.stderr)
                    for text in expected:
                        self.assertIn(text, result.stderr)
                    self.assertIn("build", result.stderr.splitlines()[-1])
                    self.assert_no_fixture_renewed()
                    self.assertNotIn("boot", self.simctl_commands())
                finally:
                    shutil.rmtree(derived)

    def test_an_e2e_build_releases_its_lane_and_sweeps_orphans(self) -> None:
        """Failure modes 1, 2 and 3: the command ends with nothing of its own booted."""
        orphan = self.owned_lane("ios-test-orphan", UDID_A, device_name="Tron iOS Tests (orphan)")
        self.owned_lane("ios-test-held", UDID_B, device_name="Tron iOS Tests (held)")
        self.hold_lease(self.discovery_root / "ios-test-held", command="run")

        result = self.e2e("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = json.loads((self.state / "simulator.json").read_text())
        self.assertEqual(marker["worktree"], os.path.realpath(ROOT))
        self.assertEqual(marker["name"], "Tron iOS Tests")
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_B)["state"], "Booted")
        self.assertIn("Focused test products ready", result.stdout)
        self.assertIn("shut down", result.stdout)
        # Releasing is not removing: both lanes keep their markers and devices.
        self.assertTrue((orphan / "simulator.json").exists())
        self.assertTrue((self.state / "simulator.json").exists())
        self.assertTrue(self.present(marker["udid"]))
        self.assertEqual(self.simctl_commands().count("delete"), 0)

    def test_an_e2e_build_generates_with_the_xcodegen_the_tools_cache_names(self) -> None:
        """#113 failure modes 3 and 4: every XcodeGen the build resolves is the fixture's."""
        result = self.e2e("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        # The harness's own toolchain check, then the generator's check and run.
        self.assertEqual(self.xcodegen_calls(self.root), ["--version", "--version", "generate"])

    def test_an_e2e_build_the_mac_refuses_keeps_the_shared_exit(self) -> None:
        """Failure mode 4: the refusal stays 73 and nothing is booted or built."""
        self.reader_value("free-percent", "0")

        result = self.e2e("build")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("reserve", result.stderr)
        self.assertNotIn("boot", self.simctl_commands())
        self.assertFalse((self.root / "e2e-derived/Build/Products").exists())

    def test_clean_never_deletes_the_development_simulator(self) -> None:
        """Failure mode 6: a lane naming the Development simulator is refused."""
        self.development_marker.parent.mkdir(parents=True, exist_ok=True)
        self.development_marker.write_text(UDID_A + "\n")
        self.owned_lane("ios-test", UDID_A)

        result = self.e2e("clean")
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("Development simulator", result.stderr)
        self.assertTrue(self.present(UDID_A))
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")
        self.assertEqual(self.simctl_commands().count("delete"), 0)
        self.assertEqual(self.shutdown_targets(), [])

    def test_removed_build_gate_directory_releases_the_e2e_command(self) -> None:
        """#128: the E2E fixture's other fake build gate cannot wait forever."""
        directory = self.root / "build-gates"
        directory.mkdir()
        gate = directory / "open"
        command = subprocess.Popen(
            [str(E2E), "build"], env={**self.environment, "FAKE_BUILD_GATE": str(gate)},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            products = self.root / "e2e-derived/Build/Products/Tron Development_UnitTests_iOS.xctestrun"
            deadline = time.monotonic() + 30
            while not products.exists() and time.monotonic() < deadline and command.poll() is None:
                time.sleep(0.05)
            self.assertTrue(products.exists(), "fake E2E build never reached its gate")
            shutil.rmtree(directory)
            _, stderr = command.communicate(timeout=5)
            self.assertNotEqual(command.returncode, 0, stderr)
        finally:
            # Opening the gate also retires the known-bad control's descendants.
            directory.mkdir(exist_ok=True)
            gate.write_text("go\n")
            if command.poll() is None:
                command.kill()
            command.communicate(timeout=30)
            self.close_pipes(command)

    def test_a_killed_e2e_build_leaves_its_lane_to_the_next_sweep(self) -> None:
        """Failure mode 5: a crash leaves the lane booted and any tool reclaims it."""
        gate = self.root / "build-gate"
        environment = {**self.environment, "FAKE_BUILD_GATE": str(gate)}
        command = subprocess.Popen(
            [str(E2E), "build"], env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            udid = self.wait_until_lane_booted(self.state / "simulator.json")
            # Kill the lease holder: its release never runs, exactly as after a
            # crash, while the command it started finishes and exits.
            command.kill()
            gate.write_text("go\n")
            _, stderr = command.communicate(timeout=60)
            self.assertEqual(command.returncode, -signal.SIGKILL, stderr)
            self.assertEqual(self.device_entry(udid)["state"], "Booted")

            # Any Tron test tool reclaims it through the same sweep.
            result = self.reap()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("shut down", result.stdout)
            self.assertEqual(self.device_entry(udid)["state"], "Shutdown")
        finally:
            if command.poll() is None:
                command.kill()
                command.wait(timeout=30)
            self.close_pipes(command)


class InheritedLeaseFixture(LifecycleHarness, unittest.TestCase):
    """W-34 (issue #126): every lane tool honours the lease it inherits, and
    `clean` leaves no lane directory behind.

    Failure modes these cases target, written before the code:

    1. The Gateway E2E harness or the profiler, started by a descendant of a
       leased command (so it inherits `TRON_IOS_TEST_LOCK_HELD`) and naming a
       lane that lease does not cover, provisions, boots or deletes that lane's
       simulator while holding no lease on it, because it only skips taking a
       lease it inherits.
    2. Their refusal differs from the runner's - another exit status or another
       message - so a caller that handles the runner's refusal (74) mistakes
       theirs for a test or destination failure; a copied check also drifts
       from the runner's (it compares spellings, or accepts no inherited lease).
    3. `clean` deletes the lane's simulator and marker but leaves the lane
       directory holding only its lease file, which no sweep reclaims because
       the sweep removes only marker-owned state.
    4. Removing that directory takes something that is not the emptied lane's
       own lease: a file or a nested lane inside it, or a lease file a command
       that started in the lane meanwhile created and holds, so two commands
       would hold the lane at once.
    5. A lane whose directory `clean` removed cannot be used again.
    6. A command opens the lane's lease file just before another holder
       unlinks it (the holder of `clean`, or `lane-remove`), locks the unlinked
       file, and runs - or removes the lane - while a command that recreated
       the lease file holds the lane too: two owners of one simulator, and the
       inherited-lease check cannot tell, because the path still names a lease.
    7. A command refused for the lease it inherited leaves the directory of the
       lane it named behind, empty and marker-less, where no sweep reclaims it.
    """

    REFUSAL = "error: this command names lane "

    def setUp(self) -> None:
        super().setUp()
        self.install_fake_xcodebuild()
        self.environment = {
            **self.environment,
            **self.install_synthetic_xcodegen(self.root),
            "TRON_IOS_E2E_STATE_DIR": str(self.root / "e2e-state"),
            "TRON_IOS_E2E_DERIVED_DATA": str(self.root / "e2e-derived"),
            "TRON_PROFILE_IOS_DERIVED_DATA": str(self.root / "profile-derived"),
            "TRON_PROFILE_RESULTS_DIR": str(self.root / "profile-results"),
        }
        for inherited in ("TRON_IOS_TEST_LOCK_HELD", "TRON_IOS_TEST_LEASE_FD", "TRON_IOS_TEST_LEASE_LOCK"):
            self.environment.pop(inherited, None)

    def tool(self, tool: Path, *arguments: str, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(tool), *arguments], env=environment or self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
        )

    def refusal(self, result: subprocess.CompletedProcess[str]) -> str:
        lines = [line for line in result.stderr.splitlines() if line.startswith(self.REFUSAL)]
        self.assertEqual(len(lines), 1, result.stderr)
        return lines[0]

    def test_every_lane_tool_refuses_an_inherited_lease_for_another_lane_as_the_runner_does(self) -> None:
        """Failure modes 1 and 2: one refusal, 74, before any simulator is touched."""
        other = self.discovery_root / "ios-test-other/lease.lock"
        commands = (
            (RUNNER, ("run", "--only-testing", "TronMobileTests/StubTests")),
            (E2E, ("build",)),
            (E2E, ("clean",)),
            (PROFILER, ("--scenario", "control", "--no-build")),
        )
        for inherited in ({"TRON_IOS_TEST_LEASE_LOCK": str(other)}, {}):
            environment = {**self.environment, "TRON_IOS_TEST_LOCK_HELD": "1", **inherited}
            refusals: dict[str, str] = {}
            for tool, arguments in commands:
                with self.subTest(tool=tool.name, arguments=arguments, inherited=inherited):
                    # Each case starts from both lanes intact, so a tool that
                    # fails to refuse is the one reported, not the cases after it.
                    self.owned_lane("ios-test", UDID_A)
                    self.owned_lane("ios-test-other", UDID_B, device_name="Tron iOS Tests (other)")
                    other.write_text("")
                    self.log_path.unlink(missing_ok=True)
                    result = self.tool(tool, *arguments, environment=environment)
                    self.assertEqual(result.returncode, 74, result.stderr)
                    line = self.refusal(result)
                    self.assertIn(str(self.state / "lease.lock"), line)
                    self.assertIn(str(other) if inherited else "covers no lane", line)
                    refusals[f"{tool.name} {arguments[0]}"] = line
                    self.assertEqual(self.simctl_commands(), [])
                    self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")
                    self.assertEqual(self.device_entry(UDID_B)["state"], "Booted")
                    self.assertTrue((self.state / "simulator.json").exists())
                    self.assertFalse((self.root / "e2e-derived/Build/Products").exists())
            self.assertEqual(len(set(refusals.values())), 1, refusals)

    def test_a_refused_command_leaves_no_directory_for_the_lane_it_named(self) -> None:
        """Failure mode 7: the refusal comes before the lane directory is made."""
        other = self.owned_lane("ios-test-other", UDID_B, device_name="Tron iOS Tests (other)") / "lease.lock"
        other.write_text("")
        environment = {
            **self.environment, "TRON_IOS_TEST_STATE_DIR": "",
            "TRON_IOS_TEST_LOCK_HELD": "1", "TRON_IOS_TEST_LEASE_LOCK": str(other),
        }
        for index, (tool, arguments) in enumerate((
            (RUNNER, ("run", "--only-testing", "TronMobileTests/StubTests")),
            (E2E, ("build",)),
            (E2E, ("clean",)),
            (PROFILER, ("--scenario", "control", "--no-build")),
        )):
            with self.subTest(tool=tool.name, arguments=arguments):
                # A lane of its own per case: a directory one tool leaves
                # behind is never charged to the next.
                fresh = self.discovery_root / f"ios-test-fresh{index}"
                result = self.tool(tool, *arguments, "--lane", f"fresh{index}", environment=environment)
                self.assertEqual(result.returncode, 74, result.stderr)
                self.assertIn(str(fresh / "lease.lock"), self.refusal(result))
                self.assertFalse(fresh.exists())

    def test_clean_removes_the_lane_directory_it_emptied_and_the_lane_is_usable_again(self) -> None:
        """Failure modes 3 and 5: nothing of the lane survives `clean` in either tool."""
        for tool, name in ((RUNNER, "alpha"), (E2E, "beta")):
            with self.subTest(tool=tool.name):
                environment = {**self.environment, "TRON_IOS_TEST_STATE_DIR": ""}
                udid = UDID_C if name == "alpha" else UDID_D
                lane = self.owned_lane(f"ios-test-{name}", udid, device_name=f"Tron iOS Tests ({name})")

                cleaned = self.tool(tool, "clean", "--lane", name, environment=environment)
                self.assertEqual(cleaned.returncode, 0, cleaned.stderr)
                self.assertFalse(lane.exists(), sorted(path.name for path in lane.iterdir()) if lane.exists() else None)
                self.assertFalse(self.present(udid))

                again = self.tool(E2E, "build", "--lane", name, environment=environment)
                self.assertEqual(again.returncode, 0, again.stderr)
                marker = json.loads((lane / "simulator.json").read_text())
                self.assertEqual(marker["name"], f"Tron iOS Tests ({name})")
                self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")

    def test_clean_keeps_a_lane_directory_that_holds_more_than_its_lease(self) -> None:
        """Failure mode 4: only a directory holding nothing but the lease goes."""
        notes = self.state / "notes.txt"
        nested = self.discovery_root / "ios-test/ios-test-inner"
        for tool in (RUNNER, E2E):
            for kept in ("a file", "a nested lane"):
                with self.subTest(tool=tool.name, kept=kept):
                    self.owned_lane("ios-test", UDID_A)
                    if kept == "a file":
                        notes.write_text("not the tooling's\n")
                    else:
                        self.owned_lane("ios-test/ios-test-inner", UDID_B, device_name="Tron iOS Tests (inner)")
                    result = self.tool(tool, "clean")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse((self.state / "simulator.json").exists())
                    self.assertTrue((self.state / "lease.lock").exists())
                    if kept == "a file":
                        self.assertEqual(notes.read_text(), "not the tooling's\n")
                        notes.unlink()
                    else:
                        self.assertTrue((nested / "simulator.json").exists())
                        self.assertTrue(self.present(UDID_B))
                        shutil.rmtree(nested)

    def test_a_lease_file_another_command_now_holds_is_never_removed(self) -> None:
        """Failure mode 4: the emptied lane's own lease, and no one else's, is removed."""
        lane = self.discovery_root / "ios-test-race"
        lane.mkdir()
        removed, go = self.root / "removed", self.root / "go"
        # The command loses the lane's lease file, and a command that starts in
        # the lane meanwhile creates a new one and holds it.
        holder = subprocess.Popen(
            [
                sys.executable, str(LOCK), "--lock", str(lane / "lease.lock"),
                "--marker", str(lane / "simulator.json"),
                "--development-state", str(self.development_marker), "--remove-empty-lane", "--",
                "/bin/sh", "-c", 'rm -f "$1/lease.lock"; echo removed >"$2"; while [ ! -e "$3" ]; do sleep 0.05; done',
                "sh", str(lane), str(removed), str(go),
            ],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.wait_for(removed)
            self.hold_lease(lane, command="run")
            go.write_text("go\n")
            _, stderr = holder.communicate(timeout=60)
            self.assertEqual(holder.returncode, 0, stderr)
            self.assertTrue(self.lock_holder(lane / "lease.lock"))
            self.assertIn('"command": "run"', (lane / "lease.lock").read_text())
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.wait(timeout=30)
            self.close_pipes(holder)

    # Runs one owner as a real process, but replaces the lease file between the
    # owner's open and its lock, as a holder that unlinks it and a command that
    # recreates and holds it would; no timing of real processes can pin that
    # interleaving down.
    LEASE_RACE = """
import fcntl, os, runpy, sys
script, lock = sys.argv[1], sys.argv[2]
take = fcntl.flock
kept = []
def flock(descriptor, operation):
    if operation & fcntl.LOCK_EX and not kept and os.path.exists(lock):
        opened, named = os.fstat(descriptor), os.stat(lock)
        if (opened.st_dev, opened.st_ino) == (named.st_dev, named.st_ino):
            os.unlink(lock)
            kept.append(open(lock, "a+"))
            take(kept[0].fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    return take(descriptor, operation)
fcntl.flock = flock
sys.argv = [script, *sys.argv[3:]]
runpy.run_path(script, run_name="__main__")
"""

    def raced(self, script: Path, lock: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-c", self.LEASE_RACE, str(script), str(lock), *arguments],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )

    def test_a_command_that_locked_an_unlinked_lease_file_never_runs(self) -> None:
        """Failure mode 6: the lease taken is the file the lane's path names."""
        lane = self.discovery_root / "ios-test-race"
        lane.mkdir()
        ran = self.root / "ran"
        result = self.raced(
            LOCK, lane / "lease.lock", "--lock", str(lane / "lease.lock"), "--",
            "/bin/sh", "-c", 'echo ran >"$1"', "sh", str(ran),
        )
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("already leased", result.stderr)
        self.assertFalse(ran.exists())

    def test_lane_removal_that_locked_an_unlinked_lease_file_removes_nothing(self) -> None:
        """Failure mode 6: the lane's owner takes its own leases the same way."""
        lane = self.owned_lane("ios-test-alpha", UDID_A)
        (lane / "lease.lock").write_text("")
        result = self.raced(
            SIMULATOR, lane / "lease.lock", "lane-remove", "--lane-dir", str(lane),
            "--discovery-root", str(self.discovery_root), "--default-state-dir", str(self.state),
            "--development-state", str(self.development_marker),
        )
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertTrue((lane / "simulator.json").exists())
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")


class AbandonedLaneFixture(LaneHarness, unittest.TestCase):
    """Issue #141: marker-less lane directories, and a lane removed mid-take.

    Failure modes these cases target, written on the issue before the code:

    1. A lane directory removed (by `clean`'s holder or the sweep) between the
       holder's mkdir and its chmod kills the holder with a traceback instead
       of the contended exit (73) and its message.
    2. The same, removed between the chmod and the lease file's open.
    3. The holder runs its command anyway after that removal - recreating the
       directory - so two commands could own one lane.
    4. The sweep's own lease take on a lane another remover just deleted
       raises, or recreates the directory and leaves a marker-less one behind.
    5. A marker-less lane directory holding only its idle lease file is never
       reclaimed.
    6. Reclaiming removes what is not an abandoned lane: a directory holding
       any other file or a nested lane, one not named like a lane, a symlinked
       directory or lease file.
    7. Reclaiming removes a lane a live command holds before its marker exists.
    8. A reclaimed lane cannot be leased and used again.
    """

    # Removes the lane directory at one point of a real process's take, as
    # `clean`'s holder or the sweep would; no timing of real processes can pin
    # that interleaving down. `chmod` follows the holder's mkdir and precedes
    # its open; a lease take's mkdir or open is the sweep's first touch.
    DIRECTORY_RACE = """
import os, pathlib, runpy, shutil, sys
script, lane, point = sys.argv[1], sys.argv[2], sys.argv[3]
done = []
def remove():
    if not done and os.path.isdir(lane):
        done.append(True)
        shutil.rmtree(lane)
if point in ("before-chmod", "after-chmod"):
    chmod = os.chmod
    def raced_chmod(path, mode, *rest, **named):
        if str(path) != lane:
            return chmod(path, mode, *rest, **named)
        if point == "before-chmod":
            remove()
        result = chmod(path, mode, *rest, **named)
        remove()
        return result
    os.chmod = raced_chmod
else:
    mkdir, open_ = pathlib.Path.mkdir, pathlib.Path.open
    def raced_mkdir(self, *rest, **named):
        if str(self) == lane:
            remove()
        return mkdir(self, *rest, **named)
    def raced_open(self, *rest, **named):
        if str(self) == os.path.join(lane, "lease.lock"):
            remove()
        return open_(self, *rest, **named)
    pathlib.Path.mkdir, pathlib.Path.open = raced_mkdir, raced_open
sys.argv = [script, *sys.argv[4:]]
runpy.run_path(script, run_name="__main__")
"""

    def raced(self, script: Path, lane: Path, point: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-c", self.DIRECTORY_RACE, str(script), str(lane), point, *arguments],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )

    def test_a_holder_whose_lane_directory_is_removed_mid_take_fails_as_contended(self) -> None:
        """Failure modes 1, 2 and 3: 73 and the contended message, and nothing runs."""
        for point in ("before-chmod", "after-chmod"):
            with self.subTest(point=point):
                lane = self.discovery_root / f"ios-test-{point}"
                ran = self.root / f"ran-{point}"
                result = self.raced(
                    LOCK, lane, point, "--lock", str(lane / "lease.lock"), "--",
                    "/bin/sh", "-c", 'echo ran >"$1"', "sh", str(ran),
                )
                self.assertEqual(result.returncode, 73, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn(
                    f"error: iOS test simulator is already leased (its lease file {lane / 'lease.lock'} "
                    "was removed or replaced while this command took it)",
                    result.stderr,
                )
                self.assertFalse(ran.exists())
                self.assertFalse(lane.exists())

    def test_the_sweep_skips_a_lane_another_remover_deleted_and_leaves_no_directory(self) -> None:
        """Failure mode 4: the sweep's lease take never recreates a removed lane."""
        old = time.time() - 8 * 24 * 3600
        lane = self.owned_lane("ios-test-gone", UDID_A, worktree=str(self.root / "gone-worktree"), last_used=old)
        result = self.raced(
            SIMULATOR, lane, "lease-take", "sweep", "--discovery-root", str(self.discovery_root),
            "--default-state-dir", str(self.state), "--development-state", str(self.development_marker),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        # A take that recreated the lane would leave a lease-only directory for
        # the same sweep's reclaim to remove, hiding the bug behind `exists`.
        self.assertNotIn("removed abandoned lane", result.stdout)
        self.assertFalse(lane.exists())

    def test_the_sweep_reclaims_only_marker_less_lanes_holding_nothing_but_an_idle_lease(self) -> None:
        """Failure modes 5, 6, 7 and 8, through `reap`."""
        def lane(name: str, lease: str = "") -> Path:
            directory = self.discovery_root / name
            directory.mkdir(parents=True)
            (directory / "lease.lock").write_text(lease)
            return directory

        abandoned = lane("ios-test-abandoned")
        # A holder killed outright leaves its metadata, naming a dead pid.
        stale = lane("ios-test-stale", json.dumps({"schema": "tron.ios-test-lock.v1", "pid": 999999}))
        held = lane("ios-test-held")
        self.hold_lease(held, command="run")
        notes = lane("ios-test-notes")
        (notes / "notes.txt").write_text("not the tooling's\n")
        inner = lane("ios-test-outer/ios-test-inner")
        unnamed = lane("ios-e2e-other")
        # The lane prefix, but no lane name can follow it with a dot.
        dotted = lane("ios-test-.hidden")
        target = lane("elsewhere")
        (self.discovery_root / "ios-test-directory-link").symlink_to(target)
        lease_link = self.discovery_root / "ios-test-lease-link"
        lease_link.mkdir()
        (lease_link / "lease.lock").symlink_to(target / "lease.lock")
        # A command that has made its lane directory but not yet opened its lease.
        starting = self.discovery_root / "ios-test-starting"
        starting.mkdir()

        result = self.reap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(abandoned.exists())
        self.assertFalse(stale.exists())
        self.assertIn(f"removed abandoned lane abandoned ({abandoned})", result.stdout)
        self.assertTrue(self.lock_holder(held / "lease.lock"))
        self.assertIn('"command": "run"', (held / "lease.lock").read_text())
        self.assertEqual(notes.joinpath("notes.txt").read_text(), "not the tooling's\n")
        for kept in (inner / "lease.lock", unnamed / "lease.lock", dotted / "lease.lock", target / "lease.lock", lease_link / "lease.lock", starting):
            self.assertTrue(os.path.lexists(kept), kept)
        self.assertTrue((self.discovery_root / "ios-test-directory-link").is_symlink())

        again = self.reap()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn("removed abandoned lane", again.stdout)

        reused = subprocess.run(
            [sys.executable, str(LOCK), "--lock", str(abandoned / "lease.lock"), "--", "/bin/sh", "-c", "exit 0"],
            env=self.environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )
        self.assertEqual(reused.returncode, 0, reused.stderr)
        self.assertTrue((abandoned / "lease.lock").exists())


class WorktreeLaneFixture(LifecycleHarness, unittest.TestCase):
    """W-17 (issue #99): each worktree defaults to a lane of its own.

    The cases run the three tools from real git checkouts - a primary checkout
    and linked worktrees of it - with no lane selected and no pre-lane
    override, so every lane path is the tools' own default under the fixture's
    HOME.

    Failure modes these cases target, written before the code:

    1. A command in a linked worktree that selects no lane uses the shared
       default lane and its one lease, so a second worktree's run is refused
       (73) while the first runs instead of running beside it.
    2. The primary checkout stops using the default lane (`ios-test`, device
       `Tron iOS Tests`) every existing caller and existing lane already name.
    3. The worktree-derived lane replaces an explicit choice: `--lane NAME`,
       `TRON_IOS_TEST_LANE`, `--lane default`, or the pre-lane
       `TRON_IOS_TEST_STATE_DIR` that CI and profiling lanes set.
    4. The profiler or the Gateway E2E harness selects a different lane than
       the runner for the same worktree and selection - or cannot select one -
       so it leases and releases a lane the runner does not use.
    5. A worktree's lane is not attributed to its worktree in `status --all`,
       or idle-lane expiry never removes it, so per-worktree lanes accumulate.
    6. A worktree whose directory name starts with `.`, `-` or `_` derives a
       lane name the lane validator refuses, so every command there fails.
    7. A deleted worktree's lane - a simulator of gigabytes - outlives its
       worktree for the whole idle period, because only idle expiry removes a
       lane; or the removal that closes this takes a lane that is not the
       deleted worktree's to lose: the default lane (whose marker may name a
       deleted worktree that created it), a lane whose worktree still exists,
       or a lane a live command holds.
    8. A read-only command (`help`, `status`) in a linked worktree creates that
       worktree's lane directory, which holds no ownership marker, so no sweep
       ever reclaims it.
    9. W-21 (issue #101): `status` names another worktree's or another lane's
       run as this worktree's latest run - one `latest` link in the shared
       results root followed whichever run finished last anywhere - or names an
       older run of this worktree and lane instead of its newest.
    """

    def setUp(self) -> None:
        super().setUp()
        self.install_fake_xcodebuild()
        # The pinned XcodeGen, found first through TRON_CI_TOOLS_DIR, so the E2E
        # build's project generation touches no real checkout.
        self.synthetic_stub(self.bin / "xcodegen", "print('Version: 2.45.3')\n")
        presets = self.root / "share/xcodegen/SettingPresets"
        (presets / "Platforms").mkdir(parents=True)
        for preset in ("base.yml", "Platforms/iOS.yml", "Platforms/macOS.yml"):
            (presets / preset).write_text("preset\n")
        self.environment = {
            **self.environment,
            "TRON_CI_TOOLS_DIR": str(self.root),
            "TRON_PROFILE_IOS_DERIVED_DATA": str(self.root / "profile-derived"),
            "TRON_PROFILE_RESULTS_DIR": str(self.root / "profile-results"),
        }
        # No lane and no pre-lane override: the tools derive every lane path.
        self.environment.pop("TRON_IOS_TEST_STATE_DIR")
        self.environment.pop("TRON_IOS_TEST_DISCOVERY_ROOT")
        self.lane_root = self.home / ".tron/internal"
        self.primary = self.root / "checkout"
        ignore = shutil.ignore_patterns("__pycache__")
        for relative in ("scripts", "config", ".github/workflows"):
            shutil.copytree(ROOT / relative, self.primary / relative, ignore=ignore)
        shutil.copy2(ROOT / ".node-version", self.primary / ".node-version")
        self.git(self.primary, "init", "-q")
        self.git(self.primary, "add", "-A")
        self.git(self.primary, "-c", "user.name=Tron Tests", "-c", "user.email=tests@tron.invalid",
                 "commit", "-q", "-m", "checkout")
        self.checkout_tree(self.primary)

    def git(self, worktree: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(worktree), *arguments], env=self.environment,
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()

    def checkout_tree(self, worktree: Path) -> None:
        # Untracked and empty, so it changes no source identity; the E2E build's
        # project generation runs inside it.
        (worktree / "packages/ios-app").mkdir(parents=True)

    def linked(self, name: str) -> Path:
        worktree = self.root / name
        self.git(self.primary, "worktree", "add", "-q", "--detach", str(worktree))
        self.checkout_tree(worktree)
        return worktree

    def key(self, worktree: Path) -> str:
        return subprocess.run(
            [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(worktree)],
            env=self.environment, check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()

    def tool(
        self, worktree: Path, name: str, *arguments: str, environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(worktree / "scripts" / name), *arguments], env=environment or self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
        )

    def stamp_products(self, worktree: Path) -> None:
        """This worktree's runner products, built from its current source."""
        derived = self.home / "Library/Developer/Tron/ios/test-derived-data" / self.key(worktree)
        (derived / "Build/Products").mkdir(parents=True)
        (derived / ".tron-ios-test-owned").write_text("tron.ios-test-owned.v1\n")
        identity = subprocess.run(
            [sys.executable, str(IDENTITY), "show", "--worktree", str(worktree)],
            env=self.environment, check=True, text=True, stdout=subprocess.PIPE,
        ).stdout
        subprocess.run(
            [sys.executable, str(IDENTITY), "write", "--worktree", str(worktree), "--derived-data", str(derived)],
            env=self.environment, check=True, text=True, input=identity,
        )

    def focused_run(self, worktree: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return self.tool(worktree, "tron-ios-test", "run", *arguments, "--only-testing", "TronMobileTests/StubTests")

    def completed_run(self, result: subprocess.CompletedProcess[str]) -> Path:
        """The run directory a successful runner command announced."""
        prefix = "iOS test run complete: "
        for line in result.stdout.splitlines():
            if line.startswith(prefix):
                return Path(line[len(prefix):])
        raise AssertionError(f"no completed run in:\n{result.stdout}")

    def reported_latest(self, worktree: Path, *arguments: str) -> str:
        """What `status` in a worktree names as its latest run."""
        status = self.tool(worktree, "tron-ios-test", "status", *arguments)
        self.assertEqual(status.returncode, 0, status.stderr)
        prefix = "Latest run: "
        for line in status.stdout.splitlines():
            if line.startswith(prefix):
                return line[len(prefix):]
        raise AssertionError(f"no latest run in:\n{status.stdout}")

    def lane_marker(self, lane: Path) -> dict[str, object]:
        return json.loads((lane / "simulator.json").read_text())

    def assert_booted_only(self, udid: object) -> None:
        """Every boot so far targeted `udid`, and nothing is left booted."""
        boots = {line.split(" ")[1] for line in self.log_path.read_text().splitlines() if line.startswith("boot ")}
        self.assertEqual(boots, {udid})
        booted = [device["udid"] for devices in self.inventory()["devices"].values()
                  for device in devices if device["state"] == "Booted"]
        self.assertEqual(booted, [])

    def assert_default_lane_untouched(self) -> None:
        default = self.lane_root / "ios-test"
        self.assertFalse((default / "simulator.json").exists())
        self.assertFalse((default / "lease.lock").exists())

    def test_each_linked_worktree_runs_in_its_own_lane_beside_the_other(self) -> None:
        """Failure mode 1: a busy worktree lane never refuses another worktree."""
        first, second = self.linked("first-worktree"), self.linked("second-worktree")
        self.stamp_products(first)
        self.stamp_products(second)
        first_lane = self.lane_root / f"ios-test-{self.key(first)}"
        first_lane.mkdir(parents=True)
        # The first worktree's run is in flight: its lane's lease is held.
        self.hold_lease(first_lane, command="run")

        second_run = self.focused_run(second)
        self.assertEqual(second_run.returncode, 0, second_run.stderr)
        second_key = self.key(second)
        marker = self.lane_marker(self.lane_root / f"ios-test-{second_key}")
        self.assertEqual(marker["worktree"], os.path.realpath(second))
        self.assertEqual(marker["name"], f"Tron iOS Tests ({second_key})")
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        owner = json.loads((self.completed_run(second_run) / "owner.json").read_text())
        self.assertEqual(owner["lane"], second_key)

        # The first worktree's own default is the lane its in-flight run holds.
        first_run = self.focused_run(first)
        self.assertEqual(first_run.returncode, 73, first_run.stderr)
        self.assert_default_lane_untouched()

    def test_the_primary_checkout_keeps_the_default_lane(self) -> None:
        """Failure mode 2: the primary checkout's lane is the one it always was."""
        self.stamp_products(self.primary)
        result = self.focused_run(self.primary)
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.lane_marker(self.lane_root / "ios-test")
        self.assertEqual(marker["name"], "Tron iOS Tests")
        self.assertEqual(marker["worktree"], os.path.realpath(self.primary))
        self.assertEqual(self.device_entry(marker["udid"])["state"], "Shutdown")
        self.assertEqual(sorted(path.name for path in self.lane_root.iterdir() if path.name.startswith("ios-test")),
                         ["ios-test"])

    def test_an_explicit_lane_wins_over_the_worktree_default(self) -> None:
        """Failure mode 3: the derived lane is only the default."""
        worktree = self.linked("explicit-worktree")
        key = self.key(worktree)
        ci_state = self.root / "ci-state"
        cases = (
            ((), {}, f"{key} ({self.lane_root}/ios-test-{key})"),
            (("--lane", "default"), {}, f"default ({self.lane_root}/ios-test)"),
            (("--lane", "alpha"), {}, f"alpha ({self.lane_root}/ios-test-alpha)"),
            ((), {"TRON_IOS_TEST_LANE": "alpha"}, f"alpha ({self.lane_root}/ios-test-alpha)"),
            ((), {"TRON_IOS_TEST_STATE_DIR": str(ci_state)}, f"default ({ci_state})"),
        )
        for arguments, override, lane in cases:
            with self.subTest(arguments=arguments, override=override):
                result = self.tool(worktree, "tron-ios-test", "status", *arguments,
                                   environment={**self.environment, **override})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Lane: {lane}\n", result.stdout)

    def test_the_profiler_and_the_e2e_harness_lease_the_runners_lane(self) -> None:
        """Failure mode 4: one selection names one lane in all three tools."""
        worktree = self.linked("tools-worktree")
        key = self.key(worktree)
        for arguments, label in (((), key), (("--lane", "beta"), "beta")):
            with self.subTest(lane=label):
                self.log_path.unlink(missing_ok=True)
                lane = self.lane_root / f"ios-test-{label}"
                # --no-build refuses (74) once the lane is provisioned: no
                # profiler products exist, so only the lane path runs.
                profile = self.tool(worktree, "tron-profile-ios", "--scenario", "control", "--no-build", *arguments)
                self.assertEqual(profile.returncode, 74, profile.stderr)
                marker = self.lane_marker(lane)
                self.assertEqual(marker["name"], f"Tron iOS Tests ({label})")
                self.assertEqual(marker["worktree"], os.path.realpath(worktree))
                self.assert_booted_only(marker["udid"])

                # The command the lease holder starts boots the leased lane's
                # simulator, not the one its own default would name.
                build = self.tool(worktree, "ios-gateway-e2e-test", "build", *arguments)
                self.assertEqual(build.returncode, 0, build.stderr)
                self.assertEqual(self.lane_marker(lane)["udid"], marker["udid"])
                self.assert_booted_only(marker["udid"])
                self.assertEqual(self.simctl_commands().count("create"), 1)
                status = self.tool(worktree, "ios-gateway-e2e-test", "status", *arguments)
                self.assertEqual(status.returncode, 0, status.stderr)
                self.assertIn(f"Lane: {label} ({lane})\n", status.stdout)
        self.assert_default_lane_untouched()

    def test_a_worktree_lane_is_attributed_and_expires_when_idle(self) -> None:
        """Failure mode 5: a worktree lane is listed as its worktree's and reclaimed."""
        worktree = self.linked("idle-worktree")
        self.stamp_products(worktree)
        result = self.focused_run(worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        key = self.key(worktree)
        lane = self.lane_root / f"ios-test-{key}"

        status = self.tool(worktree, "tron-ios-test", "status", "--all")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn(os.path.realpath(worktree), self.status_row(status.stdout, f"lane {key}"))

        marker = self.lane_marker(lane)
        marker["last_used_epoch_seconds"] = int(time.time()) - 8 * 24 * 3600
        (lane / "simulator.json").write_text(json.dumps(marker))
        reap = self.tool(self.primary, "tron-ios-test", "reap")
        self.assertEqual(reap.returncode, 0, reap.stderr)
        self.assertFalse(lane.exists())
        self.assertFalse(self.present(str(marker["udid"])))

    def test_a_worktree_named_with_a_leading_symbol_still_has_a_lane(self) -> None:
        """Failure mode 6: every worktree directory name derives a valid lane."""
        for name in (".dot-worktree", "-dash-worktree", "_underscore-worktree"):
            with self.subTest(worktree=name):
                worktree = self.linked(name)
                key = self.key(worktree)
                result = self.tool(worktree, "tron-ios-test", "status")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Lane: {key} ({self.lane_root}/ios-test-{key})\n", result.stdout)

    def test_a_deleted_worktrees_lane_is_removed_by_the_next_sweep(self) -> None:
        """Failure mode 7: a lane outlives its worktree only while a command holds it."""
        gone, held, kept = (self.linked(name) for name in ("gone-worktree", "held-worktree", "kept-worktree"))
        for worktree in (gone, held, kept):
            self.stamp_products(worktree)
            result = self.focused_run(worktree)
            self.assertEqual(result.returncode, 0, result.stderr)
        # The default lane, created - and so attributed - by a worktree deleted below.
        default_run = self.tool(gone, "tron-ios-test", "run", "--lane", "default",
                                "--only-testing", "TronMobileTests/StubTests")
        self.assertEqual(default_run.returncode, 0, default_run.stderr)
        default_lane = self.lane_root / "ios-test"
        self.assertEqual(self.lane_marker(default_lane)["worktree"], os.path.realpath(gone))
        lanes = {worktree: self.lane_root / f"ios-test-{self.key(worktree)}" for worktree in (gone, held, kept)}
        udids = {worktree: str(self.lane_marker(lane)["udid"]) for worktree, lane in lanes.items()}
        gone_key = self.key(gone)
        self.hold_lease(lanes[held], command="run")
        for worktree in (gone, held):
            self.git(self.primary, "worktree", "remove", "--force", str(worktree))

        reap = self.tool(self.primary, "tron-ios-test", "reap")
        self.assertEqual(reap.returncode, 0, reap.stderr)
        self.assertIn(f"removed lane {gone_key}", reap.stdout)
        self.assertFalse(lanes[gone].exists())
        self.assertFalse(self.present(udids[gone]))
        for lane, worktree in ((lanes[held], held), (lanes[kept], kept), (default_lane, gone)):
            with self.subTest(kept=lane.name):
                self.assertEqual(self.lane_marker(lane)["worktree"], os.path.realpath(worktree))
                self.assertTrue(self.present(str(self.lane_marker(lane)["udid"])))

    def test_status_names_the_newest_run_of_this_worktree_and_lane(self) -> None:
        """Failure mode 9: the latest run is this worktree's and lane's own."""
        first, second = self.linked("first-worktree"), self.linked("second-worktree")
        for worktree in (first, second):
            self.stamp_products(worktree)
            self.assertEqual(self.reported_latest(worktree), "none")
        runs: dict[str, Path] = {}
        # Every later run is another worktree's or another lane's, so a latest
        # result that follows the newest run anywhere names the wrong one.
        for label, worktree, arguments in (
            ("first-older", first, ()), ("first-newer", first, ()),
            ("second", second, ()), ("first-alpha", first, ("--lane", "alpha")),
        ):
            result = self.focused_run(worktree, *arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            runs[label] = self.completed_run(result)

        self.assertEqual(self.reported_latest(first), str(runs["first-newer"]))
        self.assertEqual(self.reported_latest(second), str(runs["second"]))
        self.assertEqual(self.reported_latest(first, "--lane", "alpha"), str(runs["first-alpha"]))
        self.assertEqual(self.reported_latest(second, "--lane", "alpha"), "none")

    def test_a_read_only_command_creates_no_lane_state(self) -> None:
        """Failure mode 8: only a command that leases the lane creates its directory."""
        worktree = self.linked("read-only-worktree")
        lane = self.lane_root / f"ios-test-{self.key(worktree)}"
        for tool, command in (("tron-ios-test", "status"), ("ios-gateway-e2e-test", "help"),
                              ("ios-gateway-e2e-test", "status")):
            with self.subTest(tool=tool, command=command):
                result = self.tool(worktree, tool, command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(lane.exists())


class DevelopmentSimulatorFixture(LifecycleHarness, unittest.TestCase):
    """SIM-7: the remembered Development simulator reports its uptime.

    Failure modes these cases target, written before the code:

    1. `status` cannot say how long the remembered simulator has been booted, so
       the memory it holds is invisible to the person running it.
    2. `status` invents an uptime for a simulator that is not booted, or for a
       booted one the process table cannot prove.
    3. `stop` shuts down or deletes a simulator it does not own, or leaves the
       remembered one booted.
    4. The destructive tooling that shares its row in `status --all` deletes or
       shuts down the Development simulator.
    """

    def remember_development(self, udid: str = UDID_A, *, state: str = "Booted", name: str = "iPhone 17 Pro") -> None:
        self.development_marker.parent.mkdir(parents=True, exist_ok=True)
        self.development_marker.write_text(udid + "\n")
        self.add_device(udid, name=name, state=state)

    def development(self, *arguments: str, timeout: float = 60) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(DEVELOPMENT), *arguments], env=self.environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )

    def test_status_reports_how_long_the_remembered_simulator_has_been_booted(self) -> None:
        """Failure modes 1 and 2: the uptime is real, shared and never invented."""
        self.remember_development(UDID_A)
        self.reader_value("process-table", device_process(UDID_A, "01-04:49:13"))

        result = self.development("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Simulator uptime: 1d 4h", result.stdout)
        # The one view the runner prints names the same simulator and time.
        listing = self.runner("status", "--all")
        self.assertEqual(listing.returncode, 0, listing.stderr)
        self.assertIn("1d 4h", self.status_row(listing.stdout, "development "))

        # A read-only boot process means the time is unknown, not invented.
        self.reader_value("process-table", "")
        unproven = self.development("status")
        self.assertEqual(unproven.returncode, 0, unproven.stderr)
        self.assertIn("Simulator uptime: unknown", unproven.stdout)
        self.assertNotIn("1d 4h", unproven.stdout)

        # A simulator that is not booted holds no memory and has no uptime.
        self.update_device(UDID_A, state="Shutdown")
        idle = self.development("status")
        self.assertEqual(idle.returncode, 0, idle.stderr)
        self.assertIn("Simulator uptime: not booted", idle.stdout)

    def test_stop_releases_only_the_remembered_simulator(self) -> None:
        """Failure mode 3: the other lane and the remembered device itself survive."""
        self.remember_development(UDID_A)
        self.owned_lane("ios-test-other", UDID_B)

        result = self.development("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.shutdown_targets(), [UDID_A])
        self.assertEqual(self.device_entry(UDID_A)["state"], "Shutdown")
        self.assertEqual(self.device_entry(UDID_B)["state"], "Booted")
        self.assertTrue(self.present(UDID_A))
        self.assertEqual(self.simctl_commands().count("delete"), 0)

    def test_the_sharing_tools_never_change_the_development_simulator(self) -> None:
        """Failure mode 4: sweep, lane removal and clean leave it alone."""
        self.development_marker.parent.mkdir(parents=True, exist_ok=True)
        self.development_marker.write_text(UDID_A + "\n")
        self.owned_lane("ios-test", UDID_A)

        swept = self.reap()
        self.assertEqual(swept.returncode, 0, swept.stderr)
        self.assertIn("Development simulator", swept.stderr)
        cleaned = self.runner("clean")
        self.assertEqual(cleaned.returncode, 66, cleaned.stderr)
        self.assertIn("Development simulator", cleaned.stderr)
        removed = self.runner("lane-remove", "default")
        self.assertEqual(removed.returncode, 66, removed.stderr)
        self.assertIn("Development simulator", removed.stderr)

        self.assertTrue(self.present(UDID_A))
        self.assertEqual(self.device_entry(UDID_A)["state"], "Booted")
        self.assertEqual(self.simctl_commands().count("delete"), 0)
        self.assertEqual(self.shutdown_targets(), [])


# Shared by the synthetic tools of `DeviceLeaseFixture`: every call is logged
# under the caller the case named, and a gated call holds its command open until
# the case opens the gate, recording the command tree's process group first.
DEVICE_LEASE_TOOL_SOURCE = FIXTURE_GATE_SOURCE + '''


def log(line):
    with open(os.environ["FAKE_TOOL_LOG"], "a", encoding="utf-8") as handle:
        handle.write(os.environ.get("FAKE_CALLER", "unknown") + " " + line + "\\n")


def gate():
    name = os.environ.get("FAKE_GATE")
    if not name:
        return
    gates = Path(os.environ["FAKE_GATES"])
    (gates / (name + ".reached")).write_text(str(os.getpgid(0)) + "\\n")
    wait_for_fixture_gate(gates / (name + ".open"))
'''

DEVICE_LEASE_FAKE_TOOLS = {
    "xcrun": '''arguments = sys.argv[1:]
log("xcrun " + " ".join(arguments))
if arguments[:3] == ["--sdk", "iphoneos", "--show-sdk-version"]:
    print("26.5"); raise SystemExit(0)
if arguments[:4] == ["simctl", "list", "devices", "available"]:
    print("    iPhone 17 Pro (" + os.environ["FAKE_SIMULATOR_UDID"] + ") (Booted)"); raise SystemExit(0)
if arguments[:2] == ["simctl", "get_app_container"]:
    print(os.environ["FAKE_INSTALLED_APP"]); raise SystemExit(0)
if arguments[:2] == ["simctl", "launch"] or arguments[:4] == ["devicectl", "device", "process", "launch"]:
    gate(); raise SystemExit(0)
if arguments[:2] in (["simctl", "boot"], ["simctl", "bootstatus"], ["simctl", "terminate"], ["simctl", "install"]):
    raise SystemExit(0)
if arguments[:3] == ["devicectl", "device", "install"]:
    raise SystemExit(0)
print("unexpected xcrun arguments: " + repr(arguments), file=sys.stderr)
raise SystemExit(2)
''',
    "xcodebuild": '''arguments = sys.argv[1:]
if arguments[:1] == ["-version"]:
    print("Xcode 26.6"); raise SystemExit(0)


def value(flag):
    return arguments[arguments.index(flag) + 1]


derived = os.path.abspath(value("-derivedDataPath"))
platform = "iphonesimulator" if "Simulator" in value("-destination") else "iphoneos"
log("xcodebuild build " + derived)
gate()
Path(derived, "Build/Products", value("-configuration") + "-" + platform, "TronMobile.app").mkdir(parents=True, exist_ok=True)
''',
    "codesign": 'print("Identifier=com.tron.mobile.beta", file=sys.stderr)\n',
    # `open -a Simulator` must never reach the real Simulator app from a fixture.
    "open": 'log("open " + " ".join(sys.argv[1:]))\n',
    "xcode-select": 'print("/Applications/Xcode.app/Contents/Developer")\n',
    "xcodegen": '''if sys.argv[1:] == ["--version"]:
    print("Version: " + os.environ["FAKE_XCODEGEN_VERSION"]); raise SystemExit(0)
log("xcodegen " + " ".join(sys.argv[1:]))
''',
}


class DeviceLeaseFixture(ContainedFixture, unittest.TestCase):
    """W-18 (#100): the Development simulator and each physical device are leased.

    `scripts/tron-ios-simulator` and `scripts/tron-ios-device` run from two
    synthetic worktrees (copies of the real scripts beside synthetic repository
    tools), against a synthetic xcrun, xcodebuild and codesign, so no case boots
    the Development simulator or reaches a physical device.

    Failure modes these cases target, written before the code:

    1. Two worktrees run `scripts/tron-ios-simulator install` (or `start`/`stop`)
       at once, and both build, install and launch on the one Development
       simulator.
    2. A contended command does not exit 73, does not name the holder (worktree,
       PID, start time), or has already touched the simulator or device before
       it is refused.
    3. Development simulator builds from different worktrees share one
       DerivedData directory.
    4. Two installs or launches run at once on one physical device, or the lease
       of one device blocks another device.
    5. A holder killed outright leaves a stale lease, so the next command is
       refused although nothing runs any more.
    6. That stale lease is released while the command tree the killed holder
       started is still building or installing, so a second command starts
       under it.
    7. The command, re-executed under its own lease, takes the lease again and
       refuses itself.
    8. A device identifier with path characters names a lease file outside the
       lease directory.
    """

    DEVICE_ONE = "11111111-2222-3333-4444-555555555555"
    DEVICE_TWO = "66666666-7777-8888-9999-AAAAAAAAAAAA"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.gates = self.root / "gates"
        self.gates.mkdir()
        self.tool_log = self.root / "tools.log"
        self.tool_log.write_text("")
        xcodegen_version = next(
            line.split("=", 1)[1].strip()
            for line in (ROOT / "config/ci-toolchain.env").read_text().splitlines()
            if line.startswith("TRON_CI_XCODEGEN_VERSION=")
        )
        for name, body in DEVICE_LEASE_FAKE_TOOLS.items():
            self.synthetic_stub(self.bin / name, DEVICE_LEASE_TOOL_SOURCE + body)
        self.environment = self.contained_environment(self.root)
        # The Development simulator's DerivedData is derived from HOME and the
        # worktree here, as it is on a real Mac.
        self.environment.pop("TRON_IOS_SIMULATOR_DERIVED_DATA")
        for inherited in (
            "DEVELOPER_DIR", "TRON_IOS_DEVICE_ID", "TRON_IOS_DEVICE_NAME", "TRON_IOS_SCHEME",
            "TRON_IOS_CONFIGURATION", "TRON_IOS_REQUIRED_SDK_MAJOR", "TRON_IOS_SIMULATOR_ID",
            "TRON_IOS_TEST_LOCK_HELD", "TRON_IOS_TEST_LEASE_FD", "TRON_IOS_TEST_LEASE_LOCK",
        ):
            self.environment.pop(inherited, None)
        self.environment.update({
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_TOOL_LOG": str(self.tool_log),
            "FAKE_GATES": str(self.gates),
            "FAKE_SIMULATOR_UDID": UDID_A,
            "FAKE_INSTALLED_APP": str(self.root / "installed/TronMobile.app"),
            "FAKE_XCODEGEN_VERSION": xcodegen_version,
            "TRON_XCODEGEN": str(self.bin / "xcodegen"),
            "TRON_IOS_GATEWAY_PROTOCOL_TARGET": "source",
        })
        state = Path(self.environment["TRON_IOS_SIMULATOR_STATE_DIR"])
        state.mkdir(parents=True)
        (state / "ios-simulator-udid").write_text(UDID_A + "\n")
        self.started: list[tuple[subprocess.Popen[str], Path]] = []
        self.groups: list[int] = []
        self.outputs: list[str] = []

    def tearDown(self) -> None:
        try:
            for reached in self.gates.glob("*.reached"):
                (self.gates / (reached.name.removesuffix(".reached") + ".open")).write_text("")
            for process, output in self.started:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)
                self.outputs.append(output.read_text())
            for group in self.groups:
                try:
                    os.killpg(group, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            # scripts/tron-ios-device keeps each build's log in /tmp; remove the
            # ones these cases produced, and only those.
            for output in self.outputs:
                for line in output.splitlines():
                    if line.startswith("Full log: /tmp/xcode-"):
                        Path(line.removeprefix("Full log: ")).unlink(missing_ok=True)
            self.assert_no_containment_violations()
        finally:
            self.temporary.cleanup()

    def make_worktree(self, name: str) -> Path:
        """A worktree holding the real helpers and synthetic repository tools."""
        worktree = self.root / name
        (worktree / "packages/ios-app").mkdir(parents=True)
        for relative in (
            "config/ci-toolchain.env", "scripts/tron-ios-simulator", "scripts/tron-ios-device",
            "scripts/ios-test-lock.py", "scripts/ios-test-build-identity.py",
        ):
            source = ROOT / relative
            target = worktree / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            target.chmod(source.stat().st_mode & 0o777)
        for tool in ("generate-xcode-project", "verify-gateway-protocol-contract.py", "validate-ios-artifact.py"):
            self.synthetic_stub(worktree / "scripts" / tool, DEVICE_LEASE_TOOL_SOURCE + f'log("{tool}")\n')
        return worktree

    def caller_environment(self, caller: str, gate: str | None) -> dict[str, str]:
        environment = dict(self.environment, FAKE_CALLER=caller)
        if gate is not None:
            environment["FAKE_GATE"] = gate
        return environment

    def run_tool(self, worktree: Path, tool: str, *arguments: str, caller: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(worktree / "scripts" / tool), *arguments], env=self.caller_environment(caller, None),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )
        self.outputs.append(result.stdout)
        return result

    def start_tool(self, worktree: Path, tool: str, *arguments: str, caller: str, gate: str) -> subprocess.Popen[str]:
        """A command held open at its first gated call, as a long build is."""
        output = self.root / f"{caller}-{gate}.out"
        with output.open("w") as handle:
            process = subprocess.Popen(
                [str(worktree / "scripts" / tool), *arguments], env=self.caller_environment(caller, gate),
                text=True, stdout=handle, stderr=subprocess.STDOUT,
            )
        self.started.append((process, output))
        return process

    def wait_reached(self, gate: str, timeout: float = 30) -> int:
        """The process group of the command tree that reached `gate`."""
        path = self.gates / f"{gate}.reached"
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = path.read_text().strip() if path.exists() else ""
            if text:
                group = int(text)
                # A leased command runs in the holder's own process group; one
                # still in this test's group was never leased, and killing that
                # group on teardown would kill the test run itself.
                if group == os.getpgrp():
                    self.fail(f"the command that reached {gate!r} runs in the test's own process group: it holds no lease")
                self.groups.append(group)
                return group
            time.sleep(0.05)
        self.fail(f"no command reached the {gate!r} gate within {timeout:g}s\n" + self.tool_log.read_text())

    def open_gate(self, gate: str) -> None:
        (self.gates / f"{gate}.open").write_text("")

    def output_of(self, process: subprocess.Popen[str]) -> str:
        return next(output.read_text() for started, output in self.started if started is process)

    def tool_calls(self, caller: str) -> list[str]:
        prefix = caller + " "
        return [line.removeprefix(prefix) for line in self.tool_log.read_text().splitlines() if line.startswith(prefix)]

    def derived_data(self, caller: str) -> str:
        builds = [call.removeprefix("xcodebuild build ") for call in self.tool_calls(caller) if call.startswith("xcodebuild build ")]
        self.assertEqual(len(builds), 1, self.tool_calls(caller))
        return builds[0]

    def assert_names_holder(self, stderr: str, resource: str, worktree: Path, pid: int) -> None:
        self.assertIn(f"{resource} is already leased", stderr)
        self.assertTrue(str(worktree) in stderr or os.path.realpath(worktree) in stderr, stderr)
        self.assertIn(f"PID {pid}", stderr)
        self.assertRegex(stderr, r"started \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}")

    def test_one_development_simulator_serializes_worktrees_and_keeps_their_derived_data_apart(self) -> None:
        """Failure modes 1, 2, 3 and 7."""
        alpha, beta = self.make_worktree("alpha"), self.make_worktree("beta")
        holder = self.start_tool(alpha, "tron-ios-simulator", "install", caller="alpha", gate="build")
        self.wait_reached("build")

        for verb in ("install", "start", "stop"):
            refused = self.run_tool(beta, "tron-ios-simulator", verb, caller="beta")
            self.assertEqual(refused.returncode, 73, refused.stderr)
            self.assert_names_holder(refused.stderr, "Development simulator", alpha, holder.pid)
        self.assertEqual(self.tool_calls("beta"), [])

        self.open_gate("build")
        self.assertEqual(holder.wait(timeout=60), 0, self.output_of(holder))
        self.assertIn(f"xcrun simctl launch {UDID_A} com.tron.mobile.beta", self.tool_calls("alpha"))
        admitted = self.run_tool(beta, "tron-ios-simulator", "install", caller="beta")
        self.assertEqual(admitted.returncode, 0, admitted.stderr)

        derived_root = self.home / "Library/Developer/Tron/ios/simulator-derived-data"
        alpha_derived, beta_derived = Path(self.derived_data("alpha")), Path(self.derived_data("beta"))
        self.assertEqual(alpha_derived.parent, derived_root)
        self.assertEqual(beta_derived.parent, derived_root)
        self.assertTrue(alpha_derived.name.startswith("alpha-"), alpha_derived)
        self.assertTrue(beta_derived.name.startswith("beta-"), beta_derived)

    def test_one_device_is_leased_for_build_install_and_launch_and_other_devices_are_not(self) -> None:
        """Failure modes 2, 4 and 7."""
        alpha, beta = self.make_worktree("alpha"), self.make_worktree("beta")
        holder = self.start_tool(
            alpha, "tron-ios-device", "install", "--device-id", self.DEVICE_ONE, caller="alpha", gate="build",
        )
        self.wait_reached("build")

        for verb in ("install", "launch", "stop"):
            refused = self.run_tool(beta, "tron-ios-device", verb, "--device-id", self.DEVICE_ONE, caller="beta")
            self.assertEqual(refused.returncode, 73, refused.stderr)
            self.assert_names_holder(refused.stderr, f"physical iOS device {self.DEVICE_ONE}", alpha, holder.pid)
        self.assertEqual(self.tool_calls("beta"), [])
        other = self.run_tool(beta, "tron-ios-device", "launch", "--device-id", self.DEVICE_TWO, caller="other")
        self.assertEqual(other.returncode, 0, other.stderr)

        self.open_gate("build")
        self.assertEqual(holder.wait(timeout=60), 0, self.output_of(holder))
        # The one lease covered the whole build, install and launch, in order.
        steps = ("xcodebuild build", "xcrun devicectl device install", "xcrun devicectl device process launch")
        self.assertEqual(
            [step for call in self.tool_calls("alpha") for step in steps if call.startswith(step)], list(steps),
        )
        admitted = self.run_tool(beta, "tron-ios-device", "launch", "--device-id", self.DEVICE_ONE, caller="beta")
        self.assertEqual(admitted.returncode, 0, admitted.stderr)

    def test_a_killed_holder_keeps_the_lease_until_its_command_ends_then_releases_it(self) -> None:
        """Failure modes 5 and 6."""
        alpha, beta = self.make_worktree("alpha"), self.make_worktree("beta")
        holder = self.start_tool(
            alpha, "tron-ios-device", "install", "--device-id", self.DEVICE_ONE, caller="alpha", gate="build",
        )
        group = self.wait_reached("build")
        holder.kill()
        holder.wait(timeout=10)

        # The holder is gone, but the build it started still runs.
        refused = self.run_tool(beta, "tron-ios-device", "launch", "--device-id", self.DEVICE_ONE, caller="beta")
        self.assertEqual(refused.returncode, 73, refused.stderr)
        self.assert_names_holder(refused.stderr, f"physical iOS device {self.DEVICE_ONE}", alpha, holder.pid)
        self.assertIn("has exited", refused.stderr)
        self.assertEqual(self.tool_calls("beta"), [])

        self.open_gate("build")
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                os.killpg(group, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            self.fail("the killed holder's command tree never ended")
        self.assertIn("devicectl device install", " ".join(self.tool_calls("alpha")))

        # Its stale metadata does not block the next command.
        admitted = self.run_tool(beta, "tron-ios-device", "launch", "--device-id", self.DEVICE_ONE, caller="beta")
        self.assertEqual(admitted.returncode, 0, admitted.stderr)
        self.assertIn("devicectl device process launch", " ".join(self.tool_calls("beta")))

    def test_killed_fixture_owners_leave_no_gated_build_processes(self) -> None:
        """#128: SIGKILL skips teardown; both helper trees must still retire."""
        for tool in ("tron-ios-simulator", "tron-ios-device"):
            with self.subTest(tool=tool):
                self.check_interrupted_fixture(tool, "sigkill")

    def test_timed_out_fixture_owner_leaves_no_gated_build_processes(self) -> None:
        """#128: an unhandled real wait timeout also skips fixture teardown."""
        self.check_interrupted_fixture("tron-ios-device", "timeout")

    def test_repeated_interruptions_preserve_preexisting_build_logs(self) -> None:
        """PID reuse must not authorize deleting a historical build log."""
        for attempt in range(2):
            with self.subTest(attempt=attempt):
                self.check_interrupted_fixture("tron-ios-device", "sigkill")

    def check_interrupted_fixture(self, tool: str, interruption: str) -> None:
        # Keep another real leased fixture tree gated throughout the abort. A
        # cleanup that kills by tool name or a shared group would destroy it.
        survivor_gate = f"survivor-{tool}-{interruption}-{len(self.started)}"
        survivor = self.start_tool(
            self.make_worktree(survivor_gate), "tron-ios-device", "install",
            "--device-id", self.DEVICE_TWO, caller="survivor", gate=survivor_gate,
        )
        survivor_group = self.wait_reached(survivor_gate)
        record_path = self.root / f"{survivor_gate}.json"
        owner_script = self.root / "interrupted-owner.py"
        owner_script.write_text('''import json, os, runpy, sys, tempfile, time
from pathlib import Path
module = runpy.run_path(sys.argv[1])
fixture = module["DeviceLeaseFixture"]()
fixture.setUp()
worktree = fixture.make_worktree("alpha")
tool, mode = sys.argv[3:5]
arguments = ["install"]
if tool == "tron-ios-device":
    arguments += ["--device-id", fixture.DEVICE_ONE]
holder = fixture.start_tool(worktree, tool, *arguments, caller="alpha", gate="build")
group = fixture.wait_reached("build")
# Model a retained log from an earlier invocation with this recycled group ID.
# Exclusive creation gives this regression ownership of only its stand-in.
fd, historical_log = tempfile.mkstemp(prefix="xcode-0-", suffix=f"-{group}.log", dir="/tmp")
with os.fdopen(fd, "w") as handle:
    handle.write("retained historical build log\\n")
record = Path(sys.argv[2])
temporary = record.with_suffix(".tmp")
temporary.write_text(json.dumps({
    "root": str(fixture.root), "holder": holder.pid, "group": group,
    "historical_log": historical_log,
}))
os.replace(temporary, record)
# Intentionally no teardown: exercise the interruption that bypasses it.
if mode == "timeout":
    holder.wait(timeout=0.1)
else:
    time.sleep(60)
''')
        owner = subprocess.Popen(
            [sys.executable, str(owner_script), str(Path(__file__).resolve()), str(record_path), tool, interruption],
            env=self.contained_environment(self.root), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        record = None
        survivors: list[str] = []
        try:
            deadline = time.monotonic() + 30
            while not record_path.exists() and time.monotonic() < deadline and owner.poll() is None:
                time.sleep(0.05)
            self.assertTrue(record_path.exists(), "interrupted fixture never reached its build gate")
            record = json.loads(record_path.read_text())
            self.assertNotIn(record["group"], (os.getpgrp(), survivor_group))
            if interruption == "sigkill":
                owner.kill()
            _, stderr = owner.communicate(timeout=10)
            if interruption == "sigkill":
                self.assertEqual(owner.returncode, -signal.SIGKILL, stderr)
                self.assertTrue(Path(record["root"]).is_dir(), "SIGKILL must exercise owner death, not directory removal")
            else:
                self.assertNotEqual(owner.returncode, 0, stderr)
                self.assertIn("TimeoutExpired", stderr)

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                table = subprocess.check_output(
                    ["/bin/ps", "-axo", "pid=,pgid=,command="],
                    env=self.contained_environment(self.root), text=True,
                )
                survivors = [line.strip() for line in table.splitlines() if
                             str(record["root"]) in line or
                             line.split()[:1] == [str(record["holder"])] or
                             line.split()[1:2] == [str(record["group"])]]
                if not survivors:
                    break
                time.sleep(0.05)
            retained = ROOT / "test-results/ios-infrastructure"
            retained.mkdir(parents=True, exist_ok=True)
            (retained / f"{tool}-{interruption}-cleanup.json").write_text(json.dumps({
                "tool": tool, "interruption": interruption, "owner_pid": owner.pid,
                "owner_exit": owner.returncode, **record, "surviving_processes": survivors,
                "other_fixture_pid": survivor.pid, "other_fixture_alive": survivor.poll() is None,
                "other_gate_closed": not (self.gates / f"{survivor_gate}.open").exists(),
            }, indent=2) + "\n")
            self.assertEqual(survivors, [], "gated fixture processes survived their test owner")
            self.assertIsNone(survivor.poll(), "interruption killed another fixture's lease holder")
            self.assertFalse((self.gates / f"{survivor_gate}.open").exists())
            self.open_gate(survivor_gate)
            self.assertEqual(survivor.wait(timeout=60), 0, self.output_of(survivor))
        finally:
            if owner.poll() is None:
                owner.kill()
            owner.wait(timeout=10)
            self.close_pipes(owner)
            if record is not None:
                if survivors:
                    # Negative controls must not recreate the incident. Signal
                    # only resources still observed under this fixture's root.
                    owned = [line.split() for line in survivors if str(record["root"]) in line]
                    if any(fields[1] == str(record["group"]) for fields in owned):
                        try:
                            os.killpg(record["group"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if any(fields[0] == str(record["holder"]) for fields in owned):
                        try:
                            os.kill(record["holder"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                # Device builds log outside TMPDIR. Leave logs without an
                # invocation-owned path: a recycled PID cannot prove ownership.
                shutil.rmtree(record["root"], ignore_errors=True)
            self.open_gate(survivor_gate)
            survivor.wait(timeout=60)
            if record is not None:
                historical_log = Path(record["historical_log"])
                preserved = historical_log.exists() and historical_log.read_text() == "retained historical build log\n"
                try:
                    report_path = ROOT / f"test-results/ios-infrastructure/{tool}-{interruption}-cleanup.json"
                    if report_path.exists():
                        report = json.loads(report_path.read_text())
                        report["historical_log_preserved"] = preserved
                        report_path.write_text(json.dumps(report, indent=2) + "\n")
                    self.assertTrue(preserved, "interrupted fixture cleanup deleted or changed a historical build log")
                finally:
                    # Only the exclusively created regression stand-in is ours.
                    historical_log.unlink(missing_ok=True)

    def test_removed_gate_directory_retires_the_build_without_installing(self) -> None:
        """#128: temporary-directory removal must not leave an infinite gate."""
        holder = self.start_tool(
            self.make_worktree("alpha"), "tron-ios-device", "install",
            "--device-id", self.DEVICE_ONE, caller="alpha", gate="build",
        )
        self.wait_reached("build")
        shutil.rmtree(self.gates)
        self.assertNotEqual(holder.wait(timeout=5), 0, self.output_of(holder))
        self.assertFalse(any("devicectl device install" in call for call in self.tool_calls("alpha")))

    def test_a_device_identifier_cannot_name_a_lease_outside_the_lease_directory(self) -> None:
        """Failure mode 8."""
        alpha = self.make_worktree("alpha")
        refused = self.run_tool(alpha, "tron-ios-device", "launch", "--device-id", "../../../escape", caller="alpha")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("invalid device identifier", refused.stderr)
        self.assertEqual(self.tool_calls("alpha"), [])
        self.assertEqual([path for path in self.root.rglob("*") if "escape" in path.name or ".." in path.name], [])


class ContainmentFixture(ContainedFixture, unittest.TestCase):
    """The guard that keeps every other fixture inside its own temporary directory.

    Failure modes these cases target, written before the code:

    1. A fixture (or a future caller) runs a script under test with HOME or a
       Tron state, lane, discovery, results or products root pointing at this
       Mac's real state, so a sweep, `clean` or `prune` touches something the
       fixture does not own - the leak the SIM-5 commit had, where the
       sweep-level fixtures inherited the real HOME and their `reap` pruned the
       real results root.
    2. The leak reaches a tool through a script under test rather than through
       the fixture, so the launcher never sees it: the tool has to refuse it.
    3. The leak is on the disk-only path. `prune` deletes runs and products in
       Python and starts no synthetic tool at all, so the guard must trip before
       the process starts (review P2-6).
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.stub = self.bin / "xcrun"
        # A tool that does nothing itself: only the shared guard decides.
        self.synthetic_stub(self.stub, "raise SystemExit(0)\n")
        self.spawner = self.bin / "spawn-with"
        self.synthetic_stub(self.spawner, """import os, subprocess, sys
environment = dict(os.environ)
for assignment in sys.argv[1:]:
    name, _, value = assignment.partition('=')
    environment[name] = value
completed = subprocess.run([os.environ['FAKE_CONTAINMENT_CHILD']], env=environment,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
sys.stderr.write(completed.stderr)
print(completed.returncode)
""")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_stub(self, **override: str) -> subprocess.CompletedProcess[str]:
        environment = self.contained_environment(self.root)
        environment.update(override)
        return subprocess.run([str(self.stub)], env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_a_script_whose_environment_escapes_the_fixture_is_refused(self) -> None:
        """Failure modes 1 and 2: a leaked root fails the run and the test that
        caused it, whether the fixture or a script under test hands it on."""
        inside = self.run_stub()
        self.assertEqual(inside.returncode, 0, inside.stderr)
        self.assertFalse(self.containment_log(self.root).exists())

        real_home = str(Path.home())
        with self.assertRaises(AssertionError) as refused:
            self.run_stub(HOME=real_home)
        self.assertIn(f"HOME={real_home}", str(refused.exception))

        environment = self.contained_environment(self.root)
        environment["FAKE_CONTAINMENT_CHILD"] = str(self.stub)
        handed_on = subprocess.run(
            [str(self.spawner), f"HOME={real_home}"], env=environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(handed_on.stdout.strip(), "3", handed_on.stderr)
        self.assertIn("escapes the test fixture", handed_on.stderr)
        with self.assertRaises(AssertionError):
            self.assert_no_containment_violations()

    def test_a_leaking_prune_root_is_refused_before_prune_runs(self) -> None:
        """Failure mode 3: the disk-only path is guarded too.

        `prune` removes runs and products itself, so a leaking results or
        products root reaches this Mac's state without any synthetic tool ever
        running to refuse it.
        """
        elsewhere = self.root.parent / "Tron/ios/test-runs"
        with self.assertRaises(AssertionError) as refused:
            self.run_stub(TRON_IOS_TEST_RESULTS_DIR=str(elsewhere))
        self.assertIn(f"TRON_IOS_TEST_RESULTS_DIR={elsewhere}", str(refused.exception))
        with self.assertRaises(AssertionError) as products:
            self.run_stub(TRON_IOS_TEST_DERIVED_DATA=str(self.root.parent / "Tron/ios/test-derived-data"))
        self.assertIn("TRON_IOS_TEST_DERIVED_DATA=", str(products.exception))
        self.assertFalse(self.containment_log(self.root).exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
