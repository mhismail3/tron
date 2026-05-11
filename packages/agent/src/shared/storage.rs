//! Unified engine storage runtime.
//!
//! Tron stores active server data in one engine-owned SQLite database:
//! `~/.tron/internal/database/tron.sqlite`. Runtime connections use WAL for
//! safe concurrent reads/writes; checkpoints and exports create compact
//! single-file artifacts when the operator needs one. The `payload-ref-v2`
//! generation makes `storage_payload_refs` the only ownership ledger for large
//! payload blobs, so retention can compact diagnostics without deleting
//! correctness/audit payloads still referenced by engine, session, or log rows.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// Canonical active database filename.
pub const UNIFIED_DB_FILENAME: &str = "tron.sqlite";

/// Canonical active lock filename.
pub const UNIFIED_LOCK_FILENAME: &str = "tron.sqlite.lock";

/// Current storage generation. A live DB without this marker is archived and
/// reset before startup continues.
pub const CURRENT_STORAGE_GENERATION: &str = "payload-ref-v2";

/// Metadata key storing the active storage generation.
pub const STORAGE_GENERATION_KEY: &str = "storage_generation";

/// Retired active database artifacts archived on first unified startup.
pub const RETIRED_DATABASE_FILES: &[&str] = &[
    "log.db",
    "log.db-wal",
    "log.db-shm",
    "log.db.lock",
    "engine-ledger.sqlite",
    "engine-ledger.sqlite-wal",
    "engine-ledger.sqlite-shm",
    "tron.db",
    "tron.db-wal",
    "tron.db-shm",
];

/// Default inline payload threshold. Larger payloads should store compact
/// previews and blob refs instead of duplicating full JSON in primary rows.
pub const DEFAULT_MAX_INLINE_PAYLOAD_BYTES: usize = 8 * 1024;

/// Default retention horizon for verbose diagnostic payload refs.
pub const DEFAULT_VERBOSE_RETENTION_DAYS: i64 = 7;

const ZSTD_COMPRESSION_THRESHOLD_BYTES: usize = 1024;

/// Name of the archive directory under `internal/database`.
pub const ARCHIVE_DIR: &str = "archive";

/// Internal storage envelope key for payload-ref-backed JSON columns.
pub const PAYLOAD_REF_ENVELOPE_KEY: &str = "__tronPayloadRef";

/// Summary of one retired file archive operation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchivedDatabaseFile {
    /// Retired filename.
    pub filename: String,
    /// Final archived path.
    pub archived_path: PathBuf,
    /// File size in bytes at archive time.
    pub size_bytes: u64,
}

/// Archive report emitted on startup.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchiveReport {
    /// Archive directory used for this startup, if any files moved.
    pub archive_dir: Option<PathBuf>,
    /// Retired files moved out of active storage.
    pub files: Vec<ArchivedDatabaseFile>,
}

impl ArchiveReport {
    /// Whether startup moved any retired database artifacts.
    #[must_use]
    pub fn moved_any(&self) -> bool {
        !self.files.is_empty()
    }
}

/// Result of a WAL checkpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageCheckpointReport {
    /// Database path checkpointed.
    pub database_path: PathBuf,
    /// SQLite checkpoint mode.
    pub mode: String,
    /// Reported busy pages.
    pub busy: i64,
    /// WAL log pages before/after checkpoint.
    pub log_pages: i64,
    /// Checkpointed pages.
    pub checkpointed_pages: i64,
    /// Size of the `-wal` sidecar after the checkpoint.
    pub wal_bytes: u64,
    /// Timestamp of the operation.
    pub checkpointed_at: String,
}

/// Result of exporting a single-file SQLite snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageExportReport {
    /// Source active database.
    pub source_path: PathBuf,
    /// Snapshot file created by `VACUUM INTO`.
    pub snapshot_path: PathBuf,
    /// Snapshot size in bytes.
    pub snapshot_bytes: u64,
    /// Timestamp of the export.
    pub exported_at: String,
}

/// Result of one retention pass.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageRetentionReport {
    /// Whether this run only counted rows.
    pub dry_run: bool,
    /// Verbose log retention horizon used for this pass.
    pub verbose_retention_days: u64,
    /// Log rows deleted or that would be deleted.
    pub rows_deleted: i64,
    /// Unreferenced blobs deleted or that would be deleted.
    pub blobs_deleted: i64,
    /// Expired payload refs deleted or that would be deleted.
    pub payload_refs_deleted: i64,
    /// Start timestamp.
    pub started_at: String,
    /// Finish timestamp.
    pub finished_at: String,
}

/// Result of checking the soft active database size budget.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageBudgetReport {
    /// Configured soft budget in bytes.
    pub max_database_bytes: u64,
    /// Total active storage bytes before enforcement.
    pub before_total_bytes: u64,
    /// Total active storage bytes after safe retention/checkpoint work.
    pub after_total_bytes: u64,
    /// Whether the pre-enforcement total exceeded the configured budget.
    pub over_limit: bool,
    /// Safe retention pass, when one was needed.
    pub retention: Option<StorageRetentionReport>,
    /// WAL checkpoint, when one was needed.
    pub checkpoint: Option<StorageCheckpointReport>,
}

/// High-signal storage size report.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageStatsReport {
    /// Active database path.
    pub database_path: PathBuf,
    /// Main DB file bytes.
    pub database_bytes: u64,
    /// WAL sidecar bytes.
    pub wal_bytes: u64,
    /// SHM sidecar bytes.
    pub shm_bytes: u64,
    /// SQLite page size.
    pub page_size: i64,
    /// SQLite page count.
    pub page_count: i64,
    /// Total bytes reported by page metadata.
    pub page_bytes: i64,
    /// Table row and page-size estimate summaries.
    pub tables: Vec<TableStorageStats>,
    /// Payload owner/ref summaries.
    pub payload_owners: Vec<PayloadOwnerStorageStats>,
    /// Blob rows that have no owner ref and are not pending.
    pub unowned_blob_count: i64,
    /// Expired pending payload refs.
    pub expired_pending_payload_refs: i64,
    /// Ratio of logical referenced bytes to physical compressed bytes.
    pub blob_dedupe_ratio: Option<f64>,
}

impl StorageStatsReport {
    /// Total bytes occupied by the active DB and runtime WAL/SHM sidecars.
    #[must_use]
    pub fn total_file_bytes(&self) -> u64 {
        self.database_bytes
            .saturating_add(self.wal_bytes)
            .saturating_add(self.shm_bytes)
    }
}

/// Per-table row/byte estimate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableStorageStats {
    /// Table name.
    pub name: String,
    /// Row count, when the table can be counted.
    pub rows: Option<i64>,
    /// Bytes from `dbstat` when available.
    pub bytes: Option<i64>,
}

/// Per-owner payload storage summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PayloadOwnerStorageStats {
    /// Owner kind, such as `engine_invocation` or `session_event`.
    pub owner_kind: String,
    /// Retention class.
    pub retention_class: String,
    /// Number of payload refs.
    pub refs: i64,
    /// Total original payload bytes.
    pub payload_bytes: i64,
    /// Total compressed blob bytes for out-of-line refs.
    pub blob_bytes: i64,
}

/// Compact reference to a payload that may be stored inline or in the blob table.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredPayloadRef {
    /// Stable payload-ref row id.
    pub payload_ref_id: String,
    /// SHA-256 of the original payload bytes.
    pub payload_hash: String,
    /// Blob id when the payload was stored out-of-line.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload_blob_id: Option<String>,
    /// Human-readable compact preview.
    pub payload_preview: String,
    /// Original payload size.
    pub payload_size_bytes: usize,
    /// Payload MIME/kind.
    pub payload_kind: String,
    /// Redaction level applied before storage.
    pub redaction_level: String,
    /// Storage retention class.
    pub retention_class: String,
}

/// Owner and policy metadata for one stored payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorePayloadOptions {
    /// Owner kind, usually the table/logical store name.
    pub owner_kind: String,
    /// Owner id, usually the row primary key.
    pub owner_id: String,
    /// Field name on the owner row.
    pub field_name: String,
    /// Payload MIME/kind.
    pub payload_kind: String,
    /// Redaction level already applied to the bytes.
    pub redaction_level: String,
    /// Retention class.
    pub retention_class: String,
    /// Optional trace id.
    pub trace_id: Option<String>,
    /// Optional session id.
    pub session_id: Option<String>,
    /// Optional workspace id.
    pub workspace_id: Option<String>,
    /// Optional expiry for pending/verbose refs.
    pub expires_at: Option<String>,
    /// Inline threshold.
    pub inline_threshold: usize,
}

impl StorePayloadOptions {
    /// Build standard options for a row/field pair.
    #[must_use]
    pub fn new(
        owner_kind: impl Into<String>,
        owner_id: impl Into<String>,
        field_name: impl Into<String>,
        retention_class: impl Into<String>,
    ) -> Self {
        Self {
            owner_kind: owner_kind.into(),
            owner_id: owner_id.into(),
            field_name: field_name.into(),
            payload_kind: "application/json".to_owned(),
            redaction_level: "redacted".to_owned(),
            retention_class: retention_class.into(),
            trace_id: None,
            session_id: None,
            workspace_id: None,
            expires_at: None,
            inline_threshold: DEFAULT_MAX_INLINE_PAYLOAD_BYTES,
        }
    }

    /// Attach trace/session/workspace metadata.
    #[must_use]
    pub fn with_scope(
        mut self,
        trace_id: Option<String>,
        session_id: Option<String>,
        workspace_id: Option<String>,
    ) -> Self {
        self.trace_id = trace_id;
        self.session_id = session_id;
        self.workspace_id = workspace_id;
        self
    }

    /// Override payload kind.
    #[must_use]
    pub fn with_payload_kind(mut self, payload_kind: impl Into<String>) -> Self {
        self.payload_kind = payload_kind.into();
        self
    }

    /// Override redaction level.
    #[must_use]
    pub fn with_redaction_level(mut self, redaction_level: impl Into<String>) -> Self {
        self.redaction_level = redaction_level.into();
        self
    }

    /// Override inline threshold.
    #[must_use]
    pub fn with_inline_threshold(mut self, inline_threshold: usize) -> Self {
        self.inline_threshold = inline_threshold;
        self
    }

    /// Set expiry timestamp.
    #[must_use]
    pub fn with_expires_at(mut self, expires_at: Option<String>) -> Self {
        self.expires_at = expires_at;
        self
    }
}

/// Encoded blob body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedBlobContent {
    /// Stored bytes.
    pub content: Vec<u8>,
    /// Compression algorithm name.
    pub compression: &'static str,
    /// Original size.
    pub size_original: i64,
    /// Stored size.
    pub size_compressed: i64,
}

/// Runtime handle for one active SQLite storage file.
#[derive(Debug, Clone)]
pub struct StorageRuntime {
    path: PathBuf,
}

impl StorageRuntime {
    /// Create a runtime for the canonical active path.
    #[must_use]
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// Active database path.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Open an operation connection with runtime pragmas.
    pub fn open_connection(&self) -> Result<Connection> {
        let conn = Connection::open(&self.path)
            .with_context(|| format!("failed to open {}", self.path.display()))?;
        apply_runtime_pragmas(&conn)?;
        ensure_storage_schema(&conn)?;
        Ok(conn)
    }

    /// Archive/reset any incompatible active DB and retired artifacts.
    pub fn prepare_for_startup(&self) -> Result<ArchiveReport> {
        prepare_active_database(&self.path)
    }

    /// Run a truncating WAL checkpoint and record it in storage metadata.
    pub fn checkpoint(&self) -> Result<StorageCheckpointReport> {
        checkpoint_database(&self.path)
    }

    /// Export a portable single-file snapshot.
    pub fn export_snapshot(&self, snapshot_path: impl AsRef<Path>) -> Result<StorageExportReport> {
        export_snapshot(&self.path, snapshot_path)
    }

    /// Return high-signal size stats.
    pub fn stats(&self) -> Result<StorageStatsReport> {
        storage_stats(&self.path)
    }

    /// Run storage retention.
    pub fn retention_run(
        &self,
        dry_run: bool,
        verbose_retention_days: u64,
    ) -> Result<StorageRetentionReport> {
        retention_run(&self.path, dry_run, verbose_retention_days)
    }

    /// Enforce the configured soft size budget with safe retention and a WAL
    /// checkpoint. Audit-critical owner refs are never deleted by this path.
    pub fn enforce_size_budget(
        &self,
        max_database_mb: u64,
        verbose_retention_days: u64,
    ) -> Result<StorageBudgetReport> {
        enforce_size_budget(&self.path, max_database_mb, verbose_retention_days)
    }
}

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

/// Move retired active DB files into a timestamped archive folder.
///
/// No migrated data is read from these files. This is a one-way startup cleanup
/// so the runtime has exactly one active database path.
pub fn archive_retired_database_files(active_db_path: &Path) -> Result<ArchiveReport> {
    let Some(database_dir) = active_db_path.parent() else {
        anyhow::bail!(
            "cannot archive retired database files for path without parent: {}",
            active_db_path.display()
        );
    };

    let mut candidates = Vec::new();
    for filename in RETIRED_DATABASE_FILES {
        let path = database_dir.join(filename);
        if path.exists() {
            candidates.push((filename.to_string(), path));
        }
    }

    if candidates.is_empty() {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }

    let archive_dir = database_dir.join(ARCHIVE_DIR).join(format!(
        "unified-{}",
        Utc::now().format("%Y%m%dT%H%M%S%.3fZ")
    ));
    fs::create_dir_all(&archive_dir)
        .with_context(|| format!("failed to create archive dir {}", archive_dir.display()))?;

    let mut archived = Vec::new();
    for (filename, source) in candidates {
        let meta = fs::metadata(&source)
            .with_context(|| format!("failed to inspect retired DB file {}", source.display()))?;
        let destination = archive_dir.join(&filename);
        fs::rename(&source, &destination).with_context(|| {
            format!(
                "failed to archive retired DB file {} to {}",
                source.display(),
                destination.display()
            )
        })?;
        archived.push(ArchivedDatabaseFile {
            filename,
            archived_path: destination,
            size_bytes: meta.len(),
        });
    }

    Ok(ArchiveReport {
        archive_dir: Some(archive_dir),
        files: archived,
    })
}

/// Prepare the active DB path for the current storage generation.
///
/// If `tron.sqlite` already exists without the current generation marker, the
/// DB and WAL/SHM sidecars are archived before the caller opens a fresh file.
/// Retired pre-unified DB files are archived in the same pass.
pub fn prepare_active_database(active_db_path: &Path) -> Result<ArchiveReport> {
    let mut report = archive_incompatible_active_database(active_db_path)?;
    let retired = archive_retired_database_files(active_db_path)?;
    if report.archive_dir.is_none() {
        report.archive_dir = retired.archive_dir;
    }
    report.files.extend(retired.files);
    Ok(report)
}

/// Archive the active DB when its generation marker does not match the current
/// payload-ref storage generation.
pub fn archive_incompatible_active_database(active_db_path: &Path) -> Result<ArchiveReport> {
    if !active_db_path.exists() {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }
    let generation = active_database_generation(active_db_path).unwrap_or(None);
    if generation.as_deref() == Some(CURRENT_STORAGE_GENERATION) {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }
    let wal_filename = format!("{UNIFIED_DB_FILENAME}-wal");
    let shm_filename = format!("{UNIFIED_DB_FILENAME}-shm");
    let archive_name = format!(
        "{}-{}",
        CURRENT_STORAGE_GENERATION,
        Utc::now().format("%Y%m%dT%H%M%S%.3fZ")
    );
    archive_named_files(
        active_db_path,
        &[UNIFIED_DB_FILENAME, &wal_filename, &shm_filename],
        &archive_name,
    )
}

fn active_database_generation(path: &Path) -> Result<Option<String>> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("failed to inspect storage generation {}", path.display()))?;
    let has_metadata: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'storage_metadata'",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);
    if has_metadata == 0 {
        return Ok(None);
    }
    conn.query_row(
        "SELECT value FROM storage_metadata WHERE key = ?1",
        params![STORAGE_GENERATION_KEY],
        |row| row.get::<_, String>(0),
    )
    .optional()
    .context("failed to read storage generation marker")
}

fn archive_named_files(
    active_db_path: &Path,
    filenames: &[&str],
    archive_name: &str,
) -> Result<ArchiveReport> {
    let Some(database_dir) = active_db_path.parent() else {
        anyhow::bail!(
            "cannot archive database files for path without parent: {}",
            active_db_path.display()
        );
    };
    let mut candidates = Vec::new();
    for filename in filenames {
        let path = database_dir.join(filename);
        if path.exists() {
            candidates.push(((*filename).to_owned(), path));
        }
    }
    if candidates.is_empty() {
        return Ok(ArchiveReport {
            archive_dir: None,
            files: Vec::new(),
        });
    }
    let archive_dir = database_dir.join(ARCHIVE_DIR).join(archive_name);
    fs::create_dir_all(&archive_dir)
        .with_context(|| format!("failed to create archive dir {}", archive_dir.display()))?;
    let mut archived = Vec::new();
    for (filename, source) in candidates {
        let meta = fs::metadata(&source)
            .with_context(|| format!("failed to inspect DB file {}", source.display()))?;
        let destination = archive_dir.join(&filename);
        fs::rename(&source, &destination).with_context(|| {
            format!(
                "failed to archive DB file {} to {}",
                source.display(),
                destination.display()
            )
        })?;
        archived.push(ArchivedDatabaseFile {
            filename,
            archived_path: destination,
            size_bytes: meta.len(),
        });
    }
    Ok(ArchiveReport {
        archive_dir: Some(archive_dir),
        files: archived,
    })
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
           size_original   INTEGER NOT NULL,
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

/// Store bytes in the shared content-addressed blob table.
pub fn store_content_blob(conn: &Connection, content: &[u8], mime_type: &str) -> Result<String> {
    let hash = hex_sha256(content);
    if let Some(existing) = conn
        .query_row(
            "SELECT id FROM blobs WHERE hash = ?1",
            params![hash],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .context("failed to query existing payload blob")?
    {
        let _ = conn.execute(
            "UPDATE blobs SET ref_count = ref_count + 1 WHERE id = ?1",
            params![existing],
        )?;
        return Ok(existing);
    }

    let id = format!("blob_{}", Uuid::now_v7());
    let encoded = encode_blob_content(content);
    conn.execute(
        "INSERT INTO blobs
         (id, hash, content, mime_type, size_original, size_compressed, compression, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            id,
            hash,
            encoded.content,
            mime_type,
            encoded.size_original,
            encoded.size_compressed,
            encoded.compression,
            Utc::now().to_rfc3339()
        ],
    )
    .context("failed to store payload blob")?;
    Ok(id)
}

/// Encode bytes for blob storage.
#[must_use]
pub fn encode_blob_content(content: &[u8]) -> EncodedBlobContent {
    if content.len() >= ZSTD_COMPRESSION_THRESHOLD_BYTES
        && let Ok(compressed) = zstd::bulk::compress(content, 3)
        && compressed.len() < content.len()
    {
        return EncodedBlobContent {
            size_original: i64::try_from(content.len()).unwrap_or(i64::MAX),
            size_compressed: i64::try_from(compressed.len()).unwrap_or(i64::MAX),
            content: compressed,
            compression: "zstd",
        };
    }
    EncodedBlobContent {
        size_original: i64::try_from(content.len()).unwrap_or(i64::MAX),
        size_compressed: i64::try_from(content.len()).unwrap_or(i64::MAX),
        content: content.to_vec(),
        compression: "none",
    }
}

/// Decode bytes from blob storage.
pub fn decode_blob_content(
    content: &[u8],
    compression: &str,
    original_size: i64,
) -> Result<Vec<u8>> {
    match compression {
        "none" => Ok(content.to_vec()),
        "zstd" => zstd::bulk::decompress(
            content,
            usize::try_from(original_size).unwrap_or(usize::MAX),
        )
        .context("failed to decode zstd blob"),
        other => anyhow::bail!("unsupported blob compression {other}"),
    }
}

/// Store a payload with explicit ownership metadata.
pub fn store_owned_payload_ref(
    conn: &Connection,
    payload: &[u8],
    options: &StorePayloadOptions,
) -> Result<StoredPayloadRef> {
    ensure_storage_schema(conn)?;
    let hash = hex_sha256(payload);
    let preview = payload_preview(payload, 512);
    let existing: Option<(String, Option<String>)> = conn
        .query_row(
            "SELECT id, payload_blob_id FROM storage_payload_refs
             WHERE owner_kind = ?1 AND owner_id = ?2 AND field_name = ?3",
            params![options.owner_kind, options.owner_id, options.field_name],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()
        .context("failed to query existing payload ref")?;
    let blob_id = if payload.len() > options.inline_threshold {
        if let Some((_, Some(existing_blob_id))) = existing.as_ref()
            && blob_hash_matches(conn, existing_blob_id, &hash)?
        {
            Some(existing_blob_id.clone())
        } else {
            Some(store_content_blob(conn, payload, &options.payload_kind)?)
        }
    } else {
        None
    };
    let payload_ref_id = existing
        .as_ref()
        .map(|row| row.0.clone())
        .unwrap_or_else(|| format!("payload_ref_{}", Uuid::now_v7()));
    let created_at = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO storage_payload_refs (
           id, owner_kind, owner_id, field_name, payload_hash, payload_blob_id,
           payload_preview, payload_size_bytes, payload_kind, redaction_level,
           retention_class, trace_id, session_id, workspace_id, expires_at, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
         ON CONFLICT(owner_kind, owner_id, field_name) DO UPDATE SET
           payload_hash = excluded.payload_hash,
           payload_blob_id = excluded.payload_blob_id,
           payload_preview = excluded.payload_preview,
           payload_size_bytes = excluded.payload_size_bytes,
           payload_kind = excluded.payload_kind,
           redaction_level = excluded.redaction_level,
           retention_class = excluded.retention_class,
           trace_id = excluded.trace_id,
           session_id = excluded.session_id,
           workspace_id = excluded.workspace_id,
           expires_at = excluded.expires_at",
        params![
            payload_ref_id,
            options.owner_kind,
            options.owner_id,
            options.field_name,
            hash,
            blob_id,
            preview,
            i64::try_from(payload.len()).unwrap_or(i64::MAX),
            options.payload_kind,
            options.redaction_level,
            options.retention_class,
            options.trace_id,
            options.session_id,
            options.workspace_id,
            options.expires_at,
            created_at,
        ],
    )
    .context("failed to record payload ref owner")?;
    if let Some((_, Some(old_blob_id))) = existing
        && blob_id.as_deref() != Some(old_blob_id.as_str())
    {
        let _ = conn.execute(
            "UPDATE blobs SET ref_count = CASE WHEN ref_count > 0 THEN ref_count - 1 ELSE 0 END
             WHERE id = ?1",
            params![old_blob_id],
        )?;
    }
    Ok(StoredPayloadRef {
        payload_ref_id,
        payload_hash: hash,
        payload_blob_id: blob_id,
        payload_preview: preview,
        payload_size_bytes: payload.len(),
        payload_kind: options.payload_kind.clone(),
        redaction_level: options.redaction_level.clone(),
        retention_class: options.retention_class.clone(),
    })
}

fn blob_hash_matches(conn: &Connection, blob_id: &str, expected_hash: &str) -> Result<bool> {
    let stored_hash = conn
        .query_row(
            "SELECT hash FROM blobs WHERE id = ?1",
            params![blob_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .context("failed to inspect existing payload blob hash")?;
    Ok(stored_hash.as_deref() == Some(expected_hash))
}

/// Store a JSON value for a DB row, returning either inline JSON or a compact
/// internal payload-ref envelope.
pub fn store_json_value(
    conn: &Connection,
    value: &serde_json::Value,
    options: &StorePayloadOptions,
) -> Result<String> {
    let bytes = serde_json::to_vec(value).context("failed to serialize JSON payload")?;
    store_json_bytes(conn, &bytes, options)
}

/// Store already-serialized JSON bytes for a DB row.
pub fn store_json_bytes(
    conn: &Connection,
    json_bytes: &[u8],
    options: &StorePayloadOptions,
) -> Result<String> {
    let reference = store_owned_payload_ref(conn, json_bytes, options)?;
    if json_bytes.len() <= options.inline_threshold {
        String::from_utf8(json_bytes.to_vec()).context("stored JSON bytes were not UTF-8")
    } else {
        serde_json::to_string(&serde_json::json!({ PAYLOAD_REF_ENVELOPE_KEY: reference }))
            .context("failed to serialize payload ref envelope")
    }
}

/// Resolve a stored JSON column that may contain an internal payload-ref
/// envelope back to the original JSON value.
pub fn resolve_stored_json_value(
    conn: &Connection,
    stored_json: &str,
) -> Result<serde_json::Value> {
    if let Some(bytes) = resolve_payload_ref_envelope(conn, stored_json)? {
        return serde_json::from_slice(&bytes).context("failed to parse blob-backed JSON payload");
    }
    serde_json::from_str(stored_json).context("failed to parse inline JSON payload")
}

/// Resolve a stored JSON column back to original serialized JSON.
pub fn resolve_stored_json_string(conn: &Connection, stored_json: &str) -> Result<String> {
    if let Some(bytes) = resolve_payload_ref_envelope(conn, stored_json)? {
        return String::from_utf8(bytes).context("blob-backed JSON payload was not UTF-8");
    }
    Ok(stored_json.to_owned())
}

/// Register an existing blob as owned by its own domain/product blob id.
pub fn register_existing_blob_owner(
    conn: &Connection,
    blob_id: &str,
    owner_kind: &str,
    field_name: &str,
    retention_class: &str,
) -> Result<()> {
    ensure_storage_schema(conn)?;
    let (hash, size_original, mime_type): (String, i64, String) = conn
        .query_row(
            "SELECT hash, size_original, mime_type FROM blobs WHERE id = ?1",
            params![blob_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .context("failed to lookup existing blob owner payload")?;
    let payload_ref_id = format!("payload_ref_{}", Uuid::now_v7());
    conn.execute(
        "INSERT OR IGNORE INTO storage_payload_refs (
           id, owner_kind, owner_id, field_name, payload_hash, payload_blob_id,
           payload_preview, payload_size_bytes, payload_kind, redaction_level,
           retention_class, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, '', ?7, ?8, 'binary', ?9, ?10)",
        params![
            payload_ref_id,
            owner_kind,
            blob_id,
            field_name,
            hash,
            blob_id,
            size_original,
            mime_type,
            retention_class,
            Utc::now().to_rfc3339(),
        ],
    )
    .context("failed to register existing blob owner")?;
    Ok(())
}

fn resolve_payload_ref_envelope(conn: &Connection, stored_json: &str) -> Result<Option<Vec<u8>>> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(stored_json) else {
        return Ok(None);
    };
    let Some(reference) = value.get(PAYLOAD_REF_ENVELOPE_KEY) else {
        return Ok(None);
    };
    let Some(blob_id) = reference
        .get("payloadBlobId")
        .or_else(|| reference.get("payload_blob_id"))
        .and_then(serde_json::Value::as_str)
    else {
        return Ok(None);
    };
    let (content, compression, original_size): (Vec<u8>, String, i64) = conn
        .query_row(
            "SELECT content, compression, size_original FROM blobs WHERE id = ?1",
            params![blob_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .with_context(|| format!("failed to load payload blob {blob_id}"))?;
    decode_blob_content(&content, &compression, original_size).map(Some)
}

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
    let rows_deleted = if table_exists(&conn, "logs")? {
        let count = conn
            .query_row(
                "SELECT COUNT(*) FROM logs
                 WHERE origin = 'ios-client'
                   AND lower(level) IN ('trace', 'debug')
                   AND timestamp < ?1",
                params![cutoff],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0);
        if !dry_run && count > 0 {
            let _ = conn.execute(
                "DELETE FROM logs
                 WHERE origin = 'ios-client'
                   AND lower(level) IN ('trace', 'debug')
                   AND timestamp < ?1",
                params![cutoff],
            )?;
        }
        count
    } else {
        0
    };
    let expired_refs_deleted = if table_exists(&conn, "storage_payload_refs")? {
        let count = conn
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE retention_class IN ('diagnostic_verbose', 'pending')
                   AND expires_at IS NOT NULL
                   AND expires_at < ?1",
                params![Utc::now().to_rfc3339()],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0);
        if !dry_run && count > 0 {
            let _ = conn.execute(
                "DELETE FROM storage_payload_refs
                 WHERE retention_class IN ('diagnostic_verbose', 'pending')
                   AND expires_at IS NOT NULL
                   AND expires_at < ?1",
                params![Utc::now().to_rfc3339()],
            )?;
        }
        count
    } else {
        0
    };
    let blobs_deleted = if table_exists(&conn, "blobs")? {
        let count = conn
            .query_row(
                "SELECT COUNT(*) FROM blobs
                 WHERE NOT EXISTS (
                   SELECT 1 FROM storage_payload_refs refs
                   WHERE refs.payload_blob_id = blobs.id
                 )",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0);
        if !dry_run && count > 0 {
            let _ = conn.execute(
                "DELETE FROM blobs
                 WHERE NOT EXISTS (
                   SELECT 1 FROM storage_payload_refs refs
                   WHERE refs.payload_blob_id = blobs.id
                 )",
                [],
            )?;
        }
        count
    } else {
        0
    };
    let finished_at = Utc::now().to_rfc3339();
    if !dry_run {
        conn.execute(
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
        let _ =
            conn.query_row::<(i64, i64, i64), _, _>("PRAGMA wal_checkpoint(PASSIVE)", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            });
    }
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

fn table_exists(conn: &Connection, table_name: &str) -> Result<bool> {
    let exists = conn
        .query_row(
            "SELECT EXISTS (
               SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1
             )",
            params![table_name],
            |row| row.get::<_, i64>(0),
        )
        .context("failed to inspect SQLite tables")?;
    Ok(exists != 0)
}

fn payload_preview(payload: &[u8], max_chars: usize) -> String {
    let text = String::from_utf8_lossy(payload);
    let mut preview = text.chars().take(max_chars).collect::<String>();
    if text.chars().count() > max_chars {
        preview.push_str("...");
    }
    preview
}

fn hex_sha256(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    format!("{:x}", hasher.finalize())
}

fn wal_path(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}-wal", path.to_string_lossy()))
}

fn shm_path(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}-shm", path.to_string_lossy()))
}

fn file_len(path: &Path) -> u64 {
    fs::metadata(path).map_or(0, |meta| meta.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archives_retired_files_once() {
        let dir = tempfile::tempdir().unwrap();
        let active = dir.path().join(UNIFIED_DB_FILENAME);
        fs::write(dir.path().join("log.db"), b"log").unwrap();
        fs::write(dir.path().join("engine-ledger.sqlite"), b"ledger").unwrap();

        let report = archive_retired_database_files(&active).unwrap();
        assert!(report.moved_any());
        assert_eq!(report.files.len(), 2);
        assert!(!dir.path().join("log.db").exists());
        assert!(!dir.path().join("engine-ledger.sqlite").exists());
        assert!(
            report
                .archive_dir
                .as_ref()
                .expect("archive dir")
                .join("log.db")
                .exists()
        );

        let second = archive_retired_database_files(&active).unwrap();
        assert!(!second.moved_any());
    }

    #[test]
    fn incompatible_active_database_is_archived_for_payload_ref_generation() {
        let dir = tempfile::tempdir().unwrap();
        let active = dir.path().join(UNIFIED_DB_FILENAME);
        {
            let conn = Connection::open(&active).unwrap();
            conn.execute_batch("CREATE TABLE old_shape (id INTEGER PRIMARY KEY);")
                .unwrap();
        }
        fs::write(wal_path(&active), b"wal").unwrap();
        fs::write(shm_path(&active), b"shm").unwrap();

        let report = prepare_active_database(&active).unwrap();
        assert!(report.moved_any());
        assert!(!active.exists());
        assert!(!wal_path(&active).exists());
        assert!(!shm_path(&active).exists());
        let archive_dir = report.archive_dir.unwrap();
        let archive_name = archive_dir
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap();
        assert!(archive_name.starts_with(CURRENT_STORAGE_GENERATION));
        assert!(archive_dir.join(UNIFIED_DB_FILENAME).exists());
    }

    #[test]
    fn current_generation_database_is_not_archived() {
        let dir = tempfile::tempdir().unwrap();
        let active = dir.path().join(UNIFIED_DB_FILENAME);
        let runtime = StorageRuntime::new(&active);
        let conn = runtime.open_connection().unwrap();
        drop(conn);

        let report = prepare_active_database(&active).unwrap();
        assert!(!report.moved_any());
        assert!(active.exists());
    }

    #[test]
    fn owned_payload_refs_inline_small_and_blob_large_payloads() {
        let conn = Connection::open_in_memory().unwrap();
        apply_runtime_pragmas(&conn).unwrap();
        ensure_storage_schema(&conn).unwrap();

        let small = serde_json::json!({"hello": "world"});
        let small_stored = store_json_value(
            &conn,
            &small,
            &StorePayloadOptions::new("test_owner", "row-small", "payload", "audit")
                .with_inline_threshold(100),
        )
        .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&small_stored).unwrap(),
            small
        );

        let large = serde_json::json!({"items": vec!["same"; 64]});
        let large_stored = store_json_value(
            &conn,
            &large,
            &StorePayloadOptions::new("test_owner", "row-large", "payload", "audit")
                .with_inline_threshold(32),
        )
        .unwrap();
        assert!(large_stored.contains(PAYLOAD_REF_ENVELOPE_KEY));
        assert_eq!(
            resolve_stored_json_value(&conn, &large_stored).unwrap(),
            large
        );

        let refs: i64 = conn
            .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
                row.get(0)
            })
            .unwrap();
        let blobs: i64 = conn
            .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(refs, 2);
        assert_eq!(blobs, 1);
    }

    #[test]
    fn checkpoint_and_export_use_one_active_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(UNIFIED_DB_FILENAME);
        let runtime = StorageRuntime::new(&path);
        let conn = runtime.open_connection().unwrap();
        conn.execute(
            "CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)",
            [],
        )
        .unwrap();
        conn.execute("INSERT INTO sample (value) VALUES ('x')", [])
            .unwrap();
        drop(conn);

        let checkpoint = runtime.checkpoint().unwrap();
        assert_eq!(checkpoint.database_path, path);

        let snapshot = dir.path().join("snapshots").join("tron-snapshot.sqlite");
        let export = runtime.export_snapshot(&snapshot).unwrap();
        assert!(export.snapshot_bytes > 0);
        assert!(snapshot.exists());
    }

    #[test]
    fn retention_prunes_verbose_ios_logs_and_unowned_blobs_but_keeps_owned_blobs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(UNIFIED_DB_FILENAME);
        let runtime = StorageRuntime::new(&path);
        let conn = runtime.open_connection().unwrap();
        conn.execute_batch(
            "CREATE TABLE logs (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               timestamp TEXT NOT NULL,
               level TEXT NOT NULL,
               origin TEXT
             );",
        )
        .unwrap();
        let blob_id = store_content_blob(&conn, b"unreferenced payload", "text/plain").unwrap();
        conn.execute(
            "UPDATE blobs SET ref_count = 0 WHERE id = ?1",
            params![blob_id],
        )
        .unwrap();
        let owned = store_json_bytes(
            &conn,
            br#"{"large":"owned"}"#,
            &StorePayloadOptions::new("engine_invocation", "inv_1", "result", "audit")
                .with_inline_threshold(1),
        )
        .unwrap();
        assert!(owned.contains(PAYLOAD_REF_ENVELOPE_KEY));
        conn.execute(
            "INSERT INTO logs (timestamp, level, origin) VALUES (?1, 'debug', 'ios-client')",
            params![(Utc::now() - chrono::Duration::days(10)).to_rfc3339()],
        )
        .unwrap();
        drop(conn);

        let report = runtime.retention_run(false, 1).unwrap();
        assert_eq!(report.rows_deleted, 1);
        assert_eq!(report.blobs_deleted, 1);
        assert_eq!(report.payload_refs_deleted, 0);
        let remaining_blobs: i64 = runtime
            .open_connection()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(remaining_blobs, 1);
    }

    #[test]
    fn size_budget_runs_safe_retention_and_checkpoint_without_dropping_audit_refs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(UNIFIED_DB_FILENAME);
        let runtime = StorageRuntime::new(&path);
        let conn = runtime.open_connection().unwrap();
        conn.execute_batch(
            "CREATE TABLE logs (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               timestamp TEXT NOT NULL,
               level TEXT NOT NULL,
               origin TEXT
             );
             CREATE TABLE filler (payload BLOB NOT NULL);",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO filler (payload) VALUES (?1)",
            params![vec![7_u8; 2 * 1024 * 1024]],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO logs (timestamp, level, origin) VALUES (?1, 'debug', 'ios-client')",
            params![(Utc::now() - chrono::Duration::days(10)).to_rfc3339()],
        )
        .unwrap();
        let owned = store_json_bytes(
            &conn,
            br#"{"audit":"must stay"}"#,
            &StorePayloadOptions::new("engine_invocation", "inv_budget", "result", "audit")
                .with_inline_threshold(1),
        )
        .unwrap();
        assert!(owned.contains(PAYLOAD_REF_ENVELOPE_KEY));
        drop(conn);

        let report = runtime.enforce_size_budget(1, 1).unwrap();
        assert!(report.over_limit);
        assert!(report.retention.is_some());
        assert!(report.checkpoint.is_some());

        let conn = runtime.open_connection().unwrap();
        let audit_refs: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE owner_kind = 'engine_invocation'
                   AND owner_id = 'inv_budget'
                   AND retention_class = 'audit'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(audit_refs, 1);
    }
}
