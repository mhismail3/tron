#!/usr/bin/env python3
"""Compare current authoritative and Buildkite-shadow validation payloads.

Parity is deliberately stricter than historical evidence reuse. Both inputs
must be v2 documents bound to the current policy, toolchain, and their own
provider configuration. Runtime/host measurements may differ, but source,
workloads, and relevant iOS execution identity must agree exactly.

This is an offline payload-integrity and semantic comparison. It cannot prove
provider custody, API artifact identity, run conclusions, or other
provider-native authenticity; those observations must come from provider API
exports before any authority decision. Every evidence-manifested payload is
dereferenced. Successful Buildkite job manifests must also enumerate the exact
job-local command log and provider context paths, plus the exact iOS metrics or
PR Mac DMG path when applicable. Those nested command/DMG payloads remain
structure-only checks because they are not part of shadow evidence.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import re
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence


REPORT_SCHEMA = "tron.ci-parity.v1"
EVIDENCE_SCHEMA = "tron.validation.v2"
POLICY_SCHEMA = "tron.ci-policy.v1"
IOS_SCHEMA = "tron.ios-ci-metrics.v1"
CONTEXT_SCHEMA = "tron.ci-provider-context.v1"
JOB_MANIFEST_SCHEMA = "tron.ci-shadow-artifacts.v1"
BOOTSTRAP_EXECUTION_SCHEMA = "tron.ci-shadow-bootstrap-execution.v1"
CONTEXT_ARTIFACT = "provider-context.json"
IOS_ARTIFACT = "ios-ci-metrics.json"
COMMAND_ARTIFACT = "command.log"
MAC_DMG_ARTIFACT = "Tron-dryrun.dmg"
BOOTSTRAP_ARTIFACT = "executed-bootstrap.yml"
BOOTSTRAP_RECORD_ARTIFACT = "bootstrap-execution.json"
ROOT = Path(__file__).resolve().parent.parent
POLICY_PATH = ROOT / "config" / "ci-policy.json"
TOOLCHAIN_PATH = ROOT / "config" / "ci-toolchain.env"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OID_RE = re.compile(r"^[0-9a-f]{40}$|^[0-9a-f]{64}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"JSON object contains duplicate key {key!r}")
        result[key] = value
    return result


def reject_nonfinite(token: str) -> Any:
    raise ValueError(f"JSON contains unsupported numeric value {token}")


def parse_json(payload: str | bytes, field: str) -> Any:
    try:
        return json.loads(
            payload,
            object_pairs_hook=unique_object,
            parse_constant=reject_nonfinite,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{field} is not valid JSON: {error}") from error


def require_object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{field} must be an object")
    return value


def require_keys(value: Mapping[str, Any], expected: set[str], field: str) -> None:
    if set(value) != expected:
        missing = sorted(expected - set(value))
        extra = sorted(set(value) - expected)
        raise ValueError(f"{field} keys are invalid (missing={missing}, extra={extra})")


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise ValueError(f"{field} must be a non-empty, unpadded string")
    return value


def require_bool(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{field} must be a boolean")
    return value


def require_positive_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{field} must be a positive integer")
    return value


def require_nonnegative_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{field} must be a non-negative integer")
    return value


def require_git_oid(value: Any, field: str) -> str:
    oid = require_text(value, field)
    if not GIT_OID_RE.fullmatch(oid) or set(oid) == {"0"}:
        raise ValueError(f"{field} must be a lowercase, non-null Git object ID")
    return oid


def require_sha256(value: Any, field: str, *, prefixed: bool) -> str:
    digest = require_text(value, field)
    raw = digest.removeprefix("sha256:") if prefixed else digest
    if prefixed and not digest.startswith("sha256:"):
        raise ValueError(f"{field} must use the sha256: prefix")
    if not SHA256_RE.fullmatch(raw):
        raise ValueError(f"{field} must be a lowercase SHA-256 digest")
    return digest


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
        raise ValueError("document does not have a canonical JSON encoding") from error
    return encoded.encode("utf-8")


def canonical_digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def sha256_file(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def stream_file_digest(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            size += len(chunk)
            digest.update(chunk)
    return size, "sha256:" + digest.hexdigest()


def safe_repository_path(value: Any, field: str) -> tuple[str, Path]:
    text = require_text(value, field)
    pure = PurePosixPath(text)
    if (
        pure.is_absolute()
        or pure.as_posix() in ("", ".")
        or pure.as_posix() != text
        or ".." in pure.parts
        or "\\" in text
    ):
        raise ValueError(f"{field} must be a safe repository-relative path")
    path = (ROOT / Path(*pure.parts)).resolve(strict=True)
    try:
        relative = path.relative_to(ROOT).as_posix()
    except ValueError as error:
        raise ValueError(f"{field} resolves outside the repository") from error
    if not path.is_file():
        raise ValueError(f"{field} must identify a regular file")
    return relative, path


def file_binding(value: Any, field: str) -> dict[str, str]:
    relative, path = safe_repository_path(value, field)
    return {"path": relative, "sha256": sha256_file(path)}


def load_policy() -> dict[str, Any]:
    policy = require_object(parse_json(POLICY_PATH.read_bytes(), str(POLICY_PATH)), "CI policy")
    if policy.get("schema") != POLICY_SCHEMA:
        raise ValueError("CI policy uses an unsupported schema")
    required_jobs = policy.get("required_jobs")
    if (
        not isinstance(required_jobs, list)
        or len(required_jobs) != 6
        or any(not isinstance(job, str) or not job for job in required_jobs)
        or len(set(required_jobs)) != len(required_jobs)
    ):
        raise ValueError("CI policy must declare exactly six unique required jobs")
    providers = require_object(policy.get("providers"), "policy.providers")
    if not providers:
        raise ValueError("CI policy must declare providers")
    authoritative = [
        name for name, configuration in providers.items()
        if isinstance(configuration, dict) and configuration.get("role") == "authoritative"
    ]
    if len(authoritative) != 1:
        raise ValueError("CI policy must declare exactly one authoritative provider")
    authority_name = authoritative[0]
    authority = require_object(providers[authority_name], f"policy.providers.{authority_name}")
    if (
        authority.get("shadow") is not False
        or authority.get("required_check_authority") is not True
    ):
        raise ValueError("authoritative provider has inconsistent authority flags")
    for name, value in providers.items():
        provider = require_object(value, f"policy.providers.{name}")
        require_text(name, "policy provider name")
        require_text(provider.get("role"), f"policy.providers.{name}.role")
        require_bool(provider.get("shadow"), f"policy.providers.{name}.shadow")
        require_bool(
            provider.get("required_check_authority"),
            f"policy.providers.{name}.required_check_authority",
        )
        require_bool(
            provider.get("release_authority"),
            f"policy.providers.{name}.release_authority",
        )
        require_text(provider.get("configuration_path"),
                     f"policy.providers.{name}.configuration_path")
        if name != authority_name and provider.get("required_check_authority") is not False:
            raise ValueError("a non-authoritative provider has required-check authority")
    release = require_object(policy.get("release"), "policy.release")
    if release.get("provider") != authority_name:
        raise ValueError("release owner is not the sole authoritative provider")
    return {
        "document": policy,
        "binding": file_binding("config/ci-policy.json", "policy.path"),
        "toolchain": file_binding("config/ci-toolchain.env", "toolchain.path"),
        "required_jobs": tuple(required_jobs),
        "providers": providers,
        "authoritative_provider": authority_name,
    }


def provider_configuration(contract: Mapping[str, Any], provider: str) -> dict[str, str]:
    providers = require_object(contract["providers"], "policy.providers")
    configuration = providers.get(provider)
    if not isinstance(configuration, dict):
        raise ValueError(f"CI policy does not declare provider {provider!r}")
    return file_binding(
        configuration.get("configuration_path"),
        f"policy.providers.{provider}.configuration_path",
    )


def provider_bootstrap_configuration(
    contract: Mapping[str, Any], provider: str,
) -> dict[str, str] | None:
    providers = require_object(contract["providers"], "policy.providers")
    configuration = require_object(
        providers.get(provider), f"policy.providers.{provider}"
    )
    bootstrap_path = configuration.get("bootstrap_configuration_path")
    if bootstrap_path is None:
        return None
    return file_binding(
        bootstrap_path,
        f"policy.providers.{provider}.bootstrap_configuration_path",
    )


def verify_self_digest(document: Mapping[str, Any]) -> None:
    reported = require_sha256(document.get("evidence_sha256"), "evidence_sha256", prefixed=True)
    unsigned = copy.deepcopy(document)
    unsigned.pop("evidence_sha256", None)
    if reported != canonical_digest(unsigned):
        raise ValueError("evidence canonical self-digest does not match")


def verify_binding(value: Any, expected: Mapping[str, str], field: str) -> None:
    binding = require_object(value, field)
    require_keys(binding, {"path", "sha256"}, field)
    require_text(binding.get("path"), f"{field}.path")
    require_sha256(binding.get("sha256"), f"{field}.sha256", prefixed=True)
    if binding != expected:
        raise ValueError(f"{field} does not match the current repository binding")


def verify_optional_binding(
    value: Any, expected: Mapping[str, str] | None, field: str,
) -> None:
    if expected is None:
        if value is not None:
            raise ValueError(f"{field} must be null for this provider")
        return
    verify_binding(value, expected, field)


def validate_ios_metrics(value: Any, toolchain_digest: str) -> dict[str, Any]:
    metrics = require_object(value, "ios")
    require_keys(
        metrics,
        {
            "schema", "build_seconds", "build_exit_code", "test_seconds",
            "test_exit_code", "parallel_workers", "enumerated_tests", "counts",
            "runner_arch", "runner_os", "xcode", "sdk",
            "toolchain_manifest_sha256", "xcresult_summary_sha256",
            "test_enumeration_sha256",
        },
        "ios",
    )
    if metrics.get("schema") != IOS_SCHEMA:
        raise ValueError("ios uses an unsupported metrics schema")
    for name in ("build_seconds", "test_seconds"):
        duration = metrics.get(name)
        if (
            isinstance(duration, bool)
            or not isinstance(duration, (int, float))
            or not math.isfinite(duration)
            or duration < 0
        ):
            raise ValueError(f"ios.{name} must be a finite non-negative number")
    for name in ("build_exit_code", "test_exit_code"):
        value = metrics.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value != 0:
            raise ValueError("iOS metrics do not prove successful build and test execution")
    parallel_workers = require_positive_int(metrics.get("parallel_workers"),
                                            "ios.parallel_workers")
    enumerated_tests = require_bool(metrics.get("enumerated_tests"), "ios.enumerated_tests")
    counts = require_object(metrics.get("counts"), "ios.counts")
    allowed_counts = {
        "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"
    }
    if set(counts) - allowed_counts:
        raise ValueError("ios.counts contains unsupported fields")
    for name, count in counts.items():
        require_nonnegative_int(count, f"ios.counts.{name}")
    if require_positive_int(counts.get("totalTestCount"), "ios.counts.totalTestCount") < 1:
        raise ValueError("iOS metrics do not prove any executed tests")
    if counts.get("failedTests") != 0:
        raise ValueError("iOS metrics contain failed tests")
    for name in ("runner_arch", "runner_os", "xcode", "sdk"):
        require_text(metrics.get(name), f"ios.{name}")
    actual_toolchain = require_sha256(
        metrics.get("toolchain_manifest_sha256"),
        "ios.toolchain_manifest_sha256",
        prefixed=False,
    )
    if actual_toolchain != toolchain_digest.removeprefix("sha256:"):
        raise ValueError("iOS metrics do not bind the current toolchain")
    require_sha256(metrics.get("xcresult_summary_sha256"),
                   "ios.xcresult_summary_sha256", prefixed=False)
    enumeration_digest = metrics.get("test_enumeration_sha256")
    if enumerated_tests:
        require_sha256(enumeration_digest, "ios.test_enumeration_sha256", prefixed=False)
    elif enumeration_digest is not None:
        raise ValueError("iOS metrics contain an enumeration digest without enumeration")
    return {
        "build_exit_code": 0,
        "test_exit_code": 0,
        "parallel_workers": parallel_workers,
        "enumerated_tests": enumerated_tests,
        "counts": dict(sorted(counts.items())),
        "test_enumeration_sha256": enumeration_digest,
        "toolchain_manifest_sha256": actual_toolchain,
        "xcode": metrics["xcode"],
        "sdk": metrics["sdk"],
    }


def validate_artifact_manifest(
    value: Any, *, required_jobs: Sequence[str], require_job_manifests: bool,
) -> list[dict[str, Any]]:
    manifest = require_object(value, "artifacts")
    require_keys(manifest, {"algorithm", "entries", "manifest_sha256"}, "artifacts")
    if manifest.get("algorithm") != "sha256":
        raise ValueError("artifact manifest must use SHA-256")
    entries = manifest.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ValueError("artifact manifest must contain entries")
    paths: list[str] = []
    for index, item in enumerate(entries):
        entry = require_object(item, f"artifacts.entries[{index}]")
        require_keys(entry, {"path", "sha256", "size"}, f"artifacts.entries[{index}]")
        path = require_text(entry.get("path"), f"artifacts.entries[{index}].path")
        pure = PurePosixPath(path)
        if (
            pure.is_absolute()
            or pure.as_posix() in ("", ".")
            or pure.as_posix() != path
            or ".." in pure.parts
            or "\\" in path
        ):
            raise ValueError("artifact path must be safe and repository-relative")
        require_sha256(entry.get("sha256"), f"artifacts.entries[{index}].sha256",
                       prefixed=True)
        require_nonnegative_int(entry.get("size"), f"artifacts.entries[{index}].size")
        paths.append(path)
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise ValueError("artifact paths must be sorted and unique")
    if manifest.get("manifest_sha256") != canonical_digest(entries):
        raise ValueError("artifact manifest digest does not match its entries")
    basenames = [PurePosixPath(path).name for path in paths]
    for required in (CONTEXT_ARTIFACT, IOS_ARTIFACT):
        if basenames.count(required) != 1:
            raise ValueError(f"artifact manifest must contain exactly one {required}")
    job_manifests = [name for name in basenames if name.endswith("-manifest.json")]
    expected_manifests = {f"{job}-manifest.json" for job in required_jobs}
    if require_job_manifests and (
        len(job_manifests) != len(expected_manifests)
        or set(job_manifests) != expected_manifests
    ):
        raise ValueError("Buildkite artifact manifest does not contain the exact required jobs")
    required_basenames = {CONTEXT_ARTIFACT, IOS_ARTIFACT}
    if require_job_manifests:
        required_basenames |= expected_manifests
    for entry in entries:
        if PurePosixPath(entry["path"]).name in required_basenames and entry["size"] == 0:
            raise ValueError("required parity artifacts must not be empty")
    return entries


def artifact_file_index(root_value: Path, field: str) -> tuple[Path, dict[str, Path]]:
    if root_value.is_symlink():
        raise ValueError(f"{field} must not be a symlink")
    root = root_value.resolve(strict=True)
    if not root.is_dir():
        raise ValueError(f"{field} must be a directory")
    files: dict[str, Path] = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"{field} contains a symlink: {path.relative_to(root)}")
        if not path.is_file():
            continue
        resolved = path.resolve(strict=True)
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError as error:
            raise ValueError(f"{field} contains a file outside its root") from error
        if relative in files:
            raise ValueError(f"{field} contains an ambiguous file path: {relative}")
        files[relative] = resolved
    return root, files


def resolve_manifest_payload(
    manifest_path: str,
    files: Mapping[str, Path],
    *,
    field: str,
) -> Path:
    expected = PurePosixPath(manifest_path)
    exact = [path for relative, path in files.items() if relative == manifest_path]
    suffix = [
        path
        for relative, path in files.items()
        if len(PurePosixPath(relative).parts) <= len(expected.parts)
        and expected.parts[-len(PurePosixPath(relative).parts):]
        == PurePosixPath(relative).parts
    ]
    basename = [
        path
        for relative, path in files.items()
        if PurePosixPath(relative).name == expected.name
    ]
    matches = exact or suffix or basename
    if len(matches) != 1:
        raise ValueError(
            f"{field} manifested path {manifest_path!r} resolved to {len(matches)} files"
        )
    return matches[0]


def verify_artifact_payloads(
    root: Path,
    entries: Sequence[Mapping[str, Any]],
    *,
    field: str,
) -> dict[str, Path]:
    _, files = artifact_file_index(root, field)
    payloads: dict[str, Path] = {}
    used: set[Path] = set()
    for index, entry in enumerate(entries):
        manifest_path = require_text(entry.get("path"), f"{field}.entries[{index}].path")
        payload = resolve_manifest_payload(manifest_path, files, field=field)
        if payload in used:
            raise ValueError(f"{field} maps multiple manifest entries to one payload")
        used.add(payload)
        actual_size, actual_digest = stream_file_digest(payload)
        if actual_size != entry.get("size"):
            raise ValueError(f"{field} payload {manifest_path!r} has the wrong size")
        if actual_digest != entry.get("sha256"):
            raise ValueError(f"{field} payload {manifest_path!r} has the wrong SHA-256")
        payloads[manifest_path] = payload
    return payloads


def unique_payload(
    payloads: Mapping[str, Path], basename: str, field: str,
) -> Path:
    matches = [
        payload
        for manifest_path, payload in payloads.items()
        if PurePosixPath(manifest_path).name == basename
    ]
    if len(matches) != 1:
        raise ValueError(f"{field} requires exactly one {basename}")
    return matches[0]


def repository_slug(value: Any, field: str) -> str:
    slug = require_text(value, field)
    if not REPOSITORY_RE.fullmatch(slug):
        raise ValueError(f"{field} must be an owner/repository slug")
    return slug


def provider_authority(contract: Mapping[str, Any], provider: str) -> dict[str, Any]:
    configuration = require_object(
        require_object(contract["providers"], "policy.providers").get(provider),
        f"policy.providers.{provider}",
    )
    result = {
        "role": configuration.get("role"),
        "shadow": configuration.get("shadow"),
        "required_check_authority": configuration.get("required_check_authority"),
        "release_authority": configuration.get("release_authority"),
        "configuration_path": configuration.get("configuration_path"),
    }
    bootstrap = configuration.get("bootstrap_configuration_path")
    if bootstrap is not None:
        result["bootstrap_configuration_path"] = bootstrap
    return result


def validate_provider_context(
    value: Any,
    *,
    contract: Mapping[str, Any],
    evidence: Mapping[str, Any],
) -> dict[str, Any]:
    context = require_object(value, "provider context payload")
    require_keys(
        context,
        {
            "schema", "provider", "authority", "event", "repository", "run",
            "pull_request", "base", "head", "source",
        },
        "provider context payload",
    )
    if context.get("schema") != CONTEXT_SCHEMA:
        raise ValueError("provider context payload uses an unsupported schema")
    ci = require_object(evidence.get("ci"), "evidence.ci")
    pull = require_object(evidence.get("pull_request"), "evidence.pull_request")
    provider = require_text(context.get("provider"), "context.provider")
    if provider != ci.get("provider"):
        raise ValueError("provider context provider differs from evidence")
    if context.get("authority") != provider_authority(contract, provider):
        raise ValueError("provider context authority differs from current policy")

    event = require_object(context.get("event"), "context.event")
    require_keys(event, {"kind", "provider_name", "action"}, "context.event")
    if (
        event.get("kind") != "pull_request"
        or event.get("provider_name") != "pull_request"
        or event.get("action")
        not in {"opened", "synchronize", "reopened", "ready_for_review"}
    ):
        raise ValueError("parity provider context must represent a pull request")
    repository = require_object(context.get("repository"), "context.repository")
    require_keys(repository, {"slug", "main_branch"}, "context.repository")
    repository_name = repository_slug(repository.get("slug"), "context.repository.slug")
    if repository_name != evidence.get("repository"):
        raise ValueError("provider context repository differs from evidence")
    if repository.get("main_branch") != contract["document"].get("main_branch"):
        raise ValueError("provider context main branch differs from policy")

    run = require_object(context.get("run"), "context.run")
    require_keys(run, {"id", "number", "attempt"}, "context.run")
    run_id = require_text(run.get("id"), "context.run.id")
    if run_id != ci.get("run_id"):
        raise ValueError("provider context run ID differs from evidence")
    if provider == "github-actions":
        if not run_id.isdigit() or int(run_id) < 1:
            raise ValueError("GitHub provider context run ID is malformed")
    elif provider == "buildkite":
        try:
            if str(uuid.UUID(run_id)) != run_id:
                raise ValueError
        except ValueError as error:
            raise ValueError("Buildkite provider context run ID is malformed") from error
    else:
        raise ValueError("provider context provider is unsupported")
    run_number = require_positive_int(run.get("number"), "context.run.number")
    run_attempt = require_positive_int(run.get("attempt"), "context.run.attempt")
    if run_attempt != ci.get("run_attempt"):
        raise ValueError("provider context run attempt differs from evidence")
    if provider == "buildkite" and run_attempt != 1:
        raise ValueError("Buildkite provider context attempt must be one")

    context_pull = require_object(context.get("pull_request"), "context.pull_request")
    require_keys(context_pull, {"number", "draft"}, "context.pull_request")
    number = require_positive_int(context_pull.get("number"), "context.pull_request.number")
    if number != pull.get("number") or require_bool(
        context_pull.get("draft"), "context.pull_request.draft"
    ):
        raise ValueError("provider context pull request differs from ready evidence")

    base = require_object(context.get("base"), "context.base")
    head = require_object(context.get("head"), "context.head")
    for name, identity in (("base", base), ("head", head)):
        require_keys(identity, {"repository", "ref", "sha"}, f"context.{name}")
        repository_slug(identity.get("repository"), f"context.{name}.repository")
        require_text(identity.get("ref"), f"context.{name}.ref")
        require_git_oid(identity.get("sha"), f"context.{name}.sha")
    if (
        base.get("repository") != repository_name
        or base.get("ref") != contract["document"].get("main_branch")
        or base.get("sha") != pull.get("base_sha")
        or head.get("sha") != pull.get("head_sha")
    ):
        raise ValueError("provider context base/head identity differs from evidence")

    source = require_object(context.get("source"), "context.source")
    require_keys(source, {"ref", "sha", "tree", "parents"}, "context.source")
    if source != {
        "ref": contract["document"]["pull_request_merge_ref"].format(number=number),
        "sha": pull.get("merge_sha"),
        "tree": pull.get("merge_tree"),
        "parents": [pull.get("base_sha"), pull.get("head_sha")],
    }:
        raise ValueError("provider context source identity differs from evidence")
    return {
        "provider": provider,
        "run_id": run_id,
        "run_number": run_number,
        "run_attempt": run_attempt,
        "repository": repository_name,
        "pull_request": number,
        "action": event["action"],
        "source": source,
    }


def validate_job_file_entries(
    value: Any, *, job: str,
) -> list[dict[str, Any]]:
    # These nested entries describe provider-held workload artifacts. The
    # shadow-evidence bundle contains only each job manifest plus the shared
    # context/metrics payloads, so all entries are structure-checked while only
    # context and iOS metrics can be dereferenced and content-bound offline.
    # Command logs and the PR Mac DMG still have exact required paths here so
    # a manifest cannot claim workload parity while silently omitting them.
    if not isinstance(value, list) or not value:
        raise ValueError(f"{job} manifest has no file entries")
    entries: list[dict[str, Any]] = []
    paths: list[str] = []
    for index, item in enumerate(value):
        entry = require_object(item, f"{job}.files[{index}]")
        require_keys(entry, {"path", "sha256", "size"}, f"{job}.files[{index}]")
        path = require_text(entry.get("path"), f"{job}.files[{index}].path")
        pure = PurePosixPath(path)
        if (
            pure.is_absolute()
            or pure.as_posix() in ("", ".")
            or pure.as_posix() != path
            or ".." in pure.parts
            or "\\" in path
        ):
            raise ValueError(f"{job} manifest contains an unsafe file path")
        require_sha256(entry.get("sha256"), f"{job}.files[{index}].sha256", prefixed=False)
        require_nonnegative_int(entry.get("size"), f"{job}.files[{index}].size")
        entries.append(entry)
        paths.append(path)
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise ValueError(f"{job} manifest file paths must be sorted and unique")
    return entries


def validate_candidate_job_manifests(
    *,
    payloads: Mapping[str, Path],
    evidence: Mapping[str, Any],
    context: Mapping[str, Any],
    context_payload: bytes,
    ios_payload: bytes,
    required_jobs: Sequence[str],
) -> None:
    ci = require_object(evidence.get("ci"), "evidence.ci")
    if ci.get("provider") != "buildkite" or context.get("provider") != "buildkite":
        raise ValueError("candidate job manifests require Buildkite shadow evidence")
    expected_context_digest = hashlib.sha256(context_payload).hexdigest()
    expected_ios_digest = hashlib.sha256(ios_payload).hexdigest()
    for job in required_jobs:
        path = unique_payload(payloads, f"{job}-manifest.json", "candidate artifacts")
        manifest = require_object(
            parse_json(path.read_bytes(), f"candidate {job} manifest"),
            f"candidate {job} manifest",
        )
        require_keys(
            manifest,
            {
                "schema", "advisory_only", "provider", "job", "exit_code",
                "failure_classification", "started_at", "finished_at",
                "duration_seconds", "build_id", "build_number", "job_id",
                "retry_count", "retry_source", "files",
            },
            f"candidate {job} manifest",
        )
        if (
            manifest.get("schema") != JOB_MANIFEST_SCHEMA
            or manifest.get("advisory_only") is not True
            or manifest.get("provider") != "buildkite"
            or manifest.get("job") != job
            or manifest.get("failure_classification") != "none"
        ):
            raise ValueError(f"candidate {job} manifest does not prove advisory success")
        exit_code = manifest.get("exit_code")
        if isinstance(exit_code, bool) or not isinstance(exit_code, int) or exit_code != 0:
            raise ValueError(f"candidate {job} manifest has an invalid exit code")
        if manifest.get("build_id") != ci.get("run_id"):
            raise ValueError(f"candidate {job} manifest belongs to another build")
        build_number = manifest.get("build_number")
        if str(build_number) != str(context["run_number"]):
            raise ValueError(f"candidate {job} manifest has the wrong build number")
        require_text(manifest.get("job_id"), f"candidate {job}.job_id")
        require_nonnegative_int(manifest.get("retry_count"), f"candidate {job}.retry_count")
        retry_source = manifest.get("retry_source")
        if retry_source is not None:
            require_text(retry_source, f"candidate {job}.retry_source")
        duration = require_nonnegative_int(
            manifest.get("duration_seconds"), f"candidate {job}.duration_seconds"
        )
        try:
            started = datetime.strptime(
                require_text(manifest.get("started_at"), f"candidate {job}.started_at"),
                "%Y-%m-%dT%H:%M:%SZ",
            ).replace(tzinfo=timezone.utc)
            finished = datetime.strptime(
                require_text(manifest.get("finished_at"), f"candidate {job}.finished_at"),
                "%Y-%m-%dT%H:%M:%SZ",
            ).replace(tzinfo=timezone.utc)
        except ValueError as error:
            raise ValueError(f"candidate {job} manifest timing is malformed") from error
        if finished < started or int((finished - started).total_seconds()) != duration:
            raise ValueError(f"candidate {job} manifest duration is inconsistent")
        files = validate_job_file_entries(manifest.get("files"), job=job)
        commands = [
            item
            for item in files
            if PurePosixPath(item["path"]).name == COMMAND_ARTIFACT
        ]
        expected_command_path = f"build/ci-shadow/{job}/{COMMAND_ARTIFACT}"
        if len(commands) != 1 or commands[0]["path"] != expected_command_path:
            raise ValueError(f"candidate {job} manifest lacks its exact command log")
        contexts = [
            item
            for item in files
            if PurePosixPath(item["path"]).name == CONTEXT_ARTIFACT
        ]
        expected_context_path = f"build/ci-shadow/{job}/{CONTEXT_ARTIFACT}"
        if (
            len(contexts) != 1
            or contexts[0]["path"] != expected_context_path
            or contexts[0]["size"] != len(context_payload)
            or contexts[0]["sha256"] != expected_context_digest
        ):
            raise ValueError(f"candidate {job} manifest is not bound to provider context")
        metrics = [
            item for item in files if PurePosixPath(item["path"]).name == IOS_ARTIFACT
        ]
        if job == "ios":
            if (
                len(metrics) != 1
                or metrics[0]["path"] != f"packages/ios-app/build/{IOS_ARTIFACT}"
                or metrics[0]["size"] != len(ios_payload)
                or metrics[0]["sha256"] != expected_ios_digest
            ):
                raise ValueError("candidate iOS manifest is not bound to iOS metrics")
        elif metrics:
            raise ValueError(f"candidate {job} unexpectedly claims iOS metrics")
        dmgs = [
            item
            for item in files
            if PurePosixPath(item["path"]).name == MAC_DMG_ARTIFACT
        ]
        if job == "mac":
            if (
                len(dmgs) != 1
                or dmgs[0]["path"]
                != f"packages/mac-app/dist/{MAC_DMG_ARTIFACT}"
            ):
                raise ValueError("candidate Mac manifest lacks the exact PR dry-run DMG")
        elif dmgs:
            raise ValueError(f"candidate {job} unexpectedly claims the PR Mac DMG")


def validate_bootstrap_payloads(
    *,
    payloads: Mapping[str, Path],
    bootstrap: Mapping[str, str] | None,
) -> None:
    executed_paths = [
        path
        for name, path in payloads.items()
        if PurePosixPath(name).name == BOOTSTRAP_ARTIFACT
    ]
    record_paths = [
        path
        for name, path in payloads.items()
        if PurePosixPath(name).name == BOOTSTRAP_RECORD_ARTIFACT
    ]
    if bootstrap is None:
        if executed_paths or record_paths:
            raise ValueError("provider without a bootstrap recorded bootstrap payloads")
        return
    if len(executed_paths) != 1 or len(record_paths) != 1:
        raise ValueError("candidate artifacts lack exact bootstrap execution payloads")
    executed_size, executed_digest = stream_file_digest(executed_paths[0])
    if executed_digest != bootstrap["sha256"]:
        raise ValueError("executed bootstrap differs from current configuration")
    record = require_object(
        parse_json(record_paths[0].read_bytes(), "bootstrap execution record"),
        "bootstrap execution record",
    )
    require_keys(
        record,
        {"schema", "repository_path", "sha256", "size", "matches_checked_out_merge"},
        "bootstrap execution record",
    )
    if record != {
        "schema": BOOTSTRAP_EXECUTION_SCHEMA,
        "repository_path": bootstrap["path"],
        "sha256": executed_digest,
        "size": executed_size,
        "matches_checked_out_merge": True,
    }:
        raise ValueError("bootstrap execution record differs from executed configuration")


def validate_evidence(
    document: Any,
    contract: Mapping[str, Any],
    *,
    candidate: bool,
    artifact_root: Path,
) -> dict[str, Any]:
    evidence = require_object(document, "validation evidence")
    expected_keys = {
        "schema", "repository", "ci", "pull_request", "digests", "jobs", "ios",
        "artifacts", "evidence_sha256",
    }
    if set(evidence) != expected_keys:
        raise ValueError("v2 evidence has missing or unsupported top-level fields")
    if evidence.get("schema") != EVIDENCE_SCHEMA:
        raise ValueError("CI parity requires tron.validation.v2 evidence")
    verify_self_digest(evidence)
    repository = require_text(evidence.get("repository"), "repository")

    ci = require_object(evidence.get("ci"), "ci")
    require_keys(ci, {"provider", "run_id", "run_attempt"}, "ci")
    provider = require_text(ci.get("provider"), "ci.provider")
    require_text(ci.get("run_id"), "ci.run_id")
    require_positive_int(ci.get("run_attempt"), "ci.run_attempt")
    if provider not in contract["providers"]:
        raise ValueError("evidence provider is not declared by the current policy")

    pull = require_object(evidence.get("pull_request"), "pull_request")
    require_keys(pull, {"number", "head_sha", "base_sha", "merge_sha", "merge_tree"},
                 "pull_request")
    pull_identity = {
        "number": require_positive_int(pull.get("number"), "pull_request.number"),
        "head_sha": require_git_oid(pull.get("head_sha"), "pull_request.head_sha"),
        "base_sha": require_git_oid(pull.get("base_sha"), "pull_request.base_sha"),
        "merge_sha": require_git_oid(pull.get("merge_sha"), "pull_request.merge_sha"),
        "merge_tree": require_git_oid(pull.get("merge_tree"), "pull_request.merge_tree"),
    }

    digests = require_object(evidence.get("digests"), "digests")
    require_keys(
        digests,
        {"policy", "configuration", "bootstrap_configuration", "toolchain"},
        "digests",
    )
    verify_binding(digests.get("policy"), contract["binding"], "digests.policy")
    configuration = provider_configuration(contract, provider)
    bootstrap_configuration = provider_bootstrap_configuration(contract, provider)
    verify_binding(digests.get("configuration"), configuration, "digests.configuration")
    verify_optional_binding(
        digests.get("bootstrap_configuration"),
        bootstrap_configuration,
        "digests.bootstrap_configuration",
    )
    verify_binding(digests.get("toolchain"), contract["toolchain"], "digests.toolchain")

    expected_jobs = {name: "success" for name in contract["required_jobs"]}
    if evidence.get("jobs") != expected_jobs:
        raise ValueError("evidence does not contain the exact policy-required job results")
    ios = validate_ios_metrics(evidence.get("ios"), contract["toolchain"]["sha256"])
    artifact_entries = validate_artifact_manifest(
        evidence.get("artifacts"),
        required_jobs=contract["required_jobs"],
        require_job_manifests=candidate,
    )
    payloads = verify_artifact_payloads(
        artifact_root,
        artifact_entries,
        field="candidate artifacts" if candidate else "reference artifacts",
    )
    context_path = unique_payload(payloads, CONTEXT_ARTIFACT, "artifact payloads")
    ios_path = unique_payload(payloads, IOS_ARTIFACT, "artifact payloads")
    context_payload = context_path.read_bytes()
    ios_payload = ios_path.read_bytes()
    payload_metrics = parse_json(ios_payload, str(ios_path))
    if canonical_json_bytes(payload_metrics) != canonical_json_bytes(evidence.get("ios")):
        raise ValueError("iOS metrics payload differs from validation evidence")
    context_summary = validate_provider_context(
        parse_json(context_payload, str(context_path)),
        contract=contract,
        evidence=evidence,
    )
    validate_bootstrap_payloads(
        payloads=payloads,
        bootstrap=bootstrap_configuration,
    )
    if candidate:
        validate_candidate_job_manifests(
            payloads=payloads,
            evidence=evidence,
            context=context_summary,
            context_payload=context_payload,
            ios_payload=ios_payload,
            required_jobs=contract["required_jobs"],
        )
    return {
        "provider": provider,
        "run_id": ci["run_id"],
        "run_attempt": ci["run_attempt"],
        "validation_evidence_sha256": evidence["evidence_sha256"],
        "artifact_manifest_sha256": evidence["artifacts"]["manifest_sha256"],
        "configuration": configuration,
        "bootstrap_configuration": bootstrap_configuration,
        "comparable": {
            "repository": repository,
            "pull_request": pull_identity,
            "trigger_action": context_summary["action"],
            "policy": contract["binding"],
            "toolchain": contract["toolchain"],
            "jobs": expected_jobs,
            "ios": ios,
        },
    }


def compare(
    reference: Any,
    candidate: Any,
    *,
    reference_artifacts: Path,
    candidate_artifacts: Path,
) -> dict[str, Any]:
    contract = load_policy()
    expected = validate_evidence(
        reference,
        contract,
        candidate=False,
        artifact_root=reference_artifacts,
    )
    actual = validate_evidence(
        candidate,
        contract,
        candidate=True,
        artifact_root=candidate_artifacts,
    )
    authority_name = contract["authoritative_provider"]
    if expected["provider"] != authority_name:
        raise ValueError("reference evidence is not from the sole authoritative provider")
    if actual["provider"] == expected["provider"]:
        raise ValueError("reference and candidate providers must be different")
    candidate_policy = require_object(
        contract["providers"].get(actual["provider"]),
        f"policy.providers.{actual['provider']}",
    )
    if (
        actual["provider"] != "buildkite"
        or candidate_policy.get("role") != "shadow"
        or candidate_policy.get("shadow") is not True
        or candidate_policy.get("required_check_authority") is not False
        or candidate_policy.get("release_authority") is not False
    ):
        raise ValueError("candidate evidence is not from the declared Buildkite shadow")

    differences: list[dict[str, Any]] = []

    def visit(path: str, left: Any, right: Any) -> None:
        if isinstance(left, dict) and isinstance(right, dict):
            for key in sorted(set(left) | set(right)):
                visit(f"{path}.{key}" if path else key, left.get(key), right.get(key))
            return
        if left != right:
            differences.append({"field": path, "reference": left, "candidate": right})

    visit("", expected["comparable"], actual["comparable"])
    report = {
        "schema": REPORT_SCHEMA,
        "status": "pass" if not differences else "fail",
        "reference_provider": expected["provider"],
        "candidate_provider": actual["provider"],
        # Configuration bindings are provider-specific and validated against
        # current policy above; they are reported, never compared for equality.
        "reference_configuration": expected["configuration"],
        "candidate_configuration": actual["configuration"],
        "reference_bootstrap_configuration": expected["bootstrap_configuration"],
        "candidate_bootstrap_configuration": actual["bootstrap_configuration"],
        "tested_merge_tree": expected["comparable"]["pull_request"]["merge_tree"],
        "reference_run": {
            "id": expected["run_id"],
            "attempt": expected["run_attempt"],
            "validation_evidence_sha256": expected["validation_evidence_sha256"],
            "artifact_manifest_sha256": expected["artifact_manifest_sha256"],
        },
        "candidate_run": {
            "id": actual["run_id"],
            "attempt": actual["run_attempt"],
            "validation_evidence_sha256": actual["validation_evidence_sha256"],
            "artifact_manifest_sha256": actual["artifact_manifest_sha256"],
        },
        "provider_native_authenticity": {
            "verified": False,
            "nested_job_payload_custody_verified": False,
            "scope": "offline-payload-integrity-and-semantic-parity-only",
        },
        "differences": differences,
    }
    report["report_sha256"] = canonical_digest(report)
    return report


def seal(document: Mapping[str, Any]) -> dict[str, Any]:
    sealed = copy.deepcopy(document)
    sealed.pop("evidence_sha256", None)
    sealed["evidence_sha256"] = canonical_digest(sealed)
    return sealed


def encoded_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def artifact_entries(payloads: Mapping[str, bytes]) -> dict[str, Any]:
    entries = [
        {
            "path": path,
            "sha256": "sha256:" + hashlib.sha256(payload).hexdigest(),
            "size": len(payload),
        }
        for path, payload in sorted(payloads.items())
    ]
    return {
        "algorithm": "sha256",
        "entries": entries,
        "manifest_sha256": canonical_digest(entries),
    }


def write_test_payloads(
    root: Path,
    payloads: Mapping[str, bytes],
    *,
    flattened: bool,
) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for manifest_path, payload in payloads.items():
        destination = root / (
            PurePosixPath(manifest_path).name if flattened else Path(manifest_path)
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)


def test_provider_context(
    contract: Mapping[str, Any],
    provider: str,
    *,
    run_id: str,
    run_number: int,
) -> dict[str, Any]:
    return {
        "schema": CONTEXT_SCHEMA,
        "provider": provider,
        "authority": provider_authority(contract, provider),
        "event": {
            "kind": "pull_request",
            "provider_name": "pull_request",
            "action": "opened",
        },
        "repository": {
            "slug": "example/tron",
            "main_branch": contract["document"]["main_branch"],
        },
        "run": {"id": run_id, "number": run_number, "attempt": 1},
        "pull_request": {"number": 42, "draft": False},
        "base": {
            "repository": "example/tron",
            "ref": contract["document"]["main_branch"],
            "sha": "b" * 40,
        },
        "head": {
            "repository": "example/tron",
            "ref": "feature",
            "sha": "a" * 40,
        },
        "source": {
            "ref": "refs/pull/42/merge",
            "sha": "c" * 40,
            "tree": "d" * 40,
            "parents": ["b" * 40, "a" * 40],
        },
    }


def test_job_manifest(
    job: str,
    *,
    run_id: str,
    run_number: int,
    context_payload: bytes,
    ios_payload: bytes,
) -> dict[str, Any]:
    files = [
        {
            "path": f"build/ci-shadow/{job}/command.log",
            "sha256": "3" * 64,
            "size": 17,
        },
        {
            "path": f"build/ci-shadow/{job}/{CONTEXT_ARTIFACT}",
            "sha256": hashlib.sha256(context_payload).hexdigest(),
            "size": len(context_payload),
        },
    ]
    if job == "ios":
        files.append({
            "path": f"packages/ios-app/build/{IOS_ARTIFACT}",
            "sha256": hashlib.sha256(ios_payload).hexdigest(),
            "size": len(ios_payload),
        })
    if job == "mac":
        files.append({
            "path": "packages/mac-app/dist/Tron-dryrun.dmg",
            "sha256": "4" * 64,
            "size": 4096,
        })
    return {
        "schema": JOB_MANIFEST_SCHEMA,
        "advisory_only": True,
        "provider": "buildkite",
        "job": job,
        "exit_code": 0,
        "failure_classification": "none",
        "started_at": "2026-01-01T00:00:00Z",
        "finished_at": "2026-01-01T00:00:03Z",
        "duration_seconds": 3,
        "build_id": run_id,
        "build_number": str(run_number),
        "job_id": f"job-{job}",
        "retry_count": 0,
        "retry_source": None,
        "files": sorted(files, key=lambda entry: entry["path"]),
    }


def test_document(
    contract: Mapping[str, Any], provider: str, artifact_root: Path,
) -> dict[str, Any]:
    candidate = provider == "buildkite"
    run_id = "12345678-1234-4234-8234-123456789abc" if candidate else "99"
    run_number = 7 if candidate else 12
    metrics = {
        "schema": IOS_SCHEMA,
        "build_seconds": 75 if candidate else 100,
        "build_exit_code": 0,
        "test_seconds": 150 if candidate else 200,
        "test_exit_code": 0,
        "parallel_workers": 1,
        "enumerated_tests": False,
        "counts": {"failedTests": 0, "passedTests": 12, "totalTestCount": 12},
        "runner_arch": "arm64",
        "runner_os": "candidate-fixture-os" if candidate else "reference-fixture-os",
        "xcode": "Xcode 26.3",
        "sdk": "26.2",
        "toolchain_manifest_sha256": contract["toolchain"]["sha256"].removeprefix("sha256:"),
        "xcresult_summary_sha256": "1" * 64,
        "test_enumeration_sha256": None,
    }
    context_payload = encoded_json(
        test_provider_context(
            contract,
            provider,
            run_id=run_id,
            run_number=run_number,
        )
    )
    ios_payload = encoded_json(metrics)
    prefix = "build/ci-shadow/evidence/payload" if candidate else "build"
    payloads: dict[str, bytes] = {
        f"{prefix}/{CONTEXT_ARTIFACT}": context_payload,
        f"{prefix}/{IOS_ARTIFACT}": ios_payload,
    }
    bootstrap_configuration = provider_bootstrap_configuration(contract, provider)
    if bootstrap_configuration is not None:
        bootstrap_payload = (ROOT / bootstrap_configuration["path"]).read_bytes()
        payloads[f"{prefix}/{BOOTSTRAP_ARTIFACT}"] = bootstrap_payload
        payloads[f"{prefix}/{BOOTSTRAP_RECORD_ARTIFACT}"] = encoded_json({
            "schema": BOOTSTRAP_EXECUTION_SCHEMA,
            "repository_path": bootstrap_configuration["path"],
            "sha256": "sha256:" + hashlib.sha256(bootstrap_payload).hexdigest(),
            "size": len(bootstrap_payload),
            "matches_checked_out_merge": True,
        })
    if candidate:
        for job in contract["required_jobs"]:
            payloads[f"{prefix}/{job}-manifest.json"] = encoded_json(
                test_job_manifest(
                    job,
                    run_id=run_id,
                    run_number=run_number,
                    context_payload=context_payload,
                    ios_payload=ios_payload,
                )
            )
    artifacts = artifact_entries(payloads)
    write_test_payloads(artifact_root, payloads, flattened=not candidate)
    return seal({
        "schema": EVIDENCE_SCHEMA,
        "repository": "example/tron",
        "ci": {
            "provider": provider,
            "run_id": run_id,
            "run_attempt": 1,
        },
        "pull_request": {
            "number": 42,
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
            "merge_sha": "c" * 40,
            "merge_tree": "d" * 40,
        },
        "digests": {
            "policy": contract["binding"],
            "configuration": provider_configuration(contract, provider),
            "bootstrap_configuration": bootstrap_configuration,
            "toolchain": contract["toolchain"],
        },
        "jobs": {name: "success" for name in contract["required_jobs"]},
        "ios": metrics,
        "artifacts": artifacts,
    })


def reseal(document: Mapping[str, Any]) -> dict[str, Any]:
    unsigned = copy.deepcopy(document)
    unsigned.pop("evidence_sha256", None)
    return seal(unsigned)


def expect_error(callback: Any, description: str) -> None:
    try:
        callback()
    except ValueError:
        return
    raise AssertionError(f"invalid {description} was accepted")


def self_test() -> None:
    contract = load_policy()
    with tempfile.TemporaryDirectory(prefix="tron-ci-parity-") as temporary:
        temporary_root = Path(temporary)
        fixture_number = 0

        def fixture() -> tuple[dict[str, Any], dict[str, Any], Path, Path]:
            nonlocal fixture_number
            fixture_number += 1
            root = temporary_root / str(fixture_number)
            reference_root = root / "reference"
            candidate_root = root / "candidate"
            reference = test_document(
                contract,
                contract["authoritative_provider"],
                reference_root,
            )
            candidate = test_document(contract, "buildkite", candidate_root)
            return reference, candidate, reference_root, candidate_root

        def run_compare(
            reference: Any,
            candidate: Any,
            reference_root: Path,
            candidate_root: Path,
        ) -> dict[str, Any]:
            return compare(
                reference,
                candidate,
                reference_artifacts=reference_root,
                candidate_artifacts=candidate_root,
            )

        def manifested_entry(document: dict[str, Any], basename: str) -> dict[str, Any]:
            matches = [
                entry
                for entry in document["artifacts"]["entries"]
                if PurePosixPath(entry["path"]).name == basename
            ]
            if len(matches) != 1:
                raise AssertionError(f"fixture lacks exactly one {basename}")
            return matches[0]

        def replace_payload(
            document: dict[str, Any],
            root: Path,
            basename: str,
            payload: bytes,
        ) -> None:
            entry = manifested_entry(document, basename)
            _, files = artifact_file_index(root, "fixture artifacts")
            path = resolve_manifest_payload(entry["path"], files, field="fixture artifacts")
            path.write_bytes(payload)
            entry["size"] = len(payload)
            entry["sha256"] = "sha256:" + hashlib.sha256(payload).hexdigest()
            document["artifacts"]["manifest_sha256"] = canonical_digest(
                document["artifacts"]["entries"]
            )

        def candidate_with_metrics(
            candidate: dict[str, Any], candidate_root: Path, metrics: dict[str, Any]
        ) -> dict[str, Any]:
            changed = copy.deepcopy(candidate)
            metrics_payload = encoded_json(metrics)
            replace_payload(changed, candidate_root, IOS_ARTIFACT, metrics_payload)
            ios_manifest_entry = manifested_entry(changed, "ios-manifest.json")
            _, files = artifact_file_index(candidate_root, "fixture artifacts")
            ios_manifest_path = resolve_manifest_payload(
                ios_manifest_entry["path"], files, field="fixture artifacts"
            )
            ios_manifest = require_object(
                parse_json(ios_manifest_path.read_bytes(), "fixture iOS manifest"),
                "fixture iOS manifest",
            )
            metrics_entries = [
                entry
                for entry in ios_manifest["files"]
                if PurePosixPath(entry["path"]).name == IOS_ARTIFACT
            ]
            assert len(metrics_entries) == 1
            metrics_entries[0]["size"] = len(metrics_payload)
            metrics_entries[0]["sha256"] = hashlib.sha256(metrics_payload).hexdigest()
            replace_payload(
                changed,
                candidate_root,
                "ios-manifest.json",
                encoded_json(ios_manifest),
            )
            changed["ios"] = metrics
            return reseal(changed)

        def candidate_with_context_action(
            candidate: dict[str, Any], candidate_root: Path, action: str
        ) -> dict[str, Any]:
            changed = copy.deepcopy(candidate)
            _, files = artifact_file_index(candidate_root, "fixture artifacts")
            context_entry = manifested_entry(changed, CONTEXT_ARTIFACT)
            context_path = resolve_manifest_payload(
                context_entry["path"], files, field="fixture artifacts"
            )
            context = require_object(
                parse_json(context_path.read_bytes(), "fixture context"),
                "fixture context",
            )
            context["event"]["action"] = action
            context_payload = encoded_json(context)
            replace_payload(changed, candidate_root, CONTEXT_ARTIFACT, context_payload)
            context_digest = hashlib.sha256(context_payload).hexdigest()
            for job in contract["required_jobs"]:
                name = f"{job}-manifest.json"
                _, files = artifact_file_index(candidate_root, "fixture artifacts")
                entry = manifested_entry(changed, name)
                path = resolve_manifest_payload(entry["path"], files, field="fixture artifacts")
                manifest = require_object(
                    parse_json(path.read_bytes(), f"fixture {job} manifest"),
                    f"fixture {job} manifest",
                )
                context_entries = [
                    item
                    for item in manifest["files"]
                    if item["path"] == f"build/ci-shadow/{job}/{CONTEXT_ARTIFACT}"
                ]
                assert len(context_entries) == 1
                context_entries[0]["sha256"] = context_digest
                context_entries[0]["size"] = len(context_payload)
                replace_payload(changed, candidate_root, name, encoded_json(manifest))
            return reseal(changed)

        reference, candidate, reference_root, candidate_root = fixture()
        report = run_compare(reference, candidate, reference_root, candidate_root)
        assert report["status"] == "pass"
        assert report["reference_run"]["id"] == reference["ci"]["run_id"]
        assert report["candidate_run"]["id"] == candidate["ci"]["run_id"]
        assert report["reference_run"]["validation_evidence_sha256"] == reference["evidence_sha256"]
        assert report["candidate_run"]["validation_evidence_sha256"] == candidate["evidence_sha256"]
        unsigned_report = copy.deepcopy(report)
        reported_digest = unsigned_report.pop("report_sha256")
        assert reported_digest == canonical_digest(unsigned_report)
        assert report["reference_configuration"] != report["candidate_configuration"]
        assert report["reference_bootstrap_configuration"] is None
        assert report["candidate_bootstrap_configuration"] is not None
        assert report["provider_native_authenticity"] == {
            "verified": False,
            "nested_job_payload_custody_verified": False,
            "scope": "offline-payload-integrity-and-semantic-parity-only",
        }

        reference, candidate, reference_root, candidate_root = fixture()
        candidate = candidate_with_context_action(
            candidate, candidate_root, "ready_for_review"
        )
        action_report = run_compare(
            reference, candidate, reference_root, candidate_root
        )
        assert action_report["status"] == "fail"
        assert any(
            difference["field"] == "trigger_action"
            for difference in action_report["differences"]
        )

        reference, candidate, reference_root, candidate_root = fixture()
        same_provider = copy.deepcopy(candidate)
        same_provider["ci"]["provider"] = contract["authoritative_provider"]
        expect_error(
            lambda: run_compare(
                reference, reseal(same_provider), reference_root, candidate_root
            ),
            "same-provider comparison",
        )

        for description, mutation in (
            (
                "candidate configuration",
                lambda value: value["digests"].__setitem__(
                    "configuration",
                    provider_configuration(contract, contract["authoritative_provider"]),
                ),
            ),
            (
                "candidate bootstrap configuration",
                lambda value: value["digests"].__setitem__(
                    "bootstrap_configuration", None
                ),
            ),
            (
                "omitted required job",
                lambda value: value["jobs"].pop(contract["required_jobs"][0]),
            ),
            (
                "stale policy binding",
                lambda value: value["digests"]["policy"].__setitem__(
                    "sha256", "sha256:" + "9" * 64
                ),
            ),
            (
                "stale toolchain binding",
                lambda value: value["digests"]["toolchain"].__setitem__(
                    "sha256", "sha256:" + "8" * 64
                ),
            ),
        ):
            reference, candidate, reference_root, candidate_root = fixture()
            mutation(candidate)
            expect_error(
                lambda candidate=candidate: run_compare(
                    reference, reseal(candidate), reference_root, candidate_root
                ),
                description,
            )

        reference, candidate, reference_root, candidate_root = fixture()
        omitted_name = f"{contract['required_jobs'][0]}-manifest.json"
        candidate["artifacts"]["entries"] = [
            entry
            for entry in candidate["artifacts"]["entries"]
            if PurePosixPath(entry["path"]).name != omitted_name
        ]
        candidate["artifacts"]["manifest_sha256"] = canonical_digest(
            candidate["artifacts"]["entries"]
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "omitted Buildkite job artifact",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        reference["artifacts"]["entries"] = [
            entry
            for entry in reference["artifacts"]["entries"]
            if PurePosixPath(entry["path"]).name != CONTEXT_ARTIFACT
        ]
        reference["artifacts"]["manifest_sha256"] = canonical_digest(
            reference["artifacts"]["entries"]
        )
        expect_error(
            lambda: run_compare(reseal(reference), candidate, reference_root, candidate_root),
            "omitted provider-context artifact",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        candidate["artifacts"]["entries"] = [
            entry
            for entry in candidate["artifacts"]["entries"]
            if PurePosixPath(entry["path"]).name != IOS_ARTIFACT
        ]
        candidate["artifacts"]["manifest_sha256"] = canonical_digest(
            candidate["artifacts"]["entries"]
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "omitted iOS metrics artifact",
        )

        expect_error(
            lambda: parse_json('{"schema":"one","schema":"two"}', "duplicate fixture"),
            "duplicate JSON key",
        )
        expect_error(
            lambda: parse_json('{"seconds":NaN}', "nonfinite fixture"),
            "non-finite JSON",
        )
        reference, candidate, reference_root, candidate_root = fixture()
        expect_error(
            lambda: run_compare(
                {"schema": "tron.validation.v1"},
                candidate,
                reference_root,
                candidate_root,
            ),
            "v1 parity evidence",
        )

        for field, value in (("parallel_workers", 2), ("enumerated_tests", True)):
            reference, candidate, reference_root, candidate_root = fixture()
            metrics = copy.deepcopy(candidate["ios"])
            metrics[field] = value
            if field == "enumerated_tests":
                metrics["test_enumeration_sha256"] = "2" * 64
            changed = candidate_with_metrics(candidate, candidate_root, metrics)
            drift_report = run_compare(reference, changed, reference_root, candidate_root)
            assert drift_report["status"] == "fail"
            assert any(
                item["field"] == f"ios.{field}"
                for item in drift_report["differences"]
            )

        reference, candidate, reference_root, candidate_root = fixture()
        metrics = copy.deepcopy(candidate["ios"])
        metrics["test_exit_code"] = False
        boolean_exit = candidate_with_metrics(candidate, candidate_root, metrics)
        expect_error(
            lambda: run_compare(reference, boolean_exit, reference_root, candidate_root),
            "boolean iOS exit code",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        manifested_entry(candidate, CONTEXT_ARTIFACT)["size"] += 1
        candidate["artifacts"]["manifest_sha256"] = canonical_digest(
            candidate["artifacts"]["entries"]
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "artifact payload size",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        context_entry = manifested_entry(candidate, CONTEXT_ARTIFACT)
        context_entry["sha256"] = "sha256:" + "9" * 64
        candidate["artifacts"]["manifest_sha256"] = canonical_digest(
            candidate["artifacts"]["entries"]
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "artifact payload digest",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        context_entry = manifested_entry(candidate, CONTEXT_ARTIFACT)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        resolve_manifest_payload(
            context_entry["path"], candidate_files, field="fixture artifacts"
        ).unlink()
        expect_error(
            lambda: run_compare(reference, candidate, reference_root, candidate_root),
            "missing artifact payload",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        context_entry = manifested_entry(candidate, CONTEXT_ARTIFACT)
        context_entry["path"] = "../provider-context.json"
        candidate["artifacts"]["entries"] = sorted(
            candidate["artifacts"]["entries"], key=lambda entry: entry["path"]
        )
        candidate["artifacts"]["manifest_sha256"] = canonical_digest(
            candidate["artifacts"]["entries"]
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "artifact path traversal",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        flattened_context = reference_root / CONTEXT_ARTIFACT
        payload = flattened_context.read_bytes()
        flattened_context.unlink()
        for prefix in ("one/build", "two/build"):
            duplicate = reference_root / prefix / CONTEXT_ARTIFACT
            duplicate.parent.mkdir(parents=True)
            duplicate.write_bytes(payload)
        expect_error(
            lambda: run_compare(reference, candidate, reference_root, candidate_root),
            "ambiguous artifact payload",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        (reference_root / "unsafe-link").symlink_to(temporary_root / "outside")
        expect_error(
            lambda: run_compare(reference, candidate, reference_root, candidate_root),
            "artifact symlink",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        changed_metrics = copy.deepcopy(candidate["ios"])
        changed_metrics["parallel_workers"] = 2
        replace_payload(
            candidate,
            candidate_root,
            IOS_ARTIFACT,
            encoded_json(changed_metrics),
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "iOS payload/evidence mismatch",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        context_entry = manifested_entry(candidate, CONTEXT_ARTIFACT)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        context_path = resolve_manifest_payload(
            context_entry["path"], candidate_files, field="fixture artifacts"
        )
        changed_context = require_object(
            parse_json(context_path.read_bytes(), "fixture context"), "fixture context"
        )
        changed_context["source"]["tree"] = "9" * 40
        replace_payload(
            candidate,
            candidate_root,
            CONTEXT_ARTIFACT,
            encoded_json(changed_context),
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "provider context/evidence mismatch",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        job_name = f"{contract['required_jobs'][0]}-manifest.json"
        job_entry = manifested_entry(candidate, job_name)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        job_path = resolve_manifest_payload(
            job_entry["path"], candidate_files, field="fixture artifacts"
        )
        job_manifest = require_object(
            parse_json(job_path.read_bytes(), "fixture job manifest"),
            "fixture job manifest",
        )
        job_manifest["build_id"] = "87654321-4321-4321-8321-cba987654321"
        replace_payload(
            candidate, candidate_root, job_name, encoded_json(job_manifest)
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "job manifest build identity",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        job_name = f"{contract['required_jobs'][0]}-manifest.json"
        job_entry = manifested_entry(candidate, job_name)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        job_path = resolve_manifest_payload(
            job_entry["path"], candidate_files, field="fixture artifacts"
        )
        job_manifest = require_object(
            parse_json(job_path.read_bytes(), "fixture job manifest"),
            "fixture job manifest",
        )
        job_manifest["exit_code"] = False
        replace_payload(
            candidate, candidate_root, job_name, encoded_json(job_manifest)
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "boolean job-manifest exit code",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        job_name = f"{contract['required_jobs'][0]}-manifest.json"
        job_entry = manifested_entry(candidate, job_name)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        job_path = resolve_manifest_payload(
            job_entry["path"], candidate_files, field="fixture artifacts"
        )
        job_manifest = require_object(
            parse_json(job_path.read_bytes(), "fixture job manifest"),
            "fixture job manifest",
        )
        context_record = next(
            entry
            for entry in job_manifest["files"]
            if PurePosixPath(entry["path"]).name == CONTEXT_ARTIFACT
        )
        context_record["sha256"] = "9" * 64
        replace_payload(
            candidate, candidate_root, job_name, encoded_json(job_manifest)
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "job manifest context binding",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        job = contract["required_jobs"][0]
        job_name = f"{job}-manifest.json"
        job_entry = manifested_entry(candidate, job_name)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        job_path = resolve_manifest_payload(
            job_entry["path"], candidate_files, field="fixture artifacts"
        )
        job_manifest = require_object(
            parse_json(job_path.read_bytes(), "fixture job manifest"),
            "fixture job manifest",
        )
        expected_command_path = f"build/ci-shadow/{job}/{COMMAND_ARTIFACT}"
        original_file_count = len(job_manifest["files"])
        job_manifest["files"] = [
            entry
            for entry in job_manifest["files"]
            if entry["path"] != expected_command_path
        ]
        assert len(job_manifest["files"]) == original_file_count - 1
        replace_payload(
            candidate, candidate_root, job_name, encoded_json(job_manifest)
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "omitted job command log",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        job_name = "mac-manifest.json"
        job_entry = manifested_entry(candidate, job_name)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        job_path = resolve_manifest_payload(
            job_entry["path"], candidate_files, field="fixture artifacts"
        )
        job_manifest = require_object(
            parse_json(job_path.read_bytes(), "fixture Mac manifest"),
            "fixture Mac manifest",
        )
        expected_dmg_path = f"packages/mac-app/dist/{MAC_DMG_ARTIFACT}"
        original_file_count = len(job_manifest["files"])
        job_manifest["files"] = [
            entry
            for entry in job_manifest["files"]
            if entry["path"] != expected_dmg_path
        ]
        assert len(job_manifest["files"]) == original_file_count - 1
        replace_payload(
            candidate, candidate_root, job_name, encoded_json(job_manifest)
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "omitted PR Mac dry-run DMG",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        bootstrap_entry = manifested_entry(candidate, BOOTSTRAP_ARTIFACT)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        bootstrap_path = resolve_manifest_payload(
            bootstrap_entry["path"], candidate_files, field="fixture artifacts"
        )
        replace_payload(
            candidate,
            candidate_root,
            BOOTSTRAP_ARTIFACT,
            bootstrap_path.read_bytes() + b"\n# tampered\n",
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "executed bootstrap configuration",
        )

        reference, candidate, reference_root, candidate_root = fixture()
        bootstrap_entry = manifested_entry(candidate, BOOTSTRAP_RECORD_ARTIFACT)
        _, candidate_files = artifact_file_index(candidate_root, "fixture artifacts")
        bootstrap_path = resolve_manifest_payload(
            bootstrap_entry["path"], candidate_files, field="fixture artifacts"
        )
        bootstrap_record = require_object(
            parse_json(bootstrap_path.read_bytes(), "fixture bootstrap record"),
            "fixture bootstrap record",
        )
        bootstrap_record["matches_checked_out_merge"] = False
        replace_payload(
            candidate,
            candidate_root,
            BOOTSTRAP_RECORD_ARTIFACT,
            encoded_json(bootstrap_record),
        )
        expect_error(
            lambda: run_compare(reference, reseal(candidate), reference_root, candidate_root),
            "bootstrap execution record",
        )
    print("CI parity report self-test passed")


def load_evidence(path: Path) -> dict[str, Any]:
    return require_object(parse_json(path.read_bytes(), str(path)), str(path))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--reference-artifacts", type=Path)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--candidate-artifacts", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.self_test:
            self_test()
            return 0
        if (
            not arguments.reference
            or not arguments.reference_artifacts
            or not arguments.candidate
            or not arguments.candidate_artifacts
            or not arguments.output
        ):
            parser.error(
                "--reference, --reference-artifacts, --candidate, "
                "--candidate-artifacts, and --output are required"
            )
        report = compare(
            load_evidence(arguments.reference),
            load_evidence(arguments.candidate),
            reference_artifacts=arguments.reference_artifacts,
            candidate_artifacts=arguments.candidate_artifacts,
        )
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        if report["status"] != "pass":
            print("CI parity check failed", file=sys.stderr)
            return 1
        print("CI parity check passed")
        return 0
    except (OSError, ValueError) as error:
        print(f"CI parity evidence unavailable: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
