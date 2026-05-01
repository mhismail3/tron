# iii comparison and Tron specialization

This document records how iii informs the Tron redesign and where Tron should
specialize the model for agent-native local autonomy.

## License boundary

The iii repository separates licenses by area. The engine is under Elastic
License 2.0, while SDKs, console, and docs are Apache-2.0. Tron is local-only,
so this exploration may copy or adapt iii implementation where doing so
materially improves the design. Any substantial adaptation should preserve
license/provenance notes: source path, iii commit, license, what changed for
Tron, and why the result is still local-agent-safe.

The useful artifact is the primitive model: a small set of runtime concepts
that collapse backend categories into one live system. Even when code is copied
or closely adapted, Tron should specialize the model with its own local-first
persistence, settings, auth, clients, event store, agent runtime, authority
model, idempotency rules, and guardrails.

## Comparison method

iii is evidence that a small worker/function/trigger model can collapse many
backend categories. It is not proof that Tron should inherit every behavior
unchanged.

Tron evaluates each iii idea against first principles:

- Does it help agents discover and use live capabilities?
- Does it preserve actor identity, authority, and causality?
- Does it make side effects idempotent or guarded?
- Does it keep visibility scoped until promotion is justified?
- Does it reduce special-case backend code instead of adding another layer?
- Does it work in Tron's local-first daemon with SQLite events, paired clients,
  skills, MCP, worktrees, and user-controlled settings?

If an iii mechanism is useful but too general, Tron should specialize it rather
than copy it.

## What iii gets right

iii's most important idea is that backend components and agent harness
components can share the same primitives:

| iii primitive | Reference behavior | Tron interpretation |
|---------------|--------------------|---------------------|
| Worker | Any process that connects to the engine and registers functions/triggers. | Any live actor: daemon module, agent, sandbox, browser, client, MCP bridge, cron scheduler, queue, stream, or temporary worker created by another agent. |
| Function | Stable callable unit with optional schema metadata. | Capability contract with schema, revision, authority, effect class, idempotency, risk, health, provenance, and visibility. |
| Trigger | Declarative entrypoint that causes a function to run. | Causal rule with delivery policy, authority, trace context, loop controls, and idempotency controls. |

iii also demonstrates several mechanics Tron should preserve:

- live discovery through engine functions such as function/worker/trigger
  listings;
- topology-change notifications when functions or workers appear/disappear;
- explicit trigger actions: sync, void, and enqueue;
- schema metadata as a machine-readable contract for agents, CLIs, and other
  workers;
- RBAC and registration prefixing at worker connection boundaries;
- sandbox workers that participate in the same worker/function/trigger model
  as ordinary services;
- trace propagation across worker and queue boundaries.

## Where Tron diverges

iii is general-purpose backend infrastructure. Tron should be purpose-built for
agent autonomy.

| Area | iii baseline | Tron specialization |
|------|--------------|---------------------|
| Discovery | Every worker can read the live registry and receive topology notifications. | The live catalog is the agent's primary substrate. Agents get stable meta-capabilities for discover/search/inspect/invoke/watch/spawn, and the underlying catalog changes while the agent runs. |
| Visibility | Registry availability is mostly a worker/RBAC concern. | Visibility is scoped: session, workspace, system, client, worker, admin. Agent-created capabilities default to session visibility. |
| Self-modification | Sandboxes and workers can be added live. | Agents can create session-scoped workers/functions, test them immediately, then request explicit promotion to wider visibility. |
| Idempotency | Queue retries make delivery concerns visible. | Every mutating agent-visible function must declare an idempotency contract before invocation is allowed. |
| Causality | Trace context propagates through invocations. | Every catalog mutation, trigger fire, invocation, retry, approval, state write, and worker spawn belongs to a durable causal graph. |
| Guardrails | RBAC and middleware can filter access. | Guardrails are native invocation policy: schema validation, authority checks, approval triggers, budgets, causal-depth limits, loop detection, namespace ownership, provenance, and health checks. |
| Agent context | Discovery can inform agents. | Discovery is a live action surface, not a static prompt dump. Catalog search/ranking/views prevent context explosion. |

## Live discovery

iii treats discovery as part of the engine rather than a sidecar service. The
same registry powers read APIs and topology notifications. Tron should adopt
that model but make it richer for agents.

Tron discovery should expose:

- current catalog revision;
- function id, description, schema, revision, visibility, owner, health, risk,
  effect class, idempotency contract, and authority requirements;
- worker lifecycle state and provenance;
- trigger definitions and delivery semantics;
- catalog-change streams with change classes agents can subscribe to.

The live catalog should not be frozen for an agent turn. Instead, agents should
use stable meta-capabilities:

- `engine::capabilities::search`
- `engine::capabilities::inspect`
- `engine::capabilities::invoke`
- `engine::catalog::watch`
- `engine::workers::spawn`
- `engine::capabilities::promote`

Those stable calls keep the LLM provider interface small while allowing the
underlying capability set to change at runtime.

## Trigger actions and delivery

iii distinguishes sync, void, and enqueue actions. Tron should preserve the
three modes but attach stricter causal and idempotency semantics.

| Action | Tron contract |
|--------|---------------|
| Sync | Caller waits for result or structured error. Used for reads, validation, discovery, and short deterministic operations. |
| Void | Best-effort dispatch with no retry. Allowed only for explicitly loss-tolerant effects such as non-critical telemetry. Still records causality. |
| Enqueue | Durable at-least-once delivery. Requires idempotency for mutating functions and records receipt, retry, and DLQ history in the causal ledger. |

For agents, the key policy is simple: durable or mutating work cannot be
agent-visible without an idempotency contract.

## Schemas and capability contracts

iii stores request/response formats so callers can construct payloads without
guessing. Tron should go further for agent-visible functions.

An agent-visible function needs:

- request schema;
- response schema or explicit opaque response marker;
- effect class;
- idempotency contract;
- authority requirements;
- risk level;
- revision;
- owner;
- visibility scope;
- health state;
- provenance metadata.

Schemas are not sufficient as guardrails. They describe shape. The engine must
also enforce authority, idempotency, risk, visibility, and loop policy before
invocation.

## RBAC, namespace ownership, and delegation

iii's worker RBAC can authenticate workers, restrict exposed functions, restrict
trigger registration, and prefix function registration. Tron should use the
same idea but model it as authority delegation.

Authority should answer:

- Who is the actor?
- Which grant is being used?
- Who delegated the grant?
- Which namespaces can be registered?
- Which functions can be invoked?
- Which trigger types can be registered?
- Which visibility scopes can be requested?
- Which effects require approval?

Agent-created workers should inherit narrowed authority, not the full authority
of the parent. Delegation should be explicit, revocable, and visible in the
causal graph.

## Sandbox workers and self-modification

iii's sandbox model shows why "anything is a worker" matters: a worker can
create another isolated worker, and that worker can register capabilities into
the same live system.

Tron should use this pattern for self-modification, but with stricter defaults:

1. Agent requests a worker under a session-scoped namespace.
2. Engine creates the worker with a narrowed authority grant.
3. Worker registers session-visible functions.
4. Engine emits catalog-change events.
5. Agent receives relevant catalog changes through its subscription.
6. Agent inspects schemas, runs tests, invokes functions, and records evidence.
7. Promotion to workspace/system visibility is an explicit governed function
   call.

This preserves the recursive power of the iii model while keeping blast radius
small.

## What Tron should adopt

- Worker/function/trigger as the universal primitives.
- Live discovery and topology notifications.
- Sync, void, and enqueue delivery modes.
- Schema metadata in discovery.
- Owner-tracked registration and cleanup.
- RBAC-like worker authorization and namespace prefixing.
- Sandboxed workers as ordinary live workers.
- Trace propagation across calls, queues, and worker boundaries.

## What Tron should add

- Agent-native stable meta-capabilities over the live catalog.
- Session-live default visibility for agent-created capabilities.
- Explicit promotion workflow for wider visibility.
- Required idempotency contracts for mutating agent-visible functions.
- Effect classes and risk levels as first-class function metadata.
- Catalog revisions and catalog-change classes.
- Causal ledger records for every action and catalog mutation.
- Delegated authority grants for spawned workers and subagents.
- Loop detection and budget policy for trigger cascades.

## What Tron should avoid

- Direct iii engine dependency or copied engine code.
- Treating discovery as a static prompt expansion.
- Making all new functions globally visible by default.
- Letting schema metadata stand in for authority or safety policy.
- Exposing mutating functions to agents without idempotency.
- Allowing agent-created workers before authority, namespace, provenance, and
  audit policy exist.
- Depending on exactly-once delivery, stable topology, or worker honesty.
