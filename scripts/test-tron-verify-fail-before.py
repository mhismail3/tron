#!/usr/bin/env python3
"""CLI/schema controls only; these fixtures do not prove a product regression."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SELECTOR = 'packages/gateway/src/example.test.ts::suite case'
IDENTITY = hashlib.sha256(SELECTOR.encode()).hexdigest()


class FailBeforeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.base = subprocess.check_output(['git', 'rev-parse', 'HEAD^'], cwd=ROOT, text=True).strip()
        self.head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()

    def report(self, label, status, commit):
        case = {'caseDigest': IDENTITY, 'status': status}
        if status == 'failed':
            case['failureDigest'] = hashlib.sha256(b'assertion or timeout: schema cannot tell').hexdigest()
        return {'schema': 'tron.verify.v1', 'commit': commit,
                'verdict': 'failed' if status == 'failed' else 'passed', 'attemptId': label,
                'caseEvidenceComplete': True, 'steps': [{'name': 'tests: gateway',
                    'caseEvidenceComplete': True, 'caseOutcomes': [case]}]}

    def run_pair(self, before, after, missing=False):
        for label, report in [('before', before), ('after', after)]:
            if label == 'before' and missing:
                continue
            (self.directory / f'{label}.json').write_text(json.dumps(report))
        result = subprocess.run([str(ROOT / 'scripts/tron'), 'verify', '--fail-before', SELECTOR,
            '--base', self.base, '--candidate', self.head,
            '--before-report', str(self.directory / 'before.json'),
            '--after-report', str(self.directory / 'after.json')], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertFalse(data['causalProof'])
        return data['verdict']

    def test_observed_transition(self):
        self.assertEqual(self.run_pair(self.report('b', 'failed', self.base), self.report('a', 'passed', self.head)),
                         'observed-fail-before-pass-after')

    def test_pass_on_both_is_missing_fail_before(self):
        self.assertEqual(self.run_pair(self.report('b', 'passed', self.base), self.report('a', 'passed', self.head)),
                         'missing-fail-before')

    def test_empty_selector(self):
        before = self.report('b', 'failed', self.base)
        before['steps'][0]['caseOutcomes'] = []
        self.assertEqual(self.run_pair(before, self.report('a', 'passed', self.head)), 'insufficient-evidence')

    def test_missing_report(self):
        self.assertEqual(self.run_pair({}, self.report('a', 'passed', self.head), missing=True), 'insufficient-evidence')

    def test_wrong_commit(self):
        self.assertEqual(self.run_pair(self.report('b', 'failed', self.head), self.report('a', 'passed', self.head)),
                         'insufficient-evidence')

    def test_incomplete_case_evidence(self):
        before = self.report('b', 'failed', self.base)
        before['caseEvidenceComplete'] = False
        self.assertEqual(self.run_pair(before, self.report('a', 'passed', self.head)), 'insufficient-evidence')

    def test_duplicate_identity(self):
        before = self.report('b', 'failed', self.base)
        before['steps'][0]['caseOutcomes'] *= 2
        self.assertEqual(self.run_pair(before, self.report('a', 'passed', self.head)), 'insufficient-evidence')

    def test_red_candidate(self):
        self.assertEqual(self.run_pair(self.report('b', 'failed', self.base), self.report('a', 'failed', self.head)),
                         'candidate-not-green')


if __name__ == '__main__':
    unittest.main()
