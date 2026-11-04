#!/usr/bin/env python3
"""Own the temporary HOME and scratch directory of one Gateway Vitest process."""
from pathlib import Path
import fcntl
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
# The host's one full-Gateway run at a time, shared with `verify --batch`. A run waits its turn
# for it instead of overlapping a batch Gateway lane; such a lane holds it and says so in its environment.
FULL_GATEWAY_LOCK = '/tmp/tron-full-gateway.lock'
HELD_BY_CALLER = 'TRON_FULL_GATEWAY_LOCK_HELD'


# tools/verify/batch.py carries this same function (its test fixture replaces this file);
# scripts/test-tron-verify-batch.py keeps the two identical.
def wait_for_full_gateway_lock(record, wait_seconds, announce):
    """The open full-Gateway lock file, exclusively locked once every earlier live waiter has had it.

    Waiters take the lock in arrival order: each queues a numbered ticket beside the lock and
    holds that ticket's flock while it waits, so a waiter that dies (even by SIGKILL) gives up
    its place and the next look at the queue deletes its ticket. Only the earliest live ticket
    tries the lock, whose own flock the kernel likewise drops for a dead holder. The queue
    directory's flock serializes numbering and pruning. Never interrupts the holder; raises
    TimeoutError naming it after `wait_seconds` (None waits indefinitely).
    """
    queue = Path(FULL_GATEWAY_LOCK + '.queue')
    queue.mkdir(exist_ok=True)

    def guarded(action):
        guard = os.open(queue, os.O_RDONLY)
        try:
            fcntl.flock(guard, fcntl.LOCK_EX)
            return action()
        finally:
            os.close(guard)

    def live():
        tickets = []
        for path in sorted(queue.glob('*.ticket')):
            with path.open() as probe:
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    tickets.append(path)
                    continue
            path.unlink()
        return tickets

    def enqueue():
        tickets = live()
        ticket = (queue / f'{int(tickets[-1].stem) + 1 if tickets else 0:012d}.ticket').open('x')
        fcntl.flock(ticket, fcntl.LOCK_EX)
        ticket.write(json.dumps(record))
        ticket.flush()
        return ticket

    ticket = guarded(enqueue)
    mine = Path(ticket.name)
    handle = open(FULL_GATEWAY_LOCK, 'a+')
    started = time.monotonic()
    announced = False
    try:
        try:
            while True:
                earlier = guarded(lambda: [path.read_text() for path in live() if path < mine])
                if not earlier:
                    try:
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        pass
                handle.seek(0)
                line = f"holder: {handle.read(512).strip() or 'unrecorded'}; earlier waiters: [{', '.join(earlier)}]"
                waited = time.monotonic() - started
                if wait_seconds is not None and waited >= wait_seconds:
                    raise TimeoutError(f'{line}; waited {round(waited)}s')
                if not announced:
                    announce(f'waiting for {FULL_GATEWAY_LOCK} ({line})')
                    announced = True
                time.sleep(0.2)
        finally:
            try:
                guarded(mine.unlink)
            finally:
                ticket.close()
        handle.truncate(0)
        handle.write(json.dumps(record))
        handle.flush()
    except BaseException:
        handle.close()
        raise
    return handle


def hold_full_gateway_lock():
    """The open, exclusively locked lock file, after waiting its turn behind any holder and earlier waiters; None when the caller holds it."""
    if os.environ.get(HELD_BY_CALLER) == '1':
        return None
    record = {'pid': os.getpid(), 'worktree': str(ROOT), 'purpose': 'gateway vitest ' + ' '.join(sys.argv[1:])[:200]}
    return wait_for_full_gateway_lock(record, None, lambda line: print(f'gateway tests: {line}', file=sys.stderr, flush=True))


# The browser receipt test runs the pinned agent-browser fork, which it reads from this
# variable, and whose native case runs the engine first on PATH. The runner provisions that exact
# commit once per clone and the engine version it declares once per version, so every run
# that selects the test (a batch's Gateway lane included) covers it instead of skipping it.
BROWSER_FORK_COPY = 'TRON_P99_17_BROWSER_FORK_COPY'
BROWSER_FORK_TEST = 'src/sessions/browser-fork-receipts.integration.test.ts'
BROWSER_FORK_REPOSITORY = 'https://github.com/fitchmultz/pi-agent-browser-native.git'
# Vitest options whose value is the next word, so that word is not a file filter.
VALUE_OPTIONS = {'--config', '-c', '--project', '--reporter', '--outputFile', '-t', '--testNamePattern', '--root', '-r', '--dir', '--shard',
                 '--testTimeout', '--hookTimeout', '--teardownTimeout', '--bail', '--retry', '--maxWorkers', '--minWorkers', '--pool',
                 '--environment', '--maxConcurrency', '--sequence.seed', '--exclude'}


def selects_browser_fork(args: list[str]) -> bool:
    """Whether this Vitest selection can include the browser receipt test: the default config, and no file filter or one it matches."""
    filters, value = [], None
    for word in args:
        if value:
            if value in ('--config', '-c') and Path(word).name != 'vitest.config.ts':
                return False
            value = None
        elif word.split('=', 1)[0] in ('--config', '-c') and '=' in word:
            if Path(word.split('=', 1)[1]).name != 'vitest.config.ts':
                return False
        elif word in VALUE_OPTIONS:
            value = word
        elif not word.startswith('-'):
            word = re.sub(r':\d+$', '', word).removeprefix(str(ROOT / 'packages/gateway') + '/')
            filters.append(word.removeprefix('./').removeprefix('packages/gateway/'))
    return not filters or any(word in BROWSER_FORK_TEST for word in filters)


def pinned_browser_fork() -> str:
    """The qualified fork commit, read from its one product owner."""
    adapter = (ROOT / 'packages/gateway/src/display/browser-live-view-adapter.ts').read_text()
    pins = set(re.findall(r'git:github\.com/fitchmultz/pi-agent-browser-native@([0-9a-f]{40})', adapter))
    if len(pins) != 1:
        raise SystemExit(f'gateway tests: expected one pinned agent-browser fork in browser-live-view-adapter.ts, found {sorted(pins)}')
    return pins.pop()


def provision_browser_fork() -> Path:
    """The built checkout of the pinned fork in this clone's shared verify state, built from its lockfile once."""
    commit = pinned_browser_fork()
    # This clone and the fixture's own repository, never a caller's (a hook's GIT_DIR, for example).
    clean = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    common = Path(subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                          text=True, env=clean).strip())
    fixtures = common / 'verify/fixtures'
    fixtures.mkdir(parents=True, exist_ok=True)
    target = fixtures / f'pi-agent-browser-native-{commit}'
    stamp = target / '.tron-provisioned'
    with open(fixtures / 'pi-agent-browser-native.lock', 'a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if stamp.is_file() and stamp.read_text() == commit:
            return target
        print(f'gateway tests: provisioning the pinned agent-browser fork {commit[:12]} into {target}', file=sys.stderr, flush=True)
        # Only this lock's holder stages, so any staging left here belongs to a provisioner
        # that was stopped or killed mid-build; remove it before starting over.
        for stale in fixtures.glob('.pi-agent-browser-native-*'):
            shutil.rmtree(stale, ignore_errors=True)
        staging = Path(tempfile.mkdtemp(prefix='.pi-agent-browser-native-', dir=fixtures))
        try:
            def run(*command: str) -> None:
                subprocess.run(command, cwd=staging, check=True, timeout=900, stdout=sys.stderr, env=clean)
            run('git', 'init', '-q')
            run('git', 'fetch', '-q', '--depth', '1', BROWSER_FORK_REPOSITORY, commit)
            run('git', 'checkout', '-q', '--detach', 'FETCH_HEAD')
            if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=staging, text=True, env=clean).strip() != commit:
                raise SystemExit(f'gateway tests: the fetched agent-browser fork is not {commit}')
            # The lockfile pins every dependency; lifecycle scripts stay off and the build is explicit.
            run(str(ROOT / 'scripts/tron-node'), 'exec', 'npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund')
            run(str(ROOT / 'scripts/tron-node'), 'exec', 'node', 'scripts/build.mjs')
            if not (staging / 'dist/extensions/agent-browser/index.js').is_file():
                raise SystemExit('gateway tests: the agent-browser fork build produced no extension')
            (staging / '.tron-provisioned').write_text(commit)
            shutil.rmtree(target, ignore_errors=True)
            os.rename(staging, target)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
    return target


def declared_browser_engine(fork: Path) -> str:
    """The one agent-browser engine version the fork qualifies against, read from the fork itself."""
    target = fork / 'scripts/agent-browser-target.mjs'
    source = target.read_text() if target.is_file() else ''
    versions = set(re.findall(r'TARGET_AGENT_BROWSER_VERSION\s*=\s*"(\d+\.\d+\.\d+)"', source))
    if len(versions) != 1:
        raise SystemExit(f'gateway tests: expected one TARGET_AGENT_BROWSER_VERSION in {target}, found {sorted(versions)}')
    return versions.pop()


def provision_browser_engine(fork: Path) -> Path:
    """The bin directory of the engine the fork declares, packed from the npm registry once per version.

    The registry's `agent-browser` package ships every platform's native binary; this keeps the one for
    this host, verified to report the declared version, so the engine follows the fork pin alone."""
    version = declared_browser_engine(fork)
    fixtures = fork.parent
    target = fixtures / f'agent-browser-{version}'
    stamp = target / '.tron-provisioned'
    system = {'Darwin': 'darwin', 'Linux': 'linux'}.get(platform.system(), platform.system().lower())
    machine = {'x86_64': 'x64', 'amd64': 'x64', 'aarch64': 'arm64'}.get(platform.machine().lower(), platform.machine().lower())
    member = f'package/bin/agent-browser-{system}-{machine}'
    with open(fixtures / 'agent-browser.lock', 'a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if stamp.is_file() and stamp.read_text() == version:
            return target / 'bin'
        print(f'gateway tests: provisioning agent-browser {version}, the engine the fork declares, into {target}', file=sys.stderr, flush=True)
        # As for the fork, only this lock's holder stages; leftovers are a killed provisioner's.
        for stale in fixtures.glob('.agent-browser-*'):
            shutil.rmtree(stale, ignore_errors=True)
        staging = Path(tempfile.mkdtemp(prefix='.agent-browser-', dir=fixtures))
        try:
            clean = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            subprocess.run([str(ROOT / 'scripts/tron-node'), 'exec', 'npm', 'pack', f'agent-browser@{version}', '--ignore-scripts',
                            '--pack-destination', str(staging), '--silent'], cwd=staging, check=True, timeout=900, stdout=sys.stderr, env=clean)
            tarballs = list(staging.glob('*.tgz'))
            if len(tarballs) != 1:
                raise SystemExit(f'gateway tests: npm pack agent-browser@{version} produced {len(tarballs)} tarballs')
            with tarfile.open(tarballs[0]) as archive:
                try:
                    binary = archive.extractfile(member)
                except KeyError:
                    binary = None
                if binary is None:
                    raise SystemExit(f'gateway tests: agent-browser {version} ships no {member}')
                (staging / 'bin').mkdir()
                (staging / 'bin/agent-browser').write_bytes(binary.read())
            tarballs[0].unlink()
            (staging / 'bin/agent-browser').chmod(0o755)
            reported = subprocess.run([str(staging / 'bin/agent-browser'), '--version'], capture_output=True, text=True, timeout=60).stdout.strip()
            if reported != f'agent-browser {version}':
                raise SystemExit(f'gateway tests: the packed engine reports {reported or "nothing"}, not agent-browser {version}')
            stamp_staging = staging / '.tron-provisioned'
            stamp_staging.write_text(version)
            shutil.rmtree(target, ignore_errors=True)
            os.rename(staging, target)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
    return target / 'bin'


def main() -> int:
    # Resolve the development toolchain before replacing HOME; resolution must
    # neither depend on the fixture home nor fall back to the signed Gateway.
    node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
    vitest = ROOT / "packages/gateway/node_modules/.bin/vitest"
    if not vitest.is_file():
        raise SystemExit("Gateway Vitest is missing; prepare this worktree's pinned dependencies first")
    fork = {}
    if selects_browser_fork(sys.argv[1:]):
        copy = provision_browser_fork()
        # Its native case runs `which agent-browser`: the fork's declared engine comes first.
        path = [str(provision_browser_engine(copy)), *filter(None, os.environ.get('PATH', '').split(os.pathsep))]
        fork = {BROWSER_FORK_COPY: str(copy), 'PATH': os.pathsep.join(path)}
    lock = hold_full_gateway_lock()
    with tempfile.TemporaryDirectory(prefix="tron-gateway-tests-") as temporary:
        root = Path(temporary)
        home, scratch = root / "home", root / "tmp"
        home.mkdir(); scratch.mkdir()
        environment = {**os.environ, **fork, "HOME": str(home), "TMPDIR": str(scratch), "TRON_NODE_BIN": node}
        # The existing Tron-home preflight remains authoritative for inherited
        # selectors/resource paths. Do not clear selectors or add an override
        # that would bypass its refusal; clean defaults now derive from HOME.
        with subprocess.Popen([str(ROOT / "scripts/tron-node"), "exec", str(vitest), "run", *sys.argv[1:]],
                              cwd=ROOT / "packages/gateway", env=environment) as child:
            # Keep the environment alive until Vitest has joined its own work.
            # No second timeout or descendant controller: the caller owns the
            # step group, while this launcher forwards direct signals and waits.
            def forward(signum, _frame):
                if child.poll() is None:
                    child.send_signal(signum)
            previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT)}
            try:
                return child.wait()
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
                if lock:
                    lock.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
