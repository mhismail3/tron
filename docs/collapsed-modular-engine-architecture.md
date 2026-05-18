# Collapsed Modular Engine Architecture

This document is the implementation target for the post-mobile-first Tron
engine. The architecture collapses agent coordination, artifacts, generated UI,
and module control into one substrate:

- **Workers** run.
- **Capabilities** do work.
- **Resources** hold durable objects.
- **Invocations** record execution.
- **Grants** bound authority.
- **Events** make the substrate observable.

The goal is to keep Tron modular without creating separate persistence planes
for artifacts, goals, work items, UI surfaces, and control-plane state.

## Invariants

- Every executable path is a canonical `namespace::function` capability owned
  by one worker.
- Every durable agent output is a typed resource or a resource version.
- Every mutating capability requires idempotency.
- Shared resource mutation uses compare-and-set, a resource lease, or a merge
  proposal capability.
- Child workers receive grants narrower than their parent invocation.
- Control-plane screens are projections over catalog, invocation, grant,
  resource, queue, approval, lease, storage, and stream records.
- Generated UI is declarative resource data. UI actions resolve to canonical
  capabilities or audited user-response invocations.
- Old mobile-session-manager routes, compatibility readers, aliases, and
  product-shell fallback renderers are not part of the target runtime.

## Primitive Model

### Worker

A worker is any runnable actor: first-party Rust module, local model agent,
coordinator agent, spawned subagent, sandbox process, MCP adapter, iOS client,
or system service. Workers own namespace claims and register capabilities.
Worker tokens bound visibility, authority, trust tier, session/workspace scope,
expiry, and namespace claims.

### Capability

A capability is the only executable operation. Its contract declares request and
response schemas, effect class, risk, authority requirement, idempotency,
resource lease requirements, compensation notes, and stream topics. Higher-level
behavior composes capabilities rather than calling private handlers.

### Resource

A resource is the durable object model. Resource kinds include:

- `artifact`
- `goal`
- `claim`
- `evidence`
- `decision`
- `ui_surface`
- `module_config`
- `worker_package`
- `secret_ref`
- `materialized_file`

The generic resource kernel is implemented by the engine tables:

- `engine_resource_type_definitions`
- `engine_resources`
- `engine_resource_versions`
- `engine_resource_links`
- `engine_resource_events`

Each type definition declares the kind name, schema id, JSON schema, lifecycle
states, versioning mode, allowed link relations, retention policy, redaction
rules, materialization rules, and required capabilities for operations.

### Invocation

An invocation records one capability call. It carries actor, worker, parent/root
invocation, scope, trace, catalog revision, idempotency key, leases, approvals,
result/error, and produced resource refs. A coordinator/subagent tree is an
invocation tree plus worker lifecycle records.

### Grant

A grant is scoped authority delegated to a worker or invocation. The target
grant model includes allowed capabilities, resource kinds/selectors, max risk,
file roots, network policy, output policy, budget, expiry, delegation rules, and
approval requirements. Until the full grant model lands, existing authority
scopes and worker-token ceilings remain the enforcement surface.

### Event

Events are append-only facts. Streams, state tables, local indexes, iOS caches,
and control-plane summaries are projections that must be rebuildable from the
catalog ledger, invocation ledger, resource store, and stream history.

## Resource Kernel

The first implementation slice adds `resource::*` primitive capabilities:

- `resource::register_type`
- `resource::create`
- `resource::update`
- `resource::link`
- `resource::inspect`
- `resource::list`

This is intentionally generic. Artifact, goal, claim, evidence, decision, and
UI-specific modules should register resource type definitions and then compose
the resource capabilities rather than creating separate stores.

Type registration is an admin-visible capability. Resource payloads are
validated against the registered type schema before create or update persists
any resource/version rows.

Resource writes are compare-and-set protected through `expectedCurrentVersionId`.
If the current version differs, the update fails before writing a new version.
This is the base concurrency invariant for multi-agent artifact work.

## Artifact And Goal Mapping

Artifacts are `Resource(kind = "artifact")`. Artifact operations such as
create, append, split, compose, promote, discard, materialize, and search should
be implemented as module capabilities that use the generic resource kernel.

Goals are `Resource(kind = "goal")`. Subgoals, claims, evidence, and decisions
are typed resources linked to the goal. Coordinators should return promoted
resource refs and decision resources rather than loose transcript blobs.

## Control Plane

The control plane is not a separate database. It reads and mutates the substrate
through capabilities:

- catalog workers/functions/triggers
- resource type definitions and resources
- invocation trees
- queues and leases
- approvals and compensation records
- storage stats
- generated UI surface resources

Control actions such as inspect, enable, disable, pause, stop, approve, discard,
archive, and promote must be normal capabilities.

## Security

- Unknown resource kinds are rejected until a worker registers a type
  definition.
- Unknown lifecycle states and link relations are rejected.
- Resource updates require current-version compare-and-set.
- Large resource payloads use blob-backed storage refs through the unified
  storage layer.
- Secret values must not be stored as normal artifact/resource payloads. Store
  vault handles or redacted `secret_ref` resources instead.
- Generated UI cannot execute code or call arbitrary endpoints. Actions route
  back through canonical capabilities.

## Clean-Break Cutover

The target architecture does not include runtime compatibility with old
mobile-first session-manager state. A future cutover should bump the storage
generation, archive/export old data before startup, remove legacy routes and
DTOs, and fail CI on references to retired capability names or product-shell
event reconstruction.

This initial resource-kernel slice is additive so it can be verified safely
before the destructive cutover is performed.
