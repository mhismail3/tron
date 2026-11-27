#!/usr/bin/env python3
"""Run one `scripts/tron test <lane>` on a configured remote host at this exact commit (tools/verify/README.md#hosts)."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import signal
import subprocess
import sys
import threading
import time

BASE = 'tron-ci'
LANES = ('gateway', 'tooling', 'ios', 'mac')
NO_RESULT = 69


def no_result(reason: str) -> int:
    print(f'host: no result: {reason}', file=sys.stderr, flush=True)
    return NO_RESULT


def local(host: str, arguments: list[str]) -> int:
    if not arguments or arguments[0] not in LANES:
        return no_result(f'name a lane: {", ".join(LANES)}')
    root = Path(__file__).resolve().parents[2]

    def git(*words: str) -> subprocess.CompletedProcess:
        return subprocess.run(['git', '-C', str(root), *words], capture_output=True, text=True)
    destination = git('config', '--get', f'tron.verify.{host}').stdout.strip()
    if not destination:
        return no_result(f'no host {host}; set `git config tron.verify.{host} <user@host>`')
    if git('status', '--porcelain').stdout.strip():
        return no_result('a remote host runs a commit; commit or remove every change first')
    sha = git('rev-parse', 'HEAD').stdout.strip()
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15',
           '-o', 'ServerAliveCountMax=4', destination]
    started = time.monotonic()
    pushed = subprocess.run(['git', '-C', str(root), 'push', '--quiet', f'{destination}:{BASE}/tron.git',
                             f'{sha}:refs/tron-jobs/{sha}'], env={**os.environ, 'GIT_SSH_COMMAND': shlex.join(ssh[:-1]), 'GIT_LFS_SKIP_PUSH': '1'},
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if pushed.returncode:
        return no_result(f'cannot push {sha[:12]} to {destination}:{BASE}/tron.git: {pushed.stdout.strip()}')
    job = json.dumps({'sha': sha, 'lane': arguments[0], 'args': arguments[1:],
                      'requester': {'host': platform.node(), 'worktree': str(root), 'pid': os.getpid()}})
    print(f'host: {arguments[0]} lane on {destination} at {sha[:12]}', flush=True)
    remote = shlex.join(['/usr/bin/python3', '-c', Path(__file__).read_text(), 'remote', job])
    with subprocess.Popen([*ssh, remote], stdin=subprocess.PIPE) as child:
        def stop(_signum, _frame):
            if child.stdin and not child.stdin.closed:
                child.stdin.close()
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, stop)
        code = child.wait()
    if code == 255:
        return no_result(f'the session with {destination} failed')
    print(f'host: {arguments[0]} lane on {destination} at {sha[:12]} exited {code} after {time.monotonic() - started:.0f}s',
          flush=True)
    return code


def remote(job: dict) -> int:
    try:
        return job_run(job)
    finally:
        subprocess.run(['git', '--git-dir', str(Path.home() / BASE / 'tron.git'), 'update-ref', '-d', f'refs/tron-jobs/{job["sha"]}'],
                       capture_output=True)


def job_run(job: dict) -> int:
    sha, lane = job['sha'], job['lane']
    base = Path.home() / BASE
    checkout = base / 'jobs' / lane
    env = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', 'LANG': 'en_US.UTF-8',
           'PYTHONDONTWRITEBYTECODE': '1', 'TRON_CI_TOOLS_DIR': str(base / '.ci-tools'),
           **{key: os.environ[key] for key in ('USER', 'LOGNAME', 'SHELL') if key in os.environ}}
    running: list[subprocess.Popen] = []
    stopped = threading.Event()

    def watch() -> None:
        while os.read(0, 4096):
            pass
        stopped.set()
        for child in running:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    threading.Thread(target=watch, daemon=True).start()

    def run(*command: str) -> subprocess.CompletedProcess:
        return subprocess.run(command, env=env, cwd=base, stdin=subprocess.DEVNULL, capture_output=True, text=True)

    (base / 'jobs').mkdir(parents=True, exist_ok=True)
    with open(base / 'jobs/host.lock', 'a+') as lock:
        announced = 0.0
        while True:
            if stopped.is_set():
                return no_result('stopped while waiting for the host')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() - announced >= 60:
                    lock.seek(0)
                    print(f'host: waiting for the host, held by {lock.read().strip() or "an unrecorded job"}', flush=True)
                    announced = time.monotonic()
                time.sleep(2)
        lock.seek(0)
        lock.truncate()
        lock.write(json.dumps({**job['requester'], 'sha': sha}))
        lock.flush()
        if (checkout / '.git').exists():
            steps = [('git', '-C', str(checkout), 'checkout', '--quiet', '--detach', '--force', sha),
                     ('git', '-C', str(checkout), 'clean', '-ffdxq', '-e', '/packages/gateway/node_modules',
                      '-e', '/packages/mac-app/build', '-e', '/packages/ios-app/TronMobile.xcodeproj')]
        else:
            steps = [('git', '--git-dir', str(base / 'tron.git'), 'worktree', 'prune'),
                     ('git', '--git-dir', str(base / 'tron.git'), 'worktree', 'add', '--quiet', '--detach', str(checkout), sha)]
        for step in steps:
            if stopped.is_set():
                return no_result('stopped while preparing the checkout')
            result = run(*step)
            if result.returncode:
                return no_result(f'{shlex.join(step)} failed: {(result.stdout + result.stderr).strip()}')
        node = run(str(checkout / 'scripts/tron-node')).stdout.strip()
        if not node:
            return no_result(f'no pinned Node; install it there with {checkout}/scripts/tron-node install')
        gateway = checkout / 'packages/gateway'
        inputs = hashlib.sha256((gateway / 'package-lock.json').read_bytes() + node.encode()).hexdigest()
        stamp = gateway / 'node_modules/.tron-host-install'
        if not stamp.is_file() or stamp.read_text() != inputs:
            print('host: Gateway dependencies changed; npm ci', flush=True)
            installed = run(str(checkout / 'scripts/tron-node'), 'exec', 'npm', '--prefix', str(gateway), 'ci', '--include=dev',
                            '--no-audit', '--no-fund')
            if installed.returncode:
                return no_result(f'npm ci failed: {installed.stdout[-2000:]}{installed.stderr[-2000:]}')
            stamp.write_text(inputs)
        secret = Path.home() / '.tron-signing/keychain.pass'
        if secret.is_file():
            keychain = Path.home() / 'Library/Keychains/tron-signing.keychain-db'
            unlocked = subprocess.run(['security', '-i'], input=f'unlock-keychain -p {shlex.quote(secret.read_text().strip())} '
                                      f'{shlex.quote(str(keychain))}\n', env=env, capture_output=True, text=True)
            if unlocked.returncode or unlocked.stdout.strip() or unlocked.stderr.strip():
                return no_result('cannot unlock the signing keychain')
        if stopped.is_set():
            return no_result('stopped before the lane started')
        child = subprocess.Popen([str(checkout / 'scripts/tron'), 'test', lane, *job['args']], cwd=checkout, env=env,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        running.append(child)
        if stopped.is_set():
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        code = child.wait()
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        return min(128 - code if code < 0 else code, 254)


if __name__ == '__main__':
    if sys.argv[1:2] == ['remote']:
        raise SystemExit(remote(json.loads(sys.argv[2])))
    if len(sys.argv) < 2:
        raise SystemExit(no_result('usage: scripts/tron test --host <name> <lane> [lane arguments...]'))
    raise SystemExit(local(sys.argv[1], sys.argv[2:]))
