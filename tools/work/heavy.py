#!/usr/bin/env python3
"""Host-wide heavy-run queue (#915, packages/gateway/docs/host-load.md).

Heavy local runs (iOS simulator suites, real-Gateway E2E, full suites, `work
verify`/`land`) share this Mac with the Stable Gateway. Each one runs under one
of TRON_HEAVY_SLOTS host-wide slots. A slot is a flock, so the kernel drops it
when the last process holding its descriptor ends: the holder passes the
descriptor to the command it runs, so a killed holder never leaves a stale slot
while its command tree still runs, and a finished tree never leaves one behind.

A run that cannot take a slot waits in a FIFO queue of tickets (enqueue time,
owner, PID, worktree, command) and prints its position whenever it changes.
Only the queue head may take a slot, and the head also waits while the 1-minute
load average exceeds TRON_HEAVY_MAX_LOAD, for at most
TRON_HEAVY_PRESSURE_MAX_WAIT_SECONDS on pressure alone, so a host busy for
reasons outside Tron still makes progress one run at a time. A ticket whose PID
has ended is removed by the next reader.

A command that inherits a slot (TRON_HEAVY_LEASE_HELD) takes none of its own, so
`work land` running an iOS journey does not wait on itself.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import IO, Iterator, List, Optional

HELD_ENV = "TRON_HEAVY_LEASE_HELD"
# Memory, not a slot count, is what limits this Mac (#1023): the slot count is
# only an upper bound on concurrent heavy steps, and each admission also needs
# its expected peak RSS (from the gate catalog's measurements) to fit.
DEFAULT_SLOTS = 4
DEFAULT_NEED_MB = 3000
POLL_SECONDS = 1.0


def _directory() -> Path:
    # Host-wide for this user, independent of HOME and TMPDIR, which agents isolate per run.
    return Path(os.environ.get("TRON_HEAVY_DIR") or f"/tmp/tron-heavy-runs-{os.getuid()}")


def _slots() -> int:
    return max(1, int(os.environ.get("TRON_HEAVY_SLOTS") or DEFAULT_SLOTS))


def _max_load() -> float:
    value = os.environ.get("TRON_HEAVY_MAX_LOAD")
    return float(value) if value else 2.0 * (os.cpu_count() or 1)


def _reserve_mb() -> int:
    """Memory kept free for the Stable Gateway, interactive agents and the OS."""
    return int(os.environ.get("TRON_HEAVY_RESERVE_MB") or 6144)


def _budget_mb() -> int:
    """The most expected RSS that admitted heavy steps may claim together."""
    value = os.environ.get("TRON_HEAVY_MEMORY_BUDGET_MB")
    return int(value) if value else int(_total_mb() * 0.45)


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


def _pressure_max_wait() -> float:
    return float(os.environ.get("TRON_HEAVY_PRESSURE_MAX_WAIT_SECONDS") or 1200)


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


def waiters(directory: Path) -> List[dict]:
    """Live tickets in queue order; tickets of ended processes are removed here."""
    queue = directory / "queue"
    result = []
    for path in sorted(queue.glob("*.json")) if queue.is_dir() else []:
        ticket = _read(path)
        if not ticket or not _alive(int(ticket.get("pid", 0))):
            with contextlib.suppress(FileNotFoundError):
                path.unlink()
            continue
        result.append({**ticket, "ticket": path.name})
    return result


def holders(directory: Path) -> List[dict]:
    """Slots currently held, with the metadata their holder wrote."""
    result = []
    for index in range(_slots()):
        path = directory / f"slot-{index}.lock"
        if not path.exists():
            continue
        with path.open("a+") as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                result.append({"slot": index, **(_read(path) or {})})
                continue
            fcntl.flock(probe, fcntl.LOCK_UN)
    return result


class Lease:
    def __init__(self, slot: int, handle: IO[str]):
        self.slot = slot
        self.handle = handle

    @property
    def fd(self) -> int:
        return self.handle.fileno()

    def release(self) -> None:
        with contextlib.suppress(OSError, ValueError):
            self.handle.seek(0)
            self.handle.truncate()
            self.handle.flush()
            fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


def _describe(holding: List[dict]) -> str:
    return ", ".join(f"{item.get('owner', '?')} (pid {item.get('pid', '?')})" for item in holding) or "none"


def memory_state(need_mb: int, holding: List[dict]) -> Optional[str]:
    """Why a step needing `need_mb` cannot start now, or None when memory admits it.

    The first heavy step always starts, so a large step makes progress on a busy host.
    Later ones need their expected RSS to fit both the heavy budget (with what
    running steps claimed) and the memory the host has free beyond the reserve.
    """
    if not holding:
        return None
    claimed = sum(int(item.get("needMb") or DEFAULT_NEED_MB) for item in holding)
    budget = _budget_mb()
    if claimed + need_mb > budget:
        return f"heavy steps claim {claimed} MB of the {budget} MB heavy budget; this one needs {need_mb} MB"
    free = available_mb() - _reserve_mb()
    if free < need_mb:
        return f"host has {max(free, 0)} MB available beyond the {_reserve_mb()} MB reserve; this one needs {need_mb} MB"
    return None


def acquire(owner: str, command: str, report: IO[str] = sys.stderr, need_mb: int = DEFAULT_NEED_MB) -> Optional[Lease]:
    """Wait in the queue for a slot and the memory the step needs. None when this process inherited one."""
    if os.environ.get(HELD_ENV):
        return None
    directory = _directory()
    queue = directory / "queue"
    queue.mkdir(parents=True, exist_ok=True)
    metadata = {"owner": owner, "pid": os.getpid(), "worktree": os.getcwd(), "command": command[:300], "needMb": need_mb,
                "enqueuedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    ticket = queue / f"{time.time_ns():020d}-{os.getpid()}.json"
    ticket.write_text(json.dumps(metadata) + "\n")
    last = None
    pressure_since: Optional[float] = None
    try:
        while True:
            queued = waiters(directory)
            position = next((index + 1 for index, item in enumerate(queued) if item["ticket"] == ticket.name), 1)
            state = None
            if position == 1:
                load = os.getloadavg()[0]
                limit = _max_load()
                now = time.monotonic()
                memory = memory_state(need_mb, holders(directory))
                if memory:
                    state = f"heavy-run: next, waiting for memory: {memory}"
                elif load > limit and (pressure_since is None or now - pressure_since < _pressure_max_wait()):
                    pressure_since = pressure_since or now
                    state = f"heavy-run: next, waiting for host load {load:.1f} to fall to {limit:.1f}"
                else:
                    for index in range(_slots()):
                        handle = (directory / f"slot-{index}.lock").open("a+")
                        try:
                            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            handle.close()
                            continue
                        handle.seek(0)
                        handle.truncate()
                        json.dump({**metadata, "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, handle)
                        handle.flush()
                        os.set_inheritable(handle.fileno(), True)
                        print(f"heavy-run: started in slot {index + 1} of {_slots()} ({owner}, needs {need_mb} MB)",
                              file=report, flush=True)
                        return Lease(index, handle)
            if state is None:
                state = (f"heavy-run: queued at position {position} of {len(queued)}; "
                         f"running: {_describe(holders(directory))}")
            if state != last:
                print(state, file=report, flush=True)
                last = state
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


def run(owner: str, argv: List[str], need_mb: int = DEFAULT_NEED_MB) -> int:
    """Runs `argv` under a slot; its tree holds the slot's descriptor."""
    lease = acquire(owner, " ".join(argv), need_mb=need_mb)
    environment = dict(os.environ)
    if lease:
        environment[HELD_ENV] = str(lease.slot + 1)
    process = subprocess.Popen(argv, env=environment, pass_fds=(lease.fd,) if lease else ())
    forward = lambda received, _frame: process.send_signal(received)  # noqa: E731
    for received in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(received, forward)
    try:
        return process.wait()
    finally:
        if lease:
            lease.release()


def status() -> int:
    directory = _directory()
    holding = holders(directory)
    claimed = sum(int(item.get("needMb") or DEFAULT_NEED_MB) for item in holding)
    print(f"heavy runs: up to {_slots()} at once within a {_budget_mb()} MB heavy budget ({claimed} MB claimed), "
          f"{available_mb()} MB available, {_reserve_mb()} MB reserve; max load {_max_load():.1f} "
          f"(load now {os.getloadavg()[0]:.1f})")
    for item in holding:
        print(f"  running  slot {item['slot'] + 1}: {item.get('owner', '?')} needs {item.get('needMb', '?')} MB pid {item.get('pid', '?')} "
              f"since {item.get('startedAt', '?')} in {item.get('worktree', '?')}")
    for position, item in enumerate(waiters(directory), start=1):
        print(f"  queued   #{position}: {item.get('owner', '?')} pid {item.get('pid', '?')} "
              f"since {item.get('enqueuedAt', '?')} in {item.get('worktree', '?')}")
    return 0


def main(arguments: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="tron-heavy", description="Host-wide heavy-run queue (#915)")
    commands = parser.add_subparsers(dest="action", required=True)
    runner = commands.add_parser("run", help="run one heavy command under a host-wide slot")
    runner.add_argument("--owner", default=os.environ.get("TRON_HEAVY_OWNER") or Path.cwd().name)
    runner.add_argument("--need-mb", type=int, default=DEFAULT_NEED_MB, help="expected peak RSS of the command")
    runner.add_argument("argv", nargs=argparse.REMAINDER)
    commands.add_parser("status", help="print running and queued heavy runs")
    parsed = parser.parse_args(arguments)
    if parsed.action == "status":
        return status()
    argv = parsed.argv[1:] if parsed.argv[:1] == ["--"] else parsed.argv
    if not argv:
        parser.error("run needs a command after --")
    return run(parsed.owner, argv, parsed.need_mb)


if __name__ == "__main__":
    sys.exit(main())
