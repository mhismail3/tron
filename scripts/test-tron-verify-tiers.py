#!/usr/bin/env python3
"""Real Git/CLI regressions for tier planning and local batch coverage."""
import importlib.util
import json
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('verify_cli_fixture', ROOT / 'scripts/test-tron-verify.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class TierTests(fixture.VerifyCase):
    def plan(self, *args):
        result = self.repo.verify(*args, '--plan')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout[result.stdout.index('{'):])

    def test_default_docs_and_empty_diff_need_no_executable_tests(self):
        r = self.repo
        empty = self.plan()
        self.assertEqual(empty['selection']['tier'], 'none')
        r.write('mods/core/README.md', '# Core\n')
        r.commit('documentation')
        result = r.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(r.report()['selection']['tier'], 'none')
        self.assertEqual(r.report()['passingTests'], 0)

    def test_dirty_plan_includes_working_and_untracked_paths_but_run_refuses(self):
        r = self.repo
        r.write('mods/alpha/alpha.py', "VALUE = 'dirty'\n")
        r.write('mods/alpha/new.py', 'NEW = True\n')
        planned = self.plan()
        self.assertEqual(planned['selection']['tier'], 'full')  # untracked ownership is not yet proven
        self.assertIn('mods/alpha/new.py', planned['selection']['paths'])
        self.assertEqual(r.verify().returncode, 2)

    def test_high_risk_defers_unrelated_tests_but_fails_affected_test(self):
        r = self.repo
        r.write('mods/core/core.py', "VALUE = 'kernel'\n")
        r.write('mods/core/test-core.lock.py', fixture.FAILING)
        r.commit('kernel regression')
        planned = self.plan('--changed')
        self.assertEqual(planned['selection']['tier'], 'full')
        self.assertNotIn('mods/beta/test-beta.py', planned['selection']['tests'])
        result = r.verify('--changed')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('AssertionError: 1 != 2', result.stdout)
        self.assertEqual(r.report()['selection']['tier'], 'full')

    def test_manifest_and_risk_class_require_full_but_test_only_stays_partial(self):
        r = self.repo
        data = json.loads((r.path / 'mods/alpha/alpha.module.json').read_text())
        r.write('mods/alpha/alpha.module.json', json.dumps({**data, 'riskClass': ['security']}))
        r.commit('security graph')
        self.assertEqual(self.plan()['selection']['tier'], 'full')
        r.git('branch', '-f', 'base')
        r.write('mods/alpha/test-alpha.py', fixture.PASSING + '# Updated test.\n')
        r.commit('test-only')
        self.assertEqual(self.plan()['selection']['tier'], 'partial')
        r.git('branch', '-f', 'base')
        r.write('mods/alpha/alpha.py', 'VALUE = 2\n')
        r.commit('security code')
        self.assertEqual(self.plan()['selection']['tier'], 'full')

    def test_interrupted_step_preserves_partial_report_and_stops_descendant(self):
        import signal
        import subprocess
        import time
        r = self.repo
        r.write('mods/alpha/test-alpha.py', "import subprocess,time\nfrom pathlib import Path\np=subprocess.Popen(['sleep','300'])\nPath('test-results/child.pid').write_text(str(p.pid))\ntime.sleep(300)\n")
        r.commit('held test')
        process = subprocess.Popen([str(r.path / 'scripts/tron'), 'verify', '--base', 'base'], cwd=r.path,
                                   env=r.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            pid_file = r.path / 'test-results/child.pid'
            deadline = time.monotonic() + 60
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue(pid_file.exists(), 'the real child process never started')
            self.assertEqual(r.report()['verdict'], 'running')
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=30)
            self.assertNotEqual(process.returncode, 0, output)
            self.assertEqual(r.report()['verdict'], 'interrupted')
            child = int(pid_file.read_text())
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(.05)
            else:
                self.fail('interrupted verify left its test descendant alive')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=30)


class BatchTests(fixture.VerifyCase):
    def boundary(self):
        r = self.repo
        r.write('scripts/test-batch-boundary.py',
                "from pathlib import Path\nimport unittest\nclass Boundary(unittest.TestCase):\n"
                "    def test_source(self):\n        self.assertNotIn('bad', Path('mods/alpha/alpha.py').read_text())\n"
                "unittest.main()\n")
        path = 'mods/alpha/alpha.module.json'
        data = json.loads((r.path / path).read_text())
        r.write(path, json.dumps({**data, 'verify': ['scripts/tron test tooling scripts/test-batch-boundary.py']}))
        path = 'tooling.module.json'
        data = json.loads((r.path / path).read_text())
        r.write(path, json.dumps({**data, 'owns': [*data['owns'], 'scripts/test-batch-boundary.py']}))
        r.commit('batch boundary')
        r.git('branch', '-f', 'base')

    def batch(self, *args):
        import subprocess
        r = self.repo
        result = subprocess.run([str(r.path / 'scripts/tron'), 'verify', '--batch', *args], cwd=r.path,
                                env=r.env, capture_output=True, text=True, timeout=180)
        fixture.ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (fixture.ARTIFACTS / 'batch-runs.txt').open('a') as log:
            log.write(result.stdout + result.stderr)
        return result

    def test_green_covers_exact_commits_and_next_batch_uses_it(self):
        self.boundary()
        r = self.repo
        base = r.git('rev-parse', 'base')
        r.write('mods/alpha/alpha.py', 'VALUE = 2\n')
        r.commit('first covered change')
        first = r.git('rev-parse', 'HEAD')
        result = self.batch('--base', base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        pointer = r.path / '.git/verify/green.json'
        green = json.loads(pointer.read_text())
        report = json.loads(Path(green['report']).read_text())
        self.assertEqual(green['commit'], first)
        self.assertEqual(report['commits'], [first])
        self.assertEqual(report['verdict'], 'passed')
        # Same green head runs no lane; a new commit is covered exactly once in the next range.
        repeated = self.batch()
        self.assertEqual(repeated.returncode, 0, repeated.stdout)
        self.assertIn('no uncovered commits', repeated.stdout)
        r.write('mods/alpha/alpha.py', 'VALUE = 3\n')
        r.commit('second covered change')
        second = r.git('rev-parse', 'HEAD')
        result = self.batch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(Path(json.loads(pointer.read_text())['report']).read_text())
        self.assertEqual((report['base'], report['commits']), (first, [second]))
        refused = self.batch('--base', second)
        self.assertEqual(refused.returncode, 2, refused.stdout)
        self.assertIn('never skips failed coverage', refused.stdout)

    def test_failure_bisects_real_commits_preserves_green_and_reports_issue_refusal(self):
        self.boundary()
        r = self.repo
        base = r.git('rev-parse', 'HEAD')
        initial = self.batch('--base', base)
        self.assertEqual(initial.returncode, 0, initial.stdout + initial.stderr)
        pointer = r.path / '.git/verify/green.json'
        previous = pointer.read_bytes()
        r.write('mods/beta/beta.py', 'VALUE = 2\n')
        r.commit('unrelated good')
        r.write('mods/alpha/alpha.py', "VALUE = 'bad'\n")
        r.commit('causal regression')
        bad = r.git('rev-parse', 'HEAD')
        r.write('README.md', '# Unrelated documentation\n')
        r.commit('unrelated after regression')
        result = self.batch()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(pointer.read_bytes(), previous)
        reports = [json.loads(p.read_text()) for p in (r.path / '.git/verify/batches').glob('*/report.json')]
        failed = next(report for report in reports if report['verdict'] == 'failed')
        self.assertEqual(failed['attribution']['commit'], bad)
        self.assertEqual(failed['attribution']['files'], ['mods/alpha/alpha.py'])
        self.assertEqual(failed['attribution']['probes'][0]['outcome'], 'good')
        self.assertNotEqual(failed['issue']['exit'], 0)  # fixture intentionally has no GitHub authority
        self.assertEqual(len(r.git('worktree', 'list', '--porcelain').split('worktree ')) - 1, 1)

    def test_planning_is_read_only_and_overlapping_batch_refuses(self):
        import fcntl
        self.boundary()
        r = self.repo
        base = r.git('rev-parse', 'HEAD')
        missing = self.batch('--plan')
        self.assertEqual(missing.returncode, 2, missing.stdout)
        planned = self.batch('--base', base, '--plan')
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        self.assertFalse((r.path / '.git/verify').exists())
        state = r.path / '.git/verify'
        state.mkdir()
        with (state / 'batch.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            refused = self.batch('--base', base)
            self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
            self.assertIn('no queue or wait', refused.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
