//! Storage schema and runtime pragma setup.

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

/// Ensure storage metadata tables exist.
pub fn ensure_storage_schema(conn: &Connection) -> Result<()> {
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
    let current_generation = conn
        .query_row(
            "SELECT value FROM storage_metadata WHERE key = ?1",
            params![STORAGE_GENERATION_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .context("failed to read storage generation marker")?;
    if current_generation.as_deref() != Some(CURRENT_STORAGE_GENERATION) {
        conn.execute(
            "INSERT INTO storage_metadata (key, value, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            params![
                STORAGE_GENERATION_KEY,
                CURRENT_STORAGE_GENERATION,
                Utc::now().to_rfc3339()
            ],
        )
        .context("failed to record storage generation marker")?;
    }
    Ok(())
}
