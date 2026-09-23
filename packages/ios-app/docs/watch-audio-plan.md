# Apple Watch audio recording implementation plan

Status: partial source integration only. The iPhone product embeds a Watch app,
Watch files transfer into a durable iPhone inbox, and Watch capture metadata maps
to Gateway `CaptureMetadataV1`. This is not an end-to-end Mac delivery product
or a physically qualified recording product; do not ship or represent it as
complete.

## Implemented source behavior

- `project.yml` defines `TronWatch` as a compiled watchOS application using
  Xcode's modern `com.apple.product-type.application` product type, with
  generated `WKApplication` metadata and an embedded Watch Content relationship.
  Per-configuration companion bundle identifiers pair Development with the beta
  iPhone app, Test with the test host, and DevicePerformance/LocalDevice/Release
  with the production bundle.
- Watch microphone input is copied into a bounded eight-item serial-writer queue
  and written as one-minute CAF linear PCM segments. Rotation uses the opened
  hardware input format's sample rate instead of assuming 48 kHz. Queue
  saturation and write failures stop capture rather than silently dropping
  audio. AVAudioSession interruption, route-change, and media-service-loss
  notifications stop capture and retain completed segments.
- Watch Application Support retains segments and a manifest with byte counts,
  SHA-256, frame/duration/timing information, source stop/recovery disposition,
  and ordered segments. Admission checks a 1 GiB free-space floor. Segment and
  manifest files and relevant directories are synchronized before manifest
  admission succeeds. `CaptureMetadataV1` serialization has the expected source,
  UTC date, disposition, and timeline fields. Watch files transfer after Stop
  and are retried by enqueueing stopped manifests on app launch; Watch copies
  are retained.
- The iPhone `WatchRecordingInbox` synchronously bounds each received segment to
  64 MiB and enforces a 2 GiB aggregate inbox cap plus a 1 GiB free-space floor
  before reading/moving data. It hashes and moves received files into Application Support during the WatchConnectivity callback, publishes a
  metadata index, synchronizes file and directory entries (including the inbox
  root after recording-directory creation), and treats exact duplicate delivery
  idempotently. It does not use a temporary-directory fallback. A moved-file/index
  crash window is recoverable by redelivery; no cleanup is performed. The
  Watch Recordings settings surface pins future recordings to an explicitly
  selected paired profile, retries complete pinned inbox recordings with that
  profile's Keychain credential, and finalizes against the authenticated
  recording route. Receipt capture metadata is checked before persistence and
  persisted reread. Receipt relays use non-coalescing WatchConnectivity
  user-info transfers; application context remains destination configuration
  only. Watch validates receipt identity against the exact recording and pinned
  machine before showing saved-on-Mac status. Copies are retained.
- Watch capture/admission and the iPhone receiver share the Gateway V1
  512-segment maximum. Watch writer admission stops rather than creating segment
  513. On relaunch an unfinished recording attempts to read and admit a
  contiguous unmanifested CAF tail; unreadable tails remain retained and are not
  represented as complete segments. Partial recovery remains explicit in capture
  metadata.
- Gateway final receipts validate binding identity, exact schema, canonical
  timestamp, totals, aggregate segment digest, and capture shape before status
  publication. The aggregate digest covers ordered segment number/hash/size
  records, not capture metadata: status cannot independently detect a different
  but valid capture object written into the receipt. Finalize replay rejects
  metadata that differs from the caller's capture, and the iPhone rejects a
  receipt whose capture differs from its locally derived metadata. Segment audio
  and its admitted receipts remain independently checked against the aggregate.
- Watch UI explicitly says that Watch-retained recordings do not mean Mac
  delivery has been confirmed. The process-local elapsed timer is only a UI
  estimate, not continuity evidence.

CAF/PCM remains an unqualified format choice. The source-level typechecks and
synthetic storage tests do not establish capture continuity, power-loss
durability, or reliable WatchConnectivity delivery on hardware.

## Remaining source gaps

- The iPhone coordinator now owns background `URLSession` uploads, task
  reconciliation, persisted confirmed-segment state, bounded transient retry,
  exact per-recording destination assignment, and app-delegate background event
  completion. Credentials remain resolved from the selected enabled paired
  profile's Keychain token; Watch metadata cannot supply endpoint or token.
  Protected-data lock and credential revocation still need explicit delivery
  state handling, and capability/status reconciliation is not implemented.
- WatchConnectivity callback acceptance is not a Mac receipt. Watch only reports
  saved status after validating the relayed receipt against the exact recording
  and pinned machine. Credential-bearing redirect behavior and real background
  URLSession constraints have not been validated. Neither Watch nor iPhone
  deletes source copies.
- Capture is bounded to 512 one-minute segments (about 8.5 hours by the
  application limit); it is not unlimited. Writer admission stops at the bound.
  This limit is not a claim of hardware-qualified duration or continuity.
- `WatchRecordingStoreTests` cover byte/hash/order/recovered-manifest behavior,
  metadata shape, readable CAF tail recovery, and the shared segment bound.
  Gateway store tests cover receipt identity/count/audio corruption and
  reordered-key retries; iPhone delivery tests cover exact receipt capture
  matching. Writer callback stress, queue saturation, rotation at non-48-kHz
  rates, writer failures, Watch transfer retries, iPhone move/index crash
  recovery, and cleanup regressions are not yet tested.
- Signed artifact/helper validation for an embedded Watch app is not extended.
  Built-product Info.plist/entitlements and app installation remain unverified.

## Validation and qualification

- `scripts/tron ios generate` passed. Generated project inspection confirmed
  the compiled Watch application product type and `Embed Watch Content` phase
  with destination `$(CONTENTS_FOLDER_PATH)/Watch`.
- Strict watchOS source typecheck passed with `WatchRecordingStore.swift`,
  `WatchRecordingConnectivity.swift`, and `TronWatchApp.swift`; strict iOS SDK
  source typecheck passed for `WatchRecordingInbox.swift`.
- Xcode 26.6 (build 17F113) watchOS 26.5 SDK target build passed with real
  production sources and both arm64 and arm64_32 architectures:
  `xcodebuild build -project packages/ios-app/TronMobile.xcodeproj -target TronWatch -configuration Development -sdk watchos CODE_SIGNING_ALLOWED=NO ...`.
  The built product is `/tmp/tron-watch-sdk-build-products/Development-watchos/TronWatch.app`;
  its Info.plist contains `WKApplication`, microphone usage text, and the
  Development companion bundle `com.tron.mobile.beta`. Generated configuration
  inspection confirms Test pairs with `com.tron.mobile.testhost`, and
  DevicePerformance/LocalDevice/Release pair with `com.tron.mobile`.
- This Xcode installation has the watchOS device and simulator SDKs but no watch
  simulator runtime. The iOS generic-scheme build still reports the watchOS
  component unavailable; a direct iPhone target build incorrectly schedules the
  embedded Watch sources with the iOS SDK, so it is not a valid companion build.
  No iOS simulator/device install or signing qualification was performed.
  The added metadata test and existing store tests have not been run on this
  revision.
- Gateway `npm run check` passed. The focused 18-test recording suite runs with
  Homebrew Node (`/opt/homebrew/bin/node node_modules/vitest/vitest.mjs`); the
  bundled Gateway Node rejects the native binding's Team ID. No dependency
  changes or installs were made.
- No Watch/iPhone/Mac hardware qualification, audio soak/continuity/energy test,
  low-space or abrupt-kill injection, file-protection lock/reboot check,
  WatchConnectivity relay/relaunch test, background HTTP transfer test, signed
  artifact, device install, or Gateway end-to-end request was performed.

Hardware qualification remains a release gate. It does not authorize an agent
to install an app or approve microphone permissions. Retain all source files; no
automatic mobile-copy deletion is implemented while backup policy is undecided.
