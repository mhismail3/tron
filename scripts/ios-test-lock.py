#!/usr/bin/env python3
"""Run one command under an exclusive, host-wide iOS lease.

Every exclusive iOS resource on this Mac is leased here: each test lane's
simulator (scripts/tron-ios-test, the profiler, the Gateway E2E harness), the
remembered Development simulator (scripts/tron-ios-simulator) and each physical
device (scripts/tron-ios-device). The lease is taken without waiting; a
contended one exits 73 naming its holder (with --worktree, its worktree), PID
and start time. The lease is a flock, so the kernel drops it when the holder and
the command tree it started have ended: a killed holder leaves no stale lease,
only stale metadata the next holder overwrites.

With --marker, the holder owns the lane's simulator for the whole command: it
records the intent that will keep or release the simulator in the lease
metadata, and when the command ends - after success, failure, timeout or a
signal - it releases the simulator unless the lease was taken with --keep-booted. A release that
fails is reported; it never replaces the command's own exit status.

The command runs in its own process group, and the holder passes it the lease's
own descriptor, so the lease and the simulator live exactly as long as the
command tree: a signal reaches the whole tree, the release waits for it to end,
and a holder killed outright leaves an orphan the sweep cannot mistake for an
idle lane.

A command that inherits a lease (`TRON_IOS_TEST_LOCK_HELD`) takes none of its
own, so it proves with --verify-inherited that the inherited lease is the one
of the lane it names before it touches that lane; every lane tool - the runner,
the profiler and the Gateway E2E harness - refuses here, with one exit status
and one message, rather than run on a lane it does not hold (T-3).

With --remove-empty-lane (`clean`), the holder removes the lane's directory
when the command ends, if the lease file is all it still holds: only the holder
can, because it holds the lease until the command tree has ended. Since a
holder (or the sweep reclaiming an abandoned lane) can unlink the lease file and
remove its directory, a lease counts as taken only when the file locked is
still the one --lock names; otherwise - and when the directory goes before the
lease file is opened - the take fails as contended.
"""

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
from typing import IO

LOCKED_EXIT = 73
# The runner's own failure status: a command refused for the lease it inherited
# fails as the runner does, whichever lane tool it is.
INHERITED_LEASE_EXIT = 74
# Reading the lane's state and releasing it are bounded, so a wedged simulator
# can never keep the holder - and the lease - alive.
SIMULATOR_TIMEOUT_SECONDS = 120.0
# A signalled command must end before the holder releases the simulator. The
# owner below the shell bounds and kills its own xcodebuild session, so waiting
# for the whole process group covers everything the command started; the bound
# keeps a wedged tree from holding the simulator - and the lease - forever.
COMMAND_TREE_GRACE_SECONDS = 30.0
SIMULATOR = Path(__file__).resolve().parent / "ios-test-simulator.py"


def write_metadata(handle: IO[str], metadata: dict[str, object]) -> None:
    handle.seek(0)
    handle.truncate()
    json.dump(metadata, handle, sort_keys=True)
    handle.write("\n")
    handle.flush()


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def describe_holder(text: str) -> str:
    """Who holds a contended lease, from the metadata its holder wrote."""
    try:
        metadata = json.loads(text)
    except ValueError:
        return text or "unknown owner"
    if not isinstance(metadata, dict):
        return text
    parts: list[str] = []
    worktree = metadata.get("worktree")
    if isinstance(worktree, str):
        parts.append(f"worktree {worktree}")
    pid = metadata.get("pid")
    if isinstance(pid, int):
        # A holder killed outright leaves its command tree holding the lease
        # (it inherits the descriptor); say so rather than name a dead PID alone.
        parts.append(f"PID {pid}" if process_exists(pid) else f"PID {pid}, which has exited while the command it started still runs")
    started = metadata.get("started_at_epoch_seconds")
    if isinstance(started, int):
        parts.append("started " + time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(started)))
    command = metadata.get("command")
    if isinstance(command, str):
        parts.append(f"command {command}")
    return ", ".join(parts) or text


def process_group_exists(process_group: int) -> bool:
    """Whether any process is still in this command's process group."""
    try:
        os.killpg(process_group, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def wait_for_command_tree(process_group: int, grace_seconds: float = COMMAND_TREE_GRACE_SECONDS) -> bool:
    """Wait for a signalled command's whole process group to end, bounded.

    The shell the holder starts dies at once on a signal, while the process
    owner below it - which bounds and kills the xcodebuild it runs in its own
    session - needs a moment to stop the test. Releasing the simulator before
    that moment would shut it down under a live test, so the release waits here.
    """
    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if not process_group_exists(process_group):
            return True
        time.sleep(0.05)
    return not process_group_exists(process_group)


def simulator_booted(marker: Path, development_state: Path) -> bool | None:
    """Whether the lane's simulator was already booted when this lease began.

    True means the lease found it booted under an earlier lease (a keep-booted
    lane), so this command did not boot it. None means the state could not be
    read; the lease is still taken.
    """
    command = [
        sys.executable, str(SIMULATOR), "state",
        "--marker", str(marker), "--development-state", str(development_state),
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=SIMULATOR_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    state = completed.stdout.strip()
    if state == "Booted":
        return True
    if state in ("Shutdown", "missing", "not-provisioned"):
        return False
    return None


def release_simulator(marker: Path, development_state: Path) -> None:
    """Shut down the lane's simulator; report a failure instead of raising."""
    command = [
        sys.executable, str(SIMULATOR), "shutdown",
        "--marker", str(marker), "--development-state", str(development_state),
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=SIMULATOR_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError) as error:
        print(f"warning: could not release the iOS test simulator: {error}", file=sys.stderr)
        return
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "shutdown failed").strip()
        print(f"warning: could not release the iOS test simulator: {detail}", file=sys.stderr)


def verify_inherited(lock: Path, lane: str) -> int:
    """Exit 0 if the lease this process inherited is `lock`, the lease of `lane`.

    Compared as files, not as spellings: a lock reached through a trailing
    slash, `./`, `//` or a symlink is still the lease that covers this lane.
    """
    inherited = os.environ.get("TRON_IOS_TEST_LEASE_LOCK") or ""
    try:
        covered = bool(inherited) and os.path.samefile(inherited, lock)
    except OSError:
        covered = False
    if covered:
        return 0
    print(
        f"error: this command names lane {lane}, whose lease is {lock}, but the inherited iOS test lease "
        f"covers {inherited or 'no lane'}; refusing to run on a lane this process does not hold",
        file=sys.stderr,
    )
    return INHERITED_LEASE_EXIT


def locked_file_is_named(lock: Path, handle: IO[str]) -> bool:
    """Whether the file this holder locked is still the one `lock` names.

    A holder that removes a lane (`--remove-empty-lane`, `lane-remove`, the
    sweep reclaiming an abandoned lane) unlinks the lease file while it holds it. A command that opened the file just
    before that locks the unlinked file once the remover lets go, while a
    command that recreated the file holds the lane's real lease: the lock is
    then no lease at all. `ios-test-simulator.py` checks its own takes the same
    way.
    """
    try:
        named = os.stat(lock)
    except FileNotFoundError:
        return False
    held = os.fstat(handle.fileno())
    return (held.st_dev, held.st_ino) == (named.st_dev, named.st_ino)


def lease_file_lost(resource: str, lock: Path) -> int:
    """Refuse a take whose lease file another holder removed or replaced."""
    print(
        f"error: {resource} is already leased (its lease file {lock} "
        "was removed or replaced while this command took it)",
        file=sys.stderr,
    )
    return LOCKED_EXIT


def remove_empty_lane(lock: Path, handle: IO[str]) -> None:
    """Remove the lane directory `clean` emptied, while its lease is still held.

    Only a directory whose one entry is this holder's own lease file goes: any
    other file, or a lane nested inside it, keeps it. The lease file is unlinked
    only while it is still the file this holder locked - a lease file a command
    starting in the lane created in its place is that command's - and a command
    that creates a new one between the unlink and the rmdir keeps the directory,
    because the rmdir then fails on a directory that is no longer empty.
    """
    directory = lock.parent
    try:
        if os.listdir(directory) != [lock.name]:
            return
        held, named = os.fstat(handle.fileno()), os.lstat(lock)
        if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
            return
        lock.unlink()
        directory.rmdir()
    except OSError:
        # Raced by a command starting in this lane: the lane is its now.
        return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--marker", type=Path)
    parser.add_argument("--development-state", type=Path)
    parser.add_argument("--keep-booted", action="store_true")
    parser.add_argument("--resource", default="iOS test simulator", help="what the lease protects, named when it is contended")
    parser.add_argument("--worktree", help="the worktree whose command holds the lease, named when it is contended")
    parser.add_argument("--remove-empty-lane", action="store_true",
                        help="when the command ends, remove the lane directory if the lease file is all it holds")
    parser.add_argument("--verify-inherited", metavar="LANE",
                        help="take no lease: exit 0 if the inherited lease is --lock, else refuse (74) naming LANE")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.command[:1] == ["--"]:
        arguments.command = arguments.command[1:]
    if arguments.verify_inherited is not None:
        if arguments.command:
            parser.error("--verify-inherited takes no command")
        return verify_inherited(arguments.lock, arguments.verify_inherited)
    if arguments.marker is not None and arguments.development_state is None:
        parser.error("--development-state is required with --marker")
    if not arguments.command:
        parser.error("a command is required after --")

    try:
        arguments.lock.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(arguments.lock.parent, 0o700)
        lease = arguments.lock.open("a+", encoding="utf-8")
    except FileNotFoundError:
        # Another holder's `clean` or the sweep removed this emptied lane between
        # the mkdir and the open. Recreating it here would race that remover
        # again, so the take fails as contended, never as a traceback.
        return lease_file_lost(arguments.resource, arguments.lock)
    with lease as handle:
        process: subprocess.Popen[bytes] | None = None
        interrupted: int | None = None
        held = False

        def forward(signum: int, _frame: object) -> None:
            nonlocal interrupted
            interrupted = signum
            if process is not None and process.poll() is None:
                try:
                    # The whole command tree, not just the direct child: the shell
                    # dies at once on a signal, and the process owner below it is
                    # what stops the xcodebuild it runs in its own session.
                    os.killpg(process.pid, signum)
                except ProcessLookupError:
                    pass

        # The handlers cover taking the lease and starting the command too: a
        # signal delivered in that window would otherwise kill the holder and
        # leave its command and its simulator behind.
        previous = {
            signum: signal.signal(signum, forward)
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        }
        try:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                handle.seek(0)
                owner = describe_holder(handle.read().strip())
                print(f"error: {arguments.resource} is already leased ({owner})", file=sys.stderr)
                return LOCKED_EXIT
            if not locked_file_is_named(arguments.lock, handle):
                return lease_file_lost(arguments.resource, arguments.lock)
            held = True
            if interrupted is not None:
                return 128 + interrupted

            metadata: dict[str, object] = {
                "schema": "tron.ios-test-lock.v1",
                "pid": os.getpid(),
                "started_at_epoch_seconds": int(time.time()),
                "command": arguments.command[1] if len(arguments.command) > 1 else arguments.command[0],
                "lock_path": str(arguments.lock.resolve()),
                "uid": os.getuid(),
            }
            if arguments.worktree is not None:
                metadata["worktree"] = arguments.worktree
            # The holder's own identity goes in first: `lanes` and `status --all`
            # read it instead of taking the lease, so it has to be readable as
            # soon as the lease is held, before the simulator below is probed.
            write_metadata(handle, metadata)
            if arguments.marker is not None:
                metadata["simulator"] = {
                    "marker": str(arguments.marker),
                    "keep_booted": arguments.keep_booted,
                    "booted_when_leased": simulator_booted(arguments.marker, arguments.development_state),
                }
                write_metadata(handle, metadata)
            if interrupted is not None:
                return 128 + interrupted

            environment = os.environ.copy()
            environment["TRON_IOS_TEST_LOCK_HELD"] = "1"
            # The command tree can hand the lease on, and a process it detaches on
            # purpose - the Gateway fixture of scripts/ios-gateway-e2e-test -
            # must not inherit it, so both the descriptor and its number are
            # named where a child needs them. The lock the descriptor holds is
            # named too, so a child that re-derives its own lane can prove the
            # lease it inherited is that lane's (T-3).
            environment["TRON_IOS_TEST_LEASE_FD"] = str(handle.fileno())
            environment["TRON_IOS_TEST_LEASE_LOCK"] = str(arguments.lock)
            process = subprocess.Popen(
                arguments.command,
                env=environment,
                # Its own process group, so one signal reaches the whole tree.
                start_new_session=True,
                # The lease's own descriptor: the flock then lives exactly as
                # long as the command tree, so a sweep cannot release the
                # simulator while a command a killed holder started still runs.
                pass_fds=(handle.fileno(),),
            )
            if interrupted is not None:
                # A signal that arrived while the command was starting is still
                # the command's to receive; never lose it.
                forward(interrupted, None)
            return_code = process.wait()
            status = 128 + interrupted if interrupted is not None else return_code
            if interrupted is not None and not wait_for_command_tree(process.pid):
                print(
                    f"warning: the command tree of this lease was still running "
                    f"{COMMAND_TREE_GRACE_SECONDS:g}s after the signal; releasing the iOS test simulator anyway",
                    file=sys.stderr,
                )
            return status
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
            # Another holder owns this lane; its metadata is not ours to clear.
            if held:
                # Release while the lease is still held: the next command in
                # this lane then cannot adopt a simulator that is being shut
                # down here. A command that never started released nothing.
                if process is not None and arguments.marker is not None and not arguments.keep_booted:
                    release_simulator(arguments.marker, arguments.development_state)
                handle.seek(0)
                handle.truncate()
                if arguments.remove_empty_lane:
                    remove_empty_lane(arguments.lock, handle)


if __name__ == "__main__":
    raise SystemExit(main())
