#!/bin/bash
# Verify the selected CI toolchain matches the repository-owned manifest.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/config/ci-toolchain.env"

log_ci_event() {
    local event="$1" details="${2:-}" timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="${details//$'\r'/ }"
    details="${details//$'\n'/ }"
    printf 'timestamp=%s level=info component=ci-toolchain-verifier event=%s%s\n' \
        "$timestamp" "$event" "$([[ -n "$details" ]] && printf ' %s' "$details")" >&2
}

require_contains() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != *"$expected"* ]]; then
        echo "error: $label mismatch; expected $expected, got: $actual" >&2
        return 1
    fi
}

resolved_command_path() {
    python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

verify_owned_prefix() {
    local tool="$1" prefix="$2"
    "$repo_root/scripts/install-ci-tools.sh" --verify-prefix "$tool" "$prefix"
}

verify_xcodegen() {
    local executable prefix presets
    executable="$(resolved_command_path "$(command -v xcodegen)")"
    prefix="$(cd "$(dirname "$executable")/.." && pwd -P)"
    verify_owned_prefix xcodegen "$prefix"
    require_contains XcodeGen "$TRON_CI_XCODEGEN_VERSION" "$("$executable" --version 2>&1)"
    presets="$prefix/share/xcodegen/SettingPresets"
    for required in base.yml Configs/debug.yml Configs/release.yml Platforms/iOS.yml Platforms/macOS.yml; do
        if [[ ! -f "$presets/$required" ]]; then
            echo "error: XcodeGen setting preset is missing: $presets/$required" >&2
            return 1
        fi
    done
}

verify_create_dmg() {
    local executable prefix required
    executable="$(resolved_command_path "$(command -v create-dmg)")"
    prefix="$(cd "$(dirname "$executable")/.." && pwd -P)"
    verify_owned_prefix create-dmg "$prefix"
    require_contains create-dmg "$TRON_CI_CREATE_DMG_VERSION" "$("$executable" --version 2>&1)"
    for required in template.applescript eula-resources-template.xml; do
        if [[ ! -f "$prefix/share/create-dmg/support/$required" ]]; then
            echo "error: create-dmg support asset is missing: $required" >&2
            return 1
        fi
    done
}

verify_asc() {
    local executable prefix
    executable="$(resolved_command_path "$(command -v asc)")"
    prefix="$(cd "$(dirname "$executable")" && pwd -P)"
    verify_owned_prefix asc "$prefix"
    require_contains ASC "$TRON_CI_ASC_VERSION" "$("$executable" version 2>&1)"
}

verify_xcode() {
    require_contains Xcode "Xcode $TRON_CI_XCODE_VERSION" "$(xcodebuild -version)"
}

verify_buildkite_agent() {
    local executable prefix
    executable="$(resolved_command_path "$(command -v buildkite-agent)")"
    prefix="$(cd "$(dirname "$executable")" && pwd -P)"
    verify_owned_prefix buildkite-agent "$prefix"
    require_contains Buildkite-agent \
        "version $TRON_CI_BUILDKITE_AGENT_VERSION" \
        "$("$executable" --version 2>&1)"
}

verify_ios() {
    verify_xcode
    local runtimes devices
    runtimes="$(xcrun simctl list runtimes available --json)"
    devices="$(xcrun simctl list devices available --json)"
    jq -e --arg version "$TRON_CI_IOS_RUNTIME_VERSION" '
      any(.runtimes[]; .platform == "iOS" and .version == $version and .isAvailable == true)
    ' <<< "$runtimes" >/dev/null
    jq -e --arg name "$TRON_CI_IOS_SIMULATOR_NAME" '
      any(.devices[][]; .name == $name and .isAvailable == true)
    ' <<< "$devices" >/dev/null
}

if [[ $# -eq 0 ]]; then
    set -- ios xcodegen
fi
manifest_sha256="$(shasum -a 256 "$repo_root/config/ci-toolchain.env" | awk '{print $1}')"
log_ci_event verification_started \
    "target_count=$# manifest_sha256=$manifest_sha256"
for target in "$@"; do
    case "$target" in
        xcode) verify_xcode ;;
        ios) verify_ios ;;
        xcodegen) verify_xcodegen ;;
        create-dmg) verify_create_dmg ;;
        asc) verify_asc ;;
        buildkite-agent) verify_buildkite_agent ;;
        *) echo "error: unsupported verification target: $target" >&2; exit 2 ;;
    esac
    log_ci_event target_verified "target=$target"
done
log_ci_event verification_completed \
    "target_count=$# manifest_sha256=$manifest_sha256"
