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

import json
import os
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
        self.write("README.md", "fixture\n")
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


def plans(base: Path, env: dict) -> None:
    cases = {
        "gateway-only": ({"packages/gateway/src/home/x.ts": "export const x = 1;\n"},
                         ["repo.privacy", "repo.whitespace", "gateway.deps", "gateway.typecheck",
                          "gateway.affected#1/3", "gateway.affected#2/3", "gateway.affected#3/3",
                          "gateway.affected-nested#1/3", "gateway.affected-nested#2/3", "gateway.affected-nested#3/3"]),
        "lockfile": ({"packages/gateway/package-lock.json": "{}\n"},
                     ["repo.privacy", "repo.whitespace", "gateway.deps", "gateway.typecheck", "gateway.scripts",
                      "gateway.full#1/4", "gateway.full#2/4", "gateway.full#3/4", "gateway.full#4/4",
                      "gateway.full-nested#1/3", "gateway.full-nested#2/3", "gateway.full-nested#3/3"]),
        "ios-only": ({"packages/ios-app/Sources/UI/View.swift": "// view\n",
                      "packages/ios-app/UITests/TronHomeSheetsUITests.swift": "// journey\n"},
                     ["repo.privacy", "repo.whitespace", "ios.build", "ios.journeys[TronHomeSheetsUITests]"]),
        "mac-only": ({"packages/mac-app/Sources/App.swift": "// app\n"},
                     ["repo.privacy", "repo.whitespace", "mac.build", "mac.test"]),
        "gateway-and-config": ({"packages/gateway/src/home/x.ts": "export const x = 1;\n", "packages/gateway/vitest.config.ts": "export {};\n"},
                               ["repo.privacy", "repo.whitespace", "gateway.deps", "gateway.typecheck",
                                "gateway.full#1/4", "gateway.full#2/4", "gateway.full#3/4", "gateway.full#4/4",
                                "gateway.full-nested#1/3", "gateway.full-nested#2/3", "gateway.full-nested#3/3"]),
        "protocol": ({"config/GatewayProtocol.json": "{}\n"},
                     ["repo.privacy", "repo.whitespace", "protocol.contract", "mac.build", "gateway.full#1/4",
                      "gateway.full#2/4", "gateway.full#3/4", "gateway.full#4/4", "gateway.full-nested#1/3",
                      "gateway.full-nested#2/3", "gateway.full-nested#3/3", "ios.build"]),
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
        actual = [row["shard"] for row in json.loads(result.stdout)["plan"]]
        evidence.append({"case": f"plan {name}", "plan": actual})
        assert actual == expected, f"{name}: {actual} != {expected}"


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
        {"id": "par", "trigger": {"paths": ["par/**"]}, "shards": 2, "parallelShards": True,
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


def main() -> None:
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="tron-gate-") as temporary:
            base = Path(temporary)
            (base / "home").mkdir()
            (base / "tmp").mkdir()
            env = {**{k: v for k, v in os.environ.items() if k != "TRON_HEAVY_LEASE_HELD"},
                   "HOME": str(base / "home"), "TMPDIR": str(base / "tmp"), "TRON_HEAVY_DIR": str(base / "heavy"),
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            plans(base, env)
            runner(base, env)
        print(f"Passed gate journeys; evidence: {REPORT}")
    finally:
        REPORT.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
