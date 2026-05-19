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

The cleanup proof map for removing fixed product-shell code and consolidating
recent substrate additions lives in `docs/modular-engine-cleanup-audit.md`.

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
  capabilities through the audited `ui::submit_action` gateway; clients never
  submit arbitrary target function ids or payload templates.
- Old mobile-session-manager routes, compatibility readers, aliases, and
  product-shell compatibility renderers are not part of the target runtime.

## Primitive Model

### Worker

A worker is any runnable actor: first-party Rust module, local model agent,
coordinator agent, spawned subagent, sandbox process, MCP adapter, iOS client,
or system service. Workers own namespace claims and register capabilities.
Worker tokens bind visibility, trust tier, session/workspace scope, expiry,
namespace claims, authority grant id/revision/hash, and resource selectors.
The engine resolves the stored grant before registration or invocation.

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
- `activation_record`
- `secret_ref`
- `materialized_file`
- `patch_proposal`
- `execution_output`
- `agent_result`

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
grant model is now implemented by `engine_grants` and `engine_grant_events`.
Grants include parent id, subject actor/worker/invocation, lifecycle, allowed
capabilities/namespaces/authority labels, resource kinds/selectors, file roots,
network policy, max risk, budget, expiry, delegation rules, approval
requirements, provenance, trace, and revision. Invocation prepare resolves
`authority_grant_id` to this stored record before handler execution. Raw
caller-supplied scope arrays are audit context only.

### Event

Events are append-only facts. Streams, state tables, local indexes, iOS caches,
and control-plane summaries are projections that must be rebuildable from the
catalog ledger, invocation ledger, resource store, and stream history.

## Secure Substrate Slice

The secure substrate slice adds:

- `grant::derive`
- `grant::inspect`
- `grant::list`
- `grant::revoke`

Child grants must be narrower than the parent across capability, namespace,
authority label, resource kind, resource selector, file root, network, risk,
expiry, delegation, and approval policy. Worker registration rejects namespace
claims and functions that exceed the worker's grant.

The resource kernel provides:

- `resource::register_type`
- `resource::create`
- `resource::update`
- `resource::link`
- `resource::inspect`
- `resource::list`

The engine registers first-party resource type definitions for `artifact`,
`goal`, `claim`, `evidence`, `decision`, `worker_package`, `module_config`,
and `activation_record` at primitive-store startup. Thin wrappers compose the
generic resource store:

- `artifact::create`, `artifact::update`, `artifact::promote`,
  `artifact::discard`, `artifact::inspect`, `artifact::split`,
  `artifact::compose`, `artifact::merge`, `artifact::search`
- `goal::create`, `goal::complete`, `goal::working_set`
- `claim::attach`
- `evidence::attach`
- `decision::create`

These wrappers are convenience capabilities only. They do not create separate
stores.

## Module Package Lifecycle

Plug-and-play modules are not a separate persistence plane. A module is a
validated package resource, a config resource, an activation record, derived
grants, and worker/capability catalog records.

The first-party `module` primitive exposes:

- `module::register_package` for digest/provenance/namespace/capability/config
  validation and source-trust field normalization before `worker_package`
  persistence;
- `module::inspect_package` as the read projection over package/config/
  activation/source-policy resources;
- `module::configure` for config-schema validation and `secret_ref`-only
  secret handling before `module_config` persistence;
- `module::verify_source` for resource-backed package source evidence over
  package digest, provenance, materialized file refs/hashes, and redaction;
  explicit signature material fails closed until local trust roots and signature
  verification are added;
- `module::approve_source` and `module::revoke_source_approval` for scoped
  operator `decision` resources that approve or revoke local digest-pinned
  package sources by package digest/version/scope, trust ceiling, grant ceiling,
  file/network bounds, and expiry;
- `module::policy_decide` as a pure read projection over package source
  evidence, approval decisions, requested child grants, and conformance refs;
- `module::run_conformance` for bounded package/config/activation conformance
  evidence over manifest rules, grant simulation, registration bounds,
  resource-output contracts, health policy, redaction, and cleanup behavior;
- `module::activate` for validating package/config refs, deriving or obtaining
  the narrower activation grant, binding existing/built-in workers, launching
  `local_process` packages only through a child `worker::spawn` invocation,
  enforcing source policy, validating registered worker capabilities against the
  package manifest and grant ceiling, and creating an `activation_record`;
- `module::disable`, `module::upgrade`, `module::rollback`, and
  `module::quarantine` as explicit idempotent lifecycle capabilities. Upgrade
  is a replacement operation: it names the current activation, validates and
  starts the replacement, persists the new activation version, then revokes the
  superseded grant. Disable and quarantine disconnect volatile workers through
  the canonical worker lifecycle and revoke grants; non-volatile workers remain
  catalog-visible but lose activation authority;
- `module::check_health` for resource-backed activation health evidence using
  either catalog/heartbeat inspection or a manifest-declared read-only health
  function under the activation grant;
- `module::verify_integrity` for package/config/activation evidence over
  manifest digest, materialized file hashes, config validation hash, grant
  lifecycle/hash, worker registration bounds, namespace, visibility, risk,
  file/network policy, and redaction invariants;
- `module::recover_activation` for cleanup-only recovery of incomplete or
  unsafe activation state. Recovery reconstructs truth from invocation, grant,
  worker, and resource records, revokes leaked derived grants, disconnects
  volatile workers through canonical lifecycle APIs, and persists
  failed/quarantined activation evidence. It does not spawn replacements,
  upgrade packages, or multiplex arbitrary operator actions.

`local_process` package manifests are digest-pinned to `materialized_file`
resource refs. The runtime entrypoint declares command and args templates,
expected function ids, working-directory policy, environment policy, visibility,
timeout, and executable refs. Activation verifies those refs and hashes and
requires valid source verification plus an unexpired scoped source approval
before invoking `worker::spawn`; module code never starts or kills processes
directly.
The resulting `activation_record` stores `spawnInvocationId`, `spawnResult`,
`healthResult`, `healthEvidenceRef`, `healthInvocationIds`,
`integrityDiagnostics`, `workerLifecycle`, `supersedes`, `rollbackTarget`, and
recovery metadata so operator projections can explain what ran, what authority
it received, what evidence supports the current status, and what cleanup
occurred. Source verification, approval, conformance, health, integrity, and
recovery outcomes are `evidence`/`decision` resources linked to package and
activation records. A runtime monitor derives due checks from active activation
resources and their `healthPolicy.intervalSeconds`, then enqueues
`module::check_health` through the existing queue/invocation substrate. There
is no package table, health table, policy table, conformance table, recovery
table, or non-rebuildable module cache.

No package table, module action multiplexer, client-side policy, or `control`
mutation path exists. Control and generated UI surfaces expose module resources
as projections and submit only stored canonical capability actions.

Type registration is an admin-visible capability. Resource payloads are
validated against the registered type schema before create or update persists
any resource/version rows.

Resource writes are compare-and-set protected through `expectedCurrentVersionId`.
If the current version differs, the update fails before writing a new version.
This is the base concurrency invariant for multi-agent artifact work.

Durable-output paths now declare output contracts and finish validation requires
canonical resource refs. Filesystem writes and patches produce `materialized_file`
and `patch_proposal` refs, retained process/program output produces
`execution_output` refs, and completed agent runs produce `agent_result` refs.
There is no audit-mode acceptance path for converted durable outputs.

Generated UI is also resource-native. The engine registers `ui_surface` with
schema id `tron.resource.ui_surface.v1`, validates payloads against the fixed
`tron.ui.catalog.core.v1` component catalog, and exposes `ui::catalog`,
`ui::create_surface`, `ui::surface_for_target`, `ui::validate_surface`,
`ui::refresh_surface`, `ui::expire_surface`, `ui::update_surface`,
`ui::inspect_surface`, `ui::discard_surface`, and `ui::submit_action`.
Generated surfaces carry deterministic authoring metadata for their target
graph, projection hash, preview bounds, and target revision. Surface updates
are append-only resource versions guarded by compare-and-set. Control
projections expose only bounded `uiSurfaceRefs` and authoring/refresh action
summaries; full layouts are inspected through the surface capability.
`ui::submit_action` validates the stored surface version, expiry, target
revision, required grant, idempotency key, and user input before creating the
child target invocation.

## Artifact And Goal Mapping

Artifacts are `Resource(kind = "artifact")`. Artifact operations such as
create, append, split, compose, promote, discard, materialize, and search should
be implemented as module capabilities that use the generic resource kernel.

Goals are `Resource(kind = "goal")`. Subgoals, claims, evidence, and decisions
are typed resources linked to the goal. Coordinators should return promoted
resource refs and decision resources rather than loose transcript blobs.

## Control Plane

The control plane is not a separate database. It reads the substrate through
projection capabilities:

- catalog workers/functions/triggers
- resource type definitions and resources
- invocation trees
- queues and leases
- approvals and compensation records
- storage stats
- generated UI surface resources

Advertised actions are templates for normal capabilities such as
`grant::revoke`, `worker::disconnect`, `resource::link`, `artifact::promote`,
`approval::resolve`, and `agent::abort`; there is no `control::act`
mutation multiplexer.

## Security

- Unknown resource kinds are rejected until a worker registers a type
  definition.
- Unknown lifecycle states and link relations are rejected.
- Resource updates require current-version compare-and-set.
- Invocation authority is grant-based. Missing, expired, revoked,
  subject-mismatched, insufficient-risk, insufficient-authority, or
  selector-mismatched grants fail before handler execution.
- Spawned sandbox workers receive derived grants and tokens carrying grant
  identity/resource selectors. Child grants cannot broaden the parent.
- Large resource payloads use blob-backed storage refs through the unified
  storage layer.
- Secret values must not be stored as normal artifact/resource payloads. Store
  vault handles or redacted `secret_ref` resources instead.
- Generated UI cannot execute code or call arbitrary endpoints. Actions route
  back through stored canonical capability templates and fail closed on
  unsupported components, stale versions, expired actions, damaged resources, or
  unauthorized grants.

## Clean-Break Cutover

The target architecture does not include runtime compatibility with old
mobile-first session-manager state. The current storage generation is
`modular-engine-v2`: startup archives old active `tron.sqlite`, WAL, and SHM
sidecars before opening the current schema. The runtime does not read or migrate
old product/session schemas for the new grant/resource APIs.
