# iOS Affordance Restoration Map Evidence Manifest

Branch: `codex/ios-affordance-restoration-map-current`

Old reference: `ad5e484722c6f7abbe764126409494026216ad92`

Baseline: `a0b80c7d204cf9349a5f647ecbc58a8a37735e15`

## Evidence Summary

- The prerequisite emerald restoration was committed before this branch so the
  map starts from a clean IOSAC visual baseline.
- `git diff --name-status ad5e484722c6f7abbe764126409494026216ad92..HEAD --
  packages/ios-app` was used as the old-path source for deleted and renamed iOS
  paths.
- The old-path census found 848 deleted or renamed old iOS paths: 567 source
  paths, 266 tests, 2 docs, and 13 old `.claude/rules` paths.
- The inventory groups all old paths by user-facing affordance or structural
  evidence family; the static gate verifies every old path is covered.
- No Swift source, Xcode project, iOS DTO, server protocol, database migration,
  provider tool, or runtime feature was changed by this goal.

## Failed Attempts And Fixes

- Initial planning risk: treating old iOS directories as a simple Phase 1
  backlog would have mixed current shell plumbing with backend-dependent product
  panels. Fix: the inventory uses `phase1_local_native`,
  `phase1_server_fact`, `phase1_review_only`, `phase2_agent_execution`,
  `superseded_current_shell`, and `reject_candidate` classifications.
- Initial coverage risk: file-by-file TSV rows would be noisy and easy to
  review poorly. Fix: grouped rows are allowed only because the invariant checks
  each deleted or renamed old path against explicit coverage patterns.
- Phase 2 drift risk: deferring agent-loop work could lose the old parity
  backlog. Fix: the map includes a durable Phase 2 anchor and the invariant
  checks the full deferred bucket vocabulary.

## Validation Commands

| Command | Status | Notes |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | passed | 6 tests passed, including artifact wiring, score total, TSV vocabulary, 848 old-path coverage, Phase 2 anchor, and local/GitHub target parity. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | passed | 8 tests passed; pre-restoration backlog and absence guards remain intact. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture` | passed | 11 tests passed; cockpit and emerald theme baseline remain intact. |
| `scripts/personal-info-guard.sh` | passed | Full scan reported no personal-info leaks in source. |
| `git diff --check` | passed | No whitespace errors. |
| `git ls-files -ci --exclude-standard` | passed | No ignored tracked files reported. |

## Historical Handoff

This original map handoff is historical. Its first implementation candidate was
chat composer affordance and menu sheet restoration, with the old input bar,
attachment, skills, prompt, and queue concepts presented as a first-principles
review packet before Swift changes. Phase 1 is now closed; live restoration
state is recorded in `ios-affordance-restoration-progress.md`, and the durable
Phase 2 plan is recorded in the `phase-2-agent-execution-restoration-*`
artifacts.

## Phase 1 Slice 1 Addendum: Composer Attachment / Camera / Native Menu

Commits:

- `473cce8b3 Restore chat attachment camera sheet`
- `62b577047 Refine camera capture glass button`
- `84451c969 Refine camera capture confirmation controls`
- `019f3b9ce Restore native attachment menu`
- `279fafe4e Tighten native attachment menu sizing`
- `d69afc6a1 Rename attachment menu actions`

Scope restored:

- The composer attachment entry point uses a native SwiftUI `Menu`.
- The final functional local actions are Take Photo, Select Photos, and Attach
  Files. Later local-history work may add Recent Inputs only when local history
  exists.
- Take Photo opens the local `CameraCaptureSheet` flow with camera controls,
  captured-photo preview, retake, and use-photo confirmation.
- Select Photos uses SwiftUI `PhotosPicker` for local image selection.
- Attach Files uses the existing local document picker/import path and
  attachment capability limits.
- The final native-menu cleanup renamed the labels without restoring old
  non-functional actions.

Deferred/absent:

- Skills, prompt snippets/templates, queue controls, plugin/catalog concepts,
  prompt-library APIs, generated management surfaces, and old non-functional
  menu actions remain absent.
- No backend/agent coupling, public protocol method, provider-visible tool,
  settings/auth behavior, or database migration was introduced for this slice.
- The discarded custom attachment popup/sheet path is not part of the final
  state.

Slice validation and evidence boundary:

| Command or evidence | Status | Notes |
| --- | --- | --- |
| `AttachmentMenuTests` | source-backed focused coverage | Covers menu action ordering, capability-gated image actions, final labels, native menu construction, and camera sheet construction. |
| `SourceGuardTests` | source-backed focused coverage | Covers native SwiftUI menu preservation, absence of the removed custom attachment sheet, camera presentation invariants, captured-photo preview controls, and source-guarded camera session lifecycle. |
| `IPadSheetPresentationTests` | source-backed focused coverage | Covers the compact camera sheet presentation boundary added with the camera sheet. |
| Simulator validation | bounded | Focused simulator tests/source guards validate the deterministic Slice 1 surface. Real camera capture is not treated as simulator-deterministic hardware validation. |
| Physical-device validation | not claimed | No physical-device manual validation is recorded for Slice 1; later device evidence belongs to other slices and must not be read back onto camera/photo/file picker behavior. |

## Phase 1 Slice 2 Addendum: Composer Voice Transcription

Branch: `codex/ios-voice-dictation-affordance-current`

Scope restored:

- Composer mic affordance returned as a right-side Liquid Glass button next to
  the send/abort control.
- iOS records temporary composer audio, sends it through a repository/client
  boundary, and inserts returned text into the current draft.
- iOS checks `transcription::list_models` before opening the microphone so old
  servers, disabled local transcription, and unloaded sidecars produce
  actionable local messages instead of a generic transcription failure.
- The local transcription runtime now publishes explicit
  disabled/loading/ready/failed state; startup uses a single Parakeet worker by
  default so one ready worker makes the model usable without waiting for a
  second heavyweight worker.
- The server owns an opt-in `transcription` domain with
  `transcription::audio`, `transcription::list_models`, and
  `transcription::download_model`.
- Local transcription uses the restored Parakeet/MLX sidecar boundary under
  `~/.tron/internal/transcription/`, gated by
  `[settings.server.transcription].enabled = false` by default.

Deferred/absent:

- Voice notes, voice-note dashboards, media upload/storage, `MediaClient`,
  backend voice-note resources, APNs/background delivery, fake transcription
  results, and agent-execution voice surfaces remain absent.
- Physical microphone recording initially needed hands-on device validation
  after the first build/install checkpoint. Later in the implementation thread,
  the user confirmed the device-side app behavior looked good. The final
  lifecycle-only cancel patch was test-validated but was not separately
  device-rerun in that thread.

Slice validation:

| Command | Status | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed | Rust formatting clean after applying `cargo fmt`. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | New transcription domain/settings/runtime context compiled; existing provider dead-code warnings remain. |
| `cargo test --manifest-path packages/agent/Cargo.toml transcription --lib` | passed | 7 filtered tests passed, including transcription cleanup, base64 normalization, temp-file cleanup, settings decode, and transcription path helpers. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ChatTranscriptionCoordinatorTests -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/SettingsParityTests` | passed | 28 selected tests passed on iOS 26.5 simulator. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ChatTranscriptionCoordinatorTests` | passed | 9 selected tests passed after adding pre-microphone readiness checks and actionable messages for old-server/disabled transcription states. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | Re-run after adding observable transcription runtime state and single-worker startup; existing provider dead-code warnings remain. |
| `cargo test --manifest-path packages/agent/Cargo.toml transcription --lib` | passed | 8 filtered tests passed after adding shared transcription runtime-state coverage. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ChatTranscriptionCoordinatorTests` | passed | 10 selected tests passed after adding loading-state messaging. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ChatTranscriptionCoordinatorTests -only-testing:TronMobileTests/EngineProtocolTypesTranscriptionTests` | passed | 10 coordinator tests and 2 Swift Testing DTO tests passed after adding optional runtime-state decoding. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests` | passed | 43 source guard tests passed; updated file-count budgets explicitly include transcription client/coordinator tests. |
| authenticated `/engine` probe for `transcription::list_models` on dev server PID 34581 | passed | Live server reported `{"cached":true,"enabled":true,"engineLoaded":true,"state":"ready"}` after restart. |
| `env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta install` | partial | Physical iPhone build and install succeeded for `com.tron.mobile.beta`; launch was denied because the device was locked. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | passed | 6 IARM tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants` | passed | 8 BPRC tests passed after narrowing the old-domain absence guard to allow restored local transcription. |
| `scripts/personal-info-guard.sh` | passed | Full scan reported no personal-info leaks. |
| `git diff --check` | passed | No whitespace errors. |
| `git ls-files -ci --exclude-standard` | passed | No ignored tracked files reported. |
| `env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta install` | passed | Built, installed, and launched `com.tron.mobile.beta` using the generic `TRON_IOS_DEVICE_NAME=iPhone` selector; the physical-device identifier is intentionally not recorded. Post-launch status later reported not running. |
