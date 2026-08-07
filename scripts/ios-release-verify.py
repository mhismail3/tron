#!/usr/bin/env python3
"""Verify iOS release archives and emit sanitized build provenance."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import plistlib
import re
import sys
import tempfile
from pathlib import Path
from typing import Optional


SCHEMA = "tron.ios-release-provenance.v1"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
MAX_DIAGNOSTIC_BYTES = 1024 * 1024

CODESIGN_FAILURE_PATTERNS = (
    (
        "untrusted-certificate-chain",
        (
            "unable to build chain to self-signed root",
            "cssmerr_tp_not_trusted",
            "cssmerr_tp_invalid_anchor_cert",
        ),
    ),
    (
        "keychain-interaction-not-allowed",
        ("user interaction is not allowed", "errsecinteractionnotallowed"),
    ),
    ("keychain-locked", ("errsecnotavailable", "the specified keychain is locked")),
    (
        "signing-identity-not-found",
        (
            "no identity found",
            "the specified item could not be found in the keychain",
        ),
    ),
    ("keychain-security-context", ("errsecinternalcomponent",)),
)


class VerificationError(RuntimeError):
    pass


def classify_codesign_log(path: Path) -> dict:
    if not path.is_file():
        raise VerificationError("codesign diagnostic log is missing")
    with path.open("rb") as handle:
        handle.seek(0, 2)
        size = handle.tell()
        handle.seek(max(0, size - MAX_DIAGNOSTIC_BYTES))
        contents = handle.read(MAX_DIAGNOSTIC_BYTES).decode("utf-8", errors="replace")
    normalized = contents.casefold()
    classification = "unknown"
    for candidate, patterns in CODESIGN_FAILURE_PATTERNS:
        if any(pattern in normalized for pattern in patterns):
            classification = candidate
            break
    return {"classification": classification}


def inspect_security_session(
    require_non_root: bool, require_audit_uid: Optional[int] = None
) -> dict:
    if sys.platform != "darwin":
        raise VerificationError("security-session inspection requires macOS")
    security = ctypes.CDLL(
        "/System/Library/Frameworks/Security.framework/Security"
    )
    session_get_info = security.SessionGetInfo
    session_get_info.argtypes = (
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint32),
    )
    session_get_info.restype = ctypes.c_int32
    session_id = ctypes.c_uint32()
    attributes = ctypes.c_uint32()
    status = session_get_info(
        ctypes.c_uint32(0xFFFFFFFF),
        ctypes.byref(session_id),
        ctypes.byref(attributes),
    )
    if status != 0:
        raise VerificationError(f"SessionGetInfo failed with status {status}")

    process = ctypes.CDLL(None, use_errno=True)
    get_audit_uid = process.getauid
    get_audit_uid.argtypes = (ctypes.POINTER(ctypes.c_uint32),)
    get_audit_uid.restype = ctypes.c_int
    audit_uid = ctypes.c_uint32()
    if get_audit_uid(ctypes.byref(audit_uid)) != 0:
        raise VerificationError(
            f"getauid failed with errno {ctypes.get_errno()}"
        )

    value = attributes.value
    document = {
        "audit_uid": audit_uid.value,
        "effective_uid": os.geteuid(),
        "session_id": session_id.value,
        "is_root": bool(value & 0x0001),
        "has_graphics": bool(value & 0x0010),
        "has_tty": bool(value & 0x0020),
        "is_remote": bool(value & 0x1000),
    }
    if require_non_root and document["is_root"]:
        raise VerificationError(
            "release runner inherited the root macOS security session"
        )
    if (
        require_audit_uid is not None
        and document["audit_uid"] != require_audit_uid
    ):
        raise VerificationError(
            "release runner audit user does not match its Unix account"
        )
    return document


def read_plist(path: Path) -> dict:
    if not path.is_file():
        raise VerificationError(f"missing plist: {path}")
    with path.open("rb") as handle:
        return plistlib.load(handle)


def verify_profile_certificate(args: argparse.Namespace) -> dict:
    profile = read_plist(Path(args.profile_plist).resolve())
    leaf_path = Path(args.leaf_certificate).resolve()
    if not leaf_path.is_file():
        raise VerificationError("validated distribution leaf is missing")
    leaf = leaf_path.read_bytes()
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        raise VerificationError("profile has no developer certificates")
    if any(not isinstance(certificate, bytes) for certificate in certificates):
        raise VerificationError("profile developer certificate data is malformed")
    if leaf not in certificates:
        raise VerificationError(
            "profile does not admit the validated distribution certificate"
        )
    return {"certificate_count": len(certificates), "leaf_admitted": True}


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
        root = Path(temp)
        archive = fixture_archive(root)
        ipa = root / "Fixture.ipa"
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

        diagnostic = root / "codesign.log"
        classifications = (
            (
                'Warning: unable to build chain to self-signed root for signer "Example"\n'
                "probe: errSecInternalComponent\n",
                "untrusted-certificate-chain",
            ),
            ("User interaction is not allowed.\n", "keychain-interaction-not-allowed"),
            ("probe: errSecInternalComponent\n", "keychain-security-context"),
            ("unrecognized signing failure\n", "unknown"),
        )
        for contents, expected in classifications:
            diagnostic.write_text(contents, encoding="utf-8")
            result = classify_codesign_log(diagnostic)
            if result != {"classification": expected}:
                raise AssertionError(
                    f"codesign classification {result!r}, expected {expected!r}"
                )
            if "Example" in json.dumps(result):
                raise AssertionError("codesign diagnostics leaked certificate identity")

        if sys.platform == "darwin":
            session = inspect_security_session(
                require_non_root=True, require_audit_uid=os.geteuid()
            )
            if session["audit_uid"] != session["effective_uid"]:
                raise AssertionError("security-session omitted matching audit identity")
            try:
                inspect_security_session(
                    require_non_root=True,
                    require_audit_uid=os.geteuid() + 1,
                )
            except VerificationError:
                pass
            else:
                raise AssertionError("security-session accepted the wrong audit user")

        leaf = root / "leaf.cer"
        leaf.write_bytes(b"validated leaf")
        profile = root / "profile.plist"
        with profile.open("wb") as handle:
            plistlib.dump({"DeveloperCertificates": [b"validated leaf"]}, handle)
        profile_args = argparse.Namespace(
            profile_plist=str(profile), leaf_certificate=str(leaf)
        )
        if verify_profile_certificate(profile_args)["leaf_admitted"] is not True:
            raise AssertionError("profile rejected its validated distribution leaf")
        leaf.write_bytes(b"other leaf")
        try:
            verify_profile_certificate(profile_args)
        except VerificationError:
            pass
        else:
            raise AssertionError("profile accepted an unrelated distribution leaf")


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
    profile = commands.add_parser("profile-certificate")
    profile.add_argument("--profile-plist", required=True)
    profile.add_argument("--leaf-certificate", required=True)
    diagnostic = commands.add_parser("codesign-diagnostic")
    diagnostic.add_argument("--log", required=True)
    security_session = commands.add_parser("security-session")
    security_session.add_argument("--require-non-root", action="store_true")
    security_session.add_argument("--require-audit-uid", type=int)
    commands.add_parser("self-test")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "archive":
            print(json.dumps(verify_archive(args), sort_keys=True))
        elif args.command == "provenance":
            print(json.dumps(write_provenance(args), sort_keys=True))
        elif args.command == "profile-certificate":
            print(json.dumps(verify_profile_certificate(args), sort_keys=True))
        elif args.command == "codesign-diagnostic":
            print(
                json.dumps(
                    classify_codesign_log(Path(args.log).resolve()), sort_keys=True
                )
            )
        elif args.command == "security-session":
            print(
                json.dumps(
                    inspect_security_session(
                        args.require_non_root, args.require_audit_uid
                    ),
                    sort_keys=True,
                )
            )
        else:
            self_test()
            print("iOS release verification self-test passed")
    except VerificationError as error:
        print(f"iOS release verification failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
