#!/usr/bin/env python3
"""Failure modes: wrong iOS owners omit coverage; unmapped or deleted inputs select zero tests."""
import unittest
from pathlib import Path

from ios_verify_test_selection import selectors_for, test_command


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
