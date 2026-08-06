#!/bin/bash
# Validate authoritative and advisory CI definitions with repository-owned pins.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/config/ci-toolchain.env"

validate_manifest_contract() {
    local rust_version rust_digest actionlint_digest checksum
    local rust_image="${1:-$TRON_CI_RUST_IMAGE}"
    local actionlint_image="${2:-$TRON_CI_ACTIONLINT_IMAGE}"
    rust_version="$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$repo_root/rust-toolchain.toml")"
    [[ -n "$rust_version" ]] || {
        echo "error: rust-toolchain.toml has no channel" >&2
        return 1
    }
    rust_digest="${rust_image#rust:"$rust_version"-bookworm@sha256:}"
    if [[ "$rust_digest" == "$rust_image" ]]; then
        echo "error: Rust CI image is not version-bound to rust-toolchain.toml" >&2
        return 1
    fi
    [[ "$rust_digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "error: Rust CI image is not digest-pinned" >&2
        return 1
    }
    actionlint_digest="${actionlint_image#rhysd/actionlint:1.7.12@sha256:}"
    [[ "$actionlint_digest" != "$actionlint_image" && "$actionlint_digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "error: actionlint image is not version- and digest-pinned" >&2
        return 1
    }
    [[ "$TRON_CI_BUILDKITE_AGENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "error: Buildkite agent version is invalid" >&2
        return 1
    }
    for checksum in \
        "$TRON_CI_BUILDKITE_AGENT_LINUX_AMD64_SHA256" \
        "$TRON_CI_BUILDKITE_AGENT_DARWIN_ARM64_SHA256"; do
        [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || {
            echo "error: Buildkite agent archive checksum is invalid" >&2
            return 1
        }
    done
    if [[ "$TRON_CI_BUILDKITE_AGENT_LINUX_AMD64_URL" != \
        "https://github.com/buildkite/agent/releases/download/v$TRON_CI_BUILDKITE_AGENT_VERSION/buildkite-agent-linux-amd64-$TRON_CI_BUILDKITE_AGENT_VERSION.tar.gz" \
        || "$TRON_CI_BUILDKITE_AGENT_DARWIN_ARM64_URL" != \
        "https://github.com/buildkite/agent/releases/download/v$TRON_CI_BUILDKITE_AGENT_VERSION/buildkite-agent-darwin-arm64-$TRON_CI_BUILDKITE_AGENT_VERSION.tar.gz" ]]; then
        echo "error: Buildkite agent URLs do not match the pinned version/platforms" >&2
        return 1
    fi
    for pipeline in .buildkite/pipeline.yml .buildkite/shadow-steps.yml; do
        [[ -s "$repo_root/$pipeline" ]] || {
            echo "error: missing CI definition: $pipeline" >&2
            return 1
        }
    done
    grep -Fq 'rustup component add --toolchain' "$repo_root/.buildkite/rust-shadow.Dockerfile"
}

validate_buildkite_pipeline() {
    local path="$1"
    BUILDKITE_AGENT_ACCESS_TOKEN=ci-definition-validation-placeholder \
    BUILDKITE_JOB_ID=12345678-1234-4234-8234-123456789abc \
        buildkite-agent pipeline upload \
            --dry-run \
            --format yaml \
            --reject-secrets \
            --reject-parse-warnings \
            < "$path" >/dev/null
}

self_test() {
    validate_manifest_contract
    if validate_manifest_contract \
        'rust:wrong@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        "$TRON_CI_ACTIONLINT_IMAGE" >/dev/null 2>&1; then
        echo "self-test failed: mismatched Rust image version was accepted" >&2
        return 1
    fi
    if validate_manifest_contract \
        "$TRON_CI_RUST_IMAGE" \
        'rhysd/actionlint:1.7.12@sha256:not-a-digest' >/dev/null 2>&1; then
        echo "self-test failed: malformed actionlint digest was accepted" >&2
        return 1
    fi
    grep -Fq 'TRON_CI_RUST_IMAGE' "$repo_root/scripts/ci-shadow-run.sh"
    grep -Fq '.buildkite/rust-shadow.Dockerfile' "$repo_root/scripts/ci-shadow-run.sh"
    grep -Fq 'scripts/validate-ci-definitions.sh' "$repo_root/.github/workflows/ci.yml"
    grep -Fq 'scripts/validate-ci-definitions.sh' "$repo_root/scripts/ci-shadow-run.sh"
    grep -Fq -- '--reject-parse-warnings' "$repo_root/scripts/validate-ci-definitions.sh"
    echo "CI definition validator self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
    [[ $# -eq 1 ]] || { echo "error: --self-test takes no arguments" >&2; exit 2; }
    self_test
    exit 0
fi
[[ $# -eq 0 ]] || { echo "usage: scripts/validate-ci-definitions.sh [--self-test]" >&2; exit 2; }

validate_manifest_contract
export TRON_CI_TOOLS_DIR="${TRON_CI_TOOLS_DIR:-${RUNNER_TEMP:-/tmp}/tron-ci-tools}"
export PATH="$TRON_CI_TOOLS_DIR/bin:$PATH"
"$repo_root/scripts/install-ci-tools.sh" buildkite-agent
"$repo_root/scripts/verify-ci-toolchain.sh" buildkite-agent

command -v docker >/dev/null || {
    echo "error: Docker is required to execute the pinned actionlint image" >&2
    exit 1
}
actionlint_version="$(docker run --rm "$TRON_CI_ACTIONLINT_IMAGE" -version)"
[[ "$actionlint_version" == 1.7.12$'\n'* || "$actionlint_version" == "1.7.12" ]] || {
    echo "error: pinned actionlint image reported an unexpected version" >&2
    exit 1
}
docker run --rm \
    --volume "$repo_root:/work:ro" \
    --workdir /work \
    "$TRON_CI_ACTIONLINT_IMAGE" \
    -color=false

validate_buildkite_pipeline "$repo_root/.buildkite/pipeline.yml"
validate_buildkite_pipeline "$repo_root/.buildkite/shadow-steps.yml"
echo "CI definitions validated"
