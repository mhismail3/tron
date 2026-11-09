"""Asynchronous full-main coverage and causal source repair. No scheduler, merge gate or production lifecycle."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import signal
import subprocess
import tempfile
import threading
import time

from host_lock import FULL_GATEWAY_LOCK, HELD_BY_CALLER, wait_for_full_gateway_lock
import timing
import verify

ROOT = verify.ROOT
# The host's one full-Gateway run at a time. A batch takes it only around each lane or probe
# marked `gatewayLock` (a full Gateway Vitest run), in arrival order with every other Gateway
# Vitest run (tools/verify/host_lock.py owns the lock), and marks that subprocess
# HELD_BY_CALLER so its runner does not wait on the batch. Every other subprocess runs
# unmarked: Gateway runs inside it (the verifier's Gateway groups) queue for the lock themselves.
# A Gateway lane waits its turn this long, then is uncovered naming the holder; never skipped.
FULL_GATEWAY_LOCK_WAIT_SECONDS = 45 * 60
REVERT_REMOTE_KEY = 'tron.verify.revertRemote'
# Inverse deltas touching these owners can change persisted data or authority.
IRREVERSIBLE_RISK = {'persistence', 'security', 'mac-installer'}
# The lanes run as two concurrent chains under their existing owners, each in plan order:
# Node (verifier, Gateway Vitest under the full-Gateway lock, Mac, relay) and Apple (the
# iOS lanes under host slots). Both join before freeze, attribution and verdict.
CHAINS = ('node', 'apple')
# The real-UI journey lane runs its journeys on this many owned simulator lanes at once, one
# host slot each, longest first by the previous batch's per-journey seconds.
UI_JOURNEY_LANES = 3
UI_JOURNEY_LANE = 'real Gateway UI journeys'


def save(path: Path, value: dict) -> None:
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, path)


def apple_lane(root: Path) -> dict[str, str]:
    """The Apple chain's own simulator lane and smoke products, so its iOS lanes never contend with
    the verifier's iOS steps (the Node chain) for this worktree's lane lease or DerivedData. The
    lane is named per repository (its git common directory), not per batch worktree, and owned by
    it (TRON_IOS_TEST_LANE_REPOSITORY), so each batch's worktree reuses the same warm simulators:
    one set per repository, reaped only with the repository or after the idle TTL (#2268)."""
    repository = os.path.realpath(subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip())
    name = 'batch-apple-' + hashlib.sha256(repository.encode()).hexdigest()[:12]
    # Smoke products stay the batch worktree's: their stamp names it, and products prune deletes
    # a gone worktree's products, so a shared directory could be deleted beneath a later build.
    products = 'batch-apple-' + hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:12]
    return {'TRON_IOS_TEST_LANE': name, 'TRON_IOS_TEST_LANE_REPOSITORY': repository,
            'TRON_IOS_TEST_DERIVED_DATA': str(Path.home() / 'Library/Developer/Tron/ios/test-derived-data' / products)}


def lanes(root: Path, base: str) -> list[dict]:
    """Compose existing owners, not a second test catalog."""
    apple = apple_lane(root)
    lane_only = {key: apple[key] for key in ('TRON_IOS_TEST_LANE', 'TRON_IOS_TEST_LANE_REPOSITORY')}
    # Required lanes never disappear when a checkout/tool is missing.
    result = [{'name': 'full verify', 'chain': 'node', 'command': ['scripts/tron', 'verify', '--all', '--base', base]}]
    for name, config in [('Gateway default', []), ('Gateway nested', ['--config', 'vitest.nested.config.ts'])]:
        result.append({'name': name, 'chain': 'node', 'command': ['python3', 'tools/verify/gateway.py', *config],
                       'vitest': True, 'gatewayLock': True, 'requires': 'packages/gateway/package-lock.json'})
    result.extend([
        {'name': 'Mac integration', 'chain': 'node', 'command': ['python3', 'tools/verify/mac.py'], 'requires': 'packages/mac-app/project.yml'},
        {'name': 'relay', 'chain': 'node', 'command': ['scripts/tron-node', 'exec', 'npm', '--prefix', 'packages/push-relay', 'test', '--'],
         'vitest': True, 'testRoot': 'packages/push-relay', 'requires': 'packages/push-relay/package-lock.json'},
        {'name': 'shipping iOS compile', 'chain': 'apple', 'command': ['scripts/tron-ios-device', 'compile'],
         'requires': 'packages/ios-app/project.yml', 'ios': True},
        {'name': 'iOS smoke', 'chain': 'apple', 'command': ['scripts/tron-ios-test', 'checkpoint'],
         'requires': 'scripts/tron-ios-test', 'ios': True, 'env': apple},
        # The E2E harness keeps its own DerivedData and fixture; only its lane moves.
        {'name': 'real Gateway boundary', 'chain': 'apple', 'command': ['scripts/ios-gateway-e2e-test', 'all'],
         'requires': 'scripts/ios-gateway-e2e-test', 'ios': True, 'env': lane_only},
        {'name': UI_JOURNEY_LANE, 'chain': 'apple', 'command': ['scripts/ios-gateway-e2e-test', 'run-ui'],
         'requires': 'scripts/ios-gateway-e2e-test', 'ios': True,
         'env': {**lane_only, 'TRON_IOS_E2E_UI_LANES': str(UI_JOURNEY_LANES)}},
    ])
    return result


def case_names(data: dict, failed: dict, root: Path) -> dict:
    """Each failed identity's describe titles and test title, the parts Vitest's `-t` matches joined with ' > '.

    The reporter's `fullName` joins them with spaces, so it cannot be split back into a selector."""
    names = {}
    for suite in data.get('testResults', []):
        try:
            file = Path(suite['name']).resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            continue
        for test in suite.get('assertionResults', []):
            identity = f"{file}::{test.get('fullName')}"
            if identity in failed and test.get('title') is not None:
                names[identity] = [*test.get('ancestorTitles', []), test['title']]
    return names


def signature(message: str, failures: list[str], output: str, root: Path) -> dict | None:
    # A test identity alone cannot distinguish a code regression from setup failing
    # in that same case (for example missing staged products at the baseline).
    diagnostics = re.findall(r'^(?:AssertionError:|Error:|error:|failure:|unowned:|overlap:|.+:\d+: error:).+$', output, re.M)
    diagnostics = sorted(line.replace(str(root), '<worktree>') for line in diagnostics[:20])
    failures = sorted(line.replace(str(root), '<worktree>') for line in failures)
    return {'message': message, 'failedTests': failures, 'diagnostics': diagnostics} if diagnostics else None


def host_slots_busy(root: Path) -> bool | None:
    """Whether other work holds every host slot. A slot this batch's own other chain holds
    (a job in `root`) frees when that lane ends, so a lane admitted then waits for it."""
    owner = root / 'scripts/ios-test-lock.py'
    if not owner.is_file():
        return None
    spec = importlib.util.spec_from_file_location('batch_ios_lock', owner)
    locker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(locker)
    worktrees = locker.slot_worktrees()
    return (all(worktree is not None for worktree in worktrees)
            and not any(worktree and Path(worktree).resolve() == root.resolve() for worktree in worktrees))


def previous_journey_seconds(state: Path, current: Path) -> dict[str, int]:
    """Per-journey seconds from the newest earlier batch whose UI journey lane logged any, the
    journey lines the lane owner prints (`timing.JOURNEY`); empty when none did."""
    batches = sorted(((int(path.parent.name.rsplit('-', 1)[-1]), path) for path in (state / 'batches').glob('*/report.json')
                      if path.parent != current and path.parent.name.rsplit('-', 1)[-1].isdigit()), reverse=True)
    for _, path in batches:
        try:
            lane = next(item for item in json.loads(path.read_text()).get('results', []) if item.get('name') == UI_JOURNEY_LANE)
            log = Path(lane['log']).read_text(errors='replace')
        except (OSError, ValueError, KeyError, StopIteration):
            continue
        seconds = {test: int(value) for kind, test, value, _ in timing.JOURNEY.findall(log) if kind == 'Real-UI journey'}
        if seconds:
            return seconds
    return {}


# Lane process groups running now, so an interrupted or failed chain set can stop both chains,
# and the cancellation a lane still waiting for the full-Gateway lock observes.
RUNNING: set[int] = set()
RUNNING_LOCK = threading.Lock()
CANCELLED = threading.Event()


def stop_running(grace: float = 30) -> None:
    """Terminate every running lane's process group, then kill what outlives the grace."""
    with RUNNING_LOCK:
        groups = list(RUNNING)
    for group in groups:
        verify.signal_group(group, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        with RUNNING_LOCK:
            if not RUNNING & set(groups):
                return
        time.sleep(0.05)
    with RUNNING_LOCK:
        groups = list(RUNNING & set(groups))
    for group in groups:
        verify.signal_group(group, signal.SIGKILL)


def run_chains(chains: list[list[tuple[int, dict]]], run_lane) -> None:
    """Run each chain's lanes in order on its own thread and join them all.

    A chain that raises stops the other chain's running lane and starts no further lane;
    an interrupt (SIGINT, or SIGTERM through the verifier's handler) does the same. Either way
    every chain has ended before this returns or re-raises, so nothing writes the report after."""
    stop, errors = CANCELLED, []
    stop.clear()

    def chain(items):
        try:
            for index, lane in items:
                if stop.is_set():
                    return
                run_lane(index, lane)
        except BaseException as error:  # re-raised on the main thread after both chains joined
            errors.append(error)
            stop.set()

    threads = [threading.Thread(target=chain, args=(items,), daemon=True) for items in chains if items]
    for thread in threads:
        thread.start()
    try:
        while any(thread.is_alive() for thread in threads):
            if stop.is_set():
                stop_running()
            for thread in threads:
                thread.join(timeout=0.1)
    except BaseException:
        stop.set()
        # Join every chain even through a repeated interrupt: nothing may write the report after.
        while any(thread.is_alive() for thread in threads):
            try:
                stop_running()
                for thread in threads:
                    thread.join(timeout=0.1)
            except KeyboardInterrupt:
                continue
        # Every chain has ended: cleanup that runs after (the fixture stop) must not see the stop.
        stop.clear()
        raise
    stop.clear()
    if errors:
        raise errors[0]


def execute(root: Path, lane: dict, directory: Path) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / 'output.log'
    print(f"batch: {lane['name']} … live log: {log}", flush=True)
    start, started_at = time.monotonic(), time.time()
    if lane.get('requires') and not (root / lane['requires']).is_file():
        return {**lane, 'exit': None, 'status': 'uncovered', 'reason': 'missing required owner', 'seconds': 0}
    if lane.get('ios'):
        busy = host_slots_busy(root)
        if busy is None:
            return {**lane, 'exit': None, 'status': 'uncovered', 'reason': 'missing host-slot owner', 'seconds': 0}
        if busy:
            return {**lane, 'exit': None, 'status': 'uncovered', 'reason': 'deferred: all host slots held', 'seconds': 0}
    command = lane['command']
    deferred_ios = lane['name'] == 'full verify' and host_slots_busy(root) is True
    if deferred_ios:
        command = [*command, '--skip', 'ios']
    if lane['name'] == 'shipping iOS compile':
        # This compile owner has a device lease, not a simulator slot; compose the
        # common host-slot owner rather than reserving capacity for the whole batch.
        command = ['python3', 'scripts/ios-test-lock.py', '--host-slot', '--lock',
                   str(directory / 'compile.lock'), '--', *command]
    if lane.get('vitest'):
        command = [*command, '--reporter=default', '--reporter=json', f'--outputFile.json={directory / "vitest.json"}']
    command = command.replace(str(ROOT), str(root)) if isinstance(command, str) else [word if word.startswith('--outputFile.json=') else word.replace(str(ROOT), str(root)) for word in command]
    vitest = next((Path(word.split('=', 1)[1]) for word in command if word.startswith('--outputFile.json=')), None) if isinstance(command, list) else None
    if vitest:
        vitest.parent.mkdir(parents=True, exist_ok=True)
        vitest.unlink(missing_ok=True)
    if lane['name'] == 'full verify':
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        (root / 'test-results/verify' / f'{sha}.json').unlink(missing_ok=True)
    env = {key: value for key, value in os.environ.items() if key != HELD_BY_CALLER}
    env['TRON_IOS_E2E_NO_INSTALL'] = '1'
    env.update(lane.get('env', {}))
    held, window = None, None
    if lane.get('gatewayLock'):
        record = {'pid': os.getpid(), 'worktree': str(root), 'purpose': f"verify --batch: {lane['name']}"}
        try:
            held = wait_for_full_gateway_lock(record, FULL_GATEWAY_LOCK_WAIT_SECONDS,
                                              lambda line: print(f"batch: {lane['name']} {line}", flush=True), CANCELLED.is_set)
        except InterruptedError as error:
            return {**lane, 'exit': None, 'status': 'uncovered', 'seconds': round(time.monotonic() - start, 3),
                    'reason': f'batch stopped while this lane waited for {FULL_GATEWAY_LOCK} ({error}); not run'}
        except TimeoutError as error:
            return {**lane, 'exit': None, 'status': 'uncovered', 'seconds': round(time.monotonic() - start, 3),
                    'reason': f'a full-Gateway run held or preceded this lane at {FULL_GATEWAY_LOCK} past the '
                              f'{FULL_GATEWAY_LOCK_WAIT_SECONDS}s wait cap ({error}); not run'}
        env[HELD_BY_CALLER] = '1'
        window = {'waitSeconds': round(time.monotonic() - start, 3), 'acquiredAt': time.time()}
    try:
        if CANCELLED.is_set():
            # Stopped while it waited or set up: a lane that has not started never starts.
            return {**lane, 'exit': None, 'status': 'uncovered', 'seconds': round(time.monotonic() - start, 3),
                    'reason': 'batch stopped before this lane started; not run'}
        with log.open('w') as output:
            process = subprocess.Popen(command, cwd=root / lane.get('cwd', '.'), shell=isinstance(command, str),
                                       stdout=output, stderr=subprocess.STDOUT, env=env, start_new_session=True)
            with RUNNING_LOCK:
                RUNNING.add(process.pid)
            try:
                code = process.wait()
            except BaseException:
                verify.signal_group(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    verify.signal_group(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            finally:
                with RUNNING_LOCK:
                    RUNNING.discard(process.pid)
    finally:
        if held:
            held.close()
            window['releasedAt'] = time.time()
    result = {**lane, 'exit': code, 'seconds': round(time.monotonic() - start, 3), 'startedAt': started_at, 'endedAt': time.time(),
              'log': str(log), 'executedCommand': command}
    if window:
        result['fullGatewayLock'] = window
    if deferred_ios:
        result.update(status='uncovered', reason='deferred: verifier iOS consumers; all host slots held')
    # Preserve the owning verifier's exact selection, failed tests and partial step logs.
    if lane['name'] == 'full verify':
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        source = root / 'test-results/verify' / f'{sha}.json'
        if not source.exists():
            result.update(status='uncovered', reason='missing verifier report')
        else:
            report = json.loads(source.read_text())
            verdict = report.get('verdict')
            result['verifierVerdict'] = verdict
            if report.get('commit') != sha or verdict not in ('passed', 'deferred', 'failed'):
                result.update(status='uncovered', reason='incomplete or wrong-SHA verifier report')
            if (verdict == 'passed' and not report.get('passingTests')):
                result.update(status='uncovered', reason='empty verifier test evidence')
            if (verdict == 'deferred' or report.get('skipped') or report.get('selection', {}).get('deferredTests')
                    or any(step.get('status') == 'deferred' for step in report.get('steps', []))):
                result.update(status='uncovered', reason='verifier deferred/skipped required work')
            save(directory / 'verify.json', report)
            logs = root / 'test-results/verify' / sha
            if logs.is_dir():
                shutil.copytree(logs, directory / 'steps', dirs_exist_ok=True)
            failed = next((step for step in report['steps'] if step['status'] == 'failed'), None)
            if failed and failed.get('command'):
                result['probe'] = {'name': failed['name'], 'command': failed['command'], 'cwd': failed['cwd']}
            failures = failed.get('failedTests', []) if failed else []
            detail = (root / failed['log']).read_text(errors='replace') if failed and failed.get('log') else ''
            result['signature'] = signature(report['message'], failures, detail, root)
    elif lane.get('vitest'):
        output = log.read_text(errors='replace')
        # The owning parser normalizes only the repo prefix and rejects suite errors.
        previous = verify.ROOT
        verify.ROOT = root
        try:
            failed, complete = verify.gateway_failures(vitest, output)
            _, case_complete = verify.case_outcomes(vitest)
        finally:
            verify.ROOT = previous
        result['failures'] = failed
        result['failureComplete'] = complete
        if failed:
            result['signature'] = {'failures': failed}
        if vitest and vitest.exists():
            data = json.loads(vitest.read_text())
            result['passingTests'] = data.get('numPassedTests', 0)
            result['selectedTests'] = data.get('numPassedTests', 0) + data.get('numFailedTests', 0)
            result['caseNames'] = case_names(data, failed, root)
            if (not case_complete or not (data.get('numPassedTests', 0) + data.get('numFailedTests', 0))
                    or data.get('numPendingTests') or data.get('numPendingTestSuites')):
                result.update(status='uncovered', reason='empty or skipped cases')
        else:
            result.update(status='uncovered', reason='missing test report')
    elif lane.get('probe'):
        output = log.read_text(errors='replace')
        # A sharded iOS step is named `tests: ios k/N`; its runner group is the first word.
        group = lane['name'].removeprefix('tests: ').split()[0]
        failures = []
        count = 0 if lane['name'].startswith('tests:') else None
        if vitest and vitest.exists():
            data = json.loads(vitest.read_text())
            count = data.get('numPassedTests', 0)
            result['selectedTests'] = count + data.get('numFailedTests', 0)
            failures = [f"{Path(suite['name']).name} > {test['fullName']}" for suite in data.get('testResults', [])
                        for test in suite.get('assertionResults', []) if test.get('status') == 'failed']
            shutil.copy2(vitest, directory / 'vitest.json')
        elif group == 'python':
            count = verify.python_count(output)
        elif group in ('node', 'node-gateway'):
            count = verify.tap_count(output)
        elif group == 'ios':
            count = verify.ios_count(output)
            failures = verify.ios_failures(output)
        elif group == 'shell':
            count = len(output.split(verify.FILE_MARKER)) - 1
        if lane['name'].startswith('tests:') and code == 0 and count == 0:
            result['exit'] = 1  # a runner that executes nothing cannot prove a good bisect probe
        result['signature'] = signature(f"{lane['name']} failed", failures, output, root)
    output = log.read_text(errors='replace')
    if lane['name'] == 'Mac integration':
        if code == 0 and verify.mac_count(output) == 0:
            result.update(status='uncovered', reason='missing, empty or skipped XCTest evidence')
        failures = re.findall(r"Test Case '-\[([^ .]+)\.([^ ]+) ([^]]+)\]' failed", output)
        if failures:
            result['xctestCases'] = ['/'.join(case) for case in failures]
            result['signature'] = signature('XCTest failed', result['xctestCases'], output, root)
    if lane['name'] == 'iOS smoke':
        if code == 0 and verify.ios_count(output) == 0:
            result.update(status='uncovered', reason='missing or empty XCTest summary')
        failures = verify.ios_failures(output)
        result['signature'] = signature(f"{lane['name']} failed", failures, output, root)
        # The summary retains method identity; this owner accepts exact selectors.
        if failures and re.fullmatch(r'\w+/\w+/\w+(?:\(\))?', failures[0].split(':', 1)[0]):
            selector = failures[0].split(':', 1)[0]
            result['probe'] = {'name': lane['name'], 'command': ['scripts/tron-ios-test', 'checkpoint', '--only-testing', selector], 'ios': True}
    if lane['name'] in ('real Gateway UI journeys', 'real Gateway boundary') and code:
        label, command = (('Real-UI journey', 'run-ui') if lane['name'] == 'real Gateway UI journeys'
                          else ('Focused E2E case', 'all'))
        failed_methods = re.findall(label + r' (\w+/\w+/\w+) completed .*\(status [1-9]\d*\)', output)
        if len(failed_methods) == 1:
            result['probe'] = {'name': lane['name'], 'ios': True, 'command': [
                'scripts/ios-gateway-e2e-test', command, '--only-testing', failed_methods[0]]}
    if code != 0 and 'signature' not in result:
        output = log.read_text(errors='replace')
        result['signature'] = signature(f"{lane['name']} failed", verify.ios_failures(output), output, root)
    print(f"batch: {lane['name']} {'PASS' if result['exit'] == 0 else 'FAIL'} in {result['seconds']}s", flush=True)
    return result


def stop_fixture(root: Path, directory: Path) -> dict | None:
    if (root / 'scripts/ios-gateway-e2e-test').is_file():
        return execute(root, {'name': 'fixture stop', 'command': ['scripts/ios-gateway-e2e-test', 'stop']}, directory)
    return None


def prepare(root: Path, directory: Path) -> bool:
    if not (root / 'packages/gateway/package-lock.json').is_file():
        return True
    result = execute(root, {'name': 'probe dependencies', 'command': [
        'scripts/tron-node', 'exec', 'npm', '--prefix', 'packages/gateway', 'ci', '--include=dev']}, directory)
    return result['exit'] == 0




class ProbeSelectionError(verify.VerifyError):
    """An exact-case recipe ran zero tests where the case is known to exist: a tooling error, never 'unresolved'."""


class Prober:
    """One disposable worktree runs every exact-case execution of one investigation.

    Cached outcomes in `verify/probes/` only steer the search; every control that
    proves or repairs a culprit is a fresh execution of the same recipe."""

    def __init__(self, failed: dict, directory: Path, state: Path, record: dict):
        self.failed, self.directory, self.record = failed, directory, record
        self.cache = state / 'probes'
        self.cache.mkdir(parents=True, exist_ok=True)
        directory.mkdir(parents=True, exist_ok=True)
        record.setdefault('probes', [])
        self.temporary = Path(tempfile.mkdtemp(prefix='tron-verify-bisect-')).resolve()
        self.root = self.temporary / 'repo'
        verify.git('worktree', 'add', '--detach', str(self.root), 'HEAD')
        self.dependency_key = None
        self.preserve = False

    def git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(['git', *args], cwd=self.root, check=check, capture_output=True, text=True)

    def probe(self, sha: str, hint: bool = False, selection_required: bool = False) -> str:
        key = hashlib.sha256(json.dumps([sha, self.failed['name'], self.failed['signature']], sort_keys=True).encode()).hexdigest()
        cache = self.cache / f'{key}.json'
        if hint and cache.exists():
            observed = json.loads(cache.read_text())['attempts'][0]
            self.record['probes'].append({**observed, 'reused': True})
            return observed['outcome']
        self.git('checkout', '--detach', sha)
        attempt = self.directory / f'probe-{len(self.record["probes"]):02d}-{sha[:12]}'
        lock = self.root / 'packages/gateway/package-lock.json'
        dependencies = hashlib.sha256(lock.read_bytes()).hexdigest() if lock.exists() else ''
        pure_static = self.failed.get('probe', {}).get('name') in {
            'ownership', 'budgets', 'documentation policy', 'agent policy', 'privacy guard',
            'git diff --check'}
        if not pure_static and dependencies != self.dependency_key:
            if not prepare(self.root, attempt / 'dependencies'):
                self.record['probes'].append({'commit': sha, 'outcome': 'unknown', 'reason': 'setup failure'})
                return 'unknown'
            self.dependency_key = dependencies
        try:
            outcome = execute(self.root, {**self.failed['probe'], 'probe': True}, attempt)
        finally:
            stop_fixture(self.root, attempt / 'stop')
        if selection_required and outcome.get('selectedTests') == 0:
            # The case failed at this commit, so a recipe selecting nothing is a broken selector, not a non-reproduction.
            self.record['probes'].append({'commit': sha, 'outcome': 'selector-error', 'fresh': True, **outcome})
            save(self.directory / 'progress.json', self.record)
            raise ProbeSelectionError(f"attribution probe for {self.failed['name']} selected no tests at {sha[:12]}: "
                                      f"{shlex.join(outcome['executedCommand'])}")
        if outcome.get('status') == 'uncovered' or outcome.get('exit') is None:
            state = 'unknown'
        elif outcome['exit'] == 0:
            state = 'good'
        elif outcome.get('signature') == self.failed['signature']:
            state = 'bad'
        else:
            # An exit alone is not proof that the same regression reproduced.
            state = 'unknown'
        observed = {'commit': sha, 'outcome': state, 'fresh': not hint, **outcome}
        self.record['probes'].append(observed)
        if hint and state != 'unknown':
            save(cache, {'attempts': [observed]})
        save(self.directory / 'progress.json', self.record)
        return state

    def controls(self, sha: str, expected: str, selection_required: bool = False) -> bool:
        """Two fresh executions must both observe `expected`; any mixture refuses."""
        return all(self.probe(sha, selection_required=selection_required) == expected for _ in range(2))

    def close(self) -> None:
        # Never erase a probe whose owning resource helper could not clean it.
        cleanup = []
        self.record.update(cleanup=cleanup, retainedWorktree=str(self.root))
        save(self.directory / 'progress.json', self.record)
        for script in ('scripts/ios-gateway-e2e-test', 'scripts/tron-ios-test'):
            if (self.root / script).is_file():
                try:
                    cleanup.append(execute(self.root, {'name': 'probe cleanup', 'command': [script, 'clean']}, self.directory / Path(script).name))
                except KeyboardInterrupt:
                    cleanup.append({'exit': 130, 'command': [script, 'clean'], 'status': 'interrupted'})
                    raise
                except OSError as error:
                    cleanup.append({'exit': 2, 'command': [script, 'clean'], 'error': str(error)})
                finally:
                    save(self.directory / 'progress.json', self.record)
        if self.preserve or any(item['exit'] for item in cleanup):
            print(f'batch: preserved probe worktree {self.root}', flush=True)
        else:
            verify.git('worktree', 'remove', '--force', str(self.root))
            shutil.rmtree(self.temporary)
            del self.record['retainedWorktree']
        save(self.directory / 'progress.json', self.record)


def parents(sha: str) -> int:
    return len(verify.git('rev-list', '--parents', '-n', '1', sha).split()) - 1


def attribute(base: str, head: str, failed: dict, prober: Prober) -> dict:
    """Propose by first-parent bisection, then prove with fresh head/parent/culprit controls."""
    commits = verify.git('rev-list', '--first-parent', '--reverse', f'{base}..{head}').splitlines()
    result = prober.record
    result.update(status='unresolved', candidates=commits)

    def unresolved(reason: str) -> dict:
        result['reason'] = reason
        return result
    if not failed.get('probe') or not failed.get('signature'):
        return unresolved('no exact-case selector or failure signature')
    if not commits:
        return unresolved('empty range')
    # A landing is one first-parent unit: an ordinary commit or a two-parent integration.
    octopus = [sha for sha in commits if parents(sha) > 2]
    if octopus:
        result['unsupportedHistory'] = octopus
        return unresolved('octopus landing on main first-parent history')
    # Only an exact-case Vitest recipe names one case known to exist; other recipes may select
    # nothing for real reasons (a file that fails to load), which stays an ordinary outcome.
    if not prober.controls(head, 'bad', selection_required=bool(failed['probe'].get('vitest'))):
        return unresolved('head did not reproduce the exact failure in two fresh executions')
    # `base` is the last raw-green batch; the search assumes it, the parent control proves it.
    low, high = -1, len(commits) - 1
    while high - low > 1:
        middle = (low + high) // 2
        state = prober.probe(commits[middle], hint=True)
        if state == 'unknown':
            return unresolved(f'unknown probe outcome at {commits[middle]}')
        if state == 'bad':
            high = middle
        else:
            low = middle
    culprit = commits[high]
    parent = verify.git('rev-parse', f'{culprit}^1').strip()
    if not prober.controls(parent, 'good'):
        return unresolved('first parent did not pass in two fresh executions')
    if culprit != head and not prober.controls(culprit, 'bad'):
        return unresolved('culprit did not reproduce in two fresh executions')
    result.update(status='proven', commit=culprit, parent=parent, merge=parents(culprit) == 2,
                  files=verify.git('diff', '--name-only', parent, culprit).splitlines())
    return result


def revert_remote() -> str | None:
    """The enable step: `git config tron.verify.revertRemote <remote>`; unset keeps publication off."""
    value = subprocess.run(['git', 'config', '--get', REVERT_REMOTE_KEY], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return value or None


def remote_main(remote: str) -> str | None:
    """Read the remote ref and its objects; never touch FETCH_HEAD or remote-tracking refs."""
    listed = subprocess.run(['git', 'ls-remote', remote, 'refs/heads/main'], cwd=ROOT, capture_output=True, text=True)
    fetched = subprocess.run(['git', 'fetch', '--quiet', '--no-tags', '--no-write-fetch-head', '--refmap=', remote, 'refs/heads/main'],
                             cwd=ROOT, capture_output=True, text=True)
    sha = listed.stdout.split()[0] if listed.returncode == 0 and listed.stdout.split() else None
    if not sha or fetched.returncode or subprocess.run(['git', 'cat-file', '-e', f'{sha}^{{commit}}'], cwd=ROOT).returncode:
        return None
    return sha


def patch_id(old: str, new: str) -> str:
    diff = subprocess.run(['git', 'diff', '--binary', '--full-index', old, new], cwd=ROOT, capture_output=True, check=True).stdout
    output = subprocess.run(['git', 'patch-id', '--stable'], cwd=ROOT, input=diff, capture_output=True, check=True).stdout.decode()
    return output.split()[0] if output.split() else ''


def irreversible(paths: list[str], revisions: tuple[str, str]) -> list[str]:
    """Migrations and persistence/security/installer owners keep maintainer authority."""
    found = {path for path in paths if 'migration' in path.lower()}
    for revision in revisions:
        result, _ = verify.ownership.check(revision)
        for module in result['modules'].values():
            if set(module['riskClass']) & IRREVERSIBLE_RISK:
                found |= set(module['owned']) & set(paths)
    return sorted(found)


def repair_path(state: Path, culprit: str) -> Path:
    return state / 'repairs' / f'{culprit}.json'


def case_identity(failed: dict) -> str:
    failures = (failed.get('signature') or {}).get('failures') or {}
    tests = (failed.get('signature') or {}).get('failedTests') or []
    return ', '.join([*failures, *tests]) or failed['name']


def build(journal: dict, prober: Prober, state: Path) -> dict:
    """Reproduce on the current tip, invert only the culprit landing, prove, and bind for review."""
    path = repair_path(state, journal['culprit'])
    culprit, parent = journal['culprit'], journal['parent']

    def settle(name: str, reason: str | None = None) -> dict:
        journal.update(state=name, reason=reason)
        journal['history'].append({'state': name, 'reason': reason, 'tip': journal.get('tip'), 'at': time.time()})
        save(path, journal)
        return journal
    remote = journal['remote']
    tip = remote_main(remote) if remote else journal['head']
    if not tip:
        return settle('pending', f'remote {remote} main unreadable; resumes on the next batch')
    journal['tip'] = tip
    if culprit not in verify.git('rev-list', '--first-parent', tip).splitlines():
        return settle('refused', 'culprit is not on the fetched main first-parent history')
    if tip != journal['head']:
        outcomes = [prober.probe(tip), prober.probe(tip)]
        if outcomes == ['good', 'good']:
            return settle('stale', 'the current main tip no longer fails; no revert')
        if outcomes != ['bad', 'bad']:
            return settle('refused', 'current main tip did not reproduce consistently')
    inverse = patch_id(culprit, parent)
    for sha in verify.git('rev-list', '--first-parent', f'{culprit}..{tip}').splitlines():
        if patch_id(f'{sha}^1', sha) == inverse:
            journal['revertCommit'] = sha
            return settle('already-reverted', f'{sha} already applies the exact inverse')
    boundary = irreversible(journal['files'], (parent, culprit))
    if boundary:
        return settle('refused', 'irreversible boundary (migration/persistence/security/installer): ' + ', '.join(boundary))
    prober.git('checkout', '--detach', tip)
    reverted = prober.git('revert', '--no-edit', *(['-m', '1'] if journal['merge'] else []), culprit, check=False)
    if reverted.returncode:
        prober.preserve = True
        journal.update(worktree=str(prober.root), revertError=reverted.stdout + reverted.stderr)
        return settle('refused', 'revert conflict; preserved unresolved for diagnosis')
    candidate = prober.git('rev-parse', 'HEAD').stdout.strip()
    tree = prober.git('rev-parse', 'HEAD^{tree}').stdout.strip()
    journal.update(candidate=candidate, candidateTree=tree)
    if not prober.controls(candidate, 'good'):
        return settle('refused', 'the inverse did not remove the failure in two fresh executions')
    prober.git('checkout', '--detach', candidate)
    affected = execute(prober.root, {'name': 'affected verify', 'command': ['scripts/tron', 'verify', '--changed', '--base', tip]},
                       Path(prober.directory) / f'affected-{candidate[:12]}')
    report = prober.root / 'test-results/verify' / f'{candidate}.json'
    verdict = json.loads(report.read_text()).get('verdict') if report.exists() else None
    journal['affected'] = {'exit': affected['exit'], 'verdict': verdict, 'log': affected.get('log')}
    if affected['exit'] != 0 or verdict != 'passed':
        return settle('refused', 'affected checks on the candidate did not pass')
    if not verify.git('for-each-ref', f'refs/heads/revert/{culprit}').strip():
        verify.git('branch', f'revert/{culprit}', candidate)
    evidence = Path(journal['evidence'])
    if not evidence_intact(evidence):
        return settle('refused', 'frozen first-failure evidence changed after sealing')
    bindings = {'culprit': culprit, 'parent': parent, 'tip': tip, 'candidateTree': tree, 'patchId': inverse,
                'recipe': journal['investigation']['probe'], 'signature': journal['investigation']['signature'],
                'redReport': journal['redReport'], 'evidence': str(evidence),
                'evidenceDigest': hashlib.sha256(evidence.read_bytes()).hexdigest()}
    digest = hashlib.sha256(json.dumps(bindings, sort_keys=True).encode()).hexdigest()
    request = path.parent / culprit / f'review-{digest[:16]}.json'
    request.parent.mkdir(parents=True, exist_ok=True)
    save(request, {'bindings': bindings, 'bindingDigest': digest, 'candidate': candidate, 'case': case_identity(journal['investigation']),
                   'review': 'A non-author reviewer verifies source causality, surviving oracles, no unrelated removals, '
                             'reversibility and no migration/security/production effect, then records ACCEPT or BLOCK '
                             'against this exact bindingDigest.'})
    journal.update(bindings=bindings, bindingDigest=digest, reviewRequest=str(request))
    return settle('review-required' if remote else 'publication-disabled')


def resumable(journal: dict) -> bool:
    """Interrupted or remote-blocked builds resume; a disabled repair resumes once enabled."""
    return journal['state'] in ('building', 'pending') or (journal['state'] == 'publication-disabled' and bool(revert_remote()))


def investigate(base: str, head: str, failed: dict, directory: Path, state: Path, red: dict) -> tuple[dict, dict | None]:
    """Attribute once per range and signature; repair once per culprit landing."""
    key = hashlib.sha256(json.dumps([base, head, failed['name'], failed.get('signature')], sort_keys=True).encode()).hexdigest()
    memo = state / 'attributions' / f'{key}.json'
    attribution = {**json.loads(memo.read_text()), 'reused': True} if memo.exists() else None
    if attribution and attribution.get('status') == 'proven':
        path = repair_path(state, attribution['commit'])
        if not path.exists():
            # A proof is only trusted beside the repair journal it produced; re-prove otherwise.
            attribution = None
        elif not resumable(json.loads(path.read_text())):
            return attribution, json.loads(path.read_text())
    elif attribution:
        return attribution, None
    start = time.monotonic()
    prober = Prober(failed, directory, state, attribution or {})
    journal = None
    try:
        if not attribution:
            attribution = attribute(base, head, failed, prober)
        if attribution.get('status') == 'proven':
            path = repair_path(state, attribution['commit'])
            if path.exists():
                journal = json.loads(path.read_text())
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                journal = {'culprit': attribution['commit'], 'parent': attribution['parent'],
                           'merge': parents(attribution['commit']) == 2, 'files': attribution['files'], 'head': head,
                           'investigation': failed, **red, 'state': 'building', 'history': [], 'reviews': []}
                save(path, journal)
            if resumable(journal):
                journal['remote'] = revert_remote()
                journal = build(journal, prober, state)
    finally:
        prober.close()
        if attribution and not attribution.get('reused'):
            attribution['hostSeconds'] = round(time.monotonic() - start, 3)
            memo.parent.mkdir(parents=True, exist_ok=True)
            save(memo, attribution)
    return attribution, journal


def reconcile(journal: dict, path: Path) -> str:
    """Settle a dispatched push from remote state; the push exit alone settles nothing."""
    commit = journal['publishedCommit']
    current = remote_main(journal['remote'])
    if not current:
        journal['state'] = 'push-uncertain'
    elif subprocess.run(['git', 'merge-base', '--is-ancestor', commit, current], cwd=ROOT).returncode == 0:
        journal.update(state='published', reason=None, remoteMain=current)
    elif current == journal['tip']:
        # Positively not applied and main unchanged: the bound ACCEPT may be presented again.
        journal.update(state='review-required', reason='push not applied; remote main unchanged')
    else:
        journal.update(state='review-required', reason='remote main advanced', remoteMain=current)
    journal['history'].append({'state': journal['state'], 'reason': journal.get('reason'), 'remoteMain': current, 'at': time.time()})
    save(path, journal)
    return journal['state']


def issue_write(key: str, title: str, body: str, directory: Path, state: Path, target: int | None = None) -> dict:
    # The batch lock serializes this journal. Persist BEFORE dispatch: a killed or
    # uncertain GitHub write must not become a second create on an operator rerun.
    journal = state / 'issue-writes' / f'{key}.json'
    previous = json.loads(journal.read_text()) if journal.exists() else None
    if previous and (not previous.get('number') or previous.get('status') != 'completed'):
        print(f'batch: retaining prior issue-write outcome: {journal}', flush=True)
        return {**previous, 'reused': True}
    journal.parent.mkdir(parents=True, exist_ok=True)
    number = previous.get('number') if previous else target
    save(journal, {'status': 'attempting', 'exit': None, 'directory': str(directory), 'number': number})
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'issue.md').write_text(body)
    command = (['scripts/tron', 'work', 'comment', str(number), '--body-file', str(directory / 'issue.md')] if number else
               ['scripts/tron', 'work', 'issue', 'create', '--title', title, '--body-file', str(directory / 'issue.md'),
                '--kind', 'kind:bug', '--area', 'area:tooling'])
    outcome = execute(ROOT, {'name': 'issue write', 'command': command}, directory / 'issue')
    if 'log' not in outcome:
        # The batch stopped before dispatch: nothing reached GitHub, so the journal goes back to what it was.
        save(journal, previous) if previous else journal.unlink()
        return {**outcome, 'number': number}
    match = re.search(r'(?:/issues/|created issue #)(\d+)', Path(outcome['log']).read_text(errors='replace'))
    outcome = {**outcome, 'status': 'completed' if outcome['exit'] == 0 else 'unresolved', 'number': int(match[1]) if match else number}
    save(journal, outcome)
    return outcome


def failure_key(failed: dict) -> str:
    return hashlib.sha256(json.dumps([failed['name'], failed.get('signature')], sort_keys=True).encode()).hexdigest()


def repair_summary(journal: dict | None) -> str:
    if not journal:
        return 'No source revert: attribution is unresolved; diagnose the root cause.\n'
    text = f"Repair of `{journal['culprit']}`: **{journal['state']}**" + (f" — {journal['reason']}" if journal.get('reason') else '') + '.\n'
    if journal['state'] == 'review-required':
        text += f"Review request: `{relative(journal['reviewRequest'])}` (binding `{journal['bindingDigest']}`).\n"
    return text


def relative(path: str) -> str:
    common = Path(verify.git('rev-parse', '--path-format=absolute', '--git-common-dir').strip())
    return str(Path(path).relative_to(common)) if Path(path).is_relative_to(common) else Path(path).name


def file_issue(report: dict, directory: Path, state: Path) -> dict:
    attribution, journal = report['attribution'], report.get('repair')
    body = ('## Failed verification batch\n\n'
            f"Range: `{report['base']}..{report['head']}`; {len(report['commits'])} covered commits.\n"
            f"Lane: {report['failed']['name']}; attribution: {attribution['status']}"
            + (f" ({attribution['reason']})" if attribution.get('reason') else '') + '.\n\n'
            + (f"Causal landing: `{attribution['commit']}` (first parent `{attribution['parent']}`).\n" if attribution.get('commit') else
               'Candidates: ' + ', '.join(f"`{sha}`" for sha in attribution.get('candidates', [])) + '.\n')
            + repair_summary(journal)
            + '\nFiles: ' + ', '.join(f'`{p}`' for p in attribution.get('files', report['files']))
            + '\n\nThe first failure, exact commands, counts and logs are frozen in the repository-local '
            f"Git common directory at `verify/batches/{directory.parent.name}/` (`evidence.json` manifest). "
            'No test, golden, assertion or timeout changed. The red stays red until a raw-green batch.\n')
    key = failure_key(report['failed'])
    return issue_write(key, f"Verification: {report['failed']['name']} [{key[:12]}]", body, directory, state)


def failure_cases(outcome: dict) -> list[dict]:
    """One stable signature and one exact-case probe per failure, never a suite probe."""
    cases = []
    if outcome.get('vitest') and outcome.get('failureComplete'):
        for identity, digest in outcome.get('failures', {}).items():
            file = identity.split('::', 1)[0]
            names = outcome.get('caseNames', {}).get(identity)
            if not names:
                continue
            command = outcome['command']
            cases.append({**outcome, 'signature': {'failures': {identity: digest}},
                          'probe': {'name': outcome['name'], 'vitest': True, 'gatewayLock': bool(outcome.get('gatewayLock')),
                                    'command': [*command, file.removeprefix(outcome.get('testRoot', 'packages/gateway') + '/'), '-t', '^' + re.escape(' > '.join(names)) + '$']}})
    # Other owners may only be probed if the recorded invocation is already a case filter.
    elif outcome.get('xctestCases') and outcome.get('signature'):
        for case in outcome['xctestCases']:
            # Build remains at each revision; execution selects one class/method.
            cases.append({**outcome, 'signature': {**outcome['signature'], 'failedTests': [case]},
                          'probe': {'name': outcome['name'], 'command': [*outcome['command'], case.split('/', 1)[1]]}})
    elif outcome.get('probe') and '--only-testing' in outcome['probe'].get('command', []):
        cases.append(outcome)
    return cases


def batch_verdict(results: list[dict]) -> str:
    if any(item.get('status') == 'uncovered' or item.get('exit') is None for item in results):
        return 'uncovered'
    return 'red' if any(item['exit'] for item in results) else 'green'


def freeze(directory: Path) -> Path:
    """Seal the first failure after every lane joined and before any probe runs."""
    shutil.copy2(directory / 'report.json', directory / 'first-report.json')
    files = {}
    for path in sorted(directory.rglob('*')):
        if path.is_file() and path.name != 'report.json':
            files[str(path.relative_to(directory))] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = directory / 'evidence.json'
    save(manifest, {'files': files})
    return manifest


def evidence_intact(manifest: Path, digest: str | None = None) -> bool:
    try:
        files = json.loads(manifest.read_text())['files']
        return ((digest is None or hashlib.sha256(manifest.read_bytes()).hexdigest() == digest)
                and all(hashlib.sha256((manifest.parent / name).read_bytes()).hexdigest() == value for name, value in files.items()))
    except (OSError, ValueError, KeyError):
        return False


def next_action(journal: dict) -> dict:
    item = {'culprit': journal['culprit'], 'state': journal['state'], 'reason': journal.get('reason')}
    if journal['state'] == 'review-required':
        item.update(reviewRequest=journal['reviewRequest'],
                    next=f"scripts/tron verify --batch --review {journal['culprit']} --decision ACCEPT|BLOCK "
                         f"--reviewer <non-author review id> --binding {journal['bindingDigest']}")
    return item


class Locks:
    """The nonwaiting repository batch lock. The host's full-Gateway lock is per Gateway lane (`execute`)."""

    def __init__(self, state: Path):
        state.mkdir(exist_ok=True)
        self.handle = (state / 'batch.lock').open('a')

    def __enter__(self):
        try:
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.__exit__()
            raise verify.VerifyError('another batch owns this repository; no queue or wait') from None
        return self

    def __exit__(self, *_):
        self.handle.close()


def review(args, state: Path) -> int:
    """Record a non-author decision bound to one exact review request, then publish or refuse."""
    path = repair_path(state, args.review)
    with Locks(state):
        if not path.exists():
            raise verify.VerifyError(f'no repair journal for {args.review}')
        journal = json.loads(path.read_text())
        if journal['state'] in ('push-intent', 'push-uncertain'):
            settled = reconcile(journal, path)
            print(json.dumps({'repairResult': settled, 'culprit': journal['culprit']}), flush=True)
            if settled == 'published':
                notify_published(journal, state)
                return 0
            if settled == 'push-uncertain':
                return 2
        if journal['state'] != 'review-required':
            raise verify.VerifyError(f"repair {journal['culprit'][:12]} is {journal['state']}, not awaiting review")
        if args.binding != journal['bindingDigest']:
            raise verify.VerifyError('review binding does not match the current review request; nothing recorded')
        journal['reviews'].append({'decision': args.decision, 'reviewer': args.reviewer, 'binding': args.binding, 'at': time.time()})
        if args.decision == 'BLOCK':
            journal.update(state='refused', reason=f'reviewer {args.reviewer} BLOCK')
            save(path, journal)
            print(json.dumps({'repairResult': 'refused', 'culprit': journal['culprit']}), flush=True)
            return 1
        save(path, journal)
        current = remote_main(journal['remote'])
        if not current:
            raise verify.VerifyError('remote main unreadable; nothing published')
        if current != journal['bindings']['tip']:
            # A stale ACCEPT never publishes. Rebuild once at the new tip; it needs a fresh review.
            directory = path.parent / journal['culprit'] / f'rebuild-{time.time_ns()}'
            prober = Prober(journal['investigation'], directory, state, {})
            try:
                journal['history'].append({'state': 'stale-binding', 'tip': journal['tip'], 'remoteMain': current, 'at': time.time()})
                build(journal, prober, state)
            finally:
                prober.close()
            print(json.dumps({'repairResult': journal['state'], **next_action(journal)}), flush=True)
            return 1
        bindings = journal['bindings']
        if not evidence_intact(Path(bindings['evidence']), bindings['evidenceDigest']):
            journal.update(state='refused', reason='frozen first-failure evidence changed after review binding')
            save(path, journal)
            print(json.dumps({'repairResult': 'refused', 'culprit': journal['culprit']}), flush=True)
            return 1
        message = (f"Revert landing {journal['culprit'][:12]} after a causal full-main red\n\n"
                   f"Automatic source revert of main landing {journal['culprit']} (first parent {journal['parent']}).\n"
                   f"Failing case: {case_identity(journal['investigation'])}\n"
                   f"Red batch: {relative(journal['redReport'])}; evidence {relative(bindings['evidence'])} "
                   f"({bindings['evidenceDigest'][:16]}).\nRoot-fix with fail-before/pass-after and review before relanding.\n\n"
                   f"Tron-Auto-Revert: {journal['culprit']}\nTron-Review-Binding: {journal['bindingDigest']}\n"
                   f"Tron-Reviewer: {args.reviewer}\n")
        commit = subprocess.run(['git', 'commit-tree', bindings['candidateTree'], '-p', bindings['tip'], '-F', '-'],
                                cwd=ROOT, input=message, capture_output=True, text=True, check=True).stdout.strip()
        if verify.git('rev-parse', f'{commit}^{{tree}}').strip() != bindings['candidateTree']:
            raise verify.VerifyError('published tree differs from the reviewed tree')
        journal.update(state='push-intent', publishedCommit=commit)
        save(path, journal)
        pushed = subprocess.run(['git', 'push', '--porcelain', journal['remote'], f'{commit}:refs/heads/main'],
                                cwd=ROOT, capture_output=True, text=True)
        journal['push'] = {'exit': pushed.returncode, 'output': pushed.stdout + pushed.stderr}
        save(path, journal)
        settled = reconcile(journal, path)
        print(json.dumps({'repairResult': settled, **next_action(journal)}), flush=True)
        if settled == 'published':
            notify_published(journal, state)
            return 0
        return 2 if settled == 'push-uncertain' else 1


def notify_published(journal: dict, state: Path) -> None:
    failure = state / 'issue-writes' / f"{failure_key(journal['investigation'])}.json"
    number = json.loads(failure.read_text()).get('number') if failure.exists() else None
    if not number:
        return
    body = (f"Published automatic source revert `{journal['publishedCommit']}` of `{journal['culprit']}` onto main "
            f"`{journal['tip']}` after review binding `{journal['bindingDigest']}`. The landing's owner root-fixes "
            'with fail-before/pass-after and review before relanding; the red stays recorded.\n')
    journal['notification'] = issue_write(f"published-{journal['culprit']}", '', body,
                                          repair_path(state, journal['culprit']).parent / journal['culprit'] / 'notify', state, number)
    save(repair_path(state, journal['culprit']), journal)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog='scripts/tron verify --batch')
    parser.add_argument('--base', help='explicit main starting anchor on first use; not green until this batch proves it')
    parser.add_argument('--repeat', action='store_true', help='rerun all lanes at the already-green HEAD')
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--review', metavar='CULPRIT', help='record a review decision for one repair request')
    parser.add_argument('--decision', choices=('ACCEPT', 'BLOCK'))
    parser.add_argument('--reviewer')
    parser.add_argument('--binding')
    args = parser.parse_args(argv)
    if args.repeat and args.base:
        parser.error('--repeat cannot be combined with --base')
    if args.review and not (args.decision and args.reviewer and args.binding):
        parser.error('--review needs --decision, --reviewer and --binding')
    state = Path(verify.git('rev-parse', '--path-format=absolute', '--git-common-dir').strip()) / 'verify'
    try:
        if args.review:
            return review(args, state)
        if verify.git('status', '--porcelain', '--untracked-files=normal').strip():
            raise verify.VerifyError('batch needs a clean dedicated worktree')
        head = verify.git('rev-parse', 'HEAD').strip()
        green_path = state / 'green.json'
        green = json.loads(green_path.read_text()) if green_path.exists() else None
        if green and args.base:
            raise verify.VerifyError('--base only initializes a missing last-green record; never skips failed coverage')
        if not green and not args.base:
            raise verify.VerifyError('no green batch: supply --base <main-anchor> explicitly on first use')
        base = green['commit'] if green else verify.git('rev-parse', '--verify', f'{args.base}^{{commit}}').strip()
        # A batch covers landed main only; pin a snapshot, never fetch/merge another worker's checkout.
        fetch_head = Path(verify.git('rev-parse', '--git-path', 'FETCH_HEAD').strip())
        ref = ('FETCH_HEAD' if fetch_head.is_file() else
               'origin/main' if verify.git('for-each-ref', 'refs/remotes/origin/main').strip() else 'main')
        ancestry = verify.git('rev-list', '--first-parent', ref).splitlines()
        if head not in ancestry or base not in ancestry[ancestry.index(head):]:
            raise verify.VerifyError('batch base and HEAD must be ordered commits on main first-parent history')
        if args.repeat and green['commit'] != head:
            raise verify.VerifyError('--repeat requires HEAD to equal the last green commit')
        commits = verify.git('rev-list', '--reverse', f'{base}..{head}').splitlines()
        files = verify.git('diff', '--name-only', base, head).splitlines()
        plan = {'base': base, 'head': head, 'commits': commits, 'files': files, 'lanes': lanes(ROOT, base)}
        if args.plan:
            print(json.dumps(plan, indent=2))
            return 0
        with Locks(state):
            current = json.loads(green_path.read_text()) if green_path.exists() else None
            if current != green:
                raise verify.VerifyError('last-green changed while planning; rerun against its current coverage')
            # Settle any dispatched revert push before new repair work.
            for path in sorted((state / 'repairs').glob('*.json')):
                journal = json.loads(path.read_text())
                if journal['state'] in ('push-intent', 'push-uncertain') and reconcile(journal, path) == 'published':
                    notify_published(journal, state)
            if head == base and green and not args.repeat:
                print(f'batch: no uncovered commits after {head[:12]}')
                return 0
            directory = state / 'batches' / f'{base[:12]}-{head[:12]}-{time.time_ns()}'
            directory.mkdir(parents=True)
            timestamp = int(verify.git('show', '-s', '--format=%ct', base).strip())
            report = {**plan, 'verdict': 'running', 'results': [], 'failures': [], 'setup': [],
                      'rangeAgeSeconds': max(0, round(time.time() - timestamp)), 'attributionHostSeconds': 0}
            path = directory / 'report.json'
            save(path, report)
            try:
                def source_unchanged():
                    if verify.git('rev-parse', 'HEAD').strip() != head or verify.git('status', '--porcelain', '--untracked-files=normal').strip():
                        raise verify.VerifyError('source changed during batch; no green coverage recorded')
                for package in ('gateway', 'push-relay'):
                    if (ROOT / f'packages/{package}/package-lock.json').is_file():
                        try:
                            setup = execute(ROOT, {'name': f'{package} dependencies', 'command': [
                                'scripts/tron-node', 'exec', 'npm', '--prefix', f'packages/{package}', 'ci', '--include=dev']},
                                directory / f'dependencies-{package}')
                        except (OSError, subprocess.SubprocessError) as error:
                            setup = {'exit': 2, 'error': str(error), 'name': f'{package} dependencies'}
                        report['setup'].append(setup)
                        save(path, report)
                # `results` stays in plan order whichever chain finishes a lane first.
                outcomes, active, report_lock = {}, {}, threading.Lock()

                def record(change):
                    with report_lock:
                        change()
                        report['activeLane'] = ' + '.join(active[chain] for chain in CHAINS if chain in active) or report.get('activeLane')
                        report['results'] = [outcomes[index] for index in sorted(outcomes)]
                        save(path, report)

                def run_lane(index, lane):
                    source_unchanged()
                    record(lambda: active.update({lane['chain']: lane['name']}))
                    if lane['name'] == UI_JOURNEY_LANE:
                        seconds = previous_journey_seconds(state, directory)
                        if seconds:
                            durations = directory / f'lane-{index}' / 'previous-journey-seconds.json'
                            durations.parent.mkdir(parents=True, exist_ok=True)
                            save(durations, seconds)
                            lane = {**lane, 'env': {**lane.get('env', {}), 'TRON_IOS_E2E_UI_JOURNEY_SECONDS': str(durations)}}
                    try:
                        outcome = execute(ROOT, lane, directory / f'lane-{index}')
                    except (OSError, ValueError, KeyError, verify.VerifyError, subprocess.SubprocessError) as error:
                        outcome = {**lane, 'exit': None, 'status': 'uncovered', 'error': str(error), 'seconds': 0}
                    try:
                        outcome['timing'] = timing.lane_timing(outcome, directory / f'lane-{index}', ROOT)
                    except Exception as error:  # observation only: never a verdict input
                        outcome['timing'] = {'errors': [f'{type(error).__name__}: {error}']}
                    record(lambda: (outcomes.update({index: outcome}), active.pop(lane['chain'], None)))
                    source_unchanged()

                chains = [[(index, lane) for index, lane in enumerate(plan['lanes']) if lane['chain'] == chain] for chain in CHAINS]
                print('batch: concurrent chains: ' + '; '.join(f"{name}: " + ' → '.join(lane['name'] for _, lane in items)
                                                               for name, items in zip(CHAINS, chains)), flush=True)
                run_chains(chains, run_lane)
                report['fixtureCleanup'] = stop_fixture(ROOT, directory / 'fixture-stop')
                save(path, report)
                # Finish coverage and freeze it before spending any host time on attribution.
                red = [(index, outcome) for index, outcome in enumerate(report['results']) if outcome.get('exit')]
                if red:
                    manifest = freeze(directory)
                    report['evidence'] = str(manifest)
                    save(path, report)
                for index, outcome in red:
                    cases = failure_cases(outcome)
                    if not cases:
                        # Nothing exact to bisect: the red is filed unresolved and the suite is never rerun.
                        reason = 'owner provided no exact-case attribution selector'
                        outcome.update(status='uncovered', reason=reason)
                    for case_index, failed in enumerate(cases or [outcome]):
                        if cases:
                            report['activeLane'] = f"attribution: {failed['name']}"
                            attribution, journal = investigate(base, head, failed, directory / f'attribution-{index}-{case_index}', state,
                                                               {'redReport': str(directory / 'first-report.json'), 'evidence': str(manifest)})
                        else:
                            attribution, journal = {'status': 'unresolved', 'reason': reason, 'candidates': commits}, None
                        report['attributionHostSeconds'] += attribution.get('hostSeconds', 0) if not attribution.get('reused') else 0
                        item = {'failed': failed, 'attribution': attribution, 'repair': journal}
                        item['issue'] = file_issue({**report, **item}, directory / f'failure-{index}-{case_index}', state)
                        report['failures'].append(item)
                        save(path, report)
                source_unchanged()
                report['verdict'] = ('uncovered' if (any(item['exit'] for item in report['setup'])
                                                      or (report.get('fixtureCleanup') or {}).get('exit'))
                                     else batch_verdict(report['results']))
                save(path, report)
                if report['verdict'] == 'green':
                    save(green_path, {'commit': head, 'report': str(path), 'verdict': 'green'})
                return 0 if report['verdict'] == 'green' else 1
            except KeyboardInterrupt:
                report['verdict'] = 'interrupted'
                save(path, report)
                print(f'batch: INTERRUPTED; partial evidence {path}; last-green unchanged', flush=True)
                return 130
            except (verify.VerifyError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                report.update(verdict='error', error=str(error))
                save(path, report)
                failed = {'name': report.get('activeLane', 'batch infrastructure')}
                try:
                    report['issue'] = file_issue({**report, 'failed': failed, 'attribution': {
                        'status': 'unresolved', 'reason': 'infrastructure/source changed', 'candidates': commits}},
                        directory / 'failure-infrastructure', state)
                except (OSError, ValueError, subprocess.SubprocessError) as issue_error:
                    report['issueError'] = str(issue_error)
                save(path, report)
                print(f'batch: ERROR ({error}); partial evidence {path}; last-green unchanged', flush=True)
                return 2
            finally:
                try:
                    if 'fixtureCleanup' not in report:
                        report['fixtureCleanup'] = stop_fixture(ROOT, directory / 'fixture-stop')
                        save(path, report)
                except (OSError, subprocess.SubprocessError) as error:
                    report['cleanupError'] = str(error)
                    save(path, report)
                repairs = [next_action(item['repair']) for item in report['failures'] if item.get('repair')]
                print(json.dumps({'batchResult': report['verdict'], 'head': head, 'report': str(path), 'repairs': repairs,
                                  'delivery': 'Home caller must acknowledge this result and act on each repair next step'}), flush=True)
    except (verify.VerifyError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'batch: {error}', flush=True)
        return 2
