# Notification Resource Contract And Generated Inbox Replacement Plan

## Current Checkpoint

The repo-wide production-grade rubric is complete at `100/100` because every
known source artifact, fixed shell, durable state owner, and security boundary
is either implemented, tested, documented, or explicitly classified with static
gates. The final Prompt Library boundary is locked:

- Prompt Library durable truth is `artifact:prompt-*` resources;
- Prompt Library management is server-authored generated UI over
  `resource_collection` surfaces;
- `PromptLibrarySheet` is a selection-only local composer insertion affordance;
- static gates forbid fixed Prompt Library management, local generated-action
  construction, prompt-table runtime truth, compatibility readers,
  `control::act`, dynamic UI catalogs, and raw-scope authority.

The next valuable work should not chase another score increase. It should use
the same remove-with-proof discipline to replace one remaining fixed product
shell with a resource-backed/generated-UI surface. The best candidate is the
notification inbox because it still has a bespoke event/table-derived inbox and
fixed Swift list/detail UI.

## First-Principles Goal

Notifications are operator attention records. They are not merely push-delivery
side effects and they are not chat events. The engine needs to be able to
explain:

- what notification was created;
- what invocation, session, worker, resource, or external delivery caused it;
- whether push/app delivery was attempted and whether it succeeded;
- whether the operator has read, dismissed, or archived it;
- what action is safe next;
- why stale, malformed, or unauthorized notification state is not actionable.

The source of truth should therefore be the collapsed substrate: resources,
resource versions, decisions, evidence, links, invocations, grants, streams, and
generated UI surfaces. It should not be reconstructed from old session event
payload SQL or a notification-specific read-state table.

## Scope

Build the next checkpoint as:

1. resource-backed notification durable output;
2. decision-backed read/dismiss state;
3. generated notification inbox/detail management;
4. fixed iOS notification shell replacement once the generated path is proven;
5. static gates that prevent event/table-derived notification inbox state from
   returning.

Keep public capability ids stable:

- `notifications::send`
- `notifications::list`
- `notifications::mark_read`
- `notifications::mark_all_read`

Existing response fields should remain present for current clients. Additive
`resourceRefs`, `decisionRefs`, `evidenceRefs`, and bounded action summaries are
allowed where the capability produces durable substrate facts.

## Non-Goals

- No new SQLite notification, inbox, read-state, scheduler, or product-shell
  tables.
- No compatibility reader that reconstructs inbox entries from old
  `notifications::send` session events.
- No migration/row-copy path from `notification_read_state`.
- No dynamic UI catalog, generated UI fallback renderer, or `control::act`.
- No iOS-owned grants, read policy, action target construction, payload
  templates, lineage, or durable notification truth.
- No APNs redesign, remote delivery service rewrite, or chat product redesign.
- No deletion of bell/deep-link affordances until the generated replacement is
  live, navigable, and tested.

## Resource Model

Add the smallest resource shape that makes notifications inspectable. A typed
`notification` resource kind is justified because operator attention records
have lifecycle, delivery, source, target, and read/dismiss semantics that would
be ambiguous if hidden inside generic artifacts.

### `notification` Resource

Schema id: `tron.resource.notification.v1`.

Deterministic id:

- `notification:{stableNotificationId}`
- The stable id should derive from the send invocation/idempotency key and
  caller-visible scope, not from wall-clock time alone.

Required payload:

- `notificationId`
- `title`
- `bodyPreview`
- optional `bodyResourceRef` for large/redacted body projections
- `priority`
- `severity`
- `category`
- `sourceInvocationId`
- optional `sessionId`
- optional `workspaceId`
- `sourceRefs`
- `targetRefs`
- `deliveryPolicy`
- `deliveryResult`
- `redactionPolicy`
- `createdAt`
- optional `expiresAt`

Lifecycle states:

- `pending`
- `active`
- `delivery_failed`
- `read`
- `dismissed`
- `archived`
- `expired`
- `discarded`
- `damaged`

Use lifecycle versions only for notification-owned state. Operator read/dismiss
actions should also create `decision` resources so the action remains
explainable and linkable.

### Decision And Evidence Resources

Use existing resource kinds:

- `decision` with `decisionType = "notification_read"` for single read
  receipts;
- `decision` with `decisionType = "notification_mark_all_read"` for scoped
  mark-all receipts;
- `decision` with `decisionType = "notification_dismiss"` or
  `notification_archive` if the UI introduces those actions;
- `evidence` for push delivery attempts, malformed delivery payloads, skipped
  unauthorized targets, and generated-inbox audit diagnostics.

No private notification state table is added. If a read action must affect many
resources, write one bounded decision resource with linked affected
notification refs rather than one hidden table row per item.

### Links

Use or extend built-in resource link definitions for:

- `triggered_by`
- `evidence_for`
- `decision_for`
- `targets`
- `source_invocation`
- `source_session`
- `source_worker`
- `affects_notification`
- `supersedes`

Links are indexed lineage, not a second state plane. The payload metadata
remains sufficient to rebuild projections if links are lost.

## Server Capability Changes

### `notifications::send`

Keep the public function id and current response fields.

Required behavior:

1. Validate title/body/priority/badge/data/sheetContent before durable output
   or push delivery.
2. Reject raw secret-like values in notification title, body, data,
   sheetContent, generated UI previews, logs, and evidence.
3. Create a pending `notification` resource with bounded/redacted payload.
4. Attempt push/app delivery through the existing delegate.
5. Append an active or `delivery_failed` notification version and delivery
   evidence.
6. Return existing fields plus top-level `resourceRefs` and, where useful,
   `evidenceRefs`.
7. On duplicate idempotency, replay the existing result without resending push
   and without creating duplicate notification resources, evidence, or links.

Failure rules:

- Validation failure produces no resource refs and no push attempt.
- Resource persistence failure occurs before push delivery.
- Push failure is persisted as evidence/failed notification state when a pending
  notification resource already exists.
- No accepted active notification is produced for malformed payloads.

### `notifications::list`

Keep the existing response fields: `notifications` and `unreadCount`.

Change the source of truth:

- list current notification resources and read/dismiss decisions;
- do not query `events` for `notifications::send` payloads;
- do not read `notification_read_state`;
- ignore old unregistered notification events as historical invocation records,
  not inbox truth.

DTO compatibility:

- keep `eventId` in the response shape for current Swift clients, but populate
  it with the stable notification id/resource id after conversion;
- add `notificationResourceId`, `notificationVersionId`, `resourceRefs`, and
  bounded `availableActions` only as additive fields.

### `notifications::mark_read`

Keep the request field name `eventId` for current clients, but treat the value
as a stable notification id/resource id after the conversion. Additive
`notificationResourceId` input can be accepted only if it does not create a
fallback ambiguity.

Required behavior:

- resolve the current notification resource;
- reject missing, damaged, discarded, expired, unauthorized, or selector-mismatched
  resources before mutation;
- create an idempotent `decision` resource for the read receipt;
- append a notification lifecycle/version update only if the current state
  requires it;
- return existing `success` plus top-level refs;
- duplicate idempotency replays without duplicate decisions or versions.

### `notifications::mark_all_read`

Required behavior:

- derive the target set from current notification resources and caller-visible
  selectors;
- support existing optional `sessionId` scoping;
- create one bounded `decision` resource that links affected notification refs;
- update affected notification lifecycle/version state through CAS where needed;
- return existing `marked` count plus top-level refs;
- reject over-broad, unauthorized, stale, or malformed requests before writing.

## Generated UI And Control Projections

Extend `ui::surface_for_target` only through the fixed catalog and stored
actions.

Supported v1 surface:

- `targetType = "resource_collection"`
- `targetId = "notification:inbox"`
- `layoutProfile = "notifications.inbox.v1"`

Generated inbox surface:

- bounded unread/all filters;
- notification rows with severity, priority, source refs, target refs, created
  time, read state, delivery status, and bounded body preview;
- `ResourceRef`, `InvocationRef`, and `WorkerRef` components for lineage;
- per-row mark-read action;
- mark-all-read action;
- refresh action;
- warning/empty states for stale, damaged, unauthorized, or malformed
  notification resources.

Generated detail surface:

- full bounded body preview or resource ref for large body;
- sheetContent as bounded rendered/monospace preview only when safe;
- delivery evidence refs;
- read/dismiss decisions;
- source invocation/session/resource refs;
- stored canonical actions only.

Control projections:

- expose notification refs and unread summaries without inlining large bodies;
- advertise generated inbox/detail surface creation where schema/grants allow;
- do not create notification surfaces implicitly;
- do not add durable control state.

`ui::submit_action` remains the only generated action gateway and must reject
stale notification revisions, revoked/expired grants, malformed input, missing
idempotency, and unsupported lifecycle states before child invocation.

## iOS Replacement Plan

Keep the bell/deep-link entrypoints, but replace fixed inbox management.

1. Add a generated notification inbox sheet that requests
   `ui::surface_for_target` for `notification:inbox` and renders the returned
   `ui_surface` with `GeneratedUISurfaceView`.
2. Keep `NotificationBellButton` as a thin launcher and unread-count indicator.
   The count must come from `notifications::list`, `control::snapshot`, or a
   generated/control projection, not local policy.
3. Replace `NotificationListSheet` and `NotificationInboxDetailSheet` only
   after generated surfaces cover filtering, detail, read, and mark-all flows.
4. Remove fixed read/dismiss Swift controls, stale DTO assumptions, previews,
   and tests in the same checkpoint.
5. Add source guards that forbid fixed notification list/detail management from
   returning and forbid local target function/payload/grant construction.
6. APNs and deep links may still open a client sheet, but that sheet must load
   server-authored notification surfaces and submit only stored action
   coordinates plus user input and idempotency key.

No iOS local read policy, lineage, resource truth, grant decision, or generated
action construction is allowed.

## Cleanup And Schema Boundary

High-scrutiny deletion candidates after the resource path is proven:

- `domains/notifications/inbox.rs` SQL event reconstruction;
- `notification_read_state` fresh schema table;
- fixed Swift `NotificationListSheet`;
- fixed Swift `NotificationInboxDetailSheet`;
- tests that assert event-derived inbox behavior;
- README/database-schema mentions of `notification_read_state`.

If `notification_read_state` is removed from the active schema, bump storage
generation with a clean-break reset. Do not add a migration reader or copy old
rows into resources.

If schema removal is deferred, static gates must still prove that runtime
notification truth no longer reads that table. The table would then be an
explicit retired-schema blocker, not an active state plane.

## Test Plan

Write failing tests first.

### Rust Resource And Capability Tests

- `notification` resource type is registered with schema, lifecycle, and link
  validation.
- `notifications::send` returns existing fields plus top-level `resourceRefs`.
- Invalid title/body/priority/badge/data/sheetContent fails before resource
  creation and before push delivery.
- Raw secret-like values fail before persistence, push, generated UI preview,
  and logs.
- Push success creates one active notification resource and delivery evidence.
- Push failure creates bounded failed-delivery evidence and no accepted active
  notification.
- Duplicate idempotency replays without duplicate push, resources, evidence,
  links, or invocations.
- `notifications::list` reads resource/decision truth and ignores unrelated old
  event rows.
- `notifications::mark_read` creates idempotent decision/resource refs and
  rejects stale, missing, damaged, unauthorized, discarded, expired, or
  selector-mismatched resources.
- `notifications::mark_all_read` scopes by session, uses one bounded decision,
  links affected resources, and does not mutate unauthorized notifications.

### Generated UI And Control Tests

- `ui::surface_for_target` creates deterministic `notifications.inbox.v1`
  resource-collection surfaces.
- Surfaces include bounded previews, refs, delivery/read status, and stored
  canonical actions only.
- Unknown collection targets/profiles, damaged notification resources, raw
  secrets, oversized bodies, and stale revisions fail or are omitted safely.
- Generated mark-read/mark-all-read actions are schema-valid, revision-pinned,
  idempotent, and approval/risk aware.
- `ui::submit_action` rejects stale notification revisions, revoked/expired
  grants, malformed input, and unsupported lifecycle states before child
  invocation.
- `control::snapshot` and `control::inspect` expose notification refs/counts
  without durable control state or large body inlining.

### iOS Tests

- Generated notification sheet requests only `notification:inbox` surfaces.
- `NotificationBellButton` remains a thin launcher/count view.
- Fixed list/detail read controls are absent after replacement.
- Action submission sends only `surfaceResourceId`, `surfaceVersionId`,
  `actionId`, `userInput`, and `idempotencyKey`.
- Deep-link/APNs notification entry opens generated surfaces and does not mark
  read through local policy.
- Offline/stale/expired/damaged surfaces are read-only or fail closed.
- Compact/regular width rendering has no clipped labels or overlapping
  controls.

### Static Gates

- No production notification inbox SQL query over `events` payloads.
- No production `notification_read_state` read/write path after conversion.
- No fixed notification list/detail management symbols after removal.
- No compatibility reader for old notification event rows.
- No dynamic UI catalog, fallback renderer, `control::act`, raw-scope
  authorization, client-authored generated UI action fields, or package/source/
  policy/trust/audit tables.
- Product-shell reachability map records the notification replacement decision
  and deletion proof.

## Verification

Run focused verification while iterating:

- `cd packages/agent && cargo test notifications --lib -- --nocapture`
- `cd packages/agent && cargo test generated_ui --lib -- --nocapture`
- `cd packages/agent && cargo test resource_ --lib -- --nocapture`
- `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`
- `cd packages/ios-app && xcodegen generate`
- targeted iOS notification/generated UI/source-guard tests
- `git diff --check`

Finish with:

- `scripts/tron ci fmt check clippy test`

Run Mac verification only if Mac files or XcodeGen inputs change.

## Acceptance Criteria

- Notification inbox durable truth is resource/decision backed.
- Notification push delivery remains externally side-effecting but is linked to
  inspectable resource/evidence records.
- No notification list/read path depends on old event-payload reconstruction or
  notification-specific read-state tables.
- Generated UI covers notification inbox/detail management before fixed Swift
  list/detail views are removed.
- Removed Swift/Rust symbols have static absence gates.
- Existing client response fields remain present; additive refs expose substrate
  truth.
- Docs, README, product-shell map, production-grade rubric, and ledger are
  updated in the same checkpoint.

## Assumptions And Defaults

- Storage remains unchanged unless `notification_read_state` is removed from the
  active schema; if removed, use a clean storage-generation reset rather than a
  compatibility migration.
- Notification bodies are bounded/redacted by default; large bodies use refs.
- Read/dismiss state is operator decision state, not hidden client state.
- APNs/device token registration remains platform support and is not converted
  in this phase.
- The next checkpoint is allowed to add a `notification` resource kind because
  it is substrate truth, not a new persistence plane.
