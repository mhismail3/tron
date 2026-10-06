#!/usr/bin/env python3
"""Choose only audited iOS test owners; an unknown input runs the full unit target."""
from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
TEST_TARGET = "TronMobileTests"
# Fixture-owned suites run through the harness that owns their fixture, never
# through the ordinary hosted runner, where every case would correctly skip for
# a missing fixture. Each value is that harness's own command for the suite.
FIXTURE_ONLY_TESTS = {
    "packages/ios-app/Tests/Gateway/RealGatewayPiBoundaryTests.swift": ("scripts/ios-gateway-e2e-test", "all"),
    "packages/ios-app/UITests/RealGateway/RealGatewayPairAndChatUITests.swift": ("scripts/ios-gateway-e2e-test", "run-ui"),
}
# Focus only sources with an audited owner. Other Settings files remain full-suite
# until their test ownership has been established.
SETTINGS_SOURCE_PREFIX = "packages/ios-app/Sources/UI/Settings/"
SETTINGS_SOURCE_OWNERS = {
    "SettingsView.swift": ["SettingsLayoutStyleTests", "SettingsRouteIdentityTests"],
    "AppLocalBehaviorSettings.swift": ["AppLocalBehaviorSettingsTests"],
    "AppLocalBehaviorSettingsView.swift": ["AppLocalBehaviorSettingsTests"],
    "SettingsAutosave.swift": ["ConfigurationAutosaveTests"],
    "HooksSettingsView.swift": [
        "HooksSettingsPresentationTests",
        "HookInventoryPresentationTests",
        "SettingsLayoutStyleTests",
    ],
    "BuiltinExtensionsSettingsSection.swift": ["BuiltinExtensionsSettingsTests"],
    "ProjectResourceTitlePresentation.swift": ["ProjectResourceTitlePresentationTests"],
    "ProviderUsagePresentation.swift": ["ProviderUsagePresentationTests"],
    "ProviderUsageReadController.swift": ["ProviderUsageReadControllerTests"],
}
_PRIVATE_MODIFIERS = {"private", "fileprivate"}
_TOP_LEVEL_DECLARATION = re.compile(
    r"^(?P<modifiers>(?:(?:private|fileprivate|internal|public|open|final|indirect|"
    r"nonisolated|distributed)\s+)*)"
    r"(?P<kind>struct|class|enum|actor|protocol|extension|typealias|func|let|var)\s+"
    r"(?P<name>[A-Za-z_]\w*)"
)
_ATTRIBUTE_PREFIX = re.compile(r"^(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s+)+")


def _relative(path: str) -> Optional[str]:
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    try:
        return candidate.resolve(strict=False).relative_to(ROOT).as_posix()
    except ValueError:
        return None


def _top_level_declarations(source: str) -> Optional[list[dict[str, object]]]:
    """Read the file-scope declarations conservatively; unknown syntax disables focus."""
    declarations: list[dict[str, object]] = []
    pending_suite = False
    offset = 0
    for line in source.splitlines(keepends=True):
        line_start = offset
        offset += len(line)
        if not line.strip() or line[0].isspace():
            continue
        stripped = line.rstrip("\r\n")
        if stripped.startswith(("//", "/*", "*", "*/")):
            continue
        if stripped.startswith("#"):
            return None
        if stripped.startswith("@"):
            pending_suite = pending_suite or bool(re.search(r"@Suite\b", stripped))
            without_attributes = _ATTRIBUTE_PREFIX.sub("", stripped)
            if not without_attributes or re.fullmatch(r"(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s*)+", stripped):
                continue
            stripped = without_attributes
        if stripped.startswith("import "):
            continue
        match = _TOP_LEVEL_DECLARATION.match(stripped)
        if not match:
            if stripped in ("}", ")"):
                continue
            return None
        modifiers = set(match.group("modifiers").split())
        private = bool(modifiers & _PRIVATE_MODIFIERS)
        declarations.append({
            "start": line_start,
            "end_of_line": offset,
            "kind": match.group("kind"),
            "name": match.group("name"),
            "signature": stripped,
            "private": private,
            "suite_attribute": pending_suite or "@Suite" in line,
        })
        pending_suite = False
    return declarations


def _test_file_owners(relative: str) -> Optional[list[str]]:
    if not relative.startswith("packages/ios-app/Tests/") or not relative.endswith(".swift"):
        return None
    path = ROOT / relative
    if not path.is_file():
        return None
    try:
        source = path.read_text(errors="replace")
    except OSError:
        return None
    declarations = _top_level_declarations(source)
    if not declarations:
        return None

    owners = []
    for index, declaration in enumerate(declarations):
        if declaration["private"]:
            continue
        start = int(declaration["start"])
        end = int(declarations[index + 1]["start"]) if index + 1 < len(declarations) else len(source)
        suite_body = source[int(declaration["end_of_line"]):end]
        kind = str(declaration["kind"])
        name = str(declaration["name"])
        is_type = kind in {"struct", "class", "enum", "actor"}
        has_swift_tests = "@Test" in suite_body
        has_xctest_tests = (
            kind == "class"
            and "XCTestCase" in str(declaration["signature"])
            and re.search(r"\bfunc\s+test\w*\s*\(", suite_body) is not None
        )
        is_suite = is_type and (
            ((bool(declaration["suite_attribute"]) or name.endswith("Tests")) and has_swift_tests)
            or has_xctest_tests
        )
        if not is_suite:
            # Top-level helpers can be imported or referenced by suites in other files.
            return None
        if _referenced_by_other_test_file(name, path):
            return None
        owners.append(name)
    return sorted(set(owners)) if owners else None


def _referenced_by_other_test_file(suite: str, defining_file: Path) -> bool:
    pattern = re.compile(rf"\b{re.escape(suite)}\s*\.")
    for candidate in (ROOT / "packages/ios-app/Tests").rglob("*.swift"):
        if candidate == defining_file:
            continue
        try:
            if pattern.search(candidate.read_text(errors="replace")):
                return True
        except OSError:
            return True
    return False


def selectors_for(paths: list[str], *, has_deletions: bool = False) -> Optional[list[str]]:
    """Return Xcode owners, or None when any input cannot be proven covered."""
    if not paths or has_deletions:
        return None
    owners: set[str] = set()
    for raw_path in paths:
        relative = _relative(raw_path)
        if relative is None:
            return None
        if relative.startswith(SETTINGS_SOURCE_PREFIX) and relative.endswith(".swift"):
            source_owners = SETTINGS_SOURCE_OWNERS.get(Path(relative).name)
            if source_owners is None:
                return None
            owners.update(source_owners)
            continue
        test_owners = _test_file_owners(relative)
        if test_owners is None:
            return None
        owners.update(test_owners)
    return [f"{TEST_TARGET}/{owner}" for owner in sorted(owners)] if owners else None


def _has_deletions(merge_base: str) -> bool:
    try:
        changed = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "--diff-filter=D", "-z", merge_base, "HEAD"],
            cwd=ROOT,
            capture_output=True,
            check=False,
        )
    except OSError:
        return True
    return changed.returncode != 0 or bool(changed.stdout)


def test_commands(paths: list[str], *, has_deletions: bool = False) -> list[list[str]]:
    """Dispatch fixture-owned integration suites to their real fixture runner."""
    fixture_commands: list[list[str]] = []
    ordinary_paths = []
    for raw_path in paths:
        relative = _relative(raw_path)
        owned = FIXTURE_ONLY_TESTS.get(relative or "")
        if owned is None:
            ordinary_paths.append(raw_path)
        elif list(owned) not in fixture_commands:
            fixture_commands.append(list(owned))

    commands: list[list[str]] = []
    if ordinary_paths or has_deletions:
        selectors = selectors_for(ordinary_paths, has_deletions=has_deletions)
        command = ["scripts/tron-ios-test", "run"]
        if selectors is not None:
            for selector in selectors:
                command.extend(["--only-testing", selector])
        commands.append(command)
    commands.extend(fixture_commands)
    if not commands:
        commands.append(["scripts/tron-ios-test", "run"])
    return commands


def fixture_runners() -> set[str]:
    return {runner for runner, _ in FIXTURE_ONLY_TESTS.values()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--merge-base", required=True)
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    commands = test_commands(args.paths, has_deletions=_has_deletions(args.merge_base))
    fixture_runner_started = False
    result_code = 0
    try:
        for command in commands:
            fixture_runner_started |= command[0] in fixture_runners()
            result = subprocess.run(command, cwd=ROOT, check=False)
            if result.returncode:
                result_code = result.returncode
                break
    finally:
        if fixture_runner_started:
            cleanup = subprocess.run(
                ["scripts/ios-gateway-e2e-test", "stop"], cwd=ROOT, check=False,
            )
            if result_code == 0:
                result_code = cleanup.returncode
    return result_code


if __name__ == "__main__":
    raise SystemExit(main())
