#!/usr/bin/env python3
"""Own the repository's iOS test simulators: provision, release, sweep, name lanes."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterator

DESTINATION_EXIT = 66
LANE_BUSY_EXIT = 73
SCHEMA = "tron.ios-test-simulator.v1"
OWNER = "tron-ios-test"
# A lane is one state directory holding a marker, a lease and its simulator's
# identity. The lease file name is the lock owner's contract
# (`scripts/ios-test-lock.py`), which the sweep must take before releasing.
MARKER_NAME = "simulator.json"
LEASE_NAME = "lease.lock"
# Lanes live in the default state directory and in the directories beside or
# inside it; the sweep scans no deeper, so it never walks a simulator's own tree.
SWEEP_DEPTH = 2
# A lane that no command has used for this long is reclaimed by the sweep. The
# default lane's directory is `ios-test` and a named lane's is its
# `ios-test-<name>` sibling, which is what a lane's reported name strips.
LANE_TTL_SECONDS = 7 * 24 * 60 * 60
LANE_DIRECTORY_PREFIX = "ios-test"


class DestinationError(RuntimeError):
    pass


class LaneBusyError(RuntimeError):
    """A lane whose lease a live process holds must not be changed."""


def simctl(*arguments: str, capture: bool = True, timeout: float | None = None) -> str:
    command = [os.environ.get("TRON_IOS_XCRUN", "xcrun"), "simctl", *arguments]
    try:
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise DestinationError(f"{' '.join(command)}: timed out after {timeout:g}s") from error
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "simctl failed").strip()
        raise DestinationError(f"{' '.join(command)}: {detail}")
    return completed.stdout if capture else ""


def inventory() -> dict[str, Any]:
    try:
        value = json.loads(simctl("list", "--json"))
    except json.JSONDecodeError as error:
        raise DestinationError(f"simctl returned invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise DestinationError("simctl inventory is not an object")
    return value


def available(value: dict[str, Any]) -> bool:
    return value.get("isAvailable", True) is not False and not value.get("availabilityError")


def exact_runtime(document: dict[str, Any], version: str) -> dict[str, Any]:
    matches = [
        runtime
        for runtime in document.get("runtimes", [])
        if runtime.get("platform") == "iOS" and runtime.get("version") == version and available(runtime)
    ]
    if len(matches) != 1:
        raise DestinationError(f"expected one available iOS {version} runtime, found {len(matches)}")
    return matches[0]


def exact_device_type(document: dict[str, Any], name: str) -> dict[str, Any]:
    matches = [
        device_type
        for device_type in document.get("devicetypes", [])
        if device_type.get("name") == name and available(device_type)
    ]
    if len(matches) != 1:
        raise DestinationError(f"expected one available simulator device type named {name!r}, found {len(matches)}")
    return matches[0]


def all_devices(document: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    devices = document.get("devices", {})
    if not isinstance(devices, dict):
        raise DestinationError("simctl devices inventory is malformed")
    return [
        (runtime_identifier, device)
        for runtime_identifier, runtime_devices in devices.items()
        if isinstance(runtime_devices, list)
        for device in runtime_devices
        if isinstance(device, dict)
    ]


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def load_marker(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise DestinationError(f"owned simulator marker is unreadable: {path}: {error}") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA or value.get("owner") != OWNER:
        raise DestinationError(f"refusing unowned simulator marker: {path}")
    for key in ("udid", "name", "runtime_identifier", "device_type_identifier"):
        if not isinstance(value.get(key), str) or not value[key]:
            raise DestinationError(f"owned simulator marker is missing {key}: {path}")
    return value


def development_udid(arguments: argparse.Namespace) -> str | None:
    try:
        value = arguments.development_state.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as error:
        raise DestinationError(f"Development simulator marker is unreadable: {arguments.development_state}: {error}") from error
    lines = value.splitlines()
    udid = lines[0].strip() if lines else ""
    if len(lines) != 1 or not re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", udid):
        raise DestinationError(f"Development simulator marker is empty or invalid: {arguments.development_state}")
    return udid


def find_device(document: dict[str, Any], udid: str) -> tuple[str, dict[str, Any]] | None:
    matches = [(runtime, device) for runtime, device in all_devices(document) if device.get("udid") == udid]
    if len(matches) > 1:
        raise DestinationError(f"duplicate simulator UDID in inventory: {udid}")
    return matches[0] if matches else None


def validate_marker(
    document: dict[str, Any], marker: dict[str, Any], runtime: dict[str, Any], device_type: dict[str, Any], dev_udid: str | None
) -> dict[str, Any]:
    udid = marker["udid"]
    if udid == dev_udid:
        raise DestinationError("test simulator marker points at the remembered Development simulator")
    match = find_device(document, udid)
    if match is None:
        raise DestinationError(f"owned simulator no longer exists: {udid}")
    runtime_identifier, device = match
    if not available(device):
        raise DestinationError(f"owned simulator is unavailable: {udid}")
    expected = (
        marker["name"],
        marker["runtime_identifier"],
        marker["device_type_identifier"],
    )
    actual = (
        device.get("name"),
        runtime_identifier,
        device.get("deviceTypeIdentifier"),
    )
    if actual != expected:
        raise DestinationError(f"owned simulator identity changed: expected {expected}, found {actual}")
    requested = (runtime.get("identifier"), device_type.get("identifier"))
    if actual[1:] != requested:
        raise DestinationError(f"owned simulator uses stale runtime/device type: {actual[1:]}, expected {requested}")
    return device


def owned_identity_matches(document: dict[str, Any], marker: dict[str, Any]) -> bool:
    match = find_device(document, marker["udid"])
    if match is None:
        return True
    runtime_identifier, device = match
    return (
        device.get("name") == marker["name"]
        and runtime_identifier == marker["runtime_identifier"]
        and device.get("deviceTypeIdentifier") == marker["device_type_identifier"]
    )


def delete_owned(marker_path: Path, arguments: argparse.Namespace) -> None:
    marker = load_marker(marker_path)
    if marker is None:
        return
    document = inventory()
    if not owned_identity_matches(document, marker):
        raise DestinationError("refusing to delete a simulator whose current identity does not match its ownership marker")
    current = find_device(document, marker["udid"])
    if current is not None:
        # Check immediately before either destructive simctl boundary. The
        # Development marker can change while inventory is being inspected;
        # never shut down or delete a simulator that has become its owner.
        if marker["udid"] == development_udid(arguments):
            raise DestinationError("refusing to delete the remembered Development simulator")
        if current[1].get("state") == "Booted":
            simctl("shutdown", marker["udid"])
        if marker["udid"] == development_udid(arguments):
            raise DestinationError("refusing to delete the remembered Development simulator")
        simctl("delete", marker["udid"])
    marker_path.unlink(missing_ok=True)


def marker_paths(discovery_root: Path) -> list[Path]:
    """Every ownership marker under the lane root, at most SWEEP_DEPTH deep."""
    found: list[Path] = []
    frontier = [discovery_root]
    for _ in range(SWEEP_DEPTH + 1):
        below: list[Path] = []
        for directory in frontier:
            marker = directory / MARKER_NAME
            if marker.is_file():
                found.append(marker)
            try:
                children = sorted(directory.iterdir())
            except OSError:
                continue
            below.extend(child for child in children if child.is_dir() and not child.is_symlink())
        frontier = below
    return found


@contextlib.contextmanager
def lease_hold(path: Path) -> Iterator[bool]:
    """Hold a lane's lease without waiting; yields whether it was taken."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def lease_description(text: str) -> str:
    """Describe the holder recorded in a lease file's metadata."""
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return "held"
    if not isinstance(value, dict):
        return "held"
    identifier = value.get("pid")
    command = value.get("command")
    if isinstance(identifier, int) and not isinstance(identifier, bool) and isinstance(command, str) and command:
        return f"pid {identifier} ({command})"
    return f"pid {identifier}" if isinstance(identifier, int) and not isinstance(identifier, bool) else "held"


def lease_holder(path: Path) -> str:
    """Describe the live process holding a lane's lease, or "idle".

    Read-only on purpose: listing lanes must not create the lease file it is
    reading, or a lane with no simulator would look provisioned.
    """
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except FileNotFoundError:
        return "idle"
    except OSError as error:
        raise DestinationError(f"lane lease is unreadable: {path}: {error}") from error
    with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return lease_description(handle.read())
    return "idle"


def lane_device(document: dict[str, Any], marker: dict[str, Any]) -> tuple[dict[str, Any] | None, str]:
    """The lane's device entry and its simctl state, or None and "missing"."""
    current = find_device(document, marker["udid"])
    if current is None:
        return None, "missing"
    state = current[1].get("state")
    return current[1], state if isinstance(state, str) and state else "unknown"


def lane_state(marker_path: Path) -> str:
    """The lane's simulator state: a simctl state, "missing" or "not-provisioned".

    Read-only and independent of the pinned toolchain, so the lease holder can
    record what it found without provisioning anything.
    """
    marker = load_marker(marker_path)
    if marker is None:
        return "not-provisioned"
    _, state = lane_device(inventory(), marker)
    return state


def lane_label(directory: Path, default_state_dir: Path | None = None) -> str:
    """A lane's name: "default" for the default lane, else the directory's own.

    `ios-test` is the default lane's directory and `ios-test-<name>` a named
    lane's, so a lane's name round-trips through the runner's `--lane`.
    """
    if default_state_dir is not None and same_path(directory, default_state_dir):
        return "default"
    name = directory.name
    return name[len(LANE_DIRECTORY_PREFIX) + 1:] if name.startswith(LANE_DIRECTORY_PREFIX + "-") else name


def same_path(first: Path, second: Path) -> bool:
    return os.path.realpath(first) == os.path.realpath(second)


def human_size(size: int) -> str:
    for unit, scale in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if size >= scale:
            return f"{size / scale:.1f} {unit}"
    return f"{size} B"


def lane_directories(arguments: argparse.Namespace) -> list[Path]:
    """Every lane: the default lane, then each lane with an ownership marker."""
    found = [arguments.default_state_dir]
    found.extend(marker_path.parent for marker_path in marker_paths(arguments.discovery_root))
    unique: list[Path] = []
    seen: set[str] = set()
    for directory in found:
        key = os.path.realpath(directory)
        if key not in seen:
            seen.add(key)
            unique.append(directory)
    return unique


LANE_COLUMNS = ("LANE", "WORKTREE", "STATE", "LEASE", "LAST USED", "DISK")


def lane_rows(arguments: argparse.Namespace) -> list[list[str]]:
    """One row per lane, in the column order of LANE_COLUMNS."""
    document = inventory()
    rows: list[list[str]] = []
    for directory in lane_directories(arguments):
        marker_path = directory / MARKER_NAME
        try:
            marker = load_marker(marker_path)
        except DestinationError as error:
            print(f"warning: skipping {marker_path}: {error}", file=sys.stderr)
            continue
        lease = lease_holder(directory / LEASE_NAME)
        row = [lane_label(directory, arguments.default_state_dir)]
        if marker is None:
            rows.append([*row, "-", "not-provisioned", lease, "-", "-"])
            continue
        device, state = lane_device(document, marker)
        worktree = marker.get("worktree")
        last_used = marker.get("last_used_epoch_seconds")
        size = device.get("dataPathSize") if device is not None else None
        rows.append([
            *row,
            worktree if isinstance(worktree, str) and worktree else "-",
            state,
            lease,
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(last_used))
            if isinstance(last_used, (int, float)) and not isinstance(last_used, bool)
            else "-",
            human_size(size) if isinstance(size, int) and not isinstance(size, bool) else "-",
        ])
    return sorted(rows, key=lambda row: (row[0] != "default", row[0]))


def list_lanes(arguments: argparse.Namespace) -> int:
    rows = lane_rows(arguments)
    print(f"Lanes under {arguments.discovery_root} (default lane: {arguments.default_state_dir})")
    widths = [max([len(LANE_COLUMNS[index])] + [len(row[index]) for row in rows]) for index in range(len(LANE_COLUMNS))]
    for values in (LANE_COLUMNS, *rows):
        print("  ".join(value.ljust(widths[index]) for index, value in enumerate(values)).rstrip())
    return 0


def shutdown_owned(marker_path: Path, arguments: argparse.Namespace) -> str:
    """Shut down the booted simulator one ownership marker names, bounded.

    Returns "shutdown", or why there was nothing to do: "already-shutdown",
    "missing" (the marker outlived its device) or "not-provisioned".
    """
    marker = load_marker(marker_path)
    if marker is None:
        return "not-provisioned"
    document = inventory()
    if not owned_identity_matches(document, marker):
        raise DestinationError("refusing to release a simulator whose current identity does not match its ownership marker")
    if marker["udid"] == development_udid(arguments):
        # The remembered Development simulator owns the paired app container and
        # is released only by the owner that started it.
        raise DestinationError("refusing to release the remembered Development simulator")
    current = find_device(document, marker["udid"])
    if current is None:
        return "missing"
    if current[1].get("state") != "Booted":
        return "already-shutdown"
    simctl("shutdown", marker["udid"], timeout=arguments.shutdown_timeout_seconds)
    return "shutdown"


def sweep_lane(arguments: argparse.Namespace, marker_path: Path) -> str:
    """Release one orphaned lane: booted with no live process holding its lease.

    Returns "released", or "busy" (a live owner holds the lease), "idle"
    (nothing booted), "skipped" (not safely releasable) or "failed".
    """
    try:
        marker = load_marker(marker_path)
    except DestinationError as error:
        print(f"warning: skipping {marker_path}: {error}", file=sys.stderr)
        return "skipped"
    if marker is None:
        return "idle"
    try:
        document = inventory()
        identity_matches = owned_identity_matches(document, marker)
        development_overlap = marker["udid"] == development_udid(arguments)
        current = find_device(document, marker["udid"])
    except DestinationError as error:
        print(f"warning: skipping {marker_path}: {error}", file=sys.stderr)
        return "skipped"
    if not identity_matches:
        print(f"warning: skipping {marker_path}: the simulator's current identity does not match its ownership marker", file=sys.stderr)
        return "skipped"
    if development_overlap:
        print(f"warning: skipping {marker_path}: it names the remembered Development simulator", file=sys.stderr)
        return "skipped"
    if current is None or current[1].get("state") != "Booted":
        return "idle"
    with lease_hold(marker_path.parent / LEASE_NAME) as held:
        if not held:
            return "busy"
        # Under the lease the lane cannot start a command that would adopt the
        # device, and the owner that just released may already have shut it down.
        try:
            document = inventory()
            current = find_device(document, marker["udid"])
            if current is None or current[1].get("state") != "Booted":
                return "idle"
            if marker["udid"] == development_udid(arguments):
                raise DestinationError("the lane's marker now names the remembered Development simulator")
            simctl("shutdown", marker["udid"], timeout=arguments.shutdown_timeout_seconds)
        except DestinationError as error:
            print(f"warning: could not release {marker['name']} ({marker_path}): {error}", file=sys.stderr)
            return "failed"
    print(f"shut down {marker['name']} ({marker_path.parent})")
    return "released"


def sweep(arguments: argparse.Namespace) -> int:
    """Reclaim every orphaned and expired lane under the discovery root. Idempotent."""
    markers = marker_paths(arguments.discovery_root)
    deadline = time.monotonic() + arguments.sweep_deadline_seconds
    failures = 0
    for index, marker_path in enumerate(markers):
        if time.monotonic() >= deadline:
            print(
                f"warning: sweep deadline reached; {len(markers) - index} lane marker(s) were not inspected",
                file=sys.stderr,
            )
            break
        if expire_lane(arguments, marker_path) == "failed":
            failures += 1
        if sweep_lane(arguments, marker_path) == "failed":
            failures += 1
    return DESTINATION_EXIT if failures else 0


def expiry_of(marker_path: Path, now: float) -> str:
    """Why a lane is or is not due for removal.

    "no-marker" means there is nothing that proves this directory is ours:
    marker-less state is never removed, and the default lane's directory exists
    as soon as any command creates it, before it has a simulator. "undated"
    means a marker written before lanes recorded their last use; it is kept
    until a command uses the lane and dates it.
    """
    marker = load_marker(marker_path)
    if marker is None:
        return "no-marker"
    last_used = marker.get("last_used_epoch_seconds")
    if not isinstance(last_used, (int, float)) or isinstance(last_used, bool):
        return "undated"
    return "expired" if now - last_used > LANE_TTL_SECONDS else "fresh"


def remove_lane(directory: Path, arguments: argparse.Namespace) -> None:
    """Delete one lane's simulator and its state directory.

    The ownership marker is the proof, and the directory must be a lane the
    runner would have created - inside the lane root, or the default lane's own
    configured directory - so nothing but a lane can be removed here.
    """
    root = os.path.realpath(arguments.discovery_root)
    default = os.path.realpath(arguments.default_state_dir) if arguments.default_state_dir else None
    resolved = os.path.realpath(directory)
    protected = (root, os.path.realpath("/"), os.path.realpath(Path.home()))
    if directory.is_symlink() or resolved in protected or not (Path(root) in Path(resolved).parents or resolved == default):
        raise DestinationError(f"refusing to remove a lane directory outside the lane root: {directory}")
    marker_path = directory / MARKER_NAME
    if load_marker(marker_path) is None:
        raise DestinationError(f"refusing to remove lane state with no ownership marker: {directory}")
    delete_owned(marker_path, arguments)
    shutil.rmtree(directory)


def expire_lane(arguments: argparse.Namespace, marker_path: Path) -> str:
    """Remove a lane unused for longer than the TTL.

    Returns "expired", or why not: "fresh", "undated", "no-marker", "busy" (a
    live process holds the lease), "skipped" (an unreadable marker or an
    unsafe directory) or "failed".
    """
    try:
        outcome = expiry_of(marker_path, time.time())
    except DestinationError as error:
        print(f"warning: skipping {marker_path}: {error}", file=sys.stderr)
        return "skipped"
    if outcome != "expired":
        return outcome
    with lease_hold(marker_path.parent / LEASE_NAME) as held:
        if not held:
            return "busy"
        # Under the lease the lane cannot start a command that would refresh it,
        # so this second reading decides.
        try:
            outcome = expiry_of(marker_path, time.time())
            if outcome != "expired":
                return outcome
            remove_lane(marker_path.parent, arguments)
        except DestinationError as error:
            print(f"warning: could not remove lane {marker_path.parent}: {error}", file=sys.stderr)
            return "failed"
    print(f"removed lane {lane_label(marker_path.parent)} ({marker_path.parent})")
    return "expired"


def remove_lane_command(arguments: argparse.Namespace) -> int:
    """Delete one named lane, refusing while a live process holds it."""
    directory = arguments.lane_dir
    marker_path = directory / MARKER_NAME
    marker = load_marker(marker_path)
    if marker is None:
        if not directory.exists():
            print(f"no such lane: {directory}")
            return 0
        raise DestinationError(f"refusing to remove lane state with no ownership marker: {directory}")
    with lease_hold(directory / LEASE_NAME) as held:
        if not held:
            label = lane_label(directory, arguments.default_state_dir)
            raise LaneBusyError(f"lane {label} is leased ({lease_holder(directory / LEASE_NAME)})")
        remove_lane(directory, arguments)
    print(f"removed lane {lane_label(directory, arguments.default_state_dir)} ({directory})")
    return 0


def stamp_lane_use(arguments: argparse.Namespace, marker: dict[str, Any]) -> dict[str, Any]:
    """Record the lane's creating worktree and this use in the lane's marker.

    `worktree` is written once, when the lane's simulator is created: a later
    `lane-remove` uses it to decide whether the lane's products belong to a
    worktree that still exists. `last_used_epoch_seconds` is refreshed by every
    use and is what the sweep dates a lane by.
    """
    updated = dict(marker)
    if arguments.worktree is not None and "worktree" not in updated:
        updated["worktree"] = os.path.realpath(arguments.worktree)
    updated["last_used_epoch_seconds"] = int(time.time())
    atomic_write(arguments.marker, updated)
    return updated


def provision(arguments: argparse.Namespace) -> dict[str, Any]:
    document = inventory()
    runtime = exact_runtime(document, arguments.runtime)
    device_type = exact_device_type(document, arguments.device_type)
    dev_udid = development_udid(arguments)
    marker = load_marker(arguments.marker)

    if marker is not None:
        try:
            device = validate_marker(document, marker, runtime, device_type, dev_udid)
        except DestinationError as error:
            stale_requested = (
                marker["runtime_identifier"] != runtime.get("identifier")
                or marker["device_type_identifier"] != device_type.get("identifier")
                or find_device(document, marker["udid"]) is None
            )
            if not stale_requested or not owned_identity_matches(document, marker):
                raise
            current = find_device(document, marker["udid"])
            if current is not None:
                # Stale recovery is destructive too: apply the Development
                # exclusion at each simctl boundary, not just on validation.
                if marker["udid"] == development_udid(arguments):
                    raise DestinationError("refusing to delete the remembered Development simulator")
                if current[1].get("state") == "Booted":
                    simctl("shutdown", marker["udid"])
                if marker["udid"] == development_udid(arguments):
                    raise DestinationError("refusing to delete the remembered Development simulator")
                simctl("delete", marker["udid"])
            arguments.marker.unlink(missing_ok=True)
            marker = None
            document = inventory()

    if marker is None:
        collisions = [device for _, device in all_devices(document) if device.get("name") == arguments.name]
        if collisions:
            raise DestinationError(
                f"refusing to adopt {len(collisions)} unmarked simulator(s) named {arguments.name!r}; remove them manually or choose a unique owned name"
            )
        udid = simctl("create", arguments.name, device_type["identifier"], runtime["identifier"]).strip()
        if not udid:
            raise DestinationError("simctl create returned an empty UDID")
        if udid == dev_udid:
            raise DestinationError("simctl created the remembered Development simulator UDID")
        marker = {
            "schema": SCHEMA,
            "owner": OWNER,
            "udid": udid,
            "name": arguments.name,
            "runtime_identifier": runtime["identifier"],
            "runtime_version": runtime["version"],
            "runtime_build": runtime.get("buildversion"),
            "device_type_identifier": device_type["identifier"],
            "device_type_name": device_type["name"],
            "ephemeral": arguments.ephemeral,
        }
        marker = stamp_lane_use(arguments, marker)
        document = inventory()
        device = validate_marker(document, marker, runtime, device_type, dev_udid)
    else:
        marker = stamp_lane_use(arguments, marker)

    if device.get("state") != "Booted":
        simctl("boot", marker["udid"])
    simctl("bootstatus", marker["udid"], "-b")
    document = inventory()
    device = validate_marker(document, marker, runtime, device_type, dev_udid)
    return {**marker, "state": device.get("state"), "udid_sha256": hashlib.sha256(marker["udid"].encode()).hexdigest()}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("provision", "validate", "status", "delete", "state", "shutdown", "sweep", "lanes", "lane-remove"),
    )
    parser.add_argument("--marker", type=Path)
    parser.add_argument("--runtime")
    parser.add_argument("--device-type")
    parser.add_argument("--name")
    parser.add_argument("--worktree", type=Path)
    parser.add_argument("--development-state", required=True, type=Path)
    parser.add_argument("--ephemeral", action="store_true")
    parser.add_argument("--discovery-root", type=Path)
    parser.add_argument("--default-state-dir", type=Path)
    parser.add_argument("--lane-dir", type=Path)
    parser.add_argument(
        "--shutdown-timeout-seconds",
        type=float,
        default=float(os.environ.get("TRON_IOS_TEST_SHUTDOWN_TIMEOUT_SECONDS", "60")),
    )
    parser.add_argument(
        "--sweep-deadline-seconds",
        type=float,
        default=float(os.environ.get("TRON_IOS_TEST_SWEEP_DEADLINE_SECONDS", "300")),
    )
    arguments = parser.parse_args()
    if arguments.shutdown_timeout_seconds <= 0 or arguments.sweep_deadline_seconds <= 0:
        parser.error("deadlines must be positive")
    if arguments.command in ("sweep", "lanes"):
        if arguments.discovery_root is None:
            parser.error(f"{arguments.command} requires --discovery-root")
        if arguments.marker is not None:
            parser.error(f"{arguments.command} does not take --marker")
        if arguments.command == "lanes" and arguments.default_state_dir is None:
            parser.error("lanes requires --default-state-dir")
        return arguments
    if arguments.command == "lane-remove":
        for required in ("lane_dir", "discovery_root", "default_state_dir"):
            if getattr(arguments, required) is None:
                parser.error(f"lane-remove requires --{required.replace('_', '-')}")
        if arguments.marker is not None:
            parser.error("lane-remove does not take --marker")
        return arguments
    if arguments.marker is None:
        parser.error(f"{arguments.command} requires --marker")
    # Only state and shutdown read everything they need from the marker alone.
    if arguments.command not in ("state", "shutdown") and not (arguments.runtime and arguments.device_type and arguments.name):
        parser.error(f"{arguments.command} requires --runtime, --device-type and --name")
    return arguments


SHUTDOWN_OUTCOME = {
    "shutdown": "shut down",
    "already-shutdown": "already shut down",
    "missing": "owned simulator no longer exists",
    "not-provisioned": "not provisioned",
}


def main() -> int:
    arguments = parse_args()
    try:
        if arguments.command == "sweep":
            return sweep(arguments)
        if arguments.command == "lanes":
            return list_lanes(arguments)
        if arguments.command == "lane-remove":
            return remove_lane_command(arguments)
        if arguments.command == "state":
            print(lane_state(arguments.marker))
            return 0
        if arguments.command == "shutdown":
            outcome = shutdown_owned(arguments.marker, arguments)
            print(f"{SHUTDOWN_OUTCOME[outcome]}: {arguments.marker}")
            return 0
        if arguments.command == "delete":
            delete_owned(arguments.marker, arguments)
            return 0
        if arguments.command == "provision":
            details = provision(arguments)
        else:
            document = inventory()
            runtime = exact_runtime(document, arguments.runtime)
            device_type = exact_device_type(document, arguments.device_type)
            marker = load_marker(arguments.marker)
            if marker is None:
                if arguments.command == "status":
                    print("not provisioned")
                    return 0
                raise DestinationError("test simulator is not provisioned")
            device = validate_marker(document, marker, runtime, device_type, development_udid(arguments))
            details = {
                **marker,
                "state": device.get("state"),
                "udid_sha256": hashlib.sha256(marker["udid"].encode()).hexdigest(),
            }
        if arguments.command == "status":
            public_details = dict(details)
            public_details.pop("udid", None)
            print(json.dumps(public_details, indent=2, sort_keys=True))
        else:
            print(details["udid"])
        return 0
    except LaneBusyError as error:
        print(f"error: {error}", file=sys.stderr)
        return LANE_BUSY_EXIT
    except DestinationError as error:
        print(f"error: {error}", file=sys.stderr)
        return DESTINATION_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
