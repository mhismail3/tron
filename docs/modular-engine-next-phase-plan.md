# Generated UI Surface Authoring And Integrity Phase

## Summary

The generated UI primitive now exists: `ui_surface` is a typed resource,
`tron.ui.catalog.core.v1` is the fixed component contract, iOS renders that
catalog strictly, and `ui::submit_action` executes only stored canonical action
templates. The next phase makes that substrate operationally useful by adding
server-authored surfaces for real workers, capabilities, goals, resources,
invocations, grants, approvals, queues, leases, and storage integrity.

This plan starts after the cleanup checkpoint documented in
`docs/modular-engine-cleanup-audit.md`: the fixed iOS Automations and Voice
Notes dashboards are no longer product-shell targets, control projection shaping
lives with `control::*`, and generated UI remains the path for future bespoke
operator surfaces.

This phase is not a new dashboard framework and not a dynamic third-party UI
marketplace. It is deterministic surface authoring, refresh, integrity, and
end-to-end action handling on top of the existing resource, invocation, grant,
and control substrate.

## First-Principles Objective

An operator needs to inspect the live modular engine and take bounded actions
without reading raw JSON or trusting client-local policy. A worker or control
projection can know what object is being inspected, what actions are possible,
what revisions and grants those actions require, and what redacted previews are
safe to display. That knowledge should be persisted as `ui_surface` resources,
not as bespoke iOS screens or another server state plane.

The target state for this phase:

- every generated operator surface is a `ui_surface` resource version;
- every generated surface is reproducible from substrate truth plus deterministic
  authoring rules;
- every action is a stored canonical target invocation template;
- every stale, expired, damaged, unauthorized, oversized, or dangling surface
  fails closed;
- iOS can inspect, render, submit, refresh, and display action outcomes without
  owning policy or constructing arbitrary capability payloads.

## Non-Goals

- Do not add a storage generation bump or new durable UI/control tables.
- Do not add dynamic third-party component catalogs.
- Do not add `control::act`, route aliases, fallback renderers, or local iOS
  policy decisions.
- Do not rebuild the coordinator agent, chat UX, or main app information
  architecture in this phase.
- Do not let generated surfaces read unbounded resource bodies, raw logs, or
  secrets.
- Do not treat a surface as authority. Authority remains grant plus capability
  policy at invocation prepare time.

## Server Surface Authoring

Add deterministic authoring capabilities under the `ui` worker:

- `ui::surface_for_target`
  - Mutating, resource-backed, idempotent.
  - Request: `targetType`, `targetId`, `purpose`, `layoutProfile`,
    `expectedTargetRevision`, optional `existingSurfaceResourceId`,
    optional `expectedCurrentVersionId`, `refreshPolicy`, `maxPreviewBytes`,
    `expiresAt`, and `links`.
  - Behavior: builds or refreshes a `ui_surface` resource from current substrate
    projections and returns top-level `resourceRefs`.

- `ui::validate_surface`
  - Pure read.
  - Revalidates a stored surface against current catalog, component bounds,
    bindings, action targets, target revisions, grants, resource selectors,
    expiry, redaction policy, and dangling refs.
  - Returns `valid`, `stale`, `expired`, `damaged`, or `unauthorized`, plus
    bounded diagnostics.

- `ui::refresh_surface`
  - Mutating, resource-backed, idempotent.
  - CAS update for an existing generated surface using the same deterministic
    authoring rule that created it.
  - Rejects if the surface was manually authored or its authoring metadata is
    missing.

- `ui::expire_surface`
  - Mutating, resource-backed, idempotent.
  - Lifecycle transition to `expired` when `expiresAt` or target revision drift
    makes actions invalid. It must not delete bytes.

These capabilities compose the existing resource store. They do not create a
surface registry table, local cache, or control-plane persistence layer.

## First-Party Surface Set

Author fixed first-party surfaces for these targets:

- `worker`
  - Health, lifecycle, trust tier, visibility, namespace claims, registered
    capabilities, recent invocations, child workers, disconnect/refresh actions.

- `capability`
  - Request/response schema summary, effect, risk, idempotency, output contract,
    required grant, target revision, examples, inspect/execute readiness.

- `goal`
  - Intent, success criteria, working set, candidate outputs, promoted refs,
    claims, evidence, decisions, child invocation tree, pause/abort/promote
    actions.

- `resource`
  - Current version, lifecycle, policy, versions, links, lineage, redacted
    preview, available lifecycle/curation actions.

- `invocation`
  - Function, actor, worker, grant snapshot, parent/children, inputs, result,
    produced resource refs, trace linkage, retry/inspect actions.

- `grant`
  - Subject, parent, lifecycle, allowed capabilities/resource selectors/file
    roots/network/risk/budgets/expiry/delegation, revoke/inspect actions.

- `approval`
  - Request context, risk, target function, redacted payload preview, expiry,
    approve/reject actions through canonical `approval::resolve`.

- `queue` and `lease`
  - Queue item status, lease owner, expiry, blocked work, retry/cancel/release
    actions only where canonical capabilities already exist.

- `storage` and `integrity`
  - DB size, blob refs, resource damage warnings, orphan candidates, retention
    readiness, checkpoint/export/retention actions through canonical storage
    capabilities.

Each surface must be narrow, inspectable, and bounded. Large payloads stay as
refs with previews. Layouts should prefer `Section`, `Metric`, `Table`,
`ResourceRef`, `InvocationRef`, `GrantRef`, `WorkerRef`, `Disclosure`,
`Warning`, `Error`, and explicit action buttons.

## Control Projection Integration

`control::snapshot` and `control::inspect` remain read-only projections. Extend
their `availableActions` to include `ui::surface_for_target` templates when a
target has no current active surface or when the current surface is stale.

Rules:

- Control projections may list `uiSurfaceRefs`.
- Control projections must not inline full layouts, payload templates, or input
  schemas.
- Control projections must not create surfaces implicitly.
- Surface creation and refresh happen only through `ui::*` capabilities with
  idempotency and grants.
- Stale action submissions fail at `ui::submit_action` or the target capability,
  even if control projected the action earlier.

## Integrity And Lifecycle

Add a surface integrity path that is rebuildable from existing substrate truth:

- Detect dangling resource/invocation/grant/worker/capability bindings.
- Detect target revision drift for stored actions.
- Detect expired surfaces and expired actions.
- Detect secret-like values in layout props, bindings, previews, action labels,
  and cached iOS surface summaries.
- Detect unsupported catalog/component ids.
- Detect excessive component count, depth, table rows, text bytes, and total
  payload bytes.
- Detect stale output contracts for resource-backed action targets.
- Mark damaged or expired surfaces through resource lifecycle updates; do not
  silently rewrite payload truth.

Integrity output should be visible through `ui::validate_surface`,
`control::snapshot` integrity warnings, and `observability::trace_get` when the
surface was involved in an action.

## iOS End-To-End Consumption

The iOS Engine Console should move from showing only `uiSurfaceRefs` to rendering
server-authored surfaces in detail views:

- Selecting a worker/capability/goal/resource/invocation/grant/approval can call
  `control::inspect`.
- If an active `uiSurfaceRef` exists, iOS calls `ui::inspect_surface` and renders
  the returned current version.
- If no surface exists, iOS shows the server-provided `ui::surface_for_target`
  action template as a normal server-authoritative action, not a local shortcut.
- Action submission sends only `surfaceResourceId`, `surfaceVersionId`,
  `actionId`, `userInput`, and one idempotency key.
- Action results render child invocation id, target function id, output refs,
  approval-required state, stale/rejected state, and refresh affordance from the
  server response.
- Offline cached surfaces are read-only and actions stay disabled.

Renderer work in this phase:

- Add compact and regular width layout tests for every first-party surface type.
- Add accessibility labels for reference rows, metrics, status components, and
  action controls.
- Add form-state tests for `TextField`, `TextArea`, `Select`, `Toggle`,
  `Stepper`, and `DateTime`.
- Keep unsupported components as closed error states.

## Security Rules

- Surface authoring requires a grant that can read the target projection and
  create/update `ui_surface` resources.
- Surface actions cannot exceed the authoring invocation's grant ceiling.
- `ui::surface_for_target` cannot include an action whose target function,
  revision, risk, output contract, or required grant is not visible and valid.
- `ui::submit_action` remains the only UI action gateway.
- A client cannot submit target function ids, payload templates, required grants,
  or target revisions.
- Secret-like output is represented as `secret_ref` or redacted preview only.
- Resource bodies, logs, stdout/stderr, and trace payloads are bounded previews
  unless explicitly materialized as refs.
- Duplicate surface refresh and action submissions use idempotency; they must not
  create duplicate versions or child invocations.
- Damaged or expired surfaces are inspectable but not actionable.

## TDD Sequence

1. Add failing tests for `ui::surface_for_target` creating a worker surface with
   top-level `resourceRefs`.
2. Add tests that generated action templates reject unknown targets, stale target
   revisions, excessive risk, missing idempotency, missing output contracts, and
   grants broader than the authoring grant.
3. Add tests that control projections advertise `ui::surface_for_target` without
   creating surfaces or inlining layouts/templates.
4. Add tests for deterministic surfaces for worker, capability, goal, resource,
   invocation, grant, approval, queue/lease, and storage/integrity targets.
5. Add tests that `ui::validate_surface` detects dangling refs, expired actions,
   stale target revisions, unsupported components, raw secrets, and oversized
   payloads.
6. Add CAS/idempotency tests for `ui::refresh_surface` and lifecycle tests for
   `ui::expire_surface`.
7. Add iOS DTO/client tests for inspecting a surface, submitting an action,
   rendering action results, and keeping offline surfaces read-only.
8. Add iOS renderer layout/accessibility tests for compact and regular widths.
9. Add static gates for no control mutation multiplexer, no local iOS policy,
   no dynamic catalog acceptance, no fallback renderer, and no generated UI
   payload/template in control caches.

## Verification

- Targeted Rust tests for `ui::*` authoring, validation, refresh, expiry,
  control projection integration, and action submission.
- Static gate tests in `packages/agent/tests/threat_model_invariants.rs`.
- `scripts/tron ci fmt check clippy test`.
- `cd packages/ios-app && xcodegen generate`.
- Targeted `xcodebuild test` for Engine Console generated UI DTOs, renderer,
  surface loading, action submission, cache redaction, and layout/accessibility.
- `git diff --check`.
- Update `~/LEDGER.jsonl` with the checkpoint.

## Exit Criteria

- Engine Console can render real server-authored surfaces for the core substrate
  target types.
- Surface authoring is deterministic, idempotent, resource-backed, and
  grant-scoped.
- Surface integrity failures are visible, bounded, and fail closed.
- iOS remains a thin renderer/action submitter with no local policy truth.
- No new durable plane exists beyond catalog/worker records, invocation ledger,
  grant ledger, and resource store.
