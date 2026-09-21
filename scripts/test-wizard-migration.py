#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("tron_wizard_migration", ROOT / "tron_wizard_migration.py")
MIGRATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIGRATION)


class WizardMigrationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="tron-wizard-migration-"))
        os.chmod(self.root, 0o700)
        self.home = self.root / ".tron"
        self.home.mkdir(mode=0o700)
        self.staging = self.root / "stage"
        self.staging_parent = self.root

    def tearDown(self):
        for path in sorted(self.root.rglob("*"), reverse=True):
            if path.is_file() or path.is_symlink():
                path.unlink()
            elif path.is_dir():
                path.rmdir()
        self.root.rmdir()

    @staticmethod
    def defaults_fixture(argv):
        return 0, "install\n", ""

    def test_stage_uses_only_exact_owned_defaults_key_and_publishes_record(self):
        seen = []

        def runner(argv):
            seen.append(argv)
            return self.defaults_fixture(argv)

        result = MIGRATION.stage("stable", self.home, self.staging, runner=runner)
        self.assertEqual(seen, [["/usr/bin/defaults", "read", "com.tron.mac", "tron.mac.wizardStep"]])
        self.assertEqual(json.loads((self.staging / "wizard-state.json").read_text()), {"step": "install", "version": 1})
        self.assertEqual(MIGRATION.verify(self.staging)["verified"], True)
        MIGRATION.publish(self.staging, runner=self.defaults_fixture)
        self.assertEqual(json.loads((self.home / "internal/mac/wizard-state.json").read_text()), {"step": "install", "version": 1})
        self.assertEqual(MIGRATION.load_journal(self.staging)["phase"], "published")

    def test_debug_domain_and_invalid_step_are_explicit(self):
        seen = []

        def runner(argv):
            seen.append(argv)
            return 0, "pairingInfo\n", ""

        MIGRATION.stage("debug", self.home, self.staging, runner=runner)
        self.assertEqual(seen[0][2], "com.tron.mac.dev")
        self.assertEqual(json.loads((self.staging / "wizard-state.json").read_text())["step"], "pairingInfo")

        other = self.root / "bad-stage"
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.stage("stable", self.home, other, runner=lambda _: (0, "not-a-step\n", ""))

    def test_conflict_newer_malformed_and_symlink_fail_closed(self):
        destination = self.home / "internal/mac/wizard-state.json"
        destination.parent.mkdir(parents=True, mode=0o700)
        destination.write_text('{"version":99,"step":"install"}\n')
        os.chmod(destination, 0o600)
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.stage("stable", self.home, self.staging, runner=self.defaults_fixture)

        destination.unlink()
        destination.symlink_to(self.root / "elsewhere")
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.stage("stable", self.home, self.root / "symlink-stage", runner=self.defaults_fixture)

    def test_publish_rechecks_source_and_staged_mutation(self):
        MIGRATION.stage("stable", self.home, self.staging, runner=self.defaults_fixture)
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.publish(self.staging, runner=lambda _: (0, "tailscale\n", ""))
        (self.staging / "wizard-state.json").write_text('{"step":"welcome","version":1}\n')
        os.chmod(self.staging / "wizard-state.json", 0o600)
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.publish(self.staging, runner=self.defaults_fixture)

    def test_interrupted_publication_recovers_without_shared_inode(self):
        MIGRATION.stage("stable", self.home, self.staging, runner=self.defaults_fixture)
        original_atomic_replace = MIGRATION.atomic_replace

        def crash_before_journal(path, data):
            if b'"phase":"published"' in data:
                raise RuntimeError("synthetic crash after destination creation")
            return original_atomic_replace(path, data)

        with patch.object(MIGRATION, "atomic_replace", side_effect=crash_before_journal):
            with self.assertRaises(RuntimeError):
                MIGRATION.publish(self.staging, runner=self.defaults_fixture)
        destination = self.home / "internal/mac/wizard-state.json"
        self.assertTrue(destination.exists())
        self.assertNotEqual(destination.stat().st_ino, (self.staging / "wizard-state.json").stat().st_ino)
        result = MIGRATION.recover(self.staging, runner=self.defaults_fixture)
        self.assertTrue(result["published"])
        self.assertEqual(MIGRATION.load_journal(self.staging)["phase"], "published")

    def test_redirected_journal_and_missing_stage_fail_closed(self):
        MIGRATION.stage("stable", self.home, self.staging, runner=self.defaults_fixture)
        journal_path = self.staging / "migration.json"
        journal = json.loads(journal_path.read_text())
        journal["destination"] = str(self.root / "redirected.json")
        journal_path.write_text(json.dumps(journal))
        os.chmod(journal_path, 0o600)
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.verify(self.staging)
        journal["destination"] = str(self.home / "internal/mac/wizard-state.json")
        journal_path.write_text(json.dumps(journal))
        os.chmod(journal_path, 0o600)
        (self.staging / "wizard-state.json").unlink()
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.verify(self.staging)

    def test_onboarded_marker_is_evidence_and_never_changed(self):
        marker = self.home / "internal/run/.onboarded"
        marker.parent.mkdir(parents=True, mode=0o700)
        os.chmod(marker.parent.parent, 0o700)
        os.chmod(marker.parent, 0o700)
        marker.write_bytes(b"done")
        os.chmod(marker, 0o644)
        before_stat = marker.stat()
        before = marker.read_bytes()
        result = MIGRATION.stage("stable", self.home, self.staging, runner=self.defaults_fixture)
        self.assertTrue(result["onboarded"])
        MIGRATION.publish(self.staging, runner=self.defaults_fixture)
        self.assertEqual(marker.read_bytes(), before)
        after_stat = marker.stat()
        for field in ("st_ino", "st_mode", "st_uid", "st_gid", "st_mtime_ns", "st_ctime_ns"):
            self.assertEqual(getattr(after_stat, field), getattr(before_stat, field))

    def test_shared_writable_onboarded_marker_and_readable_state_are_refused(self):
        marker = self.home / "internal/run/.onboarded"
        marker.parent.mkdir(parents=True, mode=0o700)
        os.chmod(marker.parent.parent, 0o700)
        marker.write_bytes(b"done")
        os.chmod(marker, 0o664)
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.stage("stable", self.home, self.staging, runner=self.defaults_fixture)
        state = self.root / "wizard-state.json"
        state.write_bytes(MIGRATION.record_bytes("install"))
        os.chmod(state, 0o644)
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.read_record(state)

    def test_cleanup_refuses_published_rollback_evidence(self):
        MIGRATION.stage("stable", self.home, self.staging, runner=self.defaults_fixture)
        MIGRATION.publish(self.staging, runner=self.defaults_fixture)
        with self.assertRaises(MIGRATION.MigrationError):
            MIGRATION.cleanup(self.staging)


if __name__ == "__main__":
    unittest.main(verbosity=2)
