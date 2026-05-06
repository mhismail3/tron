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
- No external worker protocol yet.
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

## Phase 1.95: host hardening and RPC migration bridge

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
- `rpc` compatibility worker with one `rpc::<method>` function for each
  registered JSON-RPC method.
- `RpcCapabilitySpec` metadata for every method: method name, function id,
  migration state, effect class, risk, visibility, authority, idempotency mode,
  execution policy, schema mode, and handler module.
- Drift guards: a registered method without a spec fails; a spec without a
  registered method fails unless it is marked removed; agent-visible mutating
  methods require idempotency.
- Handler-only methods are internal and non-routable through the engine until
  their behavior is migrated.

Acceptance:

- Slow in-process engine handlers do not block discovery/watch on the shared
  host handle.
- Success, handler error, panic, missing-function, schema, policy, and
  idempotency replay paths all produce invocation records.
- All 167 current JSON-RPC methods have bridge specs.
- The bridge is explicitly temporary: `HandlerOnly` may use `EngineOwned` or
  `ThinAdapter` as short parity checkpoints, but completed groups end at
  `GenericTrigger` with old handlers removed. Low-risk groups should skip
  intermediate states when tests can prove parity directly.
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
- README RPC counts remain reconciled with `server/rpc/handlers/mod.rs`.

## Phase 3: first generic RPC trigger and next read wave

Migrate the next batch of isolated read-only capabilities and replace
method-specific thin adapters with the first group-level generic RPC trigger.

Implemented generic-trigger functions:

- `rpc::system.ping`
- `rpc::system.getInfo`
- `rpc::settings.get`
- `rpc::model.list`
- `rpc::skill.list`
- `rpc::logs.recent`
- `rpc::events.getHistory`
- `rpc::events.getSince`
- `rpc::filesystem.getHome`
- `rpc::promptHistory.list`
- `rpc::promptSnippet.list`
- `rpc::promptSnippet.get`

Acceptance:

- Each migrated read has schema metadata, authority metadata, visibility, and
  causal records.
- `MethodRegistry::dispatch` validates method existence and JSON depth, then
  lets `try_dispatch_generic_rpc` intercept `GenericTrigger` specs before the
  marker handler can run.
- `RpcGenericTriggerHandler` is only a loud marker; if it executes, registry
  interception failed.
- Direct engine invocation and JSON-RPC dispatch return identical payloads for
  all twelve reads, including stateful event and prompt-library reads.
- Handler-only methods and custom local test methods still pass through the
  current handler path, proving generic dispatch is opt-in by spec.
- The old thin/read handler structs and duplicated business logic are deleted
  for every method in the completed generic-trigger set.

## Phase 3.5: first delete-first mutating RPC migration

Move the first mutating RPC method group directly into generic-trigger engine
functions. This is the proof that the bridge is demolition scaffolding, not a
second backend.

Implemented generic-trigger writes:

- `rpc::promptSnippet.create`
- `rpc::promptSnippet.update`
- `rpc::promptSnippet.delete`

Semantics:

- migrated reads carry `rpc.read`; migrated writes carry `rpc.write`;
- prompt snippet writes use system-scoped engine-ledger idempotency because
  snippets are local global state rather than session-owned state;
- temporary JSON-RPC idempotency dedupes exact duplicate transports with a key
  derived from method, request id, and canonical payload; reused request ids
  with different payloads remain distinct commands;
- `promptSnippet.delete` remains an irreversible side-effect capability and
  carries approval-required authority metadata before system visibility.

Acceptance:

- Method registrations for the three prompt-snippet writes are generic-trigger
  markers only.
- The old `CreateSnippetHandler`, `UpdateSnippetHandler`, and
  `DeleteSnippetHandler` business handlers are deleted.
- Direct engine invocation and JSON-RPC dispatch return the same success/error
  payloads for representative prompt-snippet write cases.
- Duplicate create/update/delete transports replay through the engine ledger
  without rerunning the store mutation.

## Phase 4: catalog watch, streams, and event unification

Introduce engine streams while preserving WebSocket clients.

Deliverables:

- Catalog watch stream with subscription classes.
- Stream worker abstraction with cursor/subscription model.
- Session event stream backed by event ids.
- Job/tool-output stream adapter.
- Compatibility bridge from stream events to current WebSocket broadcasts.

Acceptance:

- Existing event broadcast tests pass.
- Stream tests cover subscribe, resume from cursor, disconnect, multiple
  subscribers, and catalog-change filtering.
- Agent turn lifecycle ordering remains unchanged.

## Phase 5: queue primitive

Create durable queue semantics before migrating agent/background workflows.

Deliverables:

- Queue worker with enqueue, receipt, status, cancellation, retry, and DLQ.
- Queue events/logs include invocation id, trace id, idempotency key, and
  effect metadata.
- Existing job manager can be adapted to queue-backed execution.

Acceptance:

- Unit tests for enqueue/dequeue, retry, cancellation, concurrency, DLQ, and
  duplicate idempotency keys.
- Integration tests for a queued background job and a queued no-op function.
- No public client behavior changes until compatibility path is proven.

## Phase 6: cron as triggers

Convert cron execution to trigger semantics while keeping current automation
definition files.

Deliverables:

- Cron trigger type.
- Adapter from `automations.json` job definitions to trigger registrations.
- Cron execution invokes engine functions with queue policy where appropriate.
- Run history remains in SQLite.

Acceptance:

- Existing cron tests pass.
- Tests cover shell/webhook/agent/system-event payloads through the trigger
  path.
- Misfire, overlap, retry, corrupt-row, idempotency, and causality invariants
  remain documented and tested.

## Phase 7: tools, MCP, approvals, and effects

Move tool invocation behind engine functions.

Deliverables:

- Tool worker registers built-in tool functions with effect class, risk,
  authority, and idempotency metadata.
- MCP worker preserves `mcp::search` and `mcp::call` meta-tool behavior.
- Approval/question/device flows become functions plus stream/device triggers.
- Tool executor invokes engine functions where migrated.

Acceptance:

- Existing tool unit tests pass.
- Agent can call migrated tools through the engine path.
- Approval-required tools preserve current client/device behavior.
- High-risk or non-idempotent functions are not autonomously agent-visible.

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

Add external worker protocol only after the in-process live catalog is proven.

Deliverables:

- Tron-owned JSON-over-WebSocket worker protocol.
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
