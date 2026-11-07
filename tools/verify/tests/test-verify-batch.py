#!/usr/bin/env python3
"""Real Git/process fixture lanes for the shipped post-land batch owner."""
from datetime import datetime, timezone, timedelta
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / 'test-results/verify-batch'


def shipped_runner(root, lock):
    """The shipped Gateway runner and its host lock under `root`, pointed at this test's lock path, not the host's."""
    (root / 'tools/verify').mkdir(parents=True, exist_ok=True)
    (root / 'tools/verify/gateway.py').write_text((ROOT / 'tools/verify/gateway.py').read_text())
    source = (ROOT / 'tools/verify/host_lock.py').read_text()
    assert "'/tmp/tron-full-gateway.lock'" in source, 'the host lock path moved; point this fixture at its new spelling'
    (root / 'tools/verify/host_lock.py').write_text(source.replace("'/tmp/tron-full-gateway.lock'", repr(str(lock))))
    return root / 'tools/verify/gateway.py'


def wait_until(predicate, message, timeout=30):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(message)
        time.sleep(0.05)


class GatewayRuns:
    """Shipped Gateway runners pointed at one test lock, in their own scratch directory. Each stand-in
    Vitest appends its test name to `order` once its run holds the lock; a run named holder* keeps
    it until released (or its directory is gone, so an orphan of a killed runner still ends)."""

    def __init__(self, lock: Path):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-gateway-runs-')
        directory = Path(self.temporary.name)
        self.directory, self.order, self.runs = directory, directory / 'order', {}
        self.gateway = shipped_runner(directory, lock)
        node = directory / 'scripts/tron-node'
        node.parent.mkdir()
        node.write_text('#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
        vitest = directory / 'packages/gateway/node_modules/.bin/vitest'
        vitest.parent.mkdir(parents=True)
        vitest.write_text(f'#!/bin/bash\necho "$2" >> {self.order}\n'
                          f'while [[ "$2" == holder* && ! -e {directory}/release-$2 && -d {directory} ]]; do sleep 0.05; done\n')
        for script in (node, vitest):
            script.chmod(0o755)

    def start(self, name):
        inherited = {key: value for key, value in os.environ.items() if key != 'TRON_FULL_GATEWAY_LOCK_HELD'}
        with (self.directory / f'{name}.err').open('w') as stderr:
            self.runs[name] = subprocess.Popen(['python3', str(self.gateway), name], env=inherited,
                                               stdout=subprocess.DEVNULL, stderr=stderr)
        return self.runs[name]

    def stderr(self, name):
        return (self.directory / f'{name}.err').read_text()

    def names(self):
        lines = self.order.read_text().split() if self.order.exists() else []
        return list(dict.fromkeys(lines))

    def wait_holding(self, name):
        wait_until(lambda: name in self.names(), f'{name} never held the lock: {self.stderr(name)}')

    def wait_queued(self, name):
        wait_until(lambda: 'waiting for' in self.stderr(name), f'{name} never queued: {self.stderr(name)}')

    def release(self, name):
        (self.directory / f'release-{name}').touch()

    def wait_all(self, names=None):
        for name in names or self.runs:
            self.runs[name].wait(timeout=60)
            if self.runs[name].returncode != -signal.SIGKILL:
                assert self.runs[name].returncode == 0, (name, self.stderr(name))

    def close(self):
        for name, run in self.runs.items():
            self.release(name)
            if run.poll() is None:
                run.terminate()
                run.wait(timeout=30)
        self.temporary.cleanup()


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-batch-fixture-')
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        self.env = {**os.environ, 'HOME': self.temporary.name, 'TMPDIR': self.temporary.name,
                    'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
                    'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                    'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
        self.env['GIT_COMMITTER_DATE'] = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
        self.git('init', '-q', '-b', 'main')
        for file in ('batch.py', 'verify.py', 'timing.py', 'host_lock.py'):
            source = Path(os.environ.get('TRON_BATCH_UNDER_TEST', ROOT / 'tools/verify/batch.py')) if file == 'batch.py' else Path(os.environ.get('TRON_VERIFY_UNDER_TEST', ROOT / 'tools/verify' / file))
            text = source.read_text()
            # The shared host lock path belongs to real full-Gateway runs, not fixtures.
            text = text.replace("'/tmp/tron-full-gateway.lock'", repr(str(Path(self.temporary.name) / 'full-gateway.lock')))
            self.write('tools/verify/' + file, text)
        for directory in ('ownership', 'budgets', 'metrics', 'layers'):
            for source in (ROOT / 'tools' / directory).glob('*.py'):
                self.write(str(source.relative_to(ROOT)), source.read_text())
        self.write('.gitignore', 'test-results/\n__pycache__/\n')
        self.write('scripts/tron', '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
if sys.argv[1:3] == ['verify','--batch']:
    os.execvp('python3',['python3','tools/verify/verify.py',*sys.argv[2:]])
if sys.argv[1:3] == ['work','issue'] or sys.argv[1:3] == ['work','comment']:
    with Path('test-results/issue-writes').open('a') as f: f.write(' '.join(sys.argv[1:])+'\\n')
    if Path('issue-refuse').exists(): sys.exit(2)
    print('created issue #100')
    sys.exit(0)
Path('test-results').mkdir(exist_ok=True)
# The verifier and the candidate's affected checks run their Gateway groups through the real runner,
# which skips the host lock when this marker is set; only a batch Gateway lane may pass it on.
if os.environ.get('TRON_FULL_GATEWAY_LOCK_HELD'): sys.exit('verify ran marked as holding the full-Gateway lock')
with Path('test-results/executed').open('a') as f: f.write(' '.join(sys.argv[1:3])+'\\n')
import subprocess
affected = '--changed' in sys.argv and os.environ.get('FIXTURE_AFFECTED')
if affected == 'kill-owner':
    # Simulate the batch owner dying mid-repair: SIGKILL the ancestor batch process.
    pid = os.getppid()
    while pid > 1:
        if 'tools/verify/verify.py' in subprocess.check_output(['ps','-o','command=','-p',str(pid)],text=True):
            os.kill(pid, 9)
            break
        pid = int(subprocess.check_output(['ps','-o','ppid=','-p',str(pid)],text=True))
sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
Path('test-results/verify').mkdir(exist_ok=True)
verdict = Path('verifier-verdict').read_text().strip() if Path('verifier-verdict').exists() else 'passed'
if affected == 'red': verdict = 'failed'
Path('test-results/verify',sha+'.json').write_text(json.dumps({'commit':sha,'verdict':verdict,'message':'locks passed','passingTests':1,'steps':[],'selection':{},'skipped':[]}))
sys.exit(1 if verdict == 'failed' else 0)
''', True)
        self.write('tools/verify/gateway.py', '''import json,os,re,sys,time,subprocess
from pathlib import Path
# A batch lane runs under the batch's full-Gateway lock and must say so, or the real
# runner would wait on the lock its own batch holds.
if os.environ.get('TRON_FULL_GATEWAY_LOCK_HELD') != '1': sys.exit('gateway lane ran without the held-lock marker')
args=sys.argv[1:]
nested='--config' in args
name='nested' if nested else 'default'
root=Path.cwd()
(root/'test-results').mkdir(exist_ok=True)
with (root/'test-results/executed').open('a') as f: f.write(name+' '+repr(args)+'\\n')
if (root/'hold').exists():
    p=subprocess.Popen(['sleep','300'])
    (root/'test-results/child.pid').write_text(str(p.pid))
    time.sleep(300)
failed=((root/'bad').exists() or (root/'also-bad').exists()) and not nested
if failed and (root/'unhandled').exists(): print('Vitest caught 1 unhandled error during the test run.')
if (root/'flake').exists() and '-t' in args: failed=False
if (root/'unstable-repeat').exists() and '-t' in args and failed:
    common=Path(subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip())
    sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    counter=common/('fixture-count-'+sha)
    count=int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count+1))
    if count: failed=False
# Like Vitest 5: the reporter's fullName joins titles with spaces, but -t matches them joined with ' > '
# (createTaskName), and a case it does not match is skipped.
titles=['suite','group','other' if (root/'renamed-probe').exists() and '-t' in args else 'case']
selected='-t' not in args or re.search(args[args.index('-t')+1],' > '.join(titles))
failed=failed and bool(selected)
output=Path(next(a.split('=',1)[1] for a in args if a.startswith('--outputFile.json=')))
output.parent.mkdir(parents=True,exist_ok=True)
status='failed' if failed else 'passed' if selected else 'skipped'
data={'numPassedTests':int(status=='passed'),'numFailedTests':int(failed),'numPendingTests':int(not selected),
      'testResults':[{'name':str(root/'packages/gateway/src/example.test.ts'),'startTime':1000,'endTime':2500,
       'status':'failed' if failed else 'passed','assertionResults':[
        {'ancestorTitles':titles[:-1],'title':titles[-1],'fullName':' '.join(titles),'status':status,
         'failureMessages':['AssertionError: stable failure'] if failed else []}]}]}
if (root/'changed-signature').exists() and '-t' in args and failed:
    data['testResults'][0]['assertionResults'][0]['failureMessages']=['AssertionError: different failure']
if (root/'skipped').exists(): data['numPendingTests']=1
if (root/'empty-probe').exists() and '-t' in args and not failed:
    data['numPassedTests']=0
    data['testResults']=[]
if not (root/'missing-report').exists(): output.write_text(json.dumps(data))
raise SystemExit(1 if failed else 0)
''')
        self.write('scripts/tron-node', '''#!/usr/bin/env python3
import json,sys
from pathlib import Path
Path('test-results').mkdir(exist_ok=True)
with Path('test-results/executed').open('a') as f: f.write('relay\\n')
for arg in sys.argv:
    if arg.startswith('--outputFile.json='):
        Path(arg.split('=',1)[1]).write_text(json.dumps({'numPassedTests':1,'numFailedTests':0,'testResults':[{'name':str(Path('packages/push-relay/tests/worker.test.ts').resolve()),'status':'passed','assertionResults':[{'fullName':'relay case','status':'passed'}]}]}))
''', True)
        self.write('scripts/tron-xcodebuild', '#!/bin/sh\necho mac-build >> test-results/executed\n', True)
        binaries = Path(self.temporary.name) / 'bin'
        binaries.mkdir()
        for name in ('swift', 'xcodebuild'):
            (binaries / name).write_text('#!/bin/sh\necho '+name+' >> test-results/executed\necho "Executed 2 tests, with 0 failures"\n')
            (binaries / name).chmod(0o755)
        self.env['PATH'] = str(binaries) + os.pathsep + self.env['PATH']
        self.write('scripts/ios-test-lock.py', '''import sys,subprocess
HOST_SLOTS=3
def read_slot_holders(): return [None,None,None]
def slot_worktrees(): return [None,None,None]
if __name__ == '__main__': raise SystemExit(subprocess.call(sys.argv[sys.argv.index('--')+1:]))
''')
        self.write('scripts/tron-ios-device', '#!/bin/sh\necho compile >> test-results/executed\n', True)
        self.write('scripts/tron-ios-test', '''#!/usr/bin/env python3
import json,sys
from pathlib import Path
Path('test-results').mkdir(exist_ok=True)
with Path('test-results/executed').open('a') as f: f.write('smoke '+sys.argv[1]+'\\n')
if sys.argv[1] in ('run', 'checkpoint'):
    Path('test-results/summary.json').write_text(json.dumps({'passedTests':1}))
    print('iOS test run complete: '+str(Path('test-results').resolve()))
''', True)
        self.write('scripts/ios-gateway-e2e-test', '#!/bin/sh\nmkdir -p test-results\necho boundary-$1 >> test-results/executed\n', True)
        for file in ('packages/gateway/package-lock.json', 'packages/push-relay/package-lock.json',
                     'packages/mac-app/project.yml', 'packages/mac-app/native-computer-control/Package.swift',
                     'packages/ios-app/project.yml', 'packages/gateway/src/example.test.ts'):
            self.write(file, '{}\n')
        self.commit('fixture lanes')
        self.base = self.git('rev-parse', 'HEAD')

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, file, value, executable=False):
        path = self.root / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        if executable:
            path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, env=self.env, text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-qm', message)

    def land(self, file, value):
        self.git('checkout', '-qb', 'topic-' + str(time.time_ns()))
        topic = self.git('branch', '--show-current')
        self.write(file, value)
        self.commit(file)
        self.git('checkout', 'main')
        self.git('merge', '--no-ff', '--no-edit', topic)
        return self.git('rev-parse', 'HEAD')

    def remote(self, publish=True):
        self.origin = Path(self.temporary.name) / 'origin.git'
        subprocess.run(['git', 'init', '--bare', '-q', '-b', 'main', str(self.origin)], env=self.env, check=True, capture_output=True)
        self.git('remote', 'add', 'origin', str(self.origin))
        self.git('push', '-q', 'origin', 'main')
        if publish:
            # The single enable step: name the remote whose main may receive reviewed reverts.
            self.git('config', 'tron.verify.revertRemote', 'origin')

    def push(self):
        self.git('push', '-q', 'origin', 'main')

    def remote_git(self, *args):
        return subprocess.check_output(['git', '--git-dir', str(self.origin), *args], env=self.env, text=True).strip()

    def other_clone_lands(self, file, value=None):
        clone = Path(self.temporary.name) / f'other-{time.time_ns()}'
        subprocess.run(['git', 'clone', '-q', str(self.origin), str(clone)], env=self.env, check=True, capture_output=True)
        if value is None:
            (clone / file).unlink()
        else:
            (clone / file).write_text(value)
        for args in (['add', '-A'], ['commit', '-qm', 'concurrent ' + file], ['push', '-q', 'origin', 'HEAD:main']):
            subprocess.run(['git', *args], cwd=clone, env=self.env, check=True, capture_output=True)
        return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=clone, env=self.env, text=True).strip()

    def repair(self):
        return [json.loads(path.read_text()) for path in sorted((self.root / '.git/verify/repairs').glob('*.json'))]

    def review(self, repair, decision='ACCEPT', binding=None):
        return self.run_batch('--review', repair['culprit'], '--decision', decision, '--reviewer', 'fixture-reviewer',
                              '--binding', binding or repair['bindingDigest'])

    def reverts_on_remote(self, culprit):
        return [line for line in self.remote_git('log', '--format=%H %(trailers:key=Tron-Auto-Revert,valueonly,separator=)', 'main').splitlines()
                if line.split(' ', 1)[-1] == culprit]

    def run_batch(self, *args):
        result = subprocess.run(['scripts/tron', 'verify', '--batch', *args], cwd=self.root, env=self.env,
                                capture_output=True, text=True, timeout=90)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / 'runs.log').open('a') as stream:
            stream.write(result.stdout + result.stderr)
        return result

    def reports(self):
        return [json.loads(path.read_text()) for path in sorted((self.root / '.git/verify/batches').glob('*/report.json'), key=lambda path: path.stat().st_mtime_ns)]

    def test_green_exact_range_repeat_and_read_only_plan(self):
        self.land('good', 'yes')
        result = self.run_batch('--base', self.base, '--plan')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / '.git/verify').exists())
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'green')
        self.assertEqual(len(report['results']), 9)
        self.assertTrue(all(lane['seconds'] >= 0 for lane in report['results']))
        self.assertEqual(json.loads((self.root / '.git/verify/green.json').read_text())['commit'], self.git('rev-parse', 'HEAD'))
        self.assertIn('no uncovered commits', self.run_batch().stdout)
        self.assertEqual(len(self.reports()), 1)

    def test_an_inherited_held_lock_marker_reaches_only_the_gateway_lanes(self):
        # A batch started under a caller's marker must not pass it to lanes that do not hold the lock.
        self.land('good', 'yes')
        self.env['TRON_FULL_GATEWAY_LOCK_HELD'] = '1'
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'green')
        self.assertEqual([lane['name'] for lane in report['results'] if lane.get('fullGatewayLock')], ['Gateway default', 'Gateway nested'])

    def test_repeat_requires_explicit_flag_and_executes_all_lanes(self):
        self.land('good', 'yes')
        first = self.run_batch('--base', self.base)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        head = self.git('rev-parse', 'HEAD')
        original = json.loads((self.root / '.git/verify/green.json').read_text())
        self.assertEqual(original['commit'], head)

        no_op = self.run_batch()
        self.assertEqual(no_op.returncode, 0, no_op.stdout + no_op.stderr)
        self.assertIn('no uncovered commits', no_op.stdout)
        self.assertEqual(len(self.reports()), 1)

        repeated = self.run_batch('--repeat')
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertEqual(len(self.reports()), 2)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'green')
        self.assertEqual(report['base'], head)
        self.assertEqual(report['head'], head)
        self.assertEqual(len(report['results']), 9)
        self.assertTrue(all(result['exit'] == 0 for result in report['results']))
        updated = json.loads((self.root / '.git/verify/green.json').read_text())
        self.assertEqual((updated['commit'], updated['verdict']), (head, 'green'))
        self.assertTrue(Path(updated['report']).is_file())

    def test_repeat_cannot_override_base_or_bypass_coverage_fences(self):
        self.land('good', 'yes')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 0)
        with_base = self.run_batch('--repeat', '--base', self.base)
        self.assertEqual(with_base.returncode, 2)
        self.assertIn('cannot be combined', with_base.stdout + with_base.stderr)
        self.assertEqual(len(self.reports()), 1)

        self.git('checkout', '-qb', 'off-main')
        self.write('off-main', 'yes')
        self.commit('off-main commit')
        result = self.run_batch('--repeat')
        self.assertEqual(result.returncode, 2)
        self.assertIn('must be ordered commits on main first-parent history', result.stdout)
        self.assertEqual(len(self.reports()), 1)

    def test_missing_lane_is_uncovered_but_later_lanes_execute(self):
        (self.root / 'packages/gateway/package-lock.json').unlink()
        self.commit('missing Gateway owner')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'uncovered')
        self.assertEqual(len(report['results']), 9)
        self.assertIn('boundary-run-ui', (self.root / 'test-results/executed').read_text())
        self.assertFalse((self.root / '.git/verify/green.json').exists())

    def test_all_lanes_after_red_case_only_merge_attribution_twice_and_issue_dedupe(self):
        self.land('good', 'yes')
        culprit = self.land('bad', 'yes')
        self.land('later', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'red')
        self.assertEqual(len(report['results']), 9)
        failure = report['failures'][0]
        proof = failure['attribution']
        self.assertEqual(proof['status'], 'proven', proof)
        self.assertEqual(proof['commit'], culprit)
        self.assertEqual(proof['files'], ['bad'])
        head = self.git('rev-parse', 'HEAD')
        fresh = [(p['commit'], p['outcome']) for p in proof['probes'] if p['fresh']]
        # Fresh controls: head and culprit fail twice, the first parent passes twice.
        self.assertEqual(fresh.count((head, 'bad')), 2)
        self.assertEqual(fresh.count((culprit, 'bad')), 2)
        self.assertEqual(fresh.count((proof['parent'], 'good')), 2)
        self.assertTrue(all(p['command'][-2:] == ['-t', '^suite\\ >\\ group\\ >\\ case$'] for p in proof['probes']))
        self.assertTrue(all(p['selectedTests'] == 1 for p in proof['probes'] if p.get('fresh')))
        repair = failure['repair']
        self.assertEqual(repair['state'], 'publication-disabled')
        self.assertEqual(self.git('rev-parse', 'revert/' + culprit), repair['candidate'])
        self.assertEqual(self.git('show', repair['candidate'] + ':good'), 'yes')
        self.assertNotIn('bad', self.git('ls-tree', '--name-only', repair['candidate']))
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        again = self.reports()[-1]
        self.assertTrue(again['failures'][0]['attribution']['reused'])
        self.assertEqual(len(list((self.root / '.git/verify/issue-writes').glob('*.json'))), 1)
        self.assertIn('work comment 100', (self.root / 'test-results/issue-writes').read_text())
        self.assertEqual(len(self.git('worktree', 'list', '--porcelain').split('worktree ')) - 1, 1)
        self.land('new-range', 'yes')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        later = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(later['commit'], culprit)
        self.assertTrue(any(p.get('reused') for p in later['probes']))
        self.assertEqual(len(list((self.root / '.git/verify/issue-writes').glob('*.json'))), 1)

    def test_octopus_landing_is_unresolved_not_guessed(self):
        for name in ('one', 'two'):
            self.git('checkout', '-qb', name, self.base)
            self.write(name, 'yes')
            self.commit(name)
        self.git('checkout', '-q', 'main')
        self.write('bad', 'yes')
        self.commit('red on main')
        self.git('merge', '-q', '--no-edit', 'one', 'two')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'unresolved')
        self.assertEqual(proof['unsupportedHistory'], [self.git('rev-parse', 'HEAD')])
        self.assertFalse(self.repair())
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def test_verifier_nonpass_verdicts_override_zero_exit(self):
        # Retired exemption labels are not verifier verdicts; neither they nor deferral are green.
        for verdict, expected in [('deferred', 'uncovered'), ('expired', 'uncovered'), ('quarantined', 'uncovered')]:
            with self.subTest(verdict=verdict):
                self.land('verifier-verdict', verdict)
                result = self.run_batch('--base', self.base)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                report = self.reports()[-1]
                self.assertEqual(report['results'][0]['exit'], 0)
                self.assertEqual(report['results'][0]['verifierVerdict'], verdict)
                self.assertEqual(report['verdict'], expected)

    def test_missing_report_cannot_turn_zero_exit_green(self):
        self.land('missing-report', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'uncovered')

    def test_mismatched_probe_signature_is_inconclusive_not_a_culprit(self):
        self.land('changed-signature', 'yes')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'unresolved')
        self.assertEqual(proof['probes'][-1]['outcome'], 'unknown')
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def test_nonreproducing_head_is_unresolved_red_not_qualified(self):
        self.land('flake', 'yes')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'red')
        proof = report['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'unresolved')
        self.assertIn('head did not reproduce', proof['reason'])
        self.assertEqual([p['outcome'] for p in proof['probes']], ['good'])
        self.assertFalse(self.repair())

    def test_empty_case_probe_is_unknown_not_good_parent_evidence(self):
        self.land('empty-probe', 'yes')
        self.base = self.git('rev-parse', 'HEAD')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'unresolved')
        self.assertEqual([p['outcome'] for p in proof['probes'] if p['commit'] == self.base], ['unknown'])
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def test_head_probe_selecting_no_tests_fails_loudly_instead_of_unresolved(self):
        # The case failed at head, so an exact-case recipe that runs nothing there is a broken selector.
        self.land('bad', 'yes')
        self.land('renamed-probe', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('selected no tests', result.stdout)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'error')
        self.assertIn('attribution probe for Gateway default selected no tests', report['error'])
        self.assertEqual(report['activeLane'], 'attribution: Gateway default')
        self.assertEqual(report['results'][1]['exit'], 1)
        self.assertTrue((Path(report['evidence'])).is_file())
        [progress] = (self.root / '.git/verify/batches').glob('*/attribution-1-0/progress.json')
        probes = json.loads(progress.read_text())['probes']
        self.assertEqual([(p['outcome'], p['selectedTests']) for p in probes], [('selector-error', 0)])
        self.assertFalse(list((self.root / '.git/verify/attributions').glob('*.json')), 'a selector error is never memoized')
        self.assertFalse((self.root / '.git/verify/green.json').exists())
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def test_lane_timing_is_recorded_and_never_changes_the_verdict(self):
        results = Path(self.temporary.name) / 'results'
        bin = Path(self.temporary.name) / 'bin'
        (bin / 'xcrun').write_text('''#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
path=args[args.index('--path')+1]
if 'broken' in path: sys.exit('xcresulttool: cannot open result bundle')
if args[:4]==['xcresulttool','get','test-results','tests']:
    print(json.dumps({'testNodes':[{'nodeType':'Test Plan','children':[{'nodeType':'Test Suite','children':[
        {'nodeType':'Test Case','nodeIdentifier':'Journeys/testFlow()','result':'Passed','durationInSeconds':4.5}]}]}]}))
elif args[:4]==['xcresulttool','get','test-results','activities'] and args[args.index('--test-id')+1]=='Journeys/testFlow()':
    print(json.dumps({'testRuns':[{'activities':[
        {'title':'Start Test','startTime':100.0},
        {'title':'Tap "Send" Button','startTime':100.5,'childActivities':[{'title':'Wait for app to idle','startTime':100.6}]},
        {'title':'Tap "Done" Button','startTime':102.0,'childActivities':[{'title':'Wait for app to idle','startTime':102.1}]},
        {'title':'Tear Down','startTime':102.75}]}]}))
else: sys.exit('unexpected xcrun '+' '.join(args))
''')
        (bin / 'xcrun').chmod(0o755)
        self.land('scripts/ios-gateway-e2e-test', '#!/bin/sh\nmkdir -p test-results\necho boundary-$1 >> test-results/executed\n'
                  f'if [ "$1" = run-ui ]; then for j in good broken; do mkdir -p {results}/$j/Journeys.xcresult; '
                  'echo "Real-UI journey Tron/Journeys/test-$j completed in 7s (status 0); evidence: ' + str(results) + '/$j"; '
                  f'printf "\\t%s\\n" {results}/$j/Journeys.xcresult; done; fi\n')
        self.land('scripts/tron-xcodebuild', '#!/bin/sh\necho mac-build >> test-results/executed\n'
                  'printf "Build Timing Summary\\n\\nSwiftCompile (12 tasks) | 40.5 seconds\\n\\nLd (2 tasks) | 1.25 seconds\\n\\n** TEST BUILD SUCCEEDED **\\n"\n')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'green')
        lanes = {lane['name']: lane for lane in report['results']}
        self.assertTrue(all(lane['timing']['seconds'] == lane['seconds'] for lane in lanes.values()))
        self.assertEqual(lanes['Gateway default']['timing']['vitestFiles'], {'vitest.json': [
            {'file': 'packages/gateway/src/example.test.ts', 'seconds': 1.5, 'cases': 1, 'status': 'passed'}]})
        self.assertEqual(lanes['Mac integration']['timing']['buildTiming'], [{'log': 'output.log', 'buckets': [
            {'bucket': 'SwiftCompile', 'tasks': 12, 'seconds': 40.5}, {'bucket': 'Ld', 'tasks': 2, 'seconds': 1.25}]}])
        ui = lanes['real Gateway UI journeys']['timing']
        self.assertEqual(ui['journeys'], [{'kind': 'Real-UI journey', 'test': f'Tron/Journeys/test-{name}', 'seconds': 7, 'status': 0}
                                          for name in ('good', 'broken')])
        self.assertEqual(ui['xcresults'], [{'bundle': str(results / 'good/Journeys.xcresult'), 'cases': [{
            'test': 'Journeys/testFlow()', 'result': 'Passed', 'seconds': 4.5, 'runs': [{
                'activities': 4, 'idleWaits': 2,
                'slowest': [{'title': 'Tap "Send" Button', 'seconds': 1.5}, {'title': 'Tap "Done" Button', 'seconds': 0.75},
                            {'title': 'Start Test', 'seconds': 0.5}],
                'byKind': {'Tap … Button': {'count': 2, 'seconds': 2.25}, 'Start Test': {'count': 1, 'seconds': 0.5}}}]}]}])
        # An unreadable bundle is an observation error, not a coverage or verdict input.
        [error] = ui['errors']
        self.assertEqual(error, f"tests {results / 'broken/Journeys.xcresult'}: xcresulttool exit 1: "
                                'xcresulttool: cannot open result bundle')

    def test_second_culprit_reproduction_is_required(self):
        self.land('unstable-repeat', 'yes')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'unresolved')
        self.assertEqual(proof['probes'][-1]['outcome'], 'good')
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def test_mac_swift_testing_summary_is_covered_despite_empty_xctest_suite(self):
        binary = Path(self.temporary.name) / 'bin/xcodebuild'
        binary.write_text('#!/bin/sh\necho "Executed 0 tests, with 0 failures"\necho "✔ Test run with 52 tests in 13 suites passed after 153 seconds."\n')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'green')
        self.assertNotEqual(report['results'][3].get('status'), 'uncovered')

    def test_mac_xctest_case_filter_proves_landing_without_suite_probe(self):
        binary = Path(self.temporary.name) / 'bin/xcodebuild'
        binary.write_text('''#!/usr/bin/env python3
import sys
from pathlib import Path
if Path('mac-bad').exists():
    selected=[arg for arg in sys.argv if arg.startswith('-only-testing:')]
    if selected and selected != ['-only-testing:TronMacIntegrationTests/SampleTests/testExample']:
        raise SystemExit('wrong XCTest filter')
    print("Test Case '-[TronMacIntegrationTests.SampleTests testExample]' failed")
    print('sample.swift:12: error: Assertion failed')
    raise SystemExit(1)
print('Executed 2 tests, with 0 failures')
''')
        culprit = self.land('mac-bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual((proof['status'], proof['commit']), ('proven', culprit))
        self.assertTrue(all('-only-testing:TronMacIntegrationTests/SampleTests/testExample' in p['command'] for p in proof['probes']))

    def test_ios_smoke_case_selector_proves_landing_with_own_build(self):
        owner = (self.root / 'scripts/tron-ios-test').read_text()
        failure = """if Path('ios-bad').exists() and sys.argv[1] == 'checkpoint':
    if '--only-testing' in sys.argv:
        assert sys.argv[-1] == 'TronMobileUITests/SampleTests/testExample'
    Path('test-results/summary.json').write_text(json.dumps({'passedTests':0,'testFailures':[{'testIdentifierString':'TronMobileUITests/SampleTests/testExample','failureText':'AssertionError: stable smoke failure'}]}))
    print('AssertionError: stable smoke failure')
    print('iOS test run failed with status 65: '+str(Path('test-results').resolve()))
    raise SystemExit(65)
"""
        owner = owner.replace("if sys.argv[1] in ('run', 'checkpoint'):", failure + "if sys.argv[1] in ('run', 'checkpoint'):")
        self.write('scripts/tron-ios-test', owner, True)
        self.commit('case-selecting smoke owner')
        self.base = self.git('rev-parse', 'HEAD')
        culprit = self.land('ios-bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual((proof['status'], proof['commit']), ('proven', culprit))
        self.assertTrue(all(p['command'][1:3] == ['checkpoint', '--only-testing'] for p in proof['probes']))

    def test_real_ui_journey_attribution_uses_owned_exact_selector(self):
        self.write('scripts/ios-gateway-e2e-test', '''#!/usr/bin/env python3
import sys
from pathlib import Path
if sys.argv[1] == 'run-ui' and Path('ui-bad').exists():
    if '--only-testing' in sys.argv: assert sys.argv[-1] == 'TronMobileUITests/SampleTests/testExample'
    print('failure: stable journey failure')
    print('Real-UI journey TronMobileUITests/SampleTests/testExample completed in 1s (status 65); evidence: fixture')
    raise SystemExit(65)
''', True)
        self.commit('case-selecting UI owner')
        self.base = self.git('rev-parse', 'HEAD')
        culprit = self.land('ui-bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual((proof['status'], proof['commit']), ('proven', culprit))
        self.assertTrue(all('--only-testing' in p['command'] for p in proof['probes']))

    def test_real_boundary_attribution_uses_owned_exact_method_after_build(self):
        self.write('scripts/ios-gateway-e2e-test', '''#!/usr/bin/env python3
import sys
from pathlib import Path
if sys.argv[1] == 'all' and Path('boundary-bad').exists():
    if '--only-testing' in sys.argv: assert sys.argv[-1] == 'TronMobileE2ETests/RealGatewayPiBoundaryTests/testSharedLinkUploadAndWebSocketLiveness'
    print('failure: stable boundary failure')
    print('Focused E2E case TronMobileE2ETests/RealGatewayPiBoundaryTests/testSharedLinkUploadAndWebSocketLiveness completed in 1s (status 65); artifacts: fixture')
    raise SystemExit(65)
''', True)
        self.commit('case-selecting boundary owner')
        self.base = self.git('rev-parse', 'HEAD')
        culprit = self.land('boundary-bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'proven', proof)
        self.assertEqual(proof['commit'], culprit)
        self.assertTrue(all(p['command'][1:3] == ['all', '--only-testing'] for p in proof['probes']))

    def test_missing_verifier_report_and_skipped_cases_are_uncovered(self):
        command = (self.root / 'scripts/tron').read_text()
        self.write('scripts/tron', command.replace("Path('test-results/verify',sha+'.json').write_text", "# no report: "), True)
        self.commit('no verifier report')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['results'][0]['status'], 'uncovered')
        self.write('scripts/tron', command, True)
        self.commit('restore owner')
        self.land('skipped', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'uncovered')

    def test_busy_host_slots_defer_every_ios_lane_without_invoking_it(self):
        owner = (self.root / 'scripts/ios-test-lock.py').read_text()
        self.write('scripts/ios-test-lock.py', owner.replace('[None,None,None]', "['holder','holder','holder']"))
        self.commit('busy host slots')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        ios = [lane for lane in report['results'] if lane.get('ios')]
        self.assertEqual(len(ios), 4)
        self.assertTrue(all(lane['status'] == 'uncovered' and 'deferred' in lane['reason'] for lane in ios))
        self.assertNotIn('compile', (self.root / 'test-results/executed').read_text())

    def test_uncertain_issue_write_is_not_replayed(self):
        self.land('issue-refuse', 'yes')
        self.land('bad', 'yes')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        self.assertEqual(len((self.root / 'test-results/issue-writes').read_text().splitlines()), 1)
        self.assertTrue(self.reports()[-1]['failures'][0]['issue']['reused'])

    def test_cleanup_refusal_preserves_probe_and_recovery_record(self):
        self.write('scripts/ios-gateway-e2e-test', '#!/bin/sh\nmkdir -p test-results\n[ "$1" != clean ] || exit 73\n', True)
        self.commit('refusing resource owner')
        self.base = self.git('rev-parse', 'HEAD')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertTrue(Path(proof['retainedWorktree']).is_dir())
        self.assertEqual(proof['cleanup'][0]['exit'], 73)

    def test_sigterm_during_probe_cleanup_preserves_recovery_evidence(self):
        owner = (self.root / 'scripts/tron-ios-test').read_text()
        held = """import os,time,subprocess
if sys.argv[1] == 'clean':
    common=Path(subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip())
    (common/'cleanup.pid').write_text(str(os.getpid()))
    time.sleep(300)
"""
        self.write('scripts/tron-ios-test', owner.replace("Path('test-results').mkdir(exist_ok=True)", held + "Path('test-results').mkdir(exist_ok=True)", 1), True)
        self.commit('held resource cleanup')
        self.base = self.git('rev-parse', 'HEAD')
        self.land('bad', 'yes')
        process = subprocess.Popen(['scripts/tron', 'verify', '--batch', '--base', self.base], cwd=self.root,
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            marker = self.root / '.git/cleanup.pid'
            deadline = time.monotonic() + 30
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(marker.exists())
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=40)
            self.assertEqual(process.returncode, 130, output)
            self.assertEqual(self.reports()[-1]['verdict'], 'interrupted')
            progress = json.loads(next((self.root / '.git/verify/batches').glob('*/attribution-*/progress.json')).read_text())
            self.assertEqual(progress['cleanup'][-1]['exit'], 130)
            self.assertTrue(Path(progress['retainedWorktree']).is_dir())
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=40)

    def test_source_changed_by_lane_never_advances_coverage(self):
        self.write('scripts/tron-xcodebuild', '#!/bin/sh\necho changed >> packages/mac-app/project.yml\n', True)
        self.commit('lane mutates its source')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('source changed', self.reports()[-1]['error'])
        self.assertFalse((self.root / '.git/verify/green.json').exists())

    def test_overlap_refuses_without_wait(self):
        import fcntl
        state = self.root / '.git/verify'
        state.mkdir()
        with (state / 'batch.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.run_batch('--base', self.base)
            self.assertEqual(result.returncode, 2)
            self.assertIn('no queue or wait', result.stdout)

    def test_sigterm_joins_lane_descendants_keeps_partial_report(self):
        self.land('hold', 'yes')
        process = subprocess.Popen(['scripts/tron', 'verify', '--batch', '--base', self.base], cwd=self.root,
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            pid_file = self.root / 'test-results/child.pid'
            deadline = time.monotonic() + 20
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(pid_file.exists())
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=40)
            self.assertEqual(process.returncode, 130, output)
            self.assertEqual(self.reports()[-1]['verdict'], 'interrupted')
            child = int(pid_file.read_text())
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(.02)
            else:
                self.fail('owned descendant survived SIGTERM')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=40)


    # Causal source auto-revert (#2194): real Git remote, real batch CLI, controlled reviewer.

    def red_with_review(self, *, merge=True):
        self.remote()
        self.land('good', 'yes')
        if merge:
            culprit = self.land('bad', 'yes')
        else:
            self.write('bad', 'yes')
            self.commit('fast-forward landing')
            culprit = self.git('rev-parse', 'HEAD')
        self.land('later', 'yes')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'red')
        proof = report['failures'][0]['attribution']
        self.assertEqual((proof['status'], proof['commit']), ('proven', culprit), proof)
        [repair] = self.repair()
        self.assertEqual((repair['state'], repair['culprit'], repair['tip']), ('review-required', culprit, tip))
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip, 'nothing is pushed before an ACCEPT')
        result_line = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(result_line['repairs'][0]['state'], 'review-required')
        self.assertIn('--binding ' + repair['bindingDigest'], result_line['repairs'][0]['next'])
        return culprit, tip, repair

    def test_merge_landing_red_is_reverted_after_bound_accept_then_green(self):
        culprit, tip, repair = self.red_with_review()
        request = json.loads(Path(repair['reviewRequest']).read_text())
        self.assertEqual(request['bindings']['culprit'], culprit)
        self.assertTrue(Path(request['bindings']['evidence']).is_file())
        wrong = self.review(repair, binding='0' * 64)
        self.assertEqual(wrong.returncode, 2, wrong.stdout + wrong.stderr)
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)
        published = self.review(repair)
        self.assertEqual(published.returncode, 0, published.stdout + published.stderr)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'published')
        head = self.remote_git('rev-parse', 'main')
        self.assertEqual(self.remote_git('rev-parse', 'main^'), tip, 'plain fast-forward onto the tested tip')
        self.assertEqual(self.reverts_on_remote(culprit), [head + ' ' + culprit])
        files = self.remote_git('ls-tree', '--name-only', 'main').splitlines()
        self.assertNotIn('bad', files)
        self.assertIn('later', files)
        self.assertIn('good', files)
        self.git('fetch', '-q', 'origin')
        self.git('merge', '-q', '--ff-only', 'origin/main')
        green = self.run_batch('--base', self.base)
        self.assertEqual(green.returncode, 0, green.stdout + green.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'green')
        self.assertEqual(json.loads((self.root / '.git/verify/green.json').read_text())['commit'], head)
        again = self.review(repair)
        self.assertNotEqual(again.returncode, 0)
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1, 'a repeated ACCEPT never adds a second revert')

    def test_fast_forward_single_parent_landing_is_reverted(self):
        culprit, tip, repair = self.red_with_review(merge=False)
        self.assertEqual(self.review(repair).returncode, 0)
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1)
        self.assertNotIn('bad', self.remote_git('ls-tree', '--name-only', 'main').splitlines())

    def test_publication_is_disabled_without_the_enable_step(self):
        self.remote(publish=False)
        culprit = self.land('bad', 'yes')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'publication-disabled')
        self.assertNotIn('bad', self.git('ls-tree', '--name-only', repair['candidate']).splitlines())
        refused = self.review({**repair, 'bindingDigest': repair.get('bindingDigest') or '0' * 64})
        self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)
        self.assertFalse(self.reverts_on_remote(culprit))

    def test_innocent_concurrent_landing_survives_and_stale_accept_rebinds(self):
        culprit, tip, repair = self.red_with_review()
        innocent = self.other_clone_lands('innocent', 'yes')
        stale = self.review(repair)
        self.assertEqual(stale.returncode, 1, stale.stdout + stale.stderr)
        self.assertEqual(self.remote_git('rev-parse', 'main'), innocent, 'a stale ACCEPT cannot publish')
        [rebound] = self.repair()
        self.assertEqual((rebound['state'], rebound['tip']), ('review-required', innocent))
        self.assertNotEqual(rebound['bindingDigest'], repair['bindingDigest'])
        self.assertEqual(self.review(rebound).returncode, 0)
        files = self.remote_git('ls-tree', '--name-only', 'main').splitlines()
        self.assertIn('innocent', files)
        self.assertNotIn('bad', files)
        self.assertEqual(self.remote_git('rev-parse', 'main^'), innocent)

    def test_uncertain_push_is_reconciled_from_remote_without_replay(self):
        culprit, tip, repair = self.red_with_review()
        wrapper = Path(self.temporary.name) / 'receive-pack-exit-1'
        wrapper.write_text('#!/bin/sh\ngit-receive-pack "$@"\nexit 1\n')
        wrapper.chmod(0o755)
        self.git('config', 'remote.origin.receivepack', str(wrapper))
        result = self.review(repair)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'published')
        self.assertNotEqual(repair['push']['exit'], 0)
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1)

    def test_crash_after_remote_acceptance_discovers_the_published_revert(self):
        culprit, tip, repair = self.red_with_review()
        wrapper = Path(self.temporary.name) / 'receive-pack-crash'
        # Accept the push, then SIGKILL the batch owner before it can record the result.
        wrapper.write_text('#!/bin/sh\n'
                           'git-receive-pack "$@"\n'
                           'pid=$PPID\n'
                           'while [ "$pid" -gt 1 ]; do\n'
                           '  if ps -o command= -p "$pid" | grep -q "tools/verify/verify.py"; then kill -9 "$pid"; break; fi\n'
                           '  pid=$(ps -o ppid= -p "$pid" | tr -d " ")\n'
                           'done\n')
        wrapper.chmod(0o755)
        self.git('config', 'remote.origin.receivepack', str(wrapper))
        crashed = self.review(repair)
        self.assertEqual(crashed.returncode, -9, crashed.stdout + crashed.stderr)
        [pending] = self.repair()
        self.assertEqual(pending['state'], 'push-intent')
        self.git('config', '--unset', 'remote.origin.receivepack')
        recovered = self.review(repair)
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'published')
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1)
        # A later batch over the same red range reuses the journal instead of building another revert.
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1)

    def test_red_already_fixed_on_main_is_stale_and_not_reverted(self):
        self.remote()
        culprit = self.land('bad', 'yes')
        self.push()
        fixed = self.other_clone_lands('bad')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual((repair['state'], repair['culprit']), ('stale', culprit))
        self.assertEqual(self.remote_git('rev-parse', 'main'), fixed)
        self.assertFalse(self.reverts_on_remote(culprit))

    def test_irreversible_migration_boundary_refuses_publication(self):
        self.remote()
        self.git('checkout', '-qb', 'topic-migration')
        self.write('bad', 'yes')
        self.write('packages/gateway/src/store/migrations/0002-move.ts', 'export {}\n')
        self.commit('red with a migration')
        self.git('checkout', '-q', 'main')
        self.git('merge', '-q', '--no-ff', '--no-edit', 'topic-migration')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'refused')
        self.assertIn('migration', repair['reason'])
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)

    def test_reviewer_block_is_terminal_and_pushes_nothing(self):
        culprit, tip, repair = self.red_with_review()
        blocked = self.review(repair, decision='BLOCK')
        self.assertEqual(blocked.returncode, 1, blocked.stdout + blocked.stderr)
        self.assertEqual(self.repair()[0]['state'], 'refused')
        self.assertEqual(self.review(repair).returncode, 2)
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)

    def test_conflicting_inverse_is_preserved_not_resolved(self):
        self.remote()
        self.land('bad', 'yes')
        self.land('bad', 'still present, edited later')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'refused')
        self.assertIn('conflict', repair['reason'])
        self.assertTrue(Path(repair['worktree']).is_dir())
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)

    def test_security_risk_owner_refuses_publication(self):
        self.remote()
        self.git('checkout', '-qb', 'topic-security')
        self.write('bad', 'yes')
        self.write('packages/gateway/src/auth/auth.module.json', json.dumps({'layer': 'L3', 'owns': ['**'], 'riskClass': ['security']}))
        self.write('packages/gateway/src/auth/token.ts', 'export const scope = "admin";\n')
        self.commit('red with a security owner')
        self.git('checkout', '-q', 'main')
        self.git('merge', '-q', '--no-ff', '--no-edit', 'topic-security')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'refused')
        self.assertIn('packages/gateway/src/auth/token.ts', repair['reason'])
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)

    def test_a_batch_records_its_gateway_lanes_as_the_full_gateway_lock_holder(self):
        self.land('good', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        holder = json.loads((Path(self.temporary.name) / 'full-gateway.lock').read_text())
        self.assertEqual(holder['purpose'], 'verify --batch: Gateway nested')
        windows = {lane['name']: lane.get('fullGatewayLock') for lane in self.reports()[-1]['results']}
        self.assertEqual([name for name, window in windows.items() if window], ['Gateway default', 'Gateway nested'])
        default, nested = windows['Gateway default'], windows['Gateway nested']
        self.assertLessEqual(default['acquiredAt'], default['releasedAt'])
        self.assertLessEqual(default['releasedAt'], nested['acquiredAt'], 'batch Gateway lanes never overlap')

    def gateway_runs(self):
        runs = GatewayRuns(Path(self.temporary.name) / 'full-gateway.lock')
        self.addCleanup(runs.close)
        return runs

    def test_held_full_gateway_lock_leaves_gateway_lanes_uncovered_after_the_capped_wait(self):
        self.land('good', 'yes')
        # The shipped cap is 45 minutes; this fixture's copy of the batch waits 2 seconds.
        source = (self.root / 'tools/verify/batch.py').read_text()
        self.assertIn('\nFULL_GATEWAY_LOCK_WAIT_SECONDS = 45 * 60\n', source)
        self.land('tools/verify/batch.py', source.replace('\nFULL_GATEWAY_LOCK_WAIT_SECONDS = 45 * 60\n', '\nFULL_GATEWAY_LOCK_WAIT_SECONDS = 2\n'))
        runs = self.gateway_runs()
        holder = runs.start('holder')
        runs.wait_holding('holder')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'uncovered')
        lanes = {lane['name']: lane for lane in report['results']}
        self.assertEqual(len(lanes), 9)
        for name in ('Gateway default', 'Gateway nested'):
            lane = lanes[name]
            self.assertEqual((lane['status'], lane['exit']), ('uncovered', None))
            self.assertIn('full-Gateway run held', lane['reason'])
            self.assertIn(f'"pid": {holder.pid}', lane['reason'])
            self.assertIn('gateway vitest holder', lane['reason'])
            self.assertRegex(lane['reason'], r'waited \d+s')
            self.assertGreaterEqual(lane['seconds'], 2)
        self.assertNotIn('default', (self.root / 'test-results/executed').read_text().split())
        self.assertTrue(all(lane['exit'] == 0 for name, lane in lanes.items() if not name.startswith('Gateway ')))
        self.assertFalse((self.root / '.git/verify/green.json').exists())
        self.assertIsNone(holder.poll(), 'a capped lane never interrupts the holder')
        self.assertEqual(sorted(Path(self.temporary.name).glob('full-gateway.lock.queue/*')), [], 'a capped lane leaves no ticket')
        # The capped lanes left the line: the next run follows the holder.
        runs.start('next')
        runs.wait_queued('next')
        runs.release('holder')
        runs.wait_all()
        self.assertEqual(runs.names(), ['holder', 'next'])

    def land_gateway_lane_marker(self, order):
        """The fixture Gateway lane also records itself in `order` once its lane holds the lock."""
        source = (self.root / 'tools/verify/gateway.py').read_text()
        self.land('tools/verify/gateway.py', source.replace(
            "with (root/'test-results/executed').open('a') as f: f.write(name+' '+repr(args)+'\\n')\n",
            "with (root/'test-results/executed').open('a') as f: f.write(name+' '+repr(args)+'\\n')\n"
            f"with open({str(order)!r}, 'a') as f: f.write('batch-'+name+'\\n')\n", 1))
        self.assertIn('batch-', (self.root / 'tools/verify/gateway.py').read_text())

    def test_due_gateway_lanes_wait_their_turn_in_arrival_order_with_other_gateway_runs(self):
        runs = self.gateway_runs()
        self.land_gateway_lane_marker(runs.order)
        runs.start('holder')
        runs.wait_holding('holder')
        output = Path(self.temporary.name) / 'batch.out'
        with output.open('w') as stream:
            batch = subprocess.Popen(['scripts/tron', 'verify', '--batch', '--base', self.base], cwd=self.root,
                                     env=self.env, stdout=stream, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: batch.poll() is None and (batch.terminate(), batch.wait(timeout=40)))
        wait_until(lambda: batch.poll() is not None or 'Gateway default waiting for' in output.read_text(),
                   'the Gateway lane neither waited nor exited')
        self.assertIsNone(batch.poll(), 'a due Gateway lane waits behind the holder instead of refusing:\n' + output.read_text())
        for name in ('later-1', 'later-2'):
            runs.start(name)
            runs.wait_queued(name)
        runs.release('holder')
        self.assertEqual(batch.wait(timeout=90), 0, output.read_text())
        runs.wait_all()
        # The nested lane queues again after its default lane releases, so earlier arrivals go first.
        self.assertEqual(runs.names(), ['holder', 'batch-default', 'later-1', 'later-2', 'batch-nested'])

    def test_an_interrupt_cancels_a_lane_waiting_for_the_full_gateway_lock(self):
        """#2253 review: the Gateway lane waits on a chain thread; SIGTERM must end that wait at once,
        give up its queue place and never start the lane, then report the batch interrupted."""
        runs = self.gateway_runs()
        self.land_gateway_lane_marker(runs.order)
        runs.start('holder')
        runs.wait_holding('holder')
        output = Path(self.temporary.name) / 'batch.out'
        with output.open('w') as stream:
            batch = subprocess.Popen(['scripts/tron', 'verify', '--batch', '--base', self.base], cwd=self.root,
                                     env=self.env, stdout=stream, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: batch.poll() is None and (batch.kill(), batch.wait(timeout=40)))
        wait_until(lambda: batch.poll() is not None or 'Gateway default waiting for' in output.read_text(),
                   'the Gateway lane neither waited nor exited')
        self.assertIsNone(batch.poll(), output.read_text())
        batch.send_signal(signal.SIGTERM)
        self.assertEqual(batch.wait(timeout=15), 130, output.read_text())
        self.assertEqual(self.reports()[-1]['verdict'], 'interrupted')
        # The holder still has the lock; once it releases, nothing of the batch takes it.
        runs.start('after')
        runs.wait_queued('after')
        runs.release('holder')
        runs.wait_all(['holder', 'after'])
        self.assertEqual(runs.names(), ['holder', 'after'])

    def test_pre_land_gateway_runs_do_not_wait_for_the_ui_journey_lane(self):
        runs = self.gateway_runs()
        self.land_gateway_lane_marker(runs.order)
        gate = Path(self.temporary.name) / 'ui-gate'
        gate.mkdir()
        self.land('scripts/ios-gateway-e2e-test', '#!/bin/sh\nmkdir -p test-results\necho boundary-$1 >> test-results/executed\n'
                  f'if [ "$1" = run-ui ]; then touch {gate}/started; while [ ! -e {gate}/release ]; do sleep 0.05; done; fi\n')
        output = Path(self.temporary.name) / 'batch.out'
        with output.open('w') as stream:
            batch = subprocess.Popen(['scripts/tron', 'verify', '--batch', '--base', self.base], cwd=self.root,
                                     env=self.env, stdout=stream, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: batch.poll() is None and (batch.terminate(), batch.wait(timeout=40)))
        self.addCleanup(lambda: gate.is_dir() and (gate / 'release').touch())
        wait_until(lambda: (gate / 'started').exists() or batch.poll() is not None, 'the UI journey lane never started', timeout=60)
        self.assertIsNone(batch.poll(), output.read_text())
        # The Node chain runs beside the UI journeys; once its Gateway lanes are done, a
        # pre-land Gateway run takes the free lock at once while the journeys still run.
        wait_until(lambda: self.reports() and 'Gateway nested' in [lane['name'] for lane in self.reports()[-1]['results']],
                   'the Gateway lanes never finished beside the UI journeys', timeout=60)
        runs.start('pre-land')
        runs.wait_all(['pre-land'])
        self.assertNotIn('waiting for', runs.stderr('pre-land'))
        (gate / 'release').touch()
        self.assertEqual(batch.wait(timeout=90), 0, output.read_text())
        self.assertEqual(runs.names(), ['batch-default', 'batch-nested', 'pre-land'])

    def test_node_and_apple_chains_run_concurrently_and_join_before_the_verdict(self):
        """#2253: each chain waits for a lane of the other, so a sequential batch could not finish.
        The report keeps plan order, and the verdict comes only after both chains joined."""
        gate = Path(self.temporary.name) / 'chains'
        gate.mkdir()
        source = (self.root / 'tools/verify/gateway.py').read_text()
        self.land('tools/verify/gateway.py', source.replace(
            "name='nested' if nested else 'default'\n",
            "name='nested' if nested else 'default'\n"
            f"gate=Path({str(gate)!r})\n"
            "if name=='default':\n"
            "    deadline=time.time()+30\n"
            "    while not (gate/'apple-boundary').exists():\n"
            "        if time.time()>deadline: sys.exit('the Apple chain never ran beside the Node chain')\n"
            "        time.sleep(0.05)\n"
            "else: (gate/'node-nested').touch()\n", 1))
        self.land('scripts/ios-gateway-e2e-test', '#!/bin/sh\nmkdir -p test-results\necho boundary-$1 >> test-results/executed\n'
                  f'if [ "$1" = all ]; then touch {gate}/apple-boundary; fi\n'
                  f'if [ "$1" = run-ui ]; then i=0; while [ ! -e {gate}/node-nested ]; do i=$((i+1)); [ $i -gt 600 ] && exit 1; sleep 0.05; done; fi\n')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('batch: concurrent chains: node: full verify → Gateway default → Gateway nested → Mac integration → relay; '
                      'apple: shipping iOS compile → iOS smoke → real Gateway boundary → real Gateway UI journeys', result.stdout)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'green')
        self.assertEqual([lane['name'] for lane in report['results']], [lane['name'] for lane in report['lanes']])
        lanes = {lane['name']: lane for lane in report['results']}
        self.assertLess(lanes['real Gateway boundary']['endedAt'], lanes['Gateway default']['endedAt'])
        self.assertLess(lanes['Gateway nested']['startedAt'], lanes['real Gateway UI journeys']['endedAt'])

    def test_the_apple_chain_has_its_own_simulator_lane_beside_the_verifiers_ios_steps(self):
        """#2253 review: the verifier's iOS steps (Node chain) and the Apple chain's smoke, boundary and
        UI lanes run at once in one worktree. A lane lease refuses a second holder at once (73), so
        they must not share this worktree's lane, nor the smoke build its DerivedData."""
        lease = ('''import fcntl,os,sys,time
from pathlib import Path
Path('test-results').mkdir(exist_ok=True)
lane=os.environ.get('TRON_IOS_TEST_LANE','worktree')
handle=open('test-results/lane-'+lane+'.lock','a')
try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: print('error: lane '+lane+' is already leased'); sys.exit(73)
with open('test-results/lanes','a') as f: f.write(sys.argv[0].rsplit('/',1)[-1]+' '+sys.argv[1]+' '+lane+' '+os.environ.get('TRON_IOS_TEST_DERIVED_DATA','worktree-products')+'\\n')
Path('test-results/started-'+sys.argv[1]).touch()
# Hold the lease until the other chain's iOS step has started too, so the two overlap.
other={'build':'checkpoint','checkpoint':'build'}.get(sys.argv[1])
deadline=time.time()+20
while other and not Path('test-results/started-'+other).exists() and time.time()<deadline: time.sleep(0.05)
''')
        for owner in ('scripts/tron-ios-test', 'scripts/ios-gateway-e2e-test'):
            source = (self.root / owner).read_text()
            if owner == 'scripts/tron-ios-test':
                source = source.replace("import json,sys\n", "import json,sys\n" + lease, 1)
            else:
                source = '#!/usr/bin/env python3\n' + lease + "with open('test-results/executed','a') as f: f.write('boundary-'+sys.argv[1]+'\\n')\n"
            self.write(owner, source, True)
        tron = (self.root / 'scripts/tron').read_text()
        self.write('scripts/tron', tron.replace(
            "if affected == 'red': verdict = 'failed'\n",
            "if affected == 'red': verdict = 'failed'\n"
            "if sys.argv[1:3] == ['verify','--all'] and subprocess.call(['scripts/tron-ios-test','build']): verdict = 'deferred'\n", 1), True)
        self.commit('lane leases')
        self.base = self.git('rev-parse', 'HEAD')
        self.land('good', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'green')
        lanes = [line.split() for line in (self.root / 'test-results/lanes').read_text().splitlines()]
        verifier = [lane for lane in lanes if lane[1] == 'build']
        apple = [lane for lane in lanes if lane[1] in ('checkpoint', 'all', 'run-ui')]
        self.assertEqual(len(verifier), 1, lanes)
        self.assertEqual(len(apple), 3, lanes)
        self.assertEqual({lane[2] for lane in verifier}, {'worktree'})
        self.assertEqual(len({lane[2] for lane in apple}), 1, lanes)
        self.assertNotEqual(apple[0][2], 'worktree')
        smoke = next(lane for lane in apple if lane[1] == 'checkpoint')
        self.assertNotEqual(smoke[3], 'worktree-products', 'the smoke build must not share the verifier\'s products')

    def test_a_red_in_one_chain_still_runs_the_other_chain_before_attribution(self):
        """#2253: a failing Node lane does not stop the Apple chain; the freeze sees every lane."""
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(len(report['results']), 9)
        first = json.loads(next((self.root / '.git/verify/batches').glob('*/first-report.json')).read_text())
        self.assertEqual([lane['name'] for lane in first['results']], [lane['name'] for lane in report['lanes']])
        self.assertIn('boundary-run-ui', (self.root / 'test-results/executed').read_text())

    def test_ui_journeys_run_on_owned_lanes_longest_first_from_the_previous_batch(self):
        """#2253: the UI journey lane takes three host-slot lanes and, from the second batch on,
        the previous batch's per-journey seconds."""
        self.land('scripts/ios-gateway-e2e-test', '#!/bin/sh\nmkdir -p test-results\necho boundary-$1 >> test-results/executed\n'
                  'if [ "$1" = run-ui ]; then echo "lanes=$TRON_IOS_E2E_UI_LANES seconds=${TRON_IOS_E2E_UI_JOURNEY_SECONDS:-none}" >> test-results/ui-env;\n'
                  '  echo "Real-UI journey TronMobileUITests/RealGatewayPairAndChatUITests/testSlow completed in 200s (status 0); evidence: /nowhere"\n'
                  '  echo "Real-UI journey TronMobileUITests/RealGatewayPairAndChatUITests/testQuick completed in 40s (status 0); evidence: /nowhere"; fi\n')
        first = self.run_batch('--base', self.base)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second = self.run_batch('--repeat')
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        environments = (self.root / 'test-results/ui-env').read_text().splitlines()
        self.assertEqual(environments[0], 'lanes=3 seconds=none')
        lanes, seconds = environments[1].split(' ')
        self.assertEqual(lanes, 'lanes=3')
        self.assertEqual(json.loads(Path(seconds.split('=', 1)[1]).read_text()), {
            'TronMobileUITests/RealGatewayPairAndChatUITests/testSlow': 200,
            'TronMobileUITests/RealGatewayPairAndChatUITests/testQuick': 40})

    def test_a_host_slot_this_batch_holds_does_not_defer_its_other_chain(self):
        """#2253: every slot held, but one by this batch's own worktree: that slot frees when its lane
        ends, so the Apple lanes are admitted (and wait for it) rather than deferred."""
        owner = (self.root / 'scripts/ios-test-lock.py').read_text()
        self.land('scripts/ios-test-lock.py', owner.replace(
            'def read_slot_holders(): return [None,None,None]\ndef slot_worktrees(): return [None,None,None]',
            'from pathlib import Path\ndef read_slot_holders(): return ["this batch","other","other"]\n'
            'def slot_worktrees(): return [str(Path(__file__).resolve().parents[1]),"/elsewhere",""]'))
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'green')
        self.assertNotIn('--skip', json.dumps(self.reports()[-1]['results'][0]['executedCommand']))

    def test_red_while_disabled_publishes_after_the_enable_step(self):
        self.remote(publish=False)
        culprit = self.land('bad', 'yes')
        self.push()
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        self.assertEqual(self.repair()[0]['state'], 'publication-disabled')
        self.git('config', 'tron.verify.revertRemote', 'origin')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'review-required')
        self.assertEqual(self.review(repair).returncode, 0)
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1)

    def test_owner_killed_mid_repair_resumes_to_one_reviewed_revert(self):
        self.remote()
        culprit = self.land('bad', 'yes')
        self.push()
        self.env['FIXTURE_AFFECTED'] = 'kill-owner'
        killed = self.run_batch('--base', self.base)
        self.assertEqual(killed.returncode, -9, killed.stdout + killed.stderr)
        self.assertEqual(self.repair()[0]['state'], 'building')
        del self.env['FIXTURE_AFFECTED']
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'review-required')
        self.assertEqual(self.review(repair).returncode, 0)
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1)

    def test_failing_affected_checks_on_the_candidate_refuse(self):
        self.remote()
        self.land('bad', 'yes')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        self.env['FIXTURE_AFFECTED'] = 'red'
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual((repair['state'], repair['affected']['verdict']), ('refused', 'failed'))
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)

    def test_inverse_that_leaves_the_failure_refuses(self):
        self.remote()
        culprit = self.land('bad', 'yes')
        self.land('also-bad', 'yes')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual((repair['culprit'], repair['state']), (culprit, 'refused'))
        self.assertIn('did not remove the failure', repair['reason'])
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)

    def test_unreadable_remote_stays_pending_then_resumes(self):
        self.remote()
        culprit = self.land('bad', 'yes')
        self.push()
        hidden = self.origin.with_name('hidden.git')
        self.origin.rename(hidden)
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        self.assertEqual(self.repair()[0]['state'], 'pending')
        hidden.rename(self.origin)
        self.assertEqual(self.run_batch('--base', self.base).returncode, 1)
        [repair] = self.repair()
        self.assertEqual(repair['state'], 'review-required')
        self.assertEqual(self.review(repair).returncode, 0)
        self.assertEqual(len(self.reverts_on_remote(culprit)), 1)

    def test_first_failure_is_frozen_and_later_mutation_refuses_publication(self):
        culprit, tip, repair = self.red_with_review()
        report = self.reports()[-1]
        manifest = Path(report['evidence'])
        directory = manifest.parent
        first = json.loads((directory / 'first-report.json').read_text())
        self.assertEqual(first['verdict'], 'running')
        self.assertEqual(len(first['results']), 9)
        self.assertFalse(first['failures'], 'frozen before any probe or attribution')
        files = json.loads(manifest.read_text())['files']
        self.assertIn('first-report.json', files)
        self.assertFalse([name for name in files if name.startswith('attribution-')])
        log = next(name for name in files if name.endswith('output.log'))
        (directory / log).write_text('rewritten')
        refused = self.review(repair)
        self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
        self.assertIn('evidence changed', self.repair()[0]['reason'])
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)

    def test_suite_level_error_is_uncovered_without_attribution(self):
        self.remote()
        self.land('unhandled', 'yes')
        self.land('bad', 'yes')
        self.push()
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'uncovered')
        self.assertFalse(report['results'][1]['failureComplete'])
        self.assertEqual(report['failures'][0]['attribution']['status'], 'unresolved')
        self.assertFalse(self.repair())

    def assert_never_publishes(self, marker):
        self.remote()
        self.land(marker, 'yes')
        self.land('bad', 'yes')
        self.push()
        tip = self.git('rev-parse', 'HEAD')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotEqual(self.reports()[-1]['verdict'], 'green')
        self.assertFalse((self.root / '.git/verify/green.json').exists())
        self.assertFalse([r for r in self.repair() if r['state'] != 'refused'])
        self.assertEqual(self.remote_git('rev-parse', 'main'), tip)
        return self.reports()[-1]

    def test_mixed_controls_never_publish(self):
        proof = self.assert_never_publishes('unstable-repeat')['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'unresolved')

    def test_skipped_required_coverage_is_not_green_and_never_publishes(self):
        self.assertEqual(self.assert_never_publishes('skipped')['verdict'], 'uncovered')


class AppleLaneTests(unittest.TestCase):
    """#2268: every batch runs from a fresh worktree, so the Apple chain's simulator lanes are the
    repository's, not the worktree's: one warm set per repository, owned by it."""

    def setUp(self):
        import sys
        sys.path.insert(0, str(ROOT / 'tools/verify'))
        import batch
        self.batch = batch
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-apple-lane-')
        self.addCleanup(self.temporary.cleanup)

    def repository(self, name):
        root = Path(self.temporary.name).resolve() / name
        git = ['git', '-C', str(root), '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null']
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        subprocess.run([*git, 'commit', '-q', '--allow-empty', '-m', 'root'], check=True)
        return root, git

    def apple_environments(self, root):
        return {lane['name']: lane['env'] for lane in self.batch.lanes(root, 'HEAD') if lane.get('chain') == 'apple' and lane.get('env')}

    def test_batch_worktrees_of_one_repository_share_its_owned_apple_lane(self):
        primary, git = self.repository('primary')
        worktrees = [Path(self.temporary.name).resolve() / f'batch-{index}' for index in (1, 2)]
        for worktree in worktrees:
            subprocess.run([*git, 'worktree', 'add', '-q', '--detach', str(worktree)], check=True)
        other, _ = self.repository('other')
        common = os.path.realpath(primary / '.git')
        environments = [self.apple_environments(root) for root in (primary, *worktrees)]
        self.assertEqual(sorted(environments[0]), ['iOS smoke', 'real Gateway UI journeys', 'real Gateway boundary'])
        names = {env['TRON_IOS_TEST_LANE'] for environment in environments for env in environment.values()}
        self.assertEqual(len(names), 1, names)
        self.assertTrue(all(env['TRON_IOS_TEST_LANE_REPOSITORY'] == common
                            for environment in environments for env in environment.values()), environments)
        # Smoke products stay each worktree's own: products prune follows their worktree.
        smoke = {environment['iOS smoke']['TRON_IOS_TEST_DERIVED_DATA'] for environment in environments}
        self.assertEqual(len(smoke), 3, smoke)
        theirs = self.apple_environments(other)['real Gateway UI journeys']
        self.assertNotIn(theirs['TRON_IOS_TEST_LANE'], names)
        self.assertEqual(theirs['TRON_IOS_TEST_LANE_REPOSITORY'], os.path.realpath(other / '.git'))


class ShardedIosProbeTests(unittest.TestCase):
    """#2173: verify names a sharded iOS step `tests: ios k/N`; its bisect probe is still the iOS
    group, so a passing shard probe counts its XCTest summary instead of reading as empty."""

    def test_a_sharded_ios_probe_reads_its_xctest_summary(self):
        import sys
        sys.path.insert(0, str(ROOT / 'tools/verify'))
        import batch
        with tempfile.TemporaryDirectory(prefix='tron-batch-probe-') as temporary:
            root = Path(temporary)
            stub = root / 'runner.py'
            stub.write_text('import json, pathlib, sys\n'
                            'out = pathlib.Path(sys.argv[1]); out.mkdir()\n'
                            '(out / "summary.json").write_text(json.dumps({"passedTests": 3}))\n'
                            'print("iOS test run complete: " + str(out))\n')
            lane = {'name': 'tests: ios 2/3', 'command': ['python3', str(stub), str(root / 'run')], 'cwd': '.', 'probe': True}
            result = batch.execute(root, lane, root / 'probe')
        self.assertEqual(result['exit'], 0, result)

    def test_only_an_exact_case_vitest_head_control_requires_a_selection(self):
        # A verifier-step recipe can select nothing for a real, reproducible reason (a file that
        # fails to load); only the exact-case Vitest recipe turns an empty head selection into an error.
        import sys
        sys.path.insert(0, str(ROOT / 'tools/verify'))
        import batch

        class Controls:
            def __init__(self):
                self.record, self.required = {}, []

            def controls(self, sha, expected, selection_required=False):
                self.required.append(selection_required)
                return False
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        base = subprocess.check_output(['git', 'rev-parse', 'HEAD~1'], cwd=ROOT, text=True).strip()
        for probe, required in (({'name': 'Gateway default', 'vitest': True, 'command': ['x']}, True),
                                ({'name': 'tests: gateway', 'command': ['x']}, False)):
            with self.subTest(probe=probe['name']):
                prober = Controls()
                batch.attribute(base, head, {'name': probe['name'], 'probe': probe, 'signature': {'x': 1}}, prober)
                self.assertEqual(prober.required, [required])

    def test_a_verifier_gateway_step_probe_records_how_many_tests_it_selected(self):
        # A full-verify Gateway step probe counts failed as well as passed cases as selected, so a
        # reproducing failure is never mistaken for an empty selection, and an empty one is visible.
        import sys
        sys.path.insert(0, str(ROOT / 'tools/verify'))
        import batch
        for passed, failed, selected in ((0, 1, 1), (0, 0, 0)):
            with self.subTest(passed=passed, failed=failed), tempfile.TemporaryDirectory(prefix='tron-batch-probe-') as temporary:
                root = Path(temporary)
                stub = root / 'vitest.py'
                stub.write_text('import json, pathlib, sys\n'
                                'out = pathlib.Path(sys.argv[1].split("=", 1)[1])\n'
                                f'out.write_text(json.dumps({{"numPassedTests": {passed}, "numFailedTests": {failed}, "testResults": []}}))\n'
                                f'sys.exit({failed})\n')
                lane = {'name': 'tests: gateway', 'command': ['python3', str(stub), f'--outputFile.json={root / "step-vitest.json"}'],
                        'cwd': '.', 'probe': True}
                result = batch.execute(root, lane, root / 'probe')
                self.assertEqual(result['selectedTests'], selected, result)


class BrowserForkProvisionTests(unittest.TestCase):
    """A Gateway run that selects the browser receipt test hands Vitest the pinned fork copy the
    runner provisioned, so a batch's Gateway lane covers both cases instead of skipping them."""

    PIN = 'd6cde09af8d7757bbfba5a4ffaf83381bb392683'
    ENGINE = '0.33.2'

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-browser-fork-')
        root = Path(self.temporary.name).resolve()
        self.seen = root / 'seen'
        (root / 'tools/verify').mkdir(parents=True)
        shipped_runner(root, root / 'full-gateway.lock')
        self.adapter = root / 'packages/gateway/src/display/browser-live-view-adapter.ts'
        self.adapter.parent.mkdir(parents=True)
        self.adapter.write_text(f'const sources = [\n  "git:github.com/fitchmultz/pi-agent-browser-native",\n  "git:github.com/fitchmultz/pi-agent-browser-native@{self.PIN}",\n];\n')
        (root / 'scripts').mkdir()
        (root / 'scripts/tron-node').write_text('#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
        vitest = root / 'packages/gateway/node_modules/.bin/vitest'
        vitest.parent.mkdir(parents=True)
        vitest.write_text(f'#!/bin/bash\necho "${{TRON_P99_17_BROWSER_FORK_COPY:-unset}}" >> {self.seen}\n')
        for script in (root / 'scripts/tron-node', vitest):
            script.chmod(0o755)
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        # An already provisioned copy of the pin: the runner reuses it without fetching.
        self.copy = root / '.git/verify/fixtures' / f'pi-agent-browser-native-{self.PIN}'
        self.copy.mkdir(parents=True)
        (self.copy / '.tron-provisioned').write_text(self.PIN)
        self.declare_engine(self.copy, self.ENGINE)
        # ...and the engine that fork declares, already provisioned beside it.
        self.engine = root / '.git/verify/fixtures' / f'agent-browser-{self.ENGINE}'
        (self.engine / 'bin').mkdir(parents=True)
        (self.engine / 'bin/agent-browser').write_text(f'#!/bin/sh\necho "agent-browser {self.ENGINE}"\n')
        (self.engine / 'bin/agent-browser').chmod(0o755)
        (self.engine / '.tron-provisioned').write_text(self.ENGINE)
        self.root = root

    @staticmethod
    def declare_engine(fork: Path, version: str) -> None:
        """The fork's own declaration of the one engine version it qualifies against."""
        (fork / 'scripts').mkdir(parents=True, exist_ok=True)
        (fork / 'scripts/agent-browser-target.mjs').write_text(
            'export const TARGET_AGENT_BROWSER_SOURCE = "scripts/agent-browser-target.mjs";\n'
            f'export const TARGET_AGENT_BROWSER_VERSION = "{version}";\n'
            'export const TARGET_AGENT_BROWSER_VERSION_LABEL = `agent-browser ${TARGET_AGENT_BROWSER_VERSION}`;\n')

    def tearDown(self):
        self.temporary.cleanup()

    def run_gateway(self, *args, env=None):
        inherited = {key: value for key, value in os.environ.items() if key not in ('TRON_P99_17_BROWSER_FORK_COPY', 'TRON_FULL_GATEWAY_LOCK_HELD')}
        return subprocess.run(['python3', str(self.root / 'tools/verify/gateway.py'), *args], env={**inherited, **(env or {})},
                              capture_output=True, text=True, timeout=60)

    def test_a_full_default_run_receives_the_provisioned_pinned_fork(self):
        done = self.run_gateway('--reporter=default', '--reporter=json', '--outputFile.json=/dev/null')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.seen.read_text().split(), [str(self.copy)])

    def test_a_run_naming_the_browser_test_receives_it_and_other_selections_do_not(self):
        selections = {
            ('src/e2e/sessions/browser-fork-receipts.integration.test.ts',): True,
            ('src/e2e/sessions/browser-fork-receipts.integration.test.ts:48',): True,
            (str(self.root / 'packages/gateway/src/e2e/sessions/browser-fork-receipts.integration.test.ts'),): True,
            ('src/admin/package-updates.lock.integration.test.ts',): False,
            ('--testTimeout', '5000', 'src/admin/package-updates.lock.integration.test.ts'): False,
            ('--config', 'vitest.nested.config.ts'): False,
            ('--config=vitest.mac-terminal.config.ts',): False,
        }
        for args in selections:
            done = self.run_gateway(*args)
            self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.seen.read_text().split(), [str(self.copy) if selected else 'unset' for selected in selections.values()])

    def fork_repository(self, build: str) -> str:
        """A local stand-in for the fork's repository: a lockfile with no dependencies and the given build script."""
        fork = self.root / 'fork'
        (fork / 'scripts').mkdir(parents=True)
        (fork / 'package.json').write_text(json.dumps({'name': 'pi-agent-browser-native', 'version': '0.4.1'}))
        (fork / 'package-lock.json').write_text(json.dumps({'name': 'pi-agent-browser-native', 'version': '0.4.1', 'lockfileVersion': 3,
                                                            'requires': True, 'packages': {'': {'name': 'pi-agent-browser-native', 'version': '0.4.1'}}}))
        (fork / 'scripts/build.mjs').write_text(build)
        self.declare_engine(fork, self.ENGINE)
        # A lifecycle script must never run: the lockfile install is --ignore-scripts.
        package = json.loads((fork / 'package.json').read_text())
        (fork / 'package.json').write_text(json.dumps({**package, 'scripts': {'postinstall': "node -e \"require('fs').writeFileSync('postinstall-ran','')\""}}))
        git = ['git', '-C', str(fork), '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null']
        subprocess.run(['git', 'init', '-q', str(fork)], check=True)
        subprocess.run([*git, 'add', '.'], check=True)
        subprocess.run([*git, 'commit', '-qm', 'fork'], check=True)
        subprocess.run([*git, 'config', 'uploadpack.allowAnySHA1InWant', 'true'], check=True)
        commit = subprocess.check_output([*git, 'rev-parse', 'HEAD'], text=True).strip()
        runner = self.root / 'tools/verify/gateway.py'
        source = runner.read_text()
        self.assertIn("'https://github.com/fitchmultz/pi-agent-browser-native.git'", source)
        runner.write_text(source.replace("'https://github.com/fitchmultz/pi-agent-browser-native.git'", repr(str(fork))))
        # Provisioning runs npm and the build under the repository's pinned Node.
        (self.root / 'scripts/tron-node').write_text(f'#!/bin/bash\nexec {ROOT / "scripts/tron-node"} "$@"\n')
        self.adapter.write_text(f'"git:github.com/fitchmultz/pi-agent-browser-native@{commit}"\n')
        return commit

    def test_an_unprovisioned_pin_is_fetched_by_sha_built_and_stamped_once(self):
        commit = self.fork_repository("import { mkdirSync, writeFileSync } from 'node:fs';\n"
                                      "mkdirSync('dist/extensions/agent-browser', { recursive: true });\n"
                                      "writeFileSync('dist/extensions/agent-browser/index.js', 'export default () => {};\\n');\n")
        fixtures = self.root / '.git/verify/fixtures'
        killed = fixtures / '.pi-agent-browser-native-killed'
        killed.mkdir()
        (killed / 'partial').write_text('')
        # A caller's GIT_DIR (a hook, say) must not redirect the fixture's own repository.
        decoy = self.root / 'decoy.git'
        subprocess.run(['git', 'init', '-q', '--bare', str(decoy)], check=True)
        node = subprocess.check_output([str(ROOT / 'scripts/tron-node')], text=True).strip()
        done = self.run_gateway(env={'GIT_DIR': str(decoy), 'TRON_NODE_BIN': node})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(list((decoy / 'objects/pack').iterdir()) + [path for path in (decoy / 'objects').iterdir() if path.name not in ('pack', 'info')], [],
                         'provisioning wrote into the caller\'s repository')
        target = fixtures / f'pi-agent-browser-native-{commit}'
        self.assertEqual(self.seen.read_text().split(), [str(target)])
        self.assertFalse(killed.exists(), 'a killed provisioner\'s staging survived')
        self.assertFalse((target / 'postinstall-ran').exists(), 'a lifecycle script ran')
        self.assertEqual((target / '.tron-provisioned').read_text(), commit)
        self.assertEqual(subprocess.check_output(['git', '-C', str(target), 'rev-parse', 'HEAD'], text=True).strip(), commit)
        self.assertTrue((target / 'dist/extensions/agent-browser/index.js').is_file())
        again = self.run_gateway()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn('provisioning', again.stderr)

    def test_a_failed_build_fails_the_run_and_leaves_no_copy_or_staging(self):
        commit = self.fork_repository("process.exit(3);\n")
        done = self.run_gateway()
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('scripts/build.mjs', done.stderr)
        self.assertFalse(self.seen.exists())
        fixtures = self.root / '.git/verify/fixtures'
        self.assertEqual(sorted(path.name for path in fixtures.iterdir() if path.name.startswith(('.pi-agent', 'pi-agent-browser-native-' + commit))), [])

    def test_an_ambiguous_product_pin_refuses_instead_of_choosing(self):
        self.adapter.write_text(self.adapter.read_text() + f'"git:github.com/fitchmultz/pi-agent-browser-native@{"0" * 40}"\n')
        done = self.run_gateway()
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('expected one pinned agent-browser fork', done.stderr)
        self.assertFalse(self.seen.exists())


    def record_engine(self):
        """Have the stand-in Vitest record which engine its PATH resolves, as the browser test's `which` does."""
        self.engine_seen = self.root / 'engine-seen'
        vitest = self.root / 'packages/gateway/node_modules/.bin/vitest'
        vitest.write_text(f'#!/bin/bash\n(command -v agent-browser || echo missing) >> {self.engine_seen}\n')

    def registry(self, reported: str):
        """A stand-in npm whose `pack` writes an engine tarball (every platform binary reporting
        `reported`), recording its arguments; a directory to put first on PATH."""
        stand_in = self.root / 'npm-bin'
        stand_in.mkdir()
        self.packed = self.root / 'packed'
        (stand_in / 'npm').write_text(f"""#!/usr/bin/env python3
import io, sys, tarfile
from pathlib import Path
args = sys.argv[1:]
with open({str(self.packed)!r}, 'a') as calls:
    calls.write(' '.join(args) + '\\n')
assert args[0] == 'pack', args
spec = next(word for word in args[1:] if word.startswith('agent-browser@'))
version = spec.split('@', 1)[1]
destination = Path(args[args.index('--pack-destination') + 1])
with tarfile.open(destination / f'agent-browser-{{version}}.tgz', 'w:gz') as archive:
    for key in ('darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64'):
        body = f'#!/bin/sh\\necho "agent-browser {reported}"\\n# {{key}}\\n'.encode()
        member = tarfile.TarInfo(f'package/bin/agent-browser-{{key}}')
        member.size = len(body)
        archive.addfile(member, io.BytesIO(body))
""")
        (stand_in / 'npm').chmod(0o755)
        return stand_in

    def decoy_path(self):
        """An inherited PATH whose first agent-browser is a host engine the run must not use."""
        decoy = self.root / 'host-bin'
        decoy.mkdir(exist_ok=True)
        (decoy / 'agent-browser').write_text('#!/bin/sh\necho "agent-browser 0.0.1"\n')
        (decoy / 'agent-browser').chmod(0o755)
        return f'{decoy}:{os.environ["PATH"]}'

    def test_the_run_resolves_the_engine_the_fork_declares_before_the_hosts(self):
        self.record_engine()
        done = self.run_gateway(env={'PATH': self.decoy_path()})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.engine_seen.read_text().split(), [str(self.engine / 'bin/agent-browser')])
        # A selection without the browser test keeps the inherited PATH.
        done = self.run_gateway('src/admin/package-updates.lock.integration.test.ts', env={'PATH': self.decoy_path()})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.engine_seen.read_text().split()[1], str(self.root / 'host-bin/agent-browser'))

    def test_a_new_declared_engine_is_packed_from_the_registry_verified_and_stamped_once(self):
        self.record_engine()
        self.declare_engine(self.copy, '0.40.0')
        path = f'{self.registry("0.40.0")}:{self.decoy_path()}'
        fixtures = self.root / '.git/verify/fixtures'
        killed = fixtures / '.agent-browser-killed'
        killed.mkdir()
        done = self.run_gateway(env={'PATH': path})
        self.assertEqual(done.returncode, 0, done.stderr)
        engine = fixtures / 'agent-browser-0.40.0'
        self.assertEqual(self.engine_seen.read_text().split(), [str(engine / 'bin/agent-browser')])
        self.assertEqual(subprocess.check_output([str(engine / 'bin/agent-browser'), '--version'], text=True).strip(), 'agent-browser 0.40.0')
        self.assertEqual((engine / '.tron-provisioned').read_text(), '0.40.0')
        # Only this host's platform binary is kept.
        host = {'Darwin': 'darwin', 'Linux': 'linux'}[platform.system()] + '-' + {'x86_64': 'x64', 'amd64': 'x64', 'aarch64': 'arm64'}.get(platform.machine().lower(), platform.machine().lower())
        self.assertTrue((engine / 'bin/agent-browser').read_text().endswith(f'# {host}\n'))
        self.assertFalse(killed.exists(), 'a killed provisioner\'s staging survived')
        self.assertEqual(len(self.packed.read_text().splitlines()), 1)
        self.assertIn('agent-browser@0.40.0', self.packed.read_text())
        self.assertIn('--ignore-scripts', self.packed.read_text())
        again = self.run_gateway(env={'PATH': path})
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotIn('provisioning', again.stderr)
        self.assertEqual(len(self.packed.read_text().splitlines()), 1)

    def test_an_engine_reporting_another_version_fails_the_run_and_leaves_no_copy(self):
        self.record_engine()
        self.declare_engine(self.copy, '0.40.0')
        done = self.run_gateway(env={'PATH': f'{self.registry("0.39.9")}:{self.decoy_path()}'})
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('reports agent-browser 0.39.9, not agent-browser 0.40.0', done.stderr)
        self.assertFalse(self.engine_seen.exists())
        fixtures = self.root / '.git/verify/fixtures'
        self.assertEqual(sorted(path.name for path in fixtures.iterdir() if path.name.startswith(('.agent-browser', 'agent-browser-0.40.0'))), [])

    def test_a_fork_without_one_declared_engine_refuses_instead_of_guessing(self):
        self.record_engine()
        (self.copy / 'scripts/agent-browser-target.mjs').unlink()
        done = self.run_gateway(env={'PATH': self.decoy_path()})
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('expected one TARGET_AGENT_BROWSER_VERSION', done.stderr)
        self.assertFalse(self.engine_seen.exists())


class FullGatewayLockTests(unittest.TestCase):
    """A Gateway Vitest run waits for the host's full-Gateway lock, so it never overlaps a
    batch; a batch lane, which already holds it, runs without waiting."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-gateway-lock-')
        root = Path(self.temporary.name)
        self.lock = root / 'full-gateway.lock'
        self.ran = root / 'ran'
        shipped_runner(root, self.lock)
        (root / 'scripts').mkdir()
        (root / 'scripts/tron-node').write_text('#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
        vitest = root / 'packages/gateway/node_modules/.bin/vitest'
        vitest.parent.mkdir(parents=True)
        vitest.write_text(f'#!/bin/bash\necho "$@" >> {self.ran}\n')
        for script in (root / 'scripts/tron-node', vitest):
            script.chmod(0o755)
        self.gateway = root / 'tools/verify/gateway.py'

    def tearDown(self):
        self.temporary.cleanup()

    def start(self, env=None, stderr=subprocess.PIPE):
        inherited = {key: value for key, value in os.environ.items() if key != 'TRON_FULL_GATEWAY_LOCK_HELD'}
        return subprocess.Popen(['python3', str(self.gateway), 'some.test.ts'], env={**inherited, **(env or {})},
                                stdout=subprocess.PIPE, stderr=stderr, text=True)

    def test_a_run_waits_for_the_held_lock_then_records_itself(self):
        import fcntl
        errors = Path(self.temporary.name) / 'stderr'
        with self.lock.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with errors.open('w') as sink:
                run = self.start(stderr=sink)
                # The run announces its wait only after its own non-blocking try on the held lock has failed.
                wait_until(lambda: 'waiting for ' in errors.read_text(), 'the run to announce that it waits')
                # It then keeps waiting for as long as the lock is held, not just at the announcement.
                held_until = time.monotonic() + 2
                while time.monotonic() < held_until:
                    self.assertIsNone(run.poll(), 'the run waits while another holder has the lock')
                    self.assertFalse(self.ran.exists(), 'Vitest does not start before the lock is free')
                    time.sleep(0.05)
        out, _ = run.communicate(timeout=30)
        err = errors.read_text()
        self.assertEqual(run.returncode, 0, out + err)
        self.assertIn('waiting for ' + str(self.lock), err)
        self.assertEqual(self.ran.read_text().split(), ['run', 'some.test.ts'])
        self.assertIn('"purpose": "gateway vitest some.test.ts"', self.lock.read_text())

    def test_a_batch_lane_that_holds_the_lock_runs_without_waiting(self):
        import fcntl
        with self.lock.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            run = self.start({'TRON_FULL_GATEWAY_LOCK_HELD': '1'})
            out, err = run.communicate(timeout=30)
        self.assertEqual(run.returncode, 0, out + err)
        self.assertTrue(self.ran.exists())


class FullGatewayLockQueueTests(unittest.TestCase):
    """Full-Gateway lock waiters take it in arrival order, and a dead waiter or holder never wedges the line."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-gateway-queue-')
        self.addCleanup(self.temporary.cleanup)
        self.runs = GatewayRuns(Path(self.temporary.name) / 'full-gateway.lock')
        self.addCleanup(self.runs.close)

    def test_runs_take_the_lock_in_arrival_order(self):
        self.runs.start('holder')
        self.runs.wait_holding('holder')
        for name in ('first', 'second', 'third'):
            self.runs.start(name)
            self.runs.wait_queued(name)
        self.runs.release('holder')
        self.runs.wait_all()
        self.assertEqual(self.runs.names(), ['holder', 'first', 'second', 'third'])

    def test_a_killed_waiter_and_a_killed_holder_lose_their_places(self):
        holder = self.runs.start('holder')
        self.runs.wait_holding('holder')
        doomed = self.runs.start('doomed')
        self.runs.wait_queued('doomed')
        doomed.kill()
        doomed.wait(timeout=30)
        self.runs.start('after')
        self.runs.wait_queued('after')
        holder.kill()
        holder.wait(timeout=30)
        self.runs.wait_all(['after'])
        self.assertEqual(self.runs.names(), ['holder', 'after'])
        # Nothing stale remains ahead of a newcomer: it takes the free lock without waiting.
        self.runs.start('fresh')
        self.runs.wait_all(['fresh'])
        self.assertNotIn('waiting for', self.runs.stderr('fresh'))
        self.assertEqual(self.runs.names(), ['holder', 'after', 'fresh'])



if __name__ == '__main__':
    unittest.main(verbosity=2)
