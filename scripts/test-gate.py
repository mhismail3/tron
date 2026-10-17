#!/usr/bin/env python3
"""Gate runner journeys through the real CLI in temporary Git repositories (#1022).

1. The classifier: `scripts/tron gate plan --json` with the real catalog turns
   Gateway-only, lockfile, iOS, Mac, protocol and docs-only changes into their
   ordered plans.
2. The runner, on a fixture catalog: a failing shard stops the plan at its
   step with the log tail, later shards never start; a retry reuses the
   passing shard and reruns only the failed and later ones; an edited input
   invalidates exactly its step; a step past its hard timeout is killed and
   named; a heartbeat names the running step; `work land`'s entry refuses a dirty tree.

Evidence: test-results/gate.json.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "tools" / "work" / "gate.py"
REPORT = ROOT / "test-results" / "gate.json"
evidence: list = []


class Repo:
    def __init__(self, root: Path, env: dict):
        self.root, self.env = root, env
        root.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (root / ".github").mkdir()
        shutil.copy(ROOT / ".github/work.json", root / ".github/work.json")
        shutil.copy(ROOT / ".node-version", root / ".node-version")
        (root / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/personal-info-guard.sh", root / "scripts/personal-info-guard.sh")
        shutil.copy(ROOT / "scripts/tron-node", root / "scripts/tron-node")
        self.write("README.md", "fixture\n")
        self.write("packages/gateway/package.json", '{"dependencies": {}}\n')
        self.write("packages/gateway/package-lock.json", '{"packages": {}}\n')
        self.commit("base")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("checkout", "-q", "-b", "feature")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True, text=True,
                              capture_output=True).stdout.strip()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def gate(self, *args: str, env: dict | None = None, timeout: float = 60) -> subprocess.CompletedProcess:
        started = time.monotonic()
        result = subprocess.run([sys.executable, str(GATE), *args], cwd=self.root, env={**self.env, **(env or {})},
                                capture_output=True, text=True, timeout=timeout)
        result.seconds = round(time.monotonic() - started, 1)  # type: ignore[attr-defined]
        return result


IOS_DECLARATIONS = '''import XCTest

@MainActor
final class TronFixtureUITests: XCTestCase, @unchecked Sendable {
    let label = "func testInString() {"
    var computed: Int { 1 }

    @MainActor func testMainActor() async throws {}

    @available(iOS 17, *)
    @MainActor
    func testAttributed() {
        func testLocal() {}
    }

    nonisolated func testNonisolated() throws {}
    override func testOverridden() {}
    // func testCommented() {}
    /* func testBlockCommented() {} */
    private func testPrivateHelper() {}
    static func testStatic() {}
    func testWithArgument(_ value: Int) {}
    func helper() {}

    struct Nested {
        func testNested() {}
    }
}

final class Helper {
    func testNotACase() {}
}
'''
IOS_EXTENSION = '''extension TronFixtureUITests {
    @MainActor func testExtended() {}
}

class TronDerivedUITests: TronFixtureUITests {
    func testDerived() {}
}
'''


def plans(base: Path, env: dict) -> None:
    cases = {
        "gateway-only": ({"packages/gateway/src/home/x.ts": "export const x = 1;\n"},
                         ["repo.privacy", "repo.whitespace", "gateway.deps", "gateway.typecheck",
                          "gateway.affected#1/3", "gateway.affected#2/3", "gateway.affected#3/3",
                          "gateway.nested[subagents-settlement]", "gateway.nested[subagents-reports]", "gateway.nested[subagents-controls]", "gateway.nested[rest]"]),
        "lockfile": ({"packages/gateway/package-lock.json": "{}\n"},
                     ["repo.privacy", "repo.whitespace", "gateway.deps", "gateway.typecheck", "gateway.scripts[update-slow]",
                      "gateway.scripts[update-rest]", "gateway.scripts[suites]",
                      "gateway.full#1/6", "gateway.full#2/6", "gateway.full#3/6", "gateway.full#4/6", "gateway.full#5/6", "gateway.full#6/6",
                      "gateway.nested[subagents-settlement]", "gateway.nested[subagents-reports]", "gateway.nested[subagents-controls]", "gateway.nested[rest]"]),
        "ios-only": ({"packages/ios-app/Sources/UI/View.swift": "// view\n",
                      "packages/ios-app/UITests/TronHomeSheetsUITests.swift":
                          "final class TronHomeSheetsUITests: XCTestCase {\n    func testA() {}\n    func testB() {}\n    func testC() {}\n}\n"},
                     ["repo.privacy", "repo.whitespace", "ios.source-policy", "ios.build", "ios.device-compile", "ios.journeys[TronHomeSheetsUITests.testA+1]",
                      "ios.journeys[TronHomeSheetsUITests.testC]"]),
        # A UI test class with its own harness runs through it as a journey, never the plain runner.
        "ios-harness": ({"packages/ios-app/UITests/TronMacTerminalUITests.swift":
                             "import XCTest\n\n// gate-journey: scripts/ios-mac-terminal-journey\n"
                             "final class TronMacTerminalUITests: XCTestCase {\n    func testA() {}\n}\n"},
                        ["repo.privacy", "repo.whitespace", "ios.source-policy", "ios.build", "ios.device-compile", "ios.journeys[smoke]",
                         "journey[1]"]),
        # Every method XCTest runs is selected whatever its attributes, modifiers or file, and
        # nothing XCTest does not run is (#1069).
        "ios-declarations": ({
            "packages/ios-app/UITests/TronFixtureUITests.swift": IOS_DECLARATIONS,
            "packages/ios-app/UITests/TronFixtureUITests+Extension.swift": IOS_EXTENSION},
            ["repo.privacy", "repo.whitespace", "ios.source-policy", "ios.build", "ios.device-compile",
             "ios.journeys[TronFixtureUITests.testExtended+1]", "ios.journeys[TronFixtureUITests.testAttributed+1]",
             "ios.journeys[TronFixtureUITests.testOverridden]", "ios.journeys[TronDerivedUITests.testDerived]"]),
        "mac-only": ({"packages/mac-app/Sources/App.swift": "// app\n"},
                     ["repo.privacy", "repo.whitespace", "mac.build", "mac.test"]),
        "gateway-and-config": ({"packages/gateway/src/home/x.ts": "export const x = 1;\n", "packages/gateway/vitest.config.ts": "export {};\n"},
                               ["repo.privacy", "repo.whitespace", "gateway.deps", "gateway.typecheck",
                                "gateway.full#1/6", "gateway.full#2/6", "gateway.full#3/6", "gateway.full#4/6", "gateway.full#5/6", "gateway.full#6/6",
                                "gateway.nested[subagents-settlement]", "gateway.nested[subagents-reports]", "gateway.nested[subagents-controls]", "gateway.nested[rest]"]),
        "protocol": ({"config/GatewayProtocol.json": "{}\n"},
                     ["repo.privacy", "repo.whitespace", "ios.source-policy", "protocol.contract", "mac.build", "gateway.full#1/6", "gateway.full#2/6", "gateway.full#3/6", "gateway.full#4/6", "gateway.full#5/6", "gateway.full#6/6", "gateway.nested[subagents-settlement]", "gateway.nested[subagents-reports]", "gateway.nested[subagents-controls]", "gateway.nested[rest]", "ios.build", "ios.device-compile", "ios.gateway-boundary[build]", "ios.gateway-boundary[resilience]", "ios.gateway-boundary[lan]"]),
        "docs-only": ({"packages/gateway/docs/x.md": "docs\n", "packages/ios-app/docs/y.md": "docs\n"},
                      ["repo.privacy", "repo.whitespace"]),
    }
    for name, (files, expected) in cases.items():
        repo = Repo(base / f"plan-{name}", env)
        for path, text in files.items():
            repo.write(path, text)
        repo.commit(name)
        result = repo.gate("plan", "--json")
        assert result.returncode == 0, result.stderr
        rows = json.loads(result.stdout)["plan"]
        actual = [row["shard"] for row in rows]
        evidence.append({"case": f"plan {name}", "plan": actual})
        assert actual == expected, f"{name}: {actual} != {expected}"
        if name == "ios-declarations":
            selected = re.findall(r"--only-testing (\S+)", " ".join(row["command"] for row in rows))
            assert selected == [f"TronMobileUITests/{test}" for test in (
                "TronFixtureUITests/testExtended", "TronFixtureUITests/testMainActor", "TronFixtureUITests/testAttributed",
                "TronFixtureUITests/testNonisolated", "TronFixtureUITests/testOverridden",
                "TronDerivedUITests/testDerived")], selected


def source_policy(base: Path, env: dict) -> None:
    """Run the shipped policy, not a stand-in detector, before any Xcode build."""
    repo = Repo(base / "source-policy", env)
    paths = subprocess.run([
        "git", "ls-files", "packages/ios-app", "config",
        "scripts/generate-xcode-project", "scripts/verify-ci-toolchain.sh",
    ], cwd=ROOT, check=True, text=True, capture_output=True).stdout.splitlines()
    for path in paths:
        target = repo.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / path, target)
    repo.commit("seed real iOS source policy")
    repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
    probe = "packages/ios-app/Sources/UI/GatePolicyProbe.swift"
    repo.write(probe, 'struct GatePolicyProbe: View { var body: some View { Text("probe") } }\n')
    repo.commit("clean iOS change")
    plan = repo.gate("plan", "--json")
    assert plan.returncode == 0, plan.stderr
    rows = json.loads(plan.stdout)["plan"]
    ids = [row["shard"] for row in rows]
    assert ids.index("ios.source-policy") < ids.index("ios.build"), ids
    clean = repo.gate("run", "ios.source-policy")
    evidence.append({"case": "real iOS source policy accepts the clean tree", "seconds": clean.seconds,
                     "stdout": clean.stdout, "stderr": clean.stderr})
    assert clean.returncode == 0, clean.stdout + clean.stderr
    repo.write(probe, 'struct GatePolicyProbe: View { var body: some View {\n'
               '    Text("probe").sheet(isPresented: .constant(true)) { Text("unmanaged") }\n} }\n')
    bad = repo.gate("run")
    evidence.append({"case": "raw sheet fails the real policy with file and line before building", "seconds": bad.seconds,
                     "stdout": bad.stdout, "stderr": bad.stderr})
    assert bad.returncode != 0 and "GatePolicyProbe.swift:2:" in bad.stdout, bad.stdout + bad.stderr
    assert "raw sheet must use the managed presentation owner" in bad.stdout, bad.stdout
    assert "stopped at ios.source-policy" in bad.stdout and "ios.build (" not in bad.stdout, bad.stdout
    repo.git("checkout", "--", probe)
    reused = repo.gate("run", "ios.source-policy")
    assert reused.returncode == 0 and "reused pass" in reused.stdout, reused.stdout + reused.stderr
    evidence.append({"case": "restoring policy inputs reuses the clean receipt", "stdout": reused.stdout})
    # Use the real executable but omit its required presets: toolchain failure must
    # not turn into a passing policy check or an implicit download.
    incomplete = base / "incomplete-tools"
    (incomplete / "bin").mkdir(parents=True)
    search_path = f"{env['TRON_CI_TOOLS_DIR']}/bin:/opt/homebrew/bin:{env.get('PATH', '')}"
    xcodegen = shutil.which("xcodegen", path=search_path)
    assert xcodegen, "local policy journey requires the pinned XcodeGen"
    (incomplete / "bin/xcodegen").symlink_to(xcodegen)
    unavailable = repo.gate("run", "ios.source-policy", "--force",
                            env={"TRON_CI_TOOLS_DIR": str(incomplete)})
    assert unavailable.returncode != 0 and "setting presets are unavailable" in unavailable.stdout, unavailable.stdout
    evidence.append({"case": "incomplete pinned toolchain fails closed", "stdout": unavailable.stdout})


def verification_selection(base: Path, env: dict) -> None:
    suites = ("test-gate", "test-work-land", "test-work-mainline")
    for stem in ("gate", "cli", "ledger"):
        repo = Repo(base / f"selection-{stem}", env)
        for suite in suites:
            repo.write(f"scripts/{suite}.py", f"from pathlib import Path\nPath('.git/ran-{suite}').touch()\n")
        repo.commit("seed verification journeys")
        repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        repo.write(f"tools/work/{stem}.py", "# changed verification boundary\n")
        repo.commit(f"{stem}-only change")
        result = repo.gate("run")
        actual = sorted(path.name.removeprefix("ran-") for path in (repo.root / ".git").glob("ran-*"))
        evidence.append({"case": f"{stem}-only change executes gate and landing boundaries", "ran": actual,
                         "stdout": result.stdout, "stderr": result.stderr})
        assert result.returncode == 0 and actual == sorted(suites), result.stdout + result.stderr


def replacement_selection(base: Path, env: dict) -> None:
    repo = Repo(base / "replacement-selection", env)
    repo.write("scripts/test-tron-mac-replace.py",
               "import os\nfrom pathlib import Path\n"
               "with Path('.git/replacement-runs').open('a') as f:\n"
               "    f.write(str(bool(os.environ.get('TRON_HEAVY_LEASE_HELD'))) + '\\n')\n")
    repo.commit("replacement journey changed")
    result = repo.gate("run")
    runs = (repo.root / ".git/replacement-runs").read_text().splitlines()
    assert result.returncode == 0 and runs == ["True"], (runs, result.stdout, result.stderr)
    evidence.append({"case": "replacement journey runs once under its heavy catalog owner", "ran": runs})


def claim_selection(base: Path, env: dict) -> None:
    repo = Repo(base / "claim-selection", env)
    repo.write("scripts/test-work-start.py", "from pathlib import Path\nPath('.git/claim-test-ran').touch()\n")
    repo.commit("seed the owning integration journey")
    repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
    repo.write("tools/work/claim.py", "# changed claim mechanics\n")
    repo.commit("claim-only change")
    result = repo.gate("run")
    evidence.append({"case": "claim-only changes execute the owning journey", "exit": result.returncode,
                     "stdout": result.stdout, "stderr": result.stderr})
    assert result.returncode == 0 and (repo.root / ".git/claim-test-ran").exists(), result.stdout + result.stderr
    empty = repo.gate("report", "--since", "2000-01-01", "--json")
    evidence.append({"case": "absent queue and landing percentiles are unknown", "exit": empty.returncode,
                     "stdout": empty.stdout, "stderr": empty.stderr})
    assert empty.returncode == 0, empty.stdout + empty.stderr
    summary = json.loads(empty.stdout)
    assert summary["queue"]["p50"] is None and summary["queue"]["p90"] is None and summary["queue"]["max"] is None, summary
    assert summary["landing"]["startToMergeP50"] is None and summary["landing"]["mergeWaitP90"] is None, summary
    human = repo.gate("report", "--since", "2000-01-01")
    assert human.returncode == 0 and "p50 unknown" in human.stdout, human.stdout + human.stderr


FIXTURE_CATALOG = {
    "version": 1,
    "codeExclude": ["**/*.md"],
    "steps": [
        {"id": "first", "trigger": {"always": True}, "command": "echo first >> \"$GATE_TRACE\"",
         "inputs": ["a"], "budgetSeconds": 5, "timeoutSeconds": 10, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L1", "unlocks": "sharded"},
        {"id": "sharded", "trigger": {"always": True}, "shards": 3,
         "command": "echo sharded-{shard} >> \"$GATE_TRACE\"; sleep 1; if [ {shard} = 2 ] && [ -e \"$GATE_FAIL\" ]; then "
                    "echo 'assertion failed: shard two saw the injected failure' >&2; exit 3; fi",
         "inputs": ["b"], "budgetSeconds": 5, "timeoutSeconds": 10, "class": "heavy", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L1", "unlocks": "slow"},
        {"id": "slow", "trigger": {"paths": ["slow/**"]}, "command": "echo slow >> \"$GATE_TRACE\"; sleep 30",
         "inputs": ["slow"], "budgetSeconds": 1, "timeoutSeconds": 2, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L1", "unlocks": "long"},
        {"id": "long", "trigger": {"paths": ["long/**"]}, "command": "echo $$ > \"$GATE_TRACE.pid\"; sleep 30",
         "inputs": ["long"], "budgetSeconds": 40, "timeoutSeconds": 60, "class": "heavy", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L1", "unlocks": "par"},
        {"id": "par", "trigger": {"paths": ["par/**"]}, "shards": 2, "parallelShards": 2,
         "command": "if [ {shard} = 1 ]; then sleep 1; echo 'shard one fails' >&2; exit 4; fi; sleep 30",
         "inputs": ["par"], "budgetSeconds": 20, "timeoutSeconds": 60, "class": "heavy", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L1", "unlocks": "journey"},
        {"id": "journey", "trigger": {"select": "named-journeys"}, "command": "{select}",
         "inputs": ["."], "budgetSeconds": 5, "timeoutSeconds": 10, "class": "heavy", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L1", "unlocks": "land"},
    ],
}


def runner(base: Path, env: dict) -> None:
    catalog = base / "catalog.json"
    catalog.write_text(json.dumps(FIXTURE_CATALOG))
    trace, fail = base / "trace", base / "fail"
    env = {**env, "TRON_GATE_CATALOG": str(catalog), "GATE_TRACE": str(trace), "GATE_FAIL": str(fail),
           "TRON_GATE_HEARTBEAT_SECONDS": "0.5"}
    repo = Repo(base / "runner", env)
    repo.write("a/file", "a\n")
    repo.write("b/file", "b\n")
    repo.commit("inputs")

    def ran() -> list:
        lines = trace.read_text().split() if trace.exists() else []
        trace.unlink(missing_ok=True)
        return lines

    fail.touch()
    result = repo.gate("run")
    evidence.append({"case": "injected failure stops at its shard", "exit": result.returncode, "seconds": result.seconds,
                     "stdout": result.stdout[-3000:]})
    assert result.returncode == 1, result.stdout + result.stderr
    assert ran() == ["first", "sharded-1", "sharded-2"], "later shards must not start after a failure"
    assert "sharded#2/3: FAIL (exit 3)" in result.stdout and "assertion failed: shard two" in result.stdout
    assert "gate: stopped at sharded#2/3; 1 later shards not started" in result.stdout

    fail.unlink()
    result = repo.gate("run")
    evidence.append({"case": "retry reuses passing shards", "stdout": result.stdout[-3000:]})
    assert result.returncode == 0, result.stdout + result.stderr
    assert ran() == ["sharded-2", "sharded-3"], "the retry reruns only the failed and the not-yet-run shards"
    assert "first: reused pass" in result.stdout and "sharded#1/3: reused pass" in result.stdout
    assert "running" in result.stdout and "budget 5s" in result.stdout

    repo.write("b/file", "b changed\n")
    result = repo.gate("run")
    evidence.append({"case": "an edited input invalidates only its step", "stdout": result.stdout[-2000:]})
    assert result.returncode == 0 and ran() == ["sharded-1", "sharded-2", "sharded-3"], result.stdout

    result = repo.gate("next")
    assert result.returncode == 0 and ran() == [] and "all 4 shards passed (0 ran, 4 reused)" in result.stdout, result.stdout

    # The window digest explains every run from the ledgers alone (#1103): the retry of the
    # failed key, the shard that first ran on the retry, the edit that invalidated a step,
    # admission wait on heavy rows, and reuse from the per-run rows. Benchmark rows count apart.
    benchmark = repo.gate("run", "first", "--force", env={"TRON_GATE_PURPOSE": "benchmark"})
    assert benchmark.returncode == 0 and ran() == ["first"], benchmark.stdout
    result = repo.gate("report", "--since", "1h", "--json")
    assert result.returncode == 0, result.stdout + result.stderr
    digest = json.loads(result.stdout)
    evidence.append({"case": "the window digest classifies every run", "digest": digest})
    reasons = {name: entry["runs"] for name, entry in digest["byReason"].items()}
    assert reasons == {"first-ever": 2, "new-shard": 2, "rerun-same-key": 1, "inputs:branch": 3}, reasons
    assert digest["byOutcome"]["fail"]["runs"] == 1 and digest["flakes"]["failures"] == 1
    assert digest["records"]["excluded"] == {"purpose:benchmark": 1}, digest["records"]
    assert digest["byTier"]["L1"]["runs"] == 8, digest["byTier"]
    assert digest["reuse"] == {"runs": 4, "ran": 8, "reused": 7, "share": round(7 / 15, 3)}, digest["reuse"]
    one_line = repo.gate("report", "--since", "1h", "--digest")
    assert one_line.returncode == 0 and len(one_line.stdout.splitlines()) == 1, one_line.stdout + one_line.stderr
    assert f"reuse {digest['reuse']['share']:.0%}" in one_line.stdout, one_line.stdout
    assert f"{digest['queue']['measuredRows']} measured" in one_line.stdout, one_line.stdout
    assert "flakes 1 same-key failures later passed" in one_line.stdout, one_line.stdout
    assert repo.gate("report", "--digest").returncode != 0
    assert repo.gate("report", "--since", "1h", "--digest", "--json").returncode != 0
    evidence.append({"case": "one-line digest agrees with the real-run window", "digest": one_line.stdout})
    rows = [json.loads(line) for line in (repo.root / ".git/work/gate/metrics.jsonl").read_text().splitlines()]
    heavy_rows = [row for row in rows if row["class"] == "heavy"]
    assert heavy_rows and all("queuedSeconds" in row and row["session"] is not None and row["head"]
                              and Path(row["worktreePath"]).resolve() == repo.root.resolve() for row in heavy_rows), heavy_rows

    repo.write("slow/file", "slow\n")
    result = repo.gate("run")
    evidence.append({"case": "hard timeout kills and names the step", "exit": result.returncode, "seconds": result.seconds,
                     "stdout": result.stdout[-2000:]})
    assert result.returncode == 1 and "slow: TIMEOUT" in result.stdout, result.stdout
    assert "TIMEOUT slow exceeded its hard limit of 2s" in result.stdout
    assert result.seconds < 15, "the timed-out step must not run to completion"

    # A worker hands the plan to the background and keeps working; it can watch, wait and cancel.
    repo.write("slow/file", "")
    (repo.root / "slow/file").unlink()
    repo.write("long/file", "long\n")
    result = repo.gate("submit")
    assert result.returncode == 0 and "submitted job" in result.stdout, result.stdout + result.stderr
    job = result.stdout.split("submitted job ")[1].split()[0]
    pid_file = Path(str(trace) + ".pid")
    deadline = time.monotonic() + 30
    while not pid_file.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    step_pid = int(pid_file.read_text())
    listing = repo.gate("jobs").stdout
    assert f"{job}  running" in listing, listing
    cancelled = repo.gate("cancel", job)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(step_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.2)
    else:
        output = (repo.root / ".git/work/gate/jobs" / job / "output.log").read_text()
        state = subprocess.run(["ps", "-o", "pid=,ppid=,stat=,args=", "-p", str(step_pid)],
                               text=True, capture_output=True).stdout
        evidence.append({"case": "cancel failed to join step", "job": job, "pid": step_pid,
                         "state": state, "output": output})
        raise AssertionError("cancel must stop the running step's process group\n" + output)
    waited = repo.gate("wait", job)
    evidence.append({"case": "submit, jobs, cancel, wait", "jobs": listing, "cancel": cancelled.stdout, "wait": waited.stdout[-1500:]})
    assert waited.returncode != 0 and f"job {job} cancelled" in waited.stdout, waited.stdout
    # A newer submit of the same run from the same worktree supersedes the pending one (#1105).
    pid_file.unlink()
    first = repo.gate("submit").stdout.split("submitted job ")[1].split()[0]
    deadline = time.monotonic() + 30
    while not pid_file.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    second = repo.gate("submit")
    assert f"superseded job {first}" in second.stdout, second.stdout
    assert f"job {first} cancelled" in repo.gate("wait", first).stdout
    newest = second.stdout.split("submitted job ")[1].split()[0]
    other = repo.gate("submit", "--tests", "true").stdout
    assert "superseded" not in other, "a different run is not superseded"
    for running in (newest, other.split("submitted job ")[1].split()[0]):
        repo.gate("cancel", running)
        repo.gate("wait", running)
    evidence.append({"case": "a newer identical submit supersedes the pending job", "stdout": second.stdout})
    (repo.root / "long/file").unlink()
    result = repo.gate("submit")
    job = result.stdout.split("submitted job ")[1].split()[0]
    waited = repo.gate("wait", job)
    assert waited.returncode == 0 and f"job {job} passed" in waited.stdout and "reused" in waited.stdout, waited.stdout
    # A submitted full plan forwards option-leading `gate run` arguments: its named journey runs (#1047).
    ran()
    result = repo.gate("submit", "--tests", "echo journey >> \"$GATE_TRACE\"")
    assert result.returncode == 0 and "submitted job" in result.stdout, result.stdout + result.stderr
    job = result.stdout.split("submitted job ")[1].split()[0]
    waited = repo.gate("wait", job)
    evidence.append({"case": "submit forwards --tests to the full plan", "wait": waited.stdout[-1500:]})
    assert waited.returncode == 0 and f"job {job} passed" in waited.stdout, waited.stdout
    assert ran() == ["journey"], "the full plan reuses its passes and runs only the named journey"
    rejected = repo.gate("submit", "--bogus")
    assert rejected.returncode == 2 and "unrecognized arguments: --bogus" in rejected.stderr, rejected.stderr
    repo.write("slow/file", "slow\n")

    # Parallel shards of one step: the first failure stops its running sibling at once.
    (repo.root / "slow/file").unlink()
    repo.write("par/file", "par\n")
    result = repo.gate("run")
    evidence.append({"case": "a failing parallel shard stops its sibling", "exit": result.returncode, "seconds": result.seconds,
                     "stdout": result.stdout[-2000:]})
    assert result.returncode == 1 and "par#1/2: FAIL (exit 4)" in result.stdout, result.stdout
    assert "par#2/2: stopped; step cleanup joined" in result.stdout and "gate: stopped at par#1/2" in result.stdout
    assert result.seconds < 15, "the sibling must not run its 30 s"
    (repo.root / "par/file").unlink()
    repo.write("slow/file", "slow\n")

    sys.path.insert(0, str(GATE.parent))
    import gate  # noqa: E402
    try:
        gate.branch_check(repo.root, json.loads((ROOT / ".github/work.json").read_text()), [], "origin/main")
    except gate.GateError as error:
        assert "commit or remove local changes first" in str(error)
    else:
        raise AssertionError("the landing gate must refuse a dirty tree")


def boundary_plans(base: Path, env: dict) -> None:
    repo = Repo(base / "boundary", env)
    manifests = {
        "packages/gateway/package.json": {"dependencies": {"@earendil-works/pi-ai": "1.0.0"}},
        "packages/gateway/package-lock.json": {"packages": {"node_modules/@earendil-works/pi-ai": {"version": "1.0.0"}}},
    }
    for path, value in manifests.items():
        repo.write(path, json.dumps(value))
    repo.commit("Pi graph baseline")
    repo.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def selected(label: str) -> list[str]:
        result = repo.gate("plan", "--json")
        assert result.returncode == 0, result.stderr
        rows = json.loads(result.stdout)["plan"]
        evidence.append({"case": label, "plan": rows})
        return [row["shard"] for row in rows]

    lock = manifests["packages/gateway/package-lock.json"]
    lock["packages"]["node_modules/unrelated"] = {"version": "2.0.0"}
    repo.write("packages/gateway/package-lock.json", json.dumps(lock))
    assert not any("gateway-boundary" in name or "pi-sdk-rollback" in name for name in selected("unrelated lock churn"))
    lock["packages"]["node_modules/@earendil-works/pi-ai"]["version"] = "1.1.0"
    repo.write("packages/gateway/package-lock.json", json.dumps(lock))
    expected = ["ios.gateway-boundary[build]", "ios.gateway-boundary[resilience]", "ios.gateway-boundary[lan]"]
    names = selected("dirty Pi lock graph change")
    assert "gateway.pi-sdk-rollback" in names and all(name in names for name in expected), names
    repo.git("restore", "packages/gateway/package-lock.json")
    repo.write("packages/gateway/src/transport/server.ts", "export {};\n")
    names = selected("transport change")
    assert "gateway.pi-sdk-rollback" not in names and all(name in names for name in expected), names
    (repo.root / "packages/gateway/src/transport/server.ts").unlink()
    repo.write("packages/ios-app/Core/Gateway/GatewayLanPin.swift", "// pin\n")
    names = selected("iOS LAN change")
    assert "gateway.pi-sdk-rollback" not in names and all(name in names for name in expected), names


TREE_FIXTURE = '''import os, signal, subprocess, sys, time
from pathlib import Path
out = Path(os.environ["TREE_DIR"])
role = sys.argv[1] if len(sys.argv) > 1 else "step"
(out / role).write_text(str(os.getpid()))


def spawn(child):
    return subprocess.Popen([sys.executable, __file__, child], start_new_session=True)


if role == "step":
    spawn("detacher")
elif role == "holder":
    # The command of the real iOS lane lease holder, which starts it in its own session: a
    # child in another one, and a release that runs only if it is signalled, not killed.
    child = spawn("stubborn")

    def release(_signum, _frame):
        (out / "released").write_text("1")
        sys.exit(0)

    signal.signal(signal.SIGTERM, release)
elif role == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
elif role == "detacher":
    # Its child is adopted by launchd before the step times out.
    spawn("orphan")
    time.sleep(1)
    sys.exit(0)
while True:
    time.sleep(1)
'''


def timed_out_tree(base: Path, env: dict) -> None:
    """A step past its hard timeout stops its whole process tree: processes in their own
    sessions and ones launchd adopted get SIGTERM and time for their own cleanup, then
    SIGKILL; none survives the run, and the iOS lane lease the step held is free (#1071)."""
    tree = base / "tree-pids"
    tree.mkdir()
    lane = base / "lane" / "lease.lock"
    holder = f"python3 {ROOT / 'scripts/ios-test-lock.py'} --lock {lane} --resource 'fixture lane' -- python3 tree.py holder"
    catalog = {"version": 1, "codeExclude": [], "steps": [
        {"id": "tree", "trigger": {"always": True}, "command": f"python3 tree.py & {holder}", "inputs": ["tree.py"],
         "budgetSeconds": 2, "timeoutSeconds": 3, "class": "light", "expectedRssMb": 10, "pass": "exit 0",
         "tier": "L1", "unlocks": "land"}]}
    path = base / "tree-catalog.json"
    path.write_text(json.dumps(catalog))
    repo = Repo(base / "tree", {**env, "TRON_GATE_CATALOG": str(path), "TREE_DIR": str(tree),
                                "TRON_GATE_STOP_GRACE_SECONDS": "2"})
    repo.write("tree.py", TREE_FIXTURE)
    repo.commit("tree")

    def alive(pid: int) -> bool:
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return bool(state) and not state.startswith("Z")

    roles = ("step", "holder", "stubborn", "detacher", "orphan")
    try:
        result = repo.gate("run")
        pids = {role: int((tree / role).read_text()) for role in roles}
        survivors = {role: pid for role, pid in pids.items() if alive(pid)}
        log = "\n".join(p.read_text() for p in (repo.root / ".git/work/logs").rglob("*.log"))
        evidence.append({"case": "a timed-out step leaves no descendant process", "seconds": result.seconds,
                         "pids": pids, "survivors": survivors, "stdout": result.stdout[-1500:], "log": log[-1500:]})
        assert result.returncode == 1 and "TIMEOUT tree exceeded its hard limit of 3s" in result.stdout, result.stdout
        assert not survivors, f"descendants outlived the timed-out step: {survivors}"
        assert (tree / "released").exists(), "the holder must get SIGTERM and run its release before any SIGKILL"
        assert f"were killed: {pids['stubborn']}" in log, log
        assert result.seconds < 20, "stopping the tree is bounded by its grace"
        with lane.open("a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise AssertionError("the timed-out step's lane lease must be free for the next run") from None
    finally:
        for role in roles:
            with contextlib.suppress(OSError, ValueError):
                os.kill(int((tree / role).read_text()), 9)


def hosted_cli(base: Path, env: dict) -> None:
    repo = Repo(base / "hosted", env)
    for path in ("scripts/tron", "scripts/tron-node", "tools/work/gate.py", "tools/work/heavy.py", "tools/work/ledger.py", "tools/work/flakes.py",
                 "tools/work/report.py",
                 "packages/gateway/src/tron-home-environment-policy.mjs"):
        target = repo.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / path, target)
    repo.commit("CLI")
    # Shallow hosted checkouts need no origin/main for explicit CI steps.
    repo.git("update-ref", "-d", "refs/remotes/origin/main")
    catalog = json.loads((ROOT / "tools/work/gate-catalog.json").read_text())
    trace = base / "ci-trace"
    for step in catalog["steps"]:
        step.pop("shardCommands", None)
        step.pop("shards", None)
        step.pop("artifacts", None)
        step["command"] = f"echo {step['id']} >> '{trace}'"
        if step["id"] == "gateway.integration":
            step["command"] += "; exit 7"
    path = base / "hosted-catalog.json"
    path.write_text(json.dumps(catalog))
    env = {**env, "TRON_GATE_CATALOG": str(path), "GITHUB_ACTIONS": "true",
           "NVM_DIR": os.environ.get("NVM_DIR", str(Path.home() / ".nvm"))}
    result = subprocess.run([str(repo.root / "scripts/tron"), "ci"], cwd=repo.root, env=env,
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 1, result.stdout + result.stderr
    ran = trace.read_text().splitlines()
    assert ran == ["repo.privacy", "repo.agent-policy", "protocol.contract", "repo.policy", "relay.check",
                   "gateway.deps", "gateway.build", "gateway.deps", "gateway.build", "gateway.integration"], ran
    assert "Reproduce: scripts/tron ci gateway.integration" in result.stdout, result.stdout
    assert "FAIL (exit 7)" in result.stdout and "heavy queue" not in result.stdout, result.stdout
    refused = repo.gate("run", "--base", "HEAD", "gateway.full", env=env)
    assert refused.returncode == 2 and "local-only" in refused.stderr, refused.stdout + refused.stderr
    assert trace.read_text().splitlines() == ran, "hosted refusal must happen before any command"
    evidence.append({"case": "hosted CI uses catalog, prerequisites, shallow HEAD and stable failure line; local-only refused",
                     "trace": ran, "output": result.stdout, "refusal": refused.stderr})


def verification_contract(base: Path, env: dict, kind: str) -> None:
    """Unchanged scoped inputs cannot excuse changed execution semantics."""
    catalog = {"version": 1, "steps": [
        {"id": "contract", "trigger": {"always": True},
         "command": "sleep 2" if kind == "catalog" else 'test "$PROBE_MODE" = good',
         "inputs": ["app"], "budgetSeconds": 1, "timeoutSeconds": 10, "class": "light",
         "expectedRssMb": 10, "pass": "exit 0", "tier": "L1", "unlocks": "land"}]}
    if kind in ("dependency", "dependency-input"):
        value = shlex.quote(str(base / "prepared-value"))
        catalog["steps"][0].update(command=f'test "$(cat {value})" = good', after=["prepare"])
        catalog["steps"].insert(0, {**catalog["steps"][0], "id": "prepare", "after": [],
                                    "command": f"echo good > {value}"})
    path = base / f"contract-{kind}.json"
    path.write_text(json.dumps(catalog))
    repo = Repo(base / f"contract-{kind}", {**env, "TRON_GATE_CATALOG": str(path)})
    if kind == "dependency-input":
        repo.write("seed", "good\n")
        catalog["steps"][0].update(command=f"cp seed {value}", inputs=["seed"])
        # The dependent must inherit C's source inputs through B, not just B's declaration.
        bridge = {**catalog["steps"][-1], "id": "bridge", "command": f"test -f {value}", "after": ["prepare"]}
        catalog["steps"][-1]["after"] = ["bridge"]
        catalog["steps"].insert(1, bridge)
        path.write_text(json.dumps(catalog))
    config_path = repo.root / ".github/work.json"
    config = json.loads(config_path.read_text())
    config["verify"]["prelude"] = "set -e; export PROBE_MODE=good"
    if kind == "bootstrap":
        repo.write("scripts/tron-node", "export PROBE_MODE=good\n")
        config["verify"]["prelude"] = "set -e; . scripts/tron-node"
    config_path.write_text(json.dumps(config))
    repo.write("app/source", "unchanged\n")
    repo.commit("verification contract")
    first = repo.gate("run")
    assert first.returncode == 0, first.stdout + first.stderr
    catalog["steps"].append({**catalog["steps"][-1], "id": "unrelated", "after": [],
                             "trigger": {"paths": ["never/**"]}, "command": "exit 99"})
    path.write_text(json.dumps(catalog))
    unrelated = repo.gate("run")
    evidence.append({"case": f"unrelated catalog entry preserves {kind} passes", "stdout": unrelated.stdout})
    assert unrelated.returncode == 0 and "(0 ran," in unrelated.stdout, unrelated.stdout + unrelated.stderr
    if kind == "catalog":
        catalog["steps"][0]["timeoutSeconds"] = 1
        path.write_text(json.dumps(catalog))
    elif kind == "dependency":
        catalog["steps"][0]["command"] = f"echo bad > {value}"
        path.write_text(json.dumps(catalog))
    elif kind == "dependency-input":
        repo.write("seed", "bad\n")
        repo.commit("changed prerequisite input")
    elif kind == "missing-after":
        catalog["steps"][0]["after"] = ["absent"]
        path.write_text(json.dumps(catalog))
    elif kind == "bootstrap":
        repo.write("scripts/tron-node", "export PROBE_MODE=bad\n")
        repo.commit("changed interpreter bootstrap")
    else:
        config["verify"]["prelude"] = "set -e; export PROBE_MODE=bad"
        config_path.write_text(json.dumps(config))
        repo.commit("new execution environment")
    changed = repo.gate("run")
    evidence.append({"case": f"{kind} changes invalidate scoped passes", "before": first.stdout,
                     "after": changed.stdout, "exit": changed.returncode})
    if kind == "missing-after":
        assert changed.returncode == 2 and "unknown prerequisite absent" in changed.stderr, changed.stdout + changed.stderr
        return
    assert changed.returncode == 1, changed.stdout + changed.stderr
    assert "TIMEOUT" in changed.stdout if kind == "catalog" else "FAIL (exit 1)" in changed.stdout


def source_scope(base: Path, env: dict) -> None:
    """A step whose products are stamped with the exact source state (the iOS build, whose
    test runner refuses products from another commit) is not reused across commits, even
    when its inputs are unchanged; an ordinary worktree-scoped step is."""
    trace = base / "scope-trace"
    catalog = {"version": 1, "codeExclude": [], "steps": [
        {"id": f"{scope}-step", "trigger": {"always": True}, "command": f"echo {scope} >> \"$GATE_TRACE\"",
         "inputs": ["app"], "cacheScope": scope, "budgetSeconds": 5, "timeoutSeconds": 10, "class": "light",
         "expectedRssMb": 10, "pass": "exit 0", "tier": "L1", "unlocks": "land",
         "after": ["source-step"] if scope == "worktree" else []} for scope in ("source", "worktree")]}
    path = base / "scope-catalog.json"
    path.write_text(json.dumps(catalog))
    env = {**env, "TRON_GATE_CATALOG": str(path), "GATE_TRACE": str(trace)}
    repo = Repo(base / "scope", env)
    repo.write("app/file", "app\n")
    repo.commit("app")

    def ran() -> list:
        lines = trace.read_text().split() if trace.exists() else []
        trace.unlink(missing_ok=True)
        return lines

    assert repo.gate("run").returncode == 0 and ran() == ["source", "worktree"]
    assert repo.gate("run").returncode == 0 and ran() == [], "an unchanged source state reuses both"
    repo.write("docs.md", "unrelated\n")
    repo.commit("docs")
    result = repo.gate("run")
    evidence.append({"case": "a source-scoped step reruns after an unrelated commit", "stdout": result.stdout[-1500:]})
    assert result.returncode == 0 and ran() == ["source"], result.stdout


def inherited_suite(base: Path, env: dict) -> None:
    repo = Repo(base / "inherited", env)
    # Real unittest discovery includes indirect subclasses. Every one must run
    # when the gate partitions a larger script suite.
    source = "import unittest\nclass Base(unittest.TestCase):\n    def test_runs(self):\n        print(type(self).__name__)\n"
    source += "\n".join(f"class Child{i}(Base): pass" for i in range(8))
    source += "\nif __name__ == '__main__': unittest.main()\n"
    repo.write("scripts/test-inherited.py", source)
    result = repo.gate("run", "tooling.tests")
    assert result.returncode == 0, result.stdout + result.stderr
    logs = "\n".join(path.read_text() for path in (repo.root / ".git/work/logs").rglob("*.log"))
    assert "Base" in logs and all(f"Child{i}" in logs for i in range(8)), logs
    evidence.append({"case": "all indirect unittest subclasses execute in sharded tooling suite", "output": result.stdout})


FLAKY_FIXTURE = """import json, pathlib, sys, time
plan = pathlib.Path(sys.argv[1]); report = pathlib.Path(sys.argv[2].split("=", 1)[1])
steps = plan.read_text().split(); action = steps[0] if steps else "pass"
plan.write_text(" ".join(steps[1:]))
report.parent.mkdir(parents=True, exist_ok=True)
failed = action == "fail"
report.write_text(json.dumps({"testResults": [{"name": "src/flaky.test.ts", "status": "failed" if failed else "passed",
    "assertionResults": [{"fullName": "settles in time", "status": "failed" if failed else "passed"}]}]}))
if action == "hang":
    time.sleep(30)
sys.exit(1 if failed else 0)
"""
FLAKY_TEST = "src/flaky.test.ts > settles in time"


def flakes_and_quarantine(base: Path, env: dict) -> None:
    """Failures are classified from the shard's own report; a rerun only classifies (#1106).

    A plain failure stops the gate with its class and test, and is not rerun. A test that
    failed and then passed on an unchanged key has flake evidence: its next failure gets one
    isolated rerun, and passing it quarantines the test (owner issue or, when filing fails,
    a one-day unowned entry) instead of turning the failure green silently. Quarantined
    failures run, report and do not block; expired ones block again. A timeout with no
    failing test that passes alone is recorded as infra.
    """
    plan = base / "flaky-plan"
    catalog = {"version": 1, "codeExclude": [], "steps": [
        {"id": "flaky", "trigger": {"always": True}, "command": f"python3 flaky.py {plan} --outputFile.json=out/flaky.json",
         "inputs": ["flaky.py", "input"], "budgetSeconds": 2, "timeoutSeconds": 4, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L1", "unlocks": "land"}]}
    path = base / "flaky-catalog.json"
    path.write_text(json.dumps(catalog))
    # WORK_GH that always fails: a fixture must never reach the real repository's issues.
    repo = Repo(base / "flaky", {**env, "TRON_GATE_CATALOG": str(path), "WORK_GH": "/usr/bin/false"})
    repo.write("flaky.py", FLAKY_FIXTURE)
    repo.write("input", "1\n")
    repo.write(".gitignore", "out/\n")
    repo.commit("flaky step")
    rows = lambda: [json.loads(line) for line in (repo.root / ".git/work/gate/metrics.jsonl").read_text().splitlines()]

    plan.write_text("fail")
    result = repo.gate("run")
    assert result.returncode == 1 and "isolated rerun" not in result.stdout, result.stdout
    assert rows()[-1]["failureClass"] == "assertion" and rows()[-1]["failedTests"] == [FLAKY_TEST], rows()[-1]
    plan.write_text("pass")
    assert repo.gate("run").returncode == 0, "the unchanged key passes: flake evidence for the test"

    repo.write("input", "2\n")
    plan.write_text("fail pass")
    result = repo.gate("run")
    evidence.append({"case": "a flaky test's failure is classified by one rerun and quarantined", "stdout": result.stdout})
    assert result.returncode == 0 and "one isolated rerun to classify it" in result.stdout, result.stdout
    assert "FLAKY flaky: failed, then passed alone" in result.stdout and "NO OWNER" in result.stdout, result.stdout
    assert rows()[-1]["classifyRerun"] is True and rows()[-1]["outcome"] == "pass", rows()[-1]
    listing = repo.gate("quarantine", "list").stdout
    assert "active" in listing and "NO OWNER" in listing and FLAKY_TEST in listing, listing

    repo.write("input", "3\n")
    plan.write_text("fail")
    result = repo.gate("run")
    assert result.returncode == 0 and "QUARANTINED flaky" in result.stdout and "isolated rerun" not in result.stdout, result.stdout
    assert rows()[-1]["outcome"] == "fail", "a quarantined failure is still recorded as a failure"
    assert repo.gate("quarantine", "add", FLAKY_TEST).returncode != 0, "a quarantine needs an owner issue"
    assert repo.gate("quarantine", "add", FLAKY_TEST, "--issue", "5").returncode == 0
    assert "#5" in repo.gate("quarantine", "list").stdout

    # Expired: the excused pass is no longer reusable, and the failure blocks again.
    assert repo.gate("quarantine", "add", FLAKY_TEST, "--issue", "5", "--days", "-1").returncode == 0
    plan.write_text("fail fail")
    result = repo.gate("run")
    evidence.append({"case": "an expired quarantine blocks again", "stdout": result.stdout})
    assert result.returncode == 1 and "EXPIRED" in repo.gate("quarantine", "list").stdout, result.stdout
    assert "failed again on the isolated rerun" in result.stdout, "a failure with flake evidence is classified, then blocks"

    # A timeout with no failing test that passes alone is infra, not a code failure.
    assert repo.gate("quarantine", "remove", FLAKY_TEST).returncode == 0
    repo.write("input", "4\n")
    plan.write_text("hang pass")
    result = repo.gate("run")
    evidence.append({"case": "a timeout that passes alone is infra", "stdout": result.stdout})
    assert result.returncode == 0 and "INFRA flaky: timed out with no failing test" in result.stdout, result.stdout
    digest = json.loads(repo.gate("report", "--since", "1h", "--json").stdout)["flakes"]
    assert digest["infraTimeouts"] == 1 and digest["tests"][FLAKY_TEST]["flaky"] >= 2, (digest, [(r["key"][:8], r["outcome"], r.get("at")) for r in rows()])
    assert digest["byClass"]["assertion"] >= 3 and digest["byClass"]["timeout"] == 1, digest


def key_hygiene(base: Path, env: dict) -> None:
    """Cache keys depend only on what can change a result (#1104): a Markdown-only change
    neither starts nor invalidates a code step, a non-Markdown file under docs/ (a test
    resource) does both, and a --tests journey keys on the inputs of the steps that launch
    the same way, or the whole repository when none does."""
    trace = base / "hygiene-trace"
    catalog = {"version": 1, "codeExclude": ["**/*.md"], "steps": [
        {"id": "build", "trigger": {"code": True, "paths": ["app/**"]}, "command": f"echo build >> {trace}",
         "inputs": ["app"], "budgetSeconds": 5, "timeoutSeconds": 10, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L0", "unlocks": "journey"},
        {"id": "suite", "trigger": {"paths": ["never/**"]}, "command": "cd app && true", "inputs": ["app", "shared"],
         "budgetSeconds": 5, "timeoutSeconds": 10, "class": "light", "expectedRssMb": 10, "pass": "exit 0",
         "tier": "L3", "unlocks": "journey"},
        {"id": "journey", "trigger": {"code": True, "select": "named-journeys"}, "command": "{select}",
         "inputsFromCommand": True, "inputs": ["."], "budgetSeconds": 5, "timeoutSeconds": 10, "class": "light",
         "expectedRssMb": 10, "pass": "exit 0", "tier": "L3", "unlocks": "land"}]}
    path = base / "hygiene-catalog.json"
    path.write_text(json.dumps(catalog))
    repo = Repo(base / "hygiene", {**env, "TRON_GATE_CATALOG": str(path)})
    owned, unowned = f"cd app && echo owned >> {trace}", f"echo unowned >> {trace}"

    def ran(change: str, content: str = "x\n") -> list:
        repo.write(change, content)
        repo.commit(change)
        result = repo.gate("run", "--tests", owned, "--tests", unowned)
        assert result.returncode == 0, result.stdout + result.stderr
        lines = trace.read_text().split() if trace.exists() else []
        trace.unlink(missing_ok=True)
        return lines

    assert ran("app/main.c") == ["build", "owned", "unowned"]
    assert ran("app/README.md", "notes\n") == [], "a Markdown-only change starts and invalidates nothing"
    lines = ran("other/file")
    assert lines == ["unowned"], lines
    assert ran("shared/file") == ["owned", "unowned"], "a change to the launcher's inputs reruns the journey"
    assert ran("app/docs/asset.png") == ["build", "owned", "unowned"], "a docs/ test resource is a code input"
    evidence.append({"case": "keys ignore Markdown and journeys key on declared inputs", "catalog": catalog["steps"][2]})


def test_overhead(base: Path, env: dict) -> None:
    """A shard's XCTest case time is recorded, and the digest reports its overhead (#1109)."""
    output = base / "xctest-output.log"
    output.write_text("Test Case '-[App.SmokeUITests testOpens]' passed (0.125 seconds).\n"
                      "Test Case '-[App.SmokeUITests testCloses]' passed (0.375 seconds).\n")
    # The gate echoes its command, which is not test output and must not add case time.
    command = f"cat {shlex.quote(str(output))}; sleep 1 # Test Case '-[App.SmokeUITests testNotExecuted]' passed (99.000 seconds)."
    catalog = {"version": 1, "codeExclude": [], "steps": [
        {"id": "ios.journeys", "trigger": {"always": True}, "command": command,
         "inputs": ["."], "budgetSeconds": 10, "timeoutSeconds": 20, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L4", "unlocks": "land"},
        {"id": "other-tests", "trigger": {"always": True}, "command": f"cat {shlex.quote(str(output))}",
         "inputs": ["."], "budgetSeconds": 10, "timeoutSeconds": 20, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "tier": "L3", "unlocks": "land"}]}
    path = base / "overhead-catalog.json"
    path.write_text(json.dumps(catalog))
    repo = Repo(base / "overhead", {**env, "TRON_GATE_CATALOG": str(path)})
    assert repo.gate("run").returncode == 0
    rows = [json.loads(line) for line in (repo.root / ".git/work/gate/metrics.jsonl").read_text().splitlines()]
    row = next(row for row in rows if row["step"] == "ios.journeys")
    assert row["testSeconds"] == 0.5, row
    assert all("testSeconds" not in row for row in rows if row["step"] != "ios.journeys"), rows
    digest = json.loads(repo.gate("report", "--since", "1h", "--json").stdout)
    assert list(digest["testOverhead"]) == ["ios.journeys"], digest["testOverhead"]
    overhead = digest["testOverhead"]["ios.journeys"]
    evidence.append({"case": "XCTest case time and shard overhead are recorded", "row": row, "overhead": overhead})
    assert overhead["shards"] == 1 and overhead["p50"] == round(row["seconds"] - 0.5, 1), overhead


def cancellation_cleanup(base: Path, env: dict) -> None:
    """Cancellation is terminal only after the step's resource-release handler joins."""
    ready, term, release = (base / name for name in ("cancel-ready", "cancel-term", "cancel-release"))
    script = base / "cancel-step.py"
    script.write_text(f'''import os, signal, time
from pathlib import Path
stopping = False
def stop(*_):
    global stopping
    stopping = True
signal.signal(signal.SIGTERM, stop)
Path({str(ready)!r}).write_text(str(os.getpid()))
while not stopping:
    time.sleep(0.02)
Path({str(term)!r}).touch()
while not Path({str(release)!r}).exists():
    time.sleep(0.02)
''')
    catalog = base / "cancel-catalog.json"
    catalog.write_text(json.dumps({"version": 1, "steps": [
        {"id": "cleanup", "trigger": {"always": True},
         "command": f"exec {shlex.quote(sys.executable)} {shlex.quote(str(script))}",
         "inputs": ["."], "budgetSeconds": 30, "timeoutSeconds": 60, "class": "light",
         "expectedRssMb": 10, "pass": "exit 0", "tier": "L1", "unlocks": "land"}]}))
    # Hold one real ps sampling boundary. A group-wide TERM kills this sampler and
    # used to erase the gate's known tree, leaving the separately-sessioned step alive.
    hold, sampling, sampled = (base / name for name in ("sample-hold", "sample-ready", "sample-release"))
    bin_dir = base / "cancel-bin"
    bin_dir.mkdir()
    sampler = bin_dir / "ps"
    sampler.write_text(f'''#!{sys.executable}
import os, sys, time
from pathlib import Path
if Path({str(hold)!r}).exists() and not Path({str(sampled)!r}).exists():
    Path({str(sampling)!r}).touch()
    while not Path({str(sampled)!r}).exists():
        time.sleep(0.02)
os.execv('/bin/ps', ['ps', *sys.argv[1:]])
''')
    sampler.chmod(0o755)
    repo = Repo(base / "cancellation", {**env, "TRON_GATE_CATALOG": str(catalog),
                                      "PATH": str(bin_dir) + os.pathsep + env["PATH"]})
    submitted = repo.gate("submit")
    assert submitted.returncode == 0, submitted.stdout + submitted.stderr
    job = submitted.stdout.split("submitted job ")[1].split()[0]
    waiter = None
    try:
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert ready.exists(), "step did not become ready"
        hold.touch()
        deadline = time.monotonic() + 10
        while not sampling.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert sampling.exists(), "runner did not reach the sampling boundary"
        assert repo.gate("cancel", job).returncode == 0
        sampled.touch()
        deadline = time.monotonic() + 10
        while not term.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert term.exists(), "cancellation must reach the step's cleanup handler"
        assert f"{job}  cancelling" in repo.gate("jobs").stdout
        assert "already cancelling" in repo.gate("cancel", job).stdout
        waiter = subprocess.Popen([sys.executable, str(GATE), "wait", job], cwd=repo.root, env=repo.env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # Cross the old 15-second daemon-join cutoff while cleanup is held by a real resource.
        try:
            output = waiter.communicate(timeout=16)[0]
        except subprocess.TimeoutExpired:
            pass
        else:
            evidence.append({"case": "cancel returned before cleanup", "output": output})
            raise AssertionError("gate wait must join cancellation cleanup, not just its request\n" + output)
        job_pid = json.loads((repo.root / ".git/work/gate/jobs" / job / "job.json").read_text())["pid"]
        os.kill(job_pid, 0)
        release.touch()
        output = waiter.communicate(timeout=10)[0]
        assert waiter.returncode == 130 and f"job {job} cancelled" in output, output
        assert "cancellation requested; joining step cleanup" in output and "step cleanup joined" in output, output
        step_pid = int(ready.read_text())
        try:
            os.kill(step_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("settled cancellation left its step process behind")
        evidence.append({"case": "cancellation joins cleanup beyond the old daemon cutoff", "output": output})
    finally:
        sampled.touch()
        release.touch()
        if ready.exists():
            with contextlib.suppress(ProcessLookupError):
                os.kill(int(ready.read_text()), 15)
        if waiter and waiter.poll() is None:
            waiter.communicate(timeout=10)
        # The failing control still owns this process; release its fixture before removing files.
        if ready.exists():
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    os.kill(int(ready.read_text()), 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)


def main() -> None:
    global REPORT
    policy_only = sys.argv[1:] == ["--source-policy"]
    if sys.argv[1:] and not policy_only:
        raise SystemExit("usage: test-gate.py [--source-policy]")
    if policy_only:
        REPORT = ROOT / "test-results" / "ios-source-policy.json"
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-gate-") as temporary:
            base = Path(temporary)
            (base / "home").mkdir()
            (base / "tmp").mkdir()
            env = {**{k: v for k, v in os.environ.items() if k not in ("TRON_HEAVY_LEASE_HELD", "WORK_SESSION_ID", "PI_SESSION_ID")},
                   "HOME": str(base / "home"), "TMPDIR": str(base / "tmp"), "TRON_HEAVY_DIR": str(base / "heavy"),
                   # Admission must not depend on this Mac's CPU while the fixtures run.
                   "TRON_HEAVY_BUSY_CORES": "0", "TRON_GATE_PURPOSE": "work",
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "NVM_DIR": os.environ.get("NVM_DIR", str(Path.home() / ".nvm"))}
            if policy_only:
                env["TRON_CI_TOOLS_DIR"] = str(Path(os.environ.get("TRON_CI_TOOLS_DIR", ROOT / ".ci-tools")).resolve())
                source_policy(base, env)
                print(f"Passed iOS source-policy journey; evidence: {REPORT}")
                return
            test_overhead(base, env)
            cancellation_cleanup(base, env)
            timed_out_tree(base, env)
            plans(base, env)
            claim_selection(base, env)
            verification_selection(base, env)
            boundary_plans(base, env)
            hosted_cli(base, env)
            inherited_suite(base, env)
            replacement_selection(base, env)
            source_scope(base, env)
            for kind in ("catalog", "prelude", "dependency", "dependency-input", "bootstrap", "missing-after"):
                verification_contract(base, env, kind)
            flakes_and_quarantine(base, env)
            key_hygiene(base, env)
            runner(base, env)
        print(f"Passed gate journeys; evidence: {REPORT}")
    finally:
        REPORT.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
