#!/usr/bin/env python3
"""Verify iOS release archives and emit sanitized build provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import tempfile
from pathlib import Path


SCHEMA = "tron.ios-release-provenance.v1"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class VerificationError(RuntimeError):
    pass


def read_plist(path: Path) -> dict:
    if not path.is_file():
        raise VerificationError(f"missing plist: {path}")
    with path.open("rb") as handle:
        return plistlib.load(handle)


def require_equal(plist: dict, key: str, expected: str, owner: str) -> None:
    actual = str(plist.get(key, ""))
    if actual != expected:
        raise VerificationError(f"{owner} {key}={actual!r}, expected {expected!r}")


def archive_metadata(archive: Path) -> tuple[dict, dict, Path, Path]:
    app = archive / "Products" / "Applications" / "TronMobile.app"
    appex = app / "PlugIns" / "TronShareExtension.appex"
    return (
        read_plist(app / "Info.plist"),
        read_plist(appex / "Info.plist"),
        app,
        appex,
    )


def verify_archive(args: argparse.Namespace) -> dict:
    archive = Path(args.archive).resolve()
    app_info, appex_info, _, _ = archive_metadata(archive)
    owners = (
        ("app", app_info, args.app_bundle_id),
        ("share extension", appex_info, args.extension_bundle_id),
    )
    for owner, info, bundle_id in owners:
        require_equal(info, "CFBundleIdentifier", bundle_id, owner)
        require_equal(info, "CFBundleShortVersionString", args.marketing_version, owner)
        require_equal(info, "CFBundleVersion", args.build_number, owner)
        require_equal(info, "DTXcodeBuild", args.xcode_build, owner)
        require_equal(info, "MinimumOSVersion", args.minimum_os, owner)
        sdk_name = str(info.get("DTSDKName", ""))
        expected_sdk_prefix = f"iphoneos{args.sdk_version}"
        if not sdk_name.startswith(expected_sdk_prefix):
            raise VerificationError(
                f"{owner} DTSDKName={sdk_name!r}, expected prefix {expected_sdk_prefix!r}"
            )
    require_equal(app_info, "TRONCanonicalVersion", args.canonical_version, "app")
    if app_info.get("ITSAppUsesNonExemptEncryption") is not False:
        raise VerificationError("app export-compliance declaration is not false")
    if appex_info.get("ITSAppUsesNonExemptEncryption") is not False:
        raise VerificationError("share extension export-compliance declaration is not false")
    return {
        "xcode_build": args.xcode_build,
        "sdk": args.sdk_version,
        "minimum_os": args.minimum_os,
        "marketing_version": args.marketing_version,
        "build_number": args.build_number,
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_provenance(args: argparse.Namespace) -> dict:
    if not SHA_PATTERN.fullmatch(args.source_sha):
        raise VerificationError("source SHA must be a lowercase full commit id")
    archive = Path(args.archive).resolve()
    app_info, appex_info, app, appex = archive_metadata(archive)
    app_binary = app / str(app_info.get("CFBundleExecutable", "TronMobile"))
    if not app_binary.is_file():
        raise VerificationError("archive app executable is missing")
    appex_binary = appex / str(
        appex_info.get("CFBundleExecutable", "TronShareExtension")
    )
    if not appex_binary.is_file():
        raise VerificationError("archive share-extension executable is missing")
    ipa = Path(args.ipa).resolve()
    if not ipa.is_file():
        raise VerificationError("IPA is missing")
    canonical_version = str(app_info.get("TRONCanonicalVersion", ""))
    if not canonical_version:
        raise VerificationError("archive app canonical version is missing")
    document = {
        "schema": SCHEMA,
        "source_sha": args.source_sha,
        "github": {"run_id": args.run_id, "run_attempt": args.run_attempt},
        "toolchain": {
            "xcode_version": args.xcode_version,
            "xcode_build": str(app_info.get("DTXcodeBuild", "")),
            "sdk": str(app_info.get("DTSDKName", "")),
            "deployment_target": str(app_info.get("MinimumOSVersion", "")),
        },
        "product": {
            "canonical_version": canonical_version,
            "marketing_version": str(app_info.get("CFBundleShortVersionString", "")),
            "build_number": str(app_info.get("CFBundleVersion", "")),
            "app_bundle_id": str(app_info.get("CFBundleIdentifier", "")),
            "extension_bundle_id": str(appex_info.get("CFBundleIdentifier", "")),
            "app_executable_sha256": sha256(app_binary),
            "share_extension_executable_sha256": sha256(appex_binary),
            "ipa_sha256": sha256(ipa),
        },
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return document


def fixture_archive(root: Path) -> Path:
    archive = root / "Fixture.xcarchive"
    app = archive / "Products/Applications/TronMobile.app"
    appex = app / "PlugIns/TronShareExtension.appex"
    appex.mkdir(parents=True)
    common = {
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "42",
        "DTXcodeBuild": "27A5218g",
        "DTSDKName": "iphoneos27.0",
        "MinimumOSVersion": "26.0",
        "ITSAppUsesNonExemptEncryption": False,
    }
    app_info = dict(common, CFBundleIdentifier="com.example.app", CFBundleExecutable="TronMobile", TRONCanonicalVersion="1.2.3")
    extension_info = dict(
        common,
        CFBundleIdentifier="com.example.app.ShareExtension",
        CFBundleExecutable="TronShareExtension",
    )
    for path, value in ((app / "Info.plist", app_info), (appex / "Info.plist", extension_info)):
        with path.open("wb") as handle:
            plistlib.dump(value, handle)
    (app / "TronMobile").write_bytes(b"fixture executable")
    (appex / "TronShareExtension").write_bytes(b"fixture extension executable")
    return archive


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temp:
        archive = fixture_archive(Path(temp))
        ipa = Path(temp) / "Fixture.ipa"
        ipa.write_bytes(b"fixture ipa")
        base = argparse.Namespace(
            archive=str(archive), app_bundle_id="com.example.app",
            extension_bundle_id="com.example.app.ShareExtension",
            marketing_version="1.2.3", build_number="42", canonical_version="1.2.3",
            xcode_build="27A5218g", sdk_version="27.0", minimum_os="26.0",
        )
        verify_archive(base)
        for field, bad_value in (
            ("xcode_build", "26C100"), ("sdk_version", "26.5"), ("minimum_os", "27.0")
        ):
            changed = argparse.Namespace(**vars(base))
            setattr(changed, field, bad_value)
            try:
                verify_archive(changed)
            except VerificationError:
                pass
            else:
                raise AssertionError(f"fixture accepted invalid {field}")
        try:
            write_provenance(argparse.Namespace(
                archive=str(archive), ipa=str(ipa), source_sha="short", run_id="1",
                run_attempt="1", xcode_version="27.0", output=str(Path(temp) / "out.json")
            ))
        except VerificationError:
            pass
        else:
            raise AssertionError("fixture accepted invalid source SHA")
        document = write_provenance(argparse.Namespace(
            archive=str(archive), ipa=str(ipa),
            source_sha="0123456789abcdef0123456789abcdef01234567",
            run_id="1", run_attempt="1", xcode_version="27.0",
            output=str(Path(temp) / "out.json"),
        ))
        if not document["product"]["share_extension_executable_sha256"]:
            raise AssertionError("fixture provenance omitted the share extension hash")
        if document["product"]["canonical_version"] != "1.2.3":
            raise AssertionError("fixture provenance omitted the canonical version")
        if document["product"]["ipa_sha256"] != sha256(ipa):
            raise AssertionError("fixture provenance recorded the wrong IPA hash")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    archive = commands.add_parser("archive")
    archive.add_argument("--archive", required=True)
    archive.add_argument("--app-bundle-id", required=True)
    archive.add_argument("--extension-bundle-id", required=True)
    archive.add_argument("--marketing-version", required=True)
    archive.add_argument("--build-number", required=True)
    archive.add_argument("--canonical-version", required=True)
    archive.add_argument("--xcode-build", required=True)
    archive.add_argument("--sdk-version", required=True)
    archive.add_argument("--minimum-os", required=True)
    provenance = commands.add_parser("provenance")
    provenance.add_argument("--archive", required=True)
    provenance.add_argument("--ipa", required=True)
    provenance.add_argument("--source-sha", required=True)
    provenance.add_argument("--run-id", required=True)
    provenance.add_argument("--run-attempt", required=True)
    provenance.add_argument("--xcode-version", required=True)
    provenance.add_argument("--output", required=True)
    commands.add_parser("self-test")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "archive":
            print(json.dumps(verify_archive(args), sort_keys=True))
        elif args.command == "provenance":
            print(json.dumps(write_provenance(args), sort_keys=True))
        else:
            self_test()
            print("iOS release verification self-test passed")
    except VerificationError as error:
        print(f"iOS release verification failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
