#!/usr/bin/env python3
"""tools/verify/mini.py end to end, with both halves real and the network hop replaced.

A disposable checkout holds the real mini.py, scripts/tron-node, Node pin and toolchain pins, plus a
stand-in tools/verify/gateway.py lane. A disposable "mini" home holds a bare tron.git and the pinned
Node (linked where nvm keeps it). An `ssh` first on PATH drops its options and runs the remote
command in that home, the way sshd would run it in the mini user's home: git's own push and
mini.py's session both go through it. The cases check that a lane runs at the exact commit and its
report and exit code come back with the mini checkout path rewritten; that a dirty tree, an
unreachable host, an off-pin toolchain, a HEAD other than verify's commit and a job lock held past the caller's
cap fail with the no-result exit and reason and no result, while a lane's own exit 75 stays its result; that stopping a lane
waiting for the job lock ends it before it starts; that a push whose job never started leaves no ref once the next job ends; and that stopping the local runner, or killing its
whole process group, stops the mini lane and releases the mini job lock. The pool (#2336) runs on the mini when
reachable, set up and idle, and otherwise here with its reason (including an argument naming a path outside
the checkout and a probe with no or malformed status); a stopped local pool lane is stopped itself.
"""
from __future__ import annotations

import fcntl
import hashlib
import importlib.util
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
NO_RESULT = 75
SSH = r'''#!/bin/bash
while (($#)); do
  case "$1" in
    -G) exit 0 ;;
    -o|-i|-p|-l|-F) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
destination="$1"; shift
[[ "$destination" != unreachable* ]] || { echo "ssh: connect to host $destination port 22: Connection refused" >&2; exit 255; }
[[ "$destination" != silent* ]] || exit 0
[[ "$destination" != garbled* ]] || { echo 'mini status: not json'; exit 0; }
[[ "$destination" != nojob* || "$*" != *" remote "* ]] || { echo "ssh: connection to $destination closed" >&2; exit 255; }
if [[ -n "${MINI_RETAINED_FAULT:-}" && ! -e "$MINI_HOME/$MINI_RETAINED_FAULT.once" ]]; then
  if [[ "$MINI_RETAINED_FAULT" == transfer && "$*" == *" remote-retained "* ]]; then
    touch "$MINI_HOME/$MINI_RETAINED_FAULT.once"
    (cd "$MINI_HOME" && HOME="$MINI_HOME" /bin/sh -c "$*") > "$MINI_HOME/retained-transfer.tar.gz"
    head -c 64 "$MINI_HOME/retained-transfer.tar.gz"
    exit 255
  fi
  if [[ "$MINI_RETAINED_FAULT" == ack-* && "$*" == *" ack-retained "* ]]; then
    touch "$MINI_HOME/$MINI_RETAINED_FAULT.once"
    [[ "$MINI_RETAINED_FAULT" != ack-after ]] || (cd "$MINI_HOME" && HOME="$MINI_HOME" /bin/sh -c "$*")
    exit 255
  fi
fi
# sshd runs the command in its own session: killing this client's process group leaves it running, with its
# input closed once no client holds the pipe.
cd "$MINI_HOME" && HOME="$MINI_HOME" exec /usr/bin/python3 -c 'import os, sys; os.setsid(); os.execv("/bin/sh", ["sh", "-c", sys.argv[1]])' "$*"
'''
LANE = r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
args = sys.argv[1:]
print('stand-in lane progress', flush=True)
if 'hang' in args:
    marker = Path(os.environ['HOME']) / 'lane'
    signal.signal(signal.SIGTERM, lambda *_: (marker.with_name('lane-terminated').write_text('SIGTERM'), sys.exit(143)))
    marker.with_name('lane-started').write_text('started')
    time.sleep(120)
output = next(word.split('=', 1)[1] for word in args if word.startswith('--outputFile.json='))
Path(output).write_text(json.dumps({'testResults': [{'name': str(ROOT / 'packages/gateway/src/a.test.ts')}], 'args': args,
                                    'path': os.environ['PATH'], 'cwd': str(Path.cwd().relative_to(Path(os.environ['HOME']).resolve())),
                                    'sha': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()}))
sys.exit(3 if 'fail' in args else 0)
'''

PROBE = r'''import os, sys
from pathlib import Path
print('stand-in python progress', flush=True)
print('Ran 1 test in 0.001s', file=sys.stderr, flush=True)
print(Path.cwd().relative_to(Path(os.environ['HOME']).resolve()), flush=True)
sys.exit(int(sys.argv[1]) if sys.argv[1:] else 0)
'''


RECORDED = '''import sys, unittest
class Probe(unittest.TestCase):
    def test_case(self):
        self.assertNotIn('fail', sys.argv[1:])
unittest.main(argv=[sys.argv[0]])
'''


class MiniGatewayLane(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix='tron-mini-test-'))
        self.addCleanup(shutil.rmtree, self.temporary, True)
        self.local, self.mini = self.temporary / 'local', self.temporary / 'mini-home'
        for path in ('tools/verify/mini.py', 'tools/verify/ledger.py', 'tools/verify/ledger-node.mjs', 'tools/verify/ledger-host.mjs', 'scripts/tron-node', '.node-version', 'config/ci-toolchain.env'):
            (self.local / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, self.local / path)
        self.write('tools/verify/gateway.py', LANE)
        (self.local / 'tools/verify/gateway.py').chmod(0o755)
        self.write('packages/gateway/package.json', json.dumps({'name': 'fixture', 'version': '1.0.0', 'private': True}))
        self.write('packages/gateway/package-lock.json', json.dumps({'name': 'fixture', 'version': '1.0.0', 'lockfileVersion': 3, 'requires': True,
                                                                     'packages': {'': {'name': 'fixture', 'version': '1.0.0'}}}))
        self.write('packages/gateway/.npmrc', 'audit=false\nfund=false\noffline=true\n')
        self.write('packages/gateway/third_party/README', 'vendored tarballs\n')
        self.write('.gitignore', 'test-results/\nnode_modules/\n')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'tron.verify.mini', 'mini.test')
        self.commit('fixture')
        bin_dir = self.temporary / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'ssh').write_text(SSH)
        (bin_dir / 'ssh').chmod(0o755)
        subprocess.run(['git', 'init', '-q', '--bare', str(self.mini / 'tron-ci/tron.git')], check=True)
        node = Path(subprocess.check_output([str(ROOT / 'scripts/tron-node')], text=True).strip())
        version = (ROOT / '.node-version').read_text().strip()
        (self.mini / '.nvm/versions/node').mkdir(parents=True)
        (self.mini / f'.nvm/versions/node/v{version}').symlink_to(node.parent.parent)
        self.env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'MINI_HOME': str(self.mini),
                    'TRON_TEST_LEDGER': str(self.temporary / 'local-ledger.sqlite3')}
        self.env.pop('TRON_UPDATE_LOCKS', None)

    def write(self, path: str, text: str) -> None:
        (self.local / path).parent.mkdir(parents=True, exist_ok=True)
        (self.local / path).write_text(text)

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', *args], cwd=cwd or self.local,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message: str) -> str:
        self.git('add', '-A')
        self.git('commit', '-qm', message)
        return self.git('rev-parse', 'HEAD')

    def lane(self, *args: str, **options) -> subprocess.Popen | subprocess.CompletedProcess:
        command = ['python3', str(self.local / 'tools/verify/mini.py'), *args]
        if options.get('background'):
            return subprocess.Popen(command, cwd=self.local / 'packages/gateway', env=self.env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return subprocess.run(command, cwd=self.local / 'packages/gateway', env=options.get('env', self.env), text=True, capture_output=True, timeout=300)

    def reader(self):
        """The shipped mini.py, imported, for the reader verify and the batch classify a lane with."""
        spec = importlib.util.spec_from_file_location('mini_under_test', self.local / 'tools/verify/mini.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def report_args(self) -> tuple[Path, list[str]]:
        report = self.local / 'test-results/lane.json'
        return report, ['--reporter=json', f'--outputFile.json={report}', 'src/a.test.ts']

    def test_a_lane_runs_at_the_exact_commit_and_returns_its_report_and_exit_code(self) -> None:
        report, args = self.report_args()
        sha = self.git('rev-parse', 'HEAD')
        passed = self.lane(*args)
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        self.assertIn('stand-in lane progress', passed.stdout)
        self.assertIn('npm ci', passed.stdout)
        checkout = (self.mini / 'tron-ci/jobs/gateway').resolve()
        returned = json.loads(report.read_text())
        self.assertEqual(returned['testResults'][0]['name'], str(self.local.resolve() / 'packages/gateway/src/a.test.ts'))
        self.assertEqual(returned['cwd'], 'tron-ci/jobs/gateway/packages/gateway', 'the lane ran in the mini checkout')
        self.assertIn('src/a.test.ts', returned['args'])
        self.assertEqual(returned['path'].split(':')[0], '/usr/bin', 'the lane runs with the mini clean PATH, not the caller one')
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=checkout), sha)
        repository = self.mini / 'tron-ci/tron.git'
        self.assertEqual(self.git('for-each-ref', '--format=%(refname) %(objectname)', cwd=repository), f'refs/tron-jobs/gateway {sha}')
        self.assertEqual(list((self.mini / 'tron-ci/results').iterdir()), [], 'the run output on the mini is removed')

        self.write('README', 'next commit\n')
        self.commit('next')
        report.unlink()
        failed = subprocess.run(['python3', str(self.local / 'tools/verify/mini.py'), '--reporter=json',
                                 '--outputFile.json=../../test-results/lane.json', 'src/a.test.ts', 'fail'],
                                cwd=self.local, env=self.env, text=True, capture_output=True, timeout=300)
        self.assertEqual(failed.returncode, 3, failed.stdout + failed.stderr)
        self.assertTrue(report.is_file(), 'a red lane still returns its report')
        self.assertNotIn('npm ci', failed.stdout, 'unchanged Gateway dependency inputs are not reinstalled')

        report.unlink()
        moved = subprocess.run(['python3', str(self.local / 'tools/verify/mini.py'), *args], cwd=self.local, text=True,
                               capture_output=True, timeout=300, env={**self.env, 'TRON_VERIFY_COMMIT': sha})
        self.assertEqual(moved.returncode, NO_RESULT, moved.stdout + moved.stderr)
        self.assertIn('not the commit under verification', moved.stderr)
        self.assertFalse(report.exists(), 'a HEAD that moved since verify named its commit gets no result')

        self.write('README', 'uncommitted\n')
        dirty = self.lane(*args)
        self.assertEqual(dirty.returncode, NO_RESULT, dirty.stdout + dirty.stderr)
        self.assertIn('uncommitted', dirty.stderr)
        self.assertNotIn('pushing', dirty.stdout)
        self.assertFalse(report.exists())

    def test_concurrent_transfers_run_each_exact_commit_without_shared_ref_races(self) -> None:
        repository = self.mini / 'tron-ci/tron.git'
        hook = repository / 'hooks/pre-receive'
        hook.write_text('''#!/usr/bin/python3
import os, time
from pathlib import Path
barrier = Path(os.environ['MINI_HOME']) / 'transfers'
barrier.mkdir(exist_ok=True)
(barrier / str(os.getpid())).touch()
deadline = time.monotonic() + 20
while len(list(barrier.iterdir())) < 2:
    if time.monotonic() >= deadline:
        raise SystemExit('the second transfer never reached receive-pack')
    time.sleep(0.02)
''')
        hook.chmod(0o755)
        other = self.temporary / 'other'
        self.git('clone', '--quiet', str(self.local), str(other))
        self.git('config', 'tron.verify.mini', 'mini.test', cwd=other)
        (other / 'README').write_text('distinct source\n')
        self.git('add', 'README', cwd=other)
        self.git('commit', '-qm', 'distinct source', cwd=other)
        processes = []
        for checkout in (self.local, other):
            command = ['python3', str(checkout / 'tools/verify/mini.py'), '--reporter=json',
                       '--outputFile.json=' + str(checkout / 'test-results/concurrent.json'), 'src/a.test.ts']
            process = subprocess.Popen(command, cwd=checkout, env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.addCleanup(lambda process=process: process.poll() is None and process.kill())
            processes.append((checkout, process))
        results = [(checkout, process, process.communicate(timeout=90)[0]) for checkout, process in processes]
        for checkout, process, output in results:
            with self.subTest(checkout=checkout.name):
                self.assertEqual(process.returncode, 0, output)
                data = json.loads((checkout / 'test-results/concurrent.json').read_text())
                self.assertEqual(data['sha'], self.git('rev-parse', 'HEAD', cwd=checkout))
        refs = self.git('for-each-ref', '--format=%(refname)', cwd=repository).splitlines()
        self.assertEqual(refs, ['refs/tron-jobs/gateway'])

    def test_ios_lane_returns_native_artifacts_and_failure_through_the_normal_lease(self) -> None:
        self.write('tools/probe.py', RECORDED)
        self.write('scripts/tron-ios-test', '''#!/usr/bin/python3
import json, os, subprocess, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'tools/verify/ledger.py'), 'python', str(root / 'tools/probe.py'), *sys.argv[1:]])
results = Path(os.environ['TRON_IOS_TEST_RESULTS_DIR'])
results.mkdir(parents=True)
(results / 'TestResults.xcresult').mkdir()
(results / 'TestResults.xcresult/Info.plist').write_text('native result fixture')
if 'unsafe' in sys.argv:
    (results / 'outside').symlink_to(root / 'README')
(results / 'test.log').write_text('failure: fixture/native: deliberate red' if 'fail' in sys.argv else 'Executed 1 test, with 0 failures')
(results / 'source.json').write_text(json.dumps({'sha': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(), 'args': sys.argv[1:], 'home': os.environ['HOME']}))
print('Executed 1 test, with ' + ('1 failure' if 'fail' in sys.argv else '0 failures'), flush=True)
raise SystemExit(9 if 'fail' in sys.argv else 0)
''')
        (self.local / 'scripts/tron-ios-test').chmod(0o755)
        shutil.copy2(ROOT / 'scripts/tron', self.local / 'scripts/tron')
        sha = self.commit('native result fixture')
        repository = self.mini / 'tron-ci/tron.git'
        foreign = self.git('rev-parse', 'HEAD^')
        self.git('push', '--quiet', str(repository), f'{foreign}:refs/tron-jobs/incoming')
        for flag, expected in (('pass', 0), ('fail', 9), ('unsafe', NO_RESULT)):
            with self.subTest(outcome=flag):
                result = subprocess.run([str(self.local / 'scripts/tron'), 'test', 'ios', 'run', flag, '--ios-host', 'mini'],
                                        cwd=self.local, env=self.env, text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                paths = [line.removeprefix('mini: artifacts: ') for line in result.stdout.splitlines() if line.startswith('mini: artifacts: ')]
                if flag == 'unsafe':
                    self.assertEqual(paths, [])
                    self.assertIsNotNone(self.reader().no_result_reason(result.returncode, result.stdout + result.stderr))
                    self.assertIn('unsafe mini artifact source', result.stdout + result.stderr)
                    self.assertNotIn('cleanup unresolved', result.stderr)
                    continue
                self.assertEqual(len(paths), 1, result.stdout + result.stderr)
                artifacts = Path(paths[0])
                self.assertFalse((artifacts / 'ledger.sqlite3').exists())
                source = json.loads((artifacts / 'ios/source.json').read_text())
                self.assertEqual(source['sha'], sha)
                self.assertEqual(source['args'], ['run', flag])
                self.assertEqual(Path(source['home']).resolve(), self.mini.resolve())
                self.assertEqual((artifacts / 'ios/TestResults.xcresult/Info.plist').read_text(), 'native result fixture')
                self.assertEqual(json.loads((artifacts / 'receipt.json').read_text())['exit'], expected)
                if expected:
                    self.assertIn('deliberate red', (artifacts / 'ios/test.log').read_text())
        self.assertTrue(Path(self.env['TRON_TEST_LEDGER']).is_file(), 'native records return to the caller, not a second mini ledger')
        with sqlite3.connect(self.env['TRON_TEST_LEDGER']) as connection:
            rows = connection.execute('SELECT test_id, commit_sha, outcome, host, contended FROM results').fetchall()
        self.assertEqual(len(rows), 3, 'one record per completed probe, including a transport refusal without an invented failure')
        self.assertEqual([row[2] for row in rows], ['passed', 'failed', 'passed'])
        self.assertTrue(all(row[0] == 'tools/probe.py::Probe.test_case' and row[1] == sha and row[3] and row[4] == 0 for row in rows))
        with open(self.mini / 'tron-ci/jobs/gateway.lock') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.git('rev-parse', 'refs/tron-jobs/incoming', cwd=repository), foreign)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)', 'refs/tron-jobs/submissions/', cwd=repository), '')
        self.assertEqual(list((self.mini / 'tron-ci/results').iterdir()), [])

    def test_interrupted_native_evidence_survives_cleanup_and_is_retrieved_before_removal(self) -> None:
        self.write('scripts/tron-ios-test', '''#!/usr/bin/env python3
import json, os, signal, time
from pathlib import Path
if 'probe' in __import__('sys').argv:
    raise SystemExit(0)
root = Path(os.environ['TRON_IOS_TEST_RESULTS_DIR']) / 'partial-run'
root.mkdir(parents=True)
(root / 'large.log').write_bytes(b'first' + b'x' * (5 * 1024 ** 2) + b'last')
(root / 'process.json').write_text(json.dumps({'started': time.time()}))
(root / 'test.log').write_text("Test Case '-[TronMobileUITests.Probe testOne]' passed (0.25 seconds).\\n")
def stop(*_):
    (root / 'stages.json').write_text(json.dumps({'interrupted': True}))
    raise SystemExit(130)
signal.signal(signal.SIGTERM, stop)
(Path.home() / 'native-started').touch()
while True:
    time.sleep(0.05)
''')
        (self.local / 'scripts/tron-ios-test').chmod(0o755)
        sha = self.commit('interruptible native boundary fixture')
        runner = self.lane('ios', 'run', background=True)
        try:
            deadline = time.monotonic() + 30
            while not (self.mini / 'native-started').exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            runner.send_signal(signal.SIGTERM)
            output, _ = runner.communicate(timeout=30)
        finally:
            if runner.poll() is None:
                runner.kill()
                runner.wait()
        self.assertEqual(runner.returncode, 143, output)
        retained = list((self.mini / 'tron-ci/retained-native').iterdir())
        self.assertEqual(len(retained), 1, output)
        receipt = json.loads((retained[0] / 'retention.json').read_text())
        self.assertEqual(receipt['commit'], sha)
        self.assertTrue(receipt['interrupted'])
        self.assertIn('passed (0.25 seconds)', (retained[0] / 'ios/partial-run/test.log').read_text())
        self.assertTrue((retained[0] / 'ios/partial-run/process.json').is_file())
        self.assertTrue((retained[0] / 'ios/partial-run/stages.json').is_file())
        large = next(entry for entry in receipt['files'] if entry['path'].endswith('large.log'))
        self.assertEqual(large['retained'], 4 * 1024 ** 2)
        self.assertGreater(large['bytes'], large['retained'])
        self.assertTrue((retained[0] / large['path']).read_bytes().startswith(b'first'))
        self.assertTrue((retained[0] / large['path']).read_bytes().endswith(b'last'))
        partial = json.loads((retained[0] / 'partial-timings.json').read_text())
        self.assertFalse(partial['completeShard'])
        self.assertEqual(partial['cases'][0]['testId'], 'TronMobileUITests/Probe/testOne')
        with open(self.mini / 'tron-ci/jobs/gateway.lock') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        retrieved = self.lane('retrieve', retained[0].name)
        self.assertEqual(retrieved.returncode, 0, retrieved.stdout + retrieved.stderr)
        self.assertFalse(retained[0].exists())
        returned = self.local / 'test-results/mini' / f'retained-{receipt["nonce"]}'
        self.assertEqual(json.loads((returned / 'receipt.json').read_text())['exit'], 130)
        self.assertEqual(list((self.mini / 'tron-ci/results').iterdir()), [])
        pending = self.mini / 'tron-ci/retained-native'
        for index in range(8):
            (pending / str(index)).mkdir()
        full = self.lane('ios', 'probe')
        self.assertEqual(full.returncode, NO_RESULT, full.stdout + full.stderr)
        self.assertIn('evidence retention is full', full.stdout + full.stderr)
        self.assertEqual(len(list(pending.iterdir())), 8)

    def test_native_recovery_retries_construction_transfer_verification_and_acknowledgement(self) -> None:
        nonce = 'a' * 32
        originals = self.mini / 'tron-ci/results' / f'gateway-{nonce}'
        originals.mkdir(parents=True)
        content = b'first native evidence\n' + b'x' * 16384
        (originals / 'test.log').write_bytes(content)
        receipt = {'nonce': nonce, 'commit': self.git('rev-parse', 'HEAD'), 'interrupted': True}
        (originals / 'receipt.json').write_text(json.dumps(receipt))
        retained = self.mini / 'tron-ci/retained-native' / nonce
        constructor = '''import importlib.util, resource, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mini', sys.argv[1])
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
resource.setrlimit(resource.RLIMIT_FSIZE, (2048, 2048))
module.retain_native(Path(sys.argv[2]), Path(sys.argv[3]), {'nonce': sys.argv[4]})
'''
        failed = subprocess.run(['python3', '-c', constructor, str(self.local / 'tools/verify/mini.py'),
                                 str(originals), str(retained), nonce], env={**self.env, 'PYTHONDONTWRITEBYTECODE': '1'},
                                capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual((originals / 'test.log').read_bytes(), content)
        self.assertFalse(retained.exists(), 'incomplete construction must not publish a pending snapshot')
        self.assertTrue(retained.with_name(f'.{nonce}.building').is_dir())
        recovered = self.lane('recover', nonce)
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assertFalse(originals.exists())
        self.assertEqual((retained / 'test.log').read_bytes(), content)
        self.assertFalse(retained.with_name(f'.{nonce}.building').exists())
        self.env['MINI_RETAINED_FAULT'] = 'transfer'
        interrupted = self.lane('retrieve', nonce)
        self.assertNotEqual(interrupted.returncode, 0)
        target = self.local / 'test-results/mini' / f'retained-{nonce}'
        self.assertFalse(target.exists())
        self.assertTrue(retained.exists())
        self.env.pop('MINI_RETAINED_FAULT')
        (retained / 'test.log').write_bytes(b'corrupted in transfer fixture')
        corrupt = self.lane('retrieve', nonce)
        self.assertNotEqual(corrupt.returncode, 0)
        self.assertIn('digest mismatch', corrupt.stdout + corrupt.stderr)
        self.assertFalse(target.exists(), 'unverified files must not occupy the published destination')
        (retained / 'test.log').write_bytes(content)
        for fault in ('ack-before', 'ack-after'):
            self.env['MINI_RETAINED_FAULT'] = fault
            unconfirmed = self.lane('retrieve', nonce)
            self.assertNotEqual(unconfirmed.returncode, 0)
            self.assertTrue(target.is_dir(), unconfirmed.stdout + unconfirmed.stderr)
            self.assertEqual((target / 'test.log').read_bytes(), content)
            self.assertEqual(retained.exists(), fault == 'ack-before')
        self.env.pop('MINI_RETAINED_FAULT')
        retried = self.lane('retrieve', nonce)
        self.assertEqual(retried.returncode, 0, retried.stdout + retried.stderr)
        self.assertFalse(retained.exists())
        self.assertFalse(target.with_suffix('.tar.gz').exists())
        self.assertFalse(target.with_name(f'.{target.name}.partial').exists())
        nonce = 'b' * 32
        originals = self.mini / 'tron-ci/results' / f'gateway-{nonce}'
        (originals / 'locked').mkdir(parents=True)
        (originals / 'locked/test.log').write_bytes(content)
        recovered = self.lane('recover', nonce)
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        retained = self.mini / 'tron-ci/retained-native' / nonce
        (retained / 'locked').chmod(0o500)
        try:
            failed_cleanup = self.lane('retrieve', nonce)
            self.assertNotEqual(failed_cleanup.returncode, 0)
            target = self.local / 'test-results/mini' / f'retained-{nonce}'
            digest = hashlib.sha256((target / 'retention.json').read_bytes()).hexdigest()
            acknowledged = retained.with_name(f'.{nonce}.ack-{digest}')
            self.assertTrue(acknowledged.is_dir())
        finally:
            for directory in retained.parent.glob(f'.{nonce}.ack-*/locked'):
                directory.chmod(0o700)
        cleanup = self.lane('retrieve', nonce)
        self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
        self.assertFalse(acknowledged.exists())

    def test_whole_verifier_returns_its_report_logs_and_raw_75_without_another_lease(self) -> None:
        self.write('tools/probe.py', RECORDED)
        self.write('tools/verify/verify.py', '''import json, os, subprocess, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
subprocess.run([sys.executable, str(root / 'tools/verify/ledger.py'), 'python', str(root / 'tools/probe.py')], check=True)
sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
logs = root / 'test-results/verify' / sha
logs.mkdir(parents=True)
(logs / 'first-failure.log').write_text('native boundary fixture')
(logs / 'execution-plan.json').write_text(os.environ['TRON_VERIFY_IOS_PLAN'])
main = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'origin/main'], text=True).strip()
(logs.parent / (sha + '.json')).write_text(json.dumps({'commit': sha, 'main': main, 'args': sys.argv[1:]}))
raise SystemExit(75 if '--incomplete' in sys.argv else 0)
''')
        selectors = [f'TronMobileUITests/LongCanonicalFixtureProbeClass/testPreservesEverySelectedMethodAcrossRemotePacking{index}'
                     for index in range(527)]
        contract = json.dumps({'durations': {selector: 0.25 for selector in selectors},
                               'manifest': {'native': selectors}})
        sha = self.commit('whole-verifier boundary fixture')
        main = self.git('rev-parse', 'HEAD^')
        self.git('update-ref', 'refs/remotes/origin/main', main)
        missing = self.lane('verify', '--changed')
        self.assertEqual(missing.returncode, NO_RESULT, missing.stdout + missing.stderr)
        self.assertIn('requires the caller selector contract', missing.stderr)
        self.env['TRON_VERIFY_IOS_PLAN'] = contract
        for args in (['--batch'], ['--update-locks', 'owner']):
            denied = self.lane('verify', *args)
            self.assertEqual(denied.returncode, NO_RESULT, denied.stdout + denied.stderr)
            self.assertIn('synchronous checks', denied.stderr)
            self.assertNotIn('pushing', denied.stdout)
        for args, expected in ((['--changed'], 0), (['--incomplete'], 75)):
            with self.subTest(exit=expected):
                result = self.lane('verify', *args)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIsNone(self.reader().no_result_reason(result.returncode, result.stdout + result.stderr))
                line = next(line for line in result.stdout.splitlines() if line.startswith('mini: artifacts: '))
                artifacts = Path(line.removeprefix('mini: artifacts: '))
                self.assertEqual(json.loads((artifacts / 'verify.json').read_text()), {'commit': sha, 'main': main, 'args': args})
                self.assertEqual((artifacts / 'verify/first-failure.log').read_text(), 'native boundary fixture')
                self.assertEqual(json.loads((artifacts / 'verify/execution-plan.json').read_text()),
                                 json.loads(self.env['TRON_VERIFY_IOS_PLAN']))
                self.assertFalse((artifacts / 'ledger.sqlite3').exists())
        self.assertTrue(Path(self.env['TRON_TEST_LEDGER']).is_file())
        with sqlite3.connect(self.env['TRON_TEST_LEDGER']) as connection:
            rows = connection.execute('SELECT test_id, commit_sha, outcome FROM results').fetchall()
        self.assertEqual(rows, [('tools/probe.py::Probe.test_case', sha, 'passed')] * 2)
        self.assertEqual(list((self.mini / 'tron-ci/results').iterdir()), [])

    def test_a_python_lane_runs_its_command_at_the_exact_commit_with_one_ordered_output(self) -> None:
        self.write('tools/probe.py', PROBE)
        sha = self.commit('probe')
        command = "echo '### one' && python3 tools/probe.py && echo '### two' && python3 tools/probe.py 4"
        result = subprocess.run(['python3', str(self.local / 'tools/verify/mini.py'), 'python', command], cwd=self.local,
                                env={**self.env, 'TRON_VERIFY_COMMIT': sha}, text=True, capture_output=True, timeout=300)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        run = '### {}\nstand-in python progress\nRan 1 test in 0.001s\ntron-ci/jobs/gateway\n'
        self.assertIn(run.format('one') + run.format('two'), result.stdout, result.stderr)
        self.assertIn('mini: python lane for', result.stdout)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=(self.mini / 'tron-ci/jobs/gateway').resolve()), sha)

    def test_stopping_a_python_lane_stops_every_test_process_before_the_lock_is_free(self) -> None:
        self.write('tools/hang.py', "import os, pathlib, time\npathlib.Path(os.environ['HOME'], 'python-test').write_text(str(os.getpid()))\n"
                                    "time.sleep(120)\n")
        self.commit('hanging python test')
        runner = subprocess.Popen(['python3', str(self.local / 'tools/verify/mini.py'), 'python',
                                   "echo '### hang' && python3 tools/hang.py && echo after"], cwd=self.local, env=self.env,
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: runner.poll() is None and runner.kill())
        marker, deadline = self.mini / 'python-test', time.time() + 120
        while not marker.exists() or not marker.read_text():
            self.assertIsNone(runner.poll(), runner.stdout.read() if runner.poll() is not None else '')
            self.assertLess(time.time(), deadline, 'the python test never started')
            time.sleep(0.2)
        pid = int(marker.read_text())
        runner.send_signal(signal.SIGTERM)
        output, _ = runner.communicate(timeout=60)
        self.assertEqual(runner.returncode, 143, output)
        with open(self.mini / 'tron-ci/jobs/gateway.lock') as lock:
            deadline = time.time() + 60
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    self.assertLess(time.time(), deadline, 'a mini job still holds the job lock')
                    time.sleep(0.2)
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            os.kill(pid, signal.SIGKILL)
            self.fail(f'the python test {pid} outlived its stopped job:\n{output}')

    def test_a_node_lane_runs_its_test_files_at_the_exact_commit_and_returns_tap_and_exit_code(self) -> None:
        self.write('packages/gateway/scripts/pass.test.mjs', "import test from 'node:test';\ntest('passes', () => {});\n")
        self.write('packages/gateway/scripts/fail.test.mjs', "import test from 'node:test';\ntest('fails', () => { throw new Error('red'); });\n")
        sha = self.commit('node test files')
        passed = self.lane('node', 'scripts/pass.test.mjs')
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        self.assertIn(f'mini: node lane for {sha[:12]}', passed.stdout)
        self.assertRegex(passed.stdout, r'(?m)^[#ℹ] pass 1$')
        failed = self.lane('node', 'scripts/fail.test.mjs')
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertRegex(failed.stdout, r'(?m)^[#ℹ] fail 1$')
        with sqlite3.connect(self.env['TRON_TEST_LEDGER']) as connection:
            rows = connection.execute('SELECT test_id, commit_sha, tree_hash, outcome, lane, host, cpu_idle_percent, memory_free_percent FROM results').fetchall()
        self.assertEqual(len(rows), 2)
        self.assertEqual({row[3] for row in rows}, {'passed', 'failed'})
        self.assertEqual({row[1] for row in rows}, {sha})
        self.assertEqual({row[2] for row in rows}, {self.git('rev-parse', 'HEAD^{tree}')})
        self.assertTrue(all(row[0].startswith('packages/gateway/scripts/') and row[4] == 'node' and row[5] for row in rows))
        self.assertTrue(all(0 <= row[6] <= 100 and 0 <= row[7] <= 100 for row in rows))
        self.assertEqual(list((self.mini / 'tron-ci/results').iterdir()), [])
        self.write('scripts/root.test.mjs', "import test from 'node:test';\nimport { strict as assert } from 'node:assert';\ntest('root cwd', () => assert.ok(!process.cwd().endsWith('/packages/gateway')));\n")
        root_sha = self.commit('root Node case')
        root_run = self.lane('node', '--root', 'scripts/root.test.mjs')
        self.assertEqual(root_run.returncode, 0, root_run.stdout + root_run.stderr)
        with sqlite3.connect(self.env['TRON_TEST_LEDGER']) as connection:
            root_rows = connection.execute("SELECT test_id, commit_sha, outcome FROM results WHERE test_id LIKE 'scripts/root.test.mjs::%'").fetchall()
        self.assertEqual(len(root_rows), 1)
        self.assertEqual(root_rows[0][1:], (root_sha, 'passed'))

    def pool(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(['python3', str(self.local / 'tools/verify/mini.py'), 'pool', *args], cwd=self.local / 'packages/gateway',
                              env={**self.env, 'HOME': str(self.temporary)}, text=True, capture_output=True, timeout=300)

    def test_the_pool_runs_on_the_mini_when_reachable_and_idle_and_names_this_mac_otherwise(self) -> None:
        report, args = self.report_args()
        mini = self.pool(*args)
        self.assertEqual(mini.returncode, 0, mini.stdout + mini.stderr)
        self.assertIn('gateway lane: on the Mac mini mini.test', mini.stderr)
        self.assertIn('stand-in lane progress', mini.stdout)
        self.assertEqual(json.loads(report.read_text())['cwd'], 'tron-ci/jobs/gateway/packages/gateway', 'the lane ran on the mini')

        def here(reason: str, *extra: str) -> None:
            report.unlink(missing_ok=True)
            local = self.pool(*args, *extra)
            self.assertEqual(local.returncode, 3 if 'fail' in extra else 0, local.stdout + local.stderr)
            self.assertIn(f'gateway lane: on this Mac ({reason})', local.stderr)
            self.assertNotIn('pushing', local.stdout)
            self.assertNotIn('tron-ci', json.loads(report.read_text())['cwd'], 'the lane ran in this checkout')

        with open(self.mini / 'tron-ci/jobs/gateway.lock', 'a+') as lock:
            lock.write(json.dumps({'host': 'other', 'worktree': '/w', 'pid': 1}))
            lock.flush()
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            here('the mini is busy with another job')
        outside = self.temporary / 'outside.config.ts'
        here(f'an argument names {outside}, outside this checkout', '--config', str(outside))
        here('an argument names ../../../outside.config.ts, outside this checkout', '--config=../../../outside.config.ts')
        here('an argument names ../../../outside.test.ts, outside this checkout', '../../../outside.test.ts')
        self.git('config', 'tron.verify.mini', 'unreachable.test')
        here('the mini unreachable.test is unreachable: ssh: connect to host unreachable.test port 22: Connection refused', 'fail')
        self.git('config', 'tron.verify.mini', 'silent.test')
        here('the mini silent.test answered no status: no output')
        self.git('config', 'tron.verify.mini', 'garbled.test')
        here('the mini garbled.test answered no status: mini status: not json')
        self.git('config', '--unset', 'tron.verify.mini')
        here('no mini is configured')
        self.git('config', 'tron.verify.mini', 'mini.test')
        bare = self.mini / 'tron-ci/tron.git'
        bare.rename(bare.with_name('moved.git'))
        here('the mini is not set up: no ~/tron-ci/tron.git')
        bare.with_name('moved.git').rename(bare)
        self.write('README', 'uncommitted\n')
        here('uncommitted changes; the mini runs a commit')

    def test_stopping_a_pool_lane_on_this_mac_stops_the_lane_itself(self) -> None:
        self.git('config', 'tron.verify.mini', 'unreachable.test')
        runner = subprocess.Popen(['python3', str(self.local / 'tools/verify/mini.py'), 'pool', 'hang'], cwd=self.local / 'packages/gateway',
                                  env={**self.env, 'HOME': str(self.temporary)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: runner.poll() is None and runner.kill())
        started = self.temporary / 'lane-started'
        for _ in range(300):
            if started.exists():
                break
            time.sleep(0.1)
        self.assertTrue(started.exists(), 'the local lane started')
        runner.send_signal(signal.SIGTERM)
        self.assertEqual(runner.wait(timeout=30), 143)
        self.assertEqual((self.temporary / 'lane-terminated').read_text(), 'SIGTERM', 'the lane itself received the stop')

    def test_an_unreachable_host_or_off_pin_toolchain_fails_without_a_result(self) -> None:
        report, args = self.report_args()
        self.git('config', 'tron.verify.mini', 'unreachable.test')
        unreachable = self.lane(*args)
        self.assertEqual(unreachable.returncode, NO_RESULT, unreachable.stdout + unreachable.stderr)
        self.assertIn('unreachable', unreachable.stderr)
        self.assertIn('Connection refused', unreachable.stderr)

        self.git('config', 'tron.verify.mini', 'mini.test')
        pins = self.local / 'config/ci-toolchain.env'
        pins.write_text('\n'.join(f'{line.split("=", 1)[0]}={"0" * 64}' if '_RUNTIME_SHA256=' in line else line
                                  for line in pins.read_text().splitlines()) + '\n')
        self.commit('off-pin Node digest')
        off_pin = self.lane(*args)
        self.assertEqual(off_pin.returncode, NO_RESULT, off_pin.stdout + off_pin.stderr)
        self.assertIn('differs from the pins', off_pin.stderr)
        self.assertNotIn('stand-in lane progress', off_pin.stdout)
        self.assertFalse(report.exists())

    def test_a_job_lock_held_past_the_callers_cap_gives_no_result_naming_the_holder(self) -> None:
        report, args = self.report_args()
        (self.mini / 'tron-ci/jobs').mkdir(parents=True)
        with open(self.mini / 'tron-ci/jobs/gateway.lock', 'a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            lock.write(json.dumps({'host': 'other-mac', 'worktree': '/other/worktree', 'sha': 'feedface'}))
            lock.flush()
            started = time.monotonic()
            capped = self.lane(*args, env={**self.env, 'TRON_MINI_JOB_WAIT_SECONDS': '2'})
            waited = time.monotonic() - started
        self.assertEqual(capped.returncode, NO_RESULT, capped.stdout + capped.stderr)
        reason = capped.stderr.strip().splitlines()[-1]
        self.assertRegex(reason, r'^mini: no result: waited \d+s for the mini job lock, held by .*/other/worktree')
        self.assertEqual(self.reader().no_result_reason(capped.returncode, capped.stdout + capped.stderr), reason.removeprefix('mini: no result: '))
        self.assertGreaterEqual(waited, 2)
        self.assertNotIn('stand-in lane progress', capped.stdout)
        self.assertFalse(report.exists())
        self.assertEqual(self.lane(*args, env={**self.env, 'TRON_MINI_JOB_WAIT_SECONDS': '2'}).returncode, 0)

    def test_stopping_a_lane_waiting_for_the_job_lock_ends_it_before_it_starts(self) -> None:
        report, args = self.report_args()
        (self.mini / 'tron-ci/jobs').mkdir(parents=True)
        with open(self.mini / 'tron-ci/jobs/gateway.lock', 'a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            lock.write(json.dumps({'host': 'other-mac', 'worktree': '/other/worktree', 'sha': 'feedface'}))
            lock.flush()
            runner = self.lane(*args, background=True)
            self.addCleanup(lambda: runner.poll() is None and runner.kill())
            deadline = time.time() + 120
            seen = ''
            while 'waiting for the mini job lock' not in seen:
                self.assertLess(time.time(), deadline, f'the lane never waited for the job lock:\n{seen}')
                seen += runner.stdout.readline()
            runner.send_signal(signal.SIGTERM)
            output, _ = runner.communicate(timeout=30)
        self.assertEqual(runner.returncode, 143, seen + output)
        self.assertNotIn('stand-in lane progress', seen + output)
        self.assertFalse(report.exists())

    def test_an_exit_75_from_the_lane_itself_is_its_result_not_a_missing_one(self) -> None:
        report, args = self.report_args()
        self.write('tools/verify/gateway.py', LANE.replace("sys.exit(3 if 'fail' in args else 0)", "sys.exit(75)"))
        self.commit('a lane that exits 75')
        exited = self.lane(*args)
        self.assertEqual(exited.returncode, NO_RESULT, exited.stdout + exited.stderr)
        self.assertTrue(report.is_file(), 'the lane ran and returned its report')
        self.assertIsNone(self.reader().no_result_reason(exited.returncode, exited.stdout + exited.stderr))

    def test_a_push_whose_job_never_started_leaves_no_submission_ref(self) -> None:
        report, args = self.report_args()
        repository = self.mini / 'tron-ci/tron.git'
        self.git('config', 'tron.verify.mini', 'nojob.test')
        abandoned = self.lane(*args)
        self.assertEqual(abandoned.returncode, NO_RESULT, abandoned.stdout + abandoned.stderr)
        self.assertIn('pushed', abandoned.stdout)
        self.assertIn('without a result', abandoned.stderr)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)', cwd=repository), '')
        self.git('config', 'tron.verify.mini', 'mini.test')
        self.write('README', 'next commit\n')
        sha = self.commit('next')
        passed = self.lane(*args)
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname) %(objectname)', cwd=repository), f'refs/tron-jobs/gateway {sha}')

    def wait_for_lane(self, runner: subprocess.Popen) -> None:
        deadline = time.time() + 120
        while not (self.mini / 'lane-started').exists():
            self.assertIsNone(runner.poll(), runner.stdout.read() if runner.poll() is not None else '')
            self.assertLess(time.time(), deadline, 'the stand-in lane never started')
            time.sleep(0.2)

    def assert_mini_job_ended(self) -> None:
        self.assertEqual((self.mini / 'lane-terminated').read_text(), 'SIGTERM')
        with open(self.mini / 'tron-ci/jobs/gateway.lock') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(list((self.mini / 'tron-ci/results').iterdir()), [])

    def test_killing_the_local_runner_process_group_stops_the_mini_lane_and_frees_its_lock(self) -> None:
        _report, args = self.report_args()
        runner = subprocess.Popen(['python3', str(self.local / 'tools/verify/mini.py'), *args, 'hang'], cwd=self.local / 'packages/gateway',
                                  env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(lambda: runner.poll() is None and runner.kill())
        self.wait_for_lane(runner)
        os.killpg(runner.pid, signal.SIGKILL)
        runner.communicate(timeout=60)
        deadline = time.time() + 60
        with open(self.mini / 'tron-ci/jobs/gateway.lock') as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    self.assertLess(time.time(), deadline, 'a mini job still holds the job lock')
                    time.sleep(0.2)
        self.assert_mini_job_ended()

    def test_stopping_the_local_runner_stops_the_mini_lane_and_frees_its_lock(self) -> None:
        _report, args = self.report_args()
        runner = self.lane(*args, 'hang', background=True)
        self.addCleanup(lambda: runner.poll() is None and runner.kill())
        self.wait_for_lane(runner)
        self.write('README', 'later push\n')
        later = self.commit('later')
        pending = self.lane(*args, background=True)
        self.addCleanup(lambda: pending.poll() is None and pending.kill())
        seen = ''
        deadline = time.monotonic() + 30
        while 'waiting for the mini job lock' not in seen:
            self.assertLess(time.monotonic(), deadline, seen)
            self.assertIsNone(pending.poll(), seen)
            seen += pending.stdout.readline()
        runner.send_signal(signal.SIGTERM)
        output, _ = runner.communicate(timeout=60)
        resumed, _ = pending.communicate(timeout=60)
        self.assertEqual(pending.returncode, 0, seen + resumed)
        self.assertEqual(self.git('for-each-ref', '--format=%(refname) %(objectname)', cwd=self.mini / 'tron-ci/tron.git'),
                         f'refs/tron-jobs/gateway {later}', output + resumed)
        self.assertEqual((self.mini / 'lane-terminated').read_text(), 'SIGTERM', output)
        self.assertEqual(runner.returncode, 143, output)
        self.assert_mini_job_ended()


if __name__ == '__main__':
    unittest.main()
