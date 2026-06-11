# Data Integrity Storage Evolution Migration Discipline Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/data-integrity-storage-migration-discipline`
Baseline commit: `2da96a8488a46760b25524c5d8d782529fc92b68`

Evidence manifest:
[`data-integrity-storage-evolution-migration-discipline-evidence-manifest.md`](data-integrity-storage-evolution-migration-discipline-evidence-manifest.md)

Inventory:
[`data-integrity-storage-evolution-migration-discipline-inventory.md`](data-integrity-storage-evolution-migration-discipline-inventory.md)
and
[`data-integrity-storage-evolution-migration-discipline-inventory.tsv`](data-integrity-storage-evolution-migration-discipline-inventory.tsv)

Invariant target:
[`../tests/data_integrity_storage_evolution_migration_discipline_invariants.rs`](../tests/data_integrity_storage_evolution_migration_discipline_invariants.rs)

Repo path:
`packages/agent/tests/data_integrity_storage_evolution_migration_discipline_invariants.rs`

## Scope

This slice proves unified SQLite storage, clean-break generation handling,
archive sidecars, schema ownership, process locks, WAL/checkpoint/export
behavior, payload/blob retention, engine durability stores, session/event store
append ownership, CLI/dev boundaries, and iOS projection persistence cannot
silently mutate or hide server storage truth.

It does not add compatibility reads for retired product databases, production
deploy behavior, public `/engine` storage management surfaces, provider-visible
tools, repo-managed skills, or iOS settings.

## Scenario Ledger

| Row | Name | Weight | Status | Closure requirement |
| --- | --- | ---: | --- | --- |
| DISEMD-0 | Harness | 5 | passed_after_fix | Scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, local closeout list, GitHub static gates, and predecessor inventory bookkeeping are wired. |
| DISEMD-1 | Storage Inventory | 10 | passed_after_fix | SQLite/storage/archive/schema/lock/WAL/payload/event/durability/iOS persistence surfaces are classified with owner, action, rationale, evidence pointer, and row mapping. |
| DISEMD-2 | Clean-Break Generation | 10 | passed_after_fix | `tron.sqlite` generation inspection fails closed on malformed markers, archives stale active DBs plus WAL/SHM sidecars, archives orphaned sidecars, records archive manifests, and refuses archive overwrite collisions. |
| DISEMD-3 | Schema/Migration Discipline | 12 | passed_after_fix | `v001_schema.sql`, `schema_version`, `ensure_storage_schema`, storage metadata drift checks, payload-ref integrity checks, and migration FK checks are transactional or savepoint guarded. |
| DISEMD-4 | WAL/Pragmas/Integrity | 10 | passed_after_fix | Startup, shared storage runtime operations, event-store pools, engine durability stores, authority stores, logging, checkpoint, export, retention, and stats paths apply WAL/foreign-key/busy-timeout pragmas and run integrity checks on production startup. |
| DISEMD-5 | Locking/Contention/Crash | 10 | passed_after_fix | Startup process lock ordering, stale lock acquisition, busy retry policy, session write locks, crash/restart recovery, and concurrent writer failure modes are explicit and covered by source guards plus focused tests. |
| DISEMD-6 | Payload/Blob Retention | 10 | passed_after_fix | Payload refs, blob ownership, owner metadata, expired ref deletion, unowned blob cleanup, stats, snapshots, exports, and size budget enforcement preserve audit-owned data and fail closed on dangling refs. |
| DISEMD-7 | Engine Durability Stores | 10 | passed_after_fix | Ledger, queue, resources, state, streams, grants, leases, compensation, idempotency, worker catalog records, revisions, CAS, and attempt records preserve causality and use shared storage discipline. |
| DISEMD-8 | Session/Event Store Integrity | 8 | passed_after_fix | Event append order, counters, reconstruction, trace/log/provider audit rows, forks, archives, deletes, and payload refs remain append-owned and deterministic. |
| DISEMD-9 | CLI/iOS/Dev Boundaries | 5 | passed_after_fix | CLI status/log/reset helpers, dev startup, iOS event DB, diagnostics stores, and generated project state do not mutate or mask server storage truth. |
| DISEMD-10 | Corruption Drills | 5 | passed_after_fix | Adversarial tests cover stale generation, malformed generation markers, orphaned sidecars, storage schema drift, dangling payload refs, expired ref/blob retention, lock collision, export collision, FK checks, and retention edge cases. |
| DISEMD-11 | Closeout | 5 | passed_after_fix | Focused and broad verification, personal-info guard, XcodeGen drift check, ignored-file check, clean status, commit, and residual-risk note are recorded. |

Total weight: **100**

## Source Findings And Fixes

- `archive_non_current_active_database` discarded active generation inspection
  errors and treated an unreadable marker like a missing marker. It now fails
  closed, leaving the active DB in place for operator inspection.
- Startup now archives orphaned `tron.sqlite-wal` and `tron.sqlite-shm` files
  even when the main DB is absent, writes `archive-manifest.json`, allocates a
  unique archive directory, and refuses to overwrite archive files.
- `ensure_storage_schema` now runs inside a SQLite savepoint, verifies required
  storage table columns, verifies payload-ref-to-blob ownership, and rolls back
  its own schema/marker work on drift.
- Storage retention now counts, deletes, and records the retention audit row in
  one transaction; the WAL checkpoint happens after the mutation commits.
- Engine durability and authority SQLite stores now apply shared runtime
  pragmas and validate the shared storage schema before using their own tables,
  matching the startup connection pool discipline.

## Verification Commands

Focused commands passed:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo check --manifest-path packages/agent/Cargo.toml
cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml event_store::sqlite --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml event_store::store --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_successor_teardown_cleanup_invariants -- --nocapture
```

Broad closeout commands passed or recorded:

```bash
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```

`git status --short` was intentionally captured before staging and showed the
DISEMD worktree changes. The post-commit clean status is verified after the
commit and reported in the closeout response.
