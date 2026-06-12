//! Storage checkpoint, export, retention, and size-budget maintenance.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, params};

use super::{
    StorageBudgetReport, StorageCheckpointReport, StorageExportReport, StorageRetentionReport,
    apply_runtime_pragmas, ensure_storage_schema, file_len, stats::storage_stats, table_exists,
    wal_path,
};

/// Checkpoint one database file.
pub fn checkpoint_database(path: &Path) -> Result<StorageCheckpointReport> {
    let conn =
        Connection::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    apply_runtime_pragmas(&conn)?;
    ensure_storage_schema(&conn)?;
    let (busy, log_pages, checkpointed_pages): (i64, i64, i64) = conn
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .context("failed to checkpoint WAL")?;
    let wal_bytes = file_len(&wal_path(path));
    let checkpointed_at = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO storage_checkpoints
         (checkpointed_at, mode, busy, log_pages, checkpointed_pages, wal_bytes)
         VALUES (?1, 'truncate', ?2, ?3, ?4, ?5)",
        params![
            checkpointed_at,
            busy,
            log_pages,
            checkpointed_pages,
            wal_bytes
        ],
    )
    .context("failed to record storage checkpoint")?;
    Ok(StorageCheckpointReport {
        database_path: path.to_path_buf(),
        mode: "truncate".to_owned(),
        busy,
        log_pages,
        checkpointed_pages,
        wal_bytes,
        checkpointed_at,
    })
}

/// Export a single-file snapshot using SQLite `VACUUM INTO`.
pub fn export_snapshot(
    path: &Path,
    snapshot_path: impl AsRef<Path>,
) -> Result<StorageExportReport> {
    let snapshot_path = snapshot_path.as_ref();
    if snapshot_path.exists() {
        anyhow::bail!(
            "storage snapshot destination already exists: {}",
            snapshot_path.display()
        );
    }
    if let Some(parent) = snapshot_path.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!(
                "failed to create storage snapshot parent {}",
                parent.display()
            )
        })?;
    }
    let conn =
        Connection::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    apply_runtime_pragmas(&conn)?;
    ensure_storage_schema(&conn)?;
    let _ =
        conn.query_row::<(i64, i64, i64), _, _>("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?;
    conn.execute("VACUUM INTO ?1", params![snapshot_path.to_string_lossy()])
        .with_context(|| format!("failed to export snapshot {}", snapshot_path.display()))?;
    let exported_at = Utc::now().to_rfc3339();
    let snapshot_bytes = file_len(snapshot_path);
    conn.execute(
        "INSERT INTO storage_exports (exported_at, snapshot_path, snapshot_bytes)
         VALUES (?1, ?2, ?3)",
        params![
            exported_at,
            snapshot_path.to_string_lossy().as_ref(),
            snapshot_bytes
        ],
    )
    .context("failed to record storage export")?;
    Ok(StorageExportReport {
        source_path: path.to_path_buf(),
        snapshot_path: snapshot_path.to_path_buf(),
        snapshot_bytes,
        exported_at,
    })
}

/// Compact low-signal verbose diagnostic rows and remove unreferenced blobs.
pub fn retention_run(
    path: &Path,
    dry_run: bool,
    verbose_retention_days: u64,
) -> Result<StorageRetentionReport> {
    let conn =
        Connection::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    apply_runtime_pragmas(&conn)?;
    ensure_storage_schema(&conn)?;
    let started_at = Utc::now().to_rfc3339();
    let cutoff = Utc::now()
        - chrono::Duration::days(i64::try_from(verbose_retention_days).unwrap_or(i64::MAX));
    let cutoff = cutoff.to_rfc3339();
    let now = Utc::now().to_rfc3339();
    let has_logs = table_exists(&conn, "logs")?;
    let has_payload_refs = table_exists(&conn, "storage_payload_refs")?;
    let has_blobs = table_exists(&conn, "blobs")?;

    let (rows_deleted, expired_refs_deleted, blobs_deleted, finished_at) = if dry_run {
        let rows_deleted = count_verbose_logs(&conn, has_logs, &cutoff)?;
        let expired_refs_deleted = count_expired_payload_refs(&conn, has_payload_refs, &now)?;
        let blobs_deleted = count_unowned_blobs(&conn, has_blobs, has_payload_refs)?;
        (
            rows_deleted,
            expired_refs_deleted,
            blobs_deleted,
            Utc::now().to_rfc3339(),
        )
    } else {
        let tx = conn
            .unchecked_transaction()
            .context("failed to begin storage retention transaction")?;
        let tx_conn: &Connection = &tx;
        let rows_deleted = count_verbose_logs(tx_conn, has_logs, &cutoff)?;
        if rows_deleted > 0 {
            tx.execute(
                "DELETE FROM logs
                 WHERE component LIKE 'ios.%'
                   AND lower(level) IN ('trace', 'debug')
                   AND timestamp < ?1",
                params![cutoff],
            )
            .context("failed to delete verbose diagnostic logs")?;
        }
        let expired_refs_deleted = count_expired_payload_refs(tx_conn, has_payload_refs, &now)?;
        if expired_refs_deleted > 0 {
            tx.execute(
                "DELETE FROM storage_payload_refs
                 WHERE retention_class IN ('diagnostic_verbose', 'pending')
                   AND expires_at IS NOT NULL
                   AND expires_at < ?1",
                params![now],
            )
            .context("failed to delete expired storage payload refs")?;
        }
        let blobs_deleted = count_unowned_blobs(tx_conn, has_blobs, has_payload_refs)?;
        if blobs_deleted > 0 {
            tx.execute(
                "DELETE FROM blobs
                 WHERE NOT EXISTS (
                   SELECT 1 FROM storage_payload_refs refs
                   WHERE refs.payload_blob_id = blobs.id
                 )",
                [],
            )
            .context("failed to delete unowned storage blobs")?;
        }
        let finished_at = Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO storage_retention_runs
             (started_at, finished_at, dry_run, rows_deleted, blobs_deleted, notes)
             VALUES (?1, ?2, 0, ?3, ?4, ?5)",
            params![
                started_at,
                finished_at,
                rows_deleted,
                blobs_deleted,
                format!(
                    "verbose_retention_days={verbose_retention_days};expired_refs_deleted={expired_refs_deleted}"
                )
            ],
        )
        .context("failed to record storage retention run")?;
        tx.commit()
            .context("failed to commit storage retention transaction")?;
        let _ =
            conn.query_row::<(i64, i64, i64), _, _>("PRAGMA wal_checkpoint(PASSIVE)", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            });
        (
            rows_deleted,
            expired_refs_deleted,
            blobs_deleted,
            finished_at,
        )
    };
    Ok(StorageRetentionReport {
        dry_run,
        verbose_retention_days,
        rows_deleted,
        blobs_deleted,
        payload_refs_deleted: expired_refs_deleted,
        started_at,
        finished_at,
    })
}

fn count_verbose_logs(conn: &Connection, has_logs: bool, cutoff: &str) -> Result<i64> {
    if !has_logs {
        return Ok(0);
    }
    conn.query_row(
        "SELECT COUNT(*) FROM logs
         WHERE component LIKE 'ios.%'
           AND lower(level) IN ('trace', 'debug')
           AND timestamp < ?1",
        params![cutoff],
        |row| row.get::<_, i64>(0),
    )
    .context("failed to count verbose diagnostic logs")
}

fn count_expired_payload_refs(conn: &Connection, has_payload_refs: bool, now: &str) -> Result<i64> {
    if !has_payload_refs {
        return Ok(0);
    }
    conn.query_row(
        "SELECT COUNT(*) FROM storage_payload_refs
         WHERE retention_class IN ('diagnostic_verbose', 'pending')
           AND expires_at IS NOT NULL
           AND expires_at < ?1",
        params![now],
        |row| row.get::<_, i64>(0),
    )
    .context("failed to count expired storage payload refs")
}

fn count_unowned_blobs(conn: &Connection, has_blobs: bool, has_payload_refs: bool) -> Result<i64> {
    if !has_blobs {
        return Ok(0);
    }
    if !has_payload_refs {
        return conn
            .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get::<_, i64>(0))
            .context("failed to count unowned storage blobs without refs table");
    }
    conn.query_row(
        "SELECT COUNT(*) FROM blobs
         WHERE NOT EXISTS (
           SELECT 1 FROM storage_payload_refs refs
           WHERE refs.payload_blob_id = blobs.id
         )",
        [],
        |row| row.get::<_, i64>(0),
    )
    .context("failed to count unowned storage blobs")
}

/// Enforce the active database soft size budget with safe cleanup only.
pub fn enforce_size_budget(
    path: &Path,
    max_database_mb: u64,
    verbose_retention_days: u64,
) -> Result<StorageBudgetReport> {
    let max_database_bytes = max_database_mb.saturating_mul(1024).saturating_mul(1024);
    let before = storage_stats(path)?;
    let before_total_bytes = before.total_file_bytes();
    if max_database_bytes == 0 || before_total_bytes <= max_database_bytes {
        return Ok(StorageBudgetReport {
            max_database_bytes,
            before_total_bytes,
            after_total_bytes: before_total_bytes,
            over_limit: false,
            retention: None,
            checkpoint: None,
        });
    }

    let retention = retention_run(path, false, verbose_retention_days)?;
    let checkpoint = checkpoint_database(path)?;
    let after = storage_stats(path)?;
    Ok(StorageBudgetReport {
        max_database_bytes,
        before_total_bytes,
        after_total_bytes: after.total_file_bytes(),
        over_limit: true,
        retention: Some(retention),
        checkpoint: Some(checkpoint),
    })
}
