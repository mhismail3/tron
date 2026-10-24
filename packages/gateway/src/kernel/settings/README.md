# gateway/settings

## Purpose

Declared settings schema, resolution/request pins and the audited change engine,
with durable audit/approval stores. Session contexts and store adapters share
one contract and one persisted store format.

## Owns

`settings-schema.ts` owns the concrete key table, binding/type declarations,
code floors and schema indexes. Composition supplies Home tool names, the run
compaction limit and security validation without upward imports.
`settings-resolver.ts` owns layer precedence, qualification, composition, clamping
and state badges; `settings-project-diagnostics.ts` owns bounded Project diagnostics.
`settings-model.ts` owns target resolution and fixed-direction request pins.
`settings-change.ts` owns planning, tiers, approvals, ordered application/reverse
rollback, outside-write brackets, Home recipe companion effects and target stripes.
Store reads/catalogs, provider admission and binding I/O enter through its owner ports.
Home supplies learned-profile operations and typed result projection; `auditSubject`
keeps their validation, restoration, grouped audit and awaited observer/projection
under the same Home stripe, without moving Knowledge DTOs into the kernel.
`tool-contract.ts`: layer/tier/qualifier and model-reference/queue role/key vocabulary,
retired scope-name mapping
shared by session readers and store migration, and tool request, resolution,
result and worker-state interfaces. `settings-types.ts` owns value validation, formatting,
ordered queue summaries, Pi-compatible tool-selection composition and neutral resolver inputs
(store snapshots, outside marks, floor overrides, Git state and option/format sources). `settings-record.ts` owns append-only audit
segments and bounded history pages; `settings-approvals.ts` owns pending exact-diff
approvals, their admission bounds, settlement, expiry and untold outcomes.
`scope-resolution.ts` owns binding admission from declared Session/Project permissions,
canonical targets, the public/storage scope mapping and the canonical sorted-qualifier
instance identity used by resolution badges and outside-change observation.
`settings-migration-state.ts` owns shared-store value transformation and digest
validation; admin owns the migration transaction, backups and publication.

## Contract

`SettingsToolAccess` resolves and changes the current session settings and drains
its pending outcomes. Admin loads stores, supplies runtime option/format sources
and applies concrete store bindings; the kernel owns read/change policy and
transaction order. The session runtime
supplies its own identity and appliers. Audit records
are not settings truth, and pending approvals never apply themselves.

## Invariants

- No settings data, wire shape, persisted schema or policy is defined twice.
- Tool access is resolved at call time, never captured before settings start.

## Entry points

`SettingsToolAccess`, `ChangeRequest`, `ChangeResult`, `Resolution`,
`SettingsModel`, `SettingsChangePath`, `SettingsChangeRecord`, `SettingsApprovals`.

## Signals

Callers own persistence failure diagnostics; these stores propagate write failures.

## Verify

```bash
scripts/tron test gateway src/admin/settings-approvals.lock.integration.test.ts \
  src/admin/admin.store.lock.integration.test.ts \
  src/admin/settings-change.integration.test.ts src/admin/settings-migration.e2e.test.ts
```

The real settings and run locks cover consumers of this contract.

## Not here

Store loading, dynamic catalogs, concrete binding I/O and UI rendering:
[admin](../../admin/README.md).
