#!/usr/bin/env python3
"""Real pinned-Node/Vitest/Gate proof for the no-skip coverage observer (#1110)."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "tools/work/gate.py"


def gate(*args: str, env: dict | None = None, expected: int = 0) -> dict:
    result = subprocess.run([sys.executable, str(GATE), *args], cwd=ROOT,
                            env={**os.environ, **(env or {})}, text=True, capture_output=True, timeout=90)
    if result.returncode != expected:
        raise AssertionError(f"gate {args} exited {result.returncode}, expected {expected}\n{result.stdout}\n{result.stderr}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        for line in reversed(result.stdout.splitlines()):
            if line.startswith("{"):
                return json.loads(line)
        raise AssertionError(f"gate {args} emitted no JSON: {result.stdout!r}")


def main() -> int:
    nonce = next(tempfile._get_candidate_names())
    fixture_rel = f"packages/gateway/test-fixtures/gate-coverage-{nonce}.json"
    source_rel = f"packages/gateway/src/gate-coverage-fixtures-{nonce}/probe.integration.test.ts"
    source_dir = ROOT / Path(source_rel).parent
    test = ROOT / source_rel
    fixture = ROOT / fixture_rel
    dependency = source_dir / "enabled.ts"
    teardown = source_dir / "teardown.ts"
    teardown_dependency = source_dir / "teardown-dependency.ts"
    store = Path(subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-dir"],
                                cwd=ROOT, check=True, text=True, capture_output=True).stdout.strip()) / "work/gate/coverage-observations"
    made_trees: set[str] = set()
    try:
        fixture.write_text('{"enabled":true}\n')
        source_dir.mkdir(parents=True)
        dependency.write_text("export const enabled = true; export function unused() { return 1; }\n")
        teardown_dependency.write_text("export const loadedDuringTeardown = true;\n")
        teardown.write_text("export { loadedDuringTeardown } from './teardown-dependency.js';\n")
        test.write_text(f'''import {{ afterAll, expect, it }} from "vitest";
import {{ readFileSync }} from "node:fs";
import {{ enabled, unused }} from "./enabled.js";

afterAll(async () => {{
  const cleanup = await import("./teardown.js");
  expect(cleanup.loadedDuringTeardown).toBe(true);
}});

it("loads module-evaluation constants and the declared fixture", () => {{
  expect(enabled).toBe(true);
  expect(unused).toBeTypeOf("function");
  const fixture = JSON.parse(readFileSync(process.env.TRON_GATE_COVERAGE_FIXTURE!, "utf8"));
  expect(fixture.enabled).toBe(true);
}});
''')
        missing = gate("coverage", "report", "--test", source_rel, "--json")
        made_trees.add(missing["tree"])
        assert missing["evidenceCounts"]["missing"] == 1 and missing["fallbackShare"] == 1.0, missing

        baseline = gate("coverage", "observe", "--test", source_rel,
                        env={"TRON_GATE_COVERAGE_FIXTURE": str(fixture)})
        observed = baseline
        made_trees.add(observed["tree"])
        assert observed["status"] == "observed", observed
        assert observed["selectionEligible"] is False, observed
        modules = set(observed["sourceModules"])
        assert source_rel in modules, modules
        assert str(Path(source_rel).parent / "enabled.ts") in modules, modules
        assert str(Path(source_rel).parent / "teardown-dependency.ts") in modules, modules
        base_report = gate("coverage", "report", "--test", source_rel, "--base-tree", observed["tree"],
                           "--changed", "packages/gateway/src/nonexistent.ts", "--json")
        assert base_report["evidenceCounts"]["observed"] == 1
        assert base_report["selectionEnabled"] is False and base_report["fallbackTests"] == 1
        baseline_path = store / observed["tree"] / (hashlib.sha256(source_rel.encode()).hexdigest() + ".json")
        baseline_record = json.loads(baseline_path.read_text())
        baseline_record["tree"] = "0" * 40
        baseline_path.write_text(json.dumps(baseline_record) + "\n")
        explicit_stale = gate("coverage", "report", "--test", source_rel, "--base-tree", observed["tree"],
                              "--changed", str(Path(source_rel).parent / "enabled.ts"), "--json")
        assert explicit_stale["evidenceCounts"]["stale"] == 1
        assert explicit_stale["observedLoadedModuleFanoutLowerBound"][str(Path(source_rel).parent / "enabled.ts")] == 0
        baseline_record["tree"] = observed["tree"]
        baseline_path.write_text(json.dumps(baseline_record) + "\n")

        # A changed declared fixture is a global fallback, not a source-only candidate.
        fixture.write_text('{"enabled":false}\n')
        global_report = gate("coverage", "report", "--test", source_rel, "--base-tree", observed["tree"], "--json")
        assert fixture_rel in global_report["globalInputChanges"], global_report
        assert global_report["fallbackTests"] == 1 and global_report["selectionEnabled"] is False
        stale_report = gate("coverage", "report", "--test", source_rel, "--json")
        assert stale_report["evidenceCounts"]["missing"] == 1 and stale_report["fallbackTests"] == 1, stale_report

        # The V8 record still contains the top-level dependency after a real assertion fails.
        dependency.write_text("export const enabled = false; export function unused() { return 1; }\n")
        failed_current = gate("coverage", "report", "--test", source_rel, "--json")
        made_trees.add(failed_current["tree"])
        failed = gate("coverage", "observe", "--test", source_rel,
                      env={"TRON_GATE_COVERAGE_FIXTURE": str(fixture)}, expected=1)
        failed_record = failed
        made_trees.add(failed_record["tree"])
        assert failed_record["status"] == "failed", failed_record
        assert str(Path(source_rel).parent / "enabled.ts") in failed_record["sourceModules"], failed_record
        failed_report = gate("coverage", "report", "--test", source_rel, "--json")
        assert failed_report["evidenceCounts"]["failed"] == 1 and failed_report["fallbackTests"] == 1, failed_report

        # Corrupt evidence remains an explicit fallback at the real CLI boundary.
        failed_path = store / failed_record["tree"] / (hashlib.sha256(source_rel.encode()).hexdigest() + ".json")
        failed_path.write_text("{corrupt\n")
        corrupt = gate("coverage", "report", "--test", source_rel, "--json")
        assert corrupt["evidenceCounts"]["corrupt"] == 1 and corrupt["fallbackTests"] == 1, corrupt
        for invalid_record in ("null\n", "[]\n", json.dumps({"schema": 1, "tree": failed_record["tree"],
                           "test": source_rel, "status": "observed", "sourceModules": "not-a-list",
                           "fallbackReasons": [], "profileCount": 1}) + "\n",
                               json.dumps({"schema": 1, "tree": failed_record["tree"], "test": source_rel,
                                           "status": [], "sourceModules": [], "fallbackReasons": [],
                                           "profileCount": 1}) + "\n"):
            failed_path.write_text(invalid_record)
            malformed = gate("coverage", "report", "--test", source_rel, "--changed",
                              str(Path(source_rel).parent / "enabled.ts"), "--json")
            assert malformed["evidenceCounts"]["corrupt"] == 1 and malformed["fallbackTests"] == 1, malformed
            assert malformed["observedLoadedModuleFanoutLowerBound"][str(Path(source_rel).parent / "enabled.ts")] == 0, malformed

        print(json.dumps({"test": source_rel, "fixture": fixture_rel, "baselineTree": observed["tree"],
                          "failedTree": failed_record["tree"], "observedModuleCount": len(modules),
                          "moduleEvaluationDependencyObserved": True, "teardownDependencyObserved": True,
                          "globalFixtureFallback": True, "missingStaleFailedCorruptFallback": True,
                          "selectionEnabled": False}, indent=2))
        return 0
    finally:
        for tree in made_trees:
            directory = store / tree
            (directory / (hashlib.sha256(source_rel.encode()).hexdigest() + ".json")).unlink(missing_ok=True)
            try:
                directory.rmdir()  # Never remove another observation in the same snapshot.
            except OSError:
                pass
        shutil.rmtree(source_dir, ignore_errors=True)
        fixture.unlink(missing_ok=True)


def interrupted(_signal: int, _frame: object) -> None:
    # The outer gate owns process shutdown; unwind our exact fixture files too.
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    raise SystemExit(main())
