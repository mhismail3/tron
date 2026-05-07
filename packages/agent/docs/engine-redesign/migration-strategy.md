# Migration strategy

The migration should move Tron from a traditional server plus agent harness to
a live capability fabric without forcing a risky all-at-once rewrite.

## Phase 0: documentation and source reconciliation

Deliverables:

- Keep this design directory updated as the architecture evolves.
- Reconcile README/module-doc drift before touching affected source-of-truth
  areas.
- Keep a living capability matrix for each migrated subsystem.

Acceptance:

- Docs identify current behavior, target primitive, visibility, effect class,
  idempotency, authority, causality, tests, and rollback path for every
  subsystem touched.
- `git diff --check` passes for docs-only changes.

## Phase 0.5: agent-native primitive checkpoint

Before writing the engine skeleton, lock the primitive semantics in docs and
tests.

Deliverables:

- Live catalog doctrine: no frozen catalog snapshot as the default.
- Session-live default visibility for agent-created capabilities.
- Catalog-change subscription classes for agents.
- Required idempotency contracts for mutating agent-visible functions.
- Causal context fields for invocations and catalog mutations.
- Authority/delegation model for spawned workers and subagents.
- Effect classes and risk levels.
- Promotion workflow from session to workspace/system visibility.
- Non-negotiable invariants and assumptions the engine refuses to rely on.

Acceptance:

- Phase 1 tests can be derived directly from this document.
- Phase 1 type names and metadata fields are decision-complete.
- Every planned primitive can answer actor, authority, visibility, effect,
  idempotency, causality, revision, failure, and cleanup questions.

## Phase 1: in-process live catalog skeleton

Build the smallest non-disruptive engine inside the Rust agent process.

Deliverables:

- Engine registry types for workers, functions, trigger types, and triggers.
- Catalog revision counter and catalog-change records.
- In-process worker trait.
- Function registration with owner tracking, function revision, visibility,
  effect class, risk, authority metadata, health, provenance, and idempotency
  metadata.
- Trigger registration with delivery mode, authority, idempotency, and loop
  policy metadata.
- Causal context types for invocation and catalog mutation records.
- Async sync-call invocation path for in-process functions.
- Discovery/search/inspect functions over the live catalog.
- Invocation ledger records for every attempt.
- Pluggable in-memory engine ledger for invocation records, catalog-change
  records, and idempotency replay for mutating functions.
- Request/response schema validation for declared schemas.
- Explicit visibility promotion from session scope to workspace/system scope.
- Unit tests for registration, overwrite rules, unregister, cleanup,
  discovery, catalog revisions, catalog-change events, causality metadata,
  idempotency enforcement/replay, schema validation, promotion, inspection, and
  sync invocation.

Acceptance:

- No current RPC behavior changes.
- No external worker sockets or sandbox execution yet.
- No queue/void execution yet beyond metadata.
- Engine can be created in tests without starting the server.
- Mutating functions without idempotency metadata are rejected.
- Mutating invocations without a valid scoped idempotency key are rejected.
- Duplicate idempotency keys cannot re-run a handler unless their replay policy
  explicitly permits a non-executing replay.
- Every invocation attempt is recorded with actor, authority grant, trace,
  parent invocation, trigger id, catalog revision, function revision, delivery
  mode, idempotency key, outcome, and replay source.
- Tests encode first-principles invariants, not just happy-path registry
  behavior.

## Phase 1.5: durable engine ledger adapter

Make the Phase 1 causal/idempotency ledger durable without wiring it into
production server startup yet.

Deliverables:

- `EngineLedgerStore` boundary with in-memory and SQLite implementations.
- Stable stored error projection `{ kind, message, details }` instead of raw
  `EngineError` persistence.
- SQLite tables for `engine_invocations`, `engine_idempotency_entries`, and
  `engine_catalog_changes`, initialized only by the engine-ledger adapter.
- Fail-closed idempotency reservation before handler execution.
- Completion records for successful and failed handler outcomes.
- Catalog-change audit persistence without restart reconstruction of catalog
  definitions.
- Shared storage-contract tests for in-memory and SQLite stores.
- Restart test proving a duplicate idempotency key replays after a fresh
  `LiveCatalog` is created with the same SQLite ledger.

Acceptance:

- No production `v001_schema.sql` changes.
- No current RPC, runtime, tool, or client behavior changes.
- A ledger write failure before handler execution prevents the handler from
  running.
- Duplicate keys with different payloads, stale function revisions, in-flight
  reservations, unknown outcomes, and reject/no-op policies all fail or replay
  without re-running side effects.
- SQLite persistence survives reopen for invocation records, catalog changes,
  and idempotency entries.

## Phase 1.75: engine host and live meta-capabilities

Expose the first agent-facing engine surface without changing production RPC,
runtime, tools, or clients.

Deliverables:

- `EngineHost` owns `LiveCatalog` and becomes the preferred boundary for
  future server/runtime adapters.
- Reserved system `engine` worker and namespace policy.
- Privileged `engine::discover`, `engine::inspect`, `engine::watch`,
  `engine::invoke`, and `engine::promote` functions registered in the live
  catalog.
- Cursor pull watch over durable catalog changes with class/kind/prefix/owner
  filters, bounded limits, and visibility-safe historical scope metadata.
- Delegated invocation through `engine::invoke`, with target policy,
  idempotency, schema, expected revision, health, visibility, and authority
  enforced at the child invocation.
- Promotion through `engine::promote`, with expected revision, idempotency key,
  owner, workspace/system authority scope, and session ownership checks.
- Built-in mutating meta-capabilities use the same pre-effect idempotency
  reservation/replay path as normal catalog functions.
- Catalog registration records durable change metadata before mutating the live
  catalog, so ledger write failures fail closed instead of creating unaudited
  capabilities.

Acceptance:

- No production server startup, RPC, runtime, tool, or client behavior changes.
- Meta-capabilities appear in discovery as real functions but cannot be
  overwritten by ordinary workers.
- Watch does not leak hidden session/internal changes and survives SQLite
  ledger reopen.
- Child invocations carry parent invocation, trace, actor, authority, catalog
  revision, and idempotency context.
- Repeated `engine::promote` calls with the same scoped idempotency key replay
  without re-promoting or mutating a second target.
- Focused engine tests cover host bootstrap, discovery/inspect, watch,
  delegated invocation, and promotion edge cases.

## Phase 1.9: server-owned engine host lifecycle

Make the engine host a real server-owned dependency without exposing it to
production clients yet.

Deliverables:

- `EngineHostHandle` wraps `EngineHost` in a cloneable async mutex for future
  adapters.
- Server startup opens `engine-ledger.sqlite` next to the resolved event-store
  database and fails closed if the host cannot bootstrap.
- `RpcContext` carries a non-optional engine host handle. Production contexts
  use the SQLite ledger; tests use an in-memory host.
- No production RPC methods, tools, runtime paths, or clients invoke engine
  functions in this phase.

Acceptance:

- Custom event DB paths derive custom sibling engine-ledger paths.
- SQLite engine host reopen preserves watchable catalog-change audit records.
- Test helper contexts and hand-built server contexts always include an engine
  host.
- RPC method registration count and wire behavior remain unchanged.

## Phase 1.95: host hardening and JSON-RPC transport bindings

Harden the host boundary, then make JSON-RPC an explicit migration surface
rather than an untracked parallel layer.

Deliverables:

- `EngineHostHandle` intent methods for worker/function registration,
  discovery, inspection, watch, promotion, and invocation.
- Prepare/execute/finish invocation lifecycle: routing, policy, schema, and
  idempotency reservation happen under lock; handler futures run outside the
  host lock; response schema, idempotency completion, and invocation ledger
  records finish under lock.
- Handler panics are caught and stored as structured engine errors so
  idempotency replay does not rerun a panicking mutating function.
- `rpc` compatibility worker with classified transport specs for every
  registered JSON-RPC method, non-executable `rpc::<method>` transport
  metadata, and canonical domain function ids.
- `JsonRpcAliasSpec` metadata for every method: legacy method name,
  canonical function id, trigger id, canonical domain owner, effect class,
  risk, visibility, transport authority, domain authority, idempotency source,
  strict schemas, stream/lease/compensation contracts, and handler-module
  provenance.
- Drift guards: a registered method without a transport spec fails, a spec
  without a registered method fails, and agent-visible mutating methods require
  idempotency.
- Before full collapse, handler-owned methods were internal and non-routable
  through the engine until their behavior migrated; after WP85-WP96 the public
  inventory is fully generic-triggered.

Acceptance:

- Slow in-process engine handlers do not block discovery/watch on the shared
  host handle.
- Success, handler error, panic, missing-function, schema, policy, and
  idempotency replay paths all produce invocation records.
- All public JSON-RPC methods have transport specs. After the canonical
  engine transport methods land, that means 175 registered methods: five
  `engine.*` methods plus 170 legacy compatibility aliases.
- Historical `HandlerOnly` / `Mirrored` / `EngineOwned` / `ThinAdapter`
  checkpoints are gone from production. Every public method is a catalog-derived
  `json_rpc` trigger over a canonical engine function or reserved engine
  meta-capability, with old production handlers removed and the handler namespace deleted.
- A migration package is incomplete unless it advances at least one method
  group and deletes any superseded method-specific business logic. Mirroring,
  thin adapters, or fallback paths are only acceptable as short-lived parity
  checkpoints when the same package also reduces old behavior ownership.

## Phase 2: first engine-owned read RPC functions

Move low-risk read behavior into engine-owned functions while keeping the
existing WebSocket JSON-RPC transport and client wire payloads stable. This
phase originally used method-specific thin adapters as the validation bridge.
The first completed read group has now advanced past thin adapters to the
generic JSON-RPC trigger.

Deliverables:

- Engine-owned implementations for `system.ping`, `system.getInfo`,
  `settings.get`, `model.list`, `skill.list`, and `logs.recent`.
- Strict request/response schemas for those migrated reads.
- Method-specific thin adapters may be used as a short-lived parity step, but
  completed read groups should advance to generic-trigger dispatch and delete
  the old business handlers.
- Direct engine invocations and JSON-RPC dispatch return identical payloads
  except deliberately unstable fields such as timestamps and uptime.

Acceptance:

- Existing client tests pass unchanged.
- Focused tests prove selected RPC methods work through both JSON-RPC dispatch
  and direct engine invocation.
- Invocation ledger records actor, trace, authority scopes, catalog revision,
  function revision, delivery mode, and result for migrated reads.
- README RPC counts remain reconciled with `server/capabilities/catalog.rs`.

## Phase 3: first generic RPC trigger and next read wave

Migrate the next batch of isolated read-only capabilities and replace
method-specific thin adapters with the first group-level generic RPC trigger.

Implemented generic-trigger functions now execute as canonical domain ids:

- `system::ping`
- `system::get_info`
- `settings::get`
- `model::list`
- `skills::list`
- `logs::recent`
- `events::get_history`
- `events::get_since`
- `filesystem::get_home`
- `prompt_library::history_list`
- `prompt_library::snippet_list`
- `prompt_library::snippet_get`

Acceptance:

- Each migrated read has schema metadata, authority metadata, visibility, and
  causal records.
- `MethodRegistry::dispatch` validates method existence and JSON depth, then
  calls `dispatch_json_rpc_transport` directly. There is no handler fallback.
- `JsonRpcTransportBinding` is pure transport metadata.
- Direct engine invocation and JSON-RPC dispatch return identical payloads for
  all twelve reads, including stateful event and prompt-library reads.
- Unaliased registered methods fail closed instead of passing through hidden handlers.
  current handler path, proving generic dispatch is opt-in by spec.
- The old thin/read handler structs and duplicated business logic are deleted
  for every method in the completed generic-trigger set.

## Phase 3.5: first delete-first mutating RPC migration

Move the first mutating RPC method group directly into generic-trigger engine
functions. This is the proof that the bridge is demolition scaffolding, not a
second backend.

Implemented generic-trigger writes now execute as canonical domain ids:

- `prompt_library::snippet_create`
- `prompt_library::snippet_update`
- `prompt_library::snippet_delete`

Semantics:

- migrated reads carry `rpc.read` plus domain read scope; migrated writes carry
  `rpc.write` plus domain write scope;
- prompt snippet writes use system-scoped engine-ledger idempotency because
  snippets are local global state rather than session-owned state;
- temporary JSON-RPC idempotency dedupes exact duplicate transports with a key
  derived from method, request id, and canonical payload; reused request ids
  with different payloads remain distinct commands;
- `promptSnippet.delete` remains an irreversible side-effect capability and
  carries approval-required authority metadata before system visibility.

Acceptance:

- Method registrations for the three prompt-snippet writes are transport aliases only.
- The old `CreateSnippetHandler`, `UpdateSnippetHandler`, and
  `DeleteSnippetHandler` business handlers are deleted.
- Direct engine invocation and JSON-RPC dispatch return the same success/error
  payloads for representative prompt-snippet write cases.
- Duplicate create/update/delete transports replay through the engine ledger
  without rerunning the store mutation.

## Phase 3.6: first fully collapsed RPC group

Finish the prompt-library group so JSON-RPC is only a transport trigger for
that subsystem.

Implemented generic-trigger functions:

- `prompt_library::history_delete`
- `prompt_library::history_clear`

Semantics:

- all eight prompt-library RPC methods are transport aliases;
- prompt history writes use `rpc.write`, `prompt_library.write`, strict
  schemas, and system-scoped engine-ledger idempotency;
- `promptHistory.delete`, `promptHistory.clear`, and `promptSnippet.delete`
  remain irreversible side-effect capabilities with approval-required metadata;
- transport registrations are binding-only, and tests fail if a completed
  group keeps hidden business handlers.

Acceptance:

- `DeleteHistoryHandler` and `ClearHistoryHandler` are deleted.
- Direct engine invocation and JSON-RPC dispatch return the same payloads for
  history delete/clear success and representative validation cases.
- Duplicate delete/clear transports replay through the engine ledger without
  rerunning store mutations.
- The prompt-library group is the first complete proof of the end state:
  method-specific JSON-RPC business handlers can disappear once functions own
  behavior.

## Phase 3.7: high-risk reversible settings collapse

Collapse the settings group so local configuration is owned by engine
functions, not method-specific JSON-RPC handlers.

Implemented generic-trigger functions:

- `settings::update`
- `settings::reset_to_defaults`

Semantics:

- all three settings RPC methods are transport aliases;
- settings writes use `rpc.write`, `settings.write`, strict schemas, and
  system-scoped engine-ledger idempotency;
- settings writes are high-risk reversible side-effect capabilities with
  approval-required metadata because they can reconfigure MCP servers, model
  defaults, runtime policy, and the managed Codex App Server;
- the engine function preserves serialized settings writes, sparse-overlay
  rollback, profile-runtime reload, MCP router reload/broadcast, and Codex App
  Server reconfiguration semantics.

Acceptance:

- `UpdateSettingsHandler` and `ResetSettingsHandler` are deleted.
- Direct engine invocation and JSON-RPC dispatch return the same payloads for
  settings get/update/reset success cases.
- Duplicate update/reset transports replay through the engine ledger without
  rerunning disk writes, MCP reloads, or Codex App Server reconfiguration.
- Settings is the second fully collapsed RPC group and the first migrated group
  whose write capabilities are high-risk reversible configuration effects.

## Phase 3.8: append-only logs collapse

Collapse the logs group so client log ingestion and log reads are owned by
engine functions. This makes JSON-RPC only the transport trigger for local
observability input.

Implemented generic-trigger function:

- `logs::ingest`

Semantics:

- both logs RPC methods are transport aliases;
- `logs.ingest` is an append-only event capability with `rpc.write`,
  `logs.write`, strict schemas, and system-scoped engine-ledger idempotency;
- JSON-RPC request-id-derived idempotency replays exact duplicate transports
  before opening the DB transaction, while row-level log dedupe remains a lower
  defense for overlapping batches;
- mutating invocation idempotency is reserved before request-schema validation
  so rejected write attempts, including oversized batches, are recorded and
  replayable.

Acceptance:

- `IngestLogsHandler` is deleted.
- The logs group is transport-bound only.
- Direct engine invocation and JSON-RPC dispatch return the same payloads for
  ingest success cases.
- Duplicate ingest transports replay through the engine ledger without
  rerunning log insertion.
- `logs.recent` continues to read the entries written by the engine-owned
  ingest function.

## Phase 3.9: domain workers and first trigger runtime

Move the architecture's center of gravity away from the RPC bridge by making
domain workers own migrated behavior and by routing JSON-RPC through explicit
trigger definitions.

Implemented in-process workers:

- `system`
- `settings`
- `logs`
- `prompt_library`
- `skills`
- `filesystem`
- `events`
- `session`
- `context`
- `job`
- `notifications`
- `plan`

Implemented trigger foundation:

- `json_rpc` trigger type for current WebSocket JSON-RPC requests;
- `manual` trigger type for tests and future direct agent/human dispatch;
- `EngineTriggerRuntime` dispatch that records trigger id, delivery mode,
  actor, authority grant, trace, optional parent invocation, and idempotency
  context before invoking the target function through `EngineHostHandle`;
- trigger dispatch failure records for missing triggers, delivery mismatches,
  stale targets, schema/policy failures, and idempotency conflicts.

Newly collapsed groups/functions:

- all `skill.*` methods;
- read-safe filesystem functions `filesystem.listDir`, `filesystem.getHome`,
  `filesystem.createDir`, and `file.read`;
- safe session reads `session.list`, `session.getHead`, `session.getState`,
  `session.getHistory`, and `session.reconstruct`;
- safe context reads `context.getSnapshot`, `context.getDetailedSnapshot`,
  `context.getAuditTrace`, `context.shouldCompact`,
  `context.previewCompaction`, and `context.canAcceptTurn`;
- job list/subscription controls `job.list`, `job.subscribe`, and
  `job.unsubscribe`;
- all `notifications.*` methods;
- all `plan.*` methods;
- all `events.*` methods, including stream-backed subscribe/unsubscribe.

Semantics:

- the `rpc` worker is now transport compatibility only;
- migrated domain workers own function contracts, schemas, effect/risk
  metadata, and idempotency policy;
- generic-triggered methods now execute as canonical domain ids such as
  `skills::activate`, `events::append`, `filesystem::read_file`, and
  `prompt_library::snippet_create`;
- `rpc::<method>` ids remain only as compatibility metadata for legacy
  transport method names; canonical domain ids are the executable surface;
- read triggers carry `rpc.read` plus domain read scope; write triggers carry
  `rpc.write` plus domain write scope;
- skill activation/deactivation and plan writes use session-scoped
  idempotency, while global refresh/notification/log/settings/prompt-library
  writes use system-scoped idempotency;
- event append is an append-only event capability and preserves the existing
  event payload contract.

Acceptance:

- migrated registrations are JSON-RPC transport aliases;
- old business handlers for the collapsed groups are deleted;
- direct engine invocation and JSON-RPC dispatch agree for every newly
  migrated method's success path and representative legacy errors;
- duplicate transport retries replay from the engine ledger without rerunning
  handlers;
- catalog watch shows domain workers, functions, trigger types, and trigger
  bindings as live catalog changes;
- missing/stale/hidden/unhealthy/schema/policy/idempotency trigger failures
  fail closed through the same invocation boundary.

## Phase 3.10: agent tools and primitive workers

Expose canonical capabilities directly to agents and land the first local
primitive workers without changing client wire behavior.

Implemented:

- `AgentCapabilityClient` over `EngineHostHandle` with live discover, inspect,
  watch, invoke, and manual trigger dispatch.
- First-party agent tools `engine_discover`, `engine_inspect`,
  `engine_watch`, and `engine_invoke`.
- Stream worker functions `stream::subscribe`, `stream::poll`,
  `stream::unsubscribe`, and internal `stream::publish`, with cursor-pull
  semantics, scoped visibility, and in-memory/SQLite stores.
- State worker functions `state::get`, `state::set`, `state::delete`,
  `state::compare_and_set`, and `state::list`, scoped by system/workspace/
  session, namespace, and key.
- Queue worker functions `queue::enqueue`, `queue::claim`,
  `queue::complete`, `queue::fail`, `queue::cancel`, `queue::get`, and
  `queue::list`, plus `DeliveryMode::Enqueue` dispatch and a queue drain
  runtime that preserves original trace/authority/idempotency context.
- Loopback external-worker protocol message types and round-trip tests for
  hello, registration, invocation, and related envelopes.

Acceptance:

- Agents discover canonical ids and reject `rpc::*` compatibility invocation.
- Mutating agent invokes require explicit idempotency; approval-required
  high-risk functions create pending approval records and stream events instead
  of returning a generic policy denial.
- Stream/state/queue stores have in-memory behavior tests and SQLite reopen
  durability tests.
- Enqueued triggers return receipts immediately and later target invocation
  records preserve trigger id, trace id, authority scope, session/workspace,
  and idempotency key.

## Phase 3.11: approval runtime, local external runtime, and command collapse

Make the primitive layer participate in real server behavior instead of only
metadata tests, while continuing to shrink old RPC code.

Implemented primitives:

- `approval` worker with `approval::request`, `approval::resolve`,
  `approval::get`, and `approval::list`.
- Approval records persist in the isolated engine ledger DB alongside stream,
  state, queue, idempotency, invocation, and catalog-change records.
- Agent `engine_invoke` creates a pending approval for high-risk
  approval-required functions, publishes an `approvals` stream event, and
  returns a structured `APPROVAL_REQUIRED` envelope containing the approval id.
- `approval::resolve` resumes the original invocation with the original trace,
  parent, authority scopes, session/workspace, and idempotency key, then
  records the child outcome on the approval. Agents do not receive
  `approval.resolve`; resolving an approval requires a system/admin or
  user-authorized actor with the approval scope.
- `EngineExternalWorkerRuntime` accepts loopback-only `hello`,
  session-default function/trigger registration, heartbeat, and disconnect
  cleanup over the existing protocol message types. External registrations are
  volatile and session-visible until explicitly promoted.

Newly collapsed command groups:

- `session.create`, `session.delete`, `session.fork`, `session.archive`,
  `session.unarchive`, `session.archiveOlderThan`, and `session.export`;
- `agent.queuePrompt`, `agent.dequeuePrompt`, and `agent.clearQueue`;
- `context.confirmCompaction`, `context.clear`, and `context.compact`;
- `job.background` and `job.cancel`.

Semantics:

- these methods now execute as canonical domain functions such as
  `session::create`, `agent::queue_prompt`, `context::compact`, and
  `job::cancel`;
- JSON-RPC remains only the `json_rpc` trigger transport and still returns the
  existing wire payloads;
- writes carry `rpc.write` plus the domain write scope, strict schemas, risk
  metadata, and engine-ledger idempotency;
- session-created operations that lack a prior session id, such as
  `session.create`, use system-scoped idempotency; session-scoped commands use
  session idempotency; job controls use system idempotency by job/request;
- WebSocket `session.create` injects a server-owned transport discriminator
  into the migration idempotency seed so duplicate retries on one connection
  replay while two clients that both use JSON-RPC id `1` do not collapse into
  the same created session;
- approval-required command capabilities are discoverable with explicit risk
  metadata, but autonomous agent invocation pauses in the approval primitive.

Acceptance:

- generic-trigger count rises from 51 to 66 while the public JSON-RPC method
  count stays 167;
- the old job/session/context/agent-queue handler fixtures were later deleted;
  regression coverage now lives in canonical capability and transport tests;
- focused tests prove approval request/resolve causality, SQLite approval
  durability, local external-worker disconnect cleanup, session create parity,
  and agent queue retry idempotency;
- approval, job, agent queue, and event paths publish scoped stream events that
  future WebSocket pumps can consume without making WebSocket the source of
  truth.

### WP32-WP37 runtime service and approval transport step

Implemented runtime integration now moves the engine from a catalog/adapter
surface into long-running server behavior:

- `EngineRuntimeServices` starts queue drainer loops for `default`, `jobs`,
  and `agent` and a stream pump for approval, job, agent queue,
  session-event, and catalog topics;
- `approval.get`, `approval.list`, and `approval.resolve` are additive public
  JSON-RPC methods, increasing the method count from 167 to 170 while keeping
  `approval.request` available only through agent/tool invocation;
- `job.background` and `job.cancel` enqueue hidden internal
  `job::*_apply` functions, then synchronously drain their own queue receipt to
  preserve existing JSON-RPC response timing;
- `agent.status`, `agent.abort`, `agent.abortTool`,
  `agent.deliverSubagentResults`, `agent.submitConfirmation`, and
  `agent.submitAnswers` are now canonical generic-trigger functions;
- `/engine/workers` is an authenticated loopback WebSocket endpoint backed by
  the local external-worker runtime. Registered external functions receive
  executable proxy handlers over the worker socket. External workers remain
  session-scoped and volatile by default; sandboxing, remote hosting, durable
  reconnect, and stronger worker supervision remain future work.

Acceptance:

- public JSON-RPC count is 170 and every method has exactly one transport
  binding spec;
- generic-trigger count rises from 66 to 75;
- approval resolution is user/system/admin-gated and preserves original
  approval causality;
- queue lifecycle events are published from enqueue/claim/complete/fail paths;
- WebSocket delivery is a pump over engine stream state, not the source of
  truth for migrated stream topics.

### WP38-WP43 agent prompt runtime collapse

`agent.prompt` is now part of the canonical agent capability fabric instead of
the remaining method-specific agent handler path:

- `agent.prompt` is a transport-bound generic JSON-RPC trigger into
  canonical `agent::prompt`;
- `agent::prompt` validates the current wire payload, uses session-scoped
  engine-ledger idempotency, derives a stable `runId`, enqueues hidden
  `agent::prompt_apply`, and synchronously drains that receipt so existing
  clients still receive `{ acknowledged: true, runId }` after startup is
  accepted;
- `agent::prompt_apply` owns the old prompt startup behavior: busy-session
  checks, prompt history capture, run guard acquisition, hook/worktree/runtime
  setup, and asynchronous turn spawning;
- prompt completion enqueues hidden `agent::prompt_queue_drain` so queued
  follow-up turns are also engine queue work. Dequeue still happens only after
  the next run guard is acquired, preserving the existing `message.queued` and
  `message.dequeued` event-store semantics;
- autonomous agent invocation of `agent::prompt` pauses in the approval
  primitive because the function is high-risk, `agent.write`, and approval
  metadata-bearing; paired JSON-RPC clients remain wire-compatible and do not
  receive an additional approval prompt;
- hidden prompt runtime functions are internal and are not visible through
  normal agent discovery.

Acceptance:

- public JSON-RPC count remains 170 and every method has exactly one transport
  binding spec;
- transport-bound method count rises from 75 to 76;
- all current agent control methods are catalog-derived transport aliases;
- duplicate JSON-RPC prompt retries replay the first `runId` without executing
  `agent::prompt_apply` a second time.

## Phase 4: stream push, event unification, and job output

Build on the cursor-pull stream primitive while preserving WebSocket clients.

Deliverables:

- Catalog watch stream with subscription classes.
- Session event stream backed by event ids.
- Job/tool-output stream adapter.
- Compatibility bridge from stream events to current WebSocket broadcasts.

Acceptance:

- Existing event broadcast tests pass.
- Stream tests cover subscribe, resume from cursor, disconnect, multiple
  subscribers, and catalog-change filtering.
- Agent turn lifecycle ordering remains unchanged.

## Phase 5: queue-backed agent/background workflows

Use the queue primitive for production workflows that currently have bespoke
background execution paths.

Deliverables:

- Queue events/logs include invocation id, trace id, idempotency key, and
  effect metadata.
- Existing job manager and prompt queue can be adapted to queue-backed
  execution.

Acceptance:

- Unit tests for enqueue/dequeue, retry, cancellation, concurrency, DLQ, and
  duplicate idempotency keys.
- Integration tests for a queued background job and a queued no-op function.
- No public client behavior changes until compatibility path is proven.

## Phase 6: cron as triggers

Convert cron execution to trigger semantics while keeping current automation
definition files.

Delivered:

- `cron` in-process domain worker with canonical `cron::list`,
  `cron::get`, `cron::status`, `cron::get_runs`, `cron::create`,
  `cron::update`, `cron::delete`, and `cron::run` functions.
- `cron_schedule` trigger type owned by the `cron` worker.
- Live projection from `automations.json` job definitions to trigger
  registrations, including schedule, payload kind, enabled state,
  workspace id, overlap policy, and misfire policy metadata.
- Hidden `cron::scheduled_fire` function for scheduled fires. Production
  startup attaches the engine host before the scheduler starts; startup and
  config reload project enabled jobs into live trigger definitions, and due
  fires dispatch through `EngineTriggerRuntime` before execution starts.
- Current `automations.json` definitions and cron runtime SQLite remain the
  durable truth for job definitions and run history in this package. Engine
  triggers are the live invocation/watch/ledger path.
- `cron.create`, `cron.update`, `cron.delete`, and `cron.run` use strict
  schemas, `rpc.write`, `cron.write`, system-scoped engine-ledger idempotency,
  high-risk metadata, and approval-required metadata for autonomous agent
  visibility.
- `cron.run` keeps its existing compatibility behavior by scheduling an
  immediate fire; duplicate JSON-RPC retries replay the first trigger result
  and do not schedule the job twice.

Acceptance:

- Existing cron tests pass.
- Engine bridge tests prove the cron group is fully generic-triggered,
  `cron_schedule` triggers target hidden `cron::scheduled_fire`, scheduled
  dispatch records trigger/authority/idempotency ledger metadata, and duplicate
  scheduled fires replay through the engine ledger.
- Misfire, overlap, retry, corrupt-row, idempotency, and causality invariants
  remain documented and tested.

### WP59-WP66 cron and runtime-tail collapse

The runtime-tail methods below are now canonical functions too, raising the
generic-trigger count from 98 to 112 while keeping the public JSON-RPC method
count at 170:

- `system::get_diagnostics`
- `system::get_update_status`
- `codex_app::status`
- `blob::get`
- `tool::result`
- `message::delete`

Semantics:

- `system.getDiagnostics`, `system.getUpdateStatus`, `codexApp.status`, and
  `blob.get` are pure reads with strict schemas and domain read scopes.
- `tool.result` is a session-scoped runtime write with `tool.write` and
  engine-ledger idempotency, preserving pending tool-call resolution behavior.
- `message.delete` is a session-scoped irreversible side effect with
  `message.write`, strict schema, idempotency, and approval-required metadata
  for autonomous agent visibility.
- The old cron/blob/codex-app/tool/message handlers are test-only fixtures;
  production registrations are JSON-RPC transport aliases.

High-risk deferred groups stay explicitly blocked from migration until their
contracts cover strict schema, domain authority, idempotency, risk metadata,
approval metadata where required, and transport-bound registration. Those groups
include auth, sandbox lifecycle/execution, transcription audio/download,
browser/display stream mutation, voice-note mutation, device mutation, system
shutdown/update actions, and `session.resume`.

### WP67-WP74 resource leases and first high-risk command collapse

Resource leases are now an engine primitive for shared-state mutations that
need resource-level exclusion without holding the host lock. The in-memory and
SQLite lease stores live beside the engine ledger and record lease id,
resource kind/id, holder invocation, actor, authority grant, trace, parent,
function id, idempotency key, status, acquisition, expiry, and release time.
Lease lifecycle events publish to `resource.leases`.

The first high-risk command package raises generic-trigger coverage from 112
to 116 while keeping the public JSON-RPC method count at 170:

- `model.switch` -> `model::switch`, high-risk reversible session write with
  `model.write`, session idempotency, approval metadata, and
  `session:{sessionId}:model` lease.
- `config.setReasoningLevel` -> `config::set_reasoning_level`, high-risk
  reversible session write with `config.write`, session idempotency, approval
  metadata, and `session:{sessionId}:reasoning` lease.
- `memory.retain` -> `memory::retain`, high-risk external side effect with
  `memory.write`, session idempotency, approval metadata, and
  `session:{sessionId}:memory-retain` lease before the existing retain guard
  owns the long-running background summarizer.
- `import.execute` -> `import::execute`, high-risk append-only import command
  with `import.write`, system idempotency, approval metadata, and an
  import-source lease based on the canonical session path.

Acceptance gates:

- The four production registrations are JSON-RPC transport aliases.
- Legacy handler structs are test fixtures only.
- Duplicate JSON-RPC retries replay from engine idempotency without duplicate
  model/reasoning events, memory retain starts, or imports.
- Direct engine explicit-key payload conflicts return `IDEMPOTENCY_CONFLICT`.
- High-risk generic triggers must carry strict schemas, domain authority,
  idempotency, approval metadata, resource-lock metadata, stream topics, and a
  rollback/compensation note.

### WP75-WP84 enforced contracts and git/worktree collapse

High-risk contracts are now executable engine policy, not just metadata
discipline in domain functions. `ResourceLeaseRequirement` definitions are
resolved before handler execution, leases are acquired by the host, handlers run
outside the host lock, and leases are released on success, error, or panic.
Invocation records now carry acquired lease ids and compensation status, and
the isolated engine ledger persists compensation records for high-risk
invocations so future approval/rollback workers can inspect what happened.

The package raises generic-trigger coverage from 116 to 144 while keeping the
public JSON-RPC method count at 170:

- `git.clone/syncMain/push/listLocalBranches/listRemoteBranches` now route to
  canonical `git::*` functions.
- `worktree.getStatus/isGitRepo/list/getDiff/getCommittedDiff/listSessionBranches/listConflicts`
  are canonical pure reads.
- `worktree.acquire/release/stageFiles/unstageFiles` are safe mutating
  `worktree.write` capabilities with explicit idempotency, path/session
  leases, and no autonomous approval requirement.
- `worktree.commit/merge/finalizeSession/deleteBranch/pruneBranches/discardFiles/rebaseOnMain/startMerge/resolveConflict/continueMerge/abortMerge/resolveConflictsWithSubagent`
  are high-risk mutating capabilities with strict schemas, idempotency,
  approval-required metadata for autonomous agents, host-enforced leases, and
  compensation notes.

Acceptance gates:

- All 28 git/worktree registrations are JSON-RPC transport aliases.
- Legacy git/worktree handler modules are test-only wire-contract fixtures.
- Direct canonical invocation and JSON-RPC trigger dispatch produce matching
  sanitized error shapes for the migrated surface.
- No high-risk generic trigger can register without strict schema, authority,
  idempotency, approval metadata when agent-visible, resource lease metadata,
  stream topic metadata, and compensation notes.

## Phase 6.5: CI isolation and full RPC tail collapse

Finish the public JSON-RPC collapse and remove the last production
business handlers before broader client-native cutover work.

Delivered:

- Parallel integration server boots now use unique auth, onboarding, updater,
  and prompt working paths instead of shared `/tmp` fixtures, and spawned test
  server/bridge tasks shut down against isolated state.
- The final 26 handler-owned public methods are now transport-bound
  `json_rpc` triggers into canonical domain functions:
  `auth.get/update/clear/oauthBegin/oauthComplete/renameAccount/setActive/
  removeAccount/removeApiKey`, `device.register/unregister/respond`,
  `voiceNotes.save/delete`, `transcribe.audio/downloadModel`,
  `browser.startStream/stopStream`, `display.stopStream`,
  `sandbox.startContainer/stopContainer/killContainer/removeContainer`,
  `session.resume`, `system.checkForUpdates`, and `system.shutdown`.
- Auth writes preserve secure `auth.json` handling, OAuth flow state,
  provider-specific response shapes, active-account semantics, and secret
  redaction while using auth-file leases, system idempotency, approval metadata,
  and manual/inverse compensation notes.
- Local runtime/media/device/sandbox/lifecycle commands preserve current
  JSON-RPC wire behavior while adding strict schemas, domain write authority,
  idempotency, resource leases, stream topics, and approval metadata where
  autonomous agents would otherwise perform high-risk effects.
- The 170 legacy domain methods reached 170/170 transport-trigger coverage before
  the additive `engine.*` transport methods raised the current public method
  count to 175.

Acceptance gates:

- Every public JSON-RPC alias is generated from `server/capabilities/catalog.rs`
  and projected by `server/rpc/bindings.rs`.
- Every public method has exactly one transport binding and one canonical
  function mapping.
- No mutating generic trigger can register without strict schemas, domain
  authority, idempotency, risk metadata, approval metadata when required,
  resource leases for shared resources, stream topics, and compensation notes.
- Legacy handler modules are deleted; parity lives in canonical capability and transport-binding tests;
  production execution is canonical engine function execution.

### WP97-WP108 canonical capability API and transport cleanup

The next layer after full RPC tail collapse exposes the canonical engine
surface directly instead of treating legacy method names as the future API:

- `engine.discover`, `engine.inspect`, `engine.watch`, `engine.invoke`, and
  `engine.promote` are additive public JSON-RPC triggers over the reserved
  `engine::*` meta-capabilities, raising the public method count from 170 to
  175;
- the old 170 method names remain compatibility aliases over canonical
  `namespace::function` ids, while `engine.invoke` rejects `rpc::*`
  compatibility ids so callers cannot build new workflows on transport
  metadata;
- `RpcMigrationState`, thin/mirrored/handler-only branches, and schema/execution
  migration modes are removed from production specs. The remaining spec model
  is a transport binding: method name, canonical function id, trigger id,
  transport/domain authority, idempotency source, strict schemas, effect/risk
  metadata, and provenance;
- stream ownership tightens for migrated direct-broadcast classes. Auth,
  settings/MCP status, device, cron/update, memory, display, sandbox, jobs,
  agent queue, session-event, approval, and catalog topics flow through the
  engine stream pump when stream publication succeeds, with direct WebSocket
  fallback reserved for explicit stream publish failure rather than a second
  compatibility delivery path;
- `agent::prompt_apply` now hands actual turn execution to hidden
  `agent::run_turn`, which records run/turn metadata and starts the existing
  provider runtime without changing the `{ acknowledged: true, runId }`
  transport contract;
- local external workers gain heartbeat-timeout cleanup so volatile
  session-scoped functions/triggers unregister automatically when a loopback
  worker disappears.

Acceptance gates:

- all 175 registered methods have exactly one transport binding;
- every registration is transport-bound;
- direct `engine.*` JSON-RPC dispatch matches the reserved meta-capability
  behavior;
- legacy JSON-RPC wire behavior remains unchanged;
- `rpc::*` compatibility ids are never discoverable as the primary
  agent/client capability surface and are rejected by `engine.invoke`.

### WP109-WP120 canonical catalog and handler demolition

The single-shape cleanup removes the last handler-shaped production concept:

- executable domain modules live under `server/capabilities`, not the old
  `server/rpc/engine_bridge/functions` path;
- `server/capabilities/catalog.rs` owns the canonical alias inventory and
  function metadata projection. It records canonical function ids, owning
  workers, schemas, effect/risk class, authority, visibility, idempotency,
  leases, compensation metadata, provenance, hidden/internal status, and
  optional JSON-RPC aliases;
- `server/rpc/bindings.rs` is the only public alias registration layer. It
  projects catalog aliases into `MethodRegistry`;
- `MethodRegistry` stores `JsonRpcTransportBinding` entries only. There is no
  production `MethodHandler` trait object, no fallback `.handle(...)` branch,
  and no marker handler that must be intercepted;
- `server/rpc/handlers` is deleted. Parity and demolition tests now live beside
  canonical capabilities and the transport binding layer;
- hidden internal functions such as job apply, prompt apply/run-turn, cron
  scheduled apply, and tool internals remain cataloged as engine functions but
  do not receive public JSON-RPC aliases.

Acceptance gates:

- no executable or discoverable `rpc::*` functions are registered;
- every JSON-RPC alias maps to exactly one canonical function id and trigger id;
- every registered public method dispatches through `dispatch_json_rpc_transport`;
- no production `MethodHandler`, `HandlerEntry`, `RpcGenericTriggerHandler`, or
  fallback handler dispatch remains;
- normal agent discovery shows canonical `namespace::function` ids and never
  compatibility aliases.

## Phase 7: tools, MCP, approvals, and effects

Move tool and MCP execution behind engine functions without losing the runtime
semantics that made the old path reliable.

Delivered so far:

- The `tool` worker registers built-in tools as canonical `tool::*` functions
  with effect class, risk, authority, approval, provenance, and tool-schema
  metadata.
- Prompt-time tool execution now invokes the matching `tool::*` function after
  local-model policy, guardrails, and PreToolUse hooks. A one-shot runtime
  handoff gives the engine handler the exact `ToolContext`, preserving progress
  streams, abort tokens, PostToolUse hooks, process/job managers, output buffer
  access, and event persistence while the engine records idempotency and
  invocation ledger entries.
- Model tool-call retries derive stable idempotency keys from run id, session,
  turn, tool call id, tool name, working directory, workspace, and argument
  fingerprint. Direct engine/agent mutations still require explicit
  idempotency.
- Provider-facing tool schema assembly now resolves from the live engine catalog
  at each model-call boundary. `ToolRegistry` remains only the temporary
  implementation/policy backing for built-in tools, so newly registered,
  removed, or unhealthy engine/MCP capabilities affect the next provider call
  without a server restart or frozen turn snapshot.
- All public `mcp.*` methods are JSON-RPC transport aliases into canonical
  `mcp::*` functions, raising the generic-trigger count from 76 to 84 while
  preserving the public method count at 170.
- Discovered MCP tools register/unregister as live `mcp::*` external-side-effect
  functions with server/tool provenance, conservative approval-required
  authority, system idempotency, and catalog availability changes.
- MCP discovery now classifies tools conservatively at catalog refresh time:
  obvious list/read/search/query/status tools become low-risk pure reads, while
  mutation-like or unknown tools remain approval-required external side effects
  with classifier reason/confidence metadata.
- Safe read groups for tree, repo divergence, import browsing/preview, browser
  status, voice-note listing, transcription model listing, and sandbox listing
  are now canonical generic-trigger functions. The generic-trigger count rises
  from 84 to 98 while the public JSON-RPC method count stays 170.

Still to do:

- Replace remaining direct compatibility broadcasts for tool/MCP/device flows
  with stream-owned delivery classes.
- Delete the JSON-RPC compatibility inventory after clients and agents move to
  canonical domain ids.

## Phase 8: agent worker and live self-modification

Make the agent loop itself an engine worker.

Deliverables:

- `agent::run_turn` function.
- Stable agent meta-capabilities: discover/search, inspect, invoke, watch,
  spawn, promote.
- Prompt queue trigger for user prompts.
- Subagent spawn/handoff through delegated authority.
- Session-scoped worker/function creation.
- Promotion workflow for wider capability visibility.

Acceptance:

- Existing session and orchestrator tests pass.
- Agent turn persistence ordering is unchanged.
- Agents can see session-created capabilities live through subscriptions.
- Trace id connects prompt, catalog changes, LLM stream, tool calls, queued
  work, events, and final client broadcast.

## Phase 9: external and sandbox workers

Build runtime connections and sandbox execution on top of the loopback protocol
types introduced in Phase 3.10.

Deliverables:

- Tron-owned JSON-over-WebSocket worker protocol transport.
- Scoped worker tokens represented as authority grants.
- Namespace registration policy.
- Reconnect and re-registration behavior.
- Sandbox worker creation under session-scoped visibility.

Acceptance:

- External worker cannot register outside its namespace.
- Disconnect cleanup removes only owned volatile registrations.
- Reconnect is idempotent.
- Spawned workers inherit narrowed authority.
- Invocation timeout/cancellation behavior is tested.

## Phase 10: client cutover and old-path removal

Cut clients over once the server contract is stable.

Deliverables:

- Mac/iOS consume discovery and streams for selected workflows.
- Legacy RPC compatibility functions are marked migration-only.
- Removed RPC methods are deleted from docs, tests, and clients together.

Acceptance:

- Server, Mac, and iOS targeted tests pass for migrated workflows.
- README API sections describe the final engine-native contract.
- No aspirational or removed methods remain in canonical docs.

## Commit discipline

Each implementation commit should include:

- Code change.
- Focused tests for the changed behavior.
- Progressive disclosure docs for touched modules.
- README updates when a source-of-truth file listed in the project guidelines
  changes.

Docs-only exploration commits can use `git diff --check` as verification.
Implementation commits should run the smallest high-signal command set first
and escalate to full CI when shared contracts, runtime behavior, or client
protocols change.

## Phase gate

No implementation phase should start until its design can answer this checklist:

- What durable truth or invariant requires this primitive/change?
- Which assumptions does the design avoid?
- Which assumptions remain, and where are they encoded?
- What actor and authority can perform the action?
- What visibility scope is the default?
- What effect class and idempotency contract apply?
- What causal records make the action reconstructable?
- What failure modes are expected, and which tests prove them?
