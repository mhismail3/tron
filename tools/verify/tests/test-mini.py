#!/usr/bin/env python3
"""tools/verify/mini.py end to end, with both halves real and the network hop replaced.

A disposable checkout holds the real mini.py, scripts/tron-node, Node pin and toolchain pins, plus a
stand-in tools/verify/gateway.py lane. A disposable "mini" home holds a bare tron.git and the pinned
Node (linked where nvm keeps it). An `ssh` first on PATH drops its options and runs the remote
command in that home, the way sshd would run it in the mini user's home: git's own push and
mini.py's session both go through it. The cases check that a lane runs at the exact commit and its
report and exit code come back with the mini checkout path rewritten; that a dirty tree, an
unreachable host, an off-pin toolchain and a HEAD other than verify's commit fail with exit 2 and no
result; that a push whose job never started leaves no ref once the next job ends; and that stopping the local runner, or killing its
whole process group, stops the mini lane and releases the mini job lock.
"""
from __future__ import annotations

import fcntl
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
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
[[ "$destination" != nojob* || "$*" != *" remote "* ]] || { echo "ssh: connection to $destination closed" >&2; exit 255; }
# sshd runs the command in its own session: killing this client's process group leaves it running, with its
# input closed once no client holds the pipe.
cd "$MINI_HOME" && HOME="$MINI_HOME" exec /usr/bin/python3 -c 'import os, sys; os.setsid(); os.execv("/bin/sh", ["sh", "-c", sys.argv[1]])' "$*"
'''
LANE = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
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
                                    'path': os.environ['PATH'], 'cwd': str(Path.cwd().relative_to(Path(os.environ['HOME']).resolve()))}))
sys.exit(3 if 'fail' in args else 0)
'''


class MiniGatewayLane(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix='tron-mini-test-'))
        self.addCleanup(shutil.rmtree, self.temporary, True)
        self.local, self.mini = self.temporary / 'local', self.temporary / 'mini-home'
        for path in ('tools/verify/mini.py', 'scripts/tron-node', '.node-version', 'config/ci-toolchain.env'):
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
        # The pinned Node, where the mini's scripts/tron-node finds it (nvm's directory).
        node = Path(subprocess.check_output([str(ROOT / 'scripts/tron-node')], text=True).strip())
        version = (ROOT / '.node-version').read_text().strip()
        (self.mini / '.nvm/versions/node').mkdir(parents=True)
        (self.mini / f'.nvm/versions/node/v{version}').symlink_to(node.parent.parent)
        self.env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'MINI_HOME': str(self.mini)}
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
        return subprocess.run(command, cwd=self.local / 'packages/gateway', env=self.env, text=True, capture_output=True, timeout=300)

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
        # The mini checkout path is this checkout's in what comes back; the arguments reached the lane.
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
        # From the repository root: a relative output path is still the Gateway package's, as Vitest resolves it.
        failed = subprocess.run(['python3', str(self.local / 'tools/verify/mini.py'), '--reporter=json',
                                 '--outputFile.json=../../test-results/lane.json', 'src/a.test.ts', 'fail'],
                                cwd=self.local, env=self.env, text=True, capture_output=True, timeout=300)
        self.assertEqual(failed.returncode, 3, failed.stdout + failed.stderr)
        self.assertTrue(report.is_file(), 'a red lane still returns its report')
        self.assertNotIn('npm ci', failed.stdout, 'unchanged Gateway dependency inputs are not reinstalled')

        report.unlink()
        moved = subprocess.run(['python3', str(self.local / 'tools/verify/mini.py'), *args], cwd=self.local, text=True,
                               capture_output=True, timeout=300, env={**self.env, 'TRON_VERIFY_COMMIT': sha})
        self.assertEqual(moved.returncode, 2, moved.stdout + moved.stderr)
        self.assertIn('not the commit under verification', moved.stderr)
        self.assertFalse(report.exists(), 'a HEAD that moved since verify named its commit gets no result')

        self.write('README', 'uncommitted\n')
        dirty = self.lane(*args)
        self.assertEqual(dirty.returncode, 2, dirty.stdout + dirty.stderr)
        self.assertIn('uncommitted', dirty.stderr)
        self.assertNotIn('pushing', dirty.stdout)
        self.assertFalse(report.exists())

    def test_an_unreachable_host_or_off_pin_toolchain_fails_without_a_result(self) -> None:
        report, args = self.report_args()
        self.git('config', 'tron.verify.mini', 'unreachable.test')
        unreachable = self.lane(*args)
        self.assertEqual(unreachable.returncode, 2, unreachable.stdout + unreachable.stderr)
        self.assertIn('unreachable', unreachable.stderr)
        self.assertIn('Connection refused', unreachable.stderr)

        self.git('config', 'tron.verify.mini', 'mini.test')
        pins = self.local / 'config/ci-toolchain.env'
        pins.write_text('\n'.join(f'{line.split("=", 1)[0]}={"0" * 64}' if '_RUNTIME_SHA256=' in line else line
                                  for line in pins.read_text().splitlines()) + '\n')
        self.commit('off-pin Node digest')
        off_pin = self.lane(*args)
        self.assertEqual(off_pin.returncode, 2, off_pin.stdout + off_pin.stderr)
        self.assertIn('differs from the pins', off_pin.stderr)
        self.assertNotIn('stand-in lane progress', off_pin.stdout)
        self.assertFalse(report.exists())

    def test_a_push_whose_job_never_started_leaves_no_ref_after_the_next_job(self) -> None:
        report, args = self.report_args()
        repository = self.mini / 'tron-ci/tron.git'
        # The push succeeds, then the session that would start the job drops.
        self.git('config', 'tron.verify.mini', 'nojob.test')
        abandoned = self.lane(*args)
        self.assertEqual(abandoned.returncode, 2, abandoned.stdout + abandoned.stderr)
        self.assertIn('pushed', abandoned.stdout)
        self.assertIn('without a result', abandoned.stderr)
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
        deadline = time.time() + 60
        while not (self.mini / 'lane-terminated').exists():
            self.assertLess(time.time(), deadline, 'the mini lane was never stopped')
            time.sleep(0.2)
        self.assertEqual((self.mini / 'lane-terminated').read_text(), 'SIGTERM')
        with open(self.mini / 'tron-ci/jobs/gateway.lock') as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    self.assertLess(time.time(), deadline, 'a mini job still holds the job lock')
                    time.sleep(0.2)
        self.assertEqual(list((self.mini / 'tron-ci/results').iterdir()), [])

    def test_killing_the_local_runner_process_group_stops_the_mini_lane_and_frees_its_lock(self) -> None:
        _report, args = self.report_args()
        runner = subprocess.Popen(['python3', str(self.local / 'tools/verify/mini.py'), *args, 'hang'], cwd=self.local / 'packages/gateway',
                                  env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(lambda: runner.poll() is None and runner.kill())
        self.wait_for_lane(runner)
        # No local handler runs: the runner and its ssh client die together, as under a timeout's group kill.
        os.killpg(runner.pid, signal.SIGKILL)
        runner.communicate(timeout=60)
        self.assert_mini_job_ended()

    def test_stopping_the_local_runner_stops_the_mini_lane_and_frees_its_lock(self) -> None:
        _report, args = self.report_args()
        runner = self.lane(*args, 'hang', background=True)
        self.addCleanup(lambda: runner.poll() is None and runner.kill())
        self.wait_for_lane(runner)
        runner.send_signal(signal.SIGTERM)
        output, _ = runner.communicate(timeout=60)
        self.assertEqual((self.mini / 'lane-terminated').read_text(), 'SIGTERM', output)
        self.assertEqual(runner.returncode, 143, output)
        self.assert_mini_job_ended()


if __name__ == '__main__':
    unittest.main()
