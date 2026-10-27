#!/usr/bin/env python3
"""Own the temporary HOME and scratch directory of one Gateway Vitest process."""
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    # Resolve the development toolchain before replacing HOME; resolution must
    # neither depend on the fixture home nor fall back to the signed Gateway.
    node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
    vitest = ROOT / "packages/gateway/node_modules/.bin/vitest"
    if not vitest.is_file():
        raise SystemExit("Gateway Vitest is missing; prepare this worktree's pinned dependencies first")
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


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
