# Data Integrity Storage Evolution Migration Discipline Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/data-integrity-storage-evolution-migration-discipline`
Baseline commit: `05d0a5872d6426afa1bda076706a362835410748`

Evidence manifest:
[`data-integrity-storage-evolution-migration-discipline-evidence-manifest.md`](data-integrity-storage-evolution-migration-discipline-evidence-manifest.md)

Inventory:
[`data-integrity-storage-evolution-migration-discipline-inventory.md`](data-integrity-storage-evolution-migration-discipline-inventory.md)
and
[`data-integrity-storage-evolution-migration-discipline-inventory.tsv`](data-integrity-storage-evolution-migration-discipline-inventory.tsv)

Invariant target:
[`../tests/data_integrity_storage_evolution_migration_discipline_invariants.rs`](../tests/data_integrity_storage_evolution_migration_discipline_invariants.rs)

## Scope

This slice covers the unified `tron.sqlite` storage runtime, session event
store migrations, engine durability stores, shared payload/blob storage,
generation markers, archive/reset/dev scripts, profile/auth TOML and JSON
storage, database path discipline, WAL/checkpoint behavior, and local
projection boundaries. It does not add successor/self-adapting-agent features,
generated worker execution, deploy automation, product panels, public launch
surfaces, or compatibility readers for retired storage layouts.

## Scenario Ledger

| Row | Name | Weight | Status | Closure evidence |
| --- | --- | ---: | --- | --- |
| DSEMD-0 | Harness, Baseline, and Scope Inventory | 6 | passed_after_fix | DSEMD scorecard, evidence, inventory, invariant target, README, local quality script, GitHub CI, and predecessor inventories are present and validated. |
| DSEMD-1 | Storage Ownership and Canonical Path Discipline | 10 | passed_after_fix | Canonical path and storage inventories cover production DB, profile/auth paths, script paths, iOS projection storage, and temp-fixture test discipline. |
| DSEMD-2 | SQLite Schema Ownership, Migrations, and Drift Rejection | 14 | passed_after_fix | Shared schema validation is savepoint guarded, required columns are verified, generation marker mismatch is rejected, and migration/static gates passed. |
| DSEMD-3 | Transaction, Lock, WAL, Checkpoint, and Crash/Restart Safety | 14 | passed_after_fix | Retention is transactional, process locks/WAL/checkpoints are inventoried, and focused storage plus engine durability tests passed. |
| DSEMD-4 | Archive, Generation Marker, Reset, and Clean-Break Semantics | 12 | passed_after_fix | Generation inspection fails closed, stale DB/WAL/SHM archive moves write manifests, and reset/script surfaces are inventoried and guarded. |
| DSEMD-5 | Engine Durability Stores: Ledger, Queue, Streams, Resources | 12 | passed_after_fix | Ledger, queue, stream, state, resource, grant, lease, and compensation SQLite constructors apply shared pragmas and schema validation before owner tables. |
| DSEMD-6 | Session Event Store, Logs, Replay, and Provider Audit Integrity | 10 | passed_after_fix | Session event/log/trace/replay surfaces remain inventoried, ordered, redacted, and covered by DRC/ODA/session gates. |
| DSEMD-7 | Script/CLI Data Handling and Runtime State Hygiene | 8 | passed_after_fix | CLI/dev/status/log/reset surfaces are inventoried; negative guards reject ad hoc runtime deletion and broad CI/personal-info checks passed. |
| DSEMD-8 | Negative Guards Against Silent Corruption and Compatibility Drift | 8 | passed_after_fix | Static guards reject silent generation fallback, missing storage source tokens, missing inventory rows, and unbacked complete-state claims. |
| DSEMD-9 | Evidence, Broad Verification, and Clean Commit | 6 | passed_after_fix | Required focused and broad commands passed, generated iOS project drift check passed, whitespace/ignored-file hygiene passed, and staged slice files are ready for commit. |

Total weight: **100**

## Source Findings

- `archive_non_current_active_database` swallowed active generation inspection
  errors. It now fails closed and leaves the active DB in place for inspection.
- Startup preparation now archives orphaned `tron.sqlite-wal` and
  `tron.sqlite-shm` sidecars even when the main DB is absent, and writes
  `archive-manifest.json` for every archive move.
- Shared storage schema setup now runs inside `SAVEPOINT tron_storage_schema`,
  verifies required columns and payload-ref/blob ownership, and rejects a
  mismatched `storage_generation` marker instead of rewriting it.
- Storage retention now counts, deletes, and records the retention audit row in
  one transaction; the WAL checkpoint runs after the transaction commits.
- SQLite durability and authority store constructors now apply shared storage
  runtime pragmas and validate the shared storage schema before creating
  owner-specific tables.
- Slice 20A strengthens the retained DSEMD static gate with a README Database
  Schema table-catalog parity check against active SQLite schema sources,
  preventing undocumented active tables without adding a migration.

## Verification Summary

The evidence manifest records the exact commands and results used for closure.
No iOS source or generated project file changed; targeted iOS simulator tests
were not applicable for this storage-only slice.
