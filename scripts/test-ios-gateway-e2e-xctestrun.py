#!/usr/bin/env python3
"""Behavioral tests for the generated xctestrun patch helper."""

from __future__ import annotations

import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "patch-ios-gateway-e2e-xctestrun.py"


def target(name: str = "TronMobileTests", *, ui: bool = False) -> dict[str, object]:
    value: dict[str, object] = {
        "BlueprintName": name,
        "EnvironmentVariables": {"PRESERVED": "host"},
        "UnrelatedMetadata": {"preserved": True},
    }
    if ui:
        value["IsUITestBundle"] = True
    return value


def document(targets: list[dict[str, object]]) -> dict[str, object]:
    return {
        "TestConfigurations": [{"Name": "Default", "IsEnabled": True, "TestTargets": targets}],
        "__xctestrun_metadata__": {"FormatVersion": 2},
    }


class XcodeTestRunPatchTests(unittest.TestCase):
    def run_helper(self, value: object) -> tuple[subprocess.CompletedProcess[str], object]:
        with tempfile.TemporaryDirectory(prefix="tron-xctestrun-test-") as directory:
            path = Path(directory) / "fixture.xctestrun"
            with path.open("wb") as handle:
                plistlib.dump(value, handle)
            result = subprocess.run(
                [str(HELPER), str(path), "9848", "code", "/tmp/workspace", "fixture-version"],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
            with path.open("rb") as handle:
                patched = plistlib.load(handle)
            return result, patched

    def test_patches_unique_unit_blueprint_without_replacing_other_values(self) -> None:
        unit = target()
        result, patched = self.run_helper(document([target("OtherTests", ui=True), unit]))
        self.assertEqual(result.returncode, 0, result.stderr)
        patched_unit = patched["TestConfigurations"][0]["TestTargets"][1]
        expected = {
            "TRON_E2E_PORT": "9848",
            "TRON_E2E_CODE": "code",
            "TRON_E2E_WORKSPACE": "/tmp/workspace",
            "TRON_E2E_PI_VERSION": "fixture-version",
        }
        self.assertEqual(patched_unit["EnvironmentVariables"], {"PRESERVED": "host", **expected})
        self.assertEqual(patched_unit["UnrelatedMetadata"], {"preserved": True})

    def test_rejects_missing_ambiguous_and_malformed_targets(self) -> None:
        for fixture in (
            document([target("OtherTests")]),
            document([target(ui=True)]),
            document([target(), target()]),
            {"TestConfigurations": [{"IsEnabled": True, "TestTargets": "invalid"}]},
        ):
            with self.subTest(fixture=fixture):
                result, _ = self.run_helper(fixture)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("xctestrun patch failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
