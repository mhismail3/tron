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

### Server Connection

The app connects to the Tron engine over `/engine`. Physical device testing
uses the Mac pairing QR code, which carries the Mac's trusted local or Tailscale
address, port, bearer token, and label. The iOS app declares local-network use
so iOS can prompt for permission when a direct Mac/Tailscale connection needs it.
Engine protocol envelopes are JSON WebSocket text frames; the client accepts
text or binary responses for diagnostics, but outbound engine requests stay text
so they match the server protocol.

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
root, and `Stop Dev Server` runs `scripts/tron dev --stop`. `Rebuild + Install
iOS Beta on iPhone` and `Rebuild + Install iOS Beta on iPad` run
`scripts/tron-ios-beta install` with generic device-name selectors; the helper
regenerates the Xcode project, preflights the active Xcode toolchain, builds the
`Tron Beta` scheme for a physical iOS destination, writes a full log plus
`.xcresult` bundle, installs the resulting app bundle with `xcrun devicectl`,
and launches the resolved bundle ID with a bounded `devicectl` launch timeout.
`Rebuild + Launch iOS Prod Fast on iPhone` uses the same helper with
`TRON_IOS_SCHEME='Tron Fast'` and `TRON_IOS_CONFIGURATION=ProdDebug`, so it
builds the fast production-bundle app and launches it on the selected iPhone.
After each build, the helper installs the requested configuration's `iphoneos` product
so stale Beta or Prod app bundles left in DerivedData cannot be launched by a
different action.
The matching launch actions run `scripts/tron-ios-beta launch` for the
already-installed app without rebuilding.

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

## Running Tests

### Command Line

```bash
xcodebuild test \
  -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Simulator Deep-Link Harnessing

Use the simulator deep-link path only when a scenario is explicitly testing
navigation/deep-link handling, or when visible iOS evidence for an exact
server-created session is intentionally called out. Backend evidence harnesses
should default to isolated temporary server homes and must not populate the
user's normal dashboard or jump the visible Simulator without an explicit flag.
The completed post-100 UI/UX scorecard lives at
`packages/agent/docs/post-100-operating-conditions-scorecard.md`; use that
scenario ledger as the archived iPhone/mac evidence model for owner
classification and Computer Use confirmation.
The follow-up iPad-only regression ledger lives at
`packages/agent/docs/post-100-ipad-ui-regression-scorecard.md`; use it for
split-view/sidebar, popover, pointer/keyboard, and wider-viewport coverage
instead of reopening the closed iPhone/mac scorecard.
The app registers `tron` and `tron-mobile` URL schemes, and
`DeepLinkRouter` handles session routes in the form
`tron://session/<session_id>`.

```bash
# Ensure a simulator is booted.
xcrun simctl bootstatus booted

# If iOS code changed, build and install the current beta app before collecting
# app-path evidence. Unit tests alone do not update the running simulator app.
cd packages/ios-app
xcodebuild -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/tron-ios-beta-derived \
  build
xcrun simctl terminate booted com.tron.mobile.beta || true
xcrun simctl install booted /tmp/tron-ios-beta-derived/Build/Products/Beta-iphonesimulator/TronMobile.app

# Launch the installed local beta app.
xcrun simctl launch booted com.tron.mobile.beta

# Open the exact server session in the app only for intentional deep-link evidence.
xcrun simctl openurl booted "tron://session/<session_id>"

# Capture the visible state as a test artifact.
xcrun simctl io booted screenshot /tmp/<scenario>-simulator.png
```

Harnesses must treat a nonzero `simctl openurl` return code or screenshot
return code as invalid app-path evidence, even when the server DB reaches a
terminal state. For non-navigation backend evidence, keep sessions in the
isolated harness server and collect DB truth without opening them in the user's
visible Simulator. Reset the old paired simulator or classify the run as
`ios_rendering`/harness evidence failure instead of passing from stale UI state.
Cold-start session routes are consumed through the pending deep-link path on
`ContentView.onAppear`; if the app opens to the session list after a successful
`openurl`, record the mismatch as parity drift.

Record the session id, run log, screenshot path, dev-server PID or health
snapshot, and the matching database evidence together. A screenshot captured
right after `simctl openurl` is navigation evidence only. For chat parity
evidence, reopen the same deep link and capture a final screenshot after the DB
has no pending approvals, no later `stream.turn_start` after the selected
terminal event, and stable invocation/resource/queue/stream rows. Later
non-turn hook rows such as `hook.llm_result` should not keep a terminal session
open by themselves. If iOS shows the system "Open in Tron?" confirmation
instead of immediately navigating, capture that screenshot but do not treat it
as pass evidence by itself; the canonical result still comes from engine DB
reconstruction for the same session id.

Use deep-link screenshots as a parity check, not just a navigation shortcut.
For each harnessed session, compare the visible chat against the engine DB:
the submitted `message.user` prompt should appear in the transcript, the latest
assistant content should match the latest completed or paused engine turn,
approval sheets should reflect the current `engine_approvals.status`, and any
sheet for an approval or generated action should either disappear or become a
clearly non-actionable approved/denied historical marker once the engine has
resolved it or moved past it. If the chat omits the user prompt, starts at
agent content, leaves a stale actionable confirmation/action sheet mounted, or
otherwise disagrees with events/invocations/approvals/resources, record that as
chat parity drift while keeping DB evidence canonical for the scenario result.

Harnesses should not classify a session immediately after the first
`stream.turn_end`. A `stream.turn_end` with `stopReason = "tool_use"` is not
terminal; it only means the provider yielded for engine tool execution and the
assistant turn may continue after the tool result. Before collecting final
evidence, wait for `stopReason = "end_turn"`, then verify the session family has
no pending approvals, no later `stream.turn_start` exists after the terminal
event being used, and the DB rows for invocations, approvals, resources, queues,
resource versions, streams, events, and logs are stable. Use
`packages/agent/tests/fixtures/session_terminal_guard.py` for simulator or
live-worker harnesses that need a repeatable DB-backed terminal-state gate.
This prevents approval pause/resume tests and multi-tool worker tests from
being marked complete while the engine is still waiting for approval or
continuing into the next turn.

### Xcode

1. Open `TronMobile.xcodeproj`
2. Select Tron scheme
3. Cmd+U to run tests

### Test Structure

```
Tests/
├── ViewModels/        # ViewModel tests
├── Services/          # Service tests
├── Core/              # Event plugin tests
├── Mocks/             # Test doubles
└── Navigation/        # Deep link tests
```

## Debugging

### Console Logging

```swift
TronLogger.shared.debug("Message", category: .network)
TronLogger.shared.error("Error: \(error)", category: .session)
```

Categories: `.network`, `.session`, `.events`, `.notification`, `.audio`

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
The upload redacts messages again at the send boundary, tracks entry
fingerprints for the active server endpoint, uses deterministic batch
idempotency, and still relies on the server's client-log dedupe index as
durable truth. Endpoint changes cancel stale scheduled uploads, and repeated
reconnects or foreground transitions do not resend unchanged local buffers or
create duplicate DB rows. Successful `logs::ingest` transport/debug plumbing is
filtered before upload so automatic syncing cannot create a self-feeding log
loop; failed ingestion and reconnect warnings are retained. The Logs sheet
remains production-available for local inspection and copying; it is not the
source of durable log truth.

Mail delivery uses the tracked `TRON_FEEDBACK_EMAIL` build setting and opens
the native Mail composer with the support recipient, subject, body, and JSON
attachment filled in. The body names the attachment and describes the actual
included log time range when parseable timestamps are available. If Mail is not
configured, or the recipient config is missing, Settings shows an alert instead
of a share sheet because iOS public APIs do not reliably attach files through a
default-mail-app handoff. Release builds must keep
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
new tag, but it must use a unique Apple build number or an existing build that
is safe to redistribute. For the first external build of a new marketing version,
the expected successful outcome is a workflow summary that says distribution is
pending Apple Beta App Review. Rerun the same workflow after App Store Connect
shows the build as approved; duplicate-build detection will reuse the existing
upload and continue distribution. Later builds in the same approved marketing
version normally skip that review wait and move straight to group assignment.

## Common Tasks

### Adding a New Screen

1. Create view in `Views/<Feature>/`
2. Create view model if needed in `ViewModels/`
3. Add navigation in parent view or sheet coordinator
4. Add deep link route if applicable

### Adding Capability Presentation

1. Add schema or result presentation hints to the capability metadata.
2. Reuse the generated capability chip, detail sheet, and result renderer.
3. Add a reusable renderer under `Views/Capabilities/` only when metadata-driven rendering is not expressive enough.
4. Add focused tests for the schema/result shape and the sheet route.

### Updating Event Handling

See `docs/events.md` for the complete event handling guide.

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| Simulator deep-link confirmation | Platform prompt | Some `simctl openurl` runs stop at the iOS "Open in Tron?" confirmation; keep DB evidence canonical. |
| StreamingManager timing test | Flaky | `testRapidDeltasGetBatched` |

## Performance

### Memory Management

- Event arrays capped (100 events per subagent)
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
