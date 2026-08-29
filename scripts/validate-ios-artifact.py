#!/usr/bin/env python3
"""Validate the metadata and signing boundary of a Tron iOS .app artifact."""
from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

EXPECTED = {
    "Development": ("development", "beta", "com.tron.mobile.beta", "com.tron.mobile.beta.ShareExtension", "development", "development", "NO"),
    "Test": ("hosted-test", "beta", "com.tron.mobile.testhost", "com.tron.mobile.testhost.ShareExtension", "none", "none", "NO"),
    "LocalDevice": ("local-device", "production-sandbox", "com.tron.mobile", "com.tron.mobile.ShareExtension", "development", "development", "YES"),
    "DevicePerformance": ("device-performance", "production-sandbox", "com.tron.mobile", "com.tron.mobile.ShareExtension", "development", "development", "NO"),
    "Release": ("release", "production", "com.tron.mobile", "com.tron.mobile.ShareExtension", "production", "production", "NO"),
}
CANONICAL_TEAM_ID = "MYGKXH6TY4"


def fail(message: str) -> None:
    print(f"ios artifact validation: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_plist(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        fail(f"cannot read plist {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"plist is not a dictionary: {path}")
    return value


def signed_output(app: Path, require_profile: bool) -> dict:
    signature = app / "_CodeSignature" / "CodeResources"
    if not signature.exists():
        fail(f"unsigned artifact (missing {signature})")
    try:
        verification = subprocess.run(
            ["codesign", "--verify", "--strict", "--verbose=2", str(app)],
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        fail(f"cannot verify code signature: {exc}")
    if verification.returncode != 0:
        fail(f"cryptographic signature verification failed for {app}: {verification.stderr.strip()}")
    try:
        result = subprocess.run(["codesign", "-dvv", str(app)], text=True, capture_output=True, check=False)
    except OSError as exc:
        fail(f"cannot inspect code signature: {exc}")
    details = result.stdout + result.stderr
    if result.returncode != 0:
        fail(f"codesign rejected {app}")
    entitlements = {}
    entitlement_result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], text=False, capture_output=True, check=False)
    blob = entitlement_result.stdout + entitlement_result.stderr
    start, end = blob.find(b"<?xml"), blob.find(b"</plist>")
    if start >= 0 and end >= start:
        try:
            entitlements = plistlib.loads(blob[start : end + len(b"</plist>")])
        except plistlib.InvalidFileException:
            fail(f"invalid embedded entitlements in {app}")
    profile = app / "embedded.mobileprovision"
    profile_data = {}
    profile_entitlements = {}
    if require_profile and not profile.exists():
        fail(f"signed artifact has no embedded provisioning profile: {app}")
    if profile.exists():
        try:
            cms = subprocess.run(["security", "cms", "-D", "-i", str(profile)], capture_output=True, check=False)
            raw = cms.stdout
            start, end = raw.find(b"<?xml"), raw.find(b"</plist>")
            if cms.returncode != 0 or start < 0 or end < start:
                if require_profile:
                    fail(f"cannot decode provisioning profile: {profile}")
            else:
                profile_data = plistlib.loads(raw[start : end + len(b"</plist>")])
                profile_entitlements = profile_data.get("Entitlements", {})
                if not isinstance(profile_entitlements, dict):
                    fail(f"provisioning profile has invalid entitlements: {profile}")
        except OSError:
            if require_profile:
                fail("security tool is required to inspect the provisioning profile")
    identifier_match = re.search(r"(?:^|\n)Identifier=([^\n]+)", details)
    return {
        "details": details,
        "identifier": identifier_match.group(1) if identifier_match else None,
        "entitlements": entitlements,
        "profile": profile,
        "profile_data": profile_data,
        "profile_entitlements": profile_entitlements,
    }


def check_entitlements(label: str, signing: dict, expected_apns: str | None, expected_attest: str | None, config: str, expected_identifier: str | None) -> None:
    entitlements = signing["entitlements"]
    if not entitlements:
        if config == "Test":
            return
        fail(f"{label} has no inspectable signed entitlements")
    expected_keys = {
        "aps-environment": expected_apns,
        "com.apple.developer.devicecheck.appattest-environment": expected_attest,
    }
    for key, expected in expected_keys.items():
        if expected is None:
            continue
        actual = entitlements.get(key)
        if expected == "none":
            if actual is not None:
                fail(f"{label} must not carry {key}")
        elif actual != expected:
            fail(f"{label} {key}={actual!r}, expected {expected!r}")
    if entitlements.get("com.apple.security.application-groups") != ["group.com.tron.shared"]:
        fail(f"{label} has unexpected application groups")
    identifier = entitlements.get("application-identifier")
    team = entitlements.get("com.apple.developer.team-identifier")
    if expected_identifier and (not identifier or not str(identifier).endswith("." + expected_identifier)):
        fail(f"{label} application identifier does not end in {expected_identifier}: {identifier}")
    if team and not re.fullmatch(r"[A-Za-z0-9]{10}", str(team)):
        fail(f"{label} has malformed team identifier")
    if team != CANONICAL_TEAM_ID:
        fail(f"{label} team identifier {team!r} does not match the canonical team")
    get_task = entitlements.get("get-task-allow")
    if config == "Release" and get_task is True:
        fail("Release artifact must not allow get-task-allow")
    if config not in {"Release", "Test"} and get_task is not True:
        fail(f"{config} artifact must allow get-task-allow for development signing")
    if config not in {"Release", "Test"} and signing["profile_data"] and not isinstance(signing["profile_data"].get("ProvisionedDevices"), list):
        fail(f"{config} artifact does not carry a development provisioning profile")
    if config == "Release" and signing["profile_data"] and signing["profile_data"].get("ProvisionedDevices") is not None:
        fail("Release artifact carries a device provisioning profile")


def check_profile(label: str, signing: dict, expected_apns: str | None, config: str, expected_identifier: str) -> None:
    if not signing["profile_data"]:
        return
    entitlements = signing["profile_entitlements"]
    if not entitlements:
        fail(f"{label} provisioning profile has no entitlements")
    application_identifier = entitlements.get("application-identifier")
    if not application_identifier or not str(application_identifier).endswith("." + expected_identifier):
        fail(f"{label} provisioning profile application identifier does not end in {expected_identifier}: {application_identifier}")
    team = entitlements.get("com.apple.developer.team-identifier")
    if team != CANONICAL_TEAM_ID:
        fail(f"{label} provisioning profile team identifier {team!r} does not match the canonical team")
    if entitlements.get("com.apple.security.application-groups") != ["group.com.tron.shared"]:
        fail(f"{label} provisioning profile has unexpected application groups")
    if expected_apns and expected_apns != "none" and entitlements.get("aps-environment") != expected_apns:
        fail(f"{label} provisioning profile aps-environment={entitlements.get('aps-environment')!r}, expected {expected_apns!r}")
    get_task = entitlements.get("get-task-allow")
    if config == "Release" and get_task is True:
        fail(f"{label} Release provisioning profile allows get-task-allow")
    if config not in {"Release", "Test"} and get_task is not True:
        fail(f"{label} {config} provisioning profile must allow get-task-allow")


def validate(app: Path, extension: Path, config: str, require_profile: bool) -> None:
    if config not in EXPECTED:
        fail(f"unknown configuration {config}")
    role, route, bundle, extension_bundle, apns, attest, blur = EXPECTED[config]
    if not app.is_dir() or app.suffix != ".app":
        fail(f"not an app bundle: {app}")
    info = load_plist(app / "Info.plist")
    expected = {
        "CFBundleIdentifier": bundle,
        "TRONBuildRole": role,
        "TRONConfiguration": config,
        "TRONPushRoute": route,
        "TRONAPNsEnvironment": apns,
        "TRONAppAttestEnvironment": attest,
        "TRONPrivateBlurEnabled": blur,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            fail(f"app {key}={info.get(key)!r}, expected {value!r}")
    app_signing = signed_output(app, require_profile)
    if app_signing["identifier"] and app_signing["identifier"] != bundle:
        fail(f"signed app identifier {app_signing['identifier']!r} does not match {bundle!r}")
    check_entitlements("app", app_signing, apns, attest, config, bundle)
    check_profile("app", app_signing, apns, config, bundle)
    plugins = app / "PlugIns"
    candidates = sorted(plugins.glob("*.appex"))
    if len(candidates) != 1:
        fail(f"expected one embedded extension, found {len(candidates)}")
    if not extension:
        extension = candidates[0]
    try:
        extension_resolved = extension.resolve(strict=True)
        plugins_resolved = plugins.resolve(strict=True)
    except OSError as exc:
        fail(f"cannot resolve embedded extension: {exc}")
    if extension_resolved.parent != plugins_resolved or extension_resolved != candidates[0].resolve(strict=True):
        fail(f"extension is not the app's sole embedded PlugIns artifact: {extension}")
    extension = extension_resolved
    if not extension.is_dir():
        fail(f"missing extension artifact: {extension}")
    extension_info = load_plist(extension / "Info.plist")
    if extension_info.get("CFBundleIdentifier") != extension_bundle:
        fail(f"extension bundle identifier is {extension_info.get('CFBundleIdentifier')!r}, expected {extension_bundle!r}")
    extension_signing = signed_output(extension, require_profile)
    if extension_signing["identifier"] and extension_signing["identifier"] != extension_bundle:
        fail(f"signed extension identifier {extension_signing['identifier']!r} does not match {extension_bundle!r}")
    check_entitlements("extension", extension_signing, None, None, config, extension_bundle)
    check_profile("extension", extension_signing, None, config, extension_bundle)
    print(f"validated signed {config} artifact: {app}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--configuration", required=True, choices=sorted(EXPECTED))
    parser.add_argument("--extension", type=Path)
    parser.add_argument("--require-profile", action="store_true")
    args = parser.parse_args()
    validate(args.app, args.extension, args.configuration, args.require_profile)


if __name__ == "__main__":
    main()
