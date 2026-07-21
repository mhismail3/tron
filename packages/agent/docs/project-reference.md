# Tron Worker-First Technical Reference

> Last verified: 2026-07-20 on `codex/worker-first-autonomy-poc`.

This document describes the active worker-first implementation. Git history is
the record of the removed capability-governance and module-proposal system; it
is not an active compatibility contract.

## Product Model

Tron is a persistent local agent. A Rust service on the user's Mac owns model
turns, session/event truth, authenticated client transport, and engine-global
workers. The iOS app is a thin chat and worker-operations client. The Mac app
packages and supervises the service and owns pairing; it does not maintain a
parallel engine model.

The POC optimizes for one outcome: when a user or agent identifies reusable
behavior, Tron can turn it into working persistent behavior immediately. A
complete worker is created or improved through one `worker_upsert` operation.
There is no later install, binding, grant, promotion, or lifecycle actuator.

## Fixed Kernel

The source-owned kernel retains only:

- model/provider and agent-turn execution;
- local filesystem, process, and HTTP primitives;
- durable session state, events, named-secret injection, provenance, and audit;
- worker bundles, immutable versions, runners, dispatch, triggers, inbox, and
  management;
- authenticated `/engine` transport and loopback token-authenticated worker
  webhook ingress;
- isolated core-change proposal creation and explicitly approved application;
- product settings, auth, session compaction, logging, and blobs needed by
  current clients.

The authenticated `filesystem` product domain contains only the three iOS
workspace-picker operations (`get_home`, `list_dir`, and `create_dir`). Its old
parallel agent read/search/diff/write toolbox and resource-backed patch-preview
workflow were deleted; model filesystem work has one owner in the seven direct
worker-kernel host primitives.

Higher-level behavior belongs in a worker bundle. The fixed tree no longer
contains module proposal/validation/install/dependency/lifecycle/runtime
planes, capability binding and shadow routing, procedural candidates,
metadata-only schedules, the old worker lifecycle, fixed media/notification
delivery planes, fixed transcription, or the `capability::execute` wrapper.
Speech-to-text may return only as a worker authored and validated through real
use; it is not a fixed domain, settings policy, sidecar, or client feature.

The engine still uses generic words such as “capability invocation” in provider
tool-call events and client rendering. Those names describe the model protocol;
they do not imply the removed authorization or operation-catalog system.

The model-facing fixed surface currently has 27 direct primitives grouped as
seven host operations, sixteen worker-control operations, and four core-change
operations. A single typed manifest owns their provider names, groups, and
stable order; registration, provider projection, introspection, and exact-set
tests do not maintain parallel name lists. Every fixed primitive rejects
undeclared top-level input and output fields; closed response contracts keep
provider observations small and mechanically dependable.

Callable function definitions have no generic metadata map. A closed typed
model-tool contract owns the model name, autonomy exposure, fixed group/order,
and—only for direct workers—the worker id, immutable version, routing phrases,
update time, and compact provenance. Stream-topic declarations stay in the
setup-only domain registration record. This removes magic-key discovery and
prevents unproduced flags or test fixtures from changing production routing.
Calls emitted together by a provider execute concurrently. The dispatcher and
individual implementations own actual queueing and concurrency ceilings; the
agent loop has no metadata-driven serialized-wave mode.
The live function catalog is rebuilt at startup and is not itself a wire or
persistence format. Function definitions and setup-only policy types therefore
do not carry inert serialization contracts; durable idempotency and stream
records retain their explicit codecs.

### Primitive admission rule

A fixed model tool is admitted only when it passes one of two tests:

1. **Kernel custody:** only the compiled engine can own the canonical state or
   protected transition. Worker version activation, routing, stop/rollback,
   credential rotation, and approved live-tree application are in this class;
   implementing them as workers would require a worker to bootstrap or mutate
   the substrate that defines the worker itself.
2. **Material execution leverage:** a high-frequency operation is theoretically
   expressible through `process_run`, but a direct typed form materially
   improves model success and runtime reliability. The filesystem primitives
   add bounded reads/listing/search, exact stale-write detection, atomic
   publication, and closed evidence. `web_fetch` adds URL validation, response
   ceilings, and source provenance. They are ergonomic primitives, not new
   semantic product policy.

This admits the current 7/16/4 grouping without pretending the smallest
possible tool count is the objective. It rejects fixed web search providers,
transcription, memory policy, notifications, repository workflows, content
analysis, and other task semantics: those belong in workers. The deterministic
weighted worker ranker is the bootstrap fallback needed before any worker is
available; stronger embedding or model-based semantic routing is intentionally
a future worker developed through real sessions, not another mandatory kernel
service. No primitive is added merely because it is convenient, and no direct
tool is collapsed merely to make the manifest numerically smaller.

## Autonomy Modes

`autonomousWorkers` is an engine setting.

- It defaults to `false`. The agent remains conversational and
  explains that autonomous action can be enabled in Settings.
- With the setting enabled, accepted user sessions and workers are trusted
  local operators. Direct host and worker calls do not derive, mint, inspect,
  or consume per-call capability grants.
- Changes apply to the running engine without a server restart. Disabling
  hides the fixed worker primitives, unregisters direct worker tools, cancels
  active execution, and stops resident services while preserving canonical
  bundles and queued work. Re-enabling restores the primitives, rebuilds the
  enabled direct-tool surface from canonical state, and resumes dispatch unless
  engine stop-all is still engaged.
- The authenticated Engine Dashboard remains operational while autonomy is off:
  it may inspect state and history or use enable/disable, rollback,
  retire/purge, webhook rotation, and stop controls. Those operations do not
  expose tools or start dispatch until autonomy is enabled. Worker authoring,
  invocation, webhooks, process/network primitives, and core mutation stay
  blocked while the mode is off.
- Remote clients still require bearer-authenticated transport. Worker webhooks
  are loopback-only and require their own rotatable trigger token.

The setting is included in the complete `settings::get` response and has iOS
decode, state, load/reset/server-switch, mutation encoding, and Settings UI
ownership.

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
- logical named-secret bindings only;
- smoke-test and health-check commands plus source provenance.

Absent optional fields are omitted, so the human-inspectable manifest can be
passed back to `worker_upsert` directly for autonomous improvement.

`verification.json` seals redacted dependency-install, smoke-test, and health-
check evidence before the version hash is computed. A version must carry at
least one non-empty provenance source record.

The SQLite worker database is rebuildable for routes, bundle discovery, and
trigger configuration but durable for operational history. Startup reconstructs
the catalog from valid filesystem bundles, disables invalid entries, marks each
interrupted delivery attempt `interrupted`, resets its `running` invocation to
`queued`, and writes an index-rebuild report. Webhook hashes cannot be
reconstructed, so rebuilt webhook triggers remain disabled until token
rotation.

## Atomic `worker_upsert`

One request carries the complete candidate bundle, an optional predecessor, and
an optional local `sourceDirectory`. A staged source directory is recursively
imported as UTF-8 bundle files under reliability ceilings of 1,024 files and 16
MiB; explicit inline files win. Symlinks and special files are rejected. This
keeps activation atomic without requiring the model to read source back and
reproduce it as JSON. The runtime:

1. normalizes a plain direct tool name into the `worker_` namespace, then
   validates identity, schemas, runner configuration, relative paths, trigger
   definitions and deterministic schedule inputs, secret names, provenance,
   and any caller-supplied dependency checksums;
2. chooses the explicit predecessor or detects the closest semantic overlap by
   name/description terms, preferring an update over a duplicate;
3. stages outside the active worker directory;
4. fetches each exact dependency version to `dependencies/<name>`, verifies a
   supplied checksum or calculates an omitted one, and rewrites the staged
   manifest and dependency lock with the actual digest;
5. runs each optional install command inside that dependency's directory, then
   runs smoke tests and health checks from `files/` with the worker dependency
   environment, never the Tron installation environment;
6. writes redacted verification evidence and seals the staged tree with its
   content hash;
7. publishes the immutable version, updates `worker.json` and indexes,
   registers triggers, and installs the direct typed tool;
8. emits redacted lifecycle evidence and returns one-time webhook credentials
   only through the active operation result.

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
error instead of a false missing-result diagnosis. The child is aborted if its
parent invocation is dropped by timeout, disable, stop-all, or shutdown. Worker
causal depth survives the agent hop and is attached to every nested direct tool
call.

### Command runner

A command worker starts an executable with the version's `files/` directory as
its working directory. JSON input is written to stdin. JSON stdout becomes the
typed result; non-JSON stdout is wrapped as bounded text. Commands inherit the
Tron user's normal host permissions. There is no application filesystem or
process sandbox. A successful command may intentionally ignore its input; Tron
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
timeout, disable, stop-all, autonomy shutdown, and server shutdown kill the
whole group rather than leaving a background helper running.

### Resident-service runner

A service worker starts lazily on first invocation, may use an HTTP health
endpoint, and receives calls through its configured loopback invoke URL. The
runtime reuses a healthy process for later calls and supervises it between
invocations. An unexpected process exit disables the worker immediately; three
consecutive failed health probes do the same without treating a single
transient probe as terminal. The runtime also terminates a service when the
worker is disabled, retired, replaced, stop-all is engaged, autonomy is turned
off, or Tron shuts down. A resident runs from a service-lifetime disposable
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

Secret bindings resolve logical names from:

```text
~/.tron/workspace/vault/<binding-name>
```

Required bindings fail execution when absent; optional bindings permit graceful
fallback. Values are injected as normalized `TRON_SECRET_*` environment
variables. Upsert scans against every readable vault value, including undeclared
ones, and rejects a candidate containing one. Invocation input containing a
known vault value is rejected before it is persisted. Known values are redacted
from verification evidence, runner output, errors, inbox records, events, and
diagnostics. Raw values are never stored in manifests or worker SQLite.

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
numbered attempt whenever a dispatcher claims it. On restart, the unfinished
attempt becomes `interrupted` and its invocation returns to `queued` for a new
attempt. A `(workerId, idempotencyKey)` uniqueness constraint suppresses repeated
delivery. The idempotency key, invocation id, trace, depth, and trigger kind are
also passed to command runners as `TRON_WORKER_*` variables, to agent runners in
their durable prompt contract, and to resident services as `X-Tron-*` headers.
Every run records its pinned version, timestamps, input, output or error, and
inbox result.

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

Successful and failed results enter the durable inbox and emit
`worker.invocations`. Notable unseen background results are atomically attached
to the next relevant model turn once. High-visibility system failures such as
tool activation, trigger materialization, and resident supervision participate
in the same one-time attachment path even though they have no invocation row;
manual results remain explicitly inspectable.

## Failure and Recovery

A normal execution failure, timeout, invalid typed output, missing required
secret, or unhealthy resident disables the worker, unregisters its direct tool,
stops its resident process, and records a high-visibility inbox result. Tron
does not silently repair or roll it back.

Operator controls are:

- stop — cancel the worker's current invocations and resident process while
  preserving its enabled route, triggers, health, and ability to accept later
  work; the action is retained in worker audit and lifecycle streams;
- disable/enable — immediate route and trigger removal/restoration plus
  active-work stop (webhooks restore only when a token hash exists);
- rollback — activate a retained version and rotate any restored webhook token;
- retire — disable routes and triggers while preserving bundles and history;
- purge — as an irreversible critical operation, permanently remove a retired
  worker's bundle and operational rows while retaining the purge audit entry;
- stop-all — block new dispatch, cancel active work, and stop resident services;
  queued rows stay visible and resume only after explicit release.

## Model-Facing Tools

When autonomy is enabled, fixed kernel operations are direct typed tools. There
is no wrapper operation field. `worker_upsert` publishes the complete bundle
schema—including every runner, trigger, dependency lock, named-secret binding,
test, health check, provenance record, and routing field—to the model. Its tool
description includes command-runner I/O and automatic checksum locking, and
states the deterministic `files/` and `../dependencies/<name>` layout. The
optional `sourceDirectory` transport imports an already-authored local tree;
provider guidance tells the model not to read those files back just to echo them
through tool JSON and explicitly forbids searching the source tree or user home
for private authoring examples.

### Host primitives

| Model tool | Engine owner | Purpose |
|---|---|---|
| `filesystem_read` | `worker_kernel::filesystem_read` | Bounded UTF-8 read |
| `filesystem_list` | `worker_kernel::filesystem_list` | Deterministically ordered directory listing with result and traversal ceilings |
| `filesystem_search_text` | `worker_kernel::filesystem_search_text` | Recursive literal search with time, walk, result, hidden-tree, and heavy-directory controls |
| `filesystem_write` | `worker_kernel::filesystem_write` | Same-directory atomic full write with optional checksum/absence precondition |
| `filesystem_edit` | `worker_kernel::filesystem_edit` | Exact occurrence-checked UTF-8 replacements with optional checksum and atomic publication |
| `process_run` | `worker_kernel::process_run` | Local process with bounded output/timeout |
| `web_fetch` | `worker_kernel::web_fetch` | Explicit HTTP(S) fetch that stops reading at its content ceiling and returns provenance |

Filesystem reads, listings, searches, writes, and edits execute off the async
runtime thread. Reads never load the remainder of a truncated file; listing
never accumulates an unbounded directory; writes stage, sync, recheck the
observed prior state immediately before publication, rename within the target
directory, and sync that directory. `filesystem_edit` rejects stale or
ambiguous replacements before touching the target, so agents can edit a small
region without echoing an entire file through tool JSON.

### Worker operations

| Model tool | Engine function |
|---|---|
| `worker_upsert` | `worker_kernel::upsert` |
| `worker_discover` | `worker_kernel::discover` |
| `worker_list` | `worker_kernel::list` |
| `worker_inspect` | `worker_kernel::inspect` |
| `worker_invoke` | `worker_kernel::invoke` |
| `worker_await` | `worker_kernel::await` |
| `worker_stop` | `worker_kernel::stop` |
| `worker_disable` / `worker_enable` | `worker_kernel::disable` / `enable` |
| `worker_rollback` | `worker_kernel::rollback` |
| `worker_retire` / `worker_purge` | `worker_kernel::retire` / `purge` |
| `worker_inbox` / `worker_runs` | `worker_kernel::inbox` / `runs` |
| `worker_webhook_rotate` | `worker_kernel::webhook_rotate` |
| `worker_stop_all` | `worker_kernel::stop_all` |

`worker_invoke` defaults to `mode: wait`. `mode: enqueue` returns immediately
after durable admission and starts best-effort delivery; the ordinary durable
dispatcher remains restart recovery. `worker_await` observes one invocation
until terminal state or a bounded timeout, and a wait timeout never cancels the
work. These two operations let a model launch parallel or long work without
holding one provider call open for the worker's two-hour execution ceiling.

Every enabled worker is also registered as a stable direct typed tool using the
bundle's `toolName`, input schema, output schema, description, routing metadata,
provenance, version, and recent success evidence.

The provider-visible function description contains only version-stable purpose,
active version, and provenance. Success evidence lives in a durable, rebuildable
observation overlay. Completing a run updates that overlay rather than
re-registering the function, so ordinary success cannot increment the catalog
revision or stale an in-flight provider surface. Worker health remains in
canonical worker state and inbox history; failed workers are unregistered, so
the callable catalog has no duplicate synthetic health state.

At each provider request boundary, the worker-kernel-owned resolver captures the
catalog revision and ranks dynamic workers by explicit session promotion,
weighted name/description/intent/example/provenance relevance, recent
successes, recency, and identity. `worker_discover` uses the exact same scorer;
there is no second discovery policy. The deterministic local scorer is the
always-available fallback seam for a future semantic-router worker. The entire
dynamic provider surface selects at most 12 workers: recent explicit
promotions enter first, then relevant/default candidates fill remaining slots.
Promotion records are version-bound, recency-ordered, and retained to a bounded
50 per session, preventing stale worker-id revival and unbounded provider tool
growth. Each internal provider turn reranks against a bounded evolving intent
query made from the current user request plus visible assistant plan, direct
tool call, and text-result hints; it excludes binary content and hidden
thinking. The resolver records the
exact fixed functions, selected worker versions, selection reasons, and a stable
surface hash. The model receives a compact revision/count/projected-worker
primer in addition to native direct tool schemas. A `worker_discover` result
promotes matching workers into that session's next internal turn without a
restart; promotions are session-scoped durable engine state and survive server
restarts. A newly upserted worker registers immediately.

Workers and the callable catalog are profile-global. Workspace remains useful
invocation and event metadata, but it neither partitions worker availability nor
changes the provider tool surface. The current session affects only explicit
promotion and relevance ranking.

Each model-originated invocation carries the function revision and immutable
worker version that were advertised. Catalog preparation rejects any changed
contract with `ENGINE_STALE_FUNCTION_SURFACE`; it never sends old provider
arguments through a newer schema. Catalog revision and surface hash remain in
the provider-surface snapshot instead of being copied into an ephemeral
invocation metadata bag. The resulting recoverable tool error advances the
agent to a freshly resolved internal turn.

A direct tool cannot terminate the agent loop through catalog metadata or a
special result-envelope flag. Its typed result is committed to provider context
and the next provider turn sees the freshly resolved surface. Provider terminal
responses, configured limits, cancellation, and runtime failure are the only
owners of agent-run termination.

Authenticated clients may call `engine::surface_snapshot` with optional session
invocation context. The typed response returns the same provider-neutral surface
evidence plus four explicitly different inventories:

- eight server-owned compiled component roles, categorized as kernel, product
  infrastructure, or the protected core-change boundary;
- all 27 fixed tools with their exact schemas, revisions, effect/risk,
  primitive group, and whether autonomy currently exposes them;
- every published direct worker tool, including its promoted/projected state,
  selection reason, relevance evidence, and immutable worker version;
- canonical engine worker summaries, stop-all state, and autonomy state.

The selected `surface.tools` array is the exact next provider projection; the
fixed and available-worker inventories are operator evidence and must not be
mistaken for provider availability. When autonomy is off, the fixed inventory
remains inspectable with `exposed: false` while the provider surface contains no
fixed tools. The operation is deliberately not projected as model vocabulary.

## Local Authority and Provenance

When autonomous workers are enabled, local model calls enter directly with
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
`~/.tron/profiles/auth.json`. Home-directory recovery creates only required
directories; bearer-token startup atomically creates the auth document on first
use instead of seeding an inert `{}` file.

The settings schema admits only values with an independent production
consumer. Tests, serialization, dashboard display, or schema presence alone do
not justify a field. Authentication protocol URLs, redirect URIs, and scopes
remain owned by the auth implementation rather than appearing as duplicate
settings the runtime never reads.

Before bootstrap retires legacy named-profile files, it creates and verifies a
versioned whole-state snapshot using a stable inventory hash. Known legacy user
settings are projected into the current typed schema and written to the flat
file; removed or unknown fields are reported rather than fabricated. The
original profile documents remain recoverable from the snapshot and are then
deleted from the live home. Database retirement separately imports only
complete executable legacy bundles as inactive candidates, reports incomplete
proposals, and removes the old grant/resource/lease/compensation tables and
invocation columns in one transaction. Neither path retains a synthetic grant,
compatibility adapter, nullable permission observation, or permissive legacy
parser in steady-state execution. The same transaction removes legacy catalog
rows owned by the deleted generic trigger and catalog-worker registries.
Engine-ledger startup imports the last retained revision into one monotonic
scalar and drops the append-only history table; it does not keep an unconsumed
self-description plane. It also drops the former durable WebSocket
subscription table. Durable stream events remain, while current sockets keep
subscription identity and cursors in authenticated connection-local state and
explicit replay callers own their cursors.

There are no local operation claims, resource selectors, synthetic
grants, or agent-kind rejections. Executable workers can change local files and
make consequential external requests without fresh confirmation. This is the
intentional POC threat model.

Three unrelated runtime boundaries use three deliberately separate closed
types instead of the former generic visibility scope:

- function admission is either public to authenticated Agent, Worker, Client,
  and System callers, or internal to the engine-owned System actor;
- idempotency keys deduplicate within one session or across the running system;
- durable stream events are either a system broadcast or addressed to one
  session, while internal consumers may intentionally read all sessions.

Actor identity has only four production variants: Agent, Client, Worker, and
System. Session and workspace are causal observations rather than actor fields.
Unknown persisted stream scopes fail closed. This keeps admission, duplicate
suppression, and delivery from becoming another synthetic authorization model.
The generic function-definition provenance record was removed because no
runtime consumed it; executable worker bundles retain the source revisions and
checksums that actually support inspection, ranking, recovery, and audit.

Attaching unseen worker inbox results is an engine-owned session projection,
not an agent action. It runs under the internal runtime identity while retaining
the session and parent trace as provenance, so background-result delivery cannot
silently depend on an agent grant or fail internal visibility checks.

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

Provider credentials live in `~/.tron/profiles/auth.json`. Worker secrets live
under `~/.tron/workspace/vault/` and enter a worker only through declared
logical bindings. Bundle validation rejects likely secret material; runtime
injection uses environment variables, and redaction covers persisted inputs,
outputs, events, logs, and diagnostics. Redaction is field-aware for JSON and
also recognizes worker webhook credential shapes. Capability start, batch, and
completion broadcasts use the same redacted copies as durable rows. A one-time
credential remains raw only in the current caller/provider result needed to
hand it off; reconstruction receives the redacted result. The generic engine
invocation ledger independently reapplies the same boundary before writing
results or errors to either its in-memory idempotency cache or SQLite. A live
caller can therefore receive a one-time credential, while replay and audit
records cannot recover it.

## Core Source Proposals

Core changes use a separate boundary from workers. `core_proposal_create`:

1. canonicalizes the requested Git repository;
2. creates a dedicated `codex/core-proposal-*` branch and worktree under
   `~/.tron/workspace/core-proposals/`;
3. applies the supplied patch only in that worktree;
4. runs the supplied test command with a two-hour ceiling;
5. commits successful work and records branch, commit, worktree, and bounded
   test evidence.

Git and test processes use the same trusted-local executable search path as
workers, including conventional host tool locations hidden by LaunchAgents.
Patch text is preserved exactly through the operation boundary, including the
terminal newline required by standard unified diffs.

Failure removes the temporary worktree/branch and does not retain a proposal.
Creation never modifies the running tree or binary.

`core_proposal_apply` accepts a proposal id plus session and message ids. It
loads that later persisted event and requires a user-authored message created
after the proposal that explicitly names and affirmatively approves/applies it.
Messages containing negation or rejection language do not count as approval.
Only then is the proposal commit cherry-picked into the named repository. A
conflicting cherry-pick is aborted and the original live-tree commit is
verified before the proposal remains `tested`. The approval message is recorded
directly; no capability grant is minted.

## State Snapshot and Legacy Import

Before the engine first opens the worker schema, Tron creates a verified snapshot
under `~/.tron/internal/snapshots/`. The manifest records format/schema,
source home/label, creation time, every relative path, byte count, SHA-256,
and restoration instructions. It captures root settings, protected credentials,
prior worker files, and a
consistent `VACUUM INTO` copy of the primary SQLite database. Symlink targets
are checksum-covered snapshot entries and are restored as symlinks rather than
silently omitted. Legacy settings retirement runs before current settings load;
database-table retirement runs before current engine/session schemas open.
Both use this snapshot boundary, and unique snapshot directory ids prevent two
valid retirement checkpoints in the same second from colliding.

Offline commands:

```bash
scripts/tron state snapshots
scripts/tron state restore /absolute/path/to/snapshot
```

Restore verifies every checksum, requires the primary database lock (Tron must
be stopped), moves current state into a timestamped recovery directory, restores
the snapshot, and removes the disposable worker index so it rebuilds.

The explicit legacy importer reads the pre-migration SQLite database without
mutating it. Complete executable bundles become inactive candidates. Metadata-
only proposals—including the recorded `last30days` proposal—are reported as
unconvertible rather than fabricated into executable behavior. Import and
rebuild reports are written beside canonical worker state.

## Storage

The primary `tron.sqlite` remains the source for sessions, messages, provider
audits, streams, scoped engine state, and approval-message evidence. Worker
bundles remain filesystem-canonical; the worker database owns their derived
indexes and durable operational history.

### Tables

| Table | Ownership |
|---|---|
| `blobs` | content-addressed durable payloads |
| `engine_catalog_changes` | typed-function surface revisions |
| `engine_idempotency_entries` | engine invocation idempotency ledger |
| `engine_invocations` | generic engine invocation history |
| `engine_state_entries` | engine-owned state values |
| `engine_stream_events` | durable engine stream records |
| `events` | session event log |
| `logs` | structured session logs |
| `schema_version` | primary schema version |
| `sessions` | session metadata |
| `storage_checkpoints` | storage maintenance checkpoints |
| `storage_exports` | storage export evidence |
| `storage_metadata` | storage subsystem metadata |
| `storage_payload_refs` | payload ownership references |
| `storage_retention_runs` | retention-run evidence |
| `workspaces` | workspace metadata |

### Worker database

The worker database is `~/.tron/internal/database/workers.sqlite`. Bundle,
version, route, and trigger indexes rebuild from canonical worker files;
invocation, attempt, trace, inbox, health, audit, and stop-all rows are durable
operational evidence:

| Table | Ownership |
|---|---|
| `worker_schema` | worker index schema version |
| `workers` | rebuildable current catalog |
| `worker_versions` | rebuildable version index |
| `worker_routes` | rebuildable direct-tool route and routing metadata |
| `worker_triggers` | rebuildable trigger configuration and cursors |
| `worker_invocations` | durable queue, idempotency, pinned version, and results |
| `worker_attempts` | numbered execution/redelivery attempts |
| `worker_causal_traces` | trace roots, depth, delivery, and suppression counters |
| `worker_trace_deliveries` | unique worker/trigger/idempotency combinations per trace |
| `worker_inbox` | durable visible results/failures and seen state |
| `worker_audit` | lifecycle and mutation evidence |
| `worker_health` | versioned activation/lifecycle/execution health history |
| `worker_runtime_settings` | durable engine stop-all state |

The fixed kernel has no device-token registration, notification inbox, or APNs
delivery plane. A future notification workflow must be authored and exercised
as a worker rather than restored as a fixed domain.

## Events and Transport

`GET /engine` remains the authenticated WebSocket upgrade endpoint for clients.
Its one request operation invokes a canonical function id directly and returns
that function's value directly in the top-level result; there is no registered
`engine::invoke` delegation or child-result wrapper in the transport contract.
The wire admits client scope and optional idempotency metadata but rejects
injected internal authority/runtime fields. Bearer rotation continues to force
client re-pairing.

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
- `worker.invocations` — started/completed/failed invocation summaries.

The durable session log has **13 event variants**. Live-only deltas, progress,
context notices, and errors remain transport events and are not duplicated as
unwritten storage contracts:

| Concern | Event types |
|---|---|
| session | `session.start`, `session.end`, `session.fork` |
| messages | `message.user`, `message.assistant`, `message.deleted` |
| model | `model.provider_request` |
| provider tools | `capability.invocation.started`, `capability.invocation.completed` |
| turns | `stream.turn_start`, `stream.turn_end`, `turn.failed` |
| context | `compact.boundary` |

The historical `capability.invocation.*` names describe generic provider
tool-call conversation evidence; they do not restore the removed authorization
plane. Removed governance-domain stream topics and schemas are not retained
through adapters.

## iOS Client

**Minimum iOS:** 26.0. The generated project and documented toolchain workflow
support Xcode 26 and Xcode 27 without source forks for their runtime SDKs.

The iOS Engine Dashboard is backed by `WorkerKernelClient`,
`WorkerKernelRepository`, `WorkerConsoleViewModel`, and `UI/WorkerConsole`.
It exposes:

- an Overview of compiled component roles and the selected session's exact
  provider surface;
- a Core inventory of all fixed host, worker-control, and core-change tools,
  including schemas and current exposure;
- published workers with distinct Published, This session, and Promoted state;
- worker list, health, runner, active content version, provenance, and triggers;
- JSON-schema-aware typed invocation;
- engine-wide Activity plus per-worker runs, durable inbox, and audit history;
- stop current work without disabling future dispatch, enable/disable, rollback,
  retained-version restoration after retirement, purge, webhook rotation, and
  stop-all;
- live refresh from `worker.lifecycle` and `worker.invocations` cursors, owned by
  the persistent sidebar task so state remains current while the sheet is closed.

Conversational creation remains the authoring interface; the client does not
contain a bundle editor. The Mac package is a server supervisor/pairing shell,
so iOS is the only current operational engine client requiring the console.

Compaction is a direct durable session boundary. Context clearing is a live
transport event; the resulting context size is reflected by later session/token
truth rather than an unwritten `context.cleared` storage row. The client renders
both without a parallel context-control resource client or Session Briefing
sheet.

Settings exposes the Logs sheet in every iOS build configuration from its toolbar.
While connected, Tron automatically ingests deduplicated client logs into the
server log store. Successful ingest plumbing is filtered to prevent
self-feeding diagnostics loops.

For fast production-identity testing, the `Tron Fast` scheme uses the
`ProdDebug` configuration. Codex device actions include Rebuild + Install + Launch
and Just Launch Installed variants, target a deduplicated production app, and
the rebuild action installs the requested configuration's `iphoneos` artifact.

## Validation

Deterministic tests cover:

- real authenticated WebSocket startup, session reconstruction, settings,
  worker activation, lifecycle events, client connectivity, direct provider
  tools, and continued absence of `capability::execute`;
- atomic publication, failed candidates, immutable hashes, overlap, rollback,
  retirement, purge, and reconstruction;
- command, agent, and resident-service runners;
- manual, schedule, engine-event, and authenticated webhook dispatch;
- restart recovery with explicit attempts, idempotency propagation, loop
  suppression, terminal-event cursor advancement, causal depth, concurrency
  queueing, timeout, stop/disable, failure disablement, system-inbox attachment,
  and all-vault secret rejection/redaction;
- live autonomy enable/disable/re-enable without restart, including dynamic-tool
  race closure and authenticated console management while execution is off;
- lazy resident reuse plus shutdown, stop-all, disable, process-exit, and
  repeated-health-failure supervision;
- a natural-language model loop that proactively upserts a complete worker,
  sees its direct typed tool immediately, invokes it, and reports the persistent
  adaptation; plus relevance selection, discovery promotion, complete tool
  schemas, and absence of local grant creation;
- the real loopback HTTP webhook route, including token success/failure,
  durable dispatch, and remote-peer rejection;
- remote auth, snapshot/restore, legacy import reporting, and isolated core
  proposal approval, including negation rejection and cherry-pick cleanup;
- canonical tree tamper detection, disposable runner workspaces, bounded
  concurrent process I/O, process-group termination of background descendants,
  bounded resident responses, and symlink-preserving dependency/runtime copies;
- iOS protocol, repository, view-model, settings, and build parity.

The motivating replay lives at
`packages/agent/tests/fixtures/last30days_worker_gap.json`. Its deterministic
vertical slice authors one command worker with every trigger type, useful
30-day research output, optional-credential fallback, an immediately callable
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

The permissive POC is evaluated through actual sessions and the production
evidence they already persist: worker versions, runs, inbox results, causal
traces, health, and audit history. Tron does not ship a second observation
ledger or an arbitrary time/scenario gate that exists only to validate Tron.
Future guardrails must map to an observed failure or concrete threat, include a
regression scenario for it, and preserve accepted worker workflows.

## Source Owners

Source hierarchy is an ownership mechanism, not a placeholder mechanism.
Repository-owned configuration, automation, source, test, and
package-documentation trees contain no empty directories and no leaf directory
that exists only to wrap one file. The only narrow exceptions are layouts with
a concrete external or canonical contract: Codex environment and skill
packages, benchmark baselines, the canonical agent reference
directory, the iOS documentation asset directory, Apple color sets, the bundled
font directory, and generated helper-app `MacOS` payload directories. The
hierarchy guard walks these repository-owned trees so deleted planes cannot
leave empty shells and speculative single-file folders cannot accumulate again.
It also requires every Rust source or test file to have an adjacent module
owner, preventing a deleted registration edge from leaving compilationally
invisible source behind. Generated build trees are deliberately outside this
source-ownership contract and may be recreated by their toolchains. A focused
size ratchet keeps each worker-kernel production file under 1,000 lines, allows
the cohesive versioned migration boundary up to 1,100, and keeps every Engine
Dashboard Swift file under 600; growth beyond those ceilings requires another
real ownership split rather than a budget increase.

- Worker kernel: `packages/agent/src/domains/worker_kernel/`
- Worker runtime state owner and concern modules: `packages/agent/src/domains/worker_kernel/runtime/`
- Canonical worker store and concern modules: `packages/agent/src/domains/worker_kernel/persistence/store/`
- Provider-neutral tool selection: `packages/agent/src/domains/worker_kernel/surface.rs`
- Provider schema adaptation: `packages/agent/src/domains/agent/loop/primitive_surface.rs`
- Trusted-local execution: `packages/agent/src/domains/agent/loop/capability_invocation_executor/`
- Engine settings: `packages/agent/src/domains/settings/config/types/`
- Transport/auth: `packages/agent/src/transport/` and `packages/agent/src/app/bootstrap/server.rs`
- iOS engine/worker protocol: `packages/ios-app/Sources/Engine/Protocol/EngineProtocolTypes+Catalog.swift` and `EngineProtocolTypes+WorkerKernel.swift`
- iOS Engine Dashboard: `packages/ios-app/Sources/Session/WorkerKernel/` and `Sources/UI/WorkerConsole/`

Nearest `mod.rs` documentation and focused tests are the implementation-level
truth when this cross-cutting reference and source disagree.
