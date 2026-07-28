//! Offline profile snapshot commands.

use super::*;

pub(super) fn create_profile_snapshot_cli(for_worker_schema: Option<u32>) -> Result<()> {
    let snapshot = if let Some(target) = for_worker_schema {
        crate::domains::worker_kernel::prepare_worker_schema_snapshot(target)
            .map_err(anyhow::Error::msg)?
            .context("Worker-schema snapshot marker exists but no verified snapshot is available")?
    } else {
        crate::domains::worker_kernel::create_profile_snapshot().map_err(anyhow::Error::msg)?
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&snapshot).context("Failed to encode snapshot report")?
    );
    eprintln!("Profile snapshot verified at {}.", snapshot.path.display());
    Ok(())
}

pub(super) fn list_profile_snapshots_cli() -> Result<()> {
    for snapshot in
        crate::domains::worker_kernel::list_profile_snapshots().map_err(anyhow::Error::msg)?
    {
        println!("{}", snapshot.display());
    }
    Ok(())
}

pub(super) fn verify_profile_snapshot_cli(snapshot: &Path) -> Result<()> {
    let report = crate::domains::worker_kernel::verify_profile_snapshot(snapshot)
        .map_err(anyhow::Error::msg)?;
    println!(
        "{}",
        serde_json::to_string_pretty(&report).context("Failed to encode snapshot report")?
    );
    eprintln!("Profile snapshot is valid.");
    Ok(())
}

pub(super) fn restore_profile_snapshot_cli(snapshot: &Path) -> Result<()> {
    let database = crate::shared::foundation::paths::db_dir().join("tron.sqlite");
    let _offline_lock = crate::domains::session::event_store::acquire_database_lock(&database)
        .map_err(|error| anyhow::anyhow!("Tron must be stopped before profile restore: {error}"))?;
    let recovery = crate::domains::worker_kernel::restore_profile_snapshot(snapshot)
        .map_err(anyhow::Error::msg)?;
    println!("{}", recovery.display());
    eprintln!(
        "Profile restored. Replaced state is recoverable at {}.",
        recovery.display()
    );
    Ok(())
}
