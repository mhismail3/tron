#!/usr/bin/env bash
# Source-level iOS project policy checks. Generated Info-plists are projections.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/project.yml"
INFO="$ROOT/Sources/Info.plist"
fail() { echo "iOS source policy: $*" >&2; exit 1; }
[[ -f "$PROJECT" && -f "$INFO" ]] || fail "missing project source"

iphone_key='INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone'
ipad_key='INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad'
iphone_value='UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
ipad_value='UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
iphone="${iphone_key}: \"${iphone_value}\""
ipad="${ipad_key}: \"${ipad_value}\""
[[ "$(grep -Fc "$iphone" "$PROJECT")" == 1 ]] || fail "project.yml must declare the exact iPhone orientation policy once"
[[ "$(grep -Fc "$ipad" "$PROJECT")" == 1 ]] || fail "project.yml must declare the exact iPad orientation policy once"

# Every checked-in source Info.plist must leave orientation ownership to the
# generated build settings. This includes the share extension plist.
while IFS= read -r info; do
  ! grep -Eq 'UISupportedInterfaceOrientations' "$info" \
    || fail "orientation keys must not be present in $info"
done < <(find "$ROOT/Sources" "$ROOT/ShareExtension" -name Info.plist -type f -print)

# Render into a disposable directory and inspect the actual Xcode project. Do
# not leave generated projects in the working tree.
generated_root="$(mktemp -d "${TMPDIR:-/tmp}/tron-ios-source-policy.XXXXXX")"
cleanup() { rm -rf "$generated_root"; }
trap cleanup EXIT
PATH="/opt/homebrew/bin:$PATH" xcodegen generate \
  --spec "$PROJECT" --project "$generated_root" --project-root "$ROOT" --quiet \
  || fail "xcodegen could not render the iOS project"
generated_project="$generated_root/TronMobile.xcodeproj/project.pbxproj"
[[ -f "$generated_project" ]] || fail "xcodegen did not produce a project build-settings file"

# XcodeGen repeats inherited settings for generated configurations. Ensure
# every emitted orientation declaration has the exact source-owned value and
# that both device families are emitted at least once.
for pair in "$iphone_key|$iphone_value" "$ipad_key|$ipad_value"; do
  key="${pair%%|*}"
  value="${pair#*|}"
  key_count="$(grep -Fc "$key" "$generated_project")"
  value_count="$(grep -Fc "$value" "$generated_project")"
  [[ "$key_count" -gt 0 && "$key_count" == "$value_count" ]] \
    || fail "generated project orientation setting $key is missing or mismatched"
done

echo "iOS orientation source policy passed (project.yml and generated build settings are authoritative)"
