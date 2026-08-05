#!/bin/bash
# Verify the selected CI toolchain matches the repository-owned manifest.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/config/ci-toolchain.env"

require_contains() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != *"$expected"* ]]; then
        echo "error: $label mismatch; expected $expected, got: $actual" >&2
        return 1
    fi
}

verify_xcodegen() {
    require_contains XcodeGen "$TRON_CI_XCODEGEN_VERSION" "$(xcodegen --version 2>&1)"
    local executable_root presets
    executable_root="$(cd "$(dirname "$(command -v xcodegen)")/.." && pwd)"
    presets="$executable_root/share/xcodegen/SettingPresets"
    for required in base.yml Configs/debug.yml Configs/release.yml Platforms/iOS.yml Platforms/macOS.yml; do
        if [[ ! -f "$presets/$required" ]]; then
            echo "error: XcodeGen setting preset is missing: $presets/$required" >&2
            return 1
        fi
    done
}

verify_create_dmg() {
    require_contains create-dmg "$TRON_CI_CREATE_DMG_VERSION" "$(create-dmg --version 2>&1)"
}

verify_asc() {
    require_contains ASC "$TRON_CI_ASC_VERSION" "$(asc version 2>&1)"
}

verify_xcode() {
    require_contains Xcode "Xcode $TRON_CI_XCODE_VERSION" "$(xcodebuild -version)"
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
for target in "$@"; do
    case "$target" in
        xcode) verify_xcode ;;
        ios) verify_ios ;;
        xcodegen) verify_xcodegen ;;
        create-dmg) verify_create_dmg ;;
        asc) verify_asc ;;
        *) echo "error: unsupported verification target: $target" >&2; exit 2 ;;
    esac
done
