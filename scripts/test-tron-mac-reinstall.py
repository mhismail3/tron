#!/usr/bin/env python3
"""Real-process lock for the manual reinstall's offline data window.

Runs the production parser/Reinstall workflow in fresh children over real files,
locks, inventories, copies and receipts. Only MacPlatform is replaced: fixture
identity documents stand in for signed apps, and a held OS lock for a host writer.
No installed app, launchd service, login item, credential or real HOME is used.
This does not qualify codesigning, host process detection or a real reinstall.

CheckpointPlan guards `scripts/tron checkpoint` (tron_checkpoint.py) without building: every
journey it runs is one `scripts/ios-gateway-e2e-test run-ui` owns, every Gateway test it runs
exists, and its CLI refuses to prepare a live reinstall from a test-mode run before touching Git.

Run: python3 scripts/test-tron-mac-reinstall.py
Evidence: test-results/mac-reinstall/report.json (including failing runs).
"""
import fcntl
import hashlib
import importlib.util
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
            reinstall.require((root / 'resumed').exists(), 'fixture-not-resumed')
            if require_bundled:
                reinstall.require(not (root / 'home/.tron/state/payloads/stable').exists(),
                                  'fixture-external-payload-present')

    try:
        args = reinstall.parser().parse_args(arguments)
        reinstall.Reinstall(root / 'home', FixturePlatform()).run(args)
        return 0
    except reinstall.Stop as error:
        print(f'STOP: {error}', file=sys.stderr)
        return 2


class CheckpointPlan(unittest.TestCase):
    def test_every_journey_and_gateway_test_the_checkpoint_runs_exists(self):
        spec = importlib.util.spec_from_file_location("tron_checkpoint", HERE / "tron_checkpoint.py")
        sys.path.insert(0, str(HERE))
        checkpoint = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checkpoint)
        harness = HERE / "ios-gateway-e2e-test"
        listed = subprocess.run(["/bin/bash", "-c", 'eval "$(sed -n "/^ui_owned_journeys=(/,/^)/p" "$1")"; '
                                 'printf "%s\\n" "${ui_owned_journeys[@]}"', "owned", str(harness)],
                                capture_output=True, text=True, check=True).stdout.split()
        self.assertGreater(len(listed), 10, f"no ui_owned_journeys list read from {harness}")
        self.assertTrue(checkpoint.OUTCOMES, "the checkpoint names no outcomes")
        for _name, journeys, gateway_tests in checkpoint.OUTCOMES:
            for journey in journeys:
                with self.subTest(journey=journey):
                    self.assertIn(checkpoint.UI + journey, listed, f"{harness.name} run-ui does not own this journey")
            for test in gateway_tests:
                with self.subTest(test=test):
                    self.assertTrue((REPO / "packages/gateway" / test).is_file(), f"no Gateway test {test}")

    def test_a_test_mode_run_never_prepares_a_live_reinstall(self):
        result = subprocess.run([sys.executable, str(HERE / "tron_checkpoint.py"), "--test-mode", "--prepare-reinstall"],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("--test-mode cannot prepare a live reinstall", result.stderr)


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

    def test_backups_hold_what_the_home_registry_backs_up_and_every_unknown_path(self):
        tron = self.home / '.tron'
        kept = ('agent/sessions/project/session.jsonl', 'agent/auth.json', 'state/devices.json', 'state/unregistered/only-copy',
                'state/machine-group-id', 'state/subagents/run/status.json', 'unregistered/only-copy', 'logs/unregistered.txt',
                'workspace/builds/ios-ota/unregistered/only-copy')
        skipped = ('agent/npm/node_modules/package/index.js', 'agent/.tron-gateway-runtime.lock.lock/stale', 'state/local-auth.json',
                   'cache/session-search.sqlite', 'logs/gateway.jsonl', 'workspace/builds/ios-ota/builds/1/TronMobile.ipa')
        for relative in (*kept, *skipped):
            path = tron / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
            path.chmod(0o600)

        def label(name):
            return 'tron-' + hashlib.sha256(os.fsencode(name)).hexdigest()[:16]

        self.prepare()
        operation = self.operation()

        def backup(relative):
            top, _, rest = relative.partition('/')
            return operation / 'backups' / ('agent' if top == 'agent' else label(top)) / rest

        self.assertEqual({relative: backup(relative).read_text() for relative in kept}, {relative: relative for relative in kept})
        self.assertEqual([relative for relative in skipped if os.path.lexists(backup(relative))], [])
        self.assertEqual(set(self.receipt()['components']), {'agent', 'old-app', 'browser-config', 'machine-group',
                                                           label('state'), label('cache'), label('unregistered'),
                                                           label('logs'), label('workspace')})
        staged = json.loads((operation / 'tron-home-layout.json').read_text())
        self.assertEqual(staged, json.loads((REPO / 'packages/gateway/src/foundation/tron-home-layout.json').read_text()))
        staged_path = operation / 'tron-home-layout.json'
        self.assertEqual(self.receipt()['layoutRegistrySha256'], hashlib.sha256(staged_path.read_bytes()).hexdigest())
        for relative in ('logs/gateway.jsonl', 'cache/session-search.sqlite', 'state/local-auth.json'):
            (tron / relative).write_text('changed after the inventory froze')
        (tron / 'logs/gateway.jsonl.1').write_text('a new log segment')
        self.cli('--confirm-offline')
        self.assertEqual(self.receipt()['phase'], 'awaiting-replacement')
        (tron / 'logs/unregistered.txt').write_text('late writer changed an unregistered file')
        self.cli('--confirm-offline', error='source-changed')
        (tron / 'logs/unregistered.txt').write_text('logs/unregistered.txt')
        self.cli('--confirm-offline')
        (tron / 'state' / 'devices.json').write_text('late writer changed a backed-up record')
        self.cli('--confirm-offline', error='source-changed')
        (tron / 'state' / 'devices.json').write_text('state/devices.json')
        staged['paths']['state/devices.json']['backup'] = False
        staged_path.write_text(json.dumps(staged))
        self.cli('--confirm-offline', error='layout-registry-digest')
        staged_path.write_text(json.dumps({'version': 1, 'paths': {}}))
        self.cli('--confirm-offline', error='layout-registry')

    def test_unmigrated_unknown_paths_stay_in_a_local_private_recovery_copy(self):
        tron = self.home / '.tron'
        secret = 'fixture-legacy-credential-never-export'
        paths = ('gateway/local-auth.json', 'gateway/enrollment.json', 'internal/subagents/run/status.json',
                 'ios-builds/builds/1/TronMobile.ipa')
        for relative in paths:
            source = tron / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(secret + relative)
            source.chmod(0o600)
        for directory in (tron, *(path for path in tron.rglob('*') if path.is_dir())):
            directory.chmod(0o700)
        self.begin()
        output = self.cli('--confirm-offline')
        operation = self.operation()
        self.assertTrue(operation.is_relative_to(self.home / '.tron-maintenance'))
        self.assertNotIn(secret, output)
        self.assertNotIn(secret, (operation / 'receipt.json').read_text())
        for relative in paths:
            top, _, rest = relative.partition('/')
            component = next(name for name, source in self.receipt()['sourcePaths'].items() if source == str(tron / top))
            recovered = operation / 'backups' / component / rest
            self.assertTrue(recovered.resolve().is_relative_to(operation / 'backups'))
            self.assertEqual(recovered.read_text(), secret + relative)
            self.assertEqual(recovered.stat().st_mode & 0o777, 0o600)
            for directory in (parent for parent in recovered.parents if parent.is_relative_to(self.home / '.tron-maintenance')):
                self.assertEqual(directory.stat().st_mode & 0o777, 0o700)

    def test_finish_requires_verified_candidate_and_keeps_recovery_bytes(self):
        self.prepare()
        operation = self.operation()
        old_identity = (operation / 'backups/old-app/identity.json').read_bytes()
        self.cli('--finish', error='not-verified')
        self.cli('--verify', error='wrong-installed-app')
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
        channel = self.home / '.tron/state/payloads/stable'
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


class OwnedCommand(unittest.TestCase):
    def test_an_interrupt_after_the_command_exited_unreaped_stays_a_stop(self):
        """#2401: macOS answers killpg on a group whose members all exited but whose leader is not
        yet reaped with EPERM. A Ctrl-C in that window must still end as the interrupted-command
        Stop, never a PermissionError. The spy holds the window open, then the real wait runs."""
        sys.path.insert(0, str(HERE))
        import tron_mac_reinstall as reinstall
        from unittest import mock
        real_wait, interrupted = subprocess.Popen.wait, []

        def wait(process, timeout=None):
            if not interrupted:
                interrupted.append(process.pid)
                deadline = time.monotonic() + 60
                while not subprocess.run(['ps', '-o', 'stat=', '-p', str(process.pid)], capture_output=True,
                                         text=True).stdout.startswith('Z'):
                    self.assertLess(time.monotonic(), deadline, 'the command never exited')
                    time.sleep(0.02)
                raise KeyboardInterrupt
            return real_wait(process, timeout)

        with mock.patch.object(subprocess.Popen, 'wait', wait), \
                self.assertRaisesRegex(reinstall.Stop, 'owned: command interrupted or timed out'):
            reinstall.command([sys.executable, '-c', 'pass'], 'owned')
        self.assertEqual(len(interrupted), 1)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture':
        sys.exit(fixture_main(Path(sys.argv[2]), sys.argv[3:]))
    started = time.monotonic()
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case) for case in (CheckpointPlan, ReinstallWindow, OwnedCommand))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = REPO / 'test-results/mac-reinstall/report.json'
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({'passed': result.wasSuccessful(), 'testsRun': result.testsRun,
                                 'seconds': round(time.monotonic() - started, 3),
                                 'failures': [text for _, text in result.failures + result.errors]}, indent=2) + '\n')
    print(f'report: {report}')
    sys.exit(0 if result.wasSuccessful() else 1)
