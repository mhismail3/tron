#!/usr/bin/env python3
"""One kernel lease for the Mac replacement and physical iOS rebuild trees.

Descriptors, not markers, own exclusion. Children inherit the same open-file
lock, so killing a detached parent cannot admit a competing cutover while its
converter or verifier still runs.
"""
import fcntl
import os
from pathlib import Path
import subprocess
import stat
import sys


class RebuildBusy(RuntimeError):
    pass


def inherited_fd():
    value = os.environ.get('TRON_REBUILD_LOCK_FD')
    if value is None:
        return None
    fd = int(value)
    path = Path(os.environ['TRON_REBUILD_LOCK_PATH'])
    info, named = os.fstat(fd), path.lstat()
    if (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino) or path.is_symlink():
        raise RebuildBusy('inherited Mac/iOS rebuild lease does not match its file')
    # A pathname/environment value alone is not inherited ownership.
    probe = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RebuildBusy('inherited descriptor does not own the Mac/iOS rebuild lease') from None
            return fd
        raise RebuildBusy('inherited Mac/iOS rebuild lease is not held')
    finally:
        os.close(probe)


class RebuildLock:
    def __init__(self, path):
        self.path = Path(path)
        self.fd = None

    def __enter__(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(self.fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            os.close(self.fd)
            self.fd = None
            raise RebuildBusy('Mac/iOS rebuild lease must be a private owner-only regular file')
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.fd)
            self.fd = None
            raise RebuildBusy('Another Mac/iOS rebuild still owns the rebuild lease; no second cutover or install started') from None
        return self.fd

    def __exit__(self, *args):
        if self.fd is not None:
            os.close(self.fd)


if __name__ == '__main__':
    try:
        path = Path(sys.argv[1])
        if sys.argv[2:] == ['--verify-inherited']:
            fd = inherited_fd()
            if fd is None or Path(os.environ['TRON_REBUILD_LOCK_PATH']) != path:
                raise RebuildBusy('physical iOS rebuild lacks its inherited Mac/iOS lease')
        else:
            with RebuildLock(path) as fd:
                result = subprocess.run(sys.argv[2:], pass_fds=(fd,), env=dict(os.environ,
                    TRON_REBUILD_LOCK_FD=str(fd), TRON_REBUILD_LOCK_PATH=str(path)))
                sys.exit(result.returncode)
    except (RebuildBusy, OSError, ValueError, KeyError) as error:
        print(f'STOP: {error}', file=sys.stderr)
        sys.exit(73)
