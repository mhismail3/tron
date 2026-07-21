//! Worker-kernel persistence boundary.
//!
//! Filesystem worker bundles and active pointers are canonical. The SQLite
//! backend owns rebuildable routing indexes plus durable operational ledgers.
//! Database and snapshot implementation types stay private to this module.
//! Retirement also deletes catalog-change rows for the removed generic trigger
//! registry; current worker/function history remains as observational evidence,
//! and no compatibility decoder can revive the superseded trigger plane.
//!
//! Callers use [`WorkerStore`] and the narrow startup/offline snapshot
//! functions re-exported here.
//! Store concern modules and their scenario tests live under `store/`, adjacent
//! to their single state owner without inflating one production file.

mod migration;
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
