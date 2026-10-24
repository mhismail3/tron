#!/usr/bin/env python3
"""Real-process lock for the manual reinstall's offline data window.

Runs the production parser/Reinstall workflow in fresh children over real files,
locks, inventories, copies and receipts. Only MacPlatform is replaced: fixture
identity documents stand in for signed apps, and a held OS lock for a host writer.
No installed app, launchd service, login item, credential or real HOME is used.
This does not qualify codesigning, host process detection or a real reinstall.

Run: python3 scripts/test-tron-mac-reinstall.py
Evidence: test-results/mac-reinstall/report.json (including failing runs).
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def fixture_main(root, arguments):
    # The driver itself has no path to the live platform: use the existing
    # production boundary, rather than adding an environment bypass to main().
    import tron_mac_reinstall as reinstall

    class FixturePlatform:
        installed = root / 'installed'

        def validate_app(self, app, current_contract=True):
            identity = json.loads((app / 'identity.json').read_text())
            return {'team': identity['team'],
                    'resources': hashlib.sha256((app / 'identity.json').read_bytes()).hexdigest()}

        def offline(self):
            with (root / 'writer.lock').open('a+') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise reinstall.Stop('fixture-writer-present: offline preparation refused') from None

        def verify_installed(self, require_bundled=False):
            # Host launch and supervision are deliberately outside this lock.
            reinstall.require((root / 'resumed').exists(), 'fixture-not-resumed')
            if require_bundled:
                reinstall.require(not (root / 'home/.tron/gateway/payloads/stable').exists(),
                                  'fixture-external-payload-present')

    try:
        args = reinstall.parser().parse_args(arguments)
        reinstall.Reinstall(root / 'home', FixturePlatform()).run(args)
        return 0
    except reinstall.Stop as error:
        print(f'STOP: {error}', file=sys.stderr)
        return 2


class ReinstallWindow(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-reinstall-lock-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / 'home'
        self.agent = self.home / '.tron/agent'
        self.agent.mkdir(parents=True, mode=0o700)
        self.agent.parent.chmod(0o700)
        self.session = self.agent / 'session.jsonl'
        self.session.write_bytes(b'{"fixture":"retained session"}\n')
        self.session.chmod(0o600)
        self.link = self.agent / 'session-link'
        self.link.symlink_to('session.jsonl')
        self.installed, self.candidate = self.root / 'installed', self.root / 'candidate'
        for app, version in ((self.installed, 'old'), (self.candidate, 'new')):
            app.mkdir(mode=0o700)
            (app / 'identity.json').write_text(json.dumps({'team': 'FIXTURE', 'version': version}))
        self.tmp = self.root / 'tmp'
        self.tmp.mkdir(mode=0o700)

    def cli(self, *arguments, error=None):
        child = subprocess.run([sys.executable, __file__, '--fixture', str(self.root), *map(str, arguments)],
                               env={'HOME': str(self.home), 'TMPDIR': str(self.tmp),
                                    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(child.returncode, 2 if error else 0, child.stdout + child.stderr)
        if error:
            self.assertIn(error, child.stderr)
        return child.stdout

    def operation(self):
        store = self.home / '.tron-maintenance'
        pointer = json.loads((store / 'active.json').read_text())
        return store / pointer['id']

    def receipt(self):
        return json.loads((self.operation() / 'receipt.json').read_text())

    def begin(self):
        self.cli('--app', self.candidate)
        self.assertEqual(self.receipt()['phase'], 'awaiting-offline')

    def prepare(self):
        self.begin()
        self.cli('--confirm-offline')
        self.assertEqual(self.receipt()['phase'], 'awaiting-replacement')

    def test_offline_window_rechecks_frozen_source_and_backup_after_process_exit(self):
        self.begin()
        operation = self.operation()
        with (self.root / 'writer.lock').open('w') as writer:
            fcntl.flock(writer, fcntl.LOCK_EX)
            self.cli('--confirm-offline', error='fixture-writer-present')
        self.assertEqual(self.receipt()['phase'], 'awaiting-offline')
        self.assertFalse((operation / 'backups').exists())
        self.cli('--confirm-offline')
        backup = operation / 'backups/agent/session.jsonl'
        original = self.session.read_bytes()
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(os.readlink(operation / 'backups/agent/session-link'), 'session.jsonl')
        self.assertIn('awaiting-replacement', self.cli('--status'))
        backup.write_bytes(b'corrupt backup')
        self.cli('--confirm-offline', error='backup-mismatch')
        self.assertEqual(self.receipt()['phase'], 'awaiting-replacement')
        backup.write_bytes(original)
        self.session.write_bytes(b'late writer changed the source')
        self.cli('--confirm-offline', error='source-changed')
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(self.operation(), operation)
        self.session.write_bytes(original)
        self.cli('--confirm-offline')
        self.assertEqual(self.receipt()['phase'], 'awaiting-replacement')

    def test_finish_requires_verified_candidate_and_keeps_recovery_bytes(self):
        self.prepare()
        operation = self.operation()
        old_identity = (operation / 'backups/old-app/identity.json').read_bytes()
        self.cli('--finish', error='not-verified')
        self.cli('--verify', error='wrong-installed-app')
        # Only fixture identity data changes; no app is installed or launched.
        (self.installed / 'identity.json').write_bytes((self.candidate / 'identity.json').read_bytes())
        backup = operation / 'backups/agent/session.jsonl'
        original = backup.read_bytes()
        backup.write_bytes(b'corruption after fixture identity changed')
        self.cli('--confirm-offline', error='backup-mismatch')
        self.assertEqual(self.receipt()['phase'], 'awaiting-replacement')
        backup.write_bytes(original)
        self.cli('--confirm-offline')
        self.assertEqual(self.receipt()['phase'], 'awaiting-resume')
        self.cli('--verify', error='fixture-not-resumed')
        self.assertEqual(self.receipt()['phase'], 'awaiting-resume')
        (self.root / 'resumed').touch()
        self.cli('--verify')
        self.assertEqual(self.receipt()['phase'], 'verified')
        receipt = (operation / 'receipt.json').read_bytes()
        self.cli('--finish')
        self.assertFalse((operation.parent / 'active.json').exists())
        self.assertEqual((operation / 'receipt.json').read_bytes(), receipt)
        self.assertEqual((operation / 'backups/agent/session.jsonl').read_bytes(), self.session.read_bytes())
        self.assertEqual((operation / 'backups/old-app/identity.json').read_bytes(), old_identity)

    def test_channel_retirement_and_restart_keep_original_evidence_owner(self):
        channel = self.home / '.tron/gateway/payloads/stable'
        channel.mkdir(parents=True, mode=0o700)
        (channel / 'current.json').write_bytes(b'{"version":"fixture-old"}')
        (channel / 'previous.json').write_bytes(b'{"version":"fixture-previous"}')
        (channel / 'pending.json').write_bytes(b'{"version":"fixture-pending"}')
        self.begin()
        predecessor = self.operation()
        self.cli('--select-bundled-offline')
        retired = predecessor / 'retired-stable-payloads'
        self.assertFalse(channel.exists())
        self.assertEqual((retired / 'pending.json').read_bytes(), b'{"version":"fixture-pending"}')
        self.cli('--select-bundled-offline')
        self.cli('--abandon', error='abandon-irreversible')
        self.cli('--restart')
        successor = self.operation()
        self.assertNotEqual(successor, predecessor)
        self.assertEqual(self.receipt()['predecessorOperationId'], predecessor.name)
        self.assertEqual(self.receipt()['bundledSelection']['operationId'], predecessor.name)
        self.assertTrue((predecessor / 'receipt.json').is_file())
        self.cli('--confirm-offline')
        self.assertEqual(self.receipt()['phase'], 'awaiting-replacement')
        (retired / 'pending.json').write_bytes(b'changed retired selection')
        self.cli('--confirm-offline', error='selection-backup-changed')
        self.assertEqual(self.operation(), successor)
        self.assertFalse(channel.exists())
        (retired / 'pending.json').write_bytes(b'{"version":"fixture-pending"}')
        (self.installed / 'identity.json').write_bytes((self.candidate / 'identity.json').read_bytes())
        (self.root / 'resumed').touch()
        self.cli('--confirm-offline')
        self.cli('--verify')
        self.assertEqual(self.receipt()['phase'], 'verified')
        self.assertEqual(self.receipt()['bundledSelection']['operationId'], predecessor.name)
        self.assertTrue((retired / 'current.json').is_file())


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture':
        sys.exit(fixture_main(Path(sys.argv[2]), sys.argv[3:]))
    started = time.monotonic()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ReinstallWindow))
    report = REPO / 'test-results/mac-reinstall/report.json'
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({'passed': result.wasSuccessful(), 'testsRun': result.testsRun,
                                 'seconds': round(time.monotonic() - started, 3),
                                 'failures': [text for _, text in result.failures + result.errors]}, indent=2) + '\n')
    print(f'report: {report}')
    sys.exit(0 if result.wasSuccessful() else 1)
