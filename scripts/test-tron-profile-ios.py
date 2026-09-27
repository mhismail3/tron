#!/usr/bin/env python3
"""Failure-mode tests for the iOS profiler's result interpretation.

`scripts/tron-profile-ios --self-test` proves the measurement path end to end on
a real simulator, but only on the success path. These cases target the ways the
xcresult-to-report step could still mislead an agent without any simulator:

1. A scenario test that skipped (its selection never reached the test process)
   or failed is accepted as a measurement.
2. A partial run (fewer per-iteration values than requested) is accepted.
3. A counter the process cannot provide is reported as zero or silently
   dropped instead of omitted with a warning.
4. Values of another test, or XCTest's own metrics, are attributed to the
   selected scenario.
5. A value arrives in an unexpected unit and is accepted as the known metric.
6. A broken path that measured zero CPU time in every iteration is reported.
7. The self-test passes although a known-bad variant was not detected.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("tron_profile_ios", str(ROOT / "scripts/tron-profile-ios"))
spec = importlib.util.spec_from_loader(loader.name, loader)
profiler = importlib.util.module_from_spec(spec)
loader.exec_module(profiler)

TEST = "ProfileControlScenarioTests/testControl"


def metric(identifier: str, values: list[float], unit: str) -> dict:
    return {"identifier": identifier, "measurements": values, "unitOfMeasurement": unit, "polarity": "prefers smaller"}


def document(test: str, metrics: list[dict]) -> list[dict]:
    # The shape of `xcresulttool get test-results metrics` (Xcode 26).
    return [{
        "testIdentifier": f"{test}()",
        "testRuns": [{"device": {"deviceName": "Tron iOS Tests"}, "metrics": metrics}],
    }]


def essentials(count: int = 3) -> list[dict]:
    return [
        metric("com.tron.profile.time.wall", [2e9] * count, "ns"),
        metric("com.tron.profile.cpu.time", [1e8 + index for index in range(count)], "ns"),
    ]


class ResultInterpretationTests(unittest.TestCase):
    def test_skipped_or_failed_scenario_is_not_a_measurement(self) -> None:
        skipped = {"passedTests": 0, "failedTests": 0, "skippedTests": 1, "totalTestCount": 1}
        with self.assertRaises(profiler.ProfileError) as raised:
            profiler.validate_summary(skipped, "control")
        self.assertEqual(raised.exception.code, profiler.EXIT_SCENARIO_FAILURE)
        failed = {"passedTests": 0, "failedTests": 1, "skippedTests": 0, "totalTestCount": 1,
                  "testFailures": [{"failureText": "TRON_PROFILE_FAILURE scenario=control: not ready"}]}
        with self.assertRaises(profiler.ProfileError) as raised:
            profiler.validate_summary(failed, "control")
        self.assertIn("not ready", str(raised.exception))
        profiler.validate_summary({"passedTests": 1, "failedTests": 0, "skippedTests": 0, "totalTestCount": 1}, "control")

    def test_partial_run_is_refused(self) -> None:
        measurements = profiler.extract_measurements(document(TEST, [
            metric("com.tron.profile.time.wall", [2e9, 2e9], "ns"),
            metric("com.tron.profile.cpu.time", [1e8, 1e8], "ns"),
        ]), TEST)
        with self.assertRaises(profiler.ProfileError):
            profiler.build_samples(measurements, 3, {})

    def test_unmeasured_counter_is_omitted_with_a_warning(self) -> None:
        samples = profiler.build_samples(profiler.extract_measurements(document(TEST, essentials()), TEST), 3, {})
        self.assertNotIn("cpu.instructions", samples["metrics"])
        self.assertTrue(any(w.startswith("cpu.instructions not measured") for w in samples["context"]["warnings"]))
        self.assertEqual(samples["metrics"]["cpu.time"]["unit"], "ns")

    def test_only_the_selected_tests_profile_values_are_read(self) -> None:
        other = document("ProfileControlScenarioTests/testControlExtraCPU", [
            metric("com.tron.profile.cpu.instructions", [9e9] * 3, "instructions"), *essentials(),
        ])
        selected = document(TEST, [*essentials(), metric("com.apple.dt.XCTMetric_CPU.time", [1.0] * 3, "s")])
        measurements = profiler.extract_measurements(other + selected, TEST)
        self.assertEqual(sorted(measurements), ["cpu.time", "time.wall"])

    def test_unexpected_unit_is_refused(self) -> None:
        measurements = profiler.extract_measurements(document(TEST, [
            metric("com.tron.profile.time.wall", [2.0] * 3, "s"), *essentials()[1:],
        ]), TEST)
        with self.assertRaises(profiler.ProfileError):
            profiler.build_samples(measurements, 3, {})

    def test_zero_cpu_time_everywhere_is_a_broken_path(self) -> None:
        measurements = profiler.extract_measurements(document(TEST, [
            metric("com.tron.profile.time.wall", [2e9] * 3, "ns"),
            metric("com.tron.profile.cpu.time", [0, 0, 0], "ns"),
        ]), TEST)
        with self.assertRaises(profiler.ProfileError):
            profiler.build_samples(measurements, 3, {})

    def test_self_test_fails_when_a_variant_is_not_detected(self) -> None:
        regression = {"verdict": "regression", "delta": 1, "relative": 0.5, "noise_bound": 0.1}
        unchanged = {**regression, "verdict": "unchanged"}
        comparisons = {
            "control-cpu": {"metrics": {"cpu.instructions": regression}},
            "control-disk": {"metrics": {"disk.logical_writes": unchanged}},
            "control-wakeups": {"metrics": {"wakeups.interrupt": {"verdict": "missing-in-candidate"}}},
        }
        rows = {variant: passed for variant, _, _, passed in profiler.self_test_verdicts(comparisons)}
        self.assertEqual(rows, {"control-cpu": True, "control-disk": False, "control-wakeups": False})


if __name__ == "__main__":
    unittest.main()
