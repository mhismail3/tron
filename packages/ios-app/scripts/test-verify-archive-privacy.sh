#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$script_dir/.." && pwd)"
verifier="$script_dir/verify-archive-privacy.sh"
manifest="$package_root/Sources/PrivacyInfo.xcprivacy"
root="$(mktemp -d "${TMPDIR:-/tmp}/tron-privacy-archive.XXXXXX")"
trap 'rm -rf "$root"' EXIT

fixture() {
  local name="$1"
  local archive="$root/$name.xcarchive"
  local app="$archive/Products/Applications/TronMobile.app"
  local extension="$app/PlugIns/TronShareExtension.appex"
  mkdir -p "$extension"
  cp "$manifest" "$app/PrivacyInfo.xcprivacy"
  cp "$manifest" "$extension/PrivacyInfo.xcprivacy"
  printf '%s\n' "$archive"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$($verifier "$@" 2>&1)"; then
    echo "expected verifier failure containing: $expected" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "unexpected verifier failure: $output" >&2
    exit 1
  fi
}

valid="$(fixture valid)"
"$verifier" "$valid" >/dev/null

missing_app="$(fixture missing-app)"
rm "$missing_app/Products/Applications/TronMobile.app/PrivacyInfo.xcprivacy"
expect_failure "missing privacy manifest" "$missing_app"

duplicate_app="$(fixture duplicate-app)"
cp -R "$duplicate_app/Products/Applications/TronMobile.app" \
  "$duplicate_app/Products/Applications/Other.app"
expect_failure "expected exactly one app" "$duplicate_app"

duplicate_extension="$(fixture duplicate-extension)"
cp -R "$duplicate_extension/Products/Applications/TronMobile.app/PlugIns/TronShareExtension.appex" \
  "$duplicate_extension/Products/Applications/TronMobile.app/PlugIns/Other.appex"
expect_failure "expected exactly one extension" "$duplicate_extension"

malformed="$(fixture malformed)"
printf 'not a plist\n' > "$malformed/Products/Applications/TronMobile.app/PlugIns/TronShareExtension.appex/PrivacyInfo.xcprivacy"
expect_failure "PrivacyInfo.xcprivacy:" "$malformed"

echo "archive privacy verifier fixtures passed"
