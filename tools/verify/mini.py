#!/usr/bin/env python3
"""Run one Gateway Vitest lane (tools/verify/gateway.py) or verify's Python group on the Mac mini test host and return
its result as this run's.

The test-host pool is {the mini, this Mac}: `choose_host` picks the mini when it is configured, reachable and idle,
and otherwise this Mac, always with its reason; `mini.py pool [vitest args]` runs one lane on the chosen host.
`mini.py python <command>` runs verify's per-file Python command in the mini checkout, its stderr merged into
stdout in order, since verify counts each file's unittest summary after that file's marker. `mini.py node <file>...`
runs the Gateway's `node --test` files on the mini's pinned Node, its TAP output streamed back for verify to count.

Local side: refuse a dirty tree, push the exact HEAD commit to the mini's bare repository, run this same file there
(sent as source, so both halves are one version), stream its output live, and write the Vitest output files it
returns where the caller asked, with the mini's checkout path rewritten to this checkout. The exit code is the
mini's. No result, never a local fallback, exits EXIT_NO_RESULT with a last `mini: no result: <reason>` line on stderr;
`no_result_reason` reads it, so a lane that itself exits 75 stays its own exit.

Mini side (`remote`): one job at a time under ~/tron-ci/jobs/gateway.lock (a caller's TRON_MINI_JOB_WAIT_SECONDS
caps the wait for it, naming the holder; unset waits indefinitely), check out the commit in
~/tron-ci/jobs/gateway, refuse a Node or npm that differs from the commit's pins, `npm ci` only when the
commit's Gateway dependency inputs changed (Python tests import Gateway packages too), then run the commit's own
gateway.py, the Node test files on the pinned Node, or, once the pinned Dafny passes `proof doctor`, the Python command. Closing the ssh session
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
from typing import Sequence

ROOT = Path(__file__).resolve().parents[2] if '__file__' in globals() else None
BASE = 'tron-ci'
EXIT_NO_RESULT = 75
NO_RESULT_LINE = 'mini: no result: '
OUTPUT_OPTION = '--outputFile'
INCOMING = 'refs/tron-jobs/incoming'


def no_result(reason: str) -> int:
    print(NO_RESULT_LINE + ' | '.join(line.strip() for line in reason.strip().splitlines() if line.strip()), file=sys.stderr, flush=True)
    return EXIT_NO_RESULT


def no_result_reason(code: int, output: str) -> str | None:
    """Why a mini lane produced no result, read from its exit and output; None for a lane result, whatever its exit."""
    said = [line for line in output.splitlines() if line.startswith('mini: ')]
    return said[-1][len(NO_RESULT_LINE):] if code == EXIT_NO_RESULT and said and said[-1].startswith(NO_RESULT_LINE) else None


def frame(nonce: str) -> bytes:
    return f'@@tron-mini {nonce} '.encode()


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


def outside_paths(args: Sequence[str]) -> list[str]:
    """Arguments naming a path outside this checkout (output files aside): the mini cannot read them. A relative
    word resolves against the Gateway package, the lane's working directory."""
    words = [word.split('=', 1)[1] if word.startswith('--') and '=' in word else word for word in args if not word.startswith(OUTPUT_OPTION)]
    package, root = ROOT / 'packages/gateway', ROOT.resolve()
    return [word for word in words if not word.startswith('-') and not (package / word).resolve().is_relative_to(root)]


def choose_host(args: Sequence[str] = ()) -> tuple[str, str]:
    """('mini' or 'local', why). The mini is the default; this Mac runs the lane only when the mini cannot."""
    if os.environ.get('TRON_UPDATE_LOCKS'):
        return 'local', 'recording goldens writes this checkout'
    if outside := outside_paths(args):
        return 'local', f'an argument names {outside[0]}, outside this checkout'
    if not config('tron.verify.mini'):
        return 'local', 'no mini is configured'
    if git('status', '--porcelain', '--untracked-files=normal'):
        return 'local', 'uncommitted changes; the mini runs a commit'
    ssh = ssh_command()
    ssh[ssh.index('ConnectTimeout=10')] = 'ConnectTimeout=5'
    try:
        probe = subprocess.run([*ssh, shlex.join(['/usr/bin/python3', '-c', Path(__file__).read_text(), 'status'])],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return 'local', f'the mini {ssh[-1]} is unreachable: no answer within 30 s'
    try:
        status = json.loads(probe.stdout.strip().splitlines()[-1]) if probe.returncode == 0 else None
        busy, ready, load = bool(status['busy']), bool(status['ready']), float(status['load'])
    except (ValueError, IndexError, KeyError, TypeError):
        detail = ((probe.stderr if probe.returncode else probe.stdout).strip().splitlines() or ['no output'])[-1]
        return 'local', f'the mini {ssh[-1]} is unreachable: {detail}' if probe.returncode else f'the mini {ssh[-1]} answered no status: {detail}'
    if not ready:
        return 'local', f'the mini is not set up: no ~/{BASE}/tron.git'
    if busy:
        return 'local', 'the mini is busy with another job'
    return 'mini', f'reachable and idle, load {load:.1f}'


def pool_main(args: list[str]) -> int:
    host, reason = choose_host(args)
    destination = config('tron.verify.mini')
    print(f'gateway lane: on the Mac mini {destination} ({reason})' if host == 'mini' else f'gateway lane: on this Mac ({reason})',
          file=sys.stderr, flush=True)
    if host == 'mini':
        return local_main(args)
    os.execvp('python3', ['python3', str(ROOT / 'tools/verify/gateway.py'), *args])


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
    return mapped, [str(ROOT / 'packages/gateway' / path) for path in paths]


def local_main(args: list[str], lane: str = 'gateway') -> int:
    if os.environ.get('TRON_UPDATE_LOCKS'):
        return no_result('TRON_UPDATE_LOCKS would rewrite goldens in the mini checkout, not here; record locks locally')
    if git('status', '--porcelain', '--untracked-files=normal'):
        return no_result('the worktree has uncommitted or untracked changes; the mini runs a commit, commit first')
    try:
        ssh = ssh_command()
    except SystemExit as error:
        return no_result(str(error).removeprefix('mini: '))
    sha, destination = git('rev-parse', 'HEAD'), ssh[-1]
    expected = os.environ.get('TRON_VERIFY_COMMIT')
    if expected and expected != sha:
        return no_result(f'HEAD is {sha[:12]}, not the commit under verification {expected[:12]}')
    mapped, paths = outputs(args) if lane == 'gateway' else (args, [])
    started = time.time()
    print(f'mini: {lane} lane for {sha[:12]} on {destination}; pushing the commit', flush=True)
    push = subprocess.run(['git', '-C', str(ROOT), 'push', '--no-verify', '--quiet', f'{destination}:{BASE}/tron.git',
                           f'+{sha}:{INCOMING}'], env={**os.environ, 'GIT_SSH_COMMAND': shlex.join(ssh[:-1])},
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if push.returncode:
        return no_result(f'could not push {sha[:12]} to {destination}:{BASE}/tron.git; the mini is unreachable or not set up '
                         f'(pass --gateway-host local to run here): {push.stdout.strip()}')
    print(f'mini: pushed in {time.time() - started:.1f}s', flush=True)
    nonce = uuid.uuid4().hex
    wait = os.environ.get('TRON_MINI_JOB_WAIT_SECONDS')
    job = json.dumps({'sha': sha, 'lane': lane, 'args': mapped, 'outputs': len(paths), 'nonce': nonce, 'localRoot': str(ROOT),
                      'lockWaitSeconds': float(wait) if wait else None,
                      'requester': {'host': platform.node(), 'worktree': str(ROOT), 'pid': os.getpid()}})
    source = Path(__file__).read_text()
    remote = shlex.join(['/usr/bin/python3', '-c', source, 'remote', job])
    marker, code, refused, received, stopped = frame(nonce), None, None, set(), []
    with subprocess.Popen([*ssh, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        def stop(signum, _frame):
            stopped.append(signum)
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
                elif kind == 'refused':
                    refused = json.loads(value)
                elif kind == 'exit':
                    code = int(value)
            child.wait()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    if stopped:
        print(f'mini: stopped; the mini job was ended (lane exit {code}); not a test result', file=sys.stderr)
        return 128 + stopped[0]
    if code is None:
        return no_result(f'the session with {destination} ended (ssh exit {child.returncode}) without a result')
    if refused is not None:
        return no_result(refused)
    missing = [paths[index] for index in range(len(paths)) if index not in received]
    print(f'mini: lane exit {code} after {time.time() - started:.1f}s' + (f'; it wrote no {", ".join(missing)}' if missing else ''), flush=True)
    return code


def remote_status() -> int:
    """Whether the mini is set up, whether a job holds its job lock, and its load: the pool's availability probe."""
    lock_path = Path.home() / BASE / 'jobs/gateway.lock'
    busy = False
    if lock_path.is_file():
        with open(lock_path, 'a+') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock, fcntl.LOCK_UN)
            except BlockingIOError:
                busy = True
    print(json.dumps({'busy': busy, 'ready': (Path.home() / BASE / 'tron.git/HEAD').is_file(), 'load': os.getloadavg()[0]}), flush=True)
    return 0


def signal_group(pgid: int, signum: int) -> bool:
    """Signal a process group; False once it has no live member (macOS answers EPERM for an exited, unreaped one)."""
    try:
        os.killpg(pgid, signum)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def remote_main(job: dict) -> int:
    nonce, sha = job['nonce'], job['sha']
    home = Path.home()
    base = home / BASE
    repository, checkout = base / 'tron.git', base / 'jobs/gateway'
    results = base / 'results' / f'gateway-{nonce}'
    say = lambda text: print(f'mini: {text}', flush=True)  # noqa: E731
    out = sys.stdout.buffer
    cancelled = threading.Event()
    running: list[subprocess.Popen] = []

    def watch() -> None:
        while os.read(sys.stdin.fileno(), 4096):
            pass
        cancelled.set()
        for child in running:
            if child.poll() is None:
                signal_group(child.pid, signal.SIGTERM)
    threading.Thread(target=watch, daemon=True).start()

    def finish(code: int) -> int:
        out.write(b'\n' + frame(nonce) + f'exit {code}\n'.encode())
        out.flush()
        return code

    def refuse(text: str) -> int:
        """No result: the reason in its own frame, so a lane that itself exits 75 is never read as one."""
        out.write(b'\n' + frame(nonce) + f'refused {json.dumps(text)}\n'.encode())
        return finish(EXIT_NO_RESULT)

    clean = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', 'PYTHONDONTWRITEBYTECODE': '1',
             'LANG': os.environ.get('LANG', 'en_US.UTF-8'), **{key: os.environ[key] for key in ('USER', 'LOGNAME', 'SHELL') if key in os.environ}}

    def run(*command: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(command, cwd=cwd, env=clean, stdin=subprocess.DEVNULL, text=True, capture_output=True)

    def stream(*command: str, cwd: Path, env: dict | None = None) -> int:
        """Run a long child in its own process group with its output streamed; a cancel stops the whole group, as
        verify stops a local step. Whatever is left of the group is killed before the job lock is released, so
        nothing still runs in the checkout the next job cleans. A signal exit is 128+n."""
        with subprocess.Popen(command, cwd=cwd, env=env or clean, stdin=subprocess.DEVNULL, start_new_session=True) as child:
            running.append(child)
            try:
                if cancelled.is_set():
                    signal_group(child.pid, signal.SIGTERM)
                code = child.wait()
            finally:
                running.remove(child)
                signal_group(child.pid, signal.SIGKILL)
                for _ in range(100):
                    if not signal_group(child.pid, 0):
                        break
                    time.sleep(0.1)
        return 128 - code if code < 0 else code

    if not (repository / 'HEAD').is_file():
        return refuse(f'{repository} is not a bare repository; set it up with `git init --bare {repository}`')
    try:
        (base / 'jobs').mkdir(exist_ok=True)
        with open(base / 'jobs/gateway.lock', 'a+') as lock:
            announced, waiting, cap = 0.0, time.monotonic(), job.get('lockWaitSeconds')
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if cancelled.is_set():
                        return refuse('stopped while waiting for the mini job lock')
                    lock.seek(0)
                    holder = lock.read().strip() or 'an unrecorded job'
                    if cap is not None and time.monotonic() - waiting >= cap:
                        return refuse(f'waited {round(time.monotonic() - waiting)}s for the mini job lock, held by {holder}; '
                                      'the caller caps that wait, no result')
                    if time.time() - announced >= 60:
                        say(f'waiting for the mini job lock, held by {holder}')
                        announced = time.time()
                    time.sleep(min(2, cap) if cap else 2)
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
            checkout = checkout.resolve()
            head = run('git', '-C', str(checkout), 'rev-parse', 'HEAD').stdout.strip()
            dirty = run('git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=normal').stdout.strip()
            if head != sha or dirty:
                return refuse(f'the mini checkout is not exactly {sha} (HEAD {head or "unknown"}; changes: {dirty or "none"})')
            run('git', '-C', str(repository), 'update-ref', 'refs/tron-jobs/gateway', sha)

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

            inputs = run('git', '-C', str(checkout), 'rev-parse', *(f'HEAD:packages/gateway/{path}' for path in
                                                                   ('package.json', 'package-lock.json', 'third_party'))).stdout
            install = hashlib.sha256(f'{inputs}{digest}'.encode()).hexdigest()
            stamp = checkout / 'packages/gateway/node_modules/.tron-mini-install'
            if not stamp.is_file() or stamp.read_text() != install:
                say('Gateway dependencies changed; npm ci')
                installed = stream(str(checkout / 'scripts/tron-node'), 'exec', 'npm', '--prefix', 'packages/gateway', 'ci', '--include=dev',
                                   cwd=checkout)
                if installed:
                    return refuse(f'npm ci failed (exit {installed})')
                stamp.parent.mkdir(exist_ok=True)
                stamp.write_text(install)
            say(f'prepared in {time.time() - prepared:.1f}s; running the lane, load {os.getloadavg()[0]:.1f}')
            if cancelled.is_set():
                return refuse('stopped before the lane started')

            if job['lane'] == 'node':
                return finish(stream(str(checkout / 'scripts/tron-node'), 'exec', 'node', '--test', '--test-concurrency=1', *job['args'],
                                     cwd=checkout / 'packages/gateway'))
            if job['lane'] == 'python':
                doctor = (run('/bin/bash', str(checkout / 'tools/proof/bootstrap.sh'), 'doctor', cwd=checkout)
                          if (checkout / 'tools/proof/dafny.pin').is_file() else None)
                if doctor and doctor.returncode != 0:
                    return refuse(f'no pinned Dafny on the mini: {(doctor.stderr or doctor.stdout).strip()}\n'
                                  f'    install it there with: cd {checkout} && scripts/tron proof bootstrap')
                env = {**clean, 'PATH': f'{node.parent}:{clean["PATH"]}'}
                return finish(stream('/bin/bash', '-c', 'exec 2>&1\n' + job['args'][0], cwd=checkout, env=env))
            results.mkdir(parents=True, exist_ok=True)
            try:
                files = [results / f'output-{index}' for index in range(job['outputs'])]
                args = []
                for word in job['args']:
                    for index, path in enumerate(files):
                        word = word.replace(f'@output:{index}', str(path))
                    args.append(word.replace(job['localRoot'], str(checkout)))
                code = stream('/usr/bin/python3', str(checkout / 'tools/verify/gateway.py'), *args, cwd=checkout / 'packages/gateway')
                for index, path in enumerate(files):
                    if path.is_file():
                        content = path.read_text(errors='replace').replace(str(checkout), job['localRoot'])
                        out.write(b'\n' + frame(nonce) + f'output {index} '.encode() + base64.b64encode(content.encode()) + b'\n')
                return finish(code)
            finally:
                shutil.rmtree(results, ignore_errors=True)
    finally:
        run('git', '-C', str(repository), 'update-ref', '-d', INCOMING, sha)


if __name__ == '__main__':
    if sys.argv[1:2] == ['remote']:
        sys.exit(remote_main(json.loads(sys.argv[2])))
    if sys.argv[1:2] == ['status']:
        sys.exit(remote_status())
    try:
        if sys.argv[1:2] == ['python'] and len(sys.argv) != 3:
            sys.exit('usage: mini.py python <command>')
        if sys.argv[1:2] == ['pool']:
            sys.exit(pool_main(sys.argv[2:]))
        sys.exit(local_main(sys.argv[2:], sys.argv[1]) if sys.argv[1:2] in (['python'], ['node']) else local_main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(no_result(str(error)))
