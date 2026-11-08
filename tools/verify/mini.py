#!/usr/bin/env python3
"""Run one Gateway Vitest lane (tools/verify/gateway.py) on the Mac mini test host and return its result as this run's.

Local side: refuse a dirty tree, push the exact HEAD commit to the mini's bare repository, run this same file there
(sent as source, so both halves are one version), stream its output live, and write the Vitest output files it
returns where the caller asked, with the mini's checkout path rewritten to this checkout. The exit code is the
mini's. No result means a failure (exit 2), never a local fallback.

Mini side (`remote`): one job at a time under ~/tron-ci/jobs/gateway.lock, check out the commit in
~/tron-ci/jobs/gateway, refuse a Node or npm that differs from the commit's pins, `npm ci` only when the
commit's Gateway dependency inputs changed, then run the commit's own gateway.py. Closing the ssh session
(the local side stopped) sends that lane SIGTERM. The mini host is `git config tron.verify.mini` (an ssh
destination) and `tron.verify.miniIdentity` (an optional key file). Runs on the mini's /usr/bin/python3.
"""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

# The mini runs this source as `python3 -c`, where there is no file and no local checkout.
ROOT = Path(__file__).resolve().parents[2] if '__file__' in globals() else None
BASE = 'tron-ci'  # under the mini user's home: tron.git, jobs/, results/
EXIT_INFRA = 2
OUTPUT_OPTION = '--outputFile'


def frame(nonce: str) -> bytes:
    return f'@@tron-mini {nonce} '.encode()


# ---------------------------------------------------------------------------- local side

def git(*args: str) -> str:
    return subprocess.run(['git', '-C', str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def config(key: str) -> str:
    return subprocess.run(['git', '-C', str(ROOT), 'config', '--get', key], capture_output=True, text=True).stdout.strip()


def ssh_command() -> list[str]:
    destination = config('tron.verify.mini')
    if not destination:
        raise SystemExit('mini: no test host configured; set `git config tron.verify.mini <user@host>` '
                         '(and tron.verify.miniIdentity <key>), or run the Gateway lanes here with --gateway-host local')
    identity = config('tron.verify.miniIdentity')
    return ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4',
            *(['-i', os.path.expanduser(identity)] if identity else []), destination]


def outputs(args: list[str]) -> tuple[list[str], list[str]]:
    """The Vitest arguments with each --outputFile path replaced by an index the mini resolves, and the local paths."""
    mapped, paths, pending = [], [], False
    for word in args:
        if pending:
            paths.append(word)
            mapped.append(f'@output:{len(paths) - 1}')
            pending = False
        elif word.startswith(OUTPUT_OPTION) and '=' in word:
            option, path = word.split('=', 1)
            paths.append(path)
            mapped.append(f'{option}=@output:{len(paths) - 1}')
        else:
            pending = word == OUTPUT_OPTION or (word.startswith(OUTPUT_OPTION + '.') and '=' not in word)
            mapped.append(word)
    return mapped, [str(Path(os.getcwd(), path)) for path in paths]


def local_main(args: list[str]) -> int:
    if os.environ.get('TRON_UPDATE_LOCKS'):
        print('mini: TRON_UPDATE_LOCKS would rewrite goldens in the mini checkout, not here; record locks locally', file=sys.stderr)
        return EXIT_INFRA
    if git('status', '--porcelain', '--untracked-files=normal'):
        print('mini: the worktree has uncommitted or untracked changes; the mini runs a commit, commit first', file=sys.stderr)
        return EXIT_INFRA
    try:
        ssh = ssh_command()
    except SystemExit as error:
        print(error, file=sys.stderr)
        return EXIT_INFRA
    sha, destination = git('rev-parse', 'HEAD'), ssh[-1]
    mapped, paths = outputs(args)
    started = time.time()
    print(f'mini: Gateway lane for {sha[:12]} on {destination}; pushing the commit', flush=True)
    push = subprocess.run(['git', '-C', str(ROOT), 'push', '--no-verify', '--quiet', f'{destination}:{BASE}/tron.git',
                           f'{sha}:refs/tron-jobs/run-{sha}'], env={**os.environ, 'GIT_SSH_COMMAND': shlex.join(ssh[:-1])},
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if push.returncode:
        print(f'mini: could not push {sha[:12]} to {destination}:{BASE}/tron.git; the mini is unreachable or not set up, '
              f'no result (pass --gateway-host local to run here):\n{push.stdout.strip()}', file=sys.stderr)
        return EXIT_INFRA
    print(f'mini: pushed in {time.time() - started:.1f}s', flush=True)
    nonce = uuid.uuid4().hex
    job = json.dumps({'sha': sha, 'args': mapped, 'outputs': len(paths), 'nonce': nonce, 'localRoot': str(ROOT),
                      'requester': {'host': platform.node(), 'worktree': str(ROOT), 'pid': os.getpid()}})
    source = Path(__file__).read_text()
    remote = shlex.join(['/usr/bin/python3', '-c', source, 'remote', job])
    marker, code, received = frame(nonce), None, set()
    with subprocess.Popen([*ssh, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        # Closing stdin ends the mini's job: it sends its lane SIGTERM and returns what it has.
        def stop(_signum, _frame):
            if child.stdin and not child.stdin.closed:
                child.stdin.close()
        previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            for line in child.stdout:
                if not line.startswith(marker):
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()
                    continue
                kind, _, value = line[len(marker):].strip().decode().partition(' ')
                if kind == 'output':
                    index, _, payload = value.partition(' ')
                    target = Path(paths[int(index)])
                    target.parent.mkdir(parents=True, exist_ok=True)
                    temporary = target.with_name(target.name + '.mini-tmp')
                    temporary.write_bytes(base64.b64decode(payload))
                    os.replace(temporary, target)
                    received.add(int(index))
                elif kind == 'exit':
                    code = int(value)
            child.wait()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    if code is None:
        print(f'mini: the session with {destination} ended (ssh exit {child.returncode}) without a result; not a test result',
              file=sys.stderr)
        return EXIT_INFRA
    missing = [paths[index] for index in range(len(paths)) if index not in received]
    print(f'mini: lane exit {code} after {time.time() - started:.1f}s' + (f'; it wrote no {", ".join(missing)}' if missing else ''), flush=True)
    return code


# ---------------------------------------------------------------------------- mini side

def remote_main(job: dict) -> int:
    nonce, sha = job['nonce'], job['sha']
    home = Path.home()
    base = home / BASE
    repository, checkout = base / 'tron.git', base / 'jobs/gateway'
    results = base / 'results' / f'gateway-{nonce}'
    say = lambda text: print(f'mini: {text}', flush=True)  # noqa: E731
    out = sys.stdout.buffer
    cancelled = threading.Event()
    lane: list[subprocess.Popen] = []

    def watch() -> None:
        # The local side never writes; end of input means it stopped or the connection dropped.
        # A raw read: a buffered one would hold the stdin lock while the interpreter exits.
        while os.read(sys.stdin.fileno(), 4096):
            pass
        cancelled.set()
        if lane and lane[0].poll() is None:
            lane[0].send_signal(signal.SIGTERM)
    threading.Thread(target=watch, daemon=True).start()

    def finish(code: int) -> int:
        out.write(b'\n' + frame(nonce) + f'exit {code}\n'.encode())
        out.flush()
        return code

    def refuse(text: str) -> int:
        print(f'mini: {text}', file=sys.stderr, flush=True)
        return finish(EXIT_INFRA)

    clean = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', 'PYTHONDONTWRITEBYTECODE': '1',
             'LANG': os.environ.get('LANG', 'en_US.UTF-8'), **{key: os.environ[key] for key in ('USER', 'LOGNAME', 'SHELL') if key in os.environ}}

    def run(*command: str, cwd: Path | None = None, stream: bool = False) -> subprocess.CompletedProcess:
        return subprocess.run(command, cwd=cwd, env=clean, stdin=subprocess.DEVNULL, text=True,
                              **({} if stream else {'capture_output': True}))

    if not (repository / 'HEAD').is_file():
        return refuse(f'{repository} is not a bare repository; set it up with `git init --bare {repository}`')
    (base / 'jobs').mkdir(exist_ok=True)
    with open(base / 'jobs/gateway.lock', 'a+') as lock:
        announced = 0.0
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if cancelled.is_set():
                    return refuse('stopped while waiting for the mini Gateway job lock')
                if time.time() - announced >= 60:
                    lock.seek(0)
                    say(f'waiting for the mini Gateway job lock, held by {lock.read().strip() or "an unrecorded job"}')
                    announced = time.time()
                time.sleep(2)
        lock.seek(0)
        lock.truncate()
        lock.write(json.dumps({**job['requester'], 'sha': sha}))
        lock.flush()

        prepared = time.time()
        if (checkout / '.git').exists():
            steps = [('git', '-C', str(checkout), 'checkout', '--quiet', '--detach', '--force', sha),
                     ('git', '-C', str(checkout), 'clean', '-ffdxq', '-e', '/packages/gateway/node_modules')]
        else:
            steps = [('git', '-C', str(repository), 'worktree', 'prune'),
                     ('git', '-C', str(repository), 'worktree', 'add', '--quiet', '--detach', str(checkout), sha)]
        for command in steps:
            result = run(*command)
            if result.returncode:
                return refuse(f'{shlex.join(command)} failed: {(result.stdout + result.stderr).strip()}')
        head = run('git', '-C', str(checkout), 'rev-parse', 'HEAD').stdout.strip()
        dirty = run('git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=normal').stdout.strip()
        if head != sha or dirty:
            return refuse(f'the mini checkout is not exactly {sha} (HEAD {head or "unknown"}; changes: {dirty or "none"})')
        # The last checked-out commit stays referenced, so the next push sends only new objects.
        run('git', '-C', str(repository), 'update-ref', 'refs/tron-jobs/gateway', sha)
        run('git', '-C', str(repository), 'update-ref', '-d', f'refs/tron-jobs/run-{sha}')

        # The commit's own pins: exact Node version, official binary digest, bundled npm version.
        pins = dict(line.split('=', 1) for line in (checkout / 'config/ci-toolchain.env').read_text().splitlines()
                    if '=' in line and not line.lstrip().startswith('#'))
        resolved = run(str(checkout / 'scripts/tron-node'))
        node = Path(resolved.stdout.strip()) if resolved.returncode == 0 else None
        if node is None:
            return refuse(f'no pinned Node on the mini: {resolved.stderr.strip()}\n'
                          f'    install it there with: cd {checkout} && scripts/tron-node install')
        architecture = {'arm64': 'ARM64', 'aarch64': 'ARM64', 'x86_64': 'X64'}.get(platform.machine(), platform.machine().upper())
        digest = hashlib.sha256(node.read_bytes()).hexdigest()
        npm = run(str(checkout / 'scripts/tron-node'), 'exec', 'npm', '--version').stdout.strip()
        expected = {'node digest': (digest, pins.get(f'TRON_NODE_{architecture}_RUNTIME_SHA256')),
                    'npm': (npm, pins.get('TRON_NODE_NPM_VERSION'))}
        differing = [f'{name} {actual or "missing"}, pinned {pin}' for name, (actual, pin) in expected.items() if actual != pin]
        if differing:
            return refuse(f'the mini toolchain differs from the pins at {sha[:12]}: {"; ".join(differing)} ({node})\n'
                          f'    reinstall it there with: cd {checkout} && scripts/tron-node install')
        version = (checkout / '.node-version').read_text().strip()
        say(f'checkout {sha[:12]} ready; Node v{version} ({digest[:12]}) npm {npm}, macOS {platform.mac_ver()[0]}, '
            f'Python {platform.python_version()}')

        # `npm ci` runs again exactly when an input it reads changes: the manifest, lockfile, vendored tarballs or Node.
        inputs = run('git', '-C', str(checkout), 'rev-parse', *(f'HEAD:packages/gateway/{path}' for path in
                                                               ('package.json', 'package-lock.json', 'third_party'))).stdout
        install = hashlib.sha256(f'{inputs}{digest}'.encode()).hexdigest()
        stamp = checkout / 'packages/gateway/node_modules/.tron-mini-install'
        if not stamp.is_file() or stamp.read_text() != install:
            say('Gateway dependencies changed; npm ci')
            installed = run(str(checkout / 'scripts/tron-node'), 'exec', 'npm', '--prefix', 'packages/gateway', 'ci', '--include=dev',
                            cwd=checkout, stream=True)
            if installed.returncode:
                return refuse(f'npm ci failed (exit {installed.returncode})')
            stamp.write_text(install)
        say(f'prepared in {time.time() - prepared:.1f}s; running the lane, load {os.getloadavg()[0]:.1f}')
        if cancelled.is_set():
            return refuse('stopped before the lane started')

        results.mkdir(parents=True, exist_ok=True)
        try:
            files = [results / f'output-{index}' for index in range(job['outputs'])]
            args = []
            for word in job['args']:
                for index, path in enumerate(files):
                    word = word.replace(f'@output:{index}', str(path))
                args.append(word.replace(job['localRoot'], str(checkout)))
            with subprocess.Popen(['/usr/bin/python3', str(checkout / 'tools/verify/gateway.py'), *args], cwd=checkout / 'packages/gateway',
                                  env=clean, stdin=subprocess.DEVNULL) as child:
                lane.append(child)
                if cancelled.is_set():
                    child.send_signal(signal.SIGTERM)
                code = child.wait()
                code = 128 - code if code < 0 else code  # killed by a signal: the shell's convention
            for index, path in enumerate(files):
                if path.is_file():
                    content = path.read_text(errors='replace').replace(str(checkout), job['localRoot'])
                    out.write(b'\n' + frame(nonce) + f'output {index} '.encode() + base64.b64encode(content.encode()) + b'\n')
            return finish(code)
        finally:
            shutil.rmtree(results, ignore_errors=True)


if __name__ == '__main__':
    if sys.argv[1:2] == ['remote']:
        sys.exit(remote_main(json.loads(sys.argv[2])))
    try:
        sys.exit(local_main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
