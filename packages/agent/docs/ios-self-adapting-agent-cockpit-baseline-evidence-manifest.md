# iOS Self-Adapting Agent Cockpit Baseline Evidence Manifest

Status: `complete`

Branch: `codex/ios-agent-cockpit-baseline-current`
Baseline: `6aa395fddf8ad8cca8f485c6a96fa0e78862e653`

## Evidence Summary

IOSAC-0 through IOSAC-10 are backed by Swift implementation changes, focused
Swift tests, Rust static invariants, README/iOS architecture updates, XcodeGen
project regeneration, simulator inspection, and final closeout commands.
This evidence records successor-readiness cockpit scope only; it does not add
the retired SAA authorship architecture or a successor capability
implementation.

## Focused Evidence

- IOSAC-1: `WorkerLifecycleClient` calls only existing engine functions:
  `catalog::watch_snapshot`, `resource::list`, `resource::inspect`, and
  `worker_lifecycle::*` lifecycle mutations.
- IOSAC-2: `AgentCockpitProjection` derives status, rows, package actions,
  activity, and confirmations from `CatalogWatchSnapshotDTO` and
  `EngineResourceDTO`/`EngineResourceInspectionDTO` values.
- IOSAC-3: destructive and state-changing lifecycle actions require an
  `AgentCockpitConfirmation`; disabled actions are ignored; successful
  mutations refresh from server state.
- IOSAC-4: the Surfaces tab lists active `ui_surface` resources, inspects
  current versions, decodes `UiSurfaceDTO`, and renders through the retained
  generated UI renderer with resource/version refs.
- IOSAC-5: `ChatView` owns the mounted cockpit view model, displays
  `AgentStatusCapsuleView`, and presents `AgentCockpitSheet` through the
  existing sheet coordinator.
- IOSAC-6: `TronColors` now defines neutral glass backgrounds and emerald primary
  accent tokens; `TronColorsTests` lock the light/dark values.
- IOSAC-7: focused Swift tests cover DTO decoding, RPC function IDs and
  payloads, projection state, dynamic surface inspection/decoding, generated UI
  renderer invariants, and theme tokens.
- IOSAC-8: `ios_self_adapting_agent_cockpit_baseline_invariants` is wired into
  local `scripts/tron ci test` and GitHub static gates.
- IOSAC-9: README and `packages/ios-app/docs/architecture.md` describe the
  cockpit as current behavior, not future plan language.
- IOSAC-10: the late live-cockpit server failure was traced to generic resource
  read primitives being hidden from engine-client actors. `resource::list` and
  `resource::inspect` are now system-visible pure reads, while
  `resource::create`, `resource::update`, `resource::link`, and
  `resource::register_type` remain outside normal client visibility.

## Failed Attempts and Fixes

- Initial cockpit surface rendering used a hardcoded placeholder
  `UiSurfaceDTO`. Fix: the cockpit now lists and inspects active `ui_surface`
  resources and renders decoded current versions.
- Initial `AgentCockpitViewModel.refresh` used `async let` against a
  main-actor repository existential. Swift 6 rejected the nonisolated send.
  Fix: refresh uses explicit sequential repository calls inside the main-actor
  method.
- Initial Xcode focused test run executed 0 XCTest-selected tests before Swift
  Testing discovered the suites. Fix: subsequent verification uses the Swift
  Testing suite output and names the focused suite totals in this manifest.
- Initial theme baseline retained warm cream backgrounds. Fix: `TronColors` now
  resolves to neutral glass backgrounds while preserving the emerald primary
  accent and separate semantic success/warning/error tokens; tests were updated
  to assert the current baseline.
- Initial live simulator cockpit refresh reached the shell but showed a server
  response failure when the cockpit tried to list generic resources. Fix:
  `resource::list` and `resource::inspect` now use a shared
  `resource_read_function` helper that marks only those pure reads
  `VisibilityScope::System`; a regression test proves a client can read
  resources without gaining write visibility.
- Simulator setup briefly used a local-only seed test to populate pairing state
  while Computer Use was unavailable. Fix: the temporary test was deleted,
  XcodeGen was regenerated, and the simulator token handoff file was removed
  from the app container before closeout.
- Computer Use remained unable to acquire the Simulator window in the final
  closeout run. `list_apps` showed Simulator running, but
  `get_app_state("Simulator")` returned `cgWindowNotFound` and a direct
  Computer Use click returned `noWindowsAvailable` after a Simulator quit,
  relaunch, iPhone 17 Pro boot, and Prod app launch. Fix: treat this as a
  Computer Use/Simulator bridge limitation rather than an app result; validation
  used simulator-native screenshot capture, full Swift tests, WebSocket/server
  probes, and source/static invariants. Native CGEvent tap attempts were also
  ignored by macOS, so no validation-only app hook was added.

## Command Evidence

Focused commands passed during implementation:

```bash
# WebSocket bearer tokens were never printed in command output.
cargo test --manifest-path packages/agent/Cargo.toml resource_read_primitives_are_visible_to_engine_client_without_write_access -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/WorkerLifecycleDTOTests -only-testing:TronMobileTests/WorkerLifecycleClientTests -only-testing:TronMobileTests/AgentCockpitStateTests -only-testing:TronMobileTests/AgentCockpitViewModelTests
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/WorkerLifecycleClientTests -only-testing:TronMobileTests/AgentCockpitViewModelTests -only-testing:TronMobileTests/AgentCockpitStateTests
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/TronColorsTests -only-testing:TronMobileTests/GeneratedUIRendererTests -only-testing:TronMobileTests/AgentCockpitViewModelTests
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/WorkerLifecycleDTOTests -only-testing:TronMobileTests/WorkerLifecycleClientTests -only-testing:TronMobileTests/AgentCockpitStateTests -only-testing:TronMobileTests/AgentCockpitViewModelTests -only-testing:TronMobileTests/GeneratedUIRendererTests -only-testing:TronMobileTests/TronColorsTests
xcodebuild build -scheme Tron -configuration Prod -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-ios-ui-derived-final
```

Final closeout commands:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants primitive_code_cleanup_inventory_covers_tracked_files -- --quiet
cd packages/ios-app && xcodegen generate
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```

## Simulator Evidence

Simulator validation is required for this slice because Swift/UI behavior
changed. The expected user-facing baseline to validate is:

- App launches and connects to the local server.
- The chat shell shows the agent status capsule above the message surface.
- Tapping the status capsule opens the Agent cockpit sheet.
- Workers, Packages, Activity, and Surfaces tabs are present.
- Empty states render without overlap when no worker lifecycle resources exist.
- When active `ui_surface` resources exist, the Surfaces tab renders them through
  `GeneratedRuntimeSurfaceView` rather than a fixed product panel.
- Closing the cockpit returns to the chat shell without disconnecting.

Observed simulator evidence on iPhone 17 Pro, iOS 26.5:

- `/tmp/tron-prod-sessions-after-clean-launch.png`: Prod app launches without
  onboarding after simulator pairing state is present and displays the connected
  Sessions surface.
- `/tmp/tron-chat-deeplink-cockpit-entry.png`: the chat route displays the new
  `AgentStatusCapsuleView` above the message surface with Idle status and the
  cockpit icon.
- `/tmp/tron-prod-chat-capsule-unambiguous.png`: after uninstalling the
  simulator Beta bundle, only the Prod bundle remains running during the
  attempted session deep link; iOS shows its "Open in Tron?" confirmation prompt.
- `/tmp/tron-prod-sessions-final-precloseout.png`: the prompt was cleared by a
  clean Prod relaunch and the app returned to the connected Sessions baseline.
- `/tmp/tron-prod-fresh-launch-after-reboot.png`: after hard Simulator restart,
  fresh Prod build, install, and launch, the app again displayed the connected
  Sessions surface with three sessions and no onboarding blocker.
- `/tmp/tron-validation/tron-simulator.png`: final closeout screenshot after
  Simulator relaunch and `xcrun simctl launch booted com.tron.mobile` showed
  the Prod app on the connected Sessions surface with the settings control, new
  session control, and three Workspace session rows visible.
- Computer Use final closeout evidence: `list_apps` showed Simulator running,
  but `get_app_state("Simulator")` returned `cgWindowNotFound` and a direct
  Computer Use click returned `noWindowsAvailable`. No final interactive
  Computer Use validation was claimed.
- Live `/engine` probe using the iOS frame shape (`type: "invoke"`) returned:
  `resource::list` `listOk=true`, no child error, zero active `ui_surface`
  resources; `resource::create` returned a child `policy_violation` whose
  message mentions visibility. This proves the cockpit read path works against
  the running server while writes remain hidden.

Because Computer Use could inspect but not interact after recovery, and `simctl`
does not expose tap injection, final screenshot validation proves launch,
pairing, connection, and session-list rendering. Earlier simulator screenshots
prove chat-level cockpit entry visibility. The cockpit sheet internals are
covered by focused Swift state/view-model tests, source invariants, generated
surface renderer tests, and the live `/engine` resource-read probe rather than
an interactive screenshot.
