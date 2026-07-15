# iOS App Architecture

> Last verified: 2026-07-14 (typed local-storage resolution and the consumer-facing chat/connection runtime-service facade have focused composition owners; the prompt composer uses native interactive Liquid Glass while its proportional Session Briefing context ring remains a background-free, mic-scaled glyph inside that surface and yields its slot throughout voice capture/transcription; the floating model/context pill stays removed; chat response/thinking rails were removed and final-response metadata now follows one live/replay projection contract; trusted APNs lifecycle registration and redacted server delivery were restored; a transparent icon-sized attachment-menu target keeps menu presentation from replacing the composer glass; Recent Inputs clear requires destructive confirmation; Markdown block parsing preserves nested ordered/unordered list hierarchy; the Dashboard is the session list's single server-truth cockpit, with one high-signal summary for capabilities, engine, activity, triggers, verification, and issues and one status-derived Activity presentation).

## Overview

**Minimum iOS**: 26.0

The iOS app is a SwiftUI `/engine` client. In the current primitive baseline it
is intentionally a shell: it pairs with a local Tron server, sends prompts,
keeps a clearable local recent-input history for composer reuse, records
composer mic input for opt-in local transcription, renders session
messages, persists a local event cache for reconstruction, and renders generic
runtime surfaces emitted by the engine. The session dashboard keeps its
workspace-grouped chat list and adds one compact Dashboard band backed by
server-owned projections. The Dashboard sheet opens from the session list
and starts with core engine visibility before progressively exposing module-plane
diagnostics. It surfaces capabilities grouped into user-facing areas,
schema/health gaps, durable verification history, redacted
`capability_binding::cockpit_overview` operation ownership/replacement facts,
package lifecycle status, confirmation-backed lifecycle actions, activity, and
active `ui_surface` resources without adding fixed product panels. The Activity
tab renders the server-owned, invocation-scoped `module_activity::overview`
projection instead of fabricating module activity locally, and the
Capabilities tab renders operation modularity from server-owned cockpit
visibility instead of inferring policy in Swift. Cockpit refresh failures render as
degraded while preserving the last good server facts, and malformed capability
entries surface review-needed degradation instead of
being silently omitted from counts or verified/no-capabilities summaries. The app
does not own
repository-specific panels, media workflow surfaces, saved voice notes,
assistant-management panels, extension-source surfaces, memory-retain, or rules.
Session Briefing opens from the prompt composer's context progress ring or an
audited timeline action. The ring fills in direct proportion to the bounded
server-projected context percentage; model identity remains available to
accessibility without occupying a floating visual pill. The server-backed
sheet provides narrative session context status, model switching, a
provider-safe Context Breakdown, compact, clear, read-only memory status, and
recent context action audit detail. Its context section renders
`context_control` records and timeline action refs through first-party
`context_control::ui_*` wrappers; model/provider access remains behind
`capability::execute`. It does not restore memory retain/edit, skill activation,
source control, prompt-library controls, or raw logs.

The Rust server remains authoritative for provider communication, session/event
truth, model routing, execution, state, logs, and generated runtime data. iOS
may cache and render server facts, but it must not invent capability policy,
source-control state, worker state, or product panels locally.

Fixed notification and inbox product affordances remain absent. Local chat
error pills, app-global connection toasts, timeline system
events, Logs, Server Diagnostics, and feedback are the current attention
surfaces. A notification bell, unread inbox, and fixed delivery chips remain
absent. APNs registration and push delivery are narrow lifecycle effects backed
by server-owned device, notification, and delivery resources; iOS must not
create a local substitute that implies hidden backend truth. One observable
push service owns token callbacks; the app retries registration after pairing,
connection, and foreground transitions. Per-install identity plus server-side
bundle/environment identity keeps side-by-side variants independent.

The historical iOS Affordance Restoration Map classifies every deleted or
renamed old iOS path without restoring deleted product panels. It is retained
as source-backed old-path coverage, not as current planning or execution state;
this document and focused tests own current iOS behavior.
The full Phase 2 agent-execution restoration plan now lives in
`packages/agent/docs/phase-2-agent-execution-restoration-scorecard.md` and
covers capability discovery, filesystem, jobs, workers, subagents, approvals,
web, git/worktrees, skills/rules/memory, MCP, scheduling, program execution,
and matching database/event/settings/dependency work.

## Retained Surface

- Connection, strict pairing host validation, onboarding, and local paired-server
  selection.
- Settings needed to reach the server, configure providers, choose models, tune
  server-owned context policy, configure voice input, and inspect local diagnostics.
- Grouped session dashboard with one scoped Dashboard band, collapsible
  workspace headers and compact
  inset liquid-glass one-line session rows. Each workspace shows its latest 10
  sessions initially and exposes native View more/View less controls for
  independent 10-row progressive disclosure without reordering groups. Those
  controls share the row content insets so their leading/trailing actions align
  with the session status and date columns. The
  retained session actions include creation/fork/resume,
  a new-session workspace selector over the configured default workspace,
  recent session workspaces, and manual Mac paths. Its configured, default,
  recent, and navigation actions share one compact, intrinsic-width,
  single-line capsule geometry while retaining their distinct semantics. The
  prompt composer has a
  local recent-input picker, a functional-only native attachment menu whose
  transparent icon-sized target preserves composer keyboard focus. The
  composed content row directly owns native interactive Liquid Glass, while
  that Menu is applied afterward over a reserved leading dock so rebuilding
  its label cannot replace or invalidate the material owner. Native
  camera/photo/file pickers layer above it, alongside unified attachments, and
  one composer surface with an embedded left
  attachment action plus a right-side, background-free proportional context
  ring and state action that becomes voice, send, transcribing, or stop as
  needed. The context ring yields its slot while recorder-owned capture or
  coordinator-owned transcription is active, placing the waveform/status
  immediately beside the trailing stop/progress action, and returns only after
  both lifecycle states end. Recording/transcription also owns the trailing
  action even when draft content exists; sending resumes only after both voice
  states clear. Message rendering
  preserves ordered/unordered list nesting and includes quiet blank
  empty/loading chat content, streamed thinking content, and
  local in-chat error notifications.
- Live event plugins plus stored-event reconstruction into `ChatMessage`.
- Composer context-ring Session Briefing sheet for model switching,
  server-owned context snapshots, manual compact/clear actions, read-only memory
  refs, and durable context action audit refs.
- Dashboard band and sheet for core engine link/catalog health,
  catalog discovery, worker lifecycle catalog/resource state, package actions,
  server-owned module activity, capability binding cockpit visibility, and
  dynamic runtime surfaces. The primary chat conversation shell does not mount
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
|                         surfaces, Dashboard, capabilities, components,
|                         system sheets
+-- Assets.xcassets/      App icons and image assets
+-- Resources/            Bundled fonts
```

`Assets.xcassets/TronLogoVector.imageset/tron-logo.svg` is the authoritative
logo input. `scripts/generate-icons.mjs` derives only the two app icons and the
three raster logo sizes referenced by the asset catalogs; the app has no loose
icon-layer resource directory.

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
Attach:  model.list attachmentPolicy -> camera/photo/file data -> AttachmentImagePreparer -> Attachment -> hello.maxMessageSize preflight -> agent::prompt policy validation
Voice:   InputBar -> ChatTranscriptionCoordinator -> transcription::list_models readiness state -> cancellation-aware ComposerMicRecorder startup + bounded RMS meter -> cancellable transcription::audio -> InputBar
Push:    AppDelegate token -> observable PushNotificationService -> system device::register (install + bundle + environment identity) -> private APNs custody; notification_send -> policy/evidence -> relay -> APNs
New:     NewSessionFlow -> WorkspaceSelectionOptionBuilder -> WorkspaceSelector -> WorkspaceBrowserRepository -> filesystem::{get_home,list_dir,create_dir} -> SessionRepository -> session::create
Live:    Engine transport -> SessionEventRepository -> EventRegistry -> Plugin -> ChatViewModel
Stored:  EventDatabase -> Session/Timeline/Reconstruction -> ChatMessage -> ChatView
Surface: Generated UI ref/data -> GeneratedRuntimeSurfaceView
Context: ContextBriefingButton/timeline action pill -> ContextControlSheet -> context_control::{snapshot,compact,clear,action_list,action_inspect}
Dashboard: SessionSidebar -> WorkerLifecycleRepository -> catalog/resource/module_activity/capability_binding cockpit facts -> AgentCockpitProjection -> EngineCockpitDashboardBand/AgentCockpitSheet
```

Transient composer failures use the shared one-line local notification pill.
The timeline keeps the notice compact while its tap-through detail and
accessibility label retain the complete title and message. Tap-through local
errors use the same compact adaptive sheet chrome and glass detail treatment as
the rest of the chat. While recording, the capture owner publishes only a
normalized microphone-energy value; the composer keeps a bounded rolling
waveform locally so no audio samples become view state.

Prompt submission is transactional at the composer boundary. Text,
attachments, selected-photo state, the optimistic user row, and the persisted
draft are committed only after `/engine` accepts `agent::prompt`; a pre-accept
encoding, size, transport, or protocol failure removes the optimistic row and
restores the exact composer state. `hello.ok` supplies the server's canonical
frame budget, and `EngineConnection` checks the final encoded JSON byte count
before sending so an oversized attachment cannot force a disconnect or erase a
retryable prompt.

`ContextControlSheet` presents Session Briefing as a mobile-first progressive
disclosure surface. The top level is narrative plus compact metric strips; the
same server-owned snapshot, memory refs, context actions, and audit details are
available through divided rows and detail sections without duplicating raw
context-control payloads at the top level.

`AgentCockpitProjection` is also the boundary that turns partial or failed
reads into truthful diagnostics: catalog decode degradation becomes a degraded
summary, and view-model refresh failures keep the previous overview visible
with an explicit failed-refresh status.

`WorkspaceSelector` is a narrow server-backed workspace browser, not the old
general filesystem tool surface. Its hierarchy is navigation-first: configured
quick/default and recent workspace shortcuts plus the Go Up, New Folder, and
Hidden actions share one compact, intrinsic-width, single-line capsule
presentation. One primitive owns their icon slot, padding, shape, and
interactive Liquid Glass geometry while selection and action semantics remain
distinct. The current folder is listed as a plain left-aligned path, and
existing server directories own the main list. It browses the paired Mac
through `WorkspaceBrowserRepository` over
`filesystem::get_home`, `filesystem::list_dir`, and
`filesystem::create_dir`. Hidden folders are toggled from the compact action
row, and inline folder creation selects the created folder. The selector must
not restore old read/write/edit/search/diff/apply-patch/import or
agent-execution filesystem behavior without a Phase 2 module contract.

`CameraCaptureSheet` keeps the tap-to-sheet path light and immersive: the
composer `InputBar` is its sole production presentation owner; the app process
root has no launch-argument bypass or synthetic camera viewport. The camera
viewport is the sheet surface, controls layer at the bottom of that
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

### Application process root

`TronMobileApp` is only the process entry point. It resolves `AppRuntimeMode`
before constructing the application graph and stores the production root only
for application launches. Presence of an Apple hosted-XCTest marker
(`XCTestConfigurationFilePath`, `XCTestBundlePath`, or `XCInjectBundleInto`) is
the sole authority for the inert hosted-unit-test root; schemes carry no
parallel runtime-mode setting. Application and separate UI-test launches build
`ProductionAppRoot`, while an injected unit-test host mounts only an
accessibility-hidden clear view. `AppLifecycleEffects.live` is likewise
construction-inert, and every notification-center, MetricKit, logger, or
application-singleton lookup remains behind the application-mode callback
guard.

The shell mounts `ContentView` even before onboarding is complete.
`ProductionAppRoot` owns one onboarding presenter for first-run setup, Engine → Servers
pairing, and pairing URLs. It also applies the explicit soft scroll-edge style
once at the application root for all descendant native SwiftUI scroll surfaces;
the two app-owned `WKWebView` wrappers mirror that policy on every edge of their
independent UIKit scroll views. System-owned controller hierarchies remain
untouched. `OnboardingSheetPresentation` starts that flow on a
medium detent, allows expansion to large when content needs more room, and uses
compact iPad sizing so the connect form, QR-first pairing card, and setup pages
share one geometry. On iPhone, onboarding pages do not scroll at the medium
detent; the native sheet drag indicator stays visible so the sheet can be pulled
to large before page scrolling is enabled. When
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
the same medium onboarding sheet, stays on the connect step, and closes after a
successful token refresh when the host and port still match that local server;
edited host/port values are treated as a new pairing and continue into setup.

`ChatViewModel.swift` keeps the mounted session state and orchestration
boundary. Runtime callback installation for streaming text, UI update queue
drain, capability completion ordering, and live event processing lives in
`ChatViewModel+RuntimeCallbacks.swift` so new callback behavior does not grow
the root state object. Its session-lifetime observation tasks retain only their
observed sources, capture the view model weakly for mutations, and use a
cancellation-aware wait so releasing the view model terminates idle bindings;
the connection binding owns disconnect cleanup only. `ChatView` reads raw
connectivity from the repository as an immediate `InputBarConfig` transport-safety
gate, while `InteractionPolicy` remains the shared debounced read-only policy;
neither state is mirrored. Chat event-pipeline tests use `@testable` access to
the internal dispatcher and buffer instead of production-only test shims;
PhotosPicker transfers use a narrow I/O adapter and one cancel-and-replace task
that never retains the view model across data loading or image preparation.
Chat-scoped error routing lives in
`ChatViewModel+Errors.swift`: local failures append ephemeral
`LocalChatNotification` timeline items with deduped replacement and are cleared
when a new prompt starts or the chat view disappears. `ChatView.swift` keeps
shell composition; message-list scrolling, pagination, composer, and sheet
rendering live in `ChatView+MessageList.swift` and the existing toolbar/helper
extensions. `TypewriterAnimationState` is the toolbar title's single mutable
display/task owner, shared by the production view and its focused tests.
View-local async work is owned by `ChatViewTaskCoordinator`: every
delayed scroll, reconnect refresh, model prefetch, and deep-link navigation gets
a session-generation ticket and is cancelled on disappearance so stale work
cannot mutate a replaced chat view. Transcript mutations go through the
`MessageMutating` helpers in `Session/Chat/Navigation/MessageIndex.swift`; in
place updates must use `updateMessage(at:)` so message-id and capability-id
lookups cannot drift while streaming text, thinking, and tool chips update.

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
- Earlier chat history autoloads from noninteractive scroll intent after
  initial load. The timeline does not expose a manual load control; loading
  state is limited to a small `ProgressView` with an accessibility label. A
  newly opened existing session keeps the transcript hidden while server
  reconstruction, scroll-proxy readiness, stable lazy-stack height, and
  measured bottom-distance convergence complete. During that window the
  composer placeholder shows an inline progress spinner and reads "Loading
  latest messages", then transitions back to "Type here" as the latest
  transcript fades in from the settled bottom position. A single viewport-relative
  geometry top-detent loader requests additional pages before the 1px top sentinel
  must appear; leaving the bottom alone does not prepend history, because an early
  scroll-away callback can capture a stale viewport anchor during a fast flick.
  Initial reconstruction requests 300 persisted events and displays up to 300
  recent messages; each top-detent load inserts up to 90 older messages. The
  top-detent loader also waits until active drag/deceleration settles before
  prepending, waits one stable-geometry delay for frame preferences to catch up,
  then inserts at most one page per scheduling pass, consumes that top-detent
  sample, and restores the current viewport anchor. The consumed sample re-arms
  only when the user scrolls again or leaves and re-enters the top zone, which
  allows repeated older-history paging without an uncontrolled load loop.
  Prepends preserve the first visible row identity by restoring it to `.top`;
  viewport-relative offsets are not replayed as SwiftUI target anchors because
  that can strand lazy content in empty space. Bottom autoscroll is centralized
  through `ScrollStateCoordinator`: the view suppresses programmatic bottom
  jumps while the user is interacting, the scroll view is rubber-band/programmatic
  animating, or older history is being prepended. Reconnect reconstruction preserves
  the user's already-expanded visible history window, merges it with the new
  server-authoritative suffix, and performs bounded older-page backfill when the
  suffix would otherwise leave an event-sequence gap. Server reconstruction
  failures close the server-history source for that pagination epoch so the top
  detent does not retry the same failed cursor. Once reconstruction has produced
  real messages, row visibility fails open if the view-local initial-load flag
  becomes stale; no animation state is allowed to hide the entire transcript.
- Thinking placeholder rendering is a single app-owned `NeuralSparkIndicator`.
  Configurable thinking styles were removed; streamed thinking text still
  renders inline above the response when the current stream provides it.
  Provider-authored reasoning summaries keep their internal `reasoning_summary`
  kind, but the chat label is the user-facing "Thinking" label. Completed
  summaries render a static thinking icon; only actively streaming thinking
  content uses the pulsing icon animation.
  Live `agent.thinking_delta` appends visible text, while `agent.thinking_end`
  is a server-authoritative full snapshot that replaces the accumulated draft;
  iOS must not treat it as another delta.
  Legacy OpenAI replay blocks without an explicit `kind` field use the same
  reasoning-summary presentation based on persisted provider type.
- Thinking, streaming response, and completed assistant text use the same
  rail-free leading edge. Per-item metadata is absent from thinking blocks,
  capability chips, and intermediate assistant text. A metadata footer may
  appear only beneath completed assistant text projected as the final clean
  response: live events use `agent.response_complete` with zero capability
  invocations, then attach token/model/latency facts from the matching
  `agent.turn_end`; replay uses a non-interrupted `message.assistant` payload
  with text and no capability-invocation block. Raw provider stop reasons and
  visual position never establish finality.
  Capability-bearing responses get no footer even when capability execution
  explicitly stops, while their token records still contribute to
  session/context accounting.
- Capability evidence uses `CapabilityEvidencePresentation` for one-line chat
  chips and `CapabilityInvocationBriefPresentation` for detail sheets. Chips
  stay compact; detail sheets read as a progressive briefing: what happened,
  what needs attention, the concise request, the useful result, then evidence.
  Detail cards use the same liquid-glass progressive disclosure language as
  Dashboard: high-level narrative and compact summary facts first,
  invocation list rows with dividers next, and full invocation refs/raw payloads
  only inside disclosure rows so top-level sheets do not lead with raw IDs,
  grants, paths, or JSON.
- Consecutive capability invocations are grouped only at the presentation
  layer by `CapabilityInvocationGrouping`: persisted events and reconstructed
  `ChatMessage` values remain one invocation per record, while the chat
  transcript renders adjacent multi-invocation runs as a single "Using/Used N
  capabilities" chip aligned with the normal left-edge assistant/tool-chip
  lane. Tapping the group opens `CapabilityInvocationGroupDetailSheet`, whose
  rows put attention-worthy failures first and drill into the single-invocation
  briefing without changing event identity, cancellation, trace, or replay
  semantics.
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

Every WebSocket connect or manual-retry attempt builds the completed upgrade
request and consults its injected `EngineSessionAttemptDirective` before
constructing `URLSessionConfiguration`, a delegate, a `URLSession`, or a task.
Production defaults to the unchanged live-session path. Tests that exercise
connection state inject a deterministic handled outcome, making the request
observable without opening a network session. The source guard evaluates
constructor provenance independently inside each test-function or initializer
scope, including aliases, so repeated local names cannot make unrelated tests
safe or unsafe; no filename, suite, test, path, or binding-name exception can
bypass that analysis.

Engine child errors are normalized at the transport boundary. Canonical
`details.failure` payloads stay authoritative; older or setup-time child errors
that only carry `kind`, `message`, and `details` are preserved as
`EngineProtocolError` values so UI surfaces show the real server failure instead
of a generic invalid-response state.

SwiftUI and `Session/` code do not depend on concrete `EngineClient`,
`EngineConnection`, WebSocket transport types, or settings/auth wire DTOs.
They consume protocol-typed repositories and view models: `ChatSessionServices`
for mounted chat sessions, `AppConnectionRepository` for connection state,
`SessionEventRepository` for live events, `SettingsRepository` for settings
snapshots/mutations, `AuthRepository` for credential snapshots/mutations, and
the existing model/session/agent/message repositories for chat workflows.
`EngineClient` is the composition-owned concrete transport. Its domain clients
are concrete adapters over the narrower `EngineTransport` contract; repository
protocols are the sole consumer-facing injection boundary. Concrete-client and
policy-repository tests exercise those adapters over injected `EngineTransport`.
No second whole-client or per-domain client protocol mirrors those surfaces.
`AgentClient` fulfills the narrow `AgentRepository` contract directly because
that boundary adds no policy or state; policy-owning repositories such as
`DefaultModelRepository` remain separate adapters.
`ModelClient` is transport-only; `DefaultModelRepository` owns the active
server's five-minute model catalog, refresh, and invalidation policy, while
`ModelPickerState` owns only optimistic switch presentation.
`WorkerLifecycleRepository` is the cockpit-facing boundary for catalog,
resource, catalog-discovery report, module-activity overview,
capability-binding cockpit overview, and worker lifecycle calls.
`AgentCockpitProjection` remains a pure mapper from server-owned facts to UI
rows; it does not own worker truth, module-activity truth, capability binding
truth, or redaction policy.
Its focused regression suites mirror the production seams:
`WorkerLifecycleDTOTests` proves malformed catalog entries are retained as
decode issues; core projection, module-activity mapping, general degradation,
and lifecycle actions live in `AgentCockpitStateTests`; capability grouping,
schema evidence, and malformed-catalog projection through the exact degraded
Dashboard summary titled `Operations Need Review` live in
`AgentCockpitDiscoveryStateTests`; generic Dashboard summary, count
qualification, activity grouping, and user-facing copy live in
`AgentCockpitPresentationTests`. One
`AgentCockpitStateTestFixtures` namespace owns the shared synthetic catalog,
resource, module-activity, and package builders used by those suites.
`Support/Composition` is the production composition root allowed to wire those
protocols to engine-owned clients. `DependencyContainerStorage` owns typed
production/test resolution of defaults, Documents, and the event database;
`DependencyContainer+RuntimeServices` owns the consumer-facing chat repository
bundle and connection-lifecycle forwarding, while `DependencyContainer` keeps
application assembly and active-server selection. Post-switch connection and
settings startup is one cancel-and-replace task bound to the installed
`EngineClient` identity; superseded work cannot connect or update a newer
generation. Replaced-client teardown is synchronous at the `EngineClient`
owner and completes before the replacement services are installed.

`DependencyContainerRuntimeIO` is the single immutable runtime-I/O seam. Its
production value preserves live URL-session attempts, the production
`PairedServerTokenStore` Keychain backend, and `URLSessionPairingProbe`.
Hosted tests inject a handled-attempt recorder, a task-owned in-memory token
backend, and a test-target inert pairing probe; that directive is forwarded
into the initial `EngineClient` and every active-server rebuild. No process-mode
boolean or environment lookup inside transport, pairing, or token storage may
bypass the composition boundary.

`PairedServerTokenStore.Backend` is an immutable, checked `Sendable` strategy;
each of its three stored operations is `@Sendable`. Production operations
capture no Keychain object and construct a fresh local `KeychainItem` for each
call. Hosted operations capture only the existing lock-backed
`HostedTestPairedServerTokenBackend`, so this concurrency contract does not
change production Keychain behavior or the hosted in-memory token lifecycle.

Transport tests mirror the production owners: retry policy tests live under
`Tests/Engine/Transport/Retry`, and WebSocket/request-response tests live under
`Tests/Engine/Transport/WebSocket`.

DRC-9 replay manifest/event parity remains a server/iOS boundary rule. Replay
exports remain server-owned capability results, not live or persisted iOS
events. iOS decodes the metadata-only `model.provider_request` audit event for
stored-event parity, but replay manifests stay outside the iOS event plugin and
database event-case surface.

Transport and UI scheduling is guarded directly by
`concurrency_scheduling_discipline_invariants`. Long-lived `Task` handles are
stored and cancelled by their owner, SwiftUI
`.task` work is view-scoped, stream ACKs coalesce to the latest cursor, and
callback bridges use bounded stream buffering or owner queues. An observation
task must not retain its lifecycle owner through a suspended wait, and stored
observation waits must resume on cancellation. The shared bridge in
`Support/Foundation/Concurrency` enforces that contract for chat bindings and
transport owners; active-server replacement can therefore release the old
engine client, connection manager, and interaction policy even while
observation or connect debounce work is suspended. Production code
must not use `Task.detached`, `DispatchQueue.global`, or
`DispatchQueue.main.asyncAfter`; capture sessions use owner serial queues and
UI delays use cancellation-aware Swift concurrency tasks.

`Engine/Protocol` groups DTOs by server domain instead of one broad DTO bucket.
The retained runtime cockpit DTOs are accepted only where a server-owned module
or resource surface exists: worker lifecycle catalog/resources,
`module_activity::overview`, `capability_binding::cockpit_overview`, and
generic `ui_surface` schemas. Unknown fields may be ignored for wire
forward evolution, but iOS must not preserve product-shaped optional fields as
client-owned truth.
Dynamic `AnyCodable` payload accessors preserve both JSON-decoded arrays and
directly wrapped typed Swift collections so generic UI/resource projections do
not lose schema rows, option lists, or nested evidence during reconstruction.
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

`TokenRecord` is the server-projected per-turn token DTO, not an independent
state owner. `ContextTrackingState` is the sole mounted owner of live token and
context-window presentation state. On resume, `UnifiedEventTransformer`
reconstructs a Session-owned transient projection containing only messages,
reasoning level, accumulated usage, and the last context size. The chat view
model applies its token fields to `ContextTrackingState`; there is no parallel
client-side token history. Current model, turn count, workspace, session tree,
file activity, and metadata remain owned by server reconstruction metadata,
`CachedSession`, or raw durable events rather than duplicated projection fields.
Model-catalog prefetch and the selected `ModelInfo` establish the mounted
context-window limit, while `agent.turn_end.contextLimit` provides the live
server correction. Turn-end token records plus `agent.compaction` and
`agent.context_cleared` update mounted token state directly; they do not launch
a second context-refresh lifecycle. Session Briefing keeps its server-owned
snapshot and reload work sheet-local through `ContextControlRepository`.

`EventStoreManager` owns the client generation for each persistence operation;
it passes one strongly captured client into every page of that operation.
Incremental pagination, cursor advancement, and in-operation ancestor resolution therefore
finish through one server generation even if composition selects another server
while the operation is suspended. Fork orchestration uses that same captured
client for the fork request, ancestor fetch, full-history sync, and cached
server-origin tag. The two types rebuild local session/event
projections from server session lists and event-sync APIs. Session-list refresh
uses immutable creation-key server cursors in 200-row pages beneath one
`snapshotAsOf` boundary, with independent page/no-progress limits and a
2,000-session safety cap. The sync requests active and archived sessions
together so archive transitions cannot change membership mid-snapshot. Cursor
cycles and cap-limited results are partial and never delete cached rows;
missing pagination/proof fields, inconsistent boundaries, and oversized pages
fail closed before local mutation. A complete unfiltered snapshot is applied in one SQLite
transaction; server-missing sessions at or before its boundary are removed
with their events while newer local rows and all retained events survive.
Refresh completion is client-identity fenced after network and database
boundaries: a retired client cannot begin reconciliation, schedule a current
projection load or retry, or surface an error in the replacement client's UI.
An origin-scoped SQLite transaction admitted while its client was current may
finish atomically after a switch, but cannot update the replacement projection.
An accepted refresh then awaits its exact generation-bound load before
returning. Its server `isRunning` values replace the processing projection only
for sessions without a newer live or optimistic override; explicit true and
false overrides are ordered per session and retired when that refresh
supersedes them. Partial snapshots, omitted rows, and rows without an
`isRunning` value retain their overrides. The session array is the sole
observable processing projection. Overrides and transient activity are
origin-bound, and activity is captured after database suspension, so a newer
event or another server cannot leak stale state into the published projection.
Cancelling a refresh also cancels its exact pending load before it can publish.
Destructive boundary checks compare RFC 3339 instants at full nanosecond
precision; Foundation floating-point dates and SQLite `julianday` are not used
because either can collapse distinct session creation times. Full session sync
fetches its complete replacement and any fork ancestors before clearing the last
usable local event rows; fork ancestor rows remain source-session history
rather than copied client truth. Engine stream cursors are stored per server
origin/topic/filter for ACK coalescing and diagnostics only; session history is
reconstructed through server APIs, not replayed from cursor storage.
The manager owns one weak-idle global subscription lane plus predecessor-chained
replacement and load lanes. Once a stream event is accepted, its database and
completion effects are awaited inline; shutdown is idempotent and terminal,
cancels and joins the global lane, drains `SessionRefreshService`, then cancels
and joins the load chain before an outer fixture closes `EventDatabase`.
Replacement A→B→C therefore cannot allow an earlier client to overtake the
latest lane, and shutdown never finishes the shared event bus or invents an app
process-termination callback.
Session list projection keeps server titles and last-message previews together:
dashboard rows prefer generated or explicit session titles, then the latest user
prompt preview, then `New Session` for untitled new rows. `SessionSidebar`
composes the dashboard surface and shell actions; `SessionList.swift` owns
workspace grouping, per-workspace header collapse, row status mapping,
interactive row liquid-glass containers, and presentation metrics, while
`SessionListPagination.swift` owns page counts and transition generations.
Session expansion is count-based and
derived from each refreshed server group, so new or archived rows cannot leave
stale counts; disappearing or <=10-row groups shed obsolete expansion state.
Workspace disclosure is a staged state machine because each interactive Liquid
Glass row is its own compositing layer. Collapse fades child rows out before an
animated layout removal, ordered from the last visible row upward; expansion
inserts invisible rows, animates project headers into place, and then reveals
rows from the first visible row downward. The total stagger is bounded so large
projects remain responsive; its short window starts nearby feedback promptly,
while a smooth layout curve keeps the relocation measured rather than abrupt.
Generation-checked phases make rapid direction
changes deterministic without stale completion tasks.
Pagination uses the same staged contract without disturbing existing rows:
`View more` inserts only the next page invisibly, settles layout, then reveals
that page from top to bottom; `View less` fades only rows beyond the default ten
from bottom to top before removing them. Controls are briefly disabled while a
generation-owned transition is active, preventing concurrent page mutations.
`NewSessionFlow` owns the new-session sheet workflow and presents with medium
and large detents so the sheet starts compactly while still allowing expansion
for workspace and model selection.

Server settings shown in the iOS settings UI are snapshots from
`settings::get`/`settings::reset`; local state exists only to render the active
server and roll back a failed in-flight edit to the last loaded snapshot.
Onboarding completion is one device-local `@AppStorage` flag owned by
`ProductionAppRoot`, alongside the sheet and startup effects it gates.
`PairedServerStore` owns paired-server metadata and active selection as
device-local `UserDefaults` state injected at the production composition root,
so tests use isolated persistence domains and cannot alter the installed app's
active server. Bearer tokens are per-server Keychain secrets, drafts and input
history are local workflow state, pending
share content is App Group handoff state cleared after consumption, and
MetricKit payloads are bounded Application Support diagnostics buffers.
Recent input history is stored only on the device through
`InputHistoryStore`, capped at 100 sent text prompts, exposed from the
composer attachment menu only while local history exists and the session is
idle/editable, rendered as compact one-line previews with an ellipsis when
later prompt lines are omitted, and clearable from the Recent Inputs sheet with an icon-only
destructive toolbar action followed by explicit confirmation. It is not a server prompt-library
resource, snippet catalog, routing plane, or generated management surface.

Hosted test storage and I/O have explicit ownership rather than a claim of zero
activity. The injected app root itself owns no storage. `IsolatedTestState` in
the test target is the only general factory for named defaults,
temporary roots, Documents directories, SQLite databases, visual artifacts,
handled transport attempts, stub pairing probes, and injected token backends.
Its suite lifecycle ledger and synchronous process-fallback registry also live
entirely in the test target; production sources contain only the mode guard.
Scopes emit a locked, parseable `TRON_TEST_SUITE_LIFECYCLE_V1` registration
record before exposure. Cleanup cancels fixture work, awaits database close,
removes the database/WAL/SHM and root, removes the named defaults persistent
domain, proves that domain has no keys, and then emits exactly one matching
cleanup record. Process fallback uses the same idempotent lifecycle owner.
Each touched hosted token identity separately emits balanced, secret-free
`TRON_TEST_KEYCHAIN_LIFECYCLE_V1` registration/cleanup records. Cleanup first
drains every retained `EventStoreManager`, then terminally clears and proves
all token backends empty, closes databases, removes files/defaults, and finally
deregisters process fallback; hosted code never constructs the production
Keychain item or a live pairing/session owner.
CoreSimulator may retain a regular empty plist as the canonical backing
envelope for a semantically removed domain; isolation evidence accepts it only
when its exact suite identity was registered and cleaned in that invocation,
matches the owned fixture-suite grammar, parses as an empty dictionary, and
lives directly under the current app container's Preferences directory.
Task-owned DerivedData, result bundles, and
declared fixture artifacts remain allowed ephemeral outputs. The supported
claim is narrower: hosted unit tests do not read or write pre-existing user
durable state and do not initiate a real network attempt.

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

The Dashboard opens from the session list, not Settings.
`AgentCockpitPresentation.dashboardSummary(for:)` is the single presentation
boundary for its compact band and large sheet summary card. The compact band
uses the session-row icon width, icon-to-text spacing, and horizontal content
inset so its icon, title, and description share the same visual columns as
session rows. The sheet starts with one larger aggregate
summary card derived from that presentation model. One neutral, untinted glass
surface uses dividers instead of nested tinted cards, with one status header and
concise Capabilities, Engine, and Recent activity rows. Quiet state is expressed
once as “All Systems Quiet”; the activity row says “No recent work” and omits
zero-valued activity facts. The status header and all three rows share one icon
column and one text column. The rows cover qualified action/interface counts,
workers, triggers, verification, and activity while the header owns the global
issue count. The capability check action sits beside the complete fact stack,
not inside its title line, so the button cannot inflate title-to-value spacing.
Bounded action projections render returned counts as lower bounds,
and missing projections render action counts as unavailable instead of
relabeling catalog interfaces. The previous duplicate capability-verification
summary, top-level worker/trigger explainer, nested green fills, and area-count
metrics remain absent. The sheet
orders Capabilities, Engine, then Activity, grouping agent-facing actions into
user-facing areas before drilling into
server-supplied operation owner,
metadata/projection source labels, total/returned operation completeness,
bounded resource-scan state, locked/built-in/module status, redacted
replacement target, server-owned capability-pool role, runtime-routable versus
producer-extensible versus kernel-evolution-only replacement class,
readiness/next-action labels,
replacement/shadow/extension eligibility, binding and shadow-trial attempts,
active route state, route events, routed invocations,
failed-closed/disabled/rolled-back route state, rollback/disable/abort
availability, effect/risk, schema-health, worker, trigger, tags,
request/response schema bodies, and safe verification details. Top-level
Capabilities cards contain one title, one concise description, and only their
meaningful Actions and Ownership facts, all aligned in the title text column;
Engine cards may additionally show qualified engine-interface and worker facts.
Healthy cards do not repeat status badges or worker boilerplate. Operation rows and
detail summaries lead with server-owned friendly names and concise behavior
descriptions while retaining canonical identifiers as secondary technical
detail, with the canonical operation ID on its own final technical row. User-facing
Dashboard copy calls provider/model-facing `capability::execute` operations
“Actions” and calls lower-level typed catalog functions “Engine interfaces.”
The latter are contracts used by Tron and its clients and are not presented as
an additive agent-capability count; canonical Operation ID and Function ID
labels remain in technical drill-down. The shared issue count covers degraded workers,
deduplicated blocked or degraded module activity, malformed operation
classification, failed-closed routes, incomplete operation/evidence
projections, failed verification evidence, and Dashboard refresh failures. It
appears in the Dashboard summary, while Activity renders a concise review card
instead of repeating healthy badges on every capability area.
Capability map version and recent `catalog_discovery_report` resources are
rendered only inside cockpit evidence/detail surfaces, not as top-level
telemetry.
Capability modularity rows come from `capability_binding::cockpit_overview`,
which is a server-owned redacted projection over registry metadata plus scoped
binding/shadow-trial/route records. iOS may shape display labels and grouping,
but it must not infer ownership class, replacement policy, readiness, route
state, attempt state, or rollback availability locally. `capability_binding` is
a projection source, not an operation owner. Catalog snapshot DTOs accept both
camelCase client fixtures and the engine's snake_case catalog definitions at
the protocol boundary so schema, owner, risk, and authority evidence are not
misclassified as missing by presentation code. The top-level cockpit must stay
high-signal; binding, shadow-trial, route, readiness, scan completeness, and
rollback details belong in group and operation drill-down. Agent-facing group
summaries describe modular replacement/extension ownership without mixing in
engine-locked counts. Activity owns recent verification reports alongside
runtime work. Engine owns the Engine Core summary and inspectable
kernel/governance groups, keeping the trust substrate visible without
presenting it as ordinary session capability inventory.
Dashboard, capability group, and operation cards use the whole glass container
as the disclosure target instead of decorative chevron glyphs; drill-down is
communicated by the surface hierarchy and tap target, while functional
navigation and expansion controls keep their own directional icons.
The verify action can request a new
`catalog_discovery::conformance_report`; that action writes durable
report/stream evidence only and does not execute discovered functions. Deeper
worker/package/surface tabs appear only when there is server evidence to inspect. The
Surfaces tab lists active `ui_surface` resources through the same generic
`resource::list`/`resource::inspect` substrate, decodes current `UiSurfaceDTO`
payloads, and passes resource/version refs into `GeneratedRuntimeSurfaceView`.
Its Activity tab renders invocation-scoped `module_activity::overview`
summaries plus bounded catalog-verification history from the server:
active/waiting/blocked/degraded status, generic timeline entries, authority
labels, touched-resource summaries, and
rollback/quarantine/runtime-authorization gate state. iOS does not parse raw
module resource payloads, invent activity states, own redaction policy, or
mount fixed source-control, memory, process, subagent, notification, skill,
approval, work, or work-dashboard panels. These generic surfaces also do not
reintroduce broad product DTOs, product event variants, or product table-backed
state.
`Session/WorkerLifecycle/AgentCockpitPresentation.swift` is the sole
presentation boundary for the Activity tab's narrative grouping. It maps each
server-reported item exactly once into Needs review, Needs you, Active work, or
Recent activity from the explicit server status; unknown or completed states
remain truthful recent activity rather than being inferred from visual
position. The separate duplicate module-activity summary card and projection
path are absent. `UI/AgentCockpit/AgentCockpitTabViews.swift` owns tab
selection and Capabilities, Activity, Engine, worker, package, and generated
surface composition so `AgentCockpitViews.swift` remains sheet orchestration.
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

Settings main exposes three destinations without category headers: Engine,
Providers, and App. Engine owns local server pairing alongside actionable
server-mirrored session defaults, context compaction, and the Local
Transcription policy; only the pairing section remains active while a server
settings snapshot is unavailable. Providers owns OAuth and API-key setup, and
App owns local appearance and device behavior. Database logging, diagnostic
retention, and storage-budget enforcement are fixed internal Engine safeguards,
not mobile settings. Settings main does not grow a server-health dashboard;
core engine visibility lives in the Dashboard. Its trailing destination copy
stays to two or three short concepts: Servers/session defaults/context,
OAuth/API keys, and appearance/notifications/behavior. It does not attempt to
enumerate every control owned by the destination.
Each main Settings destination or maintenance action renders as its own card;
the sheet avoids grouped table dividers and chevrons because the card itself is
the tap target and disclosure affordance. Engine and Providers open directly
on their owned sections; neither sheet builds or renders a duplicate summary
hero above those controls.
The Settings footer is a reserved bottom sibling owned by the Settings shell,
so its left/right alignment matches the rows and it remains reachable at
medium and large detents without content scrolling behind it. It does not
paint a material or gradient backdrop; the tagline and feedback control sit
directly on the native sheet surface.

Chat compaction notifications display token savings and label the percentage as
reduction. The percentage is not a context-window usage value; durable compact
actions and `compact.boundary` records remain the server-owned source of truth.

`ModelPickerSheet.swift` owns the model-picker sheet frame and loading/error
state. Provider, family, model-card, reasoning-visibility, and reasoning
popover rendering live in `ModelPickerSheet+Sections.swift`. `TronColors.swift`
owns the base palette; semantic derived tokens and shape-style conveniences
live in `TronThemeTokens.swift`. The current visual baseline is neutral glass:
light backgrounds resolve to cool neutrals, dark surfaces resolve to deep
neutral glass, primary controls use the `tronEmerald` token as the emerald
primary accent, and success/warning/error remain separate semantic colors.

## Diagnostics And Build Identity

The settings toolbar exposes Logs in every build configuration without
duplicating that destination inside another settings page. The Logs sheet shows redacted local iOS log entries;
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
  deleted product roots, hosted-test storage ownership, and the explicit
  no-network session-attempt seam.
- Prove hosted lifecycle isolation through injected `AppLifecycleEffects` and
  the explicit storage, token, and runtime-I/O seams. Ambient simulator
  notification authorization is not a unit-test oracle because it is not
  owned by the test process. External isolation runs may compare scoped TCC
  rows on a newly created exact-UDID simulator, but never the whole permission
  database.
- For cockpit capability visibility changes, run the focused
  `WorkerLifecycleDTOTests`, `WorkerLifecycleClientTests`,
  `AgentCockpitStateTests`, `AgentCockpitDiscoveryStateTests`,
  `AgentCockpitPresentationTests`, and `AgentCockpitViewModelTests` on the
  iPhone simulator so server-owned DTO decoding, transport context, state,
  discovery, display shaping, and degraded states stay covered.
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
