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
assert 'TRON_GATEWAY_PROTOCOL_VERSION: "4"' in source
assert 'TRON_GATEWAY_MIN_PROTOCOL_VERSION: "4"' in source
assert 'verify-gateway-protocol-contract.py' in source
# Release is the sole archive/analyze/profile scheme and has no run/test action.
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
    "LocalDevice": ("com.tron.mobile", "production-sandbox", "development", "development", "YES", "DEBUG TRON_PRIVATE_VARIABLE_BLUR"),
    "DevicePerformance": ("com.tron.mobile", "production-sandbox", "development", "development", "NO", "DEBUG HOSTED_TEST"),
    "Release": ("com.tron.mobile", "production", "production", "production", "NO", None),
}
expected_actions = {
    "Tron Development": ("Development", "Test"),
    "Tron Device": ("LocalDevice", "Test"),
    "Tron UI Validation": ("Development", "Development"),
    "Tron Device Performance": ("DevicePerformance", "DevicePerformance"),
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
    if name == "Release":
        assert "SWIFT_OPTIMIZATION_LEVEL = -O" in text and "ENABLE_NS_ASSERTIONS = NO" in text
    if name == "LocalDevice":
        assert "TRON_PRIVATE_VARIABLE_BLUR=1" in text
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
PATH="$ROOT/../../.ci-tools/bin:/opt/homebrew/bin:$PATH" xcodegen generate --spec "$PROJECT" \
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
    "Tron Development": ("Development", "Test"),
    "Tron Device": ("LocalDevice", "Test"),
    "Tron UI Validation": ("Development", "Development"),
    "Tron Device Performance": ("DevicePerformance", "DevicePerformance"),
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
        assert all(root.find(tag) is None for tag in ("ArchiveAction", "AnalyzeAction", "ProfileAction")), path
        run_config, test_config = expected_actions[name]
        assert run.get("buildConfiguration") == run_config, path
        assert test.get("buildConfiguration") == test_config, path
        plan_references = test.findall("./TestPlans/TestPlanReference")
        assert len(plan_references) == 1, path
        expected_plan = "UIValidation.xctestplan" if name == "Tron UI Validation" else "UnitTests.xctestplan"
        assert plan_references[0].get("reference", "").endswith(expected_plan), path
        assert plan_references[0].get("default") == "YES", path
print("generated iOS scheme/test-plan action policy passed")
PY
