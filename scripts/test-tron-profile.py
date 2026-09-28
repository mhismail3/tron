#!/usr/bin/env python3
"""Failure-mode tests for the profiler's shared report and comparison owner.

Each case targets one way a comparison could silently mislead an agent:
a real regression passing, noise or an improvement failing a change, a missing
or relabeled metric being read as zero, a malformed/truncated report being
accepted, or a run recorded under an Instruments trace (whose metrics carry
tracing overhead) deciding a comparison. The profiler lanes' own self-tests cover measurement end to end.

The Gateway multi-session scenario adds failure modes its own run cannot
reveal: a catalog generator whose output drifts between runs or misplaces
forks and subagent runs relative to the Gateway's delegated-session layout; a
generated catalog (gigabytes) left behind by an interrupted or failed run; a
fixture child that survives `stop()` and must keep its home while the catalog
still goes; a removal the first Ctrl-C interrupts half-way; a
fixture probe whose walk counter never sees the Gateway's ES-module `opendir`
(reporting zero walks) or that loads outside a fixture Gateway; and a
percentile or missing-sample bug that reports a latency the run never measured.
"""

from __future__ import annotations

import hashlib
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / "scripts/tron_profile_report.py"
FRONT_DOOR = ROOT / "scripts/tron-profile"
GATEWAY_PROFILER = ROOT / "scripts/tron-profile-gateway"
DRIVER = ROOT / "scripts/tron-profile-gateway-driver.mjs"
RELAY = ROOT / "scripts/tron-profile-relay.mjs"
PROBE = ROOT / "scripts/tron-profile-gateway-probe.mjs"
# The generator and probe tests need Node (CI provides it); they fail without it.
NODE = shutil.which("node") or "node"


def samples(metrics: dict[str, tuple[str, str, list[float]]]) -> dict:
    return {
        "schema": "tron.profile-samples.v1",
        "metrics": {
            name: {"unit": unit, "better": better, "values": values}
            for name, (unit, better, values) in metrics.items()
        },
    }


class ReportFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.environment = {"TRON_PROFILE_RESULTS_DIR": str(self.root / "profiles"), "PATH": "/usr/bin:/bin"}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_report(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(REPORT), *args],
            capture_output=True,
            text=True,
            env=self.environment,
            timeout=60,
        )

    def write(self, name: str, document: dict, scenario: str = "idle-chat") -> Path:
        source = self.root / f"{name}.samples.json"
        source.write_text(json.dumps(document))
        run_dir = self.root / "profiles/ios" / name
        result = self.run_report(
            "write", "--tool", "ios", "--scenario", scenario,
            "--samples", str(source), "--run-dir", str(run_dir), "--worktree", str(ROOT),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return run_dir

    def compare(self, base: Path, candidate: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return self.run_report("compare", str(base), str(candidate), "--json", *extra)


class ComparisonVerdicts(ReportFixture):
    def test_regression_beyond_noise_fails_the_comparison(self) -> None:
        base = self.write("base", samples({"cpu.instructions": ("instructions", "lower", [100, 101, 99, 100, 100])}))
        worse = self.write("worse", samples({"cpu.instructions": ("instructions", "lower", [130, 131, 129, 130, 130])}))
        result = self.compare(base, worse)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["metrics"]["cpu.instructions"]["verdict"], "regression")

    def test_improvement_and_noise_do_not_fail(self) -> None:
        base = self.write("base", samples({
            "cpu.instructions": ("instructions", "lower", [100, 101, 99, 100, 100]),
            "wall.time": ("ns", "lower", [80, 95, 100, 105, 120]),
        }))
        better = self.write("better", samples({
            "cpu.instructions": ("instructions", "lower", [70, 71, 69, 70, 70]),
            "wall.time": ("ns", "lower", [90, 105, 110, 115, 130]),
        }))
        result = self.compare(base, better)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        verdicts = json.loads(result.stdout)["metrics"]
        self.assertEqual(verdicts["cpu.instructions"]["verdict"], "improvement")
        # A 10% move inside a wide spread is noise, not a regression.
        self.assertEqual(verdicts["wall.time"]["verdict"], "unchanged")

    def test_single_unit_count_change_is_noise(self) -> None:
        # A run that sends one extra frame on every iteration has zero spread;
        # 28 vs 27 frames is 3.7% but must not fail a change.
        base = self.write("base", samples({"wire.mobile.session.snapshot.frames": ("count", "lower", [27, 27, 27])}))
        extra = self.write("extra", samples({"wire.mobile.session.snapshot.frames": ("count", "lower", [28, 28, 28])}))
        result = self.compare(base, extra)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["metrics"]["wire.mobile.session.snapshot.frames"]["verdict"], "unchanged")
        more = self.write("more", samples({"wire.mobile.session.snapshot.frames": ("count", "lower", [29, 29, 29])}))
        self.assertEqual(self.compare(base, more).returncode, 3)

    def test_higher_is_better_inverts_the_verdict(self) -> None:
        base = self.write("base", samples({"frames.presented": ("count", "higher", [60, 60, 60, 60, 60])}))
        fewer = self.write("fewer", samples({"frames.presented": ("count", "higher", [40, 40, 40, 40, 40])}))
        result = self.compare(base, fewer)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["metrics"]["frames.presented"]["verdict"], "regression")

    def test_missing_or_relabeled_metrics_are_never_read_as_values(self) -> None:
        base = self.write("base", samples({
            "disk.bytes_written": ("B", "lower", [10, 10, 10]),
            "wakeups.idle": ("count", "lower", [5, 5, 5]),
        }))
        changed = self.write("changed", samples({
            "disk.bytes_written": ("KiB", "lower", [1, 1, 1]),
            "energy.cpu": ("nJ", "lower", [1, 1, 1]),
        }))
        verdicts = json.loads(self.compare(base, changed).stdout)["metrics"]
        self.assertEqual(verdicts["disk.bytes_written"]["verdict"], "incomparable")
        self.assertEqual(verdicts["wakeups.idle"]["verdict"], "missing-in-candidate")
        self.assertEqual(verdicts["energy.cpu"]["verdict"], "missing-in-base")

    def test_different_scenarios_are_refused_without_explicit_consent(self) -> None:
        base = self.write("base", samples({"cpu.time": ("ns", "lower", [1, 1, 1])}), scenario="idle-chat")
        other = self.write("other", samples({"cpu.time": ("ns", "lower", [1, 1, 1])}), scenario="idle-dashboard")
        self.assertEqual(self.compare(base, other).returncode, 2)
        self.assertEqual(self.compare(base, other, "--allow-mismatch").returncode, 0)


    def test_traced_reports_never_decide_a_comparison(self) -> None:
        plain = self.write("plain", samples({"cpu.instructions": ("instructions", "lower", [100, 100, 100])}))
        traced_samples = samples({"cpu.instructions": ("instructions", "lower", [150, 150, 150])})
        traced_samples["context"] = {"trace": {"template": "time-profiler"}}
        traced = self.write("traced", traced_samples)
        for base, candidate in ((plain, traced), (traced, plain)):
            result = self.compare(base, candidate)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("Instruments trace", result.stderr)


class InputAdmission(ReportFixture):
    def write_raw(self, document: object) -> subprocess.CompletedProcess[str]:
        source = self.root / "raw.json"
        source.write_text(json.dumps(document))
        return self.run_report(
            "write", "--tool", "ios", "--scenario", "idle-chat",
            "--samples", str(source), "--run-dir", str(self.root / "profiles/ios/raw"), "--worktree", str(ROOT),
        )

    def test_malformed_samples_are_rejected_without_a_report(self) -> None:
        for document in (
            {"metrics": {"cpu.time": {"unit": "ns", "better": "lower", "values": [1]}}},
            samples({"cpu.time": ("ns", "sideways", [1])}),
            samples({"cpu.time": ("ns", "lower", [])}),
            {"schema": "tron.profile-samples.v1", "metrics": {"cpu.time": {"unit": "ns", "better": "lower", "values": [float("nan")]}}},
        ):
            with self.subTest(document=document):
                self.assertEqual(self.write_raw(document).returncode, 2)
                self.assertFalse((self.root / "profiles/ios/raw/report.json").exists())

    def test_truncated_report_is_rejected(self) -> None:
        base = self.write("base", samples({"cpu.time": ("ns", "lower", [1, 1, 1])}))
        broken = self.root / "broken"
        broken.mkdir()
        (broken / "report.json").write_text('{"schema": "tron.profile-report.v1", "metr')
        self.assertEqual(self.compare(base, broken).returncode, 2)

    def test_latest_link_names_the_newest_complete_run(self) -> None:
        self.write("first", samples({"cpu.time": ("ns", "lower", [1, 1, 1])}))
        second = self.write("second", samples({"cpu.time": ("ns", "lower", [2, 2, 2])}))
        latest = self.root / "profiles/ios/latest"
        self.assertEqual(latest.resolve(), second.resolve())
        result = subprocess.run([str(FRONT_DOOR), "status"], capture_output=True, text=True, env=self.environment, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ios: latest idle-chat run second", result.stdout)


def load_gateway_profiler():
    sys.path.insert(0, str(ROOT / "scripts"))
    loader = SourceFileLoader("tron_profile_gateway", str(GATEWAY_PROFILER))
    module = module_from_spec(spec_from_loader(loader.name, loader))
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


def tree_digest(root: Path, fixture: Path) -> str:
    """Content digest with the generating fixture's absolute and encoded paths removed."""
    encoded = str(fixture).lstrip("/").replace("/", "-").encode()
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: str(item).replace(str(fixture), "")):
        if path.is_file():
            name = str(path.relative_to(root)).encode().replace(encoded, b"")
            content = path.read_bytes().replace(str(fixture).encode(), b"").replace(encoded, b"")
            digest.update(name + b"\0" + content)
    return digest.hexdigest()


class MultiSessionCatalog(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def generate(self, name: str, seed: int = 2027, files: int = 240, mebibytes: int = 48) -> dict:
        base = self.root / name
        config = {
            "gatewayDir": str(ROOT / "packages/gateway"), "agentDir": str(base / "agent"), "workspace": str(base / "workspace"),
            "seed": seed, "files": files, "bytes": mebibytes * 1024 * 1024, "runSessions": 8, "coldSessions": 12,
            "appendTargets": 4, "output": str(base / "catalog.json"),
        }
        base.mkdir()
        (base / "config.json").write_text(json.dumps(config))
        result = subprocess.run([NODE, str(DRIVER), "catalog", str(base / "config.json")], capture_output=True,
                                text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((base / "catalog.json").read_text())

    def test_same_seed_generates_the_same_tree_and_another_seed_does_not(self) -> None:
        first, second, other = self.generate("first"), self.generate("second"), self.generate("other", seed=7)
        # Headers carry absolute paths under each fixture, so compare with the fixture prefix removed.
        self.assertEqual(tree_digest(Path(first["root"]), self.root / "first"),
                         tree_digest(Path(second["root"]), self.root / "second"))
        self.assertEqual(first["digest"], second["digest"])
        self.assertNotEqual(first["digest"], other["digest"])

    def test_catalog_follows_the_gateway_delegated_session_layout(self) -> None:
        manifest = self.generate("layout")
        root = Path(manifest["root"])
        files = sorted(root.rglob("*.jsonl"))
        self.assertEqual(len(files), manifest["files"])
        self.assertEqual(sum(path.stat().st_size for path in files), manifest["bytes"])
        self.assertLess(abs(manifest["bytes"] / (48 * 1024 * 1024) - 1), 0.1)
        kinds = {"session": 0, "fork": 0, "subagent": 0}
        for path in files:
            lines = path.read_text().splitlines()
            header = json.loads(lines[0])
            self.assertEqual(header["type"], "session", path)
            relative = path.relative_to(root).parts
            if len(relative) == 2:
                kinds["session"] += 1
                self.assertNotIn("parentSession", header)
            elif relative[-2] == "forks":
                kinds["fork"] += 1
                self.assertEqual(header["parentSession"], str(path.parent.parent) + ".jsonl")
            else:
                kinds["subagent"] += 1
                self.assertEqual(path.name, "session.jsonl")
                self.assertRegex(relative[-2], r"^run-\d+$")
                self.assertEqual(header["parentSession"], str(path.parent.parent.parent) + ".jsonl")
            if "parentSession" in header:
                self.assertTrue(Path(header["parentSession"]).is_file(), header["parentSession"])
            # Pi's session tree: every entry's parent is the entry before it.
            previous = None
            for line in lines[1:]:
                entry = json.loads(line)
                self.assertEqual(entry["parentId"], previous, path)
                previous = entry["id"]
        self.assertEqual(kinds, {"session": manifest["sessions"], "fork": manifest["forks"],
                                 "subagent": manifest["subagentRuns"]})
        large = [item["bytes"] for item in manifest["large"]]
        self.assertEqual(len(large), 5)
        self.assertEqual(large, sorted(large))
        self.assertGreater(min(large), max(item["bytes"] for item in manifest["coldPool"]))
        self.assertEqual(len(manifest["runPool"]), 8)
        self.assertEqual(len(manifest["coldPool"]), 12)
        for target in manifest["appendTargets"]:
            self.assertEqual(Path(target).name, "session.jsonl")


INTERRUPT_HARNESS = """
import os
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
sys.path.insert(0, sys.argv[1] + "/scripts")
loader = SourceFileLoader("tron_profile_gateway", sys.argv[1] + "/scripts/tron-profile-gateway")
profiler = module_from_spec(spec_from_loader(loader.name, loader))
sys.modules[loader.name] = profiler
loader.exec_module(profiler)
mode, results = sys.argv[2], Path(sys.argv[3])
if mode == "fail-after-catalog":
    def start(self, deadline_seconds=90):
        raise profiler.ProfileFailure("injected fixture start failure", profiler.EXIT_FIXTURE)
    profiler.FixtureGateway.start = start
elif mode == "fixture-survives":
    class LiveFixture:
        # A fixture child that is still running: poll() never reports it gone.
        pid = os.getpid()

        @staticmethod
        def poll():
            return None

    def start(self, deadline_seconds=90):
        # The cleanup decision needs a live child, not a Gateway, so no process
        # is started here and the test can leak none.
        self.process = LiveFixture()

    def stop(self):
        raise profiler.ProfileFailure("refusing to signal PID: not the owned fixture Gateway", profiler.EXIT_FIXTURE)

    def run_multi_driver(fixture, run_dir, phase, label, workload):
        raise profiler.ProfileFailure("injected driver failure", profiler.EXIT_MEASUREMENT)

    profiler.FixtureGateway.start = start
    profiler.FixtureGateway.stop = stop
    profiler.run_multi_driver = run_multi_driver
profiler.install_interrupt_handlers()
args = profiler.parse(["--scenario", "multi-session", "--iterations", "1", "--catalog-files", sys.argv[4],
                       "--catalog-mib", sys.argv[5]])
args.host_state = {}
try:
    profiler.run_multi_session(args, results)
except profiler.Interrupted:
    sys.exit(130)
except profiler.ProfileFailure as failure:
    sys.exit(failure.code)
"""


class MultiSessionCleanup(unittest.TestCase):
    """The generated catalog never outlives the run on a failure or interruption."""

    def setUp(self) -> None:
        self.profiler = load_gateway_profiler()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.environment = {**os.environ, "TMPDIR": str(self.tmp),
                            "PATH": f"{Path(NODE).parent}{os.pathsep}{os.environ.get('PATH', '')}"}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def harness(self, mode: str, files: str, mebibytes: str) -> subprocess.Popen[str]:
        return subprocess.Popen([sys.executable, "-c", INTERRUPT_HARNESS, str(ROOT), mode, str(self.root / "results"),
                                 files, mebibytes], env=self.environment, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)

    def assert_removed(self) -> None:
        self.assertEqual([path.name for path in self.tmp.iterdir()], [])
        failures = list((self.root / "results").glob("*/failure.json"))
        self.assertEqual(len(failures), 1)

    def test_failure_after_generation_removes_the_catalog_and_home(self) -> None:
        process = self.harness("fail-after-catalog", "200", "64")
        _, stderr = process.communicate(timeout=300)
        self.assertEqual(process.returncode, 5, stderr)
        self.assert_removed()

    def test_interrupt_during_generation_stops_the_generator_and_removes_the_catalog(self) -> None:
        process = self.harness("interrupt", "3000", "1024")
        try:
            deadline = time.monotonic() + 120
            while not any(self.tmp.glob("tron-profile-gateway-*/agent/sessions/*/*.jsonl")):
                if process.poll() is not None:
                    self.fail(f"harness exited {process.returncode} before generating: {process.communicate()[1]}")
                self.assertLess(time.monotonic(), deadline, "generation never started")
                time.sleep(0.02)
            process.send_signal(signal.SIGINT)
            _, stderr = process.communicate(timeout=120)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(process.returncode, 130, stderr)
        self.assert_removed()

    def test_a_fixture_that_cannot_be_stopped_keeps_its_home_but_not_the_catalog(self) -> None:
        process = self.harness("fixture-survives", "200", "64")
        _, stderr = process.communicate(timeout=300)
        self.assertEqual(process.returncode, 5, stderr)
        homes = [path for path in self.tmp.iterdir() if path.name.startswith("tron-profile-gateway-")]
        self.assertEqual(len(homes), 1, "the surviving fixture home is kept as evidence")
        self.assertEqual([path.name for path in self.tmp.iterdir()], [home.name for home in homes])
        self.assertTrue((homes[0] / self.profiler.FIXTURE_MARKER).is_file())
        self.assertFalse((homes[0] / "agent/sessions").exists(), "the generated catalog is still deleted")
        self.assertEqual(len(list((self.root / "results").glob("*/failure.json"))), 1)


class InterruptibleRemoval(unittest.TestCase):
    """A first Ctrl-C during cleanup must not leave a partial removal behind."""

    def setUp(self) -> None:
        self.profiler = load_gateway_profiler()

    def test_a_removal_interrupted_by_a_signal_is_resumed_and_the_signal_reraised(self) -> None:
        attempts: list[int] = []

        def action() -> None:
            attempts.append(len(attempts))
            if len(attempts) == 1:
                raise self.profiler.Interrupted(signal.SIGINT)

        with self.assertRaises(self.profiler.Interrupted):
            self.profiler.removal_to_completion(action)
        self.assertEqual(len(attempts), 2, "the interrupted removal resumed to completion")

    def test_every_action_finishes_before_the_interrupt_is_reraised(self) -> None:
        order: list[str] = []

        def catalog() -> None:
            order.append("catalog")
            if order.count("catalog") == 1:
                raise self.profiler.Interrupted(signal.SIGTERM)

        def home() -> None:
            order.append("home")

        with self.assertRaises(self.profiler.Interrupted):
            self.profiler.removal_to_completion(catalog, home)
        self.assertEqual(order, ["catalog", "catalog", "home"])


class InterruptibleStop(unittest.TestCase):
    """A first Ctrl-C must reach the caller instead of being swallowed.

    `stop()` ignores every later SIGINT/SIGTERM/SIGHUP, so an `Interrupted`
    lost inside its `finally` leaves the run unstoppable."""

    def setUp(self) -> None:
        self.profiler = load_gateway_profiler()

    def test_an_interrupt_during_the_post_kill_wait_is_reraised(self) -> None:
        profiler = self.profiler
        interrupt = profiler.Interrupted(signal.SIGINT)

        class Process:
            """A live child whose post-SIGKILL wait receives the Ctrl-C."""
            pid = 424242

            def __init__(self) -> None:
                self.waits = 0
                self.killed = False

            def poll(self):
                return None

            def send_signal(self, number: int) -> None:
                pass

            def kill(self) -> None:
                self.killed = True

            def wait(self, timeout=None):
                self.waits += 1
                if self.waits == 2:
                    raise interrupt
                return 0

        fixture = profiler.FixtureGateway(tempfile.mkdtemp(), 0, None)
        self.addCleanup(shutil.rmtree, fixture.root, True)
        process = Process()
        fixture.process = process
        groups: list[int] = []
        matched, killpg = profiler.FixtureGateway.command_matches, profiler.os.killpg
        profiler.FixtureGateway.command_matches = lambda self: True
        profiler.os.killpg = lambda pid, number: groups.append((pid, number))
        try:
            with self.assertRaises(profiler.Interrupted):
                fixture.stop()
        finally:
            profiler.FixtureGateway.command_matches, profiler.os.killpg = matched, killpg
        # The group kill still ran, so the interrupt did not skip the cleanup it
        # was passed through the `finally` for.
        self.assertEqual(groups, [(process.pid, signal.SIGKILL)])


class InterruptedHomeRemoval(unittest.TestCase):
    """A Ctrl-C inside the home removal must not leave a half-deleted home.

    `rmtree` deletes the ownership marker on its way through the home, so a
    resumed removal that re-checked the marker would find nothing to do and
    leave the rest behind."""

    def setUp(self) -> None:
        self.profiler = load_gateway_profiler()

    def test_a_home_removal_interrupted_after_its_marker_is_gone_still_finishes(self) -> None:
        profiler = self.profiler
        fixture = profiler.FixtureGateway(tempfile.mkdtemp(), 0, None)
        self.addCleanup(shutil.rmtree, fixture.root, True)
        (fixture.catalog / "child").mkdir(parents=True)
        (fixture.catalog / "a.jsonl").write_text("{}\n")
        (fixture.root / "leftover").write_text("x")
        fixture.process = None  # a dead child: the home may be removed
        rmtree, calls = profiler.shutil.rmtree, []

        def interrupted(path, *args, **kwargs):
            if not calls and Path(path) == fixture.root:
                calls.append(Path(path))
                # What an interrupt inside rmtree(root) leaves: some entries
                # gone, the ownership marker among them, the rest still there.
                (fixture.root / profiler.FIXTURE_MARKER).unlink()
                (fixture.root / "leftover").unlink()
                raise profiler.Interrupted(signal.SIGINT)
            return rmtree(path, *args, **kwargs)

        profiler.shutil.rmtree = interrupted
        try:
            with self.assertRaises(profiler.Interrupted):
                profiler.removal_to_completion(*fixture.removals())
        finally:
            profiler.shutil.rmtree = rmtree
        self.assertEqual(len(calls), 1, "the injected interrupt landed in the home removal")
        self.assertFalse(fixture.root.exists(), "the resumed removal finished the half-deleted home")

    def test_a_home_that_is_not_this_profiler_s_fixture_is_never_removed(self) -> None:
        profiler = self.profiler
        fixture = profiler.FixtureGateway(tempfile.mkdtemp(), 0, None)
        self.addCleanup(shutil.rmtree, fixture.root, True)
        (fixture.root / profiler.FIXTURE_MARKER).unlink()
        self.assertEqual(fixture.removals(), [], "ownership must be proved before any removal runs")
        self.assertTrue(fixture.root.exists())


# A stand-in for the fixture Gateway's WebSocket surface, used by the
# multi-session driver tests: it answers the driver's requests, journals how
# every connection closed, and can fail the dashboard's list, hold one session
# open past the window's deadline, or bind a fixed port (so a restart can reuse
# it) on demand.
STUB_GATEWAY = """
import { createRequire } from "node:module";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [gatewayDir, configPath] = process.argv.slice(2);
const config = JSON.parse(readFileSync(configPath, "utf8"));
const { WebSocketServer } = createRequire(join(gatewayDir, "package.json"))("ws");
let sequence = 0;
let lists = 0;
// The phone is the client that mounts a chat (the dashboard and the other
// clients never set a presentation lease), which is how a test can ask the
// stub to close the mobile socket at a known point in the run.
let mobileClientId = null;
let mobileOpens = 0;
// The first connection the mobile identifies itself on: the mixed window's, before
// a leg rebuilds the socket on the relay (see `pongDelayFirstMobileConnection`).
let delayedMobileConnection = false;
const server = new WebSocketServer({ port: config.port ?? 0, perMessageDeflate: false, autoPong: false });
server.on("listening", () => writeFileSync(config.portFile, String(server.address().port)));
process.on("SIGTERM", () => process.exit(0));
process.on("SIGUSR2", () => {
  sequence += 1;
  writeFileSync(config.probeOutput, JSON.stringify({
    sequence, catalogWalks: sequence, eventLoopDelay: { p99Ms: 0, maxMs: 0 },
    heapUsedPeakBytes: 1024, heapLimitBytes: 4096, rssPeakBytes: 2048,
  }));
});
server.on("connection", (socket) => {
  let clientId = null;
  let delayThisConnection = false;
  socket.on("error", () => {});
  // Answer pings like ws's own autoPong, with a delay a test can ask for: a late
  // pong is what a backed-up path produces, and it must be charged to the ping it
  // answers rather than to the newest one.
  socket.on("ping", (data) => {
    if (config.pongDelayFirstMobileConnection && !delayThisConnection && !delayedMobileConnection
        && clientId !== null && clientId === mobileClientId) {
      delayThisConnection = true;
      delayedMobileConnection = true;
    }
    const delay = config.pongDelayMs && (!config.pongDelayFirstMobileConnection || delayThisConnection)
      ? config.pongDelayMs : 0;
    if (delay > 0) { setTimeout(() => { if (socket.readyState === 1) socket.pong(data); }, delay); return; }
    socket.pong(data);
  });
  socket.on("close", (code, reason) => appendFileSync(config.journal, `${JSON.stringify({ code, reason: reason.toString() })}\\n`));
  socket.on("message", (data) => {
    let frame;
    try { frame = JSON.parse(data.toString("utf8")); } catch { return; }
    if (frame.type === "hello") {
      clientId = frame.clientId ?? null;
      return socket.send(JSON.stringify({ type: "hello", protocolVersion: 6, gatewayVersion: "stub" }));
    }
    if (frame.type !== "request") return;
    const reply = (result) => socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result }));
    if (frame.method === "session.list") {
      lists += 1;
      if (config.failListAfter !== null && lists > config.failListAfter) {
        return socket.send(JSON.stringify({ type: "response", id: frame.id, ok: false,
          error: { code: "internal", message: "stub: injected list failure", retryable: false } }));
      }
      return reply({ sessions: [] });
    }
    if (frame.method === "session.presentation.set") mobileClientId = clientId;
    if (frame.method === "session.open") {
      const sessionId = frame.params.sessionId;
      const opened = () => reply({ subscriptionToken: `sub-${sessionId}`, syncToken: `sync-${sessionId}`,
        session: { sessionId, runtimeGeneration: "stub-generation", eventSequence: 1, transcript: [], transcriptTotal: 0 } });
      if (clientId !== null && clientId === mobileClientId) {
        mobileOpens += 1;
        if (config.closeMobileOnOpen && mobileOpens === config.closeMobileOnOpen) {
          opened();
          return socket.close(1013, "stub closes the mobile socket");
        }
        // A close pinned to one session, so a test can put it inside a named leg
        // rather than count the mobile's opens across a whole run.
        if (config.closeMobileOnOpenSession && sessionId === config.closeMobileOnOpenSession) {
          opened();
          return socket.close(1013, "stub closes the mobile socket");
        }
      }
      if (config.delayOpenSessionId === sessionId) return setTimeout(opened, config.delayMs);
      return opened();
    }
    if (frame.method === "session.sync") return reply({ synchronized: true });
    return reply({});
  });
});
"""


class StubGatewayHarness:
    """A driver run against a stub Gateway surface, shared by the multi-driver
    test classes: the stub process, the driver subprocess and the result file."""

    def setUp(self) -> None:
        self.profiler = load_gateway_profiler()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        (self.root / "stub-gateway.mjs").write_text(STUB_GATEWAY)
        (self.root / "child.jsonl").write_text(json.dumps({"type": "message", "id": "seed-0"}) + "\n")
        (self.root / "devices.json").write_text(json.dumps(
            {name: "stub-token" for name in ("mobile", "dashboard", "dashboard-reconnect", "driver", "warm", "large")}))
        self.stubs: list[subprocess.Popen[str]] = []

    def tearDown(self) -> None:
        for stub in self.stubs:
            if stub.poll() is None:
                stub.terminate()
                try:
                    stub.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    stub.kill()
                    stub.wait(timeout=10)
            if stub.stdout is not None:
                stub.stdout.close()
        self.temporary.cleanup()

    def start_stub(self, fail_list_after: int | None, delay_open_session_id: str | None = None,
                   delay_ms: int = 0, port: int | None = None, **extra: object) -> subprocess.Popen[str]:
        # A stale port file from a predecessor would be read as this one's.
        (self.root / "port").unlink(missing_ok=True)
        config = {"journal": str(self.root / "closes.jsonl"), "portFile": str(self.root / "port"),
                  "probeOutput": str(self.root / "probe.json"), "failListAfter": fail_list_after,
                  "delayOpenSessionId": delay_open_session_id, "delayMs": delay_ms, **extra,
                  **({'port': port} if port is not None else {})}
        (self.root / "stub-config.json").write_text(json.dumps(config))
        stub = subprocess.Popen([NODE, str(self.root / "stub-gateway.mjs"), str(ROOT / "packages/gateway"),
                                 str(self.root / "stub-config.json")], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True)
        self.stubs.append(stub)
        deadline = time.monotonic() + 30
        while not (self.root / "port").exists():
            self.assertIsNone(stub.poll(), "the stub Gateway exited before it listened")
            self.assertLess(time.monotonic(), deadline, "the stub Gateway never listened")
            time.sleep(0.02)
        return stub

    def stop_stub(self, stub: subprocess.Popen[str]) -> None:
        if stub.poll() is None:
            stub.terminate()
            try:
                stub.wait(timeout=10)
            except subprocess.TimeoutExpired:
                stub.kill()
                stub.wait(timeout=10)
        if stub.stdout is not None:
            stub.stdout.close()

    def restart_fixture(self, port: int, gap_seconds: float = 1.0, health_delay_seconds: float = 0.0,
                        **extra: object) -> object:
        """The profiler's side of the restart handshake as `wait_with_restart`
        uses it: an owned child and a restart that replaces the stub Gateway on
        the same port after a real gap, so the clients meet a refused connect
        while it is down. The replacement carries the same stub configuration,
        so a behaviour the test asked for survives the restart. `health_delay_
        seconds` stands in for the profiler's own health check: the new Gateway
        already serves requests while the answer (and so `restoredAtMs`) is
        still seconds away."""
        harness = self

        class RestartFixture:
            def __init__(self) -> None:
                self.process = harness.stubs[-1]

            def restart(self) -> None:
                harness.stop_stub(harness.stubs[-1])
                time.sleep(gap_seconds)
                self.process = harness.start_stub(None, port=port, **extra)
                time.sleep(health_delay_seconds)

        return RestartFixture()

    def driver_config(self, port: int, run_dir: Path, label: str, seconds: float, **overrides) -> Path:
        config = {**self.profiler.MULTI, "connection": self.profiler.CONNECTION,
                  "gatewayDir": str(ROOT / "packages/gateway"),
                  "orchestrator": str(GATEWAY_PROFILER), "gatewayPid": self.stubs[-1].pid, "port": port,
                  "tronHome": str(self.root / "tron"), "outputDir": str(run_dir), "phase": "iteration", "label": label,
                  "devicesPath": str(self.root / "devices.json"), "probeOutput": str(self.root / "probe.json"),
                  "mixedSeconds": seconds, "noSubscriberSeconds": 2, "settleBeforeMs": 200,
                  "running": [{"sessionId": "stub-run-1"}], "cold": [], "large": [],
                  "appendTargets": [str(self.root / "child.jsonl")], "listIntervalMs": 500, "proberIntervalMs": 500,
                  "cases": [], **overrides}
        config_path = run_dir / "driver-config.json"
        config_path.write_text(json.dumps(config, indent=2))
        return config_path

    def driver_environment(self) -> dict[str, str]:
        return {**os.environ, "PATH": f"{Path(NODE).parent}{os.pathsep}{os.environ.get('PATH', '')}"}

    def run_driver(self, fail_list_after: int | None = None, seconds: float = 10, cold: tuple[str, ...] = (),
                   delay_open_ms: int | None = None,
                   timeout: float = 90) -> tuple[int, str, float]:
        delayed = cold[0] if cold and delay_open_ms else None
        self.start_stub(fail_list_after, delayed, delay_open_ms or 0)
        run_dir = self.root / "run"
        run_dir.mkdir(exist_ok=True)
        config_path = self.driver_config(int((self.root / "port").read_text()), run_dir, "stub", seconds,
                                         cold=[{"sessionId": name} for name in cold])
        started = time.monotonic()
        driver = subprocess.Popen([NODE, str(DRIVER), "multi", str(config_path)], stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, env=self.driver_environment())
        try:
            output, _ = driver.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            driver.kill()
            output, _ = driver.communicate()
            self.fail(f"the driver did not exit within {timeout} s:\n{output[-2_000:]}")
        return driver.returncode, output, round(time.monotonic() - started, 1)

    def run_impairment(self, cases: list[str], overrides: dict, restart_stub: bool = False,
                       stub_config: dict | None = None, health_delay_seconds: float = 0.0,
                       timeout: float = 180) -> tuple[int, str, dict]:
        """One iteration at a short boundary, running only the given impairment
        cases. With `restart_stub` the profiler's own `wait_with_restart` plays
        the restart handshake against a stand-in for its fixture Gateway: it
        answers the driver's request by replacing the stub on the same port and
        tells the driver when the new one was listening."""
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        self.start_stub(None, port=port, **(stub_config or {}))
        run_dir = self.root / "impaired"
        run_dir.mkdir(exist_ok=True)
        config_path = self.driver_config(port, run_dir, "impaired", 4, cases=cases, **overrides)
        request_path = run_dir / "restart-request-impaired.json"
        done_path = run_dir / "restart-done-impaired.json"
        for path in (request_path, done_path):
            path.unlink(missing_ok=True)
        driver = subprocess.Popen([NODE, str(DRIVER), "multi", str(config_path)], stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, env=self.driver_environment())
        if restart_stub:
            status = self.profiler.wait_with_restart(
                driver, self.restart_fixture(port, health_delay_seconds=health_delay_seconds, **(stub_config or {})),
                request_path, done_path, timeout, "impaired", run_dir / "driver-impaired.log")
        else:
            try:
                status = driver.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                driver.kill()
                output, _ = driver.communicate()
                self.fail(f"the driver did not exit within {timeout} s:\n{output[-2_000:]}")
        output, _ = driver.communicate()
        result_path = run_dir / "result-impaired.json"
        result = json.loads(result_path.read_text()) if result_path.is_file() else {}
        return status, output, result

    def closes(self, expected: str) -> list[dict]:
        deadline = time.monotonic() + 5
        journal = self.root / "closes.jsonl"
        while True:
            records = [json.loads(line) for line in journal.read_text().splitlines()] if journal.is_file() else []
            if any(record["reason"] == expected for record in records) or time.monotonic() > deadline:
                return records
            time.sleep(0.05)

class MultiDriverWindows(StubGatewayHarness, unittest.TestCase):
    """The multi-session driver's fixed window, its tail and its cleanup.

    Failure modes written down before this harness: a lane that fails inside
    the window must not become an unhandled rejection, which kills the process
    before `multi`'s `finally` (the appender is never stopped, the clients are
    never closed and `timeline.jsonl` is never flushed); and the tail's timer
    must not keep the driver (and its parent) alive for its full grace period
    after a window that closed on its deadline.
    """

    def test_a_lane_that_fails_inside_the_window_still_closes_the_clients(self) -> None:
        status, output, _ = self.run_driver(fail_list_after=1)
        self.assertNotEqual(status, 0, "a failing lane is fatal")
        self.assertIn("stub: injected list failure", output)
        records = self.closes("profile complete")
        self.assertTrue(any(record["reason"] == "profile complete" for record in records),
                        f"the driver's finally did not close its clients: {records}")

    def test_the_tail_timer_does_not_outlive_the_window(self) -> None:
        status, output, seconds = self.run_driver()
        self.assertEqual(status, 0, output)
        self.assertTrue((self.root / "run/result-stub.json").is_file(), "the iteration did not finish")
        self.assertLess(seconds, 40, f"the driver idled {seconds} s after a {self.profiler.MULTI['tailGraceMs'] / 1000:.0f} s "
                                     "tail; the tail's timer was not cleared")

    def test_an_operation_that_cannot_start_inside_the_window_is_not_measured(self) -> None:
        # The cold lane's open finishes only after the 10 s window has closed:
        # its prompt must not be timed then (the other lanes have stopped), and
        # the result must hold the sample set the window's tail froze.
        status, output, _ = self.run_driver(seconds=10, cold=("stub-cold-1",), delay_open_ms=12_000)
        self.assertEqual(status, 0, output)
        result = json.loads((self.root / "run/result-stub.json").read_text())
        self.assertEqual(len(result["samples"]["sessionOpenCold"]), 1, "the cold open was measured")
        self.assertGreater(result["samples"]["sessionOpenCold"][0], 10_000, "the cold open outlasted the window")
        self.assertEqual(result["samples"]["promptAdmission"], [],
                         "a prompt started after the deadline was measured")


class MultiDriverImpairment(StubGatewayHarness, unittest.TestCase):
    """The impairment legs, each against the stub Gateway.

    Failure modes written down before these: a blackhole that is not counted
    (no attempt made during the outage) or whose recovery is timed from the
    attempt loop instead of from the path's return, so it reports one fast
    connect however long the outage really cost; a blackhole whose abandon is
    driven by the leg's own clock rather than by a counted pong miss, so it
    reports a fixed silence whatever the client saw; a path that lets an attempt
    made during the outage succeed (the blackhole is not one) or that drops an
    attempt a returned path should carry; a bandwidth leg whose cap never
    delays a byte (the cap is then untested) or that loses a pong it should
    not; a restart case that measures the storm only after the slowest client
    returned, so the slow requests the storm is about are left out; a restart
    case that treats the Gateway's own close as a failure, that leaves a
    connected client down, that reports a reconnect without the downtime's
    failed attempts, or that waits for the profiler's answer forever; and an
    unexpected close after an impairment leg going uncounted.
    """

    # A connection fast enough for a pong miss to be counted inside a short
    # leg; the phone's own contract values are exercised by the default runs.
    FAST_CONNECTION = {"pingIntervalMs": 300, "pongDeadlineMs": 200,
                      "transportOpenDeadlineMs": 8_000, "helloDeadlineMs": 8_000}

    def test_the_blackhole_counts_its_attempts_and_recovers_to_a_ready_chat(self) -> None:
        # The path returns 5 s into an 8 s transport-open attempt: the recovery
        # must include the rest of that attempt, not only the connect that
        # follows it. The path's return cancels a pending backoff *wait* (C-3),
        # never an attempt already on the wire, so this attempt still times out.
        status, output, result = self.run_impairment(["blackhole"], {
            "blackholeSeconds": 5, "blackholeSettleMs": 400,
            "connection": dict(self.FAST_CONNECTION),
            "measuredDeadlineMs": 30_000,
        })
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["blackhole"]
        self.assertGreaterEqual(leg["attemptsDuringOutage"], 1,
                               "an attempt must be made (and fail) while the path delivers nothing")
        self.assertTrue(any(attempt.get("failed") for attempt in leg["attempts"]),
                        f"no attempt failed during the outage: {leg['attempts']}")
        self.assertIsNotNone(leg["recoveryReadyMs"], "the recovery to a ready mounted chat was not timed")
        self.assertGreater(leg["recoveryReadyMs"], 4_000,
                           "the recovery was timed from the attempt's start, not from the path's return")
        self.assertTrue(leg["abandonedOnMiss"],
                        "the abandon must follow a counted pong miss, not the leg's own clock")
        liveness_ms = 300 + 200
        self.assertGreaterEqual(leg["silenceMs"], liveness_ms,
                               "silence is measured from the last inbound frame, one liveness window long")
        self.assertLess(leg["silenceMs"], 2_000,
                        "the socket is abandoned one liveness window after the last inbound frame")

    def test_the_bandwidth_cap_meters_the_path_without_losing_the_socket(self) -> None:
        # Three sessions, so the leg has three page mounts in flight at once:
        # one at a time it can put at most one page ahead of a queued pong, and
        # "zero pong misses" would then say nothing about the cap.
        status, output, result = self.run_impairment(["bandwidth"], {
            "bandwidthMbps": 0.2, "bandwidthLegSeconds": 5, "bandwidthInFlight": 3,
            "running": [{"sessionId": "stub-run-1"}, {"sessionId": "stub-run-2"}, {"sessionId": "stub-run-3"}],
            # Frequent pings with room for a pong despite the cap, so the leg's
            # round-trip metric has samples and the deadline is not the test.
            "connection": {"pingIntervalMs": 300, "pongDeadlineMs": 2_000,
                                     "transportOpenDeadlineMs": 8_000, "helloDeadlineMs": 8_000},
        })
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["bandwidth"]
        self.assertGreaterEqual(leg["seconds"], 5, "the leg ran its full duration, not a fixed count of operations")
        self.assertGreater(leg["deliveredBytes"], 0, "the capped path carried nothing")
        self.assertLessEqual(leg["deliveredBytesPerSecond"], leg["capBitsPerSecond"] / 8 * 1.5,
                             "the meter delivered more than the cap allows")
        self.assertLessEqual(leg["linkUse"], 1.5, "link use is the delivered rate over the cap")
        self.assertGreaterEqual(leg["maxInFlight"], 2,
                                "the leg ran one page at a time: a queued pong could never be late")
        self.assertGreater(leg["offeredInFlightBytes"], 0, "the leg reported no offered load")
        self.assertIsNotNone(leg["maxPingToPongMs"], "the mobile's ping-to-pong round trip was not reported")
        self.assertLess(leg["maxPingToPongMs"], 1_000,
                        "a pong was late on a path whose pages are a few hundred bytes")
        self.assertEqual(leg["pongDeadlineMisses"], 0, "a capped path that carries data must not lose a pong")
        self.assertEqual(leg["unexpectedCloses"], 0, "the Gateway closed a socket on the capped path")

    def test_the_restart_case_counts_the_storm_from_the_restore(self) -> None:
        # The mobile's first open after the restart is delayed past the request
        # deadline's 1 s boundary. That request is the storm: a case that started
        # measuring once every client was ready would report a fast storm and
        # leave the slow one out.
        status, output, result = self.run_impairment(["restart"], {
            "restartStormSeconds": 2, "restartDeadlineMs": 30_000,
            "connection": dict(self.FAST_CONNECTION, transportOpenDeadlineMs=2_000),
        }, restart_stub=True,
            stub_config={"delay_open_session_id": "stub-run-1", "delay_ms": 2_500})
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["restart"]
        self.assertEqual(len(leg["clients"]), 3, "the restart case needs the three measured clients connected")
        self.assertGreaterEqual(len(leg["clientsAll"]), 6, "every connected client must be reported")
        for entry in leg["clientsAll"]:
            self.assertLess(-2_000, entry["reconnectMs"], f"{entry['name']} was ready before its socket closed")
            self.assertLess(entry["reconnectMs"], 10_000, f"{entry['name']} did not reconnect within 10 s")
            self.assertTrue(any(attempt.get("connected") for attempt in entry["attempts"]))
        # The clients retry from their own socket's close, so the downtime's
        # refused connects are measured, not skipped by waiting for the answer.
        self.assertGreaterEqual(sum(1 for entry in leg["clientsAll"] for attempt in entry["attempts"]
                                    if not attempt.get("connected")), 1,
                                "no client tried while the Gateway was down")
        self.assertGreater(leg["downtimeMs"], 0, "the downtime was not reported")
        storm = [request for request in leg["requests"] if not request["duringDowntime"]]
        self.assertGreaterEqual(len(storm), 3, "the storm measured no request")
        self.assertTrue(all(request["duringDowntime"] == (request.get("failed") is not None)
                            for request in leg["requests"]),
                        "a request is the downtime's by its outcome, not by when it started")
        self.assertTrue(any(request["ms"] > 1_000 for request in storm),
                        f"the slow request made while the clients came back is missing: {storm}")

    def test_a_request_served_before_the_health_stamp_is_counted_as_the_storm(self) -> None:
        # The profiler stamps `restoredAtMs` only after the new Gateway answered
        # health: polling, `ps` and writing the answer take seconds, and the new
        # Gateway serves requests in that gap. Those requests are the first and
        # most contended ones, so they must be the storm's — classified by
        # outcome, not left out because their start precedes the stamp.
        status, output, result = self.run_impairment(["restart"], {
            "restartStormSeconds": 2, "restartDeadlineMs": 30_000,
            "connection": dict(self.FAST_CONNECTION, transportOpenDeadlineMs=2_000),
        }, restart_stub=True, health_delay_seconds=4.0)
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["restart"]
        served_before_stamp = [request for request in leg["requests"]
                               if request["sinceRestoreMs"] < 0 and not request["duringDowntime"]]
        self.assertTrue(served_before_stamp,
                        f"the requests the new Gateway served before the health stamp are not counted as the "
                        f"storm: {leg['requests']}")
        self.assertTrue(all(request["failed"] is None for request in served_before_stamp),
                        "a request the new Gateway served did not fail")
        self.assertTrue(all((request["failed"] is not None) == request["duringDowntime"]
                            for request in leg["requests"]),
                        f"a request is the downtime's by its outcome: {leg['requests']}")
        self.assertTrue(all(request["ms"] is not None for request in leg["requests"]))

    def test_the_streaming_case_holds_its_streams_and_reports_the_cap(self) -> None:
        # The streaming case is only meaningful if it holds mounted chats whose
        # transcripts stream: the stub's sessions never stream, so this proves
        # the leg holds the streams and reports what it saw, not a backlog.
        status, output, result = self.run_impairment(["bandwidth-stream"], {
            "bandwidthStreamMbps": 0.5, "bandwidthStreamSeconds": 5, "bandwidthStreamSessions": 3,
            "running": [{"sessionId": f"stub-run-{index}"} for index in range(4)],
            "connection": {"pingIntervalMs": 300, "pongDeadlineMs": 2_000,
                                     "transportOpenDeadlineMs": 8_000, "helloDeadlineMs": 8_000},
        })
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["bandwidth-stream"]
        self.assertGreaterEqual(leg["seconds"], 5, "the leg ran its full duration")
        self.assertEqual(leg["streams"], 4, "the mounted chat and the three streams it opened")
        self.assertGreater(leg["payloadBytes"], 0, "the streams carried nothing")
        self.assertIsNotNone(leg["maxPingToPongMs"], "the ping-to-pong round trip was not reported")
        self.assertEqual(leg["pongDeadlineMisses"], 0, "a stub that answers at once cannot lose a pong")
        self.assertEqual(leg["unexpectedCloses"], 0, "the stub closed a socket on the capped path")

    def test_a_leg_reports_its_own_round_trip_not_the_window_before_it(self) -> None:
        # The mobile's first connection — the mixed window's — answers every pong
        # 1.5 s late; the bandwidth leg then rebuilds its socket on the relay and
        # its own pongs come back at once. A leg that reports the client's
        # lifetime maximum hands the mixed window's delay to the leg and calls it
        # this leg's backlog.
        status, output, result = self.run_impairment(["bandwidth"], {
            "bandwidthMbps": 0.05, "bandwidthLegSeconds": 3, "measuredDeadlineMs": 30_000,
            "connection": dict(self.FAST_CONNECTION),
        }, stub_config={"pongDelayMs": 1_500, "pongDelayFirstMobileConnection": True})
        self.assertEqual(status, 0, output)
        self.assertGreaterEqual(result.get("uncappedPingToPongMs") or 0, 1_400,
                                "the delayed window before the leg did not happen")
        leg = result["impairment"]["bandwidth"]
        self.assertIsNotNone(leg["maxPingToPongMs"], "the leg reported no round trip")
        self.assertLess(leg["maxPingToPongMs"], 1_000,
                        f"the leg reported the delayed window's round trip as its own: {leg['maxPingToPongMs']}")

    def test_a_late_pong_is_charged_to_the_ping_it_answers(self) -> None:
        # Every pong answers 1.5 s late, five ping intervals after its own ping:
        # charging the pong to the newest outstanding ping instead reports ~300 ms
        # for a path whose round trip is 1.5 s.
        status, output, result = self.run_impairment(["bandwidth"], {
            "bandwidthMbps": 0.05, "bandwidthLegSeconds": 5, "measuredDeadlineMs": 30_000,
            "connection": dict(self.FAST_CONNECTION),
        }, stub_config={"pongDelayMs": 1_500})
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["bandwidth"]
        self.assertIsNotNone(leg["maxPingToPongMs"], "the leg reported no round trip")
        self.assertGreaterEqual(leg["maxPingToPongMs"], 1_400,
                                f"the pong's own delay was not reported: {leg['maxPingToPongMs']}")

    def test_a_capped_legs_close_keeps_every_other_leg_and_the_restart(self) -> None:
        # The stub closes the mobile's socket when it opens the first streamed
        # session, so the close happens inside the bandwidth-stream leg. A close
        # under the cap is that case's own finding (G-4's target is zero), not a
        # broken client: the leg records it, the restart case then still runs on
        # a reconnected client, and only then is the run rejected. It must not
        # throw away the legs already measured or skip the restart.
        status, output, result = self.run_impairment(["bandwidth-stream", "restart"], {
            "bandwidthStreamMbps": 0.5, "bandwidthStreamSeconds": 3, "bandwidthStreamSessions": 3,
            "restartStormSeconds": 2, "restartDeadlineMs": 30_000,
            "running": [{"sessionId": f"stub-run-{index}"} for index in range(4)],
            "connection": {"pingIntervalMs": 300, "pongDeadlineMs": 2_000,
                                     "transportOpenDeadlineMs": 8_000, "helloDeadlineMs": 8_000},
        }, restart_stub=True, stub_config={"closeMobileOnOpenSession": "stub-run-1"})
        self.assertNotEqual(status, 0, "a close a capped leg counted must still reject the run")
        legs = result.get("impairment") or {}
        self.assertEqual((legs.get("bandwidth-stream") or {}).get("unexpectedCloses"), 1,
                         f"the leg under the cap did not record the close: {legs.get('bandwidth-stream')}")
        restart = legs.get("restart") or {}
        self.assertTrue(restart, "the restart case was skipped after a capped leg's close")
        self.assertTrue(restart.get("clientsAll"), f"the restart case reported no client: {restart}")
        self.assertTrue(all(entry.get("readyAtMs") is not None for entry in restart["clientsAll"]),
                        f"the restart left a client down: {restart['clientsAll']}")

    def test_an_unexpected_close_after_a_blackhole_is_not_excused(self) -> None:
        # The stub closes the mobile's socket on its fourth open: the mount that
        # opens the bandwidth leg, after the blackhole's settle and recovery.
        # A close the client did not ask for must be counted and must fail the
        # run: `closing` left set by the blackhole's abandon would excuse it.
        status, output, result = self.run_impairment(["blackhole", "bandwidth"], {
            "blackholeSeconds": 2, "blackholeSettleMs": 400,
            "connection": dict(self.FAST_CONNECTION, transportOpenDeadlineMs=2_000),
            "bandwidthMbps": 0.05, "bandwidthLegSeconds": 3, "measuredDeadlineMs": 30_000,
        }, stub_config={"closeMobileOnOpen": 4})
        self.assertNotEqual(status, 0, "the unexpected close was excused")
        self.assertIn("mobile closed 1013", output)
        band = (result.get("impairment") or {}).get("bandwidth") or {}
        self.assertEqual(band.get("unexpectedCloses"), 1, "the counted close is not in the leg's result")


RELAY_FLOOD = """
import { PassThrough } from "node:stream";
import { RelayDirection } from "RELAY_PATH";

// A sink that never accepts a write: the relay must pause the source instead of
// holding the flood in this process.
const floodSource = new PassThrough();
let writes = 0;
const blockedSink = { write() { writes += 1; return false; }, on() {} };
new RelayDirection(floodSource, blockedSink, () => 0, () => {});
for (let index = 0; index < 2_000; index += 1) floodSource.write(Buffer.alloc(64 * 1024));
await new Promise((resolve) => setTimeout(resolve, 250));
const blocked = { writes, paused: floodSource.isPaused(), bufferedBytes: floodSource.readableLength };

// A held direction forwards nothing while it is held: the chunks it reads wait
// for the path to return and are written in order.
const heldSource = new PassThrough();
const heldSink = { written: [], write(chunk) { this.written.push(chunk.toString()); return true; }, on() {} };
const held = new RelayDirection(heldSource, heldSink, () => 0, () => {});
held.hold();
heldSource.write("first");
heldSource.write("second");
heldSource.resume();
await new Promise((resolve) => setTimeout(resolve, 100));
const whileHeld = [...heldSink.written];
held.release();
await new Promise((resolve) => setTimeout(resolve, 100));
process.stdout.write(JSON.stringify({ blocked, whileHeld, afterRelease: heldSink.written }));
"""

PROBE_CLIENT = """
import { opendir } from "node:fs/promises";
import { readFileSync } from "node:fs";
const [catalog, output] = process.argv.slice(2);
for (const path of [catalog, catalog, `${catalog}/child`]) await (await opendir(path)).close();
process.kill(process.pid, "SIGUSR2");
await new Promise((resolve) => setTimeout(resolve, 200));
process.stdout.write(readFileSync(output, "utf8"));
"""


class RelayBackpressure(unittest.TestCase):
    """The shaped path, driven directly.

    Failure modes written down before it: a relay that ignores the sink's
    refusal holds the sender's bytes in the driver process instead of pausing
    the source (a flooding source paired with a sink that never drains put
    90 MB there in 2 s), and a relay that forwards a chunk read while the
    direction is held leaks bytes past the blackhole.
    """

    def test_a_blocked_sink_pauses_the_source_and_a_held_direction_waits(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "relay-flood.mjs"
            script.write_text(RELAY_FLOOD.replace("RELAY_PATH", RELAY.as_posix()))
            completed = subprocess.run([NODE, str(script)], capture_output=True, text=True, timeout=60)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        blocked = result["blocked"]
        self.assertLess(blocked["writes"], 5,
                        f"the relay kept writing into a full sink: {blocked}")
        self.assertTrue(blocked["paused"], f"the source was never paused: {blocked}")
        self.assertEqual(result["whileHeld"], [], "a held direction forwarded a chunk")
        self.assertEqual(result["afterRelease"], ["first", "second"],
                         "the chunks read while held are written, in order, on release")


class FixtureProbe(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        (self.root / "catalog/child").mkdir(parents=True)
        (self.root / "client.mjs").write_text(PROBE_CLIENT)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_probe(self) -> subprocess.CompletedProcess[str]:
        output = self.root / "probe.json"
        environment = {**os.environ, "TRON_PROFILE_PROBE_OUTPUT": str(output),
                       "TRON_PROFILE_PROBE_CATALOG": str(self.root / "catalog")}
        return subprocess.run([NODE, "--import", PROBE.as_uri(), str(self.root / "client.mjs"), str(self.root / "catalog"),
                               str(output)], capture_output=True, text=True, env=environment, timeout=60)

    def test_probe_refuses_to_load_outside_a_fixture(self) -> None:
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("loads only into a tron-profile fixture Gateway", result.stderr)

    def test_probe_counts_catalog_root_walks_seen_by_es_module_importers(self) -> None:
        (self.root / ".tron-profile-gateway-fixture").write_text("tron.profile-gateway-fixture.v1\n")
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads(result.stdout)
        self.assertEqual(snapshot["catalogWalks"], 2)
        self.assertGreater(snapshot["heapUsedPeakBytes"], 0)
        self.assertGreater(snapshot["heapLimitBytes"], snapshot["heapUsedPeakBytes"])


class ImpairmentCases(unittest.TestCase):
    """Selecting the impairment cases, and rejecting a run whose case reported
    nothing. A case that silently measured nothing is a false pass, so the run
    is rejected instead of reporting metrics nobody can trust."""

    def setUp(self) -> None:
        self.profiler = load_gateway_profiler()

    def parse(self, *arguments: str):
        return self.profiler.parse(["--scenario", "multi-session", *arguments])

    def test_cases_default_to_all_of_them_in_run_order(self) -> None:
        self.assertEqual(self.parse().cases, ["blackhole", "bandwidth", "bandwidth-stream", "restart"])
        self.assertEqual(self.parse("--cases", "restart,blackhole").cases, ["blackhole", "restart"],
                         "the cases run in their own order, not the caller's")
        self.assertEqual(self.parse("--cases", "bandwidth-stream").cases, ["bandwidth-stream"])
        self.assertEqual(self.parse("--cases", "none").cases, [], "'none' runs no case")

    def test_an_unknown_case_or_an_out_of_range_bound_is_refused(self) -> None:
        with self.assertRaises(SystemExit):
            self.parse("--cases", "flap")
        with self.assertRaises(SystemExit):
            self.parse("--blackhole-seconds", "1")
        with self.assertRaises(SystemExit):
            self.parse("--bandwidth-mbps", "0.1")
        with self.assertRaises(SystemExit):
            self.parse("--bandwidth-stream-mbps", "0.01")
        with self.assertRaises(SystemExit):
            self.parse("--bandwidth-stream-seconds", "1")

    def test_a_case_that_reported_nothing_rejects_the_run(self) -> None:
        result = {"label": "iteration-1", "cases": ["blackhole"], "impairment": {}}
        self.assertEqual(len(self.profiler.validate_impairment([result])), 1)
        recovered = {"label": "iteration-1", "cases": ["blackhole"],
                     "impairment": {"blackhole": {"silenceMs": 18_000, "attemptsDuringOutage": 5, "recoveryReadyMs": 120}}}
        self.assertEqual(self.profiler.validate_impairment([recovered]), [])

    def test_a_bandwidth_case_that_never_filled_the_cap_rejects_the_run(self) -> None:
        # A leg whose cap delayed nothing reads as a pass — zero pong misses,
        # no capacity close — however the Gateway behaved, because the link was
        # never loaded. That must reject the run. What the leg offered is
        # reported, not a verdict: at this leg's own 2 Mbit/s defaults even six
        # pages of wire are far under one pong deadline of its cap, so a pong
        # miss is out of reach here whatever the Gateway does.
        def bandwidth(**overrides) -> dict:
            leg = {"capBitsPerSecond": 2_000_000, "seconds": 90.0, "operations": [4_200.0],
                   "deliveredBytes": 22_000_000, "deliveredBytesPerSecond": 244_000, "sentBytes": 4_000,
                   "linkUse": 0.98, "maxInFlight": 6, "offeredInFlightBytes": 7_200_000,
                   "offeredInFlightWireBytes": 234_000, "maxPingToPongMs": 5_100.0,
                   "pongDeadlineMisses": 0, "unexpectedCloses": 0}
            leg.update(overrides)
            return {"label": "iteration-1", "cases": ["bandwidth"], "impairment": {"bandwidth": leg}}

        self.assertEqual(self.profiler.validate_impairment([bandwidth()]), [])
        unfilled = self.profiler.validate_impairment([bandwidth(linkUse=0.2)])
        self.assertEqual(len(unfilled), 1, unfilled)
        silent = self.profiler.validate_impairment([bandwidth(maxPingToPongMs=None)])
        self.assertEqual(len(silent), 1, silent)

    def test_a_streaming_case_whose_cap_never_bound_rejects_the_run(self) -> None:
        # The streaming case only means something if its cap, not the workload,
        # bounded the link: a cap above what the streams produce leaves the queue
        # empty, so "zero misses, no close" describes the workload rather than
        # the Gateway. The one measured smoke (8 streams, a 0.3 Mbit/s cap) is
        # exactly that leg: its streams put 295,621 B/s of decoded state on the
        # wire at 11,901 B/s (link_use 0.32), so the cap never bound.
        def streamed(**overrides) -> dict:
            leg = {"capBitsPerSecond": 80_000, "seconds": 30.0, "streams": 8, "deliveredBytes": 1_100_000,
                   "deliveredBytesPerSecond": 10_000, "payloadBytes": 90_000_000,
                   "payloadBytesPerSecond": 3_000_000, "linkUse": 0.98, "maxPingToPongMs": 5_400.0,
                   "uncappedPingToPongMs": 120.0, "pongDeadlineMisses": 0, "unexpectedCloses": 0}
            leg.update(overrides)
            return {"label": "iteration-1", "cases": ["bandwidth-stream"], "impairment": {"bandwidth-stream": leg}}

        unbacked = {"capBitsPerSecond": 300_000, "seconds": 20.0, "streams": 8, "deliveredBytes": 238_973,
                    "deliveredBytesPerSecond": 11_901, "payloadBytes": 5_935_982,
                    "payloadBytesPerSecond": 295_621, "linkUse": 0.317, "maxPingToPongMs": 2_466.0,
                    "uncappedPingToPongMs": 1_696.0, "pongDeadlineMisses": 0, "unexpectedCloses": 0}
        unfilled = self.profiler.validate_impairment([streamed(**unbacked)])
        self.assertEqual(len(unfilled), 1, unfilled)
        self.assertIn("never bounded the streams", unfilled[0])
        # A full cap whose round trip is no worse than the same run's uncapped
        # one has no backlog to show. The uncapped reference is that run's own
        # measurement, not a constant: a slow host answers 1.7 s with no cap at
        # all, and that is not this leg's finding.
        short = self.profiler.validate_impairment([streamed(maxPingToPongMs=1_500.0, uncappedPingToPongMs=1_696.0)])
        self.assertEqual(len(short), 1, short)
        self.assertIn("no longer than this run's uncapped", short[0])
        self.assertEqual(self.profiler.validate_impairment([streamed(uncappedPingToPongMs=1_696.0)]), [],
                         "a leg slower than the same run's uncapped round trip is a backlog signal")
        self.assertEqual(self.profiler.validate_impairment([streamed(maxPingToPongMs=110.0, unexpectedCloses=1)]),
                         [], "a close is a backlog signal even when the round trip is short")
        self.assertEqual(self.profiler.validate_impairment([streamed(maxPingToPongMs=110.0, pongDeadlineMisses=1)]),
                         [], "a missed deadline is a backlog signal even when the round trip is short")
        idle = self.profiler.validate_impairment([streamed(streams=1, payloadBytes=0)])
        self.assertEqual(len(idle), 1, idle)
        # A run with no uncapped reference cannot say whether the leg showed a
        # backlog at all, so it is not judged on one.
        unreferenced = self.profiler.validate_impairment([streamed(uncappedPingToPongMs=None)])
        self.assertEqual(len(unreferenced), 1, unreferenced)
        self.assertIn("no uncapped round trip", unreferenced[0])
        silent = self.profiler.validate_impairment([streamed(maxPingToPongMs=None)])
        self.assertEqual(len(silent), 1, silent)

    def test_a_restart_that_leaves_a_client_down_rejects_the_run(self) -> None:
        def restart(**overrides) -> dict:
            leg = {"downtimeMs": 3_900, "restoredAtMs": 10,
                   "clients": [{"name": name, "readyAtMs": 11, "reconnectMs": 1_400, "attempts": []}
                               for name in ("mobile", "dashboard", "driver")],
                   "clientsAll": [{"name": name, "readyAtMs": 11, "reconnectMs": 1_400, "attempts": []}
                                  for name in ("mobile", "dashboard", "driver")],
                   "requests": [{"client": "mobile", "ms": 200, "duringDowntime": False}]}
            leg.update(overrides)
            return {"label": "iteration-1", "cases": ["restart"], "impairment": {"restart": leg}}

        self.assertEqual(self.profiler.validate_impairment([restart()]), [])
        down = restart()
        down["impairment"]["restart"]["clientsAll"][0]["readyAtMs"] = None
        self.assertEqual(len(self.profiler.validate_impairment([down])), 1,
                         "a client that never came back must reject the run")
        no_downtime = restart(downtimeMs=None)
        self.assertEqual(len(self.profiler.validate_impairment([no_downtime])), 1)
        short = restart(clients=[{"name": "mobile", "readyAtMs": 11, "reconnectMs": 10, "attempts": []}])
        self.assertEqual(len(self.profiler.validate_impairment([short])), 1,
                         "the three measured clients must all report")

    def test_a_restart_waits_out_a_previous_owners_runtime_lock(self) -> None:
        # A predecessor that had to be killed leaves its agent-directory runtime
        # lock until it is stale (60 s), and a child started inside that window
        # exits on the ownership conflict. The restart retries the start while
        # that is the failure, and only while it is.
        profiler = self.profiler
        fixture = profiler.FixtureGateway.__new__(profiler.FixtureGateway)
        with tempfile.TemporaryDirectory() as temporary:
            fixture.port = 51_234
            fixture.log_path = Path(temporary) / "gateway.stdout.log"
            fixture.log_path.write_text(f"Gateway failed during startup: {profiler.RUNTIME_LOCK_CONFLICT}\n")
            calls: list = []
            starts: list[tuple] = []
            failures = {"left": 1}
            fixture.stop = lambda: calls.append("stop")

            def start(deadline_seconds: float = 90, port: int | None = None) -> None:
                starts.append((port, deadline_seconds))
                calls.append("start")
                if failures["left"] > 0:
                    failures["left"] -= 1
                    raise profiler.ProfileFailure("fixture Gateway exited during startup (exit 1)",
                                                  profiler.EXIT_FIXTURE, fixture.log_path)

            fixture.start = start
            with mock.patch.object(profiler, "RESTART_LOCK_RETRY_SECONDS", 0):
                fixture.restart()
            self.assertEqual(calls, ["stop", "start", "start"], "the restart did not retry the start")
            self.assertEqual([port for port, _ in starts], [51_234, 51_234], "the restart moved the port")
            self.assertTrue(all(deadline > 0 for _, deadline in starts), "a retry started without a budget")

            fixture.log_path.write_text("Gateway failed during startup: a real crash\n")
            failures["left"] = 1
            with mock.patch.object(profiler, "RESTART_LOCK_RETRY_SECONDS", 0):
                with self.assertRaises(profiler.ProfileFailure):
                    fixture.restart()

    def test_each_case_contributes_its_own_metrics(self) -> None:
        # Two iterations whose extremes are not the first one, and whose
        # boundary values (a 1 s request, a zero-length bandwidth leg) are what
        # the metric definitions hinge on.
        def result(label: str, *, attempt: dict, reconnect: int, downtime: int, storm: list[dict]) -> dict:
            return {"label": label, "cases": ["blackhole", "bandwidth", "bandwidth-stream", "restart"], "impairment": {
                "blackhole": {"silenceMs": 18_000, "attemptsDuringOutage": 5, "recoveryReadyMs": 120,
                              "attempts": [{"ms": 1_000, "connected": True}, attempt]},
                "bandwidth": {"capBitsPerSecond": 2_000_000, "deliveredBytesPerSecond": 41_000,
                              "linkUse": 0.94, "sentBytes": 41_000, "seconds": 1.0, "operations": [4_200],
                              "maxInFlight": 6, "offeredInFlightBytes": 7_200_000,
                              "offeredInFlightWireBytes": 234_000, "maxPingToPongMs": 700.0,
                              "pongDeadlineMisses": 0, "unexpectedCloses": 0},
                "bandwidth-stream": {"capBitsPerSecond": 300_000, "seconds": 30.0, "streams": 8,
                                     "deliveredBytesPerSecond": 36_500, "payloadBytesPerSecond": 3_000_000,
                                     "linkUse": 0.97, "maxPingToPongMs": 5_400.0,
                                     "pongDeadlineMisses": 0, "unexpectedCloses": 0},
                "restart": {"downtimeMs": downtime, "restoredAtMs": 1,
                            "clients": [{"name": "mobile", "reconnectMs": reconnect,
                                         "attempts": [{"ms": 30, "failed": "ECONNREFUSED"}, {"ms": 400, "connected": True}]}],
                            "clientsAll": [{"name": name, "reconnectMs": reconnect,
                                            "attempts": [{"ms": 30, "failed": "ECONNREFUSED"},
                                                         {"ms": 400, "connected": True}]}
                                           for name in ("mobile", "dashboard", "driver", "warm", "large",
                                                        "dashboard-reconnect")],
                            "requests": storm},
            }}

        first = result("iteration-1", attempt={"ms": 90, "connected": True}, reconnect=1_400, downtime=3_900,
                       storm=[{"client": "mobile", "ms": 200, "sinceRestoreMs": 10, "duringDowntime": False},
                              {"client": "dashboard", "ms": 1_500, "sinceRestoreMs": 20, "duringDowntime": False},
                              {"client": "driver", "ms": 1_000, "sinceRestoreMs": -30, "duringDowntime": False},
                              {"client": "mobile", "ms": 5_000, "sinceRestoreMs": -4_000,
                               "duringDowntime": True, "failed": "session.open failed: refused"}])
        second = result("iteration-2", attempt={"ms": 15_000, "failed": "hello"}, reconnect=2_600, downtime=4_100,
                        storm=[{"client": "mobile", "ms": 1_001, "sinceRestoreMs": 40, "duringDowntime": False}])
        metrics = self.profiler.impairment_samples([first, second])
        self.assertEqual(metrics["impairment.blackhole.attempt_ms_max"]["values"], [1_000, 15_000],
                         "the longest attempt is the longest, whether it failed or not")
        self.assertEqual(metrics["impairment.restart.reconnect_ms_max"]["values"], [1_400, 2_600])
        self.assertEqual(metrics["impairment.restart.downtime_ms"]["values"], [3_900, 4_100])
        for metric_id in ("impairment.bandwidth.link_use", "impairment.bandwidth.delivered_bytes_per_second",
                          "impairment.bandwidth.sent_bytes_per_second", "impairment.restart.requests",
                          "impairment.bandwidth.offered_in_flight_bytes",
                          "impairment.bandwidth.max_in_flight",
                          "impairment.bandwidth_stream.streams",
                          "impairment.bandwidth_stream.link_use"):
            self.assertEqual(metrics[metric_id]["better"], "higher",
                             f"{metric_id} is a volume metric: more is not a regression")
        self.assertEqual(metrics["impairment.restart.requests_over_1s"]["values"], [1, 1],
                         "a storm request takes over 1 s only when it is strictly slower; a request that failed "
                         "on the way up or down is not a storm request")
        self.assertEqual(metrics["impairment.restart.requests"]["values"], [3, 1],
                         "a request that failed while the Gateway was down is the downtime's, not the storm's, "
                         "and is still reported")
        self.assertEqual(metrics["impairment.restart.downtime_requests"]["values"], [1, 0])
        self.assertEqual(metrics["impairment.restart.failed_attempts"]["values"], [6, 6],
                         "one refused connect per client is counted; a connected attempt is not")
        self.assertNotIn("impairment.bandwidth.cap_bits_per_second", metrics,
                         "the cap is configuration: it belongs in the report context")
        self.assertNotIn("impairment.restart.clients_ready", metrics,
                         "every client is ready or the run is rejected: the count is not a measurement")
        self.assertTrue(all(entry["unit"] for entry in metrics.values()))


class MultiSessionSamples(unittest.TestCase):
    def setUp(self) -> None:
        self.profiler = load_gateway_profiler()

    def test_nearest_rank_percentiles(self) -> None:
        values = [float(value) for value in range(100, 0, -1)]
        self.assertEqual(self.profiler.percentile(values, 50), 50)
        self.assertEqual(self.profiler.percentile(values, 99), 99)
        self.assertEqual(self.profiler.percentile([3.0, 1.0, 2.0], 99), 3)
        self.assertEqual(self.profiler.percentile([7.0], 50), 7)

    def test_an_operation_without_samples_rejects_the_run_instead_of_reporting_it(self) -> None:
        samples = {kind: [10.0] for kind in self.profiler.LATENCY_KINDS}
        result = {"label": "iteration-1", "samples": samples, "runningPhases": ["running"] * 8,
                  "mobileOutcome": {"sequenceGaps": 0}}
        self.assertEqual(self.profiler.validate_multi([result]), ([], []))
        samples["promptAdmission"] = []
        stopped = {**result, "runningPhases": ["running"] * 7 + ["idle"]}
        problems, _ = self.profiler.validate_multi([stopped])
        self.assertEqual(len(problems), 2, problems)


if __name__ == "__main__":
    unittest.main()
