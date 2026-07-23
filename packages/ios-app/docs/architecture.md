# iOS App Architecture

> Last verified: 2026-07-22 for the worker-first POC.

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
sends only `workingDirectory`, `model`, and `title`; unknown fields are not
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

An open WebSocket is transport state, not application readiness. The connection
remains publicly `connecting` until the bounded `hello` exchange succeeds and
supplies the negotiated frame ceiling. Session restoration, reconnect hooks,
and editable UI therefore cannot run against a socket that opened but never
became protocol-ready; a stalled hello is torn down and rejoins normal
foreground reconnection.

Typed domain clients call exact engine function ids. Worker operations use
`worker_kernel::*` directly and the server supplies their execution context.
Successful invocations decode the target function value directly from the
response's top-level `result`; failures decode only the canonical top-level
protocol error. There is no nested child-invocation response envelope.

`WorkerKernelClient.engineSurfaceSnapshot` calls the authenticated,
non-model-facing `engine::surface_snapshot` read. The profile-level Engine
Dashboard intentionally omits session context; a future contextual chat view
may supply it when per-turn routing evidence is useful and clearly attributed.
Strongly typed catalog DTOs expose the complete executable fixed-tool
inventory, catalog revision, surface hash/counts, function/worker versions,
every published worker's promoted/projected state, selection evidence, and
canonical worker inventory. The server does not send a separately maintained
description of its own source architecture. UI code does not reconstruct model
visibility from raw catalog `[AnyCodable]` entries. Exact selected tool
contracts remain internal to the provider request. The profile dashboard
renders fixed-function ownership plus global worker publication, health,
runner, version, trigger, and successful-run evidence. It does not present
session promotion or query-relevance scores without a named chat and actual
task query. Bounded routing evidence still reaches the model in the per-turn
surface primer without changing catalog revisions after a run.
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
  enabled/retired status, trigger count, immutable presentation/suite binding,
  and update time;
- `WorkerInspectResultDTO` for the bundle, versions, triggers, audit, and
  canonical version directory;
- `WorkerInvocationDTO` for queued/running/terminal runs, typed input/output,
  idempotency, trace, causal depth, trigger kind, numbered delivery-attempt
  count, optional child-agent session id, and timestamps;
- `WorkerInboxItemDTO` for durable delivery records, trigger provenance,
  attention classification, and truthful agent-context attachment state;
- request/response DTOs for invocation, exact invocation cancellation,
  per-worker stop, rollback, stop-all, archive-backed purge, and webhook token
  rotation.

Worker inspection explicitly requests `detail: "full"` because the operator
detail sheet renders immutable source metadata and audit history; provider tools
omit it and receive the context-safe behavioral-contract projection. Worker
history reads likewise include `detail: "full"` explicitly and request bounded
20-record pages. The server still applies per-value byte ceilings and returns a
`nextOffset` when older records exist; Activity loads subsequent pages only on
operator request. Provider tools omit full detail to receive compact summaries.

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
- typed invocation with an explicit `wait` mode for request/response actions and
  an explicit `enqueue` mode for durable background work;
- cancel one queued or running invocation while preserving the worker route;
- stop current work while preserving enabled routing, plus enable/disable;
- rollback;
- retire and purge;
- stop/resume all;
- webhook token rotation;
- cursor polling for `worker.lifecycle` and `worker.invocations`.

`WorkerKernelRepository` is the feature-facing contract. The default
repository delegates without manufacturing substitute rows or local lifecycle
state.

### View model

`WorkerConsoleViewModel` is `@MainActor` and owns only presentation state:

- the profile-level engine snapshot, fixed inventory, and published worker
  projection state;
- engine-wide activity runs and inbox results;
- current list and selection;
- selected inspection, runs, and inbox;
- editable JSON invocation input and rendered result;
- one-time returned webhook credential;
- refresh/mutation flags, stop-all status, and the last transport error.

`refresh` loads one authoritative profile-level engine snapshot, then engine
activity and the selected worker if it still exists. A disconnected
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

The session sidebar contains a compact Engine band showing core, active-worker,
and current unhealthy-worker counts. It opens `WorkerConsoleSheet`, whose visible product
identity is Engine. The sidebar owns the monitoring task, so the dashboard
continues to receive durable lifecycle/invocation changes while its sheet is
closed. The dashboard uses
the same selected typography, semantic color tokens, liquid-glass section
fills, tabs and execution actions, compact sheet chrome, status hierarchy, and
progressive evidence disclosure as the rest of Tron. Inline expansion is
reserved for bounded secondary text that cannot materially reflow a page;
schemas, durable payloads, run details, evidence collections, and editable
advanced forms open stable detail sheets. The dashboard shell,
worker-detail workflow, reusable worker evidence components, and compiled-engine
cards are separate files under the same feature owner; no all-in-one view file
owns both navigation and every evidence renderer. Engine cards use their glass
fill and press response as the navigation affordance; trailing chevrons are
intentionally omitted throughout the dashboard and its nested sheets. It
provides:

- Workers, Core, and Activity modes in one compact cockpit, with Workers as the
  initial operator view; the always-visible
  summary owns profile-wide fixed/worker/current-health counts and any active
  worker-owned engine-policy hooks instead of duplicating them in an Overview
  tab;
- the compiled kernel/product-boundary component map and profile-wide fixed and
  published worker-tool counts;
- every fixed tool shown immediately under host, worker-control, and core-change
  section headings; each operation is a separate compact title-only card that
  opens a dedicated detail sheet for its description, identifiers, exact
  schemas, effect, risk, and exposure state;
- every published worker's profile-global availability to agents, without
  leaking unnamed session promotion or queryless relevance diagnostics;
- worker list with explicit runner type, health, active hash prefix, trigger
  count, and successful-run evidence; compact metadata groups retain clear
  separation while keeping each icon visually attached to its text;
- bounded provenance tags with full accessible source labels;
- one generic worker workflow split into Overview, Run, Activity, and Manage;
- native-experience technical detail limited to Contract and Manage so domain
  tasks, reports, runs, and inbox results have one presentation owner;
- readable schema fields, raw-schema detail sheets, generated valid JSON input,
  inline syntax admission, and typed invocation results;
- trigger status and webhook rotation;
- retained versions, rollback, and restoration of a retired worker from any
  retained version (including its last active version);
- compact recent-run rows whose semantic name, summary, and error share one
  leading edge while bounded status, trigger, timestamp, attempt, and
  distinguishing run suffix form a deliberate trailing metadata column;
  tapping one opens a canonical run-detail sheet with toolbar actions. Activity
  uses runs as the primary execution ledger and shows a
  separate Attention projection only for unresolved failures and pending
  background outcomes. A later verified activation or rollback removes resolved
  errors from Attention while the explicit Delivery Audit sheet and run ledger
  retain their immutable evidence. The engine summary labels its independent
  current-state metric `Unhealthy`, so historical delivery evidence cannot be
  confused with current worker health;
- a read-only worker-session transcript sheet launched from run-detail toolbar
  actions; audit transcripts use a read-only native bottom anchor plus a
  bounded LazyVStack settling pass so the newest evidence is visible when the
  sheet opens without inheriting interactive chat's keyboard-aware scroll loop;
  the transcript content stays transparent so the canonical sheet presentation
  is Liquid Glass at medium height and an opaque app surface at large height, while
  reserved worker child sessions remain excluded from ordinary Home navigation
  and the active interactive session remains unchanged;
- stop current work without disabling the worker, enable/disable, retirement,
  exact run cancellation, and confirmation-backed archive-then-purge whose
  result retains the recovery archive path and checksum.

Loading, disconnected, empty, partial-error, and section-empty states all use
the same compact semantic cards instead of raw list placeholders. An empty
console explicitly directs the user to create workers conversationally. A
retired worker does not show the invalid ordinary Enable action; its version
rows become Restore actions that reactivate canonical server state. Stop-all,
retirement, and archive-backed purge use explicit destructive affordances and
confirmation; ordinary stop/disable controls explain their durable-state
semantics. Webhook credentials are shown only from the mutation response that
created or rotated them. Every Worker Console sheet offers medium height first
and can expand to large; worker subtype does not alter the initial detent.

### Native worker experiences

Immutable worker presentation metadata may route a supported contract from the
generic console into a native product experience. Routing is exact: the client
matches the stable experience id, contract version, and primary-entrypoint flag.
Missing metadata, an unknown version, or a secondary suite component always
falls back to `WorkerDetailSheet`; a worker can never download or execute UI
code. The technical worker detail remains reachable from every native
experience, but it owns only the immutable contract, triggers, retained
versions, and lifecycle controls. The native experience owns its tasks/reports
and activity, preventing duplicate invocation, run, and inbox entrypoints while
preserving a single server truth plane.

The first supported contract is `work-ledger` version 1. `WorkLedgerViewModel`
invokes the worker's single typed `snapshot` action to load goals, questions,
decisions, aggregate status, and bounded recent history. It never reads the
worker's SQLite state directly. Mutations use the same flat worker tool contract
as agents and then refresh one authoritative snapshot. The native sheet
provides status summaries, goal/question filters, goal/question/decision detail
sheets, creation and editing, completion/cancellation, answer/resolution, linked
record context, empty/offline/error states, and recent durable activity. Its
single top-bar plus action creates the record kind for the selected domain tab;
from Activity it offers Goal, Question, and Decision explicitly. The info
action opens Contract and Manage. The generic console remains the
export/import, dependency/link, operational, and recovery surface until real
use justifies additional native controls.

The second supported contract is the primary `research-suite` version 1
entrypoint. Its four workers remain independently versioned and independently
operable; only the coordinator's `primary` presentation binding opens the
grouped Research experience. `ResearchSuiteViewModel` filters the canonical
worker inventory by the immutable suite contract, reads bounded full-detail
runs and attention rows for every component, and decodes only exact
`research.report.v1` coordinator outputs. It does not read the coordinator's
state directory or reconstruct reports from client caches. Malformed canonical
outputs remain visible as neutral unavailable-history rows whose full evidence
opens in a detail sheet. They do not contribute to current Attention and do not
falsely mark a successful worker/catalog refresh as failed.
Unrelated outputs are not mistaken for reports.

The Research sheet provides aggregate suite health and versions, coordinator
and specialist run/query history, actionable delivery attention, report history,
claim-to-citation inspection, source/freshness cards, contradictions, evidence
gaps, limitations, specialist outcomes, and exact JSON export. Every component
links to an independently loaded generic technical console without changing the
parent coordinator selection. Engine-owned worker events refresh the dashboard;
changes to the parent worker/run projection trigger a bounded suite refresh so
the native view converges on current server truth. Unknown contract versions,
secondary suite members, and missing bindings retain the generic-console
fallback.
The suite summary enters `needs review` only for a currently unhealthy
component, unresolved server-projected Attention, or a present refresh failure.
Retained malformed or failed runs remain audit evidence without changing
current suite status.

The third supported contract is the primary `general-delegate` version 1
entrypoint. `DelegationViewModel` binds only to the exact `general-delegate`
worker id and immutable `delegation` suite metadata, loads its full inspection,
bounded run history, and inbox from the server, and decodes only canonical
`delegation.result.v1` outputs. Task submission uses durable `enqueue` rather
than holding a client request open for agent execution. Retry creates a new
invocation with the original typed input; cancellation targets exactly one
queued or running invocation.

The Delegation sheet provides active/completed/attention summaries, typed task,
deliverable, context, file, constraint, deadline, effort, and optional JSON
Schema input, plus durable task and activity views. Run detail presents the
deliverable, evidence, constraint observations, artifacts, unresolved work,
attempt and causal evidence, and model/token/cost/timing data from the linked
child session when that session is locally available. Opening a child session
presents the shared chat transcript renderer in a read-only nested sheet. Its
reconstruction path fetches the exact server-owned ID without `session::resume`,
live-stream binding, drafts, settings, or an input bar, so auditing cannot
replace or mutate the active interactive chat. No duplicate client or
delegation session database exists. Task
detail includes the original typed input, invocation/version, idempotency key,
trigger, causal depth, trace, timestamps, model/token/cost evidence, and child
session ID. Technical worker detail
remains available from the sheet; malformed outputs and unsupported bindings
remain visible and fall back safely instead of becoming client-owned truth.
The Delegation summary follows the same current-state rule: worker health,
unresolved Attention, or a present refresh failure can require review, while
completed, failed, and cancelled historical runs remain visible without
changing the current readiness card.

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
Provider direct-tool calls render through generic invocation/result chips;
“tool” in those UI type names means a provider tool call. Direct typed command vectors render as a
readable command while the technical detail retains their exact JSON evidence.
Unbounded raw payloads and technical-reference collections open nested detail
sheets rather than expanding inside the invocation sheet and displacing its
summary.
Failure presentation classifies current schema and policy errors from their
server evidence without inventing authorization state or retry policy.

Transcript geometry has one explicit alignment rule. Content that fits inside
the available viewport is top-aligned and rejects automatic bottom-positioning
requests during streaming and restoration. Once content develops real
scrollable overflow, the existing bottom-follow state machine takes ownership.
Initial restoration measures this boundary while content is hidden, revealing a
short transcript at the top and a long transcript at its latest content. This
prevents repeated streaming scroll requests from moving an undersized message
stack between incompatible anchors.

Compact-width session navigation separates the durable selected session ID from
the transient presentation identity. Every explicit open receives a fresh
presentation identity, including a second tap on the same session after
returning Home. Popping the destination clears compact selection. This ensures
the replacement `ChatView` always begins a new reconstruction and live-stream
lifecycle instead of reusing a cancelled destination shell.

The server-backed workspace browser uses its toolbar title as the current-path
breadcrumb. The full abbreviated path remains available to accessibility, while
compact displays truncate from the beginning so the selected folder and nearest
ancestors stay visible. The browser does not repeat the path as a separate row
above the folder list.

## Composer and Attachments

The composer owns:

- text and successful-send recent-input history;
- camera, photo, and file pickers;
- prepared attachment ids and encoded-size preflight against
  `hello.maxMessageSize`;
- the compact server-derived context progress ring and its Session Context
  presentation;
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
turn counts into timeline pills. Tapping a completed compaction opens its event
detail.

The composer context ring and minimal Session Context sheet consume only
existing session truth: current context tokens, selected-model window,
remaining capacity, accumulated model traffic and cost, automatic-compaction
status, the existing model catalog/switch operation, and `session::fork`.
Session actions are disabled while disconnected, compacting, or running a turn.
There is no parallel context-control repository, resource/action audit,
memory editor, or manual compact/clear façade. Those controls may appear only
after the core exposes real production operations for them.

## Settings Parity

`settings::get` returns the complete validated engine settings. iOS admits only
the explicit product projection in `ServerSettings`.

The admitted product settings are the default model, optional workspace,
read-only Tailscale address, context-compaction threshold/recent-turn count,
and the credential-free Ollama endpoint. The endpoint is server-validated as
an absolute HTTP(S) URL and follows the same decode, state, reset,
server-switch, mutation, and UI ownership path as every editable mobile field.
Worker-first execution is unconditional server architecture and therefore has
no settings DTO, client state, mutation, reset path, or toggle.

Compaction remains in Engine settings because it controls the parent session's
model window and durable context boundary. A worker contract may own its own
input, output, timeout, and execution policy, but it must not redefine the
conversation compactor shared by every model and tool call.

No other server-only provider, retry, or runtime field may drift into only one
Swift layer. `SettingsParityTests` guard the admitted projection. The Providers
page reads model availability from server `model.list`: Ollama renders endpoint
reachability, installed-model metadata, and pull/start guidance but never asks
the app or server to manage the operator-owned Ollama service. Settings
prefetch, model pickers, and Providers share the repository's five-minute
catalog cache and one coalesced in-flight request. Opening Providers therefore
does not repeat live Ollama discovery; explicit refresh still bypasses cached
truth, while endpoint changes cancel and disown any prior-endpoint request
before loading the new endpoint.

Provider cards share one leading-icon and trailing-action column contract.
Provider names and row labels therefore remain left-aligned across differing
brand symbols, while add, clear, refresh, disclosure, and endpoint-save controls
share a stable trailing axis and the same visible edge inset as the leading
icons. Add, clear, refresh, and endpoint-save symbols share one centered circular
action label, so differing intrinsic SF Symbol widths cannot move them off that
axis.

Ollama uses the same axes: refresh and endpoint-save controls occupy the shared
trailing slot, reachability and installed count render as one compact status
line, and the editable endpoint occupies one aligned row rather than a nested
label-and-field stack.

Profile-wide worker dispatch custody lives in the Settings Danger Zone rather
than the Engine Dashboard summary. Settings reads the canonical stop-all flag
from the worker repository and requires confirmation before either pausing all
dispatch or resuming durable queued work. The dashboard continues to show a
paused summary state but does not duplicate the mutation control.

Compact mutually exclusive controls use one shared liquid-glass button style.
Dashboard tabs, color-mode choices, and text/code font choices share selected
contrast, material tint, shapes, accessibility selection state, and press
feedback rather than maintaining separate solid-button implementations.

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
  -only-testing:TronMobileTests/WorkLedgerViewModelTests \
  -only-testing:TronMobileTests/ResearchSuiteViewModelTests \
  -only-testing:TronMobileTests/SettingsParityTests
```

Architecture changes must update this document with the source and focused
tests in the same commit.
