#!/usr/bin/env bash
# Buildkite's secretless, non-authoritative CI parity adapter.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap_pipeline="$repo_root/.buildkite/pipeline.yml"
shadow_pipeline="$repo_root/.buildkite/shadow-steps.yml"
artifact_root="$repo_root/build/ci-shadow"

# shellcheck disable=SC1091
source "$repo_root/config/ci-toolchain.env"
rust_version="$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$repo_root/rust-toolchain.toml")"
readonly rust_version

required_jobs=(personal-info-guard version-drift workflow-lint rust ios mac)
release_environment_names=(
    APPLE_API_ISSUER_ID
    APPLE_API_KEY_ID
    APPLE_API_KEY_PATH
    APPLE_ID
    APP_PASSWORD
    ASC_ISSUER_ID
    ASC_KEY_ID
    ASC_KEY_P8_BASE64
    ASC_PRIVATE_KEY_PATH
    ASC_TESTFLIGHT_INTERNAL_GROUP_ID
    ASC_TESTFLIGHT_PUBLIC_GROUP_ID
    CERT_B64
    CERT_PATH
    CERT_PW
    GH_TOKEN
    IOS_APPSTORE_PROFILE_BASE64
    IOS_DISTRIBUTION_CERT_P12_BASE64
    IOS_DISTRIBUTION_CERT_PASSWORD
    IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64
    IOS_SIGNING_KEYCHAIN_PATH
    KEYCHAIN_PW
    KEYCHAIN_PW_FILE
    MACOS_CERT_P12_BASE64
    MACOS_CERT_PASSWORD
    NOTARIZE_APPLE_ID
    NOTARIZE_APP_PASSWORD
    NOTARIZE_TEAM_ID
    NOTARYTOOL_PROFILE
    TRON_P12_PASSWORD
)

usage() {
    cat <<'EOF'
Usage: scripts/ci-shadow-run.sh <workload>

Buildkite advisory workloads:
  source-context         Pin one exact source and upload its dynamic job graph
  notice                 Publish the non-authoritative build annotation
  personal-info-guard    Run the repository personal-information guard
  version-drift          Run version and deterministic helper contracts
  workflow-lint          Lint the authoritative GitHub workflows
  rust                   Run the complete Rust quality suite
  ios                    Build and test the iOS app with measured output
  mac                    Build/test the Mac wrapper and PR-only dry-run DMG
  evidence               Create ready-PR-only advisory validation evidence
  operational-observation Record every terminal workload outcome without gating

Local verification:
  --self-test            Validate this adapter and both pipeline definitions

This adapter has no release, signing, notarization, deployment, or promotion
operation. Every Buildkite workload is advisory and emits a SHA-256 manifest.
EOF
}

utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

assert_no_release_environment() {
    local name
    for name in "${release_environment_names[@]}"; do
        if [[ -n "${!name:-}" ]]; then
            echo "error: advisory CI refuses release environment variable: $name" >&2
            return 1
        fi
    done
    while IFS= read -r name; do
        case "$name" in
            APPLE_API_*|ASC_*KEY*|ASC_*ISSUER*|ASC_*PRIVATE*|CERT_*|KEYCHAIN_*|\
            IOS_*CERT*|IOS_*PASSWORD*|IOS_*PROFILE*|IOS_*KEYCHAIN*|\
            MACOS_*CERT*|MACOS_*PASSWORD*|NOTARIZE_*|NOTARYTOOL_*|TRON_*P12*)
                if [[ -n "${!name:-}" ]]; then
                    echo "error: advisory CI refuses release-shaped environment variable: $name" >&2
                    return 1
                fi
                ;;
        esac
    done < <(compgen -e)
}

assert_build_is_eligible() {
    if [[ "${TRON_CI_SHADOW_SELF_TEST:-false}" == "true" ]]; then
        return 0
    fi
    if [[ "${BUILDKITE:-false}" != "true" ]]; then
        echo "error: shadow workloads run only inside Buildkite" >&2
        return 1
    fi
    if [[ -n "${BUILDKITE_TAG:-}" ]]; then
        echo "error: shadow validation never runs for tags" >&2
        return 1
    fi
    if [[ "${TRON_CI_ADVISORY_ONLY:-}" != "true" ]]; then
        echo "error: shadow validation requires the advisory-only boundary" >&2
        return 1
    fi

    if [[ "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
        if [[ "${BUILDKITE_GITHUB_EVENT:-}" != "pull_request" ]]; then
            echo "error: shadow pull request must originate from a GitHub pull_request event" >&2
            return 1
        fi
        case "${BUILDKITE_GITHUB_ACTION:-}" in
            opened|synchronize|reopened|ready_for_review) ;;
            *)
                echo "error: shadow pull request action is outside the measured trigger contract" >&2
                return 1
                ;;
        esac
        if [[ "${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}" != "main" ]]; then
            echo "error: shadow pull request must target main" >&2
            return 1
        fi
        if [[ "${BUILDKITE_PULL_REQUEST_DRAFT:-false}" != "false" ]]; then
            echo "error: shadow validation does not run for draft pull requests" >&2
            return 1
        fi
        return 0
    fi

    if [[ "${BUILDKITE_BRANCH:-}" != "main" ]]; then
        echo "error: non-PR shadow validation runs only on main" >&2
        return 1
    fi
    if [[ "${BUILDKITE_GITHUB_EVENT:-}" != "push" ]]; then
        echo "error: shadow main validation must originate from a GitHub push event" >&2
        return 1
    fi
}

assert_buildkite_agent() {
    command -v buildkite-agent >/dev/null || {
        echo "error: Buildkite agent CLI is unavailable" >&2
        return 1
    }
}

capture_buildkite_webhook() {
    local output="$1"
    assert_buildkite_agent
    umask 077
    buildkite-agent meta-data get buildkite:webhook > "$output"
    [[ -s "$output" ]] || {
        echo "error: immutable Buildkite webhook payload is unavailable" >&2
        return 1
    }
}

start_timing() {
    export TRON_CI_SHADOW_STARTED_AT="${TRON_CI_SHADOW_STARTED_AT:-$(utc_now)}"
    export TRON_CI_SHADOW_STARTED_EPOCH="${TRON_CI_SHADOW_STARTED_EPOCH:-$(date +%s)}"
}

upload_shadow_pipeline() {
    local help_text upload_arguments
    if ! help_text="$(buildkite-agent pipeline upload --help 2>&1)"; then
        echo "error: cannot determine Buildkite pipeline secret-rejection semantics" >&2
        return 1
    fi
    if ! grep -Fq -- '--reject-parse-warnings' <<< "$help_text"; then
        echo "error: Buildkite agent cannot reject pipeline parse warnings" >&2
        return 1
    fi
    upload_arguments=(--reject-parse-warnings)
    if grep -Fq -- '--reject-secrets' <<< "$help_text"; then
        upload_arguments+=(--reject-secrets)
    elif grep -Fq -- '--allow-secrets' <<< "$help_text"; then
        # Agent v4 removes --reject-secrets and rejects detected secrets by
        # default. Never pass its explicit opt-out.
        :
    else
        echo "error: unknown Buildkite pipeline secret-rejection semantics" >&2
        return 1
    fi
    buildkite-agent pipeline upload "${upload_arguments[@]}" "$shadow_pipeline"
}

verify_executed_bootstrap() {
    local executed="$1" checked_out="$2"
    if [[ ! -f "$executed" || ! -f "$checked_out" ]] || ! cmp -s "$executed" "$checked_out"; then
        echo "error: executed bootstrap differs from the synthetic merge bootstrap" >&2
        return 1
    fi
}

bootstrap_source_context() {
    local executed_bootstrap webhook_payload
    assert_no_release_environment
    assert_build_is_eligible
    assert_buildkite_agent
    start_timing

    executed_bootstrap="$(mktemp "${TMPDIR:-/tmp}/tron-ci-shadow-bootstrap.XXXXXX")"
    webhook_payload="$(mktemp "${TMPDIR:-/tmp}/tron-ci-shadow-webhook.XXXXXX")"
    trap 'rm -f -- "$executed_bootstrap" "$webhook_payload"' RETURN
    cp "$bootstrap_pipeline" "$executed_bootstrap"
    capture_buildkite_webhook "$webhook_payload"

    # This is the only moving-ref resolution in a shadow build. Reload the
    # adapter from the checked-out merge before it creates the bundle or graph.
    python3 "$repo_root/scripts/ci-provider-context.py" checkout \
        --webhook-payload "$webhook_payload"
    verify_executed_bootstrap "$executed_bootstrap" "$bootstrap_pipeline"
    TRON_CI_EXECUTED_BOOTSTRAP="$executed_bootstrap" \
    TRON_CI_WEBHOOK_PAYLOAD="$webhook_payload" \
        "$repo_root/scripts/ci-shadow-run.sh" --pin-source
}

pin_source_context() {
    local output_dir staging_dir status finished_at finished_epoch
    output_dir="$artifact_root/source-context"
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-shadow-source.XXXXXX")"
    rm -rf -- "$output_dir"
    mkdir -p "$output_dir"

    set +e
    (
        set -euo pipefail
        assert_no_release_environment
        assert_build_is_eligible
        assert_buildkite_agent
        python3 "$repo_root/scripts/ci-provider-context.py" resolve \
            --webhook-payload "${TRON_CI_WEBHOOK_PAYLOAD:?}" \
            --output "$staging_dir/provider-context.json"
        python3 "$repo_root/scripts/ci-provider-context.py" bundle \
            --context "$staging_dir/provider-context.json" \
            --webhook-payload "${TRON_CI_WEBHOOK_PAYLOAD:?}" \
            --output "$staging_dir/provider-source.bundle"
        test -f "$shadow_pipeline"
        test -f "${TRON_CI_EXECUTED_BOOTSTRAP:-}"
        verify_executed_bootstrap "$TRON_CI_EXECUTED_BOOTSTRAP" "$bootstrap_pipeline"
        cp "$staging_dir/provider-context.json" "$output_dir/provider-context.json"
        cp "$staging_dir/provider-source.bundle" "$output_dir/provider-source.bundle"
        cp "$TRON_CI_EXECUTED_BOOTSTRAP" "$output_dir/executed-bootstrap.yml"
        EXECUTED_BOOTSTRAP="$output_dir/executed-bootstrap.yml" \
            python3 - "$output_dir/bootstrap-execution.json" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

bootstrap = Path(os.environ["EXECUTED_BOOTSTRAP"])
content = bootstrap.read_bytes()
Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "schema": "tron.ci-shadow-bootstrap-execution.v1",
            "repository_path": ".buildkite/pipeline.yml",
            "sha256": "sha256:" + hashlib.sha256(content).hexdigest(),
            "size": len(content),
            "matches_checked_out_merge": True,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
PY
        upload_shadow_pipeline
    ) 2>&1 | tee "$output_dir/command.log"
    status=${PIPESTATUS[0]}
    set -e

    finished_at="$(utc_now)"
    finished_epoch="$(date +%s)"
    write_manifest source-context "$status" "$output_dir" \
        "$TRON_CI_SHADOW_STARTED_AT" "$finished_at" \
        "$((finished_epoch - TRON_CI_SHADOW_STARTED_EPOCH))"
    rm -rf -- "$staging_dir"
    return "$status"
}

verify_manifest_files() {
    local manifest="$1" root="$2" expected_job="$3"
    python3 - "$manifest" "$root" "$expected_job" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
root = Path(sys.argv[2])
expected_job = sys.argv[3]
document = json.loads(manifest.read_text())
if document.get("schema") != "tron.ci-shadow-artifacts.v1":
    raise SystemExit("error: unsupported shadow manifest schema")
if document.get("advisory_only") is not True or document.get("provider") != "buildkite":
    raise SystemExit("error: artifact escaped the advisory Buildkite boundary")
if document.get("job") != expected_job or document.get("exit_code") != 0:
    raise SystemExit("error: source artifact came from the wrong or failed job")
entries = document.get("files")
if not isinstance(entries, list) or not entries:
    raise SystemExit("error: shadow manifest has no files")
seen = set()
for entry in entries:
    path = entry.get("path")
    expected_digest = entry.get("sha256")
    size = entry.get("size")
    if not isinstance(path, str) or path in seen or path.startswith("/") or ".." in Path(path).parts:
        raise SystemExit("error: invalid shadow artifact path")
    seen.add(path)
    candidate = root / path
    if not candidate.is_file() or candidate.stat().st_size != size:
        raise SystemExit(f"error: missing or incorrectly sized shadow artifact: {path}")
    hasher = hashlib.sha256()
    with candidate.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    actual = hasher.hexdigest()
    if actual != expected_digest:
        raise SystemExit(f"error: shadow artifact digest mismatch: {path}")
required = {
    "build/ci-shadow/source-context/provider-context.json",
    "build/ci-shadow/source-context/provider-source.bundle",
    "build/ci-shadow/source-context/executed-bootstrap.yml",
    "build/ci-shadow/source-context/bootstrap-execution.json",
}
if expected_job == "source-context" and not required.issubset(seen):
    raise SystemExit("error: source context manifest is incomplete")
PY
}

download_source_context() {
    local download_root="$1" source_dir
    assert_buildkite_agent
    buildkite-agent artifact download \
        "build/ci-shadow/source-context/*" "$download_root/" \
        --step source-context
    source_dir="$download_root/build/ci-shadow/source-context"
    validate_job_manifest \
        "$source_dir/sha256-manifest.json" source-context \
        "$source_dir/provider-context.json"
    verify_manifest_files "$source_dir/sha256-manifest.json" "$download_root" source-context
}

bootstrap_pinned_workload() {
    local job="$1" download_root source_dir status webhook_payload
    assert_no_release_environment
    assert_build_is_eligible
    start_timing
    download_root="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-shadow-pinned.XXXXXX")"
    download_source_context "$download_root"
    source_dir="$download_root/build/ci-shadow/source-context"
    webhook_payload="$download_root/buildkite-webhook.json"
    capture_buildkite_webhook "$webhook_payload"

    # Never fetch the moving PR ref here. The bundle and expected context fix
    # every job to the source-context step's commit, tree, and parents. Missing
    # prerequisites are fetched only by their immutable object IDs.
    python3 "$repo_root/scripts/ci-provider-context.py" checkout \
        --expected-context "$source_dir/provider-context.json" \
        --bundle "$source_dir/provider-source.bundle" \
        --webhook-payload "$webhook_payload"

    set +e
    TRON_CI_PINNED_ROOT="$download_root" \
    TRON_CI_PINNED_CONTEXT="$source_dir/provider-context.json" \
    TRON_CI_WEBHOOK_PAYLOAD="$webhook_payload" \
        "$repo_root/scripts/ci-shadow-run.sh" --run-pinned "$job"
    status=$?
    set -e
    rm -rf -- "$download_root"
    return "$status"
}

install_mac_rust_toolchain() {
    local rust_version
    export CARGO_HOME="$repo_root/build/ci-shadow-cache/mac-cargo-home"
    export RUSTUP_HOME="$repo_root/build/ci-shadow-cache/mac-rustup-home"
    mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
    rust_version="$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$repo_root/rust-toolchain.toml")"
    if [[ -z "$rust_version" ]]; then
        echo "error: rust-toolchain.toml does not declare a channel" >&2
        return 1
    fi
    command -v rustup >/dev/null || {
        echo "error: the hosted macOS queue must provide rustup" >&2
        return 1
    }
    rustup toolchain install "$rust_version" --profile minimal --component rustfmt --component clippy
    export TRON_CI_RUST_VERSION="$rust_version"
    rustup run "$rust_version" rustc --version
    rustup run "$rust_version" cargo --version
}

configure_apple_tools() {
    export TRON_CI_TOOLS_DIR="${TRON_CI_TOOLS_DIR:-$repo_root/build/ci-tools}"
    export PATH="$TRON_CI_TOOLS_DIR/bin:$PATH"
}

workload_notice() {
    assert_buildkite_agent
    cat <<'EOF' | buildkite-agent annotate --style info --context tron-advisory-shadow
### Advisory Buildkite shadow

This pipeline measures CI parity only. It is not a merge gate and has no
release, signing, notarization, deployment, or promotion authority.
EOF
}

workload_personal_info_guard() {
    "$repo_root/scripts/personal-info-guard.sh"
}

workload_version_drift() {
    "$repo_root/scripts/tron" version check
    "$repo_root/scripts/tron" version test
    "$repo_root/scripts/tron-release-notes" --test
    "$repo_root/scripts/ci-change-flags.sh" --self-test
    "$repo_root/scripts/ios-release-runner-doctor.sh" --self-test
    python3 "$repo_root/scripts/ci-provider-context.py" --self-test
    python3 "$repo_root/scripts/ci-validation-evidence.py" --self-test
    python3 "$repo_root/scripts/ci-parity-report.py" --self-test
    python3 "$repo_root/scripts/ci-cutover-evaluation.py" --self-test
    python3 "$repo_root/scripts/ios-test-selection.py" --self-test
    python3 "$repo_root/scripts/benchmarks/bench.py" --self-test
    python3 "$repo_root/scripts/evaluation/whole-agent.py" --self-test
    "$repo_root/scripts/ci-shadow-run.sh" --self-test
    "$repo_root/scripts/validate-ci-definitions.sh" --self-test
}

workload_workflow_lint() {
    "$repo_root/scripts/validate-ci-definitions.sh"
}

workload_rust() {
    local cache_root cargo_cache home_cache target_cache rust_image_digest rust_runtime_image
    cache_root="$repo_root/build/ci-shadow-cache"
    mkdir -p "$cache_root/cargo-home" "$cache_root/home" "$repo_root/packages/agent/target"
    cargo_cache="$(cd "$cache_root/cargo-home" && pwd -P)"
    home_cache="$(cd "$cache_root/home" && pwd -P)"
    target_cache="$(cd "$repo_root/packages/agent/target" && pwd -P)"
    command -v docker >/dev/null || {
        echo "error: hosted Linux queue must provide Docker" >&2
        return 1
    }
    rust_image_digest="${TRON_CI_RUST_IMAGE##*@sha256:}"
    rust_runtime_image="tron-ci-rust:${rust_version}-${rust_image_digest:0:12}"
    docker build \
        --build-arg "RUST_IMAGE=$TRON_CI_RUST_IMAGE" \
        --build-arg "RUST_VERSION=$rust_version" \
        --tag "$rust_runtime_image" \
        - < "$repo_root/.buildkite/rust-shadow.Dockerfile"
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --env CARGO_HOME=/tron-cargo \
        --env CARGO_TARGET_DIR=/tron-target \
        --env HOME=/tron-home \
        --volume "$repo_root:/work" \
        --volume "$cargo_cache:/tron-cargo" \
        --volume "$home_cache:/tron-home" \
        --volume "$target_cache:/tron-target" \
        --workdir /work \
        "$rust_runtime_image" \
        bash -euo pipefail -c '
            rustc --version
            cargo --version
            cargo fmt --version
            cargo clippy --version
            scripts/tron ci fmt
            scripts/tron ci check
            scripts/tron ci clippy
            scripts/tron ci test
        '
}

workload_ios() {
    configure_apple_tools
    cd "$repo_root/packages/ios-app"
    ../../scripts/bootstrap-ios-release-runner.sh --self-test
    ../../scripts/ios-release-user-context /usr/bin/true
    ../../scripts/install-ci-tools.sh xcodegen
    ../../scripts/verify-ci-toolchain.sh ios xcodegen
    xcodegen generate
    xcrun simctl list devices available > "$TRON_CI_CURRENT_OUTPUT_DIR/available-simulators.txt"
    sed -n '1,60p' "$TRON_CI_CURRENT_OUTPUT_DIR/available-simulators.txt"
    ../../scripts/ios-ci-test.sh
}

workload_mac() {
    local destination app_path
    configure_apple_tools
    install_mac_rust_toolchain
    # The manifest is shared with the authoritative Mac lane so warnings
    # cannot pass on one provider and fail on the other.
    # The manifest path is resolved from this script's repository root.
    # shellcheck disable=SC1091
    source "$repo_root/config/ci-toolchain.env"
    export RUSTFLAGS="$TRON_CI_MAC_RUSTFLAGS"

    cd "$repo_root/packages/agent"
    rustup run "$TRON_CI_RUST_VERSION" cargo build --bin tron --locked

    cd "$repo_root/packages/mac-app"
    ../../scripts/install-ci-tools.sh xcodegen create-dmg
    ../../scripts/verify-ci-toolchain.sh xcode xcodegen create-dmg
    ./scripts/bundle-agent.sh --skip-build --profile debug
    test -x "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"
    xcodegen generate

    destination="platform=macOS,arch=$(uname -m)"
    TRON_MAC_TEST_HOST=1 xcodebuild build-for-testing \
        -project TronMac.xcodeproj \
        -scheme TronMac \
        -destination "$destination" \
        -configuration Debug \
        CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
        -quiet

    TRON_MAC_TEST_HOST=1 xcodebuild test \
        -project TronMac.xcodeproj \
        -scheme TronMac \
        -destination "$destination" \
        -configuration Debug \
        -only-testing:TronMacTests/TronPathsTests \
        -only-testing:TronMacTests/ServerStatusPollerTests \
        -only-testing:TronMacTests/TailscaleProbeTests \
        CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
        -quiet

    if [[ "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]]; then
        mkdir -p build dist
        xcodebuild \
            -project TronMac.xcodeproj \
            -scheme TronMac \
            -configuration Debug \
            -derivedDataPath build/dd \
            -destination 'generic/platform=macOS' \
            ENABLE_DEBUG_DYLIB=NO \
            CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
            -quiet build
        app_path="$(find build/dd -name 'TronMac.app' -print -quit)"
        if [[ -z "$app_path" ]]; then
            echo "error: TronMac.app not produced by debug build" >&2
            return 1
        fi
        ./scripts/package-dmg.sh \
            --app "$app_path" \
            --output "$(pwd)/dist/Tron-dryrun.dmg" \
            --volume-name "Tron Dry-Run" \
            --layout structural
    fi
}

validate_job_manifest() {
    local manifest="$1" expected_job="$2" pinned_context="$3"
    python3 - "$manifest" "$expected_job" "$pinned_context" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text())
expected = sys.argv[2]
pinned_context = Path(sys.argv[3])
expected_keys = {
    "schema", "advisory_only", "provider", "job", "exit_code",
    "failure_classification", "started_at", "finished_at", "duration_seconds",
    "build_id", "build_number", "job_id", "retry_count", "retry_source", "files",
}
if not isinstance(document, dict) or set(document) != expected_keys:
    raise SystemExit("error: shadow job manifest fields are invalid")
if document.get("schema") != "tron.ci-shadow-artifacts.v1":
    raise SystemExit("error: unsupported job manifest schema")
if document.get("provider") != "buildkite" or document.get("advisory_only") is not True:
    raise SystemExit("error: job manifest is not advisory Buildkite evidence")
if (
    document.get("job") != expected
    or isinstance(document.get("exit_code"), bool)
    or document.get("exit_code") != 0
):
    raise SystemExit(f"error: {expected} did not report success")
build_id = os.environ.get("BUILDKITE_BUILD_ID")
build_number = os.environ.get("BUILDKITE_BUILD_NUMBER")
if not build_id or not build_number:
    raise SystemExit("error: current Buildkite build identity is unavailable")
if document.get("build_id") != build_id or document.get("build_number") != build_number:
    raise SystemExit(f"error: {expected} manifest belongs to a different Buildkite build")
if not isinstance(document.get("job_id"), str) or not document["job_id"]:
    raise SystemExit(f"error: {expected} manifest has no Buildkite job identity")
if document.get("failure_classification") != "none":
    raise SystemExit(f"error: {expected} has an unexpected failure classification")
if (
    not isinstance(document.get("duration_seconds"), int)
    or isinstance(document["duration_seconds"], bool)
    or document["duration_seconds"] < 0
):
    raise SystemExit(f"error: {expected} has invalid duration evidence")
if (
    not isinstance(document.get("retry_count"), int)
    or isinstance(document["retry_count"], bool)
    or document["retry_count"] < 0
    or (
        document.get("retry_source") is not None
        and not isinstance(document["retry_source"], str)
    )
):
    raise SystemExit(f"error: {expected} has invalid retry evidence")
try:
    started = datetime.strptime(document["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    finished = datetime.strptime(document["finished_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except (KeyError, TypeError, ValueError) as error:
    raise SystemExit(f"error: {expected} has invalid UTC timing evidence") from error
if finished < started or int((finished - started).total_seconds()) != document["duration_seconds"]:
    raise SystemExit(f"error: {expected} timing interval does not match its duration")
files = document.get("files")
if not isinstance(files, list) or not files:
    raise SystemExit(f"error: {expected} has no artifact entries")
paths = []
for entry in files:
    if (
        not isinstance(entry, dict)
        or set(entry) != {"path", "sha256", "size"}
        or not isinstance(entry.get("path"), str)
        or not entry["path"]
        or entry["path"].startswith("/")
        or ".." in Path(entry["path"]).parts
        or not isinstance(entry.get("sha256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) is None
        or not isinstance(entry.get("size"), int)
        or isinstance(entry["size"], bool)
        or entry["size"] < 0
    ):
        raise SystemExit(f"error: {expected} has an invalid artifact entry")
    paths.append(entry["path"])
if len(paths) != len(set(paths)):
    raise SystemExit(f"error: {expected} has duplicate artifact paths")
context_entries = [
    entry for entry in files
    if isinstance(entry, dict) and Path(str(entry.get("path", ""))).name == "provider-context.json"
]
expected_path = f"build/ci-shadow/{expected}/provider-context.json"
if len(context_entries) != 1 or context_entries[0].get("path") != expected_path:
    raise SystemExit(f"error: {expected} must record exactly its own provider context")
if not pinned_context.is_file():
    raise SystemExit("error: pinned provider context is unavailable")
pinned_bytes = pinned_context.read_bytes()
if (
    context_entries[0].get("size") != len(pinned_bytes)
    or context_entries[0].get("sha256") != hashlib.sha256(pinned_bytes).hexdigest()
):
    raise SystemExit(f"error: {expected} provider context differs from the pinned context")
PY
}

workload_operational_observation() {
    local download_dir rows job state outcome
    assert_buildkite_agent
    download_dir="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-shadow-observation.XXXXXX")"
    rows="$download_dir/steps.tsv"
    : > "$rows"

    # This artifact is deliberately descriptive, never authoritative. Step
    # state/outcome comes from Buildkite itself; manifests are corroborating
    # evidence and are recorded as missing or invalid instead of aborting the
    # observer. Provider API exports remain responsible for builds where this
    # post-bootstrap step is canceled or never created.
    for job in "${required_jobs[@]}"; do
        if state="$(buildkite-agent step get state --step "$job" 2>/dev/null)"; then
            state="$(printf '%s' "$state" | tr -d '\r\n')"
        else
            state=unavailable
        fi
        if outcome="$(buildkite-agent step get outcome --step "$job" 2>/dev/null)"; then
            outcome="$(printf '%s' "$outcome" | tr -d '\r\n')"
        else
            outcome=unavailable
        fi
        [[ "$state" =~ ^[a-z_]+$ ]] || state=unavailable
        [[ "$outcome" =~ ^[a-z_]+$ ]] || outcome=unavailable
        local manifest_download=missing context_download=missing
        if buildkite-agent artifact download \
            "build/ci-shadow/$job/sha256-manifest.json" "$download_dir/" \
            --step "$job" >/dev/null 2>&1; then
            manifest_download=present
        fi
        if buildkite-agent artifact download \
            "build/ci-shadow/$job/provider-context.json" "$download_dir/" \
            --step "$job" >/dev/null 2>&1; then
            context_download=present
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$job" "$state" "$outcome" "$manifest_download" "$context_download" >> "$rows"
    done

    OBSERVATION_ROWS="$rows" OBSERVATION_DOWNLOAD_ROOT="$download_dir" \
    OBSERVATION_OUTPUT="$TRON_CI_CURRENT_OUTPUT_DIR/operational-observation.json" \
    OBSERVATION_CONTEXT="$TRON_CI_PINNED_CONTEXT" OBSERVATION_CREATED_AT="$(utc_now)" \
        python3 - <<'PY'
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

rows = Path(os.environ["OBSERVATION_ROWS"])
download_root = Path(os.environ["OBSERVATION_DOWNLOAD_ROOT"])
output = Path(os.environ["OBSERVATION_OUTPUT"])
context = Path(os.environ["OBSERVATION_CONTEXT"])
context_bytes = context.read_bytes()
context_digest = hashlib.sha256(context_bytes).hexdigest()
build_id = os.environ.get("BUILDKITE_BUILD_ID")
build_number = os.environ.get("BUILDKITE_BUILD_NUMBER")


def manifest_observation(
    job: str, outcome: str, manifest_download: str, context_download: str
) -> dict:
    path = download_root / f"build/ci-shadow/{job}/sha256-manifest.json"
    observed_context = download_root / f"build/ci-shadow/{job}/provider-context.json"
    if manifest_download != "present" or not path.is_file():
        return {"status": "missing", "sha256": None, "exit_code": None}
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    try:
        document = json.loads(path.read_text())
        context_entries = [
            entry
            for entry in document.get("files", [])
            if isinstance(entry, dict)
            and entry.get("path") == f"build/ci-shadow/{job}/provider-context.json"
        ]
        exit_code = document.get("exit_code")
        failure_classification = document.get("failure_classification")
        started = datetime.strptime(document["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
        finished = datetime.strptime(document["finished_at"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
        duration = document.get("duration_seconds")
        file_entries = document.get("files")
        entries_are_bound = isinstance(file_entries, list) and bool(file_entries) and all(
            isinstance(entry, dict)
            and set(entry) == {"path", "sha256", "size"}
            and isinstance(entry["path"], str)
            and not entry["path"].startswith("/")
            and ".." not in Path(entry["path"]).parts
            and isinstance(entry["sha256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
            and isinstance(entry["size"], int)
            and not isinstance(entry["size"], bool)
            and entry["size"] >= 0
            for entry in file_entries
        )
        outcome_matches_exit = (
            (outcome == "passed" and exit_code == 0)
            or (outcome in {"hard_failed", "soft_failed"} and isinstance(exit_code, int) and exit_code != 0)
            or outcome in {"errored", "unavailable"}
        )
        identity_bound = (
            document.get("schema") == "tron.ci-shadow-artifacts.v1"
            and document.get("advisory_only") is True
            and document.get("provider") == "buildkite"
            and document.get("job") == job
            and document.get("build_id") == build_id
            and document.get("build_number") == build_number
            and isinstance(document.get("job_id"), str)
            and bool(document["job_id"])
            and isinstance(exit_code, int)
            and not isinstance(exit_code, bool)
            and failure_classification == ("none" if exit_code == 0 else "workload_failure")
            and isinstance(duration, int)
            and not isinstance(duration, bool)
            and duration >= 0
            and finished >= started
            and int((finished - started).total_seconds()) == duration
            and isinstance(document.get("retry_count"), int)
            and not isinstance(document["retry_count"], bool)
            and document["retry_count"] >= 0
            and (document.get("retry_source") is None or isinstance(document["retry_source"], str))
            and entries_are_bound
            and outcome_matches_exit
            and context_download == "present"
            and observed_context.is_file()
            and observed_context.read_bytes() == context_bytes
            and len(context_entries) == 1
            and context_entries[0].get("size") == len(context_bytes)
            and context_entries[0].get("sha256") == context_digest
        )
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        AttributeError,
        KeyError,
        TypeError,
        ValueError,
    ):
        identity_bound = False
        exit_code = None
    return {
        "status": "identity_bound" if identity_bound else "invalid",
        "sha256": f"sha256:{digest}",
        "exit_code": exit_code,
    }


jobs = []
seen = set()
for line in rows.read_text().splitlines():
    job, state, outcome, manifest_download, context_download = line.split("\t")
    if job in seen:
        raise SystemExit("duplicate operational-observation job")
    seen.add(job)
    jobs.append(
        {
            "job": job,
            "state": state,
            "outcome": outcome,
            "manifest": manifest_observation(
                job, outcome, manifest_download, context_download
            ),
        }
    )

expected = ["personal-info-guard", "version-drift", "workflow-lint", "rust", "ios", "mac"]
if [item["job"] for item in jobs] != expected:
    raise SystemExit("operational-observation job set is incomplete")
all_job_records_identity_bound = all(
    item["state"] != "unavailable"
    and item["outcome"] != "unavailable"
    and item["manifest"]["status"] == "identity_bound"
    for item in jobs
)
output.write_text(
    json.dumps(
        {
            "schema": "tron.ci-shadow-operational-observation.v1",
            "advisory_only": True,
            "provider": "buildkite",
            "build_id": build_id,
            "build_number": build_number,
            "rebuilt_from_build_id": os.environ.get("BUILDKITE_REBUILT_FROM_BUILD_ID"),
            "created_at": os.environ["OBSERVATION_CREATED_AT"],
            "source_context_sha256": f"sha256:{context_digest}",
            "all_job_records_identity_bound": all_job_records_identity_bound,
            "jobs": jobs,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
PY
    rm -rf -- "$download_dir"
}

workload_evidence() {
    local payload_dir manifest job context_env required_jobs_json bootstrap_copy bootstrap_record
    if [[ "${BUILDKITE_PULL_REQUEST:-false}" == "false" ]]; then
        echo "error: merge validation evidence is pull-request-only" >&2
        return 1
    fi
    assert_buildkite_agent
    payload_dir="$TRON_CI_CURRENT_OUTPUT_DIR/payload"
    mkdir -p "$payload_dir"

    for job in "${required_jobs[@]}"; do
        buildkite-agent artifact download \
            "build/ci-shadow/$job/sha256-manifest.json" "$repo_root/" \
            --step "$job"
        manifest="$repo_root/build/ci-shadow/$job/sha256-manifest.json"
        validate_job_manifest "$manifest" "$job" "$TRON_CI_PINNED_CONTEXT"
        cp "$manifest" "$payload_dir/$job-manifest.json"
    done
    buildkite-agent artifact download \
        "packages/ios-app/build/ios-ci-metrics.json" "$repo_root/" \
        --step ios
    cp "$repo_root/packages/ios-app/build/ios-ci-metrics.json" "$payload_dir/ios-ci-metrics.json"
    cp "$TRON_CI_PINNED_CONTEXT" "$payload_dir/provider-context.json"
    bootstrap_copy="$TRON_CI_PINNED_ROOT/build/ci-shadow/source-context/executed-bootstrap.yml"
    bootstrap_record="$TRON_CI_PINNED_ROOT/build/ci-shadow/source-context/bootstrap-execution.json"
    test -f "$bootstrap_copy"
    test -f "$bootstrap_record"
    verify_executed_bootstrap "$bootstrap_copy" "$bootstrap_pipeline"
    cp "$bootstrap_copy" "$payload_dir/executed-bootstrap.yml"
    cp "$bootstrap_record" "$payload_dir/bootstrap-execution.json"

    context_env="$TRON_CI_CURRENT_OUTPUT_DIR/provider-context.env"
    python3 "$repo_root/scripts/ci-provider-context.py" export \
        --context "$TRON_CI_PINNED_CONTEXT" --format shell > "$context_env"
    # shellcheck disable=SC1090
    source "$context_env"
    required_jobs_json="$(python3 - "${required_jobs[@]}" <<'PY'
import json
import sys
print(json.dumps({job: "success" for job in sys.argv[1:]}, sort_keys=True))
PY
)"
    export TRON_CI_REQUIRED_JOBS_JSON="$required_jobs_json"

    local evidence_args=()
    for job in "${required_jobs[@]}"; do
        evidence_args+=(--artifact "$payload_dir/$job-manifest.json")
    done
    evidence_args+=(--artifact "$payload_dir/ios-ci-metrics.json")
    evidence_args+=(--artifact "$payload_dir/provider-context.json")
    evidence_args+=(--artifact "$payload_dir/executed-bootstrap.yml")
    evidence_args+=(--artifact "$payload_dir/bootstrap-execution.json")
    python3 "$repo_root/scripts/ci-validation-evidence.py" create \
        --output "$TRON_CI_CURRENT_OUTPUT_DIR/validation-evidence.json" \
        --ios-metrics "$payload_dir/ios-ci-metrics.json" \
        "${evidence_args[@]}"
}

write_manifest() {
    local job="$1" status="$2" output_dir="$3" started_at="$4" finished_at="$5" duration="$6"
    JOB_NAME="$job" JOB_STATUS="$status" OUTPUT_DIR="$output_dir" REPO_ROOT="$repo_root" \
    STARTED_AT="$started_at" FINISHED_AT="$finished_at" DURATION_SECONDS="$duration" \
        python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

repo = Path(os.environ["REPO_ROOT"]).resolve()
output = Path(os.environ["OUTPUT_DIR"]).resolve()
job = os.environ["JOB_NAME"]

roots = [output]
if job == "ios":
    roots.append(repo / "packages/ios-app/build/ios-ci-metrics.json")
elif job == "mac":
    roots.append(repo / "packages/mac-app/dist/Tron-dryrun.dmg")

files = set()
for root in roots:
    if root.is_file():
        files.add(root)
    elif root.is_dir():
        files.update(path for path in root.rglob("*") if path.is_file())

manifest_path = output / "sha256-manifest.json"
files.discard(manifest_path)
entries = []
for path in sorted(files):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    try:
        display_path = str(path.relative_to(repo))
    except ValueError:
        display_path = path.name
    entries.append({
        "path": display_path,
        "sha256": digest.hexdigest(),
        "size": path.stat().st_size,
    })

status = int(os.environ["JOB_STATUS"])
document = {
    "schema": "tron.ci-shadow-artifacts.v1",
    "advisory_only": True,
    "provider": "buildkite",
    "job": job,
    "exit_code": status,
    "failure_classification": "none" if status == 0 else "workload_failure",
    "started_at": os.environ["STARTED_AT"],
    "finished_at": os.environ["FINISHED_AT"],
    "duration_seconds": int(os.environ["DURATION_SECONDS"]),
    "build_id": os.environ.get("BUILDKITE_BUILD_ID"),
    "build_number": os.environ.get("BUILDKITE_BUILD_NUMBER"),
    "job_id": os.environ.get("BUILDKITE_JOB_ID"),
    "retry_count": int(os.environ.get("BUILDKITE_RETRY_COUNT", "0")),
    "retry_source": os.environ.get("BUILDKITE_RETRY_SOURCE"),
    "files": entries,
}
manifest_path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
}

dispatch_pinned_workload() {
    local job="$1"
    case "$job" in
        notice|personal-info-guard|version-drift|workflow-lint|rust|ios|mac|evidence|operational-observation) ;;
        *) echo "error: unsupported pinned workload: $job" >&2; return 2 ;;
    esac
    "workload_${job//-/_}"
}

run_pinned_workload() {
    local job="$1" output_dir staging_dir status finished_at finished_epoch
    case "$job" in
        notice|personal-info-guard|version-drift|workflow-lint|rust|ios|mac|evidence|operational-observation) ;;
        *) echo "error: unsupported pinned workload: $job" >&2; return 2 ;;
    esac
    if [[ -z "${TRON_CI_PINNED_ROOT:-}" || -z "${TRON_CI_PINNED_CONTEXT:-}" ]]; then
        echo "error: pinned workload is missing its source context" >&2
        return 1
    fi

    output_dir="$artifact_root/$job"
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-shadow-job.XXXXXX")"
    rm -rf -- "$output_dir"
    mkdir -p "$output_dir"

    set +e
    (
        set -euo pipefail
        assert_no_release_environment
        assert_build_is_eligible
        verify_manifest_files \
            "$TRON_CI_PINNED_ROOT/build/ci-shadow/source-context/sha256-manifest.json" \
            "$TRON_CI_PINNED_ROOT" source-context
        python3 "$repo_root/scripts/ci-provider-context.py" resolve \
            --expected-context "$TRON_CI_PINNED_CONTEXT" \
            --webhook-payload "${TRON_CI_WEBHOOK_PAYLOAD:?}" \
            --output "$staging_dir/provider-context.json"
        export TRON_CI_CURRENT_OUTPUT_DIR="$output_dir"
        dispatch_pinned_workload "$job"
    ) 2>&1 | tee "$output_dir/command.log"
    status=${PIPESTATUS[0]}
    set -e

    if [[ -f "$staging_dir/provider-context.json" ]]; then
        cp "$staging_dir/provider-context.json" "$output_dir/provider-context.json"
    fi
    if [[ "$job" == "ios" && "$status" -ne 0 && -d "$repo_root/packages/ios-app/build/TestResults.xcresult" ]]; then
        cp -R "$repo_root/packages/ios-app/build/TestResults.xcresult" \
            "$output_dir/TestResults.xcresult"
    fi
    finished_at="$(utc_now)"
    finished_epoch="$(date +%s)"
    write_manifest "$job" "$status" "$output_dir" \
        "$TRON_CI_SHADOW_STARTED_AT" "$finished_at" \
        "$((finished_epoch - TRON_CI_SHADOW_STARTED_EPOCH))"
    rm -rf -- "$staging_dir"
    return "$status"
}

expect_success() {
    local description="$1"
    shift
    if ! ("$@") >/dev/null 2>&1; then
        echo "self-test failed: expected success: $description" >&2
        return 1
    fi
}

expect_failure() {
    local description="$1"
    shift
    if ("$@") >/dev/null 2>&1; then
        echo "self-test failed: expected failure: $description" >&2
        return 1
    fi
}

self_test() {
    local test_root manifest expected_hash actual_hash job command_count test_build_id source_context_step
    local mock_bin observation_artifacts observation_output observation_context observation_json text_result
    test_root="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-shadow-self-test.XXXXXX")"

    "$repo_root/scripts/install-ci-tools.sh" --self-test

    expect_success "ready pull request" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=42 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
        BUILDKITE_GITHUB_EVENT=pull_request BUILDKITE_GITHUB_ACTION=opened \
        BUILDKITE_PULL_REQUEST_DRAFT=false BUILDKITE_TAG= TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_success "main build" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=false BUILDKITE_BRANCH=main BUILDKITE_TAG= \
        BUILDKITE_GITHUB_EVENT=push \
        TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_failure "draft pull request" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=42 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
        BUILDKITE_GITHUB_EVENT=pull_request BUILDKITE_GITHUB_ACTION=opened \
        BUILDKITE_PULL_REQUEST_DRAFT=true BUILDKITE_TAG= TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_failure "wrong pull request base" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=42 BUILDKITE_PULL_REQUEST_BASE_BRANCH=release \
        BUILDKITE_GITHUB_EVENT=pull_request BUILDKITE_GITHUB_ACTION=opened \
        BUILDKITE_PULL_REQUEST_DRAFT=false BUILDKITE_TAG= TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_failure "non-main branch" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=false BUILDKITE_BRANCH=feature BUILDKITE_TAG= \
        BUILDKITE_GITHUB_EVENT=push \
        TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_failure "tag build" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=false BUILDKITE_BRANCH=main BUILDKITE_TAG=v1 \
        BUILDKITE_GITHUB_EVENT=push \
        TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_failure "missing advisory boundary" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=false BUILDKITE_BRANCH=main BUILDKITE_TAG= \
        BUILDKITE_GITHUB_EVENT=push \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_failure "unmodeled pull request action" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=42 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
        BUILDKITE_GITHUB_EVENT=pull_request BUILDKITE_GITHUB_ACTION=labeled \
        BUILDKITE_PULL_REQUEST_DRAFT=false BUILDKITE_TAG= TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    expect_failure "missing pull request action" env \
        BUILDKITE=true BUILDKITE_PULL_REQUEST=42 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
        BUILDKITE_GITHUB_EVENT=pull_request BUILDKITE_PULL_REQUEST_DRAFT=false \
        BUILDKITE_TAG= TRON_CI_ADVISORY_ONLY=true \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_build_is_eligible"
    local release_name
    for release_name in "${release_environment_names[@]}"; do
        expect_failure "release environment alias $release_name" \
            env "$release_name=sentinel" \
            bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_no_release_environment"
    done
    expect_failure "unknown release-shaped environment alias" \
        env IOS_RELEASE_SIGNING_PASSWORD=sentinel \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; assert_no_release_environment"
    cp "$bootstrap_pipeline" "$test_root/executed-bootstrap.yml"
    expect_success "executed bootstrap identity" \
        verify_executed_bootstrap "$test_root/executed-bootstrap.yml" "$bootstrap_pipeline"
    printf '\n# changed\n' >> "$test_root/executed-bootstrap.yml"
    expect_failure "mismatched executed bootstrap" \
        verify_executed_bootstrap "$test_root/executed-bootstrap.yml" "$bootstrap_pipeline"

    [[ -f "$bootstrap_pipeline" && -f "$shadow_pipeline" ]] || {
        echo "self-test failed: Buildkite pipeline definitions are incomplete" >&2
        return 1
    }
    grep -Fq 'TRON_CI_ADVISORY_ONLY: "true"' "$bootstrap_pipeline"
    grep -Fq 'build.pull_request.draft == false' "$bootstrap_pipeline"
    grep -Fq 'scripts/ci-shadow-run.sh source-context' "$bootstrap_pipeline"
    grep -Fq -- '--reject-secrets' "$repo_root/scripts/ci-shadow-run.sh"
    grep -Fq -- '--reject-parse-warnings' "$repo_root/scripts/ci-shadow-run.sh"
    grep -Fq 'bootstrap-execution.json' "$repo_root/scripts/ci-shadow-run.sh"
    command_count="$(grep -c 'command:' "$bootstrap_pipeline")"
    [[ "$command_count" -eq 1 ]] || {
        echo "self-test failed: bootstrap must contain exactly one command" >&2
        return 1
    }
    source_context_step="$(sed -n '/key: "source-context"/,/artifact_paths:/p' "$bootstrap_pipeline")"
    if [[ "$source_context_step" != *$'retry:\n      manual:\n        allowed: false'* ]]; then
        echo "self-test failed: source-context must explicitly reject manual retries" >&2
        return 1
    fi
    if [[ "$source_context_step" == *'automatic:'* ]]; then
        echo "self-test failed: source-context must not automatically retry" >&2
        return 1
    fi
    grep -Fq 'scripts/ci-shadow-run.sh notice' "$shadow_pipeline"
    grep -Fq 'scripts/ci-shadow-run.sh evidence' "$shadow_pipeline"
    grep -Fq 'scripts/ci-shadow-run.sh operational-observation' "$shadow_pipeline"
    grep -A14 'key: "operational-observation"' "$shadow_pipeline" | \
        grep -Fq 'allow_dependency_failure: true'
    grep -A18 'key: "operational-observation"' "$shadow_pipeline" | \
        grep -Fq 'soft_fail: true'
    grep -Fq 'queue: "linux-medium"' "$shadow_pipeline"
    grep -Fq 'queue: "macos-medium"' "$shadow_pipeline"
    if grep -Fq 'TestResults.xcresult' "$shadow_pipeline"; then
        echo "self-test failed: successful iOS jobs must not upload full xcresult data" >&2
        return 1
    fi
    grep -Fq 'TRON_CI_REQUIRED_JOBS_JSON' "$repo_root/scripts/ci-shadow-run.sh"
    grep -Fq 'payload_dir/ios-ci-metrics.json' "$repo_root/scripts/ci-shadow-run.sh"
    grep -Fq 'payload_dir/provider-context.json' "$repo_root/scripts/ci-shadow-run.sh"
    if grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' "$repo_root/scripts/ci-shadow-run.sh"; then
        echo "self-test failed: provider exports must be sourced from a file, not eval'd" >&2
        return 1
    fi
    if grep -Eq 'release-ios|release-mac|tron-ios-release|ios-testflight|server-v' \
        "$bootstrap_pipeline" "$shadow_pipeline"; then
        echo "self-test failed: pipeline contains a release trigger or queue" >&2
        return 1
    fi
    for job in "${required_jobs[@]}"; do
        grep -Fq "scripts/ci-shadow-run.sh $job" "$shadow_pipeline" || {
            echo "self-test failed: dynamic pipeline is missing $job" >&2
            return 1
        }
    done
    if grep -A3 'automatic:' "$bootstrap_pipeline" "$shadow_pipeline" | \
        grep -E 'exit_status:' | grep -Fv -- '-1' >/dev/null; then
        echo "self-test failed: product failures must never retry automatically" >&2
        return 1
    fi

    mkdir -p "$test_root/output"
    test_build_id='12345678-1234-4234-8234-123456789abc'
    printf 'manifest fixture\n' > "$test_root/output/fixture.txt"
    printf '{"context":"pinned"}\n' > "$test_root/output/provider-context.json"
    BUILDKITE_BUILD_ID="$test_build_id" BUILDKITE_BUILD_NUMBER=7 BUILDKITE_JOB_ID=job-self-test \
        write_manifest self-test 0 "$test_root/output" \
        '2026-01-01T00:00:00Z' '2026-01-01T00:00:03Z' 3
    manifest="$test_root/output/sha256-manifest.json"
    expected_hash="$(shasum -a 256 "$test_root/output/fixture.txt" | awk '{print $1}')"
    actual_hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"][0]["sha256"])' "$manifest")"
    [[ "$actual_hash" == "$expected_hash" ]] || {
        echo "self-test failed: manifest digest mismatch" >&2
        return 1
    }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["advisory_only"] is True and d["duration_seconds"] == 3 and d["failure_classification"] == "none"' "$manifest"
    verify_manifest_files "$manifest" "$test_root/output" self-test
    printf 'tampered fixture\n' > "$test_root/output/fixture.txt"
    expect_failure "tampered manifest payload" \
        verify_manifest_files "$manifest" "$test_root/output" self-test
    printf 'manifest fixture\n' > "$test_root/output/fixture.txt"
    python3 - "$manifest" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text())
entries = [entry for entry in document["files"] if entry["path"] == "provider-context.json"]
assert len(entries) == 1
entries[0]["path"] = "build/ci-shadow/self-test/provider-context.json"
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
    BUILDKITE_BUILD_ID="$test_build_id" BUILDKITE_BUILD_NUMBER=7 BUILDKITE_JOB_ID=job-self-test \
        validate_job_manifest "$manifest" self-test "$test_root/output/provider-context.json"
    cp "$manifest" "$test_root/boolean-exit-manifest.json"
    python3 - "$test_root/boolean-exit-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text())
document["exit_code"] = True
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
    expect_failure "boolean job exit code" env \
        BUILDKITE_BUILD_ID="$test_build_id" BUILDKITE_BUILD_NUMBER=7 \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; validate_job_manifest '$test_root/boolean-exit-manifest.json' self-test '$test_root/output/provider-context.json'"
    printf '{"context":"different"}\n' > "$test_root/different-context.json"
    expect_failure "job context differs from pinned context" env \
        BUILDKITE_BUILD_ID="$test_build_id" BUILDKITE_BUILD_NUMBER=7 \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; validate_job_manifest '$manifest' self-test '$test_root/different-context.json'"
    expect_failure "job manifest belongs to another build" env \
        BUILDKITE_BUILD_ID='87654321-4321-4321-8321-cba987654321' BUILDKITE_BUILD_NUMBER=8 \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; validate_job_manifest '$manifest' self-test '$test_root/output/provider-context.json'"

    mock_bin="$test_root/mock-bin"
    observation_artifacts="$test_root/observation-artifacts"
    observation_output="$test_root/observation-output"
    observation_context="$test_root/observation-context.json"
    observation_json="$observation_output/operational-observation.json"
    mkdir -p "$mock_bin" "$observation_artifacts" "$observation_output"
    printf '{"schema":"pinned-context"}\n' > "$observation_context"
    python3 - "$observation_artifacts" "$observation_context" "$test_build_id" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
context = Path(sys.argv[2]).read_bytes()
build_id = sys.argv[3]
context_digest = hashlib.sha256(context).hexdigest()
jobs = ["personal-info-guard", "version-drift", "workflow-lint", "rust", "ios", "mac"]
for job in jobs:
    destination = root / f"build/ci-shadow/{job}"
    destination.mkdir(parents=True)
    (destination / "provider-context.json").write_bytes(context)
    exit_code = 1 if job == "rust" else 0
    document = {
        "schema": "tron.ci-shadow-artifacts.v1",
        "advisory_only": True,
        "provider": "buildkite",
        "job": job,
        "exit_code": exit_code,
        "failure_classification": "none" if exit_code == 0 else "workload_failure",
        "started_at": "2026-01-01T00:00:00Z",
        "finished_at": "2026-01-01T00:00:03Z",
        "duration_seconds": 3,
        "build_id": build_id,
        "build_number": "7",
        "job_id": f"job-{job}",
        "retry_count": 0,
        "retry_source": None,
        "files": [
            {
                "path": f"build/ci-shadow/{job}/provider-context.json",
                "sha256": context_digest,
                "size": len(context),
            }
        ],
    }
    (destination / "sha256-manifest.json").write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n"
    )
PY
    text_result="$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "step" && "$2" == "get" ]]; then
    attribute="$3"
    job="$5"
    if [[ "$attribute" == "state" ]]; then
        printf 'finished\n'
    elif [[ "$attribute" == "outcome" && "$job" == "rust" ]]; then
        printf 'hard_failed\n'
    elif [[ "$attribute" == "outcome" ]]; then
        printf 'passed\n'
    else
        exit 2
    fi
elif [[ "$1" == "artifact" && "$2" == "download" ]]; then
    query="$3"
    destination="$4"
    source_path="$MOCK_ARTIFACT_ROOT/$query"
    [[ -f "$source_path" ]] || exit 1
    mkdir -p "$destination/$(dirname "$query")"
    cp "$source_path" "$destination/$query"
elif [[ "$1" == "pipeline" && "$2" == "upload" && "${3:-}" == "--help" ]]; then
    if [[ "${MOCK_AGENT_SURFACE:-v3}" == "v3" ]]; then
        printf '%s\n' '  --reject-secrets' '  --reject-parse-warnings'
    elif [[ "${MOCK_AGENT_SURFACE:-}" == "v4" ]]; then
        printf '%s\n' '  --allow-secrets' '  --reject-parse-warnings'
    else
        printf '%s\n' '  --no-interpolation'
    fi
elif [[ "$1" == "pipeline" && "$2" == "upload" ]]; then
    printf '%s\n' "$*" > "$MOCK_UPLOAD_LOG"
else
    exit 2
fi
EOF
)"
    printf '%s\n' "$text_result" > "$mock_bin/buildkite-agent"
    chmod +x "$mock_bin/buildkite-agent"

    PATH="$mock_bin:$PATH" MOCK_AGENT_SURFACE=v3 MOCK_UPLOAD_LOG="$test_root/v3-upload.log" \
        upload_shadow_pipeline
    grep -Fq -- '--reject-secrets' "$test_root/v3-upload.log"
    grep -Fq -- '--reject-parse-warnings' "$test_root/v3-upload.log"
    PATH="$mock_bin:$PATH" MOCK_AGENT_SURFACE=v4 MOCK_UPLOAD_LOG="$test_root/v4-upload.log" \
        upload_shadow_pipeline
    if grep -Fq -- '--reject-secrets' "$test_root/v4-upload.log"; then
        echo "self-test failed: Buildkite v4 upload received its removed flag" >&2
        return 1
    fi
    grep -Fq -- '--reject-parse-warnings' "$test_root/v4-upload.log"
    grep -Fq "$shadow_pipeline" "$test_root/v4-upload.log"
    expect_failure "unknown pipeline secret semantics" env \
        PATH="$mock_bin:$PATH" MOCK_AGENT_SURFACE=unknown MOCK_UPLOAD_LOG="$test_root/unknown.log" \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; upload_shadow_pipeline"

    env PATH="$mock_bin:$PATH" MOCK_ARTIFACT_ROOT="$observation_artifacts" \
        BUILDKITE_BUILD_ID="$test_build_id" BUILDKITE_BUILD_NUMBER=7 \
        TRON_CI_CURRENT_OUTPUT_DIR="$observation_output" \
        TRON_CI_PINNED_CONTEXT="$observation_context" \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; dispatch_pinned_workload operational-observation"
    python3 - "$observation_json" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1]))
assert document["schema"] == "tron.ci-shadow-operational-observation.v1"
assert document["all_job_records_identity_bound"] is True
assert len(document["jobs"]) == 6
rust = next(item for item in document["jobs"] if item["job"] == "rust")
assert rust["outcome"] == "hard_failed"
assert rust["manifest"] == {
    "status": "identity_bound",
    "sha256": rust["manifest"]["sha256"],
    "exit_code": 1,
}
assert rust["manifest"]["sha256"].startswith("sha256:")
PY
    rm "$observation_artifacts/build/ci-shadow/ios/sha256-manifest.json"
    env PATH="$mock_bin:$PATH" MOCK_ARTIFACT_ROOT="$observation_artifacts" \
        BUILDKITE_BUILD_ID="$test_build_id" BUILDKITE_BUILD_NUMBER=7 \
        TRON_CI_CURRENT_OUTPUT_DIR="$observation_output" \
        TRON_CI_PINNED_CONTEXT="$observation_context" \
        bash -c "source '$repo_root/scripts/ci-shadow-run.sh'; dispatch_pinned_workload operational-observation"
    python3 - "$observation_json" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1]))
assert document["all_job_records_identity_bound"] is False
ios = next(item for item in document["jobs"] if item["job"] == "ios")
assert ios["manifest"] == {"status": "missing", "sha256": None, "exit_code": None}
PY
    expect_failure "unsupported workload dispatch" dispatch_pinned_workload unsupported

    rm -rf -- "$test_root"
    echo "ci-shadow-run self-test passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        source-context)
            bootstrap_source_context
            ;;
        notice|personal-info-guard|version-drift|workflow-lint|rust|ios|mac|evidence|operational-observation)
            bootstrap_pinned_workload "$1"
            ;;
        --pin-source)
            pin_source_context
            ;;
        --run-pinned)
            [[ $# -eq 2 ]] || { echo "error: --run-pinned requires one workload" >&2; exit 2; }
            run_pinned_workload "$2"
            ;;
        --self-test)
            self_test
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
fi
