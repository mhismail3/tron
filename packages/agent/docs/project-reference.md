# Tron Worker-First Technical Reference

> Last verified: 2026-07-21 on the worker-first POC branch.

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
- isolated core-change proposal creation and explicitly approved application;
- product settings, auth, session-compaction custody, logging, and blobs needed
  by current clients.

The authenticated `filesystem` product domain contains only the three iOS
workspace-picker operations (`get_home`, `list_dir`, and `create_dir`). Model
filesystem work has one owner in the seven direct worker-kernel
filesystem/process/network primitives. Session title mutation is the eighth
host primitive and owns durable session metadata rather than host I/O.

Higher-level behavior belongs in worker bundles. The fixed tree owns the model
loop, authenticated product transport, durable custody, direct host actuators,
worker execution, and isolated core-change approval. New product behaviors,
including speech-to-text, are authored and validated as workers through real
use.

Provider tool calls have a durable `tool.invocation.*` lifecycle. A started row
records the invocation id, tool name, and redacted arguments; output and
completion rows record bounded output, terminal status, error, and duration.
That lifecycle powers live running state, post-restart reconstruction,
interrupted-turn recovery, session summaries, and operator diagnostics. It is
execution evidence for an actual model tool call. It neither grants authority
nor participates in worker discovery, activation, or permission decisions.

The model-facing fixed surface currently has 29 direct primitives grouped as
eight host operations, seventeen worker-control operations, and four core-change
operations. A single typed manifest owns their canonical function IDs, provider
names, groups, and stable order; registration, provider projection,
introspection, and exact-set tests do not reconstruct partial identities. Every fixed primitive rejects
undeclared top-level input and output fields; closed response contracts keep
provider observations small and mechanically dependable.

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
   ceilings, retained-content checksums, and source provenance. Its default is
   intentionally context-safe rather than the maximum supported response.
   `session_set_title` is the narrow durable session-metadata actuator needed
   for workers to replace hardcoded title policy; it derives the current target
   from causal context unless an explicit session is named. These are ergonomic
   or state-custody primitives, not new semantic product policy.

This admits the current 8/16/4 grouping without pretending the smallest
possible tool count is the objective. It rejects fixed web search providers,
transcription, memory policy, notifications, repository workflows, content
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

The `context_summary` hook accepts a bounded transcript
of visible user text, assistant text, tool names, and textual tool results and
returns `{narrative}`. Hidden thinking, tool arguments, binary content, usage,
and cost never cross the seam. Calls use the normal durable worker dispatcher,
causal trace, idempotency, validation, failure-disable, and inbox behavior. If
no hook is installed—or the hook fails—compaction uses a deterministic recovery
summary. A hook worker is excluded while its own agent-runner session compacts,
preventing semantic-policy recursion. Token-window selection, cancellation,
checkpoint restoration, durable compact-boundary proof, and provider context
mutation remain irreducible kernel custody.

The `worker_relevance` hook accepts the evolving task query plus a bounded set
of canonical candidate summaries and returns typed worker ids and scores.
Automatic provider projection and explicit `worker_discover` call this same
hook; there is no parallel semantic-discovery policy. The engine validates that
rankings contain only unique candidates, preserves version-bound explicit
promotion precedence, and disables an owner that returns invalid semantic
output. If no healthy owner exists, or its own agent-runner turn is resolving a
tool surface, the exact local weighted scorer provides deterministic recovery.

The `inbox_context` hook receives the current task query and a bounded,
redacted, newest-first set of unseen worker-result previews. It returns the
observation ids to consume and the transient narrative to place in the next
provider turn. The kernel validates that every id is unique and came from the
supplied candidate set, atomically claims the complete selection so concurrent
sessions cannot split it, and injects only a bounded narrative. The policy may
consume irrelevant observations without narrating them. Without a healthy
owner—or while the owner resolves its own agent-runner turn—the exact
error/relevance selector and JSON projection provide deterministic recovery.
Candidate reads never mark observations seen, invalid selections disable the
hook owner, and a lost concurrent claim injects no stale narrative.

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
- immutable presentation identity, contract version, and optional suite role.

Absent optional fields are omitted, so the human-inspectable manifest can be
passed back to `worker_upsert` directly for proactive improvement.

`verification.json` seals redacted dependency-install, smoke-test, and health-
check evidence before the version hash is computed. A version must carry at
least one non-empty provenance source record.

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
reproduce it as JSON. The runtime:

1. normalizes a plain direct tool name into the `worker_` namespace, then
   validates identity, schemas, runner configuration, relative paths, trigger
   definitions and deterministic schedule inputs, engine-hook input/output
   compatibility, secret names, provenance, and any caller-supplied dependency
   checksums;
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

Before a newer worker database schema first opens an existing profile, Tron
creates and verifies one owner-only, checksummed `tar.zst` snapshot under
`~/.tron/internal/backups/`. Snapshots contain settings, authentication state,
vault files, canonical worker bundles/state, and compact consistent copies of
the session and worker databases. Runtime caches, logs, journals, WAL/SHM
files, and disposable process trees are excluded. The manifest records source
home, schema versions, checksums, and restoration instructions. Operators can
use `tron state snapshot`, `tron state snapshots`, `tron state verify <path>`,
and—only while the server is stopped—`tron state restore <path>`. Restore first
moves replaced state into a dated recovery directory and rolls back if
publication fails.

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
numbered attempt whenever a dispatcher claims it. On restart, the unfinished
attempt becomes `interrupted` and its invocation returns to `queued` for a new
attempt. Recovery clears an interrupted agent attempt's stale current-child
link before requeueing, allowing the new attempt to attach its own child session
while the interrupted attempt remains visible. A `(workerId, idempotencyKey)`
uniqueness constraint suppresses repeated delivery. The idempotency key,
invocation id, trace, depth, and trigger kind are
also passed to command runners as `TRON_WORKER_*` variables, to agent runners in
their durable prompt contract, and to resident services as `X-Tron-*` headers.
Every run records its pinned version, timestamps, input, output or error, and
inbox result.

An agent runner's durable child prompt includes the invocation input and the
immutable worker output schema verbatim. The child is told that the kernel will
reject nonconforming terminal output, and the ordinary post-run validator still
enforces that boundary. Typed agent execution therefore does not depend on a
worker author redundantly paraphrasing a hidden schema inside its instructions.

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

`worker_runs` and `worker_inbox` return compact observations by default: pages
contain at most 20 records, with inputs, outputs, and results represented by
512-byte JSON previews and no expanded attempt or trace maps. Runs filter directly by status;
inbox reads filter directly by seen state and severity, so routine health checks
do not move irrelevant history into model context. `detail: "full"` is an
explicit operator path capped at 20 records and 8 KiB per retained value; the
response reports content truncation and a `nextOffset` when older records remain.
The Engine Activity UI follows those bounded pages on demand, so the complete
run/inbox ledger remains inspectable without one unbounded transport response.
Durable state remains complete in canonical storage—these are bounded read
projections, not retention limits.

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

## Model-Facing Tools

Fixed kernel operations are direct typed tools. There
is no wrapper operation field. `worker_upsert` publishes the complete bundle
schema—including every runner, trigger, dependency lock, named-secret binding,
test, health check, provenance record, and routing field—to the model. Its tool
description owns command-runner I/O, automatic checksum locking, and the
deterministic `files/` and `../dependencies/<name>` layout. The optional
`sourceDirectory` transport imports an already-authored local tree without
requiring its contents to be copied through tool JSON.

Prompt ownership follows the same boundary. The static agent seed is a short
statement of behavioral intent. Provider request guidance contributes only the
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
| `filesystem_read` | `worker_kernel::filesystem_read` | Bounded UTF-8 read |
| `filesystem_list` | `worker_kernel::filesystem_list` | Deterministically ordered directory listing with result and traversal ceilings |
| `filesystem_search_text` | `worker_kernel::filesystem_search_text` | Recursive literal search with time, walk, result, hidden-tree, and heavy-directory controls |
| `filesystem_write` | `worker_kernel::filesystem_write` | Same-directory atomic full write with optional checksum/absence precondition |
| `filesystem_edit` | `worker_kernel::filesystem_edit` | Exact occurrence-checked UTF-8 replacements with optional checksum and atomic publication |
| `process_run` | `worker_kernel::process_run` | Local process with bounded output/timeout |
| `web_fetch` | `worker_kernel::web_fetch` | Explicit raw UTF-8 HTTP(S) fetch with a 128 KiB/30-second default, explicit larger ceilings, redirect/status metadata, truncation evidence, and retained-content SHA-256 |
| `session_set_title` | `worker_kernel::session_set_title` | Durable title update for the current causal session; the model supplies only the title |

Filesystem reads, listings, searches, writes, and edits execute off the async
runtime thread. Reads never load the remainder of a truncated file; listing
never accumulates an unbounded directory; writes stage, sync, recheck the
observed prior state immediately before publication, rename within the target
directory, and sync that directory. `filesystem_edit` rejects stale or
ambiguous replacements before touching the target, so agents can edit a small
region without echoing an entire file through tool JSON. Mutation contracts
reject empty checksum strings before execution: callers omit the optional
field for an unconditional write, use the exact `absent` sentinel only when a
new file is required, or provide raw/`sha256:`-prefixed 64-digit hex.

### Worker operations

| Model tool | Engine function |
|---|---|
| `worker_upsert` | `worker_kernel::upsert` |
| `worker_discover` | `worker_kernel::discover` |
| `worker_list` | `worker_kernel::list` |
| `worker_inspect` | `worker_kernel::inspect` |
| `worker_invoke` | `worker_kernel::invoke` |
| `worker_await` | `worker_kernel::await` |
| `worker_cancel` | `worker_kernel::cancel` |
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
`worker_cancel` targets one durable invocation id. It is intentionally distinct
from per-worker `worker_stop` and profile-wide `worker_stop_all`.

`worker_inspect` defaults to `detail=contract`: the active input/output schemas,
runner contract, routing, provenance, presentation, bindings, triggers, route,
and immutable version summaries. It omits source-file payloads, smoke/health
commands, audit, and health history so ordinary discovery does not consume
model context with operator evidence. `detail=full` returns the complete
immutable bundle metadata and bounded operational history; operator clients
request that mode explicitly.

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
catalog revision and ranks dynamic workers by explicit session promotion, the
active `worker_relevance` hook, recent successes, recency, and identity.
`worker_discover` uses the same hook and local recovery scorer; there is no
second discovery policy. The entire
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
restarts. Recent worker success evidence uses the other supported state extent,
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
special result-envelope flag. Its typed result is committed to provider context
and the next provider turn sees the freshly resolved surface. Provider terminal
responses, configured limits, cancellation, and runtime failure are the only
owners of agent-run termination.

Authenticated clients may call `engine::surface_snapshot` with optional session
invocation context. The typed response returns the same provider-neutral surface
evidence plus three operational inventories:

- all 29 fixed tools with their exact schemas, revisions, effect/risk,
  primitive group, and model exposure;
- every published direct worker tool, including its promoted/projected state,
  selection reason, relevance evidence, and immutable worker version;
- canonical engine worker summaries and stop-all state.

The selected `surface.tools` array is the exact next provider projection; the
fixed and available-worker inventories are operator evidence and must not be
mistaken for provider availability. The operation is deliberately not projected
as model vocabulary.

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

Automatic worker projection and `worker_discover` share the active
`worker_relevance` worker. Its input contains the evolving task query and
bounded canonical candidate metadata; its output is a typed ranking. The engine
retains one exact weighted-term and adjacent-phrase scorer as recovery when no
hook is active, the hook fails, or the hook's own agent-runner turn resolves its
surface. Session promotions remain version-bound and outrank both paths, so
routing never depends exclusively on another worker being healthy.

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

Attaching unseen worker inbox results is an engine-owned session projection,
not an agent action. It runs under the internal runtime identity while retaining
the session and parent trace as provenance.

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

Failure removes the temporary worktree, branch, and proposal directory and does
not retain an inert proposal shell. Creation never modifies the running tree or
binary.

`core_proposal_apply` accepts a proposal id plus session and message ids. It
loads that later persisted event and requires a user-authored message created
after the proposal that explicitly names and affirmatively approves/applies it.
Messages containing negation or rejection language do not count as approval.
Only then is the proposal commit cherry-picked into the named repository. A
conflicting cherry-pick is aborted and the original live-tree commit is
verified before the proposal remains `tested`. The approval message is recorded
directly with the proposal evidence.

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
| **Continuity Curator** | Useful continuity across turns and sessions: titles, grouping, labels, archival policy, facts, decisions, personal policies, semantic retrieval/editing/tombstones, context summaries, survivor/exclusion decisions, inspection, and explicit clear behavior. |
| **Delegation Coordinator** | Bounded specialist-agent work: launch, status, inspection, results, invocation cancellation, reusable roles, later fan-out/synthesis, and child-session traceability. |
| **Research Suite** | Source-backed freshness-aware answers: search, crawling, fetch/archive, freshness, source review, citation extraction, recent research, evidence comparison, contradictions, and synthesis. |
| **Knowledge Index** | Retrievable durable source material: document/web/repository ingestion, semantic retrieval, provenance, lineage, previews, history, update detection, export/import, and corpus maintenance. Personal memory remains Continuity custody. |
| **Software Workspace** | Safe repository work: structure/history, Git status/diff/branches/staging/commits, test selection, patch/review preparation, change analysis, and cleanup. Live-core application remains fixed custody. |
| **Automation Orchestrator** | Work caused by time or events: reminders, schedules, engine events, follow-ups, background jobs, multistep programs, retries, notifications, and workflow state over the executable dispatcher. |
| **Procedure Library and Worker Forge** | Reusable prompts, templates, procedures, skills, roles, hook patterns, external tool/API/repository scouting, worker creation/improvement, consolidation, and retirement recommendations. |
| **Worker Evaluator** | Evidence of usefulness and reliability: run inspection, traces/logs/replay, failure clustering, regression fixtures, conformance, comparison, benchmarks, routing evidence, and improvement recommendations. |
| **Connector Fabric** | Typed external-system adaptation: MCP/A2A/API adapters plus separately versioned email, calendar, issue/source-hosting, messaging, database, home, and business connectors where credentials/dependencies/failure domains differ. |
| **Artifact Studio** | Focused text, data, document, PDF, spreadsheet, presentation, image, audio, video, transcription, language, diarization, transformation, analysis, and archival specialists. |
| **Interactive Operator** | Stateful observe-act-verify loops for browser control, computer operation, screenshots, and device inspection. |
| **Engine Steward** | Provider/model monitoring, diagnostics, core patch authoring, test selection, and isolated proposal evidence without application custody. |

Every restored behavior has one primary family owner. A family splits only
when contracts, dependencies/credentials, failure isolation, semantic tool
selection, or independent usefulness materially differ. Individual CRUD verbs,
internal text helpers, authorization-only tools, and record-only metadata do
not qualify as workers. Completion means a real worker performs a useful
outcome through a concise typed contract and survives independent testing,
versioning, disabling, inspection, and improvement.

Restoration order is deliberate:

1. close concrete kernel gaps and refresh providers/models;
2. collaboratively author and field-prove Work Ledger, the four-worker
   Research suite, and General Delegate one worker at a time;
3. after explicit user confidence, generalize the presentation contract from
   those three real experiences;
4. build Evaluator, Procedure Library, Worker Forge, and Provider Steward;
5. restore Continuity/Knowledge, Software, Automation, Artifacts/Interactive,
   Connectors, then Engine Steward;
6. consolidate overlaps, remove unused adapters/helpers/fixtures, and confirm
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

### Guided Work Ledger proof

The first restoration capability was authored by Tron from a natural-language
request in an ordinary `gpt-5.5` session; it is profile state, not a
repository-managed built-in. Tron researched the live worker contracts, wrote
and smoke-tested a command-runner bundle, activated it with `worker_upsert`, and
used the newly projected `worker_work_ledger` direct tool in the same session.
The current profile retains three immutable versions; each update named the
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

iOS recognizes only immutable `work-ledger` presentation contract version 1 as
the native Work Ledger experience. It uses the worker contract rather than
reading worker storage, offers summaries, filters, creation/editing and record
lifecycle, linked detail, empty/error/offline states, and recent activity, and
keeps the generic technical console one tap away. Unknown contract versions
fall back to the generic console. Work Ledger is therefore ready for ordinary
field use; the next guided capability is the Research suite, not an additional
kernel abstraction.

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
only a manual trigger. Active immutable version
`9370477ad5af01f50713104b4e6b3a10ed14d03ab487972bb44d2e7ad1870496`
calls Search first, merges explicit seeds with discovered candidates, calls
Source Review only when candidates exist, submits reviewed claims to Citation,
and persists one strict `research.report.v1` through its worker-owned state
helper.

The useful final seeded proof used the official Brave and Exa search API
references. Search returned the current profile's typed `unavailable` result
because neither optional provider credential is configured, while the explicit
seeds still flowed through Source Review and Citation. The completed run retained
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
version recovery, restart persistence, and generic-console access. Its current
limitation is explicit: without Brave or Exa credentials, discovery cannot
produce live search results, so the accepted cited run used caller-supplied
official seeds. Semantic synthesis also remains model-fallible within the
Citation worker's deterministic provenance and relation guard.

iOS now recognizes only the primary immutable `research-suite` presentation
contract version 1 as the grouped native Research experience. It reads the
canonical suite inventory plus bounded full-detail run and inbox contracts; it
does not inspect worker-owned files. Exact `research.report.v1` coordinator
outputs provide report history, answer export, claims, claim-linked citations,
source and freshness metadata, contradictions, evidence gaps, limitations, and
specialist outcomes. The same surface shows aggregate health, component
versions, query/run history, and failures, and every component retains a path
to its separately loaded generic technical console. Secondary components,
unknown versions, and malformed or absent presentation metadata fall back to
the generic console. Malformed canonical report output is surfaced as partial
refresh evidence rather than silently rendered or adopted as client truth.
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
inventory of `/Users/moose/Workspace/testspace`. Durable invocation
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
`d10c5970c2a1d319ac01fd8dfc8a28f03ac1753e80671a57ff30d15f0b7d8c69`
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

### Prior inventory coverage evidence

The following detail is retained only to cross-check the family map above.
Worker authors must recombine it by functional closure rather than reconstruct
these bullets as one tool apiece.

#### User workflows

- **Session organization:** derive useful session titles and any later grouping,
  labeling, or archival policy from real conversation context. The kernel
  retains only the narrow durable `session_set_title` actuator.
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
  custody; semantic summarization is already available through the
  `context_summary` worker hook.
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
- **Schedules and reminders:** create, list, inspect, update, cancel, and fire
  meaningful scheduled work. Schedule triggers are already executable kernel
  substrate; reminder semantics, calendar reasoning, notification policy, and
  recurrence UX belong in workers.
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
  detection, diarization, and audio preprocessing. If mobile audio cannot be
  reached through existing authenticated transport, add one narrow typed media
  actuator and keep transcription policy in workers.
- **Devices and notifications:** device list/inspect, send, list, inspect, mark
  read, and mark all read. Delivery scheduling and message policy belong in
  workers. A concrete mobile-delivery use case may justify a narrow
  authenticated client actuator; it does not justify restoring a general
  device domain.
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
- **Core maintenance:** investigate a source change, author a patch, choose and
  run tests, and prepare a core proposal. The fixed proposal operations retain
  isolated worktree custody and approval enforcement; diagnosis and patch
  authoring can be workers.

### Kernel substrate already replacing separate behavior

- Filesystem read/list/search/write/edit, process execution, bounded HTTP fetch,
  and durable session-title mutation are direct host tools.
- Command, agent, and resident-service execution; dependency locking; named
  secrets; manual, schedule, event, and webhook triggers; queueing; retries;
  timeouts; causal traces; inbox; health; disable; rollback; retirement; purge;
  stop; and stop-all are worker-kernel custody.
- Worker discovery, semantic relevance hooks, live provider projection,
  version-bound promotion, dynamic surface revisions, and stale-contract
  rejection provide same-session adaptation without a separate catalog plane.
- Durable sessions, provider/model turns, `tool.invocation.*` evidence,
  compaction mechanics, authenticated transport, settings, credentials, blobs,
  and source-proposal approval remain fixed because they custody the runtime
  that workers depend on.

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
notification delivery, procedural activation, scheduling, and web research did
not themselves perform the useful external action. Their record shells are not
missing functionality. Only the executable behaviors listed above should be
restored, one proven worker at a time.

## Storage

The primary `tron.sqlite` remains the source for sessions, messages, provider
audits, streams, scoped engine state, and approval-message evidence. Worker
bundles remain filesystem-canonical; the worker database owns their derived
indexes and durable operational history.

### Tables

| Table | Ownership |
|---|---|
| `blobs` | content-addressed durable payloads |
| `engine_catalog_revision` | current typed-function surface revision |
| `engine_idempotency_entries` | engine invocation idempotency ledger |
| `engine_invocations` | generic engine invocation history |
| `engine_state_entries` | engine-owned state values |
| `engine_stream_events` | durable engine stream records |
| `events` | session event log |
| `logs` | structured session logs |
| `sessions` | session metadata |
| `storage_payload_refs` | payload ownership references |
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

Closed `session::*` payload schemas admit only values their owning operation
consumes. Session and workspace provenance belongs to the authenticated
transport context; it is not duplicated as ignored `sessionId`/`workspaceId`
payload ceremony. In particular, session creation accepts only working
directory plus optional model/title, while unscoped listing accepts only its
actual pagination and filtering inputs.

The same rule applies to `agent::*`: prompt commands admit the session id,
prompt, optional reasoning level, and attachments actually consumed by the run;
status/abort commands admit only their behavioral identifiers. Ignored
workspace and source-label fields are not part of public or hidden agent
contracts.

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

The durable session log has **13 event variants**. Live-only deltas, progress,
context notices, and errors remain transport events and are not duplicated as
unwritten storage contracts:

| Concern | Event types |
|---|---|
| session | `session.start`, `session.end`, `session.fork` |
| messages | `message.user`, `message.assistant`, `message.deleted` |
| model | `model.provider_request` |
| provider tools | `tool.invocation.started`, `tool.invocation.completed` |
| turns | `stream.turn_start`, `stream.turn_end`, `turn.failed` |
| context | `compact.boundary` |

The `tool.invocation.*` names describe generic provider tool-call
conversation evidence.

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
- stop current work without disabling future dispatch, enable/disable, rollback,
  retained-version restoration after retirement, purge, webhook rotation, and
  stop-all;
- live refresh from `worker.lifecycle` and `worker.invocations` cursors, owned by
  the persistent sidebar task so state remains current while the sheet is closed.

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
projects that same token truth as a context ring. Its minimal Session Context
sheet shows used/remaining/window tokens, session usage and cost, current-model
selection through `model::switch`, automatic-compaction status, and forking
through `session::fork`. It has no parallel context-control resource client,
resource/action audit, memory editor, or fabricated manual compact/clear API.

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
  tools, and the exact typed primitive surface;
- atomic publication, failed candidates, immutable hashes, overlap, rollback,
  retirement, purge, and reconstruction;
- command, agent, and resident-service runners;
- manual, schedule, engine-event, and authenticated webhook dispatch;
- restart recovery with explicit attempts, idempotency propagation, loop
  suppression, terminal-event cursor advancement, causal depth, concurrency
  queueing, timeout, stop/disable, failure disablement, system-inbox attachment,
  and all-vault secret rejection/redaction;
- lazy resident reuse plus shutdown, stop-all, disable, process-exit, and
  repeated-health-failure supervision;
- a natural-language model loop that proactively upserts a complete worker,
  sees its direct typed tool immediately, invokes it, and reports the persistent
  adaptation; plus relevance selection, discovery promotion, complete tool
  schemas, and absence of local grant creation;
- the real loopback HTTP webhook route, including token success/failure,
  durable dispatch, and remote-peer rejection;
- remote auth and isolated core-proposal approval, including negation rejection
  and cherry-pick cleanup;
- canonical tree tamper detection, disposable runner workspaces, bounded
  concurrent process I/O, process-group termination of background descendants,
  bounded resident responses, and symlink-preserving dependency/runtime copies;
- iOS protocol, repository, view-model, settings, and build parity.

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
font directory, and generated helper-app `MacOS` payload directories. The
hierarchy guard walks these repository-owned trees so deleted planes cannot
leave empty shells and speculative single-file folders cannot accumulate again.
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
- Provider-neutral tool selection: `packages/agent/src/domains/worker_kernel/surface.rs`
- Provider schema adaptation: `packages/agent/src/domains/agent/loop/primitive_surface.rs`
- Trusted-local execution: `packages/agent/src/domains/agent/loop/tool_executor/`
- Engine settings: `packages/agent/src/domains/settings/config/types/`
- Transport/auth: `packages/agent/src/transport/` and `packages/agent/src/app/bootstrap/server.rs`
- iOS engine/worker protocol: `packages/ios-app/Sources/Engine/Protocol/EngineProtocolTypes+Catalog.swift` and `EngineProtocolTypes+WorkerKernel.swift`
- iOS Engine Dashboard: `packages/ios-app/Sources/Session/WorkerKernel/` and `Sources/UI/WorkerConsole/`

Nearest `mod.rs` documentation and focused tests are the implementation-level
truth when this cross-cutting reference and source disagree.
