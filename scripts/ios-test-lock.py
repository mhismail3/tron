#!/usr/bin/env python3
"""Run one command under the exclusive repository-owned iOS test lease."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

LOCKED_EXIT = 73


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.command[:1] == ["--"]:
        arguments.command = arguments.command[1:]
    if not arguments.command:
        parser.error("a command is required after --")

    arguments.lock.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(arguments.lock.parent, 0o700)
    with arguments.lock.open("a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.seek(0)
            owner = handle.read().strip() or "unknown owner"
            print(f"error: iOS test simulator is already leased ({owner})", file=sys.stderr)
            return LOCKED_EXIT

        handle.seek(0)
        handle.truncate()
        json.dump(
            {
                "schema": "tron.ios-test-lock.v1",
                "pid": os.getpid(),
                "started_at_epoch_seconds": int(time.time()),
                "command": arguments.command[1] if len(arguments.command) > 1 else arguments.command[0],
                "lock_path": str(arguments.lock.resolve()),
                "uid": os.getuid(),
            },
            handle,
            sort_keys=True,
        )
        handle.write("\n")
        handle.flush()
        environment = os.environ.copy()
        environment["TRON_IOS_TEST_LOCK_HELD"] = "1"
        process = subprocess.Popen(arguments.command, env=environment)
        interrupted: int | None = None

        def forward(signum: int, _frame: object) -> None:
            nonlocal interrupted
            interrupted = signum
            if process.poll() is None:
                try:
                    process.send_signal(signum)
                except ProcessLookupError:
                    pass

        previous = {
            signum: signal.signal(signum, forward)
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        }
        try:
            return_code = process.wait()
            return 128 + interrupted if interrupted is not None else return_code
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
            handle.seek(0)
            handle.truncate()


if __name__ == "__main__":
    raise SystemExit(main())
