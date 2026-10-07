"""Failure-first tests for the GitHub mutation boundary.

Failure modes: (1) a read is logged as a write or a write bypasses audit;
(2) concurrent worktrees interleave/corrupt records; (3) a failed request is
reported as success, or a response lost after server commit is reported as
certainly failed; (4) a mutation body, credential, or error payload is logged;
(5) the bounded audit silently evicts history or lets an unaudited write run;
(6) a public issue comment bypasses privacy refusal or accepts an unsafe issue.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from gh import Gh, GhError  # noqa: E402


class AuditBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.fake = self.root / "fake-gh"
        self.calls = self.root / "calls.jsonl"
        self.fake.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "with open(os.environ['FAKE_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "args=sys.argv[1:]\n"
            "if os.environ.get('FAKE_MODE') == 'fail':\n"
            " print('HTTP 422 rejected', file=sys.stderr); sys.exit(1)\n"
            "if os.environ.get('FAKE_MODE') == 'ambiguous':\n"
            " print('connection reset after response', file=sys.stderr); sys.exit(1)\n"
            "if args[:3] == ['api','graphql','--input']:\n"
            " body=json.load(sys.stdin); print(json.dumps({'data': {'ok': True}}))\n"
            "elif args[:2] == ['issue','comment']:\n"
            " body=sys.stdin.read()\n"
            " with open(os.environ['FAKE_BODIES'], 'a') as f: f.write(body+'\\n---\\n')\n"
            " print('ok')\n"
            "elif args[:2] == ['api','-X']:\n"
            " body=json.load(sys.stdin) if '--input' in args else None; print(json.dumps({'ok': True}))\n"
            "else: print('ok')\n"
        )
        self.fake.chmod(0o755)
        self.bodies = self.root / "bodies.txt"
        self.env = dict(os.environ, WORK_GH=str(self.fake), FAKE_CALLS=str(self.calls),
                        FAKE_BODIES=str(self.bodies))
        self.old_env = {key: os.environ.get(key) for key in ('WORK_GH', 'FAKE_CALLS', 'FAKE_MODE')}
        os.environ.update(self.env)

    def tearDown(self):
        for key, value in self.old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def records(self):
        path = Gh.audit_path(self.root)
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_reads_are_not_audited_and_each_mutation_has_terminal_outcome(self):
        gh = Gh(self.root)
        gh.run('issue', 'view', '7', '--json', 'state')
        gh.run('issue', 'comment', '7', '--body-file', '-', stdin='private body')
        gh.rest('PATCH', 'repos/a/b/labels/x', {'description': 'private payload'})
        gh.graphql('mutation { updateProjectV2(input: {projectId: "x"}) { projectV2 { id } } }')
        rows = self.records()
        self.assertEqual([r['event'] for r in rows], ['attempt', 'result'] * 3)
        self.assertEqual([r['status'] for r in rows], ['attempted', 'succeeded'] * 3)
        serialized = json.dumps(rows)
        self.assertNotIn('private body', serialized)
        self.assertNotIn('private payload', serialized)
        self.assertEqual(len(self.calls.read_text().splitlines()), 4)

    def test_rejected_and_ambiguous_writes_are_distinguished_without_payloads(self):
        gh = Gh(self.root)
        os.environ['FAKE_MODE'] = 'fail'
        with self.assertRaises(GhError):
            gh.run('issue', 'close', '8', '--comment', 'secret')
        os.environ['FAKE_MODE'] = 'ambiguous'
        with self.assertRaises(GhError):
            gh.run('pr', 'merge', '9', '--squash')
        statuses = [r['status'] for r in self.records() if r['event'] == 'result']
        self.assertEqual(statuses, ['failed', 'uncertain'])
        self.assertNotIn('secret', json.dumps(self.records()))

    def test_concurrent_mutations_produce_complete_records(self):
        gh = Gh(self.root)
        errors = []
        def write(index):
            try:
                gh.run('issue', 'comment', str(index), '--body-file', '-', stdin=f'body {index}')
            except Exception as error:  # surfaced below, not hidden by threads
                errors.append(error)
        threads = [threading.Thread(target=write, args=(n,)) for n in range(32)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        rows = self.records()
        self.assertEqual(len(rows), 64)
        attempts = {r['id'] for r in rows if r['event'] == 'attempt'}
        results = {r['id'] for r in rows if r['event'] == 'result'}
        self.assertEqual(attempts, results)
        self.assertEqual(len(self.calls.read_text().splitlines()), 32)

    def test_typed_comment_command_refuses_private_text_before_github_and_audits_public_text(self):
        root = self.root / 'command-root'
        (root / '.github').mkdir(parents=True)
        (root / 'tools/work').mkdir(parents=True)
        (root / 'scripts').mkdir()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        (root / '.github/work.json').write_text(json.dumps({
            'verify': {'scrubCommand': 'python3 scripts/guard.py'}
        }))
        (root / 'scripts/guard.py').write_text(
            "import sys\nsys.exit(1 if 'BLOCKED_TOKEN' in sys.stdin.read() else 0)\n"
        )
        body_file = self.root / 'comment.md'
        body_file.write_text('reproduced: public safe evidence')
        good = subprocess.run(
            [sys.executable, str(HERE / 'cli.py'), 'comment', '42', '--body-file', str(body_file)],
            cwd=root, env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(good.returncode, 0, good.stderr)
        body_file.write_text('reproduced BLOCKED_TOKEN')
        refused = subprocess.run(
            [sys.executable, str(HERE / 'cli.py'), 'comment', '42', '--body-file', str(body_file)],
            cwd=root, env=self.env, capture_output=True, text=True,
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn('privacy', refused.stderr.lower())
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(sum(call[:2] == ['issue', 'comment'] for call in calls), 1)
        self.assertIn(f"<!-- work:comment session={os.environ.get('WORK_SESSION_ID') or os.environ['PI_SESSION_ID']} -->",
                      self.bodies.read_text())
        rows = [json.loads(line) for line in Gh.audit_path(root).read_text().splitlines()]
        self.assertEqual([row['status'] for row in rows], ['attempted', 'succeeded'])
        self.assertNotIn('reproduced', json.dumps(rows))
    def test_full_audit_refuses_before_mutation_and_never_discards_history(self):
        from gh import AUDIT_MAX_BYTES
        path = Gh.audit_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'x' * AUDIT_MAX_BYTES)
        before = self.calls.read_text() if self.calls.exists() else ''
        with self.assertRaises(GhError):
            Gh(self.root).run('issue', 'close', '10')
        self.assertEqual(self.calls.read_text() if self.calls.exists() else '', before)
        self.assertEqual(path.stat().st_size, AUDIT_MAX_BYTES)


if __name__ == '__main__':
    unittest.main()
