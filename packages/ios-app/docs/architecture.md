# iOS App Architecture

> Last verified: 2026-08-09 for authoritative/cached chat loading, durable
> native user input drafts, session model configuration, staged worker-console
> projections, cohesive sheets, and iOS 26/27 delivery.

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
Composer text and unsubmitted `request_user_input` choices are the only
device-owned drafts in that database. Question drafts use a separate keyed
table so transcript cache replacement cannot erase them; submitted answers and
pending request truth remain server-event-owned.

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

The authenticated hello response also negotiates native capabilities. Terminal
is advertised as `terminal.v1`; it is a fixed client/engine seam, not a
model-callable primitive or worker. `TerminalClient` uses native-client-only
typed operations for list/open/write/resize/terminate, while `terminal.attach`
and `terminal.detach` multiplex ordered base64 PTY bytes over the existing
socket. `DefaultTerminalRepository` projects capability, terminal metadata,
attachments, and ordered stream updates into UI-safe values. Session and UI
code depend on that repository and never reach through the composition root to
the concrete engine transport; the repository is recreated on every server
switch so it cannot retain a stale socket owner.
The client applies sequence numbers exactly once, reattaches from its last
applied sequence after a foreground/network epoch change, and rebuilds the
renderer from a server checkpoint if its cursor fell behind bounded replay.
Closing the sheet detaches without killing the shell; explicit termination owns
process shutdown. SwiftTerm is only the VT renderer/input adapter—session
directory authority, PTY lifecycle, replay, and retention remain server-owned.
The renderer has a transparent native surface inside the standard sheet rather
than mounting a second opaque canvas. Tron replaces SwiftTerm's ambiguous stock
accessory with one floating Liquid Glass command bar, a separately labeled
extended-key keyboard, and an independent keyboard-dismiss action. The command
strip clips at both capsule edges and scrolls inside a bounded viewport, while
the dismiss action occupies a fixed trailing region and therefore never scrolls
offscreen. The terminal pane begins directly beneath the standard toolbar; it
does not duplicate the absolute workspace path or a textual connection label.
Instead, a typed connection phase drives a compact status dot immediately before
the Terminal title (emerald when attached, amber while connecting or recovering,
and red when unavailable), with the same state exposed as an accessibility value.
The overflow menu presents retained terminals as timestamp-only choices and calls
the destructive user action **Quit Terminal**; termination remains the protocol
term for the underlying process-group shutdown operation.
The bar's safe-area inset retains explicit clearance above the glass
so the terminal's final row does not touch the controls. Input stays
PTY-authoritative—there is no incorrect local echo—but not-yet-submitted bytes
coalesce behind the one in-flight idempotent write, avoiding a network round
trip queue for every character in a typing burst.

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

The server admits correlated engine invocations concurrently through one
bounded, connection-owned task set. A slow notification or database operation
therefore cannot stop the socket read loop from admitting an independent
session resume, reconstruction, or subscription request. Responses may finish
out of order and are matched only by correlation ID; socket teardown cancels
and drains every admitted invocation within a fixed bound.

The canonical client connects on every cold active launch when a paired server
exists; opening a chat is not a prerequisite for Settings, artifacts, worker
state, notifications, or the session index to become live. A failed first live
upgrade joins the same unbounded foreground reconnect owner used after an
established socket loss. Each probe has a ten-second cold cellular/VPN route
budget, URLSession waits for connectivity within that budget, and failed
probes retry after two seconds. Backgrounding remains the hard stop for that
loop.

Read and write recovery are deliberately different. Ordinary side-effect-free
engine projections wait for a usable foreground transport and, if their socket
epoch fails, replay only after a different ready epoch exists. A
request-discovered broken socket also establishes the shared recovery owner
before waiting. Presentation-critical chat reconstruction is the deliberate
exception: its resume, live-tail subscription, and snapshot each use one bounded
request budget, and the snapshot is scoped to the current transport epoch. The
chat coordinator already owns ordered backoff and retry, so transport-level
waiting there would strand the composer without producing an outcome. Explicit
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
Every request after connection establishment finishes within the shared
session-synchronization budget; a transport epoch loss returns a retryable
outcome instead of suspending behind the global read-recovery owner. Healthy
local-server responses still commit immediately, while a genuinely slow route
continues through the same bounded reconnect/backoff state machine.
The shell's short presentation budget may reveal already cached or empty UI,
but it never changes history state to failed. Only an authoritative
reconstruction outcome can present Conversation unavailable, so a busy but
still-live connection remains truthfully labeled as synchronizing.
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
Dashboard remains profile-scoped, while Manage Session supplies its exact
session and provider-request identity for per-turn routing evidence.
Strongly typed catalog DTOs expose the complete executable fixed-tool
inventory, catalog revision, surface hash/counts, function/worker versions,
every published worker's promoted/projected state, selection evidence, and
canonical worker inventory. The compact `workerArchitecture` projection is
derived by the server from active immutable bundles and includes exposure,
runner, hooks, client boundaries, triggers, dispatch routes, `agentTools`,
suite, health, version, and provenance. The Engine dashboard merges that
architecture into each canonical worker row and detail: rows identify health,
direct/delegated agent exposure, declared engine-hook ownership, and runner
kind together in one left-aligned bottom tag row,
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
- `WorkerResultDTOs.swift` for result references, chunks, child descriptors,
  and the authenticated result-handoff response for
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

The lightweight summary lane loads one authoritative profile-level engine
snapshot once per server owner and reuses it when the dashboard opens or its
detent changes. Activity and Results are independent, lazy projections:
Activity reads one bounded run page and Results reads one bounded complete
inbox page, each only when first selected or explicitly refreshed. If the
summary is still cold, that section co-loads the snapshot rather than issuing
a second request. Neither tab queries the other's ledger, and ordinary section
switching never re-inspects a selected worker. Selecting a worker concurrently
loads its inspection, bounded runs, and complete bounded result ledger; current
attention is derived from those canonical results. Temporary disconnects keep
the last authoritative projection visible and read-only. A changed connection
continuity or server owner performs one explicit reconciliation.

Monitoring subscribes from each worker topic's current durable tail, coalesces
the adjacent facts produced by one run, and then reloads only the owning
projection. It never replays historical worker events into UI invalidation.
Invocation invalidations retain every
durable originating-session identifier seen during the 200 ms coalescing
window; lifecycle invalidations stay global and sessionless invocations do not
refresh an unrelated Manage Session sheet. Refreshes are single-flight; a section
request arriving during a summary read is preserved and runs next, while a
summary request is subsumed by an active section read. Explicit refresh and
mutations reconcile canonical summary/detail truth. Mutations serialize
through the view model's mutation state, call one repository operation, and
reload canonical server truth.

Invocation text is parsed with `JSONSerialization`; malformed JSON remains a
visible error and is not sent. The server remains responsible for validating
the worker's actual input schema.

### Views

The session sidebar contains a compact Engine band showing fixed-primitive, active-worker,
and current unhealthy-worker counts. It opens `WorkerConsoleSheet`, whose
visible product identity is Engine. While the sheet is closed, the sidebar
reloads only its compact snapshot after a live invalidation. While the sheet is
open, Workers and Primitives retain that one-read summary lane; Activity loads
and monitors bounded runs, while Results independently loads and monitors the
bounded durable-result ledger. Switching scopes cancels the old
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

- Workers, Primitives, Activity, and Results modes in one compact cockpit, with Workers as the
  initial operator view; the always-visible
  summary owns profile-wide fixed/worker/current-health counts and any active
  worker-owned engine-policy hooks instead of duplicating them in an Overview
  tab;
- the compiled kernel/product-boundary component map and profile-wide fixed and
  published worker-tool counts;
- every fixed model-addressable function shown immediately under server-owned
  group headings, including host, user interaction, session metadata, worker
  interaction, worker administration, and any future group the client has not
  named yet; grouping preserves server tool order and cannot discard an
  unfamiliar group. Each row exposes its ordinary/specialist/conditional
  audience and request-specific availability, then
  opens a dedicated detail sheet for its description, identifiers, exact
  schemas, effect, risk, and exposure state;
- every published worker's profile-global availability to agents, without
  leaking unnamed session promotion or queryless relevance diagnostics;
- worker list separated by compatibility ownership: General workers first,
  then Integrated workers whose immutable bundles declare an engine hook,
  native client action, or native client delivery boundary, and finally retired
  workers. Invocation exposure is an independent dimension: a direct chat tool
  is projected into ordinary agent sessions, while a delegated worker runs only
  through another agent, worker, trigger, or native boundary. A worker can
  therefore be both direct and integrated (Notification Policy) or delegated
  and integrated (Local Transcription). Rows retain runner
  type, health, active hash prefix, trigger count, and successful-run evidence;
  compact metadata groups retain clear
  separation while keeping each icon visually attached to its text;
- bounded provenance tags with full accessible source labels;
- one generic worker workflow split into Overview, Manage, Activity, and
  Results. Manage combines natural-language use, retained versions, lifecycle
  controls, and a collapsed lifecycle-history disclosure; Activity is only
  execution history, while Results is the independently classified durable
  result ledger;
- native-experience technical detail limited to Contract and Manage so domain
  tasks, reports, runs, and inbox results have one presentation owner;
- readable schema fields and raw-schema detail sheets for inspection, while
  Manage starts a new natural-language chat pre-addressed to the exact worker;
  users never have to construct schema JSON or manually select an invocation
  model before asking the agent to use a worker;
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
  tapping a card opens that detail sheet with toolbar actions. Activity is only
  the execution ledger. Results groups the independent durable ledger into
  `Needs attention`, `Available`, `Used by agent`, and `Resolved` using the
  server's canonical attention and context-attachment fields. Recovery or an
  owned fallback moves an earlier failure out of `Needs attention` and into
  `Resolved`; immutable evidence remains inspectable. Opening a result does
  not pretend to consume it. The engine summary labels its independent
  current-state metric `Unhealthy`, so historical delivery evidence cannot be
  confused with current worker health;
- completed results expose the same direct `Investigate with agent` action in
  the canonical run detail reached from both worker Activity and engine-wide
  Activity, in chat-owned worker run detail, and in Delivery Audit result
  inspection. The action is a standalone primary control rather than a nested
  section container, and every entry point uses the same exact-result handoff
  request;
- one transcript action per distinct agent session, owned by that session's
  worker-invocation node in the execution trace; run detail has no competing
  toolbar transcript action or duplicate Model Context section. The read-only worker-session transcript
  initially reconstructs only the latest 120 events, pages older activity
  explicitly, and uses a small vertical `LazyVStack` without interactive
  chat's viewport probes, geometry-driven autoload, speech monitoring, composer,
  or keyboard-aware scroll loop. A native bottom anchor plus two bounded layout
  passes makes the newest evidence visible. Execution Trace combines causal
  work structure and durable activity in one expandable sequence. Expanding a
  worker invocation reveals its updates and its one transcript action; agent
  and model-turn nodes that share the same session never duplicate that link.
  Each link lazily reconstructs
  the actual prompt, assistant response, provider-visible reasoning summary or
  thinking block, and tool calls from the canonical child session rather than
  copying unbounded text into the run graph. Command-only nodes retain their
  server-authored stage and activity evidence;
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

Only the frontmost worker sheet observes live worker state. Lazy run and result
rows emit selection intents only; the stable containing sheet owns the selected
identity and the single child-sheet modifier. A row can therefore be recreated
by lazy layout without destroying an already loaded detail. Presenting a run,
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

Run lists, causal graphs, Manage Session, and inbox pages never hydrate result
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

Meaningful multi-turn work can include provider-authored progress text before
tool calls and at natural milestones. It uses the same assistant content blocks
as final prose, so live streaming and reconstruction preserve its exact order
relative to thinking and tools. The client does not synthesize progress from a
tool name or expose provider reasoning as a substitute for user-facing text.

`request_user_input` is a fixed foreground agent primitive rather than a
worker-owned feature. Its tool start becomes a typed question message and opens
the standard medium/large native sheet; ordinary tool chips are not duplicated.
If another sheet is active, the latest request waits for that presentation to
dismiss. The sheet supports one to three questions, two or three explicit
choices each, and a custom `Other` answer, using shared sheet chrome and Tron
typography. A fixed status row owns the current page count and dots while each
question and its choices occupy one horizontally swipeable page whose vertical
content scrolls independently. Only the question content moves during a page
gesture; page position updates in place. Compact choice spacing and independent
rows keep the sheet concise, while compact detents, the keyboard, large text,
and a multiline `Other` value cannot clip the final choice. Pending presentation
uses the warning accent; answered presentation uses
the success accent and restores the selected values as non-interactive audit
rows. A successful tool completion is the durable pending marker. The
sheet admits choices immediately but enables submit after any one question has
a valid option or non-empty custom response and after the producing agent run
releases its ordinary session guard. Unanswered questions are omitted from the
submission in canonical question order. Closing the sheet retains its unsent
selection draft in a small app-local SQLite row keyed by session and
invocation, so leaving and reopening the chat does not discard work. The draft
is reconciled against current question IDs and option labels before reuse, and
only a successful canonical submission clears it. A newly received live
request auto-presents once; reconstructing an older unanswered request restores
its tappable chip without reopening the sheet. The same local row records that
the request has already auto-presented, closing a reconnect race in which a
replayed live start could otherwise reopen it. Manual chip taps remain
available for every durable state: pending requests reopen their editable
draft, while answered and failed requests open their canonical read-only audit
pages. Only automatic presentation applies the pending/one-shot gate. Submit
first restores the live
session subscription, then invokes the session-scoped
answer function with invocation-derived idempotency. The server validates the
non-empty answer subset against its persisted questions, appends one structured user event, and
starts a new run. Live state, cached reconstruction, pagination context, app
foregrounding, reconnect, and server restart therefore derive pending/answered
presentation from the same canonical events. The structured answer event is
folded into the original request card instead of producing a redundant second
chat message. Its compact tool-style pill changes to `Answered N questions`
without duplicating question or answer detail; tapping it reopens the same
read-only pages with all context and saved selections. There is no client pause
object or blocked network continuation. Delegated background workers never
receive this foreground primitive and return missing information to their parent
agent.

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
objects become bounded typed forms; fixed primitives use concise operation rows;
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
history. Instead, one compact `Execution trace` disclosure opens a full sheet
that nests each node's durable updates and distinct child-session transcript
  under its server-ordered causal work item. The trace disclosure remains in
  place but cannot present a provisional sheet until that bounded graph is
  available. Work structure, activity history,
and transcript navigation are never rendered as parallel or duplicative
destinations. Live invalidations refresh
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
cancel, terminal-failure retry, child-session inspection, and typed-result
inspection according to server state. Terminal result previews remove
protocol-only schema/status prefixes before presentation. A selected invocation
already contains the bounded request and result preview needed for the first
paint, so loading the richer run graph never replaces the summary layout and no
eager result-field query can make the sheet settle twice. Exact result inspection calls
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
authority. The root result inspector offers a single, directly listed agent
continuation action without wrapping that primary control in another visual
container.
That action calls the authenticated result handoff, whose server transaction
creates the visible session and its exact passive grant together, then saves a
natural-language draft before navigation. The client never assembles an
unbounded result copy. Raw run
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
the presentation critical path. Draft text and attachment restoration has its
own mounted task and publishes atomically only if the composer has not changed,
so attachment file I/O cannot delay reconstruction or overwrite fresh typing.
Manage Session and its worker, delivery, provider-context, and technical
projections start only after their sheets or rows are presented and never join
the chat lifecycle task. A five-second presentation watchdog reveals a usable
cached or empty shell without promoting cached or absent data to authority; the
composer continues to describe genuine synchronization until a bounded attempt
returns. An uncached failure shows recoverable status and continues bounded
reconnect attempts.

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

After a workspace is selected, New Session performs one cancellable,
server-backed `filesystem::inspect_source_control` read for that exact path and
connection continuity. A usable Git working tree reveals a first-level checkout
choice immediately after Workspace: use the existing checkout, create and
switch to a new session branch, or create an isolated worktree. Non-repositories
omit the choice. Source-control presentation is path-owned: while a replacement
workspace is being inspected, an existing Git row remains mounted but cannot
drive actions for the new path. A Git-to-Git result updates that row in place,
while a confirmed non-repository or probe failure removes or replaces it with a
single explicit animation. Late results from a previously selected workspace
are ignored. A connected older server that lacks the bounded inspection
function produces an explicit update-and-retry row instead of being
misrepresented as a non-repository. The app sends only the closed placement
value to `session::create`; the engine owns branch names,
worktree paths, rollback, and durable ordering. A branch/worktree response must
include the authoritative checkout directory, and the app stores that returned
path as both the new session workspace identity and working directory instead
of guessing it from the request.

## Composer and Attachments

The composer owns:

- text and successful-send recent-input history;
- camera, photo, and file pickers;
- native bounded microphone permission, mono PCM capture, metering, and WAV
  encoding when a healthy worker owns the `speech_transcription` client action;
- prepared attachment ids and encoded-size preflight against
  `hello.maxMessageSize`;
- the compact server-derived context progress ring and its Manage Session
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

The composer context ring and Manage Session sheet consume only existing
session truth. Token usage, model-window pressure, compaction, model switching,
and `session::fork` retain their existing owners. The latest
`model.provider_request` event is the sole durable explanation of what a model
received. Chat reconstruction does not query or carry provider-context
inventory. When Manage Session is actually presented, its local cache provides
any available offline overview and `session::context_requests(limit: 1)`
reconciles it independently. The exact manifest is fetched through
`session::context_request_detail` only after the user opens Agent Context or
Technical Details. Agent Context requests a lightweight projection without the
raw provider envelope; Technical Details explicitly requests that audit. Each
projection is cached independently for the immutable event while the sheet is
mounted, so the product-facing view never pays to transfer and decode technical
JSON it does not render. That lightweight projection also reduces the tool
surface to admitted tools/workers and their display evidence; schemas, hashes,
catalog metadata, and omitted candidates stay technical-only.
Exact provider audit bodies never enter the device transcript cache.

Manage Session is deliberately a high-level operation surface. Below its
compact token summary, it renders stable container rows for Agent Context,
Background Activity, Session Workers, Terminal, Fork, and Technical Details.
It does not inline unbounded instructions, deliveries, or worker runs. Every
row remains mounted through disconnects and capability negotiation: an action
that cannot currently run is disabled with a specific reason, then becomes
interactive after reconciliation. In particular, Terminal never disappears
when transport drops or an older server lacks native terminal support.

Agent Context is the product-facing account of the selected request. It shows
ordered instructions without byte counts or digests, conversation previews
with the actual source model, tool, and model-turn facts when available,
background updates included in that exact request, attachments, available
tools/workers, and continuity narratives. `Updates included` means only durable
background worker or agent deliveries admitted to that provider request;
ordinary conversation messages and answers to `request_user_input` correctly
remain under Conversation. An empty update list therefore explains the
distinction instead of implying that loading failed.

Technical Details is the single audit surface. It owns event IDs, invocation
IDs, hashes, byte counts, cache layout, exact selected/omitted tool evidence,
the redacted provider envelope, and provider-visible environment provenance.
Filesystem paths and server origins are redacted before durable audit storage
to prevent personal paths or connection details from leaking into logs and
exports; the technical sheet explains that boundary. No digest, raw identifier,
redacted-path placeholder, or raw JSON appears in Agent Context or the main
Manage Session sheet.

The context-detail response enriches each message inventory entry from its
immutable source events in one bounded, session-scoped batch. These response-
only `sourceModels`, `sourceTools`, and `sourceTurns` fields do not mutate or
duplicate the canonical provider audit. Older servers omit them and continue
to decode with empty arrays. V2/v3/v4 manifests remain readable; historical
automatic-context narratives without explicit delivery evidence remain labeled
as historical system context.

Background Activity and Session Workers are separate progressive-disclosure
sheets. Their view-scoped coordinator owns independent single-flight lanes with
dirty-bit follow-up, session/server generations, retained snapshots, and
cancellation on teardown. Reads activate only after their high-level rows mount;
foreground and reconnect refresh only activated lanes. Active state polls at a
bounded cadence and performs one terminal refresh, while settled state stops
polling. Detent changes do not restart reads. Background Activity separates
active and historical deliveries/waits and opens exact durable results. Session
Workers pages bounded `detail: "graph"` roots and their causal descendants;
opening a run reuses the canonical worker detail rather than creating another
activity store.

`UI/SessionContext/` keeps this ownership visible in source: the main sheet
owns navigation and shared snapshots; loading owns cancellable tasks and exact-
detail caching; presentation owns pure availability and labeling policy; and
the detail/activity sheets render bounded disclosures. Model metadata resolution
accepts qualified, canonical, and alias identifiers, so restored sessions use
the catalog-owned context window. Cross-file extensions share the one sheet
state rather than manufacturing parallel view models or context stores.

Delivery-only assistant continuations render without a fabricated user bubble.
Wake provenance is persisted before thinking, tools, or assistant text and is
deduplicated by delivery identity during live/reconstructed chat. The
`agent_wait_for_workers` chip says `Auto-resume registered` while pending and
does not imply completion. Session mutations remain disabled while disconnected,
compacting, or running a turn. Fork confirmation remains a native animated
liquid-glass sheet. There is no parallel context-control repository, resource/
action audit, memory editor, or fabricated manual compact/clear API.

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
colors. The reasoning control is a native toolbar `Menu`, matching the compact
system menu used by Terminal rather than presenting a custom popover. A
session-owned picker derives that menu solely from the selected catalog row's
exact non-empty `reasoningLevels`, normalizes an old selection to that model's
declared default (or first exact option), and routes the result through a direct
sheet callback. It never fabricates a generic level list or broadcasts a
selection that another mounted session could consume.

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
  Share presents one explicit native activity controller from a bottom sheet,
  so nested artifact presentation does not choose an inconsistent popover
  anchor. It already exposes Save to Files, so there is no duplicate Export
  action.
- Continue in New Chat is the artifact-to-agent bridge. It converts
  already-verified bytes into the existing `Attachment` value and emits the
  same explicit app-local handoff used by workers and results. The root content
  coordinator creates and publishes a new visible session, persists the prompt
  and attachment through `DraftStore`, verifies the saved draft, and only then
  navigates. Handoff creation is single-flight at the app root so repeated taps
  cannot create duplicate chats. Merely opening, previewing, sharing, or deleting an artifact never
  mutates a draft.
  Worker and result handoffs use the same prepared-draft path. After durable
  save verification, `DraftStore` records one app-local presentation intent;
  the next mounted composer places its multiline selection at the final edit
  point and reveals the request suffix without opening the keyboard. Ordinary
  restored drafts retain their existing cursor behavior.
  The client does not interpret worker URLs, paths, HTML, or arbitrary commands.
- The empty Artifact Inbox offers Create through chat. It posts one
  new-session handoff, dismisses Settings, and prefills an artifact request
  without sending it. The user remains in control of the final content, format,
  and submission.
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
