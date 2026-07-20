//! Worker-kernel persistence boundary.
//!
//! Filesystem worker bundles and active pointers are canonical. The SQLite
//! backend owns rebuildable routing indexes plus durable operational ledgers.
//! Database and snapshot implementation types stay private to this module;
//! callers use [`WorkerStore`] and the snapshot functions re-exported here.

mod migration;
mod snapshot;
mod store;

pub(super) use store::WorkerStore;

pub(super) fn list_snapshots(home: &std::path::Path) -> std::io::Result<Vec<std::path::PathBuf>> {
    snapshot::list_snapshots(home)
}

pub(super) fn restore_snapshot(
    snapshot_path: &std::path::Path,
    home: &std::path::Path,
) -> std::io::Result<std::path::PathBuf> {
    snapshot::restore_snapshot(snapshot_path, home)
}
