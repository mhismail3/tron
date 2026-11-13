"""Proves target-home quiescence through runtime, wrapper and kernel process owners."""

from __future__ import annotations

import contextlib
import ctypes
import errno
import fcntl
import os
import stat
import subprocess
import sys
from pathlib import Path


class Flock(ctypes.Structure):
    _fields_ = [("start", ctypes.c_longlong), ("length", ctypes.c_longlong), ("pid", ctypes.c_int),
                ("type", ctypes.c_short), ("whence", ctypes.c_short)]


def within(value, home):
    return value == home or value.startswith(home + "/")


def process_owner(home):
    if sys.platform != "darwin":
        raise OSError("stopped_proof_unavailable")
    libc = ctypes.CDLL(None, use_errno=True)
    proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    count = proc.proc_listpids(4, os.geteuid(), None, 0)
    if count <= 0 or count > 4 * 100000:
        raise OSError("process_inventory_unavailable")
    pids = (ctypes.c_int * (count // 4 + 1024))()
    used = proc.proc_listpids(4, os.geteuid(), pids, ctypes.sizeof(pids))
    if used <= 0 or used >= ctypes.sizeof(pids):
        raise OSError("process_inventory_unavailable")
    for pid in pids[:used // 4]:
        if pid <= 0 or pid == os.getpid():
            continue
        mib = (ctypes.c_int * 3)(1, 49, pid)
        buffer = ctypes.create_string_buffer(2 * 1024 * 1024)
        size = ctypes.c_size_t(len(buffer))
        if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
            if ctypes.get_errno() == errno.ESRCH:
                continue
            raise OSError(ctypes.get_errno(), "process_owner_unreadable", str(pid))
        data = buffer.raw[:size.value]
        if len(data) < 4:
            raise OSError("process_owner_unreadable")
        argc = int.from_bytes(data[:4], sys.byteorder, signed=True)
        executable, separator, tail = data[4:].partition(b"\0")
        fields = tail.lstrip(b"\0").split(b"\0")
        if not separator or argc < 0 or argc > len(fields):
            raise OSError("process_owner_unreadable")
        args = [os.fsdecode(value) for value in fields[:argc]]
        env = dict(os.fsdecode(value).split("=", 1) for value in fields[argc:] if b"=" in value)
        bindings = [env.get(key, "") for key in ("TRON_DATA_DIR", "PI_CODING_AGENT_DIR", "PI_SUBAGENTS_TEMP_ROOT", "PI_SUBAGENT_RUNNER_CONFIG")]
        bindings += [value.split("=", 1)[-1] if value.startswith("--") else value for value in args]
        runtime = any("/Gateway/" in value or "/gateway/" in value or "pi-coding-agent" in value or "subagent-runner" in value or "/Contents/MacOS/Tron" in value for value in args)
        if runtime:
            bindings.append(os.path.join(env.get("HOME", ""), env.get("TRON_HOME_NAME", ".tron")))
        if any(value.startswith("/") and within(os.path.abspath(value), home) for value in bindings):
            return pid
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-u", str(os.geteuid()), "-Fpn"], capture_output=True, timeout=30)
    if result.returncode or result.stderr or len(result.stdout) > 64 * 1024 * 1024:
        raise OSError("open_file_owners_unavailable")
    pid = None
    for line in result.stdout.splitlines():
        if line.startswith(b"p"):
            pid = int(line[1:])
        elif pid != os.getpid() and line.startswith(b"n") and within(os.fsdecode(line[1:]), home):
            return pid
    return None


def wrapper_paths(l, home):
    paths = set()
    for relative in ("gateway/mac", "state/mac"):
        directory = Path(home) / relative
        if l.observed(str(directory)) is None:
            continue
        fd = l.open_home(str(directory))
        try:
            with os.scandir(fd) as entries:
                paths.update(directory / entry.name for entry in entries if entry.name.startswith(".mac-wrapper.") and entry.name.endswith(".lock"))
        finally:
            os.close(fd)
    return sorted(paths)


def wrapper_fd(l, path):
    if l.linked_component(str(path), "/"):
        raise l.LayoutError("unsafe_mac_wrapper_lock")
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        os.close(fd)
        raise l.LayoutError("unsafe_mac_wrapper_lock")
    return fd


def probe(l, home, owned=None):
    for path in wrapper_paths(l, home):
        info = os.lstat(path)
        if owned is not None and (info.st_dev, info.st_ino) in owned:
            continue
        fd = wrapper_fd(l, path)
        try:
            query = Flock(0, 0, 0, fcntl.F_WRLCK, os.SEEK_SET)
            answer = Flock.from_buffer_copy(fcntl.fcntl(fd, fcntl.F_GETLK, bytes(query)))
            if answer.type != fcntl.F_UNLCK:
                return "mac_wrapper_running"
        finally:
            os.close(fd)
    try:
        if process_owner(home) is not None:
            return "home_process_present"
    except (OSError, ValueError, subprocess.SubprocessError):
        return "stopped_proof_unavailable"
    return None


@contextlib.contextmanager
def claim(l, home):
    owned = set()
    descriptors = []
    try:
        directory = Path(home) / ("gateway/mac" if (Path(home) / "gateway").is_dir() else "state/mac")
        l.private_directory(directory)
        paths = set(wrapper_paths(l, home)) | {directory / f".mac-wrapper.{name}.lock" for name in ("com.tron.mac", "com.tron.mac.dev", "unknown")}
        for path in sorted(paths):
            if l.observed(str(path)) is None:
                fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            else:
                fd = wrapper_fd(l, path)
            descriptors.append(fd)
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise l.LayoutError("mac_wrapper_running") from None
            info = os.fstat(fd)
            owned.add((info.st_dev, info.st_ino))
        yield owned
    finally:
        for fd in reversed(descriptors):
            os.close(fd)
