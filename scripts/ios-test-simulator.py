#!/usr/bin/env python3
"""Own the repository's iOS test resources: simulators, lanes, runs and products.

Provisioning, releasing and sweeping own the simulators a test command uses;
memory admission refuses a boot the Mac cannot afford before it happens; the
`simulators` view reports everything that holds memory; and pruning reclaims the
runs and products finished commands leave behind.
"""

from __future__ import annotations

import argparse
import calendar
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
from typing import Any, Iterator, NamedTuple

DESTINATION_EXIT = 66
# The stable "not now" exit: a lane a live process holds, or a Mac too short of
# memory to boot another simulator. Both mean the caller decides whether to
# wait; neither is a broken request.
BUSY_EXIT = 73
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
# A boot is admitted only when the Mac would still have this much free memory.
# It is read before `simctl boot`, so the booted simulator's own footprint (about
# 2 GB) comes out of the reserve. Swap in use is reported in the same table and
# never refuses a boot: it drains slowly, so a reading at a limit would refuse
# boots persistently. The environment override exists for CI and for retuning
# from the measurements the lifecycle plan records in its handoffs.
MEMORY_RESERVE_BYTES = 8 * 1024**3
# A lease records the holder's pid and the second it started; the process table's
# own age for that pid is what proves the pid has not been recycled into another
# process. The window is wider than the truncation on either side (the recorded
# second and the reported one) and narrow enough that a recycled pid would have
# to appear within seconds to be believed.
HOLDER_START_TOLERANCE_SECONDS = 5.0
# One admission lock for this Mac: every lane's boot is serialized on it, and it
# is held from the memory read until `simctl bootstatus` returns, so two starts
# cannot each read memory the other has not taken yet.
# The leading dot keeps the lock outside the lane namespace: a lane is
# `ios-test-NAME` and a lane name cannot start with a dot.
ADMISSION_LOCK_NAME = ".ios-test-admission.lock"
# The runner's ownership marker, written by `owned_directory` in
# `scripts/tron-ios-test` before it creates a results or products directory.
# Deletion outside the tool's own trees is refused without it.
OWNERSHIP_MARKER_NAME = ".tron-ios-test-owned"
# The owner of one run directory, written when the runner creates it: the
# worktree and lane that produced the run, which is what `clean` and `prune`
# scope and group by.
RUN_OWNER_NAME = "owner.json"
RUN_METADATA_NAME = "metadata.json"
# The products stamp `scripts/ios-test-build-identity.py` writes after a
# successful build; its `worktree` is the path whose existence decides whether
# those products still have an owner.
BUILD_IDENTITY_NAME = "build-identity.json"
# Retention: a run of a worktree is kept while it is one of its newest
# RUNS_KEPT_PER_WORKTREE runs or younger than RUN_TTL_SECONDS. The runner names
# a run directory `<UTC timestamp>-<command>.<suffix>`, so a run from before
# `owner.json` existed can still be dated from its name.
RUNS_KEPT_PER_WORKTREE = 50
RUN_TTL_SECONDS = 7 * 24 * 60 * 60
RUN_NAME_PATTERN = re.compile(r"^(\d{8}T\d{6}Z)-")
UNKNOWN_WORKTREE = "an unrecorded worktree"
# `status --all` and the admission refusal print the same table.
STATUS_COLUMNS = ("SIMULATOR", "STATE", "OWNER", "WORKTREE", "LEASE", "UPTIME", "DISK")
# A booted simulator's boot time is proven by the device's own init process; the
# GUI app is the other long-lived holder of the Mac's memory.
DEVICE_UDID_PATTERN = re.compile(r"/Devices/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})/")
SIMULATOR_APP_PROCESS = "Simulator.app/Contents/MacOS/Simulator"
ELAPSED_PATTERN = re.compile(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$")
FREE_PERCENTAGE_PATTERN = re.compile(r"System-wide memory free percentage:\s*([0-9]+(?:\.[0-9]+)?)%")
SWAP_USED_PATTERN = re.compile(r"\bused\s*=\s*([0-9.]+)\s*([KMGT]?)")
SIZE_SCALES = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
READER_TIMEOUT_SECONDS = 10.0
# A boot and its `bootstatus` run under the machine-wide admission lock, so a
# wedged boot must fail its own command instead of blocking every lane's boots.
BOOT_TIMEOUT_SECONDS = 180.0


class DestinationError(RuntimeError):
    pass


class MemoryAdmissionError(RuntimeError):
    """The Mac is too short of memory to boot another simulator now."""


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


def load_json(path: Path) -> dict[str, Any] | None:
    """The JSON object in a file, or None when it is missing or unreadable."""
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


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
    value = parse_lease(text)
    if value is None:
        return "held"
    identifier = value.get("pid")
    command = value.get("command")
    if isinstance(identifier, int) and not isinstance(identifier, bool) and isinstance(command, str) and command:
        return f"pid {identifier} ({command})"
    return f"pid {identifier}" if isinstance(identifier, int) and not isinstance(identifier, bool) else "held"


def parse_lease(text: str) -> dict[str, Any] | None:
    """The object a lease file records, or None when it records nothing usable."""
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def holder_is_live(metadata: dict[str, Any], table: list[tuple[int, int, str]] | None) -> bool:
    """Whether the process a lease's metadata names is still that process.

    Liveness is `kill(pid, 0)`; the age the process table reports for that pid
    is what separates the holder from a pid the system has recycled, because the
    holder records the second it started.
    """
    pid = metadata.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Another user's process is alive; this Mac's lanes are this user's.
        return True
    started_at = metadata.get("started_at_epoch_seconds")
    if not isinstance(started_at, (int, float)) or isinstance(started_at, bool):
        return True
    elapsed = next((seconds for holder, seconds, _ in table or [] if holder == pid), None)
    if elapsed is None:
        return True
    # One-sided: a recycled pid always started after the holder recorded its
    # start, while the recorded holder may have started earlier than it wrote
    # that second (bash or the profiler becomes the holder by exec, keeping its
    # fork time), so only a later start disproves it.
    return (time.time() - elapsed) <= float(started_at) + HOLDER_START_TOLERANCE_SECONDS


def lease_holder(
    path: Path, *, table: list[tuple[int, int, str]] | None = None, held: bool = False
) -> str:
    """Describe the live process holding a lane's lease, or "idle".

    Read-only on purpose, and it never takes the lane's lease: a `lanes` or
    `status --all` pass that locked each lane as it probed it made a command
    starting at that moment fail 73, as if the lane were busy. The metadata
    names the holder and the process table proves that pid is still the holder.
    Reading must not create the lease file either, or a lane with no simulator
    would look provisioned. `held` describes a lease a caller already failed to
    lock: the lane is taken, even though the recorded holder is gone.
    """
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except FileNotFoundError:
        return "idle"
    except OSError as error:
        raise DestinationError(f"lane lease is unreadable: {path}: {error}") from error
    with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
        text = handle.read()
    metadata = parse_lease(text)
    if metadata is None or not holder_is_live(metadata, table):
        return "held" if held else "idle"
    return lease_description(text)


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
    lane's, so a lane's name round-trips through the runner's `--lane`. A caller
    that cannot name the configured default directory still reads the standard
    one as the default lane.
    """
    if default_state_dir is not None and same_path(directory, default_state_dir):
        return "default"
    name = directory.name
    if name == LANE_DIRECTORY_PREFIX:
        return "default"
    return name[len(LANE_DIRECTORY_PREFIX) + 1:] if name.startswith(LANE_DIRECTORY_PREFIX + "-") else name


def same_path(first: Path, second: Path) -> bool:
    return os.path.realpath(first) == os.path.realpath(second)


# The one lane selection every iOS test tool - the runner, the profiler and the
# Gateway E2E harness - asks for, so one worktree and one selection name one
# lane in all three. A lane name becomes `<lane root>/ios-test-NAME` and the
# device `Tron iOS Tests (NAME)`, so it cannot start with a dot (see
# ADMISSION_LOCK_NAME) or contain a path separator.
DEFAULT_DEVICE_NAME = "Tron iOS Tests"
LANE_NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
IDENTITY = Path(__file__).resolve().parent / "ios-test-build-identity.py"
PRE_LANE_OVERRIDES = ("TRON_IOS_TEST_STATE_DIR", "TRON_IOS_TEST_DEVICE_NAME")


class LaneSelectionError(RuntimeError):
    """The requested lane is ambiguous, not a lane name, or cannot be derived."""


class LaneSelection(NamedTuple):
    label: str
    state_dir: Path
    device_name: str
    lane_root: Path
    default_state_dir: Path


def worktree_lane(worktree: Path) -> str:
    """The lane a checkout uses when nothing selects one.

    The primary checkout keeps the default lane. A linked worktree gets the lane
    named by its worktree key - the key that also names its test products and
    its Gateway E2E fixture - so parallel worktrees never contend for one lease;
    memory admission and idle-lane expiry bound how many such lanes exist.
    """
    located = subprocess.run(
        ["git", "-C", str(worktree), "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    directories = located.stdout.splitlines()
    if located.returncode != 0 or len(directories) != 2:
        detail = located.stderr.strip().splitlines()
        raise LaneSelectionError(
            f"cannot tell whether {worktree} is the primary checkout or a linked worktree"
            + (f": {detail[-1]}" if detail else "")
        )
    if same_path(Path(directories[0]), Path(directories[1])):
        return "default"
    keyed = subprocess.run(
        [sys.executable, str(IDENTITY), "worktree-key", "--worktree", str(worktree)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    if keyed.returncode != 0:
        raise LaneSelectionError(f"cannot derive the worktree key of {worktree}: {keyed.stderr.strip()}")
    return keyed.stdout.strip()


def select_lane(worktree: Path, requested: str | None) -> LaneSelection:
    """The lane a command in `worktree` uses.

    In order: `--lane NAME` or TRON_IOS_TEST_LANE, which must agree; then the
    pre-lane TRON_IOS_TEST_STATE_DIR and TRON_IOS_TEST_DEVICE_NAME, which
    describe the default lane and so select it (CI and profiling lanes set
    them); then this checkout's own lane. `default` names the default lane. A
    named lane refuses the pre-lane overrides rather than guess which spelling
    was meant.
    """
    environment_lane = os.environ.get("TRON_IOS_TEST_LANE") or None
    if requested is not None and environment_lane is not None and requested != environment_lane:
        raise LaneSelectionError(f"--lane {requested} conflicts with TRON_IOS_TEST_LANE={environment_lane}")
    state_override = os.environ.get("TRON_IOS_TEST_STATE_DIR") or None
    device_override = os.environ.get("TRON_IOS_TEST_DEVICE_NAME") or None
    default_state_dir = Path(state_override) if state_override else Path.home() / ".tron/internal/ios-test"
    lane_root = Path(os.environ.get("TRON_IOS_TEST_DISCOVERY_ROOT") or default_state_dir.parent)
    name = requested or environment_lane
    if name is None:
        name = "default" if state_override or device_override else worktree_lane(worktree)
    if name == "default":
        return LaneSelection(
            "default", default_state_dir, device_override or DEFAULT_DEVICE_NAME, lane_root, default_state_dir,
        )
    if not LANE_NAME_PATTERN.fullmatch(name):
        raise LaneSelectionError(f"invalid lane name: {name}")
    for variable in PRE_LANE_OVERRIDES:
        if os.environ.get(variable):
            raise LaneSelectionError(f"--lane {name} cannot be combined with {variable}")
    return LaneSelection(
        name, lane_root / f"{LANE_DIRECTORY_PREFIX}-{name}", f"{DEFAULT_DEVICE_NAME} ({name})",
        lane_root, default_state_dir,
    )


def print_lane(arguments: argparse.Namespace) -> int:
    """One field per line, in LaneSelection order, for the shell tools to read."""
    selection = select_lane(arguments.worktree, arguments.lane)
    fields = [str(value) for value in selection]
    if any("\n" in field for field in fields):
        raise LaneSelectionError("a lane path or device name contains a newline")
    print("\n".join(fields))
    return 0


def human_size(size: int) -> str:
    for unit, scale in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if size >= scale:
            return f"{size / scale:.1f} {unit}"
    return f"{size} B"


def human_duration(seconds: int) -> str:
    """How long something has been up, in the units a person reads at a glance."""
    days, remainder = divmod(max(seconds, 0), 24 * 60 * 60)
    hours, remainder = divmod(remainder, 60 * 60)
    minutes = remainder // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def run_reader(executable: str, arguments: list[str]) -> str | None:
    """Read one read-only host report, or None when the reader is unavailable.

    A missing, failing, hanging or unparsable reader never fails a boot: the
    tooling must still run where these reports are not installed (CI), so every
    caller treats None as "cannot tell" and admits with a warning.
    """
    try:
        completed = subprocess.run(
            [executable, *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=READER_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return completed.stdout if completed.returncode == 0 else None


def sysctl_reader() -> str:
    return os.environ.get("TRON_IOS_SYSCTL", "sysctl")


def memory_pressure_reader() -> str:
    return os.environ.get("TRON_IOS_MEMORY_PRESSURE", "memory_pressure")


def process_reader() -> str:
    return os.environ.get("TRON_IOS_PS", "ps")


def parse_free_percentage(text: str) -> float | None:
    match = FREE_PERCENTAGE_PATTERN.search(text)
    return float(match.group(1)) if match is not None else None


def parse_swap_used_bytes(text: str) -> int | None:
    match = SWAP_USED_PATTERN.search(text)
    if match is None:
        return None
    return int(float(match.group(1)) * SIZE_SCALES[match.group(2)])


def parse_elapsed_seconds(text: str) -> int | None:
    """Seconds from ps's `etime` field, whose shape is [[dd-]hh:]mm:ss."""
    match = ELAPSED_PATTERN.match(text)
    if match is None:
        return None
    days, hours, minutes, seconds = (int(value) if value else 0 for value in match.groups())
    return days * 24 * 60 * 60 + hours * 60 * 60 + minutes * 60 + seconds


class MemoryState(NamedTuple):
    """What the Mac's memory reports say; None wherever a reader is unavailable."""

    physical_bytes: int | None
    free_bytes: int | None
    swap_used_bytes: int | None


def read_memory_state() -> MemoryState:
    """Read the Mac's physical memory, free memory and swap in use."""
    physical_text = run_reader(sysctl_reader(), ["-n", "hw.memsize"])
    physical_bytes: int | None = None
    if physical_text is not None and physical_text.strip().isdigit():
        physical_bytes = int(physical_text.strip())
    free_bytes: int | None = None
    if physical_bytes is not None:
        percentage = parse_free_percentage(run_reader(memory_pressure_reader(), []) or "")
        if percentage is not None:
            free_bytes = int(physical_bytes * percentage / 100)
    swap_text = run_reader(sysctl_reader(), ["-n", "vm.swapusage"])
    swap_used_bytes = parse_swap_used_bytes(swap_text) if swap_text is not None else None
    return MemoryState(physical_bytes, free_bytes, swap_used_bytes)


def process_table() -> list[tuple[int, int, str]] | None:
    """(pid, seconds running, command) for every process, or None if unreadable."""
    text = run_reader(process_reader(), ["-axo", "pid=,etime=,command="])
    if text is None:
        return None
    table: list[tuple[int, int, str]] = []
    for line in text.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3 or not fields[0].isdigit():
            continue
        elapsed = parse_elapsed_seconds(fields[1])
        if elapsed is None:
            continue
        table.append((int(fields[0]), elapsed, fields[2]))
    return table


def booted_uptimes(table: list[tuple[int, int, str]] | None) -> dict[str, int]:
    """Seconds since boot for every simulator the process table proves booted.

    A booted device runs its own init process (`launchd_sim`) from its data
    directory, and that process starts when the device boots; the longest
    running match is therefore the boot time.
    """
    uptimes: dict[str, int] = {}
    for _, elapsed, command in table or []:
        match = DEVICE_UDID_PATTERN.search(command)
        if match is None:
            continue
        uptimes[match.group(1)] = max(uptimes.get(match.group(1), 0), elapsed)
    return uptimes


def simulator_app_uptime(table: list[tuple[int, int, str]] | None) -> int | None:
    uptimes = [elapsed for _, elapsed, command in table or [] if SIMULATOR_APP_PROCESS in command]
    return max(uptimes) if uptimes else None


def lane_root(arguments: argparse.Namespace) -> tuple[Path, Path] | None:
    """The lane root and default lane directory, or None when unnamed.

    The runner passes both, so a lane view can see every lane. A caller that
    only knows its own marker - the profiler, the E2E harness, the lease holder
    - gets no discovery, because a view that cannot see the Mac's other lanes
    must never claim they are idle.
    """
    if arguments.discovery_root is None or arguments.default_state_dir is None:
        return None
    return arguments.discovery_root, arguments.default_state_dir


def lane_directories(arguments: argparse.Namespace) -> list[Path]:
    """Every lane: the default lane, then each lane with an ownership marker."""
    root = lane_root(arguments)
    if root is None:
        return [arguments.marker.parent] if arguments.marker is not None else []
    discovery_root, default_state_dir = root
    found = [default_state_dir]
    found.extend(marker_path.parent for marker_path in marker_paths(discovery_root))
    unique: list[Path] = []
    seen: set[str] = set()
    for directory in found:
        key = os.path.realpath(directory)
        if key not in seen:
            seen.add(key)
            unique.append(directory)
    return unique


LANE_COLUMNS = ("LANE", "WORKTREE", "STATE", "LEASE", "LAST USED", "DISK")


def lane_states(arguments: argparse.Namespace) -> list[tuple[str, Path, dict[str, Any] | None]]:
    """(label, directory, marker) for every lane, default lane first.

    One place decides which lanes exist and which of their markers can be read:
    an unreadable marker is reported and skipped, never guessed at.
    """
    states: list[tuple[str, Path, dict[str, Any] | None]] = []
    for directory in lane_directories(arguments):
        try:
            marker = load_marker(directory / MARKER_NAME)
        except DestinationError as error:
            print(f"warning: skipping {directory / MARKER_NAME}: {error}", file=sys.stderr)
            continue
        states.append((lane_label(directory, arguments.default_state_dir), directory, marker))
    return sorted(states, key=lambda state: (state[0] != "default", state[0]))


def lane_rows(arguments: argparse.Namespace) -> list[list[str]]:
    """One row per lane, in the column order of LANE_COLUMNS."""
    document = inventory()
    table = process_table()
    rows: list[list[str]] = []
    for label, directory, marker in lane_states(arguments):
        lease = lease_holder(directory / LEASE_NAME, table=table)
        if marker is None:
            rows.append([label, "-", "not-provisioned", lease, "-", "-"])
            continue
        device, state = lane_device(document, marker)
        worktree = marker.get("worktree")
        last_used = marker.get("last_used_epoch_seconds")
        size = device.get("dataPathSize") if device is not None else None
        rows.append([
            label,
            worktree if isinstance(worktree, str) and worktree else "-",
            state,
            lease,
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(last_used))
            if isinstance(last_used, (int, float)) and not isinstance(last_used, bool)
            else "-",
            human_size(size) if isinstance(size, int) and not isinstance(size, bool) else "-",
        ])
    return rows


def list_lanes(arguments: argparse.Namespace) -> int:
    rows = lane_rows(arguments)
    print(f"Lanes under {arguments.discovery_root} (default lane: {arguments.default_state_dir})")
    widths = [max([len(LANE_COLUMNS[index])] + [len(row[index]) for row in rows]) for index in range(len(LANE_COLUMNS))]
    for values in (LANE_COLUMNS, *rows):
        print("  ".join(value.ljust(widths[index]) for index, value in enumerate(values)).rstrip())
    return 0


def uptime_cell(uptimes: dict[str, int], udid: str, state: str) -> str:
    if state != "Booted":
        return "-"
    elapsed = uptimes.get(udid)
    return human_duration(elapsed) if elapsed is not None else "-"


def disk_cell(device: dict[str, Any] | None) -> str:
    size = device.get("dataPathSize") if device is not None else None
    return human_size(size) if isinstance(size, int) and not isinstance(size, bool) else "-"


def simulator_rows(arguments: argparse.Namespace) -> list[list[str]]:
    """One row per simulator that holds memory, in the STATUS_COLUMNS order.

    Every lane appears, booted or not, so a released lane is visibly released;
    every booted device no lane owns appears, so memory held outside the test
    tooling cannot hide; the remembered Development simulator is named as the
    Development one; and Simulator.app is always listed, because the GUI app
    outlives the runs that opened it.
    """
    document = inventory()
    table = process_table()
    if table is None:
        print("warning: cannot read the process table (ps); simulator uptimes are unknown", file=sys.stderr)
    uptimes = booted_uptimes(table)
    try:
        development = development_udid(arguments)
    except DestinationError as error:
        print(f"warning: cannot tell which simulator is the Development one: {error}", file=sys.stderr)
        development = None
    rows: list[list[str]] = []
    claimed: set[str] = set()
    for label, directory, marker in lane_states(arguments):
        lease = lease_holder(directory / LEASE_NAME, table=table)
        if marker is None:
            rows.append(["-", "not-provisioned", f"lane {label}", "-", lease, "-", "-"])
            continue
        claimed.add(marker["udid"])
        device, state = lane_device(document, marker)
        worktree = marker.get("worktree")
        rows.append([
            marker["name"],
            state,
            f"lane {label}",
            worktree if isinstance(worktree, str) and worktree else "-",
            lease,
            uptime_cell(uptimes, marker["udid"], state),
            disk_cell(device),
        ])
    if development is not None:
        claimed.add(development)
        match = find_device(document, development)
        if match is None:
            rows.append(["Development simulator", "missing", "development", "-", "-", "-", "-"])
        else:
            device = match[1]
            state = device.get("state") if isinstance(device.get("state"), str) else "unknown"
            rows.append([
                device.get("name") or "Development simulator",
                state,
                "development",
                "-",
                "-",
                uptime_cell(uptimes, development, state),
                disk_cell(device),
            ])
    unowned = [
        device
        for _, device in all_devices(document)
        if device.get("state") == "Booted" and device.get("udid") not in claimed
    ]
    for device in sorted(unowned, key=lambda entry: str(entry.get("name"))):
        udid = device.get("udid")
        rows.append([
            device.get("name") or "unowned",
            "Booted",
            "unowned",
            "-",
            "-",
            uptime_cell(uptimes, udid if isinstance(udid, str) else "", "Booted"),
            disk_cell(device),
        ])
    app_uptime = simulator_app_uptime(table)
    rows.append([
        "Simulator.app",
        "running" if app_uptime is not None else "not running",
        "-",
        "-",
        "-",
        human_duration(app_uptime) if app_uptime is not None else "-",
        "-",
    ])
    return rows


def memory_summary() -> str:
    """The Mac's free memory and swap in use, as the simulator table's own line.

    Free memory is what admission gates on; swap in use is reported here and
    never refuses a boot, because it drains slowly. A reader that is unavailable
    simply leaves its part out.
    """
    state = read_memory_state()
    parts: list[str] = []
    if state.free_bytes is not None:
        total = f" of {human_size(state.physical_bytes)}" if state.physical_bytes else ""
        parts.append(f"free memory {human_size(state.free_bytes)}{total}")
    if state.swap_used_bytes is not None:
        parts.append(f"swap in use {human_size(state.swap_used_bytes)}")
    return ", ".join(parts)


def print_simulators(arguments: argparse.Namespace, stream: Any = None) -> None:
    """Print every simulator that holds memory: what is booted, whose, how long."""
    stream = sys.stdout if stream is None else stream
    rows = simulator_rows(arguments)
    memory = memory_summary()
    print(
        f"Simulators on this Mac (lane root: {arguments.discovery_root}, "
        f"Development: {arguments.development_state}{'; ' + memory if memory else ''})",
        file=stream,
    )
    widths = [max([len(STATUS_COLUMNS[index])] + [len(row[index]) for row in rows]) for index in range(len(STATUS_COLUMNS))]
    for values in (STATUS_COLUMNS, *rows):
        print("  ".join(value.ljust(widths[index]) for index, value in enumerate(values)).rstrip(), file=stream)


def list_simulators(arguments: argparse.Namespace) -> int:
    print_simulators(arguments)
    return 0


def booted_lane_labels(arguments: argparse.Namespace) -> list[str] | None:
    """The lanes whose owned simulator is booted, or None when they are unknown."""
    if lane_root(arguments) is None:
        return None
    document = inventory()
    labels: list[str] = []
    for label, _, marker in lane_states(arguments):
        if marker is not None and lane_device(document, marker)[1] == "Booted":
            labels.append(label)
    return labels


def admit_boot(arguments: argparse.Namespace) -> None:
    """Refuse to boot another simulator when the Mac is already short of memory.

    Read before `simctl boot`, and never for a lane that is already booted, so a
    reuse costs nothing. Free memory is the gate; swap in use is reported beside
    it and never refuses a boot, because swap drains slowly (the table carries
    both). The refusal is fast - no wait, no retry - and carries the table
    `status --all` prints, because the caller decides whether to wait for the Mac
    to free memory. A reader that is unavailable admits the boot with a warning:
    the tooling must still run where the Mac's reports are not installed.
    """
    state = read_memory_state()
    if state.free_bytes is None:
        print("warning: cannot read the Mac's free memory (memory_pressure); admitting the boot without that check", file=sys.stderr)
    if state.swap_used_bytes is None:
        print("warning: cannot read the Mac's swap in use (sysctl vm.swapusage); the status table will not report it", file=sys.stderr)
    breaches: list[str] = []
    if state.free_bytes is not None and state.free_bytes < arguments.memory_reserve_bytes:
        total = f" of {human_size(state.physical_bytes)}" if state.physical_bytes else ""
        breaches.append(
            f"free memory {human_size(state.free_bytes)}{total} is below the {human_size(arguments.memory_reserve_bytes)} reserve"
        )
    if not breaches:
        return
    detail = "; ".join(breaches)
    booted = booted_lane_labels(arguments)
    if booted is not None and not booted:
        detail += "; no owned lane is booted, so processes other than the iOS test tooling hold this Mac's memory"
    raise MemoryAdmissionError(f"refusing to boot {arguments.name}: {detail}")


def admission_lock_path(arguments: argparse.Namespace) -> Path:
    """The one lock every lane's boot serializes on.

    It lives in the lane root when the caller named one - every production
    caller does - so all lanes under it share one lock; a caller that knows only
    its own state directory still serializes its own boots.
    """
    if arguments.discovery_root is not None:
        return arguments.discovery_root / ADMISSION_LOCK_NAME
    return arguments.marker.parent / ADMISSION_LOCK_NAME


@contextlib.contextmanager
def admission_hold(arguments: argparse.Namespace) -> Iterator[None]:
    """Serialize this Mac's simulator boots, from the memory read to the boot.

    Held until `simctl bootstatus` has returned, so a second start reads the
    memory the first boot has already taken instead of admitting a boot the Mac
    can no longer afford. A boot that cannot take the lock in
    `--admission-wait-seconds` is refused with the same "not now" exit and
    table as a memory refusal, rather than waiting forever on a wedged boot.
    """
    lock = admission_lock_path(arguments)
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open("a+", encoding="utf-8") as handle:
        deadline = time.monotonic() + arguments.admission_wait_seconds
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise MemoryAdmissionError(
                        f"refusing to boot {arguments.name}: another simulator boot has held this Mac's "
                        f"admission lock ({lock}) for {arguments.admission_wait_seconds:g}s"
                    )
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def development_uptime(arguments: argparse.Namespace) -> int:
    """Report how long the remembered Development simulator has been booted.

    `scripts/tron-ios-simulator` owns the Development simulator and reports this
    so a person can see the memory it is holding. Its own boot process proves the
    time, exactly as the simulator table's UPTIME column does, so nothing has to
    cooperate; a simulator that is not booted prints nothing, and an unreadable
    process table warns rather than inventing a time.
    """
    udid = development_udid(arguments)
    if udid is None:
        raise DestinationError(f"no Development simulator is remembered: {arguments.development_state}")
    table = process_table()
    if table is None:
        print(
            "warning: cannot read the process table (ps); the Development simulator's uptime is unknown",
            file=sys.stderr,
        )
        return 0
    elapsed = booted_uptimes(table).get(udid)
    if elapsed is not None:
        print(human_duration(elapsed))
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
    """Reclaim every orphaned lane, expired lane and stale artifact. Idempotent."""
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
    # Disk is the other half of what a command leaves behind, so the sweep that
    # reclaims memory reclaims it too: every provisioning command and `reap`
    # pass the runner's roots and prune through the same paths as `prune`.
    failures += prune_artifacts(arguments)
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
    configured directory - so nothing but a lane can be removed here. A
    directory that holds another lane's marker is that lane's ancestor (the lane
    root itself, or a state directory above it), and removing it would take the
    other lane's simulator state with it, so it is refused too.
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
    nested = [path for path in marker_paths(directory) if path != marker_path]
    if nested:
        raise DestinationError(
            f"refusing to remove a lane directory that contains another lane's ownership marker: "
            f"{directory} holds {nested[0]}"
        )
    delete_owned(marker_path, arguments)
    shutil.rmtree(directory)


def expire_lane(arguments: argparse.Namespace, marker_path: Path) -> str:
    """Remove a lane unused for longer than the TTL.

    Returns "expired", or why not: "fresh", "undated", "no-marker", "busy" (a
    live process holds the lease), "skipped" (an unreadable marker or an unsafe
    directory) or "failed". A lane the file system refuses to remove is reported
    as "failed" and the sweep carries on with the other lanes: removal races a
    command that is provisioning the same lane, and the sweep must survive it.
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
        except (DestinationError, OSError) as error:
            # OSError covers the file system racing this removal: a directory or
            # file that vanished, or a state directory the sweep cannot delete.
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
            raise LaneBusyError(f"lane {label} is leased ({lease_holder(directory / LEASE_NAME, held=True)})")
        remove_lane(directory, arguments)
    print(f"removed lane {lane_label(directory, arguments.default_state_dir)} ({directory})")
    return 0


def owned_root(path: Path) -> bool:
    """Whether the runner's ownership marker proves a directory is the tooling's."""
    marker = path / OWNERSHIP_MARKER_NAME
    return marker.is_file() and not marker.is_symlink()


def run_started(run: Path, owner: dict[str, Any] | None) -> float:
    """When a run began: its owner file, else its UTC-named directory, else mtime."""
    if owner is not None:
        started = owner.get("started_epoch_seconds")
        if isinstance(started, (int, float)) and not isinstance(started, bool):
            return float(started)
    match = RUN_NAME_PATTERN.match(run.name)
    if match is not None:
        try:
            return float(calendar.timegm(time.strptime(match.group(1), "%Y%m%dT%H%M%SZ")))
        except ValueError:
            pass
    try:
        return run.stat().st_mtime
    except OSError:
        # An unreadable timestamp must not age a run into deletion.
        return time.time()


def run_attribution(run: Path) -> tuple[str | None, str, float]:
    """(worktree, lane, start) for one run directory.

    `owner.json` is written when the runner creates the run directory, so a run
    killed before its first metadata is still attributable. `metadata.json`,
    written after each phase, names the building worktree under
    `source.worktree`; runs from before `owner.json` existed carry only that, and
    they predate named lanes, so they belong to the default lane.
    """
    owner = load_json(run / RUN_OWNER_NAME)
    worktree = owner.get("worktree") if owner is not None else None
    lane = owner.get("lane") if owner is not None else None
    if not isinstance(worktree, str) or not worktree:
        metadata = load_json(run / RUN_METADATA_NAME)
        source = metadata.get("source") if metadata is not None else None
        worktree = source.get("worktree") if isinstance(source, dict) else None
        if lane is None:
            lane = "default"
    return (
        worktree if isinstance(worktree, str) and worktree else None,
        lane if isinstance(lane, str) and lane else "default",
        run_started(run, owner),
    )


def remove_dangling_latest(root: Path) -> None:
    latest = root / "latest"
    if latest.is_symlink() and not latest.exists():
        latest.unlink()
        print(f"removed the dangling results symlink {latest}")


def prune_runs(root: Path) -> int:
    """Keep the newest 50 runs of each worktree and everything under 7 days.

    Returns the number of runs that could not be removed. A root without the
    runner's ownership marker is never pruned: runs live in a shared results
    root, and a caller's wrong root must not cost it data.
    """
    if not root.exists():
        return 0
    if not owned_root(root):
        print(f"warning: not pruning runs in a directory without the runner's ownership marker: {root}", file=sys.stderr)
        return 0
    groups: dict[str, list[tuple[float, Path]]] = {}
    for run in sorted(root.iterdir()):
        if run.is_symlink() or not run.is_dir():
            continue
        worktree, _, started = run_attribution(run)
        groups.setdefault(worktree if worktree is not None else UNKNOWN_WORKTREE, []).append((started, run))
    now = time.time()
    failures = 0
    for worktree, runs in sorted(groups.items()):
        runs.sort(key=lambda entry: entry[0], reverse=True)
        for index, (started, run) in enumerate(runs):
            if index < RUNS_KEPT_PER_WORKTREE or now - started < RUN_TTL_SECONDS:
                continue
            try:
                shutil.rmtree(run)
            except OSError as error:
                print(f"warning: could not remove the result run {run}: {error}", file=sys.stderr)
                failures += 1
                continue
            print(
                f"removed result run {run.name} of {worktree} "
                f"({human_duration(int(now - started))} old, beyond the newest {RUNS_KEPT_PER_WORKTREE})"
            )
    remove_dangling_latest(root)
    return failures


def prune_products(root: Path) -> int:
    """Delete the test products of worktrees that no longer exist.

    The products root holds one directory per worktree, each proved by the
    runner's ownership marker and stamped after its last successful build; only
    a stamp naming a worktree path that is gone proves the products have no
    owner left, so a directory without a readable stamp is kept. Returns the
    number of directories that could not be removed.
    """
    if not root.exists():
        return 0
    failures = 0
    for directory in sorted(root.iterdir()):
        if directory.is_symlink() or not directory.is_dir() or not owned_root(directory):
            continue
        stamp = load_json(directory / BUILD_IDENTITY_NAME)
        worktree = stamp.get("worktree") if stamp is not None else None
        if not isinstance(worktree, str) or not worktree or Path(worktree).exists():
            continue
        try:
            shutil.rmtree(directory)
        except OSError as error:
            print(f"warning: could not remove the test products {directory}: {error}", file=sys.stderr)
            failures += 1
            continue
        print(f"removed the test products of the deleted worktree {worktree}: {directory}")
    return failures


def prune_artifacts(arguments: argparse.Namespace) -> int:
    """Reclaim the runs and products a finished or killed command left behind."""
    failures = 0
    if arguments.results_root is not None:
        failures += prune_runs(arguments.results_root)
    if arguments.products_root is not None:
        failures += prune_products(arguments.products_root)
    return failures


def prune_command(arguments: argparse.Namespace) -> int:
    return DESTINATION_EXIT if prune_artifacts(arguments) else 0


def clean_runs(arguments: argparse.Namespace) -> int:
    """Delete only this worktree's and lane's runs from the shared results root.

    `clean` runs while the command holds this lane's lease, so no command can be
    creating a run in this lane as its runs are removed, and a run of another
    lane or another worktree is never touched.
    """
    root = arguments.results_root
    if not root.exists():
        return 0
    if not owned_root(root):
        raise DestinationError(f"refusing to remove runs in a directory without the runner's ownership marker: {root}")
    worktree = os.path.realpath(arguments.worktree)
    removed = 0
    for run in sorted(root.iterdir()):
        if run.is_symlink() or not run.is_dir():
            continue
        owner, lane, _ = run_attribution(run)
        if owner is None or os.path.realpath(owner) != worktree or lane != arguments.lane:
            continue
        try:
            shutil.rmtree(run)
        except OSError as error:
            raise DestinationError(f"could not remove the result run {run}: {error}") from error
        removed += 1
    remove_dangling_latest(root)
    print(f"removed {removed} result run(s) of {worktree} in lane {arguments.lane}")
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
        # The memory read, the boot and its `bootstatus` all hold the one
        # machine-wide admission lock, so concurrent starts see each other's
        # boots instead of each admitting memory the other has taken.
        with admission_hold(arguments):
            admit_boot(arguments)
            simctl("boot", marker["udid"], timeout=BOOT_TIMEOUT_SECONDS)
            simctl("bootstatus", marker["udid"], "-b", timeout=BOOT_TIMEOUT_SECONDS)
    else:
        simctl("bootstatus", marker["udid"], "-b", timeout=BOOT_TIMEOUT_SECONDS)
    document = inventory()
    device = validate_marker(document, marker, runtime, device_type, dev_udid)
    return {**marker, "state": device.get("state"), "udid_sha256": hashlib.sha256(marker["udid"].encode()).hexdigest()}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=(
            "provision", "validate", "status", "delete", "state", "shutdown", "sweep", "lane", "lanes",
            "lane-remove", "simulators", "prune", "clean-runs", "development-uptime",
        ),
    )
    parser.add_argument("--marker", type=Path)
    parser.add_argument("--runtime")
    parser.add_argument("--device-type")
    parser.add_argument("--name")
    parser.add_argument("--worktree", type=Path)
    parser.add_argument("--lane")
    parser.add_argument("--results-root", type=Path)
    parser.add_argument("--products-root", type=Path)
    parser.add_argument("--development-state", type=Path)
    parser.add_argument("--ephemeral", action="store_true")
    parser.add_argument("--discovery-root", type=Path)
    parser.add_argument("--default-state-dir", type=Path)
    parser.add_argument("--lane-dir", type=Path)
    parser.add_argument("--memory-reserve-bytes", type=int)
    parser.add_argument(
        "--admission-wait-seconds",
        type=float,
        default=float(os.environ.get("TRON_IOS_TEST_ADMISSION_WAIT_SECONDS", "300")),
    )
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
    if arguments.command == "lane":
        # Selection only: it reads no simulator, so it needs no Development state.
        if arguments.worktree is None:
            parser.error("lane requires --worktree")
        return arguments
    if arguments.development_state is None:
        parser.error("the following arguments are required: --development-state")
    if arguments.shutdown_timeout_seconds <= 0 or arguments.sweep_deadline_seconds <= 0:
        parser.error("deadlines must be positive")
    if arguments.admission_wait_seconds <= 0:
        parser.error("the admission wait must be positive")
    try:
        if arguments.memory_reserve_bytes is None:
            arguments.memory_reserve_bytes = int(os.environ.get("TRON_IOS_TEST_MEMORY_RESERVE_BYTES", MEMORY_RESERVE_BYTES))
    except ValueError:
        parser.error("the memory reserve must be a whole number of bytes")
    if arguments.memory_reserve_bytes < 0:
        parser.error("the memory reserve must not be negative")
    if arguments.command in ("sweep", "lanes", "simulators"):
        if arguments.discovery_root is None:
            parser.error(f"{arguments.command} requires --discovery-root")
        if arguments.marker is not None:
            parser.error(f"{arguments.command} does not take --marker")
        if arguments.command in ("lanes", "simulators") and arguments.default_state_dir is None:
            parser.error(f"{arguments.command} requires --default-state-dir")
        return arguments
    if arguments.command == "lane-remove":
        for required in ("lane_dir", "discovery_root", "default_state_dir"):
            if getattr(arguments, required) is None:
                parser.error(f"lane-remove requires --{required.replace('_', '-')}")
        if arguments.marker is not None:
            parser.error("lane-remove does not take --marker")
        return arguments
    if arguments.command == "development-uptime":
        if arguments.marker is not None:
            parser.error("development-uptime does not take --marker")
        return arguments
    if arguments.command == "prune":
        if arguments.results_root is None and arguments.products_root is None:
            parser.error("prune requires --results-root or --products-root")
        if arguments.marker is not None:
            parser.error("prune does not take --marker")
        return arguments
    if arguments.command == "clean-runs":
        for required in ("results_root", "worktree", "lane"):
            if getattr(arguments, required) is None:
                parser.error(f"clean-runs requires --{required.replace('_', '-')}")
        if arguments.marker is not None:
            parser.error("clean-runs does not take --marker")
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
        if arguments.command == "lane":
            return print_lane(arguments)
        if arguments.command == "sweep":
            return sweep(arguments)
        if arguments.command == "lanes":
            return list_lanes(arguments)
        if arguments.command == "simulators":
            return list_simulators(arguments)
        if arguments.command == "lane-remove":
            return remove_lane_command(arguments)
        if arguments.command == "prune":
            return prune_command(arguments)
        if arguments.command == "clean-runs":
            return clean_runs(arguments)
        if arguments.command == "development-uptime":
            return development_uptime(arguments)
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
    except LaneSelectionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except LaneBusyError as error:
        print(f"error: {error}", file=sys.stderr)
        return BUSY_EXIT
    except MemoryAdmissionError as error:
        # The caller decides whether to wait for memory, so the refusal is fast
        # and shows the same picture `status --all` prints.
        print(f"error: {error}", file=sys.stderr)
        try:
            print_simulators(arguments, sys.stderr)
        except DestinationError as listing_error:
            print(f"warning: could not list this Mac's simulators: {listing_error}", file=sys.stderr)
        return BUSY_EXIT
    except DestinationError as error:
        print(f"error: {error}", file=sys.stderr)
        return DESTINATION_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
