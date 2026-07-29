//! Canonical worker bundles and their durable operational ledger.
//!
//! [`WorkerStore`] is the single persistence owner. Publication, lifecycle,
//! invocation, bounded history, interaction/causal relationship, trigger, and
//! state concerns extend that same store without repository wrappers or
//! duplicate caches. `results` owns canonical typed-result payloads and their
//! schema migration. Stateless codecs and generic SQL helpers live in `support`;
//! `notification_validation` owns the closed device/APNs route validation
//! boundary; `notification_attention` owns sanitized transport-failure inbox
//! evidence. `inbox` keeps current Attention as an unresolved-error projection
//! over immutable inbox history, excluding only exact bounded timeouts from the
//! two deterministic-fallback semantic hooks. Error-context eligibility uses
//! that same actionable-error predicate, while informational context remains
//! separate. Scenario tests live in `tests`, grouped by notification transport,
//! artifacts/presentation, result custody, durable dispatch/recovery, and
//! publication/lifecycle. They share only the canonical bundle fixture and do
//! not add production test hooks. Invocation queue admission acquires SQLite
//! writer intent before reading causal lineage, so concurrent engine hooks wait
//! at the transaction boundary instead of failing a deferred read-to-write
//! upgrade.
//! Worker schema v16 adds the immutable worker-to-agent terminal/effect outbox.
//! Lifecycle transitions terminalize affected work with that evidence, and
//! purge rechecks nonterminal/outbox custody under SQLite writer intent.
//! Permanent rejection and its deterministic operator Attention row commit in
//! one transaction so neither can survive without the other.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::agent_delivery_effects::PreparedAgentDeliveryEffect;
use super::super::artifacts::ArtifactIntent;
use super::super::dispatches::PreparedWorkerDispatch;
use super::super::types::{
    ActiveWorker, BUNDLE_SCHEMA, InvocationRecord, MAX_INVOCATION_SECONDS, PreparedWorker,
    UpsertOutcome, WebhookCredential, WorkerBundle, WorkerClientAction, WorkerClientDelivery,
    WorkerCommand, WorkerEngineDelivery, WorkerEngineHook, WorkerInteractionMode,
    WorkerPresentation, WorkerPresentationSection, WorkerPresentationSectionKind, WorkerRunEvent,
    WorkerRunStage, WorkerRunner, WorkerState, WorkerSummary, WorkerTrigger,
};
use super::super::wakeups::PreparedWorkerWakeup;
pub(super) use state::validate_bundle;
use support::*;

mod agent_delivery_outbox;
mod artifacts;
mod dispatches;
mod history;
mod inbox;
mod interaction;
mod invocation_completion;
mod invocations;
mod lifecycle;
mod notification_attention;
mod notification_clients;
mod notification_validation;
mod notifications;
pub(in crate::domains::worker_kernel) use agent_delivery_outbox::AgentDeliveryOutboxRecord;
use notification_attention::insert_notification_attention;
pub(in crate::domains::worker_kernel) use notifications::{
    NotificationDispatchOutcome, NotificationRefreshDispatch, NotificationTargetDispatch,
};
mod publication;
mod results;
mod session_organization;
pub(in crate::domains::worker_kernel) use session_organization::SessionOrganizationDispatch;
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
        let _ = super::snapshot::ensure_worker_schema_snapshot(&home, 16)?;
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
        let mut connection = self.connection()?;
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
                    parent_worker_tool_ordinal INTEGER,
                    retry_of_invocation_id TEXT,
                    not_before TEXT,
                    wake_source_invocation_id TEXT,
                    created_at TEXT NOT NULL,
                    started_at TEXT,
                    completed_at TEXT,
                    UNIQUE(worker_id, idempotency_key),
                    FOREIGN KEY(parent_worker_invocation_id) REFERENCES worker_invocations(invocation_id),
                    FOREIGN KEY(retry_of_invocation_id) REFERENCES worker_invocations(invocation_id)
                );
                CREATE INDEX IF NOT EXISTS worker_invocations_status
                    ON worker_invocations(status, created_at);
                CREATE TABLE IF NOT EXISTS worker_model_tool_result_associations (
                    model_tool_invocation_id TEXT NOT NULL,
                    worker_invocation_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(model_tool_invocation_id, worker_invocation_id),
                    FOREIGN KEY(worker_invocation_id) REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS worker_model_tool_result_associations_invocation
                    ON worker_model_tool_result_associations(worker_invocation_id, created_at);
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
                CREATE TABLE IF NOT EXISTS agent_delivery_outbox (
                    outbox_id TEXT PRIMARY KEY,
                    deduplication_key TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK(kind IN ('terminal','delivery')),
                    invocation_id TEXT NOT NULL,
                    worker_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    disposition TEXT NOT NULL DEFAULT 'pending'
                        CHECK(disposition IN ('pending','imported','rejected')),
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    created_at TEXT NOT NULL,
                    processed_at TEXT,
                    FOREIGN KEY(invocation_id)
                        REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS agent_delivery_outbox_pending
                    ON agent_delivery_outbox(disposition, created_at, outbox_id);
                CREATE INDEX IF NOT EXISTS agent_delivery_outbox_worker
                    ON agent_delivery_outbox(worker_id, disposition, created_at);
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
            (
                "parent_worker_tool_ordinal",
                "parent_worker_tool_ordinal INTEGER",
            ),
            ("retry_of_invocation_id", "retry_of_invocation_id TEXT"),
            ("not_before", "not_before TEXT"),
            (
                "wake_source_invocation_id",
                "wake_source_invocation_id TEXT",
            ),
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
                    ON worker_invocations(retry_of_invocation_id, created_at ASC);
                 CREATE INDEX IF NOT EXISTS worker_invocations_due
                    ON worker_invocations(status,not_before,created_at);
                 CREATE INDEX IF NOT EXISTS worker_invocations_wake_source
                    ON worker_invocations(wake_source_invocation_id,created_at);
                 CREATE INDEX IF NOT EXISTS worker_model_tool_result_associations_model_tool
                    ON worker_model_tool_result_associations(
                        model_tool_invocation_id,
                        created_at ASC
                    );
                 INSERT OR IGNORE INTO worker_model_tool_result_associations(
                    model_tool_invocation_id,
                    worker_invocation_id,
                    created_at
                 )
                 SELECT model_tool_invocation_id,invocation_id,created_at
                 FROM worker_invocations
                 WHERE model_tool_invocation_id IS NOT NULL;",
            )
            .map_err(|error| {
                format!("index and backfill worker invocation relationships: {error}")
            })?;
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
        connection
            .execute_batch(
                "WITH ranked AS (
                    SELECT invocation_id,
                           ROW_NUMBER() OVER (
                               PARTITION BY parent_worker_invocation_id,worker_id
                               ORDER BY created_at,invocation_id
                           ) - 1 AS ordinal
                    FROM worker_invocations
                    WHERE parent_worker_invocation_id IS NOT NULL
                 )
                 UPDATE worker_invocations
                 SET parent_worker_tool_ordinal=(
                    SELECT ordinal FROM ranked
                    WHERE ranked.invocation_id=worker_invocations.invocation_id
                 )
                 WHERE parent_worker_invocation_id IS NOT NULL
                   AND parent_worker_tool_ordinal IS NULL;
                 CREATE UNIQUE INDEX IF NOT EXISTS worker_invocations_parent_tool_slot
                    ON worker_invocations(
                        parent_worker_invocation_id,
                        worker_id,
                        parent_worker_tool_ordinal
                    )
                    WHERE parent_worker_invocation_id IS NOT NULL
                      AND parent_worker_tool_ordinal IS NOT NULL;",
            )
            .map_err(|error| format!("index nested worker call slots: {error}"))?;
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
        connection
            .execute(
                "INSERT OR IGNORE INTO worker_schema(version, applied_at)
                 VALUES (9, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record worker schema v9: {error}"))?;
        self.migrate_results_v10(&mut connection)?;
        connection
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS notification_installations (
                    installation_id TEXT PRIMARY KEY,
                    client_server_id TEXT NOT NULL,
                    topic TEXT NOT NULL,
                    environment TEXT NOT NULL,
                    authorization_status TEXT NOT NULL,
                    token TEXT,
                    token_hash TEXT,
                    enabled INTEGER NOT NULL,
                    last_registered_at TEXT NOT NULL,
                    invalidated_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS notification_installations_active
                    ON notification_installations(enabled,last_registered_at);
                CREATE TABLE IF NOT EXISTS notification_deliveries (
                    delivery_id TEXT PRIMARY KEY,
                    worker_id TEXT NOT NULL,
                    worker_version TEXT NOT NULL,
                    invocation_id TEXT NOT NULL,
                    deduplication_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    thread_key TEXT,
                    source_record_id TEXT,
                    expires_at TEXT NOT NULL,
                    actions_json TEXT NOT NULL,
                    on_open_complete INTEGER NOT NULL,
                    read_at TEXT,
                    read_reason TEXT,
                    terminal_response TEXT,
                    terminal_responded_at TEXT,
                    trace_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(worker_id,deduplication_key),
                    FOREIGN KEY(invocation_id) REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS notification_deliveries_inbox
                    ON notification_deliveries(created_at DESC,delivery_id DESC);
                CREATE INDEX IF NOT EXISTS notification_deliveries_unread
                    ON notification_deliveries(read_at,created_at DESC);
                CREATE TABLE IF NOT EXISTS notification_delivery_targets (
                    target_id TEXT PRIMARY KEY,
                    delivery_id TEXT NOT NULL,
                    installation_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    next_attempt_at TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL,
                    apns_id TEXT,
                    error_code TEXT,
                    accepted_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(delivery_id,installation_id),
                    FOREIGN KEY(delivery_id) REFERENCES notification_deliveries(delivery_id) ON DELETE CASCADE,
                    FOREIGN KEY(installation_id) REFERENCES notification_installations(installation_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS notification_delivery_targets_due
                    ON notification_delivery_targets(state,next_attempt_at);
                CREATE TABLE IF NOT EXISTS notification_delivery_attempts (
                    attempt_id TEXT PRIMARY KEY,
                    target_kind TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    attempt_number INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    apns_id TEXT,
                    error_code TEXT,
                    started_at TEXT NOT NULL,
                    completed_at TEXT NOT NULL,
                    UNIQUE(target_kind,target_id,attempt_number)
                );
                CREATE TABLE IF NOT EXISTS notification_responses (
                    response_id TEXT PRIMARY KEY,
                    client_mutation_id TEXT NOT NULL UNIQUE,
                    delivery_id TEXT NOT NULL,
                    installation_id TEXT NOT NULL,
                    acknowledgement TEXT NOT NULL,
                    accepted INTEGER NOT NULL,
                    response_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY(delivery_id) REFERENCES notification_deliveries(delivery_id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS notification_refreshes (
                    refresh_id TEXT PRIMARY KEY,
                    installation_id TEXT NOT NULL UNIQUE,
                    unread_count INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    next_attempt_at TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL,
                    error_code TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY(installation_id) REFERENCES notification_installations(installation_id) ON DELETE CASCADE
                );
                UPDATE notification_delivery_targets
                    SET state='retry_wait',next_attempt_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                        error_code='interrupted',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                    WHERE state='sending';
                UPDATE notification_refreshes
                    SET state='retry_wait',next_attempt_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                        error_code='interrupted',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                    WHERE state IN ('sending','sending_pending');
                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (11, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
                ",
            )
            .map_err(|error| format!("initialize notification schema v11: {error}"))?;
        for (column, definition) in [
            ("source_worker_id", "source_worker_id TEXT"),
            ("source_worker_version", "source_worker_version TEXT"),
            ("producer_worker_id", "producer_worker_id TEXT"),
            ("producer_worker_version", "producer_worker_version TEXT"),
            ("source_invocation_id", "source_invocation_id TEXT"),
            ("not_before", "not_before TEXT"),
        ] {
            if !table_has_column(&connection, "notification_deliveries", column)? {
                connection
                    .execute(
                        &format!("ALTER TABLE notification_deliveries ADD COLUMN {definition}"),
                        [],
                    )
                    .map_err(|error| {
                        format!("add notification delivery schema-v12 column {column}: {error}")
                    })?;
            }
        }
        for (column, definition) in [
            ("transport_kind", "transport_kind TEXT"),
            ("provider_request_id", "provider_request_id TEXT"),
        ] {
            if !table_has_column(&connection, "notification_delivery_attempts", column)? {
                connection
                    .execute(
                        &format!(
                            "ALTER TABLE notification_delivery_attempts ADD COLUMN {definition}"
                        ),
                        [],
                    )
                    .map_err(|error| {
                        format!("add notification attempt schema-v12 column {column}: {error}")
                    })?;
            }
        }
        connection
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS worker_dispatches (
                    dispatch_id TEXT PRIMARY KEY,
                    source_invocation_id TEXT NOT NULL,
                    source_worker_id TEXT NOT NULL,
                    source_worker_version TEXT NOT NULL,
                    route TEXT NOT NULL,
                    deduplication_key TEXT NOT NULL,
                    target_worker_id TEXT NOT NULL,
                    target_worker_version TEXT NOT NULL,
                    target_invocation_id TEXT NOT NULL UNIQUE,
                    response_binding TEXT NOT NULL,
                    state TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    completed_at TEXT,
                    UNIQUE(source_worker_id,route,deduplication_key),
                    FOREIGN KEY(source_invocation_id)
                        REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE,
                    FOREIGN KEY(target_invocation_id)
                        REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS worker_dispatches_source
                    ON worker_dispatches(source_invocation_id,created_at);
                CREATE INDEX IF NOT EXISTS worker_dispatches_target
                    ON worker_dispatches(target_invocation_id,state);

                UPDATE notification_deliveries SET
                    source_worker_id=COALESCE(source_worker_id,worker_id),
                    source_worker_version=COALESCE(source_worker_version,worker_version),
                    producer_worker_id=COALESCE(producer_worker_id,worker_id),
                    producer_worker_version=COALESCE(producer_worker_version,worker_version),
                    source_invocation_id=COALESCE(source_invocation_id,invocation_id),
                    not_before=COALESCE(not_before,created_at);
                UPDATE notification_delivery_attempts
                    SET provider_request_id=COALESCE(provider_request_id,target_id);

                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (12, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (13, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
                ",
            )
            .map_err(|error| format!("initialize worker dispatch schema v12: {error}"))?;
        connection
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS worker_artifacts (
                    worker_id TEXT NOT NULL,
                    artifact_id TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    content_sha256 TEXT NOT NULL,
                    content_reference_json TEXT NOT NULL,
                    content_pointer TEXT NOT NULL,
                    source_invocation_id TEXT NOT NULL,
                    source_worker_version TEXT NOT NULL,
                    trace_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(worker_id,artifact_id)
                );
                CREATE INDEX IF NOT EXISTS worker_artifacts_inbox
                    ON worker_artifacts(created_at DESC,worker_id,artifact_id);
                CREATE INDEX IF NOT EXISTS worker_artifacts_source
                    ON worker_artifacts(source_invocation_id);
                CREATE TABLE IF NOT EXISTS worker_artifact_storage_state (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    state TEXT NOT NULL,
                    attention_inbox_id TEXT,
                    updated_at TEXT NOT NULL
                );
                INSERT OR IGNORE INTO worker_artifact_storage_state(
                    singleton,state,attention_inbox_id,updated_at
                ) VALUES (
                    1,'normal',NULL,strftime('%Y-%m-%dT%H:%M:%fZ','now')
                );
                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (14, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
                ",
            )
            .map_err(|error| format!("initialize artifact schema v14: {error}"))?;
        connection
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS worker_session_organization_intents (
                    intent_id TEXT PRIMARY KEY,
                    source_invocation_id TEXT NOT NULL UNIQUE,
                    worker_id TEXT NOT NULL,
                    worker_version TEXT NOT NULL,
                    trace_id TEXT NOT NULL,
                    mutations_json TEXT NOT NULL,
                    state TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL,
                    next_attempt_at TEXT NOT NULL,
                    error TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    applied_at TEXT,
                    FOREIGN KEY(source_invocation_id)
                        REFERENCES worker_invocations(invocation_id) ON DELETE CASCADE
                );
                INSERT OR IGNORE INTO worker_schema(version, applied_at)
                    VALUES (15, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
                ",
            )
            .map_err(|error| format!("initialize session organization schema v15: {error}"))?;
        connection
            .execute(
                "INSERT OR IGNORE INTO worker_schema(version, applied_at)
                 VALUES (16, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record agent-delivery outbox schema v16: {error}"))?;
        if !table_has_column(
            &connection,
            "worker_session_organization_intents",
            "next_attempt_at",
        )? {
            connection
                .execute(
                    "ALTER TABLE worker_session_organization_intents
                     ADD COLUMN next_attempt_at TEXT NOT NULL
                     DEFAULT '1970-01-01T00:00:00Z'",
                    [],
                )
                .map_err(|error| {
                    format!("add session organization next-attempt custody: {error}")
                })?;
        }
        connection
            .execute_batch(
                "DROP INDEX IF EXISTS worker_session_organization_due;
                 CREATE INDEX worker_session_organization_due
                    ON worker_session_organization_intents(
                        state,next_attempt_at,created_at,intent_id
                    );
                 UPDATE worker_session_organization_intents
                    SET state='queued',
                        error='canonical apply interrupted before durable acknowledgement',
                        next_attempt_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                        updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                    WHERE state='applying';",
            )
            .map_err(|error| format!("index session organization custody: {error}"))?;
        super::rebuild::rebuild_indexes(&self.root, &self.database)?;
        self.recover_interrupted()
    }

    fn recover_interrupted(&self) -> Result<(), String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start interrupted worker recovery: {error}"))?;
        let inactive_workers = {
            let mut statement = transaction
                .prepare(
                    "SELECT worker_id FROM workers
                     WHERE enabled=0 OR retired=1 ORDER BY worker_id",
                )
                .map_err(|error| format!("prepare inactive worker recovery: {error}"))?;
            statement
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|error| format!("query inactive worker recovery: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode inactive worker recovery: {error}"))?
        };
        for worker_id in inactive_workers {
            let _ = invocations::cancel_worker_invocations_in_tx(
                &transaction,
                &worker_id,
                "worker invocation cancelled during inactive-worker recovery",
            )?;
        }
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
