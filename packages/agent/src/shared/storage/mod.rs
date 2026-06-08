//! Unified engine storage runtime.
//!
//! Tron stores active server data in one engine-owned SQLite database:
//! `~/.tron/internal/database/tron.sqlite`. Runtime connections use WAL for
//! safe concurrent reads/writes; checkpoints and exports create compact
//! single-file artifacts when the operator needs one. The `modular-engine-v4`
//! generation is a clean break for the collapsed substrate: startup moves
//! non-current active DB, WAL, and SHM files aside before creating the grant,
//! resource, ledger, stream, state, queue, grant, lease, compensation, storage,
//! and session-harness tables from the current schema only.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

mod archive;
mod maintenance;
mod payloads;
mod schema;
mod stats;

#[cfg(test)]
mod tests;

pub use archive::{
    archive_non_current_active_database, archive_non_current_database_files,
    prepare_active_database,
};
pub use maintenance::{checkpoint_database, enforce_size_budget, export_snapshot, retention_run};
pub use payloads::{
    decode_blob_content, encode_blob_content, register_existing_blob_owner,
    resolve_stored_json_string, resolve_stored_json_value, store_content_blob, store_json_bytes,
    store_json_value, store_owned_payload_ref,
};
pub use schema::{apply_runtime_pragmas, ensure_storage_schema};
pub use stats::storage_stats;

/// Canonical active database filename.
pub const UNIFIED_DB_FILENAME: &str = "tron.sqlite";

/// Canonical active lock filename.
pub const UNIFIED_LOCK_FILENAME: &str = "tron.sqlite.lock";

/// Current storage generation. A live DB without this marker is archived and
/// reset before startup continues.
pub const CURRENT_STORAGE_GENERATION: &str = "modular-engine-v4";

/// Metadata key storing the active storage generation.
pub const STORAGE_GENERATION_KEY: &str = "storage_generation";

/// Non-current active database artifacts moved aside on first unified startup.
pub const NON_CURRENT_DATABASE_FILES: &[&str] = &[
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

/// Summary of one archived database file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchivedDatabaseFile {
    /// Archived filename.
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
    /// Non-current files moved out of active storage.
    pub files: Vec<ArchivedDatabaseFile>,
}

impl ArchiveReport {
    /// Whether startup moved any non-current database artifacts.
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
    /// Uncompressed size.
    pub uncompressed_size: i64,
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

    /// Move any non-current active DB artifacts aside before startup.
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
