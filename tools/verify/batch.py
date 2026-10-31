"""Explicit local batch coverage. No scheduler, merge gate, or production lifecycle."""
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
import time

import verify

ROOT = verify.ROOT


def save(path: Path, value: dict) -> None:
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, path)


def lanes(root: Path, base: str) -> list[dict]:
    """Compose existing owners, not a second test catalog."""
    # Required lanes never disappear when a checkout/tool is missing.
    result = [{'name': 'full verify', 'command': ['scripts/tron', 'verify', '--all', '--base', base]}]
    for name, config in [('Gateway default', []), ('Gateway nested', ['--config', 'vitest.nested.config.ts'])]:
        result.append({'name': name, 'command': ['python3', 'tools/verify/gateway.py', *config],
                       'vitest': True, 'requires': 'packages/gateway/package-lock.json'})
    result.extend([
        {'name': 'Mac integration', 'command': 'scripts/tron mac generate && scripts/tron-xcodebuild build-for-testing -project packages/mac-app/TronMac.xcodeproj -scheme TronMac -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath packages/mac-app/build/DerivedData && xcodebuild test-without-building -project packages/mac-app/TronMac.xcodeproj -scheme TronMac -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath packages/mac-app/build/DerivedData',
         'requires': 'packages/mac-app/project.yml'},
        {'name': 'relay', 'command': ['scripts/tron-node', 'exec', 'npm', '--prefix', 'packages/push-relay', 'test', '--'],
         'vitest': True, 'testRoot': 'packages/push-relay', 'requires': 'packages/push-relay/package-lock.json'},
        {'name': 'shipping iOS compile', 'command': ['scripts/tron-ios-device', 'compile'],
         'requires': 'packages/ios-app/project.yml', 'ios': True},
        {'name': 'iOS smoke', 'command': ['scripts/tron-ios-test', 'checkpoint'],
         'requires': 'scripts/tron-ios-test', 'ios': True},
        {'name': 'real Gateway boundary', 'command': ['scripts/ios-gateway-e2e-test', 'all'],
         'requires': 'scripts/ios-gateway-e2e-test', 'ios': True},
        {'name': 'real Gateway UI journeys', 'command': ['scripts/ios-gateway-e2e-test', 'run-ui'],
         'requires': 'scripts/ios-gateway-e2e-test', 'ios': True},
    ])
    return result


def signature(message: str, failures: list[str], output: str, root: Path) -> dict | None:
    # A test identity alone cannot distinguish a code regression from setup failing
    # in that same case (for example missing staged products at the baseline).
    diagnostics = re.findall(r'^(?:AssertionError:|Error:|error:|failure:|unowned:|overlap:|.+:\d+: error:).+$', output, re.M)
    diagnostics = sorted(line.replace(str(root), '<worktree>') for line in diagnostics[:20])
    failures = sorted(line.replace(str(root), '<worktree>') for line in failures)
    return {'message': message, 'failedTests': failures, 'diagnostics': diagnostics} if diagnostics else None


def host_slots_busy(root: Path) -> bool | None:
    owner = root / 'scripts/ios-test-lock.py'
    if not owner.is_file():
        return None
    spec = importlib.util.spec_from_file_location('batch_ios_lock', owner)
    locker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(locker)
    return all(locker.read_slot_holders())


def execute(root: Path, lane: dict, directory: Path) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / 'output.log'
    print(f"batch: {lane['name']} … live log: {log}", flush=True)
    start = time.monotonic()
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
    if lane['name'] == 'Mac integration':
        home, scratch = directory / 'home', directory / 'tmp'
        home.mkdir(exist_ok=True, mode=0o700)
        scratch.mkdir(exist_ok=True, mode=0o700)
        command = command.replace('&& xcodebuild ', f'&& env HOME={shlex.quote(str(home))} TMPDIR={shlex.quote(str(scratch))} xcodebuild ')
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
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=root / lane.get('cwd', '.'), shell=isinstance(command, str),
                                   stdout=output, stderr=subprocess.STDOUT,
                                   env={**os.environ, 'TRON_IOS_E2E_NO_INSTALL': '1'}, start_new_session=True)
        try:
            code = process.wait()
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
    result = {**lane, 'exit': code, 'seconds': round(time.monotonic() - start, 3), 'log': str(log), 'executedCommand': command}
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
            result['expiredEntries'] = report.get('expiredEntries', [])
            if report.get('commit') != sha or verdict not in ('passed', 'quarantined', 'expired', 'deferred', 'failed'):
                result.update(status='uncovered', reason='incomplete or wrong-SHA verifier report')
            elif verdict == 'expired' or report.get('expiredEntries'):
                result['status'] = 'red'
            elif verdict == 'quarantined' and not deferred_ios:
                result['status'] = 'qualified'
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
            if (not case_complete or not (data.get('numPassedTests', 0) + data.get('numFailedTests', 0))
                    or data.get('numPendingTests') or data.get('numPendingTestSuites')):
                result.update(status='uncovered', reason='empty or skipped cases')
        else:
            result.update(status='uncovered', reason='missing test report')
    elif lane.get('probe'):
        output = log.read_text(errors='replace')
        group = lane['name'].removeprefix('tests: ')
        failures = []
        count = 0 if lane['name'].startswith('tests:') else None
        if vitest and vitest.exists():
            data = json.loads(vitest.read_text())
            count = data.get('numPassedTests', 0)
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
        counts = re.findall(r'Executed (\d+) tests?', output)
        if code == 0 and (not counts or int(counts[-1]) == 0 or re.search(r'\d+ tests? skipped', output)):
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
    if lane['name'] == 'real Gateway UI journeys' and code:
        failed_journeys = re.findall(r'Real-UI journey (\w+/\w+/\w+) completed .*\(status [1-9]\d*\)', output)
        if len(failed_journeys) == 1:
            result['probe'] = {'name': lane['name'], 'ios': True, 'command': [
                'scripts/ios-gateway-e2e-test', 'run-ui', '--only-testing', failed_journeys[0]]}
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


def attribute(base: str, head: str, failed: dict, directory: Path) -> dict:
    """Prove the baseline, then bisect main's integration commits, never a live worker tree."""
    commits = verify.git('rev-list', '--first-parent', '--reverse', f'{base}..{head}').splitlines()
    result = {'status': 'inconclusive', 'candidates': commits, 'probes': []}
    # Never rerun a complete suite to diagnose one case, nor attribute setup errors.
    if not failed.get('probe') or not failed.get('signature') or not commits:
        return result
    malformed = [sha for sha in commits if len(verify.git('rev-list', '--parents', '-n', '1', sha).split()) != 3]
    result['nonLandingCommits'] = malformed
    directory.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='tron-verify-bisect-')).resolve()
    root = temporary / 'repo'
    verify.git('worktree', 'add', '--detach', str(root), base)
    try:
        # One probe worktree preserves Xcode incrementals across revisions. npm installs stay local.
        dependency_key = None
        probe_state = Path(verify.git('rev-parse', '--path-format=absolute', '--git-common-dir').strip()) / 'verify/probes'
        probe_state.mkdir(parents=True, exist_ok=True)
        def probe(sha: str, repeat: bool = False) -> str:
            nonlocal dependency_key
            key = hashlib.sha256(json.dumps([sha, failed['name'], failed['signature']], sort_keys=True).encode()).hexdigest()
            cache = probe_state / f'{key}.json'
            attempts = json.loads(cache.read_text())['attempts'] if cache.exists() else []
            required = 2 if repeat else 1
            if len(attempts) >= required:
                observed = attempts[required - 1]
                result['probes'].append({**observed, 'reused': True})
                return observed['outcome']
            subprocess.run(['git', 'checkout', '--detach', sha], cwd=root, check=True, capture_output=True)
            attempt = directory / f'probe-{len(result["probes"]):02d}-{sha[:12]}'
            lock = root / 'packages/gateway/package-lock.json'
            key = hashlib.sha256(lock.read_bytes()).hexdigest() if lock.exists() else ''
            pure_static = failed.get('probe', {}).get('name') in {
                'ownership', 'budgets', 'documentation policy', 'agent policy', 'privacy guard',
                'git diff --check', 'moved-lines (advisory)'}
            if not pure_static and key != dependency_key:
                if not prepare(root, attempt / 'dependencies'):
                    result['probes'].append({'commit': sha, 'outcome': 'setup failure'})
                    return 'unknown'
                dependency_key = key
            try:
                lane = {**failed['probe'], 'probe': True}
                outcome = execute(root, lane, attempt)
            finally:
                stop_fixture(root, attempt / 'stop')
            if outcome['exit'] == 0:
                state = 'good'
            elif failed.get('signature') and outcome.get('signature') == failed['signature']:
                state = 'bad'
            else:
                # An exit alone is not proof that the same regression reproduced.
                state = 'unknown'
            observed = {'commit': sha, 'outcome': state, **outcome}
            result['probes'].append(observed)
            if state != 'unknown':
                save(cache, {'attempts': [*attempts, observed]})
            save(directory / 'progress.json', result)
            return state
        baseline = probe(base)
        if baseline == 'bad':
            result['status'] = 'pre-existing at baseline'
            return result
        if baseline != 'good':
            return result
        # Reproduce head in the same isolated environment before attributing a host failure.
        head_state = probe(head)
        if head_state != 'bad':
            if head_state == 'good':
                result['status'] = 'flake observed; registry entry required'
            return result
        low, high = -1, len(commits) - 1
        while high - low > 1:
            middle = (low + high) // 2
            state = probe(commits[middle])
            if state == 'unknown':
                return result
            if state == 'bad':
                high = middle
            else:
                low = middle
        culprit = commits[high]
        parent = verify.git('rev-parse', f'{culprit}^1').strip()
        # low is the already-observed good parent; high is already-observed bad.
        # One independent repeat proves the signature twice without suite reruns.
        if malformed or parent != (commits[low] if low >= 0 else base) or probe(culprit, repeat=True) != 'bad':
            return result
        result.update(status='proven', commit=culprit, parent=parent,
                      files=verify.git('diff', '--name-only', parent, culprit).splitlines())
        branch = f'revert/{culprit}'
        exists = verify.git('for-each-ref', f'refs/heads/{branch}').strip()
        if exists:
            result['revertBranch'] = branch
            result['revertStatus'] = 'existing; not overwritten'
        else:
            subprocess.run(['git', 'checkout', '-b', branch, head], cwd=root, check=True, capture_output=True)
            reverted = subprocess.run(['git', 'revert', '--no-edit', '-m', '1', culprit], cwd=root, capture_output=True, text=True)
            result.update(revertBranch=branch, revertStatus='prepared locally' if reverted.returncode == 0 else 'conflict; retained')
            if reverted.returncode:
                result['revertError'] = reverted.stderr
                result['preserveRevert'] = True
        return result
    finally:
        # Never erase a probe whose owning resource helper could not clean it.
        cleanup = []
        result.update(cleanup=cleanup, retainedWorktree=str(root))
        save(directory / 'progress.json', result)
        for script in ('scripts/ios-gateway-e2e-test', 'scripts/tron-ios-test'):
            if (root / script).is_file():
                try:
                    cleanup.append(execute(root, {'name': 'probe cleanup', 'command': [script, 'clean']}, directory / Path(script).name))
                except KeyboardInterrupt:
                    cleanup.append({'exit': 130, 'command': [script, 'clean'], 'status': 'interrupted'})
                    raise
                except OSError as error:
                    cleanup.append({'exit': 2, 'command': [script, 'clean'], 'error': str(error)})
                finally:
                    save(directory / 'progress.json', result)
        if result.get('preserveRevert') or any(item['exit'] for item in cleanup):
            result['retainedWorktree'] = str(root)
            print(f'batch: probe cleanup failed; preserved worktree {root}', flush=True)
        else:
            verify.git('worktree', 'remove', '--force', str(root))
            shutil.rmtree(temporary)
            del result['retainedWorktree']
        save(directory / 'progress.json', result)


def file_issue(report: dict, directory: Path, state: Path) -> dict:
    # The batch lock serializes this journal. Persist BEFORE dispatch: a killed or
    # uncertain GitHub write must not become a second create on an operator rerun.
    key = hashlib.sha256(json.dumps([report['failed']['name'], report['failed'].get('signature')], sort_keys=True).encode()).hexdigest()
    journal = state / 'issue-writes' / f'{key}.json'
    previous = json.loads(journal.read_text()) if journal.exists() else None
    if previous and (not previous.get('number') or previous.get('status') != 'completed'):
        print(f'batch: retaining prior issue-write outcome: {journal}', flush=True)
        return {**previous, 'reused': True}
    journal.parent.mkdir(parents=True, exist_ok=True)
    pending = {'status': 'attempting', 'exit': None, 'batch': str(directory), 'range': [report['base'], report['head']],
               'lane': report['failed']['name'], 'number': previous.get('number') if previous else None}
    save(journal, pending)
    attribution = report['attribution']
    directory.mkdir(parents=True, exist_ok=True)
    body = directory / 'issue.md'
    body.write_text('## Failed verification batch\n\n'
                    f"Range: `{report['base']}..{report['head']}`; {len(report['commits'])} covered commits.\n"
                    f"Lane: {report['failed']['name']}; attribution: {attribution['status']}.\n\n"
                    + (f"First failing main integration: `{attribution['commit']}`.\n" if attribution.get('commit') else
                       'No culprit proven. Candidates: ' + ', '.join(f'`{sha}`' for sha in attribution['candidates']) + '.\n')
                    + '\nFiles: ' + ', '.join(f'`{p}`' for p in attribution.get('files', report['files']))
                    + '\n\nExact commands, outcomes, per-lane wall time and partial logs are retained in the repository-local '
                    f"Git common directory at `verify/batches/{directory.name}/report.json`. No test, golden, assertion or timeout changed. "
                    'Main is not blocked or reverted. Failed/qualified coverage never advances last-green.\n')
    if attribution.get('revertBranch'):
        with body.open('a') as stream:
            stream.write(f"\nLocal revert branch: `{attribution['revertBranch']}` ({attribution['revertStatus']}); never pushed.\n")
    command = (['scripts/tron', 'work', 'comment', str(previous['number']), '--body-file', str(body)] if previous else
               ['scripts/tron', 'work', 'issue', 'create', '--title',
                f"Verification: {report['failed']['name']} [{key[:12]}]",
                '--body-file', str(body), '--kind', 'kind:bug', '--area', 'area:tooling'])
    outcome = execute(ROOT, {'name': 'file failure issue', 'command': command}, directory / 'issue')
    output = Path(outcome['log']).read_text(errors='replace')
    number = previous.get('number') if previous else None
    match = re.search(r'(?:/issues/|created issue #)(\d+)', output)
    if match:
        number = int(match[1])
    outcome = {**outcome, 'status': 'completed' if outcome['exit'] == 0 else 'unresolved', 'number': number}
    save(journal, outcome)
    return outcome


def failure_cases(outcome: dict) -> list[dict]:
    """One stable signature and one exact-case probe per failure, never a suite probe."""
    cases = []
    if outcome.get('vitest') and outcome.get('failureComplete'):
        for identity, digest in outcome.get('failures', {}).items():
            if identity in outcome.get('qualifiedFailures', {}):
                continue
            file, case = identity.split('::', 1)
            command = outcome['command']
            cases.append({**outcome, 'signature': {'failures': {identity: digest}},
                          'probe': {'name': outcome['name'], 'vitest': True,
                                    'command': [*command, file.removeprefix(outcome.get('testRoot', 'packages/gateway') + '/'), '-t', '^' + re.escape(case) + '$']}})
    # Other owners may only be probed if the recorded invocation is already a case filter.
    elif outcome.get('xctestCases') and outcome.get('signature'):
        for case in outcome['xctestCases']:
            # Build remains at each revision; execution selects one class/method.
            cases.append({**outcome, 'signature': {**outcome['signature'], 'failedTests': [case]},
                          'probe': {'name': outcome['name'], 'command': outcome['command'] + ' -only-testing:' + case}})
    elif outcome.get('probe') and '--only-testing' in outcome['probe'].get('command', []):
        cases.append(outcome)
    return cases


def memo_attribute(base: str, head: str, failed: dict, directory: Path, state: Path) -> dict:
    key = hashlib.sha256(json.dumps([base, head, failed['name'], failed.get('signature')], sort_keys=True).encode()).hexdigest()
    memo = state / 'attributions' / f'{key}.json'
    if memo.exists():
        return {**json.loads(memo.read_text()), 'reused': True}
    memo.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    result = attribute(base, head, failed, directory)
    result['hostSeconds'] = round(time.monotonic() - start, 3)
    save(memo, result)
    return result


def batch_verdict(results: list[dict]) -> str:
    if any(item.get('status') == 'uncovered' or item.get('exit') is None for item in results):
        return 'uncovered'
    if any(item.get('status') == 'red' or (item['exit'] and item.get('status') != 'qualified') for item in results):
        return 'red'
    return 'qualified' if any(item.get('status') == 'qualified' for item in results) else 'green'


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog='scripts/tron verify --batch')
    parser.add_argument('--base', help='explicit main starting anchor on first use; not green until this batch proves it')
    parser.add_argument('--plan', action='store_true')
    args = parser.parse_args(argv)
    state = Path(verify.git('rev-parse', '--path-format=absolute', '--git-common-dir').strip()) / 'verify'
    try:
        if verify.git('status', '--porcelain', '--untracked-files=normal').strip():
            raise verify.VerifyError('batch needs a clean dedicated worktree')
        head = verify.git('rev-parse', 'HEAD').strip()
        green_path = state / 'green.json'
        covered_path = state / 'covered.json'
        pointer = covered_path if covered_path.exists() else green_path
        green = json.loads(pointer.read_text()) if pointer.exists() else None
        if green and args.base:
            raise verify.VerifyError('--base only initializes a missing last-green record; never skips failed coverage')
        if not green and not args.base:
            raise verify.VerifyError('no green batch: supply --base <known-green-commit> explicitly on first use')
        base = green['commit'] if green else verify.git('rev-parse', '--verify', f'{args.base}^{{commit}}').strip()
        # A batch covers landed main only; pin a snapshot, never fetch/merge another worker's checkout.
        fetch_head = Path(verify.git('rev-parse', '--git-path', 'FETCH_HEAD').strip())
        ref = ('FETCH_HEAD' if fetch_head.is_file() else
               'origin/main' if verify.git('for-each-ref', 'refs/remotes/origin/main').strip() else 'main')
        ancestry = verify.git('rev-list', '--first-parent', ref).splitlines()
        if head not in ancestry or base not in ancestry[ancestry.index(head):]:
            raise verify.VerifyError('batch base and HEAD must be ordered commits on main first-parent history')
        commits = verify.git('rev-list', '--reverse', f'{base}..{head}').splitlines()
        files = verify.git('diff', '--name-only', base, head).splitlines()
        plan = {'base': base, 'head': head, 'commits': commits, 'files': files, 'lanes': lanes(ROOT, base)}
        if args.plan:
            print(json.dumps(plan, indent=2))
            return 0
        state.mkdir(exist_ok=True)
        with (state / 'batch.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise verify.VerifyError('another explicit batch owns this repository; no queue or wait') from None
            current = json.loads(pointer.read_text()) if pointer.exists() else None
            if current != green:
                raise verify.VerifyError('last-green changed while planning; rerun against its current coverage')
            if head == base and green:
                print(f'batch: no uncovered commits after {head[:12]}')
                return 0
            directory = state / 'batches' / f'{base[:12]}-{head[:12]}-{time.time_ns()}'
            directory.mkdir(parents=True)
            timestamp = int(verify.git('show', '-s', '--format=%ct', base).strip())
            report = {**plan, 'verdict': 'running', 'results': [], 'failures': [], 'setup': [],
                      'rangeAgeSeconds': max(0, round(time.time() - timestamp)), 'attributionHostSeconds': 0,
                      'nonLandingCommits': [sha for sha in verify.git('rev-list', '--first-parent', f'{base}..{head}').splitlines()
                                            if len(verify.git('rev-list', '--parents', '-n', '1', sha).split()) != 3]}
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
                for index, lane in enumerate(plan['lanes']):
                    source_unchanged()
                    report['activeLane'] = lane['name']
                    save(path, report)
                    try:
                        outcome = execute(ROOT, lane, directory / f'lane-{index}')
                        if (outcome.get('vitest') and outcome.get('exit') and outcome.get('failureComplete')
                                and outcome.get('status') != 'uncovered'):
                            known = verify.known_failures()
                            expired = {item['testId'] for item in verify.expired_failures(known)}
                            qualified = {identity: digest for identity, digest in outcome['failures'].items()
                                         if identity in known and identity not in expired
                                         and digest == known[identity]['evidence']['failureDigest']}
                            outcome['qualifiedFailures'] = qualified
                            if qualified == outcome['failures']:
                                outcome['status'] = 'qualified'
                    except (OSError, ValueError, KeyError, verify.VerifyError, subprocess.SubprocessError) as error:
                        outcome = {**lane, 'exit': None, 'status': 'uncovered', 'error': str(error), 'seconds': 0}
                    report['results'].append(outcome)
                    save(path, report)
                    source_unchanged()
                report['fixtureCleanup'] = stop_fixture(ROOT, directory / 'fixture-stop')
                save(path, report)
                # Finish coverage before spending any host time on attribution.
                for index, outcome in enumerate(report['results']):
                    if not outcome.get('exit') or outcome.get('status') == 'qualified':
                        continue
                    cases = failure_cases(outcome)
                    if not cases:
                        outcome.update(status='uncovered', reason='owner provided no exact-case attribution selector')
                    failures = cases or [outcome]
                    for case_index, failed in enumerate(failures):
                        attribution_directory = directory / f'attribution-{index}-{case_index}'
                        attribution = memo_attribute(base, head, failed, attribution_directory, state)
                        report['attributionHostSeconds'] += attribution.get('hostSeconds', 0) if not attribution.get('reused') else 0
                        item = {'failed': failed, 'attribution': attribution}
                        item['issue'] = file_issue({**report, **item}, directory / f'failure-{index}-{case_index}', state)
                        report['failures'].append(item)
                        save(path, report)
                source_unchanged()
                report['verdict'] = ('uncovered' if (any(item['exit'] for item in report['setup'])
                                                      or (report.get('fixtureCleanup') or {}).get('exit'))
                                     else batch_verdict(report['results']))
                save(path, report)
                if report['verdict'] in ('green', 'qualified'):
                    record = {'commit': head, 'report': str(path), 'verdict': report['verdict']}
                    save(covered_path, record)
                    if report['verdict'] == 'green':
                        save(green_path, record)
                return 0 if report['verdict'] in ('green', 'qualified') else 1
            except KeyboardInterrupt:
                report['verdict'] = 'interrupted'
                save(path, report)
                print(f'batch: INTERRUPTED; partial evidence {path}; last-green unchanged', flush=True)
                return 130
            except (verify.VerifyError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                report.update(verdict='error', error=str(error))
                report.setdefault('failed', {'name': report.get('activeLane', 'batch infrastructure')})
                report.setdefault('attribution', {'status': 'infrastructure/source changed; no culprit proven', 'candidates': commits})
                save(path, report)
                try:
                    report['issue'] = file_issue(report, directory, state)
                except (OSError, ValueError, subprocess.SubprocessError) as issue_error:
                    report['issueError'] = str(issue_error)
                save(path, report)
                print(f'batch: ERROR; partial evidence {path}; last-green unchanged', flush=True)
                return 2
            finally:
                try:
                    if 'fixtureCleanup' not in report:
                        report['fixtureCleanup'] = stop_fixture(ROOT, directory / 'fixture-stop')
                        save(path, report)
                except (OSError, subprocess.SubprocessError) as error:
                    report['cleanupError'] = str(error)
                    save(path, report)
                print(json.dumps({'batchResult': report['verdict'], 'head': head, 'report': str(path),
                                  'delivery': 'Home caller must acknowledge this result'}), flush=True)
    except (verify.VerifyError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'batch: {error}', flush=True)
        return 2
