#!/usr/bin/env python3
"""Module-scoped journey keys through the real gate CLI (#1153,
tools/work/README.md#module-scoped-journeys).

A fixture catalog's journey step declares a Swift module scope, which `swiftc` compiles for
real, and a UI test target scope. The shards report module execution the way
`scripts/tron-ios-test` does (`iOS coverage: <json>`). A pass that ran none of a scope is
reused across a change confined to it while the module's printed interface is unchanged;
body and internal-declaration changes keep it, while interface changes, changes elsewhere,
executed or unknown runs, static stored values and a module that no longer compiles alone
rerun. Evidence: test-results/gate-modules.json.
"""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "test-results" / "gate-modules.json"
_spec = importlib.util.spec_from_file_location("test_gate", ROOT / "scripts" / "test-gate.py")
_gate_journeys = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_gate_journeys)
Repo = _gate_journeys.Repo
evidence: list = []


MODULE_SHARD = """import json, os, pathlib, sys
mode = pathlib.Path(os.environ["MODULE_MODE"]).read_text().strip()
with open(os.environ["MODULE_TRACE"], "a") as trace:
    trace.write(sys.argv[1] + "\\n")
if mode != "unknown":
    report = pathlib.Path(os.environ["MODULE_REPORT"])
    covered = 3 if mode == "executed" else 0
    report.write_text(json.dumps({"files": {"engine/Engine.swift": {"covered": covered, "executable": 5},
                                            "app/App.swift": {"covered": 9, "executable": 9}}}))
    print(f"iOS coverage: {report}")
"""


def module_scopes(base: Path, env: dict) -> None:
    """A journey pass that ran none of a module's code survives a change confined to that
    module's sources while the module's printed interface is unchanged (#1153). The module
    is compiled for real by swiftc; execution comes from the shard's coverage report.
    Executed, unknown or unprovable modules, interface changes and changes elsewhere rerun.
    A UI test target's folder is skipped only by shards that do not select that target."""
    work = base / "module-work"
    work.mkdir()
    shard, mode, trace = work / "shard.py", work / "mode", work / "trace"
    shard.write_text(MODULE_SHARD)
    tests = {"testTarget": "OtherUITests", "path": "other"}
    engine_scope = {"module": "Engine", "path": "engine", "sdk": "macosx",
                    "swiftFlags": ["-swift-version", "6", "-package-name", "Fixture"]}
    catalog = {"version": 1, "codeExclude": ["**/*.md"], "steps": [
        {"id": step, "trigger": {"always": True, "code": True}, "command": f"python3 {shard} {name}",
         "inputs": ["app", "engine", "other"], "cacheScope": "worktree", "budgetSeconds": 30, "timeoutSeconds": 60,
         "class": "light", "expectedRssMb": 10, "pass": "exit 0", "tier": "L4", "unlocks": "land",
         "moduleScopes": [engine_scope, tests]}
        for step, name in (("journeys", "journeys"), ("other-journeys", "OtherUITests/case"))]}
    path = base / "module-catalog.json"
    path.write_text(json.dumps(catalog))
    repo = Repo(base / "module", {**env, "TRON_GATE_CATALOG": str(path), "MODULE_MODE": str(mode),
                                  "MODULE_TRACE": str(trace), "MODULE_REPORT": str(work / "coverage.json")})
    # A class: every interface prints its `@objc deinit`, which is no Objective-C entry point.
    engine = "package enum Engine {\n    package static func answer() -> Int { helper() + %d }\n}\n%s" \
             "func helper() -> Int { 1 }\npackage final class Box { package init() {} }\n"
    cases = []

    def check(name: str, change: str, content: str, evidence_mode: str, expected: list) -> None:
        mode.write_text(evidence_mode)
        repo.write(change, content)
        repo.commit(change)
        result = repo.gate("run")
        assert result.returncode == 0, result.stdout + result.stderr
        ran = trace.read_text().split() if trace.exists() else []
        trace.unlink(missing_ok=True)
        cases.append({"case": name, "ran": ran})
        assert sorted(ran) == sorted(expected), f"{name}: ran {ran}, expected {expected}\n{result.stdout}"
        if "journeys" not in expected:
            assert "whose surface is unchanged" in result.stdout, result.stdout

    both = ["journeys", "OtherUITests/case"]
    check("first run, engine not executed", "engine/Engine.swift", engine % (1, ""), "unexecuted", both)
    check("engine body change", "engine/Engine.swift", engine % (2, ""), "unexecuted", [])
    check("internal declaration added", "engine/Engine.swift",
          engine % (2, "func unused() -> String { \"\" }\n"), "unexecuted", [])
    check("package interface change", "engine/Engine.swift", engine % (2, "package func added() {}\n"), "unexecuted", both)
    check("UI test target change: only the shard selecting it", "other/Test.swift", "class A {}\n", "unexecuted",
          ["OtherUITests/case"])
    check("change outside the scopes", "app/App.swift", "app 1\n", "executed", both)
    check("engine body change after a pass that executed it", "engine/Engine.swift",
          engine % (3, "package func added() {}\n"), "unexecuted", both)
    check("change outside the scopes, unknown execution", "app/App.swift", "app 2\n", "unknown", both)
    check("engine body change after unknown execution", "engine/Engine.swift",
          engine % (4, "package func added() {}\n"), "unexecuted", both)
    stored = "package enum Limits {\n    package static let limit = %d\n}\n"
    check("static stored value added", "engine/Limits.swift", stored % 1, "unexecuted", both)
    check("static stored value changed: no interface proof", "engine/Limits.swift", stored % 2, "unexecuted", both)
    check("module that no longer compiles alone", "engine/Limits.swift", "package let broken: Int = \"\"\n",
          "unexecuted", both)
    check("same broken module, body-only change", "engine/Engine.swift",
          engine % (5, "package func added() {}\n"), "unexecuted", both)
    evidence.append({"case": "module-scoped journey reuse", "steps": cases})


def main() -> None:
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-gate-modules-") as temporary:
            base = Path(temporary)
            (base / "home").mkdir()
            (base / "tmp").mkdir()
            env = {**{k: v for k, v in os.environ.items() if k != "TRON_HEAVY_LEASE_HELD"},
                   "HOME": str(base / "home"), "TMPDIR": str(base / "tmp"), "TRON_HEAVY_DIR": str(base / "heavy"),
                   "TRON_HEAVY_BUSY_CORES": "0", "TRON_GATE_PURPOSE": "work",
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "NVM_DIR": os.environ.get("NVM_DIR", str(Path.home() / ".nvm"))}
            module_scopes(base, env)
        print(f"Passed module-scoped gate journeys; evidence: {REPORT}")
    finally:
        REPORT.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
