#!/usr/bin/env python3
"""Failure modes: wrong iOS owners omit coverage; unmapped or deleted inputs select zero tests."""
import json
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from ios_verify_test_selection import _has_deletions, selectors_for, test_commands


class IOSVerifyTestSelectionTests(unittest.TestCase):
    def test_fixture_suite_dispatch_runs_owned_runner_and_propagates_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            fixture_test = root / "packages/ios-app/Tests/Gateway/RealGatewayPiBoundaryTests.swift"
            fixture_test.parent.mkdir(parents=True)
            source = Path(__file__).resolve().parents[1] / "packages/ios-app/Tests/Gateway/RealGatewayPiBoundaryTests.swift"
            fixture_test.write_text(source.read_text())
            runner = root / "scripts/ios-gateway-e2e-test"
            runner.parent.mkdir(parents=True)
            runner.write_text(
                "#!/usr/bin/env python3\n"
                "import json, pathlib, sys\n"
                "path = 'fixture-run.json' if sys.argv[1] == 'all' else 'fixture-stopped.json'\n"
                "pathlib.Path(path).write_text(json.dumps(sys.argv[1:]))\n"
                "raise SystemExit(23 if sys.argv[1] == 'all' else 0)\n"
            )
            runner.chmod(0o755)
            import ios_verify_test_selection

            arguments = [
                "--merge-base", "unused-in-test", "packages/ios-app/Tests/Gateway/RealGatewayPiBoundaryTests.swift"
            ]
            with patch("ios_verify_test_selection.ROOT", root), patch(
                "ios_verify_test_selection._has_deletions", return_value=False
            ), patch("sys.argv", ["ios_verify_test_selection.py", *arguments]):
                self.assertEqual(ios_verify_test_selection.main(), 23)
            self.assertEqual(json.loads((root / "fixture-run.json").read_text()), ["all"])
            self.assertTrue((root / "fixture-stopped.json").exists())

    def test_fault_proxy_change_runs_the_real_boundary_fixture(self):
        # The proxy shapes every boundary case's traffic; a unit run skips them all.
        self.assertEqual(
            test_commands(["scripts/ios-gateway-fault-proxy.mjs"]),
            [["scripts/ios-gateway-e2e-test", "all"]],
        )

    def test_ordinary_suite_still_uses_unit_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            suite = root / "packages/ios-app/Tests/Gateway/FixtureOwnerTests.swift"
            suite.parent.mkdir(parents=True)
            suite.write_text("class FixtureOwnerTests: XCTestCase {\n    func testOne() {}\n}\n")
            runner = root / "scripts/tron-ios-test"
            runner.parent.mkdir(parents=True)
            runner.write_text(
                "#!/usr/bin/env python3\n"
                "import json, pathlib, sys\n"
                "pathlib.Path('unit-run.json').write_text(json.dumps(sys.argv[1:]))\n"
            )
            runner.chmod(0o755)
            import ios_verify_test_selection

            arguments = ["--merge-base", "unused-in-test", "packages/ios-app/Tests/Gateway/FixtureOwnerTests.swift"]
            with patch("ios_verify_test_selection.ROOT", root), patch(
                "ios_verify_test_selection._has_deletions", return_value=False
            ), patch("sys.argv", ["ios_verify_test_selection.py", *arguments]):
                self.assertEqual(ios_verify_test_selection.main(), 0)
            self.assertEqual(
                json.loads((root / "unit-run.json").read_text()),
                ["run", "--only-testing", "TronMobileTests/FixtureOwnerTests"],
            )
            self.assertFalse((root / "fixture-run.json").exists())

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

    def test_external_nested_suite_reference_forces_full_suite(self):
        relative = "packages/ios-app/Tests/Gateway/SessionHistoryStoreTests.swift"
        self.assertIsNone(selectors_for([relative]))

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
                    test_commands(
                        ["packages/ios-app/Sources/UI/Settings/SettingsView.swift"],
                        has_deletions=_has_deletions(merge_base),
                    ),
                    [["scripts/tron-ios-test", "run"]],
                )

    def test_work_json_ios_command_runs_the_script_entry_point(self):
        root = Path(__file__).resolve().parents[1]
        config = json.loads((root / ".github/work.json").read_text())
        ios_check = next(check for check in config["verify"]["checks"] if check["name"] == "ios")
        script_part = next(
            part.strip() for part in ios_check["command"].split("&&")
            if "python3 scripts/ios_verify_test_selection.py" in part
        )
        script_command = script_part[script_part.index("python3 scripts/ios_verify_test_selection.py"):]
        invocation = shlex.split(script_command)
        self.assertEqual(invocation[:2], ["python3", "scripts/ios_verify_test_selection.py"])
        relative = "packages/ios-app/Sources/UI/Settings/SettingsAutosave.swift"
        merge_base = subprocess.run(
            ["git", "-C", str(root), "merge-base", "HEAD", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        invocation = [
            item.replace("{merge_base}", merge_base).replace("{paths}", relative)
            for item in invocation[2:]
        ]
        import ios_verify_test_selection

        original_run = subprocess.run
        executed = []

        def run(command, **kwargs):
            if command[0] == "scripts/tron-ios-test":
                executed.append(command)
                return SimpleNamespace(returncode=0)
            return original_run(command, **kwargs)

        with patch("sys.argv", ["ios_verify_test_selection.py", *invocation]), patch(
            "ios_verify_test_selection.subprocess.run", side_effect=run
        ):
            self.assertEqual(ios_verify_test_selection.main(), 0)
        self.assertEqual(
            executed,
            [["scripts/tron-ios-test", "run", "--only-testing", "TronMobileTests/ConfigurationAutosaveTests"]],
        )

    def test_unmapped_deleted_empty_and_non_ios_paths_fail_closed(self):
        self.assertIsNone(selectors_for(["packages/ios-app/Sources/NewArea/UnknownView.swift"]))
        self.assertIsNone(selectors_for(["packages/ios-app/Sources/UI/Settings/AppearanceSettingsView.swift"]))
        self.assertIsNone(selectors_for(["packages/ios-app/Tests/UI/DeletedTests.swift"]))
        self.assertIsNone(selectors_for([]))
        self.assertIsNone(selectors_for(["packages/protocol-fixtures/example.json"]))
        self.assertEqual(
            test_commands(["packages/ios-app/Sources/NewArea/UnknownView.swift"]),
            [["scripts/tron-ios-test", "run"]],
        )


if __name__ == "__main__":
    unittest.main()
