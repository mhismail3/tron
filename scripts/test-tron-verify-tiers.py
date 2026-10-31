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

    def test_main_baselines_refuse_unchecked_loaded_docs_at_head(self):
        r = self.repo
        # The real loaded generator is deliberately unavailable in this tiny repo.
        # An unchanged block is not proof it was ever generated successfully.
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
                    fixture.HEALTH_ARTIFACTS.mkdir(parents=True, exist_ok=True)
                    (fixture.HEALTH_ARTIFACTS / f'health-interrupted-{owner}.json').write_text(json.dumps(card, indent=2))
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
                    (fixture.HEALTH_ARTIFACTS / f'health-interrupted-{owner}-proof.json').write_text(json.dumps({
                        'owner': owner, 'returnCode': process.returncode, 'descendantExited': True,
                        'partialRecordRetained': True,
                    }, indent=2))
                finally:
                    if process.poll() is None:
                        process.send_signal(signal.SIGTERM)
                        process.communicate(timeout=30)


# Batch process/Git regressions live in test-tron-verify-batch.py: required lanes,
# exact-case merge attribution, cleanup preservation, signals and source fencing.

if __name__ == '__main__':
    unittest.main(verbosity=2)
