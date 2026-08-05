#!/bin/bash
# Derive macOS workload flags from an exact Git diff without a third-party action.

set -euo pipefail

classify_paths() {
    local ios=false mac=false path
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        case "$path" in
            packages/ios-app/*|.github/workflows/ci.yml|.github/workflows/release-ios.yml|config/ci-toolchain.env|scripts/tron-version|scripts/install-ci-tools.sh|scripts/verify-ci-toolchain.sh)
                ios=true
                ;;
        esac
        case "$path" in
            rust-toolchain.toml|packages/agent/*|packages/mac-app/*|.github/workflows/ci.yml|.github/workflows/release-mac.yml|config/ci-toolchain.env|scripts/tron-version|scripts/install-ci-tools.sh|scripts/verify-ci-toolchain.sh)
                mac=true
                ;;
        esac
    done
    printf 'ios=%s\nmac=%s\n' "$ios" "$mac"
}

if [[ "${1:-}" == "--self-test" ]]; then
    result="$(printf '%s\n' packages/ios-app/project.yml README.md | classify_paths)"
    [[ "$result" == $'ios=true\nmac=false' ]]
    result="$(printf '%s\n' packages/agent/src/lib.rs | classify_paths)"
    [[ "$result" == $'ios=false\nmac=true' ]]
    result="$(printf '%s\n' config/ci-toolchain.env | classify_paths)"
    [[ "$result" == $'ios=true\nmac=true' ]]
    result="$(printf '%s\n' scripts/tron-version | classify_paths)"
    [[ "$result" == $'ios=true\nmac=true' ]]
    result="$(printf '%s\n' README.md | classify_paths)"
    [[ "$result" == $'ios=false\nmac=false' ]]
    echo "change classifier self-test passed"
    exit 0
fi

head_sha="${TRON_DIFF_HEAD_SHA:?TRON_DIFF_HEAD_SHA is required}"
base_sha="${TRON_DIFF_BASE_SHA:-$head_sha}"
if [[ "$base_sha" =~ ^0+$ ]]; then
    base_sha="$head_sha"
fi
git cat-file -e "$base_sha^{commit}"
git cat-file -e "$head_sha^{commit}"
result="$(git diff --name-only --no-renames "$base_sha" "$head_sha" | classify_paths)"
printf '%s\n' "$result"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$result" >> "$GITHUB_OUTPUT"
fi
