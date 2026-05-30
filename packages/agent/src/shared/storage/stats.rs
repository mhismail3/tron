//! Storage size and ownership reporting.

use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, params};

use super::{
    PayloadOwnerStorageStats, StorageStatsReport, TableStorageStats, apply_runtime_pragmas,
    ensure_storage_schema, file_len, shm_path, table_exists, wal_path,
};

/// Gather size and table summaries.
pub fn storage_stats(path: &Path) -> Result<StorageStatsReport> {
    let conn =
        Connection::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    apply_runtime_pragmas(&conn)?;
    ensure_storage_schema(&conn)?;
    let page_size: i64 = conn.query_row("PRAGMA page_size", [], |row| row.get(0))?;
    let page_count: i64 = conn.query_row("PRAGMA page_count", [], |row| row.get(0))?;
    let mut tables = table_stats(&conn)?;
    tables.sort_by(|left, right| {
        right
            .bytes
            .cmp(&left.bytes)
            .then(left.name.cmp(&right.name))
    });
    Ok(StorageStatsReport {
        database_path: path.to_path_buf(),
        database_bytes: file_len(path),
        wal_bytes: file_len(&wal_path(path)),
        shm_bytes: file_len(&shm_path(path)),
        page_size,
        page_count,
        page_bytes: page_size.saturating_mul(page_count),
        tables,
        payload_owners: payload_owner_stats(&conn)?,
        unowned_blob_count: unowned_blob_count(&conn)?,
        expired_pending_payload_refs: expired_pending_payload_refs(&conn)?,
        blob_dedupe_ratio: blob_dedupe_ratio(&conn)?,
    })
}

fn table_stats(conn: &Connection) -> Result<Vec<TableStorageStats>> {
    let mut stmt = conn.prepare(
        "SELECT name FROM sqlite_master
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
         ORDER BY name",
    )?;
    let names = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .filter_map(std::result::Result::ok)
        .collect::<Vec<_>>();

    let mut bytes_by_table = std::collections::BTreeMap::<String, i64>::new();
    if let Ok(mut dbstat) = conn.prepare("SELECT name, SUM(pgsize) FROM dbstat GROUP BY name")
        && let Ok(rows) = dbstat.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })
    {
        for row in rows.filter_map(std::result::Result::ok) {
            bytes_by_table.insert(row.0, row.1);
        }
    }

    let mut stats = Vec::with_capacity(names.len());
    for name in names {
        let rows = count_table_rows(conn, &name).ok();
        stats.push(TableStorageStats {
            bytes: bytes_by_table.get(&name).copied(),
            name,
            rows,
        });
    }
    Ok(stats)
}

fn count_table_rows(conn: &Connection, table_name: &str) -> rusqlite::Result<i64> {
    let escaped = table_name.replace('"', "\"\"");
    conn.query_row(&format!("SELECT COUNT(*) FROM \"{escaped}\""), [], |row| {
        row.get(0)
    })
}

fn payload_owner_stats(conn: &Connection) -> Result<Vec<PayloadOwnerStorageStats>> {
    if !table_exists(conn, "storage_payload_refs")? {
        return Ok(Vec::new());
    }
    let mut stmt = conn
        .prepare(
            "SELECT refs.owner_kind,
                    refs.retention_class,
                    COUNT(*) AS refs,
                    COALESCE(SUM(refs.payload_size_bytes), 0) AS payload_bytes,
                    COALESCE(SUM(blobs.size_compressed), 0) AS blob_bytes
             FROM storage_payload_refs refs
             LEFT JOIN blobs ON blobs.id = refs.payload_blob_id
             GROUP BY refs.owner_kind, refs.retention_class
             ORDER BY payload_bytes DESC, refs.owner_kind ASC",
        )
        .context("failed to prepare payload owner stats")?;
    let rows = stmt
        .query_map([], |row| {
            Ok(PayloadOwnerStorageStats {
                owner_kind: row.get(0)?,
                retention_class: row.get(1)?,
                refs: row.get(2)?,
                payload_bytes: row.get(3)?,
                blob_bytes: row.get(4)?,
            })
        })
        .context("failed to query payload owner stats")?;
    rows.collect::<std::result::Result<Vec<_>, _>>()
        .context("failed to collect payload owner stats")
}

fn unowned_blob_count(conn: &Connection) -> Result<i64> {
    if !table_exists(conn, "blobs")? || !table_exists(conn, "storage_payload_refs")? {
        return Ok(0);
    }
    conn.query_row(
        "SELECT COUNT(*) FROM blobs
         WHERE NOT EXISTS (
           SELECT 1 FROM storage_payload_refs refs
           WHERE refs.payload_blob_id = blobs.id
         )",
        [],
        |row| row.get(0),
    )
    .context("failed to count unowned blobs")
}

fn expired_pending_payload_refs(conn: &Connection) -> Result<i64> {
    if !table_exists(conn, "storage_payload_refs")? {
        return Ok(0);
    }
    conn.query_row(
        "SELECT COUNT(*) FROM storage_payload_refs
         WHERE retention_class = 'pending'
           AND expires_at IS NOT NULL
           AND expires_at < ?1",
        params![Utc::now().to_rfc3339()],
        |row| row.get(0),
    )
    .context("failed to count expired pending payload refs")
}

fn blob_dedupe_ratio(conn: &Connection) -> Result<Option<f64>> {
    if !table_exists(conn, "blobs")? || !table_exists(conn, "storage_payload_refs")? {
        return Ok(None);
    }
    let (logical, physical): (i64, i64) = conn
        .query_row(
            "SELECT
               COALESCE((
                 SELECT SUM(payload_size_bytes)
                 FROM storage_payload_refs
                 WHERE payload_blob_id IS NOT NULL
               ), 0),
               COALESCE((
                 SELECT SUM(size_compressed)
                 FROM blobs
                 WHERE id IN (
                   SELECT DISTINCT payload_blob_id
                   FROM storage_payload_refs
                   WHERE payload_blob_id IS NOT NULL
                 )
               ), 0)",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .context("failed to compute blob dedupe ratio")?;
    if physical <= 0 {
        Ok(None)
    } else {
        Ok(Some(logical as f64 / physical as f64))
    }
}
