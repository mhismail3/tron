#!/usr/bin/env python3
"""Create and verify immutable evidence for Tron's merge validation.

The v2 document is provider-neutral.  Provider adapters supply normalized
``TRON_CI_*`` values while the current GitHub adapter remains authoritative for
main-branch evidence reuse.  Verification is deliberately fail-closed: any
missing, ambiguous, stale, malformed, or unbound evidence tells the caller to
run the complete validation matrix.

Creation requires an explicit ``TRON_CI_REQUIRED_JOBS_JSON`` result for every
policy-owned job; the evidence core never infers a successful result.

Schema v1 remains readable so evidence produced before the provider-neutral
contract was introduced can expire naturally rather than forcing a validation
gap during rollout.  Successful main reuse also emits a canonical receipt and
preserves the byte-exact downloaded validation-artifact ZIP for independent
reconstruction.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import math
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable

SCHEMA_V1 = "tron.validation.v1"
SCHEMA_V2 = "tron.validation.v2"
SCHEMA = SCHEMA_V2
POLICY_SCHEMA = "tron.ci-policy.v1"
IOS_METRICS_SCHEMA = "tron.ios-ci-metrics.v1"
ARTIFACT_NAME = "tron-merge-validation"
REUSE_RECEIPT_SCHEMA = "tron.validation-reuse-receipt.v1"
GITHUB_PROVIDER = "github-actions"
DEFAULT_POLICY_PATH = Path("config/ci-policy.json")
DEFAULT_TOOLCHAIN_PATH = Path("config/ci-toolchain.env")
HISTORICAL_V1_JOBS = {"rust": "success", "ios": "success", "mac": "success"}
DEFAULT_REQUIRED_JOBS = (
    "personal-info-guard",
    "version-drift",
    "workflow-lint",
    "rust",
    "ios",
    "mac",
)
HEX_DIGEST = re.compile(r"[0-9a-f]{64}")
GIT_OBJECT_ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
SAFE_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,255}")


@dataclass(frozen=True)
class ValidatedCandidate:
    run: dict[str, Any]
    artifact: dict[str, Any]
    archive: bytes
    evidence: dict[str, Any]


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True).strip()


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty string")
    return value


def require_identifier(value: Any, field: str) -> str:
    identifier = require_text(value, field)
    if not SAFE_IDENTIFIER.fullmatch(identifier):
        raise ValueError(f"{field} contains unsupported characters")
    return identifier


def require_positive_int(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{field} must be a positive integer")
    try:
        number = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{field} must be a positive integer") from error
    if number < 1 or str(number) != str(value):
        raise ValueError(f"{field} must be a positive integer")
    return number


def require_git_oid(value: Any, field: str) -> str:
    oid = require_text(value, field)
    if not GIT_OBJECT_ID.fullmatch(oid):
        raise ValueError(f"{field} must be a lowercase Git object ID")
    return oid


def require_sha256(value: Any, field: str, *, prefixed: bool) -> str:
    digest = require_text(value, field)
    raw = digest.removeprefix("sha256:") if prefixed else digest
    if prefixed and not digest.startswith("sha256:"):
        raise ValueError(f"{field} must use the sha256: prefix")
    if not HEX_DIGEST.fullmatch(raw):
        raise ValueError(f"{field} must be a lowercase SHA-256 digest")
    return digest


def sha256_bytes(payload: bytes, *, prefixed: bool = True) -> str:
    value = hashlib.sha256(payload).hexdigest()
    return f"sha256:{value}" if prefixed else value


def canonical_json_bytes(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        raise ValueError("evidence contains a value without canonical JSON encoding") from error
    return encoded.encode("utf-8")


def canonical_digest(value: Any) -> str:
    return sha256_bytes(canonical_json_bytes(value))


def parse_json(payload: str | bytes) -> Any:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"JSON object contains duplicate key {key}")
            value[key] = item
        return value

    def reject_nonfinite(token: str) -> Any:
        raise ValueError(f"JSON contains unsupported numeric value {token}")

    return json.loads(
        payload,
        object_pairs_hook=unique_object,
        parse_constant=reject_nonfinite,
    )


def seal_document(document: dict[str, Any]) -> dict[str, Any]:
    sealed = copy.deepcopy(document)
    sealed.pop("evidence_sha256", None)
    sealed["evidence_sha256"] = canonical_digest(sealed)
    return sealed


def verify_self_digest(document: dict[str, Any]) -> None:
    reported = require_sha256(document.get("evidence_sha256"), "evidence_sha256", prefixed=True)
    unsigned = copy.deepcopy(document)
    unsigned.pop("evidence_sha256", None)
    if reported != canonical_digest(unsigned):
        raise ValueError("evidence canonical self-digest does not match")


def seal_reuse_receipt(receipt: dict[str, Any]) -> dict[str, Any]:
    sealed = copy.deepcopy(receipt)
    sealed.pop("receipt_sha256", None)
    sealed["receipt_sha256"] = canonical_digest(sealed)
    return sealed


def verify_reuse_receipt_digest(receipt: dict[str, Any]) -> None:
    reported = require_sha256(
        receipt.get("receipt_sha256"), "receipt_sha256", prefixed=True
    )
    unsigned = copy.deepcopy(receipt)
    unsigned.pop("receipt_sha256", None)
    if reported != canonical_digest(unsigned):
        raise ValueError("reuse receipt canonical self-digest does not match")


def normalize_provider(value: Any) -> str:
    provider = require_identifier(value, "ci.provider").lower().replace("_", "-")
    aliases = {
        "github": GITHUB_PROVIDER,
        "github-action": GITHUB_PROVIDER,
        "github-actions": GITHUB_PROVIDER,
    }
    return aliases.get(provider, provider)


def first_environment(*names: str, default: str | None = None) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return default


def github_event_payload() -> dict[str, Any]:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        return {}
    payload = parse_json(Path(event_path).read_text())
    if not isinstance(payload, dict):
        raise ValueError("GITHUB_EVENT_PATH must contain a JSON object")
    return payload


def normalized_creation_context() -> dict[str, Any]:
    provider_value = first_environment("TRON_CI_PROVIDER")
    if provider_value is None and first_environment("GITHUB_ACTIONS", "GITHUB_RUN_ID"):
        provider_value = GITHUB_PROVIDER
    provider = normalize_provider(provider_value)
    event_name = require_text(
        first_environment("TRON_CI_EVENT_NAME", "GITHUB_EVENT_NAME"), "ci.event_name"
    ).lower().replace("-", "_")
    if event_name != "pull_request":
        raise ValueError("validation evidence may only be created for pull requests")

    event = github_event_payload() if provider == GITHUB_PROVIDER else {}
    pull = event.get("pull_request", {}) if isinstance(event.get("pull_request"), dict) else {}
    head = pull.get("head", {}) if isinstance(pull.get("head"), dict) else {}
    base = pull.get("base", {}) if isinstance(pull.get("base"), dict) else {}
    number = first_environment("TRON_CI_PR_NUMBER", "TRON_PR_NUMBER")
    head_sha = first_environment("TRON_CI_PR_HEAD_SHA", "TRON_PR_HEAD_SHA")
    base_sha = first_environment("TRON_CI_PR_BASE_SHA", "TRON_PR_BASE_SHA")
    if number is None and pull.get("number") is not None:
        number = str(pull["number"])
    if head_sha is None and head.get("sha") is not None:
        head_sha = str(head["sha"])
    if base_sha is None and base.get("sha") is not None:
        base_sha = str(base["sha"])

    run_id = require_identifier(
        first_environment("TRON_CI_RUN_ID", "GITHUB_RUN_ID"), "ci.run_id"
    )
    run_attempt = require_positive_int(
        first_environment("TRON_CI_RUN_ATTEMPT", "GITHUB_RUN_ATTEMPT", default="1"),
        "ci.run_attempt",
    )
    return {
        "provider": provider,
        "repository": require_text(
            first_environment("TRON_CI_REPOSITORY", "GITHUB_REPOSITORY"), "repository"
        ),
        "run_id": run_id,
        "run_attempt": run_attempt,
        "pull_request": require_positive_int(number, "pull_request.number"),
        "head_sha": require_git_oid(head_sha, "pull_request.head_sha"),
        "base_sha": require_git_oid(base_sha, "pull_request.base_sha"),
    }


def repository_path(path_value: Any, field: str) -> tuple[str, Path]:
    text = require_text(path_value, field)
    pure = PurePosixPath(text)
    if (
        pure.is_absolute()
        or ".." in pure.parts
        or pure.as_posix() in ("", ".")
        or pure.as_posix() != text
        or "\\" in text
    ):
        raise ValueError(f"{field} must be a repository-relative path")
    root = Path.cwd().resolve()
    resolved = (root / Path(*pure.parts)).resolve(strict=True)
    try:
        relative = resolved.relative_to(root).as_posix()
    except ValueError as error:
        raise ValueError(f"{field} resolves outside the repository") from error
    if not resolved.is_file():
        raise ValueError(f"{field} must identify a regular file")
    return relative, resolved


def file_binding(path_value: Any, field: str) -> dict[str, str]:
    relative, resolved = repository_path(path_value, field)
    payload = resolved.read_bytes()
    try:
        committed = subprocess.check_output(["git", "show", f"HEAD:{relative}"])
    except subprocess.CalledProcessError as error:
        raise ValueError(f"{field} must be tracked by the evidence merge commit") from error
    if payload != committed:
        raise ValueError(f"{field} differs from the evidence merge commit")
    return {"path": relative, "sha256": sha256_bytes(payload)}


def policy_contract(
    provider: str,
) -> tuple[
    dict[str, str],
    dict[str, str],
    dict[str, str] | None,
    tuple[str, ...],
]:
    policy_binding = file_binding(str(DEFAULT_POLICY_PATH), "policy.path")
    policy_document = parse_json(Path(policy_binding["path"]).read_text())
    if not isinstance(policy_document, dict) or policy_document.get("schema") != POLICY_SCHEMA:
        raise ValueError("CI policy is missing or uses an unsupported schema")
    providers = policy_document.get("providers")
    if not isinstance(providers, dict) or not isinstance(providers.get(provider), dict):
        raise ValueError(f"CI policy does not define provider {provider}")
    configuration_path = providers[provider].get("configuration_path")
    configuration_binding = file_binding(configuration_path, "configuration.path")
    bootstrap_path = providers[provider].get("bootstrap_configuration_path")
    bootstrap_binding = (
        file_binding(bootstrap_path, "bootstrap_configuration.path")
        if bootstrap_path is not None
        else None
    )
    required_jobs = policy_document.get("required_jobs")
    if (
        not isinstance(required_jobs, list)
        or not required_jobs
        or any(not isinstance(item, str) or not item for item in required_jobs)
        or len(set(required_jobs)) != len(required_jobs)
    ):
        raise ValueError("CI policy required_jobs must be a non-empty unique string list")
    return policy_binding, configuration_binding, bootstrap_binding, tuple(required_jobs)


def toolchain_binding() -> dict[str, str]:
    return file_binding(str(DEFAULT_TOOLCHAIN_PATH), "toolchain.path")


def job_results(required_jobs: tuple[str, ...]) -> dict[str, str]:
    encoded = require_text(
        os.environ.get("TRON_CI_REQUIRED_JOBS_JSON"),
        "TRON_CI_REQUIRED_JOBS_JSON",
    )
    jobs = parse_json(encoded)
    if not isinstance(jobs, dict) or set(jobs) != set(required_jobs):
        raise ValueError("required job results do not match the CI policy")
    if any(jobs.get(name) != "success" for name in required_jobs):
        raise ValueError("validation evidence may only record successful required jobs")
    return {name: "success" for name in required_jobs}


def validate_ios_metrics(
    metrics: Any, *, expected_toolchain_sha256: str | None = None,
) -> dict[str, Any]:
    if not isinstance(metrics, dict) or metrics.get("schema") != IOS_METRICS_SCHEMA:
        raise ValueError("iOS metrics are missing or use an unsupported schema")
    for field in ("build_seconds", "test_seconds", "test_exit_code", "xcresult_summary_sha256"):
        if field not in metrics:
            raise ValueError(f"iOS metrics are missing {field}")
    for field in ("build_seconds", "test_seconds"):
        value = metrics[field]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError(f"iOS metrics {field} must be a finite non-negative number")
    if isinstance(metrics["test_exit_code"], bool) or metrics["test_exit_code"] != 0:
        raise ValueError("iOS metrics do not prove a successful test run")
    require_sha256(metrics["xcresult_summary_sha256"], "ios.xcresult_summary_sha256", prefixed=False)
    if expected_toolchain_sha256 is not None:
        expected_fields = {
            "schema", "build_seconds", "build_exit_code", "test_seconds",
            "test_exit_code", "parallel_workers", "enumerated_tests", "counts",
            "runner_arch", "runner_os", "xcode", "sdk",
            "toolchain_manifest_sha256", "xcresult_summary_sha256",
            "test_enumeration_sha256",
        }
        if set(metrics) != expected_fields:
            raise ValueError("iOS metrics have missing or unsupported v2 fields")
        if isinstance(metrics.get("build_exit_code"), bool) or metrics.get("build_exit_code") != 0:
            raise ValueError("iOS metrics do not prove a successful build")
        parallel_workers = metrics.get("parallel_workers")
        if (
            isinstance(parallel_workers, bool)
            or not isinstance(parallel_workers, int)
            or parallel_workers < 1
        ):
            raise ValueError("iOS metrics parallel_workers must be a positive integer")
        enumerated_tests = metrics.get("enumerated_tests")
        if not isinstance(enumerated_tests, bool):
            raise ValueError("iOS metrics enumerated_tests must be a boolean")
        for field in ("runner_arch", "runner_os", "xcode", "sdk"):
            require_text(metrics.get(field), f"ios.{field}")
        enumeration_digest = metrics.get("test_enumeration_sha256")
        if enumerated_tests:
            require_sha256(
                enumeration_digest, "ios.test_enumeration_sha256", prefixed=False
            )
        elif enumeration_digest is not None:
            raise ValueError(
                "iOS metrics include an enumeration digest without enumeration"
            )
        counts = metrics.get("counts")
        if not isinstance(counts, dict):
            raise ValueError("iOS metrics counts must be an object")
        supported_counts = {
            "totalTestCount", "passedTests", "failedTests", "skippedTests",
            "expectedFailures",
        }
        if set(counts) - supported_counts:
            raise ValueError("iOS metrics counts contain unsupported fields")
        for field, value in counts.items():
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ValueError(f"iOS metrics count {field} must be non-negative")
        total_tests = counts.get("totalTestCount")
        failed_tests = counts.get("failedTests")
        if (
            isinstance(total_tests, bool)
            or not isinstance(total_tests, int)
            or total_tests < 1
        ):
            raise ValueError("iOS metrics must prove at least one executed test")
        if (
            isinstance(failed_tests, bool)
            or not isinstance(failed_tests, int)
            or failed_tests != 0
        ):
            raise ValueError("iOS metrics contain failed tests")
        actual_toolchain = require_sha256(
            metrics.get("toolchain_manifest_sha256"),
            "ios.toolchain_manifest_sha256",
            prefixed=False,
        )
        if actual_toolchain != expected_toolchain_sha256:
            raise ValueError("iOS metrics use a different toolchain manifest")
    canonical_json_bytes(metrics)
    return metrics


def artifact_entry(path: Path, *, output: Path) -> dict[str, Any]:
    if path.is_absolute():
        root = Path.cwd().resolve()
        resolved = path.resolve(strict=True)
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError as error:
            raise ValueError("artifact.path resolves outside the repository") from error
        if not resolved.is_file():
            raise ValueError("artifact.path must identify a regular file")
    else:
        relative, resolved = repository_path(path.as_posix(), "artifact.path")
    if resolved == output.resolve():
        raise ValueError("evidence cannot include itself in its artifact manifest")
    payload = resolved.read_bytes()
    return {"path": relative, "sha256": sha256_bytes(payload), "size": len(payload)}


def artifact_manifest(paths: list[Path], *, output: Path) -> dict[str, Any]:
    entries = sorted((artifact_entry(path, output=output) for path in paths), key=lambda item: item["path"])
    if not entries:
        raise ValueError("v2 evidence requires at least one manifested artifact")
    if len({item["path"] for item in entries}) != len(entries):
        raise ValueError("artifact manifest contains a duplicate path")
    return {
        "algorithm": "sha256",
        "entries": entries,
        "manifest_sha256": canonical_digest(entries),
    }


def unique_input_artifact(paths: list[Path], name: str) -> Path:
    matches = [path for path in paths if path.name == name]
    if len(matches) != 1:
        raise ValueError(f"v2 evidence requires exactly one {name} input artifact")
    path = matches[0]
    return path if path.is_absolute() else Path.cwd() / path


def validate_artifact_manifest(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, dict) or set(value) != {"algorithm", "entries", "manifest_sha256"}:
        raise ValueError("artifact manifest is malformed")
    if value.get("algorithm") != "sha256" or not isinstance(value.get("entries"), list):
        raise ValueError("artifact manifest must use SHA-256 and contain an entry list")
    entries = value["entries"]
    if not entries:
        raise ValueError("artifact manifest must contain at least one entry")
    paths: list[str] = []
    for index, entry in enumerate(entries):
        field = f"artifacts.entries[{index}]"
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "size"}:
            raise ValueError(f"{field} is malformed")
        path = require_text(entry.get("path"), f"{field}.path")
        pure = PurePosixPath(path)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or pure.as_posix() in ("", ".")
            or pure.as_posix() != path
            or "\\" in path
        ):
            raise ValueError(f"{field}.path must be repository-relative")
        require_sha256(entry.get("sha256"), f"{field}.sha256", prefixed=True)
        size = entry.get("size")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ValueError(f"{field}.size must be a non-negative integer")
        paths.append(path)
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise ValueError("artifact manifest paths must be sorted and unique")
    reported = require_sha256(value.get("manifest_sha256"), "artifacts.manifest_sha256", prefixed=True)
    if reported != canonical_digest(entries):
        raise ValueError("artifact manifest digest does not match its entries")
    return entries


def validate_bootstrap_manifest_binding(
    manifest: Any, bootstrap: dict[str, str] | None,
) -> None:
    entries = validate_artifact_manifest(manifest)
    by_name: dict[str, list[dict[str, Any]]] = {}
    for entry in entries:
        by_name.setdefault(PurePosixPath(entry["path"]).name, []).append(entry)
    bootstrap_entries = by_name.get("executed-bootstrap.yml", [])
    record_entries = by_name.get("bootstrap-execution.json", [])
    if bootstrap is None:
        if bootstrap_entries or record_entries:
            raise ValueError("provider without a bootstrap may not record bootstrap artifacts")
        return
    if len(bootstrap_entries) != 1 or len(record_entries) != 1:
        raise ValueError("bootstrap evidence requires exact execution artifacts")
    if (
        bootstrap_entries[0]["sha256"] != bootstrap["sha256"]
        or bootstrap_entries[0]["size"] < 1
        or record_entries[0]["size"] < 1
    ):
        raise ValueError("executed bootstrap artifact does not match its configuration binding")


def validate_creation_bootstrap_artifacts(
    document: dict[str, Any], artifacts: list[Path],
) -> None:
    bootstrap = document["digests"]["bootstrap_configuration"]
    names = {path.name for path in artifacts}
    if bootstrap is None:
        if {"executed-bootstrap.yml", "bootstrap-execution.json"} & names:
            raise ValueError("provider without a bootstrap supplied bootstrap artifacts")
        return
    executed_path = unique_input_artifact(artifacts, "executed-bootstrap.yml")
    record_path = unique_input_artifact(artifacts, "bootstrap-execution.json")
    executed = executed_path.read_bytes()
    if sha256_bytes(executed) != bootstrap["sha256"]:
        raise ValueError("executed bootstrap bytes differ from the merge configuration")
    record = require_exact_object(
        parse_json(record_path.read_text()),
        {"schema", "repository_path", "sha256", "size", "matches_checked_out_merge"},
        "bootstrap execution record",
    )
    if (
        record.get("schema") != "tron.ci-shadow-bootstrap-execution.v1"
        or record.get("repository_path") != bootstrap["path"]
        or record.get("sha256") != bootstrap["sha256"]
        or isinstance(record.get("size"), bool)
        or record.get("size") != len(executed)
        or record.get("matches_checked_out_merge") is not True
    ):
        raise ValueError("bootstrap execution record does not match executed bytes")


def safe_archive_member(info: zipfile.ZipInfo) -> str:
    path = PurePosixPath(info.filename)
    if (
        path.is_absolute()
        or ".." in path.parts
        or path.as_posix() in ("", ".")
        or path.as_posix() != info.filename
        or "\\" in info.filename
    ):
        raise ValueError("validation artifact contains an unsafe ZIP member path")
    return path.as_posix()


def validate_archive_manifest(
    bundle: zipfile.ZipFile, evidence_member: zipfile.ZipInfo, manifest: Any,
) -> dict[str, bytes]:
    validate_artifact_manifest(manifest)
    members: list[tuple[zipfile.ZipInfo, str]] = []
    for info in bundle.infolist():
        if info.is_dir() or info is evidence_member:
            continue
        members.append((info, safe_archive_member(info)))

    used_members: set[int] = set()
    payloads: dict[str, bytes] = {}
    for entry in manifest["entries"]:
        expected_path = entry["path"]
        expected_name = PurePosixPath(expected_path).name
        exact = [
            (index, info, member_path)
            for index, (info, member_path) in enumerate(members)
            if member_path == expected_path
        ]
        suffix = [
            (index, info, member_path)
            for index, (info, member_path) in enumerate(members)
            if member_path.endswith("/" + expected_path)
            or expected_path.endswith("/" + member_path)
        ]
        basename = [
            (index, info, member_path)
            for index, (info, member_path) in enumerate(members)
            if PurePosixPath(member_path).name == expected_name
        ]
        candidates = exact or suffix or basename
        if len(candidates) != 1:
            raise ValueError(
                f"manifest artifact {expected_path} matched {len(candidates)} ZIP members"
            )
        index, info, _ = candidates[0]
        if index in used_members:
            raise ValueError("multiple manifest entries resolved to the same ZIP member")
        used_members.add(index)
        if info.file_size != entry["size"]:
            raise ValueError(f"manifest artifact {expected_path} has the wrong size")
        payload = bundle.read(info)
        if sha256_bytes(payload) != entry["sha256"]:
            raise ValueError(f"manifest artifact {expected_path} has the wrong digest")
        payloads[expected_path] = payload
    return payloads


def unique_named_payload(payloads: dict[str, bytes], name: str) -> bytes:
    matches = [payload for path, payload in payloads.items() if PurePosixPath(path).name == name]
    if len(matches) != 1:
        raise ValueError(f"evidence manifest must contain exactly one {name}")
    return matches[0]


def require_exact_object(value: Any, keys: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError(f"{field} has missing or unsupported fields")
    return value


def validate_provider_context_artifact(document: dict[str, Any], context: Any) -> None:
    context = require_exact_object(
        context,
        {
            "schema", "provider", "authority", "event", "repository", "run",
            "pull_request", "base", "head", "source",
        },
        "provider context artifact",
    )
    if context.get("schema") != "tron.ci-provider-context.v1":
        raise ValueError("provider context artifact uses an unsupported schema")
    ci = require_exact_object(
        document.get("ci"), {"provider", "run_id", "run_attempt"}, "evidence ci"
    )
    pull = require_exact_object(
        document.get("pull_request"),
        {"number", "head_sha", "base_sha", "merge_sha", "merge_tree"},
        "evidence pull_request",
    )
    digests = require_exact_object(
        document.get("digests"),
        {"policy", "configuration", "bootstrap_configuration", "toolchain"},
        "evidence digests",
    )
    configuration = require_exact_object(
        digests.get("configuration"), {"path", "sha256"}, "configuration binding"
    )
    bootstrap_configuration = digests.get("bootstrap_configuration")

    provider = require_text(ci.get("provider"), "ci.provider")
    if provider == GITHUB_PROVIDER:
        if bootstrap_configuration is not None:
            raise ValueError("GitHub provider context may not declare a bootstrap")
        expected_authority = {
            "role": "authoritative",
            "shadow": False,
            "required_check_authority": True,
            "release_authority": True,
            "configuration_path": configuration["path"],
        }
    elif provider == "buildkite":
        bootstrap = require_exact_object(
            bootstrap_configuration,
            {"path", "sha256"},
            "bootstrap configuration binding",
        )
        expected_authority = {
            "role": "shadow",
            "shadow": True,
            "required_check_authority": False,
            "release_authority": False,
            "configuration_path": configuration["path"],
            "bootstrap_configuration_path": bootstrap["path"],
        }
    else:
        raise ValueError("provider context artifact uses an unsupported provider")

    authority = require_exact_object(
        context.get("authority"), set(expected_authority), "provider context authority"
    )
    event = require_exact_object(
        context.get("event"),
        {"kind", "provider_name", "action"},
        "provider context event",
    )
    repository = require_exact_object(
        context.get("repository"), {"slug", "main_branch"}, "provider context repository"
    )
    run = require_exact_object(
        context.get("run"), {"id", "number", "attempt"}, "provider context run"
    )
    context_pull = require_exact_object(
        context.get("pull_request"), {"number", "draft"}, "provider context pull_request"
    )
    base = require_exact_object(
        context.get("base"), {"repository", "ref", "sha"}, "provider context base"
    )
    head = require_exact_object(
        context.get("head"), {"repository", "ref", "sha"}, "provider context head"
    )
    source = require_exact_object(
        context.get("source"), {"ref", "sha", "tree", "parents"}, "provider context source"
    )

    context_number = require_positive_int(context_pull.get("number"), "context pull_request.number")
    require_positive_int(run.get("number"), "context run.number")
    parents = source.get("parents")
    if not isinstance(parents, list) or len(parents) != 2:
        raise ValueError("provider context source must have exactly two parents")
    normalized_parents = [
        require_git_oid(value, "provider context source parent") for value in parents
    ]
    if (
        context.get("provider") != provider
        or authority != expected_authority
        or event.get("kind") != "pull_request"
        or event.get("provider_name") != "pull_request"
        or event.get("action")
        not in {"opened", "synchronize", "reopened", "ready_for_review"}
        or repository
        != {"slug": document.get("repository"), "main_branch": "main"}
        or require_identifier(run.get("id"), "context run.id") != ci.get("run_id")
        or require_positive_int(run.get("attempt"), "context run.attempt")
        != ci.get("run_attempt")
        or context_number != pull.get("number")
        or context_pull.get("draft") is not False
        or base.get("repository") != document.get("repository")
        or base.get("ref") != "main"
        or require_git_oid(base.get("sha"), "context base.sha") != pull.get("base_sha")
        or not isinstance(head.get("repository"), str)
        or not head.get("repository")
        or not isinstance(head.get("ref"), str)
        or not head.get("ref")
        or require_git_oid(head.get("sha"), "context head.sha") != pull.get("head_sha")
        or source.get("ref") != f"refs/pull/{context_number}/merge"
        or require_git_oid(source.get("sha"), "context source.sha") != pull.get("merge_sha")
        or require_git_oid(source.get("tree"), "context source.tree")
        != pull.get("merge_tree")
        or normalized_parents != [pull.get("base_sha"), pull.get("head_sha")]
    ):
        raise ValueError("provider context artifact does not match validation evidence")


def create(output: Path, ios_metrics: Path | None, artifacts: list[Path]) -> None:
    context = normalized_creation_context()
    merge_sha = require_git_oid(git("rev-parse", "HEAD"), "pull_request.merge_sha")
    merge_tree = require_git_oid(
        git("show", "-s", "--format=%T", "HEAD"), "pull_request.merge_tree"
    )
    merge_parents = [
        require_git_oid(value, "pull_request.merge_parent")
        for value in git("show", "-s", "--format=%P", "HEAD").split()
    ]
    if merge_parents != [context["base_sha"], context["head_sha"]]:
        raise ValueError("checked-out merge parents do not match the declared PR base/head")
    declared_source_sha = first_environment("TRON_CI_SOURCE_SHA")
    if declared_source_sha is not None and require_git_oid(
        declared_source_sha, "TRON_CI_SOURCE_SHA"
    ) != merge_sha:
        raise ValueError("TRON_CI_SOURCE_SHA does not match checked-out HEAD")
    declared_source_tree = first_environment("TRON_CI_SOURCE_TREE")
    if declared_source_tree is not None and require_git_oid(
        declared_source_tree, "TRON_CI_SOURCE_TREE"
    ) != merge_tree:
        raise ValueError("TRON_CI_SOURCE_TREE does not match checked-out HEAD")
    metrics: dict[str, Any] | None = None
    if ios_metrics and ios_metrics.exists():
        metrics = parse_json(ios_metrics.read_text())
    elif os.environ.get("TRON_IOS_METRICS_JSON"):
        metrics = parse_json(os.environ["TRON_IOS_METRICS_JSON"])
    policy, configuration, bootstrap_configuration, required_jobs = policy_contract(
        context["provider"]
    )
    toolchain = toolchain_binding()
    metrics = validate_ios_metrics(
        metrics,
        expected_toolchain_sha256=toolchain["sha256"].removeprefix("sha256:"),
    )
    document: dict[str, Any] = {
        "schema": SCHEMA_V2,
        "repository": context["repository"],
        "ci": {
            "provider": context["provider"],
            "run_id": context["run_id"],
            "run_attempt": context["run_attempt"],
        },
        "pull_request": {
            "number": context["pull_request"],
            "head_sha": context["head_sha"],
            "base_sha": context["base_sha"],
            "merge_sha": merge_sha,
            "merge_tree": merge_tree,
        },
        "digests": {
            "policy": policy,
            "configuration": configuration,
            "bootstrap_configuration": bootstrap_configuration,
            "toolchain": toolchain,
        },
        "jobs": job_results(required_jobs),
        "ios": metrics,
        "artifacts": artifact_manifest(artifacts, output=output),
    }
    validate_creation_bootstrap_artifacts(document, artifacts)
    context_artifact = unique_input_artifact(artifacts, "provider-context.json")
    metrics_artifact = unique_input_artifact(artifacts, "ios-ci-metrics.json")
    validate_provider_context_artifact(
        document, parse_json(context_artifact.read_text())
    )
    if parse_json(metrics_artifact.read_text()) != metrics:
        raise ValueError("iOS metrics artifact does not match validation evidence")
    document = seal_document(document)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


class GitHub:
    def __init__(self, repository: str, token: str) -> None:
        self.base = f"https://api.github.com/repos/{repository}"
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "tron-validation-evidence",
        }

    def get(self, path: str, *, raw: bool = False) -> Any:
        request = urllib.request.Request(self.base + path, headers=self.headers)
        if raw:
            # Artifact downloads redirect from api.github.com to a short-lived
            # signed blob URL. Never forward the GitHub bearer credential to
            # that different origin: signed storage rejects it, and credential
            # scoping must remain explicit even if a provider accepts it.
            class NoRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, request, file_pointer, code, message, headers, new_url):
                    return None

            try:
                with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                if error.code not in (301, 302, 303, 307, 308):
                    raise
                location = error.headers.get("Location")
                if not location:
                    raise ValueError("artifact redirect did not include a location") from error
                error.close()
                with urllib.request.urlopen(location, timeout=60) as response:
                    return response.read()
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
        return parse_json(body)


def verify_digest_binding(actual: Any, expected: dict[str, str], field: str) -> None:
    if not isinstance(actual, dict) or set(actual) != {"path", "sha256"}:
        raise ValueError(f"evidence {field} digest binding is malformed")
    require_sha256(actual.get("sha256"), f"digests.{field}.sha256", prefixed=True)
    if actual != expected:
        raise ValueError(f"evidence {field} digest does not match")


def verify_optional_digest_binding(
    actual: Any, expected: dict[str, str] | None, field: str,
) -> None:
    if expected is None:
        if actual is not None:
            raise ValueError(f"evidence {field} must be null for this provider")
        return
    verify_digest_binding(actual, expected, field)


def evidence_pull_identity(document: dict[str, Any]) -> tuple[str, str, str, str]:
    if document.get("schema") == SCHEMA_V1:
        return (
            require_git_oid(document.get("head_sha"), "head_sha"),
            require_git_oid(document.get("base_sha"), "base_sha"),
            require_git_oid(document.get("merge_sha"), "merge_sha"),
            require_git_oid(document.get("merge_tree"), "merge_tree"),
        )
    pull = document.get("pull_request")
    if not isinstance(pull, dict):
        raise ValueError("evidence pull_request identity is malformed")
    return (
        require_git_oid(pull.get("head_sha"), "pull_request.head_sha"),
        require_git_oid(pull.get("base_sha"), "pull_request.base_sha"),
        require_git_oid(pull.get("merge_sha"), "pull_request.merge_sha"),
        require_git_oid(pull.get("merge_tree"), "pull_request.merge_tree"),
    )


def verify_github_merge_commit(
    document: dict[str, Any], commit: Any, *, run_head_sha: str,
) -> None:
    head_sha, base_sha, merge_sha, merge_tree = evidence_pull_identity(document)
    if run_head_sha != head_sha:
        raise ValueError("GitHub workflow run head does not match evidence PR head")
    if not isinstance(commit, dict):
        raise ValueError("GitHub merge commit response is malformed")
    tree = commit.get("tree")
    parents = commit.get("parents")
    if (
        commit.get("sha") != merge_sha
        or not isinstance(tree, dict)
        or tree.get("sha") != merge_tree
        or not isinstance(parents, list)
        or [item.get("sha") for item in parents if isinstance(item, dict)]
        != [base_sha, head_sha]
        or any(not isinstance(item, dict) for item in parents)
    ):
        raise ValueError("GitHub does not prove the recorded synthetic merge commit")


def verify_v1_document(
    document: dict[str, Any], *, repository: str, main_tree: str, pull_request: int,
    run_id: int, run_attempt: int, toolchain_manifest_sha256: str,
    head_sha: str | None, base_sha: str | None,
) -> None:
    expected = {
        "repository": repository,
        "pull_request": pull_request,
        "workflow_run_id": run_id,
        "workflow_attempt": run_attempt,
        "merge_tree": main_tree,
    }
    for key, value in expected.items():
        if document.get(key) != value:
            raise ValueError(f"evidence {key} does not match the merged commit")
    actual_head = require_git_oid(document.get("head_sha"), "head_sha")
    actual_base = require_git_oid(document.get("base_sha"), "base_sha")
    require_git_oid(document.get("merge_sha"), "merge_sha")
    if head_sha is not None and actual_head != head_sha:
        raise ValueError("evidence head_sha does not match the merged pull request")
    if base_sha is not None and actual_base != base_sha:
        raise ValueError("evidence base_sha does not match the merged pull request")
    require_sha256(document.get("toolchain_manifest_sha256"), "toolchain_manifest_sha256", prefixed=False)
    if document.get("toolchain_manifest_sha256") != toolchain_manifest_sha256:
        raise ValueError("evidence toolchain manifest hash does not match")
    if document.get("jobs") != HISTORICAL_V1_JOBS:
        raise ValueError("evidence does not prove the historical validation matrix")
    validate_ios_metrics(document.get("ios"))


def verify_v2_document(
    document: dict[str, Any], *, repository: str, main_tree: str, pull_request: int,
    run_id: int, run_attempt: int, provider: str, head_sha: str | None,
    base_sha: str | None, policy: dict[str, str] | None,
    configuration: dict[str, str] | None,
    bootstrap_configuration: dict[str, str] | None,
    toolchain: dict[str, str] | None,
    required_jobs: tuple[str, ...] | None,
) -> None:
    required = {
        "schema", "repository", "ci", "pull_request", "digests", "jobs", "ios",
        "artifacts", "evidence_sha256",
    }
    if set(document) != required:
        raise ValueError("v2 evidence has missing or unsupported top-level fields")
    verify_self_digest(document)
    if document.get("repository") != repository:
        raise ValueError("evidence repository does not match")

    ci = document.get("ci")
    if not isinstance(ci, dict) or set(ci) != {"provider", "run_id", "run_attempt"}:
        raise ValueError("evidence CI identity is malformed")
    actual_provider = normalize_provider(ci.get("provider"))
    if actual_provider != normalize_provider(provider):
        raise ValueError("evidence provider does not match the authoritative verifier")
    if require_identifier(ci.get("run_id"), "ci.run_id") != str(run_id):
        raise ValueError("evidence run_id does not match the artifact's workflow run")
    if require_positive_int(ci.get("run_attempt"), "ci.run_attempt") != run_attempt:
        raise ValueError("evidence run_attempt does not match the artifact's workflow run")

    pull = document.get("pull_request")
    pull_fields = {"number", "head_sha", "base_sha", "merge_sha", "merge_tree"}
    if not isinstance(pull, dict) or set(pull) != pull_fields:
        raise ValueError("evidence pull_request identity is malformed")
    if require_positive_int(pull.get("number"), "pull_request.number") != pull_request:
        raise ValueError("evidence pull_request.number does not match")
    actual_head = require_git_oid(pull.get("head_sha"), "pull_request.head_sha")
    actual_base = require_git_oid(pull.get("base_sha"), "pull_request.base_sha")
    require_git_oid(pull.get("merge_sha"), "pull_request.merge_sha")
    if require_git_oid(pull.get("merge_tree"), "pull_request.merge_tree") != main_tree:
        raise ValueError("evidence merge_tree does not match the merged commit")
    if head_sha is not None and actual_head != head_sha:
        raise ValueError("evidence head_sha does not match the merged pull request")
    if base_sha is not None and actual_base != base_sha:
        raise ValueError("evidence base_sha does not match the merged pull request")

    if policy is None or configuration is None or toolchain is None or required_jobs is None:
        raise ValueError("v2 evidence verifier is missing current policy bindings")
    digests = document.get("digests")
    if not isinstance(digests, dict) or set(digests) != {
        "policy", "configuration", "bootstrap_configuration", "toolchain",
    }:
        raise ValueError("evidence digest bindings are malformed")
    verify_digest_binding(digests.get("policy"), policy, "policy")
    verify_digest_binding(digests.get("configuration"), configuration, "configuration")
    verify_optional_digest_binding(
        digests.get("bootstrap_configuration"),
        bootstrap_configuration,
        "bootstrap_configuration",
    )
    verify_digest_binding(digests.get("toolchain"), toolchain, "toolchain")

    expected_jobs = {name: "success" for name in required_jobs}
    if document.get("jobs") != expected_jobs:
        raise ValueError("evidence does not prove the policy-required validation matrix")
    validate_ios_metrics(
        document.get("ios"),
        expected_toolchain_sha256=toolchain["sha256"].removeprefix("sha256:"),
    )
    validate_bootstrap_manifest_binding(
        document.get("artifacts"), bootstrap_configuration
    )


def verify_document(
    document: Any, *, repository: str, main_sha: str, main_tree: str,
    pull_request: int, run_id: int, artifact_digest: str,
    toolchain_manifest_sha256: str, run_attempt: int = 1,
    provider: str = GITHUB_PROVIDER, head_sha: str | None = None,
    base_sha: str | None = None, policy: dict[str, str] | None = None,
    configuration: dict[str, str] | None = None,
    bootstrap_configuration: dict[str, str] | None = None,
    toolchain: dict[str, str] | None = None,
    required_jobs: tuple[str, ...] | None = None,
) -> None:
    del main_sha  # Tree identity intentionally survives squash/rebase merges.
    if not isinstance(document, dict):
        raise ValueError("validation evidence must be a JSON object")
    require_sha256(artifact_digest, "artifact.digest", prefixed=True)
    schema = document.get("schema")
    if schema == SCHEMA_V1:
        verify_v1_document(
            document,
            repository=repository,
            main_tree=main_tree,
            pull_request=pull_request,
            run_id=run_id,
            run_attempt=run_attempt,
            toolchain_manifest_sha256=toolchain_manifest_sha256,
            head_sha=head_sha,
            base_sha=base_sha,
        )
    elif schema == SCHEMA_V2:
        verify_v2_document(
            document,
            repository=repository,
            main_tree=main_tree,
            pull_request=pull_request,
            run_id=run_id,
            run_attempt=run_attempt,
            provider=provider,
            head_sha=head_sha,
            base_sha=base_sha,
            policy=policy,
            configuration=configuration,
            bootstrap_configuration=bootstrap_configuration,
            toolchain=toolchain,
            required_jobs=required_jobs,
        )
    else:
        raise ValueError("unsupported validation evidence schema")


def require_reusable_schema(document: Any) -> None:
    if not isinstance(document, dict) or document.get("schema") != SCHEMA_V2:
        raise ValueError(
            "authoritative main reuse requires current tron.validation.v2 evidence"
        )


def github_record_order(record: dict[str, Any]) -> tuple[str, int, int]:
    timestamp = next(
        (
            value
            for field in ("run_started_at", "created_at", "updated_at")
            if isinstance((value := record.get(field)), str)
        ),
        "",
    )
    identifier = record.get("id")
    numeric_identifier = (
        identifier if isinstance(identifier, int) and not isinstance(identifier, bool) else -1
    )
    attempt = record.get("run_attempt")
    numeric_attempt = attempt if isinstance(attempt, int) and not isinstance(attempt, bool) else -1
    return timestamp, numeric_identifier, numeric_attempt


def select_newest_valid_candidate(
    api: GitHub,
    runs: Any,
    validator: Callable[[dict[str, Any], dict[str, Any]], ValidatedCandidate],
    report_rejection: Callable[[str], None] | None = None,
) -> ValidatedCandidate:
    if report_rejection is None:
        report_rejection = lambda message: print(message, file=sys.stderr)
    if not isinstance(runs, dict) or not isinstance(runs.get("workflow_runs"), list):
        raise ValueError("GitHub workflow-run response is malformed")
    successful = [
        run
        for run in runs["workflow_runs"]
        if isinstance(run, dict) and run.get("conclusion") == "success"
    ]
    if not successful:
        raise ValueError("no successful pull-request CI run exists for the merged head")

    rejected = 0
    for run in sorted(successful, key=github_record_order, reverse=True):
        try:
            run_id = require_positive_int(run.get("id"), "workflow_run.id")
            response = api.get(f"/actions/runs/{run_id}/artifacts?per_page=100")
            if not isinstance(response, dict) or not isinstance(response.get("artifacts"), list):
                raise ValueError("GitHub artifact response is malformed")
            artifacts = [
                artifact
                for artifact in response["artifacts"]
                if isinstance(artifact, dict)
                and artifact.get("name") == ARTIFACT_NAME
                and artifact.get("expired") is False
            ]
        except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
            rejected += 1
            report_rejection(f"validation candidate run rejected: {error}")
            continue

        for artifact in sorted(artifacts, key=github_record_order, reverse=True):
            try:
                return validator(run, artifact)
            except (
                OSError,
                ValueError,
                KeyError,
                json.JSONDecodeError,
                urllib.error.URLError,
                zipfile.BadZipFile,
            ) as error:
                rejected += 1
                artifact_id = artifact.get("id", "unknown")
                report_rejection(
                    f"validation candidate artifact {artifact_id} rejected: {error}"
                )

    raise ValueError(f"no exact valid pull-request proof exists ({rejected} rejected)")


def validate_github_candidate(
    api: GitHub,
    *,
    repository: str,
    main_sha: str,
    main_tree: str,
    pull_request: dict[str, Any],
    run: dict[str, Any],
    artifact: dict[str, Any],
) -> ValidatedCandidate:
    if run.get("conclusion") != "success":
        raise ValueError("workflow run did not conclude successfully")
    if artifact.get("name") != ARTIFACT_NAME or artifact.get("expired") is not False:
        raise ValueError("artifact is not a live merge-validation proof")
    run_id = require_positive_int(run.get("id"), "workflow_run.id")
    run_attempt = require_positive_int(
        run.get("run_attempt", 1), "workflow_run.run_attempt"
    )
    artifact_id = require_positive_int(artifact.get("id"), "artifact.id")
    archive = api.get(f"/actions/artifacts/{artifact_id}/zip", raw=True)
    if not isinstance(archive, bytes):
        raise ValueError("GitHub artifact download is malformed")
    reported = require_sha256(artifact.get("digest"), "artifact.digest", prefixed=True)
    if reported != sha256_bytes(archive):
        raise ValueError("downloaded artifact does not match GitHub's digest")

    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        evidence_members = [
            info
            for info in bundle.infolist()
            if not info.is_dir() and info.filename.endswith("validation-evidence.json")
        ]
        if len(evidence_members) != 1:
            raise ValueError("validation artifact must contain exactly one evidence document")
        evidence_member = evidence_members[0]
        safe_archive_member(evidence_member)
        document = parse_json(bundle.read(evidence_member))
        archive_payloads: dict[str, bytes] = {}
        if isinstance(document, dict) and document.get("schema") == SCHEMA_V2:
            archive_payloads = validate_archive_manifest(
                bundle, evidence_member, document.get("artifacts")
            )

    if not isinstance(document, dict):
        raise ValueError("validation evidence must be a JSON object")
    require_reusable_schema(document)
    if document.get("schema") == SCHEMA_V2:
        context_payload = unique_named_payload(archive_payloads, "provider-context.json")
        metrics_payload = unique_named_payload(archive_payloads, "ios-ci-metrics.json")
        validate_provider_context_artifact(document, parse_json(context_payload))
        if parse_json(metrics_payload) != document.get("ios"):
            raise ValueError("iOS metrics artifact does not match validation evidence")

    _, _, merge_sha, _ = evidence_pull_identity(document)
    run_head_sha = require_git_oid(run.get("head_sha"), "workflow_run.head_sha")
    merge_commit = api.get(f"/git/commits/{merge_sha}")
    verify_github_merge_commit(document, merge_commit, run_head_sha=run_head_sha)

    kwargs: dict[str, Any] = {}
    if document.get("schema") == SCHEMA_V2:
        policy, configuration, bootstrap_configuration, required_jobs = policy_contract(
            GITHUB_PROVIDER
        )
        kwargs = {
            "policy": policy,
            "configuration": configuration,
            "bootstrap_configuration": bootstrap_configuration,
            "toolchain": toolchain_binding(),
            "required_jobs": required_jobs,
        }
    toolchain_sha256 = sha256_bytes(DEFAULT_TOOLCHAIN_PATH.read_bytes(), prefixed=False)
    head = pull_request.get("head")
    base = pull_request.get("base")
    if not isinstance(head, dict) or not isinstance(base, dict):
        raise ValueError("merged pull-request identity is malformed")
    verify_document(
        document,
        repository=repository,
        main_sha=main_sha,
        main_tree=main_tree,
        pull_request=require_positive_int(
            pull_request.get("number"), "pull_request.number"
        ),
        run_id=run_id,
        run_attempt=run_attempt,
        artifact_digest=reported,
        toolchain_manifest_sha256=toolchain_sha256,
        provider=GITHUB_PROVIDER,
        head_sha=require_git_oid(head.get("sha"), "pull_request.head_sha"),
        base_sha=require_git_oid(base.get("sha"), "pull_request.base_sha"),
        **kwargs,
    )
    return ValidatedCandidate(run, artifact, archive, document)


def reuse_receipt(
    *,
    repository: str,
    main_sha: str,
    main_tree: str,
    main_run_id: int,
    main_run_attempt: int,
    pull_request: dict[str, Any],
    candidate: ValidatedCandidate,
) -> dict[str, Any]:
    run_id = require_positive_int(candidate.run.get("id"), "workflow_run.id")
    run_attempt = require_positive_int(
        candidate.run.get("run_attempt", 1), "workflow_run.run_attempt"
    )
    artifact_id = require_positive_int(candidate.artifact.get("id"), "artifact.id")
    artifact_digest = require_sha256(
        candidate.artifact.get("digest"), "artifact.digest", prefixed=True
    )
    if artifact_digest != sha256_bytes(candidate.archive):
        raise ValueError("selected artifact digest changed before receipt creation")
    receipt = seal_reuse_receipt({
        "schema": REUSE_RECEIPT_SCHEMA,
        "repository": require_text(repository, "repository"),
        "main": {
            "run_id": str(require_positive_int(main_run_id, "main.run_id")),
            "run_attempt": require_positive_int(
                main_run_attempt, "main.run_attempt"
            ),
            "sha": require_git_oid(main_sha, "main.sha"),
            "tree": require_git_oid(main_tree, "main.tree"),
        },
        "selected_pull_request": {
            "number": require_positive_int(
                pull_request.get("number"), "pull_request.number"
            ),
            "run_id": str(run_id),
            "run_attempt": run_attempt,
            "artifact_id": str(artifact_id),
            "artifact_digest": artifact_digest,
        },
        "evidence": candidate.evidence,
    })
    verify_reuse_receipt_digest(receipt)
    return receipt


def verify(output: Path, receipt_output: Path, artifact_archive: Path) -> bool:
    repository = require_text(os.environ.get("GITHUB_REPOSITORY"), "repository")
    token = require_text(os.environ.get("GITHUB_TOKEN"), "GITHUB_TOKEN")
    main_run_id = require_positive_int(os.environ.get("GITHUB_RUN_ID"), "GITHUB_RUN_ID")
    main_run_attempt = require_positive_int(
        os.environ.get("GITHUB_RUN_ATTEMPT", "1"), "GITHUB_RUN_ATTEMPT"
    )
    main_sha = git("rev-parse", "HEAD")
    main_tree = git("show", "-s", "--format=%T", "HEAD")
    api = GitHub(repository, token)
    pulls = api.get(f"/commits/{main_sha}/pulls")
    if not isinstance(pulls, list):
        raise ValueError("GitHub merged-pull response is malformed")
    merged = [
        item
        for item in pulls
        if isinstance(item, dict)
        and item.get("merged_at")
        and isinstance(item.get("base"), dict)
        and item["base"].get("ref") == "main"
    ]
    if len(merged) != 1:
        raise ValueError(
            f"expected one merged pull request for {main_sha}, found {len(merged)}"
        )
    pull_request = merged[0]
    head = pull_request.get("head")
    if not isinstance(head, dict):
        raise ValueError("merged pull-request head is malformed")
    head_sha = require_git_oid(head.get("sha"), "pull_request.head_sha")
    runs = api.get(
        "/actions/workflows/ci.yml/runs"
        f"?event=pull_request&head_sha={head_sha}&status=completed&per_page=100"
    )
    candidate = select_newest_valid_candidate(
        api,
        runs,
        lambda run, artifact: validate_github_candidate(
            api,
            repository=repository,
            main_sha=main_sha,
            main_tree=main_tree,
            pull_request=pull_request,
            run=run,
            artifact=artifact,
        ),
    )
    receipt = reuse_receipt(
        repository=repository,
        main_sha=main_sha,
        main_tree=main_tree,
        main_run_id=main_run_id,
        main_run_attempt=main_run_attempt,
        pull_request=pull_request,
        candidate=candidate,
    )

    for path in (output, receipt_output, artifact_archive):
        path.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(candidate.evidence, indent=2, sort_keys=True) + "\n")
    receipt_output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    artifact_archive.write_bytes(candidate.archive)
    return True


def test_v1_document() -> dict[str, Any]:
    return {
        "schema": SCHEMA_V1,
        "repository": "example/tron",
        "pull_request": 42,
        "head_sha": "a" * 40,
        "base_sha": "b" * 40,
        "merge_sha": "c" * 40,
        "merge_tree": "d" * 40,
        "workflow_run_id": 99,
        "workflow_attempt": 1,
        "toolchain_manifest_sha256": "e" * 64,
        "jobs": dict(HISTORICAL_V1_JOBS),
        "ios": {
            "schema": IOS_METRICS_SCHEMA,
            "build_seconds": 100,
            "test_seconds": 200,
            "test_exit_code": 0,
            "xcresult_summary_sha256": "1" * 64,
        },
    }


def test_v2_document() -> tuple[dict[str, Any], dict[str, Any]]:
    policy = {"path": "config/ci-policy.json", "sha256": "sha256:" + "2" * 64}
    configuration = {"path": ".github/workflows/ci.yml", "sha256": "sha256:" + "3" * 64}
    toolchain = {"path": "config/ci-toolchain.env", "sha256": "sha256:" + "e" * 64}
    entries = [{"path": "build/results.json", "sha256": "sha256:" + "4" * 64, "size": 17}]
    document = seal_document({
        "schema": SCHEMA_V2,
        "repository": "example/tron",
        "ci": {"provider": GITHUB_PROVIDER, "run_id": "99", "run_attempt": 1},
        "pull_request": {
            "number": 42,
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
            "merge_sha": "c" * 40,
            "merge_tree": "d" * 40,
        },
        "digests": {
            "policy": policy,
            "configuration": configuration,
            "bootstrap_configuration": None,
            "toolchain": toolchain,
        },
        "jobs": {name: "success" for name in DEFAULT_REQUIRED_JOBS},
        "ios": {
            "schema": IOS_METRICS_SCHEMA,
            "build_exit_code": 0,
            "build_seconds": 100,
            "counts": {"failedTests": 0, "totalTestCount": 10},
            "enumerated_tests": False,
            "parallel_workers": 1,
            "runner_arch": "arm64",
            "runner_os": "fixture-os",
            "sdk": "26.2",
            "test_seconds": 200,
            "test_exit_code": 0,
            "test_enumeration_sha256": None,
            "toolchain_manifest_sha256": "e" * 64,
            "xcode": "Xcode 26.3",
            "xcresult_summary_sha256": "1" * 64,
        },
        "artifacts": {
            "algorithm": "sha256",
            "entries": entries,
            "manifest_sha256": canonical_digest(entries),
        },
    })
    bindings = {
        "policy": policy,
        "configuration": configuration,
        "bootstrap_configuration": None,
        "toolchain": toolchain,
    }
    return document, bindings


def self_test() -> None:
    for malformed_json in ('{"schema":"one","schema":"two"}', '{"seconds":NaN}'):
        try:
            parse_json(malformed_json)
        except ValueError:
            continue
        raise AssertionError("non-canonical JSON was accepted")

    original_environment = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update({
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_REPOSITORY": "example/tron",
            "GITHUB_RUN_ID": "99",
            "GITHUB_RUN_ATTEMPT": "2",
            "TRON_PR_NUMBER": "42",
            "TRON_PR_HEAD_SHA": "a" * 40,
            "TRON_PR_BASE_SHA": "b" * 40,
        })
        github_context = normalized_creation_context()
        assert github_context == {
            "provider": GITHUB_PROVIDER,
            "repository": "example/tron",
            "run_id": "99",
            "run_attempt": 2,
            "pull_request": 42,
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
        }

        os.environ.clear()
        os.environ.update({
            "TRON_CI_PROVIDER": "buildkite",
            "TRON_CI_EVENT_NAME": "pull_request",
            "TRON_CI_REPOSITORY": "example/tron",
            "TRON_CI_RUN_ID": "12345678-1234-4234-8234-123456789abc",
            "TRON_CI_RUN_ATTEMPT": "1",
            "TRON_CI_PR_NUMBER": "42",
            "TRON_CI_PR_HEAD_SHA": "a" * 40,
            "TRON_CI_PR_BASE_SHA": "b" * 40,
        })
        buildkite_context = normalized_creation_context()
        assert buildkite_context["provider"] == "buildkite"
        assert buildkite_context["run_id"] == "12345678-1234-4234-8234-123456789abc"
    finally:
        os.environ.clear()
        os.environ.update(original_environment)

    original_jobs = os.environ.pop("TRON_CI_REQUIRED_JOBS_JSON", None)
    try:
        try:
            job_results(DEFAULT_REQUIRED_JOBS)
        except ValueError:
            pass
        else:
            raise AssertionError("missing required job evidence was accepted")

        os.environ["TRON_CI_REQUIRED_JOBS_JSON"] = json.dumps(
            {name: "success" for name in DEFAULT_REQUIRED_JOBS}
        )
        assert job_results(DEFAULT_REQUIRED_JOBS) == {
            name: "success" for name in DEFAULT_REQUIRED_JOBS
        }

        incomplete_jobs = {name: "success" for name in DEFAULT_REQUIRED_JOBS[:-1]}
        os.environ["TRON_CI_REQUIRED_JOBS_JSON"] = json.dumps(incomplete_jobs)
        try:
            job_results(DEFAULT_REQUIRED_JOBS)
        except ValueError:
            pass
        else:
            raise AssertionError("incomplete required job evidence was accepted")

        failed_jobs = {name: "success" for name in DEFAULT_REQUIRED_JOBS}
        failed_jobs["ios"] = "failure"
        os.environ["TRON_CI_REQUIRED_JOBS_JSON"] = json.dumps(failed_jobs)
        try:
            job_results(DEFAULT_REQUIRED_JOBS)
        except ValueError:
            pass
        else:
            raise AssertionError("failed required job evidence was accepted")
    finally:
        if original_jobs is None:
            os.environ.pop("TRON_CI_REQUIRED_JOBS_JSON", None)
        else:
            os.environ["TRON_CI_REQUIRED_JOBS_JSON"] = original_jobs

    common = {
        "repository": "example/tron",
        "main_sha": "f" * 40,
        "main_tree": "d" * 40,
        "pull_request": 42,
        "run_id": 99,
        "run_attempt": 1,
        "artifact_digest": "sha256:" + "0" * 64,
        "toolchain_manifest_sha256": "e" * 64,
        "provider": GITHUB_PROVIDER,
        "head_sha": "a" * 40,
        "base_sha": "b" * 40,
    }
    valid_v1 = test_v1_document()
    verify_document(valid_v1, **common)
    try:
        require_reusable_schema(valid_v1)
    except ValueError:
        pass
    else:
        raise AssertionError("legacy v1 evidence was accepted for authoritative reuse")

    valid_v2, bindings = test_v2_document()
    require_reusable_schema(valid_v2)
    v2_kwargs = {
        **common,
        **bindings,
        "required_jobs": DEFAULT_REQUIRED_JOBS,
    }
    verify_document(valid_v2, **v2_kwargs)

    validation_artifact_archive = b"exact downloaded validation artifact ZIP fixture"
    validation_artifact_digest = sha256_bytes(validation_artifact_archive)
    fixture_runs = {
        "workflow_runs": [
            {
                "id": 20,
                "run_attempt": 1,
                "run_started_at": "2026-08-04T00:00:00Z",
                "conclusion": "success",
            },
            {
                "id": 30,
                "run_attempt": 2,
                "run_started_at": "2026-08-05T00:00:00Z",
                "conclusion": "success",
            },
            {
                "id": 40,
                "run_attempt": 1,
                "run_started_at": "2026-08-06T00:00:00Z",
                "conclusion": "failure",
            },
        ]
    }
    fixture_artifacts = {
        20: [{
            "id": 200,
            "name": ARTIFACT_NAME,
            "expired": False,
            "created_at": "2026-08-04T00:01:00Z",
            "digest": validation_artifact_digest,
        }],
        30: [
            {
                "id": 300,
                "name": ARTIFACT_NAME,
                "expired": False,
                "created_at": "2026-08-05T00:01:00Z",
                "digest": validation_artifact_digest,
            },
            {
                "id": 301,
                "name": ARTIFACT_NAME,
                "expired": False,
                "created_at": "2026-08-05T00:02:00Z",
                "digest": validation_artifact_digest,
            },
        ],
    }

    class FixtureGitHub:
        def get(self, path: str, *, raw: bool = False) -> Any:
            del raw
            match = re.fullmatch(r"/actions/runs/(\d+)/artifacts\?per_page=100", path)
            if match is None:
                raise AssertionError(f"unexpected fixture API path: {path}")
            return {"artifacts": fixture_artifacts[int(match.group(1))]}

    attempted_artifacts: list[int] = []

    def fixture_validator(
        run: dict[str, Any], artifact: dict[str, Any]
    ) -> ValidatedCandidate:
        attempted_artifacts.append(artifact["id"])
        if artifact["id"] == 301:
            raise ValueError("malformed newest proof")
        return ValidatedCandidate(run, artifact, validation_artifact_archive, valid_v1)

    fixture_api = FixtureGitHub()
    selected = select_newest_valid_candidate(
        fixture_api,  # type: ignore[arg-type]
        fixture_runs,
        fixture_validator,
        lambda _: None,
    )
    assert attempted_artifacts == [301, 300]
    assert selected.run["id"] == 30
    assert selected.artifact["id"] == 300

    def reject_fixture(
        _run: dict[str, Any], _artifact: dict[str, Any]
    ) -> ValidatedCandidate:
        raise ValueError("stale proof")

    try:
        select_newest_valid_candidate(
            fixture_api,  # type: ignore[arg-type]
            fixture_runs,
            reject_fixture,
            lambda _: None,
        )
    except ValueError:
        pass
    else:
        raise AssertionError("an invalid candidate set produced reusable evidence")

    receipt = reuse_receipt(
        repository="example/tron",
        main_sha="f" * 40,
        main_tree="d" * 40,
        main_run_id=500,
        main_run_attempt=2,
        pull_request={"number": 42},
        candidate=selected,
    )
    verify_reuse_receipt_digest(receipt)
    assert receipt["main"] == {
        "run_id": "500",
        "run_attempt": 2,
        "sha": "f" * 40,
        "tree": "d" * 40,
    }
    assert receipt["selected_pull_request"] == {
        "number": 42,
        "run_id": "30",
        "run_attempt": 2,
        "artifact_id": "300",
        "artifact_digest": validation_artifact_digest,
    }
    assert receipt["evidence"] == valid_v1
    damaged_receipt = copy.deepcopy(receipt)
    damaged_receipt["main"]["tree"] = "9" * 40
    try:
        verify_reuse_receipt_digest(damaged_receipt)
    except ValueError:
        pass
    else:
        raise AssertionError("a modified reuse receipt retained a valid digest")

    github_merge = {
        "sha": "c" * 40,
        "tree": {"sha": "d" * 40},
        "parents": [{"sha": "b" * 40}, {"sha": "a" * 40}],
    }
    verify_github_merge_commit(valid_v1, github_merge, run_head_sha="a" * 40)
    verify_github_merge_commit(valid_v2, github_merge, run_head_sha="a" * 40)
    provider_context = {
        "schema": "tron.ci-provider-context.v1",
        "provider": GITHUB_PROVIDER,
        "authority": {
            "configuration_path": ".github/workflows/ci.yml",
            "role": "authoritative",
            "shadow": False,
            "required_check_authority": True,
            "release_authority": True,
        },
        "event": {
            "kind": "pull_request",
            "provider_name": "pull_request",
            "action": "opened",
        },
        "repository": {"slug": "example/tron", "main_branch": "main"},
        "run": {"id": "99", "number": 12, "attempt": 1},
        "pull_request": {"number": 42, "draft": False},
        "base": {"repository": "example/tron", "ref": "main", "sha": "b" * 40},
        "head": {"repository": "example/tron", "ref": "feature", "sha": "a" * 40},
        "source": {
            "ref": "refs/pull/42/merge",
            "sha": "c" * 40,
            "tree": "d" * 40,
            "parents": ["b" * 40, "a" * 40],
        },
    }
    validate_provider_context_artifact(valid_v2, provider_context)
    stale_context = copy.deepcopy(provider_context)
    stale_context["source"]["tree"] = "9" * 40
    try:
        validate_provider_context_artifact(valid_v2, stale_context)
    except ValueError:
        pass
    else:
        raise AssertionError("stale provider context artifact was accepted")
    context_mutations: list[tuple[str, tuple[str, ...], Any]] = [
        ("authority role", ("authority", "role"), "shadow"),
        ("release authority", ("authority", "release_authority"), False),
        ("draft state", ("pull_request", "draft"), True),
        ("main branch", ("repository", "main_branch"), "trunk"),
        ("base ref", ("base", "ref"), "release"),
        ("source ref", ("source", "ref"), "refs/heads/feature"),
        ("run number", ("run", "number"), 0),
    ]
    for description, path, value in context_mutations:
        changed_context = copy.deepcopy(provider_context)
        cursor: dict[str, Any] = changed_context
        for key in path[:-1]:
            cursor = cursor[key]
        cursor[path[-1]] = value
        try:
            validate_provider_context_artifact(valid_v2, changed_context)
        except ValueError:
            continue
        raise AssertionError(f"invalid provider context {description} was accepted")
    for description, commit, run_head in (
        (
            "synthetic merge parent order",
            {
                **github_merge,
                "parents": [{"sha": "a" * 40}, {"sha": "b" * 40}],
            },
            "a" * 40,
        ),
        ("workflow run head", github_merge, "9" * 40),
    ):
        try:
            verify_github_merge_commit(valid_v2, commit, run_head_sha=run_head)
        except ValueError:
            continue
        raise AssertionError(f"invalid {description} was accepted")

    archive_payload = b'{"result":"success"}\n'
    archived = copy.deepcopy(valid_v2)
    archived.pop("evidence_sha256")
    archived_entries = [{
        "path": "build/results.json",
        "sha256": sha256_bytes(archive_payload),
        "size": len(archive_payload),
    }]
    archived["artifacts"] = {
        "algorithm": "sha256",
        "entries": archived_entries,
        "manifest_sha256": canonical_digest(archived_entries),
    }
    archived = seal_document(archived)
    archive_buffer = io.BytesIO()
    with zipfile.ZipFile(archive_buffer, "w") as bundle:
        bundle.writestr("validation-evidence.json", json.dumps(archived))
        bundle.writestr("results.json", archive_payload)
    with zipfile.ZipFile(io.BytesIO(archive_buffer.getvalue())) as bundle:
        evidence_member = bundle.getinfo("validation-evidence.json")
        validate_archive_manifest(bundle, evidence_member, archived["artifacts"])

    cases: list[tuple[str, dict[str, Any], dict[str, Any]]] = []

    stale = copy.deepcopy(valid_v2)
    stale["pull_request"]["merge_tree"] = "9" * 40
    cases.append((
        "stale merge tree",
        seal_document({key: value for key, value in stale.items() if key != "evidence_sha256"}),
        v2_kwargs,
    ))
    stale_head = copy.deepcopy(valid_v2)
    stale_head["pull_request"]["head_sha"] = "8" * 40
    cases.append((
        "stale PR head",
        seal_document({
            key: value for key, value in stale_head.items() if key != "evidence_sha256"
        }),
        v2_kwargs,
    ))

    corrupt = copy.deepcopy(valid_v2)
    corrupt["ios"]["test_seconds"] = 201
    cases.append(("corrupt self digest", corrupt, v2_kwargs))

    malformed = copy.deepcopy(valid_v2)
    malformed.pop("evidence_sha256")
    malformed["artifacts"]["entries"][0]["path"] = "../secret"
    malformed["artifacts"]["manifest_sha256"] = canonical_digest(malformed["artifacts"]["entries"])
    cases.append(("malformed artifact path", seal_document(malformed), v2_kwargs))

    bad_manifest = copy.deepcopy(valid_v2)
    bad_manifest.pop("evidence_sha256")
    bad_manifest["artifacts"]["manifest_sha256"] = "sha256:" + "5" * 64
    cases.append(("artifact manifest digest", seal_document(bad_manifest), v2_kwargs))

    empty_manifest = copy.deepcopy(valid_v2)
    empty_manifest.pop("evidence_sha256")
    empty_manifest["artifacts"] = {
        "algorithm": "sha256",
        "entries": [],
        "manifest_sha256": canonical_digest([]),
    }
    cases.append(("empty artifact manifest", seal_document(empty_manifest), v2_kwargs))

    bad_policy = copy.deepcopy(valid_v2)
    bad_policy.pop("evidence_sha256")
    bad_policy["digests"]["policy"]["sha256"] = "sha256:" + "5" * 64
    cases.append(("policy digest", seal_document(bad_policy), v2_kwargs))

    bad_configuration = copy.deepcopy(valid_v2)
    bad_configuration.pop("evidence_sha256")
    bad_configuration["digests"]["configuration"]["sha256"] = "sha256:" + "5" * 64
    cases.append(("configuration digest", seal_document(bad_configuration), v2_kwargs))

    unexpected_bootstrap = copy.deepcopy(valid_v2)
    unexpected_bootstrap.pop("evidence_sha256")
    unexpected_bootstrap["digests"]["bootstrap_configuration"] = {
        "path": ".buildkite/pipeline.yml",
        "sha256": "sha256:" + "5" * 64,
    }
    cases.append((
        "unexpected bootstrap configuration",
        seal_document(unexpected_bootstrap),
        v2_kwargs,
    ))

    bad_toolchain = copy.deepcopy(valid_v2)
    bad_toolchain.pop("evidence_sha256")
    bad_toolchain["digests"]["toolchain"]["sha256"] = "sha256:" + "5" * 64
    cases.append(("toolchain digest", seal_document(bad_toolchain), v2_kwargs))

    mismatched_ios_toolchain = copy.deepcopy(valid_v2)
    mismatched_ios_toolchain.pop("evidence_sha256")
    mismatched_ios_toolchain["ios"]["toolchain_manifest_sha256"] = "5" * 64
    cases.append((
        "iOS toolchain digest",
        seal_document(mismatched_ios_toolchain),
        v2_kwargs,
    ))

    failed_ios_build = copy.deepcopy(valid_v2)
    failed_ios_build.pop("evidence_sha256")
    failed_ios_build["ios"]["build_exit_code"] = 1
    cases.append(("failed iOS build", seal_document(failed_ios_build), v2_kwargs))

    zero_ios_tests = copy.deepcopy(valid_v2)
    zero_ios_tests.pop("evidence_sha256")
    zero_ios_tests["ios"]["counts"]["totalTestCount"] = 0
    cases.append(("zero iOS tests", seal_document(zero_ios_tests), v2_kwargs))

    failed_ios_tests = copy.deepcopy(valid_v2)
    failed_ios_tests.pop("evidence_sha256")
    failed_ios_tests["ios"]["counts"]["failedTests"] = 1
    cases.append(("failed iOS tests", seal_document(failed_ios_tests), v2_kwargs))

    boolean_ios_exit = copy.deepcopy(valid_v2)
    boolean_ios_exit.pop("evidence_sha256")
    boolean_ios_exit["ios"]["test_exit_code"] = False
    cases.append(("boolean iOS exit code", seal_document(boolean_ios_exit), v2_kwargs))

    bad_job = copy.deepcopy(valid_v2)
    bad_job.pop("evidence_sha256")
    bad_job["jobs"]["ios"] = "failure"
    cases.append(("required job result", seal_document(bad_job), v2_kwargs))

    bad_provider = copy.deepcopy(valid_v2)
    bad_provider.pop("evidence_sha256")
    bad_provider["ci"]["provider"] = "buildkite"
    cases.append(("provider binding", seal_document(bad_provider), v2_kwargs))

    bad_run = copy.deepcopy(valid_v2)
    bad_run.pop("evidence_sha256")
    bad_run["ci"]["run_id"] = "100"
    cases.append(("run binding", seal_document(bad_run), v2_kwargs))

    bad_attempt = copy.deepcopy(valid_v2)
    bad_attempt.pop("evidence_sha256")
    bad_attempt["ci"]["run_attempt"] = 2
    cases.append(("attempt binding", seal_document(bad_attempt), v2_kwargs))

    for description, document, kwargs in cases:
        try:
            verify_document(document, **kwargs)
        except ValueError:
            continue
        raise AssertionError(f"invalid {description} was accepted")

    for description, kwargs in (
        ("artifact digest", {**v2_kwargs, "artifact_digest": "md5:bad"}),
        (
            "policy verifier binding",
            {
                **v2_kwargs,
                "policy": {
                    "path": "config/ci-policy.json",
                    "sha256": "sha256:" + "6" * 64,
                },
            },
        ),
        (
            "toolchain verifier binding",
            {
                **v2_kwargs,
                "toolchain": {
                    "path": "config/ci-toolchain.env",
                    "sha256": "sha256:" + "6" * 64,
                },
            },
        ),
    ):
        try:
            verify_document(valid_v2, **kwargs)
        except ValueError:
            continue
        raise AssertionError(f"invalid {description} was accepted")

    invalid_v1_attempt = copy.deepcopy(valid_v1)
    invalid_v1_attempt["workflow_attempt"] = 2
    try:
        verify_document(invalid_v1_attempt, **common)
    except ValueError:
        pass
    else:
        raise AssertionError("v1 provider run-attempt mismatch was accepted")

    for description, members in (
        ("archive content digest", [("results.json", b'{"result":"failure"}')]),
        (
            "ambiguous archive basename",
            [("one/results.json", archive_payload), ("two/results.json", archive_payload)],
        ),
    ):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as bundle:
            bundle.writestr("validation-evidence.json", json.dumps(archived))
            for name, payload in members:
                bundle.writestr(name, payload)
        try:
            with zipfile.ZipFile(io.BytesIO(buffer.getvalue())) as bundle:
                validate_archive_manifest(
                    bundle, bundle.getinfo("validation-evidence.json"), archived["artifacts"]
                )
        except ValueError:
            continue
        raise AssertionError(f"invalid {description} was accepted")
    print("validation evidence self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    subparsers = parser.add_subparsers(dest="command")
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.add_argument("--ios-metrics", type=Path)
    create_parser.add_argument("--artifact", action="append", default=[], type=Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--output", type=Path, required=True)
    verify_parser.add_argument("--receipt", type=Path, required=True)
    verify_parser.add_argument("--artifact-archive", type=Path, required=True)
    args = parser.parse_args()
    if not args.self_test and args.command is None:
        parser.error("a command is required")
    try:
        if args.self_test:
            self_test()
        elif args.command == "create":
            create(args.output, args.ios_metrics, args.artifact)
        elif args.command == "verify":
            verify(args.output, args.receipt, args.artifact_archive)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, urllib.error.URLError, zipfile.BadZipFile) as error:
        print(f"validation evidence unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
