#!/usr/bin/env bash
# Source-level iOS project policy checks. Generated Info-plists are projections.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/project.yml"
INFO="$ROOT/Sources/Info.plist"
fail() { echo "iOS source policy: $*" >&2; exit 1; }
SOUND="$ROOT/Sources/Resources/Sounds/tron-notification.caf"
[[ -f "$PROJECT" && -f "$INFO" ]] || fail "missing project source"
[[ -f "$SOUND" && ! -L "$SOUND" && -s "$SOUND" ]] || fail "missing bundled notification sound"
[[ "$(grep -Fc 'Sources/Resources/Sounds/tron-notification.caf' "$PROJECT")" == 1 ]] \
  || fail "project.yml must bundle the notification sound exactly once"

# The application uses a checked-in Info.plist, so that plist—not generated
# INFOPLIST_KEY settings—must own the runtime orientation arrays.
! grep -Fq 'INFOPLIST_KEY_UISupportedInterfaceOrientations' "$PROJECT" \
  || fail "project.yml must not declare ineffective generated orientation keys"
/usr/bin/python3 - "$INFO" "$ROOT/ShareExtension/Info.plist" <<'PY' \
  || fail "source Info.plist orientation policy is invalid"
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    app = plistlib.load(source)
assert app.get("UISupportedInterfaceOrientations") == ["UIInterfaceOrientationPortrait"]
assert app.get("UISupportedInterfaceOrientations~ipad") == [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]
with open(sys.argv[2], "rb") as source:
    extension = plistlib.load(source)
assert not any(key.startswith("UISupportedInterfaceOrientations") for key in extension)
PY

# Render into a disposable directory and inspect the actual Xcode project. Do
# not leave generated projects in the working tree.
generated_root="$(mktemp -d "${TMPDIR:-/tmp}/tron-ios-source-policy.XXXXXX")"
cleanup() { rm -rf "$generated_root"; }
trap cleanup EXIT
"$ROOT/../../scripts/generate-xcode-project" ios \
  --spec "$PROJECT" --project "$generated_root" --project-root "$ROOT" --quiet \
  || fail "pinned XcodeGen could not render the iOS project"
generated_project="$generated_root/TronMobile.xcodeproj/project.pbxproj"
[[ -f "$generated_project" ]] || fail "xcodegen did not produce a project build-settings file"

! grep -Fq 'INFOPLIST_KEY_UISupportedInterfaceOrientations' "$generated_project" \
  || fail "generated project reintroduced competing orientation settings"
grep -Fq 'tron-notification.caf' "$generated_project" \
  || fail "generated project omitted the notification sound"

# Presentation activity is an ownership boundary. Raw SwiftUI sheets would
# bypass token registration and let covered work publish, so the only direct
# sheet calls must remain inside the managed modifier implementation.
/usr/bin/python3 "$ROOT/scripts/presentation-source-policy.py" --self-test \
  || fail "managed presentation policy regressions failed"
/usr/bin/python3 "$ROOT/scripts/presentation-source-policy.py" "$ROOT/Sources" \
  || fail "raw native sheet escaped its managed owner"

echo "iOS source policy passed (orientation/resources and managed presentation)"
