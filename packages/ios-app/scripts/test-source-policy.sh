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
for sources in "$ROOT/Sources" "$ROOT/SwiftAppEngine"; do
  /usr/bin/python3 "$ROOT/scripts/presentation-source-policy.py" "$sources" \
    || fail "raw native sheet escaped its managed owner"
done

# Exercise the actual policy command: every native confirmation form is denied,
# even in the interpreter/managed-sheet owner; prose and shared adapters pass.
/usr/bin/python3 - "$ROOT/scripts/presentation-source-policy.py" "$generated_root" <<'PY'
import pathlib, shutil, subprocess, sys
policy, root = sys.argv[1], pathlib.Path(sys.argv[2]) / "confirmation-policy"
root.mkdir()
probes = [
    ("UI/Probe.swift", "view.alert (isPresented: $show) {}"),
    ("UI/Probe.swift", "view.confirmationDialog\n (title, isPresented: $show) {}"),
    ("UI/Probe.swift", "let value = Alert(title: Text(title))"),
    ("UI/Probe.swift", "view.actionSheet(isPresented: $show) {}"),
    ("UI/Probe.swift", "let value: ActionSheet?"),
    ("UI/Probe.swift", "let value = UIActionSheet()"),
    ("State/PresentationActivityCoordinator.swift", "let controller: UIAlertController?"),
    ("UI/SwiftApps/SwiftAppViews.swift", "let action = UIAlertAction(title: title)"),
]
cases = [({relative: source}, "shared Tron confirmation sheet") for relative, source in probes]
cases += [
    ({"State/PresentationActivityCoordinator.swift": "view.sheet (item: $route) {}",
      "UI/SwiftApps/SwiftAppViews.swift": "view.sheet(item: $route) {}",
      "UI/Probe.swift": '// .sheet(x)\nlet x = ".sheet(x)"\nswitch surface ?? .sheet { case .sheet: break }'}, None),
]
for source in ["view.sheet(item: $route) {}", "view.\n sheet\n(item: $route) {}", "view.fullScreenCover(isPresented: $flag) {}"]:
    cases.append(({"UI/Probe.swift": source}, "managed presentation owner"))
host = 'struct Host: View { var body: some View { x.tronManagedSheet(isPresented: $shown, identity: "a") { Draft() } } }'
cases += [
    ({"UI/A.swift": host, "UI/B.swift": 'struct Draft: View {\n @State private var text = ""\n var body: some View { EmptyView() } }'}, "UI/B.swift:2:"),
    ({"UI/A.swift": 'struct Host: View { var body: some View { TronProgressiveSheetLink(accessibilityLabel: "x") { Draft() } label: { EmptyView() } } }',
      "UI/B.swift": 'struct Draft: View {\n @PresentationState private var text = ""\n @State private var pulse = false // view-local: animation phase\n var body: some View { EmptyView() } }'}, None),
    ({"UI/A.swift": "struct Host: View { var body: some View { Row(destination: { Draft() }) } }",
      "UI/B.swift": "struct Draft: View {\n @State var a = 0\n var body: some View { EmptyView() } }\nstruct Elsewhere: View {\n @State var b = 0\n var body: some View { EmptyView() } }"}, "UI/B.swift:2:"),
    ({"Allowed.swift": '// .alert(x) Alert UIAlertController\n/* .confirmationDialog(x) UIAlertAction */\nlet explanation = ".alert(x) Alert UIAlertController UIAlertAction"\nview.tronConfirmation(title, isPresented: $show) { Button(title) {} }'}, None),
]
for sources, expected in cases:
    shutil.rmtree(root)
    root.mkdir()
    for relative, source in sources.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
    result = subprocess.run([sys.executable, policy, str(root)], capture_output=True, text=True)
    if expected:
        assert result.returncode == 1 and expected in result.stderr, (sources, result)
        assert len(result.stderr.splitlines()) == 1, result.stderr
    else:
        assert result.returncode == 0, result.stderr

PY

# Sheet loading is one shared, centered pulse (#890): no ad-hoc spinners or
# visible "Loading…" placeholders, and only the presentation surface hosts it.
/usr/bin/python3 "$ROOT/scripts/sheet-loading-source-policy.py" --self-test \
  || fail "sheet loading policy regressions failed"
for sources in "$ROOT/Sources" "$ROOT/SwiftAppEngine"; do
  /usr/bin/python3 "$ROOT/scripts/sheet-loading-source-policy.py" "$sources" \
    || fail "ad-hoc sheet loading UI escaped the shared pulse"
done

# TronMobileCore is the app's Foundation-only lowest module (docs/architecture.md#modules):
# UI frameworks belong to the app target, so Core must never import them.
core_ui_imports() {
  grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(SwiftUI|UIKit|Observation|UserNotifications)\b' "$1" --include='*.swift'
}
core_probe="$(mktemp -d)"
printf 'import Foundation\n@preconcurrency import UIKit\n' > "$core_probe/Probe.swift"
core_ui_imports "$core_probe" >/dev/null || { rm -rf "$core_probe"; fail "Core UI-import check no longer detects a UI import"; }
rm -rf "$core_probe"
! core_ui_imports "$ROOT/Core" || fail "TronMobileCore imports a UI framework"

echo "iOS source policy passed (orientation/resources, managed presentation, shared sheet loading and Foundation-only Core)"
