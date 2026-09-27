#!/usr/bin/env python3
"""Failure-mode tests for the profiler's shared report and comparison owner.

Each case targets one way a comparison could silently mislead an agent:
a real regression passing, noise or an improvement failing a change, a missing
or relabeled metric being read as zero, a malformed/truncated report being
accepted, or a run recorded under an Instruments trace (whose metrics carry
tracing overhead) deciding a comparison. The profiler lanes' own self-tests cover measurement end to end.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / "scripts/tron_profile_report.py"
FRONT_DOOR = ROOT / "scripts/tron-profile"


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


if __name__ == "__main__":
    unittest.main()
