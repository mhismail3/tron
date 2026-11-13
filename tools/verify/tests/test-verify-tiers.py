#!/usr/bin/env python3
"""Real Git/CLI regressions for tier planning and local batch coverage."""
import importlib.util
import json
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('verify_cli_fixture', ROOT / 'tools/verify/tests/test-verify.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class DocumentationAssetTests(fixture.VerifyCase):
    def test_deleted_non_markdown_doc_is_static_only_but_code_still_needs_tests(self):
        r = self.repo
        r.git('rm', 'mods/alpha/test-alpha.py')
        r.write('docs/docs.module.json', json.dumps({'layer': 'L5', 'owns': ['**']}))
        r.write('docs/retired.diff', 'archived prose\n')
        r.commit('documentation asset')
        r.git('branch', '-f', 'base')
        r.git('rm', 'docs/retired.diff')
        r.commit('delete documentation asset')
        result = r.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(r.report()['selection']['tier'], 'none')
        self.assertEqual(r.report()['passingTests'], 0)
        r.write('mods/alpha/alpha.py', 'VALUE = 2\n')
        r.commit('real code without tests')
        result = r.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('zero tests ran', result.stdout)


class IosAcquisitionTests(fixture.VerifyCase):
    def test_unexpected_build_refusal_fails_without_deferring_named_tests(self):
        r = self.repo
        fixture.IosLaneTests.ios_fixture(self)
        r.write('scripts/tron-ios-test', '#!/bin/sh\necho "iOS lane acquisition refused"\nexit 73\n')
        (r.path / 'scripts/tron-ios-test').chmod(0o755)
        r.write('packages/ios-app/Sources/UI/Chat/ChatView.swift', 'struct Changed {}\n')
        r.commit('busy admission')
        result = r.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = r.report()
        self.assertEqual(report['verdict'], 'failed')
        self.assertFalse(report['checkpointEligible'])
        self.assertEqual(report['passingTests'], 0)
        tests = next(s for s in report['steps'] if s['name'] == 'tests: ios')
        self.assertEqual(tests['status'], 'skipped')
        self.assertNotIn('deferred', {s['status'] for s in report['steps']})
        self.assertNotIn('--host-slot-wait-seconds', next(s for s in report['steps'] if s['name'] == 'ios build')['command'])


    def test_unexpected_run_refusal_fails_after_successful_build(self):
        r = self.repo
        fixture.IosLaneTests.ios_fixture(self)
        r.write('packages/ios-app/Sources/UI/Chat/ChatView.swift', 'struct Changed {}\n')
        r.commit('selected iOS source')
        r.env['FIXTURE_IOS_BUSY'] = 'run'
        result = r.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = r.report()
        self.assertEqual(report['verdict'], 'failed')
        self.assertEqual(report['passingTests'], 0)
        self.assertEqual(next(s for s in report['steps'] if s['name'] == 'ios build')['status'], 'ok')
        step = next(s for s in report['steps'] if s['name'] == 'tests: ios')
        self.assertEqual(step['status'], 'failed')
        self.assertNotIn('deferred', {s['status'] for s in report['steps']})
        self.assertNotIn('--host-slot-wait-seconds', step['command'])
        del r.env['FIXTURE_IOS_BUSY']
        r.env['FIXTURE_IOS_FAIL'] = 'TronMobileUITests/FixtureLockTests/testChat()'
        failed = r.verify()
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertEqual(r.report()['verdict'], 'failed')


class TierTests(fixture.VerifyCase):
    def plan(self, *args):
        result = self.repo.verify(*args, '--plan')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout[result.stdout.index('{'):])

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

    def test_main_baselines_refuse_unchecked_loaded_docs_at_head(self):
        r = self.repo
        r.write('README.md', '# Fixture\n\n<!-- tron docs settings -->\nstale\n<!-- /tron docs -->\n')
        r.commit('unchecked generated block already on main')
        for arguments in ([], ['--all']):
            with self.subTest(arguments=arguments):
                result = r.verify('--base', 'HEAD', *arguments)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                step = next(s for s in r.report()['steps'] if s['name'] == 'generated docs')
                self.assertEqual(step['status'], 'failed')
                self.assertEqual(step['command'], [str(r.path.resolve() / 'scripts/tron'), 'docs', 'check'])

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
        self.assertEqual(planned['selection']['tier'], 'full')
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
        r.write(root + '/src/declaring/declaring.module.json', json.dumps({'layer': 'L2', 'owns': ['**'],
                'verify': ['scripts/tron test gateway src/worker/nested.integration.test.ts']}))
        r.write(root + '/src/declaring/declaring.ts', 'export const value = 1;\n')
        r.commit('declaring module')
        r.git('branch', '-f', 'base')
        r.write(root + '/src/declaring/declaring.ts', 'export const value = 2;\n')
        r.commit('declaring producer change')
        declared = self.plan()
        self.assertIn(nested, declared['selection']['tests'])
        self.assertNotIn(nested, declared['selection']['deferredTests'])

    def test_interrupted_step_preserves_partial_report_and_stops_descendant(self):
        import signal
        import subprocess
        import time
        r = self.repo
        held = "import subprocess,time\nfrom pathlib import Path\nPath('test-results').mkdir(exist_ok=True)\np=subprocess.Popen(['sleep','300'])\nPath('test-results/child.pid').write_text(str(p.pid))\ntime.sleep(300)\n"
        r.write('mods/alpha/test-alpha.py', held)
        r.commit('held test')
        pid_file = r.path / 'test-results/child.pid'
        pid_file.unlink(missing_ok=True)
        process = subprocess.Popen([str(r.path / 'scripts/tron'), 'verify', '--base', 'base'], cwd=r.path,
                                   env=r.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 60
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue(pid_file.exists(), 'the real child process never started')
            self.assertEqual(r.report()['verdict'], 'running')
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 130, output)
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
                self.fail('interrupted verify left its descendant alive')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=30)


if __name__ == '__main__':
    unittest.main(verbosity=2)
