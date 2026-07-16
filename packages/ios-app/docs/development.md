# iOS Development

## Setup

### Prerequisites

- Xcode 26+ with iOS 26 SDK
- XcodeGen (`brew install xcodegen`)
- Tron server running locally

### Project Generation

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

`project.yml` is the authoritative project definition. The generated
`TronMobile.xcodeproj` is local build output and remains ignored by Git.
Shared signing, Swift, and version build settings live at the project level so
the app and share extension inherit one value. `scripts/tron version sync`
updates the project-level version mirror from `VERSION.env`.

### Icon Assets

`Sources/Assets.xcassets/TronLogoVector.imageset/tron-logo.svg` is the
authoritative logo source. The Bun/Sharp generator writes only the two app-icon
PNGs and three in-app raster logo sizes that the asset catalogs reference:

```bash
cd packages/ios-app
bun install --frozen-lockfile
bun scripts/generate-icons.mjs
```

Generated image outputs stay inside `Assets.xcassets`; loose icon-layer PNGs
under `Sources/Resources` are not part of the app resource contract.

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
queries are not logged. When physical-device pairing fails, copy the
`[WebSocket]` lines from Xcode first; they should identify whether the failure
is local-network permission, Tailscale reachability, HTTP auth, or engine
protocol response handling.

### Codex App Local Actions

The repository includes `.codex/environments/environment.toml` for Codex app
toolbar actions. `Dev Server` starts `scripts/tron dev -bdt` from the project
root, and `Stop Dev Server` runs `scripts/tron dev --stop`.
`Rebuild + Install + Launch iOS Beta on iPhone` and `Rebuild + Install + Launch
iOS Beta on iPad` run `scripts/tron-ios-beta install` with generic device-name
selectors; the helper regenerates the Xcode project, preflights the active
Xcode toolchain, and builds `TronMobile.xcodeproj` directly from the authoritative
`project.yml`; arbitrary local workspaces do not override that generated owner.
It builds the `Tron Beta` scheme for a physical iOS destination, writes a full
log plus `.xcresult` bundle, installs the resulting app bundle with
`xcrun devicectl`, and launches the resolved bundle ID with a bounded `devicectl`
launch timeout.
`Rebuild + Install + Launch iOS Prod Fast Debug on iPhone` uses the same helper
with `TRON_IOS_SCHEME='Tron Fast'` and `TRON_IOS_CONFIGURATION=ProdDebug`, so
it builds the fast production-bundle app and launches it on the selected iPhone.
`Rebuild + Install + Launch iOS Prod Release on iPhone` uses
`TRON_IOS_SCHEME=Tron` and
`TRON_IOS_CONFIGURATION=Prod`, so it builds the optimized production app,
installs the fresh product, and then launches it through the same helper.
After each build, the helper installs the requested configuration's `iphoneos`
product so stale Beta or Prod app bundles left in DerivedData cannot be launched
by a different action.
Production rebuild actions call `install`, not `launch`, so local source changes
are compiled before the app is reinstalled.
The matching `Just Launch Installed ...` actions run `scripts/tron-ios-beta
launch` for the already-installed app without rebuilding. The iPhone launch
actions are deduplicated by bundle ID: Beta has its own launch action, and the
single production launch action opens whichever `com.tron.mobile` binary is
currently installed, whether it came from Prod Fast Debug or Prod Release.

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

If Xcode needs a custom destination string, set `TRON_IOS_DESTINATION`
directly, for example `platform=iOS,id=<device-identifier>`.

The helper also accepts `TRON_IOS_SCHEME` and `TRON_IOS_CONFIGURATION` for local
variants. Defaults remain `Tron Beta` and `Beta`; the fast production action sets
them to `Tron Fast` and `ProdDebug`.

## Build Configurations

| Config | Scheme | Use Case |
|--------|--------|----------|
| Beta | Tron Beta | Development (debug, beta bundle ID) |
| ProdDebug | Tron Fast | Local production-app iteration (debug, production bundle ID) |
| Prod | Tron | App Store/TestFlight (release, production bundle ID) |

Use `Tron Fast` when you want Xcode's debug-speed rebuilds to install over the
production app (`com.tron.mobile`) instead of the side-by-side beta app. It uses
the production app icon, production bundle IDs, and production entitlements, but
keeps `-Onone`, `ENABLE_TESTABILITY=YES`, and `ONLY_ACTIVE_ARCH=YES` like the
beta debug build.

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
testing.

## Running Tests

### Command Line

```bash
xcodebuild test \
  -scheme Tron \
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
and emits one matching cleanup record. Repeated and process-fallback cleanup use
the same idempotent owner and cannot duplicate the cleanup event. Tests must
not discover, unlink, or synchronize CoreSimulator preference backing files;
`cfprefsd` may materialize an empty plist after the process exits.
Token identities use a separate, complete
`TRON_TEST_KEYCHAIN_LIFECYCLE_V1` ledger. Parse it independently from defaults
records; registration and cleanup must be unique and set-equal by namespace,
service, and account, and lifecycle JSON must never contain token material.
Cleanup order is manager shutdown, token clear/proof/ledger emission, database
close, fixture-root removal, defaults cleanup, then process-fallback
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

1. Run the focused `AppDelegateTests` through the Beta test host. Require the
   hosted callbacks to leave every injected lifecycle effect at zero and the
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
  -only-testing:TronMobileTests/CapabilityInvocationGroupingTests \
  -only-testing:TronMobileTests/EventDatabaseTests/testEnrichedAssistantMessageMetadata

xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/ChatAffordanceVisualRenderTests

```

For the interactive prompt-composer glass, background-free proportional
Session Briefing context ring, and voice-lifecycle slot/action ownership, run
the focused presentation/source contracts and visual render:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/ContextBriefingButtonTests \
  -only-testing:TronMobileTests/InputBarKeyboardTraversalTests

xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/ChatAffordanceVisualRenderTests

xcodebuild test -scheme 'Tron UI Validation' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileUITests/SessionBriefingUITests/testComposerGlassKeepsAttachmentMenuAndSessionBriefingInteractive
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

For Dashboard capability visibility or `WorkerLifecycleRepository` protocol
changes, run the focused cockpit state/view-model set:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/AgentCockpitIssueStateTests \
  -only-testing:TronMobileTests/AgentCockpitStateTests \
  -only-testing:TronMobileTests/AgentCockpitDiscoveryStateTests \
  -only-testing:TronMobileTests/AgentCockpitPresentationTests \
  -only-testing:TronMobileTests/AgentCockpitViewModelTests
```

For Dashboard presentation/model changes, run the dedicated source/model
contracts and the single progressive-disclosure visual route. Issue aggregation
has its own equally small state suite:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/DashboardPresentationTests \
  -only-testing:TronMobileTests/AgentCockpitStateTests \
  -only-testing:TronMobileTests/AgentCockpitDiscoveryStateTests \
  -only-testing:TronMobileTests/AgentCockpitPresentationTests

xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/AgentCockpitIssueStateTests

xcodebuild test -scheme 'Tron UI Validation' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileUITests/DashboardHitTargetUITests/testEngineCockpitProgressiveDisclosurePath
```

For the main Settings destination copy or the Engine/Providers sheet hierarchy,
run the focused ownership and no-summary-hero contracts:

```bash
xcodebuild test -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:TronMobileTests/EngineSettingsOwnershipTests \
  -only-testing:TronMobileTests/EngineSettingsPageLayoutTests/testEngineAndProvidersSheetsDoNotMountSummaryHeroes
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
  -only-testing:TronMobileTests/EventTypeRegistryTests \
  -only-testing:TronMobileTests/ErrorEventProjectionTests \
  -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests \
  -only-testing:TronMobileTests/GeneratedUIRendererTests
```

### Simulator Deep-Link Smoke Test

`Info.plist` registers the `tron` and `tron-mobile` URL schemes;
`DeepLinkRouter` owns the routes they accept:

- `tron://session/<session-id>`
- `tron://session/<session-id>?capability=<invocation-id>`
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
│   └── WorkerLifecycle/ # State, discovery, presentation, and shared cockpit fixtures
├── UI/                # Chat, settings, onboarding, runtime surface, and component tests
├── Support/           # Composition, diagnostics, foundation, pairing, and storage tests
└── Infrastructure/    # Fakes, fixtures, SourceGuard, cleanup, and project-structure guards
```

Active hierarchy and targeted hard-budget enforcement live in
`SourceGuardTests` and do not depend on point-in-time line counts recorded in
archived scorecards.

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

## TestFlight Release CI

The iOS beta is published by `.github/workflows/release-ios.yml` on the same
`server-v*` tag that cuts the Mac DMG. The workflow always regenerates the
Xcode project with XcodeGen before building, so `project.yml` and `VERSION.env`
are the release sources of truth.

The upload lane uses the `Tron` scheme with the `Prod` configuration. That is
the App Store Connect bundle (`com.tron.mobile`, App ID `6761511764`); the
`Tron Beta` scheme remains a local/dev variant with `com.tron.mobile.beta`.
CI creates or selects an available iPhone simulator, runs the simulator tests,
archives for `generic/platform=iOS`, exports an App Store Connect IPA with
Xcode's `app-store-connect` export method, validates the exported app/extension
bundle IDs, entitlements, and export-compliance plist keys, uploads with
`asc builds upload`, waits for the build to become valid, resolves TestFlight
export compliance, updates the What to Test notes, submits TestFlight beta
review when Apple marks the build `READY_FOR_BETA_SUBMISSION`, and then branches
on the returned App Store Connect state. If Apple reports `WAITING_FOR_BETA_REVIEW`
or `WAITING_FOR_REVIEW`, CI exits successfully as a pending-review checkpoint
instead of waiting for the 1-2 day first-build review window. If the build is
already externally testable, CI prefers the configured public-link group used by
Mac onboarding, but can auto-discover a single public-link group when the stored
repository variable is stale. Missing, stale, or ambiguous group variables are
warnings after the build is uploaded and processed: CI skips API group assignment
rather than failing an otherwise successful TestFlight release checkpoint. The
optional internal group id is diagnostic only. App Store Connect does not allow
direct API assignment to an internal group, so CI warns when the configured
internal group is stale or lacks all-build access. The group validation step
supports both `asc testflight beta-groups list` and older
`asc testflight groups list` CLI shapes. Reruns use `asc builds list` to reuse an
existing Apple build number instead of uploading a duplicate binary.

The app and share extension Info.plists set
`ITSAppUsesNonExemptEncryption=false`, which is the current release assertion
for TronMobile's use of platform networking and non-encryption hashing. Revisit
that assertion before adding non-exempt cryptography. The workflow verifies the
key in archives and exported IPAs; for already-uploaded builds that are stuck in
`MISSING_EXPORT_COMPLIANCE`, it uses the App Store Connect API to set
`usesNonExemptEncryption=false` before distribution. Build beta-detail and beta
review state are also read directly from the App Store Connect API because local
and CI `asc` installations can expose different TestFlight subcommand names.

The export step supports two signing modes. If all local signing secrets are
present, CI imports an Apple Distribution `.p12` into a temporary keychain,
installs App Store Connect provisioning profiles for the app and share
extension, and exports locally. Manually managed profiles use
`signingStyle=manual`; Xcode-managed App Store profiles use
`signingStyle=automatic` without cloud-signing credentials so Xcode can reuse
the installed profiles. If the local signing secrets are absent, CI falls back
to automatic Xcode cloud signing with the ASC API key. Cloud signing requires
Apple to allow that key/account to manage App Store signing; a cloud signing
permission error means either grant that access or use the local signing
secrets.

ASC authentication is environment-backed in CI; the workflow does not create
a repo-local `.asc/config.json`. Before manual signing changes the user
keychain search list or default, it records both exactly. An always-run final
step restores those preferences, deletes the temporary private key,
certificate, and keychain, and removes only provisioning profiles the job
created. Identical pre-existing profiles are reused, while a UUID collision
with different content fails instead of overwriting runner state. Cleanup
continues after individual errors but fails the job if any restoration or
removal is incomplete.

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

Optional repository variables:

| Variable | Purpose |
|---|---|
| `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` | Public TestFlight group id used by the Mac onboarding QR link; CI auto-discovers a single public-link group when this is stale |
| `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` | Internal TestFlight group id; warnings only because public TestFlight distribution does not assign internal groups directly |

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
extension mix Xcode-managed and manually managed profile styles.

Manual workflow runs default to `dry_run=true`, which builds and tests but skips
App Store Connect upload and TestFlight distribution. A manual run with
`dry_run=false` exercises the full upload/distribution path without creating a
new tag, but it must have all three required ASC secrets and use a unique Apple
build number or an existing build that is safe to redistribute. Tag runs and
manual `dry_run=false` runs reject a missing ASC secret before the build; only
the explicit manual dry-run may omit them. For the first external build of a
new marketing version, the expected successful outcome is a workflow summary
that says distribution is pending Apple Beta App Review. Rerun the same
workflow after App Store Connect shows the build as approved; duplicate-build
detection will reuse the existing upload and continue distribution. Later
builds in the same approved marketing version normally skip that review wait
and move straight to group assignment.

## Common Tasks

### Adding a New Screen

1. Create the view under the matching `UI/<Feature>/` owner.
2. Put session/chat state under `Session/Chat` or the relevant `Session/Timeline` owner.
3. Add navigation in the parent view or coordinator.
4. Add deep link route if applicable

### Adding Runtime Presentation

1. Emit operation, trace ids, and runtime-owned presentation hints from the server or generated runtime data.
2. Reuse the generic capability chip, detail sheet, result renderer, and `GeneratedRuntimeSurfaceView`.
3. Add a reusable renderer under `UI/Capabilities/` or `UI/RuntimeSurfaces/` only when primitive trace/result rendering is not expressive enough.
4. Add focused tests for the primitive payload/result shape and the generic sheet route.

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
