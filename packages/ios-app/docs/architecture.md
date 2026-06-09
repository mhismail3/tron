# iOS App Architecture

> Last verified: 2026-06-09 (TMB-9 boundary docs audit).

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

- Connection, pairing, onboarding, and local paired-server selection.
- Settings needed to reach the server, configure providers, choose models, and
  inspect local diagnostics.
- Session list, session creation/fork/resume, prompt composer, unified
  attachments for images/documents, and message rendering.
- Live event plugins plus stored-event reconstruction into `ChatMessage`.
- Generic capability invocation chips and generic generated runtime surfaces.
- Local logs, feedback bundles, MetricKit payload retention, and bounded local
  event cache integrity.

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

`Engine/Protocol` groups DTOs by server domain instead of one broad DTO bucket.
`Engine/Persistence` owns the local SQLite cache, repositories, and sync cursor
coordination. `Engine/Events` owns live event dispatch, payload decoding,
plugin registration, and stored-event reconstruction helpers.

Engine invocation context carries session/workspace ids and trace metadata when
needed. The server owns validation, routing, execution, idempotency, and event
publication. iOS records delivered stream cursors for acknowledgement and
diagnostics only; it does not use them as an alternate truth store.

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
connected, creating a self-feeding diagnostics loop that the runtime can inspect
without relying on a debug-only export button.
`DiagnosticsBundleBuilder.swift` owns bundle assembly; DTOs, event sanitization,
hashing, and host classification live in `DiagnosticsBundleTypes.swift`.

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
