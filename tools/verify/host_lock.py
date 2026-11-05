#!/usr/bin/env python3
"""The host's one full-Gateway run at a time: the lock `scripts/tron test gateway` and `verify --batch` share."""
from pathlib import Path
import fcntl
import json
import os
import time

# A Gateway Vitest run waits its turn for this lock instead of overlapping a batch Gateway lane;
# such a lane holds it and says so in its environment, so the run inside it does not wait again.
FULL_GATEWAY_LOCK = '/tmp/tron-full-gateway.lock'
HELD_BY_CALLER = 'TRON_FULL_GATEWAY_LOCK_HELD'


def wait_for_full_gateway_lock(record, wait_seconds, announce, cancelled=None):
    """The open full-Gateway lock file, exclusively locked once every earlier live waiter has had it.

    Waiters take the lock in arrival order: each queues a numbered ticket beside the lock and
    holds that ticket's flock while it waits, so a waiter that dies (even by SIGKILL) gives up
    its place and the next look at the queue deletes its ticket. Only the earliest live ticket
    tries the lock, whose own flock the kernel likewise drops for a dead holder. The queue
    directory's flock serializes numbering and pruning. Never interrupts the holder; raises
    TimeoutError naming it after `wait_seconds` (None waits indefinitely), and InterruptedError
    once `cancelled()` is true, giving up its place.
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
                if cancelled is not None and cancelled():
                    raise InterruptedError(f'cancelled after {round(waited)}s waiting ({line})')
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
