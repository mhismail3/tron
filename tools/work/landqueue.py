"""The land queue: one landing at a time merges into the base (README.md#land-queue, #1108).

`work land` takes a ticket in `<git common dir>/work/land/queue/` and waits for its
turn; the turn is an exclusive flock on `head.lock`, so the kernel frees it when the
holder dies. Only the turn holder merges the base into its branch, verifies the merged
tree and squash-merges, so the base cannot move under a verified head and no landing
loops back because of another one. A landing whose branch already passed its plan
against a recent base reruns only what the base's newer changes invalidated (the
gate's content-addressed results).

Order is priority (`high` before `normal`), then arrival. Home or the maintainer
raises a waiting ticket with `work queue --priority BRANCH high`; nobody sequences
landings by hand. A ticket whose process ended is dropped by the next reader.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import sys
import time
from pathlib import Path
from typing import IO, Iterator, List, Optional

import ledger

POLL_SECONDS = 1.0
HEARTBEAT_SECONDS = 30.0
PRIORITIES = ("high", "normal")


def _directory(root: Path) -> Path:
    return ledger.common_dir(root) / "work" / "land" / "queue"


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def tickets(root: Path) -> List[dict]:
    """Live tickets in landing order; tickets of ended processes are removed here."""
    directory = _directory(root)
    live = []
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        try:
            ticket = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not _alive(int(ticket.get("pid", 0))):
            path.unlink(missing_ok=True)
            continue
        live.append({**ticket, "ticket": path.name})
    return sorted(live, key=lambda t: (PRIORITIES.index(t.get("priority", "normal")), t["ticket"]))


def _holder(root: Path) -> Optional[dict]:
    path = _directory(root) / "head.lock"
    if not path.exists():
        return None
    with path.open("a+") as probe:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            with contextlib.suppress(ValueError, OSError):
                return json.loads(path.read_text() or "{}")
            return {}
        fcntl.flock(probe, fcntl.LOCK_UN)
    return None


@contextlib.contextmanager
def turn(root: Path, branch: str, head: str, priority: str = "normal", report: IO[str] = sys.stdout) -> Iterator[float]:
    """Wait for this landing's turn; yields the seconds waited and holds the turn until exit."""
    directory = _directory(root)
    directory.mkdir(parents=True, exist_ok=True)
    session = os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID") or ""
    me = {"branch": branch, "head": head, "pid": os.getpid(), "session": session, "priority": priority,
          "enqueuedAt": ledger.now()}
    ticket = directory / f"{time.time_ns():020d}-{os.getpid()}.json"
    ticket.write_text(json.dumps(me) + "\n")
    started, last, last_print = time.monotonic(), None, 0.0
    handle: Optional[IO[str]] = None
    try:
        while True:
            queued = tickets(root)
            position = next((i + 1 for i, t in enumerate(queued) if t["ticket"] == ticket.name), 1)
            if position == 1:
                handle = (directory / "head.lock").open("a+")
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    handle.close()
                    handle = None
                else:
                    handle.seek(0)
                    handle.truncate()
                    json.dump(me, handle)
                    handle.flush()
                    break
            holder = _holder(root) or {}
            state = (position, holder.get("branch"))
            now = time.monotonic()
            if state != last or now - last_print >= HEARTBEAT_SECONDS:
                print(f"land queue: {branch} waits at position {position} of {len(queued)}"
                      + (f"; landing now: {holder.get('branch')}" if holder.get("branch") else "")
                      + f" ({now - started:.0f}s)", file=report, flush=True)
                last, last_print = state, now
            time.sleep(POLL_SECONDS)
        waited = round(time.monotonic() - started, 1)
        print(f"land queue: {branch} has the turn after {waited:.0f}s", file=report, flush=True)
        yield waited
    finally:
        ticket.unlink(missing_ok=True)
        if handle:
            with contextlib.suppress(OSError, ValueError):
                handle.seek(0)
                handle.truncate()
                fcntl.flock(handle, fcntl.LOCK_UN)
            handle.close()


def counts(root: Path) -> dict:
    """Bounded projection of this repository's live queue; no shadow queue."""
    holder = _holder(root)
    if holder == {}:
        return {"running": None, "waiting": None}  # Held, but its receipt is being published.
    waiting = [ticket for ticket in tickets(root) if holder is None or ticket["pid"] != holder.get("pid")]
    return {"running": int(holder is not None), "waiting": len(waiting)}


def show(root: Path) -> int:
    """`work queue`: the landing now, then each waiting ticket in order."""
    holder = _holder(root)
    print(f"landing now: {holder.get('branch')} ({holder.get('head', '')[:12]}, since {holder.get('enqueuedAt')})"
          if holder else "landing now: none")
    for position, ticket in enumerate((t for t in tickets(root) if not holder or t["pid"] != holder.get("pid")), 1):
        print(f"  #{position} {ticket['branch']} ({ticket.get('priority', 'normal')}) since {ticket['enqueuedAt']}"
              f" session {ticket.get('session') or '-'}")
    return 0


def set_priority(root: Path, branch: str, priority: str) -> int:
    for path in sorted(_directory(root).glob("*.json")):
        with contextlib.suppress(OSError, ValueError):
            ticket = json.loads(path.read_text())
            if ticket.get("branch") == branch:
                ticket["priority"] = priority
                temporary = path.with_suffix(".tmp")
                temporary.write_text(json.dumps(ticket) + "\n")
                temporary.replace(path)
                print(f"land queue: {branch} is now {priority}")
                return 0
    print(f"land queue: no waiting ticket for {branch}", file=sys.stderr)
    return 1
