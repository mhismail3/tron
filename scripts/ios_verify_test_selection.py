#!/usr/bin/env python3
"""Choose only audited iOS test owners; an unknown input runs the full unit target."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
TEST_TARGET = "TronMobileTests"
# Focus only sources with an audited owner. Other Settings files remain full-suite
# until their test ownership has been established.
SETTINGS_SOURCE_PREFIX = "packages/ios-app/Sources/UI/Settings/"
SETTINGS_SOURCE_OWNERS = {
    "SettingsView.swift": ["SettingsLayoutStyleTests", "SettingsRouteIdentityTests"],
    "AppLocalBehaviorSettings.swift": ["AppLocalBehaviorSettingsTests"],
    "AppLocalBehaviorSettingsView.swift": ["AppLocalBehaviorSettingsTests"],
    "SettingsAutosave.swift": ["SettingsDraftStoreTests"],
    "HooksSettingsView.swift": ["HooksSettingsPresentationTests", "HookInventoryPresentationTests"],
    "BuiltinExtensionsSettingsSection.swift": ["BuiltinExtensionsSettingsTests"],
    "ProjectResourceTitlePresentation.swift": ["ProjectResourceTitlePresentationTests"],
    "ProviderUsagePresentation.swift": ["ProviderUsagePresentationTests"],
    "ProviderUsageReadController.swift": ["ProviderUsageReadControllerTests"],
}
_SUITE_DECLARATION = re.compile(r"\b(?:struct|class)\s+(\w+Tests?)\b")


def _relative(path: str) -> Optional[str]:
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    try:
        return candidate.resolve(strict=False).relative_to(ROOT).as_posix()
    except ValueError:
        return None


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
    suites = sorted(set(_SUITE_DECLARATION.findall(source)))
    return suites or None


def selectors_for(paths: list[str]) -> Optional[list[str]]:
    """Return Xcode owners, or None when every changed path cannot be proven covered."""
    if not paths:
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


def test_command(paths: list[str]) -> list[str]:
    selectors = selectors_for(paths)
    command = ["scripts/tron-ios-test", "run"]
    if selectors is not None:
        for selector in selectors:
            command.extend(["--only-testing", selector])
    return command


def main() -> int:
    return subprocess.run(test_command(sys.argv[1:]), cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
