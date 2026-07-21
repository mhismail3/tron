//! Worker-kernel persistence boundary.
//!
//! Filesystem worker bundles and active pointers are canonical. The SQLite
//! backend owns rebuildable routing indexes plus durable operational ledgers.
//! Database and snapshot implementation types stay private to this module.
//! Retirement deletes legacy catalog rows for the removed generic trigger
//! registry and deactivates connection rows from the removed durable WebSocket
//! subscription design. Engine-ledger startup imports the last legacy catalog
//! revision into one scalar and drops the history table. Current worker history
//! and caller-owned durable events remain as evidence; no steady-state
//! compatibility adapter can revive either superseded plane.
//!
//! Callers use [`WorkerStore`] and the narrow startup/offline snapshot
//! functions re-exported here.
//!
//! ## Ownership
//!
//! - `filesystem` owns the one canonical atomic-JSON and immutable-tree hash
//!   implementation used by publication and reconstruction.
//! - `rebuild` projects canonical bundles into disposable SQLite indexes.
//! - `migration` is the explicit, one-time importer/retirement boundary for
//!   pre-worker profiles; it is not a steady-state compatibility adapter.
//! - `snapshot` creates and restores verified profile snapshots.
//! - `store` owns canonical publication plus durable invocation, inbox,
//!   trigger, health, and audit ledgers. Its concern modules and scenario tests
//!   live beside that single state owner.

mod filesystem;
mod migration;
mod rebuild;
mod snapshot;
mod store;

pub(super) use store::WorkerStore;

pub(crate) fn ensure_state_snapshot(
    home: &std::path::Path,
    source_label: &str,
    source_inventory_sha256: &str,
) -> Result<(), String> {
    snapshot::ensure_pre_worker_snapshot(home, source_label, source_inventory_sha256)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub(crate) fn prepare_worker_state_retirement(
    home: &std::path::Path,
    source_label: &str,
    database: &std::path::Path,
) -> Result<(), String> {
    migration::prepare_worker_first_retirement(home, source_label, database)
}

pub(crate) fn list_state_snapshots() -> Result<Vec<std::path::PathBuf>, String> {
    snapshot::list_snapshots(&crate::shared::foundation::paths::tron_home())
        .map_err(|error| error.to_string())
}

pub(crate) fn restore_state_snapshot(
    snapshot_path: &std::path::Path,
) -> Result<std::path::PathBuf, String> {
    snapshot::restore_snapshot(
        snapshot_path,
        &crate::shared::foundation::paths::tron_home(),
    )
    .map_err(|error| error.to_string())
}
