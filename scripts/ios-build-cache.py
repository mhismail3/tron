#!/usr/bin/env python3
"""Share iOS compilation work across worktrees through Xcode's compilation cache.

Every iOS build script runs xcodebuild through `run`. Xcode's content-addressed
compilation cache (CAS) replays a compile only when its key matches: the
compiler version, the exact command line and the contents of every input file.
A changed source, setting, SDK or toolchain therefore misses and compiles; the
cache cannot return output for different inputs.

The key also contains absolute paths: the DerivedData directory (search paths,
module cache, outputs) and each source file. Prefix mapping cannot hide them in
this project (Xcode's AppIntents metadata step rejects mapped package source
paths, #1077), so instead each build runs at one of a few stable *slot* paths:
the worktree's own DerivedData is renamed to `slots/<n>/DerivedData` for the
build and renamed back afterwards. Swift package checkouts live inside
DerivedData, so every worktree compiles them at the same path and replays them
from the shared cache; the worktree's own sources keep their worktree paths,
so they hit only within that worktree. Mapping the worktree path too would make
compiler diagnostics and `#filePath` (which UI tests read) name the mapped path,
so it is not done. `-file-compilation-dir .` and `-fcoverage-compilation-dir=.`
keep the project directory out of the keys (they only set the debug-info and
coverage compilation directory; source paths stay absolute).

Ownership and safety:
- The cache partition is keyed by the selected Xcode and Swift compiler, so a
  toolchain change starts a new partition; stale partitions are deleted once no
  build holds them.
- Builds hold a shared lock on their partition; eviction (over the size bound,
  stale toolchain, corruption) needs the exclusive lock, so it never deletes a
  cache a build is using. Concurrent builds share the on-disk CAS, which LLVM
  designs for concurrent multi-process use.
- A slot is held by an exclusive lock for the whole build. A build killed before
  it renamed its DerivedData back leaves an owner record; the next holder of
  that slot (or the owner's next build) moves it home.
- A corrupt cache is validated before each build. It is discarded loudly when
  no build is using it, otherwise the build runs without the cache. A build that
  fails and leaves the cache invalid is retried once without the cache.

Set TRON_IOS_BUILD_CACHE=0 to build without the shared cache.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import IO, Optional

PREFIX = "ios-build-cache"
DEFAULT_ROOT = Path.home() / "Library/Developer/Tron/ios/build-cache"
DEFAULT_LIMIT_GB = 12
DEFAULT_SLOTS = 3
HIT = re.compile(rb"note: replay(ed)? cache hit", re.IGNORECASE)
MISS = re.compile(rb"note: (replay cache miss|cache miss:)", re.IGNORECASE)


def say(message: str) -> None:
    print(f"{PREFIX}: {message}", file=sys.stderr, flush=True)


def cache_root() -> Path:
    return Path(os.environ.get("TRON_IOS_BUILD_CACHE_DIR") or DEFAULT_ROOT)


def limit_bytes() -> int:
    return int(float(os.environ.get("TRON_IOS_BUILD_CACHE_LIMIT_GB", DEFAULT_LIMIT_GB)) * 1024**3)


def slot_count() -> int:
    return max(0, int(os.environ.get("TRON_IOS_BUILD_CACHE_SLOTS", DEFAULT_SLOTS)))


def toolchain_key() -> str:
    """The selected Xcode, its build and the Swift compiler identify one partition."""
    developer = subprocess.run(["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip()
    xcode = subprocess.run(["xcodebuild", "-version"], check=True, capture_output=True, text=True).stdout.strip()
    swift = subprocess.run(["xcrun", "swiftc", "--version"], check=True, capture_output=True, text=True).stdout.strip()
    digest = hashlib.sha256("\0".join((os.path.realpath(developer), xcode, swift)).encode()).hexdigest()[:16]
    build = xcode.splitlines()[-1].split()[-1] if xcode else "unknown"
    return f"xcode-{build}-{digest}"


def tree_bytes(path: Path) -> int:
    """Allocated bytes: the CAS preallocates sparse files far larger than their data."""
    total = 0
    for directory, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(directory, name)).st_blocks * 512
            except OSError:
                pass
    return total


def open_lock(path: Path) -> IO[str]:
    path.parent.mkdir(parents=True, exist_ok=True)
    return open(path, "a+")


def try_lock(handle: IO[str], mode: int) -> bool:
    try:
        fcntl.flock(handle, mode | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def remove_tree(path: Path) -> None:
    """Rename first so a partially deleted tree is never mistaken for a live one."""
    if not path.exists():
        return
    doomed = path.with_name(f".{path.name}.deleting-{os.getpid()}-{time.time_ns()}")
    os.rename(path, doomed)
    shutil.rmtree(doomed, ignore_errors=True)


class Partition:
    def __init__(self, root: Path, key: str) -> None:
        self.root = root
        self.key = key
        self.path = root / "cas" / key
        self.lock = open_lock(root / "cas" / f"{key}.lock")

    def validate(self) -> tuple[bool, str]:
        store = self.path / "builtin"
        if not store.exists():
            return True, "empty"
        result = subprocess.run(["xcrun", "llvm-cas", f"--cas={store}", "--validate"],
                                capture_output=True, text=True)
        return result.returncode == 0, (result.stdout + result.stderr).strip()


def evict_stale_partitions(root: Path, current: str) -> None:
    cas = root / "cas"
    if not cas.is_dir():
        return
    for entry in sorted(cas.iterdir()):
        if entry.name.startswith(".") and ".deleting-" in entry.name:
            shutil.rmtree(entry, ignore_errors=True)
            continue
        if not entry.is_dir() or entry.name == current:
            continue
        lock = open_lock(cas / f"{entry.name}.lock")
        try:
            if try_lock(lock, fcntl.LOCK_EX):
                say(f"removing the cache of another toolchain: {entry} ({tree_bytes(entry) // 1024**2} MB)")
                remove_tree(entry)
        finally:
            lock.close()


class Slot:
    """One stable build path. Held exclusively for the whole build."""

    def __init__(self, root: Path, index: int) -> None:
        self.index = index
        self.dir = root / "slots" / str(index)
        self.derived_data = self.dir / "DerivedData"
        self.owner = self.dir / "owner.json"
        self.lock = open_lock(root / "slots" / f"{index}.lock")

    def recover(self) -> None:
        """Called with the slot lock held: no build is using what is parked here."""
        if not self.derived_data.exists():
            self.owner.unlink(missing_ok=True)
            return
        try:
            home = Path(json.loads(self.owner.read_text())["derived_data"])
        except (OSError, ValueError, KeyError, TypeError):
            home = None
        if home is not None and not home.exists() and home.parent.is_dir():
            say(f"slot {self.index}: returning DerivedData left by an interrupted build to {home}")
            os.rename(self.derived_data, home)
        else:
            say(f"slot {self.index}: discarding DerivedData left by an interrupted build (owner {home})")
            remove_tree(self.derived_data)
        self.owner.unlink(missing_ok=True)


def same_volume(a: Path, b: Path) -> bool:
    return os.stat(a).st_dev == os.stat(b).st_dev


def acquire_slot(root: Path, derived_data: Path) -> Optional[Slot]:
    count = slot_count()
    if count == 0:
        return None
    (root / "slots").mkdir(parents=True, exist_ok=True)
    if not same_volume(root / "slots", derived_data.parent):
        say(f"{derived_data} is on another volume than {root}; building in place (worktree-local cache hits only)")
        return None
    sticky = derived_data.parent / f".{derived_data.name}.slot"
    try:
        preferred = int(sticky.read_text().strip())
    except (OSError, ValueError):
        preferred = 0
    order = [preferred] + [i for i in range(count) if i != preferred] if preferred < count else list(range(count))
    for index in order:
        slot = Slot(root, index)
        if try_lock(slot.lock, fcntl.LOCK_EX):
            slot.recover()
            slot.dir.mkdir(parents=True, exist_ok=True)
            slot.owner.write_text(json.dumps({"derived_data": str(derived_data), "pid": os.getpid()}) + "\n")
            derived_data.mkdir(parents=True, exist_ok=True)
            os.rename(derived_data, slot.derived_data)
            sticky.write_text(f"{index}\n")
            return slot
        slot.lock.close()
    say(f"all {count} build slots are busy; building in place (worktree-local cache hits only)")
    return None


def release_slot(slot: Slot, derived_data: Path) -> None:
    if slot.derived_data.exists():
        if derived_data.exists():
            # Nothing else may create it while the DerivedData lock is held.
            raise SystemExit(f"{PREFIX}: {derived_data} reappeared during the build; slot {slot.index} kept for recovery")
        os.rename(slot.derived_data, derived_data)
    slot.owner.unlink(missing_ok=True)
    slot.lock.close()


def recover_own_derived_data(root: Path, derived_data: Path) -> None:
    """The owner's next build reclaims DerivedData an interrupted build left in a free slot."""
    slots = root / "slots"
    if derived_data.exists() or not slots.is_dir():
        return
    for index in range(slot_count()):
        slot = Slot(root, index)
        try:
            if slot.owner.exists() and try_lock(slot.lock, fcntl.LOCK_EX):
                slot.recover()
        finally:
            slot.lock.close()


def build_services(parent: int) -> set[int]:
    """xcodebuild's build-service children (another process group)."""
    result = subprocess.run(["pgrep", "-P", str(parent)], capture_output=True, text=True)
    return {pid for pid in map(int, result.stdout.split()) if is_build_service(pid)}


def is_build_service(pid: int) -> bool:
    # Checked by name every time, so a reused pid is never awaited or killed.
    result = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
    return "BuildService" in result.stdout


def run_xcodebuild(argv: list[str], counts: dict[str, int]) -> int:
    """Stream xcodebuild's stdout through unchanged while counting cache remarks.

    xcodebuild runs its build service in a separate process group, and an
    interrupted service keeps writing into DerivedData after xcodebuild exits.
    The DerivedData must not move (or its slot be reused) while it does, so the
    service's pid is recorded during the build and awaited afterwards.
    """
    process = subprocess.Popen(argv, stdout=subprocess.PIPE)
    received: list[int] = []
    services: set[int] = set()
    finished = threading.Event()

    def watch() -> None:
        while not finished.wait(1.0):
            services.update(build_services(process.pid))

    def forward(signum: int, _frame: object) -> None:
        received.append(signum)
        try:
            process.send_signal(signum)
        except ProcessLookupError:
            pass

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    previous = {signum: signal.signal(signum, forward) for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        assert process.stdout is not None
        out = sys.stdout.buffer
        for line in iter(process.stdout.readline, b""):
            out.write(line)
            out.flush()
            # One remark per cached task (Swift, Clang and module builds word
            # them differently); "local cache miss for key" precedes a miss.
            if HIT.search(line):
                counts["hits"] += 1
            elif MISS.search(line):
                counts["misses"] += 1
        status = process.wait()
        finished.set()
        watcher.join()
        deadline = time.monotonic() + 60
        while any(is_build_service(pid) for pid in services) and time.monotonic() < deadline:
            time.sleep(0.2)
        for pid in services:
            if is_build_service(pid):
                say(f"stopping build service {pid}, still running 60s after xcodebuild exited")
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    finally:
        finished.set()
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    if received:
        return 128 + received[0]
    return status


def build(derived_data: Path, xcodebuild: list[str]) -> int:
    if os.environ.get("TRON_IOS_BUILD_CACHE", "1") == "0":
        say("TRON_IOS_BUILD_CACHE=0: building without the shared compilation cache")
        return run_xcodebuild(xcodebuild + ["-derivedDataPath", str(derived_data)], {"hits": 0, "misses": 0})

    root = cache_root()
    derived_data = Path(os.path.abspath(derived_data))
    derived_data.parent.mkdir(parents=True, exist_ok=True)
    root.mkdir(parents=True, exist_ok=True)
    # One build per DerivedData at a time: its directory moves during the build.
    own = open_lock(derived_data.parent / f".{derived_data.name}.build-lock")
    fcntl.flock(own, fcntl.LOCK_EX)

    key = toolchain_key()
    evict_stale_partitions(root, key)
    partition = Partition(root, key)
    fcntl.flock(partition.lock, fcntl.LOCK_SH)
    use_cache = True
    valid, detail = partition.validate()
    if not valid:
        fcntl.flock(partition.lock, fcntl.LOCK_UN)
        if try_lock(partition.lock, fcntl.LOCK_EX):
            say(f"WARNING: the compilation cache {partition.path} is corrupt ({detail}); discarding it and building cold")
            remove_tree(partition.path)
            fcntl.flock(partition.lock, fcntl.LOCK_SH)
        else:
            say(f"WARNING: the compilation cache {partition.path} is corrupt ({detail}) and in use by another build; "
                "building without the cache")
            fcntl.flock(partition.lock, fcntl.LOCK_SH)
            use_cache = False

    recover_own_derived_data(root, derived_data)
    slot = acquire_slot(root, derived_data) if use_cache else None
    build_path = slot.derived_data if slot else derived_data
    settings = [
        "COMPILATION_CACHE_ENABLE_CACHING=YES",
        f"COMPILATION_CACHE_CAS_PATH={partition.path}",
        "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES",
        # Keep the project directory out of every Swift and Clang cache key;
        # debug info still records absolute source paths.
        "OTHER_SWIFT_FLAGS=$(inherited) -file-compilation-dir .",
        "OTHER_CFLAGS=$(inherited) -fcoverage-compilation-dir=.",
    ] if use_cache else []
    counts = {"hits": 0, "misses": 0}
    started = time.monotonic()
    try:
        status = run_xcodebuild(xcodebuild + ["-derivedDataPath", str(build_path)] + settings, counts)
    finally:
        if slot:
            release_slot(slot, derived_data)

    if use_cache and status != 0 and status < 128:
        valid, detail = partition.validate()
        if not valid:
            say(f"WARNING: the build failed and the compilation cache is corrupt ({detail}); "
                "retrying once without the cache")
            status = run_xcodebuild(xcodebuild + ["-derivedDataPath", str(derived_data)], {"hits": 0, "misses": 0})
            fcntl.flock(partition.lock, fcntl.LOCK_UN)
            if try_lock(partition.lock, fcntl.LOCK_EX):
                remove_tree(partition.path)
                say(f"discarded the corrupt compilation cache {partition.path}")
            return status

    size = tree_bytes(partition.path) if partition.path.exists() else 0
    if use_cache:
        where = f"slot {slot.index}" if slot else "in place"
        say(f"{counts['hits']} cache hits, {counts['misses']} misses ({where}, {time.monotonic() - started:.0f}s); "
            f"cache {partition.path} {size / 1024**3:.2f} GB of {limit_bytes() / 1024**3:.0f} GB")
    if size > limit_bytes():
        fcntl.flock(partition.lock, fcntl.LOCK_UN)
        if try_lock(partition.lock, fcntl.LOCK_EX):
            say(f"the compilation cache exceeds its bound; removing {partition.path}")
            remove_tree(partition.path)
    return status


def status_command() -> int:
    root = cache_root()
    print(f"root: {root}")
    cas = root / "cas"
    for entry in sorted(cas.iterdir()) if cas.is_dir() else []:
        if entry.is_dir():
            print(f"cache {entry.name}: {tree_bytes(entry) / 1024**3:.2f} GB")
    print(f"limit: {limit_bytes() / 1024**3:.0f} GB per toolchain")
    for index in range(slot_count()):
        slot = Slot(root, index)
        busy = not try_lock(slot.lock, fcntl.LOCK_EX)
        owner = slot.owner.read_text().strip() if slot.owner.exists() else "-"
        print(f"slot {index}: {'building' if busy else 'free'} {owner}")
        slot.lock.close()
    return 0


def clean_command() -> int:
    """Remove every cache partition no build is using."""
    cas = cache_root() / "cas"
    kept = 0
    for entry in sorted(cas.iterdir()) if cas.is_dir() else []:
        if not entry.is_dir():
            continue
        lock = open_lock(cas / f"{entry.name}.lock")
        if try_lock(lock, fcntl.LOCK_EX):
            remove_tree(entry)
            print(f"removed {entry}")
        else:
            kept += 1
            print(f"kept {entry}: a build is using it")
        lock.close()
    return 1 if kept else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run `-- xcodebuild ... -derivedDataPath PATH ...` through the shared cache")
    run.add_argument("xcodebuild", nargs=argparse.REMAINDER)
    commands.add_parser("status", help="print the cache partitions and build slots")
    commands.add_parser("clean", help="remove every cache partition no build is using")
    args = parser.parse_args()
    if args.command == "run":
        argv = args.xcodebuild[1:] if args.xcodebuild[:1] == ["--"] else args.xcodebuild
        positions = [i for i, value in enumerate(argv) if value == "-derivedDataPath"]
        if argv[:1] != ["xcodebuild"] or len(positions) != 1 or positions[0] + 1 >= len(argv):
            parser.error("pass `-- xcodebuild ...` with exactly one -derivedDataPath PATH")
        index = positions[0]
        return build(Path(argv[index + 1]), argv[:index] + argv[index + 2:])
    return status_command() if args.command == "status" else clean_command()


if __name__ == "__main__":
    sys.exit(main())
