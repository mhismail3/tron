#!/usr/bin/env bash
# Fail when the selected Apple/release tools differ from repository pins.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ci-toolchain.env"
for tool in "$@"; do
  case "$tool" in
    xcode)
      xcodebuild -version | grep -F "Xcode $TRON_CI_XCODE_VERSION" >/dev/null
      ;;
    ios)
      xcodebuild -version | grep -F "Xcode $TRON_CI_XCODE_VERSION" >/dev/null
      xcrun simctl list runtimes | grep -F "iOS $TRON_CI_IOS_RUNTIME_VERSION" >/dev/null
      ;;
    xcodegen)
      xcodegen --version | grep -F "$TRON_CI_XCODEGEN_VERSION" >/dev/null
      ;;
    create-dmg)
      command -v create-dmg >/dev/null
      ;;
    asc)
      asc version 2>&1 | grep -F "$TRON_CI_ASC_VERSION" >/dev/null
      ;;
    *) echo "unsupported tool verification: $tool" >&2; exit 64 ;;
  esac
done
