#!/usr/bin/env bash
set -euo pipefail

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
    echo "::notice::timestamp=$timestamp component=ios-release-runner-doctor event=$event $details"
}

doctor_mode="${1:-}"
case "$doctor_mode" in
    "" | --self-test | --audit-credentials) ;;
    *) die "usage: scripts/ios-release-runner-doctor.sh [--self-test|--audit-credentials]" ;;
esac

required_release_values=(
    TRON_RELEASE_IOS_XCODE_VERSION
    TRON_RELEASE_IOS_XCODE_BUILD
    TRON_RELEASE_IOS_SDK_VERSION
    TRON_RELEASE_IOS_DEVELOPER_DIR
    TRON_RELEASE_IOS_DEPLOYMENT_TARGET
    TRON_RELEASE_IOS_MIN_FREE_GB
    TRON_RELEASE_RUNNER_VERSION
    TRON_RELEASE_RUNNER_URL
    TRON_RELEASE_RUNNER_SHA256
    TRON_RELEASE_APPLE_ROOT_URL
    TRON_RELEASE_APPLE_ROOT_SHA256
    TRON_RELEASE_APPLE_WWDR_G3_URL
    TRON_RELEASE_APPLE_WWDR_G3_SHA256
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
[[ "$TRON_RELEASE_RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid runner version"
[[ "$TRON_RELEASE_RUNNER_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die "invalid runner checksum"
[[ "$TRON_RELEASE_APPLE_ROOT_SHA256" =~ ^[[:xdigit:]]{64}$ ]] \
    || die "invalid Apple Root CA checksum"
[[ "$TRON_RELEASE_APPLE_WWDR_G3_SHA256" =~ ^[[:xdigit:]]{64}$ ]] \
    || die "invalid Apple WWDR G3 checksum"
expected_runner_url="https://github.com/actions/runner/releases/download/v${TRON_RELEASE_RUNNER_VERSION}/actions-runner-osx-arm64-${TRON_RELEASE_RUNNER_VERSION}.tar.gz"
[[ "$TRON_RELEASE_RUNNER_URL" == "$expected_runner_url" ]] \
    || die "runner URL does not match the pinned version and ARM64 platform"
expected_apple_root_url="https://www.apple.com/appleca/AppleIncRootCertificate.cer"
[[ "$TRON_RELEASE_APPLE_ROOT_URL" == "$expected_apple_root_url" ]] \
    || die "Apple Root CA certificate must come from the canonical Apple PKI URL"
expected_wwdr_g3_url="https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
[[ "$TRON_RELEASE_APPLE_WWDR_G3_URL" == "$expected_wwdr_g3_url" ]] \
    || die "Apple WWDR G3 certificate must come from the canonical Apple PKI URL"

if [[ "$doctor_mode" == "--self-test" ]]; then
    python3 "$project_dir/scripts/ios-release-verify.py" self-test
    python3 "$project_dir/scripts/ios-release-credential-ledger.py" self-test
    echo "iOS release runner configuration self-test passed"
    exit 0
fi

notice doctor_started \
    "mode=${doctor_mode:-verify} github_actions=${GITHUB_ACTIONS:-false} source_sha=${GITHUB_SHA:-local}"

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
    [[ "${ACTIONS_RUNNER_SVC:-}" == "1" ]] \
        || die "TestFlight archives must run through the dedicated launchd service"
    runner_uid="$(id -u)"
    manager_uid="$(launchctl manageruid 2>/dev/null || true)"
    manager_name="$(launchctl managername 2>/dev/null || true)"
    [[ "$manager_uid" == "$runner_uid" ]] \
        || die "TestFlight archives must run in the release account's launchd domain: expected_uid=$runner_uid observed_uid=${manager_uid:-unavailable}"
    [[ "$manager_name" == "Background" ]] \
        || die "TestFlight archives require the headless Background domain: observed=${manager_name:-unavailable}"
    if ! security_session="$(
        python3 "$project_dir/scripts/ios-release-verify.py" \
            security-session --require-non-root \
            --require-audit-uid "$runner_uid"
    )"; then
        die "TestFlight archives require the release account's security session: ${security_session:-verifier unavailable}"
    fi
    notice listener_identity_verified \
        "effective_uid=$runner_uid manager_uid=$manager_uid manager_name=$manager_name security_session=$security_session"
    user_context="$project_dir/scripts/ios-release-user-context"
    [[ -x "$user_context" ]] \
        || die "release user-context boundary is missing or non-executable"
    boundary_manager_uid="$("$user_context" /bin/launchctl manageruid)"
    [[ "$boundary_manager_uid" == "$runner_uid" ]] \
        || die "release user-context boundary selected the wrong launchd account: expected_uid=$runner_uid observed_uid=${boundary_manager_uid:-unavailable}"
    boundary_manager_name="$("$user_context" /bin/launchctl managername)"
    [[ "$boundary_manager_name" == "Background" ]] \
        || die "release user-context boundary requires the headless Background domain: observed=${boundary_manager_name:-unavailable}"
    if ! boundary_security_session="$(
        "$user_context" python3 "$project_dir/scripts/ios-release-verify.py" \
            security-session --require-non-root \
            --require-audit-uid "$runner_uid"
    )"; then
        die "release user-context boundary has a mixed audit identity: ${boundary_security_session:-verifier unavailable}"
    fi
    notice command_boundary_verified \
        "manager_uid=$boundary_manager_uid manager_name=$boundary_manager_name security_session=$boundary_security_session"
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
    baseline_keychain="$HOME/Library/Keychains/tron-runner-baseline.keychain-db"
    [[ -f "$baseline_keychain" && ! -L "$baseline_keychain" ]] \
        || die "release runner baseline keychain must be a regular file"
    [[ "$(/usr/bin/stat -f '%Su' "$baseline_keychain")" == "$runner_user" ]] \
        || die "release runner baseline keychain has the wrong owner"
    [[ "$(/usr/bin/stat -f '%Lp' "$baseline_keychain")" == "600" ]] \
        || die "release runner baseline keychain must have mode 0600"
    [[ "$(/usr/bin/stat -f '%l' "$baseline_keychain")" == "1" ]] \
        || die "release runner baseline keychain must not have hard links"
    notice filesystem_boundary_verified \
        "home_mode=700 baseline_keychain_mode=600 workspace_confined=true temp_confined=true admin=false"
fi

free_kb="$(df -Pk "$project_dir" | awk 'NR == 2 { print $4 }')"
[[ "$free_kb" =~ ^[0-9]+$ ]] || die "could not determine free workspace capacity"
minimum_kb=$((TRON_RELEASE_IOS_MIN_FREE_GB * 1024 * 1024))
(( free_kb >= minimum_kb )) \
    || die "release runner needs at least ${TRON_RELEASE_IOS_MIN_FREE_GB}GB free"
notice capacity_verified "free_kb=$free_kb minimum_kb=$minimum_kb"

for executable in python3 security codesign xcodebuild xcrun; do
    command -v "$executable" >/dev/null || die "missing required executable: $executable"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "missing PlistBuddy"

if [[ "$doctor_mode" == "--audit-credentials" ]]; then
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        "$user_context" python3 \
            "$project_dir/scripts/ios-release-credential-ledger.py" audit >/dev/null \
            || die "stale iOS release credential state is present"
    else
        python3 "$project_dir/scripts/ios-release-credential-ledger.py" audit >/dev/null \
            || die "stale iOS release credential state is present"
    fi
fi

notice doctor_completed \
    "xcode_version=$actual_xcode_version xcode_build=$actual_xcode_build ios_sdk=$actual_sdk credential_audit=$([[ "$doctor_mode" == "--audit-credentials" ]] && echo true || echo false)"
echo "Verified release toolchain: Xcode $actual_xcode_version ($actual_xcode_build), iPhoneOS SDK $actual_sdk"
