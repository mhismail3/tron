//! Canonical worker bundles and their durable operational ledger.
//!
//! [`WorkerStore`] is the single persistence owner. Publication, lifecycle,
//! invocation, trigger, and state concerns extend that same store without
//! repository wrappers or duplicate caches. Stateless codecs, validators, and
//! SQL helpers live in `support`; scenario tests live in `tests`.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::types::{
    ActiveWorker, BUNDLE_SCHEMA, InvocationRecord, MAX_INVOCATION_SECONDS, PreparedWorker,
    UpsertOutcome, WebhookCredential, WorkerBundle, WorkerCommand, WorkerRunner, WorkerState,
    WorkerSummary, WorkerTrigger,
};
pub(super) use state::validate_bundle;
use support::*;

mod invocations;
mod lifecycle;
mod publication;
mod state;
mod support;
mod triggers;

#[derive(Clone)]
pub struct WorkerStore {
    home: PathBuf,
    root: PathBuf,
    database: PathBuf,
}

struct RemoveDirectoryOnDrop(Option<PathBuf>);

impl RemoveDirectoryOnDrop {
    fn disarm(&mut self) {
        self.0 = None;
    }

    fn cleanup_now(&mut self) -> Result<(), String> {
        let Some(path) = self.0.take() else {
            return Ok(());
        };
        fs::remove_dir_all(&path)
            .map_err(|error| format!("remove unpublished worker tree {}: {error}", path.display()))
    }
}

impl Drop for RemoveDirectoryOnDrop {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = fs::remove_dir_all(path);
        }
    }
}

impl WorkerStore {
    pub fn open(home: PathBuf) -> Result<Self, String> {
        let root = home
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::WORKERS);
        let database = home
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::DB)
            .join("workers.sqlite");
        fs::create_dir_all(&root).map_err(|error| format!("create worker root: {error}"))?;
        if let Some(parent) = database.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create worker database directory: {error}"))?;
        }
        let store = Self {
            home,
            root,
            database,
        };
        store.initialize()?;
        Ok(store)
    }

    #[cfg(test)]
    pub fn open_without_snapshot(home: PathBuf) -> Result<Self, String> {
        let root = home
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::WORKERS);
        let database = home
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::DB)
            .join("workers.sqlite");
        fs::create_dir_all(&root).map_err(|error| error.to_string())?;
        if let Some(parent) = database.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let store = Self {
            home,
            root,
            database,
        };
        store.initialize()?;
        Ok(store)
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    fn connection(&self) -> Result<Connection, String> {
        let connection = Connection::open(&self.database)
            .map_err(|error| format!("open worker database: {error}"))?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .map_err(|error| format!("configure worker database timeout: {error}"))?;
        let _ = connection.pragma_update(None, "journal_mode", "WAL");
        let _ = connection.pragma_update(None, "foreign_keys", "ON");
        Ok(connection)
    }

    fn initialize(&self) -> Result<(), String> {
        self.connection()?
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS worker_schema (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL
                );
                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (2, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (3, strftime('%Y-%m-%dT%H:%M:%fZ','now'));

                CREATE TABLE IF NOT EXISTS workers (
                    worker_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    tool_name TEXT NOT NULL UNIQUE,
                    runner_kind TEXT NOT NULL,
                    active_version TEXT NOT NULL,
                    enabled INTEGER NOT NULL,
                    retired INTEGER NOT NULL,
                    health TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS worker_versions (
                    worker_id TEXT NOT NULL,
                    version TEXT NOT NULL,
                    manifest_json TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(worker_id, version),
                    FOREIGN KEY(worker_id) REFERENCES workers(worker_id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS worker_routes (
                    worker_id TEXT PRIMARY KEY,
                    worker_version TEXT NOT NULL,
                    tool_name TEXT NOT NULL UNIQUE,
                    description TEXT NOT NULL,
                    routing_json TEXT NOT NULL,
                    enabled INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY(worker_id) REFERENCES workers(worker_id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS worker_triggers (
                    worker_id TEXT NOT NULL,
                    trigger_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    config_json TEXT NOT NULL,
                    token_hash TEXT,
                    next_run_at TEXT,
                    stream_cursor INTEGER NOT NULL DEFAULT 0,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY(worker_id, trigger_id),
                    FOREIGN KEY(worker_id) REFERENCES workers(worker_id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS worker_invocations (
                    invocation_id TEXT PRIMARY KEY,
                    worker_id TEXT NOT NULL,
                    worker_version TEXT NOT NULL,
                    status TEXT NOT NULL,
                    input_json TEXT NOT NULL,
                    output_json TEXT,
                    error TEXT,
                    idempotency_key TEXT NOT NULL,
                    trace_id TEXT NOT NULL,
                    causal_depth INTEGER NOT NULL,
                    trigger_kind TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    started_at TEXT,
                    completed_at TEXT,
                    UNIQUE(worker_id, idempotency_key)
                );
                CREATE INDEX IF NOT EXISTS worker_invocations_status
                    ON worker_invocations(status, created_at);
                CREATE TABLE IF NOT EXISTS worker_attempts (
                    attempt_id TEXT PRIMARY KEY,
                    invocation_id TEXT NOT NULL,
                    attempt_number INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    completed_at TEXT,
                    error TEXT,
                    UNIQUE(invocation_id, attempt_number),
                    FOREIGN KEY(invocation_id) REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS worker_attempts_invocation
                    ON worker_attempts(invocation_id, attempt_number);
                CREATE TABLE IF NOT EXISTS worker_causal_traces (
                    trace_id TEXT PRIMARY KEY,
                    root_invocation_id TEXT,
                    max_causal_depth INTEGER NOT NULL,
                    invocation_count INTEGER NOT NULL,
                    suppressed_count INTEGER NOT NULL,
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS worker_trace_deliveries (
                    trace_id TEXT NOT NULL,
                    worker_id TEXT NOT NULL,
                    trigger_kind TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    invocation_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(trace_id, worker_id, trigger_kind, idempotency_key),
                    FOREIGN KEY(invocation_id) REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS worker_inbox (
                    inbox_id TEXT PRIMARY KEY,
                    invocation_id TEXT NOT NULL,
                    worker_id TEXT NOT NULL,
                    severity TEXT NOT NULL,
                    result_json TEXT NOT NULL,
                    seen INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS worker_inbox_worker
                    ON worker_inbox(worker_id, seen, created_at DESC);
                CREATE TABLE IF NOT EXISTS worker_audit (
                    audit_id TEXT PRIMARY KEY,
                    worker_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    details_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS worker_audit_worker
                    ON worker_audit(worker_id, created_at DESC);
                CREATE TABLE IF NOT EXISTS worker_health (
                    health_id TEXT PRIMARY KEY,
                    worker_id TEXT NOT NULL,
                    worker_version TEXT NOT NULL,
                    status TEXT NOT NULL,
                    source TEXT NOT NULL,
                    details_json TEXT NOT NULL,
                    recorded_at TEXT NOT NULL,
                    FOREIGN KEY(worker_id) REFERENCES workers(worker_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS worker_health_worker
                    ON worker_health(worker_id, recorded_at DESC);
                CREATE TABLE IF NOT EXISTS worker_runtime_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                INSERT OR IGNORE INTO worker_runtime_settings(key, value)
                    VALUES ('stop_all', 'false');
                ",
            )
            .map_err(|error| format!("initialize worker database: {error}"))?;
        super::migration::rebuild_indexes(&self.root, &self.database)?;
        self.recover_interrupted()
    }

    fn recover_interrupted(&self) -> Result<(), String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start interrupted worker recovery: {error}"))?;
        transaction
            .execute(
                "UPDATE worker_attempts SET status='interrupted',completed_at=?1,
                    error='delivery interrupted before a durable terminal result'
                 WHERE status='running'",
                [chrono::Utc::now().to_rfc3339()],
            )
            .map_err(|error| format!("recover interrupted worker attempts: {error}"))?;
        transaction
            .execute(
                "UPDATE worker_invocations SET status='queued', started_at=NULL
                 WHERE status='running'",
                [],
            )
            .map_err(|error| format!("recover interrupted worker invocations: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit interrupted worker recovery: {error}"))
    }
}

#[cfg(test)]
mod tests;
