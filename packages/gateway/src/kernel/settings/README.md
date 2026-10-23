# gateway/settings

## Purpose

Shared settings vocabulary and durable audit/approval stores. The session context
and settings change path use one contract and one persisted store format.

## Owns

`tool-contract.ts`: layer/tier/qualifier and model-reference/queue role/key vocabulary,
retired scope-name mapping
shared by session readers and store migration, and tool request, resolution,
result and worker-state interfaces. `settings-record.ts` owns append-only audit
segments and bounded history pages; `settings-approvals.ts` owns pending exact-diff
approvals, their admission bounds, settlement, expiry and untold outcomes.
`settings-migration-state.ts` owns shared-store value transformation and digest
validation; admin owns the migration transaction, backups and publication.

## Contract

`SettingsToolAccess` resolves and changes the current session settings and drains
its pending outcomes. Concrete precedence, validation and change orchestration stay
in admin; the session runtime supplies its own identity and appliers. Audit records
are not settings truth, and pending approvals never apply themselves.

## Invariants

- No settings data, wire shape, persisted schema or policy is defined twice.
- Tool access is resolved at call time, never captured before settings start.

## Entry points

`SettingsToolAccess`, `ChangeRequest`, `ChangeResult`, `Resolution`,
`SettingsChangeRecord`, `SettingsApprovals`.

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

Settings precedence, change orchestration and UI metadata: [admin](../../admin/README.md).
