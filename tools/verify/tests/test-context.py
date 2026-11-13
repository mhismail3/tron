#!/usr/bin/env python3
"""Exercise context audit's public CLI with isolated rendered-layer violations."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class ContextAuditTests(unittest.TestCase):
    def run_audit(self, layers, sources=None, report=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'layers.json'
            path.write_text(json.dumps({'layers': layers, 'sources': sources or []}))
            command = [str(ROOT / 'scripts/tron-node'), 'exec', 'node', str(ROOT / 'tools/verify/context.mjs'), '--input', str(path)]
            result = subprocess.run(command + (['--report-only'] if report else []), capture_output=True, text=True)
            return result.returncode, json.loads(result.stdout)

    def test_clean_layers_and_report_only_budgets(self):
        code, result = self.run_audit([{'role': 'worker', 'name': 'core', 'text': 'x' * 60000, 'kind': 'system', 'always': True}])
        self.assertEqual(code, 0)
        self.assertEqual(result['diagnostics'], [])
        self.assertEqual(result['sizes'][0]['bytes'], 60000)
        self.assertEqual(result['comparisons'][0], {'role': 'worker', 'tokens': 15000, 'budget': 11000, 'over': True, 'coverage': 'partial source-rendered system layers; see unavailable'})

    def test_each_violation_is_a_failure_and_report_only_retains_it(self):
        sentence = 'Keep credentials in their owned stores and never publish secret values to source files.'
        layers = [
            {'role': 'worker', 'name': 'core', 'text': sentence, 'kind': 'system', 'always': True},
            {'role': 'worker', 'name': 'rules', 'text': sentence, 'kind': 'rules', 'always': True},
            {'role': 'home', 'name': 'profile', 'text': '12 active / 13 total; version abcdef123456', 'kind': 'index'},
            {'role': 'home', 'name': 'model', 'text': 'Current Home chat model: gpt-5', 'kind': 'system'},
            {'role': 'home', 'name': 'thinking', 'text': 'Current Home thinking level: medium', 'kind': 'system'},
            {'role': 'chat', 'name': 'skills', 'text': '<index name="skills">\n- z: Bad.\n</index>', 'kind': 'index'},
        ]
        code, result = self.run_audit(layers)
        self.assertEqual(code, 1)
        self.assertEqual({item['rule'] for item in result['diagnostics']}, {'duplicate', 'volatile', 'index-format'})
        self.assertEqual({item['layer'] for item in result['diagnostics'] if item['rule'] == 'volatile'}, {'profile', 'model', 'thinking'})
        report_code, report = self.run_audit(layers, report=True)
        self.assertEqual(report_code, 0)
        self.assertEqual(report, result)

    def test_source_ownership_and_kind_dependence(self):
        prose = 'Send a short checkin at milestones and about every 30 minutes. Ask only for spend, sends and 2FA.'
        for owners in [[{'name': 'one', 'text': prose}, {'name': 'two', 'text': prose}], [{'name': 'one', 'text': prose + '\n' + prose}]]:
            with self.subTest(owners=owners):
                sources = owners + [{'name': 'request', 'text': 'context.tools.filter(tool => homeToolAvailable(tool.name, activation.kind))'}]
                code, result = self.run_audit([], sources)
                self.assertEqual(code, 1)
                self.assertEqual({item['rule'] for item in result['diagnostics']}, {'D1-checkin-owner', 'D2-approval-owner', 'N1-kind-dependent-tools'})

    def test_well_formed_sorted_openable_index(self):
        layer = {'role': 'worker', 'name': 'skills', 'kind': 'index', 'tools': ['read'], 'text': '<index name="skills" open="read the file" kind="procedure">\n- alpha: Build the app. | /skills/alpha/SKILL.md\n- beta: Test the app. | /skills/beta/SKILL.md\n</index>'}
        code, result = self.run_audit([layer])
        self.assertEqual((code, result['diagnostics']), (0, []))
        layer['tools'] = []
        code, result = self.run_audit([layer])
        self.assertEqual((code, {item['rule'] for item in result['diagnostics']}), (1, {'index-opener'}))


if __name__ == '__main__':
    unittest.main()
