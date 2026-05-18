# Generated UI Resource And Renderer Phase

## Summary

The next phase builds the first user-facing surface that is native to the
collapsed modular engine: declarative UI resources rendered by iOS and backed by
canonical capability actions. The goal is not a custom dashboard framework and
not a second control-plane state store. The goal is a strict resource type that
lets workers describe operator interfaces, inspectable control surfaces, and
goal-specific working views without bypassing grants, output contracts, resource
lineage, or invocation audit.

This phase starts only after the resource-native orchestration checkpoint:

- storage generation is `modular-engine-v2`;
- covered durable-output paths enforce top-level `resourceRefs`;
- public child creation is `worker::spawn`;
- `agent::run_goal` owns goal execution;
- subagent output is child invocation/resource lineage, not durable markdown
  delivery;
- `control::snapshot` and `control::inspect` are rebuildable projections.

## First-Principles Objective

Agents and modules need to present structured choices, inspections, forms, and
progress views to an operator. The UI itself is output from a worker, so it must
be subject to the same substrate rules as every other output:

- it is a typed resource, not client-local state;
- it has schema, version, provenance, lifecycle, retention, links, and policy;
- it is rendered from a bounded component catalog;
- every action invokes a canonical capability with a grant and idempotency key;
- every submitted action is checked against target resource versions and policy
  at invocation prepare time;
- unsupported, stale, oversized, or unsafe UI fails closed.

The result should make Tron useful as a modular capability engine without
recreating the old mobile-first product shell.

## Non-Goals

- Do not add a new persisted UI plane, dashboard table, action queue, local iOS
  truth store, or client authority cache.
- Do not add `control::act` or any mutation multiplexer. Mutations remain normal
  capabilities such as `grant::revoke`, `resource::link`, `artifact::promote`,
  `approval::resolve`, `worker::disconnect`, and `agent::abort`.
- Do not build a broad coordinator-agent rewrite in this phase.
- Do not support legacy UI payloads, fallback renderers, component aliases,
  deprecated route readers, or best-effort approximations.
- Do not store raw secret bytes in UI resources, previews, action templates,
  iOS caches, logs, or control snapshots.

## Core Primitives

### `ui_surface` Resource

Register `Resource(kind = "ui_surface")` as first-party substrate data.

Required payload fields:

- `surfaceId`: stable logical surface id scoped to the owner resource or worker.
- `title`: short operator-facing title.
- `purpose`: `inspect`, `configure`, `approve`, `curate`, `goal_working_set`,
  `module_status`, or `custom`.
- `componentCatalog`: catalog id and revision.
- `layout`: declarative component tree with bounded depth, count, labels, and
  data references.
- `dataBindings`: resource refs, invocation refs, grant refs, and projection refs
  used by the layout.
- `actions`: capability action bindings with target revisions, idempotency
  policy, required grant/risk/approval metadata, and payload templates.
- `redactionPolicy`: preview and cache redaction rules.
- `expiry`: latest valid action time.
- `refreshPolicy`: whether the surface is static, stream-updated, or rebuilt
  from a projection.

The resource type definition must define allowed lifecycle states:

- `draft`: created but not renderable.
- `active`: renderable and actions may be submitted.
- `superseded`: replaced by a newer version.
- `expired`: renderable as read-only history; actions rejected.
- `discarded`: hidden from default projections.
- `damaged`: payload or referenced data failed integrity checks.

### Component Catalog

The catalog is a versioned contract, not a Swift implementation detail.

Initial component set:

- text: `Text`, `Heading`, `Monospace`, `Badge`;
- structure: `Section`, `List`, `Table`, `Tabs`, `Disclosure`;
- data: `ResourceRef`, `InvocationRef`, `GrantRef`, `WorkerRef`, `Metric`;
- inputs: `TextField`, `TextArea`, `Select`, `Toggle`, `Stepper`, `DateTime`;
- commands: `Button`, `ButtonGroup`, `Confirmation`;
- status: `Progress`, `Health`, `Warning`, `Error`, `EmptyState`.

Rules:

- Each component has a JSON schema and Swift renderer test fixture.
- Component props must be bounded by byte size, item count, and nesting depth.
- Text is display data only. It cannot contain executable markup, local file
  URLs, raw secrets, or unbounded logs.
- Components unsupported by the active iOS catalog make the surface invalid.
  The client must not approximate them.

### Action Binding

An action is a prepared capability invocation template.

Required action fields:

- `actionId`;
- `label` and optional icon;
- `targetFunctionId`;
- `targetResourceId` and `targetVersionId` when acting on a resource;
- `requiredGrantId` or grant selector;
- `requiredRisk`;
- `approvalPolicy`;
- `idempotencyKeyTemplate`;
- `payloadTemplate`;
- `inputSchema`;
- `confirmationPolicy`;
- `expiresAt`;
- `surfaceVersionId`;
- `targetRevision`.

Submission rules:

- iOS submits only user input plus the action id and observed surface version.
- The server reconstructs the invocation from the stored action template.
- Invocation prepare checks grant, resource selector, target revision, expiry,
  approval, idempotency, budget, and output contract before handler execution.
- Stale target revisions fail at the target capability; the renderer may then
  ask for a refreshed surface.

## Server Implementation Plan

1. Add failing tests for `ui_surface` type registration, schema validation,
   lifecycle transitions, versioning, redaction, unsupported components, stale
   actions, and action permission checks.
2. Register `ui_surface` and `ui_component_catalog` resource definitions in the
   resource kernel.
3. Add `ui::create_surface`, `ui::update_surface`, `ui::inspect_surface`,
   `ui::discard_surface`, and `ui::render_contract` wrappers over
   `resource::*`.
4. Add strict validation:
   - catalog id/revision exists;
   - component tree validates against catalog schemas;
   - referenced resources/invocations/grants are visible to the active grant;
   - action targets are canonical capabilities;
   - action payload templates validate against target request schemas;
   - mutating actions include idempotency and output contracts;
   - redaction policy covers every secret-like binding.
5. Extend `control::snapshot` and `control::inspect` to return optional
   `ui_surface` refs for worker, goal, resource, grant, invocation, and trace
   targets. The control APIs still return projections only.
6. Add event/projection output that announces surface resource versions without
   embedding mutable UI state in streams.
7. Add integrity tooling:
   - scan surfaces for dangling refs;
   - mark damaged surfaces inspectable;
   - detect orphaned surface blobs;
   - verify expired actions are rejected.
8. Remove any server code that emits bespoke dashboard payloads once a
   corresponding `ui_surface` exists.

## iOS Implementation Plan

1. Add DTOs for `ui_surface` refs, component catalog revision, component tree,
   data bindings, action bindings, and action submission.
2. Build a strict SwiftUI renderer for the initial catalog.
3. Keep the renderer stateless with respect to truth:
   - it may cache read-only surface versions;
   - it must not decide policy;
   - it must not synthesize unsupported components;
   - it must not mutate local lineage, grant, or resource state.
4. Wire Engine Console detail views to display server-provided `ui_surface`
   refs for selected workers, goals, resources, grants, invocations, and traces.
5. Submit actions through the capability client using the action id plus
   observed surface/resource revisions. The server reconstructs the real
   invocation.
6. Render stale, expired, approval-required, and rejected action states from
   server responses, not local guesses.
7. Add accessibility and layout tests for compact and regular width:
   - no clipped labels;
   - no overlapping controls;
   - dynamic type remains usable;
   - unsupported components produce a closed error state.

## Security And Failure Rules

- A surface cannot grant authority. It can only reference action templates that
  resolve to canonical capabilities.
- A worker cannot render an action above its grant ceiling.
- A client cannot submit a payload field outside the action template schema.
- A generated surface cannot read resources not visible to the active grant.
- A stale surface version cannot perform mutation.
- An expired surface is read-only.
- A damaged surface is inspectable but not actionable.
- Secret-like data is represented as `secret_ref` or redacted preview only.
- Oversized payloads, deep trees, excessive table rows, and unbounded log views
  fail validation before persistence.
- Offline iOS actions are rejected unless explicitly modeled as durable
  approval responses with idempotency and expiry. Do not add this by default.

## Test-Driven Sequence

1. `ui_surface` resource type registration fails invalid schemas.
2. Component catalog rejects unsupported components and excessive tree bounds.
3. `ui::create_surface` returns top-level `resourceRefs`.
4. Surface creation fails when bindings reference invisible resources.
5. Surface creation fails when action targets unknown or noncanonical
   capabilities.
6. Mutating action templates fail without idempotency/output contract.
7. Action submission fails when surface version is stale.
8. Action submission fails when target resource revision changed.
9. Revoked/expired grants fail before handler execution.
10. Secret-like bindings are redacted or rejected.
11. Control projections expose only surface refs and rebuild without control
    state tables.
12. iOS renderer snapshot tests cover every catalog component.
13. iOS renderer rejects unsupported component ids.
14. iOS action submission sends only action id, observed revisions, and validated
    user input.
15. Static gates fail on fallback renderers, legacy dashboard routes, local
    policy decisions, or UI mutation multiplexers.

## Static Gates

- No public mutation API named `control::act`.
- No generated UI action without a canonical `targetFunctionId`.
- No mutable action without idempotency.
- No unsupported-component fallback renderer.
- No iOS local grant/policy truth.
- No raw secret bytes in UI resources, previews, logs, or caches.
- No UI table/cache that cannot be rebuilt from catalog, invocation, grant, and
  resource truth.
- No legacy route, alias, or retired DTO reader.

## Verification

- Rust targeted tests for resource type registration, UI wrappers, validation,
  action submission, grants, stale revisions, redaction, and control projection.
- `scripts/tron ci fmt check clippy test` before checkpoint.
- iOS `xcodegen generate`.
- Targeted iOS tests for Engine Console DTOs, renderer fixtures, unsupported
  components, action submission, and cache redaction.
- `git diff --check`.
- Update `~/LEDGER.jsonl` with the phase plan and implementation checkpoint.

## Phase Exit Criteria

- A worker can create an inspectable `ui_surface` resource.
- The control plane can expose surface refs without durable control state.
- iOS can render the accepted catalog strictly and submit actions safely.
- Stale, unauthorized, unsupported, damaged, expired, and secret-bearing surfaces
  fail closed in tests.
- No legacy dashboard or mobile-first session-manager UI path remains necessary
  for substrate inspection.
