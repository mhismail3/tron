#!/usr/bin/env python3
"""Failure modes: wrong iOS owners omit coverage; unmapped or deleted inputs select zero tests."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ios_verify_test_selection import _has_deletions, selectors_for, test_command


class IOSVerifyTestSelectionTests(unittest.TestCase):
    def test_settings_view_selects_its_test_owners(self):
        selectors = selectors_for(["packages/ios-app/Sources/UI/Settings/SettingsView.swift"])
        self.assertEqual(
            selectors,
            [
                "TronMobileTests/SettingsLayoutStyleTests",
                "TronMobileTests/SettingsRouteIdentityTests",
            ],
        )

    def test_changed_test_file_selects_its_declared_suite(self):
        relative = "packages/ios-app/Tests/UI/SettingsLayoutStyleTests.swift"
        selectors = selectors_for([relative])
        self.assertEqual(selectors, ["TronMobileTests/SettingsLayoutStyleTests"])
        self.assertEqual(selectors_for([str(Path(__file__).resolve().parents[1] / relative)]), selectors)

    def test_source_mappings_include_the_actual_test_owners(self):
        self.assertEqual(
            selectors_for(["packages/ios-app/Sources/UI/Settings/SettingsAutosave.swift"]),
            ["TronMobileTests/ConfigurationAutosaveTests"],
        )
        self.assertEqual(
            selectors_for(["packages/ios-app/Sources/UI/Settings/HooksSettingsView.swift"]),
            [
                "TronMobileTests/HookInventoryPresentationTests",
                "TronMobileTests/HooksSettingsPresentationTests",
                "TronMobileTests/SettingsLayoutStyleTests",
            ],
        )

    def test_shared_top_level_helpers_force_full_suite(self):
        for relative in (
            "packages/ios-app/Tests/Gateway/BoundedHTTPDataTransportTests.swift",
            "packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift",
            "packages/ios-app/Tests/Profiling/ProfileChatScenarioTests.swift",
        ):
            with self.subTest(relative=relative):
                self.assertIsNone(selectors_for([relative]))

    def test_deletion_between_merge_base_and_head_forces_full_suite(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.invalid"], check=True)
            (repo / "SettingsView.swift").write_text("struct SettingsView {}\n")
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            merge_base = subprocess.run(
                ["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True,
            ).stdout.strip()
            (repo / "SettingsView.swift").unlink()
            (repo / "changed.swift").write_text("struct Changed {}\n")
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "delete and edit"], check=True)
            with patch("ios_verify_test_selection.ROOT", repo):
                self.assertTrue(_has_deletions(merge_base))
                self.assertEqual(
                    test_command(["packages/ios-app/Sources/UI/Settings/SettingsView.swift"], has_deletions=True),
                    ["scripts/tron-ios-test", "run"],
                )

    def test_unmapped_deleted_empty_and_non_ios_paths_fail_closed(self):
        self.assertIsNone(selectors_for(["packages/ios-app/Sources/NewArea/UnknownView.swift"]))
        self.assertIsNone(selectors_for(["packages/ios-app/Sources/UI/Settings/AppearanceSettingsView.swift"]))
        self.assertIsNone(selectors_for(["packages/ios-app/Tests/UI/DeletedTests.swift"]))
        self.assertIsNone(selectors_for([]))
        self.assertIsNone(selectors_for(["packages/protocol-fixtures/example.json"]))
        self.assertEqual(
            test_command(["packages/ios-app/Sources/NewArea/UnknownView.swift"]),
            ["scripts/tron-ios-test", "run"],
        )


if __name__ == "__main__":
    unittest.main()
