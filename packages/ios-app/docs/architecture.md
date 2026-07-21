# iOS App Architecture

> Last verified: 2026-07-20 for the worker-first autonomous POC.

## Overview

The iOS app is a SwiftUI client for a paired Tron server. It owns presentation,
local interaction state, bounded caches, audio capture, and transport adapters.
The Rust server owns model/provider communication, session and event truth,
worker state, execution, settings validation, and durable operational history.

One source tree supports iOS 26 and later:

- **Minimum iOS**: 26.0
- Supported runtime families: iOS 26 and iOS 27

The generated project uses Apple's runtime availability model instead of
SDK-specific source forks. Validated Xcode/SDK combinations live in the
development guide.

The app has two primary operational surfaces:

- Chat: create and resume sessions, submit prompts and attachments, stop work,
  inspect streamed and reconstructed messages, and manage context settings.
- Engine Dashboard: inspect the compiled core, exact session tool surface,
  published workers, active worker-owned engine policy, and durable engine
  activity; operate worker lifecycle.

Conversational creation is the worker authoring interface; iOS does not contain
a bundle editor or invent worker state.

## State Ownership

```text
SwiftUI View
    ↓ user intent / rendered server facts
@Observable ViewModel
    ↓ typed repository protocol
Repository
    ↓ typed domain client
EngineClient + /engine WebSocket
    ↓ authenticated request, response, streams
Rust server
    ↓ canonical session SQLite / worker bundles + SQLite
```

Client state may cache server facts, but it must not infer health, versions,
trigger status, authority, or lifecycle transitions. Mutations complete from
server responses and then refresh canonical state.

Protocol request DTOs mirror strict server contracts exactly. Session creation
sends only `workingDirectory`, `model`, and `title`; obsolete automation-era
`source`/`profile` metadata and the unsupported `contextFiles` field are not
encoded or silently ignored.

Catalog tools are callable registrations, not a second lifecycle plane, so
their DTOs contain no synthetic health state. Canonical worker summaries retain
the operational health used by the dashboard and lifecycle controls.

The local `EventDatabase` is a reconstructable projection under the app's
Documents `.tron/database/prod.db` path. `EventStoreManager` serializes global
stream replacement, reconstruction, and shutdown; server switching replaces
the engine client and clears server-owned projections through their owning
stores. `DependencyContainerStorage` and `DependencyContainerRuntimeIO` are the
only production composition points for these local persistence dependencies.

The Mac app is a packaging, launch-agent, and pairing shell. It is not a second
operational `/engine` client, so iOS is the current client that owns the Engine
Dashboard.

## Source Layout

```text
Sources/
├── App/                         application and scene lifecycle
├── Engine/
│   ├── Protocol/                typed wire DTOs
│   ├── Transport/               WebSocket, clients, repositories
│   ├── Events/                  live event registry and plugins
│   └── Persistence/             bounded local reconstruction cache
├── Session/
│   ├── Chat/                    chat state and coordination
│   ├── WorkerKernel/            Engine Dashboard state and presentation model
│   └── Timeline/                message reconstruction and presentation
├── Support/                     composition, diagnostics, pairing, storage
└── UI/
    ├── Chat/                    session shell and composer
    ├── WorkerConsole/           engine dashboard and worker detail console
    ├── Settings/                product and server settings
    └── Components/              reusable visual primitives
```

`Assets.xcassets/TronLogoVector.imageset/tron-logo.svg` is the authoritative
logo. The repository-owned `scripts/generate-ios-icons.mjs` derives app icons
and the README preview.

## Composition

`DependencyContainer` is the application composition root. It owns the current
`EngineClient`, constructs domain repositories, and replaces them together on
server switch. Consumer features depend on repository protocols rather than a
global socket.

Worker ownership is explicit:

```text
EngineClient.workerKernel
    → WorkerKernelClient
    → DefaultWorkerKernelRepository
    → DependencyContainer.workerKernelRepository
    → WorkerConsoleViewModel
    → WorkerConsoleSheet
```

This chain is recreated when the paired server changes. No prior server's
worker rows, runs, or inbox are retained as current truth.

## Engine Transport

`EngineConnection` owns the authenticated WebSocket, correlated request/
response continuations, stream polling, reconnection, and frame-size admission.
The bearer token comes from pairing and is never logged. Unauthorized state
requires re-pairing.

Typed domain clients call exact engine function ids. Worker operations use
`worker_kernel::*` directly and the server supplies their execution context.
Successful invocations decode the target function value directly from the
response's top-level `result`; failures decode only the canonical top-level
protocol error. There is no nested child-invocation response envelope.

`WorkerKernelClient.engineSurfaceSnapshot` calls the authenticated,
non-model-facing `engine::surface_snapshot` read with optional session context.
Strongly typed catalog DTOs expose the complete executable fixed-tool
inventory, catalog revision, surface hash/counts, function/worker versions,
every published worker's promoted/projected state, selection evidence, and
canonical worker inventory. The server does not send a separately maintained
description of its own source architecture. UI code does not reconstruct model
visibility from raw catalog `[AnyCodable]` entries. Exact selected tool
contracts remain internal to the provider request; the dashboard receives
their surface evidence without duplicating the fixed schemas it already owns.
When autonomy is off, fixed tools remain inspectable but explicitly unexposed.
The dashboard renders fixed-function ownership and worker routing reason, score,
and completed-run evidence; the same bounded routing evidence reaches the model
in the per-turn surface primer without changing catalog revisions after a run.
The client models current surface truth only; it has no catalog-watch, catalog-
change-history, or raw catalog snapshot DTO plane.

Write calls carry `EngineIdempotencyKey`. User actions use distinct generated
keys, while retrying the same accepted action retains its operation identity at
the appropriate coordinator boundary.

The public transport does not admit internal actor, grant, trace-runtime, or
worker metadata from the client. The server supplies internal causal context.

## Engine Dashboard

### DTOs

`Engine/Protocol/EngineProtocolTypes+WorkerKernel.swift` owns:

- `WorkerSummaryDTO` for identity, tool name, runner, health, active version,
  enabled/retired status, trigger count, and update time;
- `WorkerInspectResultDTO` for the bundle, versions, triggers, audit, and
  canonical version directory;
- `WorkerInvocationDTO` for queued/running/terminal runs, typed input/output,
  idempotency, trace, causal depth, trigger kind, numbered delivery-attempt
  count, and timestamps;
- `WorkerInboxItemDTO` for durable visible results and failures;
- request/response DTOs for invocation, per-worker stop, rollback, stop-all,
  purge, and webhook token rotation.

Worker history reads include `detail: "full"` explicitly and request at most 20
records. The server still applies per-value byte ceilings and reports truncation;
provider tools omit this field to receive the compact summary projection.

The bundle remains `[String: AnyCodable]` because its JSON schemas, runner, and
routing metadata are intentionally extensible. Stable operational fields are
strongly typed.

`Engine/Protocol/EngineProtocolTypes+Catalog.swift` additionally owns
`EngineIntrospectionSnapshotDTO`, `AgentToolSurfaceDTO`,
`EngineSurfaceToolDTO`, `AvailableWorkerToolDTO`, and `EngineHookOwnerDTO`.
These are the authoritative client projection for executable fixed inventory,
every published direct worker, active semantic-policy ownership, and the exact
fixed/dynamic tool surface selected by the server. The existing raw
catalog-watch DTO remains an
invalidation/change-feed contract only.

### Client and repository

`WorkerKernelClient` exposes:

- list and inspect;
- runs and inbox;
- typed invoke;
- stop current work while preserving enabled routing, plus enable/disable;
- rollback;
- retire and purge;
- stop/resume all;
- webhook token rotation;
- cursor polling for `worker.lifecycle` and `worker.invocations`.

`WorkerKernelRepository` is the feature-facing contract. The default
repository delegates without manufacturing fallback rows or local lifecycle
state.

### View model

`WorkerConsoleViewModel` is `@MainActor` and owns only presentation state:

- the selected-session engine snapshot, fixed inventory, and published worker
  projection state;
- engine-wide activity runs and inbox results;
- current list and selection;
- selected inspection, runs, and inbox;
- editable JSON invocation input and rendered result;
- one-time returned webhook credential;
- refresh/mutation flags, stop-all status, and the last transport error.

`refresh` loads one authoritative, optionally session-scoped engine snapshot,
then engine activity and the selected worker if it still exists. A disconnected
refresh clears server-owned rows. `monitor` polls
both worker stream topics with independent cursors and refreshes only after new
events. Topic polling is historical replay, so the repository contract requires
an explicit non-optional cursor and each monitoring pass begins at cursor `0`;
only live subscription may omit its starting cursor. Mutations serialize
through the view model's mutation state, call one repository operation, and
reload canonical server truth.

Invocation text is parsed with `JSONSerialization`; malformed JSON remains a
visible error and is not sent. The server remains responsible for validating
the worker's actual input schema.

### Views

The session sidebar contains a compact Engine band showing core, selected-
surface, and issue counts. It opens `WorkerConsoleSheet`, whose visible product
identity is Engine. The sidebar owns the monitoring task, so the dashboard
continues to receive durable lifecycle/invocation changes while its sheet is
closed. The dashboard uses
the same selected typography, semantic color tokens, liquid-glass section
fills, compact inline sheet chrome, status hierarchy, and progressive evidence
disclosure as the rest of Tron; raw schemas and durable payloads are supporting
detail rather than the page's primary visual hierarchy. The dashboard shell,
worker-detail workflow, reusable worker evidence components, and compiled-engine
cards are separate files under the same feature owner; no all-in-one view file
owns both navigation and every evidence renderer. It provides:

- Overview, Core, Workers, and Activity modes in one compact cockpit;
- the compiled kernel/product-boundary component map and selected session's
  exact provider surface revision/hash;
- every fixed tool grouped as host, worker control, or core change, with
  progressively disclosed input/output schemas and exposure state;
- every published worker's distinction between availability, current-session
  projection, and explicit promotion;
- engine stop-all/resume with an explanation that queued work remains durable;
- worker list with runner, health, active hash prefix, and trigger count;
- detail overview with tool identity and provenance;
- readable schema fields, progressively disclosed raw schema, generated valid
  JSON input, inline syntax admission, and typed invocation results;
- trigger status and webhook rotation;
- retained versions, rollback, and restoration of a retired worker from any
  retained version (including its last active version);
- recent runs with delivery-attempt counts and disclosed input/output, durable
  inbox results, and progressively disclosed audit history;
- stop current work without disabling the worker, enable/disable, retirement,
  and confirmation-backed permanent purge.

Loading, disconnected, empty, partial-error, and section-empty states all use
the same compact semantic cards instead of raw list placeholders. An empty
console explicitly directs the user to create workers conversationally. A
retired worker does not show the invalid ordinary Enable action; its version
rows become Restore actions that reactivate canonical server state. Stop-all,
retirement, and permanent purge use explicit destructive affordances and
confirmation; ordinary stop/disable controls explain their durable-state
semantics. Webhook credentials are shown only from the mutation response that
created or rotated them.

## Chat Flow

```text
InputBar
    → MessagingCoordinator admission reservation
    → AgentRepository.agent::prompt
    → accepted server run
    → live session events
    → EventRegistry plugin
    → ChatViewModel
    → ChatMessage presentation
```

Prompt submission is transactional at the composer boundary. The sendable text
and prepared attachment ids are snapshotted. A pre-accept encoding, frame-size,
transport, or protocol failure removes the optimistic row and preserves the
latest draft. Only an affirmative `acknowledged` response consumes the accepted
snapshot; edits made while admission is in flight remain the next draft.

Stop is single-flight and waits for server terminal lifecycle truth. Live and
reconstructed cancellation share one interruption presentation instead of
client-invented terminal state.

The event cache is reconstruction support, not an authority source. Live and
stored paths both project the same typed server events into `ChatMessage`.
Provider direct-tool calls continue to render through generic invocation/result
chips; “capability” in those UI type names means a provider tool call, not the
removed authorization framework. Direct typed command vectors render as a
readable command while the technical detail retains their exact JSON evidence.
Failure presentation classifies current schema and policy errors from their
server evidence, but never invents an authority grant or a scoped-authorization
retry path for legacy failure text.

## Composer and Attachments

The composer owns:

- text and successful-send recent-input history;
- camera, photo, and file pickers;
- prepared attachment ids and encoded-size preflight against
  `hello.maxMessageSize`;
- the trailing send/stop action.

The primitive client has no fixed microphone capture or transcription stack.
If speech input proves useful, Tron must author, activate, and exercise it as a
worker instead of adding another permanent product subsystem.

Attachment conversion commits before submission. Pending photo-picker objects
remain with the conversion owner and are not treated as sendable attachments.
The final encoded frame size is checked before socket send so an oversized
prompt cannot disconnect the client or erase retryable content.

## Context Lifecycle Presentation

Compaction and clear are direct server-owned session boundaries. Live events
and reconstruction project the same typed token counts, reason, summary, and
turn counts into timeline pills. Tapping a completed compaction opens only its
event detail; iOS has no parallel context-control repository, resource audit
sheet, hidden prompt memory editor, or Session Briefing surface.

## Settings Parity

`settings::get` returns the complete validated engine settings. iOS admits only
the explicit product projection in `ServerSettings`.

`autonomousWorkers` has end-to-end ownership:

1. decode in `EngineProtocolTypes+Settings.swift`;
2. value in `ServerSettingsSnapshot` and `SettingsState`;
3. load, reset, and server-switch handling;
4. `SettingsMutation.autonomousWorkers` and `ServerSettingsUpdate` encoding;
5. editable toggle in `EngineSettingsPage`.

Existing engines default off. The UI explains that enabling it lets local
agents create and run persistent workers with the Mac user's normal
permissions. The setting is server-owned and applies live: disabling it hides
the model-facing kernel and worker tools, cancels worker execution, and stops
resident services without deleting worker state. The authenticated Worker
Console can still inspect that state and use lifecycle or stop controls, but it
cannot invoke workers while the mode is off. Re-enabling restores the persistent
tools and dispatcher without restarting the server. Changing paired servers
reloads the new server's value.

No server-only provider, retry, or runtime field may drift into only
one Swift layer. `SettingsParityTests` guard the admitted projection.

## Notification Boundary

The worker-first client has no fixed APNs registration or notification-delivery
plane. `AppDelegate` owns only application launch diagnostics, and deep links
enter through the URL router. A future push workflow must arrive as an explicit
worker-backed product slice with observable token custody, delivery, and client
handling rather than a dormant fixed client façade.

## Local Persistence and Diagnostics

Local storage is bounded and concern-owned:

- paired server and bearer material in the secure pairing owner;
- event cache for session reconstruction;
- successful prompt history for Recent Inputs;
- local logs, feedback bundles, MetricKit payloads, and hashed server-log
  correlation ids.

Secrets, worker webhook tokens, provider credentials, and server runtime
metadata must never enter local diagnostic logs. Connection
toasts and compact in-chat error pills remain the immediate attention surfaces;
worker execution failures belong in the server-owned Engine Dashboard inbox.

The settings toolbar exposes Logs in every build configuration.
The client log ingestion service mirrors bounded client logs into the server `logs` table while connected.
Successful ingest transport chatter is filtered so ingestion cannot create a
diagnostics feedback loop.

## Build Configurations

Debug and Beta keep their isolated identities. The `ProdDebug` configuration
powers the `Tron Fast` scheme: production bundle identity and entitlements with
debug optimization and testability. Release remains the production archive
configuration. Device build/install/launch commands and their exact artifact
selection contract are documented in `docs/development.md`.

## Validation

Generate the project before building:

```bash
cd packages/ios-app
xcodegen generate
```

High-signal worker/settings tests:

```bash
xcodebuild test \
  -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/WorkerKernelDTOTests \
  -only-testing:TronMobileTests/WorkerKernelClientTests \
  -only-testing:TronMobileTests/WorkerConsolePresentationTests \
  -only-testing:TronMobileTests/WorkerConsoleViewModelTests \
  -only-testing:TronMobileTests/WorkerConsoleVisualContractTests \
  -only-testing:TronMobileTests/SettingsParityTests
```

Architecture changes must update this document with the source and focused
tests in the same commit. Historical cockpit behavior is available in Git
history and must not be reintroduced through compatibility DTOs or adapters.
