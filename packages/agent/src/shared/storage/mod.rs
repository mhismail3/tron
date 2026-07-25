//! Unified engine storage runtime.
//!
//! Tron stores active engine data in `tron.sqlite` and durable worker
//! operations in `workers.sqlite`. Both ledgers reuse this generic
//! content-addressed payload schema; ownership rows never cross databases.
//! Runtime connections use WAL for safe concurrent reads/writes; checkpoints
//! and exports create compact single-file artifacts when the operator needs
//! one. Payload references expose only semantic previews from conventional
//! summary/answer fields or structural JSON counts; they never copy an
//! arbitrary serialized object prefix back into run lists or model context.
//! Shared schema setup runs behind a savepoint with drift and
//! payload-reference integrity checks.
//! Startup and manual cleanup share one managed diagnostic horizon and active
//! database budget. Those bounds prune only low-signal diagnostic data and
//! unowned blobs; they are not chat, session, or memory retention policy.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

mod maintenance;
mod payloads;
mod schema;
mod stats;

#[cfg(test)]
mod tests;

pub use maintenance::{checkpoint_database, export_snapshot};
pub use payloads::{
    decode_blob_content, delete_owned_payload_refs, delete_unowned_blobs, encode_blob_content,
    owned_payload_ref, register_existing_blob_owner, resolve_owned_json_value,
    resolve_stored_json_string, resolve_stored_json_value, store_content_blob, store_json_bytes,
    store_json_value, store_owned_payload_ref,
};
pub use schema::{apply_runtime_pragmas, ensure_storage_schema};
pub use stats::storage_stats;

/// Canonical active database filename.
pub const UNIFIED_DB_FILENAME: &str = "tron.sqlite";

/// Managed retention horizon for verbose diagnostic evidence.
pub const DIAGNOSTIC_RETENTION_DAYS: u64 = 7;

/// Managed soft budget for the active engine database.
pub const DATABASE_STORAGE_BUDGET_MB: u64 = 512;

const ZSTD_COMPRESSION_THRESHOLD_BYTES: usize = 1024;

/// Internal storage envelope key for payload-ref-backed JSON columns.
pub const PAYLOAD_REF_ENVELOPE_KEY: &str = "__tronPayloadRef";

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
    /// Diagnostic retention horizon used for this pass.
    pub diagnostic_retention_days: u64,
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
    /// Whether the pre-enforcement total exceeded the managed budget.
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
            inline_threshold:
                crate::shared::protocol::model_tools::DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES,
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

    /// Override redaction level.
    #[must_use]
    pub fn with_redaction_level(mut self, redaction_level: impl Into<String>) -> Self {
        self.redaction_level = redaction_level.into();
        self
    }

    /// Override inline threshold in storage branch tests.
    #[cfg(test)]
    #[must_use]
    pub(crate) fn with_inline_threshold(mut self, inline_threshold: usize) -> Self {
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
        crate::shared::foundation::home::set_private_file_permissions(&self.path)
            .with_context(|| format!("failed to secure {}", self.path.display()))?;
        apply_runtime_pragmas(&conn)?;
        ensure_storage_schema(&conn)?;
        Ok(conn)
    }

    /// Run a truncating WAL checkpoint and return its result.
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
    pub fn retention_run(&self, dry_run: bool) -> Result<StorageRetentionReport> {
        maintenance::retention_run(&self.path, dry_run, DIAGNOSTIC_RETENTION_DAYS)
    }

    /// Enforce the managed soft size budget with safe retention and a WAL
    /// checkpoint. Audit-critical owner refs are never deleted by this path.
    pub fn enforce_size_budget(&self) -> Result<StorageBudgetReport> {
        maintenance::enforce_size_budget(
            &self.path,
            DATABASE_STORAGE_BUDGET_MB,
            DIAGNOSTIC_RETENTION_DAYS,
        )
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
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(payload) else {
        return truncate_preview(&String::from_utf8_lossy(payload), max_chars);
    };
    let preview = match &value {
        serde_json::Value::Object(fields) => {
            let identity = ["schema", "status"]
                .into_iter()
                .filter_map(|key| fields.get(key).and_then(serde_json::Value::as_str))
                .collect::<Vec<_>>();
            let narrative = ["summary", "answer", "report", "result", "message", "title"]
                .into_iter()
                .find_map(|key| semantic_preview_text(fields.get(key)?))
                .or_else(|| fields.get("question").and_then(semantic_preview_text));
            match (identity.is_empty(), narrative) {
                (false, Some(narrative)) => {
                    format!("{} · {narrative}", identity.join(" · "))
                }
                (true, Some(narrative)) => narrative,
                (false, None) => identity.join(" · "),
                (true, None) => format!("JSON object ({} fields)", fields.len()),
            }
        }
        serde_json::Value::Array(values) => format!("JSON array ({} items)", values.len()),
        serde_json::Value::String(text) => text.clone(),
        value => value.to_string(),
    };
    truncate_preview(&preview, max_chars)
}

fn semantic_preview_text(value: &serde_json::Value) -> Option<String> {
    value.as_str().map(ToOwned::to_owned).or_else(|| {
        value
            .as_object()
            .and_then(|value| value.get("content"))
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned)
    })
}

fn truncate_preview(text: &str, max_chars: usize) -> String {
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
