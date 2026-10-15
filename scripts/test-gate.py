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
                     ["repo.privacy", "repo.whitespace", "ios.build", "ios.device-compile", "ios.journeys[TronHomeSheetsUITests.testA+1]",
                      "ios.journeys[TronHomeSheetsUITests.testC]"]),
        # A UI test class with its own harness runs through it as a journey, never the plain runner.
        "ios-harness": ({"packages/ios-app/UITests/TronMacTerminalUITests.swift":
                             "import XCTest\n\n// gate-journey: scripts/ios-mac-terminal-journey\n"
                             "final class TronMacTerminalUITests: XCTestCase {\n    func testA() {}\n}\n"},
                        ["repo.privacy", "repo.whitespace", "ios.build", "ios.device-compile", "ios.journeys[smoke]",
                         "journey[1]"]),
        # Every method XCTest runs is selected whatever its attributes, modifiers or file, and
        # nothing XCTest does not run is (#1069).
        "ios-declarations": ({
            "packages/ios-app/UITests/TronFixtureUITests.swift": IOS_DECLARATIONS,
            "packages/ios-app/UITests/TronFixtureUITests+Extension.swift": IOS_EXTENSION},
            ["repo.privacy", "repo.whitespace", "ios.build", "ios.device-compile",
             "ios.journeys[TronFixtureUITests.testExtended+1]", "ios.journeys[TronFixtureUITests.testAttributed+1]",
             "ios.journeys[TronFixtureUITests.testOverridden]", "ios.journeys[TronDerivedUITests.testDerived]"]),
        "mac-only": ({"packages/mac-app/Sources/App.swift": "// app\n"},
                     ["repo.privacy", "repo.whitespace", "mac.build", "mac.test"]),
        "gateway-and-config": ({"packages/gateway/src/home/x.ts": "export const x = 1;\n", "packages/gateway/vitest.config.ts": "export {};\n"},
                               ["repo.privacy", "repo.whitespace", "gateway.deps", "gateway.typecheck",
                                "gateway.full#1/6", "gateway.full#2/6", "gateway.full#3/6", "gateway.full#4/6", "gateway.full#5/6", "gateway.full#6/6",
                                "gateway.nested[subagents-settlement]", "gateway.nested[subagents-reports]", "gateway.nested[subagents-controls]", "gateway.nested[rest]"]),
        "protocol": ({"config/GatewayProtocol.json": "{}\n"},
                     ["repo.privacy", "repo.whitespace", "protocol.contract", "mac.build", "gateway.full#1/6", "gateway.full#2/6", "gateway.full#3/6", "gateway.full#4/6", "gateway.full#5/6", "gateway.full#6/6", "gateway.nested[subagents-settlement]", "gateway.nested[subagents-reports]", "gateway.nested[subagents-controls]", "gateway.nested[rest]", "ios.build", "ios.device-compile", "ios.gateway-boundary[build]", "ios.gateway-boundary[resilience]", "ios.gateway-boundary[lan]"]),
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


FIXTURE_CATALOG = {
    "version": 1,
    "codeExclude": ["**/*.md"],
    "steps": [
        {"id": "first", "trigger": {"always": True}, "command": "echo first >> \"$GATE_TRACE\"",
         "inputs": ["a"], "budgetSeconds": 5, "timeoutSeconds": 10, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "unlocks": "sharded"},
        {"id": "sharded", "trigger": {"always": True}, "shards": 3,
         "command": "echo sharded-{shard} >> \"$GATE_TRACE\"; sleep 1; if [ {shard} = 2 ] && [ -e \"$GATE_FAIL\" ]; then "
                    "echo 'assertion failed: shard two saw the injected failure' >&2; exit 3; fi",
         "inputs": ["b"], "budgetSeconds": 5, "timeoutSeconds": 10, "class": "heavy", "expectedRssMb": 10,
         "pass": "exit 0", "unlocks": "slow"},
        {"id": "slow", "trigger": {"paths": ["slow/**"]}, "command": "echo slow >> \"$GATE_TRACE\"; sleep 30",
         "inputs": ["slow"], "budgetSeconds": 1, "timeoutSeconds": 2, "class": "light", "expectedRssMb": 10,
         "pass": "exit 0", "unlocks": "long"},
        {"id": "long", "trigger": {"paths": ["long/**"]}, "command": "echo $$ > \"$GATE_TRACE.pid\"; sleep 30",
         "inputs": ["long"], "budgetSeconds": 40, "timeoutSeconds": 60, "class": "heavy", "expectedRssMb": 10,
         "pass": "exit 0", "unlocks": "par"},
        {"id": "par", "trigger": {"paths": ["par/**"]}, "shards": 2, "parallelShards": 2,
         "command": "if [ {shard} = 1 ]; then sleep 1; echo 'shard one fails' >&2; exit 4; fi; sleep 30",
         "inputs": ["par"], "budgetSeconds": 20, "timeoutSeconds": 60, "class": "heavy", "expectedRssMb": 10,
         "pass": "exit 0", "unlocks": "land"},
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
        raise AssertionError("cancel must stop the running step's process group")
    waited = repo.gate("wait", job)
    evidence.append({"case": "submit, jobs, cancel, wait", "jobs": listing, "cancel": cancelled.stdout, "wait": waited.stdout[-1500:]})
    assert waited.returncode != 0 and f"job {job} cancelled" in waited.stdout, waited.stdout
    (repo.root / "long/file").unlink()
    result = repo.gate("submit")
    job = result.stdout.split("submitted job ")[1].split()[0]
    waited = repo.gate("wait", job)
    assert waited.returncode == 0 and f"job {job} passed" in waited.stdout and "reused" in waited.stdout, waited.stdout
    repo.write("slow/file", "slow\n")

    # Parallel shards of one step: the first failure stops its running sibling at once.
    (repo.root / "slow/file").unlink()
    repo.write("par/file", "par\n")
    result = repo.gate("run")
    evidence.append({"case": "a failing parallel shard stops its sibling", "exit": result.returncode, "seconds": result.seconds,
                     "stdout": result.stdout[-2000:]})
    assert result.returncode == 1 and "par#1/2: FAIL (exit 4)" in result.stdout, result.stdout
    assert "par#2/2: stopped after a sibling shard failed" in result.stdout and "gate: stopped at par#1/2" in result.stdout
    assert result.seconds < 15, "the sibling must not run its 30 s"
    (repo.root / "par/file").unlink()
    repo.write("slow/file", "slow\n")

    sys.path.insert(0, str(GATE.parent))
    import gate  # noqa: E402
    try:
        gate.verify(repo.root, json.loads((ROOT / ".github/work.json").read_text()), [], "origin/main")
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
         "unlocks": "land"}]}
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
    for path in ("scripts/tron", "scripts/tron-node", "tools/work/gate.py", "tools/work/heavy.py",
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


def main() -> None:
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-gate-") as temporary:
            base = Path(temporary)
            (base / "home").mkdir()
            (base / "tmp").mkdir()
            env = {**{k: v for k, v in os.environ.items() if k != "TRON_HEAVY_LEASE_HELD"},
                   "HOME": str(base / "home"), "TMPDIR": str(base / "tmp"), "TRON_HEAVY_DIR": str(base / "heavy"),
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "NVM_DIR": os.environ.get("NVM_DIR", str(Path.home() / ".nvm"))}
            timed_out_tree(base, env)
            plans(base, env)
            boundary_plans(base, env)
            hosted_cli(base, env)
            inherited_suite(base, env)
            runner(base, env)
        print(f"Passed gate journeys; evidence: {REPORT}")
    finally:
        REPORT.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
