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
generated_root="$(mktemp -d "${TMPDIR:-/tmp}/tron-ios-project-policy.XXXXXX")"
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

# The gate reuses a journey pass across engine-only or Swift-app-test-only changes
# (tools/work/README.md#module-scoped-journeys), which holds only while those folders
# compile into exactly their own target.
/usr/bin/python3 - "$PROJECT" <<'PY' || fail "a module-scoped folder is compiled by another target"
import re, sys
owners = {"SwiftAppEngine": "TronSwiftAppEngine", "SwiftAppUITests": "TronSwiftAppUITests"}
text = open(sys.argv[1]).read().split("\nschemes:", 1)[0].split("\ntargets:", 1)[1]
targets = re.split(r"\n  (?=[A-Za-z])", text)
seen = {folder: [] for folder in owners}
for block in targets:
    name = block.split(":", 1)[0].strip()
    for path in re.findall(r"- path: (\S+)", block):
        for folder in owners:
            if folder == path or folder.startswith(path.rstrip("/") + "/") or path in (".", "./"):
                seen[folder].append(name)
bad = {folder: names for folder, names in seen.items() if names != [owners[folder]]}
if bad:
    sys.exit(f"module-scoped folders must belong only to their own target: {bad}")
PY

echo "iOS project policy passed (orientation, bundled resources and module-scoped targets)"
