"""Proves target-home quiescence through runtime, wrapper and kernel process owners."""

from __future__ import annotations

import contextlib
import ctypes
import errno
import fcntl
import os
import select
import stat
import subprocess
import sys
from pathlib import Path


class Flock(ctypes.Structure):
    _fields_ = [("start", ctypes.c_longlong), ("length", ctypes.c_longlong), ("pid", ctypes.c_int),
                ("type", ctypes.c_short), ("whence", ctypes.c_short)]


def within(value, home):
    return value == home or value.startswith(home + "/")


def process_arguments(pid, libc, buffer):
    """The kernel's argument block for `pid`, or None once it has exited. A process between fork and exec (EIO) or
    on its way out (EINVAL) is read again at each exec it makes, until it exits or a second passes without one."""
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t()

    def read():
        size.value = len(buffer)
        return ctypes.get_errno() if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) else 0
    error = read()
    if error and error != errno.ESRCH:
        queue = select.kqueue()
        try:
            events = queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                                  fflags=select.KQ_NOTE_EXEC | select.KQ_NOTE_EXIT)], 4, 0)
            for event in events:
                if event.flags & select.KQ_EV_ERROR and event.data != errno.ESRCH:
                    raise OSError(error, "process_owner_unreadable", str(pid))
            while error not in (0, errno.ESRCH) and not any(event.flags & select.KQ_EV_ERROR or event.fflags & select.KQ_NOTE_EXIT for event in events):
                error = read()
                if error not in (0, errno.ESRCH):
                    events = queue.control(None, 4, 1)
                    if not events:
                        raise OSError(error, "process_owner_unreadable", str(pid))
            if error:
                return None
        except ProcessLookupError:
            return None
        finally:
            queue.close()
    return None if error else buffer.raw[:size.value]


def process_owners(home):
    if sys.platform != "darwin":
        raise OSError("stopped_proof_unavailable")
    libc = ctypes.CDLL(None, use_errno=True)
    proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    argmax = ctypes.c_int()
    length = ctypes.c_size_t(ctypes.sizeof(argmax))
    if libc.sysctlbyname(b"kern.argmax", ctypes.byref(argmax), ctypes.byref(length), None, 0) or not 4096 <= argmax.value <= 8 * 1024 * 1024:
        raise OSError("process_argument_capacity_unavailable")
    buffer = ctypes.create_string_buffer(argmax.value)
    count = proc.proc_listpids(4, os.geteuid(), None, 0)
    if count <= 0 or count > 4 * 100000:
        raise OSError("process_inventory_unavailable")
    owners = set()
    pids = (ctypes.c_int * (count // 4 + 1024))()
    used = proc.proc_listpids(4, os.geteuid(), pids, ctypes.sizeof(pids))
    if used <= 0 or used >= ctypes.sizeof(pids):
        raise OSError("process_inventory_unavailable")
    for pid in pids[:used // 4]:
        if pid <= 0 or pid == os.getpid():
            continue
        data = process_arguments(pid, libc, buffer)
        if data is None:
            continue
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
        if any(value.startswith("/") and within(os.path.realpath(value), home) for value in bindings):
            owners.add(pid)
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-u", str(os.geteuid()), "-Fpn"], capture_output=True, timeout=30)
    if result.returncode or result.stderr or len(result.stdout) > 64 * 1024 * 1024:
        raise OSError("open_file_owners_unavailable")
    pid = None
    for line in result.stdout.splitlines():
        if line.startswith(b"p"):
            pid = int(line[1:])
        elif pid != os.getpid() and line.startswith(b"n") and within(os.fsdecode(line[1:]), home):
            owners.add(pid)
    return owners


def wrapper_paths(l, home):
    paths = set()
    for relative in ("internal/mac", "state/mac"):
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
                return {"reason": "mac_wrapper_running", "pid": answer.pid}
        finally:
            os.close(fd)
    try:
        owners = process_owners(home)
        if owners:
            return {"reason": "home_process_present", "pid": min(owners)}
    except (OSError, ValueError, subprocess.SubprocessError) as failure:
        return {"reason": "stopped_proof_unavailable", "detail": str(failure)}
    return None


@contextlib.contextmanager
def claim(l, home):
    owned = set()
    descriptors = []
    try:
        for path in wrapper_paths(l, home):
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
