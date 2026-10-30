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

    def test_mac_observation_validates_but_never_waives_an_executed_failure(self):
        from datetime import datetime, timedelta, timezone
        r = self.repo
        path = "packages/mac-app/Tests/Integration/ObservationTests.swift"
        r.write("packages/mac-app/mac.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write(path, "// Registry fixture; native execution is not requested.\n")
        r.commit("existing Swift observation subject")
        subject = r.git("rev-parse", "HEAD")
        r.git("branch", "-f", "base")
        r.write("tools/verify/known-failures.json", json.dumps([{
            "testId": path + "::ObservationTests/branchObserved()",
            "evidence": {"command": "original branch-owned native run", "commit": subject, "failureDigest": "0" * 64},
            "issue": 2152, "expires": (datetime.now(timezone.utc) + timedelta(days=7)).date().isoformat(),
        }]))
        r.commit("observational Mac record")
        self.plan()  # Real CLI admission accepts the narrow Swift namespace.
        r.write("mods/alpha/test-alpha.py", fixture.FAILING)
        r.commit("actual executed failure")
        result = r.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("AssertionError: 1 != 2", result.stdout)

    def test_skipped_python_cases_are_not_reported_as_passes(self):
        r = self.repo
        r.write('mods/alpha/test-alpha.py',
                "import unittest\nclass Boundary(unittest.TestCase):\n"
                "    def test_executed(self):\n        self.assertTrue(True)\n"
                "    @unittest.skip('unavailable platform')\n    def test_unavailable(self):\n        self.fail()\n"
                "unittest.main()\n")
        r.commit('one actual pass and one skip')
        result = r.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(r.report()['passingTests'], 1)
        r.write('mods/alpha/test-alpha.py',
                "import unittest\nclass Boundary(unittest.TestCase):\n"
                "    @unittest.skip('unavailable platform')\n    def test_unavailable(self):\n        self.fail()\n"
                "unittest.main()\n")
        r.commit('no executed test')
        result = r.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(r.report()['passingTests'], 0)

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

    def test_retired_module_with_updated_consumer_keeps_full_tier_and_live_checks(self):
        import shutil
        r = self.repo
        path = 'mods/beta/beta.module.json'
        data = json.loads((r.path / path).read_text())
        r.write(path, json.dumps({**data, 'dependsOn': ['repo/alpha']}))
        r.write('mods/beta/test-beta.lock.py',
                "from pathlib import Path\nPath('test-results/retirement-consumer').write_text('executed')\n" + fixture.PASSING)
        r.commit('live producer and consumer')
        r.git('branch', '-f', 'base')
        shutil.rmtree(r.path / 'mods/alpha')
        # This atomic consumer-edge update selects beta directly. The oracle
        # proves retired-declaration exclusion, not reverse dependency closure.
        r.write(path, json.dumps(data))
        r.commit('retire producer and remove consumer edge')
        planned = self.plan()
        self.assertEqual(planned['selection']['tier'], 'full')
        self.assertIn('deleted module repo/alpha', planned['selection']['fullReasons'])
        self.assertIn('mods/beta/test-beta.lock.py', planned['selection']['tests'])
        result = r.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((r.path / 'test-results/retirement-consumer').read_text(), 'executed')
        self.assertEqual(r.report()['passingTests'], 2)

    def test_serial_nested_files_run_once_in_batch_unless_the_test_itself_changed(self):
        r = self.repo
        root = 'packages/gateway'
        nested = root + '/src/worker/nested.integration.test.ts'
        ordinary = root + '/src/worker/ordinary.integration.test.ts'
        r.write(root + '/src/worker/worker.module.json', json.dumps({'layer': 'L2', 'owns': ['**']}))
        r.write(root + '/src/worker/worker.ts', 'export const value = 1;\n')
        r.write(nested, '// Selected via actual nested-runner config.\n')
        r.write(ordinary, '// Selected via ordinary runner.\n')
        r.write(root + '/vitest.nested.config.ts', 'const nestedTestFiles = ["src/worker/nested.integration.test.ts"];\n')
        r.write(root + '/package.module.json', json.dumps({'layer': 'L5', 'owns': ['*.ts', '*.json']}))
        r.commit('serial consumer fixture')
        r.git('branch', '-f', 'base')
        r.write(root + '/src/worker/worker.ts', 'export const value = 2;\n')
        r.commit('producer change')
        plan = self.plan()
        self.assertEqual(plan['selection']['tier'], 'full')
        self.assertIn(ordinary, plan['selection']['tests'])
        self.assertNotIn(nested, plan['selection']['tests'])
        self.assertIn(nested, plan['selection']['deferredTests'])
        batch = self.plan('--all')
        self.assertIn(nested, batch['selection']['tests'])
        r.write(nested, '// A changed serial test must run before landing.\n')
        r.commit('serial test changes too')
        changed = self.plan()
        self.assertIn(nested, changed['selection']['tests'])
        self.assertNotIn(nested, changed['selection']['deferredTests'])
        self.assertIn(nested, self.plan('--all')['selection']['tests'],
                      'batch integration must include changed serial tests too')

    def test_interrupted_step_preserves_partial_report_and_stops_descendant(self):
        import signal
        import subprocess
        import sys
        import time
        r = self.repo
        held = "import subprocess,time\nfrom pathlib import Path\nPath('test-results').mkdir(exist_ok=True)\np=subprocess.Popen(['sleep','300'])\nPath('test-results/child.pid').write_text(str(p.pid))\ntime.sleep(300)\n"
        r.write('mods/alpha/test-alpha.py', held)
        r.commit('held test')
        for owner in ('verify', 'health'):
            with self.subTest(owner=owner):
                pid_file = r.path / 'test-results/child.pid'
                pid_file.unlink(missing_ok=True)
                env = r.env
                args = ['verify', '--base', 'base']
                if owner == 'health':
                    # A real held Git child exercises health's reuse of batch's
                    # process group owner, not a mock of cancellation logic.
                    r.write('test-results/bin/git', f'#!{sys.executable}\n' + held)
                    (r.path / 'test-results/bin/git').chmod(0o755)
                    env = {**r.env, 'PATH': str(r.path / 'test-results/bin') + os.pathsep + r.env['PATH']}
                    args = ['health', '--sha', 'HEAD']
                process = subprocess.Popen([str(r.path / 'scripts/tron'), *args], cwd=r.path,
                                           env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                try:
                    deadline = time.monotonic() + 60
                    while not pid_file.exists() and time.monotonic() < deadline:
                        time.sleep(.05)
                    self.assertTrue(pid_file.exists(), 'the real child process never started')
                    if owner == 'verify':
                        self.assertEqual(r.report()['verdict'], 'running')
                    process.send_signal(signal.SIGTERM)
                    output, _ = process.communicate(timeout=30)
                    self.assertEqual(process.returncode, 130, output)
                    if owner == 'verify':
                        self.assertEqual(r.report()['verdict'], 'interrupted')
                        card = r.health()
                        self.assertEqual(card['fields']['mainReds']['verifierOutcomes'], {'interrupted': 1})
                        self.assertIsNone(card['fields']['flakeRate']['rate'])
                    else:
                        card = json.loads(output)
                        self.assertEqual(card['status'], 'interrupted')
                        self.assertIn(card, [json.loads(p.read_text()) for p in (r.path / 'test-results/health').glob('aggregate-*.json')])
                    fixture.ARTIFACTS.mkdir(parents=True, exist_ok=True)
                    (fixture.ARTIFACTS / f'health-interrupted-{owner}.json').write_text(json.dumps(card, indent=2))
                    child = int(pid_file.read_text())
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        try:
                            os.kill(child, 0)
                        except ProcessLookupError:
                            break
                        time.sleep(.05)
                    else:
                        self.fail(f'interrupted {owner} left its descendant alive')
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
        # A second explicit run must not retry even a refused/uncertain issue write.
        repeated = self.batch()
        self.assertEqual(repeated.returncode, 1, repeated.stdout + repeated.stderr)
        reports = [json.loads(p.read_text()) for p in (r.path / '.git/verify/batches').glob('*/report.json')]
        rerun = next(report for report in reports if report.get('issue', {}).get('reused'))
        self.assertEqual(rerun['issue']['log'], failed['issue']['log'])
        self.assertEqual(len(list((r.path / '.git/verify/issue-writes').glob('*.json'))), 1)

    def test_batch_sigterm_stops_lane_descendants_and_preserves_partial_report(self):
        import signal
        import subprocess
        import time
        self.boundary()
        r = self.repo
        r.write('scripts/test-batch-boundary.py',
                "import subprocess,time\nfrom pathlib import Path\np=subprocess.Popen(['sleep','300'])\n"
                "Path('test-results/batch-child.pid').write_text(str(p.pid))\ntime.sleep(300)\n")
        r.commit('held batch boundary')
        process = subprocess.Popen([str(r.path / 'scripts/tron'), 'verify', '--batch', '--base', 'base'],
                                   cwd=r.path, env=r.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            pid_file = r.path / 'test-results/batch-child.pid'
            deadline = time.monotonic() + 60
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue(pid_file.exists(), 'the actual batch lane never reached its child')
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 130, output)
            report = json.loads(next((r.path / '.git/verify/batches').glob('*/report.json')).read_text())
            self.assertEqual(report['verdict'], 'interrupted')
            self.assertFalse((r.path / '.git/verify/green.json').exists())
            child = int(pid_file.read_text())
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(.05)
            else:
                self.fail('batch SIGTERM left its owned descendant alive')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=60)

    def resource_owner(self, source):
        self.boundary()
        r = self.repo
        r.write('scripts/tron-ios-test', source)
        (r.path / 'scripts/tron-ios-test').chmod(0o755)
        data = json.loads((r.path / 'tooling.module.json').read_text())
        r.write('tooling.module.json', json.dumps({**data, 'owns': [*data['owns'], 'scripts/tron-ios-test']}))
        r.commit('resource owner')
        r.git('branch', '-f', 'base')

    def cleanup_probes(self):
        import shutil
        import subprocess
        r = self.repo
        # These fixture owners created no simulators: repair their synthetic owner,
        # observe successful cleanup, then remove the exact retained fixture tree.
        for line in r.git('worktree', 'list', '--porcelain').splitlines():
            if line.startswith('worktree ') and Path(line[9:]).resolve() != r.path.resolve():
                root = Path(line[9:])
                owner = root / 'scripts/tron-ios-test'
                owner.write_text('#!/bin/sh\nexit 0\n')
                subprocess.run([str(owner), 'clean'], cwd=root, env=r.env, check=True)
                r.git('worktree', 'remove', '--force', str(root))
                shutil.rmtree(root.parent)

    def test_probe_cleanup_refusal_preserves_its_worktree(self):
        self.resource_owner('#!/bin/sh\nexit 73\n')
        r = self.repo
        r.write('mods/alpha/alpha.py', "VALUE = 'bad'\n")
        r.commit('regression')
        retained = None
        try:
            result = self.batch('--base', 'base')
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads(next((r.path / '.git/verify/batches').glob('*/report.json')).read_text())
            retained = Path(report['attribution']['retainedWorktree'])
            self.assertTrue(retained.is_dir(), 'refused cleanup was followed by destructive worktree removal')
            self.assertEqual(report['attribution']['cleanup'][0]['exit'], 73)
        finally:
            self.cleanup_probes()

    def test_sigterm_during_probe_cleanup_keeps_recovery_evidence(self):
        import signal
        import subprocess
        import time
        self.resource_owner("#!/usr/bin/env python3\nimport os,time\nfrom pathlib import Path\n"
                            "Path('test-results').mkdir(exist_ok=True)\nPath('test-results/cleanup.pid').write_text(str(os.getpid()))\ntime.sleep(300)\n")
        r = self.repo
        r.write('mods/alpha/alpha.py', "VALUE = 'bad'\n")
        r.commit('regression')
        process = subprocess.Popen([str(r.path / 'scripts/tron'), 'verify', '--batch', '--base', 'base'],
                                   cwd=r.path, env=r.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            root = None
            deadline = time.monotonic() + 60
            while root is None and time.monotonic() < deadline:
                for line in r.git('worktree', 'list', '--porcelain').splitlines():
                    if line.startswith('worktree '):
                        candidate = Path(line[9:])
                        if (candidate / 'test-results/cleanup.pid').exists():
                            root = candidate
                time.sleep(.05)
            self.assertIsNotNone(root, 'resource-owner cleanup never started')
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 130, output)
            report_path = next((r.path / '.git/verify/batches').glob('*/report.json'))
            report = json.loads(report_path.read_text())
            self.assertEqual(report['verdict'], 'interrupted')
            progress = json.loads((report_path.parent / 'attribution/progress.json').read_text())
            self.assertEqual(Path(progress['retainedWorktree']), root)
            self.assertEqual(progress['cleanup'][-1]['exit'], 130)
            self.assertTrue(root.is_dir(), 'interrupted cleanup erased a still-owned worktree')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=60)
            self.cleanup_probes()

    def test_batch_never_certifies_source_changed_during_a_lane(self):
        self.boundary()
        r = self.repo
        r.write('scripts/test-batch-boundary.py',
                "from pathlib import Path\nPath('mods/alpha/alpha.py').write_text('VALUE = 99\\n')\n")
        r.commit('lane that changes its inputs')
        result = self.batch('--base', 'base')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((r.path / '.git/verify/green.json').exists())
        report = json.loads(next((r.path / '.git/verify/batches').glob('*/report.json')).read_text())
        self.assertEqual(report['verdict'], 'error')
        self.assertIn('source changed', report['error'])

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
