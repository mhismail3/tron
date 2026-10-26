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
`SettingsReadOwner.admitModelChoice` supplies actual provider I/O keyed by the
active SDK runtime, including borrowed views; it does not depend on optional
module-policy availability or capture an eligibility snapshot.
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
approvals (settings changes and registered approval actions), their admission bounds,
settlement, expiry and untold outcomes; composition calls `settings-change.ts`'s `start()`
to arm one timer for the earliest pending deadline and `onOutcome` nudges Home when an
outcome settles. Known later deadlines are armed before expiry I/O, so a transient failure
cannot disarm them and a persistently bad store is not retried immediately.
Constructing an inspection-only owner starts no background work.
Expiry shares each target's decision stripe. `dispose()` cancels/fences arming and joins
accepted expiry work before composition releases the stores. Outcome selection does not
consume requests; canonical custom-entry request IDs acknowledge delivery within an
explicit requester-ID scope. Home supplies its chapter ledger and fitting-prefix predicate;
ordinary runtimes supply their singleton identity. Admission reserves at most 400 outcome
slots (pending and settled together), refusing new requests rather than evicting old ones. Approval
actions claim execution durably before effects. The first awaited `start()` recovers
pre-existing claims as uncertain failures without replay; repeated start is inert.
Ordinary selection, expiry and arming exclude execution claims, so delivery does not
join this owner's live action effects.
`scope-resolution.ts` owns binding admission from declared Session/Project permissions,
canonical targets, the public/storage scope mapping and the canonical sorted-qualifier
instance identity used by resolution badges and outside-change observation.
`settings-admission.ts` owns operational model/thinking selection and synchronous
compaction resolution/validation; provider eligibility remains supplied I/O.
`settings-sdk-manager.ts` owns SDK storage admission: declared Project projection,
validation and locked raw-document merging through the public Pi storage seam.
It never creates a second settings store; ignored repository fields remain owned
by their canonical document and survive SDK writes.
`settings-migration-state.ts` owns shared-store value transformation and digest
validation; admin owns the migration transaction, backups and publication.

## Contract

`SettingsToolAccess` resolves and changes the current session settings and drains
its pending outcomes as one typed `SettingsOutcomeMessage` (`tool-contract.ts`). Admin loads stores, supplies runtime option/format sources
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
`TRON_SETTINGS_EXPIRY_FAILED` means a background expiry attempt failed; retained requests
are revisited at the next known deadline or foreground admission, not in a tight retry loop.

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
