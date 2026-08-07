#!/usr/bin/env python3
"""Resolve one fail-closed CI identity across GitHub Actions and Buildkite.

GitHub Actions remains authoritative. Buildkite contexts are advisory shadow
evidence only. For pull requests, the source identity is always GitHub's
synthetic ``refs/pull/<number>/merge`` commit and its exact tree/parents.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.parse import urlsplit


SCHEMA = "tron.ci-provider-context.v1"
POLICY_SCHEMA = "tron.ci-policy.v1"
ROOT = Path(__file__).resolve().parent.parent
POLICY_PATH = ROOT / "config" / "ci-policy.json"
SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9_./-]+$")
BUILDKITE_PULL_REQUEST_ACTIONS = {
    "opened",
    "synchronize",
    "reopened",
    "ready_for_review",
}
GITHUB_PULL_REQUEST_ACTIONS = BUILDKITE_PULL_REQUEST_ACTIONS | {"converted_to_draft"}


class ContextError(ValueError):
    """The provider did not prove one unambiguous source context."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContextError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def read_json(path: Path, field: str) -> Any:
    try:
        return json.loads(path.read_text(), object_pairs_hook=reject_duplicate_keys)
    except (OSError, json.JSONDecodeError) as error:
        raise ContextError(f"cannot read {field}: {error}") from error


def require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContextError(f"{field} must be an object")
    return value


def require_keys(value: Mapping[str, Any], expected: set[str], field: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ContextError(f"{field} keys are invalid (missing={missing}, extra={extra})")


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise ContextError(f"{field} must be a non-empty, unpadded string")
    return value


def require_bool(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise ContextError(f"{field} must be a boolean")
    return value


def positive_integer(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise ContextError(f"{field} must be a positive integer")
    if isinstance(value, int):
        result = value
    elif isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*", value):
        result = int(value)
    else:
        raise ContextError(f"{field} must be a positive integer")
    if result < 1:
        raise ContextError(f"{field} must be a positive integer")
    return result


def require_env(environment: Mapping[str, str], name: str) -> str:
    if name not in environment:
        raise ContextError(f"{name} is required")
    return require_string(environment[name], name)


def optional_env(environment: Mapping[str, str], name: str) -> str | None:
    value = environment.get(name)
    if value is None or value == "":
        return None
    return require_string(value, name)


def normalize_sha(value: Any, field: str) -> str:
    text = require_string(value, field)
    if not SHA_RE.fullmatch(text):
        raise ContextError(f"{field} must be a 40-character hexadecimal commit ID")
    if set(text) == {"0"}:
        raise ContextError(f"{field} may not be the null object ID")
    return text.lower()


def optional_sha(value: Any, field: str) -> str | None:
    if value is None:
        return None
    return normalize_sha(value, field)


def declared_sha(environment: Mapping[str, str], names: Sequence[str], field: str,
                 *, required: bool = False) -> str | None:
    declarations = [normalize_sha(value, name) for name in names
                    if (value := optional_env(environment, name)) is not None]
    if not declarations:
        if required:
            raise ContextError(f"{field} is required")
        return None
    if len(set(declarations)) != 1:
        raise ContextError(f"inconsistent declarations for {field}")
    return declarations[0]


def normalize_repository(value: Any, field: str) -> str:
    slug = require_string(value, field)
    if not REPOSITORY_RE.fullmatch(slug) or slug.startswith(('.', '-')):
        raise ContextError(f"{field} must be an owner/repository slug")
    owner, repository = slug.split("/", 1)
    if repository.startswith(('.', '-')) or repository.endswith(".git"):
        raise ContextError(f"{field} must be an owner/repository slug without .git")
    return f"{owner}/{repository}".lower()


def repository_from_url(value: Any, field: str) -> str:
    raw = require_string(value, field)
    if REPOSITORY_RE.fullmatch(raw):
        return normalize_repository(raw, field)
    scp_match = re.fullmatch(r"(?:[^/@:]+@)?github\.com:([^?#]+)", raw,
                             flags=re.IGNORECASE)
    if scp_match:
        path = scp_match.group(1)
    else:
        parsed = urlsplit(raw)
        if parsed.hostname is None or parsed.hostname.lower() != "github.com":
            raise ContextError(f"{field} must identify a GitHub repository")
        if parsed.query or parsed.fragment:
            raise ContextError(f"{field} may not contain a query or fragment")
        path = parsed.path.lstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return normalize_repository(path, field)


def normalize_branch(value: Any, field: str) -> str:
    branch = require_string(value, field)
    invalid = (
        not BRANCH_RE.fullmatch(branch)
        or branch.startswith(("/", "."))
        or branch.endswith(("/", ".", ".lock"))
        or ".." in branch
        or "//" in branch
        or "@{" in branch
    )
    if invalid:
        raise ContextError(f"{field} is not a safe branch name")
    return branch


class Git:
    def __init__(self, root: Path) -> None:
        self.root = root

    def run(self, *arguments: str) -> str:
        process = subprocess.run(
            ["git", "-C", str(self.root), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if process.returncode != 0:
            detail = process.stderr.strip().splitlines()
            suffix = f": {detail[-1]}" if detail else ""
            raise ContextError(f"git {' '.join(arguments[:2])} failed{suffix}")
        return process.stdout.strip()

    def head(self) -> str:
        return normalize_sha(self.run("rev-parse", "--verify", "HEAD"), "git HEAD")

    def commit(self, revision: str) -> tuple[str, list[str]]:
        sha = normalize_sha(revision, "git revision")
        raw = self.run("cat-file", "-p", sha).splitlines()
        if not raw or not raw[0].startswith("tree "):
            raise ContextError(f"{sha} is not a commit")
        tree = normalize_sha(raw[0][5:], f"tree for {sha}")
        parents: list[str] = []
        for line in raw[1:]:
            if not line.startswith("parent "):
                break
            parents.append(normalize_sha(line[7:], f"parent for {sha}"))
        return tree, parents

    def ensure_commit(self, revision: str, field: str) -> None:
        sha = normalize_sha(revision, field)
        self.run("cat-file", "-e", f"{sha}^{{commit}}")

    def has_commit(self, revision: str) -> bool:
        sha = normalize_sha(revision, "git commit prerequisite")
        process = subprocess.run(
            ["git", "-C", str(self.root), "cat-file", "-e", f"{sha}^{{commit}}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return process.returncode == 0

    def ensure_or_fetch_commit(self, remote: str, revision: str, field: str) -> None:
        sha = normalize_sha(revision, field)
        if not self.has_commit(sha):
            # Fetch the immutable object ID, never a moving pull-request ref.
            # Depth one bounds each prerequisite transfer to its commit/tree.
            self.run(
                "fetch", "--no-tags", "--force", "--no-recurse-submodules", "--depth=1",
                remote, sha,
            )
        self.ensure_commit(sha, field)

    def raw_remote_url(self, remote: str) -> str:
        value = self.run("config", "--get", f"remote.{remote}.url")
        if not value or "\n" in value:
            raise ContextError(f"git remote {remote} must have exactly one URL")
        return value

    def fetch_pull_merge(self, remote: str, number: int, source_ref: str,
                         local_ref: str, expected_parents: Sequence[str]) -> str:
        expected = f"refs/pull/{number}/merge"
        if source_ref != expected:
            raise ContextError("pull-request merge ref does not match its number")
        normalized_parents = [
            normalize_sha(parent, "expected pull-request merge parent")
            for parent in expected_parents
        ]
        if len(normalized_parents) != 2:
            raise ContextError("pull-request merge requires exact base/head parents")
        arguments = [
            "git", "-C", str(self.root), "fetch", "--no-tags", "--force",
            "--no-recurse-submodules", "--depth=2", remote,
            f"+{source_ref}:{local_ref}",
        ]
        last_error = ""
        # GitHub creates or refreshes the synthetic merge ref asynchronously
        # after some PR webhooks. Retry only this same ref inside the source
        # step until the fetched commit has the immutable webhook base/head.
        # A later PR update therefore never repins this build: its parents can
        # never satisfy the event that created the build.
        for attempt, delay in enumerate((1, 2, 4, 8, 8, 0), start=1):
            process = subprocess.run(
                arguments,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if process.returncode == 0:
                fetched_sha = normalize_sha(
                    self.run("rev-parse", "--verify", local_ref),
                    "fetched pull-request merge",
                )
                _, parents = self.commit(fetched_sha)
                if parents == normalized_parents:
                    return fetched_sha
                last_error = "fetched merge parents do not match the webhook base/head"
            else:
                details = process.stderr.strip().splitlines()
                last_error = details[-1] if details else "unknown fetch failure"
            if delay:
                time.sleep(delay)
        raise ContextError(
            f"GitHub merge ref did not stabilize after {attempt} bounded attempts: "
            f"{last_error}"
        )

    def checkout(self, revision: str) -> None:
        self.run("checkout", "--detach", revision)


def load_policy(path: Path = POLICY_PATH) -> dict[str, Any]:
    policy = require_mapping(read_json(path, "CI policy"), "CI policy")
    if policy.get("schema") != POLICY_SCHEMA:
        raise ContextError("unsupported CI policy schema")
    main_branch = normalize_branch(policy.get("main_branch"), "policy.main_branch")
    events = policy.get("supported_events")
    if events != ["pull_request", "push", "workflow_dispatch"]:
        raise ContextError(
            "policy.supported_events must preserve pull_request, push, and workflow_dispatch"
        )
    if policy.get("pull_request_merge_ref") != "refs/pull/{number}/merge":
        raise ContextError("policy.pull_request_merge_ref is unsupported")
    required_jobs = policy.get("required_jobs")
    if not isinstance(required_jobs, list) or not required_jobs:
        raise ContextError("policy.required_jobs must be a non-empty list")
    jobs = [require_string(job, "policy.required_jobs[]") for job in required_jobs]
    if len(jobs) != len(set(jobs)):
        raise ContextError("policy.required_jobs contains duplicates")
    controls = policy.get("orchestration_controls")
    if not isinstance(controls, list) or not controls:
        raise ContextError("policy.orchestration_controls must be a non-empty list")
    providers = require_mapping(policy.get("providers"), "policy.providers")
    if set(providers) != {"github-actions", "buildkite"}:
        raise ContextError("policy.providers must contain GitHub Actions and Buildkite")
    expected = {
        "github-actions": ("authoritative", False, True, True),
        "buildkite": ("shadow", True, False, False),
    }
    for name, (role, shadow, required_check, release) in expected.items():
        provider = require_mapping(providers[name], f"policy.providers.{name}")
        actual = (
            require_string(provider.get("role"), f"policy.providers.{name}.role"),
            require_bool(provider.get("shadow"), f"policy.providers.{name}.shadow"),
            require_bool(provider.get("required_check_authority"),
                         f"policy.providers.{name}.required_check_authority"),
            require_bool(provider.get("release_authority"),
                         f"policy.providers.{name}.release_authority"),
        )
        if actual != (role, shadow, required_check, release):
            raise ContextError(f"policy authority for {name} violates the migration boundary")
        configuration = require_string(provider.get("configuration_path"),
                                       f"policy.providers.{name}.configuration_path")
        if configuration.startswith("/") or ".." in Path(configuration).parts:
            raise ContextError(f"policy configuration path for {name} is unsafe")
        bootstrap = provider.get("bootstrap_configuration_path")
        if bootstrap is not None:
            bootstrap_path = require_string(
                bootstrap, f"policy.providers.{name}.bootstrap_configuration_path"
            )
            if bootstrap_path.startswith("/") or ".." in Path(bootstrap_path).parts:
                raise ContextError(f"policy bootstrap path for {name} is unsafe")
        if name == "github-actions" and bootstrap is not None:
            raise ContextError("GitHub Actions may not declare a shadow bootstrap")
        if name == "buildkite" and bootstrap != ".buildkite/pipeline.yml":
            raise ContextError("Buildkite must declare its orchestration bootstrap")
    release = require_mapping(policy.get("release"), "policy.release")
    if release.get("provider") != "github-actions":
        raise ContextError("GitHub Actions must retain release ownership")
    ios_release = require_mapping(release.get("ios"), "policy.release.ios")
    mac_release = require_mapping(release.get("mac"), "policy.release.mac")
    if ios_release.get("configuration_path") != ".github/workflows/release-ios.yml":
        raise ContextError("iOS release configuration ownership is invalid")
    if ios_release.get("identity") != {
        "app_id": "6761511764",
        "bundle_ids": ["com.tron.mobile", "com.tron.mobile.ShareExtension"],
        "scheme": "Tron",
        "configuration": "Prod",
    }:
        raise ContextError("iOS release product identity is invalid")
    if ios_release.get("channels") != {"internal": "internal", "external": "external"}:
        raise ContextError("iOS release channels are invalid")
    if ios_release.get("triggers") != {
        "internal": "latest-green-main",
        "external": "server-v*",
    }:
        raise ContextError("iOS release triggers are invalid")
    if ios_release.get("runner") != {
        "labels": ["self-hosted", "macOS", "ARM64", "tron-ios-release"],
        "environment": "ios-testflight",
    }:
        raise ContextError("iOS release runner isolation is invalid")
    if mac_release != {
        "configuration_path": ".github/workflows/release-mac.yml",
        "channels": {"public": "public"},
        "triggers": {"public": "server-v*"},
    }:
        raise ContextError("Mac release ownership is invalid")
    if "buildkite" in json.dumps(release, sort_keys=True).lower():
        raise ContextError("Buildkite may not appear in release ownership")
    cutover = require_mapping(policy.get("cutover_gate"), "policy.cutover_gate")
    if cutover != {
        "minimum_representative_runs": 30,
        "minimum_observation_days": 30,
        "maximum_full_pull_request_p95_seconds": 480,
        "maximum_candidate_main_p95_seconds": 480,
        "maximum_green_main_to_testflight_p95_seconds": 600,
        "maximum_false_green_count": 0,
        "maximum_source_mismatch_count": 0,
        "maximum_candidate_provider_failure_rate": 0.01,
        "minimum_provider_failure_rate_improvement": 0.02,
        "maximum_paired_reliability_p_value": 0.05,
        "authority_change_policy": "prohibited-until-explicit-external-review",
    }:
        raise ContextError("CI cutover gate does not match the approved threshold")
    policy["main_branch"] = main_branch
    return policy


def detect_provider(environment: Mapping[str, str]) -> str:
    github = environment.get("GITHUB_ACTIONS") == "true"
    buildkite = environment.get("BUILDKITE") == "true"
    if github == buildkite:
        raise ContextError("exactly one supported CI provider marker must be true")
    return "github-actions" if github else "buildkite"


def authority(policy: Mapping[str, Any], provider: str) -> dict[str, Any]:
    selected = require_mapping(require_mapping(policy["providers"], "providers")[provider],
                               f"providers.{provider}")
    result = {
        "role": selected["role"],
        "shadow": selected["shadow"],
        "required_check_authority": selected["required_check_authority"],
        "release_authority": selected["release_authority"],
        "configuration_path": selected["configuration_path"],
    }
    if "bootstrap_configuration_path" in selected:
        result["bootstrap_configuration_path"] = selected["bootstrap_configuration_path"]
    return result


def source_identity(git: Git, ref: str, sha: str) -> dict[str, Any]:
    if git.head() != sha:
        raise ContextError("checked-out HEAD does not match the declared source commit")
    tree, parents = git.commit(sha)
    return {"ref": ref, "sha": sha, "tree": tree, "parents": parents}


def run_identity(provider: str, environment: Mapping[str, str]) -> dict[str, Any]:
    if provider == "github-actions":
        return {
            "id": str(positive_integer(require_env(environment, "GITHUB_RUN_ID"),
                                       "GITHUB_RUN_ID")),
            "number": positive_integer(require_env(environment, "GITHUB_RUN_NUMBER"),
                                       "GITHUB_RUN_NUMBER"),
            "attempt": positive_integer(require_env(environment, "GITHUB_RUN_ATTEMPT"),
                                        "GITHUB_RUN_ATTEMPT"),
        }
    build_id = require_env(environment, "BUILDKITE_BUILD_ID")
    try:
        canonical_id = str(uuid.UUID(build_id))
    except ValueError as error:
        raise ContextError("BUILDKITE_BUILD_ID must be a UUID") from error
    if canonical_id != build_id.lower():
        raise ContextError("BUILDKITE_BUILD_ID must use canonical UUID syntax")
    # Buildkite retries are job-local; a rebuild has a new build ID/number and
    # is therefore a new run. The provider-neutral run attempt is always one.
    retry = require_env(environment, "BUILDKITE_RETRY_COUNT")
    if not re.fullmatch(r"0|[1-9][0-9]*", retry):
        raise ContextError("BUILDKITE_RETRY_COUNT must be a non-negative integer")
    return {
        "id": canonical_id,
        "number": positive_integer(require_env(environment, "BUILDKITE_BUILD_NUMBER"),
                                   "BUILDKITE_BUILD_NUMBER"),
        "attempt": 1,
    }


def github_repository(payload: Mapping[str, Any], environment: Mapping[str, str]) -> str:
    repository = normalize_repository(require_env(environment, "GITHUB_REPOSITORY"),
                                      "GITHUB_REPOSITORY")
    payload_repository = require_mapping(payload.get("repository"), "event.repository")
    event_repository = normalize_repository(payload_repository.get("full_name"),
                                            "event.repository.full_name")
    if repository != event_repository:
        raise ContextError("GITHUB_REPOSITORY does not match the event repository")
    repository_id = optional_env(environment, "GITHUB_REPOSITORY_ID")
    if repository_id is not None:
        event_id = payload_repository.get("id")
        if positive_integer(repository_id, "GITHUB_REPOSITORY_ID") != positive_integer(
                event_id, "event.repository.id"):
            raise ContextError("GITHUB_REPOSITORY_ID does not match the event repository")
    return repository


def github_context(policy: Mapping[str, Any], environment: Mapping[str, str],
                   git: Git) -> dict[str, Any]:
    event_name = require_env(environment, "GITHUB_EVENT_NAME")
    if event_name not in policy["supported_events"]:
        raise ContextError(f"unsupported GitHub event {event_name!r}")
    event_path = Path(require_env(environment, "GITHUB_EVENT_PATH"))
    payload = require_mapping(read_json(event_path, "GitHub event"), "GitHub event")
    repository = github_repository(payload, environment)
    main = policy["main_branch"]
    source_sha = normalize_sha(require_env(environment, "GITHUB_SHA"), "GITHUB_SHA")
    run = run_identity("github-actions", environment)

    if event_name == "pull_request":
        event_action = require_string(payload.get("action"), "event.action")
        if event_action not in GITHUB_PULL_REQUEST_ACTIONS:
            raise ContextError("GitHub pull request action is outside the CI workflow contract")
        pull = require_mapping(payload.get("pull_request"), "event.pull_request")
        number = positive_integer(payload.get("number"), "event.number")
        if positive_integer(pull.get("number"), "event.pull_request.number") != number:
            raise ContextError("pull-request numbers in the event disagree")
        base = require_mapping(pull.get("base"), "event.pull_request.base")
        head = require_mapping(pull.get("head"), "event.pull_request.head")
        base_ref = normalize_branch(base.get("ref"), "event.pull_request.base.ref")
        head_ref = normalize_branch(head.get("ref"), "event.pull_request.head.ref")
        if base_ref != main:
            raise ContextError("pull request does not target the policy main branch")
        if require_env(environment, "GITHUB_BASE_REF") != base_ref:
            raise ContextError("GITHUB_BASE_REF does not match the event")
        if require_env(environment, "GITHUB_HEAD_REF") != head_ref:
            raise ContextError("GITHUB_HEAD_REF does not match the event")
        expected_ref = policy["pull_request_merge_ref"].format(number=number)
        if require_env(environment, "GITHUB_REF") != expected_ref:
            raise ContextError("GITHUB_REF is not the exact pull-request merge ref")
        if require_env(environment, "GITHUB_REF_NAME") != f"{number}/merge":
            raise ContextError("GITHUB_REF_NAME does not match the pull request")
        if require_env(environment, "GITHUB_REF_TYPE") != "branch":
            raise ContextError("GITHUB_REF_TYPE must be branch")
        base_sha = normalize_sha(base.get("sha"), "event.pull_request.base.sha")
        head_sha = normalize_sha(head.get("sha"), "event.pull_request.head.sha")
        # GitHub defines GITHUB_SHA as the commit currently selected by the
        # pull-request merge ref. The webhook snapshot's merge_commit_sha may
        # be null or may lag a ref regeneration, so it is schema-checked when
        # present but never admitted as source authority. Exactness comes from
        # the ref, GITHUB_SHA, checked-out HEAD, and ordered base/head parents.
        optional_sha(
            pull.get("merge_commit_sha"), "event.pull_request.merge_commit_sha"
        )
        base_repo = normalize_repository(
            require_mapping(base.get("repo"), "event.pull_request.base.repo").get("full_name"),
            "event.pull_request.base.repo.full_name",
        )
        head_repo = normalize_repository(
            require_mapping(head.get("repo"), "event.pull_request.head.repo").get("full_name"),
            "event.pull_request.head.repo.full_name",
        )
        if base_repo != repository:
            raise ContextError("pull-request base repository is not the event repository")
        source = source_identity(git, expected_ref, source_sha)
        if source["parents"] != [base_sha, head_sha]:
            raise ContextError("GitHub merge commit parents do not match declared base/head")
        draft = require_bool(pull.get("draft"), "event.pull_request.draft")
        pull_request: dict[str, Any] | None = {"number": number, "draft": draft}
        base_identity = {"repository": base_repo, "ref": base_ref, "sha": base_sha}
        head_identity = {"repository": head_repo, "ref": head_ref, "sha": head_sha}
    elif event_name == "push":
        event_action = None
        expected_ref = f"refs/heads/{main}"
        if payload.get("ref") != expected_ref:
            raise ContextError("push event ref is not the policy main branch")
        if require_env(environment, "GITHUB_REF") != expected_ref:
            raise ContextError("GITHUB_REF does not match the push event")
        if require_env(environment, "GITHUB_REF_NAME") != main:
            raise ContextError("GITHUB_REF_NAME is not the policy main branch")
        if require_env(environment, "GITHUB_REF_TYPE") != "branch":
            raise ContextError("GITHUB_REF_TYPE must be branch")
        if payload.get("deleted") is not False:
            raise ContextError("deleted pushes cannot produce CI context")
        before_sha = normalize_sha(payload.get("before"), "event.before")
        after_sha = normalize_sha(payload.get("after"), "event.after")
        if after_sha != source_sha:
            raise ContextError("GITHUB_SHA does not match event.after")
        source = source_identity(git, expected_ref, source_sha)
        pull_request = None
        base_identity = {"repository": repository, "ref": main, "sha": before_sha}
        head_identity = {"repository": repository, "ref": main, "sha": after_sha}
    else:
        event_action = None
        ref_name = normalize_branch(
            require_env(environment, "GITHUB_REF_NAME"), "GITHUB_REF_NAME"
        )
        ref_type = require_env(environment, "GITHUB_REF_TYPE")
        if ref_type == "branch":
            expected_ref = f"refs/heads/{ref_name}"
        elif ref_type == "tag":
            expected_ref = f"refs/tags/{ref_name}"
        else:
            raise ContextError("workflow dispatch ref type must be branch or tag")
        if payload.get("ref") not in (ref_name, expected_ref):
            raise ContextError("workflow dispatch payload ref does not match the selected ref")
        if require_env(environment, "GITHUB_REF") != expected_ref:
            raise ContextError("GITHUB_REF does not match the workflow dispatch")
        source = source_identity(git, expected_ref, source_sha)
        base_sha = source["parents"][0] if source["parents"] else source_sha
        pull_request = None
        base_identity = {
            "repository": repository,
            "ref": ref_name,
            "sha": base_sha,
        }
        head_identity = {"repository": repository, "ref": ref_name, "sha": source_sha}

    return {
        "schema": SCHEMA,
        "provider": "github-actions",
        "authority": authority(policy, "github-actions"),
        "event": {
            "kind": event_name,
            "provider_name": event_name,
            "action": event_action,
        },
        "repository": {"slug": repository, "main_branch": main},
        "run": run,
        "pull_request": pull_request,
        "base": base_identity,
        "head": head_identity,
        "source": source,
    }


def buildkite_repository(environment: Mapping[str, str], git: Git) -> str:
    repository = repository_from_url(require_env(environment, "BUILDKITE_REPO"),
                                     "BUILDKITE_REPO")
    remote_repository = repository_from_url(git.raw_remote_url("origin"),
                                            "git remote origin")
    if remote_repository != repository:
        raise ContextError("Buildkite repository does not match git remote origin")
    return repository


def buildkite_context(policy: Mapping[str, Any], environment: Mapping[str, str],
                      git: Git, *, fetch_merge: bool,
                      webhook: Mapping[str, Any] | None) -> dict[str, Any]:
    repository = buildkite_repository(environment, git)
    if webhook is None:
        raise ContextError("Buildkite source context requires its immutable webhook payload")
    webhook_repository = normalize_repository(
        require_mapping(webhook.get("repository"), "Buildkite webhook.repository").get(
            "full_name"
        ),
        "Buildkite webhook.repository.full_name",
    )
    if webhook_repository != repository:
        raise ContextError("Buildkite webhook repository differs from the build repository")
    main = policy["main_branch"]
    run = run_identity("buildkite", environment)
    pull_value = require_env(environment, "BUILDKITE_PULL_REQUEST")
    github_event = require_env(environment, "BUILDKITE_GITHUB_EVENT")
    if optional_env(environment, "BUILDKITE_TAG") is not None:
        raise ContextError("tag builds are outside the shadow CI contract")

    if pull_value != "false":
        if github_event != "pull_request":
            raise ContextError("Buildkite pull request was not triggered by a pull_request event")
        github_action = require_env(environment, "BUILDKITE_GITHUB_ACTION")
        if github_action not in BUILDKITE_PULL_REQUEST_ACTIONS:
            raise ContextError("Buildkite pull request action is outside the shadow contract")
        if webhook.get("action") != github_action:
            raise ContextError("Buildkite pull-request action differs from its webhook")
        draft = environment.get("BUILDKITE_PULL_REQUEST_DRAFT", "false")
        if draft not in ("true", "false"):
            raise ContextError("BUILDKITE_PULL_REQUEST_DRAFT must be true or false")
        if draft == "true":
            raise ContextError("draft pull requests are outside the shadow CI contract")
        number = positive_integer(pull_value, "BUILDKITE_PULL_REQUEST")
        webhook_number = positive_integer(webhook.get("number"), "Buildkite webhook.number")
        webhook_pull = require_mapping(
            webhook.get("pull_request"), "Buildkite webhook.pull_request"
        )
        if (
            webhook_number != number
            or positive_integer(
                webhook_pull.get("number"), "Buildkite webhook.pull_request.number"
            )
            != number
        ):
            raise ContextError("Buildkite pull-request number differs from its webhook")
        webhook_draft = require_bool(
            webhook_pull.get("draft"), "Buildkite webhook.pull_request.draft"
        )
        if webhook_draft:
            raise ContextError("draft pull requests are outside the shadow CI contract")
        webhook_base = require_mapping(
            webhook_pull.get("base"), "Buildkite webhook.pull_request.base"
        )
        webhook_head = require_mapping(
            webhook_pull.get("head"), "Buildkite webhook.pull_request.head"
        )
        base_ref = normalize_branch(
            require_env(environment, "BUILDKITE_PULL_REQUEST_BASE_BRANCH"),
            "BUILDKITE_PULL_REQUEST_BASE_BRANCH",
        )
        webhook_base_ref = normalize_branch(
            webhook_base.get("ref"), "Buildkite webhook.pull_request.base.ref"
        )
        if webhook_base_ref != base_ref:
            raise ContextError("Buildkite pull-request base branch differs from its webhook")
        if base_ref != main:
            raise ContextError("Buildkite pull request does not target policy main")
        head_ref = normalize_branch(require_env(environment, "BUILDKITE_BRANCH"),
                                    "BUILDKITE_BRANCH")
        webhook_head_ref = normalize_branch(
            webhook_head.get("ref"), "Buildkite webhook.pull_request.head.ref"
        )
        if webhook_head_ref != head_ref:
            raise ContextError("Buildkite pull-request head branch differs from its webhook")
        head_repo = repository_from_url(
            require_env(environment, "BUILDKITE_PULL_REQUEST_REPO"),
            "BUILDKITE_PULL_REQUEST_REPO",
        )
        webhook_base_repo = normalize_repository(
            require_mapping(
                webhook_base.get("repo"), "Buildkite webhook.pull_request.base.repo"
            ).get("full_name"),
            "Buildkite webhook.pull_request.base.repo.full_name",
        )
        webhook_head_repo = normalize_repository(
            require_mapping(
                webhook_head.get("repo"), "Buildkite webhook.pull_request.head.repo"
            ).get("full_name"),
            "Buildkite webhook.pull_request.head.repo.full_name",
        )
        if webhook_base_repo != repository or webhook_head_repo != head_repo:
            raise ContextError("Buildkite pull-request repositories differ from its webhook")
        head_sha = declared_sha(
            environment,
            ("BUILDKITE_COMMIT", "BUILDKITE_PULL_REQUEST_HEAD_SHA", "TRON_CI_HEAD_SHA"),
            "pull-request head SHA",
            required=True,
        )
        assert head_sha is not None
        webhook_head_sha = normalize_sha(
            webhook_head.get("sha"), "Buildkite webhook.pull_request.head.sha"
        )
        if webhook_head_sha != head_sha:
            raise ContextError("Buildkite pull-request head SHA differs from its webhook")
        declared_base = normalize_sha(
            webhook_base.get("sha"), "Buildkite webhook.pull_request.base.sha"
        )
        # The cached GitHub webhook has the same asynchronous merge-ref race as
        # Actions: merge_commit_sha may be null or stale. It is observational,
        # while immutable webhook base/head identities anchor the fetched ref.
        optional_sha(
            webhook_pull.get("merge_commit_sha"),
            "Buildkite webhook.pull_request.merge_commit_sha",
        )
        source_ref = policy["pull_request_merge_ref"].format(number=number)
        local_ref = f"refs/tron-ci/provider-context/pull/{number}/merge"
        if fetch_merge:
            fetched_source = git.fetch_pull_merge(
                "origin", number, source_ref, local_ref, [declared_base, head_sha]
            )
            # Detach by the accepted object ID, never by a ref that could be
            # changed by another local process between verification/checkout.
            git.checkout(fetched_source)
        source_sha = git.head()
        source = source_identity(git, source_ref, source_sha)
        if len(source["parents"]) != 2:
            raise ContextError("GitHub pull-request merge commit must have exactly two parents")
        base_sha, actual_head = source["parents"]
        if actual_head != head_sha:
            raise ContextError("merge commit second parent does not match Buildkite head")
        if declared_base != base_sha:
            raise ContextError("merge commit first parent differs from the immutable webhook")
        declared_tree = declared_sha(environment, ("TRON_CI_SOURCE_TREE",),
                                     "pull-request source tree")
        if declared_tree is not None and declared_tree != source["tree"]:
            raise ContextError("merge tree does not match TRON_CI_SOURCE_TREE")
        event_kind = "pull_request"
        pull_request: dict[str, Any] | None = {"number": number, "draft": False}
        base_identity = {"repository": repository, "ref": base_ref, "sha": base_sha}
        head_identity = {"repository": head_repo, "ref": head_ref, "sha": head_sha}
    else:
        if github_event != "push":
            raise ContextError("Buildkite main build was not triggered by a push event")
        branch = normalize_branch(require_env(environment, "BUILDKITE_BRANCH"),
                                  "BUILDKITE_BRANCH")
        if branch != main:
            raise ContextError("non-PR Buildkite build is not the policy main branch")
        head_sha = declared_sha(environment, ("BUILDKITE_COMMIT", "TRON_CI_HEAD_SHA"),
                                "main head SHA", required=True)
        assert head_sha is not None
        if webhook.get("ref") != f"refs/heads/{main}":
            raise ContextError("Buildkite push webhook is not for policy main")
        if webhook.get("deleted") is not False:
            raise ContextError("deleted Buildkite pushes cannot produce CI context")
        webhook_after = normalize_sha(webhook.get("after"), "Buildkite webhook.after")
        webhook_before = normalize_sha(webhook.get("before"), "Buildkite webhook.before")
        if webhook_after != head_sha:
            raise ContextError("Buildkite main SHA differs from push webhook.after")
        if git.head() != head_sha:
            raise ContextError("Buildkite main checkout does not match BUILDKITE_COMMIT")
        source_ref = f"refs/heads/{main}"
        source = source_identity(git, source_ref, head_sha)
        declared_source = declared_sha(environment, ("TRON_CI_SOURCE_SHA",),
                                       "main source SHA")
        if declared_source is not None and declared_source != head_sha:
            raise ContextError("main source SHA declarations disagree")
        declared_tree = declared_sha(environment, ("TRON_CI_SOURCE_TREE",),
                                     "main source tree")
        if declared_tree is not None and declared_tree != source["tree"]:
            raise ContextError("main source tree declarations disagree")
        declared_base = webhook_before
        event_kind = "push"
        pull_request = None
        base_identity = {"repository": repository, "ref": main, "sha": declared_base}
        head_identity = {"repository": repository, "ref": main, "sha": head_sha}

    return {
        "schema": SCHEMA,
        "provider": "buildkite",
        "authority": authority(policy, "buildkite"),
        "event": {
            "kind": event_kind,
            "provider_name": github_event,
            "action": github_action if event_kind == "pull_request" else None,
        },
        "repository": {"slug": repository, "main_branch": main},
        "run": run,
        "pull_request": pull_request,
        "base": base_identity,
        "head": head_identity,
        "source": source,
    }


def resolve_context(policy: Mapping[str, Any], environment: Mapping[str, str],
                    git: Git, *, fetch_merge: bool = False,
                    webhook: Mapping[str, Any] | None = None) -> dict[str, Any]:
    provider = detect_provider(environment)
    if provider == "github-actions":
        if fetch_merge:
            # actions/checkout owns GitHub checkouts; identity checks remain exact.
            pass
        return github_context(policy, environment, git)
    return buildkite_context(
        policy, environment, git, fetch_merge=fetch_merge, webhook=webhook
    )


def validate_context_document(document: Any, policy: Mapping[str, Any]) -> dict[str, Any]:
    context = require_mapping(document, "provider context")
    require_keys(
        context,
        {"schema", "provider", "authority", "event", "repository", "run",
         "pull_request", "base", "head", "source"},
        "provider context",
    )
    if context.get("schema") != SCHEMA:
        raise ContextError("unsupported provider context schema")
    provider = require_string(context.get("provider"), "context.provider")
    if provider not in ("github-actions", "buildkite"):
        raise ContextError("context.provider is unsupported")
    if context.get("authority") != authority(policy, provider):
        raise ContextError("context authority does not match CI policy")
    event = require_mapping(context.get("event"), "context.event")
    require_keys(event, {"kind", "provider_name", "action"}, "context.event")
    kind = require_string(event.get("kind"), "context.event.kind")
    if kind not in policy["supported_events"]:
        raise ContextError("context event is unsupported")
    if event.get("provider_name") != kind:
        raise ContextError("context provider event does not match normalized event")
    action = event.get("action")
    if kind == "pull_request":
        action = require_string(action, "context.event.action")
        allowed_actions = (
            BUILDKITE_PULL_REQUEST_ACTIONS
            if provider == "buildkite"
            else GITHUB_PULL_REQUEST_ACTIONS
        )
        if action not in allowed_actions:
            raise ContextError("context pull-request action is outside the provider contract")
    elif action is not None:
        raise ContextError("non-pull-request context may not declare an action")
    if provider == "buildkite" and kind not in ("pull_request", "push"):
        raise ContextError("Buildkite context event is outside the shadow contract")
    repository = require_mapping(context.get("repository"), "context.repository")
    require_keys(repository, {"slug", "main_branch"}, "context.repository")
    slug = normalize_repository(repository.get("slug"), "context.repository.slug")
    if normalize_branch(repository.get("main_branch"), "context.repository.main_branch") != policy["main_branch"]:
        raise ContextError("context main branch does not match CI policy")
    run = require_mapping(context.get("run"), "context.run")
    require_keys(run, {"id", "number", "attempt"}, "context.run")
    run_id = require_string(run.get("id"), "context.run.id")
    if provider == "github-actions":
        positive_integer(run_id, "context.run.id")
    else:
        try:
            if str(uuid.UUID(run_id)) != run_id:
                raise ValueError
        except ValueError as error:
            raise ContextError("Buildkite context run ID must be a canonical UUID") from error
    positive_integer(run.get("number"), "context.run.number")
    run_attempt = positive_integer(run.get("attempt"), "context.run.attempt")
    if provider == "buildkite" and run_attempt != 1:
        raise ContextError("Buildkite build context attempt must be one")
    base = require_mapping(context.get("base"), "context.base")
    head = require_mapping(context.get("head"), "context.head")
    source = require_mapping(context.get("source"), "context.source")
    for name, identity in (("base", base), ("head", head)):
        require_keys(identity, {"repository", "ref", "sha"}, f"context.{name}")
        normalize_repository(identity.get("repository"), f"context.{name}.repository")
        normalize_branch(identity.get("ref"), f"context.{name}.ref")
        normalize_sha(identity.get("sha"), f"context.{name}.sha")
    require_keys(source, {"ref", "sha", "tree", "parents"}, "context.source")
    source_sha = normalize_sha(source.get("sha"), "context.source.sha")
    normalize_sha(source.get("tree"), "context.source.tree")
    require_string(source.get("ref"), "context.source.ref")
    parents = source.get("parents")
    if not isinstance(parents, list):
        raise ContextError("context.source.parents must be an array")
    normalized_parents = [normalize_sha(parent, "context.source.parents[]") for parent in parents]
    if kind == "pull_request":
        pull = require_mapping(context.get("pull_request"), "context.pull_request")
        require_keys(pull, {"number", "draft"}, "context.pull_request")
        number = positive_integer(pull.get("number"), "context.pull_request.number")
        draft = require_bool(pull.get("draft"), "context.pull_request.draft")
        if provider == "buildkite" and draft:
            raise ContextError("Buildkite shadow context may not represent a draft")
        expected_ref = policy["pull_request_merge_ref"].format(number=number)
        if source.get("ref") != expected_ref:
            raise ContextError("context source ref does not match pull-request number")
        if normalized_parents != [base["sha"], head["sha"]]:
            raise ContextError("context merge parents do not match base/head identities")
        if base["ref"] != policy["main_branch"]:
            raise ContextError("context pull-request base is not policy main")
    elif kind == "push":
        if context.get("pull_request") is not None:
            raise ContextError("push context must not contain a pull request")
        if source.get("ref") != f"refs/heads/{policy['main_branch']}":
            raise ContextError("push context source is not policy main")
        if source_sha != head["sha"]:
            raise ContextError("push context source and head SHAs disagree")
        if base["ref"] != policy["main_branch"] or head["ref"] != policy["main_branch"]:
            raise ContextError("main context base/head refs are not policy main")
    else:
        if context.get("pull_request") is not None:
            raise ContextError("workflow dispatch context must not contain a pull request")
        if source_sha != head["sha"] or base["ref"] != head["ref"]:
            raise ContextError("workflow dispatch source/base/head identities disagree")
        expected_refs = {
            f"refs/heads/{head['ref']}",
            f"refs/tags/{head['ref']}",
        }
        if source.get("ref") not in expected_refs:
            raise ContextError("workflow dispatch source ref is not its selected branch or tag")
        expected_base = normalized_parents[0] if normalized_parents else source_sha
        if base["sha"] != expected_base:
            raise ContextError("workflow dispatch base is not the source's first parent")
    if base["repository"] != slug or (kind != "pull_request" and head["repository"] != slug):
        raise ContextError("context repository identities disagree")
    return context


def compare_expected(actual: Mapping[str, Any], expected: Mapping[str, Any]) -> None:
    if actual != expected:
        raise ContextError("resolved provider context does not exactly match pinned context")


def bundle_ref(source_sha: str) -> str:
    return f"refs/tron-ci/provider-context/bundles/{source_sha}"


def bundle_prerequisites(context: Mapping[str, Any]) -> list[str]:
    if context["event"]["kind"] == "pull_request":
        candidates = [context["base"]["sha"], context["head"]["sha"]]
    else:
        candidates = [context["base"]["sha"]]
    return list(dict.fromkeys(candidates))


def inspect_bundle(path: Path, source_sha: str, prerequisites: Sequence[str]) -> None:
    try:
        # A bundle payload can be large for a legitimate source change. Only
        # the bounded textual header is needed to prove prerequisites/heads.
        with path.open("rb") as stream:
            raw = stream.read(16386)
    except OSError as error:
        raise ContextError(f"cannot read source bundle: {error}") from error
    boundary = raw.find(b"\n\n")
    if boundary < 0 or boundary > 16384:
        raise ContextError("source bundle has an invalid header")
    try:
        lines = raw[:boundary].decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ContextError("source bundle header is not UTF-8") from error
    actual_prerequisites = {
        normalize_sha(line[1:].split(" ", 1)[0], "bundle prerequisite")
        for line in lines if line.startswith("-")
    }
    if actual_prerequisites != set(prerequisites):
        raise ContextError("source bundle prerequisites do not match pinned base/head")
    reference = bundle_ref(source_sha)
    heads = [line for line in lines if re.match(r"^[0-9a-fA-F]{40} ", line)]
    if heads != [f"{source_sha} {reference}"]:
        raise ContextError(
            "source bundle does not contain exactly the pinned source ref "
            f"(found {heads!r})"
        )


def create_bundle(git: Git, context_path: Path, output: Path,
                  policy: Mapping[str, Any], environment: Mapping[str, str],
                  webhook: Mapping[str, Any] | None = None) -> None:
    expected = validate_context_document(read_json(context_path, "provider context"), policy)
    actual = resolve_context(policy, environment, git, webhook=webhook)
    compare_expected(actual, expected)
    source_sha = expected["source"]["sha"]
    reference = bundle_ref(source_sha)
    previous = git.run("show-ref", "--verify", "--hash", reference) if _ref_exists(git, reference) else None
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", dir=output.parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    temporary.unlink()
    try:
        git.run("update-ref", reference, source_sha)
        prerequisites = bundle_prerequisites(expected)
        for prerequisite in prerequisites:
            git.ensure_commit(prerequisite, "bundle prerequisite")
        git.run("bundle", "create", str(temporary), reference,
                *(f"^{prerequisite}" for prerequisite in prerequisites))
        git.run("bundle", "verify", str(temporary))
        inspect_bundle(temporary, source_sha, prerequisites)
        temporary.replace(output)
    finally:
        if previous is None:
            git.run("update-ref", "-d", reference)
        else:
            git.run("update-ref", reference, previous)
        if temporary.exists():
            temporary.unlink()


def _ref_exists(git: Git, reference: str) -> bool:
    process = subprocess.run(
        ["git", "-C", str(git.root), "show-ref", "--verify", "--quiet", reference],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return process.returncode == 0


def import_expected_checkout(git: Git, expected: Mapping[str, Any], bundle: Path | None) -> None:
    source_sha = expected["source"]["sha"]
    reference = bundle_ref(source_sha)
    if bundle is not None:
        if not bundle.is_file():
            raise ContextError("pinned source bundle is missing")
        remote_repository = repository_from_url(git.raw_remote_url("origin"),
                                                "git remote origin")
        if remote_repository != expected["repository"]["slug"]:
            raise ContextError("pinned context repository does not match git remote origin")
        prerequisites = bundle_prerequisites(expected)
        inspect_bundle(bundle, source_sha, prerequisites)
        for prerequisite in prerequisites:
            git.ensure_or_fetch_commit("origin", prerequisite,
                                       "pinned bundle prerequisite")
        heads = git.run("bundle", "list-heads", str(bundle)).splitlines()
        if heads != [f"{source_sha} {reference}"]:
            raise ContextError("source bundle does not contain exactly the pinned context ref")
        local_ref = f"refs/tron-ci/provider-context/pinned/{source_sha}"
        git.run("fetch", "--no-tags", "--force", "--no-recurse-submodules",
                str(bundle), f"+{reference}:{local_ref}")
        git.checkout(local_ref)
    else:
        git.checkout(source_sha)


def write_json(document: Mapping[str, Any], output: Path | None) -> None:
    encoded = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(encoded)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", dir=output.parent, prefix=f".{output.name}.", delete=False
        ) as handle:
            handle.write(encoded)
            temporary = Path(handle.name)
        temporary.replace(output)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def export_shell(document: Mapping[str, Any]) -> str:
    pull_request = document["pull_request"]
    values: list[tuple[str, Any]] = [
        ("TRON_CI_PROVIDER", document["provider"]),
        ("TRON_CI_EVENT_NAME", document["event"]["kind"]),
        ("TRON_CI_REPOSITORY", document["repository"]["slug"]),
        ("TRON_CI_RUN_ID", document["run"]["id"]),
        ("TRON_CI_RUN_NUMBER", document["run"]["number"]),
        ("TRON_CI_RUN_ATTEMPT", document["run"]["attempt"]),
        ("TRON_CI_PR_NUMBER", pull_request["number"] if pull_request else ""),
        ("TRON_CI_PR_HEAD_SHA", document["head"]["sha"]),
        ("TRON_CI_PR_BASE_SHA", document["base"]["sha"]),
        ("TRON_CI_SOURCE_SHA", document["source"]["sha"]),
        ("TRON_CI_SOURCE_TREE", document["source"]["tree"]),
        ("TRON_CI_SOURCE_REF", document["source"]["ref"]),
        ("TRON_CI_BASE_REF", document["base"]["ref"]),
        ("TRON_CI_HEAD_REF", document["head"]["ref"]),
        ("TRON_CI_AUTHORITY_ROLE", document["authority"]["role"]),
        ("TRON_CI_SHADOW", str(document["authority"]["shadow"]).lower()),
        ("TRON_CI_RELEASE_AUTHORITY",
         str(document["authority"]["release_authority"]).lower()),
        ("TRON_CI_REQUIRED_CHECK_AUTHORITY",
         str(document["authority"]["required_check_authority"]).lower()),
    ]
    return "\n".join(f"export {name}={shlex.quote(str(value))}" for name, value in values) + "\n"


def fixture_repository(root: Path) -> tuple[Git, dict[str, str], Path]:
    seed = root / "seed"
    origin = root / "origin.git"
    checkout = root / "checkout"
    subprocess.run(["git", "init", "-q", "-b", "main", str(seed)], check=True)
    fixture_environment = {
        **os.environ,
        "GIT_AUTHOR_NAME": "CI",
        "GIT_AUTHOR_EMAIL": "ci@example.invalid",
        "GIT_COMMITTER_NAME": "CI",
        "GIT_COMMITTER_EMAIL": "ci@example.invalid",
    }

    def fixture_git(directory: Path, *arguments: str) -> str:
        return subprocess.check_output(["git", "-C", str(directory), *arguments],
                                       text=True, env=fixture_environment).strip()

    (seed / "fixture.txt").write_text("base\n")
    fixture_git(seed, "add", "fixture.txt")
    fixture_git(seed, "commit", "-q", "-m", "base")
    base = fixture_git(seed, "rev-parse", "HEAD")
    fixture_git(seed, "checkout", "-q", "-b", "feature")
    (seed / "fixture.txt").write_text("head\n")
    fixture_git(seed, "commit", "-q", "-am", "head")
    head = fixture_git(seed, "rev-parse", "HEAD")
    fixture_git(seed, "checkout", "-q", "main")
    fixture_git(seed, "merge", "-q", "--no-ff", "feature", "-m", "merge")
    merge = fixture_git(seed, "rev-parse", "HEAD")
    tree = fixture_git(seed, "rev-parse", "HEAD^{tree}")
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    fixture_git(seed, "push", "-q", str(origin), f"{base}:refs/heads/main",
                f"{head}:refs/heads/feature", f"{merge}:refs/pull/42/merge")
    subprocess.run(["git", "init", "-q", str(checkout)], check=True)
    git = Git(checkout)
    github_url = "https://github.com/example/tron.git"
    git.run("config", f"url.{origin.as_uri()}.insteadOf", github_url)
    git.run("remote", "add", "origin", github_url)
    git.run("fetch", "--no-tags", "origin", "refs/heads/feature")
    git.run("fetch", "--no-tags", "origin", "refs/pull/42/merge")
    git.checkout("FETCH_HEAD")
    return git, {"base": base, "head": head, "merge": merge, "tree": tree}, origin


def github_fixture(path: Path, commits: Mapping[str, str], *, pull_request: bool) -> dict[str, str]:
    common = {
        "GITHUB_ACTIONS": "true",
        "GITHUB_REPOSITORY": "example/tron",
        "GITHUB_REPOSITORY_ID": "123",
        "GITHUB_RUN_ID": "9001",
        "GITHUB_RUN_NUMBER": "17",
        "GITHUB_RUN_ATTEMPT": "2",
        "GITHUB_REF_TYPE": "branch",
        "GITHUB_EVENT_PATH": str(path),
    }
    if pull_request:
        payload = {
            "action": "opened",
            "number": 42,
            "repository": {"id": 123, "full_name": "example/tron"},
            "pull_request": {
                "number": 42,
                "draft": False,
                "merge_commit_sha": commits["merge"],
                "base": {"ref": "main", "sha": commits["base"],
                         "repo": {"full_name": "example/tron"}},
                "head": {"ref": "feature", "sha": commits["head"],
                         "repo": {"full_name": "example/tron"}},
            },
        }
        common.update({
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_SHA": commits["merge"],
            "GITHUB_REF": "refs/pull/42/merge",
            "GITHUB_REF_NAME": "42/merge",
            "GITHUB_BASE_REF": "main",
            "GITHUB_HEAD_REF": "feature",
        })
    else:
        payload = {
            "ref": "refs/heads/main",
            "before": commits["base"],
            "after": commits["head"],
            "deleted": False,
            "repository": {"id": 123, "full_name": "example/tron"},
        }
        common.update({
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_SHA": commits["head"],
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REF_NAME": "main",
        })
    path.write_text(json.dumps(payload))
    return common


def buildkite_fixture(commits: Mapping[str, str], *, pull_request: bool) -> dict[str, str]:
    common = {
        "BUILDKITE": "true",
        "BUILDKITE_REPO": "https://github.com/example/tron.git",
        "BUILDKITE_BUILD_ID": "12345678-1234-4234-8234-123456789abc",
        "BUILDKITE_BUILD_NUMBER": "23",
        "BUILDKITE_RETRY_COUNT": "0",
        "BUILDKITE_COMMIT": commits["head"],
    }
    if pull_request:
        common.update({
            "BUILDKITE_GITHUB_EVENT": "pull_request",
            "BUILDKITE_GITHUB_ACTION": "opened",
            "BUILDKITE_PULL_REQUEST": "42",
            "BUILDKITE_PULL_REQUEST_BASE_BRANCH": "main",
            "BUILDKITE_PULL_REQUEST_DRAFT": "false",
            "BUILDKITE_PULL_REQUEST_REPO": "git@github.com:example/tron.git",
            "BUILDKITE_BRANCH": "feature",
        })
    else:
        common.update({
            "BUILDKITE_GITHUB_EVENT": "push",
            "BUILDKITE_PULL_REQUEST": "false",
            "BUILDKITE_BRANCH": "main",
        })
    return common


def buildkite_webhook(commits: Mapping[str, str], *, pull_request: bool) -> dict[str, Any]:
    repository = {"full_name": "example/tron"}
    if pull_request:
        return {
            "action": "opened",
            "number": 42,
            "repository": repository,
            "pull_request": {
                "number": 42,
                "draft": False,
                "merge_commit_sha": commits["merge"],
                "base": {
                    "ref": "main",
                    "sha": commits["base"],
                    "repo": repository,
                },
                "head": {
                    "ref": "feature",
                    "sha": commits["head"],
                    "repo": repository,
                },
            },
        }
    return {
        "ref": "refs/heads/main",
        "before": commits["base"],
        "after": commits["head"],
        "deleted": False,
        "repository": repository,
    }


def expect_failure(callback: Any, label: str) -> None:
    try:
        callback()
    except ContextError:
        return
    raise AssertionError(f"malformed fixture {label!r} was accepted")


def self_test() -> None:
    policy = load_policy()
    assert policy["release"]["provider"] == "github-actions"
    assert "buildkite" not in json.dumps(policy["release"], sort_keys=True).lower()
    with tempfile.TemporaryDirectory(prefix="tron-ci-context-") as directory:
        root = Path(directory)
        git, commits, origin = fixture_repository(root)

        github_pr_path = root / "github-pr.json"
        github_pr = github_fixture(github_pr_path, commits, pull_request=True)
        git.checkout(commits["merge"])
        github_pr_context = resolve_context(policy, github_pr, git)
        assert github_pr_context["source"]["tree"] == commits["tree"]
        assert github_pr_context["authority"]["role"] == "authoritative"
        github_pr_payload = read_json(github_pr_path, "GitHub PR fixture")
        github_pr_payload["action"] = "labeled"
        github_pr_path.write_text(json.dumps(github_pr_payload))
        expect_failure(
            lambda: resolve_context(policy, github_pr, git),
            "unmodeled GitHub pull-request action",
        )
        github_pr_payload["action"] = "opened"
        github_pr_path.write_text(json.dumps(github_pr_payload))

        # GitHub may regenerate refs/pull/<number>/merge after serializing the
        # webhook snapshot. The checked-out GITHUB_SHA remains authoritative
        # only when its ordered parents still equal the event base/head.
        for observed_merge in (commits["head"], None):
            lagged_payload = json.loads(json.dumps(github_pr_payload))
            lagged_payload["pull_request"]["merge_commit_sha"] = observed_merge
            github_pr_path.write_text(json.dumps(lagged_payload))
            lagged_context = resolve_context(policy, github_pr, git)
            assert lagged_context["source"] == github_pr_context["source"]
        malformed_merge_payload = json.loads(json.dumps(github_pr_payload))
        malformed_merge_payload["pull_request"]["merge_commit_sha"] = "not-a-sha"
        github_pr_path.write_text(json.dumps(malformed_merge_payload))
        expect_failure(
            lambda: resolve_context(policy, github_pr, git),
            "malformed observational GitHub merge SHA",
        )
        changed_base_payload = json.loads(json.dumps(github_pr_payload))
        changed_base_payload["pull_request"]["base"]["sha"] = commits["head"]
        github_pr_path.write_text(json.dumps(changed_base_payload))
        expect_failure(
            lambda: resolve_context(policy, github_pr, git),
            "GitHub merge commit with the wrong ordered parents",
        )
        github_pr_path.write_text(json.dumps(github_pr_payload))
        wrong_github_source = dict(github_pr)
        wrong_github_source["GITHUB_SHA"] = commits["head"]
        expect_failure(
            lambda: resolve_context(policy, wrong_github_source, git),
            "GitHub checkout that differs from GITHUB_SHA",
        )

        github_main_path = root / "github-main.json"
        github_main = github_fixture(github_main_path, commits, pull_request=False)
        git.checkout(commits["head"])
        github_main_context = resolve_context(policy, github_main, git)
        assert github_main_context["event"]["kind"] == "push"

        github_dispatch_path = root / "github-dispatch.json"
        github_dispatch_path.write_text(json.dumps({
            "ref": "feature",
            "repository": {"id": 123, "full_name": "example/tron"},
        }))
        github_dispatch = dict(github_main)
        github_dispatch.update({
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_EVENT_PATH": str(github_dispatch_path),
            "GITHUB_REF": "refs/heads/feature",
            "GITHUB_REF_NAME": "feature",
        })
        github_dispatch_context = resolve_context(policy, github_dispatch, git)
        assert github_dispatch_context["event"]["kind"] == "workflow_dispatch"
        assert github_dispatch_context["source"]["ref"] == "refs/heads/feature"

        github_dispatch_path.write_text(json.dumps({
            "ref": "v-test",
            "repository": {"id": 123, "full_name": "example/tron"},
        }))
        github_tag_dispatch = dict(github_dispatch)
        github_tag_dispatch.update({
            "GITHUB_REF": "refs/tags/v-test",
            "GITHUB_REF_NAME": "v-test",
            "GITHUB_REF_TYPE": "tag",
        })
        github_tag_context = resolve_context(policy, github_tag_dispatch, git)
        assert github_tag_context["source"]["ref"] == "refs/tags/v-test"

        buildkite_pr = buildkite_fixture(commits, pull_request=True)
        buildkite_pr_webhook = buildkite_webhook(commits, pull_request=True)
        git.checkout(commits["head"])
        original_commit = git.commit
        inspected_merge_count = 0

        def observe_propagating_merge(revision: str) -> tuple[str, list[str]]:
            nonlocal inspected_merge_count
            tree, parents = original_commit(revision)
            inspected_merge_count += 1
            if inspected_merge_count == 1:
                return tree, [commits["base"], commits["base"]]
            return tree, parents

        git.commit = observe_propagating_merge  # type: ignore[method-assign]
        try:
            fetched_merge = git.fetch_pull_merge(
                "origin",
                42,
                "refs/pull/42/merge",
                "refs/tron-ci/provider-context/test/merge",
                [commits["base"], commits["head"]],
            )
        finally:
            git.commit = original_commit  # type: ignore[method-assign]
        assert inspected_merge_count == 2
        assert fetched_merge == commits["merge"]
        resolve_context(
            policy, buildkite_pr, git, fetch_merge=True, webhook=buildkite_pr_webhook
        )
        buildkite_pr_context = resolve_context(
            policy, buildkite_pr, git, webhook=buildkite_pr_webhook
        )
        assert buildkite_pr_context["source"]["sha"] == commits["merge"]
        assert buildkite_pr_context["authority"] == authority(policy, "buildkite")
        assert buildkite_pr_context["source"] == github_pr_context["source"]
        exported = export_shell(buildkite_pr_context)
        assert f"export TRON_CI_SOURCE_SHA={commits['merge']}\n" in exported
        assert "export TRON_CI_SHADOW=true\n" in exported
        assert "export TRON_CI_RELEASE_AUTHORITY=false\n" in exported
        expect_failure(
            lambda: resolve_context(policy, buildkite_pr, git),
            "Buildkite PR without immutable webhook",
        )
        changed_base_webhook = json.loads(json.dumps(buildkite_pr_webhook))
        changed_base_webhook["pull_request"]["base"]["sha"] = commits["head"]
        expect_failure(
            lambda: resolve_context(
                policy, buildkite_pr, git, webhook=changed_base_webhook
            ),
            "Buildkite PR webhook base race",
        )
        changed_merge_webhook = json.loads(json.dumps(buildkite_pr_webhook))
        changed_merge_webhook["pull_request"]["merge_commit_sha"] = commits["head"]
        changed_merge_context = resolve_context(
            policy, buildkite_pr, git, webhook=changed_merge_webhook
        )
        assert changed_merge_context["source"] == buildkite_pr_context["source"]
        null_merge_webhook = json.loads(json.dumps(buildkite_pr_webhook))
        null_merge_webhook["pull_request"]["merge_commit_sha"] = None
        null_merge_context = resolve_context(
            policy, buildkite_pr, git, webhook=null_merge_webhook
        )
        assert null_merge_context["source"] == buildkite_pr_context["source"]
        malformed_merge_webhook = json.loads(json.dumps(buildkite_pr_webhook))
        malformed_merge_webhook["pull_request"]["merge_commit_sha"] = "not-a-sha"
        expect_failure(
            lambda: resolve_context(
                policy, buildkite_pr, git, webhook=malformed_merge_webhook
            ),
            "malformed observational Buildkite merge SHA",
        )

        context_path = root / "provider-context.json"
        bundle_path = root / "provider-source.bundle"
        write_json(buildkite_pr_context, context_path)
        create_bundle(
            git,
            context_path,
            bundle_path,
            policy,
            buildkite_pr,
            webhook=buildkite_pr_webhook,
        )
        assert bundle_path.stat().st_size < 65536
        inspect_bundle(
            bundle_path,
            buildkite_pr_context["source"]["sha"],
            [commits["base"], commits["head"]],
        )
        # A later job must remain pinned even if GitHub's moving merge ref has
        # changed since the source-context job created the bundle.
        subprocess.run(
            ["git", "--git-dir", str(origin), "update-ref",
             "refs/pull/42/merge", commits["head"]],
            check=True,
        )
        expected = validate_context_document(read_json(context_path, "fixture context"), policy)
        consumer_root = root / "consumer"
        subprocess.run(["git", "init", "-q", str(consumer_root)], check=True)
        consumer = Git(consumer_root)
        github_url = "https://github.com/example/tron.git"
        consumer.run("config", f"url.{origin.as_uri()}.insteadOf", github_url)
        consumer.run("remote", "add", "origin", github_url)
        assert not consumer.has_commit(commits["base"])
        assert not consumer.has_commit(commits["head"])
        import_expected_checkout(consumer, expected, bundle_path)
        assert consumer.has_commit(commits["base"])
        assert consumer.has_commit(commits["head"])
        compare_expected(
            resolve_context(
                policy, buildkite_pr, consumer, webhook=buildkite_pr_webhook
            ),
            expected,
        )

        buildkite_main = buildkite_fixture(commits, pull_request=False)
        buildkite_main_webhook = buildkite_webhook(commits, pull_request=False)
        git.checkout(commits["head"])
        buildkite_main_context = resolve_context(
            policy, buildkite_main, git, webhook=buildkite_main_webhook
        )
        assert buildkite_main_context["event"]["kind"] == "push"
        assert buildkite_main_context["base"]["sha"] == commits["base"]
        force_push_webhook = json.loads(json.dumps(buildkite_main_webhook))
        force_push_webhook["before"] = commits["merge"]
        force_push_context = resolve_context(
            policy, buildkite_main, git, webhook=force_push_webhook
        )
        assert force_push_context["base"]["sha"] == commits["merge"]
        expect_failure(
            lambda: resolve_context(policy, buildkite_main, git),
            "Buildkite main without immutable webhook",
        )

        missing_run = dict(github_pr)
        del missing_run["GITHUB_RUN_ID"]
        git.checkout(commits["merge"])
        expect_failure(lambda: resolve_context(policy, missing_run, git), "missing run ID")

        ambiguous = dict(buildkite_pr)
        ambiguous["GITHUB_ACTIONS"] = "true"
        expect_failure(
            lambda: resolve_context(
                policy, ambiguous, git, webhook=buildkite_pr_webhook
            ),
            "ambiguous provider",
        )

        wrong_head = dict(buildkite_pr)
        wrong_head["BUILDKITE_COMMIT"] = commits["base"]
        expect_failure(
            lambda: resolve_context(
                policy, wrong_head, git, webhook=buildkite_pr_webhook
            ),
            "wrong PR head",
        )

        unmodeled_action = dict(buildkite_pr)
        unmodeled_action["BUILDKITE_GITHUB_ACTION"] = "labeled"
        expect_failure(
            lambda: resolve_context(
                policy, unmodeled_action, git, webhook=buildkite_pr_webhook
            ),
            "unmodeled Buildkite pull-request action",
        )
        missing_action = dict(buildkite_pr)
        del missing_action["BUILDKITE_GITHUB_ACTION"]
        expect_failure(
            lambda: resolve_context(
                policy, missing_action, git, webhook=buildkite_pr_webhook
            ),
            "missing Buildkite pull-request action",
        )

        malformed_context = json.loads(json.dumps(buildkite_pr_context))
        malformed_context["source"]["tree"] = "not-a-tree"
        expect_failure(lambda: validate_context_document(malformed_context, policy),
                       "inconsistent source tree context")
        extra_context = json.loads(json.dumps(buildkite_pr_context))
        extra_context["unrecognized"] = True
        expect_failure(lambda: validate_context_document(extra_context, policy),
                       "unrecognized context key")
    print("CI provider context self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    commands = parser.add_subparsers(dest="command")
    checkout_parser = commands.add_parser("checkout", help="check out and verify provider source")
    checkout_parser.add_argument("--expected-context", type=Path)
    checkout_parser.add_argument("--bundle", type=Path)
    checkout_parser.add_argument("--webhook-payload", type=Path)
    resolve_parser = commands.add_parser("resolve", help="write normalized provider context JSON")
    resolve_parser.add_argument("--output", type=Path)
    resolve_parser.add_argument("--expected-context", type=Path)
    resolve_parser.add_argument("--webhook-payload", type=Path)
    bundle_parser = commands.add_parser("bundle", help="bundle one already-resolved source context")
    bundle_parser.add_argument("--context", type=Path, required=True)
    bundle_parser.add_argument("--output", type=Path, required=True)
    bundle_parser.add_argument("--webhook-payload", type=Path)
    export_parser = commands.add_parser("export", help="export normalized context fields")
    export_parser.add_argument("--context", type=Path, required=True)
    export_parser.add_argument("--format", choices=("shell",), required=True)
    arguments = parser.parse_args()
    if arguments.self_test and arguments.command is not None:
        parser.error("--self-test cannot be combined with a command")
    if not arguments.self_test and arguments.command is None:
        parser.error("a command is required")
    if arguments.command == "checkout" and arguments.bundle and not arguments.expected_context:
        parser.error("--bundle requires --expected-context")

    try:
        if arguments.self_test:
            self_test()
            return 0
        policy = load_policy()
        git = Git(ROOT)
        environment = dict(os.environ)
        webhook_path = getattr(arguments, "webhook_payload", None)
        webhook = (
            require_mapping(read_json(webhook_path, "Buildkite webhook payload"),
                            "Buildkite webhook payload")
            if webhook_path is not None
            else None
        )
        if arguments.command == "checkout":
            if arguments.expected_context:
                expected = validate_context_document(
                    read_json(arguments.expected_context, "expected provider context"), policy)
                if detect_provider(environment) != expected["provider"]:
                    raise ContextError("current provider does not match pinned context")
                import_expected_checkout(git, expected, arguments.bundle)
                actual = resolve_context(policy, environment, git, webhook=webhook)
                compare_expected(actual, expected)
            else:
                actual = resolve_context(
                    policy, environment, git, fetch_merge=True, webhook=webhook
                )
            print(f"verified {actual['provider']} source {actual['source']['sha']}")
        elif arguments.command == "resolve":
            actual = resolve_context(policy, environment, git, webhook=webhook)
            if arguments.expected_context:
                expected = validate_context_document(
                    read_json(arguments.expected_context, "expected provider context"), policy)
                compare_expected(actual, expected)
            write_json(actual, arguments.output)
        elif arguments.command == "bundle":
            create_bundle(
                git,
                arguments.context,
                arguments.output,
                policy,
                environment,
                webhook=webhook,
            )
        elif arguments.command == "export":
            context = validate_context_document(
                read_json(arguments.context, "provider context"), policy
            )
            sys.stdout.write(export_shell(context))
    except (ContextError, OSError) as error:
        print(f"CI provider context unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
