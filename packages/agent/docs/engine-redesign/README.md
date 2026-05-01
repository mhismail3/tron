# Tron-native live capability fabric

Status: exploration branch artifact.

Date: 2026-04-30.

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
  `9eaf3737e8a5e86d12039d067f76bc208eb39def`
  (`fix(website): restore cleanUrls so /manifesto resolves to manifesto.html (#1579)`).

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

Local runtime facts sampled directly from `~/.tron/system/database/log.db`:

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
- async sync-call invocation only, with queue/void/external workers deferred;
- no RPC, tool, runtime, or client behavior changes yet.

That keeps Phase 1 small while encoding the invariants that make later
self-modifying agent workflows safe and debuggable.

## Phase 1 source map

The first in-repo implementation lives in `packages/agent/src/engine/` and is
deliberately isolated from production RPC, tools, runtime orchestration, and
client traffic. The module proves the live fabric contracts before any existing
workflow is migrated:

- `ids.rs` defines validated IDs for workers, functions, triggers, invocations,
  actors, authority grants, and traces.
- `types.rs` defines worker/function/trigger metadata, revisions, visibility,
  effect classes, idempotency, authority, provenance, health, and catalog-change
  records.
- `registry.rs` owns the in-memory `LiveCatalog`, deterministic discovery,
  owner-checked registration, volatile cleanup, catalog revisions, and
  in-process sync invocation. Discovery stays live but scope-gated: session and
  workspace capabilities require matching actor context, and internal entries
  require an admin/system query.
- `policy.rs` holds non-bypassable checks for mutating function idempotency,
  irreversible effects, trigger target revisions, delivery modes, authority
  scopes, health, and invocation idempotency keys. Invocation also re-checks
  visibility so a hidden function cannot be called just because its id is known.
- `invocation.rs` carries actor, authority grant, trace, parent invocation,
  trigger, catalog revision, delivery mode, and idempotency context across each
  call.
- `tests.rs` encodes the Phase 1 invariants directly so later migrations extend
  behavior from a tested core instead of replacing assumptions.
