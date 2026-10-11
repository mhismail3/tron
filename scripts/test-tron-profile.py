#!/usr/bin/env python3
"""Failure-mode tests for the profiler's shared report and comparison owner.

Each case targets one way a comparison could silently mislead an agent:
a real regression passing, noise or an improvement failing a change, a missing
or relabeled metric being read as zero, a malformed/truncated report being
accepted, or a run recorded under an Instruments trace (whose metrics carry
tracing overhead) deciding a comparison. The profiler lanes' own self-tests cover measurement end to end.

`status` must name this worktree's newest report of each tool: one `latest`
link per tool in the shared profiles root followed whichever worktree wrote
last (W-21, issue #101), so it could name another worktree's run, and an
ordering bug would name an older run of this one.

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

    def write(self, name: str, document: dict, scenario: str = "idle-chat", worktree: Path = ROOT) -> Path:
        source = self.root / f"{name}.samples.json"
        source.write_text(json.dumps(document))
        run_dir = self.root / "profiles/ios" / name
        result = self.run_report(
            "write", "--tool", "ios", "--scenario", scenario,
            "--samples", str(source), "--run-dir", str(run_dir), "--worktree", str(worktree),
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

    def test_status_names_this_worktrees_newest_report(self) -> None:
        other = self.root / "other-worktree"
        other.mkdir()
        self.write("first", samples({"cpu.time": ("ns", "lower", [1, 1, 1])}))
        second = self.write("second", samples({"cpu.time": ("ns", "lower", [2, 2, 2])}))
        # Written last, by another worktree sharing the profiles root.
        foreign = self.write("foreign", samples({"cpu.time": ("ns", "lower", [3, 3, 3])}), worktree=other)
        result = subprocess.run([str(FRONT_DOOR), "status"], capture_output=True, text=True, env=self.environment, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ios: latest idle-chat run second at ", result.stdout)
        self.assertIn(f"-> {second.resolve()}\n", result.stdout)
        self.assertIn("gateway: no runs from this worktree", result.stdout)
        there = self.run_report("status", "--worktree", str(other))
        self.assertEqual(there.returncode, 0, there.stderr)
        self.assertIn(f"-> {foreign.resolve()}\n", there.stdout)


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
      return socket.send(JSON.stringify({ type: "hello", protocolVersion: 7, gatewayVersion: "stub" }));
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
                        startup: dict | None = None, **extra: object) -> object:
        """The profiler's side of the restart handshake as `wait_with_restart`
        uses it: an owned child and a restart that replaces the stub Gateway on
        the same port after a real gap, so the clients meet a refused connect
        while it is down. The replacement carries the same stub configuration,
        so a behaviour the test asked for survives the restart. `health_delay_
        seconds` stands in for the profiler's own health check: the new Gateway
        already serves requests while the answer (and so `restoredAtMs`) is
        still seconds away. `startup` stands in for the start the real fixture
        reads from the new process's own `gateway.startup-budget` record."""
        harness = self

        class RestartFixture:
            def __init__(self) -> None:
                self.process = harness.stubs[-1]
                self.startup = startup

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
    failed attempts, or that waits for the profiler's answer forever; a
    blackhole model that retries back to back without the phone's backoff, or
    that leaves the change it consumed out of the recovery it reports; and an
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
        # never an attempt already on the wire, so this attempt still times out,
        # and its change is consumed by the attempt that follows it.
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
        self.assertGreater(leg["recoveryReadyMs"], 2_000,
                           "the recovery must include the rest of the transport-open attempt that was in "
                           "flight at the path's return, not only the connect that follows it")
        self.assertLessEqual(leg["recoveryReadyMs"], self.FAST_CONNECTION["transportOpenDeadlineMs"] + 1_000,
                             "recovery from the path's return stays inside one transport-open deadline")
        self.assertTrue(leg["abandonedOnMiss"],
                        "the abandon must follow a counted pong miss, not the leg's own clock")
        liveness_ms = 300 + 200
        self.assertGreaterEqual(leg["silenceMs"], liveness_ms,
                               "silence is measured from the last inbound frame, one liveness window long")
        self.assertLess(leg["silenceMs"], 2_000,
                        "the socket is abandoned one liveness window after the last inbound frame")

    def test_the_blackhole_waits_the_phone_backoff_and_consumes_its_path_change(self) -> None:
        # A blackhole long enough for the model to pay the phone's backoff: the
        # return 6 s in lands inside the second transport-open attempt, so the
        # recovery is that attempt's remainder plus an immediate retry, and the
        # attempts behind it are spaced by the phone's own curve instead of
        # running back to back (zero-gap retries would fit twice as many).
        connection = dict(self.FAST_CONNECTION, transportOpenDeadlineMs=2_000, helloDeadlineMs=2_000)
        status, output, result = self.run_impairment(["blackhole"], {
            "blackholeSeconds": 6, "blackholeSettleMs": 400,
            "connection": connection,
            "measuredDeadlineMs": 30_000,
        })
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["blackhole"]
        waits = [attempt.get("waitMs") for attempt in leg["attempts"] if attempt.get("duringOutage")]
        self.assertTrue(any((wait or 0) >= 1_000 for wait in waits),
                        f"no attempt during the outage waited the phone's backoff: {leg['attempts']}")
        after_return = next((attempt for attempt in leg["attempts"] if not attempt.get("duringOutage")),
                            None)
        self.assertIsNotNone(after_return, f"no attempt followed the path's return: {leg['attempts']}")
        self.assertEqual(after_return.get("waitMs"), 0,
                         "the path change the return consumed must start that attempt at once, not after a "
                         f"grown wait: {leg['attempts']}")
        self.assertGreater(leg["recoveryReadyMs"], 0,
                           "the in-flight attempt's remainder is part of the recovery")
        self.assertLessEqual(leg["recoveryReadyMs"], connection["transportOpenDeadlineMs"],
                             "recovery from the path's return stays inside the attempt that was in flight")

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

    def test_the_restart_case_reports_the_new_startups_budget(self) -> None:
        # The driver drops nothing of the profiler's answer: the budget the
        # profiler read from the new process reaches the result the qualification
        # run judges. Negative control: with `startup` not forwarded the leg
        # reports None and restart_criterion_warnings says the budget is missing.
        budget = {"listeningMs": 1_200.0, "budgetMs": 5_000.0, "closeToListeningMs": 2_400.0,
                  "slowestStep": "modules", "slowestStepMs": 1_000.0}
        status, output, result = self.run_impairment(["restart"], {
            "restartStormSeconds": 2, "restartDeadlineMs": 30_000,
            "running": [{"sessionId": "stub-run-1"}],
        }, restart_stub=True, stub_config={"startup": budget})
        self.assertEqual(status, 0, output)
        leg = result["impairment"]["restart"]
        self.assertEqual(leg.get("startup"), budget, "the driver dropped the new process's startup budget")
        self.assertEqual(self.profiler.restart_criterion_warnings([
            {"label": "impaired", "impairment": {"restart": leg}}]), [])

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


if __name__ == "__main__":
    unittest.main()
