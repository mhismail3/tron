# iOS Affordance Restoration Progress Ledger

Status: `active`

Last reconciled from implementation threads:

- `019ecf5d-c3ca-7062-94ed-4cc636441cfe`
- `019ed6d5-c564-7e20-89b2-d7d2e7a74c3a`

Implementation branch:
`codex/ios-prompt-input-snippet-affordance-current`

Implementation worktree:
`/Users/<USER>/.codex/worktrees/0ecf/tron`

Merged baseline:
`84451c969 Refine camera capture confirmation controls`

Merged checkpoint:
`d69afc6a16d7d89e05a1eca54167a94065a48449 Rename attachment menu actions`

Previous merged checkpoint:
`4e66af3022508b13a6229020d529ee248e49c5a5 Organize dashboard and title generation`

## Purpose

This ledger records what actually shipped while executing the early Phase 1
iOS affordance restoration slices. It supplements the source-backed
`ios-affordance-restoration-map-*` artifacts by tracking completed slices,
off-plan but accepted work, user-facing behavior, validation evidence, and
remaining backlog.

The canonical map remains the planning authority. This progress ledger records
execution state so future implementation threads do not need to reconstruct it
from chat history.

## Completed Work

### Phase 1 Slice 2: Composer Voice Transcription

Commits:

- `c5f92eed3 Restore composer voice transcription`
- `ec3428283 Gate composer transcription on local readiness`
- `abd396897 Harden local transcription readiness`
- `e095249be Cancel voice recording on chat exit`

User-facing state:

- The chat composer has a microphone affordance next to the send/abort control.
- When local transcription is enabled and ready, tapping the mic records
  temporary composer audio and inserts the returned transcript into the current
  draft.
- Before opening the microphone, iOS asks the server for
  `transcription::list_models`; old servers, disabled transcription, loading
  sidecars, and failed sidecars produce local actionable messages instead of a
  generic recording failure.
- Leaving chat cancels any active composer recording before the live session is
  torn down.

Server and protocol state:

- The agent now has an opt-in `transcription` domain with
  `transcription::audio`, `transcription::list_models`, and
  `transcription::download_model`.
- Local transcription is disabled by default in profile settings and is backed
  by the Parakeet/MLX sidecar boundary under
  `~/.tron/internal/transcription/`.
- The runtime reports explicit `disabled`, `loading`, `ready`, and `failed`
  states. The default startup path uses one worker so a single ready worker is
  sufficient for availability.
- iOS has typed transcription DTOs, a `TranscriptionClient`, dependency
  injection wiring, a `ChatTranscriptionCoordinator`, and settings parity for
  the local transcription toggle.

Validated:

- Rust formatting, `cargo check`, and filtered transcription Rust tests passed
  in the implementation thread.
- Focused iOS transcription coordinator, transcription DTO, settings parity,
  and source-guard tests passed on the iOS 26.5 simulator.
- `ios_affordance_restoration_map_invariants`,
  `baseline_pre_restoration_closure_invariants`,
  `scripts/personal-info-guard.sh`, `git diff --check`, and
  `git ls-files -ci --exclude-standard` passed in the implementation thread.
- A live authenticated `/engine` probe reported local transcription ready:
  `{"cached":true,"enabled":true,"engineLoaded":true,"state":"ready"}`.
- A physical iPhone beta install/launch completed, and the user later confirmed
  the app-side behavior looked good on device. The final lifecycle-only cancel
  patch was validated by tests but was not separately device-rerun in that
  implementation thread.

Deferred:

- Voice notes, voice-note dashboards, persistent media upload/storage,
  `MediaClient`, backend voice-note resources, APNs/background delivery, fake
  transcription, and agent-execution voice surfaces remain absent.
- Local transcription remains opt-in. If the setting is enabled after the
  server has started, broader on-demand sidecar loading is not yet implemented;
  a server restart may still be required for the local runtime to become ready.

### Phase 1 Slice 1 Follow-Up: Native Attachment Menu

Commits:

- `019f3b9ce Restore native attachment menu`
- `279fafe4e Tighten native attachment menu sizing`
- `d69afc6a1 Rename attachment menu actions`

User-facing state:

- The composer plus button now opens a native SwiftUI `Menu`.
- The menu exposes only currently functional local actions: Take Photo, Select
  Photos, and Attach Files.
- Menu rows use native icon-and-text presentation with compact sizing.
- The removed custom attachment sheet path is gone.

Validated:

- `AttachmentMenuTests` cover the expected native menu labels and absence of
  non-functional old actions.
- Composer keyboard source guards assert the menu does not force-focus changes
  or reintroduce the removed custom popup/sheet path.

Deferred:

- Skills, prompt snippets, queue controls, plugin/catalog concepts, and other
  old attachment-menu actions remain absent until reviewed and approved as
  separate slices.
- The custom morphing popup explored during the thread was intentionally
  discarded; it is not part of the final state.

### Accepted Off-Plan Work: Session Dashboard Simplification

Commits:

- `0f58806c5 Redesign session dashboard`
- `4e66af302 Organize dashboard and title generation`

User-facing state:

- The session dashboard now presents a minimal "Tron" first-screen surface
  instead of the older session-card preview layout.
- Sessions are grouped under workspace headers with compact one-line rows.
- Workspace headers have tappable folder/chevron affordances for collapse and
  expansion.
- Session rows show the title, right-aligned last-active time, and compact
  status icons for deleting, processing, forked, and idle states.
- The floating new-session button was preserved and moved into its own view.
- The old workspace style appearance setting was removed as obsolete.

Code organization:

- Dashboard projection and presentation moved into
  `SessionDashboard.swift`.
- The floating new-session control moved into
  `FloatingNewSessionButton.swift`.
- `SessionSidebar.swift` is now focused on shell composition, session
  selection, archiving, and sidebar wiring.
- Shared dashboard layout constants are centralized in
  `SessionDashboardLayout`.

Validated:

- `SessionDashboardPresentationTests` cover the visible title, workspace-group
  projection, compact row behavior, status icon mapping, and archived-session
  filtering.
- The user reviewed the physical-device result and confirmed it looked good.

Deferred:

- No work dashboard, import tree, source-control graph, or workspace analytics
  was restored. Those remain Phase 2 agent-execution surfaces unless a future
  server-backed contract exists.

### Accepted Off-Plan Work: Native Session Title Generation

Commits:

- `0f58806c5 Redesign session dashboard`
- `4e66af302 Organize dashboard and title generation`

User-facing state:

- New sessions can receive a short model-generated title after the first user
  message is durably persisted.
- Title changes are emitted through the existing `session_updated` path so the
  current iOS session list updates through normal event reconstruction.

Server behavior:

- Title generation is implemented in the current Rust runtime service instead
  of restoring the old `builtin:title-gen` hook/subagent path.
- The request/dependency/job boundary is explicit through
  `SessionTitleGenerationRequest` and its dependencies.
- The generator sanitizes output, bounds title length, rechecks session state
  before writing, and is registered with shutdown coordination.
- The race discovered during device testing was fixed by checking that the
  session still has exactly one user message, rather than relying on total
  message count.

Validated:

- Filtered Rust `title_generation` tests passed in the implementation thread.
- The dev server was restarted from the implementation worktree after stale
  server binary behavior initially hid the new title generator.

Deferred:

- Existing sessions are not backfilled.
- Title generation does not restore old hooks, skills, rules, or subagent
  machinery.
- A future title-management affordance should be reviewed separately if users
  need editing, pinning, or title provenance controls.

## Session-Level Validation Summary

The implementation thread reported these final closeout checks as passing:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
- `cargo test --manifest-path packages/agent/Cargo.toml title_generation --lib -- --nocapture`
- Focused iOS 26.5 simulator tests for `SessionDashboardPresentationTests`
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
- `scripts/personal-info-guard.sh`
- `git diff --check`
- `git ls-files -ci --exclude-standard`
- deterministic `xcodegen generate` project check

Earlier slice-specific implementation checkpoints also passed focused
transcription, settings, source-guard, attachment-menu, and BPRC/IARM static
gates as recorded in
`ios-affordance-restoration-map-evidence-manifest.md`.

This orchestration checkout re-ran the following after fast-forwarding the
implementation branch and adding this ledger:

- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed with 6 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml transcription --lib -- --nocapture`
  passed with 8 filtered tests.
- `cargo test --manifest-path packages/agent/Cargo.toml title_generation --lib -- --nocapture`
  passed with 7 filtered tests.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` returned no tracked ignored files.
- `cd packages/ios-app && xcodegen generate` produced no
  `TronMobile.xcodeproj` drift.
- Focused `xcodebuild test` on iPhone 17 Pro, iOS 26.5 passed with 20 XCTest
  cases and 47 Swift Testing source-guard cases across transcription,
  attachment menu, dashboard presentation, transcription DTO, and source-guard
  coverage.

### Phase 1 Slice 3: Recent Input History

Commits:

- `16586ae07 Restore local recent input history`
- `3740b33a2 Refine recent input history affordance`
- `ad777a3dd Tighten recent input history rows`
- `0655e7131 Clean up recent input menu naming`
- `d69afc6a1 Rename attachment menu actions`

Review-packet findings:

- The old prompt surface was `IARM-SURFACE-020`, with old paths under
  `packages/ios-app/Sources/Views/PromptLibrary/` and
  `packages/ios-app/Sources/ViewModels/State/PromptLibraryState.swift`.
- The old tree had a two-tab Prompt Library for snippets and searchable,
  paginated prompt history. It depended on old server-backed
  `prompt_library::*` calls and generated management UI for create, update,
  delete, and clear behavior.
- Current code already had local sent-input persistence through
  `InputHistoryStore`, stored in device `UserDefaults` under
  `tron.inputHistory`, capped at 100 entries, with existing add/dedupe/clear
  and navigation tests. The live composer gap was discoverability and
  management, not data capture.
- The approved first-principles slice was recent input history only. Snippets,
  templates, server prompt-library APIs, and command-like routing were left out.

User-facing state:

- The chat composer exposes Recent Inputs as an option in the native attachment
  menu only when local sent-input history exists and the session is
  idle/editable.
- The Recent Inputs sheet lists device-local sent text prompts. Tapping a row
  inserts that text into the current composer draft.
- The sheet includes an icon-only local clear action that removes the
  device-local history payload.
- The row presentation was refined after simulator review: larger text,
  divider-free rows, two-line maximum previews, and tighter vertical padding.
- The original attachment actions were renamed for clearer commands:
  Attach Files, Select Photos, and Take Photo.

Superseded intermediate work:

- A standalone Recent Inputs composer button was explored during the slice and
  then removed. The final approved entry point is the native attachment menu so
  the composer row stays compact.
- Stale helper names left over from the standalone-button shape were removed in
  `0655e7131`; the source now describes the feature as a menu action.

Data ownership and privacy:

- Recent input history remains owned by iOS local workflow state through
  `InputHistoryStore`.
- The store uses the existing `tron.inputHistory` `UserDefaults` payload,
  dedupes entries, and caps retention at 100 sent text prompts.
- No prompt-library server API, `PromptLibraryClient`, generated management
  surface, skill activation, queueing, prompt routing, subagent behavior, or
  fixed template catalog was restored.

Validated:

- `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/RecentInputHistoryTests -only-testing:TronMobileTests/InputHistoryStoreTests -only-testing:TronMobileTests/AttachmentMenuTests -only-testing:TronMobileTests/SourceGuardTests`
  passed on iOS 26.5 simulator with 32 XCTest cases and 46 Swift Testing
  source-guard cases.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed with 6 tests.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` returned no tracked ignored files.
- `cd packages/ios-app && xcodegen generate` completed without unintended
  `TronMobile.xcodeproj` drift.
- The current simulator app bundle was explicitly installed and launched on
  iPhone 17 Pro, iOS 26.5, paired to the local development server. Manual
  simulator validation confirmed the composer no longer shows a standalone
  recent-input button, the native attachment menu exposes Recent Inputs above
  Attach Files/Select Photos/Take Photo when local history exists, and the
  Recent Inputs sheet uses larger, concise, divider-free row text with an
  icon-only destructive clear action.
- Simulator evidence screenshots were saved under
  `/tmp/tron-ios-affordance-validation/`:
  `recent-inputs-attachment-menu.png`, `recent-input-sheet.png`,
  `recent-input-inserted.png`, `recent-inputs-sheet-icon-clear-large-font.png`,
  `recent-inputs-sheet-divider-free.png`,
  `recent-inputs-sheet-concise-rows.png`, and
  `attachment-menu-renamed-actions.png`.

Deferred:

- User-authored local snippets and manually defined local templates remain
  review-only follow-ups. They are not scheduled in the current Phase 1 queue;
  revisit only if the user explicitly wants another local-native composer
  affordance after higher-priority Phase 1 slices.
- Search, pagination, use counts, last-used metadata, server-owned prompt
  history/snippet resources, old `PromptLibraryClient`,
  `prompt_library::*` methods, generated prompt-management surfaces, skill
  activation, prompt queues, slash-command-like suggestions, and
  agent-execution routing remain absent until a future approved
  Phase 2/current-resource design exists.

## Phase 1 Slice 4: Chat Visual Cues, Status, And Error Affordances

Branch:
`codex/ios-chat-visual-cues-status-affordance-current`

Approved and shipped:

- Loading/blank-empty timeline affordance: `ChatTimelineAuxiliaryState`
  derives `Loading messages` only before initial load completes. Once initial
  load completes, a chat with no messages stays visually blank.
- Connection status is centralized through global `ToastCenter` connection
  notifications. The old in-chat `ConnectionStatusPill` surface is removed and
  guarded against returning.
- Composer disabled reasons remain accessibility/help-only; no visible disabled
  explanation panel was added.
- Thinking fallback is simplified to one app-owned `NeuralSparkIndicator`.
  `ThinkingIndicatorStyle`, `PhaseWaveIndicator`, and
  `OrbitingParticleIndicator` were removed. Streaming thinking text still
  renders inline when supplied by current stream state.
- Chat-scoped local failures route through a central paved path:
  `ChatViewModel+Errors.swift` appends deduped ephemeral
  `LocalChatNotification` timeline items, clears them on new sends/view exit,
  and opens `LocalErrorDetailSheet` only when details exist.
- Initial local error producers include generic fatal chat errors, server send
  and retry failures, capability abort failure, model switch failure, message
  delete failure, transcription failure/no speech, photo processing failure,
  file-read failure, and file-too-large validation.
- Capability invocation chat chips now use
  `CapabilityEvidencePresentation`: inline chips are one line and details move
  to a sectioned sheet with summary, target/input/result/error, and technical
  provenance only when current invocation data provides it.

Data ownership:

- Loading/blank-empty state: local iOS timeline state only.
- Connection status: existing engine connection/retry state rendered through
  the app-global toast owner.
- Chat-local errors: local iOS workflow state; not persisted as server events
  and not promoted to backend truth.
- Thinking content: existing stream/thinking state from current server events,
  with a local visual fallback only.
- Capability chip/detail content: existing capability invocation data and
  current server facts already delivered to the iOS timeline.

Rejected or deferred:

- Process/job/subagent/source-control/work dashboards, approvals,
  memory/rules/hooks status, skill activation, prompt suggestions, inbox-style
  notifications, fixed product panels, fake activity, and backend status with
  no current source of truth remain absent.
- Notification expansion beyond local errors is deferred until a current
  resource/event owner exists for each notification family.
- Rich connection detail sheets are deferred; global connection toasts remain
  the only visible connection affordance for this slice.

Validated:

- `cd packages/ios-app && xcodegen generate` completed.
- `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ChatTimelineAuxiliaryStateTests -only-testing:TronMobileTests/LocalChatNotificationTests -only-testing:TronMobileTests/CapabilityEvidencePresentationTests -only-testing:TronMobileTests/AnimatedThinkingLineTests -only-testing:TronMobileTests/CapabilityInvocationDetailViewTests -only-testing:TronMobileTests/MessagingCoordinatorTests -only-testing:TronMobileTests/SourceGuardTests`
  passed on iPhone 17 Pro, iOS 26.5 simulator.
- `TRON_VISUAL_ARTIFACT_DIR=/tmp/tron-ios-affordance-validation/slice4 xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ChatAffordanceVisualRenderTests -only-testing:TronMobileTests/CapabilityInvocationDetailViewTests`
  passed on iPhone 17 Pro, iOS 26.5 simulator. The test runner wrote to the
  simulator container, then the PNGs were copied to
  `/tmp/tron-ios-affordance-validation/slice4/`:
  `chat-normal.png`, `chat-loading.png`,
  `chat-local-error-pill.png`, `chat-thinking-neural-spark.png`,
  `chat-capability-chip.png`, `chat-connection-toast.png`, and
  `capability-invocation-detail-action-render.png`.

## Remaining Phase 1 Queue

The next recommended restoration slice is `phase1_slice_5`: settings,
onboarding, diagnostics, and pairing polish over current server facts.

Later Phase 1 items remain:

- `phase1_slice_6`: notification/inbox concept review only if it can remain
  truthful without fake push state.
- Remaining local-native affordance families from the inventory after review.

## Phase 2 Reminder

The full Phase 2 agent-execution restoration plan is still required after the
Phase 1 local/native affordance sequence. It must cover capability discovery,
filesystem tools, jobs/processes, worker self-extension, subagents,
goals/queues/questions, approvals, web, git/worktrees, skills/rules/hooks,
memory, MCP, scheduling, program execution, database/events/settings, and
dependency restoration.

The work recorded in this ledger does not restore those agent-execution
capabilities.
