# iOS Affordance Restoration Progress Ledger

Status: `active`

Last reconciled from implementation threads:

- `019ecf5d-c3ca-7062-94ed-4cc636441cfe`
- `019ed6d5-c564-7e20-89b2-d7d2e7a74c3a`
- `019ed71f-a1c5-7451-a026-8ddbc664ffda`

Latest implementation branch:
`codex/ios-settings-onboarding-diagnostics-pairing-current`

Latest implementation worktree:
`/Users/<USER>/.codex/worktrees/f028/tron`

Current orchestration checkpoint:
`f4cb11d68 Reconcile chat visual affordance progress`

Previous orchestration checkpoint:
`09d155bda Remove empty chat placeholder`

Previous implementation checkpoint:
`09d155bda Remove empty chat placeholder`

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

Commits:

- `bb9057148 Restore chat visual affordances`
- `09d155bda Remove empty chat placeholder`

Session analysis:

- The delegated thread first completed a review packet and stopped for user
  approval. It found that several old visual/status surfaces were already
  present or migrated under current owners, including thinking rendering,
  capability status/error rendering, turn failure notifications, and global
  connection toasts.
- The user approved a narrow implementation register: loading state, connection
  centralization, no visible composer-disabled microcopy, one thinking fallback,
  paved local error notifications, and compact capability evidence.
- The first implementation commit included a minimal empty-chat `Start talking`
  placeholder. The user rejected that final visual shape. The follow-up commit
  removed the placeholder entirely, removed the dashboard/no-selection tagline,
  and deleted the now-dead empty-state sidebar wrapper.
- Final behavior is intentionally quieter than both the old tree and the first
  Slice 4 implementation: after initial load, an empty selected chat renders as
  blank content with the normal shell/navigation/composer affordances only.

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
- After the placeholder removal, the implementation thread reran
  `xcodegen generate`, the focused chat affordance Swift tests, rebuilt and
  reinstalled the final app bundle on the iPhone 17 Pro simulator, verified
  the blank content area through Computer Use, and reran final repository
  guards.
- Final closeout reported `scripts/personal-info-guard.sh`, `git diff --check`,
  `git ls-files -ci --exclude-standard`, and clean `git status` as passing.

Additional orchestration observations:

- A live gpt-5.5 session showed hidden reasoning tokens without visible
  provider-returned thinking summary content. The existing thinking block path
  is still intact and recently produced visible thinking in another gpt-5.5
  session; future UI should not fake unavailable chain-of-thought. A later
  diagnostics/metadata polish slice may truthfully surface "reasoning used,
  summary unavailable" when token records show reasoning output but no thinking
  block exists.
- iOS logs currently treat an empty live `agent.thinking_end` payload as an
  unknown event. That did not suppress useful content in the observed session,
  but a future diagnostics/event-polish pass should either normalize the live
  event to the retained `stream.thinking_complete` model or suppress empty
  thinking-end chatter.

## Phase 1 Slice 5: Settings, Onboarding, Diagnostics, And Pairing Polish

Branch:
`codex/ios-settings-onboarding-diagnostics-pairing-current`

Implementation state:

- The delegated thread first produced a source-backed review packet for
  `IARM-SURFACE-010`, `IARM-SURFACE-017`, and `IARM-SURFACE-018`, then paused
  for UI/UX approval before implementation.
- The approved design kept server-health detail inside the Server page or the
  disconnected Settings card, kept model/provider/auth state inside Agent and
  Providers, retained the existing footer feedback button, and added only a
  minimal Diagnostics section.
- After implementation review, the user requested one standardized
  onboarding/connect presentation. The final state routes first-run setup,
  Server-page pairing/repair, and pairing URLs through the same
  `OnboardingFlowView` and `OnboardingSheetPresentation` large-detent policy.

User-facing state:

- Settings main remains a compact launcher grid. It does not grow a
  server-health dashboard or fixed feature index.
- The Server page remains the owner for paired-server identity, reachability,
  runtime-evidence settings, pairing/reconnect/forget controls, and the new
  minimal Diagnostics section. Diagnostics exposes one Logs row with compact
  copy explaining local redacted logs and automatic server sync while
  connected.
- The Logs sheet text now says local entries and server sync, avoiding a false
  implication that the sheet browses canonical server logs.
- Agent settings now surfaces `server.defaultProvider` beside default model and
  workspace. Known provider ids render friendly labels; unknown server-returned
  provider ids stay visible as server ids instead of being replaced with fake
  assumptions.
- Onboarding preparation copy is shorter and action-oriented. Server
  Settings-launched repair for an already paired server closes after a
  successful token refresh when the host and port still match; edited origins
  continue as fresh pairing and setup.
- Feedback remains the existing Settings footer action. With no configured
  recipient, it shows the existing local alert instead of opening a send flow.

Data ownership:

- Settings values: existing `settings::get`, `settings::update`, and
  `settings::reset` snapshots through `SettingsState` and the settings
  repository boundary.
- Provider/model/auth presentation: existing settings snapshot, model list, and
  masked auth state; no local provider truth is invented.
- Server identity and reachability: local paired-server store plus current
  engine connection state.
- Pairing: local pairing form state, strict local host validation, Keychain
  token storage, existing pairing probe, and current settings/auth hydration.
- Diagnostics/logs: bounded local iOS logs, existing client-log ingestion to
  server logs while connected, and existing feedback bundle assembly.

Rejected or deferred:

- Old fixed product dashboards, notification inboxes, APNs/device-broker
  behavior, skills/rules/memory/worktree/process/job/goal/subagent/approval
  state, web/research state, source-control surfaces, queue dashboards, and
  placeholder backend facts remain absent.
- No new public `/engine` method, server setting, database table, provider
  behavior, auth behavior, background service, or fake server-health fact was
  added.
- Legacy setup/settings concepts are not permanently banned, but they remain
  deferred until a current server/resource owner exists and the user approves a
  specific modern design.

Validated:

- `cd packages/ios-app && xcodegen generate` completed after adding
  `OnboardingFlowPresentation.swift`.
- Focused iOS 26.5 simulator tests passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/SettingsParityTests -only-testing:TronMobileTests/ServerSettingsPageTests -only-testing:TronMobileTests/ProvidersSettingsPageTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests -only-testing:TronMobileTests/OnboardingStateTests -only-testing:TronMobileTests/OnboardingFlowLayoutTests -only-testing:TronMobileTests/IPadSheetPresentationTests -only-testing:TronMobileTests/SourceGuardTests -quiet`.
- Computer Use validation on iPhone 17 Pro, iOS 26.5 confirmed Settings main,
  Server reachability, Server Diagnostics, Logs from Server Diagnostics,
  Agent provider/model defaults, feedback unconfigured alert, and the
  standardized large Server-launched pairing sheet. Screenshot evidence lives
  under `/tmp/tron-ios-affordance-validation/slice5/`, including
  `settings-main-beta.png`, `server-page-connected-beta.png`,
  `server-diagnostics-bottom-beta.png`,
  `logs-from-server-diagnostics-beta.png`,
  `agent-provider-model-beta.png`, `feedback-unconfigured-alert-beta.png`, and
  `pairing-connect-large-centralized-beta.png`.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed with 6 tests.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` returned no tracked ignored files.

### Accepted Off-Plan Work: Agent Cockpit Placement Cleanup

Branch:
`codex/ios-cockpit-placement-cleanup-current`

Implementation state:

- The Agent cockpit was originally added in IOSAC commit `9e97759dc` as a
  proof/user-facing shell for current worker lifecycle catalog facts, package
  lifecycle evidence, activity, and generated runtime `ui_surface` resources.
- That proof placed a compact status capsule above chat so the new sheet could
  be discovered while the cockpit baseline was being validated.
- Product review found the passive chat placement too prominent and
  counterintuitive for current behavior: the primary conversation could show
  `Idle / No active workers published yet` while the sheet showed zero workers
  and many functions.

User-facing state:

- The primary chat UI no longer mounts the passive Agent cockpit/status banner.
- Chat session load and reconnect paths no longer refresh cockpit data just to
  keep hidden or passive chrome current.
- The cockpit implementation remains available from Settings -> Servers ->
  Diagnostics -> Runtime Cockpit. Opening that row presents the existing
  `AgentCockpitSheet`, which refreshes current server facts on demand and now
  uses the same liquid-glass sheet chrome, typography, and shared segmented tab
  control as current app sheets.

Data ownership:

- The cockpit remains a diagnostics/operator surface over current
  `WorkerLifecycleRepository`, catalog, resource, and runtime-surface facts.
- No server primitive, public `/engine` route, database table, setting,
  APNs/push behavior, notification inbox, agent-execution capability, worker,
  subagent, skill/rule/memory surface, source-control panel, or fake backend
  truth was added.

Deferred:

- Phase 2 agent-execution UI still needs a first-principles placement review.
- A chat-level agent signal may return only for attention-worthy states such as
  approval needed, degraded runtime, an active session-relevant worker, or a
  generated surface requiring user action.
- Passive `Idle` worker-runtime diagnostics must not occupy chat.

Validation commands for this checkpoint:

- `cd packages/ios-app && xcodegen generate`
- `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SessionDashboardPresentationTests -only-testing:TronMobileTests/ChatAffordanceVisualRenderTests -only-testing:TronMobileTests/AgentCockpitStateTests -only-testing:TronMobileTests/AgentCockpitViewModelTests -only-testing:TronMobileTests/ServerSettingsPageTests -only-testing:TronMobileTests/SourceGuardTests`
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture`
- `scripts/personal-info-guard.sh`
- `git diff --check`
- `git ls-files -ci --exclude-standard`

Validated:

- `cd packages/ios-app && xcodegen generate` passed.
- The first focused iOS test run caught a stale source guard that still expected
  the old `showLogViewer` boolean on the Servers page. After updating that
  guard to the new enum-backed diagnostics sheet route, the same focused
  command passed on iPhone 17 Pro, iOS 26.5, with 6 selected XCTest cases and
  77 Swift Testing cases. After restyling the cockpit sheet to use standard
  liquid-glass sheet chrome and shared `TronSegmentedControl` tabs, the same
  focused command passed again with the same selected test coverage.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed with 6 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture`
  passed with 11 tests after updating the IOSAC static proof for diagnostics
  placement and standard cockpit sheet styling.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` returned no tracked ignored files.
- Simulator/Computer Use validation used the current Beta bundle
  `com.tron.mobile.beta` on iPhone 17 Pro, iOS 26.5. It confirmed the dashboard
  still shows larger workspace headers, interactive row backgrounds, and
  `New Session` for the untitled row; chat no longer shows the passive cockpit
  banner; Servers -> Diagnostics exposes `Runtime Cockpit`; and the row opens
  the liquid-glass cockpit sheet with shared segmented tabs and no text overlap.
  Screenshot evidence:
  `/tmp/tron-ios-cockpit-placement-validation/ui/01-beta-dashboard.png`,
  `/tmp/tron-ios-cockpit-placement-validation/ui/02-beta-chat-no-cockpit-banner.png`,
  and
  `/tmp/tron-ios-cockpit-placement-validation/ui/03-beta-runtime-cockpit-sheet.png`.

### Accepted Follow-Up Work: Dashboard Session Row Liquid Glass

Branch:
`codex/ios-cockpit-placement-cleanup-current`

User-facing state:

- Session dashboard rows now render as inset liquid-glass row containers instead
  of edge-to-edge flat interactive backgrounds.
- The row containers use the existing `sectionFill` liquid-glass helper with
  restrained emerald stroke/shadow and pressed-state feedback.
- Existing dashboard behavior remains intact: workspace headers stay larger
  than session rows, rows remain compact and one-line, and untitled sessions
  still display as `New Session`.

Validation commands for this checkpoint:

- `cd packages/ios-app && xcodegen generate`
- `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SessionDashboardPresentationTests -only-testing:TronMobileTests/SourceGuardTests`
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
- `scripts/personal-info-guard.sh`
- `git diff --check`
- `git ls-files -ci --exclude-standard`

Validated:

- `cd packages/ios-app && xcodegen generate` passed.
- The focused iOS run first caught one stale source-guard string for the new row
  inset constant wiring. After correcting the guard to assert the actual
  `rowInsets` contract, `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SessionDashboardPresentationTests -only-testing:TronMobileTests/SourceGuardTests`
  passed with 5 selected XCTest cases and 51 Swift Testing source-guard cases.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed with 6 tests.
- Simulator/Computer Use validation used the current Beta bundle
  `com.tron.mobile.beta` on iPhone 17 Pro, iOS 26.5. It confirmed the dashboard
  rows are inset from the screen edges, render as liquid-glass containers, keep
  `New Session` text legible, and still open the selected chat on tap.
  Screenshot evidence:
  `/tmp/tron-ios-dashboard-row-glass-validation/ui/01-dashboard-inset-glass-rows.png`
  and
  `/tmp/tron-ios-dashboard-row-glass-validation/ui/02-dashboard-after-row-tap.png`.

## Remaining Phase 1 Queue

The next recommended restoration slice is `phase1_slice_6`: notification/inbox
concept review only if it can remain truthful without fake push state.

Recommended Slice 6 starting scope:

- Start with a review packet, not implementation.
- Inspect `IARM-SURFACE-019` and old evidence paths:
  `packages/ios-app/Sources/Views/Notifications/`,
  `packages/ios-app/Sources/Services/NotificationStore.swift`,
  `packages/ios-app/Sources/Services/Notifications/`,
  `packages/ios-app/Sources/Views/Capabilities/NotificationDelivery/`,
  `packages/ios-app/Sources/Views/MessageBubble/NotificationViews.swift`, and
  `packages/ios-app/Sources/ViewModels/Handlers/ChatNotificationCoordinator.swift`.
- Compare only against current truthful sources: local in-app notifications,
  toast/local error state, existing timeline events, existing diagnostics/log
  surfaces, and current server facts already delivered to the app.
- Treat APNs, device-broker delivery, background push, server notification
  resources, notification send/list/mark-read APIs, durable inbox state, and
  agent-execution notification families as Phase 2 unless a current owner
  exists in source.
- Evaluate three possible outcomes explicitly: reject the old inbox concept,
  defer it wholly to Phase 2, or approve a smaller local-only attention surface
  that consolidates already-visible local errors/status events without creating
  fake backend truth.
- Ask the user whether a notification/inbox affordance is still useful in the
  long-term self-adapting-agent UI now that chat has local error pills, global
  connection toasts, Server Diagnostics, feedback, and logs.
- Required validation if implementation is approved: focused Swift tests for
  local notification state and visibility rules, source guards against APNs and
  server notification API resurrection, iOS 26.5 simulator screenshots for the
  approved visible states, `xcodegen generate` when Swift files change,
  `ios_affordance_restoration_map_invariants`, `scripts/personal-info-guard.sh`,
  `git diff --check`, `git ls-files -ci --exclude-standard`, and clean status.

After Slice 6 is reviewed, the Phase 1 map should be closed out by checking for
any remaining local-native affordance families in the inventory. If none remain,
the next major planning step is the full Phase 2 agent-execution restoration
goal plan.

## Phase 2 Reminder

The full Phase 2 agent-execution restoration plan is still required after the
Phase 1 local/native affordance sequence. It must cover capability discovery,
filesystem tools, jobs/processes, worker self-extension, subagents,
goals/queues/questions, approvals, web, git/worktrees, skills/rules/hooks,
memory, MCP, scheduling, program execution, database/events/settings, and
dependency restoration.

The work recorded in this ledger does not restore those agent-execution
capabilities.
