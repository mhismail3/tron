# Tron iOS development

## Fresh-clone prerequisites

Use Xcode 26 with the iOS 26.2 simulator runtime and XcodeGen 2.45.3. The Xcode
project is generated and intentionally untracked:

```bash
scripts/install-ci-tools.sh xcodegen
export PATH="$PWD/.ci-tools/bin:$PATH"
cd packages/ios-app
xcodegen generate
```

## Generate and build

```bash
cd packages/ios-app
xcodegen generate
xcodebuild build -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration ProdDebug \
  -destination 'generic/platform=iOS Simulator'
```

The generated Xcode project is not architectural truth; edit `project.yml` and
source files, then regenerate.

## Efficient focused tests

Do not rerun the full suite for each edit. Compile test products once, then run
only the owning suite without rebuilding:

```bash
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SnapshotCacheTests
```

Multiple `-only-testing:` arguments may select adjacent owners. After source
changes, rerun the incremental `build-for-testing` (normally seconds), then
continue with `test-without-building`. Run the complete unit target only after
focused suites pass:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests
```

`scripts/ios-ci-test.sh` is the fresh-clone unit checkpoint: it generates the
project, builds once, and runs the complete unit target without rebuilding.

Swift 6 complete strict concurrency is explicit in `project.yml`. Preserve that
baseline for focused builds that introduce or change concurrency boundaries:

```bash
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  SWIFT_STRICT_CONCURRENCY=complete
```

Gateway transport tests inject `ManualClock`, `SequenceUUIDSource`, and
`ScriptedGatewaySocket` below `GatewayClient`. Advance the manual clock only
after the expected sleeper/barrier is registered. Test-owned unstructured tasks
must be cancelled for their full lifetime and joined with `valueOfOwnedTask` so
the test watchdog propagates cancellation. Scripts enqueue and inspect raw frame
bytes; they must not implement protocol decoding, session state, receipt policy,
retry policy, or event admission. Run the focused owner with:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/GatewayClientTransportTests
```

Performance intervals use `SystemPerformanceSignposts`; tests inject
`RecordingPerformanceSignposts` at the owning boundary. Metadata accepts only a
closed result code and nonnegative item/byte counts. Never add identifiers, paths,
methods, filenames, model names, prompts, transcript content, or other strings.
Gateway and cache interval contracts are owned by `GatewayClientTransportTests`
and `SnapshotCacheTests`. `AppModelPerformanceSignpostTests` drives raw Gateway
frames through visible open, synchronization/resynchronization, uncertain receipt,
and terminal replay boundaries. It intentionally records each current resync attempt;
Phase 2 owns removal of redundant synchronization work after the baseline is frozen.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/AppModelPerformanceSignpostTests
```

Camera boundary tests inject authorization and capture-session providers into
`CameraModel`; QR boundary tests use the same authorization seam plus a scanner-specific
session provider. They never invoke camera hardware or replace AVFoundation in production.
Keep provider callbacks MainActor-bound and keep the two unchecked Sendable AVFoundation
envelopes limited to the photo provider's serial queue boundary. The QR permission task
must recheck cancellation before configuration. Phase 7 owns the remaining generation-scoped
camera setup/capture lifecycle changes.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/CameraBoundaryTests \
  -only-testing:TronMobileTests/QRCodeScannerBoundaryTests
```

Share boundary tests cover provider-fragment reduction, prompt composition, and the
single-value app-group store without loading extension UI. `PrivacyManifestTests` verify
both source manifests and both built bundles. The separate archive check is read-only and
must run after a maintainer-created archive; it never archives, exports, or uploads.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SharedContentTests \
  -only-testing:TronMobileTests/PrivacyManifestTests
packages/ios-app/scripts/verify-archive-privacy.sh <path-to-xcarchive>
```

Global configuration surfaces key their SwiftUI reload task to event-only invalidation
generations. Successful settings, provider/model, package, and custom-model reads publish
values without changing those generations. `AppModelInvalidationTests` scripts every
successful response and proves publication cannot schedule its own next load; event tests
separately prove one generation advance per canonical invalidation. Settings requests use a
typed target: global requests omit CWD, while project requests carry their exact project CWD.
The focused suite deliberately completes global/project settings and global/session provider
catalogs out of order, then reverses two same-target reads; installed values must remain under
their request key and the newest same-target request must win. It also proves auth completion
retains its catalog target after failed cancellation and unknown operations trigger no guessed reload.
Package cases similarly reverse global/workspace and same-target inventory responses, verify
mutation CWD/local parameters, and require mutation-completed update markers to be cleared.
A paired custom-model case proves the newer typed-global document read wins reversed completion.
`SettingsDraftStoreTests` prove target isolation, pre-response editing, invalidation rejection,
provider-target load identity, stale save/scope-round-trip admission across model/default, runtime,
and resource drafts, changed-field-only wire patches, and explicit redacted proxy set/clear handling.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/AppModelInvalidationTests \
  -only-testing:TronMobileTests/AppModelEventTests/globalConfigurationInvalidations \
  -only-testing:TronMobileTests/NewSessionConfigurationOwnerTests \
  -only-testing:TronMobileTests/SettingsRouteIdentityTests \
  -only-testing:TronMobileTests/SettingsDraftStoreTests
```

Pairing tests keep policy above byte transport. `GatewayPairingTransportTests`
feed raw HTTP response bytes and inspect the exact `/v1/pair` request.
`AppModelPairingAttemptTests` use barriers whose late responses intentionally
outlive task cancellation, plus an injected commit recorder, so stale-path tests
never write Keychain. Run the attempt race suite repeatedly when changing its
ownership checks:

```bash
for run in 1 2 3; do
  xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
    -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:TronMobileTests/GatewayPairingTransportTests \
    -only-testing:TronMobileTests/AppModelPairingAttemptTests \
    -only-testing:TronMobileTests/PairingInvitationParserTests || exit 1
done
```

`SessionScenarioBuilder` is test-only and generates deterministic synthetic
opening tails, on-demand history pages, tool bursts, Markdown streams, and image
metadata. It never stores a second transcript or uses personal files. Record the
seed and the requested byte/count/rate/dimension inputs with performance results.
Validate the fixture contracts with:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionScenarioBuilderTests
```

`ChatViewScrollHarnessTests` mount the actual `ChatView`, `LazyVStack`, composer
inset, and native `UIScrollView` in a fixed hosted window. Test-only authority
admission bypasses network I/O without bypassing `AppModel`'s authoritative read
gate. Raw geometry, visible semantic IDs, and row frames are reduced to one latest
sample on each `CADisplayLink` tick. The production `DisplayFrameScheduler` is a
one-shot, cancellation-aware display-link boundary; first-ready timing cannot end
before it resumes. The Phase 0 baseline requires a visible latest semantic row, not
a final displacement tolerance; Phase 5 owns that budget and the current
multiple-update-per-frame SwiftUI diagnostics.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/ChatViewScrollHarnessTests \
  -only-testing:TronMobileTests/ChatPerformanceTrackerTests
```

`ChatPerformanceBaselineTests` is opt-in and records five post-warm-up timing,
CPU, physical-memory, malloc-zone allocation, and scroll-animation signpost
samples against the 10,000-entry hosted fixture. `Tron Device Performance` uses
the provisioned app identity with `HOSTED_TEST` for test/profile actions; its archive
action points to `Prod` so hosted hooks cannot enter an archive. Run the test only at
explicit checkpoints and keep device identifiers
out of source. The recorded Phase 0 environment, results, limitations, and commands
are in [performance-baseline.md](performance-baseline.md).

Run UI tests separately because simulator launch dominates their cost:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron UI Validation' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileUITests/TronSmokeUITests \
  -collect-test-diagnostics never
```

For real gateway-to-iOS E2E work, keep the deterministic gateway fixture and
DerivedData alive across edits. Preparation and the first build happen once;
`run` renews only the one-use enrollment/session fixture and executes the
focused UI test without reinstalling dependencies or rebuilding:

```bash
scripts/ios-gateway-e2e-test prepare
scripts/ios-gateway-e2e-test build
scripts/ios-gateway-e2e-test run

# After a Swift edit:
scripts/ios-gateway-e2e-test iterate

# Exercise only native attachment menu → camera/photo/file presentations:
TRON_E2E_ATTACHMENT_ONLY=1 scripts/ios-gateway-e2e-test iterate
```

The focused runner disables Xcode's failure sysdiagnose collection, which can
otherwise add a ten-minute timeout after a UI assertion. Its reconnect journey
cold-launches back to the authoritative dashboard and explicitly reopens the
session; transient `NavigationStack` state is not part of restoration or cache
truth. Use `logs`, `status`, `stop`, and `clean` to inspect or manage the
persistent fixture. CI owns the
complete unit target; smoke/accessibility and real-gateway UI journeys remain
explicit cross-module/release checkpoints because they are slower and depend on
simulator integration rather than ordinary source compilation. Full UI suites
remain final checkpoint validation, not an edit loop.

Typography or control-style changes must run
`TronMobileTests/FontSettingsTests` and
`TronMobileTests/PresentationStyleGuardTests`. The font tests verify all bundled
faces resolve, historical preference keys round-trip, and variable Source Serif
and Recursive code roles do not silently become system fonts. The presentation
guard rejects app-owned system fonts, stock bordered/search/segmented/field
styles, system-generated section/navigation titles, unstyled text inputs, and
Form/List surfaces that omit the Tron collection treatment. OS-owned alerts,
menus, and pickers are deliberate exceptions.

UI validation audits onboarding in light and dark modes and audits a
populated real-gateway chat, session management, settings, and appearance. The
real-gateway test retains named screenshot checkpoints for the completed chat,
Manage Session, root settings, and appearance in its result bundle. It also
relaunches at accessibility XXXL to verify standard SwiftUI controls that
XCTest's simulated Dynamic Type audit misclassifies. Any audit suppression must
name one exact element, have a retained rendered checkpoint, and have a separate
real-size assertion; category-wide suppression is not allowed.

Simulator screenshots are deterministic regression artifacts, not the final
system-chrome authority. At broad presentation checkpoints, build the actual
`Tron Fast` `ProdDebug` app for the connected iOS 27 device, install it without
removing its Keychain pairing, launch it against the isolated development
gateway, and capture chat, dashboard/setup, Manage Session, tool detail, and
settings screens with `devicectl`. Compare those captures to the historical
references before declaring parity. A signed install, launch, and screenshot are
required together because default toolbar Liquid Glass can differ materially
between the simulator and physical hardware. Chat checkpoints must also verify
trailing alignment for user turns, historical transcript/tool insertion motion,
the Settings gear in the chat toolbar, the context ring at the trailing edge of
an empty idle composer, the compact runtime working row without any composer-structure
change, and emerald toolbar/sheet actions. Terminal checkpoints must exercise
the native keyboard plus the floating shortcut and command-key surfaces rather
than validating only PTY output.

Historical onboarding references captured by executing commit `c3f12c17c` live
under `docs/assets/parity/`. `TronSmokeUITests` keeps matching medium/pairing
screenshots in its result bundle. Compare the medium sheet crop as well as the
full screen: the mounted shell toolbar, detent, centered title, card geometry,
page dots, and toolbar navigation are all part of the parity contract. Copy may
change only where gateway security semantics require one-time enrollment rather
than a permanent pairing token.

## Chat top-blur validation

The chat's top-edge overlay is inspired by
[jtrivedi/VariableBlurView](https://github.com/jtrivedi/VariableBlurView). The
`Tron Fast` `ProdDebug` build enables its guarded private `CAFilter`
variable-radius path for local visual iteration only. The Objective-C bridge
catches runtime exceptions and falls back cleanly if the private filter or
backdrop hierarchy changes. Other configurations compile the App-Review-safe
public fallback: a gradient-masked `UIVisualEffectView`. Do not
add `TRON_PRIVATE_VARIABLE_BLUR` to an archived configuration; private API is
not eligible for App Store distribution.

Validate this chrome on a physical device while scrolling high-contrast content
beneath the chat, dashboard, and representative medium/large sheet toolbars.
Chat uses a 188-point fade, dashboard 176 points, and sheets a compact 124 points.
Check that each top stays legible, the lower edge has no visible cutoff, toolbar
controls remain tappable, and light/dark modes retain the same gradual
transition. Immersive camera and image-preview sheets intentionally have no
added backdrop.

## Manual iOS release validation and delivery

The repository does not archive or upload production iOS artifacts. A maintainer
performs every TestFlight or App Store delivery deliberately:

1. Select the exact commit whose CI checks passed, confirm a clean tracked
   checkout, and run `scripts/tron version check`.
2. Generate the project and complete the release checkpoint: the full iOS unit
   target, required UI/E2E journeys, and eyes-on physical iPhone/iPad review of
   onboarding, pairing, chat/attachments, system-keyboard dictation, terminal,
   settings, accessibility, and signed-device networking.
3. With a stable non-beta Xcode and maintainer-controlled signing credentials,
   archive the `Tron` scheme in `Prod`. Run
   `packages/ios-app/scripts/verify-archive-privacy.sh <path-to-xcarchive>`, then inspect
   the app and share extension bundle identifiers, versions/builds, and signatures before export.
4. Use Xcode Organizer/App Store Connect to export and upload manually, then make
   any TestFlight group assignment or App Store release choice explicitly. Record
   the source commit, version/build, and validation results with the release.

Never add or invoke a repository workflow or command that performs production
archive upload, TestFlight distribution, or App Store release automatically.

## Gateway fixture work

Protocol DTO changes require matching gateway tests and Swift decoding tests.
Use provider-qualified models, preserve unknown JSON through `JSONValue`, and
make new mutation calls carry a UUID `commandId`.

## Privacy

The app declares local-network and camera usage. Voice input remains available
through system-keyboard dictation; the app does not currently own microphone or
speech-recognition capture. Provider credentials must never be placed in fixtures,
defaults, logs, or UserDefaults.
