#!/usr/bin/env python3
"""Own the temporary HOME and scratch directory of one Gateway Vitest process."""
from pathlib import Path
import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
# The host's one full-Gateway run at a time, shared with `verify --batch`. A run waits its turn
# for it instead of overlapping a batch; batch lanes already hold it and say so in their environment.
FULL_GATEWAY_LOCK = '/tmp/tron-full-gateway.lock'
HELD_BY_CALLER = 'TRON_FULL_GATEWAY_LOCK_HELD'


# tools/verify/batch.py carries this same function (its test fixture replaces this file);
# scripts/test-tron-verify-batch.py keeps the two identical.
def wait_for_full_gateway_lock(record, wait_seconds, announce):
    """The open full-Gateway lock file, exclusively locked once every earlier live waiter has had it.

    Waiters take the lock in arrival order: each queues a numbered ticket beside the lock and
    holds that ticket's flock while it waits, so a waiter that dies (even by SIGKILL) gives up
    its place and the next look at the queue deletes its ticket. Only the earliest live ticket
    tries the lock, whose own flock the kernel likewise drops for a dead holder. The queue
    directory's flock serializes numbering and pruning. Never interrupts the holder; raises
    TimeoutError naming it after `wait_seconds` (None waits indefinitely).
    """
    queue = Path(FULL_GATEWAY_LOCK + '.queue')
    queue.mkdir(exist_ok=True)

    def guarded(action):
        guard = os.open(queue, os.O_RDONLY)
        try:
            fcntl.flock(guard, fcntl.LOCK_EX)
            return action()
        finally:
            os.close(guard)

    def live():
        tickets = []
        for path in sorted(queue.glob('*.ticket')):
            with path.open() as probe:
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    tickets.append(path)
                    continue
            path.unlink()
        return tickets

    def enqueue():
        tickets = live()
        ticket = (queue / f'{int(tickets[-1].stem) + 1 if tickets else 0:012d}.ticket').open('x')
        fcntl.flock(ticket, fcntl.LOCK_EX)
        ticket.write(json.dumps(record))
        ticket.flush()
        return ticket

    ticket = guarded(enqueue)
    mine = Path(ticket.name)
    handle = open(FULL_GATEWAY_LOCK, 'a+')
    started = time.monotonic()
    announced = False
    try:
        try:
            while True:
                earlier = guarded(lambda: [path.read_text() for path in live() if path < mine])
                if not earlier:
                    try:
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        pass
                handle.seek(0)
                line = f"holder: {handle.read(512).strip() or 'unrecorded'}; earlier waiters: [{', '.join(earlier)}]"
                waited = time.monotonic() - started
                if wait_seconds is not None and waited >= wait_seconds:
                    raise TimeoutError(f'{line}; waited {round(waited)}s')
                if not announced:
                    announce(f'waiting for {FULL_GATEWAY_LOCK} ({line})')
                    announced = True
                time.sleep(0.2)
        finally:
            try:
                guarded(mine.unlink)
            finally:
                ticket.close()
        handle.truncate(0)
        handle.write(json.dumps(record))
        handle.flush()
    except BaseException:
        handle.close()
        raise
    return handle


def hold_full_gateway_lock():
    """The open, exclusively locked lock file, after waiting its turn behind any holder and earlier waiters; None when the caller holds it."""
    if os.environ.get(HELD_BY_CALLER) == '1':
        return None
    record = {'pid': os.getpid(), 'worktree': str(ROOT), 'purpose': 'gateway vitest ' + ' '.join(sys.argv[1:])[:200]}
    return wait_for_full_gateway_lock(record, None, lambda line: print(f'gateway tests: {line}', file=sys.stderr, flush=True))


def main() -> int:
    # Resolve the development toolchain before replacing HOME; resolution must
    # neither depend on the fixture home nor fall back to the signed Gateway.
    node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
    vitest = ROOT / "packages/gateway/node_modules/.bin/vitest"
    if not vitest.is_file():
        raise SystemExit("Gateway Vitest is missing; prepare this worktree's pinned dependencies first")
    lock = hold_full_gateway_lock()
    with tempfile.TemporaryDirectory(prefix="tron-gateway-tests-") as temporary:
        root = Path(temporary)
        home, scratch = root / "home", root / "tmp"
        home.mkdir(); scratch.mkdir()
        environment = {**os.environ, "HOME": str(home), "TMPDIR": str(scratch), "TRON_NODE_BIN": node}
        # The existing Tron-home preflight remains authoritative for inherited
        # selectors/resource paths. Do not clear selectors or add an override
        # that would bypass its refusal; clean defaults now derive from HOME.
        with subprocess.Popen([str(ROOT / "scripts/tron-node"), "exec", str(vitest), "run", *sys.argv[1:]],
                              cwd=ROOT / "packages/gateway", env=environment) as child:
            # Keep the environment alive until Vitest has joined its own work.
            # No second timeout or descendant controller: the caller owns the
            # step group, while this launcher forwards direct signals and waits.
            def forward(signum, _frame):
                if child.poll() is None:
                    child.send_signal(signum)
            previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT)}
            try:
                return child.wait()
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
                if lock:
                    lock.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
