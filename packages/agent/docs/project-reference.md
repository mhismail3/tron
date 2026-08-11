# Tron Worker-First Technical Reference

> Last verified: 2026-08-11 on the worker-first implementation.
>
> The paused `codex/minimal-core-rewrite` feature branch contains an unadvertised
> replacement in progress. Its exact frozen state, known compile failures, and
> restart sequence are documented in
> [Minimal Core Rewrite — Paused Feature Handoff](minimal-core-rewrite-handoff.md).

This document describes the active worker-first implementation.

## Product Model

Tron is a persistent local agent. A Rust service on the user's Mac owns model
turns, session/event truth, authenticated client transport, and engine-global
workers. The iOS app is a thin chat and worker-operations client. The Mac app
packages and supervises the service and owns pairing; it does not maintain a
parallel engine model.

The POC optimizes for one outcome: when a user or agent identifies reusable
behavior, Tron can turn it into working persistent behavior immediately. A
complete worker is created or improved through one `worker_upsert` operation.
Successful activation publishes its version, triggers, routing, and direct tool
as one atomic state change.

## Fixed Kernel

The source-owned kernel retains only:

- model/provider and agent-turn execution;
- local filesystem, process, and HTTP primitives;
- durable session state, events, named-secret injection, provenance, and audit;
- worker bundles, immutable versions, runners, dispatch, triggers, inbox, and
  management;
- authenticated `/engine` transport and loopback token-authenticated worker
  webhook ingress;
- product settings, auth, session-compaction custody, logging, and blobs needed
  by current clients.

The authenticated `filesystem` product domain contains only four iOS
workspace-picker operations (`get_home`, `list_dir`, `create_dir`, and the
bounded `inspect_source_control` repository probe). The probe reports only
whether the selected directory is in a usable Git working tree and its current
branch; it is not a general Git or filesystem API. Model
filesystem work has one owner in the seven direct worker-kernel
filesystem/process/network primitives. Conditional session title mutation is
owned by the Session domain rather than the host or worker kernel.

New-session creation optionally admits one closed source-control placement:
use the selected checkout, create and switch to a new session branch, or create
an isolated session worktree and branch under Tron's workspace state. Branch
names and paths derive from the preallocated session identity; clients cannot
inject either. Git preparation and the durable session insert share one bounded
creation critical section. If persistence fails, the engine restores the prior
branch or removes the new worktree and branch before returning the error. The
created session and response always retain the checkout directory the agent
actually receives, including the selected relative subdirectory.

Higher-level behavior belongs in worker bundles. The fixed tree owns the model
loop, authenticated product transport, durable custody, direct host actuators,
worker execution, and isolated core-change approval. New product behaviors,
including speech-to-text, are authored and validated as workers through real
use.

The execution boundary is intentionally generic. The kernel validates typed
contracts, admits and recovers durable invocations, enforces global and
worker-declared ceilings, preserves causal/idempotency identity, cancels causal
subtrees, delivers inbox results, and projects authoritative run evidence.
Workers own title wording, routing semantics, source and claim budgets,
orchestration strategy, model choice, citation policy, repair behavior, and
presentation vocabulary. iOS renders the server projection and invokes generic
controls; it does not own an execution state machine.

Provider tool calls have a durable `tool.invocation.*` lifecycle. A started row
records the invocation id, tool name, and redacted arguments; output and
completion rows record bounded output, terminal status, error, and duration.
That lifecycle powers live running state, post-restart reconstruction,
interrupted-turn recovery, session summaries, and operator diagnostics. It is
execution evidence for an actual model tool call. It neither grants authority
nor participates in worker discovery, activation, or permission decisions.

The model-facing fixed surface has 24 direct primitives: 13 fixed operations
on an ordinary request, ten specialist administration operations, and the
conditional title operation. The ordinary set includes five host/interaction
operations, three typed-worker operations, and five first-class reusable-agent
coordination operations. Each source definition owns one complete typed
contract containing its canonical function ID, provider name, group, and
stable order; registration, provider projection, introspection, and exact-set
tests consume those definitions without a parallel manifest or reconstructed
partial identity. Every fixed primitive rejects
undeclared top-level input and output fields; closed response contracts keep
provider observations small and mechanically dependable.

The inventory is deliberately explicit. Each operation stays fixed only because
the Engine owns its state transition or because its closed direct form adds
material reliability over an arbitrary process:

| Audience | Primitive | Fixed-kernel reason |
|---|---|---|
| Ordinary | `read` | One bounded UTF-8 file or deterministic directory listing; search and multi-file composition belong in code or Bash. |
| Ordinary | `write` | Atomic publication, stale-write detection, and reusable-assignment write claims. |
| Ordinary | `edit` | Exact bounded replacements with stale/ambiguous edit rejection and the same claim discipline. |
| Ordinary | `bash` | General local composition with bounded I/O/deadlines, process-tree cancellation, and workspace collision leasing. |
| Ordinary | `request_user_input` | The foreground session alone owns authenticated human interaction and durable reply validation. |
| Ordinary | `worker_discover` | Reads the live immutable worker catalog and promotes an exact version for the current session. |
| Ordinary | `worker_invoke` | Admits typed durable work with idempotency, causal topology, version pinning, and recovery. |
| Ordinary | `result_read` | Authorizes and pages integrity-bound assignment or worker results without copying bulk payloads into context. |
| Ordinary | `agent_discover` | Resolves opaque profile agent addresses and reviewed role versions without leaking sessions or workspaces. |
| Ordinary | `agent_spawn` | Atomically creates one stable agent, hidden transcript, first assignment, authority snapshot, and causal node. |
| Ordinary | `agent_send` | Atomically persists typed communication plus any distinct assignment/offer/reply linkage. |
| Ordinary | `agent_wait` | Parks the runtime on durable mixed-result fan-in and closes completion-registration races. |
| Ordinary | `agent_manage` | Centralizes offer decisions and bounded ownership, cancellation, configuration, close, and role-upgrade authority. |
| Specialist | `worker_upsert` | Validates, tests, seals, publishes, and activates one immutable worker version atomically. |
| Specialist | `worker_list` | Reads the canonical profile catalog and health state needed for administration. |
| Specialist | `worker_inspect` | Reads exact immutable contracts, versions, provenance, and bounded operational evidence. |
| Specialist | `worker_stop` | Stops one worker's active workload while preserving future enablement and audit truth. |
| Specialist | `worker_disable` | Changes future dispatch eligibility through the canonical lifecycle owner. |
| Specialist | `worker_enable` | Re-admits a reviewed retained worker without inventing a new version. |
| Specialist | `worker_retire` | Removes a worker from active use while retaining recoverable immutable evidence. |
| Specialist | `worker_rollback` | Atomically selects a verified prior immutable version and records the transition. |
| Specialist | `worker_inbox` | Reads bounded durable worker outcomes and Attention evidence without copying result bodies. |
| Specialist | `worker_runs` | Reads authoritative invocation, topology, timing, usage, failure, and recovery evidence. |
| Conditional | `session_set_title` | Performs the narrow durable session metadata mutation only for an explicit rename request. |

This is the deliberate simplification boundary. The five agent operations
replace the old mailbox/list/claim, worker-only wait, and separate worker
cancellation vocabulary with handles that work across one coordination graph.
The host vocabulary keeps separate read, write, edit, and Bash effects because
their idempotency and collision behavior differs materially. Directory listing
is a read mode; literal search, Git, HTTP clients, pipelines, and transforms no
longer receive one schema each. They are composed through Bash or the sandboxed
code runtime, which is the actual reduction in model vocabulary.

The compatibility bindings `worker_cancel`, `agent_wait_for_workers`,
`agent_mailbox_list`, and `agent_mailbox_claim` remain executable but
are restricted to authenticated native-client actors for one release.
`worker_await` and `worker_result_read` are
also absent from the fixed inventory and ordinary provider surface; only an
immutable retained dynamic-worker `agentTools` allowlist naming either exact
historical name receives a request-local alias to the canonical await or
generic result-read function. The aliases are never registered or discoverable.
`worker_detach` and `worker_purge` remain native-client-only authenticated
operator operations;
neither is ordinary agent vocabulary.

### Unadvertised persistent code substrate

The source tree contains the first unadvertised `code_runtime` substrate; it is
not registered in the function catalog and therefore does not change the exact
provider primitive inventory. It exists so the eventual small code surface can
ship only after process custody, coordination, recovery, and client evidence
are integrated together.

A logical runtime belongs to a stable `agentId`. It is an immutable ordered
journal of successful TypeScript/JavaScript cells in `tron.sqlite`, not a
long-lived JavaScript heap. For every candidate or interrupted-cell recovery,
the runtime uses Oxc to strip TypeScript, assembles every committed fragment
plus the candidate into one fresh ES module, and evaluates that module in a
new QuickJS context. That single-module assembly preserves top-level lexical
variables, functions, and top-level `await` across cells and server restarts.
Only the candidate's success commits it; syntax/runtime failure, cancellation,
and timeout remain durable audit rows and are excluded from later replay.
Journal cell/byte ceilings require an explicit reset or future reviewed
consolidation. Tron never silently snapshots or compacts an opaque heap.

QuickJS receives language intrinsics but no module loader, filesystem,
environment, network, process, credential, or Bash binding. A frozen
`tron.code.v1` SDK is its only authority. It provides the generic broker plus
versioned agent, schedule, service, skill, and state conveniences; Bash remains
the explicit host escape hatch. Every broker call is durably admitted with a
stable idempotency key before execution. Rehydration must match the original
operation and canonical input at every call ordinal and returns the stored
result/failure. Time and randomness cross the same journal. A disposable child
started through the installed binary's hidden `code-runtime-helper` mode
implements a versioned line-delimited protocol, so the server can journal
nested broker results and terminate the physical process without changing
logical runtime identity or depending on a second packaged executable.

Skill discovery starts empty after the clean cutover; no worker bundle or
legacy state is converted. Future agent-authored packages live under explicit
profile or trusted-project skill roots, use a bounded `SKILL.md`, and may expose
single-file `.ts`/`.js` modules with exactly one default export and no imports.
Resolution canonicalizes beneath the package root, strips types, and pins exact
source/emitted digests for the call. Callable modules receive
`default({tron, state}, input)`. Their state handle is forcibly bound to the
engine-derived profile/project skill namespace, including calls attempted via
the generic broker, so a module cannot select another skill's namespace.
Profile and project capability state use separate engine-owned roots and one
SQLite database per namespace. The SQLite authorizer denies attachment, temp
schema, extension/file functions, and internal receipt access while allowing
ordinary schema, transactions, and FTS5. Mutations and their idempotency
receipt commit atomically.

Callable function definitions have no generic metadata map. A closed typed
model-tool contract owns the model name, callability, fixed group/order,
and—only for direct workers—the worker id, immutable version, routing phrases,
update time, and compact provenance. Function contracts do not carry declared
stream topics: durable stream publication is owned directly by the emitters
that perform it. Startup composes one flat executable function set; there is no
parallel domain-module owner record. Each source contract builds the exact
engine function definition once; handler binding derives the local operation
key from that canonical identity. There is no intermediate tool catalog
or unused transport-policy declaration. This removes magic-key discovery and
prevents unproduced flags or test fixtures from changing production routing.
Calls emitted together by a provider execute concurrently. The dispatcher and
individual implementations own actual queueing and concurrency ceilings; the
agent loop has no metadata-driven serialized-wave mode.
The live function catalog is rebuilt at startup and is not itself a wire or
persistence format. Function definitions and setup-only policy types therefore
do not carry inert serialization contracts; durable idempotency and stream
records retain their explicit codecs.

The provider's model-tool invocation id is carried in trusted causal context
when a projected worker is called and persisted at admission with the resulting
worker invocation. The client does not invent or own that association.
Command and resident-service workers report queued, running, and typed-result
validation phases. Agent workers additionally map bounded child turn and child
tool stage labels back to the exact originating chip. These progress updates
are redacted and live-only: child prompts, child output, arguments, secrets,
and file contents remain in their canonical owners. The process-local streaming
bridge is removed at terminal completion; the durable model-tool id, parent
worker invocation, interaction mode, detachment time, and retry link remain
authoritative recovery evidence and do not affect permission or routing.

### Primitive admission rule

A fixed function receives model exposure only when it passes one of two tests:

1. **Kernel custody:** only the compiled engine can own the canonical state or
   protected transition. Worker version activation, routing, and
   stop/rollback are in this class; implementing them as workers would require
   a worker to bootstrap or mutate the substrate that defines the worker
   itself. Secret-returning and engine-wide emergency operations remain
   authenticated-client-only.
2. **Material execution leverage:** a high-frequency operation is theoretically
   expressible through `process_run`, but a direct typed form materially
   improves model success and runtime reliability. The filesystem primitives
   add bounded reads/listing/search, exact stale-write detection, atomic
   publication, and closed evidence. `web_fetch` adds URL validation, response
   ceilings, retained-content checksums, and source provenance. Its default is
   intentionally context-safe rather than the maximum supported response.
   `session_set_title` is the narrow explicit session-metadata actuator; it
   accepts only a title, derives the target from causal context, and is
   projected only when the latest user request explicitly asks to rename the
   chat. These are ergonomic or state-custody primitives, not semantic product
   policy.

Each function contract owns one audience: `ordinary`, `specialist`, or
`conditional`. Ordinary chat receives seven worker-kernel host functions,
`request_user_input`, three typed-worker functions, and five reusable-agent
coordination functions. Exact specialist-worker allowlists may receive ten
worker-administration functions. `session_set_title` is conditional on an
explicit rename request. Webhook rotation and engine-wide stop are
authenticated-client-only and have no model projection.

This rejects fixed web search providers,
transcription, memory policy, notification timing/content policy, repository workflows, content
analysis, and other task semantics: those belong in workers. The deterministic
weighted worker ranker is the recovery substrate needed before a relevance
worker is available and while that worker handles its own agent turn. Stronger
embedding or model-based routing is an ordinary persistent worker, not another
mandatory kernel service. No primitive is added merely because it is
convenient, and no direct tool is collapsed merely to make the manifest
numerically smaller.

### Worker-owned engine policy

Higher-level behavior that must run inside an engine lifecycle boundary uses a
small typed worker-hook seam rather than remaining hardcoded. A hook is declared
in the immutable bundle's `engineHooks` array and becomes active in the same
atomic `worker_upsert` publication as its runner, version, tool, and triggers.
There is no proposal/install/bind/grant step and no separately stored hook
configuration. The newest worker declaring a hook owns it while healthy and
enabled; an older implementation never silently replaces a failed or disabled
current owner. An update switches new hook work immediately while prior
invocations retain their version.

The `context_summary` hook accepts a bounded transcript of visible user text,
durable agent-coordination text, assistant text, tool names, and textual tool
results and returns
`{narrative}`. Its public schema limits the narrative to 40,000 characters for
early structural rejection. The runtime authoritatively admits at most 10,000
estimated tokens using the same four-UTF-8-bytes-per-token pre-call heuristic
as the context budget, with a derived 40,000-byte storage ceiling. This is an
upper bound rather than a target: policy workers should normally produce the
smallest brief that faithfully preserves the task. The runtime rejects rather
than truncates an oversize result, disables the failing worker version through
the ordinary failure path, and uses the deterministic recovery summary. Every
accepted narrative is therefore the exact byte-for-byte value used in live
context, compact-boundary proof, and restart reconstruction. Agent coordination
keeps an explicit kind/source prefix while using the established `user`
projection value, preserving compatibility with already-active immutable
summary workers without treating it as end-user intent. Hidden thinking,
tool arguments, binary content, usage, and cost never cross the seam. Calls use
the normal durable worker
dispatcher, causal trace, idempotency, validation, failure-disable, and inbox
behavior. If no hook is installed—or the hook fails—compaction uses the same
deterministic recovery path. A hook worker is excluded while its own
agent-runner session compacts, preventing semantic-policy recursion.
Token-window selection, cancellation, checkpoint restoration, durable
compact-boundary proof, and provider context mutation remain irreducible
kernel custody.

The `continuity_context` hook is the narrow semantic seam for an ordinary
Continuity Curator worker. The worker owns capture, project/global scope,
correction, promotion, tombstones, explicit clear, expiry retention, retrieval,
ranking, and the selected narrative. The engine supplies only the bounded
current-task query and canonical working-directory identity, excludes the owner
from recursively recalling itself, and runs the hook asynchronously after
prompt admission. A result may enter only a later natural turn in its
originating run; if that run has ended, the result becomes stale audit evidence.
Empty output, no healthy owner, or failure contributes no replacement text and
never delays a provider request. Durable worker audit sessions are ineligible
for optional semantic preparation: their kernel-authored execution prompts are
not user task queries and must never recursively launch Continuity or relevance
work.

The initial worker contract uses deterministic hybrid retrieval and returns
matching project records before global records. SQLite FTS5 supplies exact and
prefix recall. A worker-owned 128-dimension feature-hash embedding supplies
bounded fuzzy recall without a model or network call. Embeddings are generated
lazily on search, revision-bound in the worker's SQLite state, and scan at most
5,000 eligible records per query; the engine neither loads nor ranks them. Its
direct Memory tool exposes only capture, search, inspect, correct, promote,
delete, and explicit clear outcomes.
`continuity_context` and its project/query bounds remain in the complete
internal schema and do not enter the direct model tool. Publication validates
the complete 12,000-character engine query boundary against the bundle schema,
and the active worker's own smoke test exercises that boundary so its executable
cannot accept less than it advertises.

Worker selection is deterministic kernel policy. Automatic projection and
`worker_discover` use the same bounded weighted-token and adjacent-phrase
scorer, with version-bound explicit promotions first and recent success/recency
only as later tie-breakers. Provider admission never waits for a router worker.
The historical `worker_relevance` bundle tag remains decode-only so retained
versions can be inspected, but publication, enable, and rollback reject it.

Worker results and legacy compatibility traffic use the durable Agent Delivery
primitive. First-class peer-agent messages additionally have canonical semantic
metadata and materialize as typed `message.agent` events. The engine renders
those events through a trusted coordination wrapper with explicit kind,
authority, assignment, and reply linkage; it does not place actionable agent
instructions in untrusted reference context. Core code owns addressing,
provenance, persistence, safe-turn leasing, observation, wake admission, retry,
and crash recovery.

At session creation, core code performs a cheap mailbox candidate check. When
candidates exist, the `mailbox_curation` hook receives bounded IDs and redacted
previews asynchronously and returns only selected IDs. Core code revalidates and
atomically claims the complete subset. A ready result may join the first natural
turn; a later result waits for another natural turn and never wakes or delays
the initial response. After this one creation-time scan, legacy mailbox list
and claim remain hidden compatibility operations; semantic agent messages use
the first-class coordination protocol below.

### Durable Agent Delivery and resumable sessions

An unadvertised core-coordination successor now exists in `tron.sqlite` behind
no provider or client registration. It is the migration boundary for the
minimal Engine architecture, not a second advertised protocol. A stable
`agentId` owns one persistent transcript and reusable defaults; an
`assignmentId` owns queueing, one-at-a-time execution, attempts, causal
parentage, waits, terminal state, and result custody. There is deliberately no
third execution identity and no worker kind, direct-worker adapter, role
version, or skill assignment in the new model.

Root identities are lazy and deterministic. Child admission creates the hidden
`tron.system.agent-session` transcript, stable child row, and first assignment
in one EventStore transaction. Reassignment reuses that transcript and orders
offered/queued work FIFO. Small results remain inline, large results use the
existing content-addressed blob store, and terminal assignment state commits
with wait reconciliation plus Engine-derived safe-boundary wake intents. Models
never select active/passive delivery: information is passive; actionable
message kinds, unabsorbed results, resolved fan-in, authenticated operator
instructions, schedules, and recovery create durable wake causes. Wake leasing
is at-least-once and restart requeues every unacknowledged lease.

The core message API resolves transcript addresses from opaque agent handles,
derives owner/peer authority from immutable lineage, creates queued work for an
instruction and an offered assignment for a request, and preserves exact
question/answer linkage. Its wait input is structurally limited to assignment
and reply handles. Dependency edges are derived from canonical assignment
parentage and assignment-to-agent execution, so cycle detection no longer needs
Worker execution nodes. This seam remains dormant until the Agent Execution
service, model tools, scheduler delivery, recovery loop, and native projections
can cut over together; current behavior below remains the compatibility truth.

Reusable-agent coordination uses a newer semantic path beside the legacy
worker-delivery compatibility tables. `workers.sqlite` admits stable agents,
assignments, mixed execution nodes, exact results, and message effects first;
an idempotent outbox then records canonical message metadata in `tron.sqlite`.
Recipient transcript materialization happens only at a provider-safe boundary
and atomically binds one typed `message.agent` event. Generalized waits park on
assignment, worker-invocation, or reply handles and reconcile terminal evidence
before scheduling one aggregate wake. A satisfied wait remains recoverably
unbound until that message is recorded and attached, so a crash between
resolution and wake creation replays the same aggregate effect. Neither
database is mutated while a transaction in the other remains open.

Fan-in ownership is recipient-scoped, not a global claim on the target handle.
Only a wait registered by the intended recipient session and stable agent
replaces that recipient's ordinary assignment, worker, or reply wake. An
authorized manager or other participant may independently observe the same
handle and receive its own aggregate result without suppressing the original
delegator's automatic result. That ownership marker survives terminal-outbox
replay; an `any` wait still releases its unfinished members back to ordinary
delivery.

The coordination importer selects only effects whose durable
`next_attempt_at` is due, ordered by due time and admission order. A failed
claim retains a bounded error, attempt count, and next due time, retries with capped
exponential backoff, and becomes a terminal `rejected` row after ten failed
claims. Rejection and kind-specific compensation are one `workers.sqlite`
transaction. Every poison row creates one deterministic operator Attention
item. Poisoned provisioning or assignment-admission effects additionally fail
still offered/accepted/queued work, close an agent that never left
provisioning, and retain the assignment's ordinary result outbox; terminal
result, ordinary message, and projection failures retain exact failed-delivery
evidence without rewriting their semantic truth. Replaying rejection after a
restart returns the same terminal timestamp and does not duplicate Attention or
results. A delayed or malformed row therefore cannot occupy the head of every
batch or strand admitted work; restart preserves the same retry boundary.

Fresh accepted/queued FIFO heads and already-running/waiting recovery are
selected through independent bounded dispatcher lanes. Each fresh-work row is
the oldest eligible head for a currently inactive agent. Thus even a full
recovery page of parked or process-local in-flight assignments cannot hide a
later queued assignment for another agent. The supervisor pages past
process-local owners, unresolved joins, and auxiliary transcript runs before
counting an assignment against its per-pass start budget. Content-free metrics
cover
assignment admissions/states, queue and run duration, message
delivery/redelivery attempts, wait resolution, recovery,
cancellation, coordinated orphan repair, outbox retry/import lag, and terminal
poison rejection. Metric labels use only closed kinds, states, modes, and
outcomes—never agent, assignment, message, trace, or session identifiers.
The exported families are `agent_coordination_assignment_{admissions,states}_total`,
`agent_coordination_assignment_{queue,duration}_seconds`,
`agent_coordination_{messages,message_delivery_attempts,wait_resolutions,recoveries,cancellations,orphan_recoveries}_total`,
`agent_coordination_wait_resolution_seconds`, and
`agent_coordination_outbox_{imports,poison}_total` plus its
`{import_lag,retry_delay}_seconds` histograms.

An unwaited terminal assignment still returns automatically to its requester.
The engine includes the exact JSON in that result message only when it fits the
shared 8 KiB model-tool inline boundary. Every successful result message also
contains the durable `resultReference`, including its content hash and size;
larger results set the inline `result` to null and remain available through
bounded `result_read`. Thus convenience never replaces integrity custody.

Reaching a coordination autonomy ceiling persists one pause state for the
causal trace. Queued agent assignments, queued worker invocations, and pending
coordination effects remain intact but are excluded from scheduling and import;
the pause, owning root session, reason, and timestamps survive restart. An
authenticated operator action explicitly resumes that same trace. A new
user-driven causal trace is independent and therefore starts unpaused.

### First-class reusable agents

Coordination separates three identities instead of treating a child model run
as a disposable session. An opaque `agentId` is the stable address, transcript,
role, lineage, and management subject until explicit close. An `assignmentId`
owns one accepted or offered unit of work, its FIFO state, immutable authority
and resource snapshot, attempts, result, usage, and failure. An internal
`executionId` places that assignment in the same causal topology as worker
invocations. Causal parentage and management ownership are distinct: a peer
request can be caused by its requester while the recipient retains ownership.

Every visible root session receives one deterministic root agent identity on
demand. `agent_spawn` atomically admits a reusable child plus its first
assignment and provisions a hidden `tron.system.agent-session` transcript. The
default model for a child spawned by a visible root follows the model of that
current source session/turn, even when the lazily created root identity still
records an older model. Nested reusable agents instead keep their pinned,
configurable default. The
child becomes idle after terminal work and keeps the same address and chat for
later FIFO assignments. Hidden transcripts are excluded from the ordinary
Sessions index. Authenticated promotion requires the whole nested subtree to be
quiescent, keeps the same agent/transcript/result/lineage identities, makes the
session visible, transfers lifecycle ownership to the user, and revokes the old
parent's inherited management.

One agent runs at most one assignment at a time. Instructions from an owner,
ancestor, operator, or explicit `assign` grantee create accepted assignments;
peer requests create offers that the recipient explicitly accepts or declines.
Questions create exact reply handles, answers bind the original question and
sender/recipient pair, updates enter an existing assignment at the next safe
provider boundary, and information remains passive evidence unless it names a
valid nonterminal assignment owned by the recipient; linked information then
enters at the next safe boundary without gaining instructional authority.
Accepted work is never merged into the active objective. Its semantic message
is immediately durable and inspectable but its delivery remains behind a
durable supervisor latch, excluded from every provider lease. Only after that
exact FIFO assignment enters `Running` and its attempt baseline commits does
the supervisor release the delivery into the assignment-scoped turn. Peer
offers remain ordinary auxiliary wakes until accepted. Queued/offered work is
bounded by the target agent's effective role/configured
`maxQueuedAssignments`, clamped by the live profile ceiling, and is FIFO. The
same effective limit governs model instructions/offers, native retries, and
Team Context's remaining-queue budget.
A normal assignment cannot terminalize while it owns active mixed descendants
or required reply waits; it enters a structured join and resumes when those
dependencies settle.

Each provider turn receives one engine-authored Team Context with the current
agent, parent, active assignment, direct children, recent correspondents,
unread messages/results, exact authority, write claims, and remaining budgets.
Its authority block includes immutable write scopes and effective limits; an
agent authorized to run Worker Forge also receives a bounded source-owned
delegable-tool catalog with delegation and workspace-effect metadata. Team
Context contains at most 32 entries and reports exact overflow from count-backed
durable pages. `agent_discover`
provides a bounded searchable directory of active/idle profile agents and
explicit healthy role declarations. Model-facing results expose opaque agent
and role handles, relationships, status, capability summaries, task previews,
and `canMessage`/`canManage`; they never reveal raw session IDs, transcripts,
result content, credentials, working directories, or another agent's file
authority. Cross-workspace peers communicate through messages while continuing
to execute in their own workspaces.

Agent discovery, native relationship pages, reusable assignment history,
communication history, unread evidence, and correspondent reads continue from
store-owned cursors/counts rather than paginating a capped recent snapshot.
Closed agents are never discoverable by a model; authorized relationship and
audit projections retain them as historical evidence.

Semantic messages are stored canonically in both directions, materialized once
at a safe provider boundary, reconstructed through every later turn and
compaction, and excluded from user-intent routing, title generation, and
user-prompt summaries. Priority is system policy, authenticated user/operator
instruction, owner/parent instruction, peer request, then informational
evidence. A peer message cannot replace a higher-priority objective or enlarge
authority. Provider streams and tool calls are never interrupted; actionable
arrivals schedule the next safe boundary.

Terminal assignment state and its result outbox commit atomically. Small
results return inline and larger values use the same integrity-bound paged
result store read by `result_read`. A result automatically resumes the
delegator even when it did not register a wait. Explicit `all` waits coalesce
unobserved individual completions into one aggregate wake and remain registered
across an intervening question/operator turn; `any` resolves once and releases
the remaining targets to ordinary automatic delivery. Wait admission performs
registration plus terminal reconciliation in one durable operation. The
runtime resolves opaque assignment and worker handles to exact mixed-execution
identities and reply handles to their exact responder agent, then supplies
immutable parent-to-descendant and assignment/direct-agent executor edges to
the EventStore. Its same immediate transaction rejects self,
descendant-to-ancestor, reciprocal-reply, and mixed dependency cycles with
`AGENT_WAIT_CYCLE`; a parent waiting on a descendant remains legal. A terminal
member reconciled during registration contributes no pending edge. Coalescing applies only to the registering
recipient: a third-party manager's wait never steals the requester's or worker
origin agent's automatic completion.

Recovery never replaces a reusable agent or transcript. Startup repairs
incomplete turns, records interrupted attempts without terminalizing their
assignments, accepts an already durable final result without another provider
call, otherwise resumes the same assignment/session, then reconciles waits,
replies, queued work, result outboxes, and resource leases. Retry always creates
a new assignment linked by `retryOf`; it never edits terminal evidence. Default
per-assignment ceilings are 32 turns and 15 minutes, with hard ceilings of 250
turns and two hours. Root graphs additionally bound active children, mixed
nodes, depth, queued offers, messages, and consecutive autonomous wakes. A
limit pause retains every message and result and surfaces
`AGENT_AUTONOMY_PAUSED` to the owning visible task instead of dropping work.

Function contracts declare delegation as `never`, `inherit`, or `explicit`
and workspace effect as `none`, `read`, `scoped_write`, or
`arbitrary_process`. Child authority is the intersection of the parent's exact
grant, source-owned delegability, an optional immutable role ceiling, and the
requested subset. `request_user_input`, client/admin operations, credential
management, and undeclared internals are nondelegable; children return blockers
through coordination messages. Management grants are bounded to exact
`assign`, `cancel`, `configure`, or `close` rights over one owned subtree and
are non-transitive unless independently granted. Quiescence checks for close,
configure, role upgrade, and promotion traverse exact unpaged ownership IDs;
bounded relationship or history pages never decide whether a descendant wait
can be discarded.

`tron.sqlite` owns `agent_deliveries`, `agent_waits`, and
`agent_wait_members`. Delivery provenance and authority are engine-derived:
model/worker payloads cannot select a sender identity, workspace, causal trace,
root, depth, or result grant. First-class agent messages may cross workspaces
only after the Worker Kernel resolves an opaque profile agent handle; the peer
keeps its own workspace and receives no filesystem or tool authority from the
sender. Non-agent deliveries and legacy task creation stay inside the
normalized source workspace; retained profile mailboxes remain the legacy
cross-workspace evidence seam. Every imported communication invalidates both
distinct visible roots, so outgoing and incoming message/contact projections
converge from the same durable edge. A delivery referencing a worker result grants
that full result only to its origin session or claimed target session.

Worker terminal transitions and validated delivery effects enter an immutable
`workers.sqlite` outbox in the same transaction as terminal truth. Import reads
pending rows, releases the worker transaction, commits idempotently to
`tron.sqlite`, then acknowledges the source row. Transient errors retry;
malformed effects, scope violations, deleted targets, and other permanent
failures become rejected evidence plus deterministic Attention in one
`workers.sqlite` transaction. If either write fails, both remain pending for
retry; poison rows still cannot block later rows.
Startup resumes import and exact wait reconciliation even while worker
execution is stopped. Purge is rejected while an outbox row is pending or a
surviving delivery grants result access.

Disabling, stopping, retiring, or failing a worker terminalizes its affected
queued/running invocations as cancelled evidence in the same worker transaction,
including one terminal outbox row per invocation. Startup performs the same
reconciliation for inactive workers. Permanent purge takes SQLite writer intent
and rechecks both nonterminal work and pending outbox rows before removing
canonical state, closing completion-versus-purge races.

The closed internal run trigger is either `UserPrompt` or `DeliveryWake`. Only a
user prompt validates, persists, broadcasts, or displays a user message. A wake
reloads durable delivery IDs and competes for the ordinary session run guard.
Passive deliveries never create a run. Wake deliveries arriving during a run
wait for the requested next-turn/next-run boundary; run release scans again so
arrival cannot be lost in the release race. Delivery insertion reads and
persists the target's active-run identity while holding the same registry mutex
used by run admission and release, so a `next_run` exclusion cannot straddle
that boundary.

Provider preparation leases FIFO at most eight deliveries and remains inside
the existing aggregate request-context byte bound. A persisted v4 provider
audit proves preparation before the stream opens. Only durable assistant-turn
completion marks the lease observed. Setup/provider failure, clean run release,
and startup make unobserved leases pending again for explicit at-least-once
redelivery. No wall-clock lease expiry can race a provider request. User
cancellation demotes wake deliveries to passive; shutdown and ordinary
busy/archive deferrals do not consume attempts. Three true delivery-only
failures demote a wake to passive after bounded retry delays and create one
idempotent operator Attention record. Sender expiry is reconciled to durable
cancellation before mailbox, wake, or grant reads, and an expired delivery
cannot retain result authority. Autonomous wake
propagation deeper than the existing causal limit of 16 is similarly retained
as passive evidence.

Assistant events retain bounded delivery provenance through a multi-turn tool
run so the final visible answer can identify the update that informed it. Each
entry separately records whether it was included in that exact provider turn;
the v4 request audit remains the sole source of truth for the selected request's
`Updates included` count.

The fixed first-class coordination tools are:

- `agent_discover`: bounded profile-wide discovery of addressable live agents
  and reviewed immutable dynamic-worker roles;
- `agent_spawn`: atomic admission of one reusable agent, its durable transcript
  identity, first assignment, exact authority/resource snapshot, and
  provisioning outbox;
- `agent_send`: typed instruction, request, question, answer, information, or
  assignment update to an opaque agent handle; work-bearing messages admit a
  distinct queued/offered assignment in the same transaction as their outbox;
- `agent_wait`: durable `all`/`any` parking over assignment, worker invocation,
  and reply handles, including completion-before-registration reconciliation;
- `agent_manage`: the closed offer, cancellation, close, configuration,
  management-grant, and reviewed role-upgrade union.

Named-role discovery, spawn, model/native upgrade, and the client's
`updateAvailable` projection use the same executable-role check. A version is
eligible only while its worker remains enabled, non-retired, healthy, an agent
runner, and explicitly declared discoverable; inspection and role-review audit
still retain unhealthy or retired evidence without advertising it as runnable.

Idle-agent questions and offers use an engine-owned auxiliary provider run,
not an assignment. Wake selection reserves the target transcript before its
mutable agent state and exact grant are read; run admission atomically consumes
that reservation. Close, configuration, role upgrade, and promotion use the
same non-waiting admission registry across their exact target subtree, so they
reject while an auxiliary run is reserved or active instead of racing its safe
boundary. A successful close permanently blocks new runs for that transcript
within the process and proactively demotes retained pending wakes to passive
evidence; later and recovered dispatchers repeat that reconciliation, and a
closed transcript cannot call coordination tools. Native allowed actions include
this run state but remain hints: every
mutation repeats the atomic admission check server-side.

Cancelling an agent target applies to assignment-free auxiliary work as well as
durable assignments and mixed worker descendants. The exact owned subtree's
transcripts enter one cancellation admission barrier: active tokens are
aborted, a wake reservation cancelled before run admission remains tombstoned
until its engine invocation exits, and fresh wake/run/lifecycle admission stays
blocked through durable execution cancellation and wake demotion. All pending
wakes for those transcripts—including delayed and leased records—become passive
without deleting their audit evidence. Native cancellation counts are
derived from the same uncapped assignment/execution and wake records, with an
uncovered live transcript counted once.

`agent_wait_for_workers`, mailbox list/claim, and ordinary worker cancellation
remain hidden compatibility bindings for one release. `worker_await` and
`worker_result_read` are projected only into an exact trusted retained-worker
allowlist, never an ordinary or reusable-role surface.

New visible tasks inherit the source model and working directory unless a
validated in-workspace override exists. Wait registration commits members
first, immediately reconciles exact worker states, reconciles again on terminal
outbox import, and repeats pending reconciliation at startup. Resolution and
its wake delivery share one Tron transaction, closing completion-before,
during, and after registration races. Every background invocation and replay
receipt gives the same contract: do not poll or call `worker_await`; call
`agent_wait` with a `worker_invocation` target when the assignment must park for
fan-in. Without an explicit wait, terminal work still returns automatically to
the delegator. If a wait is registered after the default passive result has
already arrived, reconciliation cancels an unprepared duplicate and creates one
wake; a result already leased into provider context is reused.

Automatic worker-result delivery is deliberately narrower than “all
background invocations.” It applies only to detached, top-level, background,
session-originated agent work. Every `engine_hook:*` invocation is excluded:
Continuity remains scoped to its originating run, Session Title applies
directly, and mailbox curation uses its explicit claim path. The
same predicate governs success, failure, cancellation, subtree cancellation,
lifecycle interruption, and integrity failure.

Assistant continuation presentation metadata is optional and
backward-compatible. It carries the engine-owned worker ID and presentation
name when available, plus wake policy, safe boundary, and whether that specific
turn was delivery-triggered. Clients can therefore distinguish `Resumed from`
from a passive `Update included` without inferring lifecycle state from message
text.

The `session_title` hook receives only the bounded user prompt and assistant
response from one successfully completed ordinary user exchange and returns
`{title}`. After publishing the canonical ready/session boundary, prompt
completion durably enqueues the hook and does not await worker execution. It
never runs for hidden worker audit sessions, failed or interrupted turns, or a
session that already has a nonblank title. The kernel validates and
compare-and-sets the proposal before committing the worker's terminal row. A
crash therefore redelivers the same idempotent invocation, while a delayed
result cannot overwrite a concurrent explicit title. There is no deterministic
generated fallback: without a healthy real worker, the session remains
untitled. Hook failure enters ordinary run/inbox evidence without changing the
completed user turn.

The one-shot `session_organization` hook is chained only after successful title
finalization; later turns do not enqueue organization work. The title result and
its closed organization-worker dispatch are committed in one `workers.sqlite`
transaction. A failed admission therefore leaves the source invocation under
the existing finalization/recovery path instead of logging and dropping the
organization step after the canonical title compare-and-set. Its ordinary
Session Organizer worker owns proposal policy and preferences, which default
to propose-only. The direct Sessions tool exposes only outcome actions:
organize, set labels, set group, archive, restore, read preferences, and enable
or disable automatic organization. Direct actions name only the target
`sessionId` plus the requested outcome fields; the full canonical session and
hook-only prompt/response projections stay in the internal protocol. Mutation
replay identity comes from the invocation environment. Explicit stored policy
is required before automatic
apply. Labels remain ordinary `sessions.tags`; exactly one group uses the
reserved `tron.organization.group:` tag, and archive/restore reuses `ended_at`.

A successful worker result may admit only a closed bounded
`sessionOrganizationMutations` array: session id, optional replacement labels,
an optional nullable group, and `preserve`, `archive`, or `restore`. Omitted
labels/group preserve canonical state while an explicit null clears the group,
so direct archive or single-field edits cannot erase unrelated organization.
Completion stores the exact intent in `workers.sqlite` in the same transaction
as the terminal worker result. The existing dispatcher then applies one
batch-atomic canonical `tron.sqlite` transaction and records applied, retry, or
failed evidence.
Infrastructure retry uses capped backoff and stale-claim recovery; it never
contains organization policy. System tags are preserved, delete is not
expressible, and direct/replayed application is idempotent.

`worker_upsert` exposes every hook's complete worker-facing input and output
contract in the `engineHooks` bundle schema. That schema is the authoring
authority: an agent creating a hook worker does not need to inspect Tron's
internal databases, credential stores, executable strings, runtime files, or
private transport endpoints. Ordinary temporary source authoring, dependency
acquisition, and smoke tests remain expected worker-creation work.

The same model-visible operation description owns the canonical protocol for
every future worker: optionally inspect public worker context, design the
complete typed bundle from the public schema, author and exercise staged source,
call one atomic upsert, then verify through the returned identity and public
worker tools. Database, credential, binary, lock-file, runtime-file, and private
endpoint inspection are never contract-discovery or activation steps. If the
public schema cannot express required behavior, the agent reports a concrete
engine-contract gap instead of guessing or probing for hidden machinery.

Worker hooks have a sixty-second default lifecycle ceiling. An
immutable worker may tighten that boundary with the generic
`executionLimits.maxInvocationSeconds` field. Timeout and failure of continuity
or mailbox curation remain ordinary durable worker evidence outside provider
latency. A request-scoped hook failure fails only that invocation and does not
globally disable its worker. Agent-runner provider, model, tool, timeout, and
result-loading failures are likewise invocation-scoped regardless of whether
the upstream failure is retryable: none proves that the immutable worker bundle
is broken, and the worker remains enabled for a later retry. Activation,
artifact integrity, command/service execution, and invalid typed output remain
structural failures and still quarantine the broken version.
Agent-runner bundles can declare default `model` and provider-neutral
`reasoningLevel` values. Normal invocations may override either value; admission
validates the effective pair regardless of whether it came from the invocation,
bundle, server fallback, or a retry pin, records requested and effective policy,
and pins the effective pair across retry. Provider-neutral `x_high` remains the
bundle and evidence spelling; OpenAI catalog validation maps it to the
provider's `xhigh` capability name only at the admission boundary. Command and
service runners reject overrides.

Model selection policy remains worker-owned. The current GPT-5.6 convention is
Luna for routine, narrow, high-volume agent workers and Sol at medium reasoning
for complex research, evaluation, or worker authoring. A measured invocation
may explicitly override that default. The engine does not contain a complexity
router, does not automatically escalate Luna to Sol, and does not reserve the
policy for OpenAI: future provider and open-source models enter through the same
catalog-validated bundle default and invocation override contract.
Session title, compaction, continuity, and
mailbox curation preserve causal idempotency because their result may be bound
to a session or trace.

## Worker-First Execution

Worker-first execution is unconditional engine architecture, not a profile
mode. Accepted local user sessions and workers are trusted operators. Direct
host and worker calls carry actor, session, trace, version, and idempotency
evidence into the engine, but those observations do not become permission
gates. Fixed kernel tools are always model-callable, enabled worker tools are
published dynamically, and dispatch starts with the server.

Fixed worker creation, invocation, cancellation, lifecycle, webhook, and
stop-all mutations are profile-owned and deduplicate across the profile. They
therefore work from the profile-level Engine console without a fabricated chat
session. Session actuators, host mutations, and direct worker tools used inside
an agent turn retain session-scoped causal replay.

Operational control remains explicit without disabling the architecture:
per-worker stop/disable and profile-wide stop-all cancel active execution,
stop resident services, and block new dispatch while retaining canonical
bundles, queued work, and history. Remote clients still require bearer-
authenticated transport. Worker webhooks are loopback-only and require their
own rotatable trigger token.

Context compaction remains a session-runtime setting because it governs the
model window, durable compact-boundary checkpoints, restoration, and the
conversation supplied to every tool call. It is not reusable task behavior and
therefore is not a worker contract. Individual workers may define their own
typed execution budgets without owning the parent session's context lifecycle.

## Canonical Worker State

Filesystem bundles are canonical:

```text
~/.tron/workspace/workers/<worker-id>/
├── worker.json
└── versions/
    └── <sha256-content-version>/
        ├── manifest.json
        ├── content.sha256
        ├── dependencies.lock.json
        ├── provenance.json
        ├── verification.json
        ├── files/
        ├── dependencies/
        └── dependency-runtime/
```

`worker.json` is the filesystem-owned active-version and status record. Every
version directory is immutable and addressed by a full tree hash. Its manifest
contains:

- stable identity, name, description, typed tool name, and routing examples;
- JSON input and output schemas;
- runner type and entrypoint;
- source files or durable agent instructions;
- exact dependency sources, revisions, and SHA-256 checksums;
- manual, schedule, engine-event, and webhook triggers;
- typed semantic engine-hook declarations activated with the version;
- logical named-secret bindings only;
- smoke-test and health-check commands plus source provenance.
- immutable presentation identity, contract version, optional suite role, and
  optional closed generic-native section descriptor.

Absent optional fields are omitted, so the human-inspectable manifest can be
passed back to `worker_upsert` directly for proactive improvement.

`verification.json` seals deterministic redacted dependency-install,
smoke-test, and health-check evidence before the version hash is computed.
Activation timestamps live in the append-only `worker_health` ledger rather
than immutable content. Re-verifying byte-identical source therefore reuses
one version while still recording each successful activation. A version must
carry at least one non-empty provenance source record.

The SQLite worker database is rebuildable for routes, bundle discovery, and
trigger configuration but durable for operational history. Startup reconstructs
the catalog from valid filesystem bundles, disables invalid entries, marks each
interrupted delivery attempt `interrupted`, and resets its `running` invocation
to `queued`. Invalid bundle details are emitted as bounded runtime warnings
instead of accumulating another state file. Webhook hashes cannot be
reconstructed, so rebuilt webhook triggers remain disabled until token
rotation.

## Atomic `worker_upsert`

One request carries the complete candidate bundle, an optional predecessor, and
an optional local `sourceDirectory`. A staged source directory is recursively
imported as UTF-8 bundle files under reliability ceilings of 1,024 files and 16
MiB; explicit inline files win. Symlinks and special files are rejected. This
keeps activation atomic without requiring the model to read source back and
reproduce it as JSON. The request schema also carries the authoritative closed
contracts for every supported engine hook, so hook creation stays on this
single direct authoring surface rather than reverse-engineering implementation
state. The same `presentation` object may declare at most 24 generic native
sections: text, status, progress, table, list, public HTTPS link, result artifact,
confirmation, or fixed same-worker action. Result bindings are bounded RFC 6901
pointers hydrated only through `result_read`; fixed action inputs are
validated against the complete owning `inputSchema`. The contract cannot carry
HTML, JavaScript, Swift, arbitrary client commands, arbitrary URL schemes, or
an inline duplicate of the result. The runtime:

1. normalizes a plain direct tool name into the `worker_` namespace, then
   validates identity, schemas, runner configuration, relative paths, trigger
   definitions and deterministic schedule inputs, engine-hook input/output
   compatibility, presentation shape/pointers/HTTPS links/fixed inputs, secret
   names, provenance, and any caller-supplied dependency checksums;
2. chooses the explicit predecessor or detects the closest semantic overlap by
   name/description terms, preferring an update over a duplicate;
3. stages outside the active worker directory;
4. fetches each exact dependency version to `dependencies/<name>`, verifies a
   supplied checksum or calculates an omitted one, and rewrites the staged
   manifest and dependency lock with the actual digest;
5. runs each optional install command inside that dependency's directory, then
   runs smoke tests and health checks from `files/` with the worker dependency
   environment, never the Tron installation environment;
6. writes deterministic redacted verification evidence and seals the staged
   tree with its content hash, reusing an existing byte-identical version;
7. publishes the immutable version, updates `worker.json` and indexes,
   registers triggers, and installs a direct typed tool only when the bundle
   selects direct model exposure;
8. emits redacted lifecycle evidence and returns one-time webhook credentials
   only through the active operation result.

`inputSchema` is the complete runtime contract shared by authenticated generic
invocation, triggers, events, and worker handoffs. Every newly activated direct
bundle must declare a narrow, outcome-oriented `toolInputSchema`; direct calls
must pass both schemas before durable admission. Discovery projects the narrow
schema, while full inspection retains both, so revision keys, occurrence IDs,
acknowledgements, and other engine-owned coordination fields do not become
model-facing ceremony. The full-input fallback remains only for already-active
migration bundles.

`modelExposure` is either `direct` or `internal`, with omitted legacy bundles
defaulting to `direct`. Direct workers publish their outcome-oriented tool.
Internal workers remain active through hooks, triggers, client actions,
declared worker dispatches, and authenticated generic invocation, but are not
returned by ordinary model-facing worker discovery. Changing a worker to
internal atomically replaces its public catalog function with an internal
function using the complete `inputSchema`; it does not create another binding,
grant, registry, or execution path. `toolInputSchema` is invalid on an internal
bundle because there is no ordinary direct projection to narrow.

Agent-runner bundles may declare `agentTools`, an exact provider-surface
allowlist of at most 32 unique model-tool names, each at most 64 UTF-8 bytes.
Omission preserves the migration surface; an explicit empty list exposes no
tools. Activation accepts only names in the current fixed model catalog,
enabled direct or internal worker functions, or the candidate's own declared
tool. For one release, only this immutable `agentTools` field may also retain
the exact historical names `worker_await` and `worker_result_read`; request
projection synthesizes them as aliases of `worker_kernel::await` and the
canonical generic `result_read` implementation. They do not enter the 27-tool
fixed inventory, ordinary requests, discovery, or `agentRole.toolCeiling`.
Different agent-worker roles require different narrow actuator sets; those
allowlists are justified by the worker's executable contract, not by a
hard-coded role inventory. The immutable bundle remains the single owner. Its
list travels as trusted causal metadata
into the existing agent run and filters both fixed and dynamic tools exactly at
provider-surface resolution; it does not add routing, relevance, workflow, or
retry semantics. If a named dynamic tool later disappears, projection simply
omits it rather than broadening authority.
Agent runners also make an explicit reusable-role decision in `agentRole`.
`disabled` records that the bundle is intentionally not a role. An enabled
declaration pins a discoverable display name, collaboration instructions,
model/reasoning defaults, delegable tool ceiling, assignment/child limits, and
natural or schema-validated result mode to the immutable worker version.
Omitted migration bundles are marked `needs_role_review`, never inferred from
runner kind, and never returned by role discovery.

The deterministic review scan classifies each active
immutable bundle: agent runner plus explicit declaration is `declared`, agent
runner plus omission is `needs_role_review`, and command/service runner is
`ineligible`. `engine::surface_snapshot` returns that status and the exact
declaration. Manage Workers groups active `needs_role_review` entries once
under **Review agent roles**. Its queue and proposal history use independent
bounded offset pages with exact totals, so more than 100 migration runners
remain reachable.

Starting a review dynamically selects the current healthy active worker that
explicitly declares the `agent_role_review` engine hook; neither Worker Forge
nor another profile-owned name is hard-coded. The reviewer receives the exact
active target/version, the complete source-owned `agentRole` schema, and a
generated catalog containing only source-delegable tools. Its strict result can
contain only one explicit enabled/disabled `agentRole` plus a bounded rationale.
The Engine persists a proposal that pins target id/version/content hash,
reviewer id/version, the exact reviewer invocation, proposal schema/hash,
rationale, status, and timestamps. Missing reviewer capacity returns a truthful
repair requirement while direct worker invocation continues unchanged.
SQLite writer admission permits only one open proposal for an exact target
version; concurrent starts observe the same winner instead of publishing
competing declarations.

Authenticated native operations list/start/inspect/apply/reject proposals.
Apply requires explicit confirmation, revalidates all pinned provenance and the
unchanged active target, then clones the exact immutable bundle, changes only
`agentRole`, and publishes through canonical worker upsert/activation. Reject,
stale-target detection, and an interrupted apply retain evidence; startup
returns an in-progress apply claim to `proposed` for safe user retry. The
content-free `worker.role_review` event invalidates client projections, and
unavailable/proposed/applied/rejected/stale counters expose workflow health
without role or rationale content. Their exact names are
`worker_agent_role_reviews_{unavailable,proposed,applied,rejected,stale}_total`.

| Native function | Ownership |
|---|---|
| `worker_kernel::role_reviews` | Independently paged review queue, proposal history, current reviewer availability, and server-authored actions |
| `worker_kernel::role_review_start` | Idempotent reviewer execution and durable proposal admission for one exact active worker version |
| `worker_kernel::role_review_inspect` | Exact proposal, declaration diff, immutable provenance, state, and allowed actions |
| `worker_kernel::role_review_apply` | Explicitly confirmed revalidation and canonical immutable publication |
| `worker_kernel::role_review_reject` | Idempotent terminal rejection with retained audit evidence |

Internal worker functions retain `FunctionVisibility::Internal`. Reusable-agent
admission resolves its trusted authority snapshot to exact source-delegable
function IDs; durable agent execution topology without that immutable grant
fails closed before public visibility is considered. Visible root Agents have
no reusable-child topology and retain the ordinary public surface. A retained
direct agent-runner allowlist remains trusted causal input, and execution adds
the exact grant when it selects an internal target. Discovery does not reveal
internal functions, `delegation=never` remains absolute, and every reusable
child call outside its exact grant fails closed.

A sparse background worker may explicitly declare the reserved
`workerWakeup` output and return one closed future wakeup containing an RFC
3339 time, a stable deduplication key, and typed input for the same immutable
worker version. Source completion and the queued wakeup commit atomically.
The dispatcher admits it only after its `notBefore` time and recovers it across
restart. The worker chooses when its next useful reconciliation occurs; the
kernel cannot select another worker, version, trace, session, device, or
credential. Inputs are limited to 64 KiB, keys to 64 UTF-8 bytes, and wakeups
to 366 days, so workers with distant work renew bounded custody without
short-interval empty polling.

Any failure before publication abandons staging and leaves the prior active
version untouched. Existing invocations retain their pinned version while new
invocations route to the newly active version. SQLite index changes commit before
the canonical filesystem pointer, so startup reconstruction returns any crash in
that interval to the prior active version. If the pointer write reports an
error, Tron removes the unpublished candidate before reconstruction, including
its stale version index. Prior versions remain available for explicit rollback.
Every canonical load recomputes the complete tree hash and checks the recorded
`content.sha256`; a changed file or symlink target is an integrity failure.
Runners receive disposable copies under `internal/run/`, so their ordinary
working-directory writes cannot change the canonical version. A detected
out-of-band mutation disables the worker and produces a durable failed run and
inbox result before worker code executes.

## Runners

### Agent runner

An agent worker combines immutable instructions with typed input and output. It
creates a child session through the existing model loop, waits for terminal
session truth, extracts the final assistant result, normalizes JSON, validates
the output schema, and records the result. It subscribes before prompt admission
so even an immediately rejected provider startup yields its concrete terminal
error instead of a false missing-result diagnosis. Worker child sessions live
in the canonical session event store and carry the reserved
`tron.system.worker-session` tag. Ordinary `session::list` pages exclude that
classification so worker internals do not become chat projects; an exact
session ID from the invocation record remains resumable for Engine audit.
Server shutdown clears only reconstructed process-local cache and never marks
retained user or worker sessions archived. The child is aborted if its
parent invocation is dropped by timeout, disable, stop-all, or shutdown. Worker
causal depth survives the agent hop and is attached to every nested direct tool
call.

### Command runner

A command worker starts an executable with the version's `files/` directory as
its working directory. JSON input is written to stdin. JSON stdout becomes the
typed result; non-JSON stdout is wrapped as bounded text. Commands inherit the
Tron user's normal host permissions. There is no application filesystem or
process sandbox. The command is an exact program-and-argument vector, not a
shell expression. Bundle and `sourceDirectory` files are published as
non-executable UTF-8 text, so a script entrypoint names its interpreter
explicitly (`python3 script.py`, `bash script.sh`, and so on). This keeps the
immutable bundle behavior independent of source-tree mode bits and host shell
configuration. A successful command may intentionally ignore its input; Tron
does not turn the resulting closed stdin pipe into a false worker failure, but
all other write errors and non-success child exits remain failures. From this
working directory, a declared dependency named `N` is available at
`../dependencies/N`. The inherited executable search path is augmented with
conventional user, Homebrew/MacPorts, and system locations so a service launcher
cannot hide locally installed dependency or build tools. Stdin and both output
pipes are handled concurrently.
Tron drains all output while retaining at most 4 MiB from each pipe; oversized
stdout fails the invocation instead of allocating without bound or deadlocking.
On Unix the command and every descendant execute in a dedicated process group;
timeout, disable, stop-all, and server shutdown kill the
whole group rather than leaving a background helper running.

### Resident-service runner

A service worker starts lazily on first invocation, may use an HTTP health
endpoint, and receives calls through its configured loopback invoke URL. The
runtime reuses a healthy process for later calls and supervises it between
invocations. An unexpected process exit disables the worker immediately; three
consecutive failed health probes do the same without treating a single
transient probe as terminal. The runtime also terminates a service when the
worker is disabled, retired, replaced, stop-all is engaged, or Tron shuts down.
A resident runs from a service-lifetime disposable
copy and its HTTP result has a 4-MiB hard ceiling. Its dedicated Unix process
group is terminated as one unit, including shell- or service-spawned children.

## Dependency and Secret Isolation

Dependencies support `file://`, `git+https://`, and bounded HTTP(S) sources.
Every dependency requires an exact revision string. A caller may supply an
expected `sha256:<hex>` tree checksum or omit it so acquisition computes and
seals the actual digest. Optional install commands run from the acquired
dependency directory with worker-local Python, npm, Cargo, Ruby, and PATH roots
under `dependency-runtime/`. File contents and symlink targets participate in
the digest. HTTP dependencies stream directly to disk and fail beyond 128 MiB;
the limit is enforced during transfer rather than after buffering the body.

Secret bindings resolve ordinary logical names from:

```text
~/.tron/workspace/vault/<binding-name>
```

Bindings named `provider-<id>` instead resolve that provider's effective named
API key from `~/.tron/auth.json`; for example, `provider-brave` is injected as
`TRON_SECRET_PROVIDER_BRAVE`. OAuth credentials do not satisfy an API-key
binding. This lets search workers consume the same Brave Search and Exa
credentials managed by the Providers UI without copying values into the vault.

Required bindings fail execution when absent; optional bindings permit graceful
operation without a value. Values are injected as normalized `TRON_SECRET_*` environment
variables. Upsert scans against every readable vault and provider-key value,
including undeclared ones, and rejects a candidate containing one. Invocation
input containing a known credential is rejected before it is persisted. Known values are redacted
from verification evidence, runner output, errors, inbox records, events, and
diagnostics. Raw values are never stored in manifests or worker SQLite.

## Worker-Owned State and Profile Recovery

Immutable worker code and mutable worker data have separate custody:

```text
~/.tron/workspace/worker-state/<worker-id>/
```

Command and resident-service runners receive that owner-only directory as
`TRON_WORKER_STATE_DIR`; agent runners receive its resolved path in their
durable instruction contract, and host processes launched by that worker
automatically inherit the same binding. The originating worker identity remains
causal evidence across engine-owned internal agent hops, while those hops retain
their internal system identity. Each worker owns its file or SQLite schema and
transactional migrations. The kernel does not interpret higher-level worker
records. Candidate smoke and health tests receive a temporary isolated state
directory, so activation cannot mutate live data. Update, rollback, disable,
and retirement preserve state.

Before a worker database migration that rewrites or removes existing durable
data first opens a profile, Tron creates and verifies one owner-only,
checksummed `tar.zst` snapshot under `~/.tron/internal/backups/`. Additive
SQLite migrations use transactional DDL and do not synchronously traverse the
profile, so a schema-only app update cannot block server readiness by copying
large immutable worker runtimes. Full snapshots contain settings,
authentication state, vault files, canonical worker bundles/state, and compact
consistent copies of the session and worker databases. Runtime caches, logs,
journals, WAL/SHM files, and disposable process trees are excluded. The
manifest records source home, schema versions, checksums, and restoration
instructions. Operators can use `tron state snapshot`, `tron state snapshots`,
`tron state verify <path>`, and—only while the server is stopped—`tron state
restore <path>`. Restore first moves replaced state into a dated recovery
directory and rolls back if publication fails.

The minimal-core clean break has a separate, deliberately non-restorable
evidence command: `tron state archive-legacy`. It requires the server to be
stopped and publishes a verified owner-only archive containing the session and
Worker databases, worker-authored text source, and mutable worker-owned state.
It excludes `auth.json`, vaults, settings, pairing/platform permission state,
downloaded dependencies and model weights, caches, logs, sockets, and prior
backup chains. Incomplete turn journals and terminal evidence are retained
because they can contain user-visible work that never reached canonical
session history. Credentials and settings remain in their live owned stores
through cutover; the archive is historical evidence, not a mechanism for
reviving the removed Worker runtime. Every retained payload has a declared
byte count and SHA-256 digest, and the command reopens and verifies the
published archive before reporting success. Verification rejects duplicate or
undeclared entries and enforces the same aggregate byte and entry ceilings
before extraction, so a nominal manifest cannot hide additional payloads.

The destructive half is a separate explicit offline operation:
`tron state cutover-minimal-core <archive> --archive-sha256 <digest>
--confirm-reset`. It verifies the exact archive again, persists a pending
receipt, and removes only five closed profile-relative roots: the runtime
database directory, terminal evidence, ephemeral run directory, Worker
bundles, and Worker-owned state. Authentication, settings, vaults, backups,
ordinary workspace files, session Git worktrees, and future capability roots
are not deletion targets. A completed owner-only receipt makes replay
idempotent; a crash after the pending receipt simply resumes the same exact
whitelist with the same archive identity.

Permanent worker purge is similarly recoverable. Before deletion, Tron creates
and verifies an owner-only archive containing the worker's immutable bundles,
mutable state, and operational history. Purge aborts if known credential
material is present. The response reports the archive path and checksum; named
secret values are never intentionally included.

## Dispatcher and Delivery Contract

All invocation sources enter the same durable queue:

- manual invocation, including a model calling the worker's direct tool;
- interval schedules;
- engine stream events whose payload recursively contains the configured JSON
  filter; configured input supplies defaults and matching top-level payload
  keys declared by the worker input schema override them, with no framework
  envelope;
- `POST /engine/webhooks/workers/<worker-id>/<trigger-id>` from loopback with
  `X-Tron-Worker-Token` or `Authorization: Bearer` and optional
  `X-Tron-Idempotency-Key`.

For a webhook, a JSON object body is the worker's direct typed input.
Object-valued trigger input supplies defaults and body fields override them;
Tron does not inject a framework-specific wrapper key.

Delivery is at least once. Tron persists `queued` before execution and records a
numbered attempt whenever a dispatcher claims it. The claim arms one
synchronous drop finalizer, disarmed only after durable terminal commit, so
task abort, panic, or an unhandled post-claim error immediately marks the
attempt `interrupted` and returns its invocation to `queued`. A bounded
dispatcher orphan reconciler is a defense for independently corrupted
ownership. On restart, any unfinished attempt follows the same interrupted
recovery path. Recovery clears an interrupted agent attempt's stale current-child
link before requeueing, allowing the new attempt to attach its own child session
while the interrupted attempt remains visible. Repeated orphan ownership loss
is counted from immutable attempt evidence rather than process memory, so the
third occurrence creates one durable Attention item even across restarts. A
`(workerId, idempotencyKey)`
uniqueness constraint suppresses repeated delivery. The idempotency key,
invocation id, trace, depth, and trigger kind are
also passed to command runners as `TRON_WORKER_*` variables, to agent runners in
their durable prompt contract, and to resident services as `X-Tron-*` headers.
Every run records its pinned version, timestamps, input, output or error, and
inbox result. Schema v7 additionally records foreground/background interaction
mode, detachment time, the originating provider call, the direct parent worker
invocation, and terminal retry linkage. Schema v8 adds append-only generic
stage evidence for queueing, execution, retry/redelivery, validation,
publication, detachment, interruption, and terminal transitions. These rows
describe the existing invocation state machine; they are not jobs or a second
execution owner. Schema v9 adds a zero-based nested-call occurrence per direct
parent and worker. Migration backfills linked historical children in durable
creation order. A recovered agent attempt restarts its per-tool occurrences at
zero, so a regenerated provider call observes the original durable child even
if its transient call id or valid arguments changed. Parent migration still
backfills only when exactly one prior-depth invocation in the trace can own it;
ambiguous history remains unlinked rather than guessed.

An agent runner's durable child prompt includes the invocation input and the
immutable worker output schema verbatim. The child is told that the kernel will
reject nonconforming terminal output, and the ordinary post-run validator still
enforces that boundary. Typed agent execution therefore does not depend on a
worker author redundantly paraphrasing a hidden schema inside its instructions.
An immutable bundle may also declare
`executionLimits.maxInvocationSeconds`, `executionLimits.maxAgentTurns`, and
`executionLimits.maxChildInvocations`. The first applies to every runner kind
and can only tighten the global two-hour wall-clock ceiling; an agent-turn limit
can only tighten the global turn ceiling; and direct child admissions are
counted transactionally against their durable parent. Task-specific source,
claim, citation, retry/repair, orchestration, and model choices remain in the
worker version.

The causal ledger stores trace roots, maximum observed depth, invocation and
suppression counts, and the unique worker/trigger/idempotency deliveries seen in
that trace. Repeated deliveries are returned idempotently without another
execution and leave explicit suppression audit evidence.

Engine ceilings are fixed reliability limits:

| Limit | Value |
|---|---:|
| Concurrent invocations per engine | 32 |
| Concurrent invocations per worker | 8 |
| Non-resident invocation timeout | 2 hours |
| Causal trigger depth | 16 |

Work beyond concurrency limits waits in the durable queue. Direct causal work
beyond depth 16 is rejected before persistence. A matching engine event beyond
that ceiling records a durable terminal-suppression trace and audit entry, then
advances its cursor so an impossible event cannot jam the trigger. Event cursors
otherwise advance only after matching invocations are durably queued; a failure
to persist either an invocation or suppression retains the cursor for retry. If
the typed engine-event projection itself violates the worker input schema or
secret-isolation contract, Tron disables the worker, its route, and its
triggers, records the inbox failure, and advances past that terminal event.
Queue admission acquires SQLite writer intent before reading causal lineage, so
concurrent hook and worker admissions wait for one another instead of failing a
deferred transaction upgrade with `database is locked`.

Successful and failed results enter the durable inbox and emit
`worker.invocations`. Notable pending background results are atomically attached
to the next relevant model turn once. High-visibility system failures such as
tool activation, trigger materialization, and resident supervision participate
in the same one-time attachment path even though they have no invocation row;
foreground manual results remain explicitly inspectable, while a detached or
predicted-background manual result is notable because no foreground caller
received its typed output. Candidate reads, policy-selected claims, and
deterministic recovery enforce that same eligibility rule, preventing a
successful foreground result from being delivered twice. A successful semantic
engine hook is consumed by the engine boundary that invoked it, so its immutable
inbox row is created with `contextAttached=true` and cannot later reappear as
unrelated background context. Hook failures remain unattached Attention until
resolved.

`worker_runs` and `worker_inbox` return compact observations by default: pages
contain at most 20 records. Inputs use bounded previews; every successful
output and inbox result retains its complete integrity-bound
`worker_result_reference` plus concise preview without loading the result body.
There is no raw-result mode in these history APIs. Runs filter
directly by status or `originSessionId`; an invocation inherits the originating
user session of its causal trace, so this filter includes both workers called
from that conversation and nested worker work they initiated. The separate
`agentSessionId` remains child-execution evidence and is never substituted for
the originating conversation. Inbox reads filter directly by context-attachment
state and severity, so routine health checks do not move irrelevant history
into model context. `detail: "full"` is an explicit operator path capped at 20
records and 8 KiB per retained input or error; successful results remain
references. The response reports content truncation and a `nextOffset` when
older records remain.
Run reads also accept exact `invocationId` and `modelToolInvocationId` filters.
`detail: "graph"` pages at most ten causal roots and reconstructs each bounded
tree from invocation, attempt, generic stage, child-session, model-turn, and
inbox evidence. The graph reports foreground/background mode, current generic
stage, child-state counts, queue/execution/wall/model and critical-path timing,
tokens, cost, session links, concise result/error previews, a canonical
parent-linked node list, and separate server-ordered timeline entries. Active
descendant work takes precedence over stale parent evidence. Historical runs
without schema-v8 stage rows remain inspectable through conservative
timestamp/status reconstruction. Domain-specific policy and vocabulary remain
in immutable worker bundles; the kernel and client do not hard-code research
or another worker family.
The Engine Activity UI treats runs as the primary execution ledger. Its
Attention projection contains only unresolved failures and setup blockers.
Successful informational outcomes never become current Attention, including
completed schedule, dispatch, reminder-reconciliation, or other background
history. Detached top-level results may separately produce durable Agent
Deliveries. Retained timeout evidence from the removed historical
`worker_relevance` or `inbox_context` hooks remains failed run/result history
without becoming current operator Attention. This
exception is derived from the hook trigger, failed invocation, result error,
and declared version timeout; invalid typed output, command failure, and every
other hook error remain actionable. A later verified healthy activation or rollback
resolves every older failure for that worker in the live Attention and
agent-context projections. Merely enabling the failed version is not recovery evidence.
Resolution never edits or deletes the failed run or delivery record: both
remain in the complete inbox available through an explicit audit sheet, where
historical `contextAttached` truthfully describes whether an old result was
attached by the removed synchronous path—not whether a human opened the
record. An authenticated operator may instead dismiss one still-actionable
error. That writes a separate idempotent disposition, removes the row from the
live Attention projection, and leaves its inbox, invocation, and result
evidence intact. The native Scheduled view likewise reads one bounded
chronological union of enabled recurring trigger cursors and queued future
invocations; it does not create a parallel scheduler. The run and inbox
ledgers page on
demand, so they remain inspectable without one unbounded transport response.
Durable state remains complete in canonical storage—these are bounded read
projections, not retention limits.

## Reminder, Schedule, and Notification Workers

The working path is intentionally three ordinary runtime-managed command
workers, not three new engine domains:

```text
automation-schedules → automation-reminders → notification-policy
                                                ↓
                              engine relay/direct transport → iOS
```

`automation-schedules` owns reusable `once`, `interval`, `daily`, and `weekly`
time calculation plus a durable occurrence ledger. Its private 15-second tick
keeps daily and weekly rules anchored to IANA-zone wall time, rolls nonexistent
DST times to the first valid minute, chooses the first repeated time, fires an
overdue one-time schedule once, and collapses recurring catch-up without moving
future cadence. A due occurrence remains pending and is retried with a new
handoff-attempt key until its target acknowledges the stable occurrence key.

`automation-reminders` owns reminder records, occurrence lifecycle, default
snooze, completion, bounded follow-ups, and stable mutation identity in
worker-owned SQLite. New and updated reminders are `registration_pending` until
the scheduler acknowledges their revision. Existing reminders retain their
local evaluator during migration; local and external clocks converge on the
same reminder-plus-scheduled-UTC occurrence key. Once registration is
acknowledged, the reminder becomes `external_active` and the local recurrence
clock stops. Cancellation is immediately authoritative in reminder state.
Snoozes and follow-ups become scheduler-owned one-time schedules. A private
30-second reconciliation trigger retries only pending commands, policy
requests, and acknowledgements; it performs no recurrence calculation after
cutover.

`notification-policy` deterministically preserves source-authored title/body,
derives bounded deduplication and thread keys, applies the delivery window,
next-recurrence boundary, and 30-day engine ceiling, and emits only fixed
Snooze/Complete plus `onOpen: complete`. Typed quiet hours are disabled by
default. When enabled, policy selects `notBefore` at the next quiet-hours end or
suppresses work whose expiry comes first. It never combines several actionable
reminders into one notification. Policy acknowledges `accepted`, `suppressed`,
or `expired` back to the reminder; duplicate reconciliation attempts retain one
logical notification.

Notification Policy remains direct for the useful immediate-notification
action, whose `toolInputSchema` requires only `title` and `body`. Its complete
`inputSchema` continues to accept the reminder/policy reconciliation protocol,
so scheduling identity, recurrence boundaries, acknowledgement keys, and
transport bookkeeping never become model-facing ceremony.

### Closed asynchronous worker handoffs

A source bundle declares fixed routes:

```json
{
  "workerDispatchRoutes": [{
    "route": "notification-policy",
    "targetWorkerId": "notification-policy",
    "clientResponseOwner": "source"
  }]
}
```

Successful output may contain a reserved `workerDispatches` array of
`route`, `deduplicationKey`, and `input`. Output cannot choose a worker/version,
trace, session, device, response destination, or credential. Activation binds
each route to an active immutable target. Completion validates the selected
target input schema, then atomically persists source completion, dispatch
evidence, causal child linkage, and the queued target invocation. Children use
`worker_dispatch`, inherit trace/origin session, increment causal depth, and
record the source invocation as parent. Deduplication is source worker plus
route plus key. Limits are 32 handoffs, 64-byte route/key values, 64 KiB per
input, and 256 KiB total. There is no synchronous worker RPC, arbitrary event
emission, or cross-engine route.

`clientResponseOwner: source` records the originating reminder worker/version
as response owner while retaining `notification-policy` as producer. Direct
notification emitters own their own responses.

### Closed client delivery

Only a worker declaring `clientDeliveries: ["notification_delivery"]` may emit
`notificationDeliveries`. The array is capped at 32 and permits only
`deduplicationKey`, `title`, `body`, `expiresAt`, optional `notBefore`,
`threadKey`/`sourceRecordId`, fixed `snooze`/`complete`, and
`onOpen: "complete"`. Keys, text, time bounds, and the final APNs payload are
bounded. URLs, raw APNs dictionaries, device ids, custom actions/sounds,
priority flags, media, and generalized device control are rejected. Delivery
intent insertion shares the successful invocation transaction; transport
unavailability becomes durable evidence instead of failing accepted worker
work.

Only a worker declaring `clientDeliveries: ["artifact_delivery"]` may emit
`artifactDeliveries`. Each delivery names a stable artifact id, display name,
closed media type, exact byte size, and a self-only RFC 6901 pointer into the
successful invocation result. The pointer must resolve to base64 content from
that same immutable result; URLs, filesystem paths, active HTML, external
invocation ids, draft mutations, and client commands are rejected. Admission
is capped at eight artifacts and 2 MiB of decoded content per invocation.
Successful invocation completion, immutable artifact metadata, and
content-addressed blob ownership commit in one `workers.sqlite` transaction.
Retries may repeat identical metadata and content, while a reused
worker/artifact id with different content fails atomically.

Worker schema v12 adds `worker_dispatches`, source/producer notification
ownership, `not_before`, target cancellation, and stable transport/provider
request evidence to the v11 notification ledger. Schema v14 adds exact
artifact custody and its storage-attention projection. An installation is active
only when enabled and refreshed in the last 30 days. Each logical delivery fans
out to every active installation. Retryable transport, APNs 429/5xx, and network
failures use bounded exponential backoff with jitter until expiry. Invalid APNs
tokens disable the installation until later registration. Provider HTTP success
is `accepted_by_apns`, never human delivery. Missing readiness creates
sanitized Attention without exposing keys or device tokens. Retention keeps the
newest 500 logical deliveries no older than 90 days with owning targets and
attempts.

Authenticated non-model client operations are:

| Engine function | Ownership |
|---|---|
| `worker_kernel::notification_device_upsert` | Current installation id, paired-server route, topic/environment, permission, and optional current token |
| `worker_kernel::notification_device_disable` | Disable one installation without a general device actuator |
| `worker_kernel::notification_deliveries` | Cursor-bounded logical inbox and authoritative unread count |
| `worker_kernel::notification_delivery_acknowledge` | Idempotent Open/Complete/Snooze or bulk-read mutation |
| `worker_kernel::notification_delivery_status` | Sanitized logical and per-target APNs evidence |
| `worker_kernel::artifact_deliveries` | Cursor-bounded immutable artifact metadata and whole-worker-database storage pressure |
| `worker_kernel::artifact_content` | Authenticated exact-content read with identity, size, and SHA-256 evidence |
| `worker_kernel::artifact_delete` | Explicit idempotent deletion of one worker-owned artifact and unowned content blob |

The first serialized Open, Complete, or Snooze wins across devices. Those
responses mark the logical delivery read and publish a typed
`notification.responses` engine event for the owning worker. `clear_unread` is
the sole bulk exception: it synchronizes read state without completing worker
work. Lifecycle changes publish `notification.deliveries` with the delivery,
source worker/record, causal trace, and sanitized state.

Every engine selects exactly one transport. It never automatically fails over,
because an ambiguous timeout followed by a second provider can duplicate a
push. Relay mode uses the closed Cloudflare provider in `packages/relay`;
direct mode uses local APNs signing:

```bash
scripts/tron auth notifications configure-relay \
  --url https://relay.example \
  --secret-file /secure/path/relay-secret
scripts/tron auth notifications use relay
scripts/tron auth notifications status
scripts/tron auth notifications clear-relay
```

The typed `notification-push` auth entry owns mode and relay HMAC credentials.
The first development start imports complete legacy `TRON_RELAY_URL` and
`TRON_RELAY_SECRET` values only when the typed entry is absent, then removes
them from the launched process environment without modifying `.env.local`.
Configuration changes immediately requeue unexpired configuration-blocked
targets.

The relay exposes only versioned single-target alert and quiet-refresh forms.
HMAC covers method, path, timestamp, stable provider request id, and body hash.
A SQLite Durable Object ledger coalesces retries by provider request id:
accepted terminal results replay, while an ambiguous crash remains blocked
instead of blindly resending. Topic/environment pairs are allowlisted, and
tokens/secrets never enter logs or responses. The allowlist admits
beta/sandbox, locally development-signed Prod/sandbox, and distributed
Prod/production; it rejects every other pairing. A first-seen provider request
is an ordinary optional ledger miss, not a storage error. Engine quiet-refresh
rows also coalesce updates that arrive during an in-flight request and queue the
latest unread count behind that attempt without reusing its attempt number.
Relay deployment is manual.

Direct credentials are the independent typed `apple-push` entry:

```bash
scripts/tron auth apns configure \
  --team-id TEAM_ID \
  --key-id KEY_ID \
  --private-key-file /secure/path/AuthKey.p8
scripts/tron auth apns status
scripts/tron auth apns clear
```

Direct mode signs ES256 provider JWTs with bounded in-memory caching and HTTP/2.
Both modes choose sandbox or production from validated client registration and
send only ordinary alert or quiet-refresh pushes.

## Failure and Recovery

A normal execution failure, timeout, invalid typed output, missing required
secret, or unhealthy resident disables the worker, unregisters its direct tool,
stops its resident process, and records a high-visibility inbox result. Tron
does not silently repair or roll it back.

Operator controls are:

- cancel — terminalize one queued or running invocation, stop only its current
  process/request/child-agent work, and preserve the worker's enabled route;
- stop — cancel the worker's current invocations and resident process while
  preserving its enabled route, triggers, health, and ability to accept later
  work; the action is retained in worker audit and lifecycle streams;
- disable/enable — immediate route and trigger removal/restoration plus
  active-work stop (webhooks restore only when a token hash exists);
- rollback — activate a retained version and rotate any restored webhook token;
- retire — disable routes and triggers while preserving bundles and history;
- purge — as an explicit critical operation, archive then remove a retired
  worker's bundle, state, and operational rows while retaining the purge audit
  entry and returning the verified archive path/checksum;
- stop-all — block new dispatch, cancel active work, and stop resident services;
  queued rows stay visible and resume only after explicit release.

## Provider and Model Runtime

`model.list` is server-authoritative. It projects current cloud catalog facts
and effective local-provider availability; clients do not maintain their own
model allowlist. The cloud registry preserves provider/auth-path distinctions,
aliases, current context and output ceilings, capability flags, price metadata,
retirement state, and recommendation order. A profile's explicit selected
model survives catalog refreshes. Only new profiles receive the current
balanced frontier default.

Session model and reasoning choices are durable engine configuration, not
client-only decoration. `model::switch` atomically updates the session model
and appends `session.model_changed`; `model::set_reasoning_level` validates the
exact level against that session's current server catalog entry and appends
`session.reasoning_changed`. Both reject an active run, deduplicate no-op
retries, and preserve a reconstruction-visible audit trail. A paired client
serializes a model-plus-reasoning commit in that order, reconstructs the latest
effective selection from the server log, and supplies that validated value on
subsequent provider turns. Each changed write also invalidates cached turn
state and publishes the authoritative session event count, so every paired
client immediately enters its normal incremental catch-up path.

Ollama is a first-class credential-free local provider. Its strict
`api.ollama.baseUrl` setting accepts an absolute HTTP(S) endpoint without a
query or fragment and is editable through complete iOS settings parity. A
`model.list` read performs bounded discovery against that endpoint:

- `GET /api/tags` establishes which native model names are installed;
- bounded concurrent `POST /api/show` reads establish tool, thinking, vision,
  audio, family, parameter, quantization, digest, and maximum-context evidence;
- known Gemma 4 models remain visible while the endpoint is offline, but are
  unavailable and carry actionable start/pull guidance;
- installed unknown models become explicit `ollama/<native-name>` choices and
  receive only capabilities proven by `/api/show`; absent evidence falls back
  to text-only, no-tools, and a 16K context rather than optimistic admission.

The runtime uses Ollama's native `/api/chat`, including `options.num_ctx`,
native tool-call history, and separate thinking output. It retains historical
thinking only on assistant tool-call turns, matching Gemma 4's documented
conversation contract. The built-in Gemma 4 E4B and 26B A4B entries request a
conservative 65,536-token working window while exposing their larger proven
maximums. E4B carries audio evidence; both variants carry thinking, tool, image,
and structured-output evidence. An ignored, operator-enabled local test checks
both installed models for discovery, tool calling, JSON-schema output, image
input, and a 32K retained Ollama context. Tron never installs, pulls, starts,
stops, or removes Ollama or its models.

The iOS Providers page shows endpoint reachability and installed-model evidence
alongside model-provider credentials. Its shared model repository retains the
catalog for five minutes and coalesces concurrent Settings, Providers, and
model-picker reads, so opening Providers does not duplicate the bounded live
Ollama discovery already in flight. Explicit refresh still requests current
endpoint truth, and changing the endpoint cancels/disowns any in-flight prior
request before invalidating its catalog. Brave
Search and Exa remain separate named API-key providers because Research workers
consume `provider-brave` and `provider-exa` secret bindings; neither becomes a
model choice.

Cloud provider response opening is bounded independently from response
streaming. If response headers do not arrive within 30 seconds, the ordinary
provider retry policy treats that attempt as a retryable network failure.
Cancellation interrupts the opening attempt immediately. The shared HTTP
client retains its longer total timeout after a stream opens, so slow or long
model answers are not cut off merely to recover quickly from a dead connection
before first response.

## Model-Facing Tools

Fixed kernel operations are direct typed tools. There
is no wrapper operation field. `worker_upsert` publishes the complete bundle
schema—including every runner, trigger, dependency lock, named-secret binding,
test, health check, provenance record, and routing field—to the model. Its tool
description owns the ordered public authoring protocol, command-runner I/O,
automatic checksum locking, and the deterministic `files/` and
`../dependencies/<name>` layout. The optional
`sourceDirectory` transport imports an already-authored local tree without
requiring its contents to be copied through tool JSON.

Prompt ownership follows the same boundary. The static agent seed is a short
statement of behavioral intent, including concise user-facing progress before
meaningful tool work and at natural milestones. Those updates remain ordinary
provider-authored assistant text: the existing stream/event/chat pipeline
persists and renders them in content-block order, and the engine never invents
status prose or exposes private reasoning. Provider request guidance contributes only the
current direct-tool inventory, strict-schema reminder, discovery path, and
immediate post-upsert availability. Exact arguments and execution mechanics
live in typed tool contracts, so adding or changing a worker updates the native
provider surface without editing a second instructional catalog.

The authenticated Engine Dashboard snapshot carries fixed-tool schemas once,
plus the selected-surface revision/hash/counts and compact worker-routing
evidence. The provider-only selected tool contracts are not duplicated into the
client payload.

### Host primitives

| Model tool | Engine owner | Purpose |
|---|---|---|
| `read` | `host::read` | Bounded UTF-8 file read or deterministic bounded directory listing |
| `write` | `host::write` | Same-directory atomic full write with optional checksum/absence precondition |
| `edit` | `host::edit` | Exact occurrence-checked UTF-8 replacements with optional checksum and atomic publication |
| `bash` | `host::bash` | Trusted local Bash composition with bounded output/deadline and process-tree custody |
| `request_user_input` | `agent::request_user_input` | One to three necessary native questions; a successful request ends the current run until a structured answer starts the next run |
| `session_set_title` | `session::set_title` | Explicit user-requested title update for the current causal session; absent from unrelated provider turns |

`bash.stdin` accepts either a string for exact bytes or a structured JSON
value that the engine serializes exactly once. Agent workers that call JSON
helpers pass the object directly; manually embedding encoded JSON in a string
adds an avoidable syntax and escaping failure boundary.

The function catalog owns a closed workspace-effect class for each primitive.
For reusable-agent assignments, `write` and `edit`
resolve only canonical workspace-relative targets covered by the assignment's
immutable write prefixes. They reject `..`, symbolic-link escapes, and
case-ambiguous paths, then acquire a durable exact-path reservation. Disjoint
paths may publish concurrently; overlapping paths queue in conflicting FIFO
order. An earlier whole-workspace process waiter blocks later writers so it
cannot be starved.

Every `bash` call associated with a durable workspace acquires that
whole-workspace process lease before spawn and releases it only after the
captured process tree exits or cancellation synchronously signals its group. A
private pre-exec gate prevents user code from running until the direct-child
PID and OS birth identity are committed, so a crash between spawn and durable
binding cannot leak an uncoordinated writer.
Ordinary root tasks use their durable session ID as claim custody; Tron does
not invent a child assignment or tool grant for them. Startup cancels orphaned
mutation claims, closes any unbound process gates, and compares a captured
process's durable OS birth identity with the live process before signalling its
recorded group, avoiding unsafe PID-reuse matches. This is collision
coordination, not a sandbox: `bash` retains the local user's normal
authority and may write outside the declared workspace.

File reads, directory listings, writes, and edits execute off the async
runtime thread. Reads never load the remainder of a truncated file; listing
never accumulates an unbounded directory; writes stage, sync, recheck the
observed prior state immediately before publication, rename within the target
directory, and sync that directory. `edit` rejects stale or
ambiguous replacements before touching the target, so agents can edit a small
region without echoing an entire file through tool JSON. Mutation contracts
reject empty checksum strings before execution: callers omit the optional
field for an unconditional write, use the exact `absent` sentinel only when a
new file is required, or provide raw/`sha256:`-prefixed 64-digit hex.

### Worker operations

Ordinary chat always receives `worker_discover`, `worker_invoke`, generic
`result_read`, `agent_discover`, `agent_spawn`, `agent_send`, `agent_wait`, and
`agent_manage` alongside the host/interaction primitives.
Broad worker creation, inspection, lifecycle, and global audit tools are
specialist-only and appear only in an exact agent-worker allowlist.

| Model tool | Engine function |
|---|---|
| `worker_upsert` | `worker_kernel::upsert` |
| `worker_discover` | `worker_kernel::discover` |
| `worker_list` | `worker_kernel::list` |
| `worker_inspect` | `worker_kernel::inspect` |
| `worker_invoke` | `worker_kernel::invoke` |
| `result_read` | `worker_kernel::result_read` |
| `worker_stop` | `worker_kernel::stop` |
| `worker_disable` / `worker_enable` | `worker_kernel::disable` / `enable` |
| `worker_rollback` | `worker_kernel::rollback` |
| `worker_retire` | `worker_kernel::retire` |
| `worker_inbox` / `worker_runs` | `worker_kernel::inbox` / `runs` |

`worker_webhook_rotate` and `worker_stop_all` remain authenticated dashboard
operations and are intentionally not model tools.

`worker_kernel::result_handoff` is a separate authenticated paired-client
operation, not model vocabulary. It atomically creates one visible chat and a
passive Agent Delivery grant for one completed invocation. Exact result bytes
remain in the worker ledger; the new agent uses `result_read` for only
the paths it needs. Retrying the same client action cannot create a second
session or grant, and the result invocation is retained as provenance rather
than being presented as the root of a new causal worker tree.

`worker_runs` keeps one bounded operation for both human inspection and worker
evaluation. Its `metrics` detail returns only the exact requested invocation's
status, immutable version, resolved model/reasoning, wall timing, and
descendant-inclusive usage/cost. Evaluators therefore do not have to retain a
large causal graph merely to record one case's measurements.

The ordinary main-agent surface always contains the narrow coordination set:
`worker_discover`, `worker_invoke`, generic `result_read`, and the five
first-class agent operations above. Cancellation is unified under
`agent_manage`; durable fan-in is unified under `agent_wait`. Worker run audit,
mailboxes, lifecycle, rollback, retirement, purge, explicit detach, and the old
worker-specific await/cancel/read aliases remain specialist-, client-, or
one-release compatibility operations. This lets an explicit known worker ID
take the direct durable invocation path without requiring an intermediary
delegate while keeping broad worker administration out of unrelated requests.

`worker_invoke` defaults to `mode: wait`. Top-level agent runners are admitted
in background mode immediately. Command/service versions with five completed
samples use exact-version wall-clock p95: a p95 over ten seconds begins in the
background; otherwise the call receives at most ten seconds of foreground
grace. Unknown command/service versions receive the same grace. Crossing that
budget atomically detaches the already-admitted invocation—its idempotency key,
attempt, version, and execution continue unchanged. Ten seconds is the model
tool's conversational handoff budget, not a worker timeout; the independent
two-hour reliability ceiling still bounds execution. `mode: enqueue` returns
immediately after durable admission for top-level and nested callers. The child
retains its mixed causal edge, and a reusable parent assignment enters its
structured join rather than terminalizing while that descendant is active.
Top-level `mode: wait` follows the ordinary interaction budget and may detach
that same durable child. Nested `mode: wait` synchronously joins the typed child
up to the worker reliability ceiling; it is distinct from enqueue rather than a
rule that every nested call is synchronous.
Nested idempotency
identity retains the ordinary typed-argument fingerprint, while a separate
durable parent/per-tool occurrence slot handles reconstruction. If a parent
attempt is reconstructed after restart, occurrences restart at zero: an
already completed child is replayed and an active/recovered child is awaited
even when the provider regenerated its call id or valid arguments. Neither
state admits a replacement invocation.

The ordinary dispatcher remains restart recovery for every background child.
The retained compatibility `worker_await` observes for at most the same
ten-second interaction budget and never cancels work. It remains callable by
authenticated clients and is synthesized for an exact trusted legacy
`agentTools` allowlist, but never enters the ordinary surface; `worker_detach`
remains an authenticated client operation that explicitly releases foreground
ownership without cancellation. `worker_invoke(retryOfInvocationId=...)`
accepts only a terminal run and derives its immutable version and original
typed input server-side. Agents cancel a selected worker execution and its
owned mixed descendants through `agent_manage`; per-worker `worker_stop` and
profile-wide `worker_stop_all` retain their separate operator meanings.

Every successful worker result is schema-validated and has exactly one logical
owner: its durable invocation. The generic payload tables live in the same
`workers.sqlite` transaction. Values at or below the shared 8 KiB boundary
remain inline in `worker_invocations.output_json`; larger values become
SHA-256-addressed, zstd-compressed blobs and the invocation column holds only
an internal payload envelope. Both forms have an ownership row, digest, byte
size, and preview. Successful inbox rows contain compact
`{status, reference, preview}` receipts rather than a second output copy.
Reference previews prefer conventional `summary`, `answer`, `report`,
`result`, `message`, or `title` text and otherwise describe only the JSON
shape. They never copy the first bytes of an arbitrary serialized result back
into run lists, receipts, or model context.
Run-graph request previews likewise prefer conventional user-authored
`question`, `query`, `request`, `prompt`, `task`, `topic`, `title`, or `action`
fields. Structured worker input remains available as technical detail, but the
primary client summary never needs to render its serialized JSON object.
Timeline ordering is chronological with lifecycle ordering for equal-time
admission facts, so an atomically recorded queued transition appears before its
detached transition rather than being alphabetized by display text.
Provider-facing fixed invoke/await records contain references. A synchronous
direct-worker result at or below 8 KiB is integrity-verified and hydrated in
its exact worker schema for the immediately following provider turn; larger
and background results are references or receipts immediately. Session tool
completion evidence stores the provider-call association rather than another
typed body. Once the provider accepts the request, all retained history, run
graphs, Manage Session, and inbox reads expose references and previews only.
An internal kernel projection resolves associations within the originating
session or causal trace. It is not model vocabulary, and a missing or corrupt
fresh association fails the turn before a provider request. Provider-call
identity is a many-to-one relation with the canonical worker invocation:
restart redelivery may produce a new provider tool-call id while the durable
nested parent/per-tool slot intentionally reuses its completed or recovering
child. The kernel records that new association before returning the reused
child, so both the pre-restart transcript and the reconstructed attempt resolve
the same result without copying it or rewriting history.

`result_read` retrieves one RFC 6901 JSON pointer/page from an exact durable
worker-invocation or reusable-agent-assignment result.
Array/object pages are limited to twenty entries and each response is bounded
to 32 KiB; oversized objects return child pointers before content. An agent
worker may read an exact direct child that its own durable invocation admitted.
Other agent and worker reads must remain in the originating session or carry an
explicit Agent Delivery grant, while authenticated paired operator clients and
system recovery can inspect profile-local results without fabricating a
chat-session context. A
worker may accept and forward a result reference in its own input schema so a
coordinator does not have to copy one specialist's complete output into every
later child and model turn. That schema can constrain downstream reads to
explicit RFC 6901 paths; the receiving worker verifies the returned reference
identity and uses only those pages. Missing, unauthorized, truncated, or
mismatched pages remain actionable worker outcomes without causing a root read.
The complete bounded page is available to the immediately
following model turn. On later turns the provider transcript carries only its
integrity-bound result reference and exact pointer/page coordinates; a worker
can explicitly re-read that page if it still needs the bytes. This projection
and the provider, token-estimation, compaction, and restart inputs are derived
from the same durable transcript and invocation evidence rather than client or
runtime shadow state. Path selection and interpretation remain worker-owned;
the kernel has no source, claim, citation, or report vocabulary.

Artifact delivery reuses this canonical result-reference pipeline instead of
inventing a second upload channel. Admission resolves the declared pointer only
from the completing invocation, validates the exact bytes, and gives the
content-addressed payload a durable `worker_artifact` owner. Client reads return
the stable artifact identity, declared metadata, exact base64 content, and hash;
clients must verify all four before preview or export. Artifact bytes persist
until an explicit authenticated delete. Storage pressure is computed from the
whole worker database, not only artifact rows, and crosses into Engine Attention
once per transition so retries cannot flood the attention ledger.

`worker_inspect` defaults to `detail=contract`: the active input/output schemas,
runner contract, routing, provenance, presentation, bindings, triggers, route,
and immutable version summaries. It omits source-file payloads, smoke/health
commands, audit, and health history so ordinary discovery does not consume
model context with operator evidence. `detail=full` returns the complete
immutable bundle metadata and bounded operational history; operator clients
request that mode explicitly.

Every enabled worker with `modelExposure: direct` is registered as a stable
typed tool using the bundle's `toolName`, declared `toolInputSchema`, output
schema, description, routing metadata, provenance, version, and recent success
evidence. Internal workers stay visible to operator inventory and the generic
worker console. Their same-catalog internal functions use the complete
`inputSchema`, do not participate in ordinary provider relevance ranking or
model-facing discovery, and enter a worker agent session only by exact
`agentTools` name.

Tool lifecycle events copy immutable presentation evidence from the exact
advertised function contract. Fixed operations identify their core primitive
group; direct workers identify their worker id, name, version, and runner kind.
This metadata is observational rather than authoritative: it cannot change
routing or execution, but it lets clients present core execution and worker
progress differently without parsing model-facing names or maintaining a
second tool catalog. Result-owned presentation hints may add visual detail
without erasing the pinned fixed/worker identity.

Exact non-worker tool output remains in durable session evidence. Exact worker
output remains only in the invocation ledger for every size; session evidence
retains its provider-call association, receipt, or reference. Consumed
`result_read` pages age to re-readable references after one model turn.
Other textual tool results larger than 32 KiB are replaced in model context by
a deterministic prefix/suffix projection carrying the original byte count and
SHA-256 digest. The same projections are applied before token estimation,
compaction, and reconstructed provider requests, so persisted process, file,
web, or worker evidence cannot repeatedly grow a resumed turn. These provider
boundaries do not reduce the complete operator/audit record.

The provider-visible function description contains only version-stable purpose,
active version, and provenance. Success evidence lives in a durable, rebuildable
observation overlay. Completing a run updates that overlay rather than
re-registering the function, so ordinary success cannot increment the catalog
revision or stale an in-flight provider surface. Worker health remains in
canonical worker state and inbox history; failed workers are unregistered, so
the callable catalog has no duplicate synthetic health state.
Semantic routing receives the canonical immutable bundle description instead
of this augmented provider-facing description, so active-version, provenance,
background-delivery, and polling instructions do not inflate model input or
bias relevance.

### Inspectable provider context

Every model request is explained by the existing append-only
`model.provider_request` session event. Format
`tron.model_provider_request.v4` adds durable Agent Delivery evidence to the
provider-neutral `contextManifest` beside the already bounded, redacted
provider envelope. V2 and v3 remain readable. This does not introduce a second
context table, retention policy, cache, or registry; the turn runner persists
the event before opening the provider stream.

A turn-local context assembly is the only writer for provider context. Stable
system content contains base instructions, environment, and one compact
engine-surface guidance block; it never embeds catalog revisions, hashes,
worker lists, selection reasons, run counts, or duplicated tool schemas.
Eligible durable deliveries and any ready asynchronous continuity output are
encoded together in one final engine-authored reference message after durable
conversation history. The wrapper explicitly treats its JSON values as
untrusted reference evidence rather than instructions. It is never added to
the message store or accumulated during replay. Empty, skipped, failed, and
unavailable evaluations add zero provider-input bytes while remaining
auditable. Finalization verifies the stable contributions exactly reconstruct
the provider-neutral system prompt. It also records:

- every provider-visible message in order, including its content kinds,
  redacted preview, byte count, digest, projection state, durable source event
  IDs, and worker invocation when one exists;
- asynchronous continuity evaluation when one was available for this exact
  turn, without claiming a synchronous policy ran;
- continuity memory ID, revision, and scope evidence returned by compatible
  Continuity Curator versions, without injecting those identifiers into the
  prompt;
- the exact fixed and worker tool surface, immutable worker versions,
  selected/omitted state, routing mechanism, bounded ranking evidence, and
  schema digests;
- redacted environment projections and whole-section digests tying the
  manifest to the final `Context`;
- automatic-context delivery as `reference` or `none`; earlier v3 rows without
  the field remain truthfully labeled as historical system-level context;
- every included delivery ID, source kind, intent, wake policy, boundary,
  redelivery state, bounded provenance, and exact provider-visible content;
- stable-instruction bytes/digest, fixed and dynamic tool counts/schema
  bytes/digests, and request-reference bytes/digest.

Message text remains canonical in the normal session/context pipeline. A
parallel in-memory sidecar carries only event and invocation identifiers;
reconstruction derives it from existing event rows, and projection/compaction
marks genuinely synthetic messages as generated rather than inventing
provenance. Binary/media bytes, credential-shaped values, and hidden provider
reasoning are never copied into the audit. Media is represented by type, byte
counts, and digest evidence.

Provider caching consumes the same partition rather than introducing another
cache owner. OpenAI Platform requests use an opaque 192-bit content-derived
`prompt_cache_key` over the resolved model, stable instructions, and fixed-tool
prefix. It contains no session or user identifier; Codex requests omit the
field, and `prompt_cache_retention` is left unset. Anthropic orders fixed tools
before dynamic workers and emits exactly three possible breakpoints: `1h` on
the last fixed tool, `1h` on the final stable system block, and `5m` on the
last durable conversation block. Request-specific reference context follows
without a marker. Google, Kimi, MiniMax, and Ollama use the same single
reference projection without changing their provider cache controls. Metrics
record bounded context-segment byte histograms, worker selection
mechanisms, cache-read/write token counters, and provider cache-read ratios;
labels never contain request or session identity.
New session aggregates denormalize the immutable `tokenRecord` into mutually
exclusive base-input and cache-read buckets, including for providers that
report cached tokens inside their aggregate input count. Raw provider values
remain unchanged in the event payload; this keeps cross-provider cache
percentages truthful without a second accounting store.

Authenticated clients read this same authority with
`session::context_requests` (reverse-chronological, cursor-paged, limit 1–20)
and `session::context_request_detail` (exact event and session ID). These
operations query only provider-request events and never invoke a model, hook,
worker, or relevance calculation. Agent-worker session IDs use the same reads.
The detail request has a closed `agent_context`/`technical` projection. The
product projection returns the enriched manifest and provider additions but
omits the raw provider envelope. Its tool surface contains only admitted
tools/workers and the fields rendered by Agent Context; exact schemas, hashes,
catalog evidence, and omitted candidates remain technical-only. The technical
projection includes the complete audit. An
omitted projection defaults to technical for existing authenticated clients.
Legacy v2 rows retain their redacted provider audit and counts while
request-specific provenance is explicitly labeled unavailable. The detail
response joins each manifest message's immutable source event IDs through one
bounded, session-scoped batch and adds response-only `sourceModels`,
`sourceTools`, and `sourceTurns` inventories when evidence exists. This gives
clients useful model/tool/turn labels without rewriting the canonical audit,
duplicating message text, or issuing one query per message. Missing source rows
and older servers degrade to empty optional inventories.

The context-request query uses `(session_id, type, sequence)` ordering and one
metadata-only look-ahead row. It resolves blob-backed payloads only for the
requested page, so `limit: 1` never inflates into two full context reads. Current
summaries include instruction, attachment-message, Agent Delivery, and
environment-presence counts; older clients and legacy audit rows remain valid.

Ordinary `session::reconstruct` pages preserve every provider-request event ID,
parent link, sequence, and cursor but replace each provider audit body with a
small `projection: "deferred"` marker. Provider-context inventory is not part of
the chat snapshot: Manage Session loads its one-row overview independently via
`session::context_requests` and then caches it on-device. This keeps chat
reconstruction proportional to its bounded event page and prevents sheet/audit
data from delaying the composer; exact manifests remain server-owned and are
read only through the explicit context-detail, export, and replay paths.

At each provider request boundary, the worker-kernel-owned resolver captures the
catalog revision and ranks dynamic workers by explicit session promotion,
deterministic relevance score, recent successes, recency, and identity.
`worker_discover` uses the same scorer; there is no second discovery policy. An ordinary top-level
dynamic provider surface selects at most 12 workers: recent explicit
promotions enter first, then relevant/default candidates fill remaining slots.
Promotion records are version-bound, recency-ordered, and retained to a bounded
50 per session, preventing stale worker-id revival and unbounded provider tool
growth. Each internal provider turn reranks against the same bounded latest-user
intent; assistant plans, direct tool calls, results, provenance, and operational
evidence cannot manufacture semantic relevance. Recent success and recency
break ties only after a semantic match. The resolver preserves that rank order
in the provider surface and records the
exact fixed functions, selected worker versions, selection reasons, and a stable
surface hash. Those volatile values stay in the local audit. The model receives
only stable guidance to use supplied typed tools, discover omitted workers, and
discover a current healthy diagnostic or authoring capability when it needs to
inspect or change workers. It never assumes that a profile contains workers
with hardcoded names. Permanent deletion, secret rotation, and engine-wide stop
remain authenticated dashboard actions. A `worker_discover` result
returns the declared `toolInputSchema` and promotes
matching workers into that session's next internal turn without a restart;
promotions are session-scoped durable engine state and survive server restarts.
An agent-runner with `agentTools` bypasses relevance and promotion selection
only for its closed child surface: exact named dynamic tools are projected
alongside exact named fixed tools, within the 32-name bundle bound.
`request_user_input` is intentionally removed from every delegated agent-worker
surface even if named: a background worker returns its missing information to
the parent agent, and only that foreground session owns native user interaction.
Recent worker success evidence uses the other supported state extent,
profile-global state. There is no generic workspace state scope. Unknown stored
scope kinds fail closed rather than being interpreted as global state. A newly
upserted worker registers immediately.

Workers and the callable catalog are profile-global. Workspace remains useful
invocation and event metadata, but it neither partitions worker availability nor
changes the provider tool surface. The current session affects only explicit
promotion and relevance ranking.

Each model-originated invocation carries the function revision and immutable
worker version that were advertised. Catalog preparation rejects any changed
contract with `ENGINE_STALE_FUNCTION_SURFACE`; it never sends stale provider
arguments through a newer schema. Catalog revision and surface hash remain in
the provider-surface snapshot instead of being copied into an ephemeral
invocation metadata bag. The resulting recoverable tool error advances the
agent to a freshly resolved internal turn.

A direct tool cannot terminate the agent loop through catalog metadata or a
special result-envelope flag. The sole interaction exception is a successful
`request_user_input`: its durable completion ends the current run, and the
validated client answer is appended as a structured `message.user` event before
starting a fresh run. All other typed results are committed to provider context
and the next provider turn sees the freshly resolved surface. Provider terminal
responses, configured limits, cancellation, and runtime failure are the only
owners of agent-run termination.

Authenticated clients may call `engine::surface_snapshot` with optional session
invocation context. The typed response returns the same provider-neutral surface
evidence plus operational inventories:

- all 27 model-addressable fixed functions with their exact schemas,
  revisions, effect/risk, audience, access path, primitive group, and
  request-specific projected/omitted reason;
- every published direct worker tool, including its promoted/projected state,
  selection reason, relevance evidence, and immutable worker version;
- current healthy engine-hook and native-client-action owners, including the
  immutable version that a client may invoke through the ordinary worker path;
- canonical engine worker summaries and stop-all state;
- a compact `workerArchitecture` graph derived from active immutable bundles:
  exposure, runner kind/model, hooks, client actions/deliveries, triggers,
  dispatch routes, exact `agentTools` dependencies, presentation suite/role,
  version, health, and provenance.

The selected `surface.tools` array is the exact next provider projection; the
fixed and available-worker inventories are operator evidence and must not be
mistaken for provider availability. The operation is deliberately not projected
as model vocabulary. The architecture graph is introspection only. It does not
create hierarchy, routing policy, or a second worker registry.

### Worker retention and profile audit

Worker identity is profile-owned and dynamically loaded; Rust and iOS do not
compile a profile inventory as permanent product vocabulary. Current state must
be inspected with authenticated `worker_list`, `worker_inspect`, `worker_runs`,
and `worker_inbox` rather than copied into source documentation.

A production worker is retained only when an independent runtime caller or
observed user task justifies it. The August 2026 audit retired Procedure
Library, Worker Relevance Router, Software Workspace, and Work Ledger without
purging their versions or history. Procedure and software capabilities may be
created again from observed work with fresh contracts. Worker relevance is now
deterministic kernel policy, and Work Ledger no longer has dedicated iOS code.
The former Artifact Studio was replaced only after the fresh Document Export
worker passed smoke validation, completed a public invocation, and delivered a
real inbox artifact.

Worker lifecycle access follows the same split without reserving profile worker
names. A current healthy diagnostic agent may receive only `worker_list`,
`worker_inspect`, `worker_runs`, `worker_inbox`, and `result_read`. A current
healthy authoring agent may accept one natural request and an optional worker
name/ID, with an exact specialist allowlist for inspection, bounded
verification, creation/update activation, enable, disable, stop, rollback, and
recoverable retirement. It cannot purge permanently, rotate secrets, change
credentials, stop the whole engine, deploy, apply core changes, or access
databases. Callers discover whichever immutable diagnostic or authoring
capability is actually healthy in the current profile; Tron does not promise
that a worker with a particular product name is installed.

### Evaluation without an evaluation engine

Evaluation semantics remain outside the fixed kernel. A profile-owned Worker
Evaluator can keep immutable suite revisions and hashes, rotate bounded cases,
invoke target workers, apply closed deterministic assertions, ask an internal
Evaluation Judge only for declared semantic rubrics, record human reviews, and
export reports through Document Export. Its schedule, budget, model policy,
calibration thresholds, suite contents, and SQLite state are worker-owned
runtime state. The judge is not considered calibrated until stored human-review
evidence meets explicit agreement, Cohen's kappa, score-error, safety
false-pass, and repeated-case stability thresholds; insufficient evidence is a
first-class status.

The kernel contributes only generic evidence. An exact
`worker_runs(detail=graph)` lookup returns a closed `requestedInvocation`
projection containing the requested worker ID/version, requested and effective
model/reasoning pair, wall time, and descendant-inclusive usage. Empty optional
string filters materialized by a provider are normalized to omission before
exact matching. These two guarantees let evaluator workers measure a target
without confusing it with their own causal-root cost or silently losing an
exact lookup.

Source-controlled whole-agent acceptance remains an external harness at
`scripts/evaluation/whole-agent.py`, backed by twenty synthetic scenarios in
`whole-agent-suite.json`. It validates normalized evidence offline and adds no
engine API, evaluator registry, deployment gate, or model call. The scheduled
server benchmark is likewise advisory until stable-runner calibration provides
a defensible baseline; raw samples and p50/p95/p99 provenance are retained, and
p99 is reported only with at least 100 samples.

For an ordinary chat request, the provider receives the intent-gated fixed
primitive surface plus at most 12 of the enabled direct workers. Session
promotions are considered first, followed by request relevance and bounded
defaults. `worker_discover` can find a direct worker omitted from that request.
Internal workers never enter the ordinary chat tool list. An agent-runner
worker instead receives only its immutable bundle-declared `agentTools`
allowlist, which may name internal specialists. The v3 request manifest records
the exact result for each request; global counts are not a substitute for that
evidence.

## Local Authority and Provenance

Local model calls enter directly with
their Agent or Worker actor identity. The durable engine record owns actor,
session, workspace, trace, parent invocation, and deterministic idempotency
evidence; the worker dispatcher owns trigger/delivery evidence, and session
events separately own model/provider-call lifecycle. None of those observations
is a permission grant.

The live causal model represents that distinction directly. Stable causal
evidence is accompanied by four explicit engine-owned execution inputs: working
directory, advertised function revision, advertised worker version, and
worker-trigger depth. There is no generic runtime-metadata map, synthetic trust
marker, grant id, or permission scope. Public transport constructs client causal
context itself and cannot inject those execution inputs.

Engine settings are one sparse strict document at `~/.tron/settings.toml` over
compiled typed defaults. Named profiles, inheritance, `active.toml`, profile
classes, and the compiled auth registry do not exist in the running engine.
Provider credentials remain separately protected in
`~/.tron/auth.json`. Home-directory recovery creates only required
directories; bearer-token startup atomically creates the auth document on first
use instead of seeding an inert `{}` file.

The settings schema admits only values with an independent production
consumer. Tests, serialization, dashboard display, or schema presence alone do
not justify a field. Authentication protocol URLs, redirect URIs, and scopes
remain owned by the auth implementation rather than appearing as duplicate
settings the runtime never reads.

There are no local operation claims, resource selectors, synthetic
grants, or agent-kind rejections. Executable workers can change local files and
make consequential external requests without fresh confirmation. This is the
intentional POC threat model.

The primary model receives one short, stable product-intent seed. Tool names,
schemas, worker availability, lifecycle mechanics, approval boundaries, and
background-result narrative are projected from live typed surfaces or
worker-owned hooks on every turn instead of being duplicated in a second
hardcoded instruction set.

Automatic worker projection and explicit discovery both use the exact
weighted-term and adjacent-phrase scorer, so neither path waits for a policy
worker. Session promotions remain version-bound and outrank relevance.

Three unrelated runtime boundaries use three deliberately separate closed
types:

- function admission is either public to authenticated Agent, Worker, Client,
  and System callers, or internal to the engine-owned System actor;
- idempotency keys deduplicate within one session or across the profile runtime;
  a matching duplicate returns its durable previous result, while payload,
  revision, in-progress, and missing-outcome conflicts fail closed. There is no
  configurable duplicate replay policy;
- durable stream events are either a system broadcast or addressed to one
  session, while internal consumers may intentionally read all sessions.

Actor identity has only four production variants: Agent, Client, Worker, and
System. Session and workspace are causal observations rather than actor fields.
Runtime state and idempotency have closed profile/session scopes, while stream
delivery has closed system/session visibility. Unknown persisted values fail
closed. This keeps admission, duplicate suppression, state, and delivery from
becoming another synthetic authorization model.
Executable worker bundles retain source revisions and checksums for inspection,
ranking, recovery, and audit.

Agent Delivery admission is an engine-owned session projection, not a fabricated
user action. A `DeliveryWake` reloads durable delivery IDs under the internal
runtime identity, acquires ordinary session admission, and enters provider
preparation without persisting or broadcasting a user message. Passive
deliveries wait for a natural safe turn. Mailbox discovery and claim remain
explicit bounded tools after the asynchronous creation-time scan.

The remaining boundaries are practical:

- bearer authentication protects remote `/engine` clients;
- worker webhook tokens protect loopback trigger endpoints;
- named-secret bindings limit accidental secret propagation;
- versions, source checksums, provenance, traces, inbox results, and audits make
  behavior inspectable and recoverable;
- execution ceilings contain runaway concurrency and causal loops;
- production deployment remains manual-only.

## Authentication and Secrets

Remote clients still authenticate to `/engine` with the paired bearer token;
permissive local execution does not weaken transport authentication.
OAuth refresh is owned by `domains/auth/credentials/`. Refreshes serialize
through a process-local refresh mutex and then an auth-file `flock`. Refreshes
re-read `auth.json` after the lock and fail the refresh if persistence fails.
Model providers receive ephemeral token copies rather than owning credential files.

Provider credentials live in `~/.tron/auth.json`. Other worker secrets live
under `~/.tron/workspace/vault/`. Both enter a worker only through declared
logical bindings, with the explicit `provider-<id>` namespace selecting a named
provider API key. Bundle validation rejects likely secret material; runtime
injection uses environment variables, and redaction covers persisted inputs,
outputs, events, logs, and diagnostics. Redaction is field-aware for JSON and
also recognizes worker webhook credential shapes. Tool start, batch, and
completion broadcasts use the same redacted copies as durable rows. A one-time
credential remains raw only in the current caller/provider result needed to
hand it off; reconstruction receives the redacted result. The generic engine
invocation ledger independently reapplies the same boundary before writing
results or errors to either its in-memory idempotency cache or SQLite. A live
caller can therefore receive a one-time credential, while replay and audit
records cannot recover it.

## Worker Restoration Backlog

The clean cut intentionally removed higher-level source-owned behavior so it
can be rebuilt from observed tasks as executable workers. The old itemized
inventory remains coverage evidence that no useful behavior was forgotten; it
does not dictate worker boundaries, names, or implementation order. The
authoritative restoration map is the following thirteen first-principles
capability families:

| Family | Functional closure and absorbed behavior |
|---|---|
| **Work Ledger** | Durable human/agent work state: goals, questions, answers, dependencies, decisions, status changes, completion, cancellation, filtering, and export/import. Reminders remain Automation custody. |
| **Continuity Curator** | Useful durable memory across turns and sessions: facts, decisions, preferences, project/global scope, deterministic retrieval, correction, promotion, tombstones, retention, inspection, and explicit clear behavior. |
| **Session Organizer** | Reversible grouping, labels, archive/restore, and organization policy over the canonical session store. Session deletion remains explicit fixed custody. |
| **Delegation Coordinator** | Bounded specialist-agent work: launch, status, inspection, results, invocation cancellation, reusable roles, later fan-out/synthesis, and child-session traceability. |
| **Research Suite** | Source-backed freshness-aware answers: search, crawling, fetch/archive, freshness, source review, citation extraction, recent research, evidence comparison, contradictions, and synthesis. |
| **Knowledge Index** | Retrievable durable source material: document/web/repository ingestion, semantic retrieval, provenance, lineage, previews, history, update detection, export/import, and corpus maintenance. Personal memory remains Continuity custody. |
| **Software Workspace** | Safe repository work: structure/history, Git status/diff/branches/staging/commits, test selection, patch/review preparation, change analysis, and cleanup through bounded host primitives. |
| **Automation Orchestrator** | Work caused by time or events: reminders, schedules, engine events, follow-ups, background jobs, multistep programs, retries, notifications, and workflow state over the executable dispatcher. |
| **Procedure Library and Worker Forge** | Reusable prompts, templates, procedures, skills, roles, hook patterns, external tool/API/repository scouting, worker creation/improvement, consolidation, and retirement recommendations. |
| **Worker Evaluator** | Evidence of usefulness and reliability: run inspection, traces/logs/replay, failure clustering, regression fixtures, conformance, comparison, benchmarks, routing evidence, and improvement recommendations. |
| **Connector Fabric** | Typed external-system adaptation: MCP/A2A/API adapters plus separately versioned email, calendar, issue/source-hosting, messaging, database, home, and business connectors where credentials/dependencies/failure domains differ. |
| **Artifact Studio** | Focused text, data, document, PDF, spreadsheet, presentation, image, audio, video, transcription, language, diarization, transformation, analysis, and archival specialists. |
| **Interactive Operator** | Stateful observe-act-verify loops for browser control, computer operation, screenshots, and device inspection. |
| **Engine Steward** | Read-only provider/model monitoring and diagnostics from canonical engine, worker, run, inbox, and result evidence. |

Every restored behavior has one primary family owner. A family splits only
when contracts, dependencies/credentials, failure isolation, semantic tool
selection, or independent usefulness materially differ. Individual CRUD verbs,
internal text helpers, authorization-only tools, and record-only metadata do
not qualify as workers. Completion means a real worker performs a useful
outcome through a concise typed contract and survives independent testing,
versioning, disabling, inspection, and improvement.

Restoration order remains evidence-driven:

1. close concrete kernel gaps and refresh providers/models;
2. keep independently useful, production-backed workers and retire contracts
   that lack observed callers;
3. create a fresh worker only when a real task establishes its trigger,
   contract, and acceptance evidence;
4. generalize native presentation only after multiple active workers prove a
   stable shared contract;
5. consolidate overlaps, remove unused adapters/helpers/fixtures, and confirm
   no legacy administrative plane returned.

There is no elapsed-day or concurrent-creation gate. Each worker still needs
schema validation, atomic activation, useful success and failure scenarios,
restart/update/rollback evidence, direct-tool routing, generic-console access,
and accurate dedicated/declarative UI before its family advances.

The kernel foundation for this program is present: mutable worker-owned state,
isolated activation state, invocation-specific cancellation, durable child-
agent session linkage, initial immutable presentation/suite bindings, verified
profile snapshots/restoration, and archive-before-purge.

The cloud-model refresh is also present. OpenAI's registry leads with GPT-5.6
Sol/Terra/Luna and keeps auth-path-specific limits; Anthropic leads with Claude
Fable 5, Opus 4.8, and Sonnet 5 and encodes their current adaptive-thinking
behavior; Google leads with Gemini 3.6 Flash and includes stable 3.5/3.1
variants, current retirement state, and non-duplicating moving aliases. The
Gemini adapter omits deprecated Gemini 3 sampling parameters, rejects trailing
model prefills at request assembly, emits current lowercase thinking levels,
and restores documented Gemini 2.5 dynamic/off budget defaults. The compiled
default for a new profile is Claude Sonnet 5; an explicit model already stored
in a profile always wins over that refreshed default. Catalog facts are checked
against the providers' official [OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model),
[Anthropic model overview](https://platform.claude.com/docs/en/about-claude/models/overview),
and [Gemini model documentation](https://ai.google.dev/gemini-api/docs/latest-model).
Ollama/Gemma discovery, conservative dynamic admission, live local contract
evidence, endpoint settings parity, and provider UI status are present. The
provider/model prerequisite is therefore closed before guided Work Ledger
authoring.

### Browser Operator boundary

The Browser Operator is an ordinary direct agent worker. Its public contract
accepts the desired outcome plus an explicit confirmation bit for a final
externally consequential action. The worker owns tab selection, page
interpretation, planning, confirmation policy, observe-before-act,
observe-after-act verification, recovery, and the bounded step count.

Chrome Native Messaging is the one fixed boundary workers cannot reproduce:
only Chrome can attach to the user's existing session and hold its
user-granted `activeTab` permission. The unpacked extension under
`packages/browser-extension/` therefore exposes exactly bounded tab discovery,
page observation, screenshot, click, type, fixed-key, scroll, and navigation.
It acts only on the explicitly enabled foreground tab, shows both an `ON`
toolbar badge and an in-page consent indicator, rejects credential fields, and
returns a fresh observation after each mutation. HTTPS and loopback HTTP are
the only navigation schemes. The extension admits at most sixteen request
lifecycles defensively (the native host admits eight), retains cancellation
only for a queued/running request and no longer than thirty seconds, and removes
completion listeners, handlers, and request identity at terminalization. Late
cancellation is ignored instead of becoming a permanent service-worker
tombstone.

Chrome owns the native-host process lifetime. The hidden
`browser-native-host` binary mode publishes one owner-only Unix socket for the
worker's bundled helper. The host validates the closed action vocabulary,
serializes actuation, bounds queue/message/time, propagates cancellation, and
removes its socket on exit. It has no page-planning or confirmation semantics
and exposes no arbitrary JavaScript, shell, cookie, credential, header,
download, extension API, background-tab, or device-control primitive.
Extension and native-host installation remain explicit local setup; server
startup never installs or launches either one.

### Mac Operator boundary

The Mac Operator is likewise an ordinary direct agent worker. Its direct tool
accepts only the desired foreground-app outcome and an explicit confirmation
bit for a final destructive or externally consequential action. The worker
owns application selection, accessibility-tree interpretation, planning,
confirmation policy, observe-act-verify sequencing, recovery, and its bounded
step count.

The unavoidable fixed seam lives in the signed Mac wrapper rather than the
Rust engine. After onboarding, the wrapper publishes an owner-only Unix socket
under the selected Tron home and admits a closed vocabulary: permission status,
visible applications, one foreground-window observation, a ScreenCaptureKit
window image, accessibility press/value assignment, fixed keys, bounded
scroll, and a normalized coordinate fallback. The host validates same-user
peer identity, exact action shapes, byte/time ceilings, the foreground
bundle/window, and latest observation/screenshot identities. It serializes
actuation and returns a new observation after every mutation. Window validation
compares the current Accessibility-focused window and WindowServer number, so
a switch to another still-visible window in the same foreground application is
rejected.

Only the native menu can engage or clear the Mac Operator emergency stop.
Stopping changes a safety generation and invalidates cached targets. The bridge
also shuts down the active client descriptor, cancels its exact action task,
and drains that task before stop returns; no worker operation can resume it.
Secure fields and editable values are redacted, and the native bridge never
writes typed content or screenshots to its own logs; native evidence excludes
process IDs, filesystem paths, socket details, or raw native errors. The bridge exposes
no shell, AppleScript, arbitrary Accessibility attributes/actions, arbitrary
key codes, background-app activation, URL opening, device/simulator control, or
engine-side desktop policy. Manual signing, Accessibility permission, Screen
Recording permission, and physical acceptance remain required before
activation.

### Historical guided Work Ledger proof (retired)

Work Ledger was authored by Tron from a natural-language
request in an ordinary `gpt-5.5` session; it is profile state, not a
repository-managed built-in. Tron researched the live worker contracts, wrote
and smoke-tested a command-runner bundle, activated it with `worker_upsert`, and
used the newly projected `worker_work_ledger` direct tool in the same session.
Its retained history contains three immutable versions; each update named the
same predecessor and preserved mutable state. The current contract has one
flat, typed action discriminator and explicit optional action fields rather
than an opaque parameter bag. Its bounded `snapshot` action returns goals,
questions, decisions, aggregate counts, and recent global history in one run
for clients.

The worker owns a WAL-backed SQLite database under its kernel-provided state
directory and supports durable goal/question/decision lifecycle, dependencies,
links, typed JSON plus Markdown export, and duplicate-safe validated import.
Reminders and schedules remain out of scope. Activation uses isolated temporary
state; the active database is not part of an immutable version hash.

Acceptance evidence on the fresh restoration profile covers:

- same-session direct-tool projection and useful goal/question creation;
- atomic worker improvement with state preserved across every version switch;
- create, inspect, update, complete, cancel, answer, resolve, decision,
  dependency, and link paths;
- a malformed import returning typed `ok: false` output without a nonzero
  process exit or automatic worker disable;
- exact invocation replay for a repeated idempotency key and duplicate-free
  repeated import;
- JSON/Markdown export, immutable rollback to the first version and restoration
  to the corrected version, plus server-restart state recovery;
- healthy bundle verification, direct routing, durable run/inbox evidence, and
  continued generic-console access.

iOS routes only independently active, production-backed presentation contracts.
The retired Work Ledger contract now falls back to the generic console; its
dedicated view model and sheets were removed rather than retained ceremonially.

### Guided Research Search proof

The first Research-suite component was likewise authored from natural
language by Tron in an ordinary `gpt-5.5` session. It is the profile-owned
`research-search` command worker and projects the typed
`worker_research_search` tool. Its immutable presentation envelope identifies
Research suite contract version 1, component role `search`, and a non-primary
suite member; clients therefore use the generic console until the complete
four-worker Research experience exists.

The contract accepts one bounded query plus optional result limit,
include/exclude domains, publication window, Brave freshness/language/country,
and the provider-neutral `fast`, `balanced`, or `deep` mode. Exa maps those
modes to its current `fast`, `auto`, and `deep` search types. When both optional
`provider-brave` and `provider-exa` bindings exist, the worker dispatches both
requests concurrently, normalizes their different response shapes, merges
canonical URLs, preserves per-provider ranks and request provenance, and
returns deterministic combined ordering. One-provider failures retain useful
results from the other provider. With neither binding configured, the command
returns a successful typed `unavailable` result naming both missing logical
bindings and makes no network request; absence of an optional provider is not
worker failure.

Guided inspection caught and corrected a first-version contract defect before
the component advanced: the worker initially looked for informal credential
environment names instead of the kernel-owned
`TRON_SECRET_PROVIDER_BRAVE`/`TRON_SECRET_PROVIDER_EXA` projection. A second
immutable version now uses only those names, maps current Exa modes, enforces
Brave's 400-character/50-word query ceiling, and includes delayed local
endpoints whose elapsed-time assertion distinguishes concurrent from sequential
dispatch. This demonstrates that immutable provenance is evidence, not an
excuse to accept the first generated bundle.

Acceptance evidence for the corrected component covers:

- deterministic Brave and Exa parsing without live credentials;
- concurrent dual-provider dispatch, canonical-URL deduplication, stable
  ranking, and secret-value redaction;
- one-provider failure degradation, malformed-input handling, and the current
  profile's actionable no-credential result;
- same-session direct-tool projection and a healthy durable run;
- retained-version rollback to the first bundle and restoration to the
  corrected bundle; and
- activation and invocation of the corrected version after a server restart.

The Search component is therefore independently proven, while live result
quality remains intentionally unclaimed until at least one real Brave or Exa
credential is configured. The separately owned Source Review, Citation, and
Coordinator proofs follow below.

### Guided Research Source Review proof

The second Research-suite component was authored and improved through an
ordinary `gpt-5.5` Tron session rather than installed from the repository. The
profile-owned `research-source-review` agent worker projects the typed
`worker_research_source_review` tool. Its immutable presentation envelope joins
Research suite contract version 1 as component role `source-review`, without
claiming primary-suite custody. Search finds candidate URLs; Source Review owns
the materially different closure of bounded retrieval, extraction, source
assessment, evidence comparison, contradiction reporting, and gap reporting.

The guided run exposed two engine defects rather than merely worker-specific
prompt problems. Agent-runner children were asked for typed JSON without being
shown their immutable output schema, and the host fetch primitive defaulted to
retaining up to one MiB of raw response content. The kernel now includes the
exact output schema in every agent worker's durable execution contract. The raw
fetch primitive remains deliberately non-semantic, but defaults to a 128-KiB
response ceiling, accepts a bounded timeout, and records a digest of retained
content so workers can reason about truncation and provenance without pushing
unbounded pages into model context. `session_set_title` now accepts only the
title and derives its target from the causal session, removing an unrelated
session-id ceremony uncovered by ordinary authoring sessions.

The corrected worker keeps semantic extraction in worker custody. Its
dependency-free `fetch_extract.py` helper performs bounded HTTP retrieval,
redirect tracking, HTML title/date/link extraction, script/style exclusion,
plain-text handling, raw and retained hashes, normalized same-domain links,
truncation reporting, and actionable unsupported-binary results. The helper is
invoked through exact `python3` argv by the agent, may review independent URLs
in parallel, retains at most 50,000 characters per page and 120,000 characters
overall, and never requires the model to ingest raw HTML. PDF content is not
silently fabricated: this version returns a typed unsupported result until a
real PDF extraction dependency is justified by use.

Acceptance evidence for immutable version
`3899d5e1a2ffeaa130afea9386453eb2644cab10afe816d0028f2f0c03b0d0d4`
covers:

- independent deterministic extraction and smoke suites for HTML, redirects,
  hashes, truncation, bounded links, plain text, unsupported binaries, input
  bounds, instruction invariants, and the output fixture;
- a useful two-source review of the official Brave and Exa search
  documentation, with typed source, evidence, agreement, contradiction, gap,
  freshness, archival, and fetch-provenance records;
- a completed linked child session and schema-valid
  `research.source_review.v1` result rather than unvalidated prose;
- reduction of roughly 1.45 MiB of fetched HTML to fewer than 23,000 retained
  review characters, a greater-than-98-percent source-text reduction before
  model reasoning; and
- durable failed-run evidence for the earlier invisible-schema and stale-child
  defects instead of deletion or rewriting of history.

Restart testing found one additional dispatcher defect: an interrupted agent
attempt retained its current-child pointer when returned to `queued`, so the
redelivered attempt could not attach a fresh child. Recovery now terminalizes
the interrupted attempt, clears only the invocation's stale live pointer, and
permits the next attempt to link its own child session. The old attempt and its
child remain inspectable. After rebuilding from that recovery change, the
corrected worker completed another two-source review with a new linked child
session. It then activated a retained earlier version and returned to the
corrected version while remaining enabled and healthy. Source Review is
therefore independently accepted. Citation and Coordinator are documented next.

### Guided Research Citation proof

The third Research-suite component was created and corrected through an
ordinary `gpt-5.5` Tron session. The profile-owned `research-citation` worker
projects `worker_research_citation`, joins Research suite presentation contract
version 1 as component role `citation`, requires no secrets, and has only its
manual trigger. It consumes explicit claims plus one or more
`research.source_review.v1` results (or the equivalent normalized evidence
corpus); it does not search, fetch, review raw sources, or synthesize the final
report.

The first active version was executable but not acceptable. It used a command
runner with lexical-overlap heuristics and correctly handled the prepared
supported/partial/unsupported fixture, missing references, and excerpt bounds.
An independent adversarial invocation then supplied positive evidence for a
negated claim. That version returned `partial` and attached the semantically
opposite evidence as a citation. Its healthy status proved only that it ran; it
did not prove useful semantic correctness. The failed invocation and immutable
version remain inspectable evidence rather than being rewritten or deleted.

Tron improved the same worker id and tool through another atomic upsert. Active
version `8da7088f55d57e3ab5c7854389e7a2b0c4d62b905619dc923b56fc8925841a35`
uses the `openai/gpt-5.5` agent runner for semantic support assessment strictly
over supplied evidence. It pairs that judgment with worker-owned
`citation_guard.py`. Before returning, the child agent must submit the original
input and proposed output to the guard through exact
`["python3", "citation_guard.py"]` argv. The final result is the guard's
canonical validated object and carries `research.citation.guard.v2` evidence.

The deterministic guard validates relational guarantees that JSON Schema alone
cannot express:

- output claim ids and text correspond one-for-one with the caller's claims;
- every source/evidence reference exists in the supplied corpus and evidence
  belongs to the cited source;
- unsupported claims have no positive citations, and evidence marked
  `contradicts` is never cited positively;
- polarity-opposite evidence and unsupported numeric/quantifier overstatements
  cannot pass as supported citations;
- quote excerpts are copied from the referenced supplied excerpt and contain at
  most 25 words; and
- source URL, title, and publication/update/access metadata are preserved from
  input rather than invented or altered.

Acceptance evidence covers:

- independent smoke and health execution for exact negation, numeric
  overstatement, missing references, invented excerpts, invented metadata,
  unsupported-with-citation, and excerpt-length cases;
- a same-session direct invocation where the positive claim was supported, its
  negation was unsupported with no citation, `always exactly 100` was partial,
  and contradictory crawling evidence was not cited;
- a linked child-session trace that contains the mandatory guard process call,
  followed by schema-valid output with guard status `passed` and no validation
  errors;
- a second successful guarded invocation after rebuilding and restarting the
  server; and
- retained-version rollback to the rejected command version and immediate
  restoration to the corrected agent version while routing stayed enabled and
  healthy.

The authoring session also exposed fixed-surface inefficiency. Optional
`sessionId` encouraged the model to invent placeholder targets, so
`session_set_title` now accepts only `title` and binds the causal session.
Full worker inspection also made the model absorb source files and audit history
when it needed contracts. Default `detail=contract` now strips those payloads;
for the corrected Citation worker the authenticated response is 14,079 bytes
versus 39,360 bytes for explicit full operator detail. Citation's remaining
limitation is intrinsic rather than hidden: semantic assessment is fallible,
while the deterministic guard covers the cited provenance and adversarial
relations above but is not a theorem prover.

### Guided Research Coordinator proof

The fourth and primary Research-suite component was authored, tested, and
repeatedly improved by Tron through the same ordinary `gpt-5.5` session. The
profile-owned `research-coordinator` agent worker projects
`worker_research_coordinator`, is the primary component of Research suite
presentation contract version 1, requires no secrets of its own, and retains
only a manual trigger. Its current contract calls Search first, merges explicit
seeds with discovered candidates, calls Source Review only when candidates
exist, submits reviewed claims to Citation, and persists one strict
`research.report.v1` through its worker-owned state helper. Source Review
preserves selected-candidate order so `S1` is addressable as `/sources/0`.
Coordinator passes the unchanged causal result reference plus only
claim-relevant source pointers to Citation; it never hydrates the Source Review
root. Citation reads those declared paths in one parallel batch, verifies
reference/content/source identity, and rejects missing, unauthorized,
truncated, or mismatched evidence as a bounded `validation_failed` outcome.
Referenced Citation results are likewise reduced to `/status`, `/claims`,
`/sourceManifest`, `/issues`, and `/validation` for synthesis instead of being
root-hydrated. Exact specialist outputs remain owned by their invocation
ledgers, and the top-level report is delivered through the kernel's integrity
reference.

The useful final seeded proof used the official Brave and Exa search API
references. Search returned the profile's typed `unavailable` result because
neither optional provider credential was configured for that historical run,
while the explicit seeds still flowed through Source Review and Citation. The
completed run retained
two sources, 13 evidence items, six claims, 11 claim-linked citation records,
and five fully supported claims. Its answer preserved documentation terms such
as `x-subscription-token`, `x-api-key`, and Bearer authorization, reported one
partially supported Brave-query comparison conservatively, and stored the
canonical report under helper-generated id
`rr-20260722T130645Z-d480507abb3e`. The exact child trace contains one
`finalize_report` call, successful on its first attempt, followed by a
schema-valid terminal result.

The accepted no-candidate path is distinct rather than an invalid empty
specialist call. Search still executes and reports its missing logical
bindings; Source Review is recorded as `called:false`, `status:skipped` with
zero sources/evidence and a reason; Citation receives its valid empty evidence
corpus and classifies the procedural claim as unsupported; then the helper
persists one partial report. This correction removed the earlier avoidable
`sources: []` schema violation instead of treating a recoverable final response
as sufficient proof of graceful degradation.

Guided field use exposed and corrected several deeper contract and runtime
problems before acceptance:

- agent-runner results originally lacked the active output schema, so the
  kernel now includes that schema in the durable child instruction and rejects
  a terminal value that does not match it;
- interrupted agent delivery originally retained a stale child pointer, so
  recovery now terminalizes the old attempt, clears only its live pointer, and
  links the redelivered attempt to a new durable child; the interrupted
  Coordinator invocation was then cancelled precisely with `worker_cancel`;
- worker processes originally lacked `TRON_WORKER_STATE_DIR`, and hidden prompt
  transport originally lost worker causality; both kernel paths now preserve
  the worker-owned state and causal trace used by the Coordinator;
- an early helper stored its pre-receipt draft and one failed iteration left a
  `rr-placeholder` artifact; exact cleanup, normalized stored receipts, and
  historical-hash assertions corrected both without hiding the audit trail;
- intermediate schemas admitted compatibility unions such as `answer.type`,
  claim `id`/`citations`, string excerpts, object evidence gaps, and open nested
  objects. Those versions were rejected. The active schema has one closed
  canonical shape, with legacy handling isolated in explicit migration;
- legacy stored reports were canonicalized, including renaming the one old
  short-suffix id. Report bodies omit mutable index counts, hashes, migration
  counts, and cleanup receipts, so appending a report cannot change historical
  bytes;
- a model-generated `a1b2c3d4e5` suffix proved that a regex was not identity
  custody. `finalize_report` now accepts a bounded draft without identity or
  storage receipts, allocates the current unique id itself, fills every matching
  path/reference, validates, atomically stores, verifies, and returns the full
  canonical body for the agent to return unchanged; and
- the first helper-owned seeded run treated documentation prose naming Bearer
  authorization as secret material. The active validator permits authentication
  terminology while still rejecting secret-shaped bearer values, `sk-` values,
  header key/value secrets, and sensitive-field values.

The active smoke and health evidence covers canonical storage, all removed
aliases, closed nested objects, historical-hash preservation, two unique
helper-owned ids, path/reference consistency, rejection of model-authored ids,
the positive and negative secret cases, and legacy migration. The state index
contains 14 reports, every indexed digest matches its file, the known synthetic
id no longer exists, and all reports validate under the active helper. An
immutable rollback to the immediately preceding helper version and restoration
to the accepted version preserved the complete state. Restoration initially
failed closed when an independent diagnostic imported code directly from the
canonical version and Python wrote `__pycache__`; removing that exact
diagnostic-generated file restored the recorded content hash, after which
rollback restoration and server restart both succeeded. Diagnostics must copy
immutable source to temporary storage before importing it.

The Coordinator is therefore independently accepted for ordinary field use,
same-session direct-tool routing, durable child/run/inbox inspection, retained
version recovery, restart persistence, and generic-console access. That
historical cited run used caller-supplied official seeds because Brave and Exa
credentials were absent at the time; runtime binding state must always be
resolved from the current profile. Semantic synthesis remains model-fallible
within the Citation worker's deterministic provenance and relation guard.

iOS now recognizes only the primary immutable `research-suite` presentation
contract version 1 as the grouped native Research experience. It reads the
canonical suite inventory plus bounded full-detail run and inbox contracts; it
does not inspect worker-owned files. Current coordinator runs expose result
references, semantic previews, sizes, schema/version identity, and an explicit
bounded result inspector; run lists and report history never receive the full
report JSON. Schema-v9 inline `research.report.v1` values remain decodeable
only as migration compatibility. The same surface shows aggregate health,
component versions, query/run history, and failures, and every component
retains a path to its separately loaded generic technical console. Secondary
components, unknown versions, and malformed or absent presentation metadata
fall back to the generic console. Malformed canonical report output is
surfaced as partial refresh evidence rather than silently rendered or adopted
as client truth.
This closes the implemented Research UI slice; physical-device field review of
the presentation remains an operator acceptance step before the broader
field-confidence gate.

### Guided General Delegate proof

The third guided capability was created and then improved by Tron through two
ordinary `gpt-5.5` turns rather than installed from repository-owned worker
source. The profile-owned `general-delegate` agent worker projects
`worker_general_delegate`, uses presentation contract `general-delegate` version
1 as the primary `delegation` entrypoint, declares no secrets or persistent
state, and retains only a manual trigger. It accepts one bounded task, requested
deliverable plus optional JSON Schema, relevant context and file paths,
constraints, optional deadline, and a low/standard/high effort budget. Kernel
idempotency, causality, cancellation, session linkage, model evidence, tokens,
cost, routing, and authority are deliberately absent from that public contract.

The first immutable version,
`36568f4a56101e83011a34324520012bc60ba2a1ca9ad9419abbe04feaa86eb6`,
passed activation smoke and health checks and completed a real read-only
inventory of `/Users/<USER>/Workspace/testspace`. Durable invocation
`worker_run_019f8a08-1154-7821-921e-2d1f08b8bcd7` linked child session
`sess_019f8a08-115e-7f52-8694-b1e735fce4bd`, returned the requested closed
four-field deliverable, preserved three explicit constraint observations, and
created no artifact. The child session records `openai/gpt-5.5`, three turns,
36,868 input tokens, 1,250 output tokens, 22,528 cache-read tokens, and
`$0.120464` total cost; this evidence remains ordinary session custody rather
than being copied into a delegation database.

Field acceptance then exercised the kernel boundaries around that worker:

- semantic surface resolution projected `worker_general_delegate` in the same
  session with the active immutable version and relevance evidence;
- a deliberately long invocation was durably enqueued, linked to child session
  `sess_019f8a0c-45a8-7192-9026-67baf46c35b9`, and cancelled precisely through
  `worker_cancel`; the worker remained enabled, healthy, and available;
- after rebuilding and restarting the dev server, a new invocation completed
  and an identical idempotency key returned its original invocation and child
  session instead of creating another row; and
- malformed nested input was rejected before dispatch and created no invocation
  record. That test exposed the transport misclassifying a selected worker's
  schema violation as internal. Nested worker input is now a typed admission
  boundary: schema and known-secret violations return actionable
  `INVALID_PARAMS`, while canonical contract-loading failures remain internal.

Inspection of the first deterministic guard exposed two worker-specific gaps,
which Tron corrected through one ordinary update and one atomic `worker_upsert`.
Active version
`83a932b3c2e085675d1d66b437efceece3f259edb32ab4352d89bdc068f80af6`
requires exact one-to-one, order-preserving coverage of every caller constraint;
a completed result requires every constraint to be observed and no unresolved
items. Its caller-supplied deliverable schema is fail-closed rather than a
decorative object. The guard supports `type` (including unions), `const`,
`enum`, `required`, `properties`, `additionalProperties`, `items`, item and
string bounds, `pattern`, numeric bounds, and `oneOf`/`anyOf`/`allOf`; any other
keyword produces an actionable validation error. Smoke and health evidence
covers baseline success, omitted/duplicate/invented constraints, false
constraints reported as complete, unresolved completed work, valid partial
work, nested-schema success and failure, and unsupported schema keywords.

The updated version then completed a real file-inspection task against
`test1.txt`. It returned the exact 21-character, one-line result, preserved all
three constraints in order, cited the actual file read, and produced no writes.
The active pointer was rolled back to the first retained version and restored
to the accepted version while health and routing stayed enabled. General
Delegate is therefore accepted for single-task typed delegation, durable
enqueue, child-session evidence, precise cancellation, restart recovery,
idempotent replay, malformed-input rejection, retained-version recovery, and
generic-console operation.

A later durable auto-resume smoke test exposed a capability mismatch rather
than a delivery failure: the delegate had been asked to enqueue a known worker
while its immutable agent surface omitted `worker_invoke` and allowed no child
invocation. It exhausted its model-turn budget probing private runtime routes,
then the generic runner mislabeled the missing terminal response as a schema
mismatch. The profile-owned worker was updated through ordinary `worker_upsert`
to include exactly `worker_invoke`, a one-child budget, and instructions to use
the public nested-call contract without polling or private API discovery. The
agent loop now records max-turn exhaustion as the execution error before typed
output validation. The corrected proof treats nested `mode: enqueue` as an
immediate durable child receipt, not a synchronous tool join; its parent
assignment remains in the mixed structured join until that child settles and
automatic result delivery resumes it. Nested `mode: wait` remains the separate
typed synchronous path bounded by the worker reliability ceiling.

iOS now recognizes only the exact primary `general-delegate` presentation
contract version 1 as the native Delegation experience. The sheet reads full
inspection, bounded runs, inbox outcomes, and linked child-session evidence
from their existing server owners; it does not invent a delegation ledger.
Typed submissions use durable enqueue, cancellation targets one invocation,
retry creates a distinct invocation from the original input, and child-session
navigation performs the ordinary authoritative session sync before opening an
uncached child. The experience exposes task, deliverable, optional context and
files, constraints, deadline, effort budget, and caller JSON Schema, then
presents deliverables, evidence, constraint observations, artifacts, unresolved
work, attempts, causality, model, tokens, cost, and timing. Unknown bindings and
malformed results fall back or surface errors rather than becoming local truth.
This closes the implemented General Delegate UI slice; physical-device field
review remains an operator acceptance step before the broader field-confidence
gate.

### Guided Compaction Worker proof

Semantic compaction is restored through the profile-owned `compaction-worker`,
not through a new hardcoded summarizer. Tron authored it from the public worker
contract in an ordinary GPT-5.6 Sol session, staged and ran its dependency-free
verification source, and activated it through one atomic `worker_upsert`.
Authoring required no database, auth-file, binary-string, runtime-file, or
private-endpoint inspection. The worker projects `worker_compaction`, uses the
`openai/gpt-5.6-luna` agent runner, owns only the `context_summary` engine hook,
and declares no triggers, dependencies, named secrets, presentation override,
or persistent state.

The active immutable version is
`13e9b3d9f0d5d87a668e5ed8c2a168cb0952595d8bf9da2662144a9786a84a80`.
Its structured brief keeps only non-empty Goal, Current state, Decisions and
constraints, Important evidence and artifacts, Open work, and Next action
sections. Later explicit user instructions supersede older conflicts; tool
calls are not treated as success without a successful result; prior compacted
state is merged without nesting or duplication; transcript content remains
untrusted data; and secret-like or irrelevant personal material is omitted.
The verifier covers ten deterministic fixtures, including section order,
envelope validity, secret detection, cumulative re-compaction, adversarial
transcript content, the ordinary output target, and actual Markdown newlines.

The public schema admits at most 40,000 characters as an early structural
check. The kernel then applies the authoritative 10,000 estimated-token and
40,000 UTF-8-byte limits. The estimate uses the context subsystem's cheap
four-bytes-per-token budgeting heuristic rather than a provider-specific
tokenizer. The worker normally targets at most 8,000 estimated tokens and
32,000 bytes so exceptional tasks retain headroom; it is still instructed to
return the smallest faithful brief. This larger maximum is a safety ceiling,
not a request to pad routine summaries. Accepted text is never silently
truncated.

Eight sequential semantic invocations proved coding progress and failure
history, latest-instruction precedence, an unverified tool call, cumulative
re-compaction, prompt injection as data, synthetic-secret redaction, large
repetitive history, and sparse history. All completed with schema-valid
structured output. The second immutable version exposed one real presentation
defect during automatic compaction: a list used visible `\n` markers instead
of actual line breaks. Tron improved the same worker through another atomic
upsert; the active version adds that regression fixture, and every semantic
scenario now returns real Markdown newlines.

A real automatic threshold proof temporarily preserved two recent turns and
lowered the trigger to one percent. Older history contained a known objective,
a reversed decision, an exact path and identifier, a failed and then successful
operation, a hard constraint, and an unresolved next action. The engine
dispatched one `engine_hook:context_summary` run, completed it within the
sixty-second ceiling, committed the exact accepted narrative byte-for-byte to
both live context and `compact.boundary`, reduced the message context, and
retained the two recent turns. A follow-up recovered the compacted facts before
and after a development-server restart, and no new Attention item remained.
The original 70-percent trigger and five-turn preservation settings were
restored after the proof.

Failure and lifecycle coverage proves that:

- no active owner returns `handled:false`, causing deterministic recovery;
- empty, schema-invalid, oversized, and timed-out hook output disables the
  failing owner instead of truncating or stalling compaction;
- hidden thinking, tool arguments, binary content, usage, and cost do not enter
  the worker transcript;
- the hook cannot recursively summarize its own agent-runner session, while a
  different worker's session remains eligible;
- cancellation restores the pre-compaction checkpoint, persistence failure
  cannot create a bare boundary, and a non-reducing or ineligible window is
  skipped; and
- immutable rollback to the first version remained healthy and callable,
  restoration to the active version succeeded, and active hook ownership
  survived another server restart.

Semantic context summary generation is therefore restored. Token measurement,
thresholds, recent-turn selection, cancellation, checkpoints, durable
boundaries, reconstruction, and deterministic recovery remain fixed engine
custody. Continuity memory now has a closed provider-context seam and an
ordinary runtime-worker contract; session grouping, labels, and archival policy
remain separate Session Organizer work.

### Prior inventory coverage evidence

The following detail is retained only to cross-check the family map above.
Worker authors must recombine it by functional closure rather than reconstruct
these bullets as one tool apiece.

#### User workflows

- **Session organization:** the kernel durably enqueues a `session_title`
  worker after eligible completed exchanges without awaiting it and retains the
  conditionally projected explicit `session_set_title` actuator plus
  compare-and-set custody. Admission uses one closed receipt:
  `handled`, `queued`, and `updated` are always present; a queued hook reports
  `true`, `true`, and `false` plus its immutable invocation, worker, and version
  identifiers. The receipt confirms durable admission, not synchronous title
  application. Replay retains the same invocation, the compare-and-set cannot
  overwrite an explicit title, and the Session Organizer handoff is committed
  exactly once with terminal worker effects.
  The actual title policy worker, and later grouping, labeling, or archival
  policy, must still be authored and improved through real conversation use.
- **Goals:** create, list, inspect, update, complete, and cancel durable goals;
  connect goal state to real worker runs and session outcomes.
- **Questions:** create, list, inspect, answer, and resolve durable questions;
  attach answers to the initiating task rather than maintaining an inert queue.
- **Memory:** status, list, inspect, semantic query, retained facts, decisions,
  policies, edit, tombstone, export, import, and query/decision recording. The
  resulting worker must own useful retrieval and maintenance policy while the
  kernel supplies only durable files, execution, and session context.
- **Context policy:** snapshots, compaction requests, clear actions, survivor
  and exclusion policy, and policy inspection. Token-window selection,
  cancellation, checkpoints, and durable compact-boundary proof remain kernel
  custody; semantic summarization is restored by the profile-owned Compaction
  Worker through the `context_summary` hook.
- **Media:** create, list, inspect, archive, transform, and analyze media
  artifacts using workers built for actual media tasks.
- **Prompt and template artifacts:** author, version, list, inspect, select,
  and apply reusable prompts or templates as working behavior.
- **Repository understanding:** tree snapshots, list/inspect, import previews,
  import lineage, import history, and update diagnostics. These should become
  real repository-ingestion and change-analysis workers, not detached metadata.
- **Text and content analysis:** deduplication, statistics, audits, structured
  extraction, summarization, recent-research synthesis, and other repeatable
  transforms developed from concrete sessions.

#### Agent and automation behavior

- **Delegated agents:** launch, status, result, cancel, task list, and task
  inspect. The agent runner is the execution substrate; delegation policy,
  specialization, fan-out, synthesis, and reusable subagent roles belong in
  workers.
- **Procedures, skills, and hooks:** author definitions, inspect active state,
  activate, deactivate, and revise reusable procedures. Use direct worker
  versions and engine hooks; do not recreate a separate definition/request/
  decision plane.
- **Schedules and reminders:** `automation-reminders` now creates, lists,
  inspects, updates, cancels, completes, snoozes, and fires meaningful
  scheduled work. Schedule triggers remain kernel substrate; reminder
  semantics, calendar reasoning, notification policy, and recurrence UX remain
  worker-owned.
- **Event automations:** filter engine events, correlate state, invoke follow-up
  work, and report results. Engine-event triggers and causal loop suppression
  are already substrate.
- **Background jobs and programs:** start, status, list, logs, cancel, cleanup,
  and multi-step orchestration. Command, agent, and resident-service runners
  plus the durable dispatcher replace separate job and program ledgers;
  task-specific orchestration belongs in workers.
- **Tool-source scouting:** list, inspect, research, compare, adapt, and update
  external tools, repositories, skills, or APIs into locked worker versions.
  The motivating `last30days` adaptation is the first concrete example.

#### External-world behavior

- **Web research:** robots-policy handling, search, crawl, source discovery,
  source review, source archive, freshness checks, citation extraction, and
  synthesis. `web_fetch` is only the bounded HTTP actuator; provider search,
  browser control, authenticated sites, crawling policy, and research strategy
  must be real workers.
- **Transcription and speech:** transcribe, status, model preload, language
  detection, diarization, and audio preprocessing. The native client owns
  bounded microphone capture, off-main-thread 16 kHz WAV normalization, and
  base64 projection. A healthy worker may declare the kernel-validated
  `speech_transcription` client action; when that owner is a resident service,
  activation waits for service/model readiness and reuses its verified private
  snapshot across calls. Initial readiness has a bounded 60-second window for
  one-time local model initialization; steady-state health probes remain
  short. The authenticated client sends the recording through
  the ordinary durable dispatcher, may request an immediate receipt without
  the already-durable input echo, and inserts its typed `text` result into the
  draft. Later run inspection remains complete. Model choice, dependencies,
  recognition, and cleanup remain entirely worker-owned.
- **Devices and notifications:** the reminder use case now owns the narrow
  `notification_delivery` path described above: authenticated registration,
  logical inbox sync, status inspection, fixed acknowledgement actions, and
  explicitly selected relay or direct APNs transport. Delivery scheduling and message policy remain in
  workers. This contract is intentionally not a general device domain.
- **External services:** email, calendars, issue trackers, source control
  hosting, messaging, databases, and home or business systems should enter as
  named-secret-bound workers authored when their first real workflow appears.

#### Developer and engine-maintenance behavior

- **Git workflows:** status, diff, branch inventory, stage, unstage, commit,
  branch creation, review preparation, test selection, and repository cleanup.
  Filesystem and process primitives are sufficient substrate; reusable safe Git
  behavior should be worker-authored.
- **Trace, log, and replay analysis:** trace list/get, recent-log analysis,
  replay-manifest generation, failure clustering, and regression-fixture
  creation. Raw durable evidence remains kernel-owned; interpretation and
  remediation workflows belong in workers.
- **Catalog and conformance analysis:** search/inspect the live engine surface,
  compare worker contracts, validate scenario coverage, and recommend worker
  consolidation. `engine::surface_snapshot` supplies the operator truth; higher
  level analysis should be a worker.
- **Core maintenance:** a fresh software-maintenance worker may be authored
  when an observed workflow establishes a bounded contract. The retired
  Software Workspace is not an automatic source-editing trigger. Tron retains
  no separate proposal store or apply actuator; normal repository history and
  the user's explicit request remain the review boundary.

### Kernel substrate already replacing separate behavior

- Filesystem read/list/search/write/edit, process execution, bounded HTTP fetch,
  and durable session-title mutation are direct host tools.
- Command, agent, and resident-service execution; dependency locking; named
  secrets; manual, schedule, event, and webhook triggers; queueing; retries;
  timeouts; causal traces; inbox; health; disable; rollback; retirement; purge;
  stop; and stop-all are worker-kernel custody.
- Deterministic worker discovery, live provider projection, version-bound
  promotion, dynamic surface revisions, and stale-contract rejection provide
  same-session adaptation without a separate relevance worker or catalog plane.
- Durable sessions, provider/model turns, `tool.invocation.*` evidence,
  compaction mechanics, authenticated transport, settings, credentials, and
  blobs remain fixed because they custody the runtime that workers depend on.

### Administrative planes that must not be recreated

Do not rebuild package proposals, validation records, installation requests,
activation decisions, dependency approvals, binding requests, grants, resource
selectors, leases, compensation records, shadow trials, replacement-candidate
records, route-binding records, lifecycle request/decision ledgers, or generic
operation catalogs. `worker_upsert` already validates, tests, atomically
publishes, activates, versions, routes, and registers triggers and tools. Source
identity, dependency locks, content hashes, traces, health, runs, inbox results,
and audit records remain observations, never permission gates.

Several removed domains only recorded intended activity: import/update,
procedural activation, scheduling, and web research did not themselves perform
the useful external action. Their record shells are not missing functionality.
Notification delivery is the deliberate exception now restored behind a real
reminder worker and a narrow authenticated APNs contract. Other executable
behaviors should still be restored one proven worker at a time.

## Storage

The primary `tron.sqlite` remains the source for sessions, messages, provider
audits, streams, scoped engine state, terminal metadata, approval-message
evidence, and the dormant core stable-agent/assignment/result/wake successor.
Worker bundles remain filesystem-canonical; the worker database owns their
derived indexes and durable operational history until compatibility removal.

### Tables

| Table | Ownership |
|---|---|
| `agent_assignment_attempts` | restart evidence for one stable core assignment; an attempt never becomes a second work identity |
| `agent_assignment_delivery_holds` | one-way FIFO admission latch that keeps accepted assignment instructions out of every provider lease until their exact Running state and attempt baseline commit |
| `agent_assignments` | unadvertised core FIFO work, immutable authority/resource snapshot, assignment-only causal topology, lifecycle, retry linkage, and terminal timestamps |
| `agent_deliveries` | durable session/mailbox updates, safe-boundary leases, wake policy, result grants, and observation state |
| `agent_message_metadata` | canonical bounded agent-message content, semantic provenance, reply linkage, channel order, and safe-boundary materialization/observation state |
| `agent_results` | one immutable inline or content-addressed result envelope per terminal core assignment |
| `agent_session_promotions` | idempotent cross-store receipt for making one promoted nested-agent transcript visible in Sessions |
| `agent_wait_members` | exact top-level worker members and terminal evidence for durable waits |
| `agent_waits` | durable current-session all/any wait state |
| `agent_wake_intents` | Engine-derived actionable delivery causes, safe-boundary leases, acknowledgement, and restart recovery |
| `agents` | stable core identity, persistent transcript, immutable lineage/owner, visibility, lifecycle, and reusable defaults |
| `coordination_dependency_edges` | immutable normalized mixed-execution parentage and assignment/direct-agent executor dependencies used by wait-cycle admission |
| `coordination_wait_dependency_nodes` | additive owner/member mapping from opaque coordination handles to exact internal dependency identities |
| `coordination_wait_dependency_topologies` | canonical per-wait edge-set seal that makes dependency replay immutable, including for an originally empty topology |
| `coordination_wait_inline_results` | exact consumer binding for a wait resolved inside its registering tool call, preventing a duplicate aggregate continuation |
| `coordination_wait_members` | opaque assignment, worker-invocation, and reply handles plus exact terminal evidence for generalized fan-in |
| `coordination_waits` | reusable-agent all/any park state and its one aggregate result-message binding |
| `blobs` | content-addressed durable payloads |
| `engine_catalog_revision` | current typed-function surface revision |
| `engine_idempotency_entries` | engine invocation idempotency ledger |
| `engine_invocations` | generic engine invocation history |
| `engine_state_entries` | engine-owned state values |
| `engine_stream_events` | durable engine stream records; topic-tail polling and session replay are cursor-indexed |
| `events` | session event log |
| `logs` | structured session logs |
| `sessions` | session metadata |
| `storage_payload_refs` | payload ownership references |
| `terminals` | native PTY launch identity, session ownership, replay cursors, process state, and bounded retention metadata; exact output bytes remain in private journals |
| `workspaces` | workspace metadata |

### Worker database

The worker database is `~/.tron/internal/database/workers.sqlite`. Bundle,
version, route, and trigger indexes rebuild from canonical worker files;
invocation, attempt, trace, inbox, health, audit, and stop-all rows are durable
operational evidence:

| Table | Ownership |
|---|---|
| `worker_schema` | worker index schema version; v12 adds atomic worker handoffs and split notification ownership; v13 adds self-only delayed invocation custody; v14 adds artifact custody and storage attention; v15 adds the exact session-organization mutation outbox; v16 adds the immutable worker-to-agent terminal/effect outbox; v17 adds requested/effective invocation model and reasoning policy; v18 adds operator inbox dispositions and the scheduled-trigger projection index; v19 adds reusable-agent coordination custody; v20 adds durable agent-role review proposals and interrupted-apply recovery; v21 adds durable due-time retry scheduling and poison terminalization for the coordination outbox |
| `worker_agent_role_review_proposals` | Immutable target/reviewer/invocation provenance, proposal hash/schema, explicit declaration/rationale, user-confirmed apply/reject state, and retained recovery evidence |
| `blobs` | generic content-addressed compressed result bodies larger than 8 KiB |
| `storage_payload_refs` | one generic ownership/integrity row for every successful invocation output |
| `workers` | rebuildable current catalog |
| `worker_versions` | rebuildable version index |
| `worker_routes` | rebuildable direct-tool route and routing metadata |
| `worker_triggers` | rebuildable trigger configuration and cursors |
| `worker_invocations` | durable queue, optional self-wakeup `not_before`/source linkage, idempotency, pinned version, originating user session, child-agent session, nested parent/per-tool call slot, and exact typed results addressed by public result references |
| `worker_model_tool_result_associations` | many-to-one provider tool-call identities for one canonical invocation result, including regenerated ids from restart redelivery |
| `worker_attempts` | numbered execution/redelivery attempts |
| `worker_run_events` | append-only generic stage evidence for authoritative run timelines |
| `worker_causal_traces` | trace roots, depth, delivery, and suppression counters |
| `worker_trace_deliveries` | unique worker/trigger/idempotency combinations per trace |
| `worker_inbox` | durable compact result-reference receipts, failure records, and agent-context attachment state |
| `worker_inbox_dispositions` | immutable idempotent operator dismissals that remove retained failures from live Attention without editing result or execution evidence |
| `agent_delivery_outbox` | immutable pending/imported/rejected terminal and worker-declared Agent Delivery effects |
| `agent_instances` | stable agent identity, hidden transcript-session link, immutable spawn lineage, current management owner, role/version, visibility, default grant/limits, workspace, and lifecycle state |
| `execution_nodes` | common causal topology for agent assignments and worker invocations, including trace, depth, owner, and deterministic child order evidence |
| `coordination_trace_states` | restart-durable autonomy pause/resume state, owning root session, reason, and timestamps for one mixed causal graph |
| `agent_assignments` | reusable-agent FIFO work, immutable admission snapshots, retry linkage, terminal failure, and exact integrity-bound result custody |
| `agent_assignment_attempts` | numbered provider execution/recovery attempts without replacing the stable assignment or transcript |
| `agent_execution_events` | append-only assignment/execution state evidence |
| `agent_outbox` | idempotent provisioning, semantic message, terminal result, and client-projection effects with due-time retry, attempt count, bounded error evidence, and imported/rejected terminal state |
| `agent_management_grant_batches` | atomic idempotency receipt for an exact validated set of non-transitive subtree management grants |
| `agent_management_grants` | bounded, non-transitive assign/cancel/configure/close authority over one specific agent subtree |
| `agent_write_claims` | durable FIFO scoped-write and whole-workspace process collision claims; coordination evidence, not an OS sandbox |
| `direct_worker_agent_runs` | stable one-to-one bridge from a direct agent-runner worker invocation to its shared Agent Execution identity and assignment |
| `worker_audit` | lifecycle and mutation evidence |
| `worker_health` | versioned activation/lifecycle/execution health history |
| `worker_runtime_settings` | durable engine stop-all state |
| `worker_dispatches` | deduplicated source route, immutable target invocation, causal parent, response binding, and terminal handoff state |
| `worker_session_organization_intents` | atomic canonical session-label/group/archive/restore mutation outbox with bounded retry and stale-claim recovery |
| `worker_artifacts` | immutable worker/artifact identity, declared display metadata, source invocation/version/trace, and content-addressed payload reference |
| `worker_artifact_storage_state` | singleton transition state for whole-worker-database artifact storage attention |
| `notification_installations` | registered iOS installation readiness, paired route, permission, and transport token material; tokens never enter API responses, exports, archives, or logs |
| `notification_deliveries` | deduplicated logical worker-authored deliveries and synchronized read/terminal-response state |
| `notification_delivery_targets` | independent per-installation dispatch state and sanitized APNs acceptance/failure evidence |
| `notification_delivery_attempts` | append-only alert and quiet-refresh transport attempts |
| `notification_responses` | idempotent client mutations and first-wins terminal disposition |
| `notification_refreshes` | coalesced quiet-refresh work for unread and badge reconciliation |

Schema v10 was preceded by one verified profile snapshot. Its backfill writes
content ownership in restart-safe bounded staging transactions without changing
schema-v9 invocation or inbox rows. One final transaction verifies all
owners/digests/blobs, publishes large-result envelopes and compact inbox
receipts, and records v10. Interrupted staging therefore leaves the old logical
view intact and safely resumes; only the verified cutover becomes visible.
Schema v11 then adds notification durability without rewriting canonical worker
run evidence. Schema v12 adds asynchronous handoffs and backfills direct
deliveries with the original worker as both source and producer. Schema v13 adds
self-only delayed invocation custody. Schema v14 adds artifact custody without
copying result bytes into metadata or inbox rows.

## Events and Transport

`GET /engine` remains the authenticated WebSocket upgrade endpoint for clients.
Its one request operation invokes a canonical function id directly and returns
that function's value directly in the top-level result; there is no registered
`engine::invoke` delegation or child-result wrapper in the transport contract.
The wire admits client scope and optional idempotency metadata but rejects
injected internal authority/runtime fields. Bearer rotation continues to force
client re-pairing.

Live subscriptions are socket-local resources. `subscribe` creates a cursor,
`ack` advances it, and idempotent `unsubscribe` releases it as soon as the
client's presentation or processing owner ends. A socket admits at most 64
active subscriptions; disconnect still clears every remaining cursor. The cap
and explicit release bound the server's 250 ms push-poll work without creating
a durable subscription registry.

Correlated invocation requests are admitted concurrently through one bounded
connection-owned task set. A slow function can no longer monopolize the socket
read loop and strand later session resume/reconstruction or subscription
frames; correlation IDs own out-of-order responses, and disconnect cancels and
boundedly drains all admitted work. Synchronous notification ledger reads and
writes run through the shared blocking supervisor rather than occupying async
runtime threads.

Authenticated hello responses include a capability list. `terminal.v1`
identifies the native Terminal seam and is also reported by
`engine::surface_snapshot` as a native capability, separate from fixed
model-facing primitives. The terminal domain owns one live login-shell PTY per
session, always rooted in the session's normalized working directory.
Native-client-only typed functions list/open/write/resize/terminate terminals;
they admit authenticated app clients and the engine while excluding agents and
workers. Socket-local
`terminal.attach`/`terminal.detach` frames stream ordered output without routing
terminal bytes through the session event log or model context.

Each output record has a monotonic sequence and is appended to a mode-0600
journal under `internal/terminal/`. Live replay is capped at 64 MiB; a vt100
screen checkpoint atomically replaces the replay base when the cap is crossed,
allowing reconnecting clients to reset and continue without unbounded memory or
disk growth. Input carries a client-generated idempotency identity, resize is
bounded, and the service admits no more than eight concurrent PTYs. Closing a
client attachment does not terminate work. Server restart deliberately marks
live terminals interrupted rather than pretending processes survived; exited
and interrupted output remains read-only for 24 hours, then its SQLite index
and private journal are purged together. Shutdown kills all owned process
groups, and Tron transport-token environment variables are removed from the
child shell environment. Login shells otherwise retain the user's own startup
configuration, while an empty `PROMPT_EOL_MARK` suppresses zsh's synthetic
reverse-video `%` before the first real prompt.

Closed `session::*` payload schemas admit only values their owning operation
consumes. Session and workspace provenance belongs to the authenticated
transport context; it is not duplicated as ignored `sessionId`/`workspaceId`
payload ceremony. In particular, session creation accepts only working
directory plus optional model/title, while unscoped listing accepts only its
actual pagination and filtering inputs.

The same rule applies to `agent::*`: prompt commands admit the session id,
prompt, optional reasoning level, and attachments actually consumed by the run;
`answer_user_input` admits the exact pending invocation and structured answers;
status/abort commands admit only their behavioral identifiers. Ignored
workspace and source-label fields are not part of public or hidden agent
contracts.

`request_user_input` uses the ordinary tool lifecycle as durable state. A
successful completion is pending; the answer endpoint checks the invocation in
that same session, validates a non-empty submitted subset against the exact
persisted question IDs/options, and appends one uniquely indexed structured
user event. Unanswered questions are intentionally omitted. The answer
then enters the normal prompt admission/run guard. Duplicate delivery is
idempotently acknowledged, concurrent answers cannot create two canonical user
events, and restart/reconnect needs no in-memory continuation or second pause
database.

Session events are the only durable owner of assistant output. Prompt completion
emits lifecycle and runtime-stream status without recreating a parallel
`agent_result` resource. Structured diagnostic logs use short SQLite write
waits; an atomically failed batch remains queued for the periodic retry rather
than blocking an agent turn or being dropped during ordinary writer contention.
Shutdown records checkpoint and terminal lifecycle evidence before a bounded
final drain of that retained batch.

Worker live topics are:

- `worker.lifecycle` — activation, per-worker stop, enablement, disablement,
  rollback, retirement, purge, engine stop/resume, failure, and related state;
- `worker.invocations` — started/completed/failed/cancelled invocation summaries.

Reusable-agent invalidation topics are `agent.lifecycle`, `agent.assignment`,
and `agent.message`. They carry only enough owning-session/agent identity to
coalesce a targeted reread; assignment state, message content, results, and
allowed actions remain canonical read projections.

Invocation stream envelopes carry the invocation ledger's durable
`origin_session_id`. Descendants therefore invalidate the originating user
session, while scheduled and otherwise sessionless work remains unscoped.
Lifecycle facts stay global because they invalidate catalog metadata. Both
topics are lossy observation hints: clients coalesce them and reread durable
worker/session projections; delivery, wait, and completion correctness never
depends on receiving an event.

The durable session log has **16 event variants**. Live-only deltas, progress,
context notices, and errors remain transport events and are not duplicated as
unwritten storage contracts:

| Concern | Event types |
|---|---|
| session | `session.start`, `session.end`, `session.fork`, `session.model_changed`, `session.reasoning_changed` |
| messages | `message.user`, `message.agent`, `message.assistant`, `message.deleted` |
| model | `model.provider_request` |
| provider tools | `tool.invocation.started`, `tool.invocation.completed` |
| turns | `stream.turn_start`, `stream.turn_end`, `turn.failed` |
| context | `compact.boundary` |

The `tool.invocation.*` names describe generic provider tool-call
conversation evidence. `tool.invocation.progress` and
`tool.invocation.output` are transient, monotonically sequenced live updates
correlated to the exact provider call. The durable
`tool.invocation.started`/`tool.invocation.completed` pair remains the
reconstruction and terminal source of truth.

## CI Authority and Portable Evidence

GitHub Actions remains the authoritative merge and release control plane.
Protected `main` requires its single fail-closed `CI summary`; successful
exact-main validation remains the sole automatic trigger for internal
TestFlight, and release tags remain the owners of public TestFlight and Mac
publication. No shadow provider receives Apple credentials or release-runner
access.

The provider boundary is repository-owned rather than encoded only in workflow
syntax. `config/ci-policy.json` declares authority, required workloads,
toolchain/config inputs, release ownership, and the non-authoritative Buildkite
shadow role. `scripts/ci-provider-context.py` normalizes GitHub and Buildkite
metadata and verifies the actual checked-out source. One Buildkite source step
pins GitHub's synthetic merge ref, proves the bootstrap bytes executed before
checkout match the merge, and distributes a history-bounded,
prerequisite-excluding thin bundle proportional to the merge delta. Every
workload then verifies the commit, tree, parents, and executed-bootstrap record.
GitHub's aggregate evidence job keeps its exact merge checkout at depth one and
reads the tree plus ordered parents from the immutable raw commit headers; it
does not mistake shallow revision-walk output for a parentless source or fetch
unneeded history.
The same-ref fetch uses a bounded propagation retry for an unavailable or
still-old merge ref. It accepts and checks out only the fetched object whose
ordered parents equal the provider-cached GitHub webhook's immutable base/head
pair. The webhook's nullable `merge_commit_sha` can lag that regeneration and
is observational rather than authoritative; Actions independently proves its
exact merge-ref `GITHUB_SHA`, checkout, and ordered parents. Main
uses that immutable payload's `before`/`after` rather than deriving a base from
commit parents. The raw payload stays ephemeral and is never an artifact.
Normalized context retains the exact provider trigger action. Missing,
malformed, draft, tag, or
unsupported provider context fails before validation.

`tron.validation.v2` evidence records provider/run identity, exact PR
base/head/merge commit and tree, policy and pipeline digests, the complete
required-job set, deterministic toolchain digest, sanitized iOS metrics, and
artifact SHA-256 metadata. The document carries a canonical self-digest so
transport corruption is detectable; GitHub artifact digest verification remains
the authority for main-reuse. Historical v1 evidence remains parseable for
audits, but is ineligible for current main reuse and provider parity.
Main selects the newest fully validated exact proof and retains its self-digested
reuse receipt plus byte-exact downloaded validation-artifact ZIP for 90 days;
otherwise it runs the full matrix. Provider-native caches and artifact metadata
never count as provenance.

`.buildkite/pipeline.yml` is an opt-in advisory experiment. The provider-side
activation and confinement contract lives in the
[Buildkite shadow runbook](../../../.buildkite/README.md). Its hosted Linux and
pinned M4 macOS jobs call the same repository scripts as GitHub, emit shadow
evidence, and cannot publish, notarize, sign, or use the isolated iOS release
runner. Cross-build writable Cargo, target, and rustup caches are deliberately
disabled so pull-request code cannot seed state later consumed by `main`.
`scripts/validate-ci-definitions.sh` uses repository-owned actionlint and
Buildkite-agent pins to validate GitHub workflows and dry-run both Buildkite
graphs with secret and parse-warning rejection. The derived Rust image installs
and executes the exact root toolchain's rustfmt/clippy components before the
quality suite. Checksum-pinned tool downloads retry bounded transient failures
and are atomically cached only after verification. `scripts/ci-parity-report.py` compares authoritative and candidate v2
evidence fail-closed. It binds each provider to its current policy-owned
configuration (without requiring those provider-specific digests to equal),
requires the exact workload set plus context, iOS metrics, and six Buildkite
job manifests, and ignores only expected host/timing differences. Comparison
also requires both extracted artifact directories. Every evidence-manifested
payload is safely resolved beneath its directory and stream-verified for exact
size and SHA-256; ambiguous, traversing, symlinked, missing, or multiply-mapped
files fail. The context and iOS payloads must equal their evidence, while
Buildkite's job manifests and bootstrap execution record must bind the same
build, pinned context, metrics, and current bootstrap. Every successful job
manifest must structurally name its exact job-local command log and provider
context; iOS must name its exact metrics path, and PR Mac must name
`packages/mac-app/dist/Tron-dryrun.dmg`. Context and metrics are content-bound,
but nested command-log and DMG payload custody remains external because those
provider-held files are absent from shadow evidence. This is offline payload
integrity and semantic parity only: it does not authenticate provider custody,
artifact IDs, run conclusions, nested job payloads, or API metadata. Provider
API exports own those observations.
Buildkite cannot become a required check or release owner until a window of at
least 30 days independently contains 30 representative ready-PR source cohorts,
30 eligible `main` pushes, 30 authenticated eligible TestFlight deliveries, and
30 successful cross-provider parity samples showing exact behavioral parity and
materially better measured reliability, followed by separately authorized
release-security proof and an atomic rollback design.

The policy's workflow inventory makes replacement scope explicit: CI merge/main
validation, PR fast feedback, server performance, iOS performance, iOS release,
and Mac release. The checked-in Buildkite graph covers only the first as a
secretless shadow. Policy-owned blockers keep the other workflows, fork and
skip-token trigger continuity, manual dispatch, provider custody, release tags,
TestFlight handoff/delivery, and Mac release from being mistaken for completed
parity. The same contract fixes the public ASC app, app/share-extension bundle
IDs, Xcode scheme, and release configuration that TestFlight evidence must
match exactly. Delivery channel identity (`internal`, `external`, or `public`)
is modeled separately from its latest-green-main or `server-v*` trigger.

An always-run, soft-failing Buildkite observer records all six post-bootstrap
step outcomes and identity-bound or missing manifests. Provider API exports
remain canonical for missing triggers, source-bootstrap failures, canceled
dependencies, outages, retries/rebuild ancestry, and superseded heads. Provider
settings must disable statuses, forks, tags, the GitHub-specific
`build_pull_request_merge_commits` provider-generated PR merge
checkouts, and queue secrets, then enable skip plus cancel-intermediate behavior
with `!main`, preserving complete `main`
history while avoiding superseded Apple work. The independent trigger universe
includes every non-draft PR-to-`main` `opened`, `synchronize`, `reopened`, and
`ready_for_review` source event, including CI-skip titles; provider suppression
is a candidate `missing`, not an allowed export filter.
The strict token universe includes both providers' documented bracketed forms
and both GitHub `skip-checks` trailer spellings. A commit-message ruleset cannot
neutralize Buildkite's PR-title suppression, so independent trigger
reconciliation and its policy blocker remain required.
Since the initial bootstrap is PR-authored code with an agent session token,
safe activation additionally requires a dedicated secretless hosted cluster
whose only addressable queues are the documented Linux and Mac shadow queues.
It must have no path to release/self-hosted agents; pipeline YAML checks cannot
substitute for that provider-side confinement.
The settings attestation additionally requires PR, ready-for-review, reopened,
and `main` branch builds, keeps existing-commit PR suppression disabled, and
records that GitHub `workflow_dispatch` currently has no Buildkite parity lane.
Provider-backed fields use Buildkite's API names and values directly:
`trigger_mode` must be `code`; status, PR, tag, merge-checkout, and trigger
booleans retain their `publish_*` and `build_*` names; and the pipeline retains
`branch_configuration`, `skip_queued_branch_builds`, and
`cancel_running_branch_builds` with their exact filters. The evaluator rejects
the GitLab-only `build_pull_request_merge` field and translated aliases such as
`code_trigger_mode`.
Shadow enablement also requires the GitHub ruleset to bind `CI summary` to the
GitHub Actions app integration ID `15368`; a name-only required context is
insufficient once another CI app is installed. The authority-ruleset export
and Buildkite status-disabled attestation jointly preserve that boundary.

`scripts/ci-cutover-evaluation.py` joins strict normalized exports for eligible
events, both providers, independent product verdicts, TestFlight delivery, and
candidate settings with separately supplied release-security and rollback
proofs. It emits `tron.ci-cutover-evaluation.v2` from a
`tron.ci-cutover-observations.v2` ledger and requires
`tron.ci-testflight-export.v2`; v1 release observations lack the complete exact
run-attempt eligibility and intent/head/provenance/admission/reuse/receipt
history and are rejected rather than upgraded by inference. Every trigger
delivery remains visible, while repeated actions for one PR+source form one
cohort and superseded heads do not inflate the independent minimums of 30 PR
cohorts, 30 eligible main pushes, 30 authenticated eligible TestFlight
deliveries, 30 successful parity samples, and a 30-day window. Candidate
reliability must be at most 1%,
improve by at least two percentage points, and win the paired one-sided exact
McNemar/binomial test at p <= 0.05, in addition to the latency and zero-error
gates. Because an offline wrapper cannot authenticate its claimed live API
response, threshold success remains
`observation-thresholds-satisfied-provenance-unverified` with
`eligible_for_external_review: false`; live API and controlled-proof
re-verification remain blocking. No evaluator path mutates CI or release
authority, and the report must reproduce the complete policy-owned blocker set
rather than narrowing replacement to the measured merge lane.
Each TestFlight observation joins authoritative and candidate main-run source,
outcome, attempts, operational evidence, and end-to-end latency, then binds the
delivery to the authoritative GitHub completion. Candidate main validation is
therefore measured, but a candidate-main-to-GitHub-release handoff is not;
`candidate-main-release-handoff-parity` remains independently blocking.

## iOS Client

**Minimum iOS:** 26.0. The generated project and documented toolchain workflow
support Xcode 26 and Xcode 27 without source forks for their runtime SDKs.

The iOS Engine Dashboard is backed by `WorkerKernelClient`,
`WorkerKernelRepository`, `WorkerConsoleViewModel`, and `UI/WorkerConsole`.
It exposes:

- an always-visible profile summary of fixed and published worker-tool
  availability, current operational state, issue count, and active
  worker-owned engine hooks, followed by Core, Workers, and Activity tabs;
- a Core inventory of all fixed host, worker-control, and core-change tools,
  including schemas and current exposure;
- published workers with explicit profile-global availability to agents;
  session promotion and raw query-relevance scores are reserved for a future
  named-chat diagnostic rather than shown without context;
- worker list, health, explicit runner type, active content version, successful
  run count, provenance, and triggers;
- JSON-schema-aware typed invocation;
- engine-wide Activity plus per-worker runs, durable inbox, and audit history;
  Activity can load every bounded history page, and any agent-runner row opens
  its exact hidden child session for detailed inspection;
- exact invocation and originating model-tool graph lookup, rendering the
  server-authored stage, causal tree, structured timeline, timing/usage,
  terminal result or failure, and child-session links before subordinate raw
  technical payloads;
- generic detach, bounded await, causal-subtree cancel, and immutable retry
  controls whose availability follows the projected durable run state;
- stop current work without disabling future dispatch, enable/disable, rollback,
  retained-version restoration after retirement, purge, webhook rotation, and
  stop-all;
- live refresh from `worker.lifecycle` and `worker.invocations` cursors, owned by
  the persistent sidebar task so state remains current while the sheet is closed.

Successful run and inbox DTOs carry integrity-bound result references and
previews, never copied result bodies. The bounded result inspector is the
explicit exact-read path. Native synchronous worker experiences may resolve
only the just-completed bounded result needed by their typed contract; historical
lists, reconnect, and server switching remain reference-only and reconstruct
from server truth. A temporary inline decoder exists only for schema-v9
migration compatibility.

Conversational creation remains the authoring interface; the client does not
contain a bundle editor. The Mac package is a server supervisor/pairing shell,
so iOS is the only current operational engine client requiring the console.
The Dashboard explicitly requests bounded 20-record detail pages for runs and
inbox items and follows server-issued offsets on demand; model calls retain the
compact default. Worker child sessions never appear in the ordinary home list,
but remain reachable from their run cards and native Delegation detail.

Compaction is a direct durable session boundary. Context clearing is a live
transport event; the resulting context size is reflected by later session/token
truth rather than an unwritten `context.cleared` storage row. The iOS composer
projects that same token truth as a context ring. The user-facing Manage Session
sheet uses the provider-request event as its sole request-context authority. It shows no
request-history card: `session::context_requests(limit: 1)` loads and caches the
overview only after Manage Session is presented, and
`session::context_request_detail` loads a lightweight
`agent_context` or full `technical` projection only for an opened row. iOS
caches those immutable projections separately while the sheet is mounted and
stores only the compact inventory beside its disposable
session row for offline presentation. Provider audit bodies never enter the
transcript or chat-reconstruction path, and older cached bodies are reduced to
deferred markers when the cache schema opens.

The sheet presents one high-level navigation inventory. Product-facing Agent
Context contains instructions, conversation/compaction, attachments,
request-specific Agent Delivery contributions, available tools, and continuity
narratives. Technical Details alone contains digests, identifiers, redacted
environment provenance, exact selected/omitted tools, cache layout, and the
redacted provider audit. Session-scoped Background Activity and Session Workers
open as bounded sub-sheets rather than mounting their histories in the main
sheet. A stable Agents row appears between Agent Context and Background
Activity; Session Workers remains a separate evidence surface. Empty
included-delivery evidence is distinct from ordinary conversation and user-input
answers. Rows remain represented while disconnected and disable only the
unavailable action so reconnect reconciliation restores interaction without
reshaping the sheet.

The Agents lane activates network management only after the server advertises
the complete `agent_coordination.v1` protocol. Older or disconnected servers
retain the row and last authoritative snapshot, showing either
`No child agents or agent conversations` or `N active · M related` rather than
reshaping the sheet. `agent::relations` supplies paged, nonduplicating Child
agents in parent-first hierarchy and Other agents for parents, ancestors,
promoted/managed agents, and durable-message correspondents. The client does
not join local session and worker caches to infer those relationships.

Agent Detail reads canonical inspect, assignment-history, message-history,
message-detail, result, and authorized transcript projections. It uses the
Worker Console's cards, typography, detents, status treatment, bounded result
inspector, and generalized read-only Audit Session sheet. The detail surface
shows current work, assignment history, role/version, effective capabilities,
management grants, limits, write claims, exact bidirectional communication and
reply linkage, own/subtree usage, results/failures, lineage, children, contacts,
and technical provenance. No device transcript cache or model-visible raw
session ID is introduced.

Every mutation is gated by server-authored `allowedActions` and an exact
disabled reason; the app never infers authority from a relationship label.
Authenticated operator instructions, owned cancellation/close, future-default
configuration, bounded management grants, role upgrades, linked retries, and
promotion carry one idempotent client mutation identity. Destructive or
ownership-changing actions require confirmation. Cancellation authorization
also carries the exact current count of cancellable mixed agent/worker
executions so clients never derive destructive impact from paged history. There is no top-level Agents
destination, graph canvas, manual Spawn form, or custom client-side lifecycle
state machine in this version.

Agent relationship and detail repositories use a lazy refresh lane with
generation fences, single flight plus one dirty follow-up, paged
deduplication, a bounded two-second cadence only while related work is active,
and one foreground/reconnect reconciliation. Coalesced `agent.lifecycle`,
`agent.assignment`, and `agent.message` events are invalidation hints only;
the client always rereads canonical server projections and never trusts event
payloads as state or message content.

Global worker architecture is inspected in the Engine dashboard, where each
canonical worker row and detail merges direct/internal and agent/command shape,
hook/native boundaries, dispatches, and `agentTools` calls/called-by
relationships with that worker's health, activity, versions, and lifecycle.
Manage Session does not load or duplicate that global directory. A bounded
session-scoped worker sheet reads
`worker_runs(originSessionId: ..., detail: "graph")`. The server pages by
causal root so one coordinator's many descendants cannot crowd later runs out
of Manage Session; exact child and originating model-tool filters reopen the
same root graph. The client opens this canonical detail rather than inventing
another activity store. Worker progress/output strings are not accumulated
into client state or concatenated into a guessed stage; only non-worker tools
retain the generic free-text lifecycle presentation. Lifecycle invalidation
and reconnect re-fetch the graph, with one-second polling used only while a
visible run remains active. Background delivery/wait state shares that bounded live
cadence. Provider-context audits are immutable once written, so the sheet reads
that lane on open, reconnect, and foreground, then once when activity settles
rather than transferring a large manifest every second. An agent-runner row can
open the same Manage Session
inspection for its child `agentSessionId`; command workers truthfully report
that no nested model context exists.
It has no parallel context-control resource client, resource/action audit,
memory editor, or fabricated manual compact/clear API.

The final Settings row opens the Logs sheet in every iOS build configuration;
the leading toolbar is reserved for the synchronized Notifications inbox.
While connected, Tron automatically ingests deduplicated client logs into the
server log store. Successful ingest plumbing is filtered to prevent
self-feeding diagnostics loops.

For fast production-identity testing, the `Tron Fast` scheme uses the
`ProdDebug` configuration. Codex device actions include Rebuild + Install + Launch
and Just Launch Installed variants, target a deduplicated production app, and
the rebuild action installs the requested configuration's `iphoneos` artifact.

Hosted iOS distribution uses one App-Store-eligible `Tron` / `Prod` archive
path for two TestFlight channels. A successful main-branch CI push uploads its
exact tested commit to the configured automatic internal group only while that
commit remains the current main head. A secretless hosted gate checks before
the release queue and retains every automatic attempt as
`tron.ios-release-eligibility.v1` for 90 days. A workflow-level concurrency key
serializes the entire intent/effect/receipt transaction for one authoritative
upstream CI run without cancelling it; distinct CI run IDs remain independent.
The isolated runner checks current main after its queue and again immediately
before App Store Connect delivery.

Automatic retries are resolved from canonical, attempt-unique GitHub artifacts.
`tron.ios-release-intent.v1` forms a linear `new`/`resume`/`completed` history
whose first entry permanently owns the build allocation. Binary provenance and
the final main-head check feed `tron.ios-release-admission.v1`, which records the
exact ASC build ID before distribution. Reusing an admitted build requires the
original provenance and admission chain, emits
`tron.ios-release-reuse-provenance.v1`, and produces a new chained admission;
matching a version/build number alone is never authority. The final
`tron.ios-release-receipt.v1` binds internal group delivery to the admission
tail and is published only after credential teardown succeeds. If ASC accepts a
fresh binary but GitHub cannot durably publish its admission, the unavoidable
cross-system dual-write window is terminal for that allocation: a retry leaves
the unadmitted build untouched and directs an operator to a fresh manual
internal run from current main.

Tag and manual live runs preserve the same custody without reinterpreting those
automatic schemas. Their run-ID-scoped records are
`tron.ios-release-direct-intent.v1`,
`tron.ios-release-direct-source-check.v1`,
`tron.ios-release-direct-admission.v1`,
`tron.ios-release-direct-reuse-provenance.v1`, and
`tron.ios-release-direct-receipt.v1`. Manual live source must equal current
`main` at checkout and immediately before ASC; tag source must remain a
`main` ancestor. Existing builds require an exact prior direct admission/ASC-ID
join. External review-pending runs retain admission without a completion receipt
and resume the same build after approval; completed evidence skips the release job.

Hosted iOS `CFBundleVersion` values come from the Release workflow's one
monotonic run-number counter. Owner run `N` maps to
`(1000 + floor(N / 100)).(N % 100).1` for automatic delivery and lane `.2` for
tag/manual delivery. Upstream and downstream reruns authenticate the first
intent's owner, while `VERSION.env` continues to own canonical product versions
and local/Mac Apple build mirrors. All ASC lookups specify platform `IOS`, and
processing and replay-safe group assignment follow the exact ASC build ID.
Release tags independently advance their build through external Beta App Review
and the public group. Pull-request CI never receives distribution credentials or
triggers TestFlight delivery. The TestFlight job runs on GitHub's ephemeral
ARM64 `macos-26` image behind the protected `ios-testflight` environment.
The workflow selects Xcode 26.6 explicitly; the pre-secret toolchain doctor
requires `RUNNER_ENVIRONMENT=github-hosted`, `ImageOS=macos26`, ARM64, Xcode
build `17F113`, the iOS 26.5 SDK, completed first-launch state, and bounded
free capacity. A beta Xcode path fails before any signing or App Store secret is
admitted. The exact hosted image inventory and repository manifest are the two
rotation inputs.

This replaces the former long-lived hidden-account runner. Xcode 26.6's asset
compiler launches CoreSimulator helpers even for device archives, while that
runner's intentionally headless Background domain denied the helper's device
directory. The hosted image supplies the normal Aqua/CoreSimulator and keychain
services; it also removes the custom launchd agent, service account, persistent
checkout, baseline keychain, runner registration, and cross-job recovery ledger
from the production surface. Pull-request CI still never receives distribution
credentials or triggers TestFlight.

ASC authentication is environment-backed. Manual signing captures the hosted
user's existing keychain search/default state, validates its `.p12` leaf
through checksum-pinned WWDR G3 and Apple Root certificates without ambient
issuer discovery, and imports the leaf/private key plus WWDR into one
run-attempt-named keychain. The trusted root stays in macOS's system-root store.
Both provisioning profiles must admit that exact leaf and retain canonical
lowercase UUID filenames. A throwaway Mach-O must sign through the exact
identity hash and keychain, and its embedded three-certificate chain must match
the validated leaf and repository pins before archive work begins. Redacted
failure classification preserves the owning trust, interaction, identity, or
toolchain layer without logging certificate subjects.

The sole `if: always()` teardown restores the captured keychain preferences
and removes the temporary private key, certificate, profiles, diagnostic files,
and job keychain. The TestFlight receipt remains gated on successful teardown.
If the process is killed before teardown, the ephemeral VM is still discarded,
so no credential or filesystem state can reach a later job. The iOS development
runbook owns the exact hosted-image/toolchain rotation and manual-signing
contract.

## Validation

Deterministic tests cover:

- real authenticated WebSocket startup, session reconstruction, settings,
  worker activation, lifecycle events, client connectivity, direct provider
  tools, and the exact typed primitive surface;
- atomic publication, failed candidates, immutable hashes, overlap, rollback,
  retirement, purge, and reconstruction;
- command, agent, and resident-service runners;
- manual, schedule, engine-event, and authenticated webhook dispatch;
- restart recovery with explicit attempts, idempotency propagation, loop
  suppression, terminal-event cursor advancement, causal depth, concurrency
  queueing, timeout, stop/disable, failure disablement, system-inbox attachment,
  and all-vault secret rejection/redaction;
- lazy ordinary resident reuse, bounded eager cold-start readiness for
  native-client-action services, verified live-snapshot reuse, plus shutdown,
  stop-all, disable, process-exit, and repeated-health-failure supervision;
- a natural-language model loop that proactively upserts a complete worker,
  sees its direct typed tool immediately, invokes it, and reports the persistent
  adaptation; plus relevance selection, discovery promotion, complete tool
  schemas, and absence of local grant creation;
- the real loopback HTTP webhook route, including token success/failure,
  durable dispatch, and remote-peer rejection;
- remote authentication and client-only secret/emergency operation boundaries;
- canonical tree tamper detection, disposable runner workspaces, bounded
  concurrent process I/O, process-group termination of background descendants,
  bounded resident responses, and symlink-preserving dependency/runtime copies;
- iOS protocol, repository, view-model, settings, and build parity.
- persistent TypeScript lexical/top-level-await replay across restart, failed
  cell exclusion, exact broker replay/idempotency, ambient-authority absence,
  skill digest/root validation, cross-skill state isolation, and restricted
  transactional capability state.

The motivating replay lives at
`packages/agent/tests/fixtures/last30days_worker_gap.json`. Its deterministic
vertical slice authors one command worker with every trigger type, useful
  30-day research output, graceful operation without optional credentials, an immediately callable
typed tool, immutable bundle evidence, and successful fresh-runtime invocation.

The separate upstream proof is ignored by default:

```bash
TRON_WORKER_LIVE_NETWORK=1 \
  cargo test --manifest-path packages/agent/Cargo.toml \
  last30days_upstream_live_network_dependency_is_locked_and_activates -- --ignored
```

It resolves the upstream HEAD revision, omits the checksum from the candidate,
proves that `worker_upsert` cloned the exact revision and sealed its actual tree
digest into canonical state, smoke-tests the locked dependency, activates the
worker, and invokes it.

## Observation-Driven Re-hardening

The permissive POC is evaluated through the deterministic scenario suite,
opt-in live-network proof, actual sessions, and the production evidence they
already persist: worker versions, runs, inbox results, causal traces, health,
and audit history. The scenarios and proactive-adaptation proofs are required;
there is no minimum elapsed-time or multi-day waiting period. Tron does not
ship a second observation ledger that exists only to validate Tron. Future
guardrails must map to an observed failure or concrete threat, include a
regression scenario for it, and preserve accepted worker workflows.

## Source Owners

Source hierarchy is an ownership mechanism, not a placeholder mechanism.
Repository-owned configuration, automation, source, test, and
package-documentation trees contain no empty directories and no leaf directory
that exists only to wrap one file. The only narrow exceptions are layouts with
a concrete external or canonical contract: Codex environment and skill
packages, benchmark baselines, the canonical agent reference
directory, the iOS documentation asset directory, Apple color sets, the bundled
font directory, the required helper-app `Contents` directories containing each
tracked `Info.plist`, and their generated `MacOS` payload directories. The
guard admits the same helper layout before or after its ignored executable is
staged. The hierarchy guard walks these repository-owned trees so deleted
planes cannot leave empty shells and speculative single-file folders cannot
accumulate again.
It also requires every Rust source or test file to have an adjacent module
owner, preventing a deleted registration edge from leaving compilationally
invisible source behind. Generated build trees are deliberately outside this
source-ownership contract and may be recreated by their toolchains. A focused
size ratchet keeps each worker-kernel production file under 1,000 lines and
every Engine Dashboard Swift file under 600; growth beyond those ceilings requires another
real ownership split rather than a budget increase.

- Worker kernel: `packages/agent/src/domains/worker_kernel/`
- Worker runtime state owner and concern modules: `packages/agent/src/domains/worker_kernel/runtime/`
- Canonical worker store and concern modules: `packages/agent/src/domains/worker_kernel/persistence/store/`
- Provider-neutral tool selection: `packages/agent/src/domains/worker_kernel/surface/`
- Provider projection and compact guidance: `packages/agent/src/domains/agent/loop/surface/`
- Trusted-local execution: `packages/agent/src/domains/agent/loop/tool_executor/`
- Engine settings: `packages/agent/src/domains/settings/config/types/`
- Persistent code and agent-authored capability substrate: `packages/agent/src/domains/code_runtime/`
- Transport/auth: `packages/agent/src/transport/` and `packages/agent/src/app/bootstrap/server.rs`
- iOS engine/worker protocol: `packages/ios-app/Sources/Engine/Protocol/EngineProtocolTypes+Catalog.swift` and `packages/ios-app/Sources/Engine/Protocol/WorkerKernel/`
- iOS Engine Dashboard: `packages/ios-app/Sources/Session/WorkerKernel/` and `Sources/UI/WorkerConsole/`

Nearest `mod.rs` documentation and focused tests are the implementation-level
truth when this cross-cutting reference and source disagree.
