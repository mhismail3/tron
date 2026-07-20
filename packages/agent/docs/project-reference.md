# Tron Worker-First Technical Reference

> Last verified: 2026-07-20 on `codex/worker-first-autonomy-poc`.

This document describes the active worker-first implementation. Git history is
the record of the removed capability-governance and module-proposal system; it
is not an active compatibility contract.

## Product Model

Tron is a persistent local agent. A Rust service on the user's Mac owns model
turns, session/event truth, authenticated client transport, and profile-global
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
- authenticated `/engine` transport and loopback external-worker transport;
- private iOS device-token custody;
- isolated core-change proposal creation and explicitly approved application;
- product settings, auth, context, memory, logging, blobs, and transcription
  needed by current clients.

Higher-level behavior belongs in a worker bundle. The fixed tree no longer
contains module proposal/validation/install/dependency/lifecycle/runtime
planes, capability binding and shadow routing, procedural candidates,
metadata-only schedules, the old worker lifecycle, fixed media/notification
delivery planes, or the `capability::execute` wrapper.

The engine still uses generic words such as “capability invocation” in provider
tool-call events and client rendering. Those names describe the model protocol;
they do not imply the removed authorization or operation-catalog system.

## Autonomy Modes

`autonomousWorkers` is a profile setting.

- Existing profiles default to `false`. The agent remains conversational and
  explains that autonomous action can be enabled in Settings.
- The bundled `worker-poc` profile defaults to `true`.
- With the setting enabled, accepted user sessions and workers are trusted
  local operators. Direct host and worker calls do not derive, mint, inspect,
  or consume per-call capability grants.
- Changes apply to the running profile without a server restart. Disabling
  hides the fixed worker primitives, unregisters direct worker tools, cancels
  active execution, and stops resident services while preserving canonical
  bundles and queued work. Re-enabling restores the primitives, rebuilds the
  enabled direct-tool surface from canonical state, and resumes dispatch unless
  profile stop-all is still engaged.
- The authenticated Worker Console remains operational while autonomy is off:
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
the output schema, and records the result. The child is aborted if its parent
invocation is dropped by timeout, disable, stop-all, or shutdown. Worker causal
depth survives the agent hop and is attached to every nested direct tool call.

### Command runner

A command worker starts an executable with the version's `files/` directory as
its working directory. JSON input is written to stdin. JSON stdout becomes the
typed result; non-JSON stdout is wrapped as bounded text. Commands inherit the
Tron user's normal host permissions. There is no application filesystem or
process sandbox. A successful command may intentionally ignore its input; Tron
does not turn the resulting closed stdin pipe into a false worker failure, but
all other write errors and non-success child exits remain failures. From this
working directory, a declared dependency named `N` is available at
`../dependencies/N`. Stdin and both output pipes are handled concurrently.
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
  filter;
- `POST /engine/workers/webhooks/<worker-id>/<trigger-id>` from loopback with
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

Profile ceilings are fixed reliability limits:

| Limit | Value |
|---|---:|
| Concurrent invocations per profile | 32 |
| Concurrent invocations per worker | 8 |
| Non-resident invocation timeout | 2 hours |
| Causal trigger depth | 16 |

Work beyond concurrency limits waits in the durable queue. Direct causal work
beyond depth 16 is rejected before persistence. A matching engine event beyond
that ceiling records a durable terminal-suppression trace and audit entry, then
advances its cursor so an impossible event cannot jam the trigger. Event cursors
otherwise advance only after matching invocations are durably queued; a failure
to persist either an invocation or suppression retains the cursor for retry. If
the configured engine-event materialization itself violates the worker input
schema or secret-isolation contract, Tron disables the worker, its route, and
its triggers, records the inbox failure, and advances past that terminal event.

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

- disable/enable — immediate route and trigger removal/restoration plus
  active-work stop (webhooks restore only when a token hash exists);
- rollback — activate a retained version and rotate any restored webhook token;
- retire — disable routes and triggers while preserving bundles and history;
- purge — permanently remove a retired worker's bundle and operational rows,
  while retaining the purge audit entry;
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
| `filesystem_list` | `worker_kernel::filesystem_list` | Directory listing |
| `filesystem_search_text` | `worker_kernel::filesystem_search_text` | Recursive literal search with time, walk, result, hidden-tree, and heavy-directory controls |
| `filesystem_write` | `worker_kernel::filesystem_write` | Complete local text write |
| `process_run` | `worker_kernel::process_run` | Local process with bounded output/timeout |
| `web_fetch` | `worker_kernel::web_fetch` | Explicit bounded HTTP(S) fetch with provenance |

### Worker operations

| Model tool | Engine function |
|---|---|
| `worker_upsert` | `worker_kernel::upsert` |
| `worker_discover` | `worker_kernel::discover` |
| `worker_list` | `worker_kernel::list` |
| `worker_inspect` | `worker_kernel::inspect` |
| `worker_invoke` | `worker_kernel::invoke` |
| `worker_disable` / `worker_enable` | `worker_kernel::disable` / `enable` |
| `worker_rollback` | `worker_kernel::rollback` |
| `worker_retire` / `worker_purge` | `worker_kernel::retire` / `purge` |
| `worker_inbox` / `worker_runs` | `worker_kernel::inbox` / `runs` |
| `worker_webhook_rotate` | `worker_kernel::webhook_rotate` |
| `worker_stop_all` | `worker_kernel::stop_all` |

Every enabled worker is also registered as a stable direct typed tool using the
bundle's `toolName`, input schema, output schema, description, routing metadata,
provenance, health, version, and recent success evidence.

The provider-visible tool description carries a compact health, active-version,
provenance, completed-run, and last-success summary. Those observations are
therefore available to the model choosing among the relevant tools, rather than
being hidden selection metadata.

At each model turn Tron ranks dynamic workers by explicit session promotion,
query overlap, recent successes, and identity, selecting at most 12. A
`worker_discover` result promotes matching workers into that session's live
tool surface without a restart. A newly upserted worker registers immediately.

## Local Authority and Provenance

For an autonomous profile, local model calls use a trusted-local causal context.
The invocation executor records actor, session, workspace, model/provider call,
trace, parent invocation, working directory, turn, and deterministic
idempotency metadata. None of those observations is a permission grant.

There are no local operation claims, resource selectors, synthetic profile
grants, or agent-kind rejections. Executable workers can change local files and
make consequential external requests without fresh confirmation. This is the
intentional POC threat model.

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
the trusted-local execution change does not weaken transport authentication.
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

Before a profile first opens the worker schema, Tron creates a verified snapshot
under `~/.tron/internal/snapshots/`. The manifest records format/schema,
source home/profile, creation time, every relative path, byte count, SHA-256,
and restoration instructions. It captures profiles, prior worker files, and a
consistent `VACUUM INTO` copy of the primary SQLite database. Symlink targets
are checksum-covered snapshot entries and are restored as symlinks rather than
silently omitted.

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
audits, generic resources, streams, and approval-message evidence. The worker
kernel does not move these shared engine records into its disposable index.

### Tables

| Table | Ownership |
|---|---|
| `blobs` | content-addressed durable payloads |
| `engine_catalog_changes` | catalog change stream |
| `engine_catalog_functions` | durable external function definitions |
| `engine_catalog_workers` | durable external worker definitions |
| `engine_compensation_records` | engine compensation evidence |
| `engine_grant_events` | retained non-local authority audit history |
| `engine_grants` | retained non-local authority grants |
| `engine_idempotency_entries` | engine invocation idempotency ledger |
| `engine_invocations` | generic engine invocation history |
| `engine_queue_items` | durable engine queue |
| `engine_resource_events` | generic resource event history |
| `engine_resource_leases` | generic resource leases |
| `engine_resource_links` | generic resource relationships |
| `engine_resource_type_definitions` | registered generic resource schemas |
| `engine_resource_versions` | immutable generic resource versions |
| `engine_resources` | generic resource heads |
| `engine_state_entries` | engine-owned state values |
| `engine_stream_events` | durable engine stream records |
| `engine_stream_subscriptions` | durable stream cursors |
| `events` | session event log |
| `logs` | structured session logs |
| `schema_version` | primary schema version |
| `sessions` | session metadata |
| `storage_checkpoints` | storage maintenance checkpoints |
| `storage_exports` | storage export evidence |
| `storage_metadata` | storage subsystem metadata |
| `storage_payload_refs` | payload ownership references |
| `storage_retention_runs` | retention-run evidence |
| `trace_records` | cross-invocation causal trace records |
| `workspaces` | workspace metadata |

### Worker database

The rebuildable worker database is
`~/.tron/internal/database/workers.sqlite` with:

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
| `worker_runtime_settings` | durable profile stop-all state |

Raw device tokens remain outside generic resources in a private `0600` file
under `~/.tron/internal/devices/`. The fixed kernel performs no notification
inbox or APNs delivery; that behavior belongs in a worker.

## Events and Transport

`GET /engine` remains the authenticated WebSocket upgrade endpoint for clients. The public
invoke contract admits client identity and idempotency metadata but rejects
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

- `worker.lifecycle` — activation, enablement, disablement, rollback,
  retirement, failure, and related state;
- `worker.invocations` — started/completed/failed invocation summaries.

The session log has **24 typed event variants**:

| Concern | Event types |
|---|---|
| session | `session.start`, `session.end`, `session.fork` |
| messages | `message.user`, `message.assistant`, `message.system`, `message.deleted` |
| model | `model.provider_request` |
| provider tools | `capability.invocation.started`, `capability.invocation.completed`, `capability.invocation.progress` |
| streaming | `stream.text_delta`, `stream.thinking_delta`, `stream.turn_start`, `stream.turn_end` |
| context | `compact.boundary`, `compact.summary_staging`, `context.cleared` |
| metadata | `metadata.update`, `metadata.tag` |
| failures | `error.agent`, `error.capability`, `error.provider`, `turn.failed` |

The historical `capability.invocation.*` and `error.capability` names describe
generic provider tool-call conversation evidence; they do not restore the
removed authorization plane. Removed governance-domain stream topics and
schemas are not retained through adapters.

## iOS Client

**Minimum iOS:** 26.0. The generated project and documented toolchain workflow
support Xcode 26 and Xcode 27 without source forks for their runtime SDKs.

The iOS Worker Console is backed by `WorkerKernelClient`,
`WorkerKernelRepository`, `WorkerConsoleViewModel`, and `UI/WorkerConsole`.
It exposes:

- worker list, health, runner, active content version, provenance, and triggers;
- JSON-schema-aware typed invocation;
- runs with delivery-attempt counts, durable inbox, and audit history;
- enable/disable, rollback, retained-version restoration after retirement,
  purge, webhook rotation, and stop-all;
- live refresh from `worker.lifecycle` and `worker.invocations` cursors.

Conversational creation remains the authoring interface; the client does not
contain a bundle editor. The Mac package is a server supervisor/pairing shell,
so iOS is the only current operational engine client requiring the console.

The Session Briefing sheet opened from the composer context ring remains the
server-backed surface for model selection, context composition, compaction,
clear actions, memory references, and durable context-action evidence.

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

## Empirical POC Gate

Automated correctness is necessary but not sufficient. The committed
`worker_poc_observations.json` ledger is intentionally empty. Real testing must
demonstrate:

- at least 10 substantive passed scenarios;
- at least three distinct calendar days;
- at least three autonomous worker creations or improvements;
- at least one of those adaptations initiated proactively during an ordinary
  task that did not explicitly request worker creation;
- no unresolved failure caused by authority ceremony, a hidden actuator, a
  proposal-only transition, or blocked activation of a valid worker.

The local ledger accepts `succeeded` as the human-facing alias for `passed` and
retains proactive-adaptation, resolution timestamp/evidence, and notes fields.
Resolved failures must include both a timestamp and concrete resolution refs;
these richer records remain validated rather than being discarded for CI.

Validate a local evidence ledger with:

```bash
TRON_WORKER_POC_LEDGER=/absolute/path/to/observations.json \
  cargo test --manifest-path packages/agent/Cargo.toml \
  --test worker_poc_gate worker_poc_empirical_gate -- --ignored
```

Re-hardening begins only after this gate passes. Every new guardrail must map to
an observed failure or concrete threat, include a regression scenario, and
prove that accepted worker workflows remain uninterrupted.

## Source Owners

- Worker kernel: `packages/agent/src/domains/worker_kernel/`
- Provider tool selection: `packages/agent/src/domains/agent/loop/primitive_surface.rs`
- Trusted-local execution: `packages/agent/src/domains/agent/loop/capability_invocation_executor/`
- Profile settings: `packages/agent/src/domains/settings/profile/types/`
- Transport/auth: `packages/agent/src/transport/` and `packages/agent/src/app/bootstrap/server.rs`
- iOS worker protocol: `packages/ios-app/Sources/Engine/Protocol/WorkerKernel/`
- iOS Worker Console: `packages/ios-app/Sources/Session/WorkerKernel/` and `Sources/UI/WorkerConsole/`

Nearest `mod.rs` documentation and focused tests are the implementation-level
truth when this cross-cutting reference and source disagree.
