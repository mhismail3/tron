#!/usr/bin/env python3
"""Real Git/process fixture lanes for the shipped post-land batch owner."""
from datetime import datetime, timezone, timedelta
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'test-results/verify-batch'


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
        for file in ('batch.py', 'verify.py'):
            source = Path(os.environ.get('TRON_BATCH_UNDER_TEST', ROOT / 'tools/verify/batch.py')) if file == 'batch.py' else Path(os.environ.get('TRON_VERIFY_UNDER_TEST', ROOT / 'tools/verify' / file))
            self.write('tools/verify/' + file, source.read_text())
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
with Path('test-results/executed').open('a') as f: f.write('locks\\n')
import subprocess
sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
Path('test-results/verify').mkdir(exist_ok=True)
Path('test-results/verify',sha+'.json').write_text(json.dumps({'commit':sha,'verdict':Path('verifier-verdict').read_text().strip() if Path('verifier-verdict').exists() else 'passed','message':'locks passed','passingTests':1,'steps':[],'selection':{},'skipped':[]}))
''', True)
        self.write('tools/verify/gateway.py', '''import json,sys,time,subprocess
from pathlib import Path
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
failed=(root/'bad').exists() and not nested
if (root/'flake').exists() and '-t' in args: failed=False
if (root/'unstable-repeat').exists() and '-t' in args and failed:
    common=Path(subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip())
    sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    counter=common/('fixture-count-'+sha)
    count=int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count+1))
    if count: failed=False
if '-t' in args and args[args.index('-t')+1] != '^suite\\\\ case$':
    raise SystemExit('wrong exact case filter')
output=Path(next(a.split('=',1)[1] for a in args if a.startswith('--outputFile.json=')))
output.parent.mkdir(parents=True,exist_ok=True)
data={'numPassedTests':0 if failed else 1,'numFailedTests':1 if failed else 0,
      'testResults':[{'name':str(root/'packages/gateway/src/example.test.ts'),
       'status':'failed' if failed else 'passed','assertionResults':[
        {'fullName':'suite case','status':'failed' if failed else 'passed',
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
        self.write('tools/verify/known-failures.json', '[]')
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
        self.assertEqual(sum(p['commit'] == culprit and p['outcome'] == 'bad' for p in proof['probes']), 2)
        self.assertTrue(all(p['outcome'] == 'good' for p in proof['probes'] if p['commit'] == proof['parent']))
        self.assertTrue(all('-t' in p['command'] for p in proof['probes']))
        self.assertEqual(self.git('show', proof['revertBranch'] + ':good'), 'yes')
        self.assertNotIn('bad', self.git('ls-tree', '--name-only', proof['revertBranch']))
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

    def test_nonlanding_history_yields_candidates_not_culprits(self):
        self.write('bad', 'yes')
        self.commit('direct commit is not a landing')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertTrue(report['nonLandingCommits'])
        self.assertEqual(report['failures'][0]['attribution']['status'], 'inconclusive')
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def register(self, expires=None, digest=None):
        # The registry validator owns duration/renewals; test entries use its real contract.
        import hashlib
        self.write('tools/verify/known-failures.json', json.dumps([{
            'testId': 'packages/gateway/src/example.test.ts::suite case', 'issue': 100,
            'expires': expires or (datetime.now(timezone.utc).date() + timedelta(days=3)).isoformat(), 'evidence': {'commit': self.git('rev-parse', 'HEAD'),
                'command': 'scripts/tron test gateway src/example.test.ts -t "suite case"',
                'failureDigest': digest or hashlib.sha256(json.dumps(['AssertionError: stable failure'], ensure_ascii=False).encode()).hexdigest()}}]))
        self.commit('register observed case')

    def test_qualified_advances_covered_not_green_and_digest_expiry_are_red(self):
        initial = self.run_batch('--base', self.base)
        self.assertEqual(initial.returncode, 0, initial.stdout + initial.stderr)
        green = (self.root / '.git/verify/green.json').read_bytes()
        self.register()
        self.land('bad', 'yes')
        result = self.run_batch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'qualified')
        self.assertEqual((self.root / '.git/verify/green.json').read_bytes(), green)
        self.assertEqual(json.loads((self.root / '.git/verify/covered.json').read_text())['commit'], self.git('rev-parse', 'HEAD'))
        self.assertFalse(self.reports()[-1]['failures'])

    def test_changed_registry_digest_is_red(self):
        self.register(digest='0' * 64)
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'red')

    def test_registered_failure_plus_skipped_case_remains_uncovered(self):
        self.register()
        self.land('skipped', 'yes')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'uncovered')
        self.assertEqual(report['results'][1]['status'], 'uncovered')
        self.assertFalse((self.root / '.git/verify/covered.json').exists())

    def test_expired_registry_entry_does_not_qualify(self):
        self.register(expires=(datetime.now(timezone.utc).date() - timedelta(days=1)).isoformat())
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.reports()[-1]['verdict'], 'red')

    def test_verifier_nonpass_verdicts_override_zero_exit(self):
        for verdict, expected in [('deferred', 'uncovered'), ('expired', 'red'), ('quarantined', 'qualified')]:
            with self.subTest(verdict=verdict):
                self.land('verifier-verdict', verdict)
                result = self.run_batch('--base', self.base)
                self.assertEqual(result.returncode, 0 if expected == 'qualified' else 1, result.stdout + result.stderr)
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
        self.assertEqual(proof['status'], 'inconclusive')
        self.assertEqual(proof['probes'][-1]['outcome'], 'unknown')
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def test_flake_retains_attempts_but_needs_registry_for_qualification(self):
        self.land('flake', 'yes')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = self.reports()[-1]
        self.assertEqual(report['verdict'], 'red')
        self.assertEqual(report['failures'][0]['attribution']['status'], 'flake observed; registry entry required')
        self.assertEqual(len(report['failures'][0]['attribution']['probes']), 2)

    def test_empty_case_probe_is_unknown_not_good_parent_evidence(self):
        self.land('empty-probe', 'yes')
        self.base = self.git('rev-parse', 'HEAD')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'inconclusive')
        self.assertEqual(proof['probes'][0]['outcome'], 'unknown')
        self.assertFalse(self.git('for-each-ref', 'refs/heads/revert/'))

    def test_second_culprit_reproduction_is_required(self):
        self.land('unstable-repeat', 'yes')
        self.land('bad', 'yes')
        result = self.run_batch('--base', self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        proof = self.reports()[-1]['failures'][0]['attribution']
        self.assertEqual(proof['status'], 'inconclusive')
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
