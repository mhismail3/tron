#!/usr/bin/env python3
"""Resolve origin/main, or run an iOS install/share from a disposable main worktree.

This selects build source, not check results. Never mutates a worker's checkout.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("command", nargs=argparse.REMAINDER, help="-- scripts/tron-ios-device install|share ...")
    args = parser.parse_args()
    root = args.root.resolve()
    git(root, "fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main")
    revision = git(root, "rev-parse", "origin/main")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        print(revision)
        return 0
    if command[0] != "scripts/tron-ios-device" or len(command) < 2 or command[1] not in ("install", "share"):
        parser.error("only scripts/tron-ios-device install or share is supported")
    # A unique worktree keeps concurrent builds independent; the device helper
    # still refuses simultaneous use of the *same* physical device.
    with tempfile.TemporaryDirectory(prefix="tron-main-source-") as directory:
        worktree = Path(directory) / "source"
        git(root, "worktree", "add", "--detach", str(worktree), revision)
        try:
            env = {**os.environ, "TRON_MAIN_SOURCE_ROOT": str(worktree)}
            child = subprocess.Popen([str(worktree / command[0]), *command[1:]], cwd=worktree, env=env,
                                     start_new_session=True)
            def stop(signum, _frame):
                try:
                    os.killpg(child.pid, signum)
                except ProcessLookupError:
                    pass
            previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
            try:
                status = child.wait()
                return 128 - status if status < 0 else status
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
        finally:
            # This invocation owns this entire disposable checkout, including
            # generated Xcode/build output. No user's checkout is ever removed.
            git(root, "worktree", "remove", "--force", str(worktree))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        sys.exit(error.returncode)
