"""Offline behavioral checks: real filesystem/journal, injected platform boundary."""
import argparse
import contextlib
import hashlib
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


class LegacyLaunchAgentVerificationTests(unittest.TestCase):
    def test_loaded_or_login_persisted_legacy_owners_refuse_verification(self):
        # Execute the verifier's collision boundary with an injected read-only
        # launchctl, not a second implementation of its admission policy.
        source = (reinstall.REPO / 'scripts/verify-mac-install.sh').read_text()
        boundary = source.split('# Release must never own a second service identity.', 1)[1].split('\nobserve_debug() {', 1)[0]
        boundary = '# Release must never own a second service identity.' + boundary
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            agents = home / 'Library/LaunchAgents'
            agents.mkdir(parents=True)
            for label in ('com.tron.server.preview', 'com.tron.server.dev-takeover'):
                for state in ('absent', 'loaded-idle', 'plist-only', 'dangling-plist'):
                    with self.subTest(label=label, state=state):
                        plist = agents / (label + '.plist')
                        if state == 'plist-only':
                            plist.write_text('fixture')
                        elif state == 'dangling-plist':
                            plist.symlink_to(home / 'missing')
                        script = '''
failures=0
UID_VALUE=501
pass() { :; }
fail() { echo "$1"; failures=$((failures + 1)); }
launchctl() {
  [[ "$1" == print && "$2" == "gui/501/$LOADED_LABEL" ]] || return 1
  echo 'state = not running'
}
''' + boundary + '\nexit "$failures"\n'
                        result = subprocess.run(['/bin/bash', '-c', script], text=True, capture_output=True,
                                                env={**os.environ, 'HOME': str(home),
                                                     'LOADED_LABEL': label if state == 'loaded-idle' else ''})
                        if plist.exists() or plist.is_symlink():
                            plist.unlink()
                        self.assertEqual(result.returncode, 0 if state == 'absent' else 1, result.stderr)
                        if state != 'absent':
                            self.assertIn(label, result.stdout)


class XcodeGenRuntimeContractVerificationTests(unittest.TestCase):
    """A store payload's pinned upstream XcodeGen must be admitted.

    The launcher requires no signature on that executable, and a store payload
    carries the pinned upstream binary unchanged, so admission rests on the
    pinned digest instead of codesign. The boundary is extracted from the
    verifier and run with injected platform commands, never a second copy of
    its admission policy.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        pins = {}
        for line in (reinstall.REPO / 'config/ci-toolchain.env').read_text().splitlines():
            if line.startswith('TRON_CI_XCODEGEN_') and '=' in line:
                name, value = line.split('=', 1)
                pins[name] = value
        self.version = pins['TRON_CI_XCODEGEN_VERSION']
        self.upstream_digest = pins['TRON_CI_XCODEGEN_BINARY_SHA256']

    def verifier_fragment(self, start, end):
        # A moved marker must fail here rather than run the whole verifier
        # against this Mac.
        source = (reinstall.REPO / 'scripts/verify-mac-install.sh').read_text()
        self.assertIn(start, source)
        self.assertIn(end, source)
        return start + source.split(start, 1)[1].split(end, 1)[0]

    def run_boundary(self, body, **environment):
        script = ("set -u\nfailures=0\n"
                  "pass() { printf 'PASS  %s\\n' \"$1\"; }\n"
                  "fail() { printf 'FAIL  %s\\n' \"$1\"; failures=$((failures + 1)); }\n"
                  + body + '\nexit "$failures"\n')
        return subprocess.run(['/bin/bash', '-c', script], text=True, capture_output=True,
                              env={**os.environ, **environment})

    def stubs(self, codesign_exit, lipo_arches='x86_64 arm64'):
        # The pinned upstream binary is unsigned, and lipo cannot read these
        # text fixtures.
        return (f"codesign() {{ return {codesign_exit}; }}\n"
                f"lipo() {{ echo '{lipo_arches}'; }}\n")

    def store_payload(self, version, symlink=False):
        payload = Path(tempfile.mkdtemp(dir=self.root))
        presets = payload / 'runtime/xcodegen/share/xcodegen/SettingPresets'
        presets.mkdir(parents=True)
        (presets / 'base.yml').write_text('name: base\n')
        bin_dir = payload / 'runtime/xcodegen/bin'
        bin_dir.mkdir()
        executable = bin_dir / 'xcodegen'
        executable.write_text(f'#!/bin/sh\n[ "$1" = --version ] && printf \'Version: %s\\n\' {version}\nexit 0\n')
        executable.chmod(0o755)
        if symlink:
            target = payload / 'runtime/xcodegen/xcodegen-real'
            executable.rename(target)
            executable.symlink_to(target)
        return payload, executable

    def contract_boundary(self):
        return (self.verifier_fragment('regular_file() {', '\nplist_value() {') + '\n'
                + self.verifier_fragment('payload_meets_current_runtime_contract() {',
                                         '\n# Resolve each identity independently.') + '\n'
                + 'payload_meets_current_runtime_contract "$PAYLOAD" || exit 1\n')

    def provenance_boundary(self):
        return ('label=stable\nxcodegen="$PAYLOAD/runtime/xcodegen/bin/xcodegen"\n'
                + self.verifier_fragment('  if codesign --verify --strict "$xcodegen"',
                                         '\n  xcodegen_arches=') + '\n')

    def test_unsigned_store_payload_with_the_pinned_digest_is_admitted(self):
        payload, executable = self.store_payload(self.version)
        # The fixture's digest stands in for the pinned upstream digest, so the
        # verifier must read TRON_CI_XCODEGEN_BINARY_SHA256 rather than a literal.
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        self.assertNotEqual(digest, self.upstream_digest)
        result = self.run_boundary(self.stubs(1) + self.contract_boundary() + self.provenance_boundary(),
                                   PAYLOAD=str(payload), TRON_CI_XCODEGEN_VERSION=self.version,
                                   TRON_CI_XCODEGEN_BINARY_SHA256=digest)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('FAIL', result.stdout)
        # The PASS line also proves the extracted provenance assertion ran.
        self.assertIn('stable XcodeGen signature valid or pinned upstream digest', result.stdout)

    def test_symlinked_non_universal_or_wrong_version_xcodegen_is_refused(self):
        cases = (
            # The first case is the control: one harness must admit the store
            # payload, so a broken harness cannot pass the refusals below.
            ('store payload', self.version, 'x86_64 arm64', False, 0),
            ('symlinked executable', self.version, 'x86_64 arm64', True, 1),
            ('non-universal executable', self.version, 'arm64', False, 1),
            ('wrong version', '0.0.0-fixture', 'x86_64 arm64', False, 1),
        )
        for name, version, arches, symlink, expected in cases:
            with self.subTest(name):
                payload, _ = self.store_payload(version, symlink=symlink)
                result = self.run_boundary(self.stubs(1, arches) + self.contract_boundary(),
                                           PAYLOAD=str(payload), TRON_CI_XCODEGEN_VERSION=self.version)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_xcodegen_provenance_requires_a_signature_or_the_pinned_digest(self):
        payload, executable = self.store_payload(self.version)
        self.assertNotEqual(hashlib.sha256(executable.read_bytes()).hexdigest(), self.upstream_digest)
        cases = (
            ('unsigned binary that is not the pinned upstream binary', 1, 1),
            ('signed binary with a different digest', 0, 0),
        )
        for name, codesign_exit, expected in cases:
            with self.subTest(name):
                result = self.run_boundary(self.stubs(codesign_exit) + self.provenance_boundary(),
                                           PAYLOAD=str(payload),
                                           TRON_CI_XCODEGEN_BINARY_SHA256=self.upstream_digest)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


class RecoveryArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.store = self.home / '.tron-maintenance'
        self.store.mkdir(mode=0o700)
        self.operation_id = 'b7e87994-9ef6-4726-a98e-b91edcd8c1ff'
        self.operation = self.store / self.operation_id
        self.operation.mkdir(mode=0o700)
        reinstall.write_json(self.operation / 'receipt.json', {
            'schema': 1, 'id': self.operation_id, 'kind': 'reinstall',
            'phase': 'verified', 'home': str(reinstall.safe_path(self.home)), 'sourceRevision': 'fixture-revision',
        })
        (self.operation / 'backups').mkdir(mode=0o700)
        post_backup = self.operation / 'backups' / 'fixture-component'
        post_backup.mkdir(mode=0o700)
        (post_backup / 'state').write_text('post fixture\n')
        receipt = reinstall.read_json(self.operation / 'receipt.json')
        recorded = reinstall.tree_manifest(post_backup)
        receipt['components'] = {'fixture-component': reinstall.manifest_digest(recorded)}
        reinstall.write_json(self.operation / 'fixture-component.json', recorded)
        reinstall.write_json(self.operation / 'receipt.json', receipt)
        self.source = self.root / 'pre-cutover-source'
        self.source.mkdir(mode=0o700)
        pre = self.source / 'pre-migration'
        pre.mkdir(mode=0o700)
        for name in ('backups', 'restore-fixture', 'manifests'):
            (pre / name).mkdir(mode=0o700)
        evidence = pre / 'data-verified-pending-groups.json'
        evidence.write_text('{"fixture":true}\n')
        os.chmod(evidence, 0o600)
        import hashlib
        digest = hashlib.sha256(evidence.read_bytes()).hexdigest()
        reinstall.write_json(pre / 'verified.json', {
            'isolatedRestoreMatches': True, 'dataEvidenceSha256': digest,
        })
        for name in ('delegated-project', 'machine-id-legacy', 'stable', 'debug',
                     'delegated-temp', 'old-app', 'browser-project-config', 'browser-global-config'):
            reinstall.write_json(pre / 'manifests' / (name + '.json'), None)
        machine = pre / 'backups' / 'machine-id-legacy'
        machine.write_text('fixture identity\n')
        os.chmod(machine, 0o600)
        restored_machine = pre / 'restore-fixture' / 'machine-id-legacy'
        restored_machine.write_text('fixture identity\n')
        os.chmod(restored_machine, 0o600)
        reinstall.write_json(pre / 'manifests' / 'machine-id-legacy.json', {
            'owners': {'.': {'uid': os.getuid(), 'gid': machine.lstat().st_gid}},
            'tree': reinstall.tree_manifest(machine),
        })
        (self.source / 'completion.md').write_text('historical evidence\n')
        self.archive = reinstall.RecoveryArchive(self.home, self.operation_id)
        self.addCleanup(self.temp.cleanup)

    def test_relocate_and_verify_is_archive_only(self):
        receipt_bytes = (self.operation / 'receipt.json').read_bytes()
        evidence_bytes = (self.source / 'pre-migration/verified.json').read_bytes()
        with patch.object(reinstall.MacPlatform, 'offline', side_effect=AssertionError('live probe')):
            result = self.archive.relocate(self.source)
            self.assertEqual(result['phase'], 'verified')
            self.assertFalse(self.source.exists())
            self.assertTrue(self.archive.destination.is_dir())
            (self.home / '.tron').write_text('not a readable live-home directory')
            self.assertEqual(self.archive.verify()['entries'], result['entries'])
        self.assertFalse((self.store / 'active.json').exists())
        self.assertEqual((self.operation / 'receipt.json').read_bytes(), receipt_bytes)
        self.assertEqual((self.archive.destination / 'pre-migration/verified.json').read_bytes(), evidence_bytes)

    def test_tampering_fails_without_reading_live_home(self):
        self.archive.relocate(self.source)
        (self.archive.destination / 'completion.md').write_text('tampered\n')
        with self.assertRaisesRegex(reinstall.Stop, 'archive-checkpoint: archive closure digest mismatch'):
            self.archive.verify()

    def test_interrupted_after_rename_resumes_without_copy_or_merge(self):
        real_rename = reinstall.rename_exclusive
        def rename_then_interrupt(source, destination):
            real_rename(source, destination)
            raise OSError(5, 'fixture interruption after rename')
        with patch.object(reinstall, 'rename_exclusive', side_effect=rename_then_interrupt):
            with self.assertRaises(OSError):
                self.archive.relocate(self.source)
        self.assertFalse(self.source.exists())
        self.assertTrue(self.archive.destination.exists())
        result = self.archive.relocate(self.source)
        self.assertEqual(result['phase'], 'verified')

    def test_wrong_source_cannot_resume_recorded_operation(self):
        with patch.object(reinstall, 'rename_exclusive', side_effect=OSError(5, 'fixture interruption')):
            with self.assertRaises(OSError):
                self.archive.relocate(self.source)
        wrong = self.root / 'other-source'
        wrong.mkdir(mode=0o700)
        with self.assertRaisesRegex(reinstall.Stop, 'resume source differs'):
            self.archive.relocate(wrong)

    def test_tampered_restore_or_post_checkpoint_fails(self):
        self.archive.relocate(self.source)
        (self.archive.destination / 'pre-migration/restore-fixture/machine-id-legacy').write_text('tampered\n')
        with self.assertRaisesRegex(reinstall.Stop, 'archive-checkpoint: archive closure digest mismatch'):
            self.archive.verify()
        (self.archive.destination / 'pre-migration/restore-fixture/machine-id-legacy').write_text('fixture identity\n')
        (self.operation / 'backups/fixture-component/state').write_text('tampered\n')
        with self.assertRaisesRegex(reinstall.Stop, 'archive-post: recorded component digest mismatch'):
            self.archive.verify()

    def test_interrupted_rename_resumes_without_copy_or_merge(self):
        with patch.object(reinstall, 'rename_exclusive', side_effect=OSError(5, 'fixture interruption')):
            with self.assertRaises(OSError):
                self.archive.relocate(self.source)
        descriptor = reinstall.read_json(self.operation / 'recovery.json')
        self.assertEqual(descriptor['phase'], 'prepared')
        self.assertTrue(self.source.exists())
        result = self.archive.relocate(self.source)
        self.assertEqual(result['phase'], 'verified')
        self.assertFalse(self.source.exists())

    def test_both_roots_present_refuses_merge(self):
        with patch.object(reinstall, 'rename_exclusive', side_effect=OSError(5, 'fixture interruption')):
            with self.assertRaises(OSError):
                self.archive.relocate(self.source)
        self.archive.destination.mkdir(mode=0o700)
        with self.assertRaisesRegex(reinstall.Stop, 'archive-collision: source and destination both exist'):
            self.archive.relocate(self.source)

    def test_destination_collision_is_rejected_before_descriptor(self):
        self.archive.destination.mkdir(mode=0o700)
        with self.assertRaisesRegex(reinstall.Stop, 'archive-collision: destination already exists'):
            self.archive.relocate(self.source)
        self.assertFalse((self.operation / 'recovery.json').exists())

    def test_completed_receipt_cannot_change_after_registration(self):
        self.archive.relocate(self.source)
        receipt = reinstall.read_json(self.operation / 'receipt.json')
        receipt['sourceRevision'] = 'different-source'
        reinstall.write_json(self.operation / 'receipt.json', receipt)
        archive = reinstall.RecoveryArchive(self.home, self.operation_id)
        with self.assertRaisesRegex(reinstall.Stop, 'completed receipt changed'):
            archive.verify()

    def test_post_manifest_tampering_is_rejected_before_rename(self):
        reinstall.write_json(self.operation / 'fixture-component.json', {})
        with self.assertRaisesRegex(reinstall.Stop, 'recorded manifest digest mismatch'):
            self.archive.relocate(self.source)
        self.assertTrue(self.source.exists())
        self.assertFalse(self.archive.destination.exists())

    def test_retired_payload_must_match_historical_manifest(self):
        retired = self.operation / 'retired-stable-payloads'
        retired.mkdir(mode=0o700)
        (retired / 'payload').write_text('original')
        proof = reinstall.tree_manifest(retired)
        reinstall.write_json(self.operation / 'stable-selection.json', proof)
        receipt = reinstall.read_json(self.operation / 'receipt.json')
        receipt['bundledSelection'] = {'phase': 'selected', 'manifestDigest': reinstall.manifest_digest(proof)}
        reinstall.write_json(self.operation / 'receipt.json', receipt)
        archive = reinstall.RecoveryArchive(self.home, self.operation_id)
        (retired / 'payload').write_text('corrupt')
        with self.assertRaisesRegex(reinstall.Stop, 'retired payload evidence differs'):
            archive.relocate(self.source)
        self.assertTrue(self.source.exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin copy attribution exception')
    def test_post_copy_provenance_differs_without_weakening_other_metadata(self):
        path = self.operation / 'backups/fixture-component'
        proof = reinstall.read_json(self.operation / 'fixture-component.json')
        proof['state']['xattrs']['com.apple.provenance'] = 'source-attribution'
        reinstall.write_json(self.operation / 'fixture-component.json', proof)
        receipt = reinstall.read_json(self.operation / 'receipt.json')
        receipt['components']['fixture-component'] = reinstall.manifest_digest(proof)
        reinstall.write_json(self.operation / 'receipt.json', receipt)
        read_xattrs = reinstall.xattr_digests
        def copied_xattrs(p):
            actual = read_xattrs(p)
            if p == path / 'state':
                actual['com.apple.provenance'] = 'copy-attribution'
            return actual
        with patch.object(reinstall, 'xattr_digests', side_effect=copied_xattrs):
            reinstall._verify_post_components(self.operation, receipt)
            (path / 'state').chmod(0o700)
            with self.assertRaisesRegex(reinstall.Stop, 'recorded component digest mismatch'):
                reinstall._verify_post_components(self.operation, receipt)

    def test_invalid_component_paths_and_active_operation_are_rejected(self):
        receipt = reinstall.read_json(self.operation / 'receipt.json')
        receipt['components']['..'] = '0' * 64
        reinstall.write_json(self.operation / 'receipt.json', receipt)
        with self.assertRaisesRegex(reinstall.Stop, 'expected completed verified operation'):
            reinstall.RecoveryArchive(self.home, self.operation_id)
        del receipt['components']['..']
        reinstall.write_json(self.operation / 'receipt.json', receipt)
        reinstall.write_json(self.store / 'active.json', {'id': self.operation_id})
        with self.assertRaisesRegex(reinstall.Stop, 'active maintenance operation'):
            reinstall.RecoveryArchive(self.home, self.operation_id)

    def test_owner_mode_extra_entries_and_restore_corruption_block_enrollment(self):
        machine = self.source / 'pre-migration/backups/machine-id-legacy'
        proof_path = self.source / 'pre-migration/manifests/machine-id-legacy.json'
        proof = reinstall.read_json(proof_path)
        proof['owners']['.']['gid'] += 1
        reinstall.write_json(proof_path, proof)
        with self.assertRaisesRegex(reinstall.Stop, 'recorded owner differs'):
            self.archive.relocate(self.source)
        proof['owners']['.']['gid'] -= 1
        reinstall.write_json(proof_path, proof)
        machine.chmod(0o644)
        with self.assertRaisesRegex(reinstall.Stop, 'recorded entry differs'):
            self.archive.relocate(self.source)
        machine.chmod(0o600)
        extra = self.source / 'pre-migration/backups/unrecorded'
        extra.write_text('extra')
        with self.assertRaisesRegex(reinstall.Stop, 'unexpected backup component'):
            self.archive.relocate(self.source)
        extra.unlink()
        (self.source / 'pre-migration/restore-fixture/machine-id-legacy').write_text('wrong restore')
        with self.assertRaisesRegex(reinstall.Stop, 'isolated fixture differs'):
            self.archive.relocate(self.source)
        self.assertTrue(self.source.exists())
        self.assertFalse((self.operation / 'recovery.json').exists())

    def test_progress_reports_work_without_changing_archive_digest(self):
        baseline = reinstall.archive_fingerprint(self.source)
        clock = iter(range(0, 100000, 11))
        progress = io.StringIO()
        with patch.object(reinstall.time, 'monotonic', side_effect=lambda: next(clock)), \
                contextlib.redirect_stderr(progress):
            observed = reinstall.archive_fingerprint(self.source)
        self.assertEqual(observed, baseline)
        self.assertIn('entries,', progress.getvalue())
        self.assertIn('GiB hashed', progress.getvalue())

    def test_depth_and_symlinked_roots_are_bounded(self):
        with patch.object(reinstall, 'MAX_ARCHIVE_ENTRIES', 1):
            with self.assertRaisesRegex(reinstall.Stop, 'archive-inventory-limit'):
                reinstall.archive_fingerprint(self.source)
        link = self.root / 'source-link'
        link.symlink_to(self.source)
        with self.assertRaisesRegex(reinstall.Stop, 'unsafe-path'):
            self.archive.relocate(link)
        with self.assertRaisesRegex(reinstall.Stop, 'overlaps the maintenance operation'):
            self.archive.relocate(self.home)

    def test_manifest_symlinked_ancestor_is_rejected(self):
        component = self.root / 'component'
        component.mkdir(mode=0o700)
        (component / 'link').symlink_to(self.root)
        with self.assertRaisesRegex(reinstall.Stop, 'symlinked ancestor'):
            reinstall._safe_archive_child(component, 'link/secret')



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

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin rename attribution')
    def test_recovery_accepts_only_renamed_root_provenance_and_preserves_original_proof(self):
        source = self.selected_store()
        self.run_workflow(app=self.app)
        retired = self.workflow.operation / 'retired-stable-payloads'
        real_xattrs = reinstall.xattr_digests
        real_rename = reinstall.rename_exclusive
        def attributed(path):
            actual = real_xattrs(path)
            if Path(path) in (source, retired):
                actual['com.apple.provenance'] = ('a' if Path(path) == source else 'b') * 64
            return actual
        def interrupted(a, b):
            real_rename(a, b)
            raise OSError('interrupted after durable rename')
        with patch.object(reinstall, 'xattr_digests', side_effect=attributed):
            with patch.object(reinstall, 'rename_exclusive', side_effect=interrupted):
                with self.assertRaises(OSError):
                    self.run_workflow(select_bundled_offline=True)
            evidence = (self.workflow.operation / 'stable-selection.json').read_bytes()
            self.assertFalse(source.exists())
            self.run_workflow(select_bundled_offline=True)
            self.assertEqual(self.workflow.receipt['bundledSelection']['phase'], 'selected')
            self.assertEqual((self.workflow.operation / 'stable-selection.json').read_bytes(), evidence)
            self.run_workflow(confirm_offline=True)
            self.assertEqual(self.workflow.receipt['phase'], 'awaiting-replacement')
            def changed_child(path):
                value = attributed(path)
                if Path(path) == retired / 'current.json':
                    value['com.apple.provenance'] = 'c' * 64
                return value
            with patch.object(reinstall, 'xattr_digests', side_effect=changed_child):
                with self.assertRaisesRegex(reinstall.Stop, 'selection-backup-changed'):
                    self.workflow.verify_bundled_selection()
            def changed_root_quarantine(path):
                value = attributed(path)
                if Path(path) == retired:
                    value['com.apple.quarantine'] = 'd' * 64
                return value
            with patch.object(reinstall, 'xattr_digests', side_effect=changed_root_quarantine):
                with self.assertRaisesRegex(reinstall.Stop, 'selection-backup-changed'):
                    self.workflow.verify_bundled_selection()
            os.chmod(retired, 0o750)
            with self.assertRaisesRegex(reinstall.Stop, 'selection-backup-changed'):
                self.workflow.verify_bundled_selection()

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin rename attribution')
    def test_source_provenance_drift_still_blocks_before_selection_retirement(self):
        source = self.selected_store()
        self.run_workflow(app=self.app)
        with patch.object(reinstall, 'rename_exclusive', side_effect=OSError('before rename')):
            with self.assertRaises(OSError):
                self.run_workflow(select_bundled_offline=True)
        real_xattrs = reinstall.xattr_digests
        def changed(path):
            actual = real_xattrs(path)
            if Path(path) == source:
                actual['com.apple.provenance'] = 'c' * 64
            return actual
        with patch.object(reinstall, 'xattr_digests', side_effect=changed):
            with self.assertRaisesRegex(reinstall.Stop, 'selection-source-changed'):
                self.run_workflow(select_bundled_offline=True)
        self.assertTrue(source.exists())
        self.assertFalse((self.workflow.operation / 'retired-stable-payloads').exists())

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
    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin OS copy attribution')
    def test_replacement_checks_copy_metadata_and_exact_source_attribution(self):
        real_xattrs = reinstall.xattr_digests
        source_provenance = ['a' * 64]
        def attributed(path):
            actual = real_xattrs(path)
            actual['com.apple.provenance'] = ('b' * 64 if Path(path).is_relative_to(self.workflow.store)
                                            else source_provenance[0])
            return actual
        with patch.object(reinstall, 'xattr_digests', side_effect=attributed):
            self.run_workflow(app=self.app, confirm_offline=True)
            (self.installed / 'identity').write_text('new')
            self.run_workflow(confirm_offline=True)
            self.assertEqual(self.workflow.receipt['phase'], 'awaiting-resume')
            source_provenance[0] = 'c' * 64
            with self.assertRaisesRegex(reinstall.Stop, 'source-changed'):
                self.run_workflow(confirm_offline=True)

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

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin link metadata contract')
    def test_private_copy_preserves_nondefault_link_modes_without_touching_targets(self):
        source, dest, scratch = [self.root / value for value in ('source', 'dest', 'scratch')]
        source.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
        outside = self.root / 'outside'
        outside.write_bytes(b'unchanged external target')
        outside.chmod(0o400)
        (source / 'external').symlink_to(outside)
        (source / 'dangling').symlink_to('missing')
        os.chmod(source / 'external', 0o755, follow_symlinks=False)
        os.chmod(source / 'dangling', 0o711, follow_symlinks=False)
        expected = reinstall.tree_manifest(source)
        previous = os.umask(0o077)
        try:
            reinstall.copy_tree(source, dest, expected, scratch)
        finally:
            os.umask(previous)
        self.assertEqual((dest / 'external').lstat().st_mode & 0o777, 0o755)
        self.assertEqual((dest / 'dangling').lstat().st_mode & 0o777, 0o711)
        self.assertEqual(outside.stat().st_mode & 0o777, 0o400)
        self.assertEqual(outside.read_bytes(), b'unchanged external target')
        self.assertFalse((dest / 'missing').exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin OS copy attribution')
    def test_copy_accepts_new_provenance_but_rejects_other_xattrs_and_source_drift(self):
        source, dest, scratch = [self.root / value for value in ('source', 'dest', 'scratch')]
        source.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
        (source / 'data').write_bytes(b'fixture')
        real_xattrs = reinstall.xattr_digests
        source_provenance = ['a' * 64]
        def attributed(path):
            actual = real_xattrs(path)
            actual['com.apple.provenance'] = source_provenance[0] if Path(path).is_relative_to(source) else 'b' * 64
            return actual
        with patch.object(reinstall, 'xattr_digests', side_effect=attributed):
            expected = reinstall.tree_manifest(source)
            reinstall.copy_tree(source, dest, expected, scratch)
            reinstall.copy_tree(source, dest, expected, scratch)
            self.assertEqual((dest / 'data').read_bytes(), b'fixture')
            subprocess.run(['/usr/bin/xattr', '-w', 'com.tron.fixture', 'changed', dest / 'data'], check=True)
            with self.assertRaisesRegex(reinstall.Stop, 'backup-corrupt'):
                reinstall.copy_tree(source, dest, expected, scratch)
            subprocess.run(['/usr/bin/xattr', '-d', 'com.tron.fixture', dest / 'data'], check=True)
            source_provenance[0] = 'c' * 64
            with self.assertRaisesRegex(reinstall.Stop, 'source-changed'):
                reinstall.copy_tree(source, dest, expected, scratch)

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
                      'com.tron.server.dev-takeover', 'com.tron.gateway.dev', 'com.tron.mac.native-host'):
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
