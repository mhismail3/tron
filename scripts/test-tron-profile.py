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
