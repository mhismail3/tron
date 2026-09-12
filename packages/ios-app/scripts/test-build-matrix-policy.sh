#!/usr/bin/env bash
# Deterministic source/build-matrix and artifact metadata policy checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/project.yml"
python3 - "$ROOT" "$PROJECT" <<'PY'
from pathlib import Path
import plistlib, re, sys
root, project = map(Path, sys.argv[1:])
source = project.read_text()
configs = ["Development", "Test", "LocalDevice", "DevicePerformance", "Release"]
schemes = ["Tron Development", "Tron Device", "Tron UI Validation", "Tron Device Performance", "Tron Release"]
for config in configs:
    assert re.search(rf"^  {re.escape(config)}:", source, re.M), config
assert len(re.findall(r"^  [A-Za-z][^:]*:\n    build:", source, re.M)) == 5
for stale in ("Tron Beta", "Tron Fast", "  Beta:", "  ProdDebug:", "  DeviceTest:"):
    assert stale not in source, stale
for scheme in schemes:
    assert source.count(f"  {scheme}:\n") == 1, scheme
assert "  Tron:\n" not in source
assert '"${CONFIGURATION:-}" == "Release"' in source
assert 'TRON_GATEWAY_PROTOCOL_VERSION: "5"' in source
assert 'TRON_GATEWAY_MIN_PROTOCOL_VERSION: "5"' in source
assert 'verify-gateway-protocol-contract.py' in source
assert 'config: LocalDevice\n      debugEnabled: false' in source
# Release is the sole archive/analyze scheme. The physical-device run scheme
# also exposes an explicit Profile action, which uses optimized LocalDevice
# settings without changing the ordinary run action.
release = source[source.index("  Tron Release:"):]
assert "    archive:" in release and "config: Release" in release
assert "    run:" not in release and "    test:" not in release
for scheme in schemes[:-1]:
    block = source[source.index(f"  {scheme}:"):]
    block = block[: source.find("\n  ", source.index(f"  {scheme}:") + 3)] if source.find("\n  ", source.index(f"  {scheme}:") + 3) != -1 else block
    assert "    run:" in block and "    test:" in block, scheme
expected = {
    "Development": ("com.tron.mobile.beta", "beta", "development", "development", "NO", "DEBUG TRON_DEVELOPMENT"),
    "Test": ("com.tron.mobile.testhost", "beta", "none", "none", "NO", "DEBUG HOSTED_TEST"),
    "LocalDevice": ("com.tron.mobile", "production-sandbox", "development", "development", "YES", "TRON_PRIVATE_VARIABLE_BLUR"),
    "DevicePerformance": ("com.tron.mobile", "production-sandbox", "development", "development", "NO", "DEBUG HOSTED_TEST"),
    "Release": ("com.tron.mobile", "production", "production", "production", "NO", None),
}
for name, (bundle, route, apns, attest, blur, flags) in expected.items():
    text = (root / "Configuration" / f"{name}.xcconfig").read_text()
    assert f"PRODUCT_BUNDLE_IDENTIFIER = {bundle}" in text, name
    assert f"TRON_PUSH_ROUTE = {route}" in text, name
    assert f"TRON_APNS_ENVIRONMENT = {apns}" in text, name
    assert f"TRON_APP_ATTEST_ENVIRONMENT = {attest}" in text, name
    assert f"TRON_PRIVATE_BLUR_ENABLED = {blur}" in text, name
    if flags:
        assert f"SWIFT_ACTIVE_COMPILATION_CONDITIONS = {flags}" in text, name
    else:
        assert "SWIFT_ACTIVE_COMPILATION_CONDITIONS" not in text and "TRON_PRIVATE_VARIABLE_BLUR" not in text, name
    if name in ("LocalDevice", "Release"):
        assert "DEBUG_INFORMATION_FORMAT = dwarf-with-dsym" in text
        assert "SWIFT_OPTIMIZATION_LEVEL = -O" in text
        assert "SWIFT_COMPILATION_MODE = wholemodule" in text
        if name == "LocalDevice":
            assert "ENABLE_TESTABILITY = NO" in text
            assert "GCC_OPTIMIZATION_LEVEL = 3" in text
    if name == "LocalDevice":
        assert "TRON_PRIVATE_VARIABLE_BLUR=1" in text
        assert "#include \"Debug.xcconfig\"" not in text
    if name == "DevicePerformance":
        assert "TRON_PRIVATE_VARIABLE_BLUR" not in text
    entitlements = {
        "Development": ("TronMobileDevelopment.entitlements", "development", "development"),
        "LocalDevice": ("TronMobileLocalDevice.entitlements", "development", "development"),
        "DevicePerformance": ("TronMobileLocalDevice.entitlements", "development", "development"),
        "Release": ("TronMobileRelease.entitlements", "production", "production"),
    }.get(name)
    if entitlements:
        entitlement_text = (root / entitlements[0]).read_text()
        document = plistlib.loads(entitlement_text.encode())
        assert document.get("aps-environment") == entitlements[1], name
        assert document.get("com.apple.developer.devicecheck.appattest-environment") == entitlements[2], name
    else:
        assert 'CODE_SIGN_ENTITLEMENTS: ""' in source[source.index("        Test:", source.index("  TronMobile:")):source.index("  TronShareExtension:")], name
info_plist = (root / "Sources/Info.plist").read_text()
assert "TRON_PUSH_ROUTE" in info_plist
assert "TRONGatewayProtocolVersion" in info_plist and "TRONGatewayMinProtocolVersion" in info_plist
assert "#if BETA" not in (root / "Sources/Notifications/PushNotificationCoordinator.swift").read_text()
assert (root / "TronMobileDevelopment.entitlements").exists()
assert (root / "TronMobileLocalDevice.entitlements").exists()
assert (root / "TronMobileRelease.entitlements").exists()
for entitlement in (root / "TronMobileDevelopment.entitlements", root / "TronMobileLocalDevice.entitlements", root / "TronMobileRelease.entitlements", root / "ShareExtension" / "ShareExtensionDevelopment.entitlements", root / "ShareExtension" / "ShareExtensionProduction.entitlements"):
    assert "com.apple.security.application-groups" in entitlement.read_text(), entitlement
    assert "application-identifier" not in entitlement.read_text() and "com.apple.developer.team-identifier" not in entitlement.read_text(), entitlement
assert not any((root / "Configuration" / old).exists() for old in ("Beta.xcconfig", "ProdDebug.xcconfig", "Prod.xcconfig", "DeviceTest.xcconfig"))
print("iOS build matrix policy passed")
PY

# XcodeGen materializes default action nodes unless its post-generation
# normalization removes actions that the source scheme intentionally omits.
generated_root="$(mktemp -d "${TMPDIR:-/tmp}/tron-ios-matrix.XXXXXX")"
cleanup() { rm -rf "$generated_root"; }
trap cleanup EXIT
"$ROOT/../../scripts/generate-xcode-project" ios --spec "$PROJECT" \
  --project "$generated_root" --project-root "$ROOT" --quiet
python3 - "$generated_root/TronMobile.xcodeproj/xcshareddata/xcschemes" "$ROOT" \
  "$generated_root/TronMobile.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import json, sys
import xml.etree.ElementTree as ET

schemes = Path(sys.argv[1])
source_root = Path(sys.argv[2])
pbxproj = Path(sys.argv[3]).read_text()
for relative in ("TestPlans/UnitTests.xctestplan", "TestPlans/UIValidation.xctestplan"):
    plan = json.loads((source_root / relative).read_text())
    references = [plan["defaultOptions"]["targetForVariableExpansion"], *[entry["target"] for entry in plan["testTargets"]]]
    for reference in references:
        assert f'{reference["identifier"]} /* {reference["name"]} */' in pbxproj, (relative, reference)

expected_actions = {
    "Tron Development": ("Development", "Test", False),
    "Tron Device": ("LocalDevice", "Test", True),
    "Tron UI Validation": ("Development", "Development", False),
    "Tron Device Performance": ("DevicePerformance", "DevicePerformance", False),
}
paths = {path.stem: path for path in schemes.glob("*.xcscheme")}
assert set(paths) == set(expected_actions) | {"Tron Release"}, sorted(paths)
for name, path in paths.items():
    root = ET.parse(path).getroot()
    if name == "Tron Release":
        assert root.find("LaunchAction") is None and root.find("TestAction") is None, path
        for tag in ("ArchiveAction", "AnalyzeAction", "ProfileAction"):
            action = root.find(tag)
            assert action is not None and action.get("buildConfiguration") == "Release", path
    else:
        run = root.find("LaunchAction")
        test = root.find("TestAction")
        assert run is not None and test is not None, path
        run_config, test_config, has_profile = expected_actions[name]
        profile = root.find("ProfileAction")
        assert (profile is not None) == has_profile, path
        if profile is not None:
            assert profile.get("buildConfiguration") == "LocalDevice", path
        forbidden_actions = ("ArchiveAction", "AnalyzeAction") + (() if has_profile else ("ProfileAction",))
        assert all(root.find(tag) is None for tag in forbidden_actions), path
        assert run.get("buildConfiguration") == run_config, path
        assert test.get("buildConfiguration") == test_config, path
        if name == "Tron Device":
            assert run.get("selectedDebuggerIdentifier") == "", path
            assert run.get("selectedLauncherIdentifier") == "Xcode.IDEFoundation.Launcher.PosixSpawn", path
        plan_references = test.findall("./TestPlans/TestPlanReference")
        assert len(plan_references) == 1, path
        expected_plan = "UIValidation.xctestplan" if name == "Tron UI Validation" else "UnitTests.xctestplan"
        assert plan_references[0].get("reference", "").endswith(expected_plan), path
        assert plan_references[0].get("default") == "YES", path
print("generated iOS scheme/test-plan action policy passed")
PY

# Show the settings Xcode will actually apply to every product built by the
# physical-device scheme. Static xcconfig checks above cannot catch a changed
# inheritance chain, so keep this as a cheap no-compile policy check.
effective_settings="$generated_root/local-device-settings.txt"
xcodebuild -showBuildSettings \
  -project "$generated_root/TronMobile.xcodeproj" \
  -scheme "Tron Device" -configuration LocalDevice >"$effective_settings" 2>&1
python3 - "$effective_settings" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
required = {
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "GCC_OPTIMIZATION_LEVEL": "3",
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_TESTABILITY": "NO",
    "ONLY_ACTIVE_ARCH": "NO",
    "COPY_PHASE_STRIP": "NO",
}
blocks = re.split(r"(?=Build settings for action build and target )", text)
seen = set()
for block in blocks:
    match = re.search(r"Build settings for action build and target ([^:]+):", block)
    if not match:
        continue
    target = match.group(1)
    if target not in {"TronMobile", "TronShareExtension"}:
        continue
    seen.add(target)
    for key, value in required.items():
        assert re.search(rf"^    {re.escape(key)} = {re.escape(value)}$", block, re.M), (target, key)
    assert re.search(r"^    SWIFT_ACTIVE_COMPILATION_CONDITIONS = TRON_PRIVATE_VARIABLE_BLUR$", block, re.M), target
assert seen == {"TronMobile", "TronShareExtension"}, seen
print("effective LocalDevice app and extension settings policy passed")
PY
