# iOS App Architecture

> Last verified: 2026-06-27 (Phase 3 Slice 23H Runtime Cockpit module activity implementation candidate added; Phase 2 Slice 1 Runtime Cockpit catalog discovery added; Phase 2 Agent Execution Restoration planning scorecard added; IARM Phase 1 Slice 6 notification/inbox concept deferred to APNs/server capability restoration; IARM Phase 1 dashboard/cockpit closeout; IARM Phase 1 Slice 5 settings/onboarding/diagnostics/pairing polish; IARM Phase 1 Slice 4 chat visual cues/status affordance restoration; IARM-9 iOS Affordance Restoration Map; IOSAC-10 self-adapting Agent cockpit baseline; IOSTC-10 thin-client generic runtime shell; SACB-9 pairing lifecycle; SACB-8 secret custody/redaction; CSD-10 concurrency scheduling discipline; DRC-9 replay manifest/event parity retained).

## Overview

**Minimum iOS**: 26.0

The iOS app is a SwiftUI `/engine` client. In the current primitive baseline it
is intentionally a shell: it pairs with a local Tron server, sends prompts,
keeps a clearable local recent-input history for composer reuse, records
composer mic input for opt-in local transcription, renders session
messages, persists a local event cache for reconstruction, and renders generic
runtime surfaces emitted by the engine. The current user-facing Agent cockpit is
a diagnostics surface opened from Servers -> Diagnostics -> Runtime Cockpit. It
surfaces live worker lifecycle catalog entries, capability discovery families,
schema/health gaps, durable `catalog_discovery_report` history,
package/resource status, confirmation-backed lifecycle actions, activity, and
active `ui_surface` resources without adding fixed product panels. The Activity
tab renders the server-owned, invocation-scoped `module_activity::overview`
projection instead of fabricating catalog/package activity locally. Cockpit
refresh failures render as
degraded while preserving the last good server facts, and malformed catalog
entries surface catalog decode degradation instead of
being silently omitted from counts or verified/no-catalog summaries. The app
does not own
repository-specific panels, media workflow surfaces, saved voice notes,
assistant-management panels, extension-source surfaces, memory-retain, or rules.

The Rust server remains authoritative for provider communication, session/event
truth, model routing, execution, state, logs, and generated runtime data. iOS
may cache and render server facts, but it must not invent capability policy,
source-control state, worker state, or product panels locally.

Notification and inbox affordances remain deferred in the current Phase 1
shell. Local chat error pills, app-global connection toasts, timeline system
events, Logs, Server Diagnostics, and feedback are the current attention
surfaces. A notification bell, unread inbox, APNs registration, push delivery,
device broker behavior, notification read state, and notification delivery
chips return only with a future server-owned APNs/device/capability resource
mechanism; iOS must not create a local substitute that implies hidden backend
truth.

The iOS Affordance Restoration Map is the active planning artifact for
functional-only Phase 1 iOS UX restoration. It classifies every deleted or
renamed old iOS path before implementation, starts with local-native and
current server-fact affordances, and does not restore deleted product panels.
The full Phase 2 agent-execution restoration plan now lives in
`packages/agent/docs/phase-2-agent-execution-restoration-scorecard.md` and
covers capability discovery, filesystem, jobs, workers, subagents, approvals,
web, git/worktrees, skills/rules/memory, MCP, scheduling, program execution,
and matching database/event/settings/dependency work.

## Retained Surface

- Connection, strict pairing host validation, onboarding, and local paired-server
  selection.
- Settings needed to reach the server, configure providers, choose models, and
  inspect local diagnostics.
- Grouped session dashboard with collapsible workspace headers and compact
  inset liquid-glass one-line session rows, session creation/fork/resume,
  a new-session workspace selector over the configured default workspace,
  recent session workspaces, and manual Mac paths, prompt composer with a
  local recent-input picker, a functional-only native attachment menu that
  preserves composer keyboard focus while layering native camera/photo/file
  pickers above it, unified attachments for images/documents, a right-side mic
  affordance for local composer transcription when enabled, and message
  rendering with quiet blank empty/loading chat content, streamed thinking content, and
  local in-chat error notifications.
- Live event plugins plus stored-event reconstruction into `ChatMessage`.
- Servers diagnostics Runtime Cockpit row and sheet for catalog discovery,
  worker lifecycle catalog/resource state, package actions, server-owned module
  activity, and dynamic runtime surfaces. The primary chat shell does not mount
  passive worker-runtime diagnostics.
- Generic capability invocation chips and generic generated runtime surfaces.
- Local logs, feedback bundles, MetricKit payload retention, hashed
  server-log correlation IDs, and bounded local event cache integrity.

## Deleted Fixed Product Modes

The primary source tree must not contain fixed product roots, repository
workflow panels, assistant-management panels, extension-source panels, or their
matching state/client objects. Static source guards and the cleanup invariant
test are the regression gates for this boundary; product names live only in
scorecards, evidence manifests, inventory docs, and static absence tests.
Protocol code must also avoid broad product DTO buckets, product event payload
files, public product clients, and product table models. Accepted DTOs live
under server-domain owners such as worker lifecycle, module activity, and
generated UI resources.

## Directory Structure

```
Sources/
+-- App/                  Lifecycle entry point, app delegate, scene phases
+-- Engine/               Engine transport, protocol DTOs, live/stored
|                         events, persistence, repositories
+-- Session/              Chat workflow, attachments, parsing, timeline
|                         messages, worker lifecycle cockpit state,
|                         reconstruction, activity, and tokens
+-- Support/              Composition, diagnostics, feedback, foundation,
|                         pairing, share, storage
+-- UI/                   Theme, chat, settings, onboarding, runtime
|                         surfaces, Agent cockpit, capabilities, components,
|                         system sheets
+-- Assets.xcassets/      App icons and image assets
+-- Resources/            Fonts and generated app-icon source layers
```

The retained `UI/Capabilities` components render capability lifecycle
data as generic chat evidence. They are not a capability catalog, admin
console, or operator policy surface. Capability identity is limited to the
model-visible primitive name, optional operation name, trace/root invocation
ids, theme color, and runtime-supplied presentation hints.

The deleted parallel session-tree projection is not a shell primitive. Fork
lineage remains in session metadata and stored events; iOS reconstructs history
through generic session/event repositories without a tree-only DTO, builder,
icon catalog, or fork-row state model.

## Data Flow

```
Prompt:  InputBar -> ChatViewModel -> AgentRepository -> agent::prompt
Recent:  successful text agent::prompt -> InputHistoryStore -> native attachment menu -> RecentInputHistorySheet -> InputBar
Attach:  InputBar -> native attachment menu -> nested platform picker -> Attachment -> agent::prompt
Voice:   InputBar -> ChatTranscriptionCoordinator -> transcription::list_models readiness state -> cancellation-aware ComposerMicRecorder startup -> cancellable transcription::audio -> InputBar
New:     NewSessionFlow -> WorkspaceSelectionOptionBuilder -> WorkspaceSelector -> WorkspaceBrowserRepository -> filesystem::{get_home,list_dir,create_dir} -> SessionRepository -> session::create
Live:    Engine transport -> SessionEventRepository -> EventRegistry -> Plugin -> ChatViewModel
Stored:  EventDatabase -> Session/Timeline/Reconstruction -> ChatMessage -> ChatView
Surface: Generated UI ref/data -> GeneratedRuntimeSurfaceView
Cockpit: Settings Diagnostics -> WorkerLifecycleRepository -> invocation-scoped module_activity::overview/other server facts -> AgentCockpitProjection -> AgentCockpitSheet
```

`AgentCockpitProjection` is also the boundary that turns partial or failed
reads into truthful diagnostics: catalog decode degradation becomes a degraded
summary, and view-model refresh failures keep the previous overview visible
with an explicit failed-refresh status.

`WorkspaceSelector` is a narrow server-backed workspace browser, not the old
general filesystem tool surface. Its hierarchy is navigation-first: configured
quick/default and recent workspace shortcuts are compact horizontal chips,
navigation actions are separate compact intrinsic-width single-line capsule
controls, the current folder is listed as a plain left-aligned path, and
existing server directories own the main list. It browses
the paired Mac through `WorkspaceBrowserRepository` over
`filesystem::get_home`, `filesystem::list_dir`, and
`filesystem::create_dir`. Hidden folders are toggled from the compact action
row, and inline folder creation selects the created folder. The selector must
not restore old read/write/edit/search/diff/apply-patch/import or
agent-execution filesystem behavior without a Phase 2 module contract.

`CameraCaptureSheet` keeps the tap-to-sheet path light and immersive: the
camera viewport is the sheet surface, controls layer at the bottom of that
surface, and the live/captured camera image is installed as the modal
presentation background. The foreground layer is controls-only; it does not add
a bottom fade or other material over the live viewport, and it expands through
a geometry root so bottom alignment is based on the sheet height instead of the
controls' intrinsic height. The controls still add the runtime bottom safe-area
inset back into their padding so the row stays low without clipping into the
rounded sheet edge. iOS 26 partial-height sheets reserve and render Liquid Glass
material at the safe-area edge, so the camera cannot rely on regular foreground
content to paint the whole rounded container.
`immersiveCameraSheetPresentation` keeps the iPad compact-form height fixed,
clears the iPad material backing, and provides the custom presentation
background that fills the entire modal. The sheet edge stays flat and does not
add foreground glass, refraction, or decorative border layers over the live
camera feed. `AVCaptureSession`/`AVCapturePhotoOutput` are created and
configured on the dedicated session queue after presentation begins. Camera
warm-up can still take time, but it must not block the initial child-sheet
presentation. The flashlight, shutter, and switch controls share native
interactive circular Liquid Glass surfaces with larger hit targets than their
visual glass buttons; the shutter stays a minimal white-tinted frosted glass
circle without a separate ring. After capture, the same center control animates
into a green-tinted use-photo check button, the switch-camera control animates
into the go-back-to-capture control, and the flashlight control fades out while
the row geometry stays stable. Entering captured-photo preview stops the live
`AVCaptureSession`; retake is the path that leaves preview and restarts the
session. Torch toggles and camera switching run through the session queue,
update UI state on failure, turn off active torch before input replacement,
discover front/back camera variants through `AVCaptureDevice` discovery, and
remove the old video input before validating and attaching the replacement
input so the old input does not make `canAddInput` fail.

The shell mounts `ContentView` even before onboarding is complete.
`TronMobileApp` owns one onboarding presenter for first-run setup, Server-page
pairing, and pairing URLs. `OnboardingSheetPresentation` keeps that flow on the
large detent so the connect form, QR-first pairing card, and setup pages share
one geometry instead of splitting into separate medium/full variants. When
`onboardingComplete` is true but no active paired server exists, the shell stays
visible.

Pairing accepts only bare DNS names, IPv4 addresses, or unbracketed IPv6
addresses from QR/deep-link paste and manual entry. Full URLs, paths, query
strings, userinfo, bracketed hosts, malformed IPs, and malformed DNS labels are
rejected before a WebSocket probe or `PairedServerStore` write. The pairing
commit path stores bearer tokens only in `PairedServerTokenStore`, rolls back
failed setup hydration by restoring the previous token or removing the
candidate token, and forgetting a server deletes the Keychain token before
removing metadata. Settings-launched repair for an existing paired server uses
the same large onboarding sheet, stays on the connect step, and closes after a
successful token refresh when the host and port still match that local server;
edited host/port values are treated as a new pairing and continue into setup.

`ChatViewModel.swift` keeps the mounted session state and orchestration
boundary. Runtime callback installation for streaming text, UI update queue
drain, capability completion ordering, and live event processing lives in
`ChatViewModel+RuntimeCallbacks.swift` so new callback behavior does not grow
the root state object. Chat-scoped error routing lives in
`ChatViewModel+Errors.swift`: local failures append ephemeral
`LocalChatNotification` timeline items with deduped replacement and are cleared
when a new prompt starts or the chat view disappears. `ChatView.swift` keeps
shell composition; message-list scrolling, pagination, composer, and sheet
rendering live in `ChatView+MessageList.swift` and the existing toolbar/helper
extensions.

## Chat Visual Affordances

The chat timeline owns only truthful local/session presentation state:

- Empty/loading chat content stays blank. Session loading does not render a
  spinner or explanatory timeline row.
- Connection status is app-global. Reconnecting, disconnected, and retry
  signals route through `ToastCenter`/connection retry policy, not through
  separate in-chat connection pills.
- Local chat errors are temporary `LocalChatNotification` timeline messages.
  Tapping opens `LocalErrorDetailSheet` only when structured details exist;
  there is no tap-to-dismiss, explicit dismiss button, timer-only dismissal, or
  persisted event claim. Pre-accept prompt-send and retry-send failures clear
  local and session processing before appending their deduped local
  notification; server-accepted stream/event failures continue through the
  server-authored event path.
- Thinking fallback is a single app-owned `NeuralSparkIndicator`.
  Configurable thinking styles were removed; streamed thinking text still
  renders inline above the response when the current stream provides it.
- Capability evidence uses `CapabilityEvidencePresentation` as the pure mapper
  for one-line chat chips and sectioned detail sheets. Chips stay compact; the
  detail sheet shows summary, target/input/result/error, and technical
  provenance only when current invocation data supplies it.
- Passive worker-runtime diagnostics stay out of the chat shell. A chat-level
  agent signal can return only for attention-worthy states such as approval
  required, degraded runtime, an active session-relevant worker, or a generated
  surface requiring user action.

Deferred or rejected surfaces remain absent: process/job/subagent/source-control
work dashboards, approvals, memory/rules/hooks status, skill activation,
prompt-suggestion/inbox surfaces, fixed product panels, fake activity, and
backend status that is not sourced from current local state or current server
facts.

## Engine Client Boundary

`Engine/Transport/WebSocket` owns the WebSocket request/response transport.
`EngineConnection` is split by transport concern: the root connection state,
request tracking, receive/heartbeat loop, reconnect coordination, protocol
frames, and transport types live in separate focused files. Typed domain client
files live under `Engine/Transport/Clients` as thin method wrappers over
`/engine` frames; system, message, and log operations use concrete
`SystemClient`, `MessageClient`, and `LogsClient` domains rather than a
miscellaneous facade. They must not encode product policy. Any fixed
workflow-specific client removed in PET-8 must stay removed unless a later
scorecard row proves it is boot infrastructure.

Engine child errors are normalized at the transport boundary. Canonical
`details.failure` payloads stay authoritative; older or setup-time child errors
that only carry `kind`, `message`, and `details` are preserved as
`EngineProtocolError` values so UI surfaces show the real server failure instead
of a generic invalid-response fallback.

SwiftUI and `Session/` code do not depend on concrete `EngineClient`,
`EngineConnection`, WebSocket transport types, or settings/auth wire DTOs.
They consume protocol-typed repositories and view models: `ChatSessionServices`
for mounted chat sessions, `AppConnectionRepository` for connection state,
`SessionEventRepository` for live events, `SettingsRepository` for settings
snapshots/mutations, `AuthRepository` for credential snapshots/mutations, and
the existing model/session/agent/message repositories for chat workflows.
`WorkerLifecycleRepository` is the cockpit-facing boundary for catalog,
resource, catalog-discovery report, module-activity overview, and worker
lifecycle calls.
`AgentCockpitProjection` remains a pure mapper from server-owned facts to UI
rows; it does not own worker truth, module-activity truth, or redaction policy.
`Support/Composition` is the production composition root allowed to wire those
protocols to engine-owned clients.

Transport tests mirror the production owners: retry policy tests live under
`Tests/Engine/Transport/Retry`, and WebSocket/request-response tests live under
`Tests/Engine/Transport/WebSocket`.

DRC-9 replay manifest/event parity remains a server/iOS boundary rule. Replay
exports remain server-owned capability results, not live or persisted iOS
events. iOS decodes the metadata-only `model.provider_request` audit event for
stored-event parity, but replay manifests stay outside the iOS event plugin and
database event-case surface.

Transport and UI scheduling follows the CSD inventory in
`packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv`.
Long-lived `Task` handles are stored and cancelled by their owner, SwiftUI
`.task` work is view-scoped, stream ACKs coalesce to the latest cursor, and
callback bridges use bounded stream buffering or owner queues. Production code
must not use `Task.detached`, `DispatchQueue.global`, or
`DispatchQueue.main.asyncAfter`; capture sessions use owner serial queues and
UI delays use cancellation-aware Swift concurrency tasks.

`Engine/Protocol` groups DTOs by server domain instead of one broad DTO bucket.
The retained runtime cockpit DTOs are accepted only where a server-owned module
or resource surface exists: worker lifecycle catalog/resources,
`module_activity::overview`, and generic `ui_surface` schemas. Unknown fields
may be ignored for wire compatibility, but iOS must not preserve product-shaped
fallback fields as client-owned truth.
`Engine/Persistence` owns the local SQLite cache, repositories, and sync cursor
coordination. `Engine/Events` owns live event dispatch, payload decoding,
plugin registration, and stored-event reconstruction helpers.

Engine invocation context carries session/workspace ids and trace metadata when
needed. The server owns validation, routing, execution, idempotency, and event
publication. iOS records delivered stream cursors for acknowledgement and
diagnostics only; it does not use them as an alternate truth store.
Replay exports remain server-owned: `session::replay_manifest` and the
`execute` `replay_manifest` operation return canonical JSON capability results,
not live or persisted iOS events. The only replay-specific persisted event iOS
decodes is the metadata-only `model.provider_request` audit event.

## State Ownership

The iOS app owns no canonical server truth. `EventDatabase` is a Documents-backed SQLite projection cache
for session lists, delivered events, sync state, and draft metadata. The
production composition root does not switch to a temporary event database when
Documents is unavailable; startup fails at the composition boundary instead of silently changing the projection substrate.
Tests and diagnostics harnesses may create explicit isolated database paths, but
those paths are not production recovery modes.

`EventStoreManager` and `SessionSynchronizer` rebuild local session/event
projections from server session lists and event-sync APIs. Server-missing
sessions are removed from the local cache, full session sync clears and
refetches event rows, and fork ancestor rows remain source-session history
rather than copied client truth. Engine stream cursors are stored per server
origin/topic/filter for ACK coalescing and diagnostics only; session history is
reconstructed through server APIs, not replayed from cursor storage.
Session list projection keeps server titles and last-message previews together:
dashboard rows prefer generated or explicit session titles, then the latest user
prompt preview, then `New Session` for untitled new rows. `SessionSidebar`
composes the dashboard surface and shell actions; `SessionList.swift` owns
workspace grouping, expansion state, row status mapping, interactive row
liquid-glass containers, and header/row presentation metrics.
`NewSessionFlow` owns the new-session sheet workflow and presents with medium
and large detents so the sheet starts compactly while still allowing expansion
for workspace and model selection.

Server settings shown in the iOS settings UI are snapshots from
`settings::get`/`settings::reset`; local state exists only to render the active
server and roll back a failed in-flight edit to the last loaded snapshot.
Pairing is device-local `UserDefaults` state, bearer tokens are per-server
Keychain secrets, drafts and input history are local workflow state, pending
share content is App Group handoff state cleared after consumption, and
MetricKit payloads are bounded Application Support diagnostics buffers.
Recent input history is stored only on the device through
`InputHistoryStore`, capped at 100 sent text prompts, exposed from the
composer attachment menu only while local history exists and the session is
idle/editable, and clearable from the Recent Inputs sheet with an icon-only
destructive toolbar action. It is not a server prompt-library
resource, snippet catalog, routing plane, or generated management surface.

## Event Handling

Live events use self-dispatching plugins registered in
`Engine/Events/Plugins/EventRegistry.swift`. Stored events use
`Engine/Events/Reconstruction` for stored-event helper types,
`Engine/Events/Reconstruction/ChatMessageProjection` for event-to-chat
projection helpers, and
`Session/Timeline/Reconstruction/UnifiedEventTransformer.swift` for the
session-owned projection into `ChatMessage` timeline state. Unsupported or
malformed events are diagnostics; they are not normalized through retired
product names.

See `events.md` for the current plugin categories and reconstruction boundary.

## Dynamic Runtime Surfaces

`UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift` is the retained
generic renderer for server/agent-authored runtime data. It uses native SwiftUI
layout primitives and submits only generic action coordinates or encoded action
payloads supplied by the runtime surface. Pure icon, formatting, array, and row
preview helpers live in `GeneratedRuntimeSurfaceView+RenderingHelpers.swift`.
It must not map fixed feature names into custom sheets.

The Agent cockpit opens from Servers -> Diagnostics -> Runtime Cockpit. Its
Discovery tab groups visible functions by namespace, summarizes schema and
health gaps, lists recent `catalog_discovery_report` resources, and can request
a new `catalog_discovery::conformance_report`. That action writes durable
report/stream evidence only; it does not execute discovered functions. Its
Surfaces tab lists active `ui_surface` resources through the same generic
`resource::list`/`resource::inspect` substrate, decodes current `UiSurfaceDTO`
payloads, and passes resource/version refs into `GeneratedRuntimeSurfaceView`.
Its Activity tab renders invocation-scoped `module_activity::overview`
summaries from the server: active/waiting/blocked status, generic timeline
entries, authority labels, touched-resource summaries, and
rollback/quarantine/runtime-authorization gate state. iOS does not parse raw
module resource payloads, invent activity states, own redaction policy, or
mount fixed source-control, memory, process, subagent, notification, skill,
approval, work, or work-dashboard panels. These generic surfaces also do not
reintroduce broad product DTOs, product event variants, or product table-backed
state.
`UI/AgentCockpit/AgentCockpitModuleActivityViews.swift` owns the Activity tab's
bounded summary card so the root cockpit sheet remains only the tab shell and
shared row composition.
The sheet uses the standard liquid-glass sheet toolbar, title, dismiss control,
and shared `TronSegmentedControl` tabs rather than a native segmented picker.
Empty state is allowed when no runtime surface is published; a hardcoded sample
surface is not.

## Settings And Theme Boundaries

`SettingsView.swift` owns settings-shell state, navigation, toolbar actions,
and sheet presentation. The main settings grid and destructive action section
live in `SettingsView+MainSection.swift`; footer-specific helpers remain in
`SettingsView+FooterSupport.swift`; paired-server row/menu helpers live in
`SettingsServerSupport.swift`; and shared row/card primitives stay in
`SettingsSupport.swift`.

Server identity, reachability, diagnostics, and pairing controls stay inside
the Servers page or the disconnected warning card; Settings main does not grow
a server-health dashboard. Servers diagnostics owns the compact Logs and
Runtime Cockpit entries. Agent settings owns server-backed quick-session
defaults, including `server.defaultProvider`, `server.defaultModel`, and
`server.defaultWorkspace`. Provider credential state remains in Providers.

`ModelPickerSheet.swift` owns the model-picker sheet frame and loading/error
state. Provider, family, model-card, reasoning-visibility, and reasoning
popover rendering live in `ModelPickerSheet+Sections.swift`. `TronColors.swift`
owns the base palette; semantic derived tokens and shape-style conveniences
live in `TronThemeTokens.swift`. The current visual baseline is neutral glass:
light backgrounds resolve to cool neutrals, dark surfaces resolve to deep
neutral glass, primary controls use the `tronEmerald` token as the emerald
primary accent, and success/warning/error remain separate semantic colors.

## Diagnostics And Build Identity

The settings toolbar and the Servers page Diagnostics section expose Logs in
every build configuration. The Logs sheet shows redacted local iOS log entries;
the client log ingestion service mirrors bounded client logs into the server
`logs` table while connected, tagging each batch with the active session id so
server-side `logs::recent` can narrow phone-tested runs by session. iOS redacts
before buffering and again at the send boundary, and the server redacts
bearer/API/OAuth fields again before durable `logs` storage, so diagnostics do
not rely on one client-only scrubber.
Successful ingest transport chatter is filtered to prevent a self-feeding
diagnostics loop.
`DiagnosticsBundleBuilder.swift` owns bundle assembly; DTOs, event sanitization,
hashing, and host classification live in `DiagnosticsBundleTypes.swift`.
Diagnostics support consumes `DiagnosticsEngineEndpoint` and
`ClientLogIngestionEndpoint`; `Support/Composition` is the only support-layer
owner that adapts those endpoints to concrete `EngineClient` instances.
`DependencyProviding` intentionally does not expose the concrete engine client.

`ProdDebug` backs the `Tron Fast` scheme: it keeps production bundle identity
and entitlements while using debug build settings for fast local iteration.

## Testing And Evidence

For shell-affecting changes:

- Regenerate the project with `xcodegen generate` when files are added,
  deleted, or renamed.
- Run `SourceGuardTests`, which compiles the full app/test target and enforces
  deleted product roots.
- Keep chat tests under the same owner names as production chat code:
  `Coordinators`, `Messaging`, `Navigation`, `State`, and `ViewModel`.
- Capture iPhone and iPad simulator screenshots when UI behavior changes.
- Include simulator name, UDID, bundle id, launch/openurl return codes, and
  screenshot paths in the relevant scorecard evidence.

The current iOS thin-client closeout proof is recorded in
`packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md`,
`packages/agent/docs/ios-thin-client-generic-runtime-shell-evidence-manifest.md`,
`packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md`, and
`packages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs`.
