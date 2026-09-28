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
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / "scripts/tron_profile_report.py"
FRONT_DOOR = ROOT / "scripts/tron-profile"
GATEWAY_PROFILER = ROOT / "scripts/tron-profile-gateway"
DRIVER = ROOT / "scripts/tron-profile-gateway-driver.mjs"
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


# A stand-in for the fixture Gateway's WebSocket surface, used only by
# MultiDriverWindows: it answers the multi-session driver's requests, journals
# how every connection closed, and can fail the dashboard's list or hold one
# session open past the window's deadline on demand.
STUB_GATEWAY = """
import { createRequire } from "node:module";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [gatewayDir, configPath] = process.argv.slice(2);
const config = JSON.parse(readFileSync(configPath, "utf8"));
const { WebSocketServer } = createRequire(join(gatewayDir, "package.json"))("ws");
let sequence = 0;
let lists = 0;
const server = new WebSocketServer({ port: 0, perMessageDeflate: false });
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
  socket.on("error", () => {});
  socket.on("close", (code, reason) => appendFileSync(config.journal, `${JSON.stringify({ code, reason: reason.toString() })}\\n`));
  socket.on("message", (data) => {
    let frame;
    try { frame = JSON.parse(data.toString("utf8")); } catch { return; }
    if (frame.type === "hello") {
      return socket.send(JSON.stringify({ type: "hello", protocolVersion: 5, gatewayVersion: "stub" }));
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
    if (frame.method === "session.open") {
      const sessionId = frame.params.sessionId;
      const opened = () => reply({ subscriptionToken: `sub-${sessionId}`, syncToken: `sync-${sessionId}`,
        session: { sessionId, runtimeGeneration: "stub-generation", eventSequence: 1, transcript: [], transcriptTotal: 0 } });
      if (config.delayOpenSessionId === sessionId) return setTimeout(opened, config.delayMs);
      return opened();
    }
    if (frame.method === "session.sync") return reply({ synchronized: true });
    return reply({});
  });
});
"""


class MultiDriverWindows(unittest.TestCase):
    """The multi-session driver's fixed window, its tail and its cleanup.

    Failure modes written down before this harness: a lane that fails inside
    the window must not become an unhandled rejection, which kills the process
    before `multi`'s `finally` (the appender is never stopped, the clients are
    never closed and `timeline.jsonl` is never flushed); and the tail's timer
    must not keep the driver (and its parent) alive for its full grace period
    after a window that closed on its deadline.
    """

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
                   delay_ms: int = 0) -> subprocess.Popen[str]:
        config = {"journal": str(self.root / "closes.jsonl"), "portFile": str(self.root / "port"),
                  "probeOutput": str(self.root / "probe.json"), "failListAfter": fail_list_after,
                  "delayOpenSessionId": delay_open_session_id, "delayMs": delay_ms}
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

    def run_driver(self, fail_list_after: int | None = None, seconds: float = 10, cold: tuple[str, ...] = (),
                   delay_open_ms: int | None = None,
                   timeout: float = 90) -> tuple[int, str, float]:
        delayed = cold[0] if cold and delay_open_ms else None
        stub = self.start_stub(fail_list_after, delayed, delay_open_ms or 0)
        run_dir = self.root / "run"
        run_dir.mkdir(exist_ok=True)
        config = {**self.profiler.MULTI, "gatewayDir": str(ROOT / "packages/gateway"),
                  "orchestrator": str(GATEWAY_PROFILER), "gatewayPid": stub.pid, "port": int((self.root / "port").read_text()),
                  "tronHome": str(self.root / "tron"), "outputDir": str(run_dir), "phase": "iteration", "label": "stub",
                  "devicesPath": str(self.root / "devices.json"), "probeOutput": str(self.root / "probe.json"),
                  "mixedSeconds": seconds, "noSubscriberSeconds": 2, "settleBeforeMs": 200,
                  "running": [{"sessionId": "stub-run-1"}], "cold": [{"sessionId": name} for name in cold], "large": [],
                  "appendTargets": [str(self.root / "child.jsonl")], "listIntervalMs": 500, "proberIntervalMs": 500}
        config_path = self.root / "driver-config.json"
        config_path.write_text(json.dumps(config, indent=2))
        environment = {**os.environ, "PATH": f"{Path(NODE).parent}{os.pathsep}{os.environ.get('PATH', '')}"}
        started = time.monotonic()
        driver = subprocess.Popen([NODE, str(DRIVER), "multi", str(config_path)], stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, env=environment)
        try:
            output, _ = driver.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            driver.kill()
            output, _ = driver.communicate()
            self.fail(f"the driver did not exit within {timeout} s:\n{output[-2_000:]}")
        return driver.returncode, output, round(time.monotonic() - started, 1)

    def closes(self, expected: str) -> list[dict]:
        deadline = time.monotonic() + 5
        journal = self.root / "closes.jsonl"
        while True:
            records = [json.loads(line) for line in journal.read_text().splitlines()] if journal.is_file() else []
            if any(record["reason"] == expected for record in records) or time.monotonic() > deadline:
                return records
            time.sleep(0.05)

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


PROBE_CLIENT = """
import { opendir } from "node:fs/promises";
import { readFileSync } from "node:fs";
const [catalog, output] = process.argv.slice(2);
for (const path of [catalog, catalog, `${catalog}/child`]) await (await opendir(path)).close();
process.kill(process.pid, "SIGUSR2");
await new Promise((resolve) => setTimeout(resolve, 200));
process.stdout.write(readFileSync(output, "utf8"));
"""


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
