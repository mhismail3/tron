#!/usr/bin/env python3
"""Create and verify immutable evidence for Tron's merge validation.

Verification is deliberately fail-closed: any missing, ambiguous, stale, or
malformed evidence tells the caller to run the complete validation matrix.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

SCHEMA = "tron.validation.v1"
ARTIFACT_NAME = "tron-merge-validation"


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True).strip()


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty string")
    return value


def create(output: Path, ios_metrics: Path | None) -> None:
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        raise ValueError("validation evidence may only be created for pull requests")
    metrics: dict[str, Any] | None = None
    if ios_metrics and ios_metrics.exists():
        metrics = json.loads(ios_metrics.read_text())
    elif os.environ.get("TRON_IOS_METRICS_JSON"):
        metrics = json.loads(os.environ["TRON_IOS_METRICS_JSON"])
    if not metrics or metrics.get("schema") != "tron.ios-ci-metrics.v1":
        raise ValueError("iOS metrics are missing or use an unsupported schema")
    manifest = Path("config/ci-toolchain.env").read_bytes()
    document = {
        "schema": SCHEMA,
        "repository": require_text(os.environ.get("GITHUB_REPOSITORY"), "repository"),
        "pull_request": int(require_text(os.environ.get("TRON_PR_NUMBER"), "pull_request")),
        "head_sha": require_text(os.environ.get("TRON_PR_HEAD_SHA"), "head_sha"),
        "base_sha": require_text(os.environ.get("TRON_PR_BASE_SHA"), "base_sha"),
        "merge_sha": git("rev-parse", "HEAD"),
        "merge_tree": git("show", "-s", "--format=%T", "HEAD"),
        "workflow_run_id": int(require_text(os.environ.get("GITHUB_RUN_ID"), "workflow_run_id")),
        "workflow_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
        "toolchain_manifest_sha256": hashlib.sha256(manifest).hexdigest(),
        "jobs": {"rust": "success", "ios": "success", "mac": "success"},
        "ios": metrics,
    }
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
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
        return body if raw else json.loads(body)


def verify_document(document: Any, *, repository: str, main_sha: str, main_tree: str,
                    pull_request: int, run_id: int, artifact_digest: str,
                    toolchain_manifest_sha256: str) -> None:
    if not isinstance(document, dict) or document.get("schema") != SCHEMA:
        raise ValueError("unsupported validation evidence schema")
    expected = {
        "repository": repository,
        "pull_request": pull_request,
        "workflow_run_id": run_id,
        "merge_tree": main_tree,
    }
    for key, value in expected.items():
        if document.get(key) != value:
            raise ValueError(f"evidence {key} does not match the merged commit")
    require_text(document.get("head_sha"), "head_sha")
    require_text(document.get("base_sha"), "base_sha")
    require_text(document.get("merge_sha"), "merge_sha")
    if document.get("toolchain_manifest_sha256") != toolchain_manifest_sha256:
        raise ValueError("evidence toolchain manifest hash does not match")
    if document.get("jobs") != {"rust": "success", "ios": "success", "mac": "success"}:
        raise ValueError("evidence does not prove the complete validation matrix")
    ios = document.get("ios")
    if not isinstance(ios, dict) or ios.get("schema") != "tron.ios-ci-metrics.v1":
        raise ValueError("evidence does not contain valid iOS metrics")
    for field in ("build_seconds", "test_seconds", "test_exit_code", "xcresult_summary_sha256"):
        if field not in ios:
            raise ValueError(f"iOS metrics are missing {field}")
    if not artifact_digest.startswith("sha256:"):
        raise ValueError("GitHub did not report a SHA-256 artifact digest")
    if main_sha == document.get("merge_sha"):
        return
    # Squash/rebase and GitHub merge commits can have a different commit ID;
    # exact tree identity is the contract, enforced above.


def verify(output: Path) -> bool:
    repository = require_text(os.environ.get("GITHUB_REPOSITORY"), "repository")
    token = require_text(os.environ.get("GITHUB_TOKEN"), "GITHUB_TOKEN")
    main_sha = git("rev-parse", "HEAD")
    main_tree = git("show", "-s", "--format=%T", "HEAD")
    api = GitHub(repository, token)
    pulls = api.get(f"/commits/{main_sha}/pulls")
    merged = [item for item in pulls if item.get("merged_at") and item.get("base", {}).get("ref") == "main"]
    if len(merged) != 1:
        raise ValueError(f"expected one merged pull request for {main_sha}, found {len(merged)}")
    pr = merged[0]
    runs = api.get(f"/actions/workflows/ci.yml/runs?event=pull_request&head_sha={pr['head']['sha']}&status=completed&per_page=30")
    candidates = [run for run in runs.get("workflow_runs", []) if run.get("conclusion") == "success"]
    if not candidates:
        raise ValueError("no successful pull-request CI run exists for the merged head")

    matches: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for run in candidates:
        artifacts = api.get(f"/actions/runs/{run['id']}/artifacts?per_page=100")
        named = [item for item in artifacts.get("artifacts", []) if item.get("name") == ARTIFACT_NAME and not item.get("expired")]
        if len(named) == 1:
            matches.append((run, named[0]))
    if len(matches) != 1:
        raise ValueError(f"expected one usable validation artifact, found {len(matches)}")
    run, artifact = matches[0]
    archive = api.get(f"/actions/artifacts/{artifact['id']}/zip", raw=True)
    digest = hashlib.sha256(archive).hexdigest()
    reported = require_text(artifact.get("digest"), "artifact.digest")
    if reported != f"sha256:{digest}":
        raise ValueError("downloaded artifact does not match GitHub's digest")
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        names = [name for name in bundle.namelist() if name.endswith("validation-evidence.json")]
        if len(names) != 1:
            raise ValueError("validation artifact must contain exactly one evidence document")
        document = json.loads(bundle.read(names[0]))
    verify_document(
        document,
        repository=repository,
        main_sha=main_sha,
        main_tree=main_tree,
        pull_request=int(pr["number"]),
        run_id=int(run["id"]),
        artifact_digest=reported,
        toolchain_manifest_sha256=hashlib.sha256(Path("config/ci-toolchain.env").read_bytes()).hexdigest(),
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    return True


def self_test() -> None:
    valid = {
        "schema": SCHEMA,
        "repository": "example/tron",
        "pull_request": 42,
        "head_sha": "a" * 40,
        "base_sha": "b" * 40,
        "merge_sha": "c" * 40,
        "merge_tree": "d" * 40,
        "workflow_run_id": 99,
        "workflow_attempt": 1,
        "toolchain_manifest_sha256": "e" * 64,
        "jobs": {"rust": "success", "ios": "success", "mac": "success"},
        "ios": {
            "schema": "tron.ios-ci-metrics.v1",
            "build_seconds": 100,
            "test_seconds": 200,
            "test_exit_code": 0,
            "xcresult_summary_sha256": "1" * 64,
        },
    }
    verify_document(valid, repository="example/tron", main_sha="f" * 40,
                    main_tree="d" * 40, pull_request=42, run_id=99,
                    artifact_digest="sha256:" + "0" * 64,
                    toolchain_manifest_sha256="e" * 64)
    mutations = [
        ("schema", "old"), ("repository", "other/tron"), ("pull_request", 7),
        ("merge_tree", "0" * 40), ("workflow_run_id", 100), ("jobs", {}),
    ]
    for key, value in mutations:
        changed = dict(valid)
        changed[key] = value
        try:
            verify_document(changed, repository="example/tron", main_sha="f" * 40,
                            main_tree="d" * 40, pull_request=42, run_id=99,
                            artifact_digest="sha256:" + "0" * 64,
                            toolchain_manifest_sha256="e" * 64)
        except ValueError:
            continue
        raise AssertionError(f"invalid {key} was accepted")
    print("validation evidence self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    subparsers = parser.add_subparsers(dest="command")
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.add_argument("--ios-metrics", type=Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.self_test and args.command is None:
        parser.error("a command is required")
    try:
        if args.self_test:
            self_test()
        elif args.command == "create":
            create(args.output, args.ios_metrics)
        elif args.command == "verify":
            verify(args.output)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, urllib.error.URLError, zipfile.BadZipFile) as error:
        print(f"validation evidence unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
