#!/usr/bin/env python3
"""Evaluate repository-bound normalized CI evidence without changing authority.

The evaluator accepts only a complete canonical export set: trigger history,
both providers, independent product and parity evidence, TestFlight delivery,
continuous candidate-settings audit history, the active authority ruleset, and
separately controlled proofs.  Repository, provider scope, source revisions,
configuration/toolchain digests, artifacts, and release handoffs are checked
one-to-one. Provider attempts preserve raw run ID/attempt pairs (including
same-ID reruns), and a provider-derived release-attempt inventory requires the
complete eligibility history before selecting the final decision. TestFlight
delivery is counted from authenticated receipts,
with completed reruns and interrupted-upload reuse joined through their intent,
admission, and reuse-provenance digests. A successful evaluation remains
advisory and reports the policy-owned replacement blockers; it never authorizes
a provider cutover.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping


ROOT = Path(__file__).resolve().parent.parent
POLICY_PATH = ROOT / "config" / "ci-policy.json"
BOOTSTRAP_PATH = ROOT / ".buildkite" / "pipeline.yml"
SHADOW_STEPS_PATH = ROOT / ".buildkite" / "shadow-steps.yml"
TOOLCHAIN_PATH = ROOT / "config" / "ci-toolchain.env"
LEDGER_SCHEMA = "tron.ci-cutover-observations.v2"
REPORT_SCHEMA = "tron.ci-cutover-evaluation.v2"
OBSERVATION_DECISION = "observation-thresholds-satisfied-provenance-unverified"
AUTHORITY_POLICY = "prohibited-until-explicit-external-review"
COLLECTION_METHOD = "normalized-provider-api-export"
TRIGGER_COVERAGE = {"present", "missing"}
EXECUTION_HEALTH = {
    "healthy",
    "not_started",
    "provider_failed",
    "provider_outage",
    "timed_out",
    "canceled",
    "superseded",
    "source_bootstrap_failed",
}
PRODUCT_OUTCOMES = {"passed", "failed"}
EVENT_ACTIONS = {"opened", "synchronize", "reopened", "ready_for_review"}
ORDERED_EVENT_ACTIONS = ["opened", "synchronize", "reopened", "ready_for_review"]
PULL_REQUEST_ELIGIBILITY = (
    "all-non-draft-main-pull-request-source-events-including-ci-skip-titles-and-commit-messages"
)
MAIN_PUSH_ELIGIBILITY = "all-main-push-events-including-ci-skip-commit-messages"
SOURCE_UNAVAILABLE_POLICY = (
    "enumerate-and-exclude-source-unavailable-merge-conflict-events"
)
MERGE_CONFLICT_EXCLUSION = "source-unavailable-merge-conflict"
RELEASE_EVIDENCE_SCHEMA = {
    "intents": ("tron.ios-release-intent.v1", "ios-release-intent.json"),
    "head_checks": ("tron.ios-release-head-check.v1", "ios-release-head-check.json"),
    "release_provenance": (
        "tron.ios-release-provenance.v1",
        "ios-release-provenance.json",
    ),
    "admissions": ("tron.ios-release-admission.v1", "ios-release-admission.json"),
    "reuse_provenance": (
        "tron.ios-release-reuse-provenance.v1",
        "ios-release-reuse-provenance.json",
    ),
    "receipts": ("tron.ios-release-receipt.v1", "ios-release-receipt.json"),
}
FORBIDDEN_CI_SKIP_PATTERNS = [
    "[skip ci]",
    "[ci skip]",
    "[no ci]",
    "[skip actions]",
    "[actions skip]",
    "[ci-skip]",
    "[skip-ci]",
    "skip-checks:true",
    "skip-checks: true",
]
REQUIRED_WORKFLOW_INVENTORY = {
    "merge-validation": {
        "configuration_path": ".github/workflows/ci.yml",
        "role": "required-validation",
        "triggers": ["pull_request:main", "push:main", "workflow_dispatch"],
        "candidate_coverage": "secretless-shadow-observation",
    },
    "fast-feedback": {
        "configuration_path": ".github/workflows/fast-feedback.yml",
        "role": "advisory-validation",
        "triggers": ["pull_request:main"],
        "candidate_coverage": "unimplemented",
    },
    "ios-performance": {
        "configuration_path": ".github/workflows/ios-performance.yml",
        "role": "advisory-measurement",
        "triggers": ["schedule", "workflow_dispatch"],
        "candidate_coverage": "unimplemented",
    },
    "server-performance": {
        "configuration_path": ".github/workflows/performance.yml",
        "role": "advisory-measurement",
        "triggers": ["schedule", "workflow_dispatch"],
        "candidate_coverage": "unimplemented",
    },
    "ios-release": {
        "configuration_path": ".github/workflows/release-ios.yml",
        "role": "release",
        "triggers": ["workflow_run:CI:main:completed", "push:server-v*", "workflow_dispatch"],
        "candidate_coverage": "unimplemented",
    },
    "mac-release": {
        "configuration_path": ".github/workflows/release-mac.yml",
        "role": "release",
        "triggers": ["push:server-v*", "workflow_dispatch"],
        "candidate_coverage": "unimplemented",
    },
}
REQUIRED_REPLACEMENT_BLOCKERS = [
    "live-provider-api-reverification",
    "trusted-product-evidence-verification",
    "controlled-proof-authenticity-verification",
    "provider-settings-continuity-verification",
    "authoritative-ruleset-binding-verification",
    "artifact-custody-verification",
    "fork-pull-request-parity",
    "skip-token-trigger-continuity",
    "workflow-dispatch-parity",
    "fast-feedback-parity",
    "performance-workflow-parity",
    "ios-performance-workflow-parity",
    "candidate-main-release-handoff-parity",
    "ios-testflight-release-parity",
    "release-tag-parity",
    "mac-release-parity",
]
EXPORT_NAMES = {
    "event": "event_export_sha256",
    "authoritative": "authoritative_provider_export_sha256",
    "candidate": "candidate_provider_export_sha256",
    "testflight": "testflight_provider_export_sha256",
    "product_verdict": "product_verdict_export_sha256",
    "candidate_settings": "candidate_settings_export_sha256",
    "authority_ruleset": "authority_ruleset_export_sha256",
    "parity": "parity_export_sha256",
}
PROOF_NAMES = {"release_security", "atomic_rollback"}
EXPORT_SCHEMAS = {
    "event": "tron.ci-trigger-export.v1",
    "authoritative": "tron.ci-provider-run-export.v1",
    "candidate": "tron.ci-provider-run-export.v1",
    "testflight": "tron.ci-testflight-export.v2",
    "product_verdict": "tron.ci-product-verdict-export.v1",
    "candidate_settings": "tron.ci-candidate-settings-export.v1",
    "authority_ruleset": "tron.ci-authority-ruleset-export.v1",
    "parity": "tron.ci-parity-export.v1",
    "release_security": "tron.ci-controlled-proof.v1",
    "atomic_rollback": "tron.ci-controlled-proof.v1",
}
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
RAW_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
OID_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,255}$")
REPOSITORY_SLUG_RE = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})$"
)
BUNDLE_ID_RE = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})){1,9}$"
)
MARKETING_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$")
HOSTED_BUILD_VERSION_RE = re.compile(r"^[1-9][0-9]{0,3}\.[0-9]{1,2}\.[12]$")
POSITIVE_INTEGER_IDENTIFIER_RE = re.compile(r"^[1-9][0-9]*$")


class EvaluationError(ValueError):
    """The observations do not prove eligibility for external review."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvaluationError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def reject_constant(token: str) -> None:
    raise EvaluationError(f"JSON contains non-finite number {token}")


def read_json(path: Path, field: str) -> Any:
    try:
        return json.loads(
            path.read_text(),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvaluationError(f"cannot read {field}: {error}") from error


def exact_object(value: Any, keys: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvaluationError(f"{field} must be an object")
    actual = set(value)
    if actual != keys:
        raise EvaluationError(
            f"{field} keys are invalid (missing={sorted(keys - actual)}, "
            f"extra={sorted(actual - keys)})"
        )
    return value


def require_text(value: Any, field: str, *, identifier: bool = False) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise EvaluationError(f"{field} must be a non-empty, unpadded string")
    if identifier and not IDENTIFIER_RE.fullmatch(value):
        raise EvaluationError(f"{field} contains unsupported characters")
    return value


def require_optional_text(value: Any, field: str) -> str | None:
    return None if value is None else require_text(value, field, identifier=True)


def require_bool(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise EvaluationError(f"{field} must be a boolean")
    return value


def require_integer(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise EvaluationError(f"{field} must be an integer >= {minimum}")
    return value


def require_positive_identifier(value: Any, field: str) -> str:
    identifier = require_text(value, field)
    if not POSITIVE_INTEGER_IDENTIFIER_RE.fullmatch(identifier):
        raise EvaluationError(f"{field} must be a positive integer string identifier")
    return identifier


def require_number(value: Any, field: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value < 0
    ):
        raise EvaluationError(f"{field} must be a finite non-negative number")
    return float(value)


def require_rate(value: Any, field: str) -> float:
    rate = require_number(value, field)
    if rate > 1:
        raise EvaluationError(f"{field} must be between zero and one")
    return rate


def require_digest(value: Any, field: str) -> str:
    digest = require_text(value, field)
    if not SHA256_RE.fullmatch(digest):
        raise EvaluationError(f"{field} must be a sha256-prefixed lowercase digest")
    return digest


def require_raw_digest(value: Any, field: str) -> str:
    digest = require_text(value, field)
    if not RAW_SHA256_RE.fullmatch(digest):
        raise EvaluationError(f"{field} must be a lowercase raw SHA-256 digest")
    return digest


def require_optional_digest(value: Any, field: str) -> str | None:
    return None if value is None else require_digest(value, field)


def require_oid(value: Any, field: str) -> str:
    oid = require_text(value, field)
    if not OID_RE.fullmatch(oid):
        raise EvaluationError(f"{field} must be a lowercase 40- or 64-character object ID")
    return oid


def require_timestamp(value: Any, field: str) -> datetime:
    timestamp = require_text(value, field)
    try:
        return datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise EvaluationError(
            f"{field} must be an RFC3339 UTC timestamp in whole seconds"
        ) from error


def require_optional_timestamp(value: Any, field: str) -> datetime | None:
    return None if value is None else require_timestamp(value, field)


def repository_identity(value: Any, field: str) -> dict[str, Any]:
    repository = exact_object(value, {"slug", "id"}, field)
    slug = require_text(repository["slug"], f"{field}.slug")
    if not REPOSITORY_SLUG_RE.fullmatch(slug):
        raise EvaluationError(f"{field}.slug must be an exact owner/repository slug")
    return {
        "slug": slug,
        "id": require_integer(repository["id"], f"{field}.id", minimum=1),
    }


def provider_scope(value: Any, field: str) -> dict[str, Any]:
    scope = exact_object(
        value,
        {
            "provider",
            "organization_id",
            "pipeline_id",
            "cluster_id",
            "repository",
        },
        field,
    )
    return {
        "provider": require_text(scope["provider"], f"{field}.provider", identifier=True),
        "organization_id": require_text(
            scope["organization_id"], f"{field}.organization_id", identifier=True
        ),
        "pipeline_id": require_text(
            scope["pipeline_id"], f"{field}.pipeline_id", identifier=True
        ),
        "cluster_id": require_text(
            scope["cluster_id"], f"{field}.cluster_id", identifier=True
        ),
        "repository": repository_identity(scope["repository"], f"{field}.repository"),
    }


def canonical_digest(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=True,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def structured_json_file_digest(value: Any) -> str:
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def artifact_history(
    value: Any,
    field: str,
    *,
    schema: str,
    artifact_name: str,
    document_keys: set[str],
) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise EvaluationError(f"{field} must be an array")
    records: list[dict[str, Any]] = []
    digests: set[str] = set()
    for index, wrapper_value in enumerate(value):
        wrapper_field = f"{field}[{index}]"
        wrapper = exact_object(
            wrapper_value,
            {"evidence", "evidence_sha256", "artifact_path"},
            wrapper_field,
        )
        document = exact_object(
            wrapper["evidence"], document_keys, f"{wrapper_field}.evidence"
        )
        if document["schema"] != schema:
            raise EvaluationError(f"{wrapper_field} schema is unsupported")
        digest = require_digest(
            wrapper["evidence_sha256"], f"{wrapper_field}.evidence_sha256"
        )
        if digest != structured_json_file_digest(document):
            raise EvaluationError(f"{wrapper_field} digest is not content-bound")
        if digest in digests:
            raise EvaluationError(f"{field} contains duplicate evidence")
        digests.add(digest)
        artifact_path = require_text(
            wrapper["artifact_path"], f"{wrapper_field}.artifact_path"
        )
        if Path(artifact_path).name != artifact_name:
            raise EvaluationError(f"{wrapper_field} artifact path is not canonical")
        records.append(
            {
                "document": document,
                "digest": digest,
                "field": wrapper_field,
            }
        )
    return records


def workflow_identity(value: Any, field: str) -> dict[str, str]:
    identity = exact_object(
        value, {"workflow_run_id", "run_number", "run_attempt"}, field
    )
    return {
        key: require_positive_identifier(identity[key], f"{field}.{key}")
        for key in ("workflow_run_id", "run_number", "run_attempt")
    }


def workflow_attempt_identity(value: Any, field: str) -> tuple[str, str]:
    identity = exact_object(value, {"workflow_run_id", "run_attempt"}, field)
    return (
        require_positive_identifier(
            identity["workflow_run_id"], f"{field}.workflow_run_id"
        ),
        require_positive_identifier(identity["run_attempt"], f"{field}.run_attempt"),
    )


def validate_release_product(
    value: Any, field: str, policy: Mapping[str, Any]
) -> dict[str, str]:
    product = exact_object(
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
        field,
    )
    normalized = {
        key: require_text(product[key], f"{field}.{key}") for key in product
    }
    if (
        normalized["asc_app_id"] != policy["testflight_identity"]["app_id"]
        or normalized["scheme"] != policy["testflight_identity"]["scheme"]
        or normalized["configuration"]
        != policy["testflight_identity"]["configuration"]
        or [
            normalized["app_bundle_id"],
            normalized["extension_bundle_id"],
        ]
        != policy["testflight_identity"]["bundle_ids"]
    ):
        raise EvaluationError(f"{field} differs from the policy TestFlight identity")
    if not MARKETING_VERSION_RE.fullmatch(normalized["marketing_version"]):
        raise EvaluationError(f"{field}.marketing_version is not canonical")
    if not HOSTED_BUILD_VERSION_RE.fullmatch(normalized["build_number"]):
        raise EvaluationError(f"{field}.build_number is not a hosted build allocation")
    require_text(
        normalized["canonical_version"], f"{field}.canonical_version", identifier=True
    )
    return normalized


def automatic_build_number(run_number: str) -> str:
    value = int(require_positive_identifier(run_number, "release owner run number"))
    if value > 899999:
        raise EvaluationError("release owner run number exceeds the hosted build namespace")
    return f"{1000 + value // 100}.{value % 100}.1"


def file_digest(path: Path) -> str:
    try:
        return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise EvaluationError(f"cannot hash {path}: {error}") from error


def nearest_rank_p95(samples: list[float]) -> float:
    if not samples:
        raise EvaluationError("p95 requires at least one observation")
    ordered = sorted(samples)
    return ordered[math.ceil(0.95 * len(ordered)) - 1]


def one_sided_exact_mcnemar(candidate_wins: int, candidate_losses: int) -> float:
    discordant = candidate_wins + candidate_losses
    if discordant == 0:
        return 1.0
    return sum(
        math.comb(discordant, successes)
        for successes in range(candidate_wins, discordant + 1)
    ) / (2**discordant)


def load_policy() -> dict[str, Any]:
    policy = read_json(POLICY_PATH, "CI policy")
    if not isinstance(policy, dict) or policy.get("schema") != "tron.ci-policy.v1":
        raise EvaluationError("CI policy is missing or uses an unsupported schema")
    providers = policy.get("providers")
    if not isinstance(providers, dict) or not providers:
        raise EvaluationError("CI policy providers are missing")
    shadow = [
        name
        for name, settings in providers.items()
        if isinstance(settings, dict)
        and settings.get("role") == "shadow"
        and settings.get("shadow") is True
        and settings.get("required_check_authority") is False
        and settings.get("release_authority") is False
    ]
    authoritative = [
        name
        for name, settings in providers.items()
        if isinstance(settings, dict)
        and settings.get("role") == "authoritative"
        and settings.get("required_check_authority") is True
    ]
    if len(shadow) != 1 or len(authoritative) != 1:
        raise EvaluationError("CI policy must define one shadow and one authoritative provider")
    release = policy.get("release")
    if not isinstance(release, dict) or release.get("provider") not in providers:
        raise EvaluationError("CI policy release provider is invalid")
    main_branch = require_text(policy.get("main_branch"), "main_branch", identifier=True)
    ios_release = exact_object(
        release.get("ios"),
        {"configuration_path", "identity", "channels", "triggers", "runner"},
        "release.ios",
    )
    ios_triggers = exact_object(
        ios_release["triggers"], {"internal", "external"}, "release.ios.triggers"
    )
    ios_identity = exact_object(
        ios_release["identity"],
        {"app_id", "bundle_ids", "scheme", "configuration"},
        "release.ios.identity",
    )
    ios_channels = exact_object(
        ios_release["channels"], {"internal", "external"}, "release.ios.channels"
    )
    ios_runner = exact_object(
        ios_release["runner"], {"image", "environment"}, "release.ios.runner"
    )
    if ios_channels != {"internal": "internal", "external": "external"} or ios_triggers != {
        "internal": "latest-green-main",
        "external": "server-v*",
    }:
        raise EvaluationError("release.ios channel/trigger semantics are not canonical")
    require_text(ios_runner["image"], "release.ios.runner.image", identifier=True)
    gate = exact_object(
        policy.get("cutover_gate"),
        {
            "minimum_representative_runs",
            "minimum_observation_days",
            "maximum_full_pull_request_p95_seconds",
            "maximum_candidate_main_p95_seconds",
            "maximum_green_main_to_testflight_p95_seconds",
            "maximum_false_green_count",
            "maximum_source_mismatch_count",
            "maximum_candidate_provider_failure_rate",
            "minimum_provider_failure_rate_improvement",
            "maximum_paired_reliability_p_value",
            "authority_change_policy",
        },
        "cutover_gate",
    )
    values = {
        "digest": file_digest(POLICY_PATH),
        "candidate": shadow[0],
        "authoritative": authoritative[0],
        "release_provider": release["provider"],
        "main_branch": main_branch,
        "testflight_channel": require_text(
            ios_channels["internal"], "release.ios.channels.internal", identifier=True
        ),
        "testflight_environment": require_text(
            ios_runner["environment"], "release.ios.runner.environment", identifier=True
        ),
        "testflight_identity": {
            "app_id": require_text(
                ios_identity["app_id"], "release.ios.identity.app_id", identifier=True
            ),
            "bundle_ids": ios_identity["bundle_ids"],
            "scheme": require_text(
                ios_identity["scheme"], "release.ios.identity.scheme", identifier=True
            ),
            "configuration": require_text(
                ios_identity["configuration"],
                "release.ios.identity.configuration",
                identifier=True,
            ),
        },
        "minimum_runs": require_integer(
            gate["minimum_representative_runs"],
            "cutover_gate.minimum_representative_runs",
            minimum=30,
        ),
        "minimum_days": require_integer(
            gate["minimum_observation_days"],
            "cutover_gate.minimum_observation_days",
            minimum=30,
        ),
        "pr_p95": require_number(
            gate["maximum_full_pull_request_p95_seconds"],
            "cutover_gate.maximum_full_pull_request_p95_seconds",
        ),
        "main_p95": require_number(
            gate["maximum_candidate_main_p95_seconds"],
            "cutover_gate.maximum_candidate_main_p95_seconds",
        ),
        "testflight_p95": require_number(
            gate["maximum_green_main_to_testflight_p95_seconds"],
            "cutover_gate.maximum_green_main_to_testflight_p95_seconds",
        ),
        "false_green_max": require_integer(
            gate["maximum_false_green_count"],
            "cutover_gate.maximum_false_green_count",
        ),
        "source_mismatch_max": require_integer(
            gate["maximum_source_mismatch_count"],
            "cutover_gate.maximum_source_mismatch_count",
        ),
        "candidate_failure_rate_max": require_rate(
            gate["maximum_candidate_provider_failure_rate"],
            "cutover_gate.maximum_candidate_provider_failure_rate",
        ),
        "failure_rate_improvement_min": require_rate(
            gate["minimum_provider_failure_rate_improvement"],
            "cutover_gate.minimum_provider_failure_rate_improvement",
        ),
        "paired_p_value_max": require_rate(
            gate["maximum_paired_reliability_p_value"],
            "cutover_gate.maximum_paired_reliability_p_value",
        ),
    }
    if values["false_green_max"] != 0 or values["source_mismatch_max"] != 0:
        raise EvaluationError("cutover policy must retain zero-tolerance correctness gates")
    if gate["authority_change_policy"] != AUTHORITY_POLICY:
        raise EvaluationError("cutover policy may only permit separately reviewed authority changes")
    bundle_ids = values["testflight_identity"]["bundle_ids"]
    if (
        not isinstance(bundle_ids, list)
        or len(bundle_ids) != 2
        or bundle_ids != sorted(bundle_ids)
        or len(set(bundle_ids)) != len(bundle_ids)
        or any(
            not isinstance(bundle_id, str) or not BUNDLE_ID_RE.fullmatch(bundle_id)
            for bundle_id in bundle_ids
        )
    ):
        raise EvaluationError("release.ios.identity.bundle_ids are not canonical")
    configuration_digests: dict[str, str] = {}
    bootstrap_digests: dict[str, str] = {}
    for provider, settings in providers.items():
        if not isinstance(settings, dict):
            raise EvaluationError(f"provider {provider!r} settings are invalid")
        configuration_path = require_text(
            settings.get("configuration_path"),
            f"providers.{provider}.configuration_path",
        )
        configuration = (ROOT / configuration_path).resolve()
        if ROOT.resolve() not in configuration.parents:
            raise EvaluationError(f"provider {provider!r} configuration leaves the repository")
        configuration_digests[provider] = file_digest(configuration)
        bootstrap_path = settings.get("bootstrap_configuration_path", configuration_path)
        bootstrap_text = require_text(
            bootstrap_path, f"providers.{provider}.bootstrap_configuration_path"
        )
        bootstrap = (ROOT / bootstrap_text).resolve()
        if ROOT.resolve() not in bootstrap.parents:
            raise EvaluationError(f"provider {provider!r} bootstrap leaves the repository")
        bootstrap_digests[provider] = file_digest(bootstrap)
    values["configuration_digests"] = configuration_digests
    values["bootstrap_digests"] = bootstrap_digests
    values["toolchain_digest"] = file_digest(TOOLCHAIN_PATH)
    inventory = exact_object(
        policy.get("workflow_inventory"),
        set(REQUIRED_WORKFLOW_INVENTORY),
        "workflow_inventory",
    )
    for workflow_id, expected in REQUIRED_WORKFLOW_INVENTORY.items():
        entry = exact_object(
            inventory[workflow_id],
            {"configuration_path", "provider", "role", "triggers", "candidate_coverage"},
            f"workflow_inventory.{workflow_id}",
        )
        expected_entry = {**expected, "provider": values["authoritative"]}
        if entry != expected_entry:
            raise EvaluationError(f"workflow_inventory.{workflow_id} contract drifted")
        workflow_path = (ROOT / expected["configuration_path"]).resolve()
        if ROOT.resolve() not in workflow_path.parents:
            raise EvaluationError(f"workflow_inventory.{workflow_id} leaves the repository")
        file_digest(workflow_path)
    replacement_gate = exact_object(
        policy.get("replacement_gate"),
        {"scope", "required_blockers"},
        "replacement_gate",
    )
    if replacement_gate["scope"] != "all-workflow-inventory-entries":
        raise EvaluationError("replacement_gate does not cover the complete workflow inventory")
    blocker_values = replacement_gate["required_blockers"]
    if not isinstance(blocker_values, list):
        raise EvaluationError("replacement_gate.required_blockers must be an array")
    blockers = [
        require_text(item, f"replacement_gate.required_blockers[{index}]", identifier=True)
        for index, item in enumerate(blocker_values)
    ]
    if blockers != REQUIRED_REPLACEMENT_BLOCKERS:
        raise EvaluationError("replacement_gate.required_blockers is incomplete or reordered")
    values["required_blockers"] = blockers
    return values


def validate_candidate_attestation(
    value: Any, field: str, policy: Mapping[str, Any]
) -> dict[str, Any]:
    attestation = exact_object(
        value,
        {
            "repository_pipeline_sha256",
            "repository_shadow_steps_sha256",
            "toolchain_sha256",
            "provider_id",
            "provider_webhook_url_present",
            "trigger_mode",
            "filter_enabled",
            "publish_commit_status",
            "publish_commit_status_per_step",
            "publish_blocked_as_pending",
            "separate_pull_request_statuses",
            "build_pull_request_forks",
            "build_tags",
            "queue_secrets_attached",
            "pipeline_secrets_attached",
            "cluster_secrets_attached",
            "organization_secrets_attached",
            "release_runner_access",
            "allowed_queues",
            "build_pull_requests",
            "build_pull_request_merge_commits",
            "build_pull_request_ready_for_review",
            "build_pull_request_reopened",
            "build_pull_request_base_branch_changed",
            "build_pull_request_labels_changed",
            "build_pull_request_edited",
            "build_pull_request_converted_to_draft",
            "build_pull_request_review_requested",
            "build_check_run_completed",
            "build_pull_request_review_submitted",
            "build_pull_request_review_dismissed",
            "build_release_published",
            "build_release_created",
            "build_release_released",
            "build_issue_comment_created",
            "build_deployment_status_created",
            "build_pull_request_review_comment_created",
            "build_pull_request_dequeued",
            "build_create_event",
            "build_merge_group_checks_requested",
            "skip_builds_for_closed_pull_requests",
            "pull_request_branch_filter_enabled",
            "build_branches",
            "branch_configuration",
            "skip_builds_for_existing_commits",
            "skip_pull_request_builds_for_existing_commits",
            "workflow_dispatch_parity_implemented",
            "skip_queued_branch_builds",
            "skip_queued_branch_builds_filter",
            "cancel_running_branch_builds",
            "cancel_running_branch_builds_filter",
        },
        field,
    )
    if require_digest(
        attestation["repository_pipeline_sha256"],
        f"{field}.repository_pipeline_sha256",
    ) != policy["bootstrap_digests"][policy["candidate"]]:
        raise EvaluationError("candidate settings do not attest the current Buildkite bootstrap")
    if require_digest(
        attestation["repository_shadow_steps_sha256"],
        f"{field}.repository_shadow_steps_sha256",
    ) != policy["configuration_digests"][policy["candidate"]]:
        raise EvaluationError("candidate settings do not attest the current Buildkite job graph")
    if require_digest(attestation["toolchain_sha256"], f"{field}.toolchain_sha256") != policy[
        "toolchain_digest"
    ]:
        raise EvaluationError("candidate settings do not attest the current CI toolchain")
    required_bools = {
        "provider_webhook_url_present": True,
        "filter_enabled": False,
        "publish_commit_status": False,
        "publish_commit_status_per_step": False,
        "publish_blocked_as_pending": False,
        "separate_pull_request_statuses": False,
        "build_pull_request_forks": False,
        "build_tags": False,
        "queue_secrets_attached": False,
        "pipeline_secrets_attached": False,
        "cluster_secrets_attached": False,
        "organization_secrets_attached": False,
        "release_runner_access": False,
        "build_pull_requests": True,
        "build_pull_request_merge_commits": False,
        "build_pull_request_ready_for_review": True,
        "build_pull_request_reopened": True,
        "build_pull_request_base_branch_changed": False,
        "build_pull_request_labels_changed": False,
        "build_pull_request_edited": False,
        "build_pull_request_converted_to_draft": False,
        "build_pull_request_review_requested": False,
        "build_check_run_completed": False,
        "build_pull_request_review_submitted": False,
        "build_pull_request_review_dismissed": False,
        "build_release_published": False,
        "build_release_created": False,
        "build_release_released": False,
        "build_issue_comment_created": False,
        "build_deployment_status_created": False,
        "build_pull_request_review_comment_created": False,
        "build_pull_request_dequeued": False,
        "build_create_event": False,
        "build_merge_group_checks_requested": False,
        "skip_builds_for_closed_pull_requests": False,
        "pull_request_branch_filter_enabled": False,
        "build_branches": True,
        "skip_builds_for_existing_commits": False,
        "skip_pull_request_builds_for_existing_commits": False,
        "workflow_dispatch_parity_implemented": False,
        "skip_queued_branch_builds": True,
        "cancel_running_branch_builds": True,
    }
    for setting, expected in required_bools.items():
        if require_bool(attestation[setting], f"{field}.{setting}") is not expected:
            raise EvaluationError(
                f"candidate external setting {setting} violates the advisory boundary"
            )
    if attestation["provider_id"] != "github":
        raise EvaluationError("candidate source provider must be GitHub")
    if attestation["trigger_mode"] != "code":
        raise EvaluationError("candidate GitHub trigger_mode must be code")
    if attestation["skip_queued_branch_builds_filter"] != "!main":
        raise EvaluationError("intermediate-build cancellation must preserve complete main history")
    if attestation["cancel_running_branch_builds_filter"] != "!main":
        raise EvaluationError("running-build cancellation must preserve complete main history")
    if attestation["branch_configuration"] != "main":
        raise EvaluationError("candidate branch builds must be restricted to main")
    if attestation["allowed_queues"] != ["linux-medium", "macos-medium"]:
        raise EvaluationError("candidate may use only the documented secretless shadow queues")
    return attestation


def source_identity(value: Any, field: str) -> dict[str, str]:
    source = exact_object(value, {"sha", "tree"}, field)
    return {
        "sha": require_oid(source["sha"], f"{field}.sha"),
        "tree": require_oid(source["tree"], f"{field}.tree"),
    }


def run_observation(value: Any, field: str) -> dict[str, Any]:
    run = exact_object(
        value,
        {
            "run_id",
            "provider_run_id",
            "provider_run_attempt",
            "trigger_id",
            "attempts",
            "rebuilt_from_run_ids",
            "provider_failure_attempt_count",
            "trigger_coverage",
            "execution_health",
            "product_outcome",
            "source",
            "provider_started_at",
            "provider_finished_at",
            "operational_observation_sha256",
            "validation_artifact_sha256",
            "provider_scope",
            "policy_sha256",
            "configuration_sha256",
            "bootstrap_sha256",
            "toolchain_sha256",
            "settings_revision",
        },
        field,
    )
    coverage = run["trigger_coverage"]
    health = run["execution_health"]
    product = run["product_outcome"]
    if coverage not in TRIGGER_COVERAGE or health not in EXECUTION_HEALTH:
        raise EvaluationError(f"{field} has unsupported provider state")
    run_id = require_optional_text(run["run_id"], f"{field}.run_id")
    provider_run_id = require_optional_text(
        run["provider_run_id"], f"{field}.provider_run_id"
    )
    provider_run_attempt = (
        None
        if run["provider_run_attempt"] is None
        else require_positive_identifier(
            run["provider_run_attempt"], f"{field}.provider_run_attempt"
        )
    )
    trigger_id = require_optional_text(run["trigger_id"], f"{field}.trigger_id")
    attempts_value = run["attempts"]
    rebuilt_ids_value = run["rebuilt_from_run_ids"]
    if not isinstance(attempts_value, list) or not isinstance(rebuilt_ids_value, list):
        raise EvaluationError(f"{field} attempt identities must be arrays")
    attempts: list[dict[str, str]] = []
    for index, value in enumerate(attempts_value):
        attempt_field = f"{field}.attempts[{index}]"
        attempt = exact_object(
            value,
            {"canonical_attempt_id", "run_id", "run_attempt"},
            attempt_field,
        )
        attempts.append(
            {
                "canonical_attempt_id": require_text(
                    attempt["canonical_attempt_id"],
                    f"{attempt_field}.canonical_attempt_id",
                    identifier=True,
                ),
                "provider_run_id": require_text(
                    attempt["run_id"], f"{attempt_field}.run_id"
                ),
                "provider_run_attempt": require_positive_identifier(
                    attempt["run_attempt"],
                    f"{attempt_field}.run_attempt",
                ),
            }
        )
    attempt_ids = [attempt["canonical_attempt_id"] for attempt in attempts]
    provider_attempts = [
        (attempt["provider_run_id"], attempt["provider_run_attempt"])
        for attempt in attempts
    ]
    rebuilt_ids = [
        require_text(item, f"{field}.rebuilt_from_run_ids[{index}]", identifier=True)
        for index, item in enumerate(rebuilt_ids_value)
    ]
    if (
        len(set(attempt_ids)) != len(attempt_ids)
        or len(set(provider_attempts)) != len(provider_attempts)
        or len(set(rebuilt_ids)) != len(rebuilt_ids)
    ):
        raise EvaluationError(f"{field} attempt identities must be unique")
    if not set(rebuilt_ids).issubset(set(attempt_ids[:-1])):
        raise EvaluationError(f"{field} rebuild ancestry must refer to earlier attempts")
    failure_attempts = require_integer(
        run["provider_failure_attempt_count"],
        f"{field}.provider_failure_attempt_count",
    )
    if failure_attempts > len(attempt_ids):
        raise EvaluationError(f"{field} provider failure attempts exceed total attempts")
    source = None if run["source"] is None else source_identity(run["source"], f"{field}.source")
    started = require_optional_timestamp(run["provider_started_at"], f"{field}.provider_started_at")
    finished = require_optional_timestamp(run["provider_finished_at"], f"{field}.provider_finished_at")
    operational = require_optional_digest(
        run["operational_observation_sha256"],
        f"{field}.operational_observation_sha256",
    )
    validation_artifact = require_optional_digest(
        run["validation_artifact_sha256"], f"{field}.validation_artifact_sha256"
    )
    scope = provider_scope(run["provider_scope"], f"{field}.provider_scope")
    policy_digest = require_digest(run["policy_sha256"], f"{field}.policy_sha256")
    configuration_digest = require_digest(
        run["configuration_sha256"], f"{field}.configuration_sha256"
    )
    bootstrap_digest = require_digest(
        run["bootstrap_sha256"], f"{field}.bootstrap_sha256"
    )
    toolchain_digest = require_digest(run["toolchain_sha256"], f"{field}.toolchain_sha256")
    settings_revision = require_text(
        run["settings_revision"], f"{field}.settings_revision", identifier=True
    )
    if coverage == "missing":
        if health != "not_started" or any(
            item is not None
            for item in (
                run_id,
                provider_run_id,
                provider_run_attempt,
                trigger_id,
                product,
                source,
                started,
                finished,
                operational,
                validation_artifact,
            )
        ) or attempt_ids or rebuilt_ids or failure_attempts != 0:
            raise EvaluationError(f"{field} missing trigger must have no invented run data")
    else:
        if (
            health == "not_started"
            or run_id is None
            or provider_run_id is None
            or provider_run_attempt is None
            or trigger_id is None
            or started is None
            or finished is None
            or not attempt_ids
            or run_id != attempt_ids[-1]
            or (provider_run_id, provider_run_attempt) != provider_attempts[-1]
        ):
            raise EvaluationError(f"{field} present trigger requires a terminal provider run")
        if finished < started:
            raise EvaluationError(f"{field} provider timestamps are reversed")
        if health == "healthy":
            if product not in PRODUCT_OUTCOMES or source is None or validation_artifact is None:
                raise EvaluationError(
                    f"{field} healthy run requires source, product outcome, and validation artifact"
                )
            if failure_attempts >= len(attempt_ids):
                raise EvaluationError(f"{field} healthy final attempt cannot be counted as failed")
        elif product is not None or validation_artifact is not None:
            raise EvaluationError(f"{field} unhealthy run cannot claim product/artifact success")
        if health not in {"healthy", "superseded"} and failure_attempts == 0:
            raise EvaluationError(f"{field} unhealthy execution must record a failed provider attempt")
    return {
        "run_id": run_id,
        "provider_run_id": provider_run_id,
        "provider_run_attempt": provider_run_attempt,
        "trigger_id": trigger_id,
        "attempt_ids": attempt_ids,
        "provider_attempts": provider_attempts,
        "rebuilt_ids": rebuilt_ids,
        "failure_attempts": failure_attempts,
        "coverage": coverage,
        "health": health,
        "product": product,
        "source": source,
        "started": started,
        "finished": finished,
        "operational": operational,
        "validation_artifact": validation_artifact,
        "scope": scope,
        "policy_digest": policy_digest,
        "configuration_digest": configuration_digest,
        "bootstrap_digest": bootstrap_digest,
        "toolchain_digest": toolchain_digest,
        "settings_revision": settings_revision,
    }


def validate_run_provenance(
    run: Mapping[str, Any],
    field: str,
    owner_provider: str,
    policy: Mapping[str, Any],
    repository: Mapping[str, Any],
    settings_history: list[dict[str, Any]],
    event_time: datetime,
    export_binding: Mapping[str, Any],
) -> None:
    if run["scope"]["provider"] != owner_provider or run["scope"]["repository"] != repository:
        raise EvaluationError(f"{field} is bound to the wrong provider/repository scope")
    expected_digests = {
        "policy_digest": policy["digest"],
        "configuration_digest": policy["configuration_digests"][owner_provider],
        "bootstrap_digest": policy["bootstrap_digests"][owner_provider],
        "toolchain_digest": policy["toolchain_digest"],
    }
    for name, expected in expected_digests.items():
        if run[name] != expected:
            raise EvaluationError(f"{field}.{name} is stale or bound to different source")
    if run["scope"] != export_binding["scope"]:
        raise EvaluationError(f"{field} scope differs from its canonical provider export")
    if owner_provider != policy["candidate"]:
        if run["settings_revision"] != export_binding["settings_revision"]:
            raise EvaluationError(f"{field} settings revision differs from its provider export")
        return
    interval_start = run["started"] if run["started"] is not None else event_time
    interval_end = run["finished"] if run["finished"] is not None else event_time
    matching = [
        record
        for record in settings_history
        if record["effective_from"] <= interval_start
        and interval_end <= record["effective_until"]
    ]
    if len(matching) != 1:
        raise EvaluationError(f"{field} is not wholly covered by one audited settings interval")
    audited = matching[0]
    if run["settings_revision"] != audited["revision"] or run["scope"] != audited["scope"]:
        raise EvaluationError(f"{field} does not match its safe audited settings revision/scope")


def validate_proof(
    value: Any,
    field: str,
    keys: set[str],
    observed_sources: set[str],
    observed_candidate_runs: Mapping[tuple[str, str], dict[str, Any]],
    window_started_at: datetime,
    exported_at: datetime,
    settings_revision: str,
    repository: Mapping[str, Any],
) -> dict[str, Any]:
    proof = exact_object(value, keys, field)
    if proof["status"] != "passed":
        raise EvaluationError(f"{field}.status must be passed")
    authorized_by = require_text(proof["authorized_by"], f"{field}.authorized_by", identifier=True)
    executed_by = require_text(proof["executed_by"], f"{field}.executed_by", identifier=True)
    if authorized_by == executed_by:
        raise EvaluationError(f"{field} must be separately authorized and executed")
    require_text(proof["authorization_reference"], f"{field}.authorization_reference", identifier=True)
    observed_at = require_timestamp(proof["observed_at"], f"{field}.observed_at")
    if not window_started_at <= observed_at <= exported_at:
        raise EvaluationError(f"{field} is stale or occurs after the normalized export snapshot")
    source_sha = require_oid(proof["source_sha"], f"{field}.source_sha")
    if source_sha not in observed_sources:
        raise EvaluationError(f"{field}.source_sha is not represented by a candidate observation")
    candidate_run_id = require_text(
        proof["candidate_run_id"], f"{field}.candidate_run_id", identifier=True
    )
    candidate_binding = observed_candidate_runs.get((source_sha, candidate_run_id))
    if candidate_binding is None:
        raise EvaluationError(f"{field} is not bound to an observed healthy candidate run")
    candidate_finished_at = candidate_binding["finished"]
    if observed_at < candidate_finished_at:
        raise EvaluationError(f"{field} predates its bound candidate run completion")
    if proof["candidate_settings_revision"] != candidate_binding["settings_revision"]:
        raise EvaluationError(f"{field} is not bound to the attested candidate settings")
    if proof["candidate_settings_revision"] != settings_revision:
        raise EvaluationError(f"{field} is not bound to the ledger candidate settings revision")
    if repository_identity(proof["repository"], f"{field}.repository") != repository:
        raise EvaluationError(f"{field} is bound to a different repository")
    if provider_scope(
        proof["candidate_provider_scope"], f"{field}.candidate_provider_scope"
    ) != candidate_binding["scope"]:
        raise EvaluationError(f"{field} is not bound to its candidate provider scope")
    require_digest(proof["evidence_sha256"], f"{field}.evidence_sha256")
    return proof


def validate_collection(
    value: Any,
    policy: Mapping[str, Any],
    export_digests: Mapping[str, str],
) -> dict[str, Any]:
    collection = exact_object(
        value,
        {
            "method",
            "exported_at",
            "window_started_at",
            "window_ended_at",
            "eligible_ready_pull_request_event_count",
            "representative_source_cohort_count",
            "eligible_main_push_event_count",
            "eligible_testflight_delivery_count",
            "excluded_source_unavailable_merge_conflict_count",
            "successful_parity_sample_count",
            "event_export_sha256",
            "authoritative_provider_export_sha256",
            "candidate_provider_export_sha256",
            "testflight_provider_export_sha256",
            "product_verdict_export_sha256",
            "candidate_settings_export_sha256",
            "authority_ruleset_export_sha256",
            "parity_export_sha256",
            "candidate_settings_revision",
            "candidate_settings_attestation",
            "candidate_provider_scope",
            "authority_ruleset_id",
        },
        "collection",
    )
    if collection["method"] != COLLECTION_METHOD:
        raise EvaluationError("collection must use the normalized provider/API export contract")
    exported = require_timestamp(collection["exported_at"], "collection.exported_at")
    window_start = require_timestamp(collection["window_started_at"], "collection.window_started_at")
    window_end = require_timestamp(collection["window_ended_at"], "collection.window_ended_at")
    if window_end < window_start or exported < window_end:
        raise EvaluationError("collection window or export timestamp is invalid")
    for export_name, field in EXPORT_NAMES.items():
        digest = require_digest(collection[field], f"collection.{field}")
        if export_digests.get(export_name) != digest:
            raise EvaluationError(
                f"collection {export_name} digest does not match the supplied normalized export"
            )
    require_text(
        collection["candidate_settings_revision"],
        "collection.candidate_settings_revision",
        identifier=True,
    )
    validate_candidate_attestation(
        collection["candidate_settings_attestation"],
        "collection.candidate_settings_attestation",
        policy,
    )
    scope = provider_scope(
        collection["candidate_provider_scope"], "collection.candidate_provider_scope"
    )
    if scope["provider"] != policy["candidate"]:
        raise EvaluationError("candidate provider scope names the wrong provider")
    return {
        "exported": exported,
        "window_start": window_start,
        "window_end": window_end,
        "pull_count": require_integer(
            collection["eligible_ready_pull_request_event_count"],
            "collection.eligible_ready_pull_request_event_count",
        ),
        "representative_pull_count": require_integer(
            collection["representative_source_cohort_count"],
            "collection.representative_source_cohort_count",
            minimum=policy["minimum_runs"],
        ),
        "main_count": require_integer(
            collection["eligible_main_push_event_count"],
            "collection.eligible_main_push_event_count",
            minimum=policy["minimum_runs"],
        ),
        "delivery_count": require_integer(
            collection["eligible_testflight_delivery_count"],
            "collection.eligible_testflight_delivery_count",
            minimum=policy["minimum_runs"],
        ),
        "conflict_count": require_integer(
            collection["excluded_source_unavailable_merge_conflict_count"],
            "collection.excluded_source_unavailable_merge_conflict_count",
        ),
        "parity_count": require_integer(
            collection["successful_parity_sample_count"],
            "collection.successful_parity_sample_count",
            minimum=policy["minimum_runs"],
        ),
        "settings_revision": collection["candidate_settings_revision"],
        "candidate_scope": scope,
        "authority_ruleset_id": require_integer(
            collection["authority_ruleset_id"],
            "collection.authority_ruleset_id",
            minimum=1,
        ),
    }


def indexed_records(value: Any, field: str) -> dict[str, dict[str, Any]]:
    if not isinstance(value, list):
        raise EvaluationError(f"{field} must be an array")
    indexed: dict[str, dict[str, Any]] = {}
    for index, record in enumerate(value):
        if not isinstance(record, dict):
            raise EvaluationError(f"{field}[{index}] must be an object")
        event_id = require_text(record.get("event_id"), f"{field}[{index}].event_id", identifier=True)
        if event_id in indexed:
            raise EvaluationError(f"{field} contains duplicate event ID {event_id}")
        indexed[event_id] = record
    return indexed


def validate_parity_export(
    parity_export: Mapping[str, Any],
    cohort_records: Mapping[str, list[dict[str, Any]]],
    source_key_by_cohort: Mapping[str, tuple[str, str, str]],
    collection: Mapping[str, Any],
    policy: Mapping[str, Any],
) -> int:
    value = parity_export["records"]
    if not isinstance(value, list):
        raise EvaluationError("parity export.records must be an array")
    records: dict[str, dict[str, Any]] = {}
    parity_keys = {
        "source_cohort_id",
        "event_ids",
        "source",
        "authoritative_run_ids",
        "candidate_run_ids",
        "status",
        "evidence_sha256",
        "authoritative_artifacts",
        "candidate_artifacts",
    }
    for index, item in enumerate(value):
        field = f"parity export.records[{index}]"
        record = exact_object(item, parity_keys, field)
        cohort_id = require_text(
            record["source_cohort_id"], f"{field}.source_cohort_id", identifier=True
        )
        if cohort_id in records:
            raise EvaluationError("parity export contains duplicate source cohorts")
        if record["status"] != "passed":
            raise EvaluationError("parity export may contain only passed records")
        evidence_digest = require_digest(record["evidence_sha256"], f"{field}.evidence_sha256")
        source_identity(record["source"], f"{field}.source")
        for array_field in ("event_ids", "authoritative_run_ids", "candidate_run_ids"):
            array = record[array_field]
            if not isinstance(array, list) or not array:
                raise EvaluationError(f"{field}.{array_field} must be a non-empty array")
            identities = [
                require_text(entry, f"{field}.{array_field}[{i}]", identifier=True)
                for i, entry in enumerate(array)
            ]
            if len(set(identities)) != len(identities):
                raise EvaluationError(f"{field}.{array_field} contains duplicate identities")
        for artifact_field in ("authoritative_artifacts", "candidate_artifacts"):
            artifacts = record[artifact_field]
            if not isinstance(artifacts, list) or not artifacts:
                raise EvaluationError(f"{field}.{artifact_field} must be a non-empty array")
            artifact_run_ids: set[str] = set()
            for artifact_index, artifact_value in enumerate(artifacts):
                artifact_field_name = f"{field}.{artifact_field}[{artifact_index}]"
                artifact = exact_object(
                    artifact_value,
                    {"run_id", "artifact_sha256"},
                    artifact_field_name,
                )
                run_id = require_text(
                    artifact["run_id"], f"{artifact_field_name}.run_id", identifier=True
                )
                digest = require_digest(
                    artifact["artifact_sha256"],
                    f"{artifact_field_name}.artifact_sha256",
                )
                if run_id in artifact_run_ids or digest == evidence_digest:
                    raise EvaluationError("parity artifacts must be unique and distinct from evidence")
                artifact_run_ids.add(run_id)
        records[cohort_id] = record

    expected: dict[str, dict[str, Any]] = {}
    for cohort_id, cohort in cohort_records.items():
        representatives = [item for item in cohort if item["superseded_by"] is None]
        if not representatives:
            continue
        successful = all(
            item["verdict"] == "passed"
            and item["authoritative"]["health"] == "healthy"
            and item["authoritative"]["product"] == "passed"
            and item["authoritative"]["source"] == item["expected_source"]
            and item["candidate"]["health"] == "healthy"
            and item["candidate"]["product"] == "passed"
            and item["candidate"]["source"] == item["expected_source"]
            for item in representatives
        )
        if not successful:
            continue
        source_key = source_key_by_cohort[cohort_id]
        expected[cohort_id] = {
            "event_ids": [item["event_id"] for item in representatives],
            "source": {"sha": source_key[1], "tree": source_key[2]},
            "authoritative_run_ids": [
                item["authoritative"]["run_id"] for item in representatives
            ],
            "candidate_run_ids": [item["candidate"]["run_id"] for item in representatives],
            "authoritative_artifacts": [
                {
                    "run_id": item["authoritative"]["run_id"],
                    "artifact_sha256": item["authoritative"]["validation_artifact"],
                }
                for item in representatives
            ],
            "candidate_artifacts": [
                {
                    "run_id": item["candidate"]["run_id"],
                    "artifact_sha256": item["candidate"]["validation_artifact"],
                }
                for item in representatives
            ],
        }
    if set(records) != set(expected):
        raise EvaluationError(
            "parity records must cover every and only successful representative PR cohort"
        )
    for cohort_id, expected_binding in expected.items():
        record = records[cohort_id]
        for key, expected_value in expected_binding.items():
            if record[key] != expected_value:
                raise EvaluationError(f"parity record {cohort_id} has a stale {key} binding")
        if record["evidence_sha256"] != parity_evidence_digest(record):
            raise EvaluationError(f"parity record {cohort_id} evidence digest is not content-bound")
    if len(records) < policy["minimum_runs"] or len(records) != collection["parity_count"]:
        raise EvaluationError("successful parity samples do not satisfy the policy minimum")
    return len(records)


def validate_export_header(
    document: Any,
    name: str,
    keys: set[str],
    exported_at: str,
    repository: Mapping[str, Any],
) -> dict[str, Any]:
    export = exact_object(document, keys | {"repository"}, f"{name} export")
    if export["schema"] != EXPORT_SCHEMAS[name]:
        raise EvaluationError(f"{name} export uses an unsupported schema")
    if export["exported_at"] != exported_at:
        raise EvaluationError(f"{name} export is not from the ledger snapshot")
    require_timestamp(export["exported_at"], f"{name} export.exported_at")
    require_digest(export["source_response_sha256"], f"{name} export.source_response_sha256")
    if repository_identity(export["repository"], f"{name} export.repository") != repository:
        raise EvaluationError(f"{name} export is bound to a different repository")
    return export


def parity_evidence_digest(record: Mapping[str, Any]) -> str:
    return canonical_digest(
        {
            "schema": "tron.ci-parity-record.v1",
            "source_cohort_id": record["source_cohort_id"],
            "event_ids": record["event_ids"],
            "source": record["source"],
            "authoritative_run_ids": record["authoritative_run_ids"],
            "candidate_run_ids": record["candidate_run_ids"],
            "status": record["status"],
            "authoritative_artifacts": record["authoritative_artifacts"],
            "candidate_artifacts": record["candidate_artifacts"],
        }
    )


def validate_candidate_settings_history(
    settings_export: Mapping[str, Any],
    collection: Mapping[str, Any],
    policy: Mapping[str, Any],
    repository: Mapping[str, Any],
) -> list[dict[str, Any]]:
    history_value = settings_export["audit_history"]
    if not isinstance(history_value, list) or not history_value:
        raise EvaluationError("candidate settings audit history must be non-empty")
    window_start = require_timestamp(
        collection["window_started_at"], "collection.window_started_at"
    )
    window_end = require_timestamp(collection["window_ended_at"], "collection.window_ended_at")
    exported_at = require_timestamp(collection["exported_at"], "collection.exported_at")
    expected_scope = provider_scope(
        collection["candidate_provider_scope"], "collection.candidate_provider_scope"
    )
    records: list[dict[str, Any]] = []
    revisions: set[str] = set()
    audit_event_ids: set[str] = set()
    audit_event_digests: set[str] = set()
    for index, value in enumerate(history_value):
        field = f"candidate settings export.audit_history[{index}]"
        record = exact_object(
            value,
            {
                "audit_event_id",
                "audit_event_sha256",
                "revision",
                "effective_from",
                "effective_until",
                "provider_scope",
                "attestation",
            },
            field,
        )
        audit_event_id = require_text(
            record["audit_event_id"], f"{field}.audit_event_id", identifier=True
        )
        audit_event_digest = require_digest(
            record["audit_event_sha256"], f"{field}.audit_event_sha256"
        )
        if audit_event_id in audit_event_ids or audit_event_digest in audit_event_digests:
            raise EvaluationError("candidate settings audit event identities must be unique")
        audit_event_ids.add(audit_event_id)
        audit_event_digests.add(audit_event_digest)
        revision = require_text(record["revision"], f"{field}.revision", identifier=True)
        if revision in revisions:
            raise EvaluationError("candidate settings audit revisions must be unique")
        revisions.add(revision)
        effective_from = require_timestamp(record["effective_from"], f"{field}.effective_from")
        effective_until = require_timestamp(record["effective_until"], f"{field}.effective_until")
        if effective_until <= effective_from or effective_until > exported_at:
            raise EvaluationError("candidate settings audit interval is invalid")
        scope = provider_scope(record["provider_scope"], f"{field}.provider_scope")
        if scope != expected_scope or scope["repository"] != repository:
            raise EvaluationError("candidate settings audit scope changed during observation")
        attestation = validate_candidate_attestation(record["attestation"], f"{field}.attestation", policy)
        if index and effective_from != records[-1]["effective_until"]:
            raise EvaluationError("candidate settings audit history has a gap or overlap")
        records.append(
            {
                "audit_event_id": audit_event_id,
                "revision": revision,
                "effective_from": effective_from,
                "effective_until": effective_until,
                "scope": scope,
                "attestation": attestation,
            }
        )
    if records[0]["effective_from"] > window_start or records[-1]["effective_until"] < window_end:
        raise EvaluationError("candidate settings audit history does not span the observation window")
    if records[-1]["revision"] != collection["candidate_settings_revision"]:
        raise EvaluationError("candidate settings current revision is not the final audited revision")
    if records[-1]["attestation"] != collection["candidate_settings_attestation"]:
        raise EvaluationError("candidate settings current attestation is not the final audited state")
    return records


def cross_validate_exports(
    ledger: Mapping[str, Any],
    policy: Mapping[str, Any],
    export_documents: Mapping[str, Any],
    export_digests: Mapping[str, str],
) -> dict[str, Any]:
    if set(export_documents) != set(EXPORT_NAMES) | PROOF_NAMES:
        raise EvaluationError("the canonical export/proof set is incomplete")
    collection = ledger["collection"]
    exported_at = collection["exported_at"]
    repository = repository_identity(ledger["repository"], "ledger.repository")
    ready_events = [
        {
            "event_id": item["event_id"],
            "delivery_id": item["delivery_id"],
            "action": item["action"],
            "pull_request_key": item["pull_request_key"],
            "source_cohort_id": item["source_cohort_id"],
            "ready_at": item["ready_at"],
            "superseded_by_event_id": item["superseded_by_event_id"],
            "expected_source": item["expected_source"],
        }
        for item in ledger["ready_pull_requests"]
    ]
    main_pushes = [
        {
            "event_id": item["event_id"],
            "sequence": item["sequence"],
            "pushed_at": item["pushed_at"],
            "expected_source": item["expected_source"],
        }
        for item in ledger["main_pushes"]
    ]
    event_export = validate_export_header(
        export_documents["event"],
        "event",
        {
            "schema",
            "source",
            "source_response_sha256",
            "exported_at",
            "window_started_at",
            "window_ended_at",
            "pull_request_eligibility_contract",
            "main_push_eligibility_contract",
            "included_actions",
            "ready_pull_requests",
            "main_pushes",
            "source_unavailable_policy",
            "source_unavailable_merge_conflicts",
        },
        exported_at,
        repository,
    )
    if event_export["source"] != "provider-api":
        raise EvaluationError("event export is not provider-API sourced")
    if (
        event_export["pull_request_eligibility_contract"] != PULL_REQUEST_ELIGIBILITY
        or event_export["main_push_eligibility_contract"] != MAIN_PUSH_ELIGIBILITY
        or event_export["included_actions"] != ORDERED_EVENT_ACTIONS
        or event_export["source_unavailable_policy"] != SOURCE_UNAVAILABLE_POLICY
    ):
        raise EvaluationError("event export eligibility can omit canonical CI triggers")
    if (
        event_export["window_started_at"] != collection["window_started_at"]
        or event_export["window_ended_at"] != collection["window_ended_at"]
        or indexed_records(event_export["ready_pull_requests"], "event export.ready_pull_requests")
        != indexed_records(ready_events, "ledger ready events")
        or indexed_records(event_export["main_pushes"], "event export.main_pushes")
        != indexed_records(main_pushes, "ledger main pushes")
        or indexed_records(
            event_export["source_unavailable_merge_conflicts"],
            "event export.source_unavailable_merge_conflicts",
        )
        != indexed_records(
            ledger["source_unavailable_merge_conflicts"],
            "ledger source_unavailable_merge_conflicts",
        )
    ):
        raise EvaluationError("ledger trigger coverage is not derived from the canonical event export")

    provider_bindings: dict[str, dict[str, Any]] = {}
    for name, provider, owner in (
        ("authoritative", policy["authoritative"], "authoritative"),
        ("candidate", policy["candidate"], "candidate"),
    ):
        provider_export = validate_export_header(
            export_documents[name],
            name,
            {
                "schema",
                "source",
                "source_response_sha256",
                "provider",
                "exported_at",
                "runs",
                "main_runs",
                "provider_scope",
                "settings_revision",
            },
            exported_at,
            repository,
        )
        export_scope = provider_scope(
            provider_export["provider_scope"], f"{name} export.provider_scope"
        )
        export_revision = require_text(
            provider_export["settings_revision"],
            f"{name} export.settings_revision",
            identifier=True,
        )
        if (
            provider_export["source"] != "provider-api"
            or provider_export["provider"] != provider
            or export_scope["provider"] != provider
            or export_scope["repository"] != repository
        ):
            raise EvaluationError(f"{name} export has the wrong provider source")
        if name == "candidate" and (
            export_scope != provider_scope(
                collection["candidate_provider_scope"], "collection.candidate_provider_scope"
            )
            or export_revision != collection["candidate_settings_revision"]
        ):
            raise EvaluationError("candidate provider export is not bound to audited settings")
        provider_bindings[provider] = {
            "scope": export_scope,
            "settings_revision": export_revision,
        }
        expected_runs = [
            {"event_id": item["event_id"], "observation": item[owner]}
            for item in ledger["ready_pull_requests"]
        ]
        if indexed_records(provider_export["runs"], f"{name} export.runs") != indexed_records(
            expected_runs, f"ledger {name} runs"
        ):
            raise EvaluationError(f"ledger {name} run data is not derived from its provider export")
        expected_main_runs = [
            {"event_id": item["event_id"], "observation": item[owner]}
            for item in ledger["main_pushes"]
        ]
        if indexed_records(
            provider_export["main_runs"], f"{name} export.main_runs"
        ) != indexed_records(expected_main_runs, f"ledger {name} main runs"):
            raise EvaluationError(
                f"ledger {name} main-run data is not derived from its provider export"
            )

    verdict_export = validate_export_header(
        export_documents["product_verdict"],
        "product_verdict",
        {
            "schema",
            "source",
            "source_response_sha256",
            "exported_at",
            "verdicts",
            "main_verdicts",
        },
        exported_at,
        repository,
    )
    if verdict_export["source"] != "independent-product-evidence":
        raise EvaluationError("product verdicts are not independently sourced")
    expected_verdicts = [
        {
            "event_id": item["event_id"],
            "product_verdict": item["product_verdict"],
            "product_verdict_evidence_sha256": item["product_verdict_evidence_sha256"],
        }
        for item in ledger["ready_pull_requests"]
    ]
    if indexed_records(verdict_export["verdicts"], "product verdict export.verdicts") != indexed_records(
        expected_verdicts, "ledger product verdicts"
    ):
        raise EvaluationError("ledger product verdicts are not derived from their canonical export")
    expected_main_verdicts = [
        {
            "event_id": item["event_id"],
            "product_verdict": item["product_verdict"],
            "product_verdict_evidence_sha256": item[
                "product_verdict_evidence_sha256"
            ],
        }
        for item in ledger["main_pushes"]
    ]
    if indexed_records(
        verdict_export["main_verdicts"], "product verdict export.main_verdicts"
    ) != indexed_records(expected_main_verdicts, "ledger main product verdicts"):
        raise EvaluationError("ledger main verdicts are not derived from independent evidence")

    testflight_export = validate_export_header(
        export_documents["testflight"],
        "testflight",
        {
            "schema",
            "source",
            "source_response_sha256",
            "release_provider",
            "exported_at",
            "release_evidence",
            "release_eligibility",
        },
        exported_at,
        repository,
    )
    if (
        testflight_export["source"] != "provider-api"
        or testflight_export["release_provider"] != policy["release_provider"]
        or indexed_records(
            testflight_export["release_eligibility"],
            "testflight export.release_eligibility",
        )
        != indexed_records(
            [
                {
                    "event_id": item["event_id"],
                    "sequence": item["sequence"],
                    "main_sha": item["expected_source"]["sha"],
                    "release_attempt_inventory": item["release_attempt_inventory"],
                    "history": item["release_eligibility_history"],
                    "selected_evidence_sha256": item[
                        "selected_release_eligibility_sha256"
                    ],
                }
                for item in ledger["main_pushes"]
            ],
            "ledger release eligibility",
        )
        or indexed_records(
            testflight_export["release_evidence"],
            "testflight export.release_evidence",
        )
        != indexed_records(
            [
                {"event_id": item["event_id"], **item["release_evidence"]}
                for item in ledger["main_pushes"]
            ],
            "ledger release evidence",
        )
    ):
        raise EvaluationError("ledger TestFlight data is not derived from its provider export")

    settings_export = validate_export_header(
        export_documents["candidate_settings"],
        "candidate_settings",
        {
            "schema",
            "source",
            "source_response_sha256",
            "provider",
            "exported_at",
            "current_revision",
            "provider_scope",
            "audit_history",
        },
        exported_at,
        repository,
    )
    if (
        settings_export["source"] != "provider-audit-api"
        or settings_export["provider"] != policy["candidate"]
        or settings_export["current_revision"] != collection["candidate_settings_revision"]
        or provider_scope(
            settings_export["provider_scope"], "candidate settings export.provider_scope"
        )
        != provider_scope(
            collection["candidate_provider_scope"], "collection.candidate_provider_scope"
        )
    ):
        raise EvaluationError("candidate settings are not derived from the canonical provider export")
    settings_history = validate_candidate_settings_history(
        settings_export, collection, policy, repository
    )

    ruleset_export = validate_export_header(
        export_documents["authority_ruleset"],
        "authority_ruleset",
        {
            "schema",
            "source",
            "source_response_sha256",
            "provider",
            "exported_at",
            "ruleset_id",
            "name",
            "target",
            "enforcement",
            "default_branch",
            "branch_includes",
            "branch_excludes",
            "required_status_checks",
            "bypass_actors",
            "pull_request_requirement",
            "forbidden_metadata_patterns",
        },
        exported_at,
        repository,
    )
    required_status_checks = exact_object(
        ruleset_export["required_status_checks"],
        {"strict", "checks"},
        "authority ruleset export.required_status_checks",
    )
    checks = required_status_checks["checks"]
    pull_request_requirement = exact_object(
        ruleset_export["pull_request_requirement"],
        {"required"},
        "authority ruleset export.pull_request_requirement",
    )
    require_text(
        ruleset_export["name"], "authority ruleset export.name", identifier=True
    )
    if (
        ruleset_export["source"] != "provider-api"
        or ruleset_export["provider"] != policy["authoritative"]
        or require_integer(
            ruleset_export["ruleset_id"], "authority ruleset export.ruleset_id", minimum=1
        )
        != collection["authority_ruleset_id"]
        or ruleset_export["target"] != "branch"
        or ruleset_export["enforcement"] != "active"
        or ruleset_export["default_branch"] != policy["main_branch"]
        or ruleset_export["branch_includes"] != ["~DEFAULT_BRANCH"]
        or ruleset_export["branch_excludes"] != []
        or require_bool(
            required_status_checks["strict"],
            "authority ruleset export.required_status_checks.strict",
        )
        is not True
        or checks != [{"context": "CI summary", "integration_id": 15368}]
        or ruleset_export["bypass_actors"] != []
        or require_bool(
            pull_request_requirement["required"],
            "authority ruleset export.pull_request_requirement.required",
        )
        is not True
        or ruleset_export["forbidden_metadata_patterns"] != FORBIDDEN_CI_SKIP_PATTERNS
    ):
        raise EvaluationError(
            "authoritative ruleset does not strictly protect CI summary and CI-skip continuity"
        )

    parity_export = validate_export_header(
        export_documents["parity"],
        "parity",
        {
            "schema",
            "source",
            "source_response_sha256",
            "exported_at",
            "records",
        },
        exported_at,
        repository,
    )
    if parity_export["source"] != "independent-parity-evidence":
        raise EvaluationError("parity export is not independently sourced")

    for name in sorted(PROOF_NAMES):
        proof = ledger["proofs"][name]
        expected = {
            "schema": EXPORT_SCHEMAS[name],
            "kind": name,
            **{key: value for key, value in proof.items() if key != "evidence_sha256"},
        }
        document = export_documents[name]
        if document != expected or proof["evidence_sha256"] != export_digests[name]:
            raise EvaluationError(f"{name} proof is not the supplied controlled evidence file")
        if repository_identity(document["repository"], f"{name} proof.repository") != repository:
            raise EvaluationError(f"{name} proof is bound to a different repository")
    return {
        "repository": repository,
        "settings_history": settings_history,
        "parity_export": parity_export,
        "provider_bindings": provider_bindings,
    }


def validate_testflight_release_history(
    main_push: Mapping[str, Any],
    field: str,
    expected_source: Mapping[str, str],
    pushed_at: datetime,
    authoritative_main: Mapping[str, Any],
    collection: Mapping[str, Any],
    policy: Mapping[str, Any],
    repository: Mapping[str, Any],
    latest_main_at: Callable[[datetime], str],
    release_attempt_identities: set[tuple[str, str]],
    testflight_build_ids: set[str],
    build_numbers: set[str],
) -> dict[str, Any]:
    """Validate the complete authenticated release chain for one main event.

    Eligibility decisions are release-attempt records, not deliveries. Multiple
    release attempts may observe one CI attempt, and multiple successful CI
    attempts may resolve through one persistent CI-run intent and one receipt.
    """

    inventory_value = main_push["release_attempt_inventory"]
    if not isinstance(inventory_value, list) or not inventory_value:
        raise EvaluationError(f"{field}.release_attempt_inventory must be a non-empty array")
    release_attempt_inventory: list[
        tuple[tuple[str, str], tuple[str, str]]
    ] = []
    inventory_release_attempts: set[tuple[str, str]] = set()
    inventory_ci_by_release_run: dict[str, tuple[str, str]] = {}
    previous_attempt_by_release_run: dict[str, int] = {}
    for index, inventory_record_value in enumerate(inventory_value):
        inventory_field = f"{field}.release_attempt_inventory[{index}]"
        inventory_record = exact_object(
            inventory_record_value, {"authoritative_ci", "release"}, inventory_field
        )
        provider_attempt = workflow_attempt_identity(
            inventory_record["authoritative_ci"],
            f"{inventory_field}.authoritative_ci",
        )
        release_attempt = workflow_attempt_identity(
            inventory_record["release"], f"{inventory_field}.release"
        )
        release_run_id, release_run_attempt = release_attempt
        prior_ci = inventory_ci_by_release_run.setdefault(
            release_run_id, provider_attempt
        )
        previous_attempt = previous_attempt_by_release_run.get(release_run_id, 0)
        if (
            release_attempt in inventory_release_attempts
            or prior_ci != provider_attempt
            or int(release_run_attempt) <= previous_attempt
        ):
            raise EvaluationError(
                f"{inventory_field} is a duplicate, reversed, or cross-CI release attempt"
            )
        inventory_release_attempts.add(release_attempt)
        previous_attempt_by_release_run[release_run_id] = int(release_run_attempt)
        release_attempt_inventory.append((provider_attempt, release_attempt))

    eligibility_history = artifact_history(
        main_push["release_eligibility_history"],
        f"{field}.release_eligibility_history",
        schema="tron.ios-release-eligibility.v1",
        artifact_name="ios-release-eligibility.json",
        document_keys={
            "schema",
            "repository",
            "source_sha",
            "observed_main_sha",
            "checked_at",
            "eligible",
            "authoritative_ci",
            "release",
        },
    )
    provider_attempts = authoritative_main["provider_attempts"]
    if not eligibility_history or len(eligibility_history) < len(provider_attempts):
        raise EvaluationError(
            f"{field} release eligibility does not cover every authoritative CI attempt"
        )
    provider_attempt_index = {
        identity: index for index, identity in enumerate(provider_attempts)
    }
    supported_conclusions = {
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
    eligibility_records: list[dict[str, Any]] = []
    first_seen_provider_attempts: list[tuple[str, str]] = []
    provider_attempt_evidence: dict[tuple[str, str], tuple[str, datetime]] = {}
    last_provider_index = -1
    previous_checked_at: datetime | None = None
    for record in eligibility_history:
        eligibility = record["document"]
        record_field = record["field"]
        authoritative = exact_object(
            eligibility["authoritative_ci"],
            {
                "workflow_run_id",
                "run_attempt",
                "event",
                "branch",
                "conclusion",
                "completed_at",
            },
            f"{record_field}.evidence.authoritative_ci",
        )
        release_attempt = workflow_attempt_identity(
            eligibility["release"], f"{record_field}.evidence.release"
        )
        provider_attempt = (
            require_positive_identifier(
                authoritative["workflow_run_id"],
                f"{record_field}.evidence.authoritative_ci.workflow_run_id",
            ),
            require_positive_identifier(
                authoritative["run_attempt"],
                f"{record_field}.evidence.authoritative_ci.run_attempt",
            ),
        )
        if provider_attempt not in provider_attempt_index:
            raise EvaluationError(f"{record_field} names an unobserved CI attempt")
        current_provider_index = provider_attempt_index[provider_attempt]
        if current_provider_index < last_provider_index:
            raise EvaluationError(f"{field} release eligibility reverses CI attempt order")
        last_provider_index = current_provider_index
        if provider_attempt not in provider_attempt_evidence:
            first_seen_provider_attempts.append(provider_attempt)
        conclusion = require_text(
            authoritative["conclusion"],
            f"{record_field}.evidence.authoritative_ci.conclusion",
            identifier=True,
        )
        if conclusion not in supported_conclusions:
            raise EvaluationError(f"{record_field} CI conclusion is unsupported")
        completed_at = require_timestamp(
            authoritative["completed_at"],
            f"{record_field}.evidence.authoritative_ci.completed_at",
        )
        prior_evidence = provider_attempt_evidence.get(provider_attempt)
        if prior_evidence is not None and prior_evidence != (conclusion, completed_at):
            raise EvaluationError(
                f"{record_field} conflicts with another release observation of the same CI attempt"
            )
        provider_attempt_evidence[provider_attempt] = (conclusion, completed_at)
        checked_at = require_timestamp(
            eligibility["checked_at"], f"{record_field}.evidence.checked_at"
        )
        if (
            completed_at < pushed_at
            or checked_at < completed_at
            or checked_at > collection["exported"]
            or (previous_checked_at is not None and checked_at < previous_checked_at)
        ):
            raise EvaluationError(f"{record_field} timestamps are not attempt ordered")
        previous_checked_at = checked_at
        observed_main_sha = require_oid(
            eligibility["observed_main_sha"],
            f"{record_field}.evidence.observed_main_sha",
        )
        source_sha = require_oid(
            eligibility["source_sha"], f"{record_field}.evidence.source_sha"
        )
        eligible = require_bool(
            eligibility["eligible"], f"{record_field}.evidence.eligible"
        )
        expected_eligible = (
            conclusion == "success" and observed_main_sha == expected_source["sha"]
        )
        if (
            eligibility["repository"] != repository["slug"]
            or source_sha != expected_source["sha"]
            or observed_main_sha != latest_main_at(checked_at)
            or authoritative["event"] != "push"
            or authoritative["branch"] != policy["main_branch"]
            or eligible is not expected_eligible
        ):
            raise EvaluationError(f"{record_field} is not a canonical release decision")
        if release_attempt in release_attempt_identities:
            raise EvaluationError(
                "release eligibility identities must be unique by run ID and run attempt"
            )
        release_attempt_identities.add(release_attempt)
        eligibility_records.append(
            {
                "digest": record["digest"],
                "provider_attempt": provider_attempt,
                "release_attempt": release_attempt,
                "conclusion": conclusion,
                "completed_at": completed_at,
                "checked_at": checked_at,
                "observed_main_sha": observed_main_sha,
                "eligible": eligible,
            }
        )

    authoritative_green = (
        authoritative_main["health"] == "healthy"
        and authoritative_main["product"] == "passed"
    )
    final_provider_attempt = provider_attempts[-1]
    final_conclusion, final_completed_at = provider_attempt_evidence[final_provider_attempt]
    failed_provider_attempts = sum(
        conclusion != "success"
        for conclusion, _ in provider_attempt_evidence.values()
    )
    selected_digest = require_digest(
        main_push["selected_release_eligibility_sha256"],
        f"{field}.selected_release_eligibility_sha256",
    )
    if (
        [
            (record["provider_attempt"], record["release_attempt"])
            for record in eligibility_records
        ]
        != release_attempt_inventory
        or first_seen_provider_attempts != provider_attempts
        or eligibility_records[-1]["provider_attempt"] != final_provider_attempt
        or selected_digest != eligibility_records[-1]["digest"]
        or failed_provider_attempts != authoritative_main["failure_attempts"]
        or authoritative_main["finished"] is None
        or final_completed_at != authoritative_main["finished"]
        or (final_conclusion == "success") is not authoritative_green
    ):
        raise EvaluationError(
            f"{field} selected release eligibility is not the complete final CI history"
        )

    release_evidence = exact_object(
        main_push["release_evidence"],
        {"release_provider", *RELEASE_EVIDENCE_SCHEMA},
        f"{field}.release_evidence",
    )
    if release_evidence["release_provider"] != policy["release_provider"]:
        raise EvaluationError(f"{field} release evidence names the wrong provider")
    document_keys = {
        "intents": {
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
        "head_checks": {
            "schema",
            "repository",
            "source_sha",
            "current_main_sha",
            "source_is_current_main",
            "checked_at",
            "authoritative_ci",
            "release",
        },
        "release_provenance": {"schema", "source_sha", "github", "toolchain", "product"},
        "admissions": {
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
        "reuse_provenance": {
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
        "receipts": {
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
    }
    histories: dict[str, list[dict[str, Any]]] = {}
    for name, (schema, artifact_name) in RELEASE_EVIDENCE_SCHEMA.items():
        histories[name] = artifact_history(
            release_evidence[name],
            f"{field}.release_evidence.{name}",
            schema=schema,
            artifact_name=artifact_name,
            document_keys=document_keys[name],
        )

    eligible_by_release = {
        record["release_attempt"]: record
        for record in eligibility_records
        if record["eligible"]
    }
    intent_by_digest: dict[str, dict[str, Any]] = {}
    intent_by_release: dict[tuple[str, str], dict[str, Any]] = {}
    for record in histories["intents"]:
        intent = record["document"]
        record_field = record["field"]
        authoritative = exact_object(
            intent["authoritative_ci"],
            {"workflow_run_id", "run_number", "run_attempt", "completed_at"},
            f"{record_field}.evidence.authoritative_ci",
        )
        ci_run_id = require_positive_identifier(
            authoritative["workflow_run_id"],
            f"{record_field}.evidence.authoritative_ci.workflow_run_id",
        )
        ci_run_number = require_positive_identifier(
            authoritative["run_number"],
            f"{record_field}.evidence.authoritative_ci.run_number",
        )
        ci_attempt = require_positive_identifier(
            authoritative["run_attempt"],
            f"{record_field}.evidence.authoritative_ci.run_attempt",
        )
        ci_completed_at = require_timestamp(
            authoritative["completed_at"],
            f"{record_field}.evidence.authoritative_ci.completed_at",
        )
        owner = workflow_identity(intent["owner"], f"{record_field}.evidence.owner")
        release = workflow_identity(
            intent["release"], f"{record_field}.evidence.release"
        )
        release_attempt = (release["workflow_run_id"], release["run_attempt"])
        eligibility = eligible_by_release.get(release_attempt)
        created_at = require_timestamp(
            intent["created_at"], f"{record_field}.evidence.created_at"
        )
        product = validate_release_product(
            intent["product"], f"{record_field}.evidence.product", policy
        )
        resolution = exact_object(
            intent["resolution"],
            {"state", "previous_intent_sha256", "completion_receipt_sha256"},
            f"{record_field}.evidence.resolution",
        )
        state = resolution["state"]
        if state not in {"new", "resume", "completed"}:
            raise EvaluationError(f"{record_field} intent resolution is unsupported")
        previous = require_optional_digest(
            resolution["previous_intent_sha256"],
            f"{record_field}.evidence.resolution.previous_intent_sha256",
        )
        completion_receipt = require_optional_digest(
            resolution["completion_receipt_sha256"],
            f"{record_field}.evidence.resolution.completion_receipt_sha256",
        )
        if (
            intent["repository"] != repository["slug"]
            or require_oid(intent["source_sha"], f"{record_field}.evidence.source_sha")
            != expected_source["sha"]
            or intent["intent_key"] != f"github-ci-run:{ci_run_id}"
            or eligibility is None
            or eligibility["provider_attempt"] != (ci_run_id, ci_attempt)
            or eligibility["completed_at"] != ci_completed_at
            or created_at < eligibility["checked_at"]
            or created_at > collection["exported"]
            or release_attempt in intent_by_release
        ):
            raise EvaluationError(f"{record_field} intent is not bound to its eligibility attempt")
        if state == "new":
            if previous is not None or completion_receipt is not None or owner != release:
                raise EvaluationError(f"{record_field} new intent has prior evidence or another owner")
        elif state == "resume":
            if previous is None or completion_receipt is not None:
                raise EvaluationError(f"{record_field} resumable intent evidence is incomplete")
        elif previous is None or completion_receipt is None:
            raise EvaluationError(f"{record_field} completed intent evidence is incomplete")
        normalized = {
            "document": intent,
            "digest": record["digest"],
            "field": record_field,
            "authoritative_ci": {
                "workflow_run_id": ci_run_id,
                "run_number": ci_run_number,
                "run_attempt": ci_attempt,
                "completed_at": ci_completed_at,
            },
            "owner": owner,
            "release": release,
            "release_attempt": release_attempt,
            "product": product,
            "created_at": created_at,
            "state": state,
            "previous": previous,
            "completion_receipt": completion_receipt,
        }
        intent_by_digest[record["digest"]] = normalized
        intent_by_release[release_attempt] = normalized

    if set(intent_by_release) != set(eligible_by_release):
        raise EvaluationError(
            f"{field} eligible decisions and authenticated release intents are not one-to-one"
        )

    if intent_by_digest:
        roots = [intent for intent in intent_by_digest.values() if intent["state"] == "new"]
        if len(roots) != 1:
            raise EvaluationError(f"{field} release intent history must have one root")
        root = roots[0]
        owner = root["owner"]
        product = root["product"]
        intent_key = root["document"]["intent_key"]
        ci_run_id = root["authoritative_ci"]["workflow_run_id"]
        ci_run_number = root["authoritative_ci"]["run_number"]
        if product["build_number"] != automatic_build_number(owner["run_number"]):
            raise EvaluationError(f"{field} release build is not owned by its allocation")
        successors: dict[str, str] = {}
        for digest, intent in intent_by_digest.items():
            if (
                intent["owner"] != owner
                or intent["product"] != product
                or intent["document"]["intent_key"] != intent_key
                or intent["authoritative_ci"]["workflow_run_id"] != ci_run_id
                or intent["authoritative_ci"]["run_number"] != ci_run_number
            ):
                raise EvaluationError(f"{field} release intent allocation changed across attempts")
            previous = intent["previous"]
            if previous is not None:
                predecessor = intent_by_digest.get(previous)
                if (
                    predecessor is None
                    or previous == digest
                    or previous in successors
                    or intent["created_at"] < predecessor["created_at"]
                ):
                    raise EvaluationError(f"{field} release intent ancestry is broken or branched")
                successors[previous] = digest
        cursor = root["digest"]
        visited = {cursor}
        completed_seen = root["state"] == "completed"
        while cursor in successors:
            cursor = successors[cursor]
            if cursor in visited:
                raise EvaluationError(f"{field} release intent ancestry contains a cycle")
            current = intent_by_digest[cursor]
            if completed_seen and current["state"] != "completed":
                raise EvaluationError(f"{field} release intent resumed after completion")
            completed_seen = completed_seen or current["state"] == "completed"
            visited.add(cursor)
        if visited != set(intent_by_digest):
            raise EvaluationError(f"{field} release intent ancestry is disconnected")
    elif any(histories[name] for name in RELEASE_EVIDENCE_SCHEMA if name != "intents"):
        raise EvaluationError(f"{field} release side effects exist without an intent")

    # The remaining evidence is parsed and joined below. Keeping the indexes by
    # content digest makes the offline evaluator fail closed on copied or
    # cross-attempt artifacts even when their visible product fields agree.
    head_by_digest: dict[str, dict[str, Any]] = {}
    for record in histories["head_checks"]:
        head = record["document"]
        record_field = record["field"]
        authoritative = exact_object(
            head["authoritative_ci"],
            {"workflow_run_id", "run_attempt", "completed_at"},
            f"{record_field}.evidence.authoritative_ci",
        )
        authoritative_ci = {
            "workflow_run_id": require_positive_identifier(
                authoritative["workflow_run_id"],
                f"{record_field}.evidence.authoritative_ci.workflow_run_id",
            ),
            "run_attempt": require_positive_identifier(
                authoritative["run_attempt"],
                f"{record_field}.evidence.authoritative_ci.run_attempt",
            ),
            "completed_at": require_timestamp(
                authoritative["completed_at"],
                f"{record_field}.evidence.authoritative_ci.completed_at",
            ),
        }
        release_attempt = workflow_attempt_identity(
            head["release"], f"{record_field}.evidence.release"
        )
        checked_at = require_timestamp(
            head["checked_at"], f"{record_field}.evidence.checked_at"
        )
        source_sha = require_oid(
            head["source_sha"], f"{record_field}.evidence.source_sha"
        )
        current_main_sha = require_oid(
            head["current_main_sha"], f"{record_field}.evidence.current_main_sha"
        )
        if (
            head["repository"] != repository["slug"]
            or source_sha != expected_source["sha"]
            or current_main_sha != source_sha
            or require_bool(
                head["source_is_current_main"],
                f"{record_field}.evidence.source_is_current_main",
            )
            is not True
            or current_main_sha != latest_main_at(checked_at)
            or checked_at < authoritative_ci["completed_at"]
            or checked_at > collection["exported"]
        ):
            raise EvaluationError(f"{record_field} is not a current-main head check")
        head_by_digest[record["digest"]] = {
            "document": head,
            "digest": record["digest"],
            "field": record_field,
            "authoritative_ci": authoritative_ci,
            "release_attempt": release_attempt,
            "checked_at": checked_at,
        }

    provenance_by_digest: dict[str, dict[str, Any]] = {}
    for record in histories["release_provenance"]:
        provenance = record["document"]
        record_field = record["field"]
        github = exact_object(
            provenance["github"],
            {"run_id", "run_attempt"},
            f"{record_field}.evidence.github",
        )
        producer = (
            require_positive_identifier(
                github["run_id"], f"{record_field}.evidence.github.run_id"
            ),
            require_positive_identifier(
                github["run_attempt"],
                f"{record_field}.evidence.github.run_attempt",
            ),
        )
        toolchain = exact_object(
            provenance["toolchain"],
            {"xcode_version", "xcode_build", "sdk", "deployment_target"},
            f"{record_field}.evidence.toolchain",
        )
        for name, value in toolchain.items():
            require_text(value, f"{record_field}.evidence.toolchain.{name}")
        product = exact_object(
            provenance["product"],
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
            f"{record_field}.evidence.product",
        )
        normalized_product = {
            key: require_text(value, f"{record_field}.evidence.product.{key}")
            for key, value in product.items()
        }
        if (
            require_oid(
                provenance["source_sha"], f"{record_field}.evidence.source_sha"
            )
            != expected_source["sha"]
            or not MARKETING_VERSION_RE.fullmatch(
                normalized_product["marketing_version"]
            )
            or not HOSTED_BUILD_VERSION_RE.fullmatch(
                normalized_product["build_number"]
            )
            or [
                normalized_product["app_bundle_id"],
                normalized_product["extension_bundle_id"],
            ]
            != policy["testflight_identity"]["bundle_ids"]
        ):
            raise EvaluationError(f"{record_field} release provenance has stale identities")
        for digest_name in (
            "app_executable_sha256",
            "share_extension_executable_sha256",
            "ipa_sha256",
        ):
            require_raw_digest(
                normalized_product[digest_name],
                f"{record_field}.evidence.product.{digest_name}",
            )
        provenance_by_digest[record["digest"]] = {
            "document": provenance,
            "digest": record["digest"],
            "field": record_field,
            "producer": producer,
            "product": normalized_product,
        }

    admission_by_digest: dict[str, dict[str, Any]] = {}
    admission_by_intent: dict[str, dict[str, Any]] = {}
    for record in histories["admissions"]:
        admission = record["document"]
        record_field = record["field"]
        product = validate_release_product(
            admission["product"], f"{record_field}.evidence.product", policy
        )
        owner = workflow_identity(admission["owner"], f"{record_field}.evidence.owner")
        producer = workflow_identity(
            admission["producer"], f"{record_field}.evidence.producer"
        )
        asc = exact_object(
            admission["asc"], {"app_id", "build_id"}, f"{record_field}.evidence.asc"
        )
        asc_app_id = require_text(
            asc["app_id"], f"{record_field}.evidence.asc.app_id", identifier=True
        )
        asc_build_id = require_text(
            asc["build_id"], f"{record_field}.evidence.asc.build_id", identifier=True
        )
        evidence = exact_object(
            admission["evidence"],
            {
                "intent_sha256",
                "release_provenance_sha256",
                "head_check_sha256",
                "prior_admission_sha256",
                "reuse_provenance_sha256",
            },
            f"{record_field}.evidence.evidence",
        )
        intent_digest = require_digest(
            evidence["intent_sha256"],
            f"{record_field}.evidence.evidence.intent_sha256",
        )
        provenance_digest = require_digest(
            evidence["release_provenance_sha256"],
            f"{record_field}.evidence.evidence.release_provenance_sha256",
        )
        head_digest = require_digest(
            evidence["head_check_sha256"],
            f"{record_field}.evidence.evidence.head_check_sha256",
        )
        prior_admission = require_optional_digest(
            evidence["prior_admission_sha256"],
            f"{record_field}.evidence.evidence.prior_admission_sha256",
        )
        reuse_digest = require_optional_digest(
            evidence["reuse_provenance_sha256"],
            f"{record_field}.evidence.evidence.reuse_provenance_sha256",
        )
        if (prior_admission is None) != (reuse_digest is None):
            raise EvaluationError(f"{record_field} reuse evidence is incomplete")
        intent = intent_by_digest.get(intent_digest)
        head = head_by_digest.get(head_digest)
        provenance = provenance_by_digest.get(provenance_digest)
        producer_attempt = (producer["workflow_run_id"], producer["run_attempt"])
        admitted_at = require_timestamp(
            admission["admitted_at"], f"{record_field}.evidence.admitted_at"
        )
        if (
            intent is None
            or head is None
            or provenance is None
            or admission["repository"] != repository["slug"]
            or require_oid(
                admission["source_sha"], f"{record_field}.evidence.source_sha"
            )
            != expected_source["sha"]
            or admission["intent_key"] != intent["document"]["intent_key"]
            or product != intent["product"]
            or owner != intent["owner"]
            or intent["state"] == "completed"
            or asc_app_id != product["asc_app_id"]
            or producer != intent["release"]
            or any(
                provenance["product"][name] != product[name]
                for name in (
                    "canonical_version",
                    "marketing_version",
                    "build_number",
                    "app_bundle_id",
                    "extension_bundle_id",
                )
            )
            or head["release_attempt"] != producer_attempt
            or head["authoritative_ci"]["workflow_run_id"]
            != intent["authoritative_ci"]["workflow_run_id"]
            or head["authoritative_ci"]["run_attempt"]
            != intent["authoritative_ci"]["run_attempt"]
            or head["authoritative_ci"]["completed_at"]
            != intent["authoritative_ci"]["completed_at"]
            or head["checked_at"] < intent["created_at"]
            or admitted_at < head["checked_at"]
            or admitted_at > collection["exported"]
            or intent_digest in admission_by_intent
        ):
            raise EvaluationError(f"{record_field} admission is not bound to its exact inputs")
        if prior_admission is None and provenance["producer"] != producer_attempt:
            raise EvaluationError(f"{record_field} fresh admission provenance has another producer")
        normalized = {
            "document": admission,
            "digest": record["digest"],
            "field": record_field,
            "intent_digest": intent_digest,
            "intent": intent,
            "owner": owner,
            "product": product,
            "producer": producer,
            "producer_attempt": producer_attempt,
            "asc_app_id": asc_app_id,
            "asc_build_id": asc_build_id,
            "provenance_digest": provenance_digest,
            "head_digest": head_digest,
            "prior_admission": prior_admission,
            "reuse_digest": reuse_digest,
            "admitted_at": admitted_at,
        }
        admission_by_digest[record["digest"]] = normalized
        admission_by_intent[intent_digest] = normalized

    reuse_by_digest: dict[str, dict[str, Any]] = {}
    for record in histories["reuse_provenance"]:
        reuse = record["document"]
        record_field = record["field"]
        product = exact_object(
            reuse["product"],
            {
                "canonical_version",
                "marketing_version",
                "build_number",
                "app_bundle_id",
                "extension_bundle_id",
                "ipa_sha256",
            },
            f"{record_field}.evidence.product",
        )
        normalized_product = {
            key: require_text(value, f"{record_field}.evidence.product.{key}")
            for key, value in product.items()
        }
        if (
            not MARKETING_VERSION_RE.fullmatch(
                normalized_product["marketing_version"]
            )
            or not HOSTED_BUILD_VERSION_RE.fullmatch(
                normalized_product["build_number"]
            )
        ):
            raise EvaluationError(f"{record_field} reused product identity is invalid")
        require_raw_digest(
            normalized_product["ipa_sha256"],
            f"{record_field}.evidence.product.ipa_sha256",
        )
        asc = exact_object(
            reuse["asc"], {"app_id", "build_id"}, f"{record_field}.evidence.asc"
        )
        asc_app_id = require_text(
            asc["app_id"], f"{record_field}.evidence.asc.app_id", identifier=True
        )
        asc_build_id = require_text(
            asc["build_id"], f"{record_field}.evidence.asc.build_id", identifier=True
        )
        owner = workflow_identity(reuse["owner"], f"{record_field}.evidence.owner")
        original = exact_object(
            reuse["original"],
            {
                "workflow_run_id",
                "run_attempt",
                "provenance_sha256",
                "intent_sha256",
                "admission_sha256",
            },
            f"{record_field}.evidence.original",
        )
        original_attempt = (
            require_positive_identifier(
                original["workflow_run_id"],
                f"{record_field}.evidence.original.workflow_run_id",
            ),
            require_positive_identifier(
                original["run_attempt"],
                f"{record_field}.evidence.original.run_attempt",
            ),
        )
        original_provenance_digest = require_digest(
            original["provenance_sha256"],
            f"{record_field}.evidence.original.provenance_sha256",
        )
        original_intent_digest = require_digest(
            original["intent_sha256"],
            f"{record_field}.evidence.original.intent_sha256",
        )
        original_admission_digest = require_digest(
            original["admission_sha256"],
            f"{record_field}.evidence.original.admission_sha256",
        )
        consumer_object = exact_object(
            reuse["consumer"],
            {"workflow_run_id", "run_number", "run_attempt", "intent_sha256"},
            f"{record_field}.evidence.consumer",
        )
        consumer = {
            key: require_positive_identifier(
                consumer_object[key], f"{record_field}.evidence.consumer.{key}"
            )
            for key in ("workflow_run_id", "run_number", "run_attempt")
        }
        consumer_intent_digest = require_digest(
            consumer_object["intent_sha256"],
            f"{record_field}.evidence.consumer.intent_sha256",
        )
        prior_admission = admission_by_digest.get(original_admission_digest)
        original_provenance = provenance_by_digest.get(original_provenance_digest)
        original_intent = intent_by_digest.get(original_intent_digest)
        consumer_intent = intent_by_digest.get(consumer_intent_digest)
        consumer_attempt = (consumer["workflow_run_id"], consumer["run_attempt"])
        expected_product = None
        if original_provenance is not None:
            expected_product = {
                key: original_provenance["product"][key]
                for key in normalized_product
            }
        if (
            reuse["repository"] != repository["slug"]
            or require_oid(reuse["source_sha"], f"{record_field}.evidence.source_sha")
            != expected_source["sha"]
            or prior_admission is None
            or original_provenance is None
            or original_intent is None
            or consumer_intent is None
            or consumer_intent["state"] != "resume"
            or reuse["intent_key"] != consumer_intent["document"]["intent_key"]
            or owner != consumer_intent["owner"]
            or owner != prior_admission["owner"]
            or normalized_product != expected_product
            or asc_app_id != prior_admission["asc_app_id"]
            or asc_build_id != prior_admission["asc_build_id"]
            or original_attempt != original_provenance["producer"]
            or prior_admission["provenance_digest"] != original_provenance_digest
            or prior_admission["intent_digest"] != original_intent_digest
            or consumer != consumer_intent["release"]
            or consumer_attempt != consumer_intent["release_attempt"]
        ):
            raise EvaluationError(f"{record_field} reuse provenance breaks its custody chain")
        reuse_by_digest[record["digest"]] = {
            "document": reuse,
            "digest": record["digest"],
            "field": record_field,
            "original_admission_digest": original_admission_digest,
            "original_provenance_digest": original_provenance_digest,
            "original_intent_digest": original_intent_digest,
            "consumer_intent_digest": consumer_intent_digest,
            "consumer": consumer,
            "asc_build_id": asc_build_id,
        }

    referenced_reuse: set[str] = set()
    tail_admission_digest: str | None = None
    if admission_by_digest:
        roots = [
            admission
            for admission in admission_by_digest.values()
            if admission["prior_admission"] is None
        ]
        if len(roots) != 1:
            raise EvaluationError(f"{field} release admission history must have one root")
        successors: dict[str, str] = {}
        asc_build_ids = {admission["asc_build_id"] for admission in admission_by_digest.values()}
        if len(asc_build_ids) != 1:
            raise EvaluationError(f"{field} release admissions disagree on the ASC build")
        for digest, admission in admission_by_digest.items():
            prior_digest = admission["prior_admission"]
            reuse_digest = admission["reuse_digest"]
            if prior_digest is None:
                continue
            prior = admission_by_digest.get(prior_digest)
            reuse = reuse_by_digest.get(reuse_digest or "")
            if (
                prior is None
                or prior_digest == digest
                or prior_digest in successors
                or reuse is None
                or reuse["original_admission_digest"] != prior_digest
                or reuse["consumer_intent_digest"] != admission["intent_digest"]
                or reuse["consumer"] != admission["producer"]
                or reuse["asc_build_id"] != admission["asc_build_id"]
                or admission["admitted_at"] < prior["admitted_at"]
            ):
                raise EvaluationError(f"{field} release admission ancestry is broken or branched")
            successors[prior_digest] = digest
            assert reuse_digest is not None
            referenced_reuse.add(reuse_digest)
        cursor = roots[0]["digest"]
        visited = {cursor}
        while cursor in successors:
            cursor = successors[cursor]
            if cursor in visited:
                raise EvaluationError(f"{field} release admission ancestry contains a cycle")
            visited.add(cursor)
        if visited != set(admission_by_digest):
            raise EvaluationError(f"{field} release admission ancestry is disconnected")
        tail_admission_digest = cursor
    if referenced_reuse != set(reuse_by_digest):
        raise EvaluationError(f"{field} reuse provenance is missing or orphaned")

    referenced_heads = {admission["head_digest"] for admission in admission_by_digest.values()}
    referenced_provenance = {
        admission["provenance_digest"] for admission in admission_by_digest.values()
    }
    if referenced_heads != set(head_by_digest) or referenced_provenance != set(
        provenance_by_digest
    ):
        raise EvaluationError(f"{field} release input evidence is missing or orphaned")

    receipt_by_digest: dict[str, dict[str, Any]] = {}
    for record in histories["receipts"]:
        receipt = record["document"]
        record_field = record["field"]
        authoritative = exact_object(
            receipt["authoritative_ci"],
            {"workflow_run_id", "run_number"},
            f"{record_field}.evidence.authoritative_ci",
        )
        authoritative_ci = {
            "workflow_run_id": require_positive_identifier(
                authoritative["workflow_run_id"],
                f"{record_field}.evidence.authoritative_ci.workflow_run_id",
            ),
            "run_number": require_positive_identifier(
                authoritative["run_number"],
                f"{record_field}.evidence.authoritative_ci.run_number",
            ),
        }
        product = validate_release_product(
            receipt["product"], f"{record_field}.evidence.product", policy
        )
        owner = workflow_identity(receipt["owner"], f"{record_field}.evidence.owner")
        producer = workflow_identity(
            receipt["producer"], f"{record_field}.evidence.producer"
        )
        delivery = exact_object(
            receipt["delivery"],
            {"channel", "asc_build_id", "testflight_group_id", "completed_at"},
            f"{record_field}.evidence.delivery",
        )
        asc_build_id = require_text(
            delivery["asc_build_id"],
            f"{record_field}.evidence.delivery.asc_build_id",
            identifier=True,
        )
        testflight_group_id = require_text(
            delivery["testflight_group_id"],
            f"{record_field}.evidence.delivery.testflight_group_id",
            identifier=True,
        )
        completed_at = require_timestamp(
            delivery["completed_at"],
            f"{record_field}.evidence.delivery.completed_at",
        )
        evidence = exact_object(
            receipt["evidence"],
            {
                "intent_sha256",
                "admission_sha256",
                "release_provenance_sha256",
                "head_check_sha256",
                "reuse_provenance_sha256",
            },
            f"{record_field}.evidence.evidence",
        )
        intent_digest = require_digest(
            evidence["intent_sha256"],
            f"{record_field}.evidence.evidence.intent_sha256",
        )
        admission_digest = require_digest(
            evidence["admission_sha256"],
            f"{record_field}.evidence.evidence.admission_sha256",
        )
        provenance_digest = require_digest(
            evidence["release_provenance_sha256"],
            f"{record_field}.evidence.evidence.release_provenance_sha256",
        )
        head_digest = require_digest(
            evidence["head_check_sha256"],
            f"{record_field}.evidence.evidence.head_check_sha256",
        )
        reuse_digest = require_optional_digest(
            evidence["reuse_provenance_sha256"],
            f"{record_field}.evidence.evidence.reuse_provenance_sha256",
        )
        intent = intent_by_digest.get(intent_digest)
        admission = admission_by_digest.get(admission_digest)
        head = head_by_digest.get(head_digest)
        provenance = provenance_by_digest.get(provenance_digest)
        producer_attempt = (producer["workflow_run_id"], producer["run_attempt"])
        if (
            intent is None
            or admission is None
            or head is None
            or provenance is None
            or receipt["repository"] != repository["slug"]
            or require_oid(receipt["source_sha"], f"{record_field}.evidence.source_sha")
            != expected_source["sha"]
            or receipt["intent_key"] != intent["document"]["intent_key"]
            or product != intent["product"]
            or owner != intent["owner"]
            or authoritative_ci
            != {
                "workflow_run_id": intent["authoritative_ci"]["workflow_run_id"],
                "run_number": intent["authoritative_ci"]["run_number"],
            }
            or admission["intent_digest"] != intent_digest
            or admission["producer"] != producer
            or admission["provenance_digest"] != provenance_digest
            or admission["head_digest"] != head_digest
            or admission["reuse_digest"] != reuse_digest
            or asc_build_id != admission["asc_build_id"]
            or delivery["channel"] != policy["testflight_channel"]
            or completed_at < admission["admitted_at"]
            or completed_at > collection["exported"]
            or (reuse_digest is not None and reuse_digest not in reuse_by_digest)
            or (reuse_digest is None and provenance["producer"] != producer_attempt)
        ):
            raise EvaluationError(f"{record_field} receipt is not bound to its exact admission")
        receipt_by_digest[record["digest"]] = {
            "document": receipt,
            "digest": record["digest"],
            "field": record_field,
            "intent": intent,
            "intent_digest": intent_digest,
            "admission_digest": admission_digest,
            "completed_at": completed_at,
            "asc_build_id": asc_build_id,
            "testflight_group_id": testflight_group_id,
        }

    canonical_receipt: dict[str, Any] | None = None
    if eligible_by_release:
        tail_receipts = [
            receipt
            for receipt in receipt_by_digest.values()
            if receipt["admission_digest"] == tail_admission_digest
        ]
        delivery_identities = {
            (
                receipt["document"]["delivery"]["channel"],
                receipt["asc_build_id"],
                receipt["testflight_group_id"],
            )
            for receipt in receipt_by_digest.values()
        }
        if not receipt_by_digest or not tail_receipts or len(delivery_identities) != 1:
            raise EvaluationError(
                f"{field} release-eligible history lacks one unambiguous tail receipt"
            )
        canonical_receipt = min(
            tail_receipts,
            key=lambda receipt: (receipt["completed_at"], receipt["digest"]),
        )
        if canonical_receipt["asc_build_id"] in testflight_build_ids:
            raise EvaluationError("TestFlight ASC build identities must be globally unique")
        testflight_build_ids.add(canonical_receipt["asc_build_id"])
    elif receipt_by_digest:
        raise EvaluationError(f"{field} receipt exists without an eligible release decision")

    for intent in intent_by_digest.values():
        receipt_digest = intent["completion_receipt"]
        if intent["state"] == "completed":
            receipt = receipt_by_digest.get(receipt_digest or "")
            if receipt is None or intent["created_at"] < receipt["completed_at"]:
                raise EvaluationError(
                    f"{intent['field']} completed intent does not reference the prior receipt"
                )

    if receipt_by_digest:
        completed_receipt = min(
            receipt_by_digest.values(), key=lambda receipt: receipt["completed_at"]
        )
        for intent in intent_by_digest.values():
            if (
                intent["created_at"] > completed_receipt["completed_at"]
                and intent["state"] != "completed"
            ):
                raise EvaluationError(f"{field} release intent resumed after its receipt")

    selected = eligibility_records[-1]
    if not receipt_by_digest:
        return {
            "selected_eligible": selected["eligible"],
            "delivery_count": 0,
            "delivery_duration": None,
            "delivery_scope": None,
        }
    assert canonical_receipt is not None
    receipt = canonical_receipt
    receipt_intent = receipt["intent"]
    build_number = receipt_intent["product"]["build_number"]
    if build_number in build_numbers:
        raise EvaluationError("hosted release build allocations must be globally unique")
    build_numbers.add(build_number)
    duration = (
        receipt["completed_at"]
        - receipt_intent["authoritative_ci"]["completed_at"]
    ).total_seconds()
    if duration < 0:
        raise EvaluationError(f"{field} TestFlight receipt predates authoritative CI")
    return {
        "selected_eligible": selected["eligible"],
        "delivery_count": 1,
        "delivery_duration": duration,
        "delivery_scope": (
            receipt_intent["product"]["asc_app_id"],
            receipt_intent["product"]["app_bundle_id"],
            receipt_intent["product"]["extension_bundle_id"],
            receipt_intent["product"]["scheme"],
            receipt_intent["product"]["configuration"],
            receipt["document"]["delivery"]["channel"],
            receipt["testflight_group_id"],
        ),
    }


def evaluate(
    document: Any,
    policy: Mapping[str, Any],
    export_digests: Mapping[str, str],
    export_documents: Mapping[str, Any],
) -> dict[str, Any]:
    ledger = exact_object(
        document,
        {
            "schema",
            "policy_sha256",
            "repository",
            "candidate_provider",
            "collection",
            "ready_pull_requests",
            "source_unavailable_merge_conflicts",
            "main_pushes",
            "proofs",
        },
        "ledger",
    )
    if ledger["schema"] != LEDGER_SCHEMA:
        raise EvaluationError("ledger uses an unsupported schema")
    if require_digest(ledger["policy_sha256"], "ledger.policy_sha256") != policy["digest"]:
        raise EvaluationError("ledger is not bound to the current CI policy")
    if ledger["candidate_provider"] != policy["candidate"]:
        raise EvaluationError("ledger candidate is not the policy shadow provider")
    repository = repository_identity(ledger["repository"], "ledger.repository")
    collection = validate_collection(ledger["collection"], policy, export_digests)
    canonical = cross_validate_exports(ledger, policy, export_documents, export_digests)
    if canonical["repository"] != repository:
        raise EvaluationError("canonical inputs are not bound to the ledger repository")
    settings_history = canonical["settings_history"]
    provider_bindings = canonical["provider_bindings"]

    pulls = ledger["ready_pull_requests"]
    if not isinstance(pulls, list) or len(pulls) != collection["pull_count"]:
        raise EvaluationError("ready-PR records do not cover every normalized eligible event")
    event_ids: set[str] = set()
    delivery_ids: set[str] = set()
    event_metadata: dict[str, tuple[str, str, datetime, str | None]] = {}
    source_cohort_by_key: dict[tuple[str, str, str], str] = {}
    source_key_by_cohort: dict[str, tuple[str, str, str]] = {}
    cohort_records: dict[str, list[dict[str, Any]]] = {}
    authoritative_ids: set[str] = set()
    candidate_ids: set[str] = set()
    authoritative_provider_attempts: set[tuple[str, str]] = set()
    candidate_provider_attempts: set[tuple[str, str]] = set()
    authoritative_trigger_ids: set[str] = set()
    candidate_trigger_ids: set[str] = set()
    event_times: list[datetime] = []
    candidate_durations: list[float] = []
    observed_sources: set[str] = set()
    observed_candidate_runs: dict[tuple[str, str], dict[str, Any]] = {}
    false_greens = 0
    source_mismatches = 0
    product_mismatches = 0
    authoritative_failures = 0
    candidate_failures = 0
    candidate_reliability_wins = 0
    candidate_reliability_losses = 0
    missing_operational_observations = 0
    candidate_missing_trigger_events = 0
    representative_count = 0
    conflicts = ledger["source_unavailable_merge_conflicts"]
    if not isinstance(conflicts, list) or len(conflicts) != collection["conflict_count"]:
        raise EvaluationError(
            "source-unavailable merge-conflict count differs from the canonical event export"
        )
    conflict_keys = {
        "event_id",
        "delivery_id",
        "action",
        "pull_request_key",
        "ready_at",
        "head_sha",
        "exclusion_reason",
        "evidence_sha256",
    }
    for index, value in enumerate(conflicts):
        field = f"source_unavailable_merge_conflicts[{index}]"
        conflict = exact_object(value, conflict_keys, field)
        event_id = require_text(conflict["event_id"], f"{field}.event_id", identifier=True)
        delivery_id = require_text(
            conflict["delivery_id"], f"{field}.delivery_id", identifier=True
        )
        if event_id in event_ids or delivery_id in delivery_ids:
            raise EvaluationError("canonical merge-conflict event identities must be unique")
        event_ids.add(event_id)
        delivery_ids.add(delivery_id)
        if conflict["action"] not in EVENT_ACTIONS:
            raise EvaluationError(f"{field}.action is unsupported")
        require_text(conflict["pull_request_key"], f"{field}.pull_request_key", identifier=True)
        conflict_time = require_timestamp(conflict["ready_at"], f"{field}.ready_at")
        if not collection["window_start"] <= conflict_time <= collection["window_end"]:
            raise EvaluationError(f"{field} is outside the normalized export window")
        require_oid(conflict["head_sha"], f"{field}.head_sha")
        if conflict["exclusion_reason"] != MERGE_CONFLICT_EXCLUSION:
            raise EvaluationError(f"{field} may only exclude a source-unavailable merge conflict")
        require_digest(conflict["evidence_sha256"], f"{field}.evidence_sha256")
    pull_keys = {
        "event_id",
        "delivery_id",
        "action",
        "pull_request_key",
        "source_cohort_id",
        "ready_at",
        "superseded_by_event_id",
        "expected_source",
        "product_verdict",
        "product_verdict_evidence_sha256",
        "authoritative",
        "candidate",
    }
    for index, value in enumerate(pulls):
        field = f"ready_pull_requests[{index}]"
        observation = exact_object(value, pull_keys, field)
        event_id = require_text(observation["event_id"], f"{field}.event_id", identifier=True)
        if event_id in event_ids:
            raise EvaluationError("ready-PR event IDs must be unique")
        event_ids.add(event_id)
        delivery_id = require_text(
            observation["delivery_id"], f"{field}.delivery_id", identifier=True
        )
        if delivery_id in delivery_ids:
            raise EvaluationError("ready-PR webhook delivery IDs must be unique")
        delivery_ids.add(delivery_id)
        action = observation["action"]
        if action not in EVENT_ACTIONS:
            raise EvaluationError(f"{field}.action is unsupported")
        pull_request_key = require_text(
            observation["pull_request_key"], f"{field}.pull_request_key", identifier=True
        )
        source_cohort_id = require_text(
            observation["source_cohort_id"], f"{field}.source_cohort_id", identifier=True
        )
        superseded_by = require_optional_text(
            observation["superseded_by_event_id"], f"{field}.superseded_by_event_id"
        )
        if superseded_by == event_id:
            raise EvaluationError(f"{field} cannot supersede itself")
        ready_at = require_timestamp(observation["ready_at"], f"{field}.ready_at")
        if not collection["window_start"] <= ready_at <= collection["window_end"]:
            raise EvaluationError(f"{field} is outside the normalized export window")
        expected_source = source_identity(observation["expected_source"], f"{field}.expected_source")
        source_key = (pull_request_key, expected_source["sha"], expected_source["tree"])
        existing_cohort = source_cohort_by_key.setdefault(source_key, source_cohort_id)
        existing_source = source_key_by_cohort.setdefault(source_cohort_id, source_key)
        if existing_cohort != source_cohort_id or existing_source != source_key:
            raise EvaluationError("source cohort identity is not one-to-one with PR source")
        event_metadata[event_id] = (
            pull_request_key,
            source_cohort_id,
            ready_at,
            superseded_by,
        )
        verdict = observation["product_verdict"]
        verdict_evidence = observation["product_verdict_evidence_sha256"]
        if superseded_by is None:
            if verdict not in PRODUCT_OUTCOMES:
                raise EvaluationError(f"{field}.product_verdict is unsupported")
            require_digest(verdict_evidence, f"{field}.product_verdict_evidence_sha256")
        elif verdict is not None or verdict_evidence is not None:
            raise EvaluationError(f"{field} superseded event cannot invent a product verdict")
        authoritative = run_observation(observation["authoritative"], f"{field}.authoritative")
        candidate = run_observation(observation["candidate"], f"{field}.candidate")
        validate_run_provenance(
            authoritative,
            f"{field}.authoritative",
            policy["authoritative"],
            policy,
            repository,
            settings_history,
            ready_at,
            provider_bindings[policy["authoritative"]],
        )
        validate_run_provenance(
            candidate,
            f"{field}.candidate",
            policy["candidate"],
            policy,
            repository,
            settings_history,
            ready_at,
            provider_bindings[policy["candidate"]],
        )
        if superseded_by is not None and (
            authoritative["health"] not in {"superseded", "canceled"}
            or candidate["health"] not in {"superseded", "canceled"}
        ):
            raise EvaluationError(
                f"{field} may be excluded as superseded only when both providers record cancellation"
            )
        for run, identities, provider_attempt_identities, trigger_ids, owner in (
            (
                authoritative,
                authoritative_ids,
                authoritative_provider_attempts,
                authoritative_trigger_ids,
                "authoritative",
            ),
            (
                candidate,
                candidate_ids,
                candidate_provider_attempts,
                candidate_trigger_ids,
                "candidate",
            ),
        ):
            if any(run_id in identities for run_id in run["attempt_ids"]):
                raise EvaluationError(f"{owner} provider attempt IDs must be unique across events")
            identities.update(run["attempt_ids"])
            if any(identity in provider_attempt_identities for identity in run["provider_attempts"]):
                raise EvaluationError(f"{owner} raw provider attempts must be unique across events")
            provider_attempt_identities.update(run["provider_attempts"])
            if run["trigger_id"] is not None:
                if run["trigger_id"] in trigger_ids:
                    raise EvaluationError(f"{owner} provider trigger IDs must be one-to-one")
                trigger_ids.add(run["trigger_id"])
            if run["started"] is not None and run["started"] < ready_at:
                raise EvaluationError(f"{field}.{owner} starts before the ready event")
            if run["finished"] is not None and run["finished"] > collection["exported"]:
                raise EvaluationError(f"{field}.{owner} finishes after the provider export")
            if run["health"] == "superseded" and superseded_by is None:
                raise EvaluationError(f"{field}.{owner} cannot be superseded on a representative event")
            if superseded_by is not None:
                continue
            if run["health"] == "healthy":
                if run["source"] != expected_source:
                    source_mismatches += 1
                if run["product"] != verdict:
                    product_mismatches += 1
        if superseded_by is None and candidate["health"] == "healthy":
            assert candidate["source"] is not None and candidate["finished"] is not None
            observed_sources.add(candidate["source"]["sha"])
            assert candidate["run_id"] is not None
            observed_candidate_runs[
                (candidate["source"]["sha"], candidate["run_id"])
            ] = {
                "finished": candidate["finished"],
                "settings_revision": candidate["settings_revision"],
                "scope": candidate["scope"],
            }
            if candidate["operational"] is None:
                missing_operational_observations += 1
            if candidate["product"] == "passed" and verdict == "failed":
                false_greens += 1
        if superseded_by is None and candidate["coverage"] == "missing":
            candidate_missing_trigger_events += 1
        cohort_records.setdefault(source_cohort_id, []).append(
            {
                "event_id": event_id,
                "ready_at": ready_at,
                "superseded_by": superseded_by,
                "verdict": verdict,
                "expected_source": expected_source,
                "authoritative": authoritative,
                "candidate": candidate,
            }
        )

    for event_id, (pull_key, cohort_id, ready_at, superseded_by) in event_metadata.items():
        if superseded_by is None:
            continue
        target = event_metadata.get(superseded_by)
        if (
            target is None
            or target[0] != pull_key
            or target[1] == cohort_id
            or target[2] <= ready_at
            or target[3] is not None
        ):
            raise EvaluationError(
                f"{event_id} must be superseded by a later representative event for the same PR"
            )

    for cohort_id, records in cohort_records.items():
        representative_records = [
            record for record in records if record["superseded_by"] is None
        ]
        if not representative_records:
            continue
        representative_count += 1
        event_times.append(min(record["ready_at"] for record in representative_records))
        verdicts = {record["verdict"] for record in representative_records}
        if len(verdicts) != 1:
            raise EvaluationError(f"source cohort {cohort_id} has conflicting product verdicts")
        authoritative_failed = any(
            record["authoritative"]["health"] != "healthy"
            or record["authoritative"]["failure_attempts"] > 0
            for record in representative_records
        )
        candidate_failed = any(
            record["candidate"]["health"] != "healthy"
            or record["candidate"]["failure_attempts"] > 0
            for record in representative_records
        )
        authoritative_failures += int(authoritative_failed)
        candidate_failures += int(candidate_failed)
        if authoritative_failed and not candidate_failed:
            candidate_reliability_wins += 1
        elif candidate_failed and not authoritative_failed:
            candidate_reliability_losses += 1
        if all(record["candidate"]["health"] == "healthy" for record in representative_records):
            candidate_durations.append(
                max(
                    (record["candidate"]["finished"] - record["ready_at"]).total_seconds()
                    for record in representative_records
                )
            )

    if representative_count != collection["representative_pull_count"]:
        raise EvaluationError("representative source-cohort count does not match the normalized export")
    if representative_count > collection["pull_count"]:
        raise EvaluationError("representative source-cohort count exceeds eligible events")
    successful_parity_count = validate_parity_export(
        canonical["parity_export"],
        cohort_records,
        source_key_by_cohort,
        collection,
        policy,
    )

    observation_days = (max(event_times) - min(event_times)).total_seconds() / 86400
    if observation_days < policy["minimum_days"]:
        raise EvaluationError("ready-PR observations do not span the policy minimum days")
    if len(candidate_durations) < policy["minimum_runs"]:
        raise EvaluationError("candidate has too few healthy ready-PR latency samples")
    if candidate_missing_trigger_events != 0:
        raise EvaluationError("candidate ready-PR trigger coverage is incomplete")
    candidate_p95 = nearest_rank_p95(candidate_durations)
    if candidate_p95 > policy["pr_p95"]:
        raise EvaluationError("candidate ready-PR end-to-end p95 exceeds policy")
    if false_greens > policy["false_green_max"]:
        raise EvaluationError("candidate produced a false green against independent product evidence")
    if source_mismatches > policy["source_mismatch_max"]:
        raise EvaluationError("a healthy provider validated the wrong source")
    if product_mismatches != 0:
        raise EvaluationError("provider product outcome diverged from independent product evidence")
    if missing_operational_observations != 0:
        raise EvaluationError("a healthy candidate run lacks its operational observation artifact")
    authoritative_rate = authoritative_failures / representative_count
    candidate_rate = candidate_failures / representative_count
    improvement = authoritative_rate - candidate_rate
    paired_p_value = one_sided_exact_mcnemar(
        candidate_reliability_wins, candidate_reliability_losses
    )
    if candidate_rate > policy["candidate_failure_rate_max"]:
        raise EvaluationError("candidate provider failure rate exceeds the absolute policy floor")
    if improvement < policy["failure_rate_improvement_min"]:
        raise EvaluationError("candidate is not materially more reliable than the authoritative provider")
    if paired_p_value > policy["paired_p_value_max"]:
        raise EvaluationError("paired reliability advantage is not statistically significant")

    main_pushes = ledger["main_pushes"]
    if not isinstance(main_pushes, list) or len(main_pushes) != collection["main_count"]:
        raise EvaluationError("main-push records do not cover every canonical main push")
    main_event_ids: set[str] = set()
    release_attempt_identities: set[tuple[str, str]] = set()
    testflight_build_ids: set[str] = set()
    delivery_durations: list[float] = []
    candidate_main_durations: list[float] = []
    main_event_times: list[datetime] = []
    eligible_delivery_count = 0
    latest_head_excluded_count = 0
    authoritative_main_failures = 0
    candidate_main_failures = 0
    candidate_main_missing_triggers = 0
    main_source_mismatches = 0
    main_product_mismatches = 0
    main_false_greens = 0
    missing_candidate_main_operational = 0
    main_push_keys = {
        "event_id",
        "sequence",
        "pushed_at",
        "expected_source",
        "product_verdict",
        "product_verdict_evidence_sha256",
        "authoritative",
        "candidate",
        "release_attempt_inventory",
        "release_eligibility_history",
        "selected_release_eligibility_sha256",
        "release_evidence",
    }
    delivery_scope: tuple[str, ...] | None = None
    build_numbers: set[str] = set()
    canonical_main_history: list[tuple[datetime, int, str]] = []
    for index, raw in enumerate(main_pushes):
        if not isinstance(raw, dict):
            raise EvaluationError(f"main_pushes[{index}] must be an object")
        sequence = require_integer(
            raw.get("sequence"), f"main_pushes[{index}].sequence", minimum=1
        )
        if sequence != index + 1:
            raise EvaluationError("canonical main sequence must be contiguous and ordered")
        pushed = require_timestamp(raw.get("pushed_at"), f"main_pushes[{index}].pushed_at")
        source = source_identity(
            raw.get("expected_source"), f"main_pushes[{index}].expected_source"
        )
        if canonical_main_history and pushed < canonical_main_history[-1][0]:
            raise EvaluationError("canonical main history must be timestamp ordered")
        canonical_main_history.append((pushed, sequence, source["sha"]))

    def latest_main_at(observed_at: datetime) -> str:
        eligible = [
            item for item in canonical_main_history if item[0] <= observed_at
        ]
        if not eligible:
            raise EvaluationError("latest-main evidence predates canonical main history")
        return max(eligible, key=lambda item: (item[0], item[1]))[2]

    for index, value in enumerate(main_pushes):
        field = f"main_pushes[{index}]"
        main_push = exact_object(value, main_push_keys, field)
        require_integer(main_push["sequence"], f"{field}.sequence", minimum=1)
        event_id = require_text(main_push["event_id"], f"{field}.event_id", identifier=True)
        if event_id in main_event_ids or event_id in event_ids:
            raise EvaluationError("canonical event IDs must be globally unique")
        main_event_ids.add(event_id)
        pushed_at = require_timestamp(main_push["pushed_at"], f"{field}.pushed_at")
        if not collection["window_start"] <= pushed_at <= collection["window_end"]:
            raise EvaluationError(f"{field} main event is outside the normalized export window")
        main_event_times.append(pushed_at)
        expected_source = source_identity(
            main_push["expected_source"], f"{field}.expected_source"
        )
        verdict = main_push["product_verdict"]
        if verdict not in PRODUCT_OUTCOMES:
            raise EvaluationError(f"{field}.product_verdict is unsupported")
        require_digest(
            main_push["product_verdict_evidence_sha256"],
            f"{field}.product_verdict_evidence_sha256",
        )
        authoritative_main = run_observation(
            main_push["authoritative"], f"{field}.authoritative"
        )
        candidate_main = run_observation(main_push["candidate"], f"{field}.candidate")
        validate_run_provenance(
            authoritative_main,
            f"{field}.authoritative",
            policy["authoritative"],
            policy,
            repository,
            settings_history,
            pushed_at,
            provider_bindings[policy["authoritative"]],
        )
        validate_run_provenance(
            candidate_main,
            f"{field}.candidate",
            policy["candidate"],
            policy,
            repository,
            settings_history,
            pushed_at,
            provider_bindings[policy["candidate"]],
        )
        for run, identities, provider_attempt_identities, trigger_ids, owner in (
            (
                authoritative_main,
                authoritative_ids,
                authoritative_provider_attempts,
                authoritative_trigger_ids,
                "authoritative",
            ),
            (
                candidate_main,
                candidate_ids,
                candidate_provider_attempts,
                candidate_trigger_ids,
                "candidate",
            ),
        ):
            if any(run_id in identities for run_id in run["attempt_ids"]):
                raise EvaluationError(f"{owner} main attempt IDs must be unique")
            identities.update(run["attempt_ids"])
            if any(identity in provider_attempt_identities for identity in run["provider_attempts"]):
                raise EvaluationError(f"{owner} raw main provider attempts must be unique")
            provider_attempt_identities.update(run["provider_attempts"])
            if run["trigger_id"] is not None:
                if run["trigger_id"] in trigger_ids:
                    raise EvaluationError(f"{owner} main trigger IDs must be one-to-one")
                trigger_ids.add(run["trigger_id"])
            if run["started"] is not None and run["started"] < pushed_at:
                raise EvaluationError(f"{field}.{owner} main run starts before its push")
            if run["finished"] is not None and run["finished"] > collection["exported"]:
                raise EvaluationError(f"{field}.{owner} main run finishes after the export")
            failed = run["health"] != "healthy" or run["failure_attempts"] > 0
            if owner == "authoritative":
                authoritative_main_failures += int(failed)
            else:
                candidate_main_failures += int(failed)
            if run["health"] == "healthy":
                if run["source"] != expected_source:
                    main_source_mismatches += 1
                if run["product"] != verdict:
                    main_product_mismatches += 1
        candidate_main_missing_triggers += int(candidate_main["coverage"] == "missing")
        if candidate_main["health"] == "healthy":
            assert candidate_main["finished"] is not None
            candidate_main_durations.append(
                (candidate_main["finished"] - pushed_at).total_seconds()
            )
            observed_sources.add(candidate_main["source"]["sha"])
            assert candidate_main["run_id"] is not None
            observed_candidate_runs[
                (candidate_main["source"]["sha"], candidate_main["run_id"])
            ] = {
                "finished": candidate_main["finished"],
                "settings_revision": candidate_main["settings_revision"],
                "scope": candidate_main["scope"],
            }
            if candidate_main["operational"] is None:
                missing_candidate_main_operational += 1
            if candidate_main["product"] == "passed" and verdict == "failed":
                main_false_greens += 1

        release_result = validate_testflight_release_history(
            main_push,
            field,
            expected_source,
            pushed_at,
            authoritative_main,
            collection,
            policy,
            repository,
            latest_main_at,
            release_attempt_identities,
            testflight_build_ids,
            build_numbers,
        )
        if not release_result["selected_eligible"] and (
            authoritative_main["health"] == "healthy"
            and authoritative_main["product"] == "passed"
        ):
            latest_head_excluded_count += 1
        eligible_delivery_count += release_result["delivery_count"]
        if release_result["delivery_duration"] is not None:
            delivery_durations.append(release_result["delivery_duration"])
        current_scope = release_result["delivery_scope"]
        if current_scope is not None:
            if delivery_scope is None:
                delivery_scope = current_scope
            elif delivery_scope != current_scope:
                raise EvaluationError("TestFlight delivery scope changed during observation")
    if eligible_delivery_count != collection["delivery_count"]:
        raise EvaluationError(
            "authenticated TestFlight receipt count differs from the canonical export"
        )
    if len(delivery_durations) != eligible_delivery_count:
        raise EvaluationError("one or more authenticated deliveries lacks a latency sample")
    if len(candidate_main_durations) < policy["minimum_runs"]:
        raise EvaluationError("candidate has too few healthy main latency samples")
    main_observation_days = (
        max(main_event_times) - min(main_event_times)
    ).total_seconds() / 86400
    if main_observation_days < policy["minimum_days"]:
        raise EvaluationError("main-push observations do not span the policy minimum days")
    candidate_main_p95 = nearest_rank_p95(candidate_main_durations)
    if candidate_main_p95 > policy["main_p95"]:
        raise EvaluationError("candidate main end-to-end p95 exceeds policy")
    if main_source_mismatches != 0 or main_product_mismatches != 0 or main_false_greens != 0:
        raise EvaluationError("candidate/authoritative main validation diverged from canonical evidence")
    if candidate_main_missing_triggers != 0:
        raise EvaluationError("candidate main trigger coverage is incomplete")
    if candidate_main_failures / len(main_pushes) > policy["candidate_failure_rate_max"]:
        raise EvaluationError("candidate main provider failure rate exceeds policy")
    if missing_candidate_main_operational != 0:
        raise EvaluationError("a healthy candidate main run lacks operational evidence")
    testflight_p95 = nearest_rank_p95(delivery_durations)
    if testflight_p95 > policy["testflight_p95"]:
        raise EvaluationError("green-main-to-TestFlight p95 exceeds policy")

    proofs = exact_object(ledger["proofs"], {"release_security", "atomic_rollback"}, "proofs")
    release_proof = validate_proof(
        proofs["release_security"],
        "proofs.release_security",
        {
            "status",
            "candidate_provider",
            "release_provider",
            "authorized_by",
            "executed_by",
            "authorization_reference",
            "observed_at",
            "source_sha",
            "candidate_run_id",
            "candidate_settings_revision",
            "repository",
            "candidate_provider_scope",
            "evidence_sha256",
        },
        observed_sources,
        observed_candidate_runs,
        collection["window_start"],
        collection["exported"],
        collection["settings_revision"],
        repository,
    )
    if (
        release_proof["candidate_provider"] != policy["candidate"]
        or release_proof["release_provider"] != policy["release_provider"]
    ):
        raise EvaluationError("release-security proof has the wrong provider boundary")
    rollback_proof = validate_proof(
        proofs["atomic_rollback"],
        "proofs.atomic_rollback",
        {
            "status",
            "from_provider",
            "to_provider",
            "atomic",
            "authorized_by",
            "executed_by",
            "authorization_reference",
            "observed_at",
            "source_sha",
            "candidate_run_id",
            "candidate_settings_revision",
            "repository",
            "candidate_provider_scope",
            "evidence_sha256",
        },
        observed_sources,
        observed_candidate_runs,
        collection["window_start"],
        collection["exported"],
        collection["settings_revision"],
        repository,
    )
    if (
        rollback_proof["from_provider"] != policy["candidate"]
        or rollback_proof["to_provider"] != policy["authoritative"]
        or require_bool(rollback_proof["atomic"], "proofs.atomic_rollback.atomic") is not True
    ):
        raise EvaluationError("rollback proof does not atomically restore the authoritative provider")

    return {
        "schema": REPORT_SCHEMA,
        "decision": OBSERVATION_DECISION,
        "eligible_for_external_review": False,
        "provenance_verified": False,
        "authority_change_applied": False,
        "blocking_requirements": list(policy["required_blockers"]),
        "repository": repository,
        "candidate_provider": policy["candidate"],
        "authoritative_provider": policy["authoritative"],
        "release_provider": policy["release_provider"],
        "candidate_settings_revision": collection["settings_revision"],
        "policy_sha256": policy["digest"],
        "ledger_sha256": canonical_digest(ledger),
        "normalized_export_and_proof_sha256": dict(sorted(export_digests.items())),
        "observations": {
            "eligible_ready_pull_request_events": len(pulls),
            "representative_source_cohorts": representative_count,
            "successful_parity_samples": successful_parity_count,
            "excluded_source_unavailable_merge_conflict_events": len(conflicts),
            "nonrepresentative_or_duplicate_trigger_events": len(pulls) - representative_count,
            "observation_days": observation_days,
            "candidate_pull_request_p95_seconds": candidate_p95,
            "false_green_count": false_greens,
            "source_mismatch_count": source_mismatches,
            "product_outcome_mismatch_count": product_mismatches,
            "authoritative_provider_failure_count": authoritative_failures,
            "authoritative_provider_failure_rate": authoritative_rate,
            "candidate_provider_failure_count": candidate_failures,
            "candidate_provider_failure_rate": candidate_rate,
            "candidate_missing_trigger_event_count": candidate_missing_trigger_events,
            "candidate_pull_request_healthy_latency_sample_count": len(candidate_durations),
            "provider_failure_rate_improvement": improvement,
            "paired_candidate_reliability_wins": candidate_reliability_wins,
            "paired_candidate_reliability_losses": candidate_reliability_losses,
            "paired_reliability_p_value": paired_p_value,
            "missing_operational_observation_count": missing_operational_observations,
            "eligible_main_push_events": len(main_pushes),
            "main_push_observation_days": main_observation_days,
            "authenticated_testflight_delivery_receipt_count": eligible_delivery_count,
            "authoritative_green_superseded_before_release_handoff_events": (
                latest_head_excluded_count
            ),
            "authoritative_main_provider_failure_count": authoritative_main_failures,
            "authoritative_main_provider_failure_rate": (
                authoritative_main_failures / len(main_pushes)
            ),
            "candidate_main_provider_failure_count": candidate_main_failures,
            "candidate_main_provider_failure_rate": candidate_main_failures / len(main_pushes),
            "candidate_main_missing_trigger_count": candidate_main_missing_triggers,
            "candidate_main_healthy_latency_sample_count": len(candidate_main_durations),
            "candidate_main_p95_seconds": candidate_main_p95,
            "main_source_mismatch_count": main_source_mismatches,
            "main_product_outcome_mismatch_count": main_product_mismatches,
            "missing_candidate_main_operational_observation_count": (
                missing_candidate_main_operational
            ),
            "green_main_to_testflight_p95_seconds": testflight_p95,
        },
        "proofs": {
            "release_security_evidence_sha256": release_proof["evidence_sha256"],
            "atomic_rollback_evidence_sha256": rollback_proof["evidence_sha256"],
        },
    }


def write_report_exclusive(path: Path, report: Mapping[str, Any]) -> None:
    if path.exists():
        raise EvaluationError("output path already exists; refusing to replace prior evidence")
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
            temporary = Path(handle.name)
        os.link(temporary, path)
    except FileExistsError as error:
        raise EvaluationError("output path appeared during evaluation") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def fake_export_digests() -> dict[str, str]:
    return {
        name: "sha256:" + hashlib.sha256(f"fixture:{name}".encode()).hexdigest()
        for name in sorted(set(EXPORT_NAMES) | PROOF_NAMES)
    }


def fixture_repository() -> dict[str, Any]:
    return {"slug": "example/tron", "id": 1001}


def fixture_provider_scope(
    provider: str, policy: Mapping[str, Any]
) -> dict[str, Any]:
    if provider == policy["candidate"]:
        organization_id, pipeline_id, cluster_id = (
            "buildkite-organization-1",
            "buildkite-pipeline-1",
            "buildkite-cluster-1",
        )
    else:
        organization_id, pipeline_id, cluster_id = (
            "github-organization-1",
            "github-workflow-ci",
            "github-hosted-runners",
        )
    return {
        "provider": provider,
        "organization_id": organization_id,
        "pipeline_id": pipeline_id,
        "cluster_id": cluster_id,
        "repository": fixture_repository(),
    }


def fixture_run_provenance(prefix: str, policy: Mapping[str, Any]) -> dict[str, Any]:
    provider = policy["candidate"] if prefix.startswith("candidate") else policy["authoritative"]
    return {
        "provider_scope": fixture_provider_scope(provider, policy),
        "policy_sha256": policy["digest"],
        "configuration_sha256": policy["configuration_digests"][provider],
        "bootstrap_sha256": policy["bootstrap_digests"][provider],
        "toolchain_sha256": policy["toolchain_digest"],
        "settings_revision": (
            "buildkite-settings-revision-1"
            if provider == policy["candidate"]
            else "github-settings-revision-1"
        ),
    }


def healthy_run(
    prefix: str,
    index: int,
    source: Mapping[str, str],
    ready: datetime,
    finish_seconds: float,
    *,
    operational: bool,
    policy: Mapping[str, Any],
) -> dict[str, Any]:
    return {
        **fixture_run_provenance(prefix, policy),
        "run_id": f"{prefix}-{index + 1}",
        "provider_run_id": f"{prefix}-{index + 1}",
        "provider_run_attempt": "1",
        "trigger_id": f"{prefix}-trigger-{index + 1}",
        "attempts": [
            {
                "canonical_attempt_id": f"{prefix}-{index + 1}",
                "run_id": f"{prefix}-{index + 1}",
                "run_attempt": "1",
            }
        ],
        "rebuilt_from_run_ids": [],
        "provider_failure_attempt_count": 0,
        "trigger_coverage": "present",
        "execution_health": "healthy",
        "product_outcome": "passed",
        "source": dict(source),
        "provider_started_at": (ready + timedelta(seconds=5)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "provider_finished_at": (ready + timedelta(seconds=finish_seconds)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "operational_observation_sha256": "sha256:" + "d" * 64 if operational else None,
        "validation_artifact_sha256": "sha256:"
        + hashlib.sha256(f"artifact:{prefix}:{index + 1}".encode()).hexdigest(),
    }


def missing_run(prefix: str, policy: Mapping[str, Any]) -> dict[str, Any]:
    return {
        **fixture_run_provenance(prefix, policy),
        "run_id": None,
        "provider_run_id": None,
        "provider_run_attempt": None,
        "trigger_id": None,
        "attempts": [],
        "rebuilt_from_run_ids": [],
        "provider_failure_attempt_count": 0,
        "trigger_coverage": "missing",
        "execution_health": "not_started",
        "product_outcome": None,
        "source": None,
        "provider_started_at": None,
        "provider_finished_at": None,
        "operational_observation_sha256": None,
        "validation_artifact_sha256": None,
    }


def superseded_run(
    prefix: str, index: int, observed_at: datetime, policy: Mapping[str, Any]
) -> dict[str, Any]:
    return {
        **fixture_run_provenance(prefix, policy),
        "run_id": f"{prefix}-{index + 1}",
        "provider_run_id": f"{prefix}-{index + 1}",
        "provider_run_attempt": "1",
        "trigger_id": f"{prefix}-trigger-{index + 1}",
        "attempts": [
            {
                "canonical_attempt_id": f"{prefix}-{index + 1}",
                "run_id": f"{prefix}-{index + 1}",
                "run_attempt": "1",
            }
        ],
        "rebuilt_from_run_ids": [],
        "provider_failure_attempt_count": 0,
        "trigger_coverage": "present",
        "execution_health": "superseded",
        "product_outcome": None,
        "source": None,
        "provider_started_at": observed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "provider_finished_at": (observed_at + timedelta(seconds=1)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "operational_observation_sha256": None,
        "validation_artifact_sha256": None,
    }


def fixture_artifact(document: dict[str, Any], artifact_name: str) -> dict[str, Any]:
    return {
        "evidence": document,
        "evidence_sha256": structured_json_file_digest(document),
        "artifact_path": f"build/release/{artifact_name}",
    }


def fixture_release_product(
    policy: Mapping[str, Any], owner_run_number: str
) -> dict[str, str]:
    return {
        "asc_app_id": policy["testflight_identity"]["app_id"],
        "scheme": policy["testflight_identity"]["scheme"],
        "configuration": policy["testflight_identity"]["configuration"],
        "canonical_version": "server-v1.2.3",
        "marketing_version": "1.2.3",
        "build_number": automatic_build_number(owner_run_number),
        "app_bundle_id": policy["testflight_identity"]["bundle_ids"][0],
        "extension_bundle_id": policy["testflight_identity"]["bundle_ids"][1],
    }


def fixture_release_chain(
    *,
    index: int,
    source_sha: str,
    ci_run_id: str,
    ci_run_number: str,
    eligible_records: list[dict[str, Any]],
    release_run_numbers: Mapping[str, str],
    available_at: datetime,
    policy: Mapping[str, Any],
    scenario: str,
) -> dict[str, Any]:
    evidence: dict[str, Any] = {
        "release_provider": policy["release_provider"],
        **{name: [] for name in RELEASE_EVIDENCE_SCHEMA},
    }
    if not eligible_records:
        return evidence
    if scenario not in {"first", "completed-rerun", "interrupted-resume"}:
        raise AssertionError(f"unsupported release fixture scenario {scenario}")

    repository = fixture_repository()["slug"]
    root_eligibility = eligible_records[0]
    root_release = root_eligibility["release"]
    root_release_identity = {
        "workflow_run_id": root_release["workflow_run_id"],
        "run_number": release_run_numbers[root_release["workflow_run_id"]],
        "run_attempt": root_release["run_attempt"],
    }
    owner = dict(root_release_identity)
    product = fixture_release_product(policy, owner["run_number"])
    intent_key = f"github-ci-run:{ci_run_id}"

    def make_intent(
        eligibility: Mapping[str, Any],
        state: str,
        previous: str | None,
        receipt: str | None,
        created_at: datetime,
    ) -> dict[str, Any]:
        release = eligibility["release"]
        return {
            "schema": "tron.ios-release-intent.v1",
            "repository": repository,
            "intent_key": intent_key,
            "source_sha": source_sha,
            "created_at": created_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "authoritative_ci": {
                "workflow_run_id": ci_run_id,
                "run_number": ci_run_number,
                "run_attempt": eligibility["authoritative_ci"]["run_attempt"],
                "completed_at": eligibility["authoritative_ci"]["completed_at"],
            },
            "product": dict(product),
            "owner": dict(owner),
            "release": {
                "workflow_run_id": release["workflow_run_id"],
                "run_number": release_run_numbers[release["workflow_run_id"]],
                "run_attempt": release["run_attempt"],
            },
            "resolution": {
                "state": state,
                "previous_intent_sha256": previous,
                "completion_receipt_sha256": receipt,
            },
        }

    def make_head(
        eligibility: Mapping[str, Any], checked_at: datetime
    ) -> dict[str, Any]:
        return {
            "schema": "tron.ios-release-head-check.v1",
            "repository": repository,
            "source_sha": source_sha,
            "current_main_sha": source_sha,
            "source_is_current_main": True,
            "checked_at": checked_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "authoritative_ci": {
                "workflow_run_id": ci_run_id,
                "run_attempt": eligibility["authoritative_ci"]["run_attempt"],
                "completed_at": eligibility["authoritative_ci"]["completed_at"],
            },
            "release": dict(eligibility["release"]),
        }

    def make_provenance(eligibility: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "schema": "tron.ios-release-provenance.v1",
            "source_sha": source_sha,
            "github": {
                "run_id": eligibility["release"]["workflow_run_id"],
                "run_attempt": eligibility["release"]["run_attempt"],
            },
            "toolchain": {
                "xcode_version": "27.0",
                "xcode_build": "27A100",
                "sdk": "iphoneos27.0",
                "deployment_target": "17.0",
            },
            "product": {
                "canonical_version": product["canonical_version"],
                "marketing_version": product["marketing_version"],
                "build_number": product["build_number"],
                "app_bundle_id": product["app_bundle_id"],
                "extension_bundle_id": product["extension_bundle_id"],
                "app_executable_sha256": "a" * 64,
                "share_extension_executable_sha256": "b" * 64,
                "ipa_sha256": "c" * 64,
            },
        }

    def make_admission(
        intent: Mapping[str, Any],
        intent_digest: str,
        provenance_digest: str,
        head_digest: str,
        prior_admission_digest: str | None,
        reuse_digest: str | None,
        admitted_at: datetime,
    ) -> dict[str, Any]:
        return {
            "schema": "tron.ios-release-admission.v1",
            "repository": repository,
            "intent_key": intent_key,
            "source_sha": source_sha,
            "product": dict(product),
            "owner": dict(owner),
            "asc": {
                "app_id": product["asc_app_id"],
                "build_id": f"asc-build-{index + 1}",
            },
            "evidence": {
                "intent_sha256": intent_digest,
                "release_provenance_sha256": provenance_digest,
                "head_check_sha256": head_digest,
                "prior_admission_sha256": prior_admission_digest,
                "reuse_provenance_sha256": reuse_digest,
            },
            "producer": dict(intent["release"]),
            "admitted_at": admitted_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

    def make_receipt(
        intent: Mapping[str, Any],
        intent_digest: str,
        admission_digest: str,
        provenance_digest: str,
        head_digest: str,
        reuse_digest: str | None,
    ) -> dict[str, Any]:
        return {
            "schema": "tron.ios-release-receipt.v1",
            "repository": repository,
            "intent_key": intent_key,
            "source_sha": source_sha,
            "authoritative_ci": {
                "workflow_run_id": ci_run_id,
                "run_number": ci_run_number,
            },
            "product": dict(product),
            "owner": dict(owner),
            "delivery": {
                "channel": policy["testflight_channel"],
                "asc_build_id": f"asc-build-{index + 1}",
                "testflight_group_id": "internal-testers",
                "completed_at": available_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
            "evidence": {
                "intent_sha256": intent_digest,
                "admission_sha256": admission_digest,
                "release_provenance_sha256": provenance_digest,
                "head_check_sha256": head_digest,
                "reuse_provenance_sha256": reuse_digest,
            },
            "producer": dict(intent["release"]),
        }

    root_checked = require_timestamp(root_eligibility["checked_at"], "fixture.checked_at")
    root_intent = make_intent(
        root_eligibility, "new", None, None, root_checked + timedelta(seconds=1)
    )
    root_intent_wrapper = fixture_artifact(root_intent, "ios-release-intent.json")
    root_intent_digest = root_intent_wrapper["evidence_sha256"]
    root_head = make_head(root_eligibility, root_checked + timedelta(seconds=2))
    root_head_wrapper = fixture_artifact(root_head, "ios-release-head-check.json")
    root_provenance = make_provenance(root_eligibility)
    root_provenance_wrapper = fixture_artifact(
        root_provenance, "ios-release-provenance.json"
    )
    root_admission = make_admission(
        root_intent,
        root_intent_digest,
        root_provenance_wrapper["evidence_sha256"],
        root_head_wrapper["evidence_sha256"],
        None,
        None,
        root_checked + timedelta(seconds=3),
    )
    root_admission_wrapper = fixture_artifact(
        root_admission, "ios-release-admission.json"
    )
    evidence["intents"].append(root_intent_wrapper)
    evidence["head_checks"].append(root_head_wrapper)
    evidence["release_provenance"].append(root_provenance_wrapper)
    evidence["admissions"].append(root_admission_wrapper)

    receipt_intent = root_intent
    receipt_intent_digest = root_intent_digest
    receipt_head_digest = root_head_wrapper["evidence_sha256"]
    receipt_admission_digest = root_admission_wrapper["evidence_sha256"]
    receipt_reuse_digest = None

    if scenario == "interrupted-resume":
        resume_eligibility = eligible_records[1]
        resume_checked = require_timestamp(
            resume_eligibility["checked_at"], "fixture.resume_checked_at"
        )
        resume_intent = make_intent(
            resume_eligibility,
            "resume",
            root_intent_digest,
            None,
            resume_checked + timedelta(seconds=1),
        )
        resume_intent_wrapper = fixture_artifact(
            resume_intent, "ios-release-intent.json"
        )
        resume_head = make_head(
            resume_eligibility, resume_checked + timedelta(seconds=2)
        )
        resume_head_wrapper = fixture_artifact(
            resume_head, "ios-release-head-check.json"
        )
        reuse = {
            "schema": "tron.ios-release-reuse-provenance.v1",
            "repository": repository,
            "intent_key": intent_key,
            "source_sha": source_sha,
            "product": {
                "canonical_version": product["canonical_version"],
                "marketing_version": product["marketing_version"],
                "build_number": product["build_number"],
                "app_bundle_id": product["app_bundle_id"],
                "extension_bundle_id": product["extension_bundle_id"],
                "ipa_sha256": root_provenance["product"]["ipa_sha256"],
            },
            "asc": dict(root_admission["asc"]),
            "owner": dict(owner),
            "original": {
                "workflow_run_id": root_provenance["github"]["run_id"],
                "run_attempt": root_provenance["github"]["run_attempt"],
                "provenance_sha256": root_provenance_wrapper["evidence_sha256"],
                "intent_sha256": root_intent_digest,
                "admission_sha256": root_admission_wrapper["evidence_sha256"],
            },
            "consumer": {
                **resume_intent["release"],
                "intent_sha256": resume_intent_wrapper["evidence_sha256"],
            },
        }
        reuse_wrapper = fixture_artifact(reuse, "ios-release-reuse-provenance.json")
        resume_admission = make_admission(
            resume_intent,
            resume_intent_wrapper["evidence_sha256"],
            root_provenance_wrapper["evidence_sha256"],
            resume_head_wrapper["evidence_sha256"],
            root_admission_wrapper["evidence_sha256"],
            reuse_wrapper["evidence_sha256"],
            resume_checked + timedelta(seconds=3),
        )
        resume_admission_wrapper = fixture_artifact(
            resume_admission, "ios-release-admission.json"
        )
        evidence["intents"].append(resume_intent_wrapper)
        evidence["head_checks"].append(resume_head_wrapper)
        evidence["reuse_provenance"].append(reuse_wrapper)
        evidence["admissions"].append(resume_admission_wrapper)
        receipt_intent = resume_intent
        receipt_intent_digest = resume_intent_wrapper["evidence_sha256"]
        receipt_head_digest = resume_head_wrapper["evidence_sha256"]
        receipt_admission_digest = resume_admission_wrapper["evidence_sha256"]
        receipt_reuse_digest = reuse_wrapper["evidence_sha256"]

    receipt = make_receipt(
        receipt_intent,
        receipt_intent_digest,
        receipt_admission_digest,
        root_provenance_wrapper["evidence_sha256"],
        receipt_head_digest,
        receipt_reuse_digest,
    )
    receipt_wrapper = fixture_artifact(receipt, "ios-release-receipt.json")
    evidence["receipts"].append(receipt_wrapper)

    if scenario == "completed-rerun":
        completed_eligibility = eligible_records[1]
        completed_checked = require_timestamp(
            completed_eligibility["checked_at"], "fixture.completed_checked_at"
        )
        completed_intent = make_intent(
            completed_eligibility,
            "completed",
            root_intent_digest,
            receipt_wrapper["evidence_sha256"],
            max(completed_checked, available_at) + timedelta(seconds=1),
        )
        evidence["intents"].append(
            fixture_artifact(completed_intent, "ios-release-intent.json")
        )
    return evidence


def valid_fixture(policy: Mapping[str, Any], exports: Mapping[str, str]) -> dict[str, Any]:
    count = policy["minimum_runs"]
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    span_seconds = policy["minimum_days"] * 86400
    pulls = []
    for index in range(count):
        offset = round(index * span_seconds / (count - 1)) if count > 1 else span_seconds
        ready = start + timedelta(seconds=offset)
        source = {"sha": f"{index + 1:040x}", "tree": f"{index + 1001:040x}"}
        authoritative = healthy_run(
            "authoritative-pr", index, source, ready, 120, operational=False, policy=policy
        )
        if index < 5:
            provider_run_id = authoritative["provider_run_id"]
            first_attempt = f"{provider_run_id}:1"
            final_attempt = f"{provider_run_id}:2"
            authoritative["run_id"] = final_attempt
            authoritative["provider_run_attempt"] = "2"
            authoritative["attempts"] = [
                {
                    "canonical_attempt_id": first_attempt,
                    "run_id": provider_run_id,
                    "run_attempt": "1",
                },
                {
                    "canonical_attempt_id": final_attempt,
                    "run_id": provider_run_id,
                    "run_attempt": "2",
                },
            ]
            authoritative["rebuilt_from_run_ids"] = [first_attempt]
            authoritative["provider_failure_attempt_count"] = 1
        pulls.append(
            {
                "event_id": f"ready-event-{index + 1}",
                "delivery_id": f"webhook-delivery-{index + 1}",
                "action": "opened",
                "pull_request_key": f"pull-request-{index + 1}",
                "source_cohort_id": f"source-cohort-{index + 1}",
                "ready_at": ready.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "superseded_by_event_id": None,
                "expected_source": source,
                "product_verdict": "passed",
                "product_verdict_evidence_sha256": "sha256:" + "e" * 64,
                "authoritative": authoritative,
                "candidate": healthy_run(
                    "candidate-pr",
                    index,
                    source,
                    ready,
                    max(10, policy["pr_p95"] - 1),
                    operational=True,
                    policy=policy,
                ),
            }
        )
    main_count = count + 2
    main_pushes = []
    for index in range(main_count):
        offset = round(index * span_seconds / (main_count - 1))
        pushed = start + timedelta(seconds=offset)
        authoritative_finish_seconds = 120
        if index == 1:
            next_offset = round((index + 1) * span_seconds / (main_count - 1))
            authoritative_finish_seconds = next_offset - offset + 120
        elif index == 2:
            # Leave enough time for attempt 1 to deliver before a successful
            # upstream rerun resolves through a completed intent.
            authoritative_finish_seconds = 1800
        completed = pushed + timedelta(seconds=authoritative_finish_seconds)
        main_source = {
            "sha": f"{index + 5001:040x}",
            "tree": f"{index + 7001:040x}",
        }
        authoritative_main = healthy_run(
            "authoritative-main",
            index,
            main_source,
            pushed,
            authoritative_finish_seconds,
            operational=False,
            policy=policy,
        )
        authoritative_workflow_run_id = str(100000 + index)
        authoritative_main["provider_run_id"] = authoritative_workflow_run_id
        authoritative_main["provider_run_attempt"] = "1"
        authoritative_main["run_id"] = f"{authoritative_workflow_run_id}:1"
        authoritative_main["attempts"] = [
            {
                "canonical_attempt_id": authoritative_main["run_id"],
                "run_id": authoritative_workflow_run_id,
                "run_attempt": "1",
            }
        ]
        if index == 0:
            authoritative_main["provider_failure_attempt_count"] = 1
            authoritative_main["execution_health"] = "provider_failed"
            authoritative_main["product_outcome"] = None
            authoritative_main["source"] = None
            authoritative_main["validation_artifact_sha256"] = None
        elif index in {2, 3}:
            first_attempt = f"{authoritative_workflow_run_id}:1"
            final_attempt = f"{authoritative_workflow_run_id}:2"
            authoritative_main["run_id"] = final_attempt
            authoritative_main["provider_run_attempt"] = "2"
            authoritative_main["attempts"] = [
                {
                    "canonical_attempt_id": first_attempt,
                    "run_id": authoritative_workflow_run_id,
                    "run_attempt": "1",
                },
                {
                    "canonical_attempt_id": final_attempt,
                    "run_id": authoritative_workflow_run_id,
                    "run_attempt": "2",
                },
            ]
            authoritative_main["rebuilt_from_run_ids"] = [first_attempt]
            authoritative_main["provider_failure_attempt_count"] = int(index == 3)

        release_specs: list[dict[str, Any]] = []
        if index == 2:
            first_completed = pushed + timedelta(seconds=120)
            release_specs = [
                {
                    "ci_attempt": "1",
                    "conclusion": "success",
                    "completed_at": first_completed,
                    "release_run_id": str(200000 + index),
                    "release_attempt": "1",
                    "checked_at": first_completed + timedelta(seconds=1),
                    "observed_main_sha": main_source["sha"],
                },
                {
                    "ci_attempt": "2",
                    "conclusion": "success",
                    "completed_at": completed,
                    "release_run_id": str(300000 + index),
                    "release_attempt": "1",
                    "checked_at": completed + timedelta(seconds=1),
                    "observed_main_sha": main_source["sha"],
                },
            ]
        elif index == 3:
            first_completed = completed - timedelta(seconds=60)
            release_specs = [
                {
                    "ci_attempt": "1",
                    "conclusion": "failure",
                    "completed_at": first_completed,
                    "release_run_id": str(300000 + index),
                    "release_attempt": "1",
                    "checked_at": first_completed + timedelta(seconds=1),
                    "observed_main_sha": main_source["sha"],
                },
                {
                    "ci_attempt": "2",
                    "conclusion": "success",
                    "completed_at": completed,
                    "release_run_id": str(200000 + index),
                    "release_attempt": "1",
                    "checked_at": completed + timedelta(seconds=1),
                    "observed_main_sha": main_source["sha"],
                },
            ]
        elif index == 4:
            release_specs = [
                {
                    "ci_attempt": "1",
                    "conclusion": "success",
                    "completed_at": completed,
                    "release_run_id": str(200000 + index),
                    "release_attempt": "1",
                    "checked_at": completed + timedelta(seconds=1),
                    "observed_main_sha": main_source["sha"],
                },
                {
                    "ci_attempt": "1",
                    "conclusion": "success",
                    "completed_at": completed,
                    "release_run_id": str(200000 + index),
                    "release_attempt": "2",
                    "checked_at": completed + timedelta(seconds=5),
                    "observed_main_sha": main_source["sha"],
                },
            ]
        else:
            release_specs = [
                {
                    "ci_attempt": "1",
                    "conclusion": "failure" if index == 0 else "success",
                    "completed_at": completed,
                    "release_run_id": str(200000 + index),
                    "release_attempt": "1",
                    "checked_at": completed + timedelta(seconds=1),
                    "observed_main_sha": (
                        f"{index + 5002:040x}" if index == 1 else main_source["sha"]
                    ),
                }
            ]

        release_eligibility_history: list[dict[str, Any]] = []
        release_run_numbers: dict[str, str] = {}
        for spec_index, spec in enumerate(release_specs):
            release_run_numbers.setdefault(
                spec["release_run_id"], str(1000 + index * 10 + spec_index)
            )
            eligible = (
                spec["conclusion"] == "success"
                and spec["observed_main_sha"] == main_source["sha"]
            )
            eligibility = {
                "schema": "tron.ios-release-eligibility.v1",
                "repository": fixture_repository()["slug"],
                "source_sha": main_source["sha"],
                "observed_main_sha": spec["observed_main_sha"],
                "checked_at": spec["checked_at"].strftime("%Y-%m-%dT%H:%M:%SZ"),
                "eligible": eligible,
                "authoritative_ci": {
                    "workflow_run_id": authoritative_workflow_run_id,
                    "run_attempt": spec["ci_attempt"],
                    "event": "push",
                    "branch": policy["main_branch"],
                    "conclusion": spec["conclusion"],
                    "completed_at": spec["completed_at"].strftime(
                        "%Y-%m-%dT%H:%M:%SZ"
                    ),
                },
                "release": {
                    "workflow_run_id": spec["release_run_id"],
                    "run_attempt": spec["release_attempt"],
                },
            }
            release_eligibility_history.append(
                fixture_artifact(eligibility, "ios-release-eligibility.json")
            )

        eligible_records = [
            wrapper["evidence"]
            for wrapper in release_eligibility_history
            if wrapper["evidence"]["eligible"]
        ]
        release_attempt_inventory = [
            {
                "authoritative_ci": {
                    "workflow_run_id": wrapper["evidence"]["authoritative_ci"][
                        "workflow_run_id"
                    ],
                    "run_attempt": wrapper["evidence"]["authoritative_ci"][
                        "run_attempt"
                    ],
                },
                "release": dict(wrapper["evidence"]["release"]),
            }
            for wrapper in release_eligibility_history
        ]
        if index == 2:
            scenario = "completed-rerun"
            first_completed = require_timestamp(
                eligible_records[0]["authoritative_ci"]["completed_at"],
                "fixture.first_ci_completed_at",
            )
            available_at = first_completed + timedelta(
                seconds=max(0, policy["testflight_p95"] - 1)
            )
        else:
            scenario = "interrupted-resume" if index == 4 else "first"
            available_at = completed + timedelta(
                seconds=max(0, policy["testflight_p95"] - 1)
            )
        release_evidence = fixture_release_chain(
            index=index,
            source_sha=main_source["sha"],
            ci_run_id=authoritative_workflow_run_id,
            ci_run_number=str(5000 + index),
            eligible_records=eligible_records,
            release_run_numbers=release_run_numbers,
            available_at=available_at,
            policy=policy,
            scenario=scenario,
        )
        main_pushes.append(
            {
                "event_id": f"main-push-{index + 1}",
                "sequence": index + 1,
                "pushed_at": pushed.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "expected_source": main_source,
                "product_verdict": "passed",
                "product_verdict_evidence_sha256": "sha256:" + "c" * 64,
                "authoritative": authoritative_main,
                "candidate": healthy_run(
                    "candidate-main",
                    index,
                    main_source,
                    pushed,
                    max(10, policy["main_p95"] - 1),
                    operational=True,
                    policy=policy,
                ),
                "release_attempt_inventory": release_attempt_inventory,
                "release_eligibility_history": release_eligibility_history,
                "selected_release_eligibility_sha256": release_eligibility_history[-1][
                    "evidence_sha256"
                ],
                "release_evidence": release_evidence,
            }
        )
    proof_source = pulls[-1]["candidate"]["source"]["sha"]
    proof_run_id = pulls[-1]["candidate"]["run_id"]
    exported = start + timedelta(days=max(policy["minimum_days"], count) + 1)
    return {
        "schema": LEDGER_SCHEMA,
        "policy_sha256": policy["digest"],
        "repository": fixture_repository(),
        "candidate_provider": policy["candidate"],
        "collection": {
            "method": COLLECTION_METHOD,
            "exported_at": exported.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "window_started_at": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "window_ended_at": (start + timedelta(days=policy["minimum_days"])).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            ),
            "eligible_ready_pull_request_event_count": count,
            "representative_source_cohort_count": count,
            "eligible_main_push_event_count": main_count,
            "eligible_testflight_delivery_count": count,
            "excluded_source_unavailable_merge_conflict_count": 1,
            "successful_parity_sample_count": count,
            **{field: exports[name] for name, field in EXPORT_NAMES.items()},
            "candidate_settings_revision": "buildkite-settings-revision-1",
            "candidate_settings_attestation": {
                "repository_pipeline_sha256": file_digest(BOOTSTRAP_PATH),
                "repository_shadow_steps_sha256": file_digest(SHADOW_STEPS_PATH),
                "toolchain_sha256": file_digest(TOOLCHAIN_PATH),
                "provider_id": "github",
                "provider_webhook_url_present": True,
                "trigger_mode": "code",
                "filter_enabled": False,
                "publish_commit_status": False,
                "publish_commit_status_per_step": False,
                "publish_blocked_as_pending": False,
                "separate_pull_request_statuses": False,
                "build_pull_request_forks": False,
                "build_tags": False,
                "queue_secrets_attached": False,
                "pipeline_secrets_attached": False,
                "cluster_secrets_attached": False,
                "organization_secrets_attached": False,
                "release_runner_access": False,
                "allowed_queues": ["linux-medium", "macos-medium"],
                "build_pull_requests": True,
                "build_pull_request_merge_commits": False,
                "build_pull_request_ready_for_review": True,
                "build_pull_request_reopened": True,
                "build_pull_request_base_branch_changed": False,
                "build_pull_request_labels_changed": False,
                "build_pull_request_edited": False,
                "build_pull_request_converted_to_draft": False,
                "build_pull_request_review_requested": False,
                "build_check_run_completed": False,
                "build_pull_request_review_submitted": False,
                "build_pull_request_review_dismissed": False,
                "build_release_published": False,
                "build_release_created": False,
                "build_release_released": False,
                "build_issue_comment_created": False,
                "build_deployment_status_created": False,
                "build_pull_request_review_comment_created": False,
                "build_pull_request_dequeued": False,
                "build_create_event": False,
                "build_merge_group_checks_requested": False,
                "skip_builds_for_closed_pull_requests": False,
                "pull_request_branch_filter_enabled": False,
                "build_branches": True,
                "branch_configuration": "main",
                "skip_builds_for_existing_commits": False,
                "skip_pull_request_builds_for_existing_commits": False,
                "workflow_dispatch_parity_implemented": False,
                "skip_queued_branch_builds": True,
                "skip_queued_branch_builds_filter": "!main",
                "cancel_running_branch_builds": True,
                "cancel_running_branch_builds_filter": "!main",
            },
            "candidate_provider_scope": fixture_provider_scope(policy["candidate"], policy),
            "authority_ruleset_id": 4242,
        },
        "ready_pull_requests": pulls,
        "source_unavailable_merge_conflicts": [
            {
                "event_id": "merge-conflict-event-1",
                "delivery_id": "merge-conflict-delivery-1",
                "action": "synchronize",
                "pull_request_key": "pull-request-conflict-1",
                "ready_at": (start + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "head_sha": "f" * 40,
                "exclusion_reason": MERGE_CONFLICT_EXCLUSION,
                "evidence_sha256": "sha256:" + "6" * 64,
            }
        ],
        "main_pushes": main_pushes,
        "proofs": {
            "release_security": {
                "status": "passed",
                "candidate_provider": policy["candidate"],
                "release_provider": policy["release_provider"],
                "authorized_by": "reviewer-a",
                "executed_by": "operator-b",
                "authorization_reference": "release-security-proof-1",
                "observed_at": (exported - timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "source_sha": proof_source,
                "candidate_run_id": proof_run_id,
                "candidate_settings_revision": "buildkite-settings-revision-1",
                "repository": fixture_repository(),
                "candidate_provider_scope": fixture_provider_scope(
                    policy["candidate"], policy
                ),
                "evidence_sha256": "sha256:" + "a" * 64,
            },
            "atomic_rollback": {
                "status": "passed",
                "from_provider": policy["candidate"],
                "to_provider": policy["authoritative"],
                "atomic": True,
                "authorized_by": "reviewer-c",
                "executed_by": "operator-d",
                "authorization_reference": "atomic-rollback-proof-1",
                "observed_at": (exported - timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "source_sha": proof_source,
                "candidate_run_id": proof_run_id,
                "candidate_settings_revision": "buildkite-settings-revision-1",
                "repository": fixture_repository(),
                "candidate_provider_scope": fixture_provider_scope(
                    policy["candidate"], policy
                ),
                "evidence_sha256": "sha256:" + "b" * 64,
            },
        },
    }


def fixture_export_documents(
    ledger: Mapping[str, Any], policy: Mapping[str, Any]
) -> dict[str, Any]:
    exported_at = ledger["collection"]["exported_at"]
    source_digests = {
        name: "sha256:" + hashlib.sha256(f"source:{name}".encode()).hexdigest()
        for name in sorted(EXPORT_NAMES)
    }
    parity_by_cohort: dict[str, dict[str, Any]] = {}
    for item in ledger["ready_pull_requests"]:
        if (
            item["superseded_by_event_id"] is not None
            or item["product_verdict"] != "passed"
            or item["authoritative"]["execution_health"] != "healthy"
            or item["candidate"]["execution_health"] != "healthy"
        ):
            continue
        record = parity_by_cohort.setdefault(
            item["source_cohort_id"],
            {
                "source_cohort_id": item["source_cohort_id"],
                "event_ids": [],
                "source": copy.deepcopy(item["expected_source"]),
                "authoritative_run_ids": [],
                "candidate_run_ids": [],
                "status": "passed",
                "evidence_sha256": "sha256:" + "1" * 64,
                "authoritative_artifacts": [],
                "candidate_artifacts": [],
            },
        )
        record["event_ids"].append(item["event_id"])
        record["authoritative_run_ids"].append(item["authoritative"]["run_id"])
        record["candidate_run_ids"].append(item["candidate"]["run_id"])
        record["authoritative_artifacts"].append(
            {
                "run_id": item["authoritative"]["run_id"],
                "artifact_sha256": item["authoritative"]["validation_artifact_sha256"],
            }
        )
        record["candidate_artifacts"].append(
            {
                "run_id": item["candidate"]["run_id"],
                "artifact_sha256": item["candidate"]["validation_artifact_sha256"],
            }
        )
    for record in parity_by_cohort.values():
        record["evidence_sha256"] = parity_evidence_digest(record)
    documents = {
        "event": {
            "schema": EXPORT_SCHEMAS["event"],
            "source": "provider-api",
            "source_response_sha256": source_digests["event"],
            "exported_at": exported_at,
            "window_started_at": ledger["collection"]["window_started_at"],
            "window_ended_at": ledger["collection"]["window_ended_at"],
            "pull_request_eligibility_contract": PULL_REQUEST_ELIGIBILITY,
            "main_push_eligibility_contract": MAIN_PUSH_ELIGIBILITY,
            "included_actions": ORDERED_EVENT_ACTIONS,
            "source_unavailable_policy": SOURCE_UNAVAILABLE_POLICY,
            "source_unavailable_merge_conflicts": copy.deepcopy(
                ledger["source_unavailable_merge_conflicts"]
            ),
            "ready_pull_requests": [
                {
                    "event_id": item["event_id"],
                    "delivery_id": item["delivery_id"],
                    "action": item["action"],
                    "pull_request_key": item["pull_request_key"],
                    "source_cohort_id": item["source_cohort_id"],
                    "ready_at": item["ready_at"],
                    "superseded_by_event_id": item["superseded_by_event_id"],
                    "expected_source": item["expected_source"],
                }
                for item in ledger["ready_pull_requests"]
            ],
            "main_pushes": [
                {
                    "event_id": item["event_id"],
                    "sequence": item["sequence"],
                    "pushed_at": item["pushed_at"],
                    "expected_source": item["expected_source"],
                }
                for item in ledger["main_pushes"]
            ],
        },
        "authoritative": {
            "schema": EXPORT_SCHEMAS["authoritative"],
            "source": "provider-api",
            "source_response_sha256": source_digests["authoritative"],
            "provider": policy["authoritative"],
            "provider_scope": fixture_provider_scope(policy["authoritative"], policy),
            "settings_revision": "github-settings-revision-1",
            "exported_at": exported_at,
            "runs": [
                {"event_id": item["event_id"], "observation": item["authoritative"]}
                for item in ledger["ready_pull_requests"]
            ],
            "main_runs": [
                {"event_id": item["event_id"], "observation": item["authoritative"]}
                for item in ledger["main_pushes"]
            ],
        },
        "candidate": {
            "schema": EXPORT_SCHEMAS["candidate"],
            "source": "provider-api",
            "source_response_sha256": source_digests["candidate"],
            "provider": policy["candidate"],
            "provider_scope": fixture_provider_scope(policy["candidate"], policy),
            "settings_revision": ledger["collection"]["candidate_settings_revision"],
            "exported_at": exported_at,
            "runs": [
                {"event_id": item["event_id"], "observation": item["candidate"]}
                for item in ledger["ready_pull_requests"]
            ],
            "main_runs": [
                {"event_id": item["event_id"], "observation": item["candidate"]}
                for item in ledger["main_pushes"]
            ],
        },
        "product_verdict": {
            "schema": EXPORT_SCHEMAS["product_verdict"],
            "source": "independent-product-evidence",
            "source_response_sha256": source_digests["product_verdict"],
            "exported_at": exported_at,
            "verdicts": [
                {
                    "event_id": item["event_id"],
                    "product_verdict": item["product_verdict"],
                    "product_verdict_evidence_sha256": item[
                        "product_verdict_evidence_sha256"
                    ],
                }
                for item in ledger["ready_pull_requests"]
            ],
            "main_verdicts": [
                {
                    "event_id": item["event_id"],
                    "product_verdict": item["product_verdict"],
                    "product_verdict_evidence_sha256": item[
                        "product_verdict_evidence_sha256"
                    ],
                }
                for item in ledger["main_pushes"]
            ],
        },
        "testflight": {
            "schema": EXPORT_SCHEMAS["testflight"],
            "source": "provider-api",
            "source_response_sha256": source_digests["testflight"],
            "release_provider": policy["release_provider"],
            "exported_at": exported_at,
            "release_eligibility": [
                {
                    "event_id": item["event_id"],
                    "sequence": item["sequence"],
                    "main_sha": item["expected_source"]["sha"],
                    "release_attempt_inventory": item["release_attempt_inventory"],
                    "history": item["release_eligibility_history"],
                    "selected_evidence_sha256": item[
                        "selected_release_eligibility_sha256"
                    ],
                }
                for item in ledger["main_pushes"]
            ],
            "release_evidence": [
                {"event_id": item["event_id"], **item["release_evidence"]}
                for item in ledger["main_pushes"]
            ],
        },
        "candidate_settings": {
            "schema": EXPORT_SCHEMAS["candidate_settings"],
            "source": "provider-audit-api",
            "source_response_sha256": source_digests["candidate_settings"],
            "provider": policy["candidate"],
            "exported_at": exported_at,
            "current_revision": ledger["collection"]["candidate_settings_revision"],
            "provider_scope": copy.deepcopy(
                ledger["collection"]["candidate_provider_scope"]
            ),
            "audit_history": [
                {
                    "audit_event_id": "candidate-settings-audit-1",
                    "audit_event_sha256": "sha256:" + "5" * 64,
                    "revision": ledger["collection"]["candidate_settings_revision"],
                    "effective_from": ledger["collection"]["window_started_at"],
                    "effective_until": exported_at,
                    "provider_scope": copy.deepcopy(
                        ledger["collection"]["candidate_provider_scope"]
                    ),
                    "attestation": copy.deepcopy(
                        ledger["collection"]["candidate_settings_attestation"]
                    ),
                }
            ],
        },
        "authority_ruleset": {
            "schema": EXPORT_SCHEMAS["authority_ruleset"],
            "source": "provider-api",
            "source_response_sha256": source_digests["authority_ruleset"],
            "provider": policy["authoritative"],
            "exported_at": exported_at,
            "ruleset_id": ledger["collection"]["authority_ruleset_id"],
            "name": "main-protection",
            "target": "branch",
            "enforcement": "active",
            "default_branch": policy["main_branch"],
            "branch_includes": ["~DEFAULT_BRANCH"],
            "branch_excludes": [],
            "required_status_checks": {
                "strict": True,
                "checks": [{"context": "CI summary", "integration_id": 15368}],
            },
            "bypass_actors": [],
            "pull_request_requirement": {"required": True},
            "forbidden_metadata_patterns": FORBIDDEN_CI_SKIP_PATTERNS,
        },
        "parity": {
            "schema": EXPORT_SCHEMAS["parity"],
            "source": "independent-parity-evidence",
            "source_response_sha256": source_digests["parity"],
            "exported_at": exported_at,
            "records": list(parity_by_cohort.values()),
        },
    }
    for name in EXPORT_NAMES:
        documents[name]["repository"] = copy.deepcopy(ledger["repository"])
    for name in sorted(PROOF_NAMES):
        documents[name] = {
            "schema": EXPORT_SCHEMAS[name],
            "kind": name,
            **{
                key: value
                for key, value in ledger["proofs"][name].items()
                if key != "evidence_sha256"
            },
        }
    return documents


def valid_fixture_inputs(
    policy: Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, str], dict[str, Any]]:
    ledger = valid_fixture(policy, fake_export_digests())
    digests, documents = bind_fixture_inputs(ledger, policy)
    return ledger, digests, documents


def bind_fixture_inputs(
    ledger: dict[str, Any], policy: Mapping[str, Any]
) -> tuple[dict[str, str], dict[str, Any]]:
    documents = fixture_export_documents(ledger, policy)
    digests = {name: canonical_digest(document) for name, document in documents.items()}
    for name, field in EXPORT_NAMES.items():
        ledger["collection"][field] = digests[name]
    for name in PROOF_NAMES:
        ledger["proofs"][name]["evidence_sha256"] = digests[name]
    return digests, documents


def expect_ineligible(
    document: dict[str, Any],
    policy: Mapping[str, Any],
    exports: Mapping[str, str],
    export_documents: Mapping[str, Any],
) -> None:
    try:
        evaluate(document, policy, exports, export_documents)
    except EvaluationError:
        return
    raise AssertionError("mutated cutover ledger unexpectedly became eligible")


def expect_export_mutation_ineligible(
    ledger: Mapping[str, Any],
    policy: Mapping[str, Any],
    export_digests: Mapping[str, str],
    export_documents: Mapping[str, Any],
    name: str,
    mutate: Callable[[dict[str, Any]], None],
) -> None:
    changed_ledger = copy.deepcopy(ledger)
    changed_documents = copy.deepcopy(export_documents)
    mutate(changed_documents[name])
    changed_digests = dict(export_digests)
    changed_digests[name] = canonical_digest(changed_documents[name])
    if name in EXPORT_NAMES:
        changed_ledger["collection"][EXPORT_NAMES[name]] = changed_digests[name]
    else:
        changed_ledger["proofs"][name]["evidence_sha256"] = changed_digests[name]
    expect_ineligible(changed_ledger, policy, changed_digests, changed_documents)


def redigest_fixture_wrapper(wrapper: dict[str, Any]) -> None:
    wrapper["evidence_sha256"] = structured_json_file_digest(wrapper["evidence"])


def self_test() -> None:
    policy = load_policy()
    assert one_sided_exact_mcnemar(1, 0) == 0.5
    assert one_sided_exact_mcnemar(5, 0) == 0.03125
    assert one_sided_exact_mcnemar(0, 0) == 1.0
    valid, exports, export_documents = valid_fixture_inputs(policy)
    report = evaluate(valid, policy, exports, export_documents)
    assert report["decision"] == OBSERVATION_DECISION
    assert report["eligible_for_external_review"] is False
    assert report["provenance_verified"] is False
    assert report["authority_change_applied"] is False
    assert report["blocking_requirements"] == policy["required_blockers"]
    assert report["observations"]["authoritative_provider_failure_count"] == 5
    assert report["observations"]["candidate_provider_failure_count"] == 0
    assert report["observations"]["eligible_main_push_events"] == 32
    assert report["observations"]["authenticated_testflight_delivery_receipt_count"] == 30
    assert sum(
        wrapper["evidence"]["eligible"]
        for main_push in valid["main_pushes"]
        for wrapper in main_push["release_eligibility_history"]
    ) == 32
    assert report["observations"]["authoritative_main_provider_failure_count"] == 2
    assert report["observations"]["candidate_main_provider_failure_count"] == 0
    assert report["observations"]["candidate_main_healthy_latency_sample_count"] == 32
    assert report["observations"]["successful_parity_samples"] == 30
    assert report["observations"]["excluded_source_unavailable_merge_conflict_events"] == 1
    assert (
        report["observations"][
            "authoritative_green_superseded_before_release_handoff_events"
        ]
        == 1
    )
    rerun = valid["main_pushes"][2]["authoritative"]
    assert [attempt["run_id"] for attempt in rerun["attempts"]] == [
        rerun["provider_run_id"],
        rerun["provider_run_id"],
    ]
    assert [attempt["run_attempt"] for attempt in rerun["attempts"]] == [
        "1",
        "2",
    ]
    assert len(valid["main_pushes"][2]["release_eligibility_history"]) == 2
    completed_rerun = valid["main_pushes"][2]
    assert [
        item["evidence"]["authoritative_ci"]["conclusion"]
        for item in completed_rerun["release_eligibility_history"]
    ] == ["success", "success"]
    assert [
        item["evidence"]["resolution"]["state"]
        for item in completed_rerun["release_evidence"]["intents"]
    ] == ["new", "completed"]
    assert len(completed_rerun["release_evidence"]["admissions"]) == 1
    assert len(completed_rerun["release_evidence"]["receipts"]) == 1
    first_delivery = valid["main_pushes"][5]["release_evidence"]
    assert len(first_delivery["intents"]) == 1
    assert len(first_delivery["admissions"]) == 1
    assert len(first_delivery["reuse_provenance"]) == 0
    assert len(first_delivery["receipts"]) == 1
    resumed = valid["main_pushes"][4]
    assert [
        (
            item["evidence"]["authoritative_ci"]["workflow_run_id"],
            item["evidence"]["authoritative_ci"]["run_attempt"],
        )
        for item in resumed["release_eligibility_history"]
    ] == [("100004", "1"), ("100004", "1")]
    assert [
        (
            item["evidence"]["release"]["workflow_run_id"],
            item["evidence"]["release"]["run_attempt"],
        )
        for item in resumed["release_eligibility_history"]
    ] == [("200004", "1"), ("200004", "2")]
    assert [
        item["evidence"]["resolution"]["state"]
        for item in resumed["release_evidence"]["intents"]
    ] == ["new", "resume"]
    assert len(resumed["release_evidence"]["admissions"]) == 2
    assert len(resumed["release_evidence"]["reuse_provenance"]) == 1
    assert len(resumed["release_evidence"]["receipts"]) == 1

    duplicate_receipt_ledger = copy.deepcopy(valid)
    duplicate_evidence = duplicate_receipt_ledger["main_pushes"][4][
        "release_evidence"
    ]
    duplicate_receipt = copy.deepcopy(duplicate_evidence["receipts"][0])
    root_intent = duplicate_evidence["intents"][0]
    root_admission = duplicate_evidence["admissions"][0]
    duplicate_receipt["evidence"]["producer"] = dict(
        root_intent["evidence"]["release"]
    )
    duplicate_receipt["evidence"]["evidence"].update(
        {
            "intent_sha256": root_intent["evidence_sha256"],
            "admission_sha256": root_admission["evidence_sha256"],
            "release_provenance_sha256": root_admission["evidence"]["evidence"][
                "release_provenance_sha256"
            ],
            "head_check_sha256": root_admission["evidence"]["evidence"][
                "head_check_sha256"
            ],
            "reuse_provenance_sha256": None,
        }
    )
    redigest_fixture_wrapper(duplicate_receipt)
    duplicate_evidence["receipts"].append(duplicate_receipt)
    duplicate_exports, duplicate_documents = bind_fixture_inputs(
        duplicate_receipt_ledger, policy
    )
    duplicate_report = evaluate(
        duplicate_receipt_ledger, policy, duplicate_exports, duplicate_documents
    )
    assert (
        duplicate_report["observations"][
            "authenticated_testflight_delivery_receipt_count"
        ]
        == 30
    )

    with_superseded = copy.deepcopy(valid)
    superseded = copy.deepcopy(with_superseded["ready_pull_requests"][0])
    superseded["event_id"] = "ready-event-superseded"
    superseded["delivery_id"] = "webhook-delivery-superseded"
    superseded["source_cohort_id"] = "source-cohort-superseded"
    superseded["ready_at"] = "2025-12-31T23:59:59Z"
    superseded["superseded_by_event_id"] = "ready-event-1"
    superseded["expected_source"] = {"sha": "f" * 40, "tree": "e" * 40}
    superseded["product_verdict"] = None
    superseded["product_verdict_evidence_sha256"] = None
    superseded_ready = require_timestamp(superseded["ready_at"], "fixture.ready_at")
    superseded["authoritative"] = superseded_run(
        "authoritative-superseded", 0, superseded_ready, policy
    )
    superseded["candidate"] = superseded_run(
        "candidate-superseded", 0, superseded_ready, policy
    )
    with_superseded["ready_pull_requests"].insert(0, superseded)
    with_superseded["collection"]["window_started_at"] = superseded["ready_at"]
    with_superseded["collection"]["eligible_ready_pull_request_event_count"] += 1
    superseded_exports, superseded_documents = bind_fixture_inputs(with_superseded, policy)
    superseded_report = evaluate(
        with_superseded, policy, superseded_exports, superseded_documents
    )
    assert (
        superseded_report["observations"]["nonrepresentative_or_duplicate_trigger_events"]
        == 1
    )
    completed_superseded = copy.deepcopy(with_superseded)
    completed_superseded["ready_pull_requests"][0]["candidate"] = healthy_run(
        "candidate-completed-before-supersession",
        0,
        completed_superseded["ready_pull_requests"][0]["expected_source"],
        superseded_ready,
        1,
        operational=True,
        policy=policy,
    )
    completed_exports, completed_documents = bind_fixture_inputs(
        completed_superseded, policy
    )
    expect_ineligible(
        completed_superseded, policy, completed_exports, completed_documents
    )
    with_duplicate_trigger = copy.deepcopy(valid)
    duplicate = copy.deepcopy(with_duplicate_trigger["ready_pull_requests"][0])
    duplicate["event_id"] = "ready-event-reopened"
    duplicate["delivery_id"] = "webhook-delivery-reopened"
    duplicate["action"] = "reopened"
    duplicate_ready = require_timestamp(duplicate["ready_at"], "fixture.ready_at") + timedelta(
        seconds=60
    )
    duplicate["ready_at"] = duplicate_ready.strftime("%Y-%m-%dT%H:%M:%SZ")
    duplicate["authoritative"] = healthy_run(
        "authoritative-reopened",
        0,
        duplicate["expected_source"],
        duplicate_ready,
        120,
        operational=False,
        policy=policy,
    )
    duplicate["candidate"] = healthy_run(
        "candidate-reopened",
        0,
        duplicate["expected_source"],
        duplicate_ready,
        max(10, policy["pr_p95"] - 1),
        operational=True,
        policy=policy,
    )
    with_duplicate_trigger["ready_pull_requests"].append(duplicate)
    with_duplicate_trigger["collection"]["eligible_ready_pull_request_event_count"] += 1
    duplicate_exports, duplicate_documents = bind_fixture_inputs(
        with_duplicate_trigger, policy
    )
    duplicate_report = evaluate(
        with_duplicate_trigger, policy, duplicate_exports, duplicate_documents
    )
    assert duplicate_report["observations"]["representative_source_cohorts"] == 30

    mutations = []
    changed = copy.deepcopy(valid)
    changed["policy_sha256"] = "sha256:" + "0" * 64
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["collection"]["method"] = "manual-success-selection"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["collection"]["eligible_ready_pull_request_event_count"] += 1
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"].pop()
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][-1]["ready_at"] = changed["ready_pull_requests"][0]["ready_at"]
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    for item in changed["ready_pull_requests"][-2:]:
        ready = require_timestamp(item["ready_at"], "fixture.ready_at")
        item["candidate"]["provider_finished_at"] = (
            ready + timedelta(seconds=policy["pr_p95"] + 1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["candidate"]["source"]["tree"] = "f" * 40
    changed["ready_pull_requests"][0]["candidate"]["provider_failure_attempt_count"] = 1
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["product_verdict"] = "failed"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["candidate"] = missing_run("candidate-pr", policy)
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["authoritative"] = healthy_run(
        "authoritative-pr", 0, changed["ready_pull_requests"][0]["expected_source"],
        require_timestamp(changed["ready_pull_requests"][0]["ready_at"], "fixture.ready_at"),
        120, operational=False, policy=policy,
    )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    for index, item in enumerate(changed["ready_pull_requests"]):
        item["authoritative"] = healthy_run(
            "authoritative-pr",
            index,
            item["expected_source"],
            require_timestamp(item["ready_at"], "fixture.ready_at"),
            120,
            operational=False,
            policy=policy,
        )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    for index in range(1, len(changed["ready_pull_requests"])):
        item = changed["ready_pull_requests"][index]
        item["authoritative"] = healthy_run(
            "authoritative-pr",
            index,
            item["expected_source"],
            require_timestamp(item["ready_at"], "fixture.ready_at"),
            120,
            operational=False,
            policy=policy,
        )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    for index, item in enumerate(changed["ready_pull_requests"]):
        item["authoritative"] = healthy_run(
            "authoritative-pr",
            index,
            item["expected_source"],
            require_timestamp(item["ready_at"], "fixture.ready_at"),
            120,
            operational=False,
            policy=policy,
        )
    changed["ready_pull_requests"][0]["candidate"] = missing_run("candidate-pr", policy)
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][1]["candidate"]["run_id"] = changed[
        "ready_pull_requests"
    ][0]["candidate"]["run_id"]
    changed["ready_pull_requests"][1]["candidate"]["attempts"] = copy.deepcopy(changed[
        "ready_pull_requests"
    ][0]["candidate"]["attempts"])
    changed["ready_pull_requests"][1]["candidate"]["provider_run_id"] = changed[
        "ready_pull_requests"
    ][0]["candidate"]["provider_run_id"]
    changed["ready_pull_requests"][1]["candidate"]["provider_run_attempt"] = changed[
        "ready_pull_requests"
    ][0]["candidate"]["provider_run_attempt"]
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["candidate"]["operational_observation_sha256"] = None
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"].pop()
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][0]["candidate"] = missing_run("candidate-main", policy)
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][0]["candidate"]["source"]["tree"] = "f" * 40
    changed["main_pushes"][0]["candidate"]["provider_failure_attempt_count"] = 1
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][0]["candidate"]["operational_observation_sha256"] = None
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    for item in changed["main_pushes"][-2:]:
        pushed = require_timestamp(item["pushed_at"], "fixture.pushed_at")
        item["candidate"]["provider_finished_at"] = (
            pushed + timedelta(seconds=policy["main_p95"] + 1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["release_evidence"]["receipts"].clear()
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    for item in changed["main_pushes"][-2:]:
        receipt_wrapper = item["release_evidence"]["receipts"][0]
        receipt = receipt_wrapper["evidence"]
        intent = item["release_evidence"]["intents"][0]["evidence"]
        completed = require_timestamp(
            intent["authoritative_ci"]["completed_at"], "fixture.ci_completed_at"
        )
        receipt["delivery"]["completed_at"] = (
            completed + timedelta(seconds=policy["testflight_p95"] + 1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["release_evidence"]["receipts"].append(
        copy.deepcopy(changed["main_pushes"][2]["release_evidence"]["receipts"][0])
    )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][0]["release_evidence"] = copy.deepcopy(
        changed["main_pushes"][2]["release_evidence"]
    )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["collection"]["eligible_testflight_delivery_count"] += 1
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    first_main = changed["main_pushes"][0]
    first_pushed = require_timestamp(first_main["pushed_at"], "fixture.pushed_at")
    first_main["pushed_at"] = (first_pushed + timedelta(days=1)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    for timestamp_field in ("provider_started_at", "provider_finished_at"):
        timestamp = require_timestamp(
            first_main["candidate"][timestamp_field], f"fixture.{timestamp_field}"
        )
        first_main["candidate"][timestamp_field] = (
            timestamp + timedelta(days=1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["collection"]["candidate_settings_attestation"]["publish_commit_status"] = True
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["collection"]["candidate_settings_attestation"][
        "build_pull_request_labels_changed"
    ] = True
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["release_security"]["executed_by"] = "reviewer-a"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["atomic_rollback"]["atomic"] = False
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["release_security"]["observed_at"] = "2025-12-31T23:59:59Z"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["release_security"]["observed_at"] = changed[
        "ready_pull_requests"
    ][-1]["ready_at"]
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["release_security"]["candidate_run_id"] = "unobserved-run"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["release_security"]["candidate_settings_revision"] = "stale-settings"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["repository"]["id"] += 1
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["source_unavailable_merge_conflicts"].pop()
    mutations.append(changed)
    for digest_field in (
        "policy_sha256",
        "configuration_sha256",
        "bootstrap_sha256",
        "toolchain_sha256",
    ):
        changed = copy.deepcopy(valid)
        changed["ready_pull_requests"][0]["candidate"][digest_field] = "sha256:" + "0" * 64
        mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["candidate"]["settings_revision"] = "stale-settings"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["candidate"]["provider_scope"][
        "pipeline_id"
    ] = "other-pipeline"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["ready_pull_requests"][0]["authoritative"]["settings_revision"] = (
        "stale-authority-settings"
    )
    mutations.append(changed)
    unsafe_settings = {
        "provider_webhook_url_present": False,
        "filter_enabled": True,
        "publish_commit_status": True,
        "publish_commit_status_per_step": True,
        "publish_blocked_as_pending": True,
        "separate_pull_request_statuses": True,
        "build_pull_request_forks": True,
        "build_tags": True,
        "queue_secrets_attached": True,
        "pipeline_secrets_attached": True,
        "cluster_secrets_attached": True,
        "organization_secrets_attached": True,
        "release_runner_access": True,
        "build_pull_requests": False,
        "build_pull_request_merge_commits": True,
        "build_pull_request_ready_for_review": False,
        "build_pull_request_reopened": False,
        "build_pull_request_base_branch_changed": True,
        "build_pull_request_labels_changed": True,
        "build_pull_request_edited": True,
        "build_pull_request_converted_to_draft": True,
        "build_pull_request_review_requested": True,
        "build_check_run_completed": True,
        "build_pull_request_review_submitted": True,
        "build_pull_request_review_dismissed": True,
        "build_release_published": True,
        "build_release_created": True,
        "build_release_released": True,
        "build_issue_comment_created": True,
        "build_deployment_status_created": True,
        "build_pull_request_review_comment_created": True,
        "build_pull_request_dequeued": True,
        "build_create_event": True,
        "build_merge_group_checks_requested": True,
        "skip_builds_for_closed_pull_requests": True,
        "pull_request_branch_filter_enabled": True,
        "build_branches": False,
        "skip_builds_for_existing_commits": True,
        "skip_pull_request_builds_for_existing_commits": True,
        "workflow_dispatch_parity_implemented": True,
        "skip_queued_branch_builds": False,
        "cancel_running_branch_builds": False,
        "branch_configuration": "*",
        "skip_queued_branch_builds_filter": "*",
        "cancel_running_branch_builds_filter": "*",
        "allowed_queues": ["release"],
        "trigger_mode": "deployment",
        "provider_id": "gitlab",
    }
    for setting, unsafe_value in unsafe_settings.items():
        changed = copy.deepcopy(valid)
        changed["collection"]["candidate_settings_attestation"][setting] = unsafe_value
        mutations.append(changed)
    changed = copy.deepcopy(valid)
    candidate_attestation = changed["collection"]["candidate_settings_attestation"]
    candidate_attestation["build_pull_request_merge"] = candidate_attestation.pop(
        "build_pull_request_merge_commits"
    )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    candidate_attestation = changed["collection"]["candidate_settings_attestation"]
    candidate_attestation["code_trigger_mode"] = candidate_attestation.pop("trigger_mode")
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["release_security"]["repository"]["id"] += 1
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["proofs"]["release_security"]["candidate_provider_scope"][
        "cluster_id"
    ] = "other-cluster"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][1]["sequence"] = 1
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["release_eligibility_history"][-1]["evidence"][
        "eligible"
    ] = False
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    eligibility_wrapper = changed["main_pushes"][2]["release_eligibility_history"][-1]
    eligibility_wrapper["evidence"]["eligible"] = False
    redigest_fixture_wrapper(eligibility_wrapper)
    changed["main_pushes"][2]["selected_release_eligibility_sha256"] = (
        eligibility_wrapper["evidence_sha256"]
    )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][1]["release_eligibility_history"][-1]["evidence"][
        "observed_main_sha"
    ] = "a" * 40
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["release_eligibility_history"][-1]["evidence"][
        "checked_at"
    ] = changed["main_pushes"][2]["pushed_at"]
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["release_eligibility_history"].pop(0)
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["release_attempt_inventory"].pop(0)
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][4]["release_attempt_inventory"][1]["release"][
        "run_attempt"
    ] = "1"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["selected_release_eligibility_sha256"] = changed[
        "main_pushes"
    ][2]["release_eligibility_history"][0]["evidence_sha256"]
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["authoritative"]["attempts"][1][
        "run_attempt"
    ] = "1"
    mutations.append(changed)

    # Completed successful reruns must retain the second intent while reusing
    # the first receipt; neither eligibility record represents a new delivery.
    changed = copy.deepcopy(valid)
    changed["main_pushes"][2]["release_evidence"]["intents"].pop()
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    completed_intent = changed["main_pushes"][2]["release_evidence"]["intents"][1]
    completed_intent["evidence"]["resolution"]["completion_receipt_sha256"] = changed[
        "main_pushes"
    ][3]["release_evidence"]["receipts"][0]["evidence_sha256"]
    redigest_fixture_wrapper(completed_intent)
    mutations.append(changed)

    # Recompute wrapper digests for semantic join mutations so these exercise
    # the authenticated graph rather than only stale-digest rejection.
    changed = copy.deepcopy(valid)
    target = changed["main_pushes"][5]["release_evidence"]
    admission_wrapper = target["admissions"][0]
    admission_wrapper["evidence"]["evidence"]["intent_sha256"] = changed[
        "main_pushes"
    ][6]["release_evidence"]["intents"][0]["evidence_sha256"]
    redigest_fixture_wrapper(admission_wrapper)
    receipt_wrapper = target["receipts"][0]
    receipt_wrapper["evidence"]["evidence"]["admission_sha256"] = admission_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    resumed_evidence = changed["main_pushes"][4]["release_evidence"]
    receipt_wrapper = resumed_evidence["receipts"][0]
    receipt_wrapper["evidence"]["evidence"]["admission_sha256"] = resumed_evidence[
        "admissions"
    ][0]["evidence_sha256"]
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    resumed_evidence = changed["main_pushes"][4]["release_evidence"]
    receipt_wrapper = resumed_evidence["receipts"][0]
    root_intent = resumed_evidence["intents"][0]
    root_admission = resumed_evidence["admissions"][0]
    receipt_wrapper["evidence"]["producer"] = dict(root_intent["evidence"]["release"])
    receipt_wrapper["evidence"]["evidence"].update(
        {
            "intent_sha256": root_intent["evidence_sha256"],
            "admission_sha256": root_admission["evidence_sha256"],
            "release_provenance_sha256": root_admission["evidence"]["evidence"][
                "release_provenance_sha256"
            ],
            "head_check_sha256": root_admission["evidence"]["evidence"][
                "head_check_sha256"
            ],
            "reuse_provenance_sha256": None,
        }
    )
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    resumed_evidence = changed["main_pushes"][4]["release_evidence"]
    reuse_wrapper = resumed_evidence["reuse_provenance"][0]
    reuse_wrapper["evidence"]["consumer"]["run_attempt"] = "3"
    redigest_fixture_wrapper(reuse_wrapper)
    admission_wrapper = resumed_evidence["admissions"][1]
    admission_wrapper["evidence"]["evidence"]["reuse_provenance_sha256"] = reuse_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(admission_wrapper)
    receipt_wrapper = resumed_evidence["receipts"][0]
    receipt_wrapper["evidence"]["evidence"]["reuse_provenance_sha256"] = reuse_wrapper[
        "evidence_sha256"
    ]
    receipt_wrapper["evidence"]["evidence"]["admission_sha256"] = admission_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    resumed_evidence = changed["main_pushes"][4]["release_evidence"]
    reuse_wrapper = resumed_evidence["reuse_provenance"][0]
    reuse_wrapper["evidence"]["original"]["workflow_run_id"] = "999999"
    redigest_fixture_wrapper(reuse_wrapper)
    admission_wrapper = resumed_evidence["admissions"][1]
    admission_wrapper["evidence"]["evidence"]["reuse_provenance_sha256"] = reuse_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(admission_wrapper)
    receipt_wrapper = resumed_evidence["receipts"][0]
    receipt_wrapper["evidence"]["evidence"]["reuse_provenance_sha256"] = reuse_wrapper[
        "evidence_sha256"
    ]
    receipt_wrapper["evidence"]["evidence"]["admission_sha256"] = admission_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    receipt_wrapper = changed["main_pushes"][4]["release_evidence"]["receipts"][0]
    receipt_wrapper["evidence"]["evidence"]["reuse_provenance_sha256"] = None
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    target = changed["main_pushes"][5]["release_evidence"]
    head_wrapper = target["head_checks"][0]
    head_wrapper["evidence"]["source_is_current_main"] = False
    redigest_fixture_wrapper(head_wrapper)
    admission_wrapper = target["admissions"][0]
    admission_wrapper["evidence"]["evidence"]["head_check_sha256"] = head_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(admission_wrapper)
    receipt_wrapper = target["receipts"][0]
    receipt_wrapper["evidence"]["evidence"]["head_check_sha256"] = head_wrapper[
        "evidence_sha256"
    ]
    receipt_wrapper["evidence"]["evidence"]["admission_sha256"] = admission_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    target = changed["main_pushes"][5]["release_evidence"]
    provenance_wrapper = target["release_provenance"][0]
    provenance_wrapper["evidence"]["product"]["build_number"] = changed[
        "main_pushes"
    ][6]["release_evidence"]["intents"][0]["evidence"]["product"]["build_number"]
    redigest_fixture_wrapper(provenance_wrapper)
    admission_wrapper = target["admissions"][0]
    admission_wrapper["evidence"]["evidence"][
        "release_provenance_sha256"
    ] = provenance_wrapper["evidence_sha256"]
    redigest_fixture_wrapper(admission_wrapper)
    receipt_wrapper = target["receipts"][0]
    receipt_wrapper["evidence"]["evidence"][
        "release_provenance_sha256"
    ] = provenance_wrapper["evidence_sha256"]
    receipt_wrapper["evidence"]["evidence"]["admission_sha256"] = admission_wrapper[
        "evidence_sha256"
    ]
    redigest_fixture_wrapper(receipt_wrapper)
    mutations.append(changed)

    changed = copy.deepcopy(valid)
    changed["main_pushes"][5]["release_evidence"]["intents"][0][
        "artifact_path"
    ] = "build/release/not-an-intent.json"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][5]["release_evidence"]["release_provider"] = "other-provider"
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    duplicate_eligibility = copy.deepcopy(
        changed["main_pushes"][4]["release_eligibility_history"][-1]
    )
    duplicate_checked = require_timestamp(
        duplicate_eligibility["evidence"]["checked_at"], "fixture.duplicate_checked_at"
    )
    duplicate_eligibility["evidence"]["checked_at"] = (
        duplicate_checked + timedelta(seconds=1)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    redigest_fixture_wrapper(duplicate_eligibility)
    changed["main_pushes"][4]["release_eligibility_history"].append(
        duplicate_eligibility
    )
    changed["main_pushes"][4]["selected_release_eligibility_sha256"] = (
        duplicate_eligibility["evidence_sha256"]
    )
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["main_pushes"][4]["release_evidence"]["reuse_provenance"].clear()
    mutations.append(changed)
    changed = copy.deepcopy(valid)
    changed["unexpected"] = True
    mutations.append(changed)
    for mutation in mutations:
        mutation_exports, mutation_documents = bind_fixture_inputs(mutation, policy)
        expect_ineligible(mutation, policy, mutation_exports, mutation_documents)

    for name in EXPORT_NAMES:
        expect_export_mutation_ineligible(
            valid,
            policy,
            exports,
            export_documents,
            name,
            lambda document: document["repository"].__setitem__("id", 9001),
        )
    for name in PROOF_NAMES:
        expect_export_mutation_ineligible(
            valid,
            policy,
            exports,
            export_documents,
            name,
            lambda document: document["repository"].__setitem__("id", 9001),
        )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "event",
        lambda document: document["source_unavailable_merge_conflicts"].pop(),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "event",
        lambda document: document.__setitem__("source_unavailable_policy", "omit-conflicts"),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "candidate_settings",
        lambda document: document["audit_history"][0].__setitem__(
            "effective_from", "2026-01-02T00:00:00Z"
        ),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "candidate_settings",
        lambda document: document["audit_history"][0]["provider_scope"].__setitem__(
            "organization_id", "other-organization"
        ),
    )

    def break_settings_continuity(document: dict[str, Any]) -> None:
        first = copy.deepcopy(document["audit_history"][0])
        second = copy.deepcopy(first)
        first["revision"] = "buildkite-settings-revision-0"
        first["effective_until"] = "2026-01-15T00:00:00Z"
        second["audit_event_id"] = "candidate-settings-audit-2"
        second["audit_event_sha256"] = "sha256:" + "4" * 64
        second["effective_from"] = "2026-01-15T00:00:01Z"
        document["audit_history"] = [first, second]

    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "candidate_settings",
        break_settings_continuity,
    )
    ruleset_mutations = {
        "ruleset_id": 9001,
        "target": "tag",
        "enforcement": "evaluate",
        "default_branch": "develop",
        "branch_includes": ["refs/heads/other"],
        "branch_excludes": ["refs/heads/main"],
        "bypass_actors": [{"actor_id": 1}],
        "forbidden_metadata_patterns": FORBIDDEN_CI_SKIP_PATTERNS[:-1],
    }
    for ruleset_field, unsafe_value in ruleset_mutations.items():
        expect_export_mutation_ineligible(
            valid,
            policy,
            exports,
            export_documents,
            "authority_ruleset",
            lambda document, field=ruleset_field, value=unsafe_value: document.__setitem__(
                field, value
            ),
        )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "authority_ruleset",
        lambda document: document["required_status_checks"].__setitem__("strict", False),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "authority_ruleset",
        lambda document: document["required_status_checks"].__setitem__(
            "checks", [{"context": "CI summary", "integration_id": 1}]
        ),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "authority_ruleset",
        lambda document: document["pull_request_requirement"].__setitem__(
            "required", False
        ),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "parity",
        lambda document: document["records"].pop(),
    )
    for parity_field, unsafe_value in (
        ("status", "failed"),
        ("source", {"sha": "a" * 40, "tree": "b" * 40}),
        ("candidate_run_ids", ["other-run"]),
        ("evidence_sha256", "invalid"),
    ):
        expect_export_mutation_ineligible(
            valid,
            policy,
            exports,
            export_documents,
            "parity",
            lambda document, field=parity_field, value=unsafe_value: document["records"][
                0
            ].__setitem__(field, value),
        )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "parity",
        lambda document: document["records"][0]["candidate_artifacts"][0].__setitem__(
            "artifact_sha256", "sha256:" + "4" * 64
        ),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "testflight",
        lambda document: document["release_eligibility"].pop(),
    )
    expect_export_mutation_ineligible(
        valid,
        policy,
        exports,
        export_documents,
        "testflight",
        lambda document: document["release_evidence"].pop(),
    )

    wrong_exports = dict(exports)
    wrong_exports["candidate"] = "sha256:" + "0" * 64
    expect_ineligible(valid, policy, wrong_exports, export_documents)
    empty_documents = copy.deepcopy(export_documents)
    empty_documents["candidate"] = {}
    empty_exports = dict(exports)
    empty_exports["candidate"] = canonical_digest({})
    empty_ledger = copy.deepcopy(valid)
    empty_ledger["collection"][EXPORT_NAMES["candidate"]] = empty_exports["candidate"]
    expect_ineligible(empty_ledger, policy, empty_exports, empty_documents)
    try:
        json.loads('{"schema":"one","schema":"two"}', object_pairs_hook=reject_duplicate_keys)
    except EvaluationError:
        pass
    else:
        raise AssertionError("duplicate ledger keys were accepted")

    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "evaluation.json"
        write_report_exclusive(output, report)
        assert read_json(output, "self-test output") == report
        try:
            write_report_exclusive(output, report)
        except EvaluationError:
            pass
        else:
            raise AssertionError("existing evaluation output was overwritten")
    print("CI cutover evaluation self-test passed")


def load_export_inputs(
    arguments: argparse.Namespace,
) -> tuple[dict[str, str], dict[str, Any]]:
    paths = {
        "event": arguments.event_export,
        "authoritative": arguments.authoritative_export,
        "candidate": arguments.candidate_export,
        "testflight": arguments.testflight_export,
        "product_verdict": arguments.product_verdict_export,
        "candidate_settings": arguments.candidate_settings_export,
        "authority_ruleset": arguments.authority_ruleset_export,
        "parity": arguments.parity_export,
        "release_security": arguments.release_security_proof,
        "atomic_rollback": arguments.atomic_rollback_proof,
    }
    digests = {}
    documents = {}
    for name, path in paths.items():
        assert path is not None
        documents[name] = read_json(path, f"{name} canonical export")
        digests[name] = file_digest(path)
    return digests, documents


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--ledger", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--event-export", type=Path)
    parser.add_argument("--authoritative-export", type=Path)
    parser.add_argument("--candidate-export", type=Path)
    parser.add_argument("--testflight-export", type=Path)
    parser.add_argument("--product-verdict-export", type=Path)
    parser.add_argument("--candidate-settings-export", type=Path)
    parser.add_argument("--authority-ruleset-export", type=Path)
    parser.add_argument("--parity-export", type=Path)
    parser.add_argument("--release-security-proof", type=Path)
    parser.add_argument("--atomic-rollback-proof", type=Path)
    arguments = parser.parse_args()
    input_paths = [
        arguments.ledger,
        arguments.output,
        arguments.event_export,
        arguments.authoritative_export,
        arguments.candidate_export,
        arguments.testflight_export,
        arguments.product_verdict_export,
        arguments.candidate_settings_export,
        arguments.authority_ruleset_export,
        arguments.parity_export,
        arguments.release_security_proof,
        arguments.atomic_rollback_proof,
    ]
    if arguments.self_test and any(path is not None for path in input_paths):
        parser.error("--self-test cannot be combined with evaluation inputs")
    if not arguments.self_test and any(path is None for path in input_paths):
        parser.error("ledger, output, every normalized export, and both proof files are required")
    try:
        if arguments.self_test:
            self_test()
            return 0
        assert arguments.ledger is not None and arguments.output is not None
        resolved_inputs = [path.resolve() for path in input_paths if path is not None]
        if len(set(resolved_inputs)) != len(resolved_inputs):
            raise EvaluationError("ledger, output, normalized export, and proof paths must be distinct")
        if arguments.output.exists():
            raise EvaluationError("output path already exists")
        policy = load_policy()
        exports, export_documents = load_export_inputs(arguments)
        ledger = read_json(arguments.ledger, "cutover observation ledger")
        report = evaluate(ledger, policy, exports, export_documents)
        write_report_exclusive(arguments.output, report)
        print(OBSERVATION_DECISION)
        return 0
    except (EvaluationError, OSError) as error:
        print(f"CI cutover remains ineligible: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
