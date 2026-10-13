#!/usr/bin/env python3
"""Choose the iOS validation commands for a change: fixture-owned E2E harnesses, else the UI smoke set."""
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
# Inputs proven only by a real fixture runner: the real-Gateway boundary cases
# and the fault proxy that shapes every real-Gateway case. Each value is the
# owning harness and its command for that input.
FIXTURE_RUNNER_INPUTS = {
    "packages/ios-app/E2ETests/RealGatewayPiBoundaryTests.swift": ("scripts/ios-gateway-e2e-test", "all"),
    "packages/ios-app/UITests/RealGateway/RealGatewayPairAndChatUITests.swift": ("scripts/ios-gateway-e2e-test", "run-ui"),
    "scripts/ios-gateway-fault-proxy.mjs": ("scripts/ios-gateway-e2e-test", "all"),
}
# Every other iOS input runs the smoke journeys of the UI-validation product,
# which `scripts/tron-ios-test run` selects when no --only-testing is given.
SMOKE_COMMAND = ["scripts/tron-ios-test", "run"]


def _relative(path: str) -> Optional[str]:
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    try:
        return candidate.resolve(strict=False).relative_to(ROOT).as_posix()
    except ValueError:
        return None


def test_commands(paths: list[str]) -> list[list[str]]:
    """Return the ordered commands that validate these paths; each fixture harness runs once."""
    fixture_commands: list[list[str]] = []
    ordinary = False
    for raw_path in paths:
        owned = FIXTURE_RUNNER_INPUTS.get(_relative(raw_path) or "")
        if owned is None:
            ordinary = True
        elif list(owned) not in fixture_commands:
            fixture_commands.append(list(owned))
    commands: list[list[str]] = []
    if ordinary or not paths:
        commands.append(list(SMOKE_COMMAND))
    commands.extend(fixture_commands)
    return commands


def fixture_runners() -> set[str]:
    return {runner for runner, _ in FIXTURE_RUNNER_INPUTS.values()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    fixture_runner_started = False
    result_code = 0
    try:
        for command in test_commands(args.paths):
            fixture_runner_started |= command[0] in fixture_runners()
            result = subprocess.run(command, cwd=ROOT, check=False)
            if result.returncode:
                result_code = result.returncode
                break
    finally:
        if fixture_runner_started:
            cleanup = subprocess.run(
                ["scripts/ios-gateway-e2e-test", "stop"], cwd=ROOT, check=False,
            )
            if result_code == 0:
                result_code = cleanup.returncode
    return result_code


if __name__ == "__main__":
    raise SystemExit(main())
