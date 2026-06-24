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

- Voice notes, voice-note session lists, persistent media upload/storage,
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

### Accepted Off-Plan Work: Session List Simplification

Commits:

- `0f58806c5 Redesign session list`
- `4e66af302 Organize session list and title generation`

User-facing state:

- The session list now presents a minimal "Tron" first-screen surface
  instead of the older session-card preview layout.
- Sessions are grouped under workspace headers with compact one-line rows.
- Workspace headers have tappable folder/chevron affordances for collapse and
  expansion.
- Session rows show the title, right-aligned last-active time, and compact
  status icons for deleting, processing, forked, and idle states.
- The floating new-session button was preserved and moved into its own view.
- The old workspace style appearance setting was removed as obsolete.

Code organization:

- Session-list projection and presentation moved into
  `SessionList.swift`.
- The floating new-session control moved into
  `FloatingNewSessionButton.swift`.
- `SessionSidebar.swift` is now focused on shell composition, session
  selection, archiving, and sidebar wiring.
- Shared session list layout constants are centralized in
  `SessionListLayout`.

Validated:

- `SessionListPresentationTests` cover the visible title, workspace-group
  projection, compact row behavior, status icon mapping, and archived-session
  filtering.
- The user reviewed the physical-device result and confirmed it looked good.

Deferred:

- No work overview, import tree, source-control graph, or workspace analytics
  was restored. Those remain Phase 2 agent-execution surfaces unless a future
  server-backed contract exists.

### Accepted Off-Plan Work: Native Session Title Generation

Commits:

- `0f58806c5 Redesign session list`
- `4e66af302 Organize session list and title generation`

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
- Focused iOS 26.5 simulator tests for `SessionListPresentationTests`
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
  attachment menu, session list presentation, transcription DTO, and source-guard
  coverage.

### Phase 1 Slice 3: Recent Input History

Commits:

- `16586ae07 Restore local recent input history`
- `3740b33a2 Refine recent input history affordance`
- `ad777a3dd Tighten recent input history rows`
- `0655e7131 Clean up recent input menu naming`
- `d69afc6a1 Rename attachment menu actions`

Review-packet findings:

- The old prompt surface was `IARM-SURFACE-020`, with old paths under retired
  prompt-history view and state folders.
- The old tree had a two-tab prompt-history surface for snippets and searchable,
  paginated history. It depended on old server-backed
  `prompt_library::*` calls and generated management UI for create, update,
  delete, and clear behavior.
- Current code already had local sent-input persistence through
  `InputHistoryStore`, stored in device `UserDefaults` under
  `tron.inputHistory`, capped at 100 entries, with existing add/dedupe/clear
  and navigation tests. The live composer gap was discoverability and
  management, not data capture.
- The approved first-principles slice was recent input history only. Snippets,
  templates, server prompt-history APIs, and command-like routing were left out.

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
- No server prompt-history API, old server prompt-history client, generated management
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
  history/snippet resources, old server prompt-history client,
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
  removed the placeholder entirely, removed the session list/no-selection tagline,
  and deleted the now-dead empty-state sidebar wrapper.
- Final behavior is intentionally quieter than both the old tree and the first
  Slice 4 implementation: after initial load, an empty selected chat renders as
  blank content with the normal shell/navigation/composer affordances only.

Approved and shipped:

- Loading/blank-empty timeline affordance: Slice 4 initially shipped a narrow
  local loading row. The later session list/cockpit placement cleanup removed
  that row at user request. Current loading and empty chat content stays
  visually blank unless current server or local state supplies a real
  user-facing event.
- Connection status is centralized through global `ToastCenter` connection
  notifications. The old in-chat status-pill surface is removed and guarded
  against returning.
- Composer disabled reasons remain accessibility/help-only; no visible disabled
  explanation panel was added.
- Thinking fallback is simplified to one app-owned `NeuralSparkIndicator`.
  The retired configurable theme and alternate animated indicator variants were
  removed. Streaming thinking text still renders inline when supplied by current
  stream state.
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

- Loading/blank-empty state: local iOS load state only; no timeline row or
  explanatory spinner is rendered.
- Connection status: existing engine connection/retry state rendered through
  the app-global toast owner.
- Chat-local errors: local iOS workflow state; not persisted as server events
  and not promoted to backend truth.
- Thinking content: existing stream/thinking state from current server events,
  with a local visual fallback only.
- Capability chip/detail content: existing capability invocation data and
  current server facts already delivered to the iOS timeline.

Rejected or deferred:

- Process/job/subagent/source-control/work session lists, approvals,
  memory/rules/hooks status, skill activation, prompt suggestions, inbox-style
  notifications, fixed product panels, fake activity, and backend status with
  no current source of truth remain absent.
- Notification expansion beyond local errors is deferred until a current
  resource/event owner exists for each notification family.
- Rich connection detail sheets are deferred; global connection toasts remain
  the only visible connection affordance for this slice.

Validated:

- `cd packages/ios-app && xcodegen generate` completed.
- Focused chat loading-row, local-notification, capability evidence, animated
  thinking, invocation detail, messaging coordinator, and source-guard tests
  passed on iPhone 17 Pro, iOS 26.5 simulator before the later loading-row
  removal.
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
  server-health session list or fixed feature index.
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

- Old fixed product session lists, notification inboxes, APNs/device-broker
  behavior, skills/rules/memory/worktree/process/job/goal/subagent/approval
  state, web/research state, source-control surfaces, queue session lists, and
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

### Accepted Follow-Up Work: Cockpit Placement And Session-List Row Polish

Branch:
`codex/ios-cockpit-placement-cleanup-current`

Commits:

- `becbc0e95` - `Clean up iOS cockpit chat placement`
- `34c53dc93` - `Polish iOS session list row glass styling`
- `22cb96e72` - `Fix session list row container press feedback`
- `9d172aa27` - `Use native glass session list rows`
- `0176379ba` - `Align session list header and row columns`

User-facing state:

- The passive Agent cockpit banner was removed from the primary chat surface.
  It had become a prominent idle diagnostics strip rather than an
  attention-worthy chat signal.
- Runtime Cockpit access is retained as an operator/diagnostics surface under
  Settings -> Servers -> Diagnostics. The cockpit sheet was restyled with the
  app's standard liquid-glass sheet chrome and shared segmented tabs.
- Chat loading/empty content remains visually quiet. The temporary
  `Loading messages` spinner row was removed, and empty/loading chat no longer
  renders explanatory timeline content.
- Session-list workspace headers remain larger than session row text, untitled new
  sessions render as `New Session`, and session rows are inset from the screen
  edges.
- The row styling went through two validated corrections. A custom
  content-level glass treatment was first moved to an outer row surface after
  user feedback that the container itself felt static. The final accepted state
  superseded that custom surface with SwiftUI's native interactive liquid-glass
  row behavior so the platform owns container response, hit testing, and touch
  affordance.
- Header and row columns were aligned so the workspace folder icon column lines
  up with row status icons and the workspace title aligns with session titles.

Deferred or explicitly not changed:

- No notification inbox, APNs, device broker, server notification API, durable
  inbox state, agent-execution notification family, worker launch flow, or Phase
  2 agent capability was restored.
- A chat-level runtime signal may return later only for attention-worthy states
  with a real owner, such as approval needed, degraded runtime, or a
  session-relevant active worker. Passive `Idle` diagnostics should not occupy
  chat.
- The Agent cockpit remains a server-fact diagnostics surface pending a future
  first-principles placement review before Phase 2 agent-execution UI.

Validation evidence:

- XcodeGen completed for the touched iOS project after each Swift checkpoint.
- Focused iOS tests on iPhone 17 Pro, iOS 26.5 passed for session list,
  source-guard, chat visual, cockpit state/view-model, and Settings placement
  coverage as appropriate to each checkpoint.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed after plan/progress updates.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture`
  passed after updating the IOSAC proof for diagnostics placement and standard
  cockpit sheet styling.
- `scripts/personal-info-guard.sh`, `git diff --check`, and
  `git ls-files -ci --exclude-standard` passed.
- Simulator/Computer Use validation used the current iPhone 17 Pro, iOS 26.5
  app builds. Screenshot and video evidence was written under the cockpit
  placement and row-polish validation directories in `/tmp/`, covering the
  beta list surface, chat without the cockpit banner, the Runtime Cockpit sheet,
  inset glass rows, row container press feedback, native interactive glass, and
  header/row alignment.

Effect on Phase 1 queue:

- This was accepted off-plan cleanup/polish of existing restored shell surfaces.
  It does not consume or replace Slice 6.

### Accepted Follow-Up Work: Server-Backed Workspace Browser

Branch:
`codex/ios-affordance-restoration-map-current`

User-facing state:

- Tapping the Workspace card in the New Session sheet opens a server-backed
  workspace browser for the paired Mac.
- The selector still starts with useful quick paths: configured quick/default
  workspace, recent session workspaces reconstructed from current cached
  sessions, and server-returned home suggestions.
- The main selector browses directories from the paired Mac through
  `filesystem::get_home` and `filesystem::list_dir`.
- The toolbar hidden-files toggle reloads the current directory with dot
  folders included or excluded.
- The inline New Folder row creates a folder through `filesystem::create_dir`,
  then selects the created folder and dismisses the sheet, matching the old
  useful picker workflow while using current transport/repository ownership.
- The same selector is reused by New Session, onboarding default-workspace
  setup, and Agent settings default-workspace selection.
- Follow-up UI cleanup compacted the selector around filesystem navigation:
  shortcuts are small chips, actions sit above the current path as
  intrinsic-width single-line pills, the hidden-files toggle is an action pill,
  and the current folder is a plain left-aligned path rather than another large
  button/container.

Data ownership:

- Default workspace comes from the existing iOS dependency container value that
  mirrors current server settings.
- Recent workspaces come from current cached session projections via
  `CachedSession.recentWorkspaces`.
- Home path, directory entries, hidden-entry filtering, and folder creation are
  server-owned facts/actions through the narrow `filesystem` workspace-browser
  domain.
- iOS consumes those facts through `WorkspaceBrowserRepository`, so SwiftUI
  surfaces do not depend on concrete transport clients.

Rejected or deferred:

- Restored in the original workspace-browser follow-up:
  `filesystem::get_home`, `filesystem::list_dir`, and
  `filesystem::create_dir`.
- Restored in Phase 2 Slice 4: backend/generic-result filesystem agent
  operations for bounded read/list/find/glob/text search/diff and
  preview-first write/edit/apply-patch under trusted working-directory roots.
- Still deferred: native file/patch review UI, import, worktree, git, and
  broader file-management/product surfaces.
- The `filesystem` domain now has separate workspace-browser and agent-toolbox
  surfaces; it still does not add fixed native product panels.
- No fake validation, fake workspace analytics, import tree, session tree, or
  source-control workspace surface was restored.

Validation evidence:

- Focused validation for this follow-up must include Rust filesystem service
  tests, New Session workspace browser tests, source guards, XcodeGen drift
  check, `ios_affordance_restoration_map_invariants`,
  `baseline_pre_restoration_closure_invariants`, personal-info guard,
  `git diff --check`, and ignored-file checks.
- New-session tests cover default/recent option ordering, trimming,
  deduplication, configured default workspace injection, restored
  workspace-browser markers, and absence of broad old filesystem operations.
- Workspace selector visual render tests cover the compact shortcuts/action
  layout, intrinsic-width action pills, and current-path presentation.

### Phase 1 Slice 6: Notification/Inbox Concept Review

Branch:
`codex/ios-notification-inbox-concept-review-current`

Commit:
`ace41ac98c0003124e2395003ddce12c4bac7b30` -
`Defer iOS notification inbox restoration`

Decision:

- Do not implement a Phase 1 notification/inbox affordance.
- Hold notification and inbox work until Tron restores APNs, server notification
  resources, device delivery, and the agent-facing notification capability
  through the central engine/resource mechanism.
- This is not a permanent rejection of APNs. It rejects only a local Phase 1
  substitute and the old fixed inbox/bell UI before the backend authority exists
  again.

Old evidence inspected:

- `packages/ios-app/Sources/Views/Notifications/NotificationBellButton.swift`
- `packages/ios-app/Sources/Views/Notifications/NotificationListSheet.swift`
- `packages/ios-app/Sources/Views/Notifications/NotificationInboxDetailSheet.swift`
- `packages/ios-app/Sources/Services/NotificationStore.swift`
- `packages/ios-app/Sources/Services/Notifications/GitNotificationRouter.swift`
- `packages/ios-app/Sources/Services/Notifications/PushNotificationService.swift`
- `packages/ios-app/Sources/Services/Infrastructure/APNsEnvironment.swift`
- `packages/ios-app/Sources/Services/Network/Clients/NotificationClient.swift`
- `packages/ios-app/Sources/Models/Messages/NotificationDeliveryTypes.swift`
- `packages/ios-app/Sources/Views/Capabilities/NotificationDelivery/`
- `packages/ios-app/Sources/Views/MessageBubble/NotificationViews.swift`
- `packages/ios-app/Sources/ViewModels/Handlers/ChatNotificationCoordinator.swift`
- Nearby old APNs/device/resource evidence under old `AppDelegate.swift`,
  `packages/ios-app/docs/apns.md`, old notification/APNs tests, and old Rust
  `domains/notifications`, `domains/device`, `platform/apns`, and
  `platform/device_broker` paths.

Review findings:

- The old bell and inbox depended on durable server notification resources,
  unread/read decisions, `notifications::list`, `notifications::mark_read`,
  `notifications::mark_all_read`, app badge clearing, and deep-link auto-open by
  invocation id.
- The old delivery chip depended on `notifications::send`, APNs/device delivery
  evidence, success/failure device counts, and optional Markdown detail content.
- The old APNs path depended on permission prompts, remote notification
  registration, APNs environment detection, device token registration,
  Cloudflare relay configuration, physical-device validation, and server-side
  token invalidation.
- Old message notification pills also included removed skill, rules, memory,
  subagent, worktree, and other agent-execution concepts that do not have
  current Phase 1 owners.
- Current production source has no notification bell, inbox, notification
  client/store, APNs entitlement, remote-notification registration, device-token
  client, notification delivery chip, or notification server API. Current source
  guards intentionally keep those planes absent.
- Direct inspection of the local Tron SQLite database at review time found no
  notification/device/push tables. Current `engine_resources` rows were
  `agent_result` only, so there was no durable notification inbox owner to
  render truthfully.

Current replacements preserved:

- Local chat errors remain temporary `LocalChatNotification` timeline pills.
- App-global connection state remains `ToastCenter`/`ConnectionToastPolicy`.
- Durable session facts remain timeline events reconstructed from current
  server event truth.
- Capability activity remains generic capability evidence chips/details.
- Diagnostics remain Logs, Server Diagnostics, feedback bundles, MetricKit
  payload retention, and local/server log evidence.

Rejected or deferred:

- Rejected for Phase 1: fake unread counts, a local bell badge, placeholder
  notification content, a local-only inbox that implies hidden backend truth,
  notification delivery chips, and old fixed notification categories.
- Deferred to Phase 2/restoration: APNs, background push, device broker
  behavior, `device::register`/`device::unregister`, `notifications::send`,
  `notifications::list`, `notifications::mark_read`,
  `notifications::mark_all_read`, durable notification resources, read-state
  decisions, app badge semantics, and source-control/process/job/subagent/
  approval/web/research/skills/rules/memory notification families.
- No Swift UI, public `/engine` methods, database tables, server settings, APNs
  entitlements, background services, provider/auth/model behavior, or fake
  server health/state were added.

Validated:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed with 7 tests after adding the Slice 6 defer guard.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` returned no tracked ignored files.

Simulator validation:

- Not required. Slice 6 made no Swift or UI changes; the approved outcome was a
  documentation/static-guard decision to defer notification/inbox restoration.

## Phase 1 Closeout

Phase 1 local-native/user-facing affordance restoration is closed after Slices
1-6 and the session-list/cockpit placement cleanup. No remaining Phase 1 slice is queued.
The IARM inventory remains historical coverage evidence, not a live Phase 1
implementation queue.

Closed Phase 1 work:

- Slice 1 restored the functional composer attachment/menu structure without
  restoring old hardcoded skills, server prompt history panels, or agent-execution
  actions.
- Slice 2 restored local composer dictation/audio capture affordances without
  restoring voice-note storage or server transcription orchestration.
- Slice 3 restored local recent-input reuse as the accepted minimal prompt
  history affordance without restoring the old prompt history.
- Slice 4 restored chat visual cues around local errors, thinking, generic
  capability evidence, and quiet empty/loading behavior without restoring stale
  loading rows or fixed product indicators.
- Slice 5 restored settings, onboarding, diagnostics, pairing, provider/model,
  and feedback affordances over current server facts and local support state.
- The session-list/cockpit placement cleanup removed the passive chat worker
  banner, moved Runtime Cockpit access into Servers -> Diagnostics, removed the
  temporary chat loading row, and retained inset liquid-glass interactive
  session rows with `New Session` untitled rows.
- The server-backed workspace browser follow-up restored paired-Mac directory
  navigation, hidden-folder visibility, and folder creation for workspace
  selection without restoring broad agent filesystem tools.
- Slice 6 reviewed notification/inbox affordances and deferred them until a
  server-owned APNs/device/capability resource mechanism exists.
- Phase 2 Slice 5A adds backend durable job/process lifecycle resources and
  `execute` job operations only. It does not restore a native iOS process list,
  log viewer, terminal, PTY, or cancel panel; generic resource/runtime facts
  remain the only iOS-visible foundation until a later server contract and UX
  pass.

Closeout cleanup expectations:

- No old notification bell, local inbox, APNs registration service, device
  broker substitute, unread badge, delivery chip, or fake notification store
  remains in current iOS source.
- No chat-mounted passive worker-runtime banner remains in the primary chat
  shell. Runtime Cockpit remains a settings diagnostics surface until Phase 2
  defines attention-worthy, session-relevant runtime signals.
- No temporary chat timeline loading spinner/text row remains. Empty and
  loading chat content stay visually blank unless current server/local state
  supplies a real user-facing event.
- No custom fallback session list row press implementation remains. Session rows
  use native SwiftUI liquid-glass interactive containers.
- Historical IARM rows remain as evidence and classification records; they are
  not a live queue to implement legacy surfaces by default.

The next planned body of work is the full Phase 2 agent-execution restoration
goal plan, including APNs/device notification capability restoration through the
central engine/resource mechanism.

## Phase 2 Reminder

The full Phase 2 agent-execution restoration plan now lives in
`phase-2-agent-execution-restoration-scorecard.md` after the Phase 1
local/native affordance sequence. It covers capability discovery, filesystem
tools, jobs/processes, worker self-extension, subagents, goals/queues/questions,
approvals, web, git/worktrees, skills/rules/hooks, memory, MCP, scheduling,
program execution, database/events/settings, and dependency restoration.

The work recorded in this ledger does not restore those agent-execution
capabilities.
