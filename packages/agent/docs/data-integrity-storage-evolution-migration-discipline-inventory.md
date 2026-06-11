# Data Integrity Storage Evolution Migration Discipline Inventory

Status: Complete; every listed surface has an owner, action, rationale,
evidence pointer, and DISEMD row mapping.

Scorecard:
[`data-integrity-storage-evolution-migration-discipline-scorecard.md`](data-integrity-storage-evolution-migration-discipline-scorecard.md)

Evidence manifest:
[`data-integrity-storage-evolution-migration-discipline-evidence-manifest.md`](data-integrity-storage-evolution-migration-discipline-evidence-manifest.md)

Machine-readable inventory:
[`data-integrity-storage-evolution-migration-discipline-inventory.tsv`](data-integrity-storage-evolution-migration-discipline-inventory.tsv)

Tracked path:
`packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv`

## Surface Classes

- `campaign_harness`: DISEMD scorecard, evidence, invariant target, and
  inventory artifacts.
- `server_storage`: shared storage runtime, generation archive, schema,
  payload refs, stats, checkpoint/export/retention, and tests.
- `startup_boundary`: server bootstrap, database path policy, production
  integrity and lock ordering.
- `event_store`: session SQLite connection, migrations, process lock, busy
  contention, repositories, append facade, reconstruction, trace/log rows, and
  event payload types.
- `engine_durability`: ledger, queue, state, streams, resources, replay, and
  primitive durability tests.
- `authority_storage`: grants, leases, compensation, and grant SQLite codecs.
- `ios_projection`: iOS local SQLite projection cache, sync cursor, drafts,
  diagnostics, and architecture docs.
- `cli_dev_boundary`: scripts that inspect, reset, or report storage without
  becoming canonical storage truth.
- `docs_static_gate`: README, local closeout harness, and GitHub static gates.

## Coverage Policy

The TSV covers every storage-marker file named by the DISEMD invariant target
and the primary source areas from the slice brief. Inventory rows are evidence
classification, not authority by themselves; source files remain authoritative
for behavior.

## Closeout Notes

The slice intentionally hardens existing storage owners instead of adding new
storage surfaces. Runtime storage remains one active `tron.sqlite` generation;
non-current data is archived and never read through a compatibility path. iOS
remains a projection cache and local-device persistence owner, not server
truth.
