#!/usr/bin/env python3
"""Own a source-hashed native test artifact, compiler group and reader lease."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading


class CallerGone(Exception):
    pass


def cancelled(_signal, _frame):
    for name in (signal.SIGUSR1, signal.SIGTERM, signal.SIGINT):
        signal.signal(name, signal.SIG_IGN)
    raise CallerGone()


def watch_caller():
    sys.stdin.buffer.read(1)
    os.kill(os.getpid(), signal.SIGUSR1)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError('Unsafe native fixture cache file')
        return os.fdopen(descriptor, 'rb')
    except BaseException:
        os.close(descriptor); raise


def binary_digest(path):
    with safe_file(path) as source:
        before = os.fstat(source.fileno())
        if before.st_size > 32 * 1024 * 1024: raise ValueError('Native fixture exceeds bounds')
        result = hashlib.sha256(); total = 0
        for chunk in iter(lambda: source.read(65536), b''):
            total += len(chunk)
            if total > 32 * 1024 * 1024: raise ValueError('Native fixture grew beyond bounds')
            result.update(chunk)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('Native fixture changed while hashing')
        return result.hexdigest()


def compile_fixture(repo, stage, headers):
    job = None
    blocked = {signal.SIGUSR1, signal.SIGTERM, signal.SIGINT}
    try:
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        try:
            # Unblock the inherited preparation signals before running the real
            # builder. No preexec callback runs in this threaded parent.
            bootstrap = 'import signal,runpy,sys;signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGUSR1,signal.SIGTERM,signal.SIGINT});script=sys.argv.pop(1);runpy.run_path(script,run_name="__main__")'
            scratch = stage / 'compiler-tmp'; scratch.mkdir(mode=0o700)
            job = subprocess.Popen([sys.executable, '-c', bootstrap, str(repo / 'packages/mac-app/native-gateway-client/build.py'),
                '--output', str(stage / 'tron-native-capture.node'), '--headers', str(headers)],
                stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr, start_new_session=True,
                env={**os.environ, 'TMPDIR': str(scratch)})
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        if job.wait() != 0: raise ValueError('Native fixture compilation failed')
        shutil.rmtree(scratch)
    finally:
        if job is not None and job.returncode is None:
            # Only this unpublished fixture's fresh process group. Its leader
            # remains unreaped, so the group identity cannot be recycled here.
            try: os.killpg(job.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            job.wait()


def serve(repo, cache, headers):
    spec = importlib.util.spec_from_file_location('native_builder', repo / 'packages/mac-app/native-gateway-client/build.py')
    builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
    def source_hash():
        # The production builder alone owns its input list.
        inputs = {name: digest((repo / name).read_bytes()) for name in builder.INPUTS}
        inputs['fixture-owner'] = digest(Path(__file__).read_bytes())
        return digest(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode())
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = cache.lstat()
    if any(path.is_symlink() for path in (cache, *cache.parents)) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Unsafe native fixture cache root')
    lock = os.open(cache / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(lock, 'rb') as owner:
        if not stat.S_ISREG(os.fstat(owner.fileno()).st_mode): raise ValueError('Unsafe native fixture lock')
        # Caller EOF interrupts blocking flock as well as compilation, without
        # polling or leaving a waiting owner to perform stale work later.
        fcntl.flock(owner, fcntl.LOCK_EX)
        key = source_hash(); target = cache / key; binary = target / 'tron-native-capture.node'
        hit = False
        try:
            if target.is_symlink(): raise ValueError('Unsafe native fixture cache entry')
            builder.verify_inputs(binary.with_suffix('.inputs.json'))
            with safe_file(target / 'receipt.json') as receipt_file:
                receipt_bytes = receipt_file.read(1025)
            if len(receipt_bytes) > 1024: raise ValueError('Native fixture receipt exceeds bounds')
            hit = json.loads(receipt_bytes) == {'sourceHash': key, 'binarySha256': binary_digest(binary)}
        except (OSError, ValueError):
            pass
        if not hit:
            if target.exists() or target.is_symlink():
                if target.is_symlink() or not target.is_dir(): raise ValueError('Unsafe native fixture cache entry')
                shutil.rmtree(target)
            stage = Path(tempfile.mkdtemp(prefix='.stage-', dir=cache))
            try:
                compile_fixture(repo, stage, headers)
                if source_hash() != key: raise ValueError('Native fixture source changed during preparation')
                receipt = {'sourceHash': key, 'binarySha256': binary_digest(stage / binary.name)}
                (stage / 'receipt.json').write_text(json.dumps(receipt), encoding='utf8')
                stage.rename(target)  # Exclusive cache lock; never a user directory.
            finally:
                if stage.exists(): shutil.rmtree(stage)
        for old in cache.iterdir():
            if old.name == key or old.name == '.lock': continue
            if old.is_dir() and not old.is_symlink() and (len(old.name) == 64 and all(c in '0123456789abcdef' for c in old.name) or old.name.startswith('.stage-')):
                shutil.rmtree(old)
        print(json.dumps({'artifact': str(binary), 'sourceHash': key, 'cacheHit': hit}), flush=True)
        threading.Event().wait()  # EOF cancels this reader lease; close the kernel lock.


if __name__ == '__main__':
    for name in (signal.SIGUSR1, signal.SIGTERM, signal.SIGINT): signal.signal(name, cancelled)
    try:
        # Only main receives preparation signals. Otherwise process-directed EOF
        # delivery on the watcher can queue a Python handler inside masked Popen.
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1, signal.SIGTERM, signal.SIGINT})
        try: threading.Thread(target=watch_caller, daemon=True).start()
        finally: signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        serve(*(Path(value).absolute() for value in sys.argv[1:]))
    except CallerGone:
        pass
