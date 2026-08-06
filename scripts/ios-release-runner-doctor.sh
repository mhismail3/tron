#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$project_dir/config/ci-toolchain.env"

die() {
    echo "::error::$*" >&2
    exit 1
}

required_release_values=(
    TRON_RELEASE_IOS_XCODE_VERSION
    TRON_RELEASE_IOS_XCODE_BUILD
    TRON_RELEASE_IOS_SDK_VERSION
    TRON_RELEASE_IOS_RUNTIME_VERSION
    TRON_RELEASE_IOS_DEVELOPER_DIR
    TRON_RELEASE_IOS_DEPLOYMENT_TARGET
    TRON_RELEASE_IOS_MIN_FREE_GB
    TRON_RELEASE_RUNNER_VERSION
    TRON_RELEASE_RUNNER_URL
    TRON_RELEASE_RUNNER_SHA256
)
for variable_name in "${required_release_values[@]}"; do
    [[ -n "${!variable_name:-}" ]] || die "missing $variable_name in config/ci-toolchain.env"
done
[[ "$TRON_RELEASE_IOS_XCODE_VERSION" != "latest" ]] || die "release Xcode must be exact"
[[ "$TRON_RELEASE_IOS_XCODE_BUILD" =~ ^[[:alnum:]]+$ ]] || die "invalid release Xcode build"
[[ "$TRON_RELEASE_IOS_SDK_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid release SDK version"
[[ "$TRON_RELEASE_IOS_DEPLOYMENT_TARGET" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid deployment target"
[[ "$TRON_RELEASE_RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid runner version"
[[ "$TRON_RELEASE_RUNNER_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die "invalid runner checksum"
expected_runner_url="https://github.com/actions/runner/releases/download/v${TRON_RELEASE_RUNNER_VERSION}/actions-runner-osx-arm64-${TRON_RELEASE_RUNNER_VERSION}.tar.gz"
[[ "$TRON_RELEASE_RUNNER_URL" == "$expected_runner_url" ]] \
    || die "runner URL does not match the pinned version and ARM64 platform"

if [[ "${1:-}" == "--self-test" ]]; then
    python3 "$project_dir/scripts/ios-release-verify.py" self-test
    echo "iOS release runner configuration self-test passed"
    exit 0
fi

[[ "$(uname -m)" == "arm64" ]] || die "iOS release runner must be Apple silicon"
[[ -d "${TRON_RELEASE_IOS_DEVELOPER_DIR%/Contents/Developer}" ]] \
    || die "pinned Xcode application is not installed"
export DEVELOPER_DIR="$TRON_RELEASE_IOS_DEVELOPER_DIR"

xcode_version_output="$(xcodebuild -version)"
actual_xcode_version="$(sed -n '1s/^Xcode //p' <<< "$xcode_version_output")"
actual_xcode_build="$(sed -n '2s/^Build version //p' <<< "$xcode_version_output")"
[[ "$actual_xcode_version" == "$TRON_RELEASE_IOS_XCODE_VERSION" ]] \
    || die "Xcode version $actual_xcode_version does not match $TRON_RELEASE_IOS_XCODE_VERSION"
[[ "$actual_xcode_build" == "$TRON_RELEASE_IOS_XCODE_BUILD" ]] \
    || die "Xcode build $actual_xcode_build does not match $TRON_RELEASE_IOS_XCODE_BUILD"

actual_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
[[ "$actual_sdk" == "$TRON_RELEASE_IOS_SDK_VERSION" ]] \
    || die "iPhoneOS SDK $actual_sdk does not match $TRON_RELEASE_IOS_SDK_VERSION"
xcodebuild -checkFirstLaunchStatus >/dev/null \
    || die "Xcode first-launch tasks or license acceptance are incomplete"

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    [[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]] \
        || die "TestFlight archives must run on a self-hosted runner"
    runner_user="$(id -un)"
    [[ "$runner_user" == "tron-ci" ]] \
        || die "TestFlight archives must run as the isolated tron-ci account"
    [[ "$HOME" == "/Users/tron-ci" ]] \
        || die "release runner HOME must be /Users/tron-ci"
    [[ "$(/usr/bin/stat -f '%Su' "$HOME")" == "$runner_user" ]] \
        || die "release runner home has the wrong owner"
    [[ "$(/usr/bin/stat -f '%Lp' "$HOME")" == "700" ]] \
        || die "release runner home must have mode 0700"
    if id -Gn "$runner_user" | tr ' ' '\n' | grep -Fxq admin; then
        die "release runner account must not be an administrator"
    fi
    case "${GITHUB_WORKSPACE:-}" in
        "$HOME/actions-runner/_work/"*) ;;
        *) die "GitHub workspace is outside the isolated runner home" ;;
    esac
    case "${RUNNER_TEMP:-}" in
        "$HOME/actions-runner/_work/"*) ;;
        *) die "runner temp is outside the isolated runner home" ;;
    esac
    [[ -f "$HOME/Library/Keychains/tron-runner-baseline.keychain-db" ]] \
        || die "release runner baseline keychain is missing"
fi

free_kb="$(df -Pk "$project_dir" | awk 'NR == 2 { print $4 }')"
[[ "$free_kb" =~ ^[0-9]+$ ]] || die "could not determine free workspace capacity"
minimum_kb=$((TRON_RELEASE_IOS_MIN_FREE_GB * 1024 * 1024))
(( free_kb >= minimum_kb )) \
    || die "release runner needs at least ${TRON_RELEASE_IOS_MIN_FREE_GB}GB free"

for executable in python3 security codesign xcodebuild xcrun; do
    command -v "$executable" >/dev/null || die "missing required executable: $executable"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "missing PlistBuddy"

echo "Verified release toolchain: Xcode $actual_xcode_version ($actual_xcode_build), iPhoneOS SDK $actual_sdk"
