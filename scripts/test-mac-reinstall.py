"""Offline behavioral checks: real filesystem/journal, injected platform boundary."""
import argparse
import contextlib
import io
import json
import multiprocessing
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

import tron_mac_reinstall as reinstall
from tron_agent_home_cutover import AgentHomeCutover, verify_pre_helper_layout


def lock_child(root, connection):
    try:
        with reinstall.exclusive(Path(root)):
            connection.send('acquired')
    except reinstall.Stop as error:
        connection.send(str(error))
    finally:
        connection.close()


class Platform:
    def __init__(self, installed):
        self.installed = installed
        self.busy = False
        self.health = True
        self.verifications = 0
        self.bundled = True
        self.required_bundled = False

    def validate_app(self, app, current_contract=True):
        return {'team': 'EXAMPLE123', 'cdhash': (app / 'identity').read_text(), 'resources': 'fixture'}

    def offline(self):
        if self.busy:
            raise reinstall.Stop('service-loaded: fixture')

    def verify_installed(self, require_bundled=False):
        self.required_bundled = require_bundled
        reinstall.require(not require_bundled or self.bundled, "wrong-selected-payload: fixture external")
        self.verifications += 1
        reinstall.require(self.health, 'installed-verification: fixture failed')


class Fixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        (self.home / '.tron').mkdir(mode=0o700)
        (self.home / '.tron/agent').mkdir(mode=0o700)
        (self.home / '.tron/agent/credentials').write_bytes(b'private fixture never logged')
        (self.home / '.tron/gateway').mkdir(mode=0o700)
        (self.home / '.tron/gateway/pairing').write_bytes(b'pairing fixture')
        (self.home / '.tron/profiles').mkdir(mode=0o700)
        (self.home / '.tron/profiles/settings').write_text('preserve this too')
        self.installed = self.root / 'installed.app'
        self.app = self.root / 'prepared.app'
        for path, identity in ((self.installed, 'old'), (self.app, 'new')):
            path.mkdir()
            (path / 'identity').write_text(identity)
        self.platform = Platform(self.installed)
        self.workflow = reinstall.Reinstall(self.home, self.platform)

    def args(self, **kwargs):
        values = dict(app=None, confirm_offline=False, verify=False, status=False, finish=False)
        values.update(kwargs)
        return argparse.Namespace(**values)

    def run_workflow(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            self.workflow.run(self.args(**kwargs))


class BundledSelectionTests(Fixture, unittest.TestCase):
    def selected_store(self):
        source = self.home / '.tron/gateway/payloads/stable'
        source.mkdir(parents=True, mode=0o700)
        for name in ('current.json', 'previous.json', 'pending-attempt.json'):
            (source / name).write_text('fixture ' + name)
        (source / 'versions').mkdir()
        (source / 'versions/old-code').write_bytes(b'old executable fixture')
        return source

    def test_whole_channel_retirement_precedes_snapshot_and_requires_bundled_live_verification(self):
        source = self.selected_store()
        proof = reinstall.tree_manifest(source)
        self.run_workflow(app=self.app)
        self.run_workflow(select_bundled_offline=True)
        self.assertFalse(source.exists())
        self.assertEqual(reinstall.tree_manifest(self.workflow.operation / 'retired-stable-payloads'), proof)
        self.assertFalse((self.workflow.operation / 'backups').exists())
        self.run_workflow(select_bundled_offline=True)
        # Approved migrations intentionally happen before the snapshot.
        (self.home / '.tron/agent/migrated').write_text('new authority')
        self.run_workflow(confirm_offline=True)
        (self.installed / 'identity').write_text('new')
        self.platform.bundled = False
        with self.assertRaisesRegex(reinstall.Stop, 'wrong-selected-payload'):
            self.run_workflow(verify=True)
        self.assertNotEqual(self.workflow.receipt['phase'], 'verified')
        self.platform.bundled = True
        self.run_workflow(verify=True)
        self.assertTrue(self.platform.required_bundled)

    def test_busy_candidate_changed_or_wrong_order_cannot_retire_selection(self):
        source = self.selected_store()
        original = reinstall.tree_manifest(source)
        self.run_workflow(app=self.app)
        self.platform.busy = True
        with self.assertRaisesRegex(reinstall.Stop, 'service-loaded'):
            self.run_workflow(select_bundled_offline=True)
        self.platform.busy = False
        (self.app / 'identity').write_text('changed')
        with self.assertRaisesRegex(reinstall.Stop, 'artifact-changed'):
            self.run_workflow(select_bundled_offline=True)
        (self.app / 'identity').write_text('new')
        self.run_workflow(confirm_offline=True)
        with self.assertRaisesRegex(reinstall.Stop, 'selection-order'):
            self.run_workflow(select_bundled_offline=True)
        self.assertEqual(reinstall.tree_manifest(source), original)

    def test_recovery_after_atomic_retirement_never_recreates_old_selection(self):
        source = self.selected_store()
        self.run_workflow(app=self.app)
        real_rename = reinstall.rename_exclusive
        def interrupted(a, b):
            real_rename(a, b)
            raise OSError('interrupted after durable rename')
        with patch.object(reinstall, 'rename_exclusive', side_effect=interrupted):
            with self.assertRaises(OSError):
                self.run_workflow(select_bundled_offline=True)
        self.assertFalse(source.exists())
        self.assertEqual(self.workflow.receipt['bundledSelection']['phase'], 'retiring')
        with self.assertRaisesRegex(reinstall.Stop, 'selection-incomplete'):
            self.run_workflow(confirm_offline=True)
        self.run_workflow(select_bundled_offline=True)
        self.assertFalse(source.exists())
        self.assertEqual(self.workflow.receipt['bundledSelection']['phase'], 'selected')

    def test_changed_source_after_interrupted_journal_cannot_be_adopted(self):
        source = self.selected_store()
        self.run_workflow(app=self.app)
        with patch.object(reinstall, 'rename_exclusive', side_effect=OSError('before rename')):
            with self.assertRaises(OSError):
                self.run_workflow(select_bundled_offline=True)
        (source / 'current.json').write_text('other writer')
        with self.assertRaisesRegex(reinstall.Stop, 'selection-source-changed'):
            self.run_workflow(select_bundled_offline=True)
        self.assertTrue(source.exists())

    def test_retired_store_corruption_blocks_snapshot(self):
        self.selected_store()
        self.run_workflow(app=self.app)
        self.run_workflow(select_bundled_offline=True)
        (self.workflow.operation / 'retired-stable-payloads/current.json').write_text('corrupt')
        with self.assertRaisesRegex(reinstall.Stop, 'selection-backup-changed'):
            self.run_workflow(confirm_offline=True)
        self.assertFalse((self.workflow.operation / 'backups').exists())

    def test_absent_channel_is_recorded_and_reappearance_blocks_snapshot(self):
        self.run_workflow(app=self.app)
        self.run_workflow(select_bundled_offline=True)
        self.assertFalse((self.workflow.operation / 'retired-stable-payloads').exists())
        self.selected_store()
        with self.assertRaisesRegex(reinstall.Stop, 'selection-changed'):
            self.run_workflow(confirm_offline=True)

    def test_symlinked_channel_refuses_without_retiring_target(self):
        target = self.root / 'external'
        target.mkdir()
        parent = self.home / '.tron/gateway/payloads'
        parent.mkdir()
        (parent / 'stable').symlink_to(target, target_is_directory=True)
        self.run_workflow(app=self.app)
        with self.assertRaisesRegex(reinstall.Stop, 'unsafe-path'):
            self.run_workflow(select_bundled_offline=True)
        self.assertTrue(target.exists())

    def test_real_platform_passes_required_bundled_verification_flag(self):
        calls = []
        def command(argv, *args, **kwargs):
            calls.append([str(x) for x in argv])
            return b''
        platform = reinstall.MacPlatform(self.home, self.installed)
        with patch.object(reinstall, 'command', side_effect=command):
            platform.verify_installed(require_bundled=True)
        self.assertIn('--require-bundled', calls[0])


class ReinstallTests(Fixture, unittest.TestCase):
    def test_replacement_retry_rejects_damaged_backup_before_advancing(self):
        self.run_workflow(app=self.app, confirm_offline=True)
        (self.installed / 'identity').write_text('new')
        (self.workflow.operation / 'backups/agent/credentials').write_bytes(b'corrupt fixture')
        before = (self.workflow.operation / 'receipt.json').read_bytes()
        with self.assertRaisesRegex(reinstall.Stop, 'backup-mismatch'):
            self.run_workflow(confirm_offline=True)
        self.assertEqual((self.workflow.operation / 'receipt.json').read_bytes(), before)

    def test_replacement_retry_checks_data_and_allows_only_the_app_to_change(self):
        self.run_workflow(app=self.app, confirm_offline=True)
        (self.installed / 'identity').write_text('new')
        source = self.home / '.tron/agent/credentials'
        original = source.read_bytes()
        source.write_bytes(b'new offline write')
        with self.assertRaisesRegex(reinstall.Stop, 'source-changed'):
            self.run_workflow(confirm_offline=True)
        source.write_bytes(original)
        self.run_workflow(confirm_offline=True)
        self.assertEqual(self.workflow.receipt['phase'], 'awaiting-resume')
        self.run_workflow(confirm_offline=True)
        self.assertEqual((self.workflow.operation / 'backups/old-app/identity').read_text(), 'old')

    def test_readable_container_is_preserved_without_weakening_private_state(self):
        container = self.home / '.tron'
        container.chmod(0o755)
        self.run_workflow(app=self.app, confirm_offline=True)
        self.assertEqual(container.stat().st_mode & 0o777, 0o755)
        for path in (self.home / '.tron/agent', self.workflow.store, self.workflow.operation / 'backups'):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)

    def test_container_write_permissions_still_refuse_before_backup(self):
        container = self.home / '.tron'
        for mode in (0o775, 0o777):
            container.chmod(mode)
            with self.assertRaisesRegex(reinstall.Stop, 'unsafe-state-container'):
                self.run_workflow(app=self.app)
            self.assertFalse((self.workflow.store / 'active.json').exists())
            self.assertEqual(container.stat().st_mode & 0o777, mode)

    def test_readable_container_does_not_admit_readable_private_agent(self):
        (self.home / '.tron').chmod(0o755)
        (self.home / '.tron/agent').chmod(0o755)
        with self.assertRaisesRegex(reinstall.Stop, 'unsafe-state-directory'):
            self.run_workflow(app=self.app)
        self.assertFalse((self.workflow.store / 'active.json').exists())

    def test_two_manual_boundaries_and_repeated_clicks(self):
        original = reinstall.tree_manifest(self.home / '.tron')
        self.run_workflow(app=self.app)
        operation = self.workflow.operation
        self.assertFalse((operation / 'backups').exists())
        self.run_workflow(app=self.app)
        self.assertEqual(operation, self.workflow.operation)
        self.run_workflow(confirm_offline=True)
        self.assertEqual(self.workflow.receipt['phase'], 'awaiting-replacement')
        self.assertEqual(self.installed.joinpath('identity').read_text(), 'old')
        self.assertEqual(reinstall.tree_manifest(self.home / '.tron'), original)
        self.assertTrue(any(name.startswith('tron-') for name in self.workflow.receipt['components']))
        self.run_workflow(confirm_offline=True)
        self.assertEqual(operation, self.workflow.operation)
        with self.assertRaisesRegex(reinstall.Stop, 'wrong-installed-app'):
            self.run_workflow(verify=True)
        shutil.copyfile(self.app / 'identity', self.installed / 'identity')
        self.platform.health = False
        with self.assertRaisesRegex(reinstall.Stop, 'installed-verification'):
            self.run_workflow(verify=True)
        self.assertNotEqual(self.workflow.receipt['phase'], 'verified')
        self.platform.health = True
        self.run_workflow(verify=True)
        self.assertEqual(self.workflow.receipt['phase'], 'verified')
        self.run_workflow(finish=True)
        self.assertFalse((self.workflow.store / 'active.json').exists())
        self.assertTrue((operation / 'backups/old-app/identity').exists())

    def test_busy_fails_before_copy(self):
        self.run_workflow(app=self.app)
        self.platform.busy = True
        with self.assertRaisesRegex(reinstall.Stop, 'service-loaded'):
            self.run_workflow(confirm_offline=True)
        self.assertFalse((self.workflow.operation / 'backups').exists())

    def test_changed_artifact_stops_before_backup(self):
        self.run_workflow(app=self.app)
        (self.app / 'identity').write_text('substituted')
        with self.assertRaisesRegex(reinstall.Stop, 'artifact-changed'):
            self.run_workflow(confirm_offline=True)

    def test_corrupt_receipt_is_not_replaced(self):
        self.run_workflow(app=self.app)
        path = self.workflow.operation / 'receipt.json'
        path.write_text('{')
        with self.assertRaises(json.JSONDecodeError):
            self.run_workflow(status=True)
        self.assertEqual(path.read_text(), '{')

    def test_source_change_and_backup_tamper_stop_replacement(self):
        self.run_workflow(app=self.app, confirm_offline=True)
        source = self.home / '.tron/agent/credentials'
        source.write_bytes(b'new write')
        with self.assertRaisesRegex(reinstall.Stop, 'source-changed'):
            self.run_workflow(confirm_offline=True)
        source.write_bytes(b'private fixture never logged')
        (self.workflow.operation / 'backups/agent/credentials').write_bytes(b'corrupt')
        with self.assertRaisesRegex(reinstall.Stop, 'backup-mismatch'):
            self.run_workflow(confirm_offline=True)

    def test_interrupted_backup_resumes_same_operation(self):
        original = reinstall.copy_tree
        count = 0
        def interrupt(*args):
            nonlocal count
            count += 1
            if count == 2:
                raise KeyboardInterrupt()
            return original(*args)
        with patch.object(reinstall, 'copy_tree', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.run_workflow(app=self.app, confirm_offline=True)
        operation = self.workflow.operation
        self.run_workflow(confirm_offline=True)
        self.assertEqual(self.workflow.operation, operation)
        self.assertEqual(self.workflow.receipt['phase'], 'awaiting-replacement')

    def test_regular_reinstall_does_not_migrate(self):
        shutil.rmtree(self.home / '.tron/agent')
        (self.home / '.pi').mkdir()
        (self.home / '.pi/agent').mkdir()
        with self.assertRaises(FileNotFoundError):
            self.run_workflow(app=self.app)
        self.assertFalse((self.home / '.tron/agent').exists())

    def test_disk_space_refusal_copies_nothing(self):
        with patch.object(reinstall.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(100, 100, 0)):
            with self.assertRaisesRegex(reinstall.Stop, 'disk-space'):
                self.run_workflow(app=self.app, confirm_offline=True)
        self.assertEqual(list((self.workflow.operation / 'backups').iterdir()), [])

    def test_symlinked_store_and_symlinked_manifest_fail(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.home / '.tron-maintenance').symlink_to(outside)
        with self.assertRaisesRegex(reinstall.Stop, 'unsafe-path'):
            self.run_workflow(app=self.app)
        self.assertEqual(list(outside.iterdir()), [])

    def test_mutually_exclusive_actions(self):
        with self.assertRaisesRegex(reinstall.Stop, 'arguments'):
            self.run_workflow(app=self.app, verify=True, confirm_offline=True)

    def test_wrong_workflow_does_not_reinterpret_receipt(self):
        self.run_workflow(app=self.app)
        other = AgentHomeCutover(self.home, self.platform)
        with self.assertRaisesRegex(reinstall.Stop, 'invalid-operation'):
            other.run(self.args(status=True))

    def test_receipt_write_failure_never_replaces_app_or_source(self):
        before = reinstall.tree_manifest(self.home / '.tron')
        with patch.object(reinstall, 'write_json', side_effect=OSError(28, 'fixture full')):
            with self.assertRaises(OSError):
                self.run_workflow(app=self.app, confirm_offline=True)
        self.assertEqual(reinstall.tree_manifest(self.home / '.tron'), before)
        self.assertEqual((self.installed / 'identity').read_text(), 'old')

    def test_added_state_root_and_corrupt_source_map_refuse_replacement(self):
        self.run_workflow(app=self.app, confirm_offline=True)
        extra = self.home / '.tron/new-owner'
        extra.mkdir()
        with self.assertRaisesRegex(reinstall.Stop, 'state-inventory-changed'):
            self.run_workflow(confirm_offline=True)
        extra.rmdir()
        self.workflow.receipt['sourcePaths']['agent'] = str(extra)
        self.workflow.save()
        with self.assertRaisesRegex(reinstall.Stop, 'source-map-changed'):
            self.run_workflow(confirm_offline=True)

    def test_artifact_signature_failure_never_executes_embedded_code(self):
        real = reinstall.MacPlatform(self.home, self.installed)
        with patch.object(reinstall, 'command', side_effect=reinstall.Stop('app-signature: fixture')) as calls:
            with self.assertRaisesRegex(reinstall.Stop, 'app-signature'):
                real.validate_app(self.app)
        self.assertEqual(len(calls.call_args_list), 1)
        self.assertEqual(calls.call_args.args[0][0], '/usr/bin/codesign')

    def test_artifact_only_verification_selects_no_live_gateway(self):
        contents = self.app / 'Contents'
        (contents / '_CodeSignature').mkdir(parents=True)
        (contents / '_CodeSignature/CodeResources').write_bytes(b'fixture seal')
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.tron.mac'}))
        signed = b'TeamIdentifier=EXAMPLE123\nCDHash=abcdef\n'
        with patch.object(reinstall, 'command', return_value=signed) as calls:
            reinstall.MacPlatform(self.home, self.installed).validate_app(self.app)
        commands = [list(map(str, call.args[0])) for call in calls.call_args_list]
        self.assertIn(["/bin/bash", str(reinstall.REPO / 'scripts/verify-mac-install.sh'), '--artifact-only'], commands)
        self.assertFalse(any('launchctl' in command[0] for command in commands))


class FilesystemTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_unreadable_optional_state_is_not_treated_as_absent(self):
        with patch.object(reinstall.os, 'lstat', side_effect=PermissionError(13, 'fixture denied')):
            with self.assertRaises(PermissionError):
                reinstall.exists(self.root / 'browser-config')
        self.assertFalse(reinstall.exists(self.root / 'missing'))

    def test_container_rejects_symlink_and_foreign_owner(self):
        link = self.root / 'link'
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(reinstall.Stop, 'unsafe-path'):
            reinstall.owned_container(link)
        with patch.object(reinstall.os, 'getuid', return_value=os.getuid() + 1):
            with self.assertRaisesRegex(reinstall.Stop, 'unsafe-state-container'):
                reinstall.owned_container(self.root)

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin ACL admission contract')
    def test_container_with_acl_requires_owner_review(self):
        import pwd
        container = self.root / 'container'
        container.mkdir(mode=0o755)
        subprocess.run(['/bin/chmod', '+a', pwd.getpwuid(os.getuid()).pw_name + ' allow add_file', container], check=True)
        with self.assertRaisesRegex(reinstall.Stop, 'unsafe-state-container: ACL'):
            reinstall.owned_container(container)
        self.assertIsNotNone(reinstall.acl_digest(container))

    def test_cross_process_lock_and_stable_inode(self):
        store = self.root / 'store'
        with reinstall.exclusive(store):
            inode = (store / 'lock').stat().st_ino
            parent, child = multiprocessing.Pipe()
            process = multiprocessing.Process(target=lock_child, args=(str(store), child))
            process.start()
            self.assertTrue(parent.poll(5))
            self.assertIn('busy:', parent.recv())
            process.join(5)
            self.assertEqual(process.exitcode, 0)
        with reinstall.exclusive(store):
            self.assertEqual((store / 'lock').stat().st_ino, inode)

    def test_exclusive_rename_never_overwrites(self):
        for name in ('source', 'destination'):
            (self.root / name).mkdir()
            (self.root / name / 'data').write_text(name)
        with self.assertRaises(OSError):
            reinstall.rename_exclusive(self.root / 'source', self.root / 'destination')
        self.assertEqual((self.root / 'destination/data').read_text(), 'destination')
        self.assertTrue((self.root / 'source/data').exists())

    def test_exclusive_rename_refuses_even_empty_destination(self):
        for name in ('source', 'destination'):
            (self.root / name).mkdir()
        with self.assertRaises(OSError):
            reinstall.rename_exclusive(self.root / 'source', self.root / 'destination')
        self.assertTrue((self.root / 'source').exists())
        self.assertTrue((self.root / 'destination').exists())

    def test_copy_preserves_bytes_modes_links_xattrs_and_resumes(self):
        source, dest, scratch = [self.root / value for value in ('source', 'dest', 'scratch')]
        source.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
        (source / 'empty').write_bytes(b'')
        (source / 'private').write_bytes(b'\0' * 1024)
        (source / 'private').chmod(0o600)
        attr = 'com.tron.test' if sys.platform == 'darwin' else 'user.tron.test'
        if sys.platform == 'darwin':
            subprocess.run(['/usr/bin/xattr', '-w', attr, 'fixture', source / 'private'], check=True)
        else:
            os.setxattr(source / 'private', attr, b'fixture')
        (source / 'link').symlink_to('private')
        expected = reinstall.tree_manifest(source)
        reinstall.copy_tree(source, dest, expected, scratch)
        reinstall.copy_tree(source, dest, expected, scratch)
        self.assertEqual((dest / 'private').read_bytes(), b'\0' * 1024)
        self.assertEqual((dest / 'private').stat().st_mode & 0o777, 0o600)
        self.assertEqual(os.readlink(dest / 'link'), 'private')
        if sys.platform == 'darwin':
            self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', attr, dest / 'private']), b'fixture\n')
        else:
            self.assertEqual(os.getxattr(dest / 'private', attr), b'fixture')

    def test_partial_backup_symlink_substitution_cannot_write_outside(self):
        source, dest, scratch = [self.root / value for value in ('source', 'dest', 'scratch')]
        for path in (source, dest, scratch):
            path.mkdir()
        (source / 'child').mkdir()
        (source / 'child/private').write_text('fixture')
        outside = self.root / 'outside'
        outside.mkdir()
        (dest / 'child').symlink_to(outside)
        with self.assertRaisesRegex(reinstall.Stop, 'backup-collision'):
            reinstall.copy_tree(source, dest, reinstall.tree_manifest(source), scratch)
        self.assertEqual(list(outside.iterdir()), [])

    def test_special_file_refused(self):
        os.mkfifo(self.root / 'fifo')
        with self.assertRaisesRegex(reinstall.Stop, 'special-file'):
            reinstall.tree_manifest(self.root)

    def test_interrupted_leaf_copy_resumes_without_exposing_partial_bytes(self):
        source, dest, scratch = [self.root / value for value in ('source', 'dest', 'scratch')]
        source.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
        for name in ('a', 'b'):
            (source / name).write_bytes(name.encode() * 1024)
        expected = reinstall.tree_manifest(source)
        actual = reinstall.rename_exclusive
        def interrupt(src, dst):
            actual(src, dst)
            raise KeyboardInterrupt()
        with patch.object(reinstall, 'rename_exclusive', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                reinstall.copy_tree(source, dest, expected, scratch)
        self.assertEqual((dest / 'a').read_bytes(), b'a' * 1024)
        self.assertFalse((dest / 'b').exists())
        reinstall.copy_tree(source, dest, expected, scratch)
        self.assertEqual((dest / 'b').read_bytes(), b'b' * 1024)

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin ACL copy contract')
    def test_acl_survives_backup(self):
        import pwd
        source, dest, scratch = [self.root / value for value in ('source', 'dest', 'scratch')]
        source.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
        data = source / 'data'
        data.write_text('fixture')
        subprocess.run(['/bin/chmod', '+a', pwd.getpwuid(os.getuid()).pw_name + ' allow read', data], check=True)
        expected = reinstall.tree_manifest(source)
        self.assertIsNotNone(expected['data']['acl'])
        reinstall.copy_tree(source, dest, expected, scratch)
        before = subprocess.check_output(['/bin/ls', '-le', data]).splitlines()[1:]
        after = subprocess.check_output(['/bin/ls', '-le', dest / 'data']).splitlines()[1:]
        self.assertEqual(before, after)

    def test_command_timeout_reports_category_without_private_output(self):
        with self.assertRaisesRegex(reinstall.Stop, '^fixture-probe: command interrupted or timed out') as stopped:
            reinstall.command([sys.executable, '-c', 'import time; print("PRIVATE", flush=True); time.sleep(60)'],
                              'fixture-probe', timeout=0.1)
        self.assertNotIn('PRIVATE', str(stopped.exception))


class PlatformProbeTests(unittest.TestCase):
    def setUp(self):
        self.platform = reinstall.MacPlatform(Path('/fixture/home'))
        self.loaded = None
        self.listener = False
        self.unreadable = False
        self.processes = b'123 /usr/bin/fixture-app\n'
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def command(self, argv, *args, **kwargs):
        return self.processes if argv[0] == '/bin/ps' else b''

    def probe(self, argv, **kwargs):
        if argv[0] == '/usr/sbin/lsof':
            return SimpleNamespace(returncode=0 if self.listener else 1,
                                   stdout=b'123' if self.listener else b'', stderr=b'')
        return SimpleNamespace(returncode=0 if argv[-1].endswith('/' + str(self.loaded)) else 113,
                               stdout=b'', stderr=b'permission denied' if self.unreadable else b'Could not find service')

    def offline(self):
        with patch.object(reinstall, 'command', side_effect=self.command), \
                patch.object(reinstall.subprocess, 'run', side_effect=self.probe):
            self.platform.offline()

    def test_absence_requires_successful_inspection(self):
        self.offline()
        self.unreadable = True
        with self.assertRaisesRegex(reinstall.Stop, 'launchd-probe'):
            self.offline()

    def test_each_loaded_owner_blocks_even_without_port(self):
        for label in ('com.tron.server', 'com.tron.server.dev', 'com.tron.server.preview',
                      'com.tron.gateway.dev', 'com.tron.mac.native-host'):
            self.loaded = label
            with self.assertRaisesRegex(reinstall.Stop, 'service-loaded'):
                self.offline()

    def test_unknown_listener_and_unmanaged_writer_block(self):
        self.listener = True
        with self.assertRaisesRegex(reinstall.Stop, 'port-busy-or-unreadable'):
            self.offline()
        self.listener = False
        self.processes = b'321 /fixture/node /fixture/Gateway/app/dist/index.js --port 9999\n'
        with self.assertRaisesRegex(reinstall.Stop, 'writer-present'):
            self.offline()

    def test_environment_override_is_neither_printed_nor_cleared(self):
        for key in ('PI_CODING_AGENT_DIR', 'TRON_DATA_DIR', 'TRON_HOME_NAME', 'PI_AGENT_BROWSER_CONFIG'):
            with patch.dict(os.environ, {key: '/private-fixture-value'}):
                with self.assertRaisesRegex(reinstall.Stop, 'custom-configuration') as error:
                    self.offline()
                self.assertNotIn('/private-fixture-value', str(error.exception))
                self.assertEqual(os.environ[key], '/private-fixture-value')

    def test_postinstall_refuses_loaded_agent_override(self):
        with patch.object(reinstall, 'command', return_value=b'\tPI_CODING_AGENT_DIR => /custom\n'):
            with self.assertRaisesRegex(reinstall.Stop, 'custom-agent-authority'):
                self.platform.verify_installed()


class CutoverTests(Fixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        (self.home / '.pi').mkdir(mode=0o700)
        (self.home / '.tron/agent').rename(self.home / '.pi/agent')
        self.workflow = AgentHomeCutover(self.home, self.platform)

    def pre_helper_fixture(self):
        contents = self.installed / 'Contents'
        (contents / 'Library/LoginItems/Tron Agent.app').mkdir(parents=True)
        (contents / 'Library/LaunchAgents').mkdir()
        (contents / 'Library/LaunchAgents/com.tron.server.plist').write_bytes(
            plistlib.dumps({'Label': 'com.tron.server'}))
        (contents / 'Resources/Gateway').mkdir(parents=True)
        manifest = contents / 'Resources/Gateway/manifest.json'
        manifest.write_text(json.dumps({'schema': 1, 'kind': 'tron-gateway-payload',
                                       'sourceRevision': '0f376b197df6603c32cee3a5706e0295c1705e55'}))
        return manifest

    def test_pre_helper_confirmation_is_checked_before_backups(self):
        self.pre_helper_fixture()
        with patch.object(self.workflow, 'prepare', side_effect=reinstall.Stop('fixture-backup-boundary')):
            with self.assertRaisesRegex(reinstall.Stop, 'fixture-backup-boundary'):
                self.run_workflow(app=self.app, confirm_pre_helper_offline=True)
        receipt = reinstall.read_json(self.workflow.operation / 'receipt.json')
        self.assertTrue(receipt['retirementBasis'].startswith('reviewed-pre-helper-'))
        self.assertFalse((self.workflow.operation / 'backups').exists())

    def test_pre_helper_retry_uses_verified_old_backup_after_app_replacement(self):
        self.pre_helper_fixture()
        self.prepare_publication()
        self.workflow.publish()
        (self.installed / 'identity').write_text('new')
        self.run_workflow(confirm_pre_helper_offline=True)
        self.assertEqual(self.workflow.receipt['phase'], 'awaiting-resume')
        (self.workflow.operation / 'backups/old-app/identity').write_text('substituted')
        with self.assertRaisesRegex(reinstall.Stop, 'pre-helper-identity'):
            self.run_workflow(confirm_pre_helper_offline=True)

    def test_pre_helper_unknown_revision_or_added_helper_refuses(self):
        manifest = self.pre_helper_fixture()
        verify_pre_helper_layout(self.installed)
        original = manifest.read_bytes()
        document = json.loads(original)
        document['sourceRevision'] = 'a' * 40
        manifest.write_text(json.dumps(document))
        with self.assertRaisesRegex(reinstall.Stop, 'pre-helper-ineligible'):
            self.run_workflow(app=self.app, confirm_pre_helper_offline=True)
        self.assertFalse((self.workflow.operation / 'backups').exists())
        manifest.write_bytes(original)
        (self.installed / 'Contents/Library/Native').mkdir()
        with self.assertRaisesRegex(reinstall.Stop, 'pre-helper-ineligible'):
            self.run_workflow(confirm_pre_helper_offline=True)
        self.assertFalse((self.workflow.operation / 'backups').exists())

    def test_pre_helper_flags_cannot_be_combined_or_used_for_regular_reinstall(self):
        for option in ('confirm_offline', 'verify', 'status', 'finish'):
            with self.assertRaisesRegex(reinstall.Stop, 'arguments'):
                self.run_workflow(app=self.app, confirm_pre_helper_offline=True, **{option: True})
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            reinstall.parser().parse_args(['--confirm-pre-helper-offline'])

    def test_pre_helper_signature_failure_never_accepts_absence_as_retirement(self):
        self.pre_helper_fixture()
        self.run_workflow(app=self.app)
        with patch.object(self.platform, 'validate_app', side_effect=reinstall.Stop('app-signature: fixture')):
            with self.assertRaisesRegex(reinstall.Stop, 'app-signature'):
                self.run_workflow(confirm_pre_helper_offline=True)
        self.assertNotIn('retirementBasis', reinstall.read_json(self.workflow.operation / 'receipt.json'))
        self.assertFalse((self.workflow.operation / 'backups').exists())

    def prepare_publication(self):
        self.run_workflow(app=self.app)
        self.workflow.backup()
        shutil.copytree(self.workflow.source_agent(), self.workflow.staging)
        source = reinstall.tree_manifest(self.workflow.source_agent())
        staged = reinstall.tree_manifest(self.workflow.staging)
        reinstall.write_json(self.workflow.operation / 'published-agent.json', staged)
        self.workflow.receipt.update(publishedDigest=reinstall.manifest_digest(staged),
                                     sourceInode=self.workflow.source_agent().stat().st_ino,
                                     stagingInode=self.workflow.staging.stat().st_ino)
        self.workflow.save('publishing')
        return source

    def test_replacement_retry_refuses_recreated_old_authority(self):
        self.prepare_publication()
        self.workflow.publish()
        (self.installed / 'identity').write_text('new')
        self.workflow.source_agent().mkdir(mode=0o700)
        before = (self.workflow.operation / 'receipt.json').read_bytes()
        with self.assertRaisesRegex(reinstall.Stop, 'dual-authority'):
            self.run_workflow(confirm_offline=True)
        self.assertEqual((self.workflow.operation / 'receipt.json').read_bytes(), before)
        self.assertTrue(self.workflow.source_agent().is_dir())
        self.assertTrue(self.workflow.destination.is_dir())

    def test_replacement_retry_refuses_changed_published_home(self):
        self.prepare_publication()
        self.workflow.publish()
        (self.installed / 'identity').write_text('new')
        data = self.workflow.destination / 'credentials'
        original = data.read_bytes()
        data.write_bytes(b'changed after publication')
        with self.assertRaisesRegex(reinstall.Stop, 'published-home-changed'):
            self.run_workflow(confirm_offline=True)
        data.write_bytes(original)
        self.run_workflow(confirm_offline=True)
        self.assertEqual(self.workflow.receipt['phase'], 'awaiting-resume')
        (self.workflow.retired / 'credentials').write_bytes(b'changed rollback evidence')
        with self.assertRaisesRegex(reinstall.Stop, 'source-changed'):
            self.run_workflow(confirm_offline=True)

    def test_replacement_retry_refuses_corrupt_cutover_backup(self):
        self.prepare_publication()
        self.workflow.publish()
        (self.installed / 'identity').write_text('new')
        (self.workflow.operation / 'backups/agent/credentials').write_bytes(b'corrupt backup')
        with self.assertRaisesRegex(reinstall.Stop, 'backup-mismatch'):
            self.run_workflow(confirm_offline=True)
        self.assertEqual(reinstall.read_json(self.workflow.operation / 'receipt.json')['phase'], 'awaiting-replacement')

    def test_container_becoming_writable_blocks_publication(self):
        self.prepare_publication()
        (self.home / '.tron').chmod(0o777)
        with self.assertRaisesRegex(reinstall.Stop, 'unsafe-state-container'):
            self.workflow.publish()
        self.assertTrue(self.workflow.source_agent().is_dir())
        self.assertFalse(self.workflow.retired.exists())
        self.assertFalse(self.workflow.destination.exists())

    def test_recovery_after_each_rename_before_receipt(self):
        self.prepare_publication()
        actual = reinstall.rename_exclusive
        import tron_agent_home_cutover as cutover
        count = 0
        def interrupt(source, destination):
            nonlocal count
            actual(source, destination)
            count += 1
            raise KeyboardInterrupt()
        with patch.object(cutover, 'rename_exclusive', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.workflow.publish()
        self.assertFalse(self.workflow.source_agent().exists())
        self.assertFalse(self.workflow.destination.exists())
        with patch.object(cutover, 'rename_exclusive', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.workflow.publish()
        self.assertTrue(self.workflow.destination.exists())
        self.workflow.publish()
        self.assertEqual(count, 2)
        self.assertEqual(self.workflow.receipt['phase'], 'awaiting-replacement')
        self.assertEqual((self.workflow.retired / 'credentials').read_bytes(), b'private fixture never logged')
        self.assertEqual((self.workflow.destination / 'credentials').read_bytes(), b'private fixture never logged')

    def test_collision_never_retires_old_authority(self):
        self.prepare_publication()
        self.workflow.destination.mkdir()
        (self.workflow.destination / 'foreign').write_text('leave alone')
        with self.assertRaisesRegex(reinstall.Stop, 'publication-collision'):
            self.workflow.publish()
        self.assertTrue(self.workflow.source_agent().exists())
        self.assertEqual((self.workflow.destination / 'foreign').read_text(), 'leave alone')

    def test_changed_stage_never_retires_source(self):
        self.prepare_publication()
        (self.workflow.staging / 'credentials').write_text('changed')
        with self.assertRaisesRegex(reinstall.Stop, 'stage-changed'):
            self.workflow.publish()
        self.assertTrue(self.workflow.source_agent().exists())

    def test_partial_rename_recovery_refuses_retired_data_changes(self):
        self.prepare_publication()
        reinstall.rename_exclusive(self.workflow.source_agent(), self.workflow.retired)
        (self.workflow.retired / 'credentials').write_text('post-cutover write')
        with self.assertRaisesRegex(reinstall.Stop, 'retired-home-mismatch'):
            self.workflow.publish()
        self.assertFalse(self.workflow.destination.exists())

    def test_missing_or_dual_homes_fail_before_backup(self):
        self.workflow.destination.mkdir(mode=0o700)
        with self.assertRaisesRegex(reinstall.Stop, 'destination-present'):
            self.run_workflow(app=self.app)

    def test_other_owner_write_prevents_retirement(self):
        self.prepare_publication()
        (self.home / '.tron/gateway/pairing').write_bytes(b'changed pairing')
        with self.assertRaisesRegex(reinstall.Stop, 'source-changed'):
            self.workflow.publish()
        self.assertTrue(self.workflow.source_agent().exists())
        self.assertFalse(self.workflow.retired.exists())

    def test_space_admission_includes_staged_home_not_only_backups(self):
        self.assertEqual(self.workflow.required_copy_bytes({'agent': 100, 'old-app': 20}), 220)

    def test_publication_intent_write_failure_leaves_authority_intact(self):
        self.prepare_publication()
        # The intent must exist before publish. Exercise the actual stage owner
        # with canonical verification stubbed only at its external CLI boundary.
        self.workflow.save('staging')
        with patch.object(self.workflow, 'migration', return_value={
                'changesMade': False, 'publicationMode': 'same-filesystem-rename'}), \
                patch.object(self.workflow, 'save', side_effect=OSError(28, 'fixture full')):
            with self.assertRaises(OSError):
                self.workflow.stage()
        self.assertTrue(self.workflow.source_agent().exists())
        self.assertFalse(self.workflow.destination.exists())

    def test_stage_sync_failure_prevents_publication_intent(self):
        self.prepare_publication()
        self.workflow.save('staging')
        import tron_agent_home_cutover as cutover
        with patch.object(self.workflow, 'migration', return_value={
                'changesMade': False, 'publicationMode': 'same-filesystem-rename'}), \
                patch.object(cutover, 'sync_tree', side_effect=OSError(5, 'fixture I/O failure')):
            with self.assertRaises(OSError):
                self.workflow.stage()
        self.assertEqual(reinstall.read_json(self.workflow.operation / 'receipt.json')['phase'], 'staging')
        self.assertTrue(self.workflow.source_agent().exists())

    def test_canonical_stage_metadata_loss_blocks_before_retirement(self):
        self.prepare_publication()
        self.workflow.save('staging')
        (self.workflow.staging / 'credentials').chmod(0o644 if
            (self.workflow.source_agent() / 'credentials').stat().st_mode & 0o777 != 0o644 else 0o600)
        with patch.object(self.workflow, 'migration', return_value={
                'changesMade': False, 'publicationMode': 'same-filesystem-rename'}):
            with self.assertRaisesRegex(reinstall.Stop, 'stage-metadata-mismatch'):
                self.workflow.stage()
        self.assertTrue(self.workflow.source_agent().exists())
        self.assertFalse(self.workflow.destination.exists())


@unittest.skipUnless(os.environ.get('TRON_TEST_APP'), 'set TRON_TEST_APP to a built app for bundled-tool integration')
class BundledCutoverTests(Fixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        (self.home / '.pi').mkdir(mode=0o700)
        (self.home / '.tron/agent').rename(self.home / '.pi/agent')
        self.workflow = AgentHomeCutover(self.home, self.platform)
        # Filesystem fixtures and fake service boundary; real bundled Node and
        # migration CLI. No real homes or service transitions are exercised.
        self.app = Path(os.environ['TRON_TEST_APP']).resolve()
        self.platform.validate_app = lambda app, current_contract=True: {
            'team': 'EXAMPLE123', 'cdhash': 'new' if app == self.app else 'old', 'resources': 'fixture'}

    def test_real_stage_without_transform(self):
        # Match an existing Mac's container mode without changing that machine.
        (self.home / '.tron').chmod(0o755)
        self.run_workflow(app=self.app, confirm_offline=True)
        self.assertEqual(self.workflow.receipt['phase'], 'awaiting-replacement')
        self.assertFalse((self.home / '.pi/agent').exists())
        self.assertEqual((self.home / '.tron/agent/credentials').read_bytes(), b'private fixture never logged')
        self.assertEqual((self.installed / 'identity').read_text(), 'old')
        self.assertEqual((self.home / '.tron').stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.workflow.destination.stat().st_mode & 0o777, 0o700)

    def test_exact_legacy_package_removed_only_from_staged_settings(self):
        old = self.home / '.pi/agent/settings.json'
        document = {'packages': ['npm:@zhushanwen/pi-ask-user@7.0.15', 'npm:fixture-package@1.0.0']}
        old.write_text(json.dumps(document))
        self.run_workflow(app=self.app, confirm_offline=True)
        self.assertEqual(json.loads((self.workflow.retired / 'settings.json').read_text()), document)
        self.assertEqual(json.loads((self.workflow.destination / 'settings.json').read_text())['packages'],
                         ['npm:fixture-package@1.0.0'])

    def test_relocation_sensitive_extension_stops_before_backup(self):
        (self.home / '.pi/agent/settings.json').write_text(json.dumps({
            'extensions': [str(self.home / '.pi/agent/extension.ts')]}))
        with self.assertRaisesRegex(reinstall.Stop, 'preflight-decision'):
            self.run_workflow(app=self.app, confirm_offline=True)
        self.assertTrue((self.home / '.pi/agent').exists())
        self.assertFalse(self.workflow.destination.exists())
        self.assertFalse((self.workflow.operation / 'backups').exists())


if __name__ == '__main__':
    unittest.main()
