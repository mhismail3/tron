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
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import IO, Iterator, List, Optional

HELD_ENV = "TRON_HEAVY_LEASE_HELD"
DEFAULT_SLOTS = 2  # Maintainer decision, 2026-10-13 (#915).
POLL_SECONDS = 1.0


def _directory() -> Path:
    # Host-wide for this user, independent of HOME and TMPDIR, which agents isolate per run.
    return Path(os.environ.get("TRON_HEAVY_DIR") or f"/tmp/tron-heavy-runs-{os.getuid()}")


def _slots() -> int:
    return max(1, int(os.environ.get("TRON_HEAVY_SLOTS") or DEFAULT_SLOTS))


def _max_load() -> float:
    value = os.environ.get("TRON_HEAVY_MAX_LOAD")
    return float(value) if value else 2.0 * (os.cpu_count() or 1)


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


def acquire(owner: str, command: str, report: IO[str] = sys.stderr) -> Optional[Lease]:
    """Wait in the queue for a slot. None when this process inherited one."""
    if os.environ.get(HELD_ENV):
        return None
    directory = _directory()
    queue = directory / "queue"
    queue.mkdir(parents=True, exist_ok=True)
    metadata = {"owner": owner, "pid": os.getpid(), "worktree": os.getcwd(), "command": command[:300],
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
                if load > limit and (pressure_since is None or now - pressure_since < _pressure_max_wait()):
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
                        print(f"heavy-run: started in slot {index + 1} of {_slots()} ({owner})", file=report, flush=True)
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


def run(owner: str, argv: List[str]) -> int:
    """Runs `argv` under a slot; its tree holds the slot's descriptor."""
    lease = acquire(owner, " ".join(argv))
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
    print(f"heavy runs: {_slots()} slots, max load {_max_load():.1f} (load now {os.getloadavg()[0]:.1f})")
    for item in holders(directory):
        print(f"  running  slot {item['slot'] + 1}: {item.get('owner', '?')} pid {item.get('pid', '?')} "
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
    runner.add_argument("argv", nargs=argparse.REMAINDER)
    commands.add_parser("status", help="print running and queued heavy runs")
    parsed = parser.parse_args(arguments)
    if parsed.action == "status":
        return status()
    argv = parsed.argv[1:] if parsed.argv[:1] == ["--"] else parsed.argv
    if not argv:
        parser.error("run needs a command after --")
    return run(parsed.owner, argv)


if __name__ == "__main__":
    sys.exit(main())
