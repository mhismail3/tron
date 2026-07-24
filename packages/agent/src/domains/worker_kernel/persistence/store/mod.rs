//! Canonical worker bundles and their durable operational ledger.
//!
//! [`WorkerStore`] is the single persistence owner. Publication, lifecycle,
//! invocation, bounded history, interaction/causal relationship, trigger, and
//! state concerns extend that same store without repository wrappers or
//! duplicate caches. Stateless codecs, validators, and SQL helpers live in
//! `support`; scenario tests live in `tests`.

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
    UpsertOutcome, WebhookCredential, WorkerBundle, WorkerClientAction, WorkerCommand,
    WorkerEngineHook, WorkerInteractionMode, WorkerRunEvent, WorkerRunStage, WorkerRunner,
    WorkerState, WorkerSummary, WorkerTrigger,
};
pub(super) use state::validate_bundle;
use support::*;

mod history;
mod interaction;
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
    state_root: PathBuf,
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
        let _ = super::snapshot::ensure_worker_schema_snapshot(&home, 8)?;
        let root = home
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::WORKERS);
        let state_root = home
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::WORKER_STATE);
        let database = home
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::DB)
            .join("workers.sqlite");
        fs::create_dir_all(&root).map_err(|error| format!("create worker root: {error}"))?;
        crate::shared::foundation::home::set_private_directory_permissions(&root)
            .map_err(|error| format!("secure worker root: {error}"))?;
        fs::create_dir_all(&state_root)
            .map_err(|error| format!("create worker state root: {error}"))?;
        crate::shared::foundation::home::set_private_directory_permissions(&state_root)
            .map_err(|error| format!("secure worker state root: {error}"))?;
        if let Some(parent) = database.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create worker database directory: {error}"))?;
            crate::shared::foundation::home::set_private_directory_permissions(parent)
                .map_err(|error| format!("secure worker database directory: {error}"))?;
        }
        let store = Self {
            home,
            root,
            state_root,
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
        let state_root = home
            .join(crate::shared::foundation::paths::dirs::WORKSPACE)
            .join(crate::shared::foundation::paths::dirs::WORKER_STATE);
        let database = home
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::DB)
            .join("workers.sqlite");
        fs::create_dir_all(&root).map_err(|error| error.to_string())?;
        crate::shared::foundation::home::set_private_directory_permissions(&root)
            .map_err(|error| error.to_string())?;
        fs::create_dir_all(&state_root).map_err(|error| error.to_string())?;
        crate::shared::foundation::home::set_private_directory_permissions(&state_root)
            .map_err(|error| error.to_string())?;
        if let Some(parent) = database.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            crate::shared::foundation::home::set_private_directory_permissions(parent)
                .map_err(|error| error.to_string())?;
        }
        let store = Self {
            home,
            root,
            state_root,
            database,
        };
        store.initialize()?;
        Ok(store)
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn state_dir(&self, worker_id: &str) -> Result<PathBuf, String> {
        validate_identifier(worker_id, "workerId")?;
        let path = self.state_root.join(worker_id);
        fs::create_dir_all(&path)
            .map_err(|error| format!("create worker state directory: {error}"))?;
        crate::shared::foundation::home::set_private_directory_permissions(&path)
            .map_err(|error| format!("secure worker state directory: {error}"))?;
        Ok(path)
    }

    fn connection(&self) -> Result<Connection, String> {
        let connection = Connection::open(&self.database)
            .map_err(|error| format!("open worker database: {error}"))?;
        crate::shared::foundation::home::set_private_file_permissions(&self.database)
            .map_err(|error| format!("secure worker database: {error}"))?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .map_err(|error| format!("configure worker database timeout: {error}"))?;
        let _ = connection.pragma_update(None, "journal_mode", "WAL");
        let _ = connection.pragma_update(None, "foreign_keys", "ON");
        Ok(connection)
    }

    fn initialize(&self) -> Result<(), String> {
        let connection = self.connection()?;
        connection
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
                    presentation_json TEXT,
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
                    origin_session_id TEXT,
                    agent_session_id TEXT,
                    interaction_mode TEXT NOT NULL DEFAULT 'foreground',
                    detached_at TEXT,
                    model_tool_invocation_id TEXT,
                    parent_worker_invocation_id TEXT,
                    retry_of_invocation_id TEXT,
                    created_at TEXT NOT NULL,
                    started_at TEXT,
                    completed_at TEXT,
                    UNIQUE(worker_id, idempotency_key),
                    FOREIGN KEY(parent_worker_invocation_id) REFERENCES worker_invocations(invocation_id),
                    FOREIGN KEY(retry_of_invocation_id) REFERENCES worker_invocations(invocation_id)
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
                CREATE TABLE IF NOT EXISTS worker_run_events (
                    event_id TEXT PRIMARY KEY,
                    invocation_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    stage TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    occurred_at TEXT NOT NULL,
                    UNIQUE(invocation_id, sequence),
                    FOREIGN KEY(invocation_id) REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS worker_run_events_invocation
                    ON worker_run_events(invocation_id, sequence);
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
                    context_attached INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                );
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
        if !table_has_column(&connection, "workers", "presentation_json")? {
            connection
                .execute("ALTER TABLE workers ADD COLUMN presentation_json TEXT", [])
                .map_err(|error| format!("add worker presentation index: {error}"))?;
        }
        if !table_has_column(&connection, "worker_invocations", "agent_session_id")? {
            connection
                .execute(
                    "ALTER TABLE worker_invocations ADD COLUMN agent_session_id TEXT",
                    [],
                )
                .map_err(|error| format!("add agent session linkage: {error}"))?;
        }
        if !table_has_column(&connection, "worker_invocations", "origin_session_id")? {
            connection
                .execute(
                    "ALTER TABLE worker_invocations ADD COLUMN origin_session_id TEXT",
                    [],
                )
                .map_err(|error| format!("add originating session linkage: {error}"))?;
        }
        for (column, definition) in [
            (
                "interaction_mode",
                "interaction_mode TEXT NOT NULL DEFAULT 'foreground'",
            ),
            ("detached_at", "detached_at TEXT"),
            ("model_tool_invocation_id", "model_tool_invocation_id TEXT"),
            (
                "parent_worker_invocation_id",
                "parent_worker_invocation_id TEXT",
            ),
            ("retry_of_invocation_id", "retry_of_invocation_id TEXT"),
        ] {
            if !table_has_column(&connection, "worker_invocations", column)? {
                connection
                    .execute(
                        &format!("ALTER TABLE worker_invocations ADD COLUMN {definition}"),
                        [],
                    )
                    .map_err(|error| format!("add worker invocation {column}: {error}"))?;
            }
        }
        connection
            .execute_batch(
                "CREATE INDEX IF NOT EXISTS worker_invocations_origin_session
                    ON worker_invocations(origin_session_id, created_at DESC);
                 CREATE INDEX IF NOT EXISTS worker_invocations_model_tool
                    ON worker_invocations(model_tool_invocation_id, created_at DESC);
                 CREATE INDEX IF NOT EXISTS worker_invocations_parent
                    ON worker_invocations(parent_worker_invocation_id, created_at ASC);
                 CREATE INDEX IF NOT EXISTS worker_invocations_retry
                    ON worker_invocations(retry_of_invocation_id, created_at ASC);",
            )
            .map_err(|error| format!("index worker invocation relationships: {error}"))?;
        connection
            .execute(
                "UPDATE worker_invocations AS child
                 SET parent_worker_invocation_id=(
                    SELECT parent.invocation_id
                    FROM worker_invocations parent
                    WHERE parent.trace_id=child.trace_id
                      AND parent.causal_depth=child.causal_depth-1
                      AND parent.created_at<=child.created_at
                 )
                 WHERE child.parent_worker_invocation_id IS NULL
                   AND child.causal_depth>0
                   AND (
                    SELECT COUNT(*)
                    FROM worker_invocations parent
                    WHERE parent.trace_id=child.trace_id
                      AND parent.causal_depth=child.causal_depth-1
                      AND parent.created_at<=child.created_at
                   )=1",
                [],
            )
            .map_err(|error| format!("backfill unambiguous worker parents: {error}"))?;
        if !table_has_column(&connection, "worker_inbox", "context_attached")? {
            if !table_has_column(&connection, "worker_inbox", "seen")? {
                return Err("worker inbox has no context-delivery column".to_owned());
            }
            connection
                .execute_batch(
                    "DROP INDEX IF EXISTS worker_inbox_worker;
                     ALTER TABLE worker_inbox RENAME COLUMN seen TO context_attached;",
                )
                .map_err(|error| format!("rename worker inbox context delivery state: {error}"))?;
        }
        connection
            .execute_batch(
                "DROP INDEX IF EXISTS worker_inbox_worker;
                 CREATE INDEX worker_inbox_worker
                    ON worker_inbox(worker_id, context_attached, created_at DESC);",
            )
            .map_err(|error| format!("index worker inbox context delivery state: {error}"))?;
        connection
            .execute(
                "INSERT OR IGNORE INTO worker_schema(version, applied_at)
                 VALUES (4, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record worker schema v4: {error}"))?;
        connection
            .execute(
                "INSERT OR IGNORE INTO worker_schema(version, applied_at)
                 VALUES (5, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record worker schema v5: {error}"))?;
        connection
            .execute(
                "INSERT OR IGNORE INTO worker_schema(version, applied_at)
                 VALUES (6, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record worker schema v6: {error}"))?;
        connection
            .execute(
                "INSERT OR IGNORE INTO worker_schema(version, applied_at)
                 VALUES (7, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record worker schema v7: {error}"))?;
        connection
            .execute(
                "INSERT OR IGNORE INTO worker_schema(version, applied_at)
                 VALUES (8, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record worker schema v8: {error}"))?;
        super::rebuild::rebuild_indexes(&self.root, &self.database)?;
        self.recover_interrupted()
    }

    fn recover_interrupted(&self) -> Result<(), String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start interrupted worker recovery: {error}"))?;
        let interrupted_ids = {
            let mut statement = transaction
                .prepare(
                    "SELECT invocation_id FROM worker_invocations
                     WHERE status='running' ORDER BY created_at,invocation_id",
                )
                .map_err(|error| format!("prepare interrupted worker recovery: {error}"))?;
            statement
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|error| format!("query interrupted worker recovery: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode interrupted worker recovery: {error}"))?
        };
        let recovered_at = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "UPDATE worker_attempts SET status='interrupted',completed_at=?1,
                    error='delivery interrupted before a durable terminal result'
                 WHERE status='running'",
                [&recovered_at],
            )
            .map_err(|error| format!("recover interrupted worker attempts: {error}"))?;
        transaction
            .execute(
                "UPDATE worker_invocations SET status='queued', started_at=NULL,
                    agent_session_id=NULL
                 WHERE status='running'",
                [],
            )
            .map_err(|error| format!("recover interrupted worker invocations: {error}"))?;
        for invocation_id in interrupted_ids {
            insert_run_event(
                &transaction,
                &invocation_id,
                WorkerRunStage::Interrupted,
                "Delivery was interrupted before a durable terminal result",
                &recovered_at,
            )?;
            insert_run_event(
                &transaction,
                &invocation_id,
                WorkerRunStage::Queued,
                "Queued for durable redelivery after interruption",
                &recovered_at,
            )?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit interrupted worker recovery: {error}"))
    }
}

fn table_has_column(connection: &Connection, table: &str, column: &str) -> Result<bool, String> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| format!("inspect {table} columns: {error}"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("query {table} columns: {error}"))?;
    for candidate in columns {
        if candidate.map_err(|error| format!("decode {table} column: {error}"))? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests;
