//! Worker-kernel persistence boundary.
//!
//! Filesystem worker bundles and active pointers are canonical. The SQLite
//! backend owns rebuildable routing indexes plus durable operational ledgers.
//! Database and snapshot implementation types stay private to this module;
//! callers use [`WorkerStore`] and the snapshot functions re-exported here.
//! Store concern modules and their scenario tests live under `store/`, adjacent
//! to their single state owner without inflating one production file.

mod migration;
mod snapshot;
mod store;

pub(super) use store::WorkerStore;

pub(crate) fn prepare_profile_state_retirement(
    home: &std::path::Path,
    source_profile: &str,
    database: &std::path::Path,
) -> Result<(), String> {
    migration::prepare_worker_first_retirement(home, source_profile, database)
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
