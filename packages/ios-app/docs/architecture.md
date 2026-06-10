# iOS App Architecture

> Last verified: 2026-06-10 (SACB-9 pairing lifecycle; SACB-8 secret custody/redaction; CSD-10 concurrency scheduling discipline; DRC-9 replay manifest/event parity retained).

## Overview

**Minimum iOS**: 26.0

The iOS app is a SwiftUI `/engine` client. On the primitive teardown branch it
is intentionally a shell: it pairs with a local Tron server, sends prompts,
renders session messages, persists a local event cache for reconstruction, and
renders generic runtime surfaces emitted by the engine. It does not own fixed
product panels, repository-specific panels, media workflow surfaces,
assistant-management panels, extension-source surfaces, audio transcription,
memory-retain, or rules.

The Rust server remains authoritative for provider communication, session/event
truth, model routing, execution, state, logs, and generated runtime data. iOS
may cache and render server facts, but it must not invent capability policy,
source-control state, worker state, or product panels locally.

## Retained Surface

- Connection, strict pairing host validation, onboarding, and local paired-server
  selection.
- Settings needed to reach the server, configure providers, choose models, and
  inspect local diagnostics.
- Session list, session creation/fork/resume, prompt composer, unified
  attachments for images/documents, and message rendering.
- Live event plugins plus stored-event reconstruction into `ChatMessage`.
- Generic capability invocation chips and generic generated runtime surfaces.
- Local logs, feedback bundles, MetricKit payload retention, hashed
  server-log correlation IDs, and bounded local event cache integrity.

## Deleted Fixed Product Modes

The primary source tree must not contain fixed product roots, repository
workflow panels, assistant-management panels, extension-source panels, or their
matching state/client objects. Static source guards and the cleanup invariant
test are the regression gates for this boundary; product names live only in
scorecards, evidence manifests, inventory docs, and static absence tests.

## Directory Structure

```
Sources/
+-- App/                  Lifecycle entry point, app delegate, scene phases
+-- Engine/               Engine transport, protocol DTOs, live/stored
|                         events, persistence, repositories
+-- Session/              Chat workflow, attachments, parsing, timeline
|                         messages, reconstruction, activity, and tokens
+-- Support/              Composition, diagnostics, feedback, foundation,
|                         pairing, share, storage
+-- UI/                   Theme, chat, settings, onboarding, runtime
|                         surfaces, capabilities, components, system sheets
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
Live:    Engine transport -> SessionEventRepository -> EventRegistry -> Plugin -> ChatViewModel
Stored:  EventDatabase -> Session/Timeline/Reconstruction -> ChatMessage -> ChatView
Surface: Generated UI ref/data -> GeneratedRuntimeSurfaceView
```

The shell mounts `ContentView` even before onboarding is complete. First-run
onboarding is presented as a sheet over the shell. When `onboardingComplete` is
true but no active paired server exists, the shell stays visible.

Pairing accepts only bare DNS names, IPv4 addresses, or unbracketed IPv6
addresses from QR/deep-link paste and manual entry. Full URLs, paths, query
strings, userinfo, bracketed hosts, malformed IPs, and malformed DNS labels are
rejected before a WebSocket probe or `PairedServerStore` write. The pairing
commit path stores bearer tokens only in `PairedServerTokenStore`, rolls back
failed setup hydration by restoring the previous token or removing the
candidate token, and forgetting a server deletes the Keychain token before
removing metadata.

`ChatViewModel.swift` keeps the mounted session state and orchestration
boundary. Runtime callback installation for streaming text, UI update queue
drain, capability completion ordering, and live event processing lives in
`ChatViewModel+RuntimeCallbacks.swift` so new callback behavior does not grow
the root state object. `ChatView.swift` keeps shell composition; message-list
scrolling, pagination, composer, and sheet rendering live in
`ChatView+MessageList.swift` and the existing toolbar/helper extensions.

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

SwiftUI and `Session/` code do not depend on concrete `EngineClient`,
`EngineConnection`, WebSocket transport types, or settings/auth wire DTOs.
They consume protocol-typed repositories and view models: `ChatSessionServices`
for mounted chat sessions, `AppConnectionRepository` for connection state,
`SessionEventRepository` for live events, `SettingsRepository` for settings
snapshots/mutations, `AuthRepository` for credential snapshots/mutations, and
the existing model/session/agent/message repositories for chat workflows.
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

Server settings shown in the iOS settings UI are snapshots from
`settings::get`/`settings::reset`; local state exists only to render the active
server and roll back a failed in-flight edit to the last loaded snapshot.
Pairing is device-local `UserDefaults` state, bearer tokens are per-server
Keychain secrets, drafts and input history are local workflow state, pending
share content is App Group handoff state cleared after consumption, and
MetricKit payloads are bounded Application Support diagnostics buffers.

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

## Settings And Theme Boundaries

`SettingsView.swift` owns settings-shell state, navigation, toolbar actions,
and sheet presentation. The main settings grid and destructive action section
live in `SettingsView+MainSection.swift`; footer-specific helpers remain in
`SettingsView+FooterSupport.swift`; paired-server row/menu helpers live in
`SettingsServerSupport.swift`; and shared row/card primitives stay in
`SettingsSupport.swift`.

`ModelPickerSheet.swift` owns the model-picker sheet frame and loading/error
state. Provider, family, model-card, reasoning-visibility, and reasoning
popover rendering live in `ModelPickerSheet+Sections.swift`. `TronColors.swift`
owns the base palette; semantic derived tokens and shape-style conveniences
live in `TronThemeTokens.swift`.

## Diagnostics And Build Identity

The settings toolbar exposes Logs in every build configuration. The client log
ingestion service mirrors bounded client logs into the server `logs` table while
connected. iOS redacts before buffering and again at the send boundary, and the
server redacts bearer/API/OAuth fields again before durable `logs` storage, so
diagnostics do not rely on one client-only scrubber. Successful ingest transport
chatter is filtered to prevent a self-feeding diagnostics loop.
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
