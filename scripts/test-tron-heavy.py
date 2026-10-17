#!/usr/bin/env python3
"""Host-wide heavy-run queue journeys with real concurrent processes (#915, #1023, #1083).

Each case runs tools/work/heavy.py (or a gate run's job driving it) as separate processes
against an isolated queue directory and observes the commands it starts. Host CPU, memory
and booted simulators are pinned through their overrides so admission is deterministic.
Evidence: test-results/tron-heavy.json.
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
# The command each run executes: record its start with the cores it was granted, wait for
# its release file, record its end.
WORK = ("import os, pathlib, sys, time\n"
        "log = pathlib.Path(sys.argv[1]); name = sys.argv[2]; release = pathlib.Path(sys.argv[3])\n"
        "with log.open('a') as f: f.write(f'start {name} {os.environ.get(\"TRON_HEAVY_CORES\", \"-\")}\\n')\n"
        "while not release.exists(): time.sleep(0.05)\n"
        "with log.open('a') as f: f.write(f'end {name}\\n')\n")


class Fixture:
    def __init__(self, root: Path, **environment: str):
        self.root = root
        self.log = root / "log"
        self.log.touch()
        self.environment = {**{k: v for k, v in os.environ.items() if k not in ("TRON_HEAVY_LEASE_HELD", "TRON_HEAVY_CORES")},
                            "TRON_HEAVY_DIR": str(root / "queue"), "TRON_HEAVY_SLOTS": "2", "TRON_HEAVY_JOBS": "8",
                            "TRON_HEAVY_CPUS": "16", "TRON_HEAVY_CPU_BUDGET": "1000", "TRON_HEAVY_BUSY_CORES": "0",
                            "TRON_HEAVY_BOOTED_SIMULATORS": "0", "TRON_HEAVY_AVAILABLE_MB": "1000000",
                            "TRON_HEAVY_MEMORY_BUDGET_MB": "1000000", **environment}
        self.processes: dict[str, subprocess.Popen] = {}

    def start(self, name: str, need_mb: int = 3000, cores: float = 1, cores_min: float | None = None,
              pool: str | None = None, **environment: str) -> subprocess.Popen:
        output = (self.root / f"{name}.out").open("w")
        options = ["--cores", str(cores)] + (["--cores-min", str(cores_min)] if cores_min else []) + (["--pool", pool] if pool else [])
        # Its own session, so a case can kill the holder together with its command tree.
        process = subprocess.Popen([sys.executable, str(HEAVY), "run", "--owner", name, "--need-mb", str(need_mb), *options, "--",
                                    sys.executable, "-c", WORK, str(self.log), name, str(self.root / f"release-{name}")],
                                   env={**self.environment, **environment}, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        self.processes[name] = process
        return process

    def job(self, name: str, steps: int, pool: str = "", **environment: str) -> subprocess.Popen:
        """A gate run: one heavy-queue Job whose steps run one after another (gate.execute)."""
        output = (self.root / f"{name}.out").open("w")
        process = subprocess.Popen([sys.executable, "-c", JOB, str(HEAVY.parent), str(self.log), name, str(self.root), str(steps), pool],
                                   env={**self.environment, **environment}, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        self.processes[name] = process
        return process

    def granted(self, name: str) -> str:
        return next(line.split()[2] for line in self.log.read_text().splitlines() if line.split()[:2] == ["start", name])

    def release(self, name: str) -> None:
        (self.root / f"release-{name}").touch()

    def events(self) -> list[str]:
        return [word for line in self.log.read_text().splitlines() for word in line.split()[:2]]

    def started(self) -> list[str]:
        lines = self.log.read_text().splitlines()
        return [line.split()[1] for line in lines if line.startswith("start ")]

    def running(self) -> set[str]:
        lines = self.log.read_text().splitlines()
        running: set[str] = set()
        for line in lines:
            kind, name = line.split()[:2]
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
            for step in range(4):
                self.release(f"{name}.{step}")
        for process in self.processes.values():
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()


# A gate run's job: `steps` heavy steps in sequence under one heavy.Job, each named
# <name>.<i> and released by its release file, the job slot held until the run ends.
# The last step runs in `pool`, if one is given.
JOB = ("import os, pathlib, subprocess, sys\n"
       "sys.path.insert(0, sys.argv[1]); import heavy\n"
       "log, name, root, steps = pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4]), int(sys.argv[5])\n"
       "pool = sys.argv[6] or None\n"
       "job = heavy.Job(name)\n"
       "try:\n"
       "    for index in range(steps):\n"
       "        step = f'{name}.{index}'\n"
       "        lease = heavy.acquire(step, 'step', need_mb=1000, cores=1, job=job, pool=pool if index == steps - 1 else None)\n"
       "        try:\n"
       "            subprocess.run([sys.executable, '-c', " + repr(WORK) + ", str(log), step, str(root / f'release-{step}')],\n"
       "                           env={**os.environ, **lease.environment()}, pass_fds=(lease.fd,), check=True)\n"
       "        finally:\n"
       "            lease.release()\n"
       "finally:\n"
       "    job.release()\n")


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
            wait_until(lambda name=name: "position" in fixture.output(name), f"{name} queued")
        # A waiter reprints its position whenever the queue changes.
        wait_until(lambda: "position 1 of 2" in fixture.output("c"), "c sees d behind it")
        assert "position 2 of 2" in fixture.output("d"), fixture.output("d")
        status = fixture.status()
        assert status.count("running  slot") == 2 and "queued   #1: c" in status and "queued   #2: d" in status, status
        repo = root / "status-repo"
        (repo / ".github").mkdir(parents=True)
        shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
        home, temporary = root / "home", root / "tmp"
        home.mkdir(); temporary.mkdir()
        environment = {**fixture.environment, "HOME": str(home), "TMPDIR": str(temporary),
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        subprocess.run(["git", "init", "-b", "main"], cwd=repo, env=environment, check=True, capture_output=True)
        def home_status():
            result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "status", "--json"],
                                    cwd=repo, env=environment, check=True, capture_output=True, text=True, timeout=10)
            return json.loads(result.stdout)
        before = home_status()
        assert before["heavy"] == {"running": 2, "waiting": 2, "gateJobs": 2}, before
        assert before["land"] == {"running": 0, "waiting": 0}, before
        assert before["advice"] is None and before["adviceError"], before  # No remote: not disjoint.
        time.sleep(1.5)
        assert fixture.running() == {"a", "b"}, fixture.running()
        fixture.release("b")
        wait_until(lambda: "c" in fixture.running(), "c takes the freed slot")
        assert "d" not in fixture.running()
        wait_until(lambda: "position 1 of 1" in fixture.output("d"), "d advances to the head")
        fixture.release("a")
        wait_until(lambda: "d" in fixture.running(), "d starts next")
        for name in ("c", "d"):
            fixture.release(name)
        for process in fixture.processes.values():
            assert process.wait(timeout=10) == 0
        events = fixture.events()
        assert fixture.started() == ["a", "b", "c", "d"], fixture.started()
        assert max_concurrency(events) == 2, events
        after = home_status()
        assert after["heavy"] == {"running": 0, "waiting": 0, "gateJobs": 0}, after
        return {"started": fixture.started(), "maxConcurrent": max_concurrency(events), "status": status.splitlines(),
                "homeWorkStatusBefore": before, "homeWorkStatusAfter": after}
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
        wait_until(lambda: "position 1 of 1" in fixture.output("b"), "b queued behind a's live command")
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
        wait_until(lambda: "position 1 of 1" in fixture.output("b"), "b queued")
        fixture.start("c")
        wait_until(lambda: "position 2 of 2" in fixture.output("c"), "c queued behind b")
        waiter.send_signal(signal.SIGKILL)
        waiter.wait(timeout=5)
        wait_until(lambda: "position 1 of 1" in fixture.output("c"), "c advances past the dead waiter")
        fixture.release("a")
        wait_until(lambda: "c" in fixture.running(), "c starts")
        fixture.release("c")
        assert "b" not in fixture.started()
        return {"started": fixture.started()}
    finally:
        fixture.close()


def case_cpu_admission(root: Path) -> dict:
    """Free slots and memory do not admit a step whose cores do not fit (#1083).

    The heavy CPU budget binds claims; the host's idle cores bind what runs outside the
    queue (booted simulators, unqueued builds). A scalable step starts with fewer cores and
    sizes itself to the grant. A waiter shows its position, why it waits and the host's CPU
    and memory as they are now.
    """
    fixture = Fixture(root, TRON_HEAVY_SLOTS="8", TRON_HEAVY_CPU_BUDGET="12", TRON_HEAVY_STATUS_SECONDS="1")
    try:
        fixture.start("a", cores=8)
        wait_until(lambda: "a" in fixture.running(), "the first heavy step always starts")
        fixture.start("b", cores=8)
        wait_until(lambda: "for cpu: heavy steps claim 8 of the 12-core heavy budget; this one needs 8 cores" in fixture.output("b"),
                   "b waits on the CPU budget with free slots and memory")
        fixture.start("c", cores=2)
        wait_until(lambda: "c" in fixture.running(), "c backfills the idle cores while b waits for CPU")
        # Live status: repeated as a heartbeat, with the host's CPU and memory now.
        wait_until(lambda: fixture.output("b").count("waiting at position 1 of 2") >= 2, "b repeats its status")
        line = [l for l in fixture.output("b").splitlines() if "waiting at position 1" in l][-1]
        assert "host cpu 0.0/16 cores busy" in line and "1000000 MB memory available" in line and "running: a (pid" in line, line
        status = fixture.status()
        assert "heavy claims 10/12 cores" in status and "waits for cpu" in status, status
        assert fixture.running() == {"a", "c"}, fixture.running()
        fixture.release("a")
        wait_until(lambda: {"b", "c"} <= fixture.running(), "b and c fit together once a ends")
        assert fixture.granted("b") == "8" and fixture.granted("c") == "2", fixture.log.read_text()
        # A scalable step (needs 8, can start with 2) takes the 2 cores left and is told so.
        fixture.start("d", cores=8, cores_min=2)
        wait_until(lambda: "d" in fixture.running(), "d starts on the cores left")
        assert fixture.granted("d") == "2", fixture.log.read_text()
        assert "started in slot" in fixture.output("d") and "(d, 2 cores" in fixture.output("d"), fixture.output("d")
        for name in ("b", "c", "d"):
            fixture.release(name)
        wait_until(lambda: not fixture.running(), "all done")
        # Live host CPU: with 14 of 16 cores busy outside the queue, a second step needing 4 waits.
        fixture.start("e", cores=4)
        wait_until(lambda: "e" in fixture.running(), "e starts")
        fixture.start("f", cores=4, TRON_HEAVY_BUSY_CORES="14")
        wait_until(lambda: "for cpu: host has 2.0 of 16 cores idle; this one needs 4 cores" in fixture.output("f"),
                   "f waits for idle host cores")
        fixture.release("e")
        wait_until(lambda: "f" in fixture.running(), "f starts alone: the first step always starts")
        fixture.release("f")
        return {"started": fixture.started(), "status": status.splitlines(), "statusLine": line}
    finally:
        fixture.close()


def case_pools_xcode_counts_booted_simulators(root: Path) -> dict:
    """At most TRON_HEAVY_XCODE_SLOTS xcode steps, counting simulators still booted, and one
    serial suite at a time (#1083).

    A step waiting only for an Xcode slot does not hold back a Gateway step behind it, and
    booted simulators never stop the first xcode step.
    """
    fixture = Fixture(root, TRON_HEAVY_SLOTS="8", TRON_HEAVY_XCODE_SLOTS="2", TRON_HEAVY_BOOTED_SIMULATORS="2")
    try:
        fixture.start("x1", pool="xcode")
        wait_until(lambda: "x1" in fixture.running(), "the first heavy step always starts")
        fixture.start("x2", pool="xcode")
        wait_until(lambda: "an Xcode slot (2 of 2 in use: 1 xcode steps, 2 booted simulators)" in fixture.output("x2"),
                   "x2 waits: two simulators are booted")
        fixture.start("g")
        wait_until(lambda: "g" in fixture.running(), "a Gateway step passes the xcode step waiting for its pool")
        fixture.release("x1")
        wait_until(lambda: "x2" in fixture.running(), "x2 starts: with no xcode step running, booted simulators never block")
        fixture.start("x3", pool="xcode", TRON_HEAVY_BOOTED_SIMULATORS="1")
        wait_until(lambda: "x3" in fixture.running(), "x3 joins x2 once the tooling released a simulator")
        for name in ("g", "x2", "x3"):
            fixture.release(name)
        wait_until(lambda: not fixture.running(), "all done")
        # Timing-sensitive real-process suites run one at a time host-wide.
        fixture.start("s1", pool="serial")
        wait_until(lambda: "s1" in fixture.running(), "s1 starts")
        fixture.start("s2", pool="serial")
        wait_until(lambda: "for a serial slot (1 of 1 running)" in fixture.output("s2"), "s2 waits for the serial slot")
        fixture.release("s1")
        wait_until(lambda: "s2" in fixture.running(), "s2 starts once s1 ends")
        fixture.release("s2")
        return {"started": fixture.started()}
    finally:
        fixture.close()


def case_gate_jobs_fair_and_bounded(root: Path) -> dict:
    """At most TRON_HEAVY_JOBS gate runs have heavy work in flight; a running job's next step
    goes ahead of runs waiting for a job slot, so admitted runs finish first (#1083)."""
    fixture = Fixture(root, TRON_HEAVY_SLOTS="8", TRON_HEAVY_JOBS="1")
    try:
        fixture.job("A", steps=2)
        wait_until(lambda: "A.0" in fixture.running(), "job A's first step starts")
        fixture.start("B")
        wait_until(lambda: "for a gate job slot (1 of 1 gate jobs have heavy work in flight)" in fixture.output("B"),
                   "B waits for a job slot")
        fixture.release("A.0")
        wait_until(lambda: "A.1" in fixture.running(), "A's next step goes ahead of B, which queued first")
        assert "B" not in fixture.running()
        fixture.release("A.1")
        wait_until(lambda: "B" in fixture.running(), "B starts once job A ends")
        fixture.release("B")
        assert fixture.processes["A"].wait(timeout=10) == 0
        # A run whose only waiting step waits for a full pool lends its place in the limit:
        # with S holding the serial pool, run C waits for it and D starts on idle cores.
        fixture.start("S", pool="serial", TRON_HEAVY_JOBS="2")
        wait_until(lambda: "S" in fixture.running(), "S holds the serial pool")
        fixture.job("C", steps=2, pool="serial", TRON_HEAVY_JOBS="2")
        wait_until(lambda: "C.0" in fixture.running(), "C's first step takes its job slot")
        fixture.release("C.0")
        wait_until(lambda: "for a serial slot" in fixture.output("C"), "C's next step waits for the pool")
        fixture.start("D", TRON_HEAVY_JOBS="2")
        wait_until(lambda: "D" in fixture.running(), "D starts: C lends its job slot while it waits for the pool")
        fixture.release("S")
        wait_until(lambda: "C.1" in fixture.running(), "C runs once the pool frees")
        for name in ("D", "C.1"):
            fixture.release(name)
        return {"started": fixture.started()}
    finally:
        fixture.close()


def case_dead_holder_slot_reclaimed(root: Path) -> dict:
    """A holder that dies with its command frees its step slot and its job slot at once."""
    fixture = Fixture(root, TRON_HEAVY_SLOTS="1", TRON_HEAVY_JOBS="1")
    try:
        holder = fixture.start("a")
        wait_until(lambda: "a" in fixture.running(), "a started")
        fixture.start("b")
        wait_until(lambda: "position 1 of 1" in fixture.output("b"), "b queued behind a")
        os.killpg(holder.pid, signal.SIGKILL)
        holder.wait(timeout=5)
        wait_until(lambda: "b" in fixture.running(), "b takes the dead holder's slot")
        fixture.release("b")
        # A gate run killed between steps frees the job slot it held without a step slot.
        job = fixture.job("J", steps=2)
        wait_until(lambda: "J.0" in fixture.running(), "J's first step runs")
        fixture.release("J.0")
        wait_until(lambda: "J.1" in fixture.running(), "J's second step runs")
        os.killpg(job.pid, signal.SIGKILL)
        job.wait(timeout=5)
        fixture.start("c")
        wait_until(lambda: "c" in fixture.running(), "c takes the killed run's job and step slots")
        fixture.release("c")
        return {"started": fixture.started()}
    finally:
        fixture.close()


def case_queue_wait_is_not_step_time(root: Path) -> dict:
    """A gate shard's hard limit starts when it is admitted, not when it queues (#1083)."""
    sys.path.insert(0, str(HEAVY.parent))
    fixture = Fixture(root, TRON_HEAVY_SLOTS="1")
    try:
        fixture.start("a")
        wait_until(lambda: "a" in fixture.running(), "a holds the only slot")
        driver = ("import pathlib, sys, threading\n"
                  "sys.path.insert(0, sys.argv[1]); import gate\n"
                  "root = pathlib.Path(sys.argv[2])\n"
                  "step = {'id': 'slow', 'class': 'heavy', 'expectedRssMb': 100, 'expectedCores': 1, 'budgetSeconds': 3,\n"
                  "        'timeoutSeconds': 3}\n"
                  "shard = gate.Shard(step, 1, 1, 'sleep 1')\n"
                  "outcome = gate.run_shard(root, '', shard, root / 'slow.log', dict(__import__('os').environ), '[1/1]')\n"
                  "print('outcome', outcome.outcome, outcome.seconds, outcome.queued_seconds)\n")
        output = (root / "slow.out").open("w")
        process = subprocess.Popen([sys.executable, "-c", driver, str(HEAVY.parent), str(root)], env=fixture.environment,
                                   stdout=output, stderr=subprocess.STDOUT)
        wait_until(lambda: "waiting at position 1 of 1 for a step slot" in (root / "slow.out").read_text(), "the shard queues")
        time.sleep(4)
        fixture.release("a")
        assert process.wait(timeout=30) == 0, (root / "slow.out").read_text()
        result = (root / "slow.out").read_text().split("outcome ")[-1].split()
        assert result[0] == "pass" and float(result[2]) >= 4 and float(result[1]) < 3, result
        return {"outcome": result[0], "seconds": float(result[1]), "queuedSeconds": float(result[2])}
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
        wait_until(lambda: "for memory: heavy steps claim 6000 MB of the 10000 MB heavy budget" in fixture.output("b"),
                   "b waits on the heavy memory budget with free slots")
        fixture.start("c", need_mb=1000)
        # A matched six-second holder workload measures the old FIFO cost as well as
        # reproducing the bug. Keep the failing timings in the ordinary suite artifact.
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and "c" not in fixture.started():
            time.sleep(0.05)
        backfilled = "c" in fixture.started()
        status = fixture.status()
        assert "a 1 cores 6000 MB" in status and "waits for memory" in status, status
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
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
        rows = [json.loads(line) for line in (root / "queue/events.jsonl").read_text().splitlines()]
        waits = {row["owner"]: row["queuedSeconds"] for row in rows if row["event"] == "acquire"}
        assert backfilled, f"small c did not start while big b waited; queuedSeconds={waits}"
        return {"started": fixture.started(), "status": status.splitlines(), "queuedSeconds": waits}
    finally:
        fixture.close()


def case_aged_head_drains_backfill(root: Path) -> dict:
    """A continuing supply of fitting small work cannot keep a large job out forever.

    Run the actual CLI: after its backfill window, an aged resource waiter closes
    backfill, lets already accepted work drain, and starts before the next small job.
    """
    sys.path.insert(0, str(HEAVY.parent))
    import heavy
    fixture = Fixture(root, TRON_HEAVY_SLOTS="8", TRON_HEAVY_MEMORY_BUDGET_MB="10000",
                      TRON_HEAVY_CPU_BUDGET="10", TRON_HEAVY_STATUS_SECONDS="1")
    try:
        fixture.start("holder", need_mb=6000, cores=6)
        wait_until(lambda: "holder" in fixture.running(), "holder starts")
        fixture.start("big", need_mb=9000, cores=9)
        wait_until(lambda: "for memory" in fixture.output("big"), "big waits for resources")
        fixture.start("early", need_mb=2000, cores=2)
        wait_until(lambda: "early" in fixture.running(), "small work backfills before the age bound")
        fixture.release("holder")
        wait_until(lambda: "holder" not in fixture.running(), "holder drains")
        # This second resource-blocked ticket is also aged before late arrives. It
        # must report its own resource reason, not hide behind the fairness barrier.
        fixture.start("other-big", need_mb=9000, cores=9)
        wait_until(lambda: "for memory" in fixture.output("other-big"), "other big queues")
        time.sleep(heavy.BACKFILL_SECONDS + 1)
        fixture.start("late", need_mb=2000, cores=2)
        wait_until(lambda: "head-of-line" in fixture.output("late"), "late waits for aged big, not resources")
        status = fixture.status()
        assert "late needs" in status and "head-of-line" in status and "backfill closed" in status, status
        assert "other-big needs" in status and "waits for memory" in status, status
        assert "late" not in fixture.started(), "fresh small jobs must not extend the drain"
        drained_at = time.monotonic()
        fixture.release("early")
        wait_until(lambda: "big" in fixture.running(), "big starts as accepted work drains")
        drain_seconds = time.monotonic() - drained_at
        assert "late" not in fixture.started(), fixture.started()
        fixture.release("big")
        wait_until(lambda: "other-big" in fixture.running(), "next aged big starts before late")
        assert "late" not in fixture.started(), fixture.started()
        fixture.release("other-big")
        wait_until(lambda: "late" in fixture.running(), "backfill resumes after protected heads run")
        fixture.release("late")
        for process in fixture.processes.values():
            assert process.wait(timeout=10) == 0
        rows = [json.loads(line) for line in (root / "queue/events.jsonl").read_text().splitlines()]
        waits = {row["owner"]: row["queuedSeconds"] for row in rows if row["event"] == "acquire"}
        assert waits["big"] <= heavy.BACKFILL_SECONDS + 10, waits
        return {"started": fixture.started(), "backfillSeconds": heavy.BACKFILL_SECONDS,
                "drainToBigStartSeconds": round(drain_seconds, 3), "queuedSeconds": waits,
                "status": status.splitlines()}
    finally:
        fixture.close()


def case_direct_vitest_waits_and_ledger_records_it(root: Path) -> dict:
    """A direct `vitest` run (a diagnosis run, outside any gate) waits for the heavy queue
    like a gate shard, then runs; the heavy ledger records both holders with their kind,
    wait and hold, and the vitest admission only after the holder's release (#1105)."""
    gateway = ROOT / "packages" / "gateway"
    if not (gateway / "node_modules" / ".bin" / "vitest").exists():
        raise AssertionError("packages/gateway has no node_modules; run its deps (gateway.deps) first")
    fixture = Fixture(root, TRON_HEAVY_SLOTS="1")
    try:
        fixture.start("holder")
        wait_until(lambda: "holder" in fixture.running(), "the holder runs")
        environment = {k: v for k, v in fixture.environment.items() if k not in ("CI", "GITHUB_ACTIONS")}
        output = (root / "vitest.out").open("w")
        vitest = subprocess.Popen([str(ROOT / "scripts/tron-node"), "exec", "npx", "vitest", "run",
                                   "src/admin/hook-resources.integration.test.ts", "-t", "no test has this name",
                                   "--passWithNoTests"], cwd=gateway, env=environment, stdout=output, stderr=subprocess.STDOUT)
        wait_until(lambda: "vitest in " in (root / "vitest.out").read_text() and "waiting" in (root / "vitest.out").read_text()
                   or "queued" in (root / "vitest.out").read_text(), "vitest waits in the heavy queue", 60)
        time.sleep(1)
        assert vitest.poll() is None, "vitest must not run while the only slot is held"
        fixture.release("holder")
        assert vitest.wait(timeout=120) == 0, (root / "vitest.out").read_text()
        rows = [json.loads(line) for line in (root / "queue" / "events.jsonl").read_text().splitlines()]
        sequence = [(row["event"], row["owner"].split(" in ")[0]) for row in rows]
        assert sequence == [("acquire", "holder"), ("release", "holder"), ("acquire", "vitest"),
                            ("release", "vitest")], sequence
        vitest_acquire = rows[2]
        assert vitest_acquire["kind"] == "direct" and vitest_acquire["queuedSeconds"] >= 1, vitest_acquire
        assert all(row["heldSeconds"] >= 0 for row in rows if row["event"] == "release"), rows
        assert not any(item for item in (root / "queue").glob("slot-*.lock") if item.read_text().strip()), "slots freed"
        return {"ledger": rows}
    finally:
        fixture.close()


def main() -> int:
    cases = [case_direct_vitest_waits_and_ledger_records_it, case_memory_admission, case_cpu_admission, case_aged_head_drains_backfill, case_pools_xcode_counts_booted_simulators, case_gate_jobs_fair_and_bounded,
             case_dead_holder_slot_reclaimed, case_queue_wait_is_not_step_time, case_slots_fifo_and_positions,
             case_holder_killed_slot_follows_command_tree, case_dead_waiter_leaves_queue, case_inherited_slot_never_waits]
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
