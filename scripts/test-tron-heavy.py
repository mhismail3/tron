#!/usr/bin/env python3
"""Host-wide heavy-run queue journeys with real concurrent processes (#915).

Each case runs tools/work/heavy.py as separate processes against an isolated queue
directory and observes the commands it starts. Evidence: test-results/tron-heavy.json.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEAVY = ROOT / "tools" / "work" / "heavy.py"
REPORT = ROOT / "test-results" / "tron-heavy.json"
# The command each run executes: record its start, wait for its release file, record its end.
WORK = ("import pathlib, sys, time\n"
        "log = pathlib.Path(sys.argv[1]); name = sys.argv[2]; release = pathlib.Path(sys.argv[3])\n"
        "with log.open('a') as f: f.write(f'start {name}\\n')\n"
        "while not release.exists(): time.sleep(0.05)\n"
        "with log.open('a') as f: f.write(f'end {name}\\n')\n")


class Fixture:
    def __init__(self, root: Path, **environment: str):
        self.root = root
        self.log = root / "log"
        self.log.touch()
        self.environment = {**{k: v for k, v in os.environ.items() if k != "TRON_HEAVY_LEASE_HELD"},
                            "TRON_HEAVY_DIR": str(root / "queue"), "TRON_HEAVY_SLOTS": "2",
                            "TRON_HEAVY_MAX_LOAD": "100000", "TRON_HEAVY_AVAILABLE_MB": "1000000",
                            "TRON_HEAVY_MEMORY_BUDGET_MB": "1000000", **environment}
        self.processes: dict[str, subprocess.Popen] = {}

    def start(self, name: str, need_mb: int = 3000, **environment: str) -> subprocess.Popen:
        output = (self.root / f"{name}.out").open("w")
        process = subprocess.Popen([sys.executable, str(HEAVY), "run", "--owner", name, "--need-mb", str(need_mb), "--",
                                    sys.executable, "-c", WORK, str(self.log), name, str(self.root / f"release-{name}")],
                                   env={**self.environment, **environment}, stdout=output, stderr=subprocess.STDOUT)
        self.processes[name] = process
        return process

    def release(self, name: str) -> None:
        (self.root / f"release-{name}").touch()

    def events(self) -> list[str]:
        return self.log.read_text().split()

    def started(self) -> list[str]:
        lines = self.log.read_text().splitlines()
        return [line.split()[1] for line in lines if line.startswith("start ")]

    def running(self) -> set[str]:
        lines = self.log.read_text().splitlines()
        running: set[str] = set()
        for line in lines:
            kind, name = line.split()
            (running.add if kind == "start" else running.discard)(name)
        return running

    def output(self, name: str) -> str:
        return (self.root / f"{name}.out").read_text()

    def status(self) -> str:
        return subprocess.run([sys.executable, str(HEAVY), "status"], env=self.environment,
                              capture_output=True, text=True, check=True).stdout

    def close(self) -> None:
        for name in self.processes:
            self.release(name)
        for process in self.processes.values():
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()


def wait_until(predicate, label: str, seconds: float = 10.0) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {label}")


def max_concurrency(events: list[str]) -> int:
    running = peak = 0
    for index in range(0, len(events), 2):
        running += 1 if events[index] == "start" else -1
        peak = max(peak, running)
    return peak


def case_slots_fifo_and_positions(root: Path) -> dict:
    fixture = Fixture(root)
    try:
        for name in ("a", "b"):
            fixture.start(name)
            wait_until(lambda name=name: name in fixture.running(), f"{name} started")
        for name in ("c", "d"):
            fixture.start(name)
            wait_until(lambda name=name: "queued at position" in fixture.output(name), f"{name} queued")
        # A waiter reprints its position whenever the queue changes.
        wait_until(lambda: "queued at position 1 of 2" in fixture.output("c"), "c sees d behind it")
        assert "queued at position 2 of 2" in fixture.output("d"), fixture.output("d")
        status = fixture.status()
        assert status.count("running  slot") == 2 and "queued   #1: c" in status and "queued   #2: d" in status, status
        time.sleep(1.5)
        assert fixture.running() == {"a", "b"}, fixture.running()
        fixture.release("b")
        wait_until(lambda: "c" in fixture.running(), "c takes the freed slot")
        assert "d" not in fixture.running()
        wait_until(lambda: "queued at position 1 of 1" in fixture.output("d"), "d advances to the head")
        fixture.release("a")
        wait_until(lambda: "d" in fixture.running(), "d starts next")
        for name in ("c", "d"):
            fixture.release(name)
        for process in fixture.processes.values():
            assert process.wait(timeout=10) == 0
        events = fixture.events()
        assert fixture.started() == ["a", "b", "c", "d"], fixture.started()
        assert max_concurrency(events) == 2, events
        return {"started": fixture.started(), "maxConcurrent": max_concurrency(events), "status": status.splitlines()}
    finally:
        fixture.close()


def case_holder_killed_slot_follows_command_tree(root: Path) -> dict:
    fixture = Fixture(root, TRON_HEAVY_SLOTS="1")
    try:
        holder = fixture.start("a")
        wait_until(lambda: "a" in fixture.running(), "a started")
        holder.send_signal(signal.SIGKILL)
        holder.wait(timeout=5)
        fixture.start("b")
        wait_until(lambda: "queued at position 1 of 1" in fixture.output("b"), "b queued behind a's live command")
        time.sleep(1.5)
        assert "b" not in fixture.running(), "the slot outlived its holder only as long as its command"
        fixture.release("a")
        wait_until(lambda: "b" in fixture.running(), "b starts once a's command ends")
        fixture.release("b")
        return {"queuedWhileOrphanedCommandRan": True, "started": fixture.started()}
    finally:
        fixture.close()


def case_dead_waiter_leaves_queue(root: Path) -> dict:
    fixture = Fixture(root, TRON_HEAVY_SLOTS="1")
    try:
        fixture.start("a")
        wait_until(lambda: "a" in fixture.running(), "a started")
        waiter = fixture.start("b")
        wait_until(lambda: "queued at position 1 of 1" in fixture.output("b"), "b queued")
        fixture.start("c")
        wait_until(lambda: "queued at position 2 of 2" in fixture.output("c"), "c queued behind b")
        waiter.send_signal(signal.SIGKILL)
        waiter.wait(timeout=5)
        wait_until(lambda: "queued at position 1 of 1" in fixture.output("c"), "c advances past the dead waiter")
        fixture.release("a")
        wait_until(lambda: "c" in fixture.running(), "c starts")
        fixture.release("c")
        assert "b" not in fixture.started()
        return {"started": fixture.started()}
    finally:
        fixture.close()


def case_load_gate_is_bounded(root: Path) -> dict:
    fixture = Fixture(root, TRON_HEAVY_MAX_LOAD="0", TRON_HEAVY_PRESSURE_MAX_WAIT_SECONDS="2")
    try:
        started = time.monotonic()
        fixture.start("a")
        wait_until(lambda: "waiting for host load" in fixture.output("a"), "a waits on host load")
        wait_until(lambda: "a" in fixture.running(), "a starts after the bounded pressure wait")
        waited = time.monotonic() - started
        assert waited >= 1.9, waited
        fixture.release("a")
        return {"waitedSeconds": round(waited, 1)}
    finally:
        fixture.close()


def case_inherited_slot_never_waits(root: Path) -> dict:
    fixture = Fixture(root, TRON_HEAVY_SLOTS="1")
    try:
        fixture.start("a")
        wait_until(lambda: "a" in fixture.running(), "a started")
        fixture.start("nested", TRON_HEAVY_LEASE_HELD="1")
        wait_until(lambda: "nested" in fixture.running(), "a command that inherited a slot runs at once")
        assert "queued" not in fixture.output("nested")
        for name in ("nested", "a"):
            fixture.release(name)
        return {"running": ["a", "nested"]}
    finally:
        fixture.close()


def case_memory_admission(root: Path) -> dict:
    """Free slots do not admit a step whose expected RSS does not fit (#1023)."""
    fixture = Fixture(root, TRON_HEAVY_SLOTS="4", TRON_HEAVY_MEMORY_BUDGET_MB="10000")
    try:
        fixture.start("a", need_mb=6000)
        wait_until(lambda: "a" in fixture.running(), "the first heavy step always starts")
        fixture.start("b", need_mb=6000)
        wait_until(lambda: "waiting for memory: heavy steps claim 6000 MB of the 10000 MB heavy budget" in fixture.output("b"),
                   "b waits on the heavy memory budget with free slots")
        fixture.start("c", need_mb=1000)
        wait_until(lambda: "queued at position 2 of 2" in fixture.output("c"), "c keeps FIFO order behind b")
        status = fixture.status()
        assert "6000 MB claimed" in status and "needs 6000 MB" in status, status
        time.sleep(1.5)
        assert fixture.running() == {"a"}, fixture.running()
        fixture.release("a")
        wait_until(lambda: {"b", "c"} <= fixture.running(), "b and c fit together once a ends")
        for name in ("b", "c"):
            fixture.release(name)
        # Host memory: with too little available beyond the reserve, a second step waits.
        (root / "low").mkdir()
        low = Fixture(root / "low", TRON_HEAVY_SLOTS="4", TRON_HEAVY_AVAILABLE_MB="7000", TRON_HEAVY_RESERVE_MB="6144")
        try:
            low.start("d", need_mb=2000)
            wait_until(lambda: "d" in low.running(), "d starts")
            low.start("e", need_mb=2000)
            wait_until(lambda: "host has 856 MB available beyond the 6144 MB reserve" in low.output("e"), "e waits on host memory")
            low.release("d")
            wait_until(lambda: "e" in low.running(), "e starts alone")
            low.release("e")
        finally:
            low.close()
        return {"started": fixture.started(), "status": status.splitlines()}
    finally:
        fixture.close()


def main() -> int:
    cases = [case_memory_admission, case_slots_fifo_and_positions, case_holder_killed_slot_follows_command_tree,
             case_dead_waiter_leaves_queue, case_load_gate_is_bounded, case_inherited_slot_never_waits]
    evidence = []
    failed = False
    for case in cases:
        root = Path(tempfile.mkdtemp(prefix="tron-heavy-"))
        try:
            evidence.append({"case": case.__name__, "result": "pass", **case(root)})
            print(f"pass: {case.__name__}")
        except Exception as error:  # noqa: BLE001 - every case reports
            failed = True
            evidence.append({"case": case.__name__, "result": "fail", "error": str(error)})
            print(f"FAIL: {case.__name__}: {error}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({"suite": "tron-heavy", "cases": evidence}, indent=2) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
