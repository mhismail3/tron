#!/usr/bin/env bash
set -euo pipefail

# Fail-closed preflight for the ephemeral GitHub-hosted TestFlight job. This
# runs before any signing or App Store secret is admitted.

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$project_dir/config/ci-toolchain.env"

die() {
    echo "::error::$*" >&2
    exit 1
}

notice() {
    local event="$1" details="${2:-}" timestamp
    timestamp="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="${details//$'\r'/ }"
    details="${details//$'\n'/ }"
    echo "::notice::timestamp=$timestamp component=ios-release-toolchain-doctor event=$event $details"
}

doctor_mode="${1:-}"
case "$doctor_mode" in
    "" | --self-test) ;;
    *) die "usage: scripts/ios-release-toolchain-doctor.sh [--self-test]" ;;
esac

required_release_values=(
    TRON_RELEASE_IOS_XCODE_VERSION
    TRON_RELEASE_IOS_XCODE_BUILD
    TRON_RELEASE_IOS_SDK_VERSION
    TRON_RELEASE_IOS_DEVELOPER_DIR
    TRON_RELEASE_IOS_DEPLOYMENT_TARGET
    TRON_RELEASE_IOS_MIN_FREE_GB
)
for variable_name in "${required_release_values[@]}"; do
    [[ -n "${!variable_name:-}" ]] || die "missing $variable_name in config/ci-toolchain.env"
done
[[ "$TRON_RELEASE_IOS_XCODE_VERSION" != "latest" ]] || die "release Xcode must be exact"
[[ "$TRON_RELEASE_IOS_DEVELOPER_DIR" != *[Bb]eta* ]] \
    || die "TestFlight delivery must not use a beta Xcode bundle"
[[ "$TRON_RELEASE_IOS_XCODE_BUILD" =~ ^[[:alnum:]]+$ ]] || die "invalid release Xcode build"
[[ "$TRON_RELEASE_IOS_SDK_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid release SDK version"
[[ "$TRON_RELEASE_IOS_DEPLOYMENT_TARGET" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid deployment target"
[[ "$TRON_RELEASE_IOS_MIN_FREE_GB" =~ ^[1-9][0-9]*$ ]] || die "invalid minimum free capacity"

if [[ "$doctor_mode" == "--self-test" ]]; then
    echo "iOS release toolchain configuration self-test passed"
    exit 0
fi

notice doctor_started \
    "github_actions=${GITHUB_ACTIONS:-false} runner_environment=${RUNNER_ENVIRONMENT:-unavailable} image_os=${ImageOS:-unavailable} source_sha=${GITHUB_SHA:-local}"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
    || die "TestFlight delivery requires GitHub's macOS 26 ARM64 image"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || die "live TestFlight preflight requires GitHub Actions"
[[ "${RUNNER_ENVIRONMENT:-}" == "github-hosted" ]] \
    || die "TestFlight delivery must use an ephemeral GitHub-hosted runner"
[[ "${ImageOS:-}" == "macos26" ]] \
    || die "TestFlight delivery requires the pinned macos-26 image"
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

free_kb="$(df -Pk "$project_dir" | awk 'NR == 2 { print $4 }')"
[[ "$free_kb" =~ ^[0-9]+$ ]] || die "could not determine free workspace capacity"
minimum_kb=$((TRON_RELEASE_IOS_MIN_FREE_GB * 1024 * 1024))
(( free_kb >= minimum_kb )) \
    || die "release job needs at least ${TRON_RELEASE_IOS_MIN_FREE_GB}GB free"

for executable in python3 security codesign xcodebuild xcrun; do
    command -v "$executable" >/dev/null || die "missing required executable: $executable"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "missing PlistBuddy"

notice doctor_completed \
    "runner_environment=$RUNNER_ENVIRONMENT image_os=$ImageOS xcode_version=$actual_xcode_version xcode_build=$actual_xcode_build ios_sdk=$actual_sdk free_kb=$free_kb"
echo "Verified hosted release toolchain: Xcode $actual_xcode_version ($actual_xcode_build), iPhoneOS SDK $actual_sdk"
