#!/usr/bin/env python3
"""Host-wide heavy-run queue (#915, #1023, #1083; packages/gateway/docs/host-load.md).

Heavy local runs (iOS simulator suites, Xcode builds, real-Gateway E2E, Gateway test
shards) share this Mac with the Stable Gateway and every agent. Each runs under a
host-wide step slot, admitted only when its measured cost fits:

- memory: its expected peak RSS within the heavy memory budget (with what running steps
  claimed) and within what the host has available beyond a reserve;
- CPU: its cores within the heavy CPU budget (core count minus headroom, with what
  running steps claimed), and within the cores the host has idle right now (measured
  from kernel CPU ticks, so booted simulators and unqueued builds count too);
- pools: at most TRON_HEAVY_XCODE_SLOTS steps that run xcodebuild or a simulator at
  once (`xcode`), counting every booted simulator the iOS tooling has not released, and
  at most TRON_HEAVY_SERIAL_SLOTS timing-sensitive real-process suites (`serial`): they
  slow each other through process spawning and file churn, not CPU (#1083);
- gate jobs: at most TRON_HEAVY_JOBS gate runs with heavy work in flight. A gate run
  (Job) takes a job slot at its first heavy step and keeps it until the run ends, so
  admitted runs finish instead of every worker holding half-finished work. A run whose
  only waiting step waits for a full pool lends its place, so idle cores do not wait
  behind runs that cannot use them.

A step that scales (xcodebuild -jobs, vitest workers) declares the fewest cores it can
use; it may start with fewer than its full cores and receives its grant in
TRON_HEAVY_CORES, which its command uses to size its own parallelism.

Every slot is a flock, so the kernel drops it when the last process holding its
descriptor ends: a step slot's descriptor passes to the command it runs (a killed holder
never frees a slot while its command still runs, and a dead tree never leaves one
behind); a job slot is held by the gate runner process.

Waiters hold tickets (enqueue time, owner, PID, worktree, command, needs). Tickets of
jobs that already hold a job slot go first, then FIFO. A ticket may pass earlier tickets
that wait only for a count limit (a job or pool slot), never one that waits for CPU or
memory, so a large step is never starved by smaller ones. Admission decisions serialize
on one lock. A ticket whose PID has ended is removed by the next reader. A waiter prints
its position, what it waits for and the host's current CPU and memory whenever that
changes and every TRON_HEAVY_STATUS_SECONDS. The first heavy step always starts, so a
host busy for reasons outside Tron still makes progress one step at a time.

A command that inherits a slot (TRON_HEAVY_LEASE_HELD) takes none of its own, so a gate
shard running `scripts/tron-ios-test` does not wait on itself.

Every admission and release appends one row to `events.jsonl` in the queue directory
(host-wide, like the queue): holder kind (`gate` shard or `direct` run), owner,
worktree, need, granted cores, pool, seconds queued and seconds held. `gate report`
reads it to tell waits behind real holders from waits behind nothing (#1105).
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import fcntl
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import IO, Callable, Iterator, List, Optional

HELD_ENV = "TRON_HEAVY_LEASE_HELD"
CORES_ENV = "TRON_HEAVY_CORES"
# A command without a measurement claims 4 GB and 4 cores.
DEFAULT_NEED_MB = 4000
DEFAULT_CORES = 4.0
POLL_SECONDS = 1.0
# Job slot files: more than TRON_HEAVY_JOBS, because runs that wait only for a pool
# lend their place in the limit but keep their slot (and their priority).
JOB_FILES = 64
XCODE = "xcode"
SERIAL = "serial"
POOLS = (XCODE, SERIAL)


def _env_number(name: str, default: float) -> float:
    value = os.environ.get(name)
    return float(value) if value else default


def _directory() -> Path:
    # Host-wide for this user, independent of HOME and TMPDIR, which agents isolate per run.
    return Path(os.environ.get("TRON_HEAVY_DIR") or f"/tmp/tron-heavy-runs-{os.getuid()}")


def _cpus() -> int:
    return int(_env_number("TRON_HEAVY_CPUS", os.cpu_count() or 1))


def _slots() -> int:
    """Upper bound on concurrent heavy steps; CPU and memory normally bind first."""
    return max(1, int(_env_number("TRON_HEAVY_SLOTS", 8)))


def _job_slots() -> int:
    """Gate runs with heavy work in flight at once: one per six cores, at least two."""
    return max(1, int(_env_number("TRON_HEAVY_JOBS", max(2, _cpus() // 6))))


def _pool_slots(pool: str) -> int:
    """Steps of one pool that may run at once.

    `serial` suites (gateway.scripts, gateway.nested) passed alone in 158 s but took 336 s
    two at a time and timed out at 420 s four at a time, with the host's CPU half idle
    (#1083), so they run one at a time host-wide.
    """
    if pool == XCODE:
        return max(1, int(_env_number("TRON_HEAVY_XCODE_SLOTS", 2)))
    return max(1, int(_env_number("TRON_HEAVY_SERIAL_SLOTS", 1)))


def _cpu_budget() -> float:
    """Cores admitted heavy steps may claim together: the core count less a sixth (at least two)
    left for the Stable Gateway, interactive agents and light steps."""
    return _env_number("TRON_HEAVY_CPU_BUDGET", _cpus() - max(2, _cpus() // 6))


def _reserve_mb() -> int:
    """Memory kept free for the Stable Gateway, interactive agents and the OS."""
    return int(_env_number("TRON_HEAVY_RESERVE_MB", 6144))


def _budget_mb() -> int:
    """The most expected RSS that admitted heavy steps may claim together."""
    value = os.environ.get("TRON_HEAVY_MEMORY_BUDGET_MB")
    return int(value) if value else int(_total_mb() * 0.45)


def _status_seconds() -> float:
    return _env_number("TRON_HEAVY_STATUS_SECONDS", 15)


def _total_mb() -> int:
    with contextlib.suppress(OSError, ValueError):
        out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout
        return int(out) // (1024 * 1024)
    return 16384


def available_mb() -> int:
    """Memory the kernel can hand out without paging: free, inactive and speculative pages.

    TRON_HEAVY_AVAILABLE_MB overrides it so journeys can observe admission deterministically.
    """
    override = os.environ.get("TRON_HEAVY_AVAILABLE_MB")
    if override:
        return int(override)
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    page = int(re.search(r"page size of (\d+)", out).group(1)) if "page size of" in out else 16384
    pages = 0
    for name in ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"):
        match = re.search(rf"^{name}:\s+(\d+)", out, re.M)
        pages += int(match.group(1)) if match else 0
    return pages * page // (1024 * 1024)


class CpuMeter:
    """Busy cores on the host, from the kernel's cumulative CPU ticks (user, system, nice).

    The 1-minute load average is not CPU use: on this Mac it read 21 with three cores busy
    and 50 with sixteen (#1083), so admission measures the ticks instead. Readings are
    smoothed over a few seconds so one burst does not decide. TRON_HEAVY_BUSY_CORES
    overrides it so journeys can observe admission deterministically.
    """

    def __init__(self) -> None:
        self._last: Optional[List[int]] = None
        self._busy: Optional[float] = None
        self._lib = None
        if sys.platform == "darwin":
            with contextlib.suppress(OSError):
                self._lib = ctypes.CDLL("/usr/lib/libSystem.dylib")
                self._lib.mach_host_self.restype = ctypes.c_uint

    def _ticks(self) -> Optional[List[int]]:
        if not self._lib:
            return None
        info = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)
        # HOST_CPU_LOAD_INFO (3): user, system, idle, nice ticks summed over every core.
        if self._lib.host_statistics(self._lib.mach_host_self(), 3, info, ctypes.byref(count)) != 0:
            return None
        return list(info)

    def busy(self) -> float:
        override = os.environ.get("TRON_HEAVY_BUSY_CORES")
        if override:
            return float(override)
        ticks = self._ticks()
        if ticks is None:
            return min(float(_cpus()), os.getloadavg()[0])
        if self._last is None:
            self._last = ticks
            time.sleep(0.5)
            ticks = self._ticks() or ticks
        delta = [now - before for now, before in zip(ticks, self._last)]
        total = sum(delta)
        if total > 0:
            self._last = ticks
            sample = (delta[0] + delta[1] + delta[3]) / total * _cpus()
            self._busy = sample if self._busy is None else 0.4 * sample + 0.6 * self._busy
        return round(self._busy or 0.0, 1)


_booted_cache: tuple = (0.0, 0)


def booted_simulators() -> int:
    """Booted simulators other than the remembered Development simulator (cached 5 s).

    A lane's simulator stays booted only while its command runs, or until the iOS tooling's
    sweep reclaims an orphan (scripts/ios-test-simulator.py), so each one is Xcode work in
    flight whether or not a heavy holder accounts for it.
    """
    global _booted_cache
    override = os.environ.get("TRON_HEAVY_BOOTED_SIMULATORS")
    if override:
        return int(override)
    if time.monotonic() - _booted_cache[0] < 5:
        return _booted_cache[1]
    count = 0
    with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
        done = subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"], capture_output=True, text=True, timeout=20)
        development = ""
        with contextlib.suppress(OSError):
            state = Path(os.environ.get("TRON_IOS_SIMULATOR_STATE_DIR") or Path.home() / ".tron/internal/run") / "ios-simulator-udid"
            development = state.read_text().strip()
        devices = json.loads(done.stdout or "{}").get("devices", {})
        count = sum(1 for runtime in devices.values() for device in runtime
                    if device.get("state") == "Booted" and device.get("udid") != development)
    _booted_cache = (time.monotonic(), count)
    return count


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _read(path: Path) -> Optional[dict]:
    with contextlib.suppress(OSError, ValueError):
        return json.loads(path.read_text() or "null")
    return None


def _locked(path: Path) -> Optional[dict]:
    """The metadata of a held flock slot, or None when no live process holds it."""
    if not path.exists():
        return None
    with path.open("a+") as probe:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return _read(path) or {}
        fcntl.flock(probe, fcntl.LOCK_UN)
    return None


def holders(directory: Path) -> List[dict]:
    """Step slots currently held, with the metadata their holder wrote."""
    result = []
    for index in range(_slots()):
        metadata = _locked(directory / f"slot-{index}.lock")
        if metadata is not None:
            result.append({"slot": index, **metadata})
    return result


def jobs(directory: Path) -> List[dict]:
    """Job slots currently held by gate runs (or standalone heavy runs)."""
    result = []
    for index in range(JOB_FILES):
        metadata = _locked(directory / f"job-{index}.lock")
        if metadata is not None:
            result.append({"jobSlot": index, **metadata})
    return result


def waiters(directory: Path, active: Optional[set] = None) -> List[dict]:
    """Live tickets in admission order; tickets of ended processes are removed here.

    Tickets of jobs that already hold a job slot come first: a running gate's next step
    must never wait behind a run that waits for that gate's job slot.
    """
    queue = directory / "queue"
    if active is None:
        active = {item.get("job") for item in jobs(directory)}
    result = []
    for path in sorted(queue.glob("*.json")) if queue.is_dir() else []:
        ticket = _read(path)
        if not ticket or not _alive(int(ticket.get("pid", 0))):
            with contextlib.suppress(FileNotFoundError):
                path.unlink()
            continue
        result.append({**ticket, "ticket": path.name})
    return sorted(result, key=lambda item: (0 if item.get("job") in active else 1, item["ticket"]))


class Cancelled(Exception):
    """The waiter's owner gave up before it was admitted."""


class Job:
    """One gate run's claim on a job slot: taken with its first heavy step, held until `release`."""

    def __init__(self, owner: str):
        self.id = f"{os.getpid()}-{time.time_ns()}"
        self.owner = owner
        self.handle: Optional[IO[str]] = None
        self.slot: Optional[int] = None

    @property
    def held(self) -> bool:
        return self.handle is not None

    def release(self) -> None:
        if self.handle:
            with contextlib.suppress(OSError, ValueError):
                self.handle.seek(0)
                self.handle.truncate()
                self.handle.flush()
                fcntl.flock(self.handle, fcntl.LOCK_UN)
            self.handle.close()
            self.handle = None


def _event(row: dict) -> None:
    """One heavy ledger row; the ledger observes admission and never blocks it."""
    with contextlib.suppress(OSError):
        path = _directory() / "events.jsonl"
        with path.open("a") as stream:
            stream.write(json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **row}, sort_keys=True) + "\n")


class Lease:
    def __init__(self, slot: int, handle: IO[str], cores: float, job: Optional[Job] = None,
                 metadata: Optional[dict] = None):
        self.slot = slot
        self.handle = handle
        self.cores = cores
        self._own_job = job
        self.metadata = metadata or {}
        self.started = time.monotonic()

    @property
    def fd(self) -> int:
        return self.handle.fileno()

    def environment(self) -> dict:
        """What the command tree inherits: the slot (so nested runs take none) and its cores."""
        return {HELD_ENV: str(self.slot + 1), CORES_ENV: str(max(1, int(self.cores)))}

    def release(self) -> None:
        if self.handle.closed:
            return
        with contextlib.suppress(OSError, ValueError):
            self.handle.seek(0)
            self.handle.truncate()
            self.handle.flush()
            fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()
        _event({**self.metadata, "event": "release", "heldSeconds": round(time.monotonic() - self.started, 1)})
        if self._own_job:
            self._own_job.release()


@dataclass
class Host:
    """What admission reads: the queue's holders and the host's live CPU and memory."""
    holding: List[dict]
    active_jobs: set
    busy: float
    available: int
    booted: Callable[[], int]
    queued: List[dict] = field(default_factory=list)

    @property
    def claimed_mb(self) -> int:
        return sum(int(item.get("needMb") or DEFAULT_NEED_MB) for item in self.holding)

    @property
    def claimed_cores(self) -> float:
        return sum(float(item.get("cores") or DEFAULT_CORES) for item in self.holding)

    def held(self, pool: str) -> int:
        return sum(1 for item in self.holding if item.get("pool") == pool)

    def in_use(self, pool: str) -> int:
        return max(self.held(pool), self.booted()) if pool == XCODE else self.held(pool)

    def pool_full(self, pool: Optional[str]) -> bool:
        # Like the first heavy step, the first xcode step always starts: simulators booted outside
        # the queue (or orphans the iOS tooling has yet to sweep) limit concurrency, never progress.
        return pool in POOLS and bool(self.held(pool)) and self.in_use(pool) >= _pool_slots(pool)

    def lending_jobs(self) -> set:
        """Active runs with no step running whose every waiting step waits for a full pool."""
        running = {item.get("job") for item in self.holding}
        lending = set()
        for job in self.active_jobs - running:
            tickets = [item for item in self.queued if item.get("job") == job]
            if tickets and all(self.pool_full(item.get("pool")) for item in tickets):
                lending.add(job)
        return lending

    def summary(self) -> str:
        return (f"host cpu {self.busy:.1f}/{_cpus()} cores busy (load {os.getloadavg()[0]:.1f}), "
                f"{self.available} MB memory available; heavy claims {self.claimed_cores:g}/{_cpu_budget():g} cores, "
                f"{self.claimed_mb}/{_budget_mb()} MB")


def blocked(ticket: dict, host: Host) -> tuple:
    """(kind, why) a ticket cannot start now, kind "count" or "resource"; ("", grant) when it can.

    The first heavy step always starts. Later ones need their memory and at least their
    minimum cores to fit the heavy budgets and what the host has free right now.
    """
    need_mb = int(ticket.get("needMb") or DEFAULT_NEED_MB)
    cores = float(ticket.get("cores") or DEFAULT_CORES)
    minimum = float(ticket.get("coresMin") or cores)
    if ticket.get("job") not in host.active_jobs:
        lending = host.lending_jobs()
        if len(host.active_jobs) - len(lending) >= _job_slots():
            return "count", (f"a gate job slot ({len(host.active_jobs) - len(lending)} of {_job_slots()} gate jobs have "
                             f"heavy work in flight" + (f"; {len(lending)} more wait only for a pool" if lending else "") + ")")
    pool = ticket.get("pool")
    if host.pool_full(pool):
        if pool == XCODE:
            return "count", (f"an Xcode slot ({host.in_use(pool)} of {_pool_slots(pool)} in use: {host.held(pool)} xcode steps, "
                             f"{host.booted()} booted simulators)")
        return "count", f"a {pool} slot ({host.held(pool)} of {_pool_slots(pool)} running)"
    if not host.holding:
        return "", min(cores, float(_cpus()))
    if len(host.holding) >= _slots():
        return "resource", f"a step slot (all {_slots()} running)"
    if host.claimed_mb + need_mb > _budget_mb():
        return "resource", f"memory: heavy steps claim {host.claimed_mb} MB of the {_budget_mb()} MB heavy budget; this one needs {need_mb} MB"
    free = host.available - _reserve_mb()
    if free < need_mb:
        return "resource", f"memory: host has {max(free, 0)} MB available beyond the {_reserve_mb()} MB reserve; this one needs {need_mb} MB"
    grant = min(cores, _cpu_budget() - host.claimed_cores)
    if grant < minimum:
        return "resource", (f"cpu: heavy steps claim {host.claimed_cores:g} of the {_cpu_budget():g}-core heavy budget; "
                            f"this one needs {minimum:g}" + (f"-{cores:g}" if cores > minimum else "") + " cores")
    idle = _cpus() - host.busy
    grant = min(grant, max(idle, 0.0))
    if grant < minimum:
        return "resource", f"cpu: host has {max(idle, 0):.1f} of {_cpus()} cores idle; this one needs {minimum:g} cores"
    return "", grant


def decide(queued: List[dict], host: Host) -> tuple:
    """Which ticket starts now and with how many cores: (ticket name or None, grant, {ticket: why})."""
    reasons = {}
    host.queued = queued
    for ticket in queued:
        kind, detail = blocked(ticket, host)
        if not kind:
            return ticket["ticket"], detail, reasons
        reasons[ticket["ticket"]] = detail
        if kind == "resource":
            break
    return None, 0.0, reasons


def _describe(holding: List[dict]) -> str:
    return ", ".join(f"{item.get('owner', '?')} (pid {item.get('pid', '?')}, {item.get('cores', '?')} cores)"
                     for item in holding) or "none"


def _take(directory: Path, prefix: str, count: int, metadata: dict) -> Optional[tuple]:
    for index in range(count):
        handle = (directory / f"{prefix}-{index}.lock").open("a+")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            continue
        handle.seek(0)
        handle.truncate()
        json.dump({**metadata, "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, handle)
        handle.flush()
        return index, handle
    return None


def acquire(owner: str, command: str, report: IO[str] = sys.stderr, need_mb: int = DEFAULT_NEED_MB,
            cancelled=lambda: False, cores: float = DEFAULT_CORES, cores_min: Optional[float] = None,
            pool: Optional[str] = None, job: Optional[Job] = None) -> Optional[Lease]:
    """Wait in the queue until the step fits; None when this process inherited a slot.

    Without a `job`, the step is its own job: it takes a job slot with its step slot and
    frees both together.
    """
    if os.environ.get(HELD_ENV):
        return None
    directory = _directory()
    queue = directory / "queue"
    queue.mkdir(parents=True, exist_ok=True)
    own_job = None
    if job is None:
        job = own_job = Job(owner)
    metadata = {"owner": owner, "pid": os.getpid(), "worktree": os.getcwd(), "command": command[:300], "needMb": need_mb,
                "cores": cores, "coresMin": cores_min or cores, "pool": pool, "job": job.id,
                "enqueuedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    ticket = queue / f"{time.time_ns():020d}-{os.getpid()}-{threading.get_ident() % 100000}.json"
    ticket.write_text(json.dumps(metadata) + "\n")
    enqueued = time.monotonic()
    meter = CpuMeter()
    last_state, last_print = None, 0.0
    try:
        while True:
            with (directory / "admit.lock").open("a+") as admit:
                fcntl.flock(admit, fcntl.LOCK_EX)
                held_jobs = jobs(directory)
                host = Host(holders(directory), {item.get("job") for item in held_jobs}, meter.busy(), available_mb(),
                            booted_simulators)
                queued = waiters(directory, host.active_jobs)
                chosen, grant, reasons = decide(queued, host)
                if chosen == ticket.name:
                    if job.held or (job_slot := _take(directory, "job", JOB_FILES, {"owner": job.owner, "pid": os.getpid(),
                                                                                       "worktree": os.getcwd(), "job": job.id})):
                        if not job.held:
                            job.slot, job.handle = job_slot
                        taken = _take(directory, "slot", _slots(), {**metadata, "cores": round(grant, 1)})
                        if taken:
                            index, handle = taken
                            os.set_inheritable(handle.fileno(), True)
                            print(f"heavy-run: started in slot {index + 1} of {_slots()} ({owner}, {grant:g} cores, "
                                  f"{need_mb} MB; {host.summary()})", file=report, flush=True)
                            row = {"kind": "gate" if owner.startswith("gate ") else "direct", "owner": owner[:200],
                                   "pid": os.getpid(), "worktree": os.getcwd(), "needMb": need_mb, "cores": round(grant, 1),
                                   "pool": pool, "job": job.id, "slot": index}
                            _event({**row, "event": "acquire", "queuedSeconds": round(time.monotonic() - enqueued, 1),
                                     "busyCores": round(host.busy, 1)})
                            return Lease(index, handle, grant, own_job, row)
                        if own_job:
                            own_job.release()
            position = next((index + 1 for index, item in enumerate(queued) if item["ticket"] == ticket.name), 1)
            why = reasons.get(ticket.name)
            if why:
                state = f"waiting at position {position} of {len(queued)} for {why}"
            else:
                head = next((reasons[item["ticket"]] for item in queued if item["ticket"] in reasons), "the queue ahead")
                state = f"queued at position {position} of {len(queued)}; ahead waits for {head}"
            now = time.monotonic()
            # Live numbers change every poll: print on a new position or reason, and as a heartbeat.
            key = (position, len(queued), why.split(":")[0] if why else None)
            if key != last_state or now - last_print >= _status_seconds():
                print(f"heavy-run: {owner}: {state}; {host.summary()}; running: {_describe(host.holding)}",
                      file=report, flush=True)
                last_state, last_print = key, now
            if cancelled():
                raise Cancelled()
            time.sleep(POLL_SECONDS)
    finally:
        with contextlib.suppress(FileNotFoundError):
            ticket.unlink()


@contextlib.contextmanager
def leased(owner: str, command: str) -> Iterator[Optional[Lease]]:
    lease = acquire(owner, command)
    try:
        yield lease
    finally:
        if lease:
            lease.release()


def worker_worktree_error(root: Path, command: str) -> Optional[str]:
    """Worker admission, not source validation: maintainers and hosted CI keep their gates."""
    if not (os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID")) or os.environ.get("GITHUB_ACTIONS") == "true":
        return None
    done = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--show-toplevel"],
                          cwd=root, capture_output=True, text=True)
    if done.returncode:
        return None  # The host-wide queue also serves non-repository commands.
    git_dir, common, top = done.stdout.strip().splitlines()
    config_path = Path(top) / ".github/work.json"
    if Path(git_dir).resolve() != Path(common).resolve() or not config_path.is_file():
        return None
    config = json.loads(config_path.read_text())
    tasks = (Path(top) / config["claim"]["worktreeRoot"]).resolve()
    return (f"{command}: worker execution from primary checkout {top} is refused before resource allocation; "
            f"use your claimed linked task worktree under {tasks}. "
            "scripts/tron work start <issue> prints its exact path; do not unset the worker identity to bypass admission.")


def run(owner: str, argv: List[str], need_mb: int = DEFAULT_NEED_MB, cores: float = DEFAULT_CORES,
        cores_min: Optional[float] = None, pool: Optional[str] = None) -> int:
    """Runs `argv` under a slot; its tree holds the slot's descriptor."""
    refusal = worker_worktree_error(Path.cwd(), "tron-heavy run")
    if refusal:
        print(refusal, file=sys.stderr)
        return 78
    lease = acquire(owner, " ".join(argv), need_mb=need_mb, cores=cores, cores_min=cores_min, pool=pool)
    environment = dict(os.environ)
    if lease:
        environment.update(lease.environment())
    process = subprocess.Popen(argv, env=environment, pass_fds=(lease.fd,) if lease else ())
    forward = lambda received, _frame: process.send_signal(received)  # noqa: E731
    for received in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(received, forward)
    try:
        return process.wait()
    finally:
        if lease:
            lease.release()


def counts() -> dict:
    """Read current lease/ticket owners without launching host probes or keeping a cache."""
    directory = _directory()
    active = jobs(directory)
    return {"running": len(holders(directory)),
            "waiting": len(waiters(directory, {item.get("job") for item in active})), "gateJobs": len(active)}


def status() -> int:
    directory = _directory()
    held_jobs = jobs(directory)
    host = Host(holders(directory), {item.get("job") for item in held_jobs}, CpuMeter().busy(), available_mb(),
                booted_simulators)
    print(f"heavy runs: {host.summary()}; {_reserve_mb()} MB reserve; up to {_slots()} steps, {_job_slots()} gate jobs, "
          f"{_pool_slots(XCODE)} Xcode steps ({host.in_use(XCODE)} in use, {host.booted()} booted simulators), "
          f"{_pool_slots(SERIAL)} serial ({host.in_use(SERIAL)} running)")
    for item in held_jobs:
        print(f"  job      slot {item['jobSlot'] + 1}: {item.get('owner', '?')} pid {item.get('pid', '?')} "
              f"since {item.get('startedAt', '?')}")
    for item in host.holding:
        print(f"  running  slot {item['slot'] + 1}: {item.get('owner', '?')} {float(item.get('cores') or 0):g} cores "
              f"{item.get('needMb', '?')} MB{' ' + item['pool'] if item.get('pool') else ''} pid {item.get('pid', '?')} "
              f"since {item.get('startedAt', '?')} in {item.get('worktree', '?')}")
    queued = waiters(directory, host.active_jobs)
    _, _, reasons = decide(queued, host)
    for position, item in enumerate(queued, start=1):
        why = f"for {reasons[item['ticket']]}" if item["ticket"] in reasons else "behind the queue ahead"
        print(f"  queued   #{position}: {item.get('owner', '?')} needs {float(item.get('cores') or 0):g} cores "
              f"{item.get('needMb', '?')} MB pid {item.get('pid', '?')} since {item.get('enqueuedAt', '?')}; waits {why}")
    return 0


def main(arguments: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="tron-heavy", description="Host-wide heavy-run queue (#915)")
    commands = parser.add_subparsers(dest="action", required=True)
    runner = commands.add_parser("run", help="run one heavy command under a host-wide slot")
    runner.add_argument("--owner", default=os.environ.get("TRON_HEAVY_OWNER") or Path.cwd().name)
    runner.add_argument("--need-mb", type=int, default=DEFAULT_NEED_MB, help="expected peak RSS of the command")
    runner.add_argument("--cores", type=float, default=DEFAULT_CORES, help="cores the command uses at full parallelism")
    runner.add_argument("--cores-min", type=float, help="fewest cores it can start with (it reads TRON_HEAVY_CORES)")
    runner.add_argument("--pool", choices=POOLS, help="xcode: runs xcodebuild or a simulator; serial: a timing-sensitive suite")
    runner.add_argument("argv", nargs=argparse.REMAINDER)
    commands.add_parser("status", help="print running and queued heavy runs")
    parsed = parser.parse_args(arguments)
    if parsed.action == "status":
        return status()
    argv = parsed.argv[1:] if parsed.argv[:1] == ["--"] else parsed.argv
    if not argv:
        parser.error("run needs a command after --")
    return run(parsed.owner, argv, parsed.need_mb, parsed.cores, parsed.cores_min, parsed.pool)


if __name__ == "__main__":
    sys.exit(main())
