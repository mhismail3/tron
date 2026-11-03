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

ROOT = Path(__file__).resolve().parents[2]
# The host's one full-Gateway run at a time, shared with `verify --batch`. A run waits for it
# instead of overlapping a batch; batch lanes already hold it and say so in their environment.
FULL_GATEWAY_LOCK = '/tmp/tron-full-gateway.lock'
HELD_BY_CALLER = 'TRON_FULL_GATEWAY_LOCK_HELD'


def hold_full_gateway_lock():
    """The open, exclusively locked lock file, after waiting for any other holder; None when the caller holds it."""
    if os.environ.get(HELD_BY_CALLER) == '1':
        return None
    handle = open(FULL_GATEWAY_LOCK, 'a+')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.seek(0)
        holder = handle.read(512).strip() or 'unrecorded'
        print(f"gateway tests: waiting for {FULL_GATEWAY_LOCK} (last holder: {holder})", file=sys.stderr, flush=True)
        fcntl.flock(handle, fcntl.LOCK_EX)
    handle.truncate(0)
    handle.write(json.dumps({'pid': os.getpid(), 'worktree': str(ROOT), 'purpose': 'gateway vitest ' + ' '.join(sys.argv[1:])[:200]}))
    handle.flush()
    return handle


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
