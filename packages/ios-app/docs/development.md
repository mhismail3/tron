# iOS Development

## Setup

### Prerequisites

- Xcode 26 or newer
- Validated toolchains: Xcode 26.6 with the iOS 26.5 SDK; Xcode 27 beta with the iOS 27 SDK
- XcodeGen (`brew install xcodegen`)
- Tron server running locally

The project keeps `iOS: "26.0"` as its deployment target and
`xcodeVersion: "2640"` as its generated-project compatibility baseline. The same source and
production bundle therefore support iOS 26 and iOS 27; do not raise the
deployment target or create an iOS 27-only project. Select a locally installed
toolchain without changing the project:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -version
```

Physical-device builds honor the same selection when `DEVELOPER_DIR` is passed
to `scripts/tron-ios-device`.

Codex variant selection is owned by the repository's `tron-ios` skill:
simulator app-path work and hosted tests select `Tron Beta`; fast
physical-device iteration selects `Tron Fast` / `ProdDebug`; an install handed
to the user selects `Tron` / `Prod`. Physical Beta installs are exceptional and
require an explicit user request.

### Project Generation

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

`project.yml` is the authoritative project definition; regenerate after it or
tracked `Configuration/` changes. The generated `TronMobile.xcodeproj` remains
ignored by Git. Shared deployment, signing, Swift, and version settings live at
the project level, so all targets inherit one value. `scripts/tron version sync`
updates the project-level version mirror from `VERSION.env`.

### Icon Assets

`Sources/Assets.xcassets/TronLogoVector.imageset/tron-logo.svg` is the
authoritative logo source. The Bun/Sharp generator writes only the two app-icon
PNGs and the 100px README preview under `docs/assets/`:

```bash
cd packages/ios-app
bun install --frozen-lockfile
bun ../../scripts/generate-ios-icons.mjs
```

The app renders the vector asset directly; no raster logo image set is bundled.
Loose icon-layer PNGs under `Sources/Resources` are not part of the app resource
contract.

### Server Connection

The app connects to the Tron engine over `/engine`. Physical device testing
uses the Mac pairing QR code, which carries the Mac's trusted local or Tailscale
address, port, bearer token, and label. QR/deep-link paste and manual entry
accept only a bare DNS name, IPv4 address, or unbracketed IPv6 address; paste
`100.64.x.y` or `mac.tailnet.ts.net`, not `http://.../engine`. The iOS app
declares local-network use so iOS can prompt for permission when a direct
Mac/Tailscale connection needs it. Engine protocol envelopes are JSON WebSocket
text frames; the client accepts text or binary responses for diagnostics, but
outbound engine requests stay text so they match the server protocol.

If pairing times out before showing an authorization error, verify that
Tailscale is connected on both devices, accept the iOS local-network permission
prompt if it appears, and confirm the Mac can serve
`http://<tailscale-ip>:9847/health`.

The iOS engine transport logs redacted connection diagnostics under the
`[WebSocket]` category for each `/engine` upgrade: host/path, timeout budget,
Authorization header presence, URLSession task metrics, HTTP upgrade status
when available, and NSError domain/code/underlying details. Tokens and URL
queries are not logged. Frame and event diagnostics admit only route metadata
and encoded byte counts; their logging APIs have no raw-payload argument.
When physical-device pairing fails, copy the
`[WebSocket]` lines from Xcode first; they should identify whether the failure
is local-network permission, Tailscale reachability, HTTP auth, or engine
protocol response handling.

Transport lifecycle tests must cover replacement races, not only ordinary
disconnects. A receive, heartbeat, send, completion, or verification callback
from an old socket must be unable to retire the current generation; manual
retry must install exactly one reconnect owner. Chat lifecycle tests likewise
assert that leaving a mounted chat cancels presentation-owned work and releases
its display link while preserving reconstructable stream state. Run these
focused checks with the Beta simulator scheme:

```bash
xcodebuild test -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EnginePendingRequestLifecycleTests -only-testing:TronMobileTests/WebSocketRequestTransportTests -only-testing:TronMobileTests/EngineConnectionReconnectTests -only-testing:TronMobileTests/TronLoggerSensitiveDataTests -only-testing:TronMobileTests/StreamingManagerTypewriterTests -only-testing:TronMobileTests/ChatViewModelLifecycleTests
```

### Codex App Local Actions

The repository includes `.codex/environments/environment.toml` for Codex app
toolbar actions. `Dev Server` starts `scripts/tron dev -bdt` from the project
root, and `Stop Dev Server` runs `scripts/tron dev --stop`.
`Rebuild + Install + Launch iOS Beta Simulator` and `Just Launch Installed iOS
Beta Simulator` use `scripts/tron-ios-simulator`; Codex-owned simulator
app-path work therefore keeps the persistent Beta bundle and pairing container.
`Test Affected iOS Changes` uses a separate stable test DerivedData directory
and a source-controlled concern manifest. `Test Affected + Rebuild iOS Beta
Simulator` runs that validation before installing and launching the persistent
Beta app. Any unmapped iOS path, test change, project setting, or shared app
foundation falls back to the full suite; selectors are an iteration aid, never
the authoritative ready-PR merge boundary.
Physical-device actions use `scripts/tron-ios-device`, which regenerates the
Xcode project, preflights the active Xcode toolchain, and builds
`TronMobile.xcodeproj` directly from authoritative `project.yml`; arbitrary
local workspaces do not override that generated owner. It writes a full log
plus `.xcresult` bundle, installs through `xcrun devicectl`, and launches the
resolved bundle ID with a bounded `devicectl` launch timeout.
The `status` and `stop` commands match the full app executable while tolerating
the trailing column padding emitted by `devicectl` process tables.
When Xcode fails before compilation, the helper preserves project-level
diagnostics as well as file-and-line compiler errors. Signing failures such as a
missing Apple account or development certificate are therefore shown directly
in the action output; repair those in Xcode's Apple Accounts settings, then run
the same rebuild action again.
`Rebuild + Install + Launch iOS Prod Fast Debug on iPhone` uses the same helper
with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`,
`TRON_IOS_REQUIRED_SDK_MAJOR=27`, `TRON_IOS_SCHEME='Tron Fast'`, and
`TRON_IOS_CONFIGURATION=ProdDebug`. It therefore builds the fast
production-bundle app against the iOS 27 SDK and launches it on the selected
iPhone. The helper fails before compilation if that selected Xcode no longer
provides an iOS 27 SDK; it must never silently fall back to the system-selected
iOS 26 SDK because SDK-linked SwiftUI behavior, including scroll-edge effects,
would differ. The action prints both the Xcode version and selected iPhoneOS SDK
before compiling so its toolchain is visible in the action log.
`Rebuild + Install + Launch iOS Prod Release on iPhone` and the matching iPad
action use
`TRON_IOS_SCHEME=Tron` and
`TRON_IOS_CONFIGURATION=Prod`, so it builds the optimized production app,
installs the fresh product, and then launches it through the same helper.
After each build, the helper installs the requested configuration's `iphoneos`
product so stale Beta or Prod app bundles left in DerivedData cannot be launched
by a different action.
Production rebuild actions use the helper's sole rebuild command, `install`, so
local source changes are compiled before the app is reinstalled.
The matching physical `Just Launch Installed ...` actions run
`scripts/tron-ios-device launch` without rebuilding. Prod Fast Debug and Prod
Release are deduplicated by bundle ID: one production launch action per device
opens whichever `com.tron.mobile` binary is currently installed.

### Native Notification Validation

The tracked Beta and production entitlement files declare their intended APNs
environment, and the app declares the `remote-notification` background mode.
Beta uses topic `com.tron.mobile.beta` with APNs sandbox; an App Store-exported
Prod build uses `com.tron.mobile` with APNs production. The physical-device
helper explicitly signs local Prod and ProdDebug installs for APNs development
and embeds the matching `sandbox` registration route. This lets the
production-bundle app receive notifications during device testing without
misrouting its sandbox token to the production provider. It is still not
production APNs acceptance; use TestFlight or an App Store export for that
path. The relay accepts only the beta/sandbox, local-Prod/sandbox, and
distributed-Prod/production routes. Every paired engine selects exactly one
provider path. Development engines normally use the Cloudflare relay:

```bash
scripts/tron auth notifications configure-relay \
  --url https://relay.example \
  --secret-file /secure/path/relay-secret
scripts/tron auth notifications use relay
scripts/tron auth notifications status
```

Direct mode is explicit and requires local Apple signing credentials:

```bash
scripts/tron auth apns configure \
  --team-id TEAM_ID \
  --key-id KEY_ID \
  --private-key-file /secure/path/AuthKey.p8
scripts/tron auth apns status
scripts/tron auth notifications use direct
```

Never put a relay secret, `.p8`, APNs token, or physical device id in the
repository or a test fixture. Status commands report only mode and readiness.
The engine never fails over between relay and direct automatically.

Notification foundation changes use the Beta simulator and must cover legacy
cache migration, concurrent actor serialization, batched Mark All Read
durability, pending-response replay over an authoritative sync page, per-server
work coalescing, request/work budgets, and shutdown draining:

```bash
xcodebuild test -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/NotificationLocalStoreTests -only-testing:TronMobileTests/NativeNotificationPolicyTests -only-testing:TronMobileTests/DependencyContainerTests
```

Artifact delivery changes also use the Beta simulator. The focused suite covers
closed protocol decoding and routing, exact-content hash verification, bounded
temporary-file lifecycle, explicit deletion, and the explicit draft-attachment
bridge:

```bash
xcodebuild test -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ArtifactInboxViewModelTests -only-testing:TronMobileTests/WorkerKernelDTOTests -only-testing:TronMobileTests/WorkerKernelClientTests
```

For physical production-notification acceptance:

1. Start the development server and install the current Prod build through
   TestFlight or an App Store export. A locally development-signed Prod build is
   not production APNs acceptance.
2. Pair successfully, accept notification permission, tap the Settings toolbar
   bell, and confirm Notifications separately reports permission, device/token
   readiness, selected transport, and provider readiness.
3. Create a natural-language one-time reminder and background, then terminate,
   the app. Confirm exactly one notification arrives on every active
   installation.
4. Exercise tap/Open, Snooze, and Complete. Confirm inbox/read/badge state
   reconciles on a second device and after reconnect.
5. Verify recurrence, bounded follow-ups, restart catch-up, offline response
   retry, inactive paired-server registration, and deep-link server switching.
6. Repeat with denied permission, cleared selected-transport credentials,
   server downtime, relay timeout, scheduler/policy outage, and an invalidated
   token. The reminder run must remain successful while Engine Activity shows
   sanitized blocked/retry/permanent evidence and no duplicate logical
   notification.

APNs HTTP success proves provider acceptance only. Product copy, tests, and
diagnostics must say `accepted_by_apns`, never delivered.

Keep device-specific values out of the repo. The Codex app actions use generic
`TRON_IOS_DEVICE_NAME=iPhone` and `TRON_IOS_DEVICE_NAME=iPad` selectors. For
manual terminal use, the helper auto-selects the only selectable physical iOS
device, where selectable means CoreDevice reports it as `available` or
`connected`. If multiple devices are selectable, set one of these before running
it:

```bash
export TRON_IOS_DEVICE_ID=<device-identifier>
# or
export TRON_IOS_DEVICE_NAME=<device-name>
```

The helper also accepts `TRON_IOS_SCHEME` and `TRON_IOS_CONFIGURATION` for local
variants. Defaults remain `Tron Beta` and `Beta`; the fast production action sets
them to `Tron Fast` and `ProdDebug`. `TRON_IOS_REQUIRED_SDK_MAJOR` is an optional
preflight for SDK-sensitive workflows; the Codex Prod Fast action sets it to
`27` and explicitly selects Xcode beta.

## Build Configurations

| Config | Scheme | Use Case |
|--------|--------|----------|
| Beta | Tron Beta | Development (debug, beta bundle ID) |
| ProdDebug | Tron Fast | Local production-app iteration (debug, production bundle ID) |
| Prod | Tron | App Store/TestFlight (release, production bundle ID) |
| Test | Every test action | Hosted unit/UI validation (debug, isolated test identities) |

`Debug.xcconfig` owns the compiler and test settings shared by Beta, ProdDebug,
and Test; each leaf configuration owns its compilation conditions, product
identity, and APNs route. `Base.xcconfig` remains common to every configuration.

Use `Tron Fast` when you want Xcode's debug-speed rebuilds to install over the
production app (`com.tron.mobile`) instead of the side-by-side beta app. It uses
the production app icon and production bundle IDs, but uses development APNs
signing/sandbox delivery and keeps `-Onone`, `ENABLE_TESTABILITY=YES`, and
`ONLY_ACTIVE_ARCH=YES` like the beta debug build.

### Persistent Paired Simulator

Use `scripts/tron-ios-simulator` for local app-path testing. The helper remembers
one simulator UUID in `~/.tron/internal/run/ios-simulator-udid`, always uses the
`Tron Beta` bundle, and installs over the existing app without uninstalling or
erasing its data container:

```bash
# Select the current Simulator device once and retain its pairing.
scripts/tron-ios-simulator remember

# Later launches reuse that exact simulator and paired app container.
scripts/tron-ios-simulator start

# Rebuild only when iOS code changed; pairing remains intact.
scripts/tron-ios-simulator install
```

Pairing is scoped to both the simulator UUID and bundle ID. Avoid name-only
destinations when multiple iOS runtimes contain an identically named device,
and do not uninstall, erase, or switch to the production bundle for simulator
testing. Hosted unit and UI-validation test actions use the separate
`com.tron.mobile.testhost` identity, so they cannot replace the paired Beta or
production app. The `start` and `status` actions also verify the installed code
identifier as a fail-closed defense: if an older or manual XCTest invocation
left a linker-signed host at the Beta identity, `start` directs you to `install`,
which restores normal Keychain access without erasing the pairing. Run hosted
tests only on the disposable simulator described below. When the remembered
device is shut down, `status` reports validation as unavailable instead of
misclassifying the preserved app as absent; `start` boots and validates it.

## Running Tests

### Command Line

```bash
xcodebuild test \
  -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Hosted Unit-Test Isolation

Hosted `TronMobileTests` are allowed to create only declared, task-owned
defaults suites, fixture roots, visual artifacts, DerivedData, and result
bundles, all with registered cleanup. The supported isolation claim is that the
hosted suite neither reads nor writes pre-existing user durable state and opens
no real network session. It is not a claim of zero filesystem activity or raw
whole-simulator byte equality. Production and separate UI-test behavior remain
unchanged.

Every hosted `DependencyContainer` must come from `IsolatedTestState`. Its
immutable runtime-I/O configuration uses a handled-attempt recorder for direct,
retry, reconnect, and rebuilt-client paths, a test-target inert pairing probe,
and a task-owned in-memory `PairedServerTokenStore.Backend`. Do not construct a
live session, `URLSessionPairingProbe`, the production token backend, or an
OAuth owner in a hosted unit-test path.

Named-suite cleanup is semantic and test-only. `IsolatedTestState` emits a
versioned registration record before exposure, removes the exact persistent
domain during cleanup, proves that the domain is nil or an empty dictionary,
and emits one matching cleanup record. Repeated and process-exit cleanup use
the same idempotent owner and cannot duplicate the cleanup event. Tests must
not discover, unlink, or synchronize CoreSimulator preference backing files;
`cfprefsd` may materialize an empty plist after the process exits.
Token identities use a separate, complete
`TRON_TEST_KEYCHAIN_LIFECYCLE_V1` ledger. Parse it independently from defaults
records; registration and cleanup must be unique and set-equal by namespace,
service, and account, and lifecycle JSON must never contain token material.
Cleanup order is manager shutdown, token clear/proof/ledger emission, database
close, fixture-root removal, defaults cleanup, then process-exit
deregistration. Repeated cleanup must await the same drain and emit no duplicate
record.

Hosted logical-time tests use a cancellation-cooperative `MockAsyncClock`.
Manual sleepers and deterministic registration waiters have stable identities;
cancellation, logical advance, and teardown atomically select one continuation
owner, and every continuation resumes outside the clock lock. Terminal service
owners must cancel and await their accepted tasks. Tests must await genuine
clock registration before shutdown and must not use real-time sleeps, polling,
or post-shutdown clock advancement to unblock canceled work.

Isolation validation must not use the persistent paired simulator above. Create
a new simulator for the task, record the UDID returned by `simctl create`, and
use `-destination id=<task-udid>` and that literal UDID for every subsequent
operation—never a device name or `booted`. Keep DerivedData, result bundles,
HOME/TMPDIR where supported, and all fixture/artifact roots under the task's
private evidence directory. Register the device as a task-owned process and
delete that exact UDID after all checks.

Before the full hosted suite, seed adversarial app defaults, Documents/SQLite,
Application Support, App Group, and production-pairing sentinels, start a
loopback connection recorder for that seeded pairing, and capture these
separate baselines:

1. Run the focused `AppDelegateTests` through the dedicated hosted-test app.
   Its app, extension, and test-bundle identifiers are distinct from both Beta
   and production identities; the app and extension carry none of the Beta or
   production entitlement files. Require the hosted callbacks to leave every
   injected lifecycle effect at zero and the
   application callbacks to preserve their live semantics.
2. Read only sorted TCC rows for the exact built app and extension bundle IDs,
   comparing service, client, client type, authorization value, and reason.
3. Hash and semantically decode the App Group canary; inventory the seeded
   defaults, database, and durable trees.

Run focused lifecycle, storage, cleanup, transport, guard, and hosted-render
tests before all `TronMobileTests`. Then capture the scoped TCC, App Group,
defaults, database, durable-tree, registered-scope, and recorder post-state.
Require identical protected records and zero recorder accepts/bytes. Ambient
simulator notification authorization is not an isolation oracle because the
test process does not own it. Do not launch a normal or UI-test app until these
post-snapshots pass. Only then may a normal Beta launch/background-to-active
negative require a recorder accept, followed by the separate onboarding
UI-validation cases. Terminate owned processes and verify deletion of the exact
task UDID at the end.

For every hosted invocation, parse only complete
`TRON_TEST_SUITE_LIFECYCLE_V1` records. Registration and cleanup identities
must each be unique and set-equal. A residual preference artifact is permitted
only when `lstat` proves it is a regular non-symlink plist directly under the
current task app container's `Library/Preferences`, its stem matches an owned
suite grammar and a cumulative registration, and its plist root is an empty
dictionary. Unknown, unregistered, malformed, nonempty, duplicate, misplaced,
directory, or symlink artifacts fail the run; only accepted empty envelopes
are excluded from durable-tree comparison.

For chat response rails and final-response metadata projection, run only the
payload, dispatch, lifecycle, reconstruction, and presentation contracts:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/AssistantMessagePayloadTests \
  -only-testing:TronMobileTests/AgentResponseCompletePluginTests \
  -only-testing:TronMobileTests/TurnEndPluginTests \
  -only-testing:TronMobileTests/EventPluginTests \
  -only-testing:TronMobileTests/EventRegistryDispatchTests \
  -only-testing:TronMobileTests/ChatViewModelEventRoutingTests \
  -only-testing:TronMobileTests/TurnLifecycleCoordinatorTests \
  -only-testing:TronMobileTests/TextStreamConvergenceTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerTokenMetadataTests \
  -only-testing:TronMobileTests/ChatMessagePresentationTests \
  -only-testing:TronMobileTests/ToolInvocationGroupingTests \
  -only-testing:TronMobileTests/EventDatabaseTests/testEnrichedAssistantMessageMetadata

xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/ChatAffordanceVisualRenderTests

```

The chat-affordance render retains its PNGs in the result bundle, including the
cached-history composer and shared sheet-loading typography fixtures, so local
and CI reviewers can export the exact successful-test images with
`xcresulttool export attachments`.

For the interactive prompt-composer glass and voice-lifecycle action ownership,
run the focused presentation/source contracts and visual render:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/ComposerVoiceStateTests \
  -only-testing:TronMobileTests/InputBarKeyboardTraversalTests

xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/ChatAffordanceVisualRenderTests

```

For the workspace selector's shared shortcut/action capsule geometry, run its
focused source contract and visual render:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/NewSessionFlowTests/testWorkspaceSelectorActionsShareTheShortcutPillPresentation \
  -only-testing:TronMobileTests/WorkspaceSelectorVisualRenderTests/testWorkspaceSelectorNavigationHierarchyRendersForVisualQA
```

For dashboard session-list loading and per-workspace disclosure changes, run:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionListPageLoaderTests \
  -only-testing:TronMobileTests/SessionRepositoryTests \
  -only-testing:TronMobileTests/SessionListPresentationTests \
  -only-testing:TronMobileTests/SessionListExpansionAccessibilityTests
```

For Worker Console protocol, repository, declarative presentation, state, or
Settings parity changes, run the focused worker-first set on Beta:

```bash
xcodebuild test -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/WorkerKernelDTOTests \
  -only-testing:TronMobileTests/WorkerKernelClientTests \
  -only-testing:TronMobileTests/WorkerConsolePresentationTests \
  -only-testing:TronMobileTests/WorkerConsoleViewModelTests \
  -only-testing:TronMobileTests/WorkerConsoleVisualContractTests \
  -only-testing:TronMobileTests/SettingsParityTests
```

For Session Context, worker protocol layout, invocation presentation,
notification ownership helpers, or connection-policy moves, run this
state-owner suite on Beta with parallel testing disabled so one hosted process
owns teardown:

```bash
xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:TronMobileTests/SessionContextPresentationTests \
  -only-testing:TronMobileTests/SessionContextAuditDecodingTests \
  -only-testing:TronMobileTests/WorkerKernelDTOTests \
  -only-testing:TronMobileTests/WorkerConsoleInteractionTests \
  -only-testing:TronMobileTests/ToolInvocationDetailViewTests \
  -only-testing:TronMobileTests/NativeNotificationPolicyTests \
  -only-testing:TronMobileTests/EngineClientTests \
  -only-testing:TronMobileTests/EngineConnectionReconnectTests
```

For the main Settings destination copy or the Engine/Providers sheet hierarchy,
run the focused ownership and no-summary-hero contracts:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/EngineSettingsOwnershipTests \
  -only-testing:TronMobileTests/EngineSettingsPageLayoutTests/testEngineAndProvidersSheetsDoNotMountSummaryHeroes \
  -only-testing:TronMobileTests/EngineSettingsPageLayoutTests/testNotificationAndLogsUseTheirOwnedSettingsEntryPoints \
  -only-testing:TronMobileTests/EngineSettingsPageLayoutTests/testNotificationSheetsUseStandardCardsToolbarsAndMediumDetents
```

For settings, pairing, event decoding, error projection, and generic runtime
rendering changes, use this focused iOS 26.5 simulator set:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/ServerSettingsTests

xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/SettingsParityTests \
  -only-testing:TronMobileTests/PairingValidationTests \
  -only-testing:TronMobileTests/PairingURLParserTests \
  -only-testing:TronMobileTests/SessionEventTypeTests \
  -only-testing:TronMobileTests/ErrorEventProjectionTests \
  -only-testing:TronMobileTests/ToolInvocationDisplayModelTests \
  -only-testing:TronMobileTests/WorkerConsoleVisualContractTests
```

### Simulator Deep-Link Smoke Test

`Info.plist` registers the `tron` and `tron-mobile` URL schemes;
`DeepLinkRouter` owns the routes they accept:

- `tron://session/<session-id>`
- `tron://session/<session-id>?tool=<invocation-id>`
- `tron://session/<session-id>?event=<event-id>`
- `tron://settings`
- `tron://share`

The same routes work with the `tron-mobile` scheme. Boot the target simulator,
then build and install the current beta app before testing; unit tests do not
update an installed simulator app.

```bash
xcrun simctl bootstatus booted

cd packages/ios-app
xcodebuild -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/tron-ios-beta-derived \
  build

xcrun simctl terminate booted com.tron.mobile.beta || true
xcrun simctl install booted \
  /tmp/tron-ios-beta-derived/Build/Products/Beta-iphonesimulator/TronMobile.app
xcrun simctl launch booted com.tron.mobile.beta
xcrun simctl openurl booted "tron://session/<session-id>"
```

A nonzero `simctl openurl` status fails this navigation smoke test. Engine
session correctness and persistence belong to their server-owned tests, not to
simulator screenshots or this developer workflow.

### Xcode

1. Open `TronMobile.xcodeproj`
2. Select Tron scheme
3. Cmd+U to run tests

### Test Structure

```
Tests/
├── Engine/            # Transport, protocol, event, persistence, and model tests
│   └── Transport/     # Clients, Retry, WebSocket, and DeepLinks tests mirror Sources
├── Session/           # Chat, timeline, attachment, and parsing tests
│   ├── Chat/          # Coordinators, Messaging, Navigation, State, ViewModel owner roots
│   └── WorkerKernel/  # Worker state and repository fixtures
├── UI/                # Feature presentation and source-ownership contracts
│   └── EngineInspection/ # Session Context and Worker Console contracts
├── Support/           # Composition, diagnostics, foundation, pairing, and storage tests
└── Infrastructure/    # Fakes, fixtures, SourceGuard, cleanup, and project-structure guards
```

After moving Swift sources, regenerate `TronMobile.xcodeproj` from
`project.yml` before building. Source-ownership guards follow the feature
directories recursively; do not preserve an obsolete path solely to satisfy a
test, and do not add the same Swift file to more than one build phase.

Active hierarchy and targeted hard-budget enforcement live in
`SourceGuardTests` and do not depend on point-in-time campaign line counts.

## Debugging

### Console Logging

```swift
TronLogger.shared.debug("Message", category: .network)
TronLogger.shared.error("Error: \(error)", category: .session)
```

Categories: `.network`, `.session`, `.events`, `.notification`, `.database`

### Network Inspector

View WebSocket traffic:
1. Run in Beta
2. Check Xcode console for `[Network]` logs
3. Or use Proxyman/Charles for detailed inspection

### Event Debugging

```swift
// In ChatViewModel
eventPublisherV2.sink { event in
    print("Event: \(event.type) - \(event.sessionId ?? "nil")")
}
```

### Local Diagnostics

Tron does not send usage analytics. `MetricKitDiagnosticsStore` subscribes to
Apple MetricKit in `AppDelegate` and stores payload JSON under Application
Support with 30-day / 50-file / 10 MB retention. Settings -> Send Feedback
builds a redacted `tron-diagnostics-<timestamp>.json` attachment that includes
bounded iOS logs, `logs::recent(limit: 1000)` when connected, local session and
event summaries, and MetricKit payloads.

When the app is connected to a paired server,
`ClientLogIngestionService` automatically mirrors the bounded, redacted
`TronLogger` buffer into the server `logs` table through `logs::ingest`.
The upload redacts messages again at the send boundary; the server then applies
its bearer/API/OAuth redactor before durable `logs` storage. Uploads track entry
fingerprints for the active server endpoint, attach the active session id to
each batch, use deterministic session-scoped batch idempotency, and still rely
on the server's client-log dedupe index as durable truth. Endpoint or active
session changes cancel stale duplicate suppression, and repeated
reconnects or foreground transitions do not resend unchanged local buffers or
create duplicate DB rows. Successful `logs::ingest` transport/debug plumbing is
filtered before upload so automatic syncing cannot create a self-feeding log
loop; failed ingestion and reconnect warnings are retained. The Logs sheet
remains production-available for local inspection and copying; it is not the
source of durable log truth.

Mail delivery uses the `TRON_FEEDBACK_EMAIL` build setting and opens the native
Mail composer with the support recipient, subject, body, and JSON attachment
filled in. The tracked default in `Configuration/Base.xcconfig` is blank;
maintainer or release builds can supply it through `Configuration/Local.xcconfig`,
CI secrets, or other runtime build settings without changing source control. The
body names the attachment and describes the actual included log time range when
parseable timestamps are available. If Mail is not configured, or the recipient
config is missing, Settings shows an alert instead of a share sheet because iOS
public APIs do not reliably attach files through a default-mail-app handoff.
Release builds must keep
`DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`; App Store/TestFlight crashes are
retrieved through Apple's Xcode Organizer diagnostics path.

## Deterministic CI toolchain

`config/ci-toolchain.env` is the repository-owned Apple/release tool manifest.
Hosted compatibility CI selects stable Xcode 26.3, iOS 26.2, and iPhone 17 Pro.
The isolated TestFlight runner separately pins Xcode 27.0 beta 3 build
`27A5218g`, the iOS 27.0 SDK, and a 26.0 deployment floor. Apple's
[App Store Connect release notes](https://developer.apple.com/help/app-store-connect/release-notes/)
list that beta/SDK pair for internal and external TestFlight submission; recheck
that source whenever rotating the beta. Both paths download exact XcodeGen,
create-dmg, App Store Connect CLI, GitHub runner, and CI-definition parser
releases whose SHA-256 values are checked before execution. The manifest also
owns the advisory shadow's digest-pinned Rust image and the digest-pinned
actionlint image exercised by both providers.
Workflows must not select `latest`, install these tools through Homebrew, or
maintain a second version list.

The installer writes only to an isolated runner directory and appends its bin
directory to `GITHUB_PATH`:

```bash
scripts/install-ci-tools.sh xcodegen
scripts/verify-ci-toolchain.sh ios xcodegen
scripts/validate-ci-definitions.sh
```

The tool installer, manifest verifier, CI-definition validator, and measured
iOS build/test driver emit UTC structured events into the provider-owned job
log. They identify cache hits versus verified downloads, checksum and manifest
provenance, prefix rebuilds, each validated definition/target, phase start/end,
exit status, duration, and the final metrics SHA-256. URLs with credentials,
environment dumps, and command tracing are excluded. GitHub retains those logs;
the iOS lane additionally uploads the matching metrics JSON on every run and
the `.xcresult` on failure. A change to either `scripts/ios-*` or
`scripts/bootstrap-ios-*` is classified as iOS work so these contracts cannot
skip their owning validation lane.

The Mac lane adds `create-dmg`; the iOS release lane adds `asc` and runs
`scripts/ios-release-runner-doctor.sh` before touching credentials. Pull-request
path classification is owned by `scripts/ci-change-flags.sh`, including its
offline self-test. Draft PRs receive lightweight feedback; ready PRs run the
complete Rust, iOS, and Mac matrix. The iOS lane separates
`build-for-testing` from `test-without-building`, uses explicit DerivedData,
and uploads `tron.ios-ci-metrics.v1` timing/count/toolchain evidence on every
run plus the full `.xcresult` only on failure. A successful ready-PR run also
publishes `tron.validation.v2` evidence for its exact merge tree, complete
required-job set, CI policy, pipeline configuration, toolchain, sanitized iOS
metrics, and artifact manifest. Historical v1 evidence remains readable. Main
never reuses v1: current reuse and parity require v2. Main reuses v2 work only
after checking the associated PR, successful run,
artifact SHA-256, schema, policy/toolchain digest, and tree; every verification
failure runs the full matrix.

An opt-in Buildkite pipeline may run the same iOS lane on a hosted M4 queue
pinned to the manifest's Xcode 26.3 and iOS 26.2 runtime. It is shadow evidence
only: GitHub's `CI summary` remains authoritative, and Buildkite has no
TestFlight environment, signing material, or access to the isolated release
runner. Provider-side activation and queue confinement are documented in the
[Buildkite shadow runbook](../../../.buildkite/README.md). One shadow
source-context job pins GitHub's synthetic merge commit;
every workload then verifies the distributed commit, tree, and parents. Use
`scripts/ci-parity-report.py` to compare v2 evidence with the GitHub run; it
requires the extracted artifact directory from each provider, stream-verifies
every evidence-manifested file, and semantically binds both context and metrics
payloads plus all six Buildkite job manifests and bootstrap records. Nested
job-manifest command-log/DMG entries are structure-checked but not dereferenced
because they are not copied into shadow evidence. SDK, toolchain, source, job,
enumeration, worker-count, or test-result drift fails the comparison. This
offline report does not authenticate provider artifact IDs, nested payloads,
run conclusions, or custody; those remain provider-API evidence.
The provider-neutral policy pins the live ASC app ID, production app and share
extension bundle IDs, `Tron` scheme, and `Prod` configuration; a future
provider's delivery measurements must match that exact product identity.

The scheduled performance workflow is advisory and uploads raw benchmark
evidence; cache or parallel-test changes remain advisory until repeated runs
prove identical test sets, isolation, and a material p95 improvement.
Test enumeration is intentionally confined to that experiment because a cold
hosted enumeration can add minutes without increasing authoritative coverage.

XcodeGen requires both its executable and version-matched `SettingPresets`
data. The checksum installer links both into its isolated tool root, and the
verifier rejects an executable-only installation before project generation;
without those presets, XcodeGen can appear healthy while emitting empty Apple
product settings.

Historical-session changes use the Beta simulator and the focused deterministic
tests below. Local timing evidence is emitted as `[SESSION_LOAD]` log entries
and OS signposts without message content or identifiers:

```bash
cd packages/ios-app
xcodegen generate
xcodebuild test -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionLoadDiagnosticsTests \
  -only-testing:TronMobileTests/ChatViewModelCachedTranscriptTests \
  -only-testing:TronMobileTests/ChatTranscriptRevealPolicyTests
```

### Dedicated iOS release runner

TestFlight archives run on the repository-scoped labels
`self-hosted`, `macOS`, `ARM64`, and `tron-ios-release`. This public repository
must never route pull-request or fork-authored code to that runner. The release
workflow accepts only an exact successful `main` CI SHA, a release tag reachable
from `main`, or a manual run whose live source is the exact current `main` head.
Manual dry-runs retain the less restrictive `main`-reachability check. The
protected `ios-testflight` environment
and the one-job dedicated runner provide the remaining release boundary. The
complete automatic intent/effect/receipt transaction is serialized, without
cancellation, by authoritative upstream CI run ID. Reruns of one upstream run
therefore cannot race each other, while different main commits retain distinct
concurrency keys. A small hosted job with no signing or App Store secrets admits
an automatic run only when its successful CI source is still the exact current
`origin/main` head. The release checkout repeats that equality check after the
dedicated runner queue and again immediately before the first App Store Connect
delivery. Direct live runs repeat their own source check immediately before ASC:
manual delivery requires equality with current `main`, while a release tag must
remain an ancestor of current `main`. Each direct GitHub run ID is its immutable
transaction key.

For every automatic workflow-run attempt, including failed and stale upstream
attempts, the hosted gate retains an attempt-unique 90-day
`tron.ios-release-eligibility.v1` artifact containing the upstream CI identity,
source/outcome, freshly observed main SHA, decision, downstream producer, and
UTC observation time. An eligible attempt reconstructs the authenticated
artifact history and emits `tron.ios-release-intent.v1` as `new`, `resume`, or
`completed`. A completed intent does not reserve the protected runner. Tag and
manual live attempts similarly reconstruct a run-ID-scoped
`tron.ios-release-direct-intent.v1` history. Their separate direct schemas keep
the existing automatic v1 contract unchanged.

The runner lives on a separate hidden standard macOS account named `tron-ci`.
Its home, keychain baseline, Actions checkout, DerivedData, and signing material
are isolated from interactive development and from every normal Tron data home.
Create the `ios-testflight` GitHub environment first with only the `main` branch
and `server-v*` tags admitted; the bootstrap verifies that the environment
exists before it requests a short-lived runner registration token.
The checked-in bootstrap downloads the checksum-pinned ARM64 Actions runner,
removes any accidental admin membership, constrains the service home to mode
0700, verifies it cannot read the invoking user's home, installs a root-owned
Background agent definition at
`/Library/Application Support/Tron/ReleaseRunner/com.tron.ios-release-runner.plist`
with updates disabled, and disables AC sleep. Keeping the definition outside
`/Library/LaunchAgents` prevents launchd from discovering it for other users;
the boot helper explicitly loads it only into `tron-ci`'s `user/<uid>` domain.
The agent has no `UserName` or `GroupName` and inherits that domain's identity.
A root-owned
`/Library/Application Support/Tron/ReleaseRunner/start-runner` entry point
checks the listener's effective UID, Background manager, Security session, and
audit UID before it executes the runner-owned `runsvc.sh`; an invalid listener
therefore remains offline and cannot receive a GitHub job.
A separate root-owned, one-shot
LaunchDaemon at
`/Library/LaunchDaemons/com.tron.ios-release-runner-bootstrap.plist` creates
that user domain at boot and loads the agent through
`/Library/Application Support/Tron/ReleaseRunner/bootstrap-user-agent`. The
helper retries after failure, but the long-lived runner itself never enters the
system domain:

```bash
scripts/bootstrap-ios-release-runner.sh
scripts/ios-release-runner-doctor.sh
```

The bootstrap and both launchd boundaries emit timestamped, single-line,
secret-safe operational records. The interactive transaction writes a unique
`trace`, the exact checkout commit/dirty bit, and SHA-256 provenance for the
bootstrap, toolchain manifest, and iOS release workflow to the root-only
`/Library/Logs/Tron/ios-release-runner-bootstrap.log`. The boot helper's stdout
and stderr are retained separately at
`/Library/Logs/Tron/ios-release-runner-launchd.log` and
`/Library/Logs/Tron/ios-release-runner-launchd-error.log`; the directory is
root-owned mode 0755 and every file is root-owned mode 0600. The immutable
listener guard records only its PID, effective/audit UIDs, launchd manager,
Security-session root flag, and validation outcome in the existing private
`/Users/tron-ci/Library/Logs/com.tron.ios-release-runner/` streams. It never
logs a command line, process environment, GitHub token, keychain value,
signing identity, profile contents, or runner credential file. Do not enable
shell tracing on a release script.

An otherwise-unhandled bootstrap command failure records its named phase,
source line, and exit status before transactional cleanup. It deliberately does
not record `BASH_COMMAND` or arguments because account passwords, runner tokens,
and signing material can cross those command boundaries.

Every doctor run adds the same sanitized identity document, exact Xcode/SDK,
capacity, filesystem-boundary result, source SHA, and credential-audit mode to
the durable GitHub Actions job log. To correlate host, GitHub, and recent
workflow state after any failure, run the read-only collector:

```bash
scripts/ios-release-runner-diagnostics.sh
```

It continues collecting after an unhealthy check and exits nonzero at the end.
The output contains fixed installed-file metadata and hashes, rollback-journal
presence, filtered launchd state, the exact listener process and Unix UID,
remote runner state, and the three most recent main CI and iOS release run
records. It tails only the root-owned Tron logs and
`component=ios-release-runner-session` guard lines; raw Actions `_diag` logs,
job output, credentials, keychains, environments, and signing state are
deliberately excluded. This is the first evidence bundle to capture before
manually changing launchd state.

Bootstrap-only preparation commands enter the hidden account's launchd context
in a strict order. Root first invokes `launchctl asuser`, which adopts the
target bootstrap and security audit session but does not change Unix
credentials; the boundary then immediately drops UID/GID to `tron-ci` before
executing the requested command. Dropping privileges before `asuser` is invalid:
the non-root process cannot adopt the separate Background audit session and
macOS rejects it with `EPERM`. Every call verifies the resulting manager UID,
manager type, effective UID, and audit UID before keychain state is prepared.
The agent deliberately omits `SessionCreate`: the independent `user/<uid>`
Background domain already owns the correct non-root audit session, while asking
launchd to create another session gives the listener a different audit login
identity. The root-owned session entry point is the launchd program itself: it
checks its own effective UID, manager UID/type, Security session, audit UID,
home, and immutable file metadata before it can execute `runsvc.sh`. Repair
therefore requires a different exact listener PID and the same GitHub runner
ID to return online before restoring its scheduling label. It deliberately
does not use `launchctl bsexec` as a second identity check; on current macOS,
that command can preserve the verifier's audit identity instead of reporting
the target process's identity. The pre-exec guard and job-time doctor inspect
their own real contexts and remain the two fail-closed enforcement boundaries.

Every Actions job reruns the doctor before any step receives release secrets.
It rejects a mislabeled runner unless the process is the non-admin `tron-ci`
account with its exact home, mode-0700 ownership, baseline keychain, checkout,
and temporary directory all inside the isolated Actions installation. It also
requires launchd's manager UID and the Security framework audit UID to equal
the account's effective UID, requires the manager session type to be
`Background`, and rejects a root security session. Unix identity alone is not
sufficient for CodeSign: a process in another bootstrap or audit domain cannot
reliably resolve the isolated account's `secd` and `trustd` services. The
checked-in `ios-release-user-context` boundary therefore validates the current
context and executes directly; it deliberately refuses to use
`launchctl asuser` to repair a listener that started in the wrong domain.
Manual keychain preparation, archive, export, and teardown all stay inside that
validated boundary. Each sensitive step uses absolute `/bin/bash` and invokes
the boundary as its first command through `$GITHUB_WORKSPACE`; the boundary is
not a GitHub custom-shell executable, whose path is resolved before the step
script and cannot use workflow context expressions.
The next secretless step replays `ios-release-credential-ledger.py recover` in
that user context, creates or validates every component of the standard
provisioning-profile directory with no-follow ownership checks, and audits an
empty result before GitHub injects any release secret. This restores the
baseline keychain preferences and removes only the strictly validated keychains
and provisioning profiles durably claimed by an interrupted earlier attempt. A
symlinked or wrong-owner ancestor fails before profile content or signing
material is exposed. Operators can run the doctor's
`--audit-credentials` mode to check the same persistent boundary without
recovering it.

GitHub's generated Darwin `svc.sh` is created only after runner registration,
installs a per-login LaunchAgent, and refuses root. The hidden service account
has no Aqua login session, so Tron owns the launchd definitions and uses the
checksum-pinned package's documented `runsvc.sh` entry point. The root helper
uses launchd's supported independent `user/<uid>` domain and
`LimitLoadToSessionType=Background`; the listener inherits that domain's
non-root security audit session without requiring a GUI login. The immutable
session entry point enforces the same identity contract on every restart before
the listener can connect to GitHub. Hosted macOS CI
also runs the bootstrap's non-privileged `--self-test` and executes the
user-context wrapper inside its Aqua account. Those checks exercise the real
BSD ownership query, idempotent ACL denial semantics, generated agent/helper
contracts, launchd manager identity, and audit identity without creating an
account or registering a runner. The real release doctor adds the
Background-session requirement that a hosted Aqua job cannot reproduce.

The bootstrap requires an authenticated repository-admin `gh` session and an
interactive `sudo` checkpoint. Fresh installation and service repair share a
root-owned process lock, so concurrent privileged invocations fail before
mutating the host. Fresh installation fails rather than replacing an existing
runner. `sysadminctl` may report that the hidden service account
cannot unlock FileVault; that is expected. When macOS records the custom home
without creating it, the bootstrap creates and validates the missing mode-0700
home and Keychains hierarchy with macOS system utilities, independent of any
Homebrew coreutils in the invoking shell's `PATH`. A retry resumes safely from
that account-only state; checks beneath the private service home run with the
service/root identity so an already-created baseline keychain is detected and
reused rather than mistaken for a missing file. Because standard macOS accounts
share the `staff` group, the bootstrap also probes both list and traversal
access to the invoking user's home. When needed, it adds an idempotent
`tron-ci deny list,search` ACL for only the runner instead of changing the
home's broader POSIX permissions. If permanently deleting the service account,
remove that exact ACL with
`/bin/chmod -a "user:tron-ci deny list,search" "$HOME"`.

Hosts installed with the former system-domain listener require one privileged
migration after updating the checkout:

```bash
scripts/bootstrap-ios-release-runner.sh --repair-service
```

Repair validates the existing account, pinned runner version, exact GitHub
runner ID, registration, files, and remote
idle state before changing launchd. Installations produced by the former
privileged-tar bootstrap can have an `actions-runner` directory whose mode was
broadened from 0700 to the pinned archive root's 0755 even though its enclosing
home remained private. Repair recognizes only that exact legacy mode, waits for
the exact remote runner to be idle, tightens it as `tron-ci`, and revalidates
the complete installation before staging the cutover; every other unexpected
mode fails closed. Fresh extraction also reasserts and verifies the directory's
0700 boundary after tar completes. Repair temporarily removes only the dedicated
`tron-ios-release` scheduling label and observes the runner idle twice, so a
queued release cannot race the cutover. Each observation validates busy state
and label presence from one successful GitHub API snapshot; malformed or failed
reads reset the idle proof and fail closed. It then stages the complete agent/helper
set and atomically moves the legacy plist to the root-owned, non-autoloading
`legacy-system-service.plist` rollback journal before stopping the daemon. The
old listener must disappear locally and the same GitHub runner ID must become
offline before the candidate starts; the candidate must produce a different
local PID and take that exact ID online. That proof is the logical commit;
journal cleanup and scheduling-label restoration follow it. A failure after
commit keeps the verified candidate running and scheduling fenced. If
verification fails before commit, repair stops the boot helper first, removes
the candidate, proves the exact runner offline, restores the journaled legacy
daemon, proves it online, and only then restores scheduling. The journal also
makes an interrupted process or reboot resumable. A completed repair is
idempotent; inconsistent mixed topologies and a busy runner fail closed. Repair
reuses the existing registration and credential files—it does not unregister
or rotate the runner. Root mutates only root-owned service paths; all paths
beneath the runner home, including legacy permission normalization, are created
and changed as `tron-ci` to prevent privileged symlink-follow races.

`launchctl bootout` is only a teardown request: launchd may keep the target
observable briefly after returning. Repair and rollback therefore poll the
exact system or user target for up to 30 seconds and treat observed absence as
the postcondition. Each request status, poll count, convergence, and timeout is
written under the transaction trace. This same bounded wait protects the
forward cutover and rollback, so a normal asynchronous removal cannot be
misclassified as a failed stop or trigger a rollback into the same transition.

Rotation is explicit. Stop and remove the Background agent and its boot helper,
request a short-lived removal token, unregister as the service account, then
move the old installation aside before rerunning the bootstrap. Removing the
legacy path as well makes the procedure safe for a host whose migration did not
complete:

```bash
runner_uid="$(id -u tron-ci)"
sudo launchctl bootout system/com.tron.ios-release-runner-bootstrap || true
sudo launchctl bootout "user/$runner_uid/com.tron.ios-release-runner" || true
sudo launchctl bootout system/com.tron.ios-release-runner || true
sudo /bin/rm -f \
  /Library/LaunchDaemons/com.tron.ios-release-runner-bootstrap.plist \
  /Library/LaunchDaemons/com.tron.ios-release-runner.plist \
  "/Library/Application Support/Tron/ReleaseRunner/com.tron.ios-release-runner.plist" \
  "/Library/Application Support/Tron/ReleaseRunner/legacy-system-service.plist" \
  "/Library/Application Support/Tron/ReleaseRunner/bootstrap-user-agent" \
  "/Library/Application Support/Tron/ReleaseRunner/start-runner"
repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
removal_token="$(gh api --method POST \
  "repos/$repository/actions/runners/remove-token" --jq .token)"
(cd / && sudo -H -u tron-ci \
  /Users/tron-ci/actions-runner/config.sh remove --token "$removal_token")
unset removal_token
sudo /bin/mv /Users/tron-ci/actions-runner \
  "/Users/tron-ci/actions-runner.retired.$(date -u +%Y%m%dT%H%M%SZ)"
```

Update the exact version/URL/SHA in the manifest, rerun the bootstrap, and let
its bounded final poll confirm that GitHub reports the release label online. An
interrupted post-registration bootstrap removes the new remote registration,
local credentials, and custom launchd definition before returning failure; it
reports explicitly if that rollback cannot be verified. Never register this
label on a general-purpose user account or add it to another workflow.

Before changing the Xcode beta pin, install the candidate side-by-side, confirm
Apple currently accepts that build for TestFlight, and update the version,
build, SDK, and developer-directory fields together, then run:

```bash
scripts/ios-release-runner-doctor.sh
python3 scripts/ios-release-verify.py self-test
```

Trigger a manual `dry-run` from `main` and inspect its provenance artifact
before permitting a live upload. The archive verifier rejects an Xcode 26
archive, a different Xcode 27 build, the wrong SDK, or a minimum OS above 26.0.

## TestFlight Delivery CI

`.github/workflows/release-ios.yml` owns two independent TestFlight lanes. A
successful `CI` workflow for a push to `main` publishes that workflow's exact
tested commit to the private internal group only if it is still the current
`main` head. The hosted eligibility job compares the upstream SHA with a freshly
fetched `origin/main` without entering the protected environment; the release
checkout repeats that exact comparison after acquiring the self-hosted runner
and just before a live App Store Connect upload or existing-build distribution.
A `server-v*` tag publishes to the external/public TestFlight path used by Mac
onboarding. Pull requests, failed or cancelled CI runs, stale successful main
runs, CI runs for other branches, and manual feature-branch dry-runs never
trigger delivery. Live manual runs must still equal current `main` at checkout
and at the final guard; tags must remain reachable from `main`. Manual dry-runs
remain restricted to `main` but need only pass the reachability guard.
The workflow always regenerates the Xcode project with XcodeGen, so
`project.yml` and `VERSION.env` remain the marketing-version sources of truth.
Hosted delivery overrides `CURRENT_PROJECT_VERSION` from the Release workflow's
single monotonic run-number counter. Owner run number `N` maps to
`(1000 + floor(N / 100)).(N % 100).1` for automatic internal delivery and to the same
prefix with lane `.2` for tag/manual delivery. The first automatic intent owns
its allocation permanently; later upstream or downstream reruns authenticate
and reuse that owner instead of allocating from their own counters. The `1000`
epoch keeps hosted values above legacy bare-integer builds. Checked-in
`TRON_APPLE_BUILD` remains the local and Mac build-number source.

The upload lane uses the exact Xcode 27 release pin with the `Tron` scheme and
`Prod` configuration. That is the App Store Connect bundle
(`com.tron.mobile`, App ID `6761511764`); the
`Tron Beta` scheme remains a local/dev variant with `com.tron.mobile.beta`.
Simulator and XCTest execution stays on hosted Xcode 26 CI, where a logged-in
Aqua session owns CoreSimulator and TestManager. The isolated Background
release listener does not duplicate those tests: signing-sensitive commands
remain in its account's headless user domain, then compile and archive the same
accepted `main` source with Xcode 27. This proves the SDK-linked product
surface without weakening host isolation merely to create a GUI login session.
All live lanes archive for `generic/platform=iOS`, export an App Store Connect
IPA with Xcode's `app-store-connect` export method, validate the exported
app/extension bundle IDs, entitlements, and export-compliance plist keys, upload
with `asc builds upload`, wait for the build to become valid, resolve TestFlight
export compliance, and update the What to Test notes. Every App Store Connect
lookup is scoped to platform `IOS`; processing follows the exact ASC build ID,
not a loose version match. A bounded preflight rejects an allocation that is not
strictly newer than the visible hosted build namespace.

Before export, `ios-release-verify.py` reads both archived Info plists and
asserts the exact Xcode build, iPhoneOS 27 SDK, iOS 26.0 minimum, bundle IDs,
versions, and export-compliance declarations. The exported IPA retains the
existing signing and entitlement checks. Each newly built dry or live archive
also uploads `tron.ios-release-provenance.v1`: exact source SHA, GitHub run and
attempt, Xcode version/build, SDK, deployment target, canonical/marketing/build
versions, app/extension identifiers, and app/share-extension executable plus
IPA SHA-256 values. It intentionally contains no runner name, user name, path,
credential, or device identity.

Automatic delivery is an authenticated evidence state machine. Its immutable
`tron.ios-release-intent.v1` owns source, product, and build allocation;
`tron.ios-release-provenance.v1` binds the binary; and
`tron.ios-release-head-check.v1` records the just-in-time current-main check.
After a fresh upload becomes addressable, `tron.ios-release-admission.v1` binds
the exact ASC build ID to the intent, provenance, and head-check digests. An
existing build is accepted only when its exact ASC ID and original provenance
are already bound by that authenticated admission chain. The retry then emits
`tron.ios-release-reuse-provenance.v1` plus a new chained admission; it never
relabels old provenance as if the retry produced it. Final internal group
delivery emits `tron.ios-release-receipt.v1`. Every v4 artifact name includes
the producing run ID and attempt, and the final receipt is published only after
credential teardown succeeds.

Tag and manual live delivery use a separate run-ID-scoped state machine so the
automatic v1 contract remains unchanged. `tron.ios-release-direct-intent.v1`
owns trigger, channel, source, product, and allocation;
`tron.ios-release-direct-source-check.v1` records the final `current-main` or
`main-ancestor` decision; and `tron.ios-release-direct-admission.v1` binds those
records plus exact binary provenance to one ASC build ID. Reuse requires
`tron.ios-release-direct-reuse-provenance.v1` and a new chained admission.
Completed internal or external delivery emits
`tron.ios-release-direct-receipt.v1` only after credential teardown. External
review-pending attempts retain admission without a completion receipt so the
same run can safely resume after Apple approval.

The final head check is performed immediately before the first App Store
Connect side effect. For a fresh build, its secret-free artifact is uploaded
immediately after the ASC upload attempt so artifact I/O does not widen the
check-to-upload race; admission follows only after ASC returns the exact build
identity. This necessarily leaves a narrow cross-system dual-write window in
every live lane: ASC can accept a binary before GitHub durably records
admission. A retry polls for that delayed upload, but fails closed if it finds
an unadmitted build. Leave the stranded build untouched and start a fresh manual
live workflow from current `main`, which receives a new lane-2 allocation. The
workflow never guesses ownership from a matching build number alone.

The internal lane fails before archive unless the configured group exists, is
internal, has automatic all-build access, and contains at least one tester. It
does not log or retain tester identity data. After upload, it waits until App
Store Connect reports an internally testable build and confirms the build's
relationship to that group by paging through Apple's documented
beta-group-to-builds relationship. The inverse build-to-groups relationship is
write-only in App Store Connect and must not be used as a read check. Internal
builds remain normal App Store Connect builds, so a selected build can later be
promoted through external TestFlight or App Review without rebuilding.

The external lane submits TestFlight beta review when Apple marks the build
`READY_FOR_BETA_SUBMISSION`, then branches on App Store Connect state. If Apple
reports `WAITING_FOR_BETA_REVIEW` or `WAITING_FOR_REVIEW`, CI exits successfully
as a pending-review checkpoint instead of waiting for the first-build review
window. Once externally testable, CI prefers the configured public-link group
used by Mac onboarding, but can auto-discover a single public-link group when
the repository variable is stale. Missing, stale, or ambiguous public-group
configuration is a warning after upload and processing; CI skips API group
assignment rather than failing the external release checkpoint. Group
assignment itself is replay-safe: the workflow pages the group relationship,
skips publication when the exact build is already present, and verifies that
the relationship becomes observable after a new publication.

The app and share extension Info.plists set
`ITSAppUsesNonExemptEncryption=false`, which is the current release assertion
for TronMobile's use of platform networking and non-encryption hashing. Revisit
that assertion before adding non-exempt cryptography. The workflow verifies the
key in archives and exported IPAs; for already-uploaded builds that are stuck in
`MISSING_EXPORT_COMPLIANCE`, it uses the App Store Connect API to set
`usesNonExemptEncryption=false` before distribution. The API request retries
transient failures, tolerates Apple's update-in-progress conflict, and saves
sanitized response diagnostics as a failed-run artifact. Build beta-detail and
beta review state are also read directly from the App Store Connect API because
local and CI `asc` installations can expose different TestFlight subcommand
names.

The export step supports two signing modes. If all local signing secrets are
present, CI imports an Apple Distribution `.p12` into a uniquely named,
job-owned file keychain under the isolated account's standard
`~/Library/Keychains/` directory,
installs App Store Connect provisioning profiles for the app and share
extension, and uses those same assets for both archive and export. Manually
managed and Xcode-managed profiles both resolve separate target-level profile
specifiers for the app and share extension during archive. Each decoded profile
must include the exact validated distribution leaf from the `.p12`; certificate
rotation can therefore fail before installation rather than during archive. CI
pins the installed Apple Distribution identity by certificate hash, directs archive
CodeSign lookup to that exact keychain, and uses manual archive signing without
provisioning updates. Xcode therefore cannot select a similarly named identity,
fall back to development signing, or create certificates and profiles in the
Apple account. Export then uses
`signingStyle=manual` or `signingStyle=automatic` to match the installed profile
kind. If the local signing secrets are absent, CI falls back to automatic Xcode
cloud signing with the ASC API key. Cloud signing requires Apple to allow that
key/account to manage App Store signing; a cloud signing permission error means
either grant that access or use the local signing secrets.

ASC authentication is environment-backed in CI; the workflow does not create
a repo-local `.asc/config.json`. Before manual signing changes the user
keychain search list or default, it validates the release account's current
Background context and records both exactly. Before creating the job
keychain, it atomically writes a private mode-0600 attempt ledger under the
isolated runner home; each new provisioning-profile UUID is added and fsynced
immediately before that profile is installed. The ledger contains only
recomputed run/attempt ownership and paths—never passwords, keys,
certificates, profile contents, or other credentials. The temporary search path
includes the job keychain plus macOS's system and system-root keychains; the
system-owned Apple root retains its built-in trust. Archive and export remain
in that same audit/bootstrap context. An always-run final step re-enters it,
restores the original preferences, deletes the temporary private key,
certificate, standard-directory keychain, and diagnostic files, and removes
only provisioning profiles the job created. Identical pre-existing profiles
are reused, while a UUID collision
with different content fails instead of overwriting runner state. Cleanup
continues after individual errors but fails the job if any restoration or
removal is incomplete. Only a fully successful teardown may remove the attempt
ledger and pass its final empty-state audit; otherwise the ledger remains for
the next job's bounded pre-secret recovery. This covers host termination and
process kills that bypass GitHub's `always()` step, while the TestFlight receipt
still cannot publish until normal teardown succeeds. A final always-run step
removes release build products and runs `git clean -ffdx` only inside the
isolated Actions checkout; this operation is forbidden in an interactive
development workspace.

Required GitHub Actions secrets:

| Secret | Purpose |
|---|---|
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_KEY_P8_BASE64` | base64-encoded `.p8` private key contents |

Optional local signing secrets:

| Secret | Purpose |
|---|---|
| `IOS_DISTRIBUTION_CERT_P12_BASE64` | base64-encoded Apple Distribution `.p12` for team `MYGKXH6TY4` |
| `IOS_DISTRIBUTION_CERT_PASSWORD` | Password used when exporting the `.p12` |
| `IOS_APPSTORE_PROFILE_BASE64` | base64-encoded App Store Connect provisioning profile for `com.tron.mobile` |
| `IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64` | base64-encoded App Store Connect provisioning profile for `com.tron.mobile.ShareExtension` |

Repository variables:

| Variable | Purpose |
|---|---|
| `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` | **Required for live internal delivery.** Private internal group with automatic all-build access and at least one tester |
| `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` | Optional public TestFlight group used by the Mac onboarding QR link; external delivery auto-discovers a single public-link group when this is stale |

One-time internal setup requires a manual App Store Connect checkpoint: create
or select an Internal Testing group, enable automatic distribution of all
builds, add the intended App Store Connect user as a tester, and store that
group's id as `ASC_TESTFLIGHT_INTERNAL_GROUP_ID`. After the first CI build is
available, that tester must accept the TestFlight invitation on the iPhone and
should enable TestFlight automatic updates. Those Apple UI actions cannot be
performed by repository automation; subsequent builds require no nearby Mac or
device connection.

To reuse the local App Store Connect API key, `asc auth status --verbose` shows
the current profile and key id, and `asc auth doctor` shows the `.p8` path. The
issuer id is shown in App Store Connect under Users and Access -> Integrations
-> App Store Connect API -> Team Keys. If the original `.p8` is unavailable,
generate a replacement team key there, download it once, and update all three
GitHub secrets together. Store the private key in GitHub as base64 text:
`base64 -i /path/to/AuthKey_<KEY_ID>.p8 | gh secret set ASC_KEY_P8_BASE64`.

To create the local signing secrets:

1. In Keychain Access, create a certificate signing request for the signing Mac.
2. In Apple Developer -> Certificates, Identifiers & Profiles -> Certificates,
   create an Apple Distribution certificate from that CSR, download it, and
   import it into Keychain Access.
3. Export the Apple Distribution certificate plus private key from Keychain
   Access as a password-protected `.p12`, then set
   `IOS_DISTRIBUTION_CERT_PASSWORD` and
   `base64 -i /path/to/ios_distribution.p12 | gh secret set IOS_DISTRIBUTION_CERT_P12_BASE64`.
4. In Profiles, create two Distribution -> App Store Connect profiles: one for
   `com.tron.mobile` and one for `com.tron.mobile.ShareExtension`. Select the
   same Apple Distribution certificate, generate, and download both profiles.
5. Set the profile secrets with
   `base64 -i /path/to/AppStore.mobileprovision | gh secret set IOS_APPSTORE_PROFILE_BASE64`
   and
   `base64 -i /path/to/ShareExtension.mobileprovision | gh secret set IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64`.

The workflow decodes each profile before export and fails early if the
`application-identifier` does not match the expected team/bundle ID, if the
profile is an Ad Hoc/development profile with devices, or if the app and share
extension mix Xcode-managed and manually managed profile styles. It also fails
an expired profile immediately and emits a GitHub warning during the final 30
days. Temporary profiles are installed in Xcode's current build-time library at
`~/Library/Developer/Xcode/UserData/Provisioning Profiles`; Xcode 16 moved this
library from the former `~/Library/MobileDevice` location (see Apple's
[Xcode 16 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)).
The workflow preserves Xcode's canonical lowercase profile UUID in the cache
filename, export options, and durable credential ledger; Xcode 27's manual
export lookup does not resolve the same UUID after case conversion. Recovery
and teardown therefore cannot drift from either profile installation path or
identity. Because the isolated service account has no interactive login keychain,
manual signing also downloads Apple's public root and WWDR G3 intermediate from
their canonical Apple PKI URLs and verifies both repository-pinned SHA-256
digests. Before the private key is admitted, CI extracts the single public leaf
from the `.p12` and validates the exact leaf -> WWDR G3 -> Apple Root chain with
ambient keychain lookup and issuer fetching disabled. Only WWDR G3 is imported
into the temporary user keychain; the explicit system-root keychain preserves
macOS's built-in trust instead of treating a copied root certificate as trust
configuration. These checks do not substitute for the execution-context gate:
`security verify-cert` can validate explicit files from the system bootstrap
even when CodeSign cannot reach the account's user-domain trust service. The
doctor therefore proves the matching Background manager UID and audit UID
first. A throwaway Mach-O is then signed in that context through the exact
identity hash and keychain, verified, and its
three embedded certificates are extracted and compared with the validated leaf
and both repository pins. Any failure is reduced to a redacted category such as
untrusted chain, forbidden keychain interaction, missing identity, or security
context; certificate subjects and raw signing output never enter Actions logs.
This prevents a build from silently depending on a developer's ambient login
keychain or failing only after an expensive archive begins. Provisioning
profiles cannot outlive their selected distribution certificate, so rotate the Apple
Distribution certificate, `.p12`, and both profile secrets together before the
earliest expiration date. This is a credential rotation only; the TestFlight
group and workflow configuration stay in place.

Manual workflow runs expose a `channel` choice. `dry-run` builds and tests but
skips App Store Connect; `internal` exercises private delivery from `main`; and
`external` exercises the public path from `main` without creating a tag. Live
and dry-run manual channels are all restricted to `main`, so the release runner
never compiles an arbitrary branch. Live manual runs require the ASC secrets
and consume the workflow run's Apple build
number. For the first external build of a new marketing version, the expected
successful outcome is a summary that says distribution is pending Apple Beta
App Review. Rerun the same workflow after App Store Connect shows the build as
approved; duplicate-build detection reuses the existing upload and continues
distribution. Later builds in the same approved marketing version normally
move straight to public-group assignment.

## Common Tasks

### Adding a New Screen

1. Create the view under the matching `UI/<Feature>/` owner.
2. Put session/chat state under `Session/Chat` or the relevant `Session/Timeline` owner.
3. Add navigation in the parent view or coordinator.
4. Add deep link route if applicable

### Adding Runtime Presentation

1. Emit operation, trace ids, and runtime-owned presentation hints from the server.
2. Reuse the generic tool chip, detail sheet, and result renderer.
3. Add a reusable renderer under `UI/Tools/` only when primitive trace/result rendering is not expressive enough.
4. Add focused tests for the primitive payload/result shape and its generic sheet route. Do not recreate the retired resource-backed generated-UI plane.

### Updating Event Handling

See `docs/events.md` for the complete event handling guide.

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| Simulator deep-link confirmation | Platform prompt | Some `simctl openurl` runs stop at the iOS "Open in Tron?" confirmation; keep DB evidence canonical. |
| StreamingManager timing test | Flaky | `testRapidDeltasGetBatched` |

## Performance

### Memory Management

- Event arrays capped per retained session/detail view
- Messages windowed for large sessions
- Images loaded lazily

### UI Performance

- Streaming batched at 16ms intervals
- Scroll state tracked to avoid unnecessary updates
- Heavy transforms run on background threads

## Code Style

- SwiftLint configured via `.swiftlint.yml`
- Run `swiftlint` before committing
- Use `@MainActor` for all UI-touching code
- Prefer `@Observable` over `ObservableObject`
