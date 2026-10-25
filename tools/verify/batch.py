"""Explicit local batch coverage. No scheduler, merge gate, or production lifecycle."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
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
    result = [{'name': 'full verify', 'command': ['scripts/tron', 'verify', '--all', '--base', base]}]
    if (root / 'packages/ios-app/project.yml').is_file():
        result.extend([
            {'name': 'shipping iOS compile', 'command': ['scripts/tron-ios-device', 'compile']},
            {'name': 'iOS smoke', 'command': ['scripts/tron-ios-test', 'run']},
        ])
    if (root / 'scripts/ios-gateway-e2e-test').is_file():
        result.extend([
            {'name': 'real Gateway boundary', 'command': ['scripts/ios-gateway-e2e-test', 'all']},
            {'name': 'real Gateway UI journeys', 'command': ['scripts/ios-gateway-e2e-test', 'run-ui']},
            {'name': 'fixture stop', 'command': ['scripts/ios-gateway-e2e-test', 'stop']},
        ])
    return result


def signature(message: str, failures: list[str], output: str, root: Path) -> dict | None:
    diagnostics = [] if failures else re.findall(r'^(?:AssertionError:|Error:|error:|unowned:|overlap:).+$', output, re.M)
    diagnostics = [line.replace(str(root), '<worktree>') for line in diagnostics[:20]]
    return {'message': message, 'failedTests': failures, 'diagnostics': diagnostics} if failures or diagnostics else None


def execute(root: Path, lane: dict, directory: Path) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / 'output.log'
    print(f"batch: {lane['name']} … live log: {log}", flush=True)
    start = time.monotonic()
    command = lane['command']
    command = command.replace(str(ROOT), str(root)) if isinstance(command, str) else [word.replace(str(ROOT), str(root)) for word in command]
    vitest = next((Path(word.split('=', 1)[1]) for word in command if word.startswith('--outputFile.json=')), None) if isinstance(command, list) else None
    if vitest:
        vitest.parent.mkdir(parents=True, exist_ok=True)
        vitest.unlink(missing_ok=True)
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
    result = {**lane, 'exit': code, 'seconds': round(time.monotonic() - start, 3), 'log': str(log)}
    # Preserve the owning verifier's exact selection, failed tests and partial step logs.
    if lane['name'] == 'full verify':
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        source = root / 'test-results/verify' / f'{sha}.json'
        if source.exists():
            report = json.loads(source.read_text())
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
    if code != 0 and 'signature' not in result:
        output = log.read_text(errors='replace')
        result['signature'] = signature(f"{lane['name']} failed", verify.ios_failures(output), output, root)
    print(f"batch: {lane['name']} {'PASS' if result['exit'] == 0 else 'FAIL'} in {result['seconds']}s", flush=True)
    return result


def stop_fixture(root: Path, directory: Path) -> None:
    if (root / 'scripts/ios-gateway-e2e-test').is_file():
        execute(root, {'name': 'fixture stop', 'command': ['scripts/ios-gateway-e2e-test', 'stop']}, directory)


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
    with tempfile.TemporaryDirectory(prefix='tron-verify-bisect-') as temporary:
        root = Path(temporary) / 'repo'
        verify.git('worktree', 'add', '--detach', str(root), base)
        try:
            # One probe worktree preserves Xcode incrementals across revisions. npm installs stay local.
            dependency_key = None
            def probe(sha: str) -> str:
                nonlocal dependency_key
                subprocess.run(['git', 'checkout', '--detach', sha], cwd=root, check=True, capture_output=True)
                attempt = directory / f'probe-{len(result["probes"]):02d}-{sha[:12]}'
                lock = root / 'packages/gateway/package-lock.json'
                key = hashlib.sha256(lock.read_bytes()).hexdigest() if lock.exists() else ''
                if key != dependency_key:
                    if not prepare(root, attempt / 'dependencies'):
                        result['probes'].append({'commit': sha, 'outcome': 'setup failure'})
                        return 'unknown'
                    dependency_key = key
                try:
                    lane = {**failed['probe'], 'probe': True} if failed.get('probe') else {k: failed[k] for k in ('name', 'command')}
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
                result['probes'].append({'commit': sha, 'outcome': state, **outcome})
                return state
            baseline = probe(base)
            if baseline == 'bad':
                result['status'] = 'pre-existing at baseline'
                return result
            if baseline != 'good':
                return result
            # Reproduce head in the same isolated environment before attributing a host failure.
            if probe(head) != 'bad':
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
            result.update(status='first failing main integration', commit=culprit,
                          files=verify.git('diff-tree', '--root', '--no-commit-id', '--name-only', '-r', culprit).splitlines())
            return result
        finally:
            # Resource owners clean only this disposable worktree's simulator/products/fixture.
            for script in ('scripts/ios-gateway-e2e-test', 'scripts/tron-ios-test'):
                if (root / script).is_file():
                    execute(root, {'name': 'probe cleanup', 'command': [script, 'clean']}, directory / Path(script).name)
            verify.git('worktree', 'remove', '--force', str(root))


def file_issue(report: dict, directory: Path) -> dict:
    attribution = report['attribution']
    body = directory / 'issue.md'
    body.write_text('## Failed verification batch\n\n'
                    f"Range: `{report['base']}..{report['head']}`; {len(report['commits'])} covered commits.\n"
                    f"Lane: {report['failed']['name']}; attribution: {attribution['status']}.\n\n"
                    + (f"First failing main integration: `{attribution['commit']}`.\n" if attribution.get('commit') else
                       'No culprit proven. Candidates: ' + ', '.join(f'`{sha}`' for sha in attribution['candidates']) + '.\n')
                    + '\nFiles: ' + ', '.join(f'`{p}`' for p in attribution.get('files', report['files']))
                    + '\n\nExact commands, outcomes, per-lane wall time and partial logs are retained in the repository-local '
                    f"Git common directory at `verify/batches/{directory.name}/report.json`. No test, golden, assertion or timeout changed. "
                    'Main is not blocked or reverted; last-green coverage has not advanced.\n')
    command = ['scripts/tron', 'work', 'issue', 'create', '--title',
               f"Verification batch {report['head'][:12]}: {report['failed']['name']}",
               '--body-file', str(body), '--kind', 'kind:bug', '--area', 'area:tooling']
    outcome = execute(ROOT, {'name': 'file failure issue', 'command': command}, directory / 'issue')
    # A failed/uncertain write is retained, never automatically replayed.
    return outcome


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog='scripts/tron verify --batch')
    parser.add_argument('--base', help='explicit last-known-green starting commit on first use only')
    parser.add_argument('--plan', action='store_true')
    args = parser.parse_args(argv)
    state = Path(verify.git('rev-parse', '--path-format=absolute', '--git-common-dir').strip()) / 'verify'
    try:
        if verify.git('status', '--porcelain', '--untracked-files=normal').strip():
            raise verify.VerifyError('batch needs a clean dedicated worktree')
        head = verify.git('rev-parse', 'HEAD').strip()
        green_path = state / 'green.json'
        green = json.loads(green_path.read_text()) if green_path.exists() else None
        if green and args.base:
            raise verify.VerifyError('--base only initializes a missing last-green record; never skips failed coverage')
        if not green and not args.base:
            raise verify.VerifyError('no green batch: supply --base <known-green-commit> explicitly on first use')
        base = green['commit'] if green else verify.git('rev-parse', '--verify', f'{args.base}^{{commit}}').strip()
        # A batch covers landed main only; pin a snapshot, never fetch/merge another worker's checkout.
        ref = 'origin/main' if verify.git('for-each-ref', 'refs/remotes/origin/main').strip() else 'main'
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
            current = json.loads(green_path.read_text()) if green_path.exists() else None
            if current != green:
                raise verify.VerifyError('last-green changed while planning; rerun against its current coverage')
            if head == base and green:
                print(f'batch: no uncovered commits after {head[:12]}')
                return 0
            directory = state / 'batches' / f'{base[:12]}-{head[:12]}-{time.time_ns()}'
            directory.mkdir(parents=True)
            report = {**plan, 'verdict': 'running', 'results': []}
            path = directory / 'report.json'
            save(path, report)
            try:
                for index, lane in enumerate(plan['lanes']):
                    report['activeLane'] = lane['name']
                    save(path, report)
                    outcome = execute(ROOT, lane, directory / f'lane-{index}')
                    report['results'].append(outcome)
                    save(path, report)
                    if outcome['exit']:
                        report.update(verdict='failed', failed=outcome)
                        save(path, report)
                        report['attribution'] = attribute(base, head, outcome, directory / 'attribution')
                        save(path, report)
                        report['issue'] = file_issue(report, directory)
                        save(path, report)
                        print(f'batch: FAILED; evidence {path}; last-green unchanged', flush=True)
                        return 1
                report['verdict'] = 'passed'
                save(path, report)
                save(green_path, {'commit': head, 'report': str(path)})
                print(f'batch: GREEN; covered {len(commits)} commits; evidence {path}', flush=True)
                return 0
            except KeyboardInterrupt:
                report['verdict'] = 'interrupted'
                save(path, report)
                print(f'batch: INTERRUPTED; partial evidence {path}; last-green unchanged', flush=True)
                return 130
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                report.update(verdict='error', error=str(error))
                save(path, report)
                print(f'batch: ERROR; partial evidence {path}; last-green unchanged', flush=True)
                return 2
            finally:
                if report['verdict'] != 'passed':
                    stop_fixture(ROOT, directory / 'fixture-stop')
    except (verify.VerifyError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'batch: {error}', flush=True)
        return 2
