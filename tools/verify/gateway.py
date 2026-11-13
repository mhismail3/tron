#!/usr/bin/env python3
"""Own the temporary HOME and scratch directory of one Gateway Vitest process."""
from __future__ import annotations
from pathlib import Path
import fcntl
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_lock import HELD_BY_CALLER, wait_for_full_gateway_lock  # noqa: E402  (the one host lock owner)
import vitest_configs  # noqa: E402  (the one reader of the listing Vitest configs)
import ledger


def hold_full_gateway_lock():
    """The open, exclusively locked lock file, after waiting its turn behind any holder and earlier waiters; None when the caller holds it."""
    if os.environ.get(HELD_BY_CALLER) == '1':
        return None
    record = {'pid': os.getpid(), 'worktree': str(ROOT), 'purpose': 'gateway vitest ' + ' '.join(sys.argv[1:])[:200]}
    return wait_for_full_gateway_lock(record, lambda line: print(f'gateway tests: {line}', file=sys.stderr, flush=True))


BROWSER_FORK_COPY = 'TRON_P99_17_BROWSER_FORK_COPY'
BROWSER_FORK_TEST = 'src/e2e/sessions/browser-fork-receipts.integration.test.ts'
BROWSER_FORK_REPOSITORY = 'https://github.com/fitchmultz/pi-agent-browser-native.git'
VALUE_OPTIONS = {'--config', '-c', '--project', '--reporter', '--outputFile', '-t', '--testNamePattern', '--root', '-r', '--dir', '--shard',
                 '--testTimeout', '--hookTimeout', '--teardownTimeout', '--bail', '--retry', '--maxWorkers', '--minWorkers', '--pool',
                 '--environment', '--maxConcurrency', '--sequence.seed', '--exclude'}


def vitest_selection(args: list[str]) -> tuple[str | None, list[tuple[str, str]]]:
    """The config file this Vitest selection names, if any, and each file filter as given and relative to the Gateway package."""
    config, filters, value = None, [], None
    for word in args:
        if value:
            if value in ('--config', '-c'):
                config = word
            value = None
        elif word.split('=', 1)[0] in ('--config', '-c') and '=' in word:
            config = word.split('=', 1)[1]
        elif word in VALUE_OPTIONS:
            value = word
        elif not word.startswith('-'):
            relative = re.sub(r':\d+$', '', word).removeprefix(str(ROOT / 'packages/gateway') + '/')
            filters.append((word, relative.removeprefix('./').removeprefix('packages/gateway/')))
    return config, filters


def filter_selects(relative: str, path: str) -> bool:
    """Whether a file filter selects the test file at `path`: Vitest's rule, the path contains the filter ignoring case."""
    return relative.lower() in path.lower()


def selects_browser_fork(args: list[str]) -> bool:
    """Whether this Vitest selection can include the browser receipt test: the default config, and no file filter or one it matches."""
    config, filters = vitest_selection(args)
    if config is not None and Path(config).name != 'vitest.config.ts':
        return False
    return not filters or any(filter_selects(relative, BROWSER_FORK_TEST) for _, relative in filters)


def with_own_config(args: list[str]) -> list[str]:
    """`args` under the one config that runs every file its filters select: a listing config when that is it.

    A filter selects each test file `filter_selects` matches. Filters selecting files of
    more than one config are refused with each config's command, since any one config would skip the rest."""
    config, filters = vitest_selection(args)
    if config is not None or not filters:
        return args
    gateway = ROOT / 'packages/gateway'
    listed = vitest_configs.listed_files(gateway)
    owners = {path.relative_to(gateway).as_posix(): None for path in (gateway / 'src').rglob('*.test.ts')}
    owners.update({path: name for name, paths in listed.items() for path in paths})
    selected: dict[str | None, list[str]] = {}
    for word, relative in filters:
        for name in {owner for path, owner in owners.items() if filter_selects(relative, path)} or {None}:
            selected.setdefault(name, []).append(word)
    if len(selected) == 1:
        name = next(iter(selected))
        return args if name is None else ['--config', name, *args]
    options = ' '.join(word for word in args if word not in {raw for raw, _ in filters})
    commands = [' '.join(['scripts/tron test gateway', '--config', name or 'vitest.config.ts', *([options] if options else []), *words])
                for name, words in sorted(selected.items(), key=lambda item: item[0] or '')]
    raise Refused('gateway tests: these files run under different Vitest configs; run each set under its own:\n  '
                  + '\n  '.join(commands))


class Refused(Exception):
    """A selection this runner cannot run as one Vitest process; nothing ran."""


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
    node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
    vitest = ROOT / "packages/gateway/node_modules/.bin/vitest"
    if not vitest.is_file():
        raise SystemExit("Gateway Vitest is missing; prepare this worktree's pinned dependencies first")
    try:
        arguments = with_own_config(sys.argv[1:])
    except Refused as refusal:
        print(refusal, file=sys.stderr)
        return 2
    fork = {}
    if selects_browser_fork(arguments):
        copy = provision_browser_fork()
        path = [str(provision_browser_engine(copy)), *filter(None, os.environ.get('PATH', '').split(os.pathsep))]
        fork = {BROWSER_FORK_COPY: str(copy), 'PATH': os.pathsep.join(path)}
    lock = hold_full_gateway_lock()
    capture = ledger.Capture('gateway-nested' if 'vitest.nested.config.ts' in arguments else 'gateway')
    signal.signal(signal.SIGTERM, lambda signum, _frame: sys.exit(128 + signum))
    with tempfile.TemporaryDirectory(prefix="tron-gateway-tests-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, scratch = root / "home", root / "tmp"
        home.mkdir(); scratch.mkdir()
        environment = {**os.environ, **fork, "HOME": str(home), "TMPDIR": str(scratch), "TRON_NODE_BIN": node}
        report = next((Path(word.split('=', 1)[1]) for word in arguments if word.startswith('--outputFile.json=')), None)
        if report is None:
            report = root / 'vitest.json'
            arguments = [*arguments, '--reporter=json', f'--outputFile.json={report}']
            if not any(word.startswith('--reporter') for word in arguments[:-2]):
                arguments.append('--reporter=default')
        report = report if report.is_absolute() else ROOT / 'packages/gateway' / report
        with subprocess.Popen([str(ROOT / "scripts/tron-node"), "exec", str(vitest), "run", *arguments],
                              cwd=ROOT / "packages/gateway", env=environment) as child:
            def forward(signum, _frame):
                if child.poll() is None:
                    child.send_signal(signum)
            previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT)}
            try:
                return child.wait()
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
                try:
                    capture.vitest(report)
                finally:
                    if lock:
                        lock.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
