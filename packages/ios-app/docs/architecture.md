# iOS App Architecture

> Last verified: 2026-08-06 for authoritative/cached chat loading, canonical
> reconstruction ownership, cohesive sheets, and iOS 26/27 delivery.

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
Documents `.tron/database/prod.db` path. `session::reconstruct` is the sole
transcript-history and fork-ancestry contract; its committed event window warms
the cache. The client has no incremental history RPC, ancestor RPC, or local
sync-cursor repository; cache initialization removes that obsolete cursor table
from older builds. Session-list refresh publishes metadata for deep links.
New-session and fork rows publish synchronously after their database write
commits, then the mounted chat reconstructs canonical history.
`EventStoreManager` serializes global stream
replacement and shutdown; server switching replaces the engine client and
clears server-owned projections through their owning stores.
`DependencyContainerStorage` and `DependencyContainerRuntimeIO` are the only
production composition points for these local persistence dependencies.

The Mac app is a packaging, launch-agent, and pairing shell. It is not a second
operational `/engine` client, so iOS is the current client that owns the Engine
Dashboard.

## Source Layout

```text
Sources/
├── App/                         application and scene lifecycle
├── Engine/
│   ├── Protocol/                typed wire DTOs, grouped by domain contract
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
    ├── SessionContext/          provider-context inspection and worker map
    ├── WorkerConsole/           overview, detail, run graph, and presentations
    ├── Tools/Invocation/        fixed/worker invocation presentation
    ├── Settings/                product and server settings
    └── Components/              reusable visual primitives
```

Feature directories follow state and lifecycle owners instead of individual
sheet names. `Engine/Protocol/WorkerKernel/` separates summary/lifecycle,
invocation, run-graph, result, inbox, artifact, and request DTOs without
creating another protocol registry. `UI/WorkerConsole/` separates overview,
detail, run graph, presentation/shared components, and domain experiences while
retaining one `WorkerConsoleViewModel` and repository truth. Source-level layout
guards resolve these owning subdirectories directly so a clean checkout cannot
silently rely on a removed pre-decomposition facade.

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

`EngineClient` remains the single domain-facing connection authority.
`EngineClientPolicies.swift` contains only value policies for reconnect
classification, stream identity and interest, subscription admission, and
acknowledgement coalescing. It owns no socket, request continuation,
subscription registry, cache, or background task.

Connection, reconnect, and per-subscription admission are single-flight. Swift
task cancellation removes exactly one request record; that record owns both
its continuation and deadline, so timeout, response, cancellation, and
disconnect cannot leave parallel resource maps out of sync or resume twice.
One request timeout never tears down otherwise healthy shared transport.
Heartbeat and actual send/receive failures own socket liveness. Receive,
heartbeat, and verification work captures both the socket and its monotonic
transport generation; completion from a retired owner is discarded instead of
reading from or disconnecting its replacement. Manual retry rejoins the same
generation-owned reconnect loop rather than creating an untracked second
owner. Connection-owned serial decoder actors normalize raw text and binary
frames and decode generic response DTOs off the main actor, in receive order,
without allocating an unstructured detached task per frame. Only compact state
or event delivery returns to UI ownership. Transport logging APIs accept route,
direction, byte count, and bounded session prefixes only; raw payload previews
cannot be passed to them.

The canonical client connects on every cold active launch when a paired server
exists; opening a chat is not a prerequisite for Settings, artifacts, worker
state, notifications, or the session index to become live. A failed first live
upgrade joins the same unbounded foreground reconnect owner used after an
established socket loss. Each probe has a ten-second cold cellular/VPN route
budget, URLSession waits for connectivity within that budget, and failed
probes retry after two seconds. Backgrounding remains the hard stop for that
loop.

Read and write recovery are deliberately different. A side-effect-free engine
read waits for a usable foreground transport and, if its socket epoch fails,
replays only after a different ready epoch exists. A request-discovered broken
socket also establishes the shared recovery owner before waiting. Explicit
client retirement prevents a deferred read from resurrecting a replaced
server. Mutations remain fail-fast and use their existing idempotency contracts;
the transport never guesses that a write is safe to replay.

Session live tails have explicit domain leases. The presented chat and the
background processing projection retain independent interests in the same
subscription. Switching chats or observing terminal processing releases its
interest; the final release sends an idempotent `unsubscribe`. Reconnect
restores only still-interested session keys, while disconnect clears all
connection-local subscription identifiers. This prevents previously visited
tasks from remaining in the engine's polling loop without losing the interests
that a reconnect must restore.

A real iOS `.background` transition is a connection-epoch boundary. The client
immediately retires the WebSocket, fails its pending RPCs, cancels connection-
local subscriptions and acknowledgements, and discards that transport object;
selected-session, session-subscription interests, and previously requested
engine-global worker-monitoring intent survive. `.inactive` is only a transient
system interruption and does not tear down the socket. On returning active,
Tron opens a fresh authenticated transport, restores those still-owned live
lanes, refreshes engine projections, and asks every mounted chat for an
authoritative continuity pass. This explicit foreground request is
coalesced with the ordinary disconnected-to-connected observer, so SwiftUI
state-update coalescing cannot skip catch-up. A separate monotonic ready-socket
generation also forces that pass when a fast replacement is sampled as
connected-to-connected. Continuity also carries the stable identity of its
server-bound client, because a replacement client can have the same numeric
generation as its predecessor. Mounted server projections key their refreshes
on this complete continuity token, retain the last same-server snapshot while
offline, suppress transient transport errors, and clear only when the client/
server owner is explicitly replaced. Late decoded results and cancelled loads
are generation-fenced so they cannot repopulate a new server or strand a
loading indicator. Unauthorized connections remain parked for re-pair
rather than being retried by automatic session work. A process launched while
already backgrounded installs the same suspension gate before app
initialization, because no scene transition exists to do it later.

Interactive reconstruction closes the durable-snapshot/live-stream race in one
order: resume the session, establish its connection-local live subscription,
fetch the authoritative snapshot, commit its sequence high-water mark, then
drain the buffered live suffix through sequence deduplication. Connection loss,
timeout, cancellation, and foreground socket churn retain cached rows and draft
state and stay out of the chat timeline; protocol or data-integrity failures
remain visible. A successful pass removes only its prior reconstruction error.
The live suffix is bounded; pathological overflow requests another authoritative
snapshot rather than admitting unbounded memory or treating a partial suffix as
complete. Subscription interests survive transport-classified failures even if
the observed connection state has not yet caught up with the failed request.

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
Dashboard remains profile-scoped, while Session Context supplies its exact
session and provider-request identity for per-turn routing evidence.
Strongly typed catalog DTOs expose the complete executable fixed-tool
inventory, catalog revision, surface hash/counts, function/worker versions,
every published worker's promoted/projected state, selection evidence, and
canonical worker inventory. The compact `workerArchitecture` projection is
derived by the server from active immutable bundles and includes exposure,
runner, hooks, client boundaries, triggers, dispatch routes, `agentTools`,
suite, health, version, and provenance. The Engine dashboard merges that
architecture into each canonical worker row and detail: rows identify health,
direct/internal exposure, and runner kind together in one left-aligned bottom
tag row,
omit a redundant status-icon column, keep the description primary, and begin
one compact wrapping footer with the active version followed by trigger/run and
hook/native/connection evidence. The worker's normal overview keeps health and
purpose primary, then opens one on-demand medium/large technical sheet for
identity, source, exposure, execution, suite role, engine hooks, native
boundaries, worker-to-worker relationships, and fixed engine-tool
dependencies. Worker-to-worker relationships are labeled `Calls workers` and
`Called by workers`; fixed dependencies are separately labeled `Uses engine
tools`, so an engine hook or direct chat invocation is not confused with a
worker caller. Input contract and triggers remain in the main Overview tab
because they describe how the worker is used, while the secondary sheet is
limited to additional inspection metadata. Engine hooks and relationship or
dependency rows render `None` when empty so an absent relationship is not
mistaken for missing inspection data. Provenance is
ordinary source metadata inside that bounded technical sheet rather than a
one-row sheet of its own. Empty trigger state uses the section's single surface
instead of nesting another card. The client
does not hard-code the current worker catalog or reconstruct execution policy
from raw catalog `[AnyCodable]` entries. Exact selected tool contracts remain
internal to the provider request. The profile dashboard
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

`Engine/Protocol/WorkerKernel/` owns:

- `WorkerSummaryDTOs.swift` for identity, tool name, runner, health, active version,
  enabled/retired status, trigger count, immutable presentation/suite binding,
  its optional closed native section descriptor, and update time;
- `WorkerSummaryDTOs.swift` also contains `WorkerInspectResultDTO` for the
  bundle, versions, triggers, audit, and
  canonical version directory;
- `WorkerInvocationDTOs.swift` for queued/running/terminal runs, typed input and an
  integrity-bound result reference (with decode-only legacy-inline migration
  compatibility),
  idempotency, trace, causal depth, trigger kind, numbered delivery-attempt
  count, foreground/background mode, detachment time, originating model-tool
  invocation, parent/retry linkage, optional child-agent session id, and
  timestamps;
- `WorkerRunGraphDTOs.swift` for the graph and its node, timeline, stage,
  timing, usage, and child
  count DTOs for the bounded server-authored causal projection;
- `WorkerResultDTOs.swift` for result references, chunks, and child descriptors for
  integrity-bound, on-demand reads of exact durable results without copying a
  large payload into run history or client state;
- `WorkerInboxDTOs.swift` for compact durable result-reference receipts or bounded
  failure evidence, trigger provenance, attention classification, and truthful
  agent-context attachment state;
- `WorkerRequestDTOs.swift` for invocation and lifecycle request/response
  contracts, exact invocation cancellation,
  per-worker stop, rollback, stop-all, archive-backed purge, and webhook token
  rotation; and
- `WorkerArtifactDTOs.swift` for bounded artifact metadata, content reads, and
  deletion contracts.

These files are one wire-contract family. They do not add a second client,
decoder, cache, or worker authority.

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

- worker invocation accepts optional model and reasoning overrides. The Worker
  Console loads the server model catalog, offers Worker default plus supported
  models/reasoning levels, and shows requested/effective evidence returned by
  the invocation. Retry remains server-pinned and exposes no override control;

- list and inspect;
- bounded run history, exact invocation/model-tool graph lookup, and inbox;
- bounded RFC 6901 result reads for a completed invocation;
- typed invocation with an explicit `wait` mode for request/response actions and
  an explicit `enqueue` mode for durable background work;
- detach, bounded await, retry from immutable input/version, and exact
  causal-subtree cancellation;
- stop current work while preserving enabled routing, plus enable/disable;
- rollback;
- retire and purge;
- stop/resume all;
- webhook token rotation;
- cached connection-local live-tail subscriptions for `worker.lifecycle` and
  `worker.invocations`.

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

The lightweight summary refresh loads one authoritative profile-level engine
snapshot. A full dashboard refresh loads that snapshot, bounded activity, and
attention concurrently, then loads the selected worker's inspection, runs, and
attention concurrently if it still exists. A
disconnected refresh clears server-owned rows. Monitoring subscribes from each
worker topic's current durable tail, coalesces the adjacent facts produced by
one run, and then reloads authoritative state. It never replays historical
worker events into UI invalidation. Invocation invalidations retain every
durable originating-session identifier seen during the 200 ms coalescing
window; lifecycle invalidations stay global and sessionless invocations do not
refresh an unrelated Session Context. Refreshes are single-flight; a full request
arriving during a summary read is preserved and runs next. Mutations serialize
through the view model's mutation state, call one repository operation, and
reload canonical server truth.

Invocation text is parsed with `JSONSerialization`; malformed JSON remains a
visible error and is not sent. The server remains responsible for validating
the worker's actual input schema.

### Views

The session sidebar contains a compact Engine band showing core, active-worker,
and current unhealthy-worker counts. It opens `WorkerConsoleSheet`, whose
visible product identity is Engine. While the sheet is closed, the sidebar
reloads only its compact snapshot after a live invalidation. While the sheet is
open, Workers and Core retain that one-read summary lane; only the Activity tab
loads and monitors bounded runs and attention. Switching scopes cancels the old
view task without creating another server subscription because subscriptions
are cached per socket. The dashboard uses
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
- every fixed model-addressable function shown immediately under host, session,
  worker-interaction, and worker-administration section headings, including its
  ordinary/specialist/conditional audience and request-specific exposure; each
  operation is a separate compact title-only card that
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
- shared compact activity cards that identify the worker and plain-text status
  first, keep the task or failure summary to one line, and place caller,
  manual/automatic provenance, foreground/background mode, retry count when
  relevant, and invocation time on one bounded metadata row. The caller
  projection distinguishes engine hooks, agent tool calls,
  agent sessions, the Worker Console, schedules, self-wakeups, and parent
  workers when the bounded run snapshot contains that parent. Random invocation,
  version, trace, and idempotency identifiers remain in the canonical run-detail
  sheet rather than competing with operational facts in the activity list;
  tapping a card opens that detail sheet with toolbar actions. Activity uses
  runs as the primary execution ledger and shows a
  separate Attention projection only for unresolved failures and pending
  background outcomes. A later verified activation or rollback removes resolved
  errors from Attention while the explicit Delivery Audit sheet and run ledger
  retain their immutable evidence. The engine summary labels its independent
  current-state metric `Unhealthy`, so historical delivery evidence cannot be
  confused with current worker health;
- one emerald `Open Chat` toolbar action for agent-backed runs; run detail has
  no duplicate Model Context section. The read-only worker-session transcript
  initially reconstructs only the latest 120 events, pages older activity
  explicitly, and uses a small vertical `LazyVStack` without interactive
  chat's viewport probes, geometry-driven autoload, speech monitoring, composer,
  or keyboard-aware scroll loop. A native bottom anchor plus two bounded layout
  passes makes the newest evidence visible;
  the transcript content stays transparent so the canonical sheet presentation
  is Liquid Glass at medium height and an opaque app surface at large height, while
  reserved worker child sessions remain excluded from ordinary Home navigation
  and the active interactive session remains unchanged;
- stop current work without disabling the worker, enable/disable, retirement,
  exact run cancellation, and confirmation-backed archive-then-purge whose
  result retains the recovery archive path and checksum.

The canonical run detail and chat-embedded run graph also reuse one generic
declarative renderer for presentation contract version 1. The run sheet names
the canonical worker prominently and keeps the bounded request preview
separately labeled, so an internal semantic query containing another worker's
text cannot be mistaken for the identity of the run being inspected. The
renderer supports only
native text, status, progress, bounded table/list, public HTTPS link, durable-result
artifact, native confirmation, and fixed same-worker action sections. Bound
values are loaded concurrently from distinct RFC 6901 paths through
`worker_kernel::result_read`, never from copied output or a client presentation
cache. Artifacts reopen the existing generic result inspector at their declared
path. Actions use the ordinary worker repository and immutable server-validated
input; no worker-specific screen, downloaded code, HTML, arbitrary URL scheme,
or client command is interpreted. Unknown contract versions and future section
kinds leave the standard console intact.

Loading, disconnected, empty, partial-error, and section-empty states all use
the same compact semantic cards instead of raw list placeholders. An empty
console explicitly directs the user to create workers conversationally. A
temporarily disconnected console keeps its last authoritative inventory and
detail projections visible but read-only under one automatic-recovery banner;
reconnection replaces them from server truth. A
retired worker appears only in the final dedicated Retired workers section,
after the active persistent inventory, so historical state cannot compete with
operational workers. It does not show the invalid ordinary Enable action; its
version rows become Restore actions that reactivate canonical server state. Stop-all,
retirement, and archive-backed purge use explicit destructive affordances and
confirmation; ordinary stop/disable controls explain their durable-state
semantics. Webhook credentials are shown only from the mutation response that
created or rotated them. Every Worker Console sheet offers medium height first
and can expand to large; worker subtype does not alter the initial detent.
Worker sheets keep Liquid Glass on sheet chrome, top-level controls, and
first-level content containers. A section fill increments an environment-owned
container depth, so any card or shared control nested inside another card
automatically uses a static semantic tint instead of another glass layer. Each
presented sheet resets that depth, preserving one glass level without
glass-on-glass compositing. Top-level scroll stacks are lazy so opening or
scrolling a detail does not construct every offscreen card.
Activity run, Attention, trigger, audit, and lifecycle-action cards own those
first-level surfaces directly; their headings are plain layout groups rather
than decorative outer containers. Container sections remain reserved for
cohesive forms, tables, and multi-row metadata whose rows are not independently
actionable cards.

Only the frontmost worker sheet observes live worker state. Presenting a run,
technical detail, result, timeline, or other child sheet freezes the covered
parent's polling and invalidation-triggered refreshes. Closing the child starts
one authoritative catch-up read. This does not lose worker state: stream events
are invalidation hints, while repository snapshots remain the source of truth.
An in-flight read may finish during presentation, but it cannot start a
repeated hidden refresh cycle; the catch-up snapshot on return supersedes it.

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

Run lists, causal graphs, Session Context, and inbox pages never hydrate result
bodies. Their previews, sizes, schema/version identity, and integrity digests
come from the server reference. `worker_kernel::result_read` is the only exact
read path. Native request/response experiences may use the repository's bounded
resolver only for the just-completed invocation whose typed value is required
to finish that user action; it rejects a mismatched reference, child
projection, or truncated root instead of assembling client-owned result state.
Reconnect and server switching refetch references and pages from server truth.

The first supported contract is the primary `research-suite` version 1
entrypoint. Its four workers remain independently versioned and independently
operable; only the coordinator's `primary` presentation binding opens the
grouped Research experience. `ResearchSuiteViewModel` filters the canonical
worker inventory by the immutable suite contract, reads bounded full-detail
runs and attention rows for every component, and keeps current reference-owned
outputs in the generic run/report history rather than hydrating them from the
list response. Schema-v9 inline `research.report.v1` outputs remain decodeable
only during migration. The view model never reads the coordinator's state
directory or reconstructs reports from client caches. Malformed or unrelated
historical outputs remain neutral operational evidence and do not falsely mark
a successful worker/catalog refresh as failed.

Reference composition is also server/worker truth. Source Review preserves
stable `/sources/N` records, Citation admits only a causal result reference plus
explicit source pointers, and Coordinator reads only bounded synthesis fields
from referenced Citation results. iOS receives the resulting references and
semantic previews; it does not receive or infer the selected evidence graph.

The Research sheet provides aggregate suite health and versions, coordinator
and specialist run/query history, actionable delivery attention, reference
previews and bounded typed-result inspection. Legacy inline reports retain
claim-to-citation inspection, source/freshness cards, contradictions, evidence
gaps, limitations, and specialist outcomes during migration; sharing exports
the user-facing answer rather than retaining another raw JSON copy. Every
component links to an independently loaded generic technical console without
changing the parent coordinator selection. Engine-owned worker events refresh
the dashboard;
changes to the parent worker/run projection trigger a bounded suite refresh so
the native view converges on current server truth. Unknown contract versions,
secondary suite members, and missing bindings retain the generic-console
fallback.
Unbounded technical timeline text uses its own subordinate
`WorkerTextDetailSheet`; it never expands the authoritative run sheet inline.
Report rows and report summaries translate missing Brave Search or Exa
bindings into explicit historical run-time limitations. This explains a
`Partial` report without claiming that the profile remains unconfigured after
credentials are later added; exact binding evidence remains available under
specialist outcomes.
The suite summary enters `needs review` only for a currently unhealthy
component, unresolved server-projected Attention, or a present refresh failure.
Retained malformed or failed runs remain audit evidence without changing
current suite status.

The third supported contract is the primary `general-delegate` version 1
entrypoint. `DelegationViewModel` binds only to the exact `general-delegate`
worker id and immutable `delegation` suite metadata, loads its full inspection,
bounded run history, and inbox from the server. Current reference-owned results
remain run evidence until the user opens the bounded inspector; legacy inline
`delegation.result.v1` outputs remain decodeable during migration. Task
submission uses durable `enqueue` rather than holding a client request open for
agent execution. Retry creates a new invocation with the original typed input;
cancellation targets exactly one queued or running invocation.

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
The technical sheet is presented from the already loaded immutable worker,
inspection, runs, and Attention projection, then refreshes only supplemental
architecture metadata. It does not repeat the parent sheet's complete set of
repository reads before becoming visible.
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
Provider direct-tool calls use one lifecycle chip, while their detail
presentation is classified by immutable engine-owned metadata as either a core
primitive or a projected worker tool. The client never infers worker identity
from a tool-name prefix. Partial progress and completion events merge into the
first authoritative identity observation so late events cannot erase the
worker, version, runner, or primitive-group contract.

The detail sheet is action-first rather than a generic JSON viewer. It shows a
plain-language outcome and status first; schema-valid worker request/result
objects become bounded typed forms; core primitives use concise operation rows;
and artifacts remain in the primary flow only when they are user-relevant.
Identifiers, protocol references, and raw request/result values share one
`Technical details` entry and move through progressive disclosure into nested
sheets; the obsolete generic `Evidence` container is not a user-facing
category. Worker results open only through the bounded reference inspector; a
legacy raw-result sheet exists solely for schema-v9 migration compatibility.
Direct typed command vectors render as a readable command while technical
detail retains their exact JSON evidence. Unbounded raw payloads and
technical-reference collections never expand inline and displace the summary.

Generic non-worker calls retain the same sheet identity and may render bounded
free-text `tool.invocation.progress`, `tool.invocation.output`, and terminal
lifecycle events. Direct worker calls do not accumulate those strings into a
client-owned journey. Their chat chip resolves the persisted
model-tool/invocation association through `worker_kernel::runs(detail:
"graph")`, then renders the server's status, mode, meaningful stage, elapsed
time, child counts, result or actionable failure, and links to execution
detail. The primary sheet never embeds an unbounded causal tree or lifecycle
history. Instead, one `Execution` section shows the work-item/attempt/model-turn
counts and the latest three user-facing durable updates. One full execution
history sheet then combines the server-ordered causal nodes, child-session
links, and complete user-facing timeline; the same run is never split into
parallel Work Breakdown and Activity destinations. Live invalidations refresh
only an absent or active graph; a terminal chip remains stable instead of
restarting its durable result read when unrelated workers run. Disclosure
containers remain fully tappable without repeating right-aligned open-link
symbols; their leading icon, title, and supporting text carry the navigation
affordance. Every detail destination reachable from a tool sheet—including
execution history, exact result, technical evidence, raw payload, and
child-session views—declares medium and large detents.
The shared adaptive presentation contract therefore opens each at medium on
iPhone and leaves large available. Active child work therefore outranks a stale
parent model event, and
starts/finishes cannot collapse into a concatenated “Latest output” blob.

The same generic graph surface offers detach, bounded await, causal-subtree
cancel, terminal-failure retry, root/child session inspection, and typed-result
inspection according to server state. Terminal result previews remove
protocol-only schema/status prefixes before presentation. A completed run
loads one bounded root result page so its highest-signal fields appear ahead of
Execution; the preview status is never the only visible output when readable
fields are available. Exact result inspection still calls
`worker_kernel::result_read` on demand: the complete-result sheet is a readable
field browser over one server-bounded path or page and follows server-authored
child pointers. Primitive values wrap vertically as content rather than
entering a code container. A run has one Technical Details destination for raw
input and result JSON, immutable version and content/schema digests, timings,
identifiers, and internal events. The complete-result sheet opened from that
run does not add a second technical-details branch. Standalone result
inspection retains its own integrity evidence when no parent run sheet exists.
An empty collection receives an explicit empty state rather than a blank
surface.
Parsed JSON fields across exact worker results, structured tool results, and
worker input schemas use one row hierarchy: field identity leads, plain value
type metadata trails, and the value or preview wraps below. Type labels never
become leading content or decorative pills.
The authenticated paired-client actor may inspect profile-local results from
the engine-global Worker Console without inventing an originating session;
agent and worker reads still require server-validated session or delivery-grant
authority. The client never assembles an unbounded result copy. Raw run
projections, schemas, trace identifiers, and technical process/filesystem
entries likewise live in subordinate detail sheets. One-second polling is only
a live/reconnect fallback; every refresh re-reads server truth. The client never
reads worker storage, infers a worker stage from tool names, or owns a second
execution state.
Failure presentation classifies current schema and policy errors from their
server evidence without inventing authorization state or retry policy.

Reasoning-like content retains its server-declared source contract through
streaming, persistence, replay, compact chat, and the detail sheet.
Append-only provider thinking and provider-authored reasoning summaries retain
distinct typed contracts and are never represented as hidden chain-of-thought.
Compact chat blocks render only their grey reasoning text, without repeating a
`Thinking` or `Reasoning Summary` header above every preview. The detail sheet
labels the source kind explicitly and receives the tapped block's kind directly
rather than inferring it from the active model. Compact previews preserve
separate source paragraphs instead of joining status headings onto one line.
Reasoning text uses regular-weight provider-neutral typography: whole-line
Markdown heading/emphasis wrappers are treated as transport decoration, while
line breaks, list depth, punctuation, and literal content remain intact.

Transcript geometry has one explicit alignment rule. Content that fits inside
the available viewport is top-aligned and rejects automatic bottom-positioning
requests during streaming and restoration. Once content develops real
scrollable overflow, the existing bottom-follow state machine takes ownership.
Initial restoration measures this boundary while content is hidden, revealing a
short transcript at the top and a long transcript at its latest content. This
prevents repeated streaming scroll requests from moving an undersized message
stack between incompatible anchors. The composer's `safeAreaInset` is the sole
bottom-inset owner. If the transient thinking tail appears after initial load,
one cancellable next-layout follow request keeps it above the composer only
while the user still owns bottom-follow; its visibility does not animate layout
height or override an intentional upward scroll.

The native scroll position starts at the bottom while the independent alignment
anchor remains top, giving overflowing history a correct latest-message default
without moving short history to the foot of the viewport. Every provisional-to-
authoritative replacement invalidates empty-shell geometry before classifying
overflow and requests native bottom ownership before the bounded LazyVStack
settle pass. Current bottom distance, not the initial probe's stale value, owns a
late authoritative reconciliation. New rows wait one layout turn before testing
whether a formerly short transcript has crossed into scrollable overflow.

Assistant Markdown lists use the message edge as the marker origin: a root
bullet or ordered marker is itself flush with neighboring paragraph text, not
trailing-aligned inside an invisible inset column. Ordinary bullets reserve
only a compact glyph-width column before their content; ordered markers expand
to their intrinsic width only when their digits require it. Each child bullet
begins at its parent's minimum text origin. Two-space, four-space, and tab
source indentation are normalized into semantic levels so provider formatting
differences do not change the visible hierarchy.

Compact-width session navigation separates the durable selected session ID from
the transient presentation identity. Every explicit open receives a fresh
presentation identity, including a second tap on the same session after
returning Home. Popping the destination clears compact selection. This ensures
the replacement `ChatView` always begins a new reconstruction and live-stream
lifecycle instead of reusing a cancelled destination shell.

Configured session creation publishes the new local session projection before
navigating or dismissing its sheet. Chat identity also includes the
selected-server generation, so a deep link or server switch cannot reuse a
view model backed by the previous server's repositories. Initial reconstruction
first mounts an indexed, newest-first bounded window from the device event
cache, then refreshes it from the server-authoritative bounded snapshot. Fork
caches use one bounded recursive ancestor query across the session boundary.
Older history remains cursor-paged and user-driven rather than being decoded
during presentation. Successful snapshots update that cache; provider-request
audit bodies are reduced to deferred markers at the cache-write boundary, and
cache initialization compacts bodies left by older app builds. Closing the chat
performs no redundant history RPC. One `ConversationHistoryPhase` drives
transcript reveal and the composer:
loading, cached-and-synchronizing, authoritative, or recoverable failure. Cached
rows switch the prompt to `Type here` and permit draft text, attachment
selection, and speech capture; only send waits for the server snapshot to
commit. An uncached initial load shows progress only in the composer rather
than covering the interactive transcript with a second loading presentation;
read-only worker audits, which have no composer, use the standard sheet loading
state. Hidden interactive rows reject gestures and accessibility focus until
their initial viewport is settled. Composer actions use the session transport's
current connection state instead of a second debounced readiness owner.
Reconstruction prepares its projection before one non-suspending MainActor
commit publishes transcript rows, context state, agent state, and the
authoritative composer phase together. Device-cache persistence then runs off
the presentation critical path. A five-second presentation watchdog ends stale
loading copy without promoting cached or absent data to authority. An uncached
failure shows recoverable status and continues bounded reconnect attempts.

Cached and authoritative rows use the same bounded geometry settle and fade.
After authoritative replacement changes lazy row heights, the shell performs
one final bottom reconciliation only while the app still owns the initial
viewport. This also covers an uncached reconstruction that finishes after the
five-second recovery shell has appeared. A message deep link and any user
scroll-away take precedence; Reduce Motion removes the fade without changing
final placement. Transcript reveal is bounded to roughly 400 ms and short
histories remain top-aligned.

`SessionLoadDiagnostics` records local monotonic phase evidence for shell,
cache, authoritative reconstruction, and first interactive state. OS signposts
and structured local logs contain only elapsed milliseconds, cache outcome, and
bounded event/message counts—never session identity or content. The clock is
injectable for deterministic tests; the server remains authoritative and no
analytics, engine state, or second loading state machine is introduced.

The server-backed workspace browser uses its toolbar title as the current-path
breadcrumb. The full abbreviated path remains available to accessibility, while
compact displays truncate from the beginning so the selected folder and nearest
ancestors stay visible. The browser does not repeat the path as a separate row
above the folder list.

## Composer and Attachments

The composer owns:

- text and successful-send recent-input history;
- camera, photo, and file pickers;
- native bounded microphone permission, mono PCM capture, metering, and WAV
  encoding when a healthy worker owns the `speech_transcription` client action;
- prepared attachment ids and encoded-size preflight against
  `hello.maxMessageSize`;
- the compact server-derived context progress ring and its Session Context
  presentation;
- the trailing send/stop/record action.

The microphone stack is a narrow native actuator, not a transcription
subsystem. The engine publishes at most one current healthy owner for the
kernel-validated `speech_transcription` client action. Only then does the
composer show its mic. Tapping it records a temporary WAV, invokes that worker
through the ordinary durable worker API with the originating session, hydrates
any referenced result with that same session identity, deletes the temporary
file after loading, and inserts the worker's typed `text` result into the draft.
The shared live-tail worker subscription refreshes ownership only for worker
lifecycle changes, not for ordinary scheduled or manual invocations. Each
mounted chat owns at most one cancellation-aware monitor;
navigation teardown stops it, and its weak event loop cannot retain a
previously opened chat. Ownership therefore changes without historical replay,
per-run engine reads, or reopening the chat. Model choice, recognition
dependencies, language policy, cleanup, and quality remain worker-owned; the
app has no fixed recognizer, transcription setting, or private transcription
endpoint.

Audio-session ownership is explicit: a capture engine deactivates the shared
system session only after that same instance successfully activated it.
Creating or destroying an idle chat therefore performs no process-global audio
work.

Attachment conversion commits before submission. Pending photo-picker objects
remain with the conversion owner and are not treated as sendable attachments.
The final encoded frame size is checked before socket send so an oversized
prompt cannot disconnect the client or erase retryable content.

Streaming text uses a lazy, explicitly invalidated display link with a weak
target. Received deltas drain from an append-only chunk queue, so each display
tick appends only new characters instead of indexing and copying the complete
growing response. Mounted-chat teardown cancels recording and live monitors,
drains its accepted UI batch, flushes pending text, and invalidates the display
link without erasing recoverable stream identity. Draft metadata remains
database-owned; potentially large draft attachment reads and writes run through
one serial file actor rather than blocking SwiftUI.

## Context Lifecycle Presentation

Compaction and clear are direct server-owned session boundaries. Live events
and reconstruction project the same typed token counts, reason, summary, and
turn counts into timeline pills. Tapping a completed compaction opens its event
detail.

The composer context ring and Session Context sheet consume only existing
session truth. Token usage, model-window pressure, compaction, model switching,
and `session::fork` retain their existing owners. The latest
`model.provider_request` event is the sole durable explanation of what a model
received. The sheet uses that one latest event rather than presenting a
non-actionable request-history card. Top-level reconstruction carries one
bounded latest-request inventory, which iOS stores beside its existing cached
session row. The sheet can therefore present that inventory offline without
decoding transcript events. While connected it reconciles the summary through
`session::context_requests(limit: 1)` and loads exact manifest/audit evidence
through `session::context_request_detail` only when a detail row is opened.
There is no context-specific database, subscription, or polling service, and
exact provider audit bodies never enter the device transcript cache. Competing
cache writes retain the highest server sequence so a slower reconstruction
cannot overwrite a newer visible-sheet refresh.

`UI/SessionContext/` keeps that ownership visible in source: the main sheet owns
only presentation state and navigation; sections render the manifest; loading
owns the sheet-scoped cancellable tasks; detail sheets load bounded
evidence lazily; and the audit formatter projects redacted payloads. Cross-file
extensions share the one sheet state rather than manufacturing feature view
models or copies of provider-request data. Model metadata resolution accepts
the engine's qualified, canonical, and alias identifiers, so a restored
provider-local model id still recovers its catalog-owned context window instead
of presenting a transient loading state. The main sheet constrains its content
to the presentation width and owns only a vertical scroll axis; long live-state
labels wrap within their cards rather than widening the scroll content. Global
worker architecture remains in the Engine dashboard rather than being loaded
again by Session Context. The toolbar shows the current short model name and
opens the model picker; the main body begins directly with actionable context
inventory, so model switching does not consume a long body section. The latest
audit retains its exact model identifier in durable evidence.
The main context inventory has one Tool Surface disclosure row. Its
available/omitted counts, relevance scores, and exact selected/omitted lists
live together in the Tool Surface detail rather than being duplicated in
another main-sheet summary card. Detail rows use lazy vertical layout so a
large omitted-tool inventory does not mount all cards when the sheet opens.
That detail orders the summary, selected fixed tools, selected direct workers,
other fixed tools, omitted direct workers, and finally lazy exact evidence;
headers remain visually attached to compact cards rather than sharing the
inter-group spacing.
Navigation rows across the Session Context surface remain fully tappable
without trailing chevrons; their leading icon, title, supporting text, and
interactive glass treatment carry the affordance.

The sheet seeds its inventory from the compact cached session projection; it
does not predecode or prewarm an exact manifest. Provider Request and Tool
Surface show bounded structured evidence first. Their exact JSON stays inside
one internally scrolling selectable text view rather than expanding the parent
scroll by hundreds of kilobytes. The main sheet uses a lazy vertical stack. Its
view-scoped coordinator owns independent worker, delivery/wait, and provider
summary lanes, each allowing one read in flight and retaining a dirty bit so an
invalidation during that read guarantees a follow-up without cancelling
authoritative work. Only the provider summary is eager. Worker and delivery/
wait reads activate when their rows become visible, and reconnect or foreground
refreshes only lanes that have been activated. A session/server generation
prevents stale responses from applying after switches or disconnects. Only
visible worker and delivery/wait state poll once per second while known
activity remains; the immutable provider audit receives one final summary
refresh when activity settles.
Worker graphs publish before the optional friendly-name catalog lookup. Prior
snapshots remain visible during refresh; cancellation is silent control flow,
while a genuine refresh failure either offers retry for an empty lane or labels
the retained snapshot as the last successful update. View teardown owns and
cancels the coordinator. Manifest provenance arrays omitted by the server when
empty decode as empty collections, preserving the rest of the audit instead of
collapsing the visible sections to summary-only counts.

The v4 manifest drives standardized sections for ordered instructions,
conversation/compaction, attachments and documents, environment, exact
selected/omitted tools, durable Agent Deliveries, and the advanced redacted
provider audit. V2/v3 remain readable; historical automatic-context outcomes
stay visible and older v3 narratives without delivery evidence are labeled
`System context (historical)`. The sheet also loads one bounded
`session::agent_updates` projection. Request-specific evidence is named
`Updates included` and counts only deliveries in the selected model request;
its friendly summary leads to a lazy disclosure containing the unmodified
model-visible v4 content. Live durable state is separately named `Delivery &
wait status`, with active entries first. Resolved deliveries and waits remain
behind one compact `Recent delivery history` button that opens a standard,
width-bounded history sheet; nested history cards never expand inside the main
Session Context scroll.
Passive results are `Available` and never called waits; pending wakes say `Will
resume`, prepared entries say `In request`, observed entries say `Seen`, and
retry-exhausted wakes say `Resume failed · Available passively`.

The sheet reuses its bounded visible observer while an agent or session worker
is active, a wait is pending, or a wake is pending/prepared, then performs one
terminal refresh. Passive-only and historical state stop observation. Exact v4
content and provenance remain request-specific evidence in the detail sheet.
Delivery-only assistant continuations render without a fabricated user bubble
and say `Resumed from …`; a natural turn says `Update included · …` only when
that delivery belongs to the same provider request. If a later tool turn carries
the run-level provenance onto the final answer, chat says `Update used earlier
· …`, while Session Context continues to count only the selected request. Wake
provenance is persisted and broadcast on the first turn-start, before thinking,
tools, or assistant text, while the completed assistant event retains the same
metadata for replay. Live and reconstructed chat deduplicate that audit metadata
by delivery identity within one resumed run, so a multi-turn tool exchange shows
one compact provenance prelude with an eight-point gap before the resumed
content. A later explicit redelivery remains presentable. Older servers that
supply provenance only at response completion retain a bounded fallback. The
`agent_wait_for_workers` chip says `Auto-resume registered` while pending and
does not imply that the worker has completed. Optional continuation metadata is
backward-compatible and records source worker identity and presentation name,
wake policy, safe boundary, and whether the continuation was wake-triggered.
The summary shows cache-read percentage beside
input, output, and cost using existing session token totals. Advanced detail
shows session cache reads/writes and manifest-owned stable instruction,
fixed/dynamic schema, and reference-context byte/digest evidence. No context-
or delivery-specific client store is added. Binary media renders only metadata,
size, and digest; it is never converted to audit text. Exact selected and
omitted worker tools remain visible per provider request. Global exposure,
runner, hook/native-boundary, relationship, suite, version, health, and
provenance metadata is shown with each worker's canonical Engine inspection
instead of a duplicate Worker System directory.

The sheet also requests bounded `detail: "graph"` worker runs
filtered by the durable originating session. Because causal descendants
preserve the root session id, this includes direct and nested worker activity.
Rows group by causal root and explicitly retain queued, running, detached,
completed, failed, and cancelled descendants; opening any row resolves the
same exact server graph, including child-session links and generic controls.
Session sections share the same compact header typography and card
geometry; headings remain attached to the content they introduce while wider
inter-section spacing separates each completed card from the next section.
The worker heading and explanatory line are one compact label block, and worker
rows do not introduce a separate dashboard visual scale.
Run detail offers one emerald `Open Chat` toolbar action only when the
invocation created a real agent child session. The originating session remains
provenance and never masquerades as a worker transcript; command and
resident-service runs have no redundant empty Model Context section. Fork
confirmation is a native animated liquid-glass sheet rather than an abrupt
dialog overlay.
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

Every standard phone sheet using the canonical adaptive presentation helper
preserves the translucent liquid-glass medium detent. In dark mode only, that
detent adds one shared bounded readability underlay so content behind the sheet
cannot wash out its foreground. The large detent remains the canonical opaque
surface, while light-mode medium sheets and iPad presentation retain their
existing appearance. Explicit clear or unchanged presentation surfaces, such
as immersive camera and onboarding flows, remain intentional opt-outs.

The main Settings sheet binds its phone detent selection. Its version tagline
is absent at the medium detent and mounts as a bottom-pinned sibling of the
scrolling content only at the large detent, without an independent solid
backdrop. The sheet has no mail-composer or diagnostics-bundle feedback path;
Logs remains the explicit local diagnostics surface.

Sheet-level asynchronous labels use `SheetLoadingState`, which separates the
spinner from a Tron-typography text label. Raw labeled `ProgressView` remains
reserved for numeric progress; compact unlabeled spinners may remain inside
buttons and status controls.

The model picker additionally resolves the OpenAI neutral accent to the
standard high-contrast secondary-text token in dark mode. Model-entry chrome,
the picker title and confirmation action, and the reasoning control share the
emerald product accent; provider and model cards retain their provider-specific
colors.

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

## Canonical Session Organization Projection

Session labels, one group, and archive state arrive through the existing
`SessionInfo` snapshot and `session.updated` event. `CachedSession` persists
them in the existing disposable `sessions` table (`labels_json` and
`organization_group`) beside canonical archive projection. There is no
organizer-specific cache, view model, polling loop, or duplicate grouping
owner. A full server snapshot clears a removed group and replaces labels;
live events use `organizationChanged` so an explicit null group also clears
the cached value.

## Notification Boundary

Native notifications are the narrow client boundary for worker-authored
reminders; they are not a general device-control surface.

- `AppDelegate` installs `NotificationLifecycleBridge` as the
  `UNUserNotificationCenterDelegate` before launch completes and forwards APNs
  registration callbacks and quiet background refreshes. The runtime-mode guard
  keeps hosted tests inert.
- `NativeNotificationCoordinator` waits for the first authenticated engine
  connection before requesting permission. Denial is never repeatedly
  requested; Settings exposes the system state and an Open System Settings
  action.
- `NotificationRegistrationPolicy.swift` contains the stateless authorization
  decision, `NotificationModels.swift` contains readiness/inbox/mutation value
  types, and `NotificationRouting.swift` contains the one notification
  navigation event name. These helpers own no task or cache:
  `NativeNotificationCoordinator` remains the single registration, per-server
  lane, inbox-sync, mutation-outbox, badge, and lifecycle owner.
- Every already-authorized launch calls `registerForRemoteNotifications`
  without waiting for engine connectivity. The current APNs
  token lives only in coordinator memory. A stable installation UUID lives in
  app-private defaults and is distinct from every paired-server id. The build's
  embedded APNs route is forwarded with that token: local physical Prod/Prod
  Fast installs use sandbox to match development signing, while distributed
  Prod uses production.
- Registration fans out to all paired engines through a narrow
  `NotificationRepository` session. `DependencyContainer` alone selects and
  owns the transport: a connected active server reuses its current `/engine`
  connection. An inactive server, or an active server whose canonical socket
  is disconnected during a notification-only background launch, gets one
  bounded, short-lived authenticated client that is disconnected when the
  repository operation returns. The coordinator never receives socket, URL,
  token, or connection controls and never changes the selected server.
- `NotificationLifecycleBridge` presents worker-authored title/body as ordinary
  banner, list, and sound notifications. APNs `thread-id` comes only from the
  worker's bounded `threadKey`. The fixed reminder category exposes Snooze and
  Complete; system dismissal has no effect.
- Default taps enqueue an idempotent Open response and route through
  `NavigationIntent.notification(serverId:deliveryId:)`. The app selects the
  owning paired engine when available and otherwise shows a safe unavailable
  detail.
- The Settings leading toolbar bell opens the Notifications sheet. The ordinary
  Settings list ends with Logs, keeping diagnostics available without using the
  primary toolbar affordance. Notifications is the native synchronized inbox
  and readiness surface. It distinguishes system permission, aligned
  per-server device/token and provider readiness, selected relay/direct
  transport, and the last sanitized provider problem. Its app-private cache
  is one actor-owned, file-protected atomic projection rather than whole-array
  main-thread defaults writes. It shows logical deliveries while transport
  failures remain engine-owned Activity/Attention evidence. The actor migrates
  the former defaults arrays only after a successful file write. Mark All Read
  lives in the sheet toolbar, emits only `clear_unread`, and appends its full
  mutation batch with one durable store transaction.
- Notification inbox and detail presentations use the standard Settings
  container, liquid-glass cards, toolbar actions, and medium/large detents.
  Opening an item completes its occurrence. Snooze and Complete stay fixed
  reminder actions and live in the detail toolbar rather than ad hoc content
  buttons. The leading toolbar slot is omitted when a delivery exposes no
  response actions, so informational notifications never render empty chrome.
  The inbox uses an unnested native list: section headers are grouped with the
  content below, previews use compact one-title/two-body-line cards, and native
  swipes expose Details, read-state clearing, and only the Snooze/Complete
  actions declared by that delivery.
- The Settings Artifacts row opens a native Artifact Inbox backed by server
  metadata rather than a second local content cache. Selecting an item performs
  one authenticated exact-content read, verifies worker/artifact identity,
  declared byte count, and SHA-256, then asks the actor-owned file coordinator
  for a bounded temporary preview file whose final path component preserves the
  verified display name for sharing. Repeated ownership of one artifact's
  materialized file is reference-counted, while distinct artifact identities
  have independent custody even when their bytes match. One sheet therefore
  cannot invalidate another sheet's preview. Closing the preview or inbox
  cancels work and removes temporary files.
  Metadata pages load lazily from the engine rather than materializing an
  unbounded local array or content cache.
  Server custody persists until explicit Delete. Storage pressure reflects the
  whole worker database and remains Engine Attention rather than silently
  evicting user artifacts.
  Each inbox item is one compact filename/size row and opens verified content
  directly, without a redundant metadata/action intermediary. The inbox and
  preview use the same Settings page container, cards,
  typography, toolbar hierarchy, and medium/large sheet detents as the other
  Settings sheets; artifact ownership does not introduce a visual subsystem.
  Markdown and ordinary UTF-8 text render natively with selected Tron typography
  on the sheet's own background; structured text uses the selected mono family.
  Rich Markdown parsing is bounded, with oversized content falling back to an
  efficient selectable text view that still displays every byte. Format-owned
  binary documents fall back to Quick Look, whose UIKit-owned descendant scroll
  views receive the same soft edge treatment as SwiftUI sheets and OAuth web
  content. Share and confirmed Delete live as independent controls in the
  standard leading toolbar group, so neither is compressed into an ad hoc
  stack;
  Share already exposes Save to Files, so there is no duplicate Export action.
- Attach to Draft is the only bridge from Artifact Inbox into chat. It converts
  already-verified bytes into the existing `Attachment` value and sends an
  explicit app-local intent carrying the target session ID. Only the matching
  mounted interactive chat may consume it, and that chat remains the sole
  writer of its live draft state; other mounted chats ignore it. The preview
  labels this action `Attach to Current Draft` and shows it only when a selected
  mounted chat makes the action valid, instead of displaying a disabled mystery
  control. Merely opening, previewing, sharing, or deleting an artifact never
  mutates a draft.
  The client does not interpret worker URLs, paths, HTML, or arbitrary commands.
- The empty Artifact Inbox offers Create through chat. It posts one
  session-targeted request, dismisses Settings, and prefills an artifact request
  in the matching mounted chat without sending it. The user remains in control
  of the final content, format, and submission.
- Open, Complete, Snooze, and clear-read mutations enter a durable per-server
  outbox, apply optimistically, retry after reconnect/foreground, and reconcile
  to the engine's first-wins terminal state. Quiet pushes refresh one server;
  foreground and reconnect refresh all paired servers. A notification action
  callback does not return to iOS until the mutation is durably admitted and
  one bounded online synchronization attempt finishes. If a cold launch
  delivers the callback before dependency composition, the process bridge
  retains it until the coordinator attaches instead of dropping it. The app
  badge is the aggregate unread count across cached server truth.

Registration and inbox synchronization share one coalescing lane per paired
server: requests for the same engine serialize and merge, while unrelated
engines can progress independently. One server pass reuses one authenticated
client for registration, a bounded response batch, and inbox refresh. Protocol
requests own an eight-second timeout, each pass admits at most 32 responses
within a twenty-second work budget, and quiet-refresh waiting remains bounded
to eight seconds. Synchronization commits acknowledgement removal and
authoritative pages atomically, then reapplies any newer pending optimistic
responses. Explicit coordinator shutdown cancels network/system lanes and
awaits every accepted local outbox write. Sanitized lifecycle diagnostics
record only a short route hash for receipt, foreground presentation, and
response handling.

The client contract is closed to device registration, inbox sync, fixed
responses, and sanitized status reads. It never accepts raw APNs payloads,
arbitrary action names, device commands, URLs, media, or alert priority.
Delivery records decode their source reminder worker separately from the
producing notification-policy worker, plus `notBefore`, selected transport, and
cancelled-target counts.

## Local Persistence and Diagnostics

Local storage is bounded and concern-owned:

- paired server and bearer material in the secure pairing owner;
- native notification installation identity, logical inbox cache, server
  readiness, and mutation outbox in app-private defaults; APNs tokens are never
  persisted by Tron;
- event cache for session reconstruction;
- successful prompt history for Recent Inputs;
- local logs, MetricKit payloads, and hashed server-log correlation ids.

Secrets, worker webhook tokens, provider credentials, notification content,
raw protocol frames, and server runtime metadata must never enter local
diagnostic logs. In-memory logs use bounded ring buffers with filtering and
sorting outside the lock. Automatic server ingestion admits only a bounded
warning/error tail, not verbose WebSocket traffic. Connection
toasts and compact in-chat error pills remain the immediate attention surfaces;
worker execution failures belong in the server-owned Engine Dashboard inbox.

The final Settings row exposes Logs in every build configuration.
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
  -only-testing:TronMobileTests/SessionContextPresentationTests \
  -only-testing:TronMobileTests/WorkerConsoleInteractionTests \
  -only-testing:TronMobileTests/WorkerConsolePresentationTests \
  -only-testing:TronMobileTests/WorkerConsoleViewModelTests \
  -only-testing:TronMobileTests/ResearchSuiteViewModelTests \
  -only-testing:TronMobileTests/SettingsParityTests
```

Architecture changes must update this document with the source and focused
tests in the same commit.
