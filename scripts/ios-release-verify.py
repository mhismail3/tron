#!/usr/bin/env python3
"""Verify iOS releases and emit sanitized build and latest-head provenance."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
import plistlib
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Optional


SCHEMA = "tron.ios-release-provenance.v1"
HEAD_CHECK_SCHEMA = "tron.ios-release-head-check.v1"
ELIGIBILITY_SCHEMA = "tron.ios-release-eligibility.v1"
INTENT_SCHEMA = "tron.ios-release-intent.v1"
RECEIPT_SCHEMA = "tron.ios-release-receipt.v1"
REUSE_SCHEMA = "tron.ios-release-reuse-provenance.v1"
ADMISSION_SCHEMA = "tron.ios-release-admission.v1"
DIRECT_INTENT_SCHEMA = "tron.ios-release-direct-intent.v1"
DIRECT_SOURCE_CHECK_SCHEMA = "tron.ios-release-direct-source-check.v1"
DIRECT_ADMISSION_SCHEMA = "tron.ios-release-direct-admission.v1"
DIRECT_REUSE_SCHEMA = "tron.ios-release-direct-reuse-provenance.v1"
DIRECT_RECEIPT_SCHEMA = "tron.ios-release-direct-receipt.v1"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
POSITIVE_INTEGER_PATTERN = re.compile(r"^[1-9][0-9]*$")
HOSTED_BUILD_PATTERN = re.compile(r"^[1-9][0-9]{0,3}\.[0-9]{1,2}\.[12]$")
DIGEST_PATTERN = re.compile(r"^sha256:([0-9a-f]{64})$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
UTC_TIMESTAMP_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
MAX_DIAGNOSTIC_BYTES = 1024 * 1024
MAX_EVIDENCE_ARCHIVE_BYTES = 8 * 1024 * 1024
RELEASE_WORKFLOW_NAME = "Release (iOS TestFlight)"
RELEASE_WORKFLOW_PATH = ".github/workflows/release-ios.yml"

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


def canonical_json_bytes(document: dict) -> bytes:
    return (json.dumps(document, sort_keys=True, indent=2) + "\n").encode("utf-8")


def write_document(document: dict, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(canonical_json_bytes(document))


def strict_json_bytes(contents: bytes, owner: str) -> dict:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise VerificationError(f"{owner} contains duplicate JSON key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(contents.decode("utf-8"), object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"{owner} is not canonical UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise VerificationError(f"{owner} must be a JSON object")
    if contents != canonical_json_bytes(value):
        raise VerificationError(f"{owner} is not canonical producer JSON")
    return value


def require_exact_keys(value: dict, expected: set[str], owner: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise VerificationError(
            f"{owner} keys differ (missing={missing}, extra={extra})"
        )


def require_digest(value: str, field: str) -> str:
    if not isinstance(value, str) or not DIGEST_PATTERN.fullmatch(value):
        raise VerificationError(f"{field} must be a sha256 digest")
    return value


def require_hosted_build(value: str, field: str) -> str:
    if not isinstance(value, str) or not HOSTED_BUILD_PATTERN.fullmatch(value):
        raise VerificationError(f"{field} must be a namespaced hosted build number")
    return value


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise VerificationError(f"{field} must be a non-empty unpadded string")
    return value


def sha256_bytes(contents: bytes) -> str:
    return f"sha256:{hashlib.sha256(contents).hexdigest()}"


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


def utc_timestamp(value: str, field: str) -> dt.datetime:
    if not UTC_TIMESTAMP_PATTERN.fullmatch(value):
        raise VerificationError(f"{field} must be a canonical UTC timestamp")
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as error:
        raise VerificationError(f"{field} is not a valid UTC timestamp") from error


def positive_identifier(value: str, field: str) -> str:
    if not POSITIVE_INTEGER_PATTERN.fullmatch(value):
        raise VerificationError(f"{field} must be a positive integer identifier")
    return value


def write_head_check(args: argparse.Namespace) -> dict:
    if not REPOSITORY_PATTERN.fullmatch(args.repository):
        raise VerificationError("repository must be an owner/name slug")
    if not SHA_PATTERN.fullmatch(args.source_sha):
        raise VerificationError("source SHA must be a lowercase full commit id")
    if not SHA_PATTERN.fullmatch(args.current_main_sha):
        raise VerificationError("current main SHA must be a lowercase full commit id")
    if args.source_sha != args.current_main_sha:
        raise VerificationError("automatic release source is not the current main head")
    checked_at = utc_timestamp(args.checked_at, "checked_at")
    ci_completed_at = utc_timestamp(args.ci_completed_at, "ci_completed_at")
    if checked_at < ci_completed_at:
        raise VerificationError("head check predates authoritative CI completion")
    document = {
        "schema": HEAD_CHECK_SCHEMA,
        "repository": args.repository,
        "source_sha": args.source_sha,
        "current_main_sha": args.current_main_sha,
        "source_is_current_main": True,
        "checked_at": args.checked_at,
        "authoritative_ci": {
            "workflow_run_id": positive_identifier(
                args.ci_workflow_run_id, "ci_workflow_run_id"
            ),
            "run_attempt": positive_identifier(
                args.ci_run_attempt, "ci_run_attempt"
            ),
            "completed_at": args.ci_completed_at,
        },
        "release": {
            "workflow_run_id": positive_identifier(
                args.release_workflow_run_id, "release_workflow_run_id"
            ),
            "run_attempt": positive_identifier(
                args.release_run_attempt, "release_run_attempt"
            ),
        },
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return document


def write_eligibility(args: argparse.Namespace) -> dict:
    if not REPOSITORY_PATTERN.fullmatch(args.repository):
        raise VerificationError("repository must be an owner/name slug")
    if not SHA_PATTERN.fullmatch(args.source_sha):
        raise VerificationError("source SHA must be a lowercase full commit id")
    if not SHA_PATTERN.fullmatch(args.observed_main_sha):
        raise VerificationError("observed main SHA must be a lowercase full commit id")
    if not args.upstream_event or args.upstream_event != args.upstream_event.strip():
        raise VerificationError("upstream event must be a non-empty unpadded string")
    if not args.upstream_branch or args.upstream_branch != args.upstream_branch.strip():
        raise VerificationError("upstream branch must be a non-empty unpadded string")
    conclusions = {
        "action_required",
        "cancelled",
        "failure",
        "neutral",
        "skipped",
        "stale",
        "startup_failure",
        "success",
        "timed_out",
    }
    if args.upstream_conclusion not in conclusions:
        raise VerificationError("upstream conclusion is unsupported")
    checked_at = utc_timestamp(args.checked_at, "checked_at")
    completed_at = utc_timestamp(args.ci_completed_at, "ci_completed_at")
    if checked_at < completed_at:
        raise VerificationError("eligibility check predates authoritative CI completion")
    if args.eligible not in {"true", "false"}:
        raise VerificationError("eligible must be true or false")
    eligible = args.eligible == "true"
    expected_eligible = (
        args.upstream_conclusion == "success"
        and args.upstream_event == "push"
        and args.upstream_branch == "main"
        and args.source_sha == args.observed_main_sha
    )
    if eligible != expected_eligible:
        raise VerificationError("eligibility does not match the observed CI/main identity")
    document = {
        "schema": ELIGIBILITY_SCHEMA,
        "repository": args.repository,
        "source_sha": args.source_sha,
        "observed_main_sha": args.observed_main_sha,
        "checked_at": args.checked_at,
        "eligible": eligible,
        "authoritative_ci": {
            "workflow_run_id": positive_identifier(
                args.ci_workflow_run_id, "ci_workflow_run_id"
            ),
            "run_attempt": positive_identifier(
                args.ci_run_attempt, "ci_run_attempt"
            ),
            "event": args.upstream_event,
            "branch": args.upstream_branch,
            "conclusion": args.upstream_conclusion,
            "completed_at": args.ci_completed_at,
        },
        "release": {
            "workflow_run_id": positive_identifier(
                args.release_workflow_run_id, "release_workflow_run_id"
            ),
            "run_attempt": positive_identifier(
                args.release_run_attempt, "release_run_attempt"
            ),
        },
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return document


def hosted_build_number(owner_run_number: str, lane: int) -> str:
    number = int(positive_identifier(owner_run_number, "owner_run_number"))
    if number > 899999:
        raise VerificationError("owner_run_number exceeds the hosted build namespace")
    if lane not in {1, 2}:
        raise VerificationError("hosted build lane must be 1 or 2")
    return f"{1000 + number // 100}.{number % 100}.{lane}"


def automatic_build_number(owner_run_number: str) -> str:
    return hosted_build_number(owner_run_number, 1)


def validate_intent(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "created_at",
            "authoritative_ci",
            "product",
            "owner",
            "release",
            "resolution",
        },
        "release intent",
    )
    if document["schema"] != INTENT_SCHEMA:
        raise VerificationError("release intent schema is unsupported")
    repository = require_string(document["repository"], "intent.repository")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise VerificationError("intent repository must be an owner/name slug")
    source_sha = require_string(document["source_sha"], "intent.source_sha")
    if not SHA_PATTERN.fullmatch(source_sha):
        raise VerificationError("intent source SHA must be a lowercase full commit id")
    created_at = require_string(document["created_at"], "intent.created_at")
    created = utc_timestamp(created_at, "intent.created_at")

    ci = document["authoritative_ci"]
    if not isinstance(ci, dict):
        raise VerificationError("intent authoritative_ci must be an object")
    require_exact_keys(
        ci,
        {"workflow_run_id", "run_number", "run_attempt", "completed_at"},
        "intent.authoritative_ci",
    )
    ci_run_id = positive_identifier(str(ci["workflow_run_id"]), "intent CI run id")
    ci_run_number = positive_identifier(str(ci["run_number"]), "intent CI run number")
    positive_identifier(str(ci["run_attempt"]), "intent CI run attempt")
    completed_at = require_string(ci["completed_at"], "intent CI completed_at")
    if created < utc_timestamp(completed_at, "intent CI completed_at"):
        raise VerificationError("release intent predates authoritative CI completion")
    if document["intent_key"] != f"github-ci-run:{ci_run_id}":
        raise VerificationError("release intent key does not bind the CI run")

    product = document["product"]
    if not isinstance(product, dict):
        raise VerificationError("intent product must be an object")
    require_exact_keys(
        product,
        {
            "asc_app_id",
            "scheme",
            "configuration",
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
        },
        "intent.product",
    )
    for field in (
        "asc_app_id",
        "scheme",
        "configuration",
        "canonical_version",
        "marketing_version",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        require_string(product[field], f"intent product {field}")
    build_number = require_hosted_build(product["build_number"], "intent build number")

    for owner_name in ("owner", "release"):
        owner = document[owner_name]
        if not isinstance(owner, dict):
            raise VerificationError(f"intent {owner_name} must be an object")
        require_exact_keys(
            owner,
            {"workflow_run_id", "run_number", "run_attempt"},
            f"intent.{owner_name}",
        )
        for field in ("workflow_run_id", "run_number", "run_attempt"):
            positive_identifier(str(owner[field]), f"intent {owner_name} {field}")
    if build_number != automatic_build_number(str(document["owner"]["run_number"])):
        raise VerificationError("release intent build number is not owned by its release allocation")

    resolution = document["resolution"]
    if not isinstance(resolution, dict):
        raise VerificationError("intent resolution must be an object")
    require_exact_keys(
        resolution,
        {"state", "previous_intent_sha256", "completion_receipt_sha256"},
        "intent.resolution",
    )
    state = resolution["state"]
    if state not in {"new", "resume", "completed"}:
        raise VerificationError("intent resolution state is unsupported")
    previous = resolution["previous_intent_sha256"]
    receipt = resolution["completion_receipt_sha256"]
    if state == "new":
        if previous is not None or receipt is not None:
            raise VerificationError("new intent cannot reference prior evidence")
        if document["owner"] != document["release"]:
            raise VerificationError("new intent owner must be the resolving release run")
    elif state == "resume":
        require_digest(previous, "intent previous digest")
        if receipt is not None:
            raise VerificationError("resumable intent cannot reference a completion receipt")
    else:
        require_digest(previous, "intent previous digest")
        require_digest(receipt, "intent completion receipt digest")
    return document


def write_intent(args: argparse.Namespace) -> dict:
    previous = args.previous_intent_sha256 or None
    receipt = args.completion_receipt_sha256 or None
    document = {
        "schema": INTENT_SCHEMA,
        "repository": args.repository,
        "intent_key": f"github-ci-run:{args.ci_workflow_run_id}",
        "source_sha": args.source_sha,
        "created_at": args.created_at,
        "authoritative_ci": {
            "workflow_run_id": args.ci_workflow_run_id,
            "run_number": args.ci_run_number,
            "run_attempt": args.ci_run_attempt,
            "completed_at": args.ci_completed_at,
        },
        "product": {
            "asc_app_id": args.asc_app_id,
            "scheme": args.scheme,
            "configuration": args.configuration,
            "canonical_version": args.canonical_version,
            "marketing_version": args.marketing_version,
            "build_number": args.build_number,
            "app_bundle_id": args.app_bundle_id,
            "extension_bundle_id": args.extension_bundle_id,
        },
        "owner": {
            "workflow_run_id": args.owner_release_workflow_run_id,
            "run_number": args.owner_release_run_number,
            "run_attempt": args.owner_release_run_attempt,
        },
        "release": {
            "workflow_run_id": args.release_workflow_run_id,
            "run_number": args.release_run_number,
            "run_attempt": args.release_run_attempt,
        },
        "resolution": {
            "state": args.resolution_state,
            "previous_intent_sha256": previous,
            "completion_receipt_sha256": receipt,
        },
    }
    validate_intent(document)
    write_document(document, Path(args.output))
    return document


def validate_admission(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "product",
            "owner",
            "asc",
            "evidence",
            "producer",
            "admitted_at",
        },
        "release admission",
    )
    if document["schema"] != ADMISSION_SCHEMA:
        raise VerificationError("release admission schema is unsupported")
    if not REPOSITORY_PATTERN.fullmatch(
        require_string(document["repository"], "admission repository")
    ):
        raise VerificationError("admission repository must be an owner/name slug")
    if not SHA_PATTERN.fullmatch(
        require_string(document["source_sha"], "admission source SHA")
    ):
        raise VerificationError("admission source SHA must be a full commit id")
    intent_key = require_string(document["intent_key"], "admission intent key")
    intent_match = re.fullmatch(r"github-ci-run:([1-9][0-9]*)", intent_key)
    if intent_match is None:
        raise VerificationError("release admission must bind an automatic CI intent")
    positive_identifier(intent_match.group(1), "admission CI run id")
    utc_timestamp(require_string(document["admitted_at"], "admission admitted_at"), "admission admitted_at")
    if not isinstance(document["product"], dict):
        raise VerificationError("admission product must be an object")
    require_exact_keys(
        document["product"],
        {
            "asc_app_id",
            "scheme",
            "configuration",
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
        },
        "admission.product",
    )
    for field, value in document["product"].items():
        require_string(value, f"admission product {field}")
    build_number = require_hosted_build(
        document["product"]["build_number"], "admission build number"
    )
    if not isinstance(document["owner"], dict) or not isinstance(document["producer"], dict):
        raise VerificationError("admission owner and producer must be objects")
    for field in ("owner", "producer"):
        require_exact_keys(
            document[field],
            {"workflow_run_id", "run_number", "run_attempt"},
            f"admission.{field}",
        )
        for value in document[field].values():
            positive_identifier(str(value), f"admission {field} identifier")
    if build_number != automatic_build_number(str(document["owner"]["run_number"])):
        raise VerificationError(
            "admission build number is not owned by its release allocation"
        )
    asc = document["asc"]
    if not isinstance(asc, dict):
        raise VerificationError("admission ASC binding must be an object")
    require_exact_keys(asc, {"app_id", "build_id"}, "admission.asc")
    require_string(asc["app_id"], "admission ASC app id")
    require_string(asc["build_id"], "admission ASC build id")
    if asc["app_id"] != document["product"]["asc_app_id"]:
        raise VerificationError("admission ASC app id conflicts with its product")
    evidence = document["evidence"]
    if not isinstance(evidence, dict):
        raise VerificationError("admission evidence must be an object")
    require_exact_keys(
        evidence,
        {
            "intent_sha256",
            "release_provenance_sha256",
            "head_check_sha256",
            "prior_admission_sha256",
            "reuse_provenance_sha256",
        },
        "admission.evidence",
    )
    for field, value in evidence.items():
        if field in {"prior_admission_sha256", "reuse_provenance_sha256"} and value is None:
            continue
        require_digest(value, f"admission {field}")
    if (evidence["prior_admission_sha256"] is None) != (
        evidence["reuse_provenance_sha256"] is None
    ):
        raise VerificationError("admission reuse evidence must be complete")
    return document


def validate_reuse_provenance(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "product",
            "asc",
            "owner",
            "original",
            "consumer",
        },
        "reuse provenance",
    )
    if document["schema"] != REUSE_SCHEMA:
        raise VerificationError("reuse provenance schema is unsupported")
    repository = require_string(document["repository"], "reuse repository")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise VerificationError("reuse repository must be an owner/name slug")
    source_sha = require_string(document["source_sha"], "reuse source SHA")
    if not SHA_PATTERN.fullmatch(source_sha):
        raise VerificationError("reuse source SHA must be a lowercase full commit id")

    intent_key = require_string(document["intent_key"], "reuse intent key")
    automatic_match = re.fullmatch(r"github-ci-run:([1-9][0-9]*)", intent_key)
    manual_match = re.fullmatch(
        r"github-release-run:([1-9][0-9]*)", intent_key
    )
    if automatic_match is None and manual_match is None:
        raise VerificationError("reuse intent key has an unsupported owner")

    product = document["product"]
    if not isinstance(product, dict):
        raise VerificationError("reuse product must be an object")
    require_exact_keys(
        product,
        {
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
            "ipa_sha256",
        },
        "reuse.product",
    )
    for field in (
        "canonical_version",
        "marketing_version",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        require_string(product[field], f"reuse product {field}")
    build_number = require_hosted_build(product["build_number"], "reuse build number")
    if not isinstance(product["ipa_sha256"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", product["ipa_sha256"]
    ):
        raise VerificationError("reuse IPA digest must be a SHA-256 value")

    asc = document["asc"]
    if not isinstance(asc, dict):
        raise VerificationError("reuse ASC binding must be an object")
    require_exact_keys(asc, {"app_id", "build_id"}, "reuse.asc")
    require_string(asc["app_id"], "reuse ASC app id")
    require_string(asc["build_id"], "reuse ASC build id")

    owner = document["owner"]
    original = document["original"]
    consumer = document["consumer"]
    if not all(isinstance(value, dict) for value in (owner, original, consumer)):
        raise VerificationError("reuse owner, original, and consumer must be objects")
    require_exact_keys(
        owner,
        {"workflow_run_id", "run_number", "run_attempt"},
        "reuse.owner",
    )
    require_exact_keys(
        original,
        {
            "workflow_run_id",
            "run_attempt",
            "provenance_sha256",
            "intent_sha256",
            "admission_sha256",
        },
        "reuse.original",
    )
    require_exact_keys(
        consumer,
        {"workflow_run_id", "run_number", "run_attempt", "intent_sha256"},
        "reuse.consumer",
    )
    for field in ("workflow_run_id", "run_number", "run_attempt"):
        positive_identifier(str(owner[field]), f"reuse owner {field}")
        positive_identifier(str(consumer[field]), f"reuse consumer {field}")
    for field in ("workflow_run_id", "run_attempt"):
        positive_identifier(str(original[field]), f"reuse original {field}")
    require_digest(original["provenance_sha256"], "reuse original provenance")

    automatic = automatic_match is not None
    expected_lane = 1 if automatic else 2
    if build_number != hosted_build_number(str(owner["run_number"]), expected_lane):
        raise VerificationError("reuse build number is not owned by its release allocation")
    if automatic:
        positive_identifier(automatic_match.group(1), "reuse CI run id")
        for field in ("intent_sha256", "admission_sha256"):
            require_digest(original[field], f"reuse original {field}")
        require_digest(consumer["intent_sha256"], "reuse consumer intent")
        if (
            owner["workflow_run_id"] != original["workflow_run_id"]
            or owner["run_attempt"] != original["run_attempt"]
        ):
            raise VerificationError("automatic reuse original does not match its owner")
    else:
        release_run_id = positive_identifier(
            manual_match.group(1), "reuse release run id"
        )
        if any(
            value is not None
            for value in (
                original["intent_sha256"],
                original["admission_sha256"],
                consumer["intent_sha256"],
            )
        ):
            raise VerificationError("non-automatic reuse cannot claim automatic evidence")
        if (
            owner["workflow_run_id"] != release_run_id
            or original["workflow_run_id"] != release_run_id
            or consumer["workflow_run_id"] != release_run_id
            or owner["run_number"] != consumer["run_number"]
            or owner["run_attempt"] != original["run_attempt"]
        ):
            raise VerificationError("non-automatic reuse has conflicting release ownership")
    return document


def write_admission(args: argparse.Namespace) -> dict:
    intent_contents = Path(args.intent).read_bytes()
    intent = validate_intent(strict_json_bytes(intent_contents, "release intent"))
    provenance_contents = Path(args.provenance).read_bytes()
    provenance = validate_release_provenance(
        strict_json_bytes(provenance_contents, "release provenance")
    )
    head_contents = Path(args.head_check).read_bytes()
    head = validate_head_check_document(
        strict_json_bytes(head_contents, "release head check")
    )
    if (
        intent["repository"] != args.repository
        or intent["source_sha"] != args.source_sha
        or provenance["source_sha"] != args.source_sha
        or head["repository"] != args.repository
        or head["source_sha"] != args.source_sha
        or intent["product"]["build_number"] != args.build_number
        or provenance["product"]["build_number"] != args.build_number
        or intent["product"]["asc_app_id"] != args.asc_app_id
    ):
        raise VerificationError("release admission inputs disagree on source or build")
    for field in (
        "canonical_version",
        "marketing_version",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        if provenance["product"][field] != intent["product"][field]:
            raise VerificationError(f"release admission provenance has the wrong {field}")
    producer = {
        "workflow_run_id": args.release_workflow_run_id,
        "run_number": args.release_run_number,
        "run_attempt": args.release_run_attempt,
    }
    if (
        intent["release"] != producer
        or head["authoritative_ci"]["workflow_run_id"]
        != intent["authoritative_ci"]["workflow_run_id"]
        or head["authoritative_ci"]["run_attempt"]
        != intent["authoritative_ci"]["run_attempt"]
        or head["authoritative_ci"]["completed_at"]
        != intent["authoritative_ci"]["completed_at"]
        or head["release"]["workflow_run_id"] != producer["workflow_run_id"]
        or head["release"]["run_attempt"] != producer["run_attempt"]
    ):
        raise VerificationError("release admission head check has the wrong producer")
    prior_admission_digest = None
    reuse_digest = None
    if args.prior_admission or args.reuse_provenance:
        if not args.prior_admission or not args.reuse_provenance:
            raise VerificationError("reuse admission requires prior admission and reuse binding")
        prior_contents = Path(args.prior_admission).read_bytes()
        prior = validate_admission(
            strict_json_bytes(prior_contents, "prior release admission")
        )
        reuse_contents = Path(args.reuse_provenance).read_bytes()
        reuse = validate_reuse_provenance(
            strict_json_bytes(reuse_contents, "reuse provenance")
        )
        reuse_product = {
            "canonical_version": intent["product"]["canonical_version"],
            "marketing_version": intent["product"]["marketing_version"],
            "build_number": intent["product"]["build_number"],
            "app_bundle_id": intent["product"]["app_bundle_id"],
            "extension_bundle_id": intent["product"]["extension_bundle_id"],
            "ipa_sha256": provenance["product"]["ipa_sha256"],
        }
        if (
            prior["repository"] != args.repository
            or prior["source_sha"] != args.source_sha
            or prior["intent_key"] != intent["intent_key"]
            or prior["product"] != intent["product"]
            or prior["owner"] != intent["owner"]
            or prior["asc"] != {"app_id": args.asc_app_id, "build_id": args.asc_build_id}
            or reuse["repository"] != args.repository
            or reuse["source_sha"] != args.source_sha
            or reuse["intent_key"] != intent["intent_key"]
            or reuse["product"] != reuse_product
            or reuse["asc"] != {"app_id": args.asc_app_id, "build_id": args.asc_build_id}
            or reuse["owner"] != intent["owner"]
            or reuse["original"]["workflow_run_id"]
            != provenance["github"]["run_id"]
            or reuse["original"]["run_attempt"]
            != provenance["github"]["run_attempt"]
            or reuse["original"]["provenance_sha256"]
            != sha256_bytes(provenance_contents)
            or reuse["original"]["intent_sha256"]
            != prior["evidence"]["intent_sha256"]
            or reuse["original"]["admission_sha256"]
            != sha256_bytes(prior_contents)
            or reuse["consumer"]
            != {**producer, "intent_sha256": sha256_bytes(intent_contents)}
        ):
            raise VerificationError("reuse admission does not continue its authenticated predecessor")
        prior_admission_digest = sha256_bytes(prior_contents)
        reuse_digest = sha256_bytes(reuse_contents)
    elif provenance["github"] != {
        "run_id": producer["workflow_run_id"],
        "run_attempt": producer["run_attempt"],
    }:
        raise VerificationError("fresh release admission provenance has the wrong producer")
    if utc_timestamp(args.admitted_at, "admission admitted_at") < utc_timestamp(
        head["checked_at"], "head-check checked_at"
    ):
        raise VerificationError("release admission predates its head check")
    document = {
        "schema": ADMISSION_SCHEMA,
        "repository": args.repository,
        "intent_key": intent["intent_key"],
        "source_sha": args.source_sha,
        "product": intent["product"],
        "owner": intent["owner"],
        "asc": {"app_id": args.asc_app_id, "build_id": args.asc_build_id},
        "evidence": {
            "intent_sha256": sha256_bytes(intent_contents),
            "release_provenance_sha256": sha256_bytes(provenance_contents),
            "head_check_sha256": sha256_bytes(head_contents),
            "prior_admission_sha256": prior_admission_digest,
            "reuse_provenance_sha256": reuse_digest,
        },
        "producer": producer,
        "admitted_at": args.admitted_at,
    }
    validate_admission(document)
    write_document(document, Path(args.output))
    return document


def validate_receipt(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "authoritative_ci",
            "product",
            "owner",
            "delivery",
            "evidence",
            "producer",
        },
        "release receipt",
    )
    if document["schema"] != RECEIPT_SCHEMA:
        raise VerificationError("release receipt schema is unsupported")
    repository = require_string(document["repository"], "receipt.repository")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise VerificationError("receipt repository must be an owner/name slug")
    source_sha = require_string(document["source_sha"], "receipt.source_sha")
    if not SHA_PATTERN.fullmatch(source_sha):
        raise VerificationError("receipt source SHA must be a lowercase full commit id")

    ci = document["authoritative_ci"]
    if not isinstance(ci, dict):
        raise VerificationError("receipt authoritative_ci must be an object")
    require_exact_keys(ci, {"workflow_run_id", "run_number"}, "receipt.authoritative_ci")
    ci_id = positive_identifier(str(ci["workflow_run_id"]), "receipt CI run id")
    ci_number = positive_identifier(str(ci["run_number"]), "receipt CI run number")
    if document["intent_key"] != f"github-ci-run:{ci_id}":
        raise VerificationError("release receipt key does not bind the CI run")

    product = document["product"]
    if not isinstance(product, dict):
        raise VerificationError("receipt product must be an object")
    require_exact_keys(
        product,
        {
            "asc_app_id",
            "scheme",
            "configuration",
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
        },
        "receipt.product",
    )
    for field in (
        "asc_app_id",
        "scheme",
        "configuration",
        "canonical_version",
        "marketing_version",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        require_string(product[field], f"receipt product {field}")
    build_number = require_hosted_build(product["build_number"], "receipt build number")

    for owner_name in ("owner", "producer"):
        owner = document[owner_name]
        if not isinstance(owner, dict):
            raise VerificationError(f"receipt {owner_name} must be an object")
        require_exact_keys(
            owner,
            {"workflow_run_id", "run_number", "run_attempt"},
            f"receipt.{owner_name}",
        )
        for field in ("workflow_run_id", "run_number", "run_attempt"):
            positive_identifier(str(owner[field]), f"receipt {owner_name} {field}")
    if build_number != automatic_build_number(str(document["owner"]["run_number"])):
        raise VerificationError("receipt build number is not owned by its release allocation")

    delivery = document["delivery"]
    if not isinstance(delivery, dict):
        raise VerificationError("receipt delivery must be an object")
    require_exact_keys(
        delivery,
        {"channel", "asc_build_id", "testflight_group_id", "completed_at"},
        "receipt.delivery",
    )
    if delivery["channel"] != "internal":
        raise VerificationError("automatic release receipt must describe internal delivery")
    require_string(delivery["asc_build_id"], "receipt ASC build id")
    require_string(delivery["testflight_group_id"], "receipt TestFlight group id")
    utc_timestamp(require_string(delivery["completed_at"], "receipt completed_at"), "receipt completed_at")

    evidence = document["evidence"]
    if not isinstance(evidence, dict):
        raise VerificationError("receipt evidence must be an object")
    require_exact_keys(
        evidence,
        {
            "intent_sha256",
            "admission_sha256",
            "release_provenance_sha256",
            "head_check_sha256",
            "reuse_provenance_sha256",
        },
        "receipt.evidence",
    )
    for field, value in evidence.items():
        if field == "reuse_provenance_sha256" and value is None:
            continue
        require_digest(value, f"receipt {field}")
    return document


def write_receipt(args: argparse.Namespace) -> dict:
    intent_contents = Path(args.intent).read_bytes()
    intent = validate_intent(strict_json_bytes(intent_contents, "release intent"))
    if intent["repository"] != args.repository or intent["source_sha"] != args.source_sha:
        raise VerificationError("receipt does not match its release intent source")
    if intent["authoritative_ci"]["workflow_run_id"] != args.ci_workflow_run_id:
        raise VerificationError("receipt does not match its authoritative CI run")
    if intent["product"]["build_number"] != args.build_number:
        raise VerificationError("receipt does not match its release intent build")
    if utc_timestamp(args.completed_at, "receipt completed_at") < utc_timestamp(
        intent["created_at"], "intent created_at"
    ):
        raise VerificationError("receipt predates its release intent")
    provenance_contents = Path(args.provenance).read_bytes()
    provenance = validate_release_provenance(
        strict_json_bytes(provenance_contents, "release provenance")
    )
    if provenance["source_sha"] != args.source_sha:
        raise VerificationError("receipt provenance has the wrong source")
    for field in (
        "canonical_version",
        "marketing_version",
        "build_number",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        if provenance["product"][field] != intent["product"][field]:
            raise VerificationError(f"receipt provenance has the wrong {field}")

    head_contents = Path(args.head_check).read_bytes()
    head = validate_head_check_document(
        strict_json_bytes(head_contents, "release head check")
    )
    producer = {
        "workflow_run_id": args.release_workflow_run_id,
        "run_number": args.release_run_number,
        "run_attempt": args.release_run_attempt,
    }
    if (
        head["repository"] != args.repository
        or head["source_sha"] != args.source_sha
        or head["authoritative_ci"]["workflow_run_id"] != args.ci_workflow_run_id
        or head["authoritative_ci"]["run_attempt"]
        != intent["authoritative_ci"]["run_attempt"]
        or head["authoritative_ci"]["completed_at"]
        != intent["authoritative_ci"]["completed_at"]
        or head["release"]["workflow_run_id"] != args.release_workflow_run_id
        or head["release"]["run_attempt"] != args.release_run_attempt
        or intent["release"] != producer
    ):
        raise VerificationError("receipt head check has the wrong source or producer")

    admission_contents = Path(args.admission).read_bytes()
    admission = validate_admission(
        strict_json_bytes(admission_contents, "release admission")
    )
    if (
        admission["repository"] != args.repository
        or admission["source_sha"] != args.source_sha
        or admission["intent_key"] != intent["intent_key"]
        or admission["product"] != intent["product"]
        or admission["owner"] != intent["owner"]
        or admission["producer"] != producer
        or admission["asc"]["app_id"] != intent["product"]["asc_app_id"]
        or admission["asc"]["build_id"] != args.asc_build_id
        or admission["evidence"]["intent_sha256"] != sha256_bytes(intent_contents)
        or admission["evidence"]["release_provenance_sha256"] != sha256_bytes(provenance_contents)
        or admission["evidence"]["head_check_sha256"] != sha256_bytes(head_contents)
    ):
        raise VerificationError("receipt admission does not bind its exact evidence")
    completed_at = utc_timestamp(args.completed_at, "receipt completed_at")
    if completed_at < utc_timestamp(
        admission["admitted_at"], "admission admitted_at"
    ) or completed_at < utc_timestamp(head["checked_at"], "head-check checked_at"):
        raise VerificationError("receipt predates its admission or head check")

    reuse_digest = None
    if args.reuse_provenance:
        reuse_contents = Path(args.reuse_provenance).read_bytes()
        reuse = validate_reuse_provenance(
            strict_json_bytes(reuse_contents, "reuse provenance")
        )
        expected_reuse_product = {
            "canonical_version": intent["product"]["canonical_version"],
            "marketing_version": intent["product"]["marketing_version"],
            "build_number": intent["product"]["build_number"],
            "app_bundle_id": intent["product"]["app_bundle_id"],
            "extension_bundle_id": intent["product"]["extension_bundle_id"],
            "ipa_sha256": provenance["product"]["ipa_sha256"],
        }
        if (
            reuse["repository"] != args.repository
            or reuse["intent_key"] != intent["intent_key"]
            or reuse["source_sha"] != args.source_sha
            or reuse["product"] != expected_reuse_product
            or reuse["asc"]
            != {"app_id": intent["product"]["asc_app_id"], "build_id": args.asc_build_id}
            or reuse["owner"] != intent["owner"]
            or reuse["consumer"]
            != {
                "workflow_run_id": args.release_workflow_run_id,
                "run_number": args.release_run_number,
                "run_attempt": args.release_run_attempt,
                "intent_sha256": sha256_bytes(intent_contents),
            }
            or reuse["original"]["workflow_run_id"]
            != provenance["github"]["run_id"]
            or reuse["original"]["run_attempt"]
            != provenance["github"]["run_attempt"]
            or reuse["original"]["provenance_sha256"]
            != sha256_bytes(provenance_contents)
            or reuse["original"]["admission_sha256"]
            != admission["evidence"]["prior_admission_sha256"]
            or admission["evidence"]["reuse_provenance_sha256"]
            != sha256_bytes(reuse_contents)
        ):
            raise VerificationError("receipt reuse binding has the wrong source or producer")
        reuse_digest = sha256_bytes(reuse_contents)
    if not args.reuse_provenance:
        if provenance["github"] != {
            "run_id": args.release_workflow_run_id,
            "run_attempt": args.release_run_attempt,
        }:
            raise VerificationError("fresh receipt provenance was not produced by this attempt")
        if (
            admission["evidence"]["prior_admission_sha256"] is not None
            or admission["evidence"]["reuse_provenance_sha256"] is not None
        ):
            raise VerificationError("fresh receipt admission unexpectedly claims reuse evidence")
    document = {
        "schema": RECEIPT_SCHEMA,
        "repository": args.repository,
        "intent_key": intent["intent_key"],
        "source_sha": args.source_sha,
        "authoritative_ci": {
            "workflow_run_id": intent["authoritative_ci"]["workflow_run_id"],
            "run_number": intent["authoritative_ci"]["run_number"],
        },
        "product": intent["product"],
        "owner": intent["owner"],
        "delivery": {
            "channel": "internal",
            "asc_build_id": args.asc_build_id,
            "testflight_group_id": args.testflight_group_id,
            "completed_at": args.completed_at,
        },
        "evidence": {
            "intent_sha256": sha256_bytes(intent_contents),
            "admission_sha256": sha256_bytes(admission_contents),
            "release_provenance_sha256": sha256_bytes(provenance_contents),
            "head_check_sha256": sha256_bytes(head_contents),
            "reuse_provenance_sha256": reuse_digest,
        },
        "producer": producer,
    }
    validate_receipt(document)
    write_document(document, Path(args.output))
    return document


def validate_release_identity(value: Any, owner: str) -> dict:
    if not isinstance(value, dict):
        raise VerificationError(f"{owner} must be an object")
    require_exact_keys(
        value,
        {"workflow_run_id", "run_number", "run_attempt"},
        owner,
    )
    for field in ("workflow_run_id", "run_number", "run_attempt"):
        positive_identifier(str(value[field]), f"{owner} {field}")
    return value


def validate_direct_trigger(value: Any, owner: str) -> dict:
    if not isinstance(value, dict):
        raise VerificationError(f"{owner} must be an object")
    require_exact_keys(value, {"event", "ref_type", "ref_name", "channel"}, owner)
    for field in ("event", "ref_type", "ref_name", "channel"):
        require_string(value[field], f"{owner} {field}")
    event = value["event"]
    if event == "push":
        if value["ref_type"] != "tag" or value["channel"] != "external":
            raise VerificationError("direct tag trigger must describe external tag delivery")
    elif event == "workflow_dispatch":
        if (
            value["ref_type"] != "branch"
            or value["ref_name"] != "main"
            or value["channel"] not in {"internal", "external"}
        ):
            raise VerificationError("direct manual trigger must describe live main delivery")
    else:
        raise VerificationError("direct release trigger event is unsupported")
    return value


def validate_direct_product(value: Any, owner: str) -> dict:
    if not isinstance(value, dict):
        raise VerificationError(f"{owner} must be an object")
    require_exact_keys(
        value,
        {
            "asc_app_id",
            "scheme",
            "configuration",
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
        },
        owner,
    )
    for field, item in value.items():
        require_string(item, f"{owner} {field}")
    require_hosted_build(value["build_number"], f"{owner} build number")
    return value


def validate_direct_intent(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "created_at",
            "trigger",
            "product",
            "owner",
            "producer",
            "resolution",
        },
        "direct release intent",
    )
    if document["schema"] != DIRECT_INTENT_SCHEMA:
        raise VerificationError("direct release intent schema is unsupported")
    repository = require_string(document["repository"], "direct intent repository")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise VerificationError("direct intent repository must be an owner/name slug")
    source_sha = require_string(document["source_sha"], "direct intent source SHA")
    if not SHA_PATTERN.fullmatch(source_sha):
        raise VerificationError("direct intent source SHA must be a full commit id")
    utc_timestamp(
        require_string(document["created_at"], "direct intent created_at"),
        "direct intent created_at",
    )
    trigger = validate_direct_trigger(document["trigger"], "direct intent trigger")
    product = validate_direct_product(document["product"], "direct intent product")
    owner = validate_release_identity(document["owner"], "direct intent owner")
    producer = validate_release_identity(
        document["producer"], "direct intent producer"
    )
    if document["intent_key"] != f"github-release-run:{owner['workflow_run_id']}":
        raise VerificationError("direct intent key does not bind its release run")
    if producer["workflow_run_id"] != owner["workflow_run_id"]:
        raise VerificationError("direct intent producer escaped its release run")
    if product["build_number"] != hosted_build_number(str(owner["run_number"]), 2):
        raise VerificationError("direct intent build is not owned by its release run")
    if trigger["event"] == "push" and trigger["channel"] != "external":
        raise VerificationError("tag intent channel is invalid")

    resolution = document["resolution"]
    if not isinstance(resolution, dict):
        raise VerificationError("direct intent resolution must be an object")
    require_exact_keys(
        resolution,
        {"state", "previous_intent_sha256", "completion_receipt_sha256"},
        "direct intent resolution",
    )
    state = resolution["state"]
    previous = resolution["previous_intent_sha256"]
    receipt = resolution["completion_receipt_sha256"]
    if state == "new":
        if previous is not None or receipt is not None or owner != producer:
            raise VerificationError("new direct intent cannot reference prior evidence")
    elif state == "resume":
        require_digest(previous, "direct intent previous digest")
        if receipt is not None:
            raise VerificationError("resumable direct intent cannot reference a receipt")
    elif state == "completed":
        require_digest(previous, "direct intent previous digest")
        require_digest(receipt, "direct intent completion receipt")
    else:
        raise VerificationError("direct intent resolution state is unsupported")
    return document


def write_direct_intent(args: argparse.Namespace) -> dict:
    document = {
        "schema": DIRECT_INTENT_SCHEMA,
        "repository": args.repository,
        "intent_key": f"github-release-run:{args.release_workflow_run_id}",
        "source_sha": args.source_sha,
        "created_at": args.created_at,
        "trigger": {
            "event": args.event,
            "ref_type": args.ref_type,
            "ref_name": args.ref_name,
            "channel": args.channel,
        },
        "product": {
            "asc_app_id": args.asc_app_id,
            "scheme": args.scheme,
            "configuration": args.configuration,
            "canonical_version": args.canonical_version,
            "marketing_version": args.marketing_version,
            "build_number": args.build_number,
            "app_bundle_id": args.app_bundle_id,
            "extension_bundle_id": args.extension_bundle_id,
        },
        "owner": {
            "workflow_run_id": args.owner_release_workflow_run_id,
            "run_number": args.owner_release_run_number,
            "run_attempt": args.owner_release_run_attempt,
        },
        "producer": {
            "workflow_run_id": args.release_workflow_run_id,
            "run_number": args.release_run_number,
            "run_attempt": args.release_run_attempt,
        },
        "resolution": {
            "state": args.resolution_state,
            "previous_intent_sha256": args.previous_intent_sha256 or None,
            "completion_receipt_sha256": args.completion_receipt_sha256 or None,
        },
    }
    validate_direct_intent(document)
    write_document(document, Path(args.output))
    return document


def validate_direct_source_check(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "observed_main_sha",
            "mode",
            "source_admitted",
            "checked_at",
            "trigger",
            "release",
        },
        "direct source check",
    )
    if document["schema"] != DIRECT_SOURCE_CHECK_SCHEMA:
        raise VerificationError("direct source-check schema is unsupported")
    if not REPOSITORY_PATTERN.fullmatch(
        require_string(document["repository"], "direct source-check repository")
    ):
        raise VerificationError("direct source-check repository is invalid")
    for field in ("source_sha", "observed_main_sha"):
        if not SHA_PATTERN.fullmatch(
            require_string(document[field], f"direct source-check {field}")
        ):
            raise VerificationError(f"direct source-check {field} is invalid")
    trigger = validate_direct_trigger(
        document["trigger"], "direct source-check trigger"
    )
    release = validate_release_identity(
        document["release"], "direct source-check release"
    )
    if document["intent_key"] != f"github-release-run:{release['workflow_run_id']}":
        raise VerificationError("direct source-check intent key is invalid")
    if document["source_admitted"] is not True:
        raise VerificationError("direct source-check did not admit its source")
    expected_mode = "current-main" if trigger["event"] == "workflow_dispatch" else "main-ancestor"
    if document["mode"] != expected_mode:
        raise VerificationError("direct source-check mode conflicts with its trigger")
    if expected_mode == "current-main" and document["source_sha"] != document["observed_main_sha"]:
        raise VerificationError("manual live source is not the current main head")
    utc_timestamp(
        require_string(document["checked_at"], "direct source-check checked_at"),
        "direct source-check checked_at",
    )
    return document


def write_direct_source_check(args: argparse.Namespace) -> dict:
    document = {
        "schema": DIRECT_SOURCE_CHECK_SCHEMA,
        "repository": args.repository,
        "intent_key": f"github-release-run:{args.release_workflow_run_id}",
        "source_sha": args.source_sha,
        "observed_main_sha": args.observed_main_sha,
        "mode": args.mode,
        "source_admitted": args.source_admitted == "true",
        "checked_at": args.checked_at,
        "trigger": {
            "event": args.event,
            "ref_type": args.ref_type,
            "ref_name": args.ref_name,
            "channel": args.channel,
        },
        "release": {
            "workflow_run_id": args.release_workflow_run_id,
            "run_number": args.release_run_number,
            "run_attempt": args.release_run_attempt,
        },
    }
    validate_direct_source_check(document)
    write_document(document, Path(args.output))
    return document


def validate_direct_admission(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "trigger",
            "product",
            "owner",
            "asc",
            "evidence",
            "producer",
            "admitted_at",
        },
        "direct admission",
    )
    if document["schema"] != DIRECT_ADMISSION_SCHEMA:
        raise VerificationError("direct admission schema is unsupported")
    if not REPOSITORY_PATTERN.fullmatch(
        require_string(document["repository"], "direct admission repository")
    ):
        raise VerificationError("direct admission repository is invalid")
    if not SHA_PATTERN.fullmatch(
        require_string(document["source_sha"], "direct admission source")
    ):
        raise VerificationError("direct admission source is invalid")
    trigger = validate_direct_trigger(document["trigger"], "direct admission trigger")
    product = validate_direct_product(document["product"], "direct admission product")
    owner = validate_release_identity(document["owner"], "direct admission owner")
    producer = validate_release_identity(
        document["producer"], "direct admission producer"
    )
    if (
        document["intent_key"] != f"github-release-run:{owner['workflow_run_id']}"
        or producer["workflow_run_id"] != owner["workflow_run_id"]
        or product["build_number"] != hosted_build_number(str(owner["run_number"]), 2)
    ):
        raise VerificationError("direct admission release ownership is invalid")
    asc = document["asc"]
    if not isinstance(asc, dict):
        raise VerificationError("direct admission ASC binding must be an object")
    require_exact_keys(asc, {"app_id", "build_id"}, "direct admission ASC")
    require_string(asc["app_id"], "direct admission ASC app id")
    require_string(asc["build_id"], "direct admission ASC build id")
    if asc["app_id"] != product["asc_app_id"]:
        raise VerificationError("direct admission ASC app conflicts with its product")
    evidence = document["evidence"]
    if not isinstance(evidence, dict):
        raise VerificationError("direct admission evidence must be an object")
    require_exact_keys(
        evidence,
        {
            "intent_sha256",
            "release_provenance_sha256",
            "source_check_sha256",
            "prior_admission_sha256",
            "reuse_provenance_sha256",
        },
        "direct admission evidence",
    )
    for field, value in evidence.items():
        if field in {"prior_admission_sha256", "reuse_provenance_sha256"} and value is None:
            continue
        require_digest(value, f"direct admission {field}")
    if (evidence["prior_admission_sha256"] is None) != (
        evidence["reuse_provenance_sha256"] is None
    ):
        raise VerificationError("direct admission reuse evidence must be complete")
    utc_timestamp(
        require_string(document["admitted_at"], "direct admission admitted_at"),
        "direct admission admitted_at",
    )
    if trigger != document["trigger"]:
        raise VerificationError("direct admission trigger is invalid")
    return document


def validate_direct_reuse_provenance(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "trigger",
            "product",
            "asc",
            "owner",
            "original",
            "consumer",
        },
        "direct reuse provenance",
    )
    if document["schema"] != DIRECT_REUSE_SCHEMA:
        raise VerificationError("direct reuse schema is unsupported")
    if not REPOSITORY_PATTERN.fullmatch(
        require_string(document["repository"], "direct reuse repository")
    ):
        raise VerificationError("direct reuse repository is invalid")
    if not SHA_PATTERN.fullmatch(
        require_string(document["source_sha"], "direct reuse source")
    ):
        raise VerificationError("direct reuse source is invalid")
    validate_direct_trigger(document["trigger"], "direct reuse trigger")
    product = document["product"]
    if not isinstance(product, dict):
        raise VerificationError("direct reuse product must be an object")
    require_exact_keys(
        product,
        {
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
            "ipa_sha256",
        },
        "direct reuse product",
    )
    for field in (
        "canonical_version",
        "marketing_version",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        require_string(product[field], f"direct reuse product {field}")
    require_hosted_build(product["build_number"], "direct reuse build")
    if not isinstance(product["ipa_sha256"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", product["ipa_sha256"]
    ):
        raise VerificationError("direct reuse IPA digest is invalid")
    asc = document["asc"]
    if not isinstance(asc, dict):
        raise VerificationError("direct reuse ASC binding must be an object")
    require_exact_keys(asc, {"app_id", "build_id"}, "direct reuse ASC")
    require_string(asc["app_id"], "direct reuse ASC app id")
    require_string(asc["build_id"], "direct reuse ASC build id")
    owner = validate_release_identity(document["owner"], "direct reuse owner")
    if (
        document["intent_key"] != f"github-release-run:{owner['workflow_run_id']}"
        or product["build_number"] != hosted_build_number(str(owner["run_number"]), 2)
    ):
        raise VerificationError("direct reuse ownership is invalid")
    original = document["original"]
    consumer = document["consumer"]
    if not isinstance(original, dict) or not isinstance(consumer, dict):
        raise VerificationError("direct reuse producer bindings must be objects")
    require_exact_keys(
        original,
        {
            "workflow_run_id",
            "run_attempt",
            "provenance_sha256",
            "intent_sha256",
            "admission_sha256",
        },
        "direct reuse original",
    )
    require_exact_keys(
        consumer,
        {"workflow_run_id", "run_number", "run_attempt", "intent_sha256"},
        "direct reuse consumer",
    )
    for field in ("workflow_run_id", "run_attempt"):
        positive_identifier(str(original[field]), f"direct reuse original {field}")
    for field in ("workflow_run_id", "run_number", "run_attempt"):
        positive_identifier(str(consumer[field]), f"direct reuse consumer {field}")
    for field in ("provenance_sha256", "intent_sha256", "admission_sha256"):
        require_digest(original[field], f"direct reuse original {field}")
    require_digest(consumer["intent_sha256"], "direct reuse consumer intent")
    if (
        original["workflow_run_id"] != owner["workflow_run_id"]
        or consumer["workflow_run_id"] != owner["workflow_run_id"]
        or consumer["run_number"] != owner["run_number"]
    ):
        raise VerificationError("direct reuse escaped its immutable release run")
    return document


def write_direct_reuse_provenance(args: argparse.Namespace) -> dict:
    intent_contents = Path(args.intent).read_bytes()
    intent = validate_direct_intent(
        strict_json_bytes(intent_contents, "direct release intent")
    )
    admission_contents = Path(args.admission).read_bytes()
    admission = validate_direct_admission(
        strict_json_bytes(admission_contents, "direct release admission")
    )
    provenance_contents = Path(args.provenance).read_bytes()
    provenance = validate_release_provenance(
        strict_json_bytes(provenance_contents, "direct release provenance")
    )
    consumer = {
        "workflow_run_id": args.release_workflow_run_id,
        "run_number": args.release_run_number,
        "run_attempt": args.release_run_attempt,
    }
    expected_product = {
        field: getattr(args, field)
        for field in (
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
        )
    }
    if (
        intent["repository"] != args.repository
        or intent["source_sha"] != args.source_sha
        or intent["producer"] != consumer
        or intent["product"]["asc_app_id"] != args.asc_app_id
        or admission["repository"] != args.repository
        or admission["source_sha"] != args.source_sha
        or admission["intent_key"] != intent["intent_key"]
        or admission["product"] != intent["product"]
        or admission["owner"] != intent["owner"]
        or admission["asc"]
        != {"app_id": args.asc_app_id, "build_id": args.asc_build_id}
        or admission["evidence"]["release_provenance_sha256"]
        != sha256_bytes(provenance_contents)
        or provenance["source_sha"] != args.source_sha
    ):
        raise VerificationError("direct reuse evidence has conflicting custody")
    for field, expected in expected_product.items():
        if intent["product"][field] != expected or provenance["product"][field] != expected:
            raise VerificationError(f"direct reuse evidence has the wrong {field}")
    document = {
        "schema": DIRECT_REUSE_SCHEMA,
        "repository": args.repository,
        "intent_key": intent["intent_key"],
        "source_sha": args.source_sha,
        "trigger": intent["trigger"],
        "product": {
            **expected_product,
            "ipa_sha256": provenance["product"]["ipa_sha256"],
        },
        "asc": {"app_id": args.asc_app_id, "build_id": args.asc_build_id},
        "owner": intent["owner"],
        "original": {
            "workflow_run_id": provenance["github"]["run_id"],
            "run_attempt": provenance["github"]["run_attempt"],
            "provenance_sha256": sha256_bytes(provenance_contents),
            "intent_sha256": admission["evidence"]["intent_sha256"],
            "admission_sha256": sha256_bytes(admission_contents),
        },
        "consumer": {**consumer, "intent_sha256": sha256_bytes(intent_contents)},
    }
    validate_direct_reuse_provenance(document)
    write_document(document, Path(args.output))
    return document


def write_direct_admission(args: argparse.Namespace) -> dict:
    intent_contents = Path(args.intent).read_bytes()
    intent = validate_direct_intent(
        strict_json_bytes(intent_contents, "direct release intent")
    )
    provenance_contents = Path(args.provenance).read_bytes()
    provenance = validate_release_provenance(
        strict_json_bytes(provenance_contents, "direct release provenance")
    )
    source_contents = Path(args.source_check).read_bytes()
    source_check = validate_direct_source_check(
        strict_json_bytes(source_contents, "direct source check")
    )
    producer = {
        "workflow_run_id": args.release_workflow_run_id,
        "run_number": args.release_run_number,
        "run_attempt": args.release_run_attempt,
    }
    if (
        intent["repository"] != args.repository
        or intent["source_sha"] != args.source_sha
        or intent["producer"] != producer
        or intent["product"]["build_number"] != args.build_number
        or intent["product"]["asc_app_id"] != args.asc_app_id
        or provenance["source_sha"] != args.source_sha
        or provenance["product"]["build_number"] != args.build_number
        or source_check["repository"] != args.repository
        or source_check["source_sha"] != args.source_sha
        or source_check["intent_key"] != intent["intent_key"]
        or source_check["trigger"] != intent["trigger"]
        or source_check["release"] != producer
    ):
        raise VerificationError("direct admission inputs disagree on release identity")
    for field in (
        "canonical_version",
        "marketing_version",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        if provenance["product"][field] != intent["product"][field]:
            raise VerificationError(f"direct admission provenance has wrong {field}")
    prior_digest = None
    reuse_digest = None
    if args.prior_admission or args.reuse_provenance:
        if not args.prior_admission or not args.reuse_provenance:
            raise VerificationError("direct reuse admission requires both predecessor records")
        prior_contents = Path(args.prior_admission).read_bytes()
        prior = validate_direct_admission(
            strict_json_bytes(prior_contents, "prior direct admission")
        )
        reuse_contents = Path(args.reuse_provenance).read_bytes()
        reuse = validate_direct_reuse_provenance(
            strict_json_bytes(reuse_contents, "direct reuse provenance")
        )
        expected_reuse_product = {
            "canonical_version": intent["product"]["canonical_version"],
            "marketing_version": intent["product"]["marketing_version"],
            "build_number": intent["product"]["build_number"],
            "app_bundle_id": intent["product"]["app_bundle_id"],
            "extension_bundle_id": intent["product"]["extension_bundle_id"],
            "ipa_sha256": provenance["product"]["ipa_sha256"],
        }
        if (
            prior["repository"] != args.repository
            or prior["source_sha"] != args.source_sha
            or prior["intent_key"] != intent["intent_key"]
            or prior["product"] != intent["product"]
            or prior["owner"] != intent["owner"]
            or prior["asc"]
            != {"app_id": args.asc_app_id, "build_id": args.asc_build_id}
            or reuse["repository"] != args.repository
            or reuse["source_sha"] != args.source_sha
            or reuse["intent_key"] != intent["intent_key"]
            or reuse["product"] != expected_reuse_product
            or reuse["asc"]
            != {"app_id": args.asc_app_id, "build_id": args.asc_build_id}
            or reuse["owner"] != intent["owner"]
            or reuse["original"]["provenance_sha256"]
            != sha256_bytes(provenance_contents)
            or reuse["original"]["admission_sha256"]
            != sha256_bytes(prior_contents)
            or reuse["consumer"]
            != {**producer, "intent_sha256": sha256_bytes(intent_contents)}
        ):
            raise VerificationError("direct reuse admission breaks evidence custody")
        prior_digest = sha256_bytes(prior_contents)
        reuse_digest = sha256_bytes(reuse_contents)
    elif provenance["github"] != {
        "run_id": producer["workflow_run_id"],
        "run_attempt": producer["run_attempt"],
    }:
        raise VerificationError("fresh direct admission provenance has wrong producer")
    if utc_timestamp(args.admitted_at, "direct admission admitted_at") < utc_timestamp(
        source_check["checked_at"], "direct source-check checked_at"
    ):
        raise VerificationError("direct admission predates its source check")
    document = {
        "schema": DIRECT_ADMISSION_SCHEMA,
        "repository": args.repository,
        "intent_key": intent["intent_key"],
        "source_sha": args.source_sha,
        "trigger": intent["trigger"],
        "product": intent["product"],
        "owner": intent["owner"],
        "asc": {"app_id": args.asc_app_id, "build_id": args.asc_build_id},
        "evidence": {
            "intent_sha256": sha256_bytes(intent_contents),
            "release_provenance_sha256": sha256_bytes(provenance_contents),
            "source_check_sha256": sha256_bytes(source_contents),
            "prior_admission_sha256": prior_digest,
            "reuse_provenance_sha256": reuse_digest,
        },
        "producer": producer,
        "admitted_at": args.admitted_at,
    }
    validate_direct_admission(document)
    write_document(document, Path(args.output))
    return document


def validate_direct_receipt(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "intent_key",
            "source_sha",
            "trigger",
            "product",
            "owner",
            "delivery",
            "evidence",
            "producer",
        },
        "direct receipt",
    )
    if document["schema"] != DIRECT_RECEIPT_SCHEMA:
        raise VerificationError("direct receipt schema is unsupported")
    if not REPOSITORY_PATTERN.fullmatch(
        require_string(document["repository"], "direct receipt repository")
    ) or not SHA_PATTERN.fullmatch(
        require_string(document["source_sha"], "direct receipt source")
    ):
        raise VerificationError("direct receipt repository or source is invalid")
    trigger = validate_direct_trigger(document["trigger"], "direct receipt trigger")
    product = validate_direct_product(document["product"], "direct receipt product")
    owner = validate_release_identity(document["owner"], "direct receipt owner")
    producer = validate_release_identity(document["producer"], "direct receipt producer")
    if (
        document["intent_key"] != f"github-release-run:{owner['workflow_run_id']}"
        or producer["workflow_run_id"] != owner["workflow_run_id"]
        or product["build_number"] != hosted_build_number(str(owner["run_number"]), 2)
    ):
        raise VerificationError("direct receipt ownership is invalid")
    delivery = document["delivery"]
    if not isinstance(delivery, dict):
        raise VerificationError("direct receipt delivery must be an object")
    require_exact_keys(
        delivery,
        {"channel", "asc_build_id", "testflight_group_id", "disposition", "completed_at"},
        "direct receipt delivery",
    )
    if delivery["channel"] != trigger["channel"]:
        raise VerificationError("direct receipt channel conflicts with trigger")
    require_string(delivery["asc_build_id"], "direct receipt ASC build id")
    require_string(delivery["disposition"], "direct receipt disposition")
    group = delivery["testflight_group_id"]
    if group is not None:
        require_string(group, "direct receipt TestFlight group id")
    if delivery["channel"] == "internal" and group is None:
        raise VerificationError("internal direct receipt requires its group id")
    utc_timestamp(
        require_string(delivery["completed_at"], "direct receipt completed_at"),
        "direct receipt completed_at",
    )
    evidence = document["evidence"]
    if not isinstance(evidence, dict):
        raise VerificationError("direct receipt evidence must be an object")
    require_exact_keys(
        evidence,
        {
            "intent_sha256",
            "admission_sha256",
            "release_provenance_sha256",
            "source_check_sha256",
            "reuse_provenance_sha256",
        },
        "direct receipt evidence",
    )
    for field, value in evidence.items():
        if field == "reuse_provenance_sha256" and value is None:
            continue
        require_digest(value, f"direct receipt {field}")
    return document


def write_direct_receipt(args: argparse.Namespace) -> dict:
    intent_contents = Path(args.intent).read_bytes()
    intent = validate_direct_intent(
        strict_json_bytes(intent_contents, "direct release intent")
    )
    admission_contents = Path(args.admission).read_bytes()
    admission = validate_direct_admission(
        strict_json_bytes(admission_contents, "direct release admission")
    )
    provenance_contents = Path(args.provenance).read_bytes()
    provenance = validate_release_provenance(
        strict_json_bytes(provenance_contents, "direct release provenance")
    )
    source_contents = Path(args.source_check).read_bytes()
    source_check = validate_direct_source_check(
        strict_json_bytes(source_contents, "direct source check")
    )
    producer = {
        "workflow_run_id": args.release_workflow_run_id,
        "run_number": args.release_run_number,
        "run_attempt": args.release_run_attempt,
    }
    if (
        intent["repository"] != args.repository
        or intent["source_sha"] != args.source_sha
        or intent["producer"] != producer
        or intent["product"]["build_number"] != args.build_number
        or admission["repository"] != args.repository
        or admission["source_sha"] != args.source_sha
        or admission["intent_key"] != intent["intent_key"]
        or admission["product"] != intent["product"]
        or admission["owner"] != intent["owner"]
        or admission["producer"] != producer
        or admission["asc"]["build_id"] != args.asc_build_id
        or admission["evidence"]["intent_sha256"] != sha256_bytes(intent_contents)
        or admission["evidence"]["release_provenance_sha256"]
        != sha256_bytes(provenance_contents)
        or admission["evidence"]["source_check_sha256"] != sha256_bytes(source_contents)
        or source_check["intent_key"] != intent["intent_key"]
        or source_check["release"] != producer
    ):
        raise VerificationError("direct receipt does not bind exact admission evidence")
    reuse_digest = None
    if args.reuse_provenance:
        reuse_contents = Path(args.reuse_provenance).read_bytes()
        reuse = validate_direct_reuse_provenance(
            strict_json_bytes(reuse_contents, "direct reuse provenance")
        )
        if (
            reuse["repository"] != args.repository
            or reuse["source_sha"] != args.source_sha
            or reuse["intent_key"] != intent["intent_key"]
            or reuse["asc"] != admission["asc"]
            or reuse["consumer"]
            != {**producer, "intent_sha256": sha256_bytes(intent_contents)}
            or admission["evidence"]["reuse_provenance_sha256"]
            != sha256_bytes(reuse_contents)
        ):
            raise VerificationError("direct receipt reuse binding is invalid")
        reuse_digest = sha256_bytes(reuse_contents)
    elif (
        admission["evidence"]["prior_admission_sha256"] is not None
        or admission["evidence"]["reuse_provenance_sha256"] is not None
        or provenance["github"]
        != {"run_id": producer["workflow_run_id"], "run_attempt": producer["run_attempt"]}
    ):
        raise VerificationError("fresh direct receipt has unexpected reuse custody")
    completed_at = utc_timestamp(args.completed_at, "direct receipt completed_at")
    if completed_at < utc_timestamp(admission["admitted_at"], "direct admission admitted_at"):
        raise VerificationError("direct receipt predates admission")
    group_id = args.testflight_group_id or None
    document = {
        "schema": DIRECT_RECEIPT_SCHEMA,
        "repository": args.repository,
        "intent_key": intent["intent_key"],
        "source_sha": args.source_sha,
        "trigger": intent["trigger"],
        "product": intent["product"],
        "owner": intent["owner"],
        "delivery": {
            "channel": args.channel,
            "asc_build_id": args.asc_build_id,
            "testflight_group_id": group_id,
            "disposition": args.disposition,
            "completed_at": args.completed_at,
        },
        "evidence": {
            "intent_sha256": sha256_bytes(intent_contents),
            "admission_sha256": sha256_bytes(admission_contents),
            "release_provenance_sha256": sha256_bytes(provenance_contents),
            "source_check_sha256": sha256_bytes(source_contents),
            "reuse_provenance_sha256": reuse_digest,
        },
        "producer": producer,
    }
    validate_direct_receipt(document)
    write_document(document, Path(args.output))
    return document


def select_release_state(
    intents: list[tuple[dict, str]],
    admissions: list[tuple[dict, str]],
    receipts: list[tuple[dict, str]],
) -> dict:
    if not intents:
        if admissions or receipts:
            raise VerificationError("release side-effect evidence exists without an intent")
        return {"state": "new"}
    known_intent_digests = {digest for _, digest in intents}
    known_admission_digests = {digest for _, digest in admissions}
    known_receipt_digests = {digest for _, digest in receipts}
    if (
        len(known_intent_digests) != len(intents)
        or len(known_admission_digests) != len(admissions)
        or len(known_receipt_digests) != len(receipts)
    ):
        raise VerificationError("release evidence contains duplicate canonical documents")
    roots = [(intent, digest) for intent, digest in intents if intent["resolution"]["state"] == "new"]
    if len(roots) != 1:
        raise VerificationError("release intent history must contain exactly one root")
    intent_by_digest = {digest: intent for intent, digest in intents}
    successors: dict[str, str] = {}
    for intent, digest in intents:
        resolution = intent["resolution"]
        if resolution["state"] in {"resume", "completed"}:
            previous = resolution["previous_intent_sha256"]
            if previous == digest or previous not in known_intent_digests:
                raise VerificationError("release intent has a broken previous-intent chain")
            if previous in successors:
                raise VerificationError("release intent ancestry is not linear")
            predecessor = intent_by_digest[previous]
            current_order = (
                utc_timestamp(intent["created_at"], "intent created_at"),
                int(intent["release"]["workflow_run_id"]),
                int(intent["release"]["run_attempt"]),
            )
            predecessor_order = (
                utc_timestamp(predecessor["created_at"], "predecessor created_at"),
                int(predecessor["release"]["workflow_run_id"]),
                int(predecessor["release"]["run_attempt"]),
            )
            if current_order <= predecessor_order:
                raise VerificationError("release intent ancestry reverses producer time")
            successors[previous] = digest
        if resolution["state"] == "completed":
            if resolution["completion_receipt_sha256"] not in known_receipt_digests:
                raise VerificationError("completed intent has a broken receipt chain")
    owners = {json.dumps(intent["owner"], sort_keys=True) for intent, _ in intents}
    if len(owners) != 1:
        raise VerificationError("release intent evidence has conflicting owners")
    products = {json.dumps(intent["product"], sort_keys=True) for intent, _ in intents}
    sources = {intent["source_sha"] for intent, _ in intents}
    keys = {intent["intent_key"] for intent, _ in intents}
    if len(products) != 1 or len(sources) != 1 or len(keys) != 1:
        raise VerificationError("release intent evidence conflicts on source or product")
    original, original_digest = roots[0]
    cursor = original_digest
    visited = {cursor}
    while cursor in successors:
        cursor = successors[cursor]
        if cursor in visited:
            raise VerificationError("release intent ancestry contains a cycle")
        visited.add(cursor)
    if visited != known_intent_digests:
        raise VerificationError("release intent ancestry is disconnected")
    latest_intent_digest = cursor
    asc_build_ids = set()
    admission_digests = []
    admission_roots = [
        (admission, digest)
        for admission, digest in admissions
        if admission["evidence"]["prior_admission_sha256"] is None
    ]
    if admissions and len(admission_roots) != 1:
        raise VerificationError("release admission history must contain exactly one root")
    admission_by_digest = {digest: admission for admission, digest in admissions}
    admission_successors: dict[str, str] = {}
    for admission, digest in admissions:
        if (
            admission["repository"] != original["repository"]
            or admission["intent_key"] != original["intent_key"]
            or admission["source_sha"] != original["source_sha"]
            or admission["product"] != original["product"]
            or admission["owner"] != original["owner"]
            or admission["evidence"]["intent_sha256"] not in known_intent_digests
        ):
            raise VerificationError("release admission conflicts with its intent")
        asc_build_ids.add(admission["asc"]["build_id"])
        admission_digests.append(digest)
        predecessor_digest = admission["evidence"]["prior_admission_sha256"]
        if predecessor_digest is not None:
            if (
                predecessor_digest == digest
                or predecessor_digest not in known_admission_digests
                or predecessor_digest in admission_successors
            ):
                raise VerificationError("release admission ancestry is broken or branched")
            predecessor = admission_by_digest[predecessor_digest]
            current_order = (
                utc_timestamp(admission["admitted_at"], "admission admitted_at"),
                int(admission["producer"]["workflow_run_id"]),
                int(admission["producer"]["run_attempt"]),
            )
            predecessor_order = (
                utc_timestamp(
                    predecessor["admitted_at"], "prior admission admitted_at"
                ),
                int(predecessor["producer"]["workflow_run_id"]),
                int(predecessor["producer"]["run_attempt"]),
            )
            if current_order <= predecessor_order:
                raise VerificationError("release admission ancestry reverses producer time")
            admission_successors[predecessor_digest] = digest
    if len(asc_build_ids) > 1:
        raise VerificationError("release admissions conflict on App Store Connect build")
    if admissions:
        admission_cursor = admission_roots[0][1]
        admission_visited = {admission_cursor}
        while admission_cursor in admission_successors:
            admission_cursor = admission_successors[admission_cursor]
            if admission_cursor in admission_visited:
                raise VerificationError("release admission ancestry contains a cycle")
            admission_visited.add(admission_cursor)
        if admission_visited != known_admission_digests:
            raise VerificationError("release admission ancestry is disconnected")
    if not receipts:
        state = {
            "state": "resume",
            "owner": original["owner"],
            "product": original["product"],
            "previous_intent_sha256": latest_intent_digest,
        }
        if admissions:
            state["admission"] = {
                "asc_build_id": sorted(asc_build_ids)[0],
                "admission_sha256": admission_cursor,
            }
        return state
    receipt_asc_build_ids = set()
    delivery_signatures = set()
    tail_receipts: list[tuple[dict, str]] = []
    for receipt, digest in receipts:
        if (
            receipt["repository"] != original["repository"]
            or receipt["intent_key"] != original["intent_key"]
            or receipt["source_sha"] != original["source_sha"]
            or receipt["product"] != original["product"]
            or receipt["owner"] != original["owner"]
        ):
            raise VerificationError("completion receipt conflicts with its release intent")
        if receipt["evidence"]["intent_sha256"] not in known_intent_digests:
            raise VerificationError("completion receipt references an unknown intent digest")
        if receipt["evidence"]["admission_sha256"] not in known_admission_digests:
            raise VerificationError("completion receipt references an unknown admission digest")
        receipt_admission = admission_by_digest[receipt["evidence"]["admission_sha256"]]
        if (
            receipt["producer"] != receipt_admission["producer"]
            or receipt["evidence"]["intent_sha256"]
            != receipt_admission["evidence"]["intent_sha256"]
            or receipt["evidence"]["release_provenance_sha256"]
            != receipt_admission["evidence"]["release_provenance_sha256"]
            or receipt["evidence"]["head_check_sha256"]
            != receipt_admission["evidence"]["head_check_sha256"]
            or receipt["evidence"]["reuse_provenance_sha256"]
            != receipt_admission["evidence"]["reuse_provenance_sha256"]
            or utc_timestamp(
                receipt["delivery"]["completed_at"], "receipt completed_at"
            )
            < utc_timestamp(
                receipt_admission["admitted_at"], "receipt admission admitted_at"
            )
        ):
            raise VerificationError("completion receipt conflicts with its admission evidence")
        receipt_asc_build_ids.add(receipt["delivery"]["asc_build_id"])
        delivery_signatures.add(
            (
                receipt["delivery"]["channel"],
                receipt["delivery"]["asc_build_id"],
                receipt["delivery"]["testflight_group_id"],
            )
        )
        if receipt["evidence"]["admission_sha256"] == admission_cursor:
            tail_receipts.append((receipt, digest))
    if len(receipt_asc_build_ids) != 1 or receipt_asc_build_ids != asc_build_ids:
        raise VerificationError("completion receipts conflict on App Store Connect build")
    if len(delivery_signatures) != 1 or not tail_receipts:
        raise VerificationError("completion receipts conflict or do not bind the admission tail")
    selected_receipt, selected_receipt_digest = max(
        tail_receipts,
        key=lambda entry: (
            int(entry[0]["producer"]["workflow_run_id"]),
            int(entry[0]["producer"]["run_attempt"]),
            entry[0]["delivery"]["completed_at"],
        ),
    )
    return {
        "state": "completed",
        "owner": original["owner"],
        "product": original["product"],
        "previous_intent_sha256": latest_intent_digest,
        "completion_receipt_sha256": selected_receipt_digest,
        "admission": {
            "asc_build_id": sorted(asc_build_ids)[0],
            "admission_sha256": admission_cursor,
        },
        "delivery": selected_receipt["delivery"],
    }


def select_direct_release_state(
    intents: list[tuple[dict, str]],
    admissions: list[tuple[dict, str]],
    receipts: list[tuple[dict, str]],
) -> dict:
    if not intents:
        if admissions or receipts:
            raise VerificationError("direct release effects exist without an intent")
        return {"state": "new"}
    intent_by_digest = {digest: value for value, digest in intents}
    admission_by_digest = {digest: value for value, digest in admissions}
    receipt_by_digest = {digest: value for value, digest in receipts}
    if (
        len(intent_by_digest) != len(intents)
        or len(admission_by_digest) != len(admissions)
        or len(receipt_by_digest) != len(receipts)
    ):
        raise VerificationError("direct release evidence contains duplicate documents")

    roots = [
        (value, digest)
        for value, digest in intents
        if value["resolution"]["state"] == "new"
    ]
    if len(roots) != 1:
        raise VerificationError("direct intent history must contain exactly one root")
    root, root_digest = roots[0]
    successors: dict[str, str] = {}
    for value, digest in intents:
        if (
            value["repository"] != root["repository"]
            or value["source_sha"] != root["source_sha"]
            or value["intent_key"] != root["intent_key"]
            or value["trigger"] != root["trigger"]
            or value["product"] != root["product"]
            or value["owner"] != root["owner"]
        ):
            raise VerificationError("direct intent history conflicts on immutable identity")
        resolution = value["resolution"]
        if resolution["state"] in {"resume", "completed"}:
            previous = resolution["previous_intent_sha256"]
            if previous == digest or previous not in intent_by_digest or previous in successors:
                raise VerificationError("direct intent ancestry is broken or branched")
            predecessor = intent_by_digest[previous]
            order = (
                utc_timestamp(value["created_at"], "direct intent created_at"),
                int(value["producer"]["run_attempt"]),
            )
            predecessor_order = (
                utc_timestamp(predecessor["created_at"], "prior direct intent created_at"),
                int(predecessor["producer"]["run_attempt"]),
            )
            if order <= predecessor_order:
                raise VerificationError("direct intent ancestry reverses producer time")
            successors[previous] = digest
        if (
            resolution["state"] == "completed"
            and resolution["completion_receipt_sha256"] not in receipt_by_digest
        ):
            raise VerificationError("completed direct intent has a broken receipt link")
    cursor = root_digest
    visited = {cursor}
    while cursor in successors:
        cursor = successors[cursor]
        if cursor in visited:
            raise VerificationError("direct intent ancestry contains a cycle")
        visited.add(cursor)
    if visited != set(intent_by_digest):
        raise VerificationError("direct intent ancestry is disconnected")
    latest_intent_digest = cursor

    admission_roots = [
        (value, digest)
        for value, digest in admissions
        if value["evidence"]["prior_admission_sha256"] is None
    ]
    if admissions and len(admission_roots) != 1:
        raise VerificationError("direct admission history must contain exactly one root")
    admission_successors: dict[str, str] = {}
    asc_ids: set[str] = set()
    for value, digest in admissions:
        if (
            value["repository"] != root["repository"]
            or value["source_sha"] != root["source_sha"]
            or value["intent_key"] != root["intent_key"]
            or value["trigger"] != root["trigger"]
            or value["product"] != root["product"]
            or value["owner"] != root["owner"]
            or value["evidence"]["intent_sha256"] not in intent_by_digest
        ):
            raise VerificationError("direct admission conflicts with its intent")
        asc_ids.add(value["asc"]["build_id"])
        previous = value["evidence"]["prior_admission_sha256"]
        if previous is not None:
            if previous == digest or previous not in admission_by_digest or previous in admission_successors:
                raise VerificationError("direct admission ancestry is broken or branched")
            predecessor = admission_by_digest[previous]
            order = (
                utc_timestamp(value["admitted_at"], "direct admission admitted_at"),
                int(value["producer"]["run_attempt"]),
            )
            predecessor_order = (
                utc_timestamp(predecessor["admitted_at"], "prior direct admission admitted_at"),
                int(predecessor["producer"]["run_attempt"]),
            )
            if order <= predecessor_order:
                raise VerificationError("direct admission ancestry reverses producer time")
            admission_successors[previous] = digest
    if len(asc_ids) > 1:
        raise VerificationError("direct admissions conflict on ASC build identity")
    admission_tail = None
    if admissions:
        admission_tail = admission_roots[0][1]
        admission_visited = {admission_tail}
        while admission_tail in admission_successors:
            admission_tail = admission_successors[admission_tail]
            if admission_tail in admission_visited:
                raise VerificationError("direct admission ancestry contains a cycle")
            admission_visited.add(admission_tail)
        if admission_visited != set(admission_by_digest):
            raise VerificationError("direct admission ancestry is disconnected")

    if not receipts:
        result = {
            "state": "resume",
            "owner": root["owner"],
            "product": root["product"],
            "trigger": root["trigger"],
            "previous_intent_sha256": latest_intent_digest,
        }
        if admission_tail is not None:
            result["admission"] = {
                "asc_build_id": next(iter(asc_ids)),
                "admission_sha256": admission_tail,
            }
        return result

    tail_receipts: list[tuple[dict, str]] = []
    delivery_signatures = set()
    for value, digest in receipts:
        if (
            value["repository"] != root["repository"]
            or value["source_sha"] != root["source_sha"]
            or value["intent_key"] != root["intent_key"]
            or value["trigger"] != root["trigger"]
            or value["product"] != root["product"]
            or value["owner"] != root["owner"]
            or value["evidence"]["intent_sha256"] not in intent_by_digest
            or value["evidence"]["admission_sha256"] not in admission_by_digest
        ):
            raise VerificationError("direct receipt conflicts with its intent or admission")
        admission = admission_by_digest[value["evidence"]["admission_sha256"]]
        if (
            value["producer"] != admission["producer"]
            or value["delivery"]["asc_build_id"] != admission["asc"]["build_id"]
            or value["evidence"]["intent_sha256"]
            != admission["evidence"]["intent_sha256"]
            or value["evidence"]["release_provenance_sha256"]
            != admission["evidence"]["release_provenance_sha256"]
            or value["evidence"]["source_check_sha256"]
            != admission["evidence"]["source_check_sha256"]
            or value["evidence"]["reuse_provenance_sha256"]
            != admission["evidence"]["reuse_provenance_sha256"]
        ):
            raise VerificationError("direct receipt does not bind its exact admission")
        delivery_signatures.add(
            (
                value["delivery"]["channel"],
                value["delivery"]["asc_build_id"],
                value["delivery"]["testflight_group_id"],
                value["delivery"]["disposition"],
            )
        )
        if value["evidence"]["admission_sha256"] == admission_tail:
            tail_receipts.append((value, digest))
    if len(delivery_signatures) != 1 or not tail_receipts or len(asc_ids) != 1:
        raise VerificationError("direct receipts conflict or miss the admission tail")
    selected, selected_digest = max(
        tail_receipts,
        key=lambda entry: (
            int(entry[0]["producer"]["run_attempt"]),
            entry[0]["delivery"]["completed_at"],
        ),
    )
    return {
        "state": "completed",
        "owner": root["owner"],
        "product": root["product"],
        "trigger": root["trigger"],
        "previous_intent_sha256": latest_intent_digest,
        "completion_receipt_sha256": selected_digest,
        "admission": {
            "asc_build_id": next(iter(asc_ids)),
            "admission_sha256": admission_tail,
        },
        "delivery": selected["delivery"],
    }


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


def trusted_artifact_redirect(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    host = (parsed.hostname or "").lower()
    trusted_host = (
        host.endswith(".blob.core.windows.net")
        or host.endswith(".actions.githubusercontent.com")
        or host.endswith(".githubusercontent.com")
    )
    if parsed.scheme != "https" or not trusted_host or parsed.username or parsed.password:
        raise VerificationError("artifact redirect target is not trusted GitHub storage")
    return url


def unsigned_artifact_request(url: str, user_agent: str) -> urllib.request.Request:
    target = trusted_artifact_redirect(url)
    request = urllib.request.Request(
        target,
        headers={"Accept": "application/zip", "User-Agent": user_agent},
    )
    if request.has_header("Authorization"):
        raise VerificationError("artifact storage request unexpectedly carries authorization")
    return request


class GitHubApi:
    def __init__(self, repository: str, token: str):
        if not REPOSITORY_PATTERN.fullmatch(repository):
            raise VerificationError("repository must be an owner/name slug")
        if not token:
            raise VerificationError("GITHUB_TOKEN is required to verify release evidence")
        self.repository = repository
        self.root = f"https://api.github.com/repos/{repository}"
        self.opener = urllib.request.build_opener(_NoRedirect())
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "tron-ios-release-verifier",
        }

    def _read(self, request: urllib.request.Request) -> bytes:
        with self.opener.open(request, timeout=30) as response:
            contents = response.read(MAX_EVIDENCE_ARCHIVE_BYTES + 1)
        if len(contents) > MAX_EVIDENCE_ARCHIVE_BYTES:
            raise VerificationError("GitHub evidence response exceeds the size limit")
        return contents

    def _request(self, url: str) -> bytes:
        if not url.startswith("https://api.github.com/"):
            raise VerificationError("GitHub API request escaped the trusted API origin")
        last_error: Optional[Exception] = None
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers=self.headers)
                return self._read(request)
            except urllib.error.HTTPError as error:
                last_error = error
                if error.code not in {429, 500, 502, 503, 504}:
                    break
            except (urllib.error.URLError, TimeoutError) as error:
                last_error = error
            if attempt < 2:
                time.sleep(1 << attempt)
        raise VerificationError(f"GitHub evidence request failed: {last_error}")

    def json(self, path: str, query: Optional[dict[str, str]] = None) -> dict:
        if not path.startswith("/") or ".." in path:
            raise VerificationError("GitHub API path is invalid")
        url = self.root + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        try:
            value = json.loads(self._request(url).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise VerificationError("GitHub API returned malformed JSON") from error
        if not isinstance(value, dict):
            raise VerificationError("GitHub API returned a non-object response")
        return value

    def archive(self, url: str, expected_digest: str) -> bytes:
        if not url.startswith(f"{self.root}/actions/artifacts/") or not url.endswith("/zip"):
            raise VerificationError("artifact archive URL is outside the trusted repository")
        request = urllib.request.Request(url, headers=self.headers)
        try:
            self._read(request)
        except urllib.error.HTTPError as error:
            if error.code not in {301, 302, 303, 307, 308}:
                raise VerificationError(f"artifact download failed with HTTP {error.code}") from error
            location = error.headers.get("Location")
        else:
            raise VerificationError("artifact API did not return a signed storage redirect")
        if not location:
            raise VerificationError("artifact API redirect omitted its signed location")
        # Deliberately construct a fresh request: repository credentials never
        # cross from api.github.com to the signed artifact-storage origin.
        unsigned = unsigned_artifact_request(location, self.headers["User-Agent"])
        try:
            contents = self._read(unsigned)
        except urllib.error.HTTPError as error:
            raise VerificationError(f"signed artifact download failed with HTTP {error.code}") from error
        if sha256_bytes(contents) != require_digest(expected_digest, "artifact digest"):
            raise VerificationError("downloaded artifact digest differs from GitHub metadata")
        return contents


def validate_release_workflow_run(
    run: dict, repository: str, source_sha: str, *, automatic_only: bool
) -> dict:
    required = {
        "id",
        "name",
        "path",
        "head_branch",
        "head_sha",
        "run_number",
        "event",
        "run_attempt",
        "repository",
        "head_repository",
    }
    if not required.issubset(run):
        raise VerificationError("release workflow run metadata is incomplete")
    positive_identifier(str(run["id"]), "release workflow run id")
    positive_identifier(str(run["run_number"]), "release workflow run number")
    positive_identifier(str(run["run_attempt"]), "release workflow run attempt")
    if run["name"] != RELEASE_WORKFLOW_NAME:
        raise VerificationError("release evidence came from the wrong workflow name")
    path = require_string(run["path"], "release workflow path").split("@", 1)[0]
    if path != RELEASE_WORKFLOW_PATH:
        raise VerificationError("release evidence came from the wrong workflow path")
    allowed_events = {"workflow_run"} if automatic_only else {"workflow_run", "push", "workflow_dispatch"}
    if run["event"] not in allowed_events:
        raise VerificationError("release evidence came from an unsupported event")
    if run["head_sha"] != source_sha:
        raise VerificationError("release evidence workflow run has the wrong source")
    if automatic_only and run["head_branch"] != "main":
        raise VerificationError("automatic release evidence did not run from main")
    for field in ("repository", "head_repository"):
        value = run[field]
        if not isinstance(value, dict) or value.get("full_name") != repository:
            raise VerificationError("release evidence came from a different repository")
    return run


def safe_artifact_member(archive: bytes, expected_name: str) -> bytes:
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            matches = []
            total_size = 0
            for entry in bundle.infolist():
                path = Path(entry.filename)
                if path.is_absolute() or ".." in path.parts or entry.is_dir():
                    raise VerificationError("release evidence artifact has an unsafe member")
                mode = (entry.external_attr >> 16) & 0o170000
                if mode not in {0, 0o100000}:
                    raise VerificationError("release evidence artifact member is not a regular file")
                if entry.flag_bits & 0x1:
                    raise VerificationError("release evidence artifact member is encrypted")
                if entry.filename != expected_name:
                    raise VerificationError("release evidence artifact contains an unexpected member")
                total_size += entry.file_size
                if total_size > MAX_EVIDENCE_ARCHIVE_BYTES:
                    raise VerificationError("release evidence artifact expands beyond its limit")
                if entry.filename == expected_name:
                    matches.append(entry)
            if len(matches) != 1:
                raise VerificationError(
                    f"release evidence artifact must contain exactly one {expected_name}"
                )
            return bundle.read(matches[0])
    except (zipfile.BadZipFile, RuntimeError) as error:
        raise VerificationError("release evidence artifact is not a readable ZIP archive") from error


def list_run_artifacts(api: GitHubApi, run_id: str) -> list[dict]:
    artifacts = []
    for page in range(1, 11):
        response = api.json(
            f"/actions/runs/{positive_identifier(run_id, 'artifact run id')}/artifacts",
            {"per_page": "100", "page": str(page)},
        )
        page_artifacts = response.get("artifacts")
        if not isinstance(page_artifacts, list):
            raise VerificationError("GitHub artifact listing is malformed")
        if any(not isinstance(artifact, dict) for artifact in page_artifacts):
            raise VerificationError("GitHub artifact metadata is malformed")
        artifacts.extend(page_artifacts)
        if len(page_artifacts) < 100:
            return artifacts
    raise VerificationError("GitHub artifact listing exceeded the verification bound")


def artifact_document(
    api: GitHubApi,
    artifact: dict,
    run: dict,
    expected_name: str,
    expected_file: str,
) -> tuple[dict, str, str]:
    required = {
        "id",
        "name",
        "archive_download_url",
        "expired",
        "digest",
        "workflow_run",
    }
    if not required.issubset(artifact):
        raise VerificationError("release artifact metadata is incomplete")
    if artifact["name"] != expected_name or artifact["expired"] is not False:
        raise VerificationError("release artifact name or expiration state is invalid")
    positive_identifier(str(artifact["id"]), "artifact id")
    digest = require_digest(artifact["digest"], "artifact digest")
    workflow = artifact["workflow_run"]
    if not isinstance(workflow, dict):
        raise VerificationError("artifact workflow metadata is malformed")
    if str(workflow.get("id")) != str(run["id"]):
        raise VerificationError("artifact is not owned by its claimed workflow run")
    if workflow.get("head_sha") != run["head_sha"] or workflow.get("head_branch") != run["head_branch"]:
        raise VerificationError("artifact workflow source metadata conflicts")
    archive = api.archive(artifact["archive_download_url"], digest)
    contents = safe_artifact_member(archive, expected_file)
    return strict_json_bytes(contents, expected_file), sha256_bytes(contents), digest


def resolve_github_release_state(args: argparse.Namespace) -> dict:
    if not SHA_PATTERN.fullmatch(args.source_sha):
        raise VerificationError("source SHA must be a lowercase full commit id")
    ci_run_id = positive_identifier(args.ci_workflow_run_id, "ci_workflow_run_id")
    ci_run_number = positive_identifier(args.ci_run_number, "ci_run_number")
    api = GitHubApi(args.repository, args.github_token)
    response = api.json(
        "/actions/workflows/release-ios.yml/runs",
        {
            "event": "workflow_run",
            "head_sha": args.source_sha,
            "per_page": "100",
        },
    )
    runs = response.get("workflow_runs")
    if not isinstance(runs, list) or any(not isinstance(run, dict) for run in runs):
        raise VerificationError("GitHub release workflow listing is malformed")
    if len(runs) >= 100:
        raise VerificationError("release workflow lookup exceeded the verification bound")

    intent_prefix = f"tron-ios-release-intent-{ci_run_id}-"
    receipt_prefix = f"tron-ios-release-receipt-{ci_run_id}-"
    intents: list[tuple[dict, str]] = []
    admissions: list[tuple[dict, str]] = []
    receipts: list[tuple[dict, str]] = []
    artifact_custody: dict[str, str] = {}
    for raw_run in runs:
        run = validate_release_workflow_run(
            raw_run, args.repository, args.source_sha, automatic_only=True
        )
        for artifact in list_run_artifacts(api, str(run["id"])):
            name = artifact.get("name")
            if not isinstance(name, str):
                raise VerificationError("release artifact name is malformed")
            if name.startswith(intent_prefix):
                expected = f"{intent_prefix}{run['id']}-"
                if not name.startswith(expected):
                    raise VerificationError("release intent artifact name has the wrong producer")
                suffix = name[len(expected) :]
                positive_identifier(suffix, "intent artifact run attempt")
                if int(suffix) > int(run["run_attempt"]):
                    raise VerificationError("intent artifact claims a future run attempt")
                intent, digest, artifact_digest = artifact_document(
                    api, artifact, run, name, "ios-release-intent.json"
                )
                validate_intent(intent)
                if (
                    intent["repository"] != args.repository
                    or intent["source_sha"] != args.source_sha
                    or intent["authoritative_ci"]["workflow_run_id"] != ci_run_id
                    or intent["authoritative_ci"]["run_number"] != ci_run_number
                    or intent["release"]["workflow_run_id"] != str(run["id"])
                    or intent["release"]["run_number"] != str(run["run_number"])
                    or intent["release"]["run_attempt"] != suffix
                ):
                    raise VerificationError("release intent content conflicts with its producer")
                intents.append((intent, digest))
                artifact_custody[digest] = artifact_digest
            elif name.startswith(receipt_prefix):
                expected = f"{receipt_prefix}{run['id']}-"
                if not name.startswith(expected):
                    raise VerificationError("release receipt artifact name has the wrong producer")
                suffix = name[len(expected) :]
                positive_identifier(suffix, "receipt artifact run attempt")
                if int(suffix) > int(run["run_attempt"]):
                    raise VerificationError("receipt artifact claims a future run attempt")
                receipt, digest, artifact_digest = artifact_document(
                    api, artifact, run, name, "ios-release-receipt.json"
                )
                validate_receipt(receipt)
                if (
                    receipt["repository"] != args.repository
                    or receipt["source_sha"] != args.source_sha
                    or receipt["authoritative_ci"]["workflow_run_id"] != ci_run_id
                    or receipt["authoritative_ci"]["run_number"] != ci_run_number
                    or receipt["producer"]["workflow_run_id"] != str(run["id"])
                    or receipt["producer"]["run_number"] != str(run["run_number"])
                    or receipt["producer"]["run_attempt"] != suffix
                ):
                    raise VerificationError("release receipt content conflicts with its producer")
                receipts.append((receipt, digest))
                artifact_custody[digest] = artifact_digest
            elif name.startswith("ios-release-admission-"):
                admission, digest, artifact_digest = artifact_document(
                    api, artifact, run, name, "ios-release-admission.json"
                )
                validate_admission(admission)
                if admission["intent_key"] != f"github-ci-run:{ci_run_id}":
                    continue
                suffix = name.rsplit("-", 1)[-1]
                positive_identifier(suffix, "admission artifact run attempt")
                expected_name = (
                    f"ios-release-admission-{admission['product']['build_number']}-"
                    f"{run['id']}-{suffix}"
                )
                if (
                    admission["repository"] != args.repository
                    or admission["source_sha"] != args.source_sha
                    or admission["producer"]["workflow_run_id"] != str(run["id"])
                    or admission["producer"]["run_number"] != str(run["run_number"])
                    or admission["producer"]["run_attempt"] != suffix
                    or name != expected_name
                    or int(suffix) > int(run["run_attempt"])
                ):
                    raise VerificationError("release admission content conflicts with its producer")
                admissions.append((admission, digest))
                artifact_custody[digest] = artifact_digest
    state = select_release_state(intents, admissions, receipts)
    custody = {}
    for field in (
        "previous_intent_sha256",
        "completion_receipt_sha256",
    ):
        if field in state:
            custody[field.replace("_sha256", "_artifact_sha256")] = artifact_custody[
                state[field]
            ]
    if "admission" in state:
        custody["admission_artifact_sha256"] = artifact_custody[
            state["admission"]["admission_sha256"]
        ]
    if custody:
        state["artifact_custody"] = custody
    write_document(state, Path(args.output))
    return state


def resolve_github_direct_release_state(args: argparse.Namespace) -> dict:
    if not SHA_PATTERN.fullmatch(args.source_sha):
        raise VerificationError("direct state source SHA must be a full commit id")
    run_id = positive_identifier(args.release_workflow_run_id, "direct state run id")
    run_number = positive_identifier(
        args.release_run_number, "direct state run number"
    )
    api = GitHubApi(args.repository, args.github_token)
    run = validate_release_workflow_run(
        api.json(f"/actions/runs/{run_id}"),
        args.repository,
        args.source_sha,
        automatic_only=False,
    )
    if (
        str(run["id"]) != run_id
        or str(run["run_number"]) != run_number
        or run["event"] not in {"push", "workflow_dispatch"}
    ):
        raise VerificationError("direct state run identity is invalid")
    intents: list[tuple[dict, str]] = []
    admissions: list[tuple[dict, str]] = []
    receipts: list[tuple[dict, str]] = []
    artifact_custody: dict[str, str] = {}
    intent_prefix = f"tron-ios-direct-release-intent-{run_id}-"
    receipt_prefix = f"tron-ios-direct-release-receipt-{run_id}-"
    for artifact in list_run_artifacts(api, run_id):
        name = artifact.get("name")
        if not isinstance(name, str):
            raise VerificationError("direct release artifact name is malformed")
        if name.startswith(intent_prefix):
            suffix = name[len(intent_prefix) :]
            positive_identifier(suffix, "direct intent artifact attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("direct intent artifact claims a future attempt")
            intent, digest, artifact_digest = artifact_document(
                api, artifact, run, name, "ios-release-direct-intent.json"
            )
            validate_direct_intent(intent)
            if (
                intent["repository"] != args.repository
                or intent["source_sha"] != args.source_sha
                or intent["intent_key"] != f"github-release-run:{run_id}"
                or intent["producer"]["workflow_run_id"] != run_id
                or intent["producer"]["run_number"] != run_number
                or intent["producer"]["run_attempt"] != suffix
            ):
                raise VerificationError("direct intent content conflicts with its producer")
            intents.append((intent, digest))
            artifact_custody[digest] = artifact_digest
        elif name.startswith(receipt_prefix):
            suffix = name[len(receipt_prefix) :]
            positive_identifier(suffix, "direct receipt artifact attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("direct receipt artifact claims a future attempt")
            receipt, digest, artifact_digest = artifact_document(
                api, artifact, run, name, "ios-release-direct-receipt.json"
            )
            validate_direct_receipt(receipt)
            if (
                receipt["repository"] != args.repository
                or receipt["source_sha"] != args.source_sha
                or receipt["intent_key"] != f"github-release-run:{run_id}"
                or receipt["producer"]["workflow_run_id"] != run_id
                or receipt["producer"]["run_number"] != run_number
                or receipt["producer"]["run_attempt"] != suffix
            ):
                raise VerificationError("direct receipt content conflicts with its producer")
            receipts.append((receipt, digest))
            artifact_custody[digest] = artifact_digest
        elif name.startswith("ios-release-direct-admission-"):
            suffix = name.rsplit("-", 1)[-1]
            positive_identifier(suffix, "direct admission artifact attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("direct admission artifact claims a future attempt")
            admission, digest, artifact_digest = artifact_document(
                api, artifact, run, name, "ios-release-direct-admission.json"
            )
            validate_direct_admission(admission)
            expected_name = (
                f"ios-release-direct-admission-{admission['product']['build_number']}-"
                f"{run_id}-{suffix}"
            )
            if (
                admission["repository"] != args.repository
                or admission["source_sha"] != args.source_sha
                or admission["intent_key"] != f"github-release-run:{run_id}"
                or admission["producer"]["workflow_run_id"] != run_id
                or admission["producer"]["run_number"] != run_number
                or admission["producer"]["run_attempt"] != suffix
                or name != expected_name
            ):
                raise VerificationError("direct admission content conflicts with its producer")
            admissions.append((admission, digest))
            artifact_custody[digest] = artifact_digest
    state = select_direct_release_state(intents, admissions, receipts)
    custody = {}
    for field in ("previous_intent_sha256", "completion_receipt_sha256"):
        if field in state:
            custody[field.replace("_sha256", "_artifact_sha256")] = artifact_custody[
                state[field]
            ]
    if "admission" in state:
        custody["admission_artifact_sha256"] = artifact_custody[
            state["admission"]["admission_sha256"]
        ]
    if custody:
        state["artifact_custody"] = custody
    write_document(state, Path(args.output))
    return state


def validate_release_provenance(document: dict) -> dict:
    require_exact_keys(
        document, {"schema", "source_sha", "github", "toolchain", "product"},
        "release provenance",
    )
    if document["schema"] != SCHEMA:
        raise VerificationError("release provenance schema is unsupported")
    source_sha = require_string(document["source_sha"], "provenance source_sha")
    if not SHA_PATTERN.fullmatch(source_sha):
        raise VerificationError("provenance source SHA must be a lowercase full commit id")
    github = document["github"]
    if not isinstance(github, dict):
        raise VerificationError("provenance github owner must be an object")
    require_exact_keys(github, {"run_id", "run_attempt"}, "provenance.github")
    positive_identifier(str(github["run_id"]), "provenance run id")
    positive_identifier(str(github["run_attempt"]), "provenance run attempt")
    toolchain = document["toolchain"]
    if not isinstance(toolchain, dict):
        raise VerificationError("provenance toolchain must be an object")
    require_exact_keys(
        toolchain,
        {"xcode_version", "xcode_build", "sdk", "deployment_target"},
        "provenance.toolchain",
    )
    for field, value in toolchain.items():
        require_string(value, f"provenance toolchain {field}")
    product = document["product"]
    if not isinstance(product, dict):
        raise VerificationError("provenance product must be an object")
    require_exact_keys(
        product,
        {
            "canonical_version",
            "marketing_version",
            "build_number",
            "app_bundle_id",
            "extension_bundle_id",
            "app_executable_sha256",
            "share_extension_executable_sha256",
            "ipa_sha256",
        },
        "provenance.product",
    )
    for field in (
        "canonical_version",
        "marketing_version",
        "app_bundle_id",
        "extension_bundle_id",
    ):
        require_string(product[field], f"provenance product {field}")
    require_hosted_build(product["build_number"], "provenance build number")
    for field in (
        "app_executable_sha256",
        "share_extension_executable_sha256",
        "ipa_sha256",
    ):
        value = product[field]
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise VerificationError(f"provenance {field} must be a SHA-256 value")
    return document


def validate_head_check_document(document: dict) -> dict:
    require_exact_keys(
        document,
        {
            "schema",
            "repository",
            "source_sha",
            "current_main_sha",
            "source_is_current_main",
            "checked_at",
            "authoritative_ci",
            "release",
        },
        "head-check evidence",
    )
    if document["schema"] != HEAD_CHECK_SCHEMA:
        raise VerificationError("head-check schema is unsupported")
    repository = require_string(document["repository"], "head-check repository")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise VerificationError("head-check repository must be an owner/name slug")
    for field in ("source_sha", "current_main_sha"):
        value = require_string(document[field], f"head-check {field}")
        if not SHA_PATTERN.fullmatch(value):
            raise VerificationError(f"head-check {field} must be a full commit id")
    if document["source_is_current_main"] is not True:
        raise VerificationError("head-check does not prove the current main source")
    if document["source_sha"] != document["current_main_sha"]:
        raise VerificationError("head-check source differs from current main")
    checked_at = utc_timestamp(
        require_string(document["checked_at"], "head-check checked_at"),
        "head-check checked_at",
    )
    ci = document["authoritative_ci"]
    release = document["release"]
    if not isinstance(ci, dict) or not isinstance(release, dict):
        raise VerificationError("head-check run bindings must be objects")
    require_exact_keys(
        ci, {"workflow_run_id", "run_attempt", "completed_at"},
        "head-check.authoritative_ci",
    )
    require_exact_keys(
        release, {"workflow_run_id", "run_attempt"}, "head-check.release"
    )
    positive_identifier(str(ci["workflow_run_id"]), "head-check CI run id")
    positive_identifier(str(ci["run_attempt"]), "head-check CI run attempt")
    completed = utc_timestamp(
        require_string(ci["completed_at"], "head-check CI completed_at"),
        "head-check CI completed_at",
    )
    if checked_at < completed:
        raise VerificationError("head-check predates authoritative CI completion")
    positive_identifier(str(release["workflow_run_id"]), "head-check release run id")
    positive_identifier(str(release["run_attempt"]), "head-check release run attempt")
    return document


def write_reuse_provenance(args: argparse.Namespace) -> dict:
    if not args.intent or not args.admission:
        raise VerificationError(
            "automatic existing-build reuse requires intent and admission evidence"
        )
    provenance_contents = Path(args.provenance).read_bytes()
    provenance = validate_release_provenance(
        strict_json_bytes(provenance_contents, "release provenance")
    )
    if provenance["source_sha"] != args.source_sha:
        raise VerificationError("reused provenance has the wrong source")
    product = provenance["product"]
    expectations = {
        "canonical_version": args.canonical_version,
        "marketing_version": args.marketing_version,
        "build_number": args.build_number,
        "app_bundle_id": args.app_bundle_id,
        "extension_bundle_id": args.extension_bundle_id,
    }
    for field, expected in expectations.items():
        if product[field] != expected:
            raise VerificationError(f"reused provenance has the wrong {field}")

    intent_contents = Path(args.intent).read_bytes()
    intent = validate_intent(strict_json_bytes(intent_contents, "release intent"))
    consumer = {
        "workflow_run_id": args.release_workflow_run_id,
        "run_number": args.release_run_number,
        "run_attempt": args.release_run_attempt,
    }
    if (
        intent["repository"] != args.repository
        or intent["source_sha"] != args.source_sha
        or intent["release"] != consumer
        or intent["product"]["asc_app_id"] != args.asc_app_id
    ):
        raise VerificationError("reuse intent has the wrong source")
    intent_product = intent["product"]
    for field, expected in expectations.items():
        if intent_product[field] != expected:
            raise VerificationError(f"reuse intent has the wrong {field}")
    intent_key = intent["intent_key"]
    owner = intent["owner"]
    intent_sha = sha256_bytes(intent_contents)
    admission_contents = Path(args.admission).read_bytes()
    admission = validate_admission(
        strict_json_bytes(admission_contents, "release admission")
    )
    if (
        admission["repository"] != args.repository
        or admission["source_sha"] != args.source_sha
        or admission["intent_key"] != intent_key
        or admission["product"] != intent_product
        or admission["owner"] != owner
        or admission["asc"]["app_id"] != args.asc_app_id
        or admission["asc"]["build_id"] != args.asc_build_id
        or admission["evidence"]["release_provenance_sha256"]
        != sha256_bytes(provenance_contents)
    ):
        raise VerificationError("reuse admission does not bind the existing build evidence")
    admission_sha = sha256_bytes(admission_contents)

    document = {
        "schema": REUSE_SCHEMA,
        "repository": args.repository,
        "intent_key": intent_key,
        "source_sha": args.source_sha,
        "product": {
            "canonical_version": product["canonical_version"],
            "marketing_version": product["marketing_version"],
            "build_number": product["build_number"],
            "app_bundle_id": product["app_bundle_id"],
            "extension_bundle_id": product["extension_bundle_id"],
            "ipa_sha256": product["ipa_sha256"],
        },
        "asc": {"app_id": args.asc_app_id, "build_id": args.asc_build_id},
        "owner": owner,
        "original": {
            "workflow_run_id": provenance["github"]["run_id"],
            "run_attempt": provenance["github"]["run_attempt"],
            "provenance_sha256": sha256_bytes(provenance_contents),
            "intent_sha256": admission["evidence"]["intent_sha256"],
            "admission_sha256": admission_sha,
        },
        "consumer": {
            "workflow_run_id": args.release_workflow_run_id,
            "run_number": args.release_run_number,
            "run_attempt": args.release_run_attempt,
            "intent_sha256": intent_sha,
        },
    }
    validate_reuse_provenance(document)
    write_document(document, Path(args.output))
    return document


def fetch_github_provenance(args: argparse.Namespace) -> dict:
    if not SHA_PATTERN.fullmatch(args.source_sha):
        raise VerificationError("source SHA must be a lowercase full commit id")
    require_hosted_build(args.build_number, "expected provenance build number")
    api = GitHubApi(args.repository, args.github_token)
    if not args.intent:
        raise VerificationError(
            "automatic provenance lookup requires an authenticated release intent"
        )
    intent = validate_intent(
        strict_json_bytes(Path(args.intent).read_bytes(), "release intent")
    )
    if intent["repository"] != args.repository or intent["source_sha"] != args.source_sha:
        raise VerificationError("provenance lookup intent has the wrong source")
    if intent["product"]["build_number"] != args.build_number:
        raise VerificationError("provenance lookup intent has the wrong build")

    response = api.json(
        "/actions/workflows/release-ios.yml/runs",
        {"head_sha": args.source_sha, "per_page": "100"},
    )
    runs = response.get("workflow_runs")
    if not isinstance(runs, list) or any(not isinstance(run, dict) for run in runs):
        raise VerificationError("GitHub release workflow listing is malformed")
    if len(runs) >= 100:
        raise VerificationError("provenance workflow lookup exceeded the verification bound")

    candidates: list[tuple[dict, bytes, str]] = []
    admissions: list[tuple[dict, bytes]] = []
    for raw_run in runs:
        run = validate_release_workflow_run(
            raw_run, args.repository, args.source_sha, automatic_only=True
        )
        artifacts = list_run_artifacts(api, str(run["id"]))
        paired_intent = False
        paired_intent_digests: set[str] = set()
        prefix = f"tron-ios-release-intent-{intent['authoritative_ci']['workflow_run_id']}-{run['id']}-"
        for artifact in artifacts:
            name = artifact.get("name")
            if not isinstance(name, str) or not name.startswith(prefix):
                continue
            suffix = name[len(prefix) :]
            positive_identifier(suffix, "paired intent artifact attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("paired intent artifact claims a future attempt")
            paired, _, _ = artifact_document(
                api, artifact, run, name, "ios-release-intent.json"
            )
            validate_intent(paired)
            if (
                paired["repository"] == intent["repository"]
                and paired["source_sha"] == intent["source_sha"]
                and paired["intent_key"] == intent["intent_key"]
                and paired["owner"] == intent["owner"]
                and paired["product"] == intent["product"]
                and paired["release"]["workflow_run_id"] == str(run["id"])
                and paired["release"]["run_number"] == str(run["run_number"])
                and paired["release"]["run_attempt"] == suffix
            ):
                paired_intent = True
                paired_intent_digests.add(sha256_bytes(canonical_json_bytes(paired)))
            else:
                raise VerificationError("provenance producer has a conflicting intent")

        prefix = f"ios-release-provenance-{args.build_number}-{run['id']}-"
        for artifact in artifacts:
            name = artifact.get("name")
            if not isinstance(name, str) or not name.startswith(prefix):
                continue
            if not paired_intent:
                raise VerificationError("release provenance producer lacks its authenticated intent")
            suffix = name[len(prefix) :]
            positive_identifier(suffix, "provenance artifact attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("provenance artifact claims a future attempt")
            provenance, _, artifact_digest = artifact_document(
                api, artifact, run, name, "ios-release-provenance.json"
            )
            validate_release_provenance(provenance)
            if (
                provenance["source_sha"] != args.source_sha
                or provenance["github"]["run_id"] != str(run["id"])
                or provenance["github"]["run_attempt"] != suffix
                or provenance["product"]["canonical_version"] != args.canonical_version
                or provenance["product"]["marketing_version"] != args.marketing_version
                or provenance["product"]["build_number"] != args.build_number
                or provenance["product"]["app_bundle_id"] != args.app_bundle_id
                or provenance["product"]["extension_bundle_id"] != args.extension_bundle_id
            ):
                raise VerificationError("release provenance conflicts with its producer or product")
            # Download once more only to retain the exact canonical producer bytes.
            archive = api.archive(artifact["archive_download_url"], artifact_digest)
            contents = safe_artifact_member(archive, "ios-release-provenance.json")
            candidates.append((provenance, contents, artifact_digest))

        admission_prefix = f"ios-release-admission-{args.build_number}-{run['id']}-"
        for artifact in artifacts:
            name = artifact.get("name")
            if not isinstance(name, str) or not name.startswith(admission_prefix):
                continue
            if not paired_intent:
                raise VerificationError("release admission producer lacks its authenticated intent")
            suffix = name[len(admission_prefix) :]
            positive_identifier(suffix, "admission artifact attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("admission artifact claims a future attempt")
            admission, _, admission_artifact_digest = artifact_document(
                api, artifact, run, name, "ios-release-admission.json"
            )
            validate_admission(admission)
            if (
                admission["repository"] != args.repository
                or admission["source_sha"] != args.source_sha
                or admission["intent_key"] != intent["intent_key"]
                or admission["product"] != intent["product"]
                or admission["owner"] != intent["owner"]
                or admission["producer"]["workflow_run_id"] != str(run["id"])
                or admission["producer"]["run_number"] != str(run["run_number"])
                or admission["producer"]["run_attempt"] != suffix
                or admission["evidence"]["intent_sha256"] not in paired_intent_digests
            ):
                raise VerificationError("release admission conflicts with its producer or intent")
            archive = api.archive(
                artifact["archive_download_url"], admission_artifact_digest
            )
            contents = safe_artifact_member(archive, "ios-release-admission.json")
            admissions.append((admission, contents))

    if not candidates:
        raise VerificationError("existing App Store build has no authenticated release provenance")
    if intent is not None:
        if not admissions:
            raise VerificationError("existing automatic build has no authenticated admission receipt")
        asc_ids = {admission[0]["asc"]["build_id"] for admission in admissions}
        if len(asc_ids) != 1:
            raise VerificationError("automatic admission receipts conflict on ASC build id")
        admitted_provenance = {
            admission[0]["evidence"]["release_provenance_sha256"]
            for admission in admissions
        }
        candidates = [
            candidate
            for candidate in candidates
            if sha256_bytes(candidate[1]) in admitted_provenance
        ]
        if not candidates:
            raise VerificationError("admission receipt does not bind available provenance")
        admission_by_digest = {
            sha256_bytes(contents): (admission, contents)
            for admission, contents in admissions
        }
        roots = [
            digest
            for digest, (admission, _) in admission_by_digest.items()
            if admission["evidence"]["prior_admission_sha256"] is None
        ]
        if len(roots) != 1:
            raise VerificationError("provenance admission chain must contain one root")
        successors = {}
        for digest, (admission, _) in admission_by_digest.items():
            previous = admission["evidence"]["prior_admission_sha256"]
            if previous is None:
                continue
            if previous not in admission_by_digest or previous in successors:
                raise VerificationError("provenance admission chain is broken or branched")
            successors[previous] = digest
        admission_tail = roots[0]
        visited = {admission_tail}
        while admission_tail in successors:
            admission_tail = successors[admission_tail]
            if admission_tail in visited:
                raise VerificationError("provenance admission chain contains a cycle")
            visited.add(admission_tail)
        if visited != set(admission_by_digest):
            raise VerificationError("provenance admission chain is disconnected")
        selected_admission, selected_admission_contents = admission_by_digest[
            admission_tail
        ]
        tail_provenance_digest = selected_admission["evidence"][
            "release_provenance_sha256"
        ]
        candidates = [
            candidate
            for candidate in candidates
            if sha256_bytes(candidate[1]) == tail_provenance_digest
        ]
        if not candidates:
            raise VerificationError("admission-chain tail has no exact provenance producer")
        Path(args.admission_output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.admission_output).write_bytes(selected_admission_contents)

    product_hashes = {
        (
            candidate[0]["product"]["app_executable_sha256"],
            candidate[0]["product"]["share_extension_executable_sha256"],
            candidate[0]["product"]["ipa_sha256"],
        )
        for candidate in candidates
    }
    if len(product_hashes) != 1:
        raise VerificationError("existing build provenance conflicts on executable content")
    candidates.sort(
        key=lambda entry: (
            int(entry[0]["github"]["run_id"]),
            int(entry[0]["github"]["run_attempt"]),
        )
    )
    selected, contents, artifact_digest = candidates[0]
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_bytes(contents)
    metadata = {
        "artifact_sha256": artifact_digest,
        "provenance_sha256": sha256_bytes(contents),
        "producer": selected["github"],
        "admission_sha256": (
            sha256_bytes(selected_admission_contents) if admissions else None
        ),
    }
    write_document(metadata, Path(args.metadata_output))
    return metadata


def fetch_github_direct_provenance(args: argparse.Namespace) -> dict:
    intent_contents = Path(args.intent).read_bytes()
    current_intent = validate_direct_intent(
        strict_json_bytes(intent_contents, "current direct release intent")
    )
    if (
        current_intent["repository"] != args.repository
        or current_intent["source_sha"] != args.source_sha
        or current_intent["product"]["build_number"] != args.build_number
        or current_intent["product"]["canonical_version"] != args.canonical_version
        or current_intent["product"]["marketing_version"] != args.marketing_version
        or current_intent["product"]["app_bundle_id"] != args.app_bundle_id
        or current_intent["product"]["extension_bundle_id"] != args.extension_bundle_id
    ):
        raise VerificationError("direct provenance lookup intent has wrong product identity")
    run_id = positive_identifier(
        args.release_workflow_run_id, "direct provenance run id"
    )
    api = GitHubApi(args.repository, args.github_token)
    run = validate_release_workflow_run(
        api.json(f"/actions/runs/{run_id}"),
        args.repository,
        args.source_sha,
        automatic_only=False,
    )
    if (
        str(run["id"]) != run_id
        or run["event"] not in {"push", "workflow_dispatch"}
        or current_intent["producer"]
        != {
            "workflow_run_id": run_id,
            "run_number": str(run["run_number"]),
            "run_attempt": args.release_run_attempt,
        }
    ):
        raise VerificationError("direct provenance lookup has wrong release producer")
    artifacts = list_run_artifacts(api, run_id)
    intents: list[tuple[dict, str]] = []
    admissions: list[tuple[dict, str]] = []
    admission_bytes: dict[str, bytes] = {}
    candidates: list[tuple[dict, bytes, str]] = []
    intent_prefix = f"tron-ios-direct-release-intent-{run_id}-"
    admission_prefix = f"ios-release-direct-admission-{args.build_number}-{run_id}-"
    provenance_prefix = f"ios-release-provenance-{args.build_number}-{run_id}-"
    for artifact in artifacts:
        name = artifact.get("name")
        if not isinstance(name, str):
            raise VerificationError("direct provenance artifact name is malformed")
        if name.startswith(intent_prefix):
            suffix = name[len(intent_prefix) :]
            positive_identifier(suffix, "direct provenance intent attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("direct provenance intent claims a future attempt")
            value, digest, _ = artifact_document(
                api, artifact, run, name, "ios-release-direct-intent.json"
            )
            validate_direct_intent(value)
            if (
                value["repository"] != args.repository
                or value["source_sha"] != args.source_sha
                or value["intent_key"] != current_intent["intent_key"]
                or value["product"] != current_intent["product"]
                or value["owner"] != current_intent["owner"]
                or value["producer"]["workflow_run_id"] != run_id
                or value["producer"]["run_number"] != str(run["run_number"])
                or value["producer"]["run_attempt"] != suffix
            ):
                raise VerificationError("direct provenance intent conflicts with producer")
            intents.append((value, digest))
        elif name.startswith(admission_prefix):
            suffix = name[len(admission_prefix) :]
            positive_identifier(suffix, "direct provenance admission attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("direct provenance admission claims a future attempt")
            value, digest, artifact_digest = artifact_document(
                api, artifact, run, name, "ios-release-direct-admission.json"
            )
            validate_direct_admission(value)
            if (
                value["repository"] != args.repository
                or value["source_sha"] != args.source_sha
                or value["intent_key"] != current_intent["intent_key"]
                or value["product"] != current_intent["product"]
                or value["owner"] != current_intent["owner"]
                or value["producer"]["workflow_run_id"] != run_id
                or value["producer"]["run_number"] != str(run["run_number"])
                or value["producer"]["run_attempt"] != suffix
            ):
                raise VerificationError("direct provenance admission conflicts with producer")
            archive = api.archive(artifact["archive_download_url"], artifact_digest)
            contents = safe_artifact_member(
                archive, "ios-release-direct-admission.json"
            )
            admissions.append((value, digest))
            admission_bytes[digest] = contents
        elif name.startswith(provenance_prefix):
            suffix = name[len(provenance_prefix) :]
            positive_identifier(suffix, "direct provenance artifact attempt")
            if int(suffix) > int(run["run_attempt"]):
                raise VerificationError("direct provenance artifact claims a future attempt")
            value, _, artifact_digest = artifact_document(
                api, artifact, run, name, "ios-release-provenance.json"
            )
            validate_release_provenance(value)
            if (
                value["source_sha"] != args.source_sha
                or value["github"]
                != {"run_id": run_id, "run_attempt": suffix}
                or value["product"]["canonical_version"] != args.canonical_version
                or value["product"]["marketing_version"] != args.marketing_version
                or value["product"]["build_number"] != args.build_number
                or value["product"]["app_bundle_id"] != args.app_bundle_id
                or value["product"]["extension_bundle_id"] != args.extension_bundle_id
            ):
                raise VerificationError("direct provenance conflicts with its producer")
            archive = api.archive(artifact["archive_download_url"], artifact_digest)
            contents = safe_artifact_member(archive, "ios-release-provenance.json")
            candidates.append((value, contents, artifact_digest))
    if sha256_bytes(intent_contents) not in {digest for _, digest in intents}:
        raise VerificationError("current direct intent lacks durable artifact custody")
    state = select_direct_release_state(intents, admissions, [])
    if "admission" not in state:
        raise VerificationError("existing direct build lacks authenticated admission")
    admission_digest = state["admission"]["admission_sha256"]
    admission = next(
        value for value, digest in admissions if digest == admission_digest
    )
    if admission["asc"]["build_id"] != args.asc_build_id:
        raise VerificationError("direct admission ASC build id conflicts with existing build")
    provenance_digest = admission["evidence"]["release_provenance_sha256"]
    candidates = [
        candidate
        for candidate in candidates
        if sha256_bytes(candidate[1]) == provenance_digest
    ]
    if len(candidates) != 1:
        raise VerificationError("direct admission lacks one exact provenance producer")
    selected, contents, artifact_digest = candidates[0]
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_bytes(contents)
    Path(args.admission_output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.admission_output).write_bytes(admission_bytes[admission_digest])
    metadata = {
        "artifact_sha256": artifact_digest,
        "provenance_sha256": sha256_bytes(contents),
        "producer": selected["github"],
        "admission_sha256": admission_digest,
    }
    write_document(metadata, Path(args.metadata_output))
    return metadata


def fixture_archive(root: Path, build_number: str = "42") -> Path:
    archive = root / "Fixture.xcarchive"
    app = archive / "Products/Applications/TronMobile.app"
    appex = app / "PlugIns/TronShareExtension.appex"
    appex.mkdir(parents=True)
    common = {
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": build_number,
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

        head_check_args = argparse.Namespace(
            repository="example/tron",
            source_sha="0123456789abcdef0123456789abcdef01234567",
            current_main_sha="0123456789abcdef0123456789abcdef01234567",
            checked_at="2026-08-06T12:00:01Z",
            ci_workflow_run_id="100",
            ci_run_attempt="2",
            ci_completed_at="2026-08-06T12:00:00Z",
            release_workflow_run_id="200",
            release_run_attempt="1",
            output=str(root / "head-check.json"),
        )
        head_check = write_head_check(head_check_args)
        if (
            head_check["source_is_current_main"] is not True
            or head_check["authoritative_ci"]["workflow_run_id"] != "100"
            or head_check["release"]["workflow_run_id"] != "200"
        ):
            raise AssertionError("head-check fixture lost its source/run binding")
        for field, bad_value in (
            ("current_main_sha", "f" * 40),
            ("checked_at", "2026-08-06T11:59:59Z"),
            ("repository", "not-a-slug"),
            ("release_run_attempt", "0"),
        ):
            changed = argparse.Namespace(**vars(head_check_args))
            setattr(changed, field, bad_value)
            try:
                write_head_check(changed)
            except VerificationError:
                pass
            else:
                raise AssertionError(f"head-check fixture accepted invalid {field}")

        eligibility_args = argparse.Namespace(
            repository="example/tron",
            source_sha="0123456789abcdef0123456789abcdef01234567",
            observed_main_sha="0123456789abcdef0123456789abcdef01234567",
            checked_at="2026-08-06T12:00:01Z",
            eligible="true",
            ci_workflow_run_id="100",
            ci_run_attempt="2",
            ci_completed_at="2026-08-06T12:00:00Z",
            upstream_event="push",
            upstream_branch="main",
            upstream_conclusion="success",
            release_workflow_run_id="200",
            release_run_attempt="1",
            output=str(root / "eligibility.json"),
        )
        eligibility = write_eligibility(eligibility_args)
        if eligibility["eligible"] is not True:
            raise AssertionError("eligibility fixture rejected exact green main")
        stale = argparse.Namespace(**vars(eligibility_args))
        stale.observed_main_sha = "f" * 40
        stale.eligible = "false"
        if write_eligibility(stale)["eligible"] is not False:
            raise AssertionError("eligibility fixture admitted a stale main source")
        for field, bad_value in (
            ("eligible", "true"),
            ("checked_at", "2026-08-06T11:59:59Z"),
            ("upstream_conclusion", "unknown"),
        ):
            changed = argparse.Namespace(**vars(stale))
            setattr(changed, field, bad_value)
            try:
                write_eligibility(changed)
            except VerificationError:
                pass
            else:
                raise AssertionError(f"eligibility fixture accepted invalid {field}")

        failed_attempt = argparse.Namespace(**vars(eligibility_args))
        failed_attempt.ci_run_attempt = "1"
        failed_attempt.upstream_conclusion = "failure"
        failed_attempt.eligible = "false"
        if write_eligibility(failed_attempt)["eligible"] is not False:
            raise AssertionError("failed first upstream attempt was admitted")
        successful_retry = argparse.Namespace(**vars(eligibility_args))
        successful_retry.ci_run_attempt = "2"
        if write_eligibility(successful_retry)["eligible"] is not True:
            raise AssertionError("successful second upstream attempt was not admitted")

        for owner, expected in (
            ("99", "1000.99.1"),
            ("100", "1001.0.1"),
            ("899999", "9999.99.1"),
        ):
            if automatic_build_number(owner) != expected:
                raise AssertionError(f"hosted build mapping {owner} did not produce {expected}")
        try:
            automatic_build_number("900000")
        except VerificationError:
            pass
        else:
            raise AssertionError("hosted build mapping accepted an overflowing owner")

        hosted = root / "hosted"
        hosted_archive = fixture_archive(hosted, "1000.37.1")
        hosted_ipa = hosted / "Fixture.ipa"
        hosted_ipa.write_bytes(b"hosted fixture ipa")
        source_sha = "0123456789abcdef0123456789abcdef01234567"
        provenance_path = hosted / "ios-release-provenance.json"
        hosted_provenance = write_provenance(
            argparse.Namespace(
                archive=str(hosted_archive),
                ipa=str(hosted_ipa),
                source_sha=source_sha,
                run_id="200",
                run_attempt="1",
                xcode_version="27.0",
                output=str(provenance_path),
            )
        )
        validate_release_provenance(hosted_provenance)

        root_intent_path = hosted / "root" / "ios-release-intent.json"
        root_intent_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            created_at="2026-08-06T12:00:01Z",
            ci_workflow_run_id="100",
            ci_run_number="215",
            ci_run_attempt="2",
            ci_completed_at="2026-08-06T12:00:00Z",
            asc_app_id="1234567890",
            scheme="Tron",
            configuration="Prod",
            canonical_version="1.2.3",
            marketing_version="1.2.3",
            build_number="1000.37.1",
            app_bundle_id="com.example.app",
            extension_bundle_id="com.example.app.ShareExtension",
            owner_release_workflow_run_id="200",
            owner_release_run_number="37",
            owner_release_run_attempt="1",
            release_workflow_run_id="200",
            release_run_number="37",
            release_run_attempt="1",
            resolution_state="new",
            previous_intent_sha256="",
            completion_receipt_sha256="",
            output=str(root_intent_path),
        )
        root_intent = write_intent(root_intent_args)
        root_intent_digest = sha256_bytes(root_intent_path.read_bytes())
        if select_release_state([], [], []) != {"state": "new"}:
            raise AssertionError("empty release evidence did not resolve as new")

        root_head_path = hosted / "root" / "ios-release-head-check.json"
        root_head_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            current_main_sha=source_sha,
            checked_at="2026-08-06T12:00:02Z",
            ci_workflow_run_id="100",
            ci_run_attempt="2",
            ci_completed_at="2026-08-06T12:00:00Z",
            release_workflow_run_id="200",
            release_run_attempt="1",
            output=str(root_head_path),
        )
        write_head_check(root_head_args)
        root_admission_path = hosted / "root" / "ios-release-admission.json"
        root_admission_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            build_number="1000.37.1",
            asc_app_id="1234567890",
            asc_build_id="asc-build-1",
            admitted_at="2026-08-06T12:00:03Z",
            release_workflow_run_id="200",
            release_run_number="37",
            release_run_attempt="1",
            intent=str(root_intent_path),
            provenance=str(provenance_path),
            head_check=str(root_head_path),
            prior_admission="",
            reuse_provenance="",
            output=str(root_admission_path),
        )
        root_admission = write_admission(root_admission_args)
        root_admission_digest = sha256_bytes(root_admission_path.read_bytes())

        resume_intent_path = hosted / "resume" / "ios-release-intent.json"
        resume_intent_args = argparse.Namespace(**vars(root_intent_args))
        resume_intent_args.created_at = "2026-08-06T12:00:04Z"
        resume_intent_args.ci_run_attempt = "3"
        resume_intent_args.release_workflow_run_id = "201"
        resume_intent_args.release_run_number = "38"
        resume_intent_args.release_run_attempt = "1"
        resume_intent_args.resolution_state = "resume"
        resume_intent_args.previous_intent_sha256 = root_intent_digest
        resume_intent_args.output = str(resume_intent_path)
        resume_intent = write_intent(resume_intent_args)
        resume_intent_digest = sha256_bytes(resume_intent_path.read_bytes())

        reuse_path = hosted / "resume" / "ios-release-reuse-provenance.json"
        reuse_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            canonical_version="1.2.3",
            marketing_version="1.2.3",
            build_number="1000.37.1",
            app_bundle_id="com.example.app",
            extension_bundle_id="com.example.app.ShareExtension",
            asc_app_id="1234567890",
            asc_build_id="asc-build-1",
            release_workflow_run_id="201",
            release_run_number="38",
            release_run_attempt="1",
            intent=str(resume_intent_path),
            admission=str(root_admission_path),
            provenance=str(provenance_path),
            output=str(reuse_path),
        )
        reuse_document = write_reuse_provenance(reuse_args)
        validate_reuse_provenance(reuse_document)

        resume_head_path = hosted / "resume" / "ios-release-head-check.json"
        resume_head_args = argparse.Namespace(**vars(root_head_args))
        resume_head_args.checked_at = "2026-08-06T12:00:05Z"
        resume_head_args.ci_run_attempt = "3"
        resume_head_args.release_workflow_run_id = "201"
        resume_head_args.output = str(resume_head_path)
        write_head_check(resume_head_args)
        resume_admission_path = hosted / "resume" / "ios-release-admission.json"
        resume_admission_args = argparse.Namespace(**vars(root_admission_args))
        resume_admission_args.admitted_at = "2026-08-06T12:00:06Z"
        resume_admission_args.release_workflow_run_id = "201"
        resume_admission_args.release_run_number = "38"
        resume_admission_args.intent = str(resume_intent_path)
        resume_admission_args.head_check = str(resume_head_path)
        resume_admission_args.prior_admission = str(root_admission_path)
        resume_admission_args.reuse_provenance = str(reuse_path)
        resume_admission_args.output = str(resume_admission_path)
        resume_admission = write_admission(resume_admission_args)
        resume_admission_digest = sha256_bytes(resume_admission_path.read_bytes())

        receipt_path = hosted / "resume" / "ios-release-receipt.json"
        receipt_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            ci_workflow_run_id="100",
            build_number="1000.37.1",
            asc_build_id="asc-build-1",
            testflight_group_id="group-1",
            completed_at="2026-08-06T12:00:07Z",
            release_workflow_run_id="201",
            release_run_number="38",
            release_run_attempt="1",
            intent=str(resume_intent_path),
            admission=str(resume_admission_path),
            provenance=str(provenance_path),
            head_check=str(resume_head_path),
            reuse_provenance=str(reuse_path),
            output=str(receipt_path),
        )
        receipt = write_receipt(receipt_args)
        receipt_digest = sha256_bytes(receipt_path.read_bytes())
        state = select_release_state(
            [(root_intent, root_intent_digest), (resume_intent, resume_intent_digest)],
            [
                (root_admission, root_admission_digest),
                (resume_admission, resume_admission_digest),
            ],
            [(receipt, receipt_digest)],
        )
        if (
            state["state"] != "completed"
            or state["owner"] != root_intent["owner"]
            or state["previous_intent_sha256"] != resume_intent_digest
            or state["admission"]["asc_build_id"] != "asc-build-1"
            or state["completion_receipt_sha256"] != receipt_digest
        ):
            raise AssertionError("release state lost its linear owner/admission/receipt binding")

        completed_intent_args = argparse.Namespace(**vars(resume_intent_args))
        completed_intent_args.created_at = "2026-08-06T12:00:08Z"
        completed_intent_args.release_workflow_run_id = "202"
        completed_intent_args.release_run_number = "39"
        completed_intent_args.resolution_state = "completed"
        completed_intent_args.previous_intent_sha256 = resume_intent_digest
        completed_intent_args.completion_receipt_sha256 = receipt_digest
        completed_intent_args.output = str(hosted / "completed" / "ios-release-intent.json")
        completed_intent = write_intent(completed_intent_args)
        completed_intent_digest = sha256_bytes(Path(completed_intent_args.output).read_bytes())
        completed_state = select_release_state(
            [
                (root_intent, root_intent_digest),
                (resume_intent, resume_intent_digest),
                (completed_intent, completed_intent_digest),
            ],
            [
                (root_admission, root_admission_digest),
                (resume_admission, resume_admission_digest),
            ],
            [(receipt, receipt_digest)],
        )
        if completed_state["previous_intent_sha256"] != completed_intent_digest:
            raise AssertionError("completed intent did not become the ancestry tail")

        def expect_verification_failure(callback, label):
            try:
                callback()
            except VerificationError:
                return
            raise AssertionError(f"fixture accepted {label}")

        conflicting_owner = json.loads(json.dumps(resume_intent))
        conflicting_owner["owner"]["workflow_run_id"] = "999"
        expect_verification_failure(
            lambda: select_release_state(
                [(root_intent, root_intent_digest), (conflicting_owner, "sha256:" + "9" * 64)],
                [],
                [],
            ),
            "conflicting intent owner",
        )
        conflicting_product = json.loads(json.dumps(resume_intent))
        conflicting_product["product"]["marketing_version"] = "9.9.9"
        expect_verification_failure(
            lambda: select_release_state(
                [(root_intent, root_intent_digest), (conflicting_product, "sha256:" + "8" * 64)],
                [],
                [],
            ),
            "conflicting intent product",
        )
        broken = json.loads(json.dumps(resume_intent))
        broken["resolution"]["previous_intent_sha256"] = "sha256:" + "7" * 64
        expect_verification_failure(
            lambda: select_release_state(
                [(root_intent, root_intent_digest), (broken, "sha256:" + "6" * 64)],
                [],
                [],
            ),
            "broken intent ancestry",
        )
        branch = json.loads(json.dumps(resume_intent))
        branch["release"]["workflow_run_id"] = "203"
        branch["release"]["run_number"] = "40"
        expect_verification_failure(
            lambda: select_release_state(
                [
                    (root_intent, root_intent_digest),
                    (resume_intent, resume_intent_digest),
                    (branch, "sha256:" + "5" * 64),
                ],
                [],
                [],
            ),
            "branched intent ancestry",
        )
        cycle_a = json.loads(json.dumps(resume_intent))
        cycle_b = json.loads(json.dumps(resume_intent))
        cycle_a["resolution"]["previous_intent_sha256"] = "sha256:" + "2" * 64
        cycle_b["resolution"]["previous_intent_sha256"] = "sha256:" + "1" * 64
        expect_verification_failure(
            lambda: select_release_state(
                [(cycle_a, "sha256:" + "1" * 64), (cycle_b, "sha256:" + "2" * 64)],
                [],
                [],
            ),
            "cyclic intent ancestry",
        )

        reversed_intent = json.loads(json.dumps(resume_intent))
        reversed_intent["created_at"] = root_intent["created_at"]
        reversed_intent["release"]["workflow_run_id"] = "199"
        expect_verification_failure(
            lambda: select_release_state(
                [
                    (root_intent, root_intent_digest),
                    (reversed_intent, "sha256:" + "3" * 64),
                ],
                [],
                [],
            ),
            "intent ancestry with reversed producer order",
        )

        malformed_reuse = json.loads(json.dumps(reuse_document))
        malformed_reuse["original"] = []
        expect_verification_failure(
            lambda: validate_reuse_provenance(malformed_reuse),
            "non-object reuse origin",
        )
        extra_reuse_field = json.loads(json.dumps(reuse_document))
        extra_reuse_field["unexpected"] = True
        expect_verification_failure(
            lambda: validate_reuse_provenance(extra_reuse_field),
            "extra reuse evidence field",
        )
        unowned_reuse_build = json.loads(json.dumps(reuse_document))
        unowned_reuse_build["product"]["build_number"] = "1000.38.1"
        expect_verification_failure(
            lambda: validate_reuse_provenance(unowned_reuse_build),
            "reuse build outside its owner allocation",
        )

        mismatched_receipt = json.loads(json.dumps(receipt))
        mismatched_receipt["evidence"]["release_provenance_sha256"] = (
            "sha256:" + "4" * 64
        )
        expect_verification_failure(
            lambda: select_release_state(
                [(root_intent, root_intent_digest), (resume_intent, resume_intent_digest)],
                [
                    (root_admission, root_admission_digest),
                    (resume_admission, resume_admission_digest),
                ],
                [(mismatched_receipt, "sha256:" + "0" * 64)],
            ),
            "receipt with mismatched admission evidence",
        )

        tampered_provenance = json.loads(json.dumps(hosted_provenance))
        tampered_provenance["product"]["marketing_version"] = "9.9.9"
        tampered_path = hosted / "tampered-provenance.json"
        write_document(tampered_provenance, tampered_path)
        tampered_receipt_args = argparse.Namespace(**vars(receipt_args))
        tampered_receipt_args.provenance = str(tampered_path)
        expect_verification_failure(
            lambda: write_receipt(tampered_receipt_args), "tampered receipt provenance"
        )
        wrong_asc_args = argparse.Namespace(**vars(receipt_args))
        wrong_asc_args.asc_build_id = "asc-build-other"
        expect_verification_failure(
            lambda: write_receipt(wrong_asc_args), "receipt ASC id mismatch"
        )
        bare_provenance = json.loads(json.dumps(hosted_provenance))
        bare_provenance["product"]["build_number"] = "42"
        expect_verification_failure(
            lambda: validate_release_provenance(bare_provenance),
            "bare existing build provenance",
        )

        direct_root = hosted / "direct-root"
        direct_archive = fixture_archive(direct_root, "1000.41.2")
        direct_ipa = direct_root / "Fixture.ipa"
        direct_ipa.write_bytes(b"direct fixture ipa")
        direct_provenance_path = direct_root / "ios-release-provenance.json"
        direct_provenance = write_provenance(
            argparse.Namespace(
                archive=str(direct_archive),
                ipa=str(direct_ipa),
                source_sha=source_sha,
                run_id="500",
                run_attempt="1",
                xcode_version="27.0",
                output=str(direct_provenance_path),
            )
        )
        direct_intent_path = direct_root / "ios-release-direct-intent.json"
        direct_intent_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            created_at="2026-08-06T13:00:00Z",
            event="workflow_dispatch",
            ref_type="branch",
            ref_name="main",
            channel="internal",
            asc_app_id="1234567890",
            scheme="Tron",
            configuration="Prod",
            canonical_version="1.2.3",
            marketing_version="1.2.3",
            build_number="1000.41.2",
            app_bundle_id="com.example.app",
            extension_bundle_id="com.example.app.ShareExtension",
            owner_release_workflow_run_id="500",
            owner_release_run_number="41",
            owner_release_run_attempt="1",
            release_workflow_run_id="500",
            release_run_number="41",
            release_run_attempt="1",
            resolution_state="new",
            previous_intent_sha256="",
            completion_receipt_sha256="",
            output=str(direct_intent_path),
        )
        direct_intent = write_direct_intent(direct_intent_args)
        direct_intent_digest = sha256_bytes(direct_intent_path.read_bytes())
        direct_source_path = direct_root / "ios-release-direct-source-check.json"
        direct_source_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            observed_main_sha=source_sha,
            mode="current-main",
            source_admitted="true",
            checked_at="2026-08-06T13:00:01Z",
            event="workflow_dispatch",
            ref_type="branch",
            ref_name="main",
            channel="internal",
            release_workflow_run_id="500",
            release_run_number="41",
            release_run_attempt="1",
            output=str(direct_source_path),
        )
        write_direct_source_check(direct_source_args)
        stale_direct_source = argparse.Namespace(**vars(direct_source_args))
        stale_direct_source.observed_main_sha = "f" * 40
        stale_direct_source.output = str(direct_root / "stale-source.json")
        expect_verification_failure(
            lambda: write_direct_source_check(stale_direct_source),
            "stale manual live source",
        )
        tag_source = argparse.Namespace(**vars(direct_source_args))
        tag_source.event = "push"
        tag_source.ref_type = "tag"
        tag_source.ref_name = "server-v1.2.3"
        tag_source.channel = "external"
        tag_source.mode = "main-ancestor"
        tag_source.observed_main_sha = "f" * 40
        tag_source.output = str(direct_root / "tag-source.json")
        write_direct_source_check(tag_source)

        direct_admission_path = direct_root / "ios-release-direct-admission.json"
        direct_admission_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            build_number="1000.41.2",
            asc_app_id="1234567890",
            asc_build_id="asc-direct-1",
            admitted_at="2026-08-06T13:00:02Z",
            release_workflow_run_id="500",
            release_run_number="41",
            release_run_attempt="1",
            intent=str(direct_intent_path),
            provenance=str(direct_provenance_path),
            source_check=str(direct_source_path),
            prior_admission="",
            reuse_provenance="",
            output=str(direct_admission_path),
        )
        direct_admission = write_direct_admission(direct_admission_args)
        direct_admission_digest = sha256_bytes(direct_admission_path.read_bytes())
        direct_pending = select_direct_release_state(
            [(direct_intent, direct_intent_digest)],
            [(direct_admission, direct_admission_digest)],
            [],
        )
        if (
            direct_pending["state"] != "resume"
            or direct_pending["admission"]["asc_build_id"] != "asc-direct-1"
        ):
            raise AssertionError("direct pending-review state lost authenticated admission")

        direct_retry = hosted / "direct-retry"
        direct_retry_intent_path = direct_retry / "ios-release-direct-intent.json"
        direct_retry_intent_args = argparse.Namespace(**vars(direct_intent_args))
        direct_retry_intent_args.created_at = "2026-08-06T13:00:03Z"
        direct_retry_intent_args.release_run_attempt = "2"
        direct_retry_intent_args.resolution_state = "resume"
        direct_retry_intent_args.previous_intent_sha256 = direct_intent_digest
        direct_retry_intent_args.output = str(direct_retry_intent_path)
        direct_retry_intent = write_direct_intent(direct_retry_intent_args)
        direct_retry_intent_digest = sha256_bytes(direct_retry_intent_path.read_bytes())
        direct_reuse_path = direct_retry / "ios-release-direct-reuse-provenance.json"
        direct_reuse_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            canonical_version="1.2.3",
            marketing_version="1.2.3",
            build_number="1000.41.2",
            app_bundle_id="com.example.app",
            extension_bundle_id="com.example.app.ShareExtension",
            asc_app_id="1234567890",
            asc_build_id="asc-direct-1",
            release_workflow_run_id="500",
            release_run_number="41",
            release_run_attempt="2",
            intent=str(direct_retry_intent_path),
            admission=str(direct_admission_path),
            provenance=str(direct_provenance_path),
            output=str(direct_reuse_path),
        )
        direct_reuse = write_direct_reuse_provenance(direct_reuse_args)
        direct_retry_source_path = direct_retry / "ios-release-direct-source-check.json"
        direct_retry_source_args = argparse.Namespace(**vars(direct_source_args))
        direct_retry_source_args.checked_at = "2026-08-06T13:00:04Z"
        direct_retry_source_args.release_run_attempt = "2"
        direct_retry_source_args.output = str(direct_retry_source_path)
        write_direct_source_check(direct_retry_source_args)
        direct_retry_admission_path = direct_retry / "ios-release-direct-admission.json"
        direct_retry_admission_args = argparse.Namespace(**vars(direct_admission_args))
        direct_retry_admission_args.admitted_at = "2026-08-06T13:00:05Z"
        direct_retry_admission_args.release_run_attempt = "2"
        direct_retry_admission_args.intent = str(direct_retry_intent_path)
        direct_retry_admission_args.source_check = str(direct_retry_source_path)
        direct_retry_admission_args.prior_admission = str(direct_admission_path)
        direct_retry_admission_args.reuse_provenance = str(direct_reuse_path)
        direct_retry_admission_args.output = str(direct_retry_admission_path)
        direct_retry_admission = write_direct_admission(direct_retry_admission_args)
        direct_retry_admission_digest = sha256_bytes(
            direct_retry_admission_path.read_bytes()
        )
        direct_receipt_path = direct_retry / "ios-release-direct-receipt.json"
        direct_receipt_args = argparse.Namespace(
            repository="example/tron",
            source_sha=source_sha,
            build_number="1000.41.2",
            asc_build_id="asc-direct-1",
            channel="internal",
            testflight_group_id="group-1",
            disposition="available-internal-group",
            completed_at="2026-08-06T13:00:06Z",
            release_workflow_run_id="500",
            release_run_number="41",
            release_run_attempt="2",
            intent=str(direct_retry_intent_path),
            admission=str(direct_retry_admission_path),
            provenance=str(direct_provenance_path),
            source_check=str(direct_retry_source_path),
            reuse_provenance=str(direct_reuse_path),
            output=str(direct_receipt_path),
        )
        direct_receipt = write_direct_receipt(direct_receipt_args)
        direct_receipt_digest = sha256_bytes(direct_receipt_path.read_bytes())
        direct_completed = select_direct_release_state(
            [
                (direct_intent, direct_intent_digest),
                (direct_retry_intent, direct_retry_intent_digest),
            ],
            [
                (direct_admission, direct_admission_digest),
                (direct_retry_admission, direct_retry_admission_digest),
            ],
            [(direct_receipt, direct_receipt_digest)],
        )
        if (
            direct_completed["state"] != "completed"
            or direct_completed["completion_receipt_sha256"] != direct_receipt_digest
        ):
            raise AssertionError("direct release receipt did not complete its state")
        wrong_direct_asc = argparse.Namespace(**vars(direct_reuse_args))
        wrong_direct_asc.asc_build_id = "asc-unowned"
        expect_verification_failure(
            lambda: write_direct_reuse_provenance(wrong_direct_asc),
            "direct reuse without exact admission ASC identity",
        )
        tampered_direct = json.loads(json.dumps(direct_retry_admission))
        tampered_direct["evidence"]["release_provenance_sha256"] = "sha256:" + "0" * 64
        expect_verification_failure(
            lambda: select_direct_release_state(
                [
                    (direct_intent, direct_intent_digest),
                    (direct_retry_intent, direct_retry_intent_digest),
                ],
                [
                    (direct_admission, direct_admission_digest),
                    (tampered_direct, direct_retry_admission_digest),
                ],
                [(direct_receipt, direct_receipt_digest)],
            ),
            "tampered direct admission custody",
        )

        valid_redirect = (
            "https://productionresultssa0.blob.core.windows.net/actions-results/"
            "fixture?sig=redacted"
        )
        if trusted_artifact_redirect(valid_redirect) != valid_redirect:
            raise AssertionError("trusted artifact redirect changed")
        unsigned = unsigned_artifact_request(valid_redirect, "fixture")
        if unsigned.has_header("Authorization"):
            raise AssertionError("artifact storage request retained authorization")
        for bad_redirect in (
            "http://productionresultssa0.blob.core.windows.net/actions-results/x",
            "https://example.com/actions-results/x",
            "https://token@example.blob.core.windows.net/actions-results/x",
        ):
            expect_verification_failure(
                lambda value=bad_redirect: trusted_artifact_redirect(value),
                "untrusted artifact redirect",
            )

        def zip_fixture(entries):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as bundle:
                for name, contents, mode in entries:
                    entry = zipfile.ZipInfo(name)
                    entry.external_attr = mode << 16
                    bundle.writestr(entry, contents)
            return buffer.getvalue()

        member_contents = canonical_json_bytes({"fixture": True})
        good_zip = zip_fixture((("evidence.json", member_contents, 0o100600),))
        if safe_artifact_member(good_zip, "evidence.json") != member_contents:
            raise AssertionError("safe artifact member changed producer bytes")
        if sha256_bytes(good_zip) == sha256_bytes(member_contents):
            raise AssertionError("artifact and document digest domains collapsed")
        unsafe_archives = (
            zip_fixture(
                (
                    ("evidence.json", member_contents, 0o100600),
                    ("extra.json", b"{}\n", 0o100600),
                )
            ),
            zip_fixture((("../evidence.json", member_contents, 0o100600),)),
            zip_fixture((("evidence.json", b"target", 0o120777),)),
            zip_fixture(
                (("evidence.json", b"x" * (MAX_EVIDENCE_ARCHIVE_BYTES + 1), 0o100600),)
            ),
        )
        for unsafe in unsafe_archives:
            expect_verification_failure(
                lambda value=unsafe: safe_artifact_member(value, "evidence.json"),
                "unsafe artifact archive",
            )
        encrypted = bytearray(good_zip)
        local_header = encrypted.find(b"PK\x03\x04")
        central_header = encrypted.find(b"PK\x01\x02")
        if local_header < 0 or central_header < 0:
            raise AssertionError("ZIP fixture omitted required headers")
        for offset in (local_header + 6, central_header + 8):
            flags = int.from_bytes(encrypted[offset : offset + 2], "little") | 0x1
            encrypted[offset : offset + 2] = flags.to_bytes(2, "little")
        expect_verification_failure(
            lambda: safe_artifact_member(bytes(encrypted), "evidence.json"),
            "encrypted artifact archive",
        )

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
    head_check = commands.add_parser("head-check")
    head_check.add_argument("--repository", required=True)
    head_check.add_argument("--source-sha", required=True)
    head_check.add_argument("--current-main-sha", required=True)
    head_check.add_argument("--checked-at", required=True)
    head_check.add_argument("--ci-workflow-run-id", required=True)
    head_check.add_argument("--ci-run-attempt", required=True)
    head_check.add_argument("--ci-completed-at", required=True)
    head_check.add_argument("--release-workflow-run-id", required=True)
    head_check.add_argument("--release-run-attempt", required=True)
    head_check.add_argument("--output", required=True)
    eligibility = commands.add_parser("eligibility")
    eligibility.add_argument("--repository", required=True)
    eligibility.add_argument("--source-sha", required=True)
    eligibility.add_argument("--observed-main-sha", required=True)
    eligibility.add_argument("--checked-at", required=True)
    eligibility.add_argument("--eligible", required=True)
    eligibility.add_argument("--ci-workflow-run-id", required=True)
    eligibility.add_argument("--ci-run-attempt", required=True)
    eligibility.add_argument("--ci-completed-at", required=True)
    eligibility.add_argument("--upstream-event", required=True)
    eligibility.add_argument("--upstream-branch", required=True)
    eligibility.add_argument("--upstream-conclusion", required=True)
    eligibility.add_argument("--release-workflow-run-id", required=True)
    eligibility.add_argument("--release-run-attempt", required=True)
    eligibility.add_argument("--output", required=True)
    intent = commands.add_parser("intent")
    intent.add_argument("--repository", required=True)
    intent.add_argument("--source-sha", required=True)
    intent.add_argument("--created-at", required=True)
    intent.add_argument("--ci-workflow-run-id", required=True)
    intent.add_argument("--ci-run-number", required=True)
    intent.add_argument("--ci-run-attempt", required=True)
    intent.add_argument("--ci-completed-at", required=True)
    intent.add_argument("--asc-app-id", required=True)
    intent.add_argument("--scheme", required=True)
    intent.add_argument("--configuration", required=True)
    intent.add_argument("--canonical-version", required=True)
    intent.add_argument("--marketing-version", required=True)
    intent.add_argument("--build-number", required=True)
    intent.add_argument("--app-bundle-id", required=True)
    intent.add_argument("--extension-bundle-id", required=True)
    intent.add_argument("--owner-release-workflow-run-id", required=True)
    intent.add_argument("--owner-release-run-number", required=True)
    intent.add_argument("--owner-release-run-attempt", required=True)
    intent.add_argument("--release-workflow-run-id", required=True)
    intent.add_argument("--release-run-number", required=True)
    intent.add_argument("--release-run-attempt", required=True)
    intent.add_argument("--resolution-state", choices=("new", "resume", "completed"), required=True)
    intent.add_argument("--previous-intent-sha256", default="")
    intent.add_argument("--completion-receipt-sha256", default="")
    intent.add_argument("--output", required=True)
    state = commands.add_parser("github-release-state")
    state.add_argument("--repository", required=True)
    state.add_argument("--source-sha", required=True)
    state.add_argument("--ci-workflow-run-id", required=True)
    state.add_argument("--ci-run-number", required=True)
    state.add_argument("--github-token", required=True)
    state.add_argument("--output", required=True)
    provenance_fetch = commands.add_parser("github-provenance")
    provenance_fetch.add_argument("--repository", required=True)
    provenance_fetch.add_argument("--source-sha", required=True)
    provenance_fetch.add_argument("--build-number", required=True)
    provenance_fetch.add_argument("--canonical-version", required=True)
    provenance_fetch.add_argument("--marketing-version", required=True)
    provenance_fetch.add_argument("--app-bundle-id", required=True)
    provenance_fetch.add_argument("--extension-bundle-id", required=True)
    provenance_fetch.add_argument("--release-workflow-run-id", required=True)
    provenance_fetch.add_argument("--github-token", required=True)
    provenance_fetch.add_argument("--intent", default="")
    provenance_fetch.add_argument("--output", required=True)
    provenance_fetch.add_argument("--metadata-output", required=True)
    provenance_fetch.add_argument("--admission-output", default="")
    reuse = commands.add_parser("reuse-provenance")
    reuse.add_argument("--repository", required=True)
    reuse.add_argument("--source-sha", required=True)
    reuse.add_argument("--canonical-version", required=True)
    reuse.add_argument("--marketing-version", required=True)
    reuse.add_argument("--build-number", required=True)
    reuse.add_argument("--app-bundle-id", required=True)
    reuse.add_argument("--extension-bundle-id", required=True)
    reuse.add_argument("--asc-app-id", required=True)
    reuse.add_argument("--asc-build-id", required=True)
    reuse.add_argument("--release-workflow-run-id", required=True)
    reuse.add_argument("--release-run-number", required=True)
    reuse.add_argument("--release-run-attempt", required=True)
    reuse.add_argument("--intent", default="")
    reuse.add_argument("--admission", default="")
    reuse.add_argument("--provenance", required=True)
    reuse.add_argument("--output", required=True)
    receipt = commands.add_parser("receipt")
    receipt.add_argument("--repository", required=True)
    receipt.add_argument("--source-sha", required=True)
    receipt.add_argument("--ci-workflow-run-id", required=True)
    receipt.add_argument("--build-number", required=True)
    receipt.add_argument("--asc-build-id", required=True)
    receipt.add_argument("--testflight-group-id", required=True)
    receipt.add_argument("--completed-at", required=True)
    receipt.add_argument("--release-workflow-run-id", required=True)
    receipt.add_argument("--release-run-number", required=True)
    receipt.add_argument("--release-run-attempt", required=True)
    receipt.add_argument("--intent", required=True)
    receipt.add_argument("--admission", required=True)
    receipt.add_argument("--provenance", required=True)
    receipt.add_argument("--head-check", required=True)
    receipt.add_argument("--reuse-provenance", default="")
    receipt.add_argument("--output", required=True)
    admission = commands.add_parser("admission")
    admission.add_argument("--repository", required=True)
    admission.add_argument("--source-sha", required=True)
    admission.add_argument("--build-number", required=True)
    admission.add_argument("--asc-app-id", required=True)
    admission.add_argument("--asc-build-id", required=True)
    admission.add_argument("--admitted-at", required=True)
    admission.add_argument("--release-workflow-run-id", required=True)
    admission.add_argument("--release-run-number", required=True)
    admission.add_argument("--release-run-attempt", required=True)
    admission.add_argument("--intent", required=True)
    admission.add_argument("--provenance", required=True)
    admission.add_argument("--head-check", required=True)
    admission.add_argument("--prior-admission", default="")
    admission.add_argument("--reuse-provenance", default="")
    admission.add_argument("--output", required=True)
    direct_intent = commands.add_parser("direct-intent")
    for argument in (
        "repository",
        "source-sha",
        "created-at",
        "event",
        "ref-type",
        "ref-name",
        "channel",
        "asc-app-id",
        "scheme",
        "configuration",
        "canonical-version",
        "marketing-version",
        "build-number",
        "app-bundle-id",
        "extension-bundle-id",
        "owner-release-workflow-run-id",
        "owner-release-run-number",
        "owner-release-run-attempt",
        "release-workflow-run-id",
        "release-run-number",
        "release-run-attempt",
    ):
        direct_intent.add_argument(f"--{argument}", required=True)
    direct_intent.add_argument(
        "--resolution-state", choices=("new", "resume", "completed"), required=True
    )
    direct_intent.add_argument("--previous-intent-sha256", default="")
    direct_intent.add_argument("--completion-receipt-sha256", default="")
    direct_intent.add_argument("--output", required=True)
    direct_state = commands.add_parser("github-direct-release-state")
    for argument in (
        "repository",
        "source-sha",
        "release-workflow-run-id",
        "release-run-number",
        "github-token",
        "output",
    ):
        direct_state.add_argument(f"--{argument}", required=True)
    direct_source = commands.add_parser("direct-source-check")
    for argument in (
        "repository",
        "source-sha",
        "observed-main-sha",
        "mode",
        "source-admitted",
        "checked-at",
        "event",
        "ref-type",
        "ref-name",
        "channel",
        "release-workflow-run-id",
        "release-run-number",
        "release-run-attempt",
        "output",
    ):
        direct_source.add_argument(f"--{argument}", required=True)
    direct_fetch = commands.add_parser("github-direct-provenance")
    for argument in (
        "repository",
        "source-sha",
        "canonical-version",
        "marketing-version",
        "build-number",
        "app-bundle-id",
        "extension-bundle-id",
        "asc-build-id",
        "release-workflow-run-id",
        "release-run-attempt",
        "github-token",
        "intent",
        "output",
        "metadata-output",
        "admission-output",
    ):
        direct_fetch.add_argument(f"--{argument}", required=True)
    direct_reuse = commands.add_parser("direct-reuse-provenance")
    for argument in (
        "repository",
        "source-sha",
        "canonical-version",
        "marketing-version",
        "build-number",
        "app-bundle-id",
        "extension-bundle-id",
        "asc-app-id",
        "asc-build-id",
        "release-workflow-run-id",
        "release-run-number",
        "release-run-attempt",
        "intent",
        "admission",
        "provenance",
        "output",
    ):
        direct_reuse.add_argument(f"--{argument}", required=True)
    direct_admission = commands.add_parser("direct-admission")
    for argument in (
        "repository",
        "source-sha",
        "build-number",
        "asc-app-id",
        "asc-build-id",
        "admitted-at",
        "release-workflow-run-id",
        "release-run-number",
        "release-run-attempt",
        "intent",
        "provenance",
        "source-check",
        "output",
    ):
        direct_admission.add_argument(f"--{argument}", required=True)
    direct_admission.add_argument("--prior-admission", default="")
    direct_admission.add_argument("--reuse-provenance", default="")
    direct_receipt = commands.add_parser("direct-receipt")
    for argument in (
        "repository",
        "source-sha",
        "build-number",
        "asc-build-id",
        "channel",
        "disposition",
        "completed-at",
        "release-workflow-run-id",
        "release-run-number",
        "release-run-attempt",
        "intent",
        "admission",
        "provenance",
        "source-check",
        "output",
    ):
        direct_receipt.add_argument(f"--{argument}", required=True)
    direct_receipt.add_argument("--testflight-group-id", default="")
    direct_receipt.add_argument("--reuse-provenance", default="")
    profile = commands.add_parser("profile-certificate")
    profile.add_argument("--profile-plist", required=True)
    profile.add_argument("--leaf-certificate", required=True)
    diagnostic = commands.add_parser("codesign-diagnostic")
    diagnostic.add_argument("--log", required=True)
    commands.add_parser("self-test")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "archive":
            print(json.dumps(verify_archive(args), sort_keys=True))
        elif args.command == "provenance":
            print(json.dumps(write_provenance(args), sort_keys=True))
        elif args.command == "head-check":
            print(json.dumps(write_head_check(args), sort_keys=True))
        elif args.command == "eligibility":
            print(json.dumps(write_eligibility(args), sort_keys=True))
        elif args.command == "intent":
            print(json.dumps(write_intent(args), sort_keys=True))
        elif args.command == "github-release-state":
            print(json.dumps(resolve_github_release_state(args), sort_keys=True))
        elif args.command == "github-provenance":
            print(json.dumps(fetch_github_provenance(args), sort_keys=True))
        elif args.command == "reuse-provenance":
            print(json.dumps(write_reuse_provenance(args), sort_keys=True))
        elif args.command == "receipt":
            print(json.dumps(write_receipt(args), sort_keys=True))
        elif args.command == "admission":
            print(json.dumps(write_admission(args), sort_keys=True))
        elif args.command == "direct-intent":
            print(json.dumps(write_direct_intent(args), sort_keys=True))
        elif args.command == "github-direct-release-state":
            print(json.dumps(resolve_github_direct_release_state(args), sort_keys=True))
        elif args.command == "direct-source-check":
            print(json.dumps(write_direct_source_check(args), sort_keys=True))
        elif args.command == "github-direct-provenance":
            print(json.dumps(fetch_github_direct_provenance(args), sort_keys=True))
        elif args.command == "direct-reuse-provenance":
            print(json.dumps(write_direct_reuse_provenance(args), sort_keys=True))
        elif args.command == "direct-admission":
            print(json.dumps(write_direct_admission(args), sort_keys=True))
        elif args.command == "direct-receipt":
            print(json.dumps(write_direct_receipt(args), sort_keys=True))
        elif args.command == "profile-certificate":
            print(json.dumps(verify_profile_certificate(args), sort_keys=True))
        elif args.command == "codesign-diagnostic":
            print(
                json.dumps(
                    classify_codesign_log(Path(args.log).resolve()), sort_keys=True
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
