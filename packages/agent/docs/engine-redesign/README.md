# Tron-native live capability fabric

Status: exploration branch artifact.

Date: 2026-05-06.

Branch: `codex/iii-engine-redesign-exploration`.

## Thesis

Tron is not redesigning the server as a generic backend engine that agents
happen to use. Tron is redesigning the server as a live capability fabric where
agents are first-class participants.

The engine primitives are still worker, function, and trigger, but Tron gives
them agent-native semantics:

- A worker is a live actor with identity, authority, lifecycle, namespace
  ownership, and delegation rules.
- A function is a capability contract with schema, revision, effect class,
  authority, idempotency, risk, health, provenance, and visibility.
- A trigger is a causal rule that invokes a function under a specific
  authority, delivery mode, trace context, idempotency key, and loop policy.

The live catalog is the core product surface. Agents should be able to discover,
watch, invoke, create, test, and promote capabilities while the system is
running. The answer to safety is not hiding catalog churn from the model. The
answer is making every catalog change and every invocation authorized,
idempotent where needed, causally recorded, observable, and scoped.

## Design doctrine

- The catalog is always live. No frozen capability snapshot is the default.
- Live does not mean globally visible. Agent-created capabilities are
  session-live by default.
- Promotion from session visibility to workspace or system visibility is an
  explicit, auditable function call.
- Agents subscribe to catalog-change classes and decide which changes should
  interrupt or replan active work.
- Every mutating function must declare an idempotency contract before it can be
  agent-visible.
- Every invocation records actor, authority grant, trace id, parent invocation,
  catalog revision, function revision, trigger id, delivery mode, and
  idempotency key.
- Event sourcing remains the durable ledger. State is useful shared data, but
  it is not a replacement for session truth.

## First principles

The design starts from these truths, not from iii's implementation details:

- Agents are stochastic, long-running actors. The system must make their
  actions inspectable, attributable, interruptible, and bounded.
- Capabilities appear, disappear, and change while agents are working. Static
  tool lists are an optimization, not the ground truth.
- Retries, reconnects, crashes, and queue handoffs happen. Mutating effects
  must be idempotent or explicitly guarded.
- A schema describes payload shape, not authority, safety, cost, or effect.
  Policy must be a separate enforceable contract.
- Local-first software still has multiple actors: user, client, agent, worker,
  cron, queue, and system. Every action needs an actor and authority grant.
- Debugging agent systems requires causality, not log correlation. The engine
  must preserve parent/child relationships across every call and side effect.
- State and events serve different jobs. Mutable state helps coordination;
  append-only events explain what happened.

These truths imply the primitives. Workers identify live actors. Functions
describe capabilities and effects. Triggers describe causal rules. The engine
enforces policy and records the causal graph.

## Assumption discipline

The architecture must not depend on optimistic assumptions such as:

- workers are honest;
- function schemas are always accurate;
- topology is static during a turn;
- delivery is exactly once;
- retries are harmless;
- all useful capabilities fit in a prompt;
- global visibility is safe;
- logs alone are enough to reconstruct behavior;
- an agent-created worker should inherit the full authority of its parent.

Where the system cannot eliminate an uncertainty, it should encode the
uncertainty as metadata, policy, or an explicit promotion/approval step.

## Documents

- [iii comparison and Tron specialization](iii-teardown.md) explains what iii
  teaches, what Tron adopts, and where Tron intentionally diverges.
- [Tron capability matrix](tron-capability-matrix.md) inventories the current
  server and maps subsystems to live workers, functions, triggers, visibility,
  effects, idempotency, authority, and observability.
- [Target engine design](target-engine-design.md) specifies the agent-native
  capability fabric, causal ledger, catalog semantics, guardrails, and
  primitive contracts.
- [Migration strategy](migration-strategy.md) defines the incremental path from
  the current server to the live capability fabric.

## Source snapshot

iii sources analyzed:

- Documentation: <https://iii.dev/docs/quickstart> and linked architecture,
  discovery, trigger-action, schema, RBAC, sandbox, and worker pages listed in
  <https://iii.dev/docs/llms.txt>.
- Repository: <https://github.com/iii-hq/iii> at commit
  `3db657386a21a2b48b44a3f959c2b7e3fe7adf7a`.
- Local implementation comparison focused on iii `engine/src/protocol.rs`,
  `engine/src/function.rs`, `engine/src/trigger.rs`,
  `engine/src/engine/mod.rs`, `engine/src/invocation/mod.rs`,
  `engine/src/workers/worker/rbac_config.rs`, `engine/src/builtins/queue.rs`,
  and `engine/src/builtins/kv.rs`.

Tron sources analyzed:

- `packages/agent/src/main.rs`
- `packages/agent/src/lib.rs`
- `packages/agent/src/server/mod.rs`
- `packages/agent/src/server/app/server.rs`
- `packages/agent/src/server/rpc/handlers/mod.rs`
- `packages/agent/src/runtime/mod.rs`
- `packages/agent/src/runtime/agent/mod.rs`
- `packages/agent/src/runtime/orchestrator/mod.rs`
- `packages/agent/src/tool_factory.rs`
- `packages/agent/src/tools/mod.rs`
- `packages/agent/src/mcp/mod.rs`
- `packages/agent/src/cron/mod.rs`
- `packages/agent/src/events/mod.rs`
- `packages/agent/src/events/types/generated.rs`
- `packages/agent/src/settings/types/mod.rs`

Local runtime facts sampled directly from `~/.tron/internal/database/log.db`:

- Tables: `sessions`, `events`, `blobs`, `branches`, `logs`,
  `device_tokens`, `notification_read_state`, `cron_jobs`, `cron_runs`,
  `prompt_history`, `prompt_snippets`, `workspaces`, and `schema_version`.
- High-traffic event types at the time of sampling were session, message,
  stream, tool, hook, notification, config, worktree, and metadata events.

## Phase 1 implication

The first code phase should not be a plain registry. It should be the smallest
in-process expression of the live capability fabric:

- catalog revisions and catalog-change events from day one;
- causal context and actor/authority metadata on invocations;
- owner-tracked workers, functions, trigger types, and triggers;
- function metadata for effect class, risk, visibility, idempotency, health,
  provenance, and revision;
- async sync-call invocation first, with queues, streams, approval, and local
  external workers added once the host/ledger invariants were stable;
- no broad tool, runtime, or client rewrite yet; RPC migration begins only
  with classified compatibility functions and low-risk read adapters that keep
  existing wire payloads stable.

That keeps Phase 1 small while encoding the invariants that make later
self-modifying agent workflows safe and debuggable.

## Phase 1 source map

The in-repo implementation lives in `packages/agent/src/engine/`. The module
proved the live fabric contracts before migration, then became server-owned
infrastructure. Current work has moved beyond RPC bridge scaffolding: agents
now have live engine tools, canonical domain functions are the executable
surface for migrated methods, and stream/state/queue primitives exist as
first-class workers.

- `ids.rs` defines validated IDs for workers, functions, triggers, invocations,
  actors, authority grants, and traces.
- `types.rs` defines worker/function/trigger metadata, revisions, visibility,
  effect classes, idempotency, authority, provenance, health, schemas, and
  catalog-change records. Catalog changes now carry subject kind, change
  class, visibility, and scope metadata so cursor watch can filter historical
  changes without leaking session/internal capabilities.
- `host.rs` owns the first agent-facing `EngineHost` boundary and cloneable
  `EngineHostHandle`. It bootstraps the reserved system `engine` worker,
  registers privileged `engine::*` meta-capabilities as real catalog functions,
  derives a sibling `engine-ledger.sqlite` path from the resolved event DB, and
  executes live discovery, scoped inspection, cursor watch, delegated
  invocation, and promotion without exposing those built-ins to ordinary worker
  replacement. The handle is now the adapter boundary: it prepares invocation
  policy/idempotency/schema under lock, executes in-process handlers outside
  the host lock, catches panics as structured errors, and finishes ledger
  records under lock.
- `ledger.rs` defines the pluggable engine-ledger boundary plus in-memory and
  isolated SQLite implementations for catalog-change audit records,
  invocation records, and idempotency reservations/results. Its SQLite schema
  is initialized by the adapter and is not wired into the production
  event-store migration yet.
- `registry.rs` owns the in-memory `LiveCatalog`, deterministic discovery,
  owner-checked registration, volatile cleanup, catalog revisions, and
  in-process sync invocation. It writes catalog changes, invocation attempts,
  and idempotency reservations/results through the ledger store while keeping
  catalog definitions volatile. Discovery stays live but scope-gated: session
  and workspace capabilities require matching actor context, and internal
  entries require an admin/system query.
- `policy.rs` holds non-bypassable checks for mutating function idempotency,
  irreversible effects, trigger target revisions, delivery modes, authority
  scopes, health, and invocation idempotency keys. Invocation also re-checks
  visibility so a hidden function cannot be called just because its id is known.
- `invocation.rs` carries actor, authority grant, trace, parent invocation,
  trigger, catalog revision, delivery mode, and idempotency context across each
  call, plus the invocation record shape stored by the engine ledger.
- `schema.rs` enforces a deliberately small JSON-schema subset for request and
  response payloads: `type`, `required`, `properties`, `additionalProperties`,
  `items`, `maxItems`, and `enum`.
- `triggers.rs` defines the first in-process trigger runtime. It dispatches
  registered `json_rpc` and `manual` trigger definitions through
  `EngineHostHandle`, preserving trigger id, delivery mode, actor, authority,
  trace, parent invocation, session/workspace scope, and idempotency context in
  the invocation ledger. Dispatch failures before normal target execution are
  recorded too, so missing triggers, delivery mismatches, stale targets,
  schema/policy failures, and idempotency conflicts are causally visible.
  `DeliveryMode::Enqueue` now stores a durable queue receipt and the queue
  drain runtime replays the original trace/authority/idempotency context when
  invoking the target later.
- `streams.rs`, `state.rs`, and `queue.rs` define the first primitive workers:
  cursor-pull streams, scoped revisioned state, and at-least-once queues with
  leases, retry, cancellation, and dead-letter status. Each has in-memory and
  SQLite-backed stores initialized in the isolated engine ledger database.
- `capabilities.rs` defines `AgentCapabilityClient`, the typed agent-facing
  adapter for live discover/inspect/watch/invoke/manual-dispatch flows. Agent
  tools use this client and refuse `rpc::*` compatibility ids.
- `protocol.rs` and `external.rs` define the loopback-only external worker
  contract/runtime for hello, catalog snapshot, session-default
  function/trigger registration, invoke/result, catalog change, heartbeat, and
  disconnect cleanup. The server now exposes the local `/engine/workers`
  WebSocket endpoint for authenticated loopback workers, and registered
  functions receive executable proxy handlers over that socket; sandbox and
  remote worker hosting remain deferred.
- `tests.rs` encodes the Phase 1 invariants directly so later migrations extend
  behavior from a tested core instead of replacing assumptions.
- `server/rpc/engine_bridge.rs` plus `server/rpc/engine_bridge/*` are the first
  production adapter surface. They register the transport-only `rpc`
  compatibility worker, domain-owned in-process workers, canonical domain
  functions for migrated methods, non-routable `rpc::<method>` metadata for
  handler-only inventory, the `json_rpc` and `manual` trigger types, and
  `json_rpc` trigger bindings from legacy method names into canonical targets.
  Handler-only methods remain internal/non-routable until their behavior moves.
  Prompt library, settings, logs, skills, notifications, plan, approval
  get/list/resolve, events, basic filesystem, safe session reads, safe context
  reads, job controls, and agent status/abort/submission controls are
  generic-triggered. Migrated writes use `rpc.write`, strict schemas, domain
  write scopes, and scoped engine-ledger idempotency;
  superseded method-specific business handlers are deleted as each group
  migrates.
- `tools/engine` adds first-party agent tools: `engine_discover`,
  `engine_inspect`, `engine_watch`, and `engine_invoke`. These are stable
  meta-tools over the live canonical catalog; they do not expose frozen tool
  snapshots or `rpc::*` compatibility names as the agent surface.

## Phase 1 acceptance checklist

Implemented:

- live catalog revisions and catalog-change records for worker/function/trigger
  registration, cleanup, and visibility promotion;
- owner-checked worker, function, trigger type, and trigger registration;
- deterministic live discovery plus scoped inspect APIs;
- `EngineHost` and privileged `engine::discover`, `engine::inspect`,
  `engine::watch`, `engine::invoke`, and `engine::promote` meta-capabilities;
- reserved `engine` namespace enforcement so ordinary workers cannot spoof or
  overwrite engine built-ins;
- function visibility enforcement at both discovery and invocation time;
- in-process sync invocation with structured success/error results;
- invocation ledger records for every attempt, including missing functions,
  policy failures, schema failures, handler failures, idempotency replays, and
  successes;
- pluggable engine-ledger storage for invocation records, catalog-change audit
  records, and idempotency reservations/results;
- idempotency contracts for mutating functions, including session/workspace
  scope validation, canonical payload fingerprinting, fail-closed pre-handler
  reservation, replay after catalog recreation, handler-error replay without
  reinvocation, `ReturnPrevious`, `Reject`, and `NoOp` replay behavior;
- request/response schema validation for the supported Phase 1 subset;
- explicit session-to-workspace/system promotion with owner checks and audit
  catalog changes, including scoped idempotency replay for duplicate promotion
  attempts;
- cursor-based catalog watch with class/kind/prefix/owner filters, scope-aware
  historical visibility, bounded limits, and SQLite reopen coverage;
- delegated invocation through `engine::invoke`, preserving parent invocation,
  trace, actor, authority, target revision, schema, visibility, health, and
  target idempotency checks;
- fail-closed catalog registration/promotion paths that write durable
  catalog-change records before mutating live definitions;
- server-owned `EngineHostHandle` startup using a SQLite engine ledger beside
  the resolved event-store database, with test contexts defaulting to an
  in-memory host;
- intent-shaped `EngineHostHandle` registration, discovery, inspect, watch,
  promote, and invoke methods so production adapters do not take the raw host
  mutex;
- direct function invocation and `engine::invoke` delegated child invocation
  that do not hold the host lock while handler futures run, including
  structured panic capture and idempotency completion for success, handler
  error, and panic paths;
- RPC migration bridge specs for every current RPC method, with drift guards
  that fail if a method is registered without classification;
- first generic-triggered read RPC functions for `system.ping`,
  `system.getInfo`, `settings.get`, `model.list`, `skill.list`, `logs.recent`,
  `events.getHistory`, `events.getSince`, `filesystem.getHome`,
  `promptHistory.list`, `promptSnippet.list`, and `promptSnippet.get`, with
  tests proving direct engine invocation and JSON-RPC dispatch return the same
  wire payloads;
- first generic-triggered write RPC functions for `promptSnippet.create`,
  `promptSnippet.update`, and `promptSnippet.delete`; these use `rpc.write`,
  `prompt_library.write`, strict schemas, system-scoped engine-ledger
  idempotency, and exact-duplicate JSON-RPC transport dedupe while deleting the
  old prompt-snippet write handlers;
- full prompt-library collapse: `promptHistory.delete` and
  `promptHistory.clear` now join the generic-trigger path with `rpc.write`,
  `prompt_library.write`, strict schemas, system-scoped engine-ledger
  idempotency, approval metadata for irreversible effects, and tests proving
  generic-trigger registrations are marker-only;
- full settings collapse: `settings.update` and `settings.resetToDefaults` now
  join `settings.get` on the generic-trigger path with strict schemas,
  `rpc.write`, `settings.write`, system-scoped engine-ledger idempotency,
  approval metadata for high-risk reversible configuration effects, and tests
  proving duplicate transports do not rerun disk writes or reload side effects;
- full logs collapse: `logs.ingest` now joins `logs.recent` on the
  generic-trigger path with strict schemas, `rpc.write`, `logs.write`,
  append-only effect metadata, system-scoped engine-ledger idempotency, and
  tests proving duplicate transports replay without reopening the log-ingest DB
  transaction;
- agent-native engine tools over `AgentCapabilityClient`, giving agents live
  discovery, inspection, cursor watch, and direct canonical invocation while
  enforcing explicit idempotency for writes and approval-required errors for
  high-risk capabilities;
- stream, state, and queue primitive workers, with in-memory and SQLite-backed
  stores, scoped visibility, idempotent mutations, cursor-pull stream polling,
  compare-and-set state revisions, queue leases/retries/cancellation/DLQ, and
  enqueue-trigger dispatch that preserves original causality when drained;
- full events collapse: `events.subscribe` and `events.unsubscribe` now join
  history/since/append on the canonical `events::*` path, backed by stream
  subscription records while preserving current JSON-RPC acknowledgement
  payloads;
- basic filesystem collapse: `filesystem.createDir` now joins home/list/read
  on the canonical `filesystem::*` path with strict schema, `rpc.write`,
  `filesystem.write`, engine-ledger idempotency, and current path/error
  behavior preserved through the existing filesystem service;
- session command/read collapse: `session.create/delete/fork/archive/
  unarchive/archiveOlderThan/export` now join
  `session.list/getHead/getState/getHistory/reconstruct` on canonical
  `session::*` functions; `session.resume` remains handler-owned because it is
  still tied to transport/session lifecycle;
- context command/read collapse:
  `context.getSnapshot/getDetailedSnapshot/getAuditTrace/shouldCompact/
  previewCompaction/canAcceptTurn/confirmCompaction/clear/compact` are now
  canonical `context::*` functions with approval metadata on high-risk effects;
- job collapse: `job.background/cancel/list/subscribe/unsubscribe` are
  canonical `job::*` functions; background/cancel enqueue hidden internal
  apply functions, synchronously drain their own receipt for current JSON-RPC
  compatibility, publish job/queue stream events, and use engine-ledger
  idempotency;
- agent command collapse: `agent.prompt/status/abort/abortTool/queuePrompt/
  dequeuePrompt/clearQueue/deliverSubagentResults/submitConfirmation/
  submitAnswers` are canonical `agent::*` functions with strict schemas,
  session-scoped idempotency for writes, approval metadata where high risk, and
  stream publication for queue/prompt state; `agent.prompt` now enqueues hidden
  `agent::prompt_apply` and prompt completion enqueues hidden
  `agent::prompt_queue_drain`;
- approval runtime: `approval::request/resolve/get/list` records high-risk
  agent-visible pauses in the engine ledger, publishes scoped approval stream
  events, and resumes approved invocations with their original trace/authority/
  parent/idempotency context; agents can request approvals but resolution is
  reserved for system/admin or user-authorized actors;
- approval RPC transport: `approval.get`, `approval.list`, and
  `approval.resolve` are additive JSON-RPC trigger bindings over the existing
  `approval::*` primitive functions; `approval.request` intentionally remains
  agent/tool-only;
- server runtime services: `EngineRuntimeServices` starts queue drainers for
  `default`, `jobs`, and `agent` plus a stream pump for approvals, jobs, agent queue,
  session events, and catalog topics so engine primitives drive runtime
  behavior instead of staying test-only stores;
- `RpcEngineInvocation` envelopes that preserve request id, method, params,
  canonical domain function id, actor `rpc-client`, authority grant
  `rpc-bridge`, transport read/write authority scope, domain authority scope,
  trace id, optional idempotency key, and optional session/workspace scope
  extracted from params;
- cleanup of triggers that target an unregistered function.

Still deferred:

- RPC migrations and generic-trigger conversion for the remaining handler-only
  method groups beyond prompt library, settings, logs, skills, notifications,
  plan, events, basic filesystem, session commands/reads except resume, context
  commands/reads, job controls, and current agent controls;
- runtime/client-native cutover beyond the first agent engine tools and RPC
  adapters;
- stream-first token/text turn delivery beyond the existing compatibility
  EventBridge;
- sandbox workers, remote worker hosting, durable reconnect semantics, and
  stronger executable-worker supervision beyond the authenticated local
  loopback endpoint;
- trigger firing/runtime loop detection;
- reconstruction of live catalog definitions from durable ledger state.

## iii reuse note

The current Work Package 2 implementation is heavily informed by iii but does
not copy substantial iii source verbatim. Useful patterns retained from iii
include explicit protocol/result shapes, live registry ownership, trigger
action vocabulary, registration cleanup, RBAC-as-policy inspiration, and trace
context as an invocation concern. Tron intentionally diverges by making
idempotency metadata mandatory for mutating functions, reserving idempotency
keys before handler execution, storing stable error projections instead of raw
Rust enum internals, and keeping agent-created capability visibility scoped
until explicit promotion.

If a later package copies iii engine code directly, keep the source path,
commit, license, and Tron modification note beside the adapted code or in this
directory. iii `engine/` is Elastic License 2.0; SDK/docs/console material is
Apache-2.0.
