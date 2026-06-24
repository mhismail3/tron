# Data Integrity Storage Evolution Migration Discipline Inventory

Status: Drafted for active DSEMD work.

Machine-readable inventory:
[`data-integrity-storage-evolution-migration-discipline-inventory.tsv`](data-integrity-storage-evolution-migration-discipline-inventory.tsv)

## Surface Classes

- `campaign_harness`: DSEMD docs, invariant target, README, and CI/static-gate wiring.
- `path_policy`: canonical `~/.tron` and production database path ownership.
- `shared_storage`: unified `tron.sqlite` generation, archive, schema, payload, retention, checkpoint, export, and stats runtime.
- `event_store`: session/event/log/trace SQLite store, migrations, repositories, transactional facade, and reconstruction/replay surfaces.
- `engine_durability`: ledger, queue, stream, state, resource, grant, lease, and compensation SQLite stores.
- `profile_auth`: profile TOML, active/default/user profiles, auth JSON/TOML, and bearer-token custody paths.
- `script_cli`: local dev/status/log/reset/benchmark scripts that touch or report runtime storage.
- `ios_projection`: iOS local SQLite/Keychain/UserDefaults projection state that must not become server truth.
- `predecessor_inventory`: HRA/PCC/TPC/SACB/OPSAA inventory rows updated so this new tracked work is discoverable.

## Coverage Policy

Every row identifies a source path, owner, schema/path mechanism, lock or
transaction expectation, generation/version behavior, crash/restart or archive
semantics, and DSEMD scorecard rows. Missing fields are invariant failures.

## Closeout Notes

This inventory intentionally treats clean-break storage as a hard rule:
non-current active databases are archived, not migrated through compatibility
readers, and malformed generation inspection fails closed before startup
accepts writes.
