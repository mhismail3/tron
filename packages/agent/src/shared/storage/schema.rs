//! Storage schema and runtime pragma setup.

use std::collections::BTreeSet;

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};

use super::{CURRENT_STORAGE_GENERATION, STORAGE_GENERATION_KEY};

/// Apply storage-wide SQLite pragmas to one connection.
pub fn apply_runtime_pragmas(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA foreign_keys = ON;
         PRAGMA wal_autocheckpoint = 1000;
         PRAGMA synchronous = NORMAL;",
    )
    .context("failed to apply storage runtime pragmas")?;
    Ok(())
}

/// Ensure storage metadata tables exist and still match the current owner shape.
pub fn ensure_storage_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch("SAVEPOINT tron_storage_schema")
        .context("failed to start storage schema savepoint")?;
    let result = ensure_storage_schema_inner(conn);
    match result {
        Ok(()) => conn
            .execute_batch("RELEASE SAVEPOINT tron_storage_schema")
            .context("failed to release storage schema savepoint"),
        Err(error) => {
            let _ = conn.execute_batch(
                "ROLLBACK TO SAVEPOINT tron_storage_schema;
                 RELEASE SAVEPOINT tron_storage_schema;",
            );
            Err(error)
        }
    }
}

/// Rebuild an owner table when one historical `TEXT NOT NULL` observation
/// column becomes nullable.
///
/// The caller supplies the canonical table and index SQL plus the complete
/// ordered column list. This migration is intentionally narrow: it preserves
/// rows byte-for-byte, runs under a savepoint, and is only valid for tables
/// without inbound foreign-key references. It exists so trusted-local causal
/// records can store SQL `NULL` instead of manufacturing an authority id.
pub(crate) fn ensure_nullable_text_observation(
    conn: &Connection,
    table: &'static str,
    column: &'static str,
    create_table_sql: &'static str,
    create_indexes_sql: &'static str,
    ordered_columns: &'static [&'static str],
) -> Result<()> {
    let table_identifier = quoted_identifier(table);
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table_identifier})"))
        .with_context(|| format!("failed to inspect {table}.{column} nullability"))?;
    let mut rows = stmt
        .query([])
        .with_context(|| format!("failed to query {table}.{column} nullability"))?;
    let mut not_null = None;
    while let Some(row) = rows
        .next()
        .with_context(|| format!("failed to read {table}.{column} nullability"))?
    {
        let name: String = row.get(1).context("failed to decode schema column name")?;
        if name == column {
            not_null = Some(
                row.get::<_, i64>(3)
                    .context("failed to decode schema not-null flag")?
                    != 0,
            );
            break;
        }
    }
    drop(rows);
    drop(stmt);

    match not_null {
        Some(false) => return Ok(()),
        None => anyhow::bail!("storage schema drift: table {table} missing column {column}"),
        Some(true) => {}
    }

    let legacy = format!("{table}__nullable_observation_migration");
    let legacy_identifier = quoted_identifier(&legacy);
    let column_list = ordered_columns
        .iter()
        .map(|name| quoted_identifier(name))
        .collect::<Vec<_>>()
        .join(", ");
    conn.execute_batch("SAVEPOINT tron_nullable_observation")
        .with_context(|| format!("failed to start {table}.{column} migration"))?;
    let migration = (|| -> Result<()> {
        let stale_legacy: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [legacy.as_str()],
                |row| row.get(0),
            )
            .with_context(|| format!("failed to inspect migration table {legacy}"))?;
        if stale_legacy != 0 {
            anyhow::bail!("refusing to overwrite stale migration table {legacy}");
        }
        conn.execute(
            &format!("ALTER TABLE {table_identifier} RENAME TO {legacy_identifier}"),
            [],
        )
        .with_context(|| format!("failed to rename {table} for nullable migration"))?;
        conn.execute_batch(create_table_sql)
            .with_context(|| format!("failed to recreate {table} with nullable {column}"))?;
        conn.execute(
            &format!(
                "INSERT INTO {table_identifier} ({column_list}) \
                 SELECT {column_list} FROM {legacy_identifier} ORDER BY rowid ASC"
            ),
            [],
        )
        .with_context(|| format!("failed to copy {table} rows during nullable migration"))?;
        conn.execute(&format!("DROP TABLE {legacy_identifier}"), [])
            .with_context(|| format!("failed to remove migrated {legacy} table"))?;
        conn.execute_batch(create_indexes_sql)
            .with_context(|| format!("failed to recreate {table} indexes"))?;
        Ok(())
    })();
    match migration {
        Ok(()) => conn
            .execute_batch("RELEASE SAVEPOINT tron_nullable_observation")
            .with_context(|| format!("failed to finish {table}.{column} migration")),
        Err(error) => {
            let _ = conn.execute_batch(
                "ROLLBACK TO SAVEPOINT tron_nullable_observation;
                 RELEASE SAVEPOINT tron_nullable_observation;",
            );
            Err(error)
        }
    }
}

fn quoted_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn ensure_storage_schema_inner(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS storage_metadata (
           key TEXT PRIMARY KEY,
           value TEXT NOT NULL,
           updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS storage_checkpoints (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           checkpointed_at TEXT NOT NULL,
           mode TEXT NOT NULL,
           busy INTEGER NOT NULL,
           log_pages INTEGER NOT NULL,
           checkpointed_pages INTEGER NOT NULL,
           wal_bytes INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS storage_exports (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           exported_at TEXT NOT NULL,
           snapshot_path TEXT NOT NULL,
           snapshot_bytes INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS storage_retention_runs (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           started_at TEXT NOT NULL,
           finished_at TEXT NOT NULL,
           dry_run INTEGER NOT NULL DEFAULT 0,
           rows_deleted INTEGER NOT NULL DEFAULT 0,
           blobs_deleted INTEGER NOT NULL DEFAULT 0,
           notes TEXT
         );
         CREATE TABLE IF NOT EXISTS blobs (
           id              TEXT    PRIMARY KEY,
           hash            TEXT    NOT NULL UNIQUE,
           content         BLOB    NOT NULL,
           mime_type       TEXT    NOT NULL DEFAULT 'text/plain',
           uncompressed_size INTEGER NOT NULL,
           size_compressed INTEGER NOT NULL,
           compression     TEXT    NOT NULL DEFAULT 'none',
           created_at      TEXT    NOT NULL,
           ref_count       INTEGER NOT NULL DEFAULT 1
         );
         CREATE TABLE IF NOT EXISTS storage_payload_refs (
           id                 TEXT PRIMARY KEY,
           owner_kind         TEXT NOT NULL,
           owner_id           TEXT NOT NULL,
           field_name         TEXT NOT NULL,
           payload_hash       TEXT NOT NULL,
           payload_blob_id    TEXT,
           payload_preview    TEXT NOT NULL,
           payload_size_bytes INTEGER NOT NULL,
           payload_kind       TEXT NOT NULL,
           redaction_level    TEXT NOT NULL,
           retention_class    TEXT NOT NULL,
           trace_id           TEXT,
           session_id         TEXT,
           workspace_id       TEXT,
           expires_at         TEXT,
           created_at         TEXT NOT NULL,
           UNIQUE(owner_kind, owner_id, field_name)
         );",
    )
    .context("failed to create storage metadata tables")?;
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash);
         CREATE INDEX IF NOT EXISTS idx_blobs_ref_count ON blobs(ref_count) WHERE ref_count <= 0;
         CREATE INDEX IF NOT EXISTS idx_storage_payload_refs_owner
           ON storage_payload_refs(owner_kind, owner_id);
         CREATE INDEX IF NOT EXISTS idx_storage_payload_refs_blob
           ON storage_payload_refs(payload_blob_id);
         CREATE INDEX IF NOT EXISTS idx_storage_payload_refs_retention
           ON storage_payload_refs(retention_class, expires_at);",
    )
    .context("failed to create blob indexes")?;
    verify_storage_schema(conn)?;
    verify_payload_blob_integrity(conn)?;
    let current_generation = conn
        .query_row(
            "SELECT value FROM storage_metadata WHERE key = ?1",
            params![STORAGE_GENERATION_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .context("failed to read storage generation marker")?;
    match current_generation {
        Some(generation) if generation == CURRENT_STORAGE_GENERATION => {}
        Some(generation) => {
            anyhow::bail!(
                "storage generation marker mismatch: found {generation}, expected {CURRENT_STORAGE_GENERATION}"
            );
        }
        None => {
            conn.execute(
                "INSERT INTO storage_metadata (key, value, updated_at)
                 VALUES (?1, ?2, ?3)",
                params![
                    STORAGE_GENERATION_KEY,
                    CURRENT_STORAGE_GENERATION,
                    Utc::now().to_rfc3339()
                ],
            )
            .context("failed to record storage generation marker")?;
        }
    }
    Ok(())
}

fn verify_storage_schema(conn: &Connection) -> Result<()> {
    for (table, columns) in [
        ("storage_metadata", &["key", "value", "updated_at"][..]),
        (
            "storage_checkpoints",
            &[
                "id",
                "checkpointed_at",
                "mode",
                "busy",
                "log_pages",
                "checkpointed_pages",
                "wal_bytes",
            ][..],
        ),
        (
            "storage_exports",
            &["id", "exported_at", "snapshot_path", "snapshot_bytes"][..],
        ),
        (
            "storage_retention_runs",
            &[
                "id",
                "started_at",
                "finished_at",
                "dry_run",
                "rows_deleted",
                "blobs_deleted",
                "notes",
            ][..],
        ),
        (
            "blobs",
            &[
                "id",
                "hash",
                "content",
                "mime_type",
                "uncompressed_size",
                "size_compressed",
                "compression",
                "created_at",
                "ref_count",
            ][..],
        ),
        (
            "storage_payload_refs",
            &[
                "id",
                "owner_kind",
                "owner_id",
                "field_name",
                "payload_hash",
                "payload_blob_id",
                "payload_preview",
                "payload_size_bytes",
                "payload_kind",
                "redaction_level",
                "retention_class",
                "trace_id",
                "session_id",
                "workspace_id",
                "expires_at",
                "created_at",
            ][..],
        ),
    ] {
        verify_table_columns(conn, table, columns)?;
    }
    Ok(())
}

fn verify_table_columns(conn: &Connection, table_name: &str, required: &[&str]) -> Result<()> {
    let escaped = table_name.replace('"', "\"\"");
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info(\"{escaped}\")"))
        .with_context(|| format!("failed to inspect storage table {table_name}"))?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .with_context(|| format!("failed to list columns for storage table {table_name}"))?
        .collect::<rusqlite::Result<BTreeSet<_>>>()
        .with_context(|| format!("failed to collect columns for storage table {table_name}"))?;
    for column in required {
        if !columns.contains(*column) {
            anyhow::bail!("storage schema drift: table {table_name} missing column {column}");
        }
    }
    Ok(())
}

fn verify_payload_blob_integrity(conn: &Connection) -> Result<()> {
    let dangling: i64 = conn
        .query_row(
            "SELECT COUNT(*)
             FROM storage_payload_refs refs
             LEFT JOIN blobs ON blobs.id = refs.payload_blob_id
             WHERE refs.payload_blob_id IS NOT NULL
               AND blobs.id IS NULL",
            [],
            |row| row.get(0),
        )
        .context("failed to verify payload-ref blob ownership")?;
    if dangling > 0 {
        anyhow::bail!(
            "storage payload integrity failed: {dangling} payload ref(s) point at missing blobs"
        );
    }
    Ok(())
}
