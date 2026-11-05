#!/usr/bin/env bash
# Fail when the selected Apple/release tools differ from repository pins.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ci-toolchain.env"
NODE_VERSION_FILE="$ROOT/.node-version"
[[ -f "$NODE_VERSION_FILE" ]] || { echo "missing canonical Node version file: $NODE_VERSION_FILE" >&2; exit 1; }
TRON_NODE_VERSION="$(<"$NODE_VERSION_FILE")"
node_version_lines="$(awk 'END { print NR }' "$NODE_VERSION_FILE")"
[[ "$node_version_lines" == 1 && "$TRON_NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "canonical Node version must be one strict x.y.z line (found $TRON_NODE_VERSION)" >&2; exit 1; }
for tool in "$@"; do
  case "$tool" in
    node)
      [[ "$(node --version 2>/dev/null || true)" == "v${TRON_NODE_VERSION}" ]] \
        || { echo "Node must be exactly ${TRON_NODE_VERSION}" >&2; exit 1; }
      ;;
    xcode)
      xcodebuild -version | grep -F "Xcode $TRON_CI_XCODE_VERSION" >/dev/null
      ;;
    ios)
      xcodebuild -version | grep -F "Xcode $TRON_CI_XCODE_VERSION" >/dev/null
      xcrun simctl list runtimes | grep -F "iOS $TRON_CI_IOS_RUNTIME_VERSION" >/dev/null
      ;;
    xcodegen)
      xcodegen_version="$(xcodegen --version)"
      [[ "$xcodegen_version" == "Version: $TRON_CI_XCODEGEN_VERSION" ]] \
        || { echo "XcodeGen must be exactly $TRON_CI_XCODEGEN_VERSION" >&2; exit 1; }
      presets="$(cd "$(dirname "$(command -v xcodegen)")/../share/xcodegen/SettingPresets" 2>/dev/null && pwd -P)" \
        || { echo "xcodegen setting presets are unavailable" >&2; exit 1; }
      [[ -f "$presets/base.yml" && -f "$presets/Platforms/iOS.yml" && -f "$presets/Platforms/macOS.yml" ]] \
        || { echo "xcodegen setting presets are incomplete" >&2; exit 1; }
      ;;
    release)
      # The maintainer's manual iOS release (packages/ios-app/docs/development.md) archives with this exact Xcode.
      [[ "$TRON_RELEASE_IOS_DEVELOPER_DIR" != *[Bb]eta* ]] \
        || { echo "release Xcode must not be a beta bundle: $TRON_RELEASE_IOS_DEVELOPER_DIR" >&2; exit 1; }
      [[ -d "$TRON_RELEASE_IOS_DEVELOPER_DIR" ]] \
        || { echo "release Xcode is not installed: $TRON_RELEASE_IOS_DEVELOPER_DIR" >&2; exit 1; }
      release_xcode="$(DEVELOPER_DIR="$TRON_RELEASE_IOS_DEVELOPER_DIR" xcodebuild -version)"
      [[ "$(sed -n '1s/^Xcode //p' <<< "$release_xcode")" == "$TRON_RELEASE_IOS_XCODE_VERSION" \
         && "$(sed -n '2s/^Build version //p' <<< "$release_xcode")" == "$TRON_RELEASE_IOS_XCODE_BUILD" ]] \
        || { echo "release Xcode must be $TRON_RELEASE_IOS_XCODE_VERSION ($TRON_RELEASE_IOS_XCODE_BUILD); found: ${release_xcode//$'\n'/ }" >&2; exit 1; }
      release_sdk="$(DEVELOPER_DIR="$TRON_RELEASE_IOS_DEVELOPER_DIR" xcrun --sdk iphoneos --show-sdk-version)"
      [[ "$release_sdk" == "$TRON_RELEASE_IOS_SDK_VERSION" ]] \
        || { echo "release iPhoneOS SDK must be $TRON_RELEASE_IOS_SDK_VERSION; found: $release_sdk" >&2; exit 1; }
      DEVELOPER_DIR="$TRON_RELEASE_IOS_DEVELOPER_DIR" xcodebuild -checkFirstLaunchStatus >/dev/null \
        || { echo "release Xcode first-launch tasks or license acceptance are incomplete" >&2; exit 1; }
      ;;
    *) echo "unsupported tool verification: $tool" >&2; exit 64 ;;
  esac
done
