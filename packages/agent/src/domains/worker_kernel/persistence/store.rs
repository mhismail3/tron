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
use super::snapshot::ensure_pre_worker_snapshot;

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
    pub fn open(home: PathBuf, source_profile: &str) -> Result<Self, String> {
        ensure_pre_worker_snapshot(&home, source_profile)
            .map_err(|error| format!("create pre-worker state snapshot: {error}"))?;
        let root = home.join("workspace").join("workers");
        let database = home
            .join("internal")
            .join("database")
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
        let root = home.join("workspace").join("workers");
        let database = home
            .join("internal")
            .join("database")
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
        super::migration::import_legacy_candidates(&self.home, &self.root)?;
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

    pub fn prepare(
        &self,
        mut bundle: WorkerBundle,
        predecessor: Option<&str>,
    ) -> Result<PreparedWorker, String> {
        validate_bundle(&bundle)?;
        let explicit_worker_id = bundle.worker_id.clone();
        let explicit_worker_exists = explicit_worker_id
            .as_deref()
            .map(|worker_id| self.read_state(worker_id))
            .transpose()?
            .flatten()
            .is_some();
        let overlap_threshold = if explicit_worker_id.is_some() {
            0.90
        } else {
            0.60
        };
        let worker_id = if let Some(predecessor) = predecessor {
            if self.read_state(predecessor)?.is_none() {
                return Err(format!("predecessor worker '{predecessor}' was not found"));
            }
            predecessor.to_owned()
        } else if explicit_worker_exists {
            explicit_worker_id.expect("checked explicit worker identity")
        } else if let Some(overlap) = self.closest_overlap(&bundle, overlap_threshold)? {
            overlap
        } else {
            explicit_worker_id.unwrap_or_else(|| slug(&bundle.name))
        };
        validate_identifier(&worker_id, "workerId")?;
        bundle.worker_id = Some(worker_id.clone());
        let requested_tool = self
            .summary(&worker_id)?
            .map(|existing| existing.tool_name)
            .or_else(|| bundle.tool_name.clone())
            .unwrap_or_else(|| format!("worker_{}", slug(&bundle.name)));
        let tool_name = normalize_tool_name(&requested_tool)?;
        bundle.tool_name = Some(tool_name.clone());

        let staging_dir =
            self.root
                .join(".staging")
                .join(format!("{}-{}", worker_id, uuid::Uuid::now_v7()));
        fs::create_dir_all(staging_dir.join("files"))
            .map_err(|error| format!("create worker staging directory: {error}"))?;
        fs::write(
            staging_dir.join("manifest.json"),
            serde_json::to_vec_pretty(&bundle)
                .map_err(|error| format!("encode worker manifest: {error}"))?,
        )
        .map_err(|error| format!("write worker manifest: {error}"))?;
        for (relative, contents) in &bundle.files {
            let relative = safe_relative_path(relative)?;
            let target = staging_dir.join("files").join(relative);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .map_err(|error| format!("create worker file directory: {error}"))?;
            }
            fs::write(&target, contents)
                .map_err(|error| format!("write worker file {}: {error}", target.display()))?;
        }
        fs::write(
            staging_dir.join("dependencies.lock.json"),
            serde_json::to_vec_pretty(&bundle.dependencies)
                .map_err(|error| format!("encode dependency lock: {error}"))?,
        )
        .map_err(|error| format!("write dependency lock: {error}"))?;
        fs::write(
            staging_dir.join("provenance.json"),
            serde_json::to_vec_pretty(&bundle.provenance)
                .map_err(|error| format!("encode provenance: {error}"))?,
        )
        .map_err(|error| format!("write provenance: {error}"))?;
        let version = tree_version(&staging_dir)?;

        Ok(PreparedWorker {
            prior_state: self.read_state(&worker_id)?,
            worker_id,
            version,
            tool_name,
            bundle,
            staging_dir,
        })
    }

    pub fn abandon(&self, prepared: &PreparedWorker) {
        let _ = fs::remove_dir_all(&prepared.staging_dir);
    }

    /// Rewrite the staged canonical metadata after dependency acquisition has
    /// filled every optional input checksum. Publication must never preserve an
    /// unresolved dependency even though callers may omit expected digests.
    pub fn seal_resolved_dependencies(&self, prepared: &PreparedWorker) -> Result<(), String> {
        for dependency in &prepared.bundle.dependencies {
            if dependency.checksum.is_none() {
                return Err(format!(
                    "dependency '{}' was not resolved to a checksum",
                    dependency.name
                ));
            }
        }
        fs::write(
            prepared.staging_dir.join("manifest.json"),
            serde_json::to_vec_pretty(&prepared.bundle)
                .map_err(|error| format!("encode resolved worker manifest: {error}"))?,
        )
        .map_err(|error| format!("write resolved worker manifest: {error}"))?;
        fs::write(
            prepared.staging_dir.join("dependencies.lock.json"),
            serde_json::to_vec_pretty(&prepared.bundle.dependencies)
                .map_err(|error| format!("encode resolved dependency lock: {error}"))?,
        )
        .map_err(|error| format!("write resolved dependency lock: {error}"))
    }

    /// Seal the exact staged tree after dependency acquisition and smoke tests.
    /// The resulting full SHA-256 is the immutable content-version directory.
    pub fn finalize(&self, prepared: &mut PreparedWorker) -> Result<(), String> {
        prepared.version = tree_version(&prepared.staging_dir)?;
        fs::write(
            prepared.staging_dir.join("content.sha256"),
            format!("{}\n", prepared.version),
        )
        .map_err(|error| format!("write worker content hash: {error}"))
    }

    pub fn publish(&self, prepared: PreparedWorker) -> Result<UpsertOutcome, String> {
        self.publish_with_pointer_writer(prepared, write_json_atomic)
    }

    fn publish_with_pointer_writer(
        &self,
        prepared: PreparedWorker,
        write_pointer: impl FnOnce(&Path, &WorkerState) -> Result<(), String>,
    ) -> Result<UpsertOutcome, String> {
        validate_content_version(&prepared.version)?;
        let sealed = fs::read_to_string(prepared.staging_dir.join("content.sha256"))
            .map_err(|error| format!("read finalized worker content hash: {error}"))?;
        let actual = tree_version(&prepared.staging_dir)?;
        if sealed.trim() != prepared.version || actual != prepared.version {
            return Err(format!(
                "worker candidate was not finalized consistently: expected {}, recorded {}, resolved {}",
                prepared.version,
                sealed.trim(),
                actual
            ));
        }
        let worker_dir = self.root.join(&prepared.worker_id);
        let versions_dir = worker_dir.join("versions");
        fs::create_dir_all(&versions_dir)
            .map_err(|error| format!("create worker versions directory: {error}"))?;
        let version_dir = versions_dir.join(&prepared.version);
        let created_version = !version_dir.exists();
        if created_version {
            fs::rename(&prepared.staging_dir, &version_dir)
                .map_err(|error| format!("publish worker version: {error}"))?;
        } else {
            let _ = fs::remove_dir_all(&prepared.staging_dir);
        }
        let cleanup_target = if created_version && prepared.prior_state.is_none() {
            Some(worker_dir.clone())
        } else {
            created_version.then(|| version_dir.clone())
        };
        let mut version_cleanup = RemoveDirectoryOnDrop(cleanup_target);

        let now = chrono::Utc::now().to_rfc3339();
        let state = WorkerState {
            worker_id: prepared.worker_id.clone(),
            active_version: prepared.version.clone(),
            enabled: true,
            retired: false,
            health: "healthy".to_owned(),
            failure: None,
            updated_at: now.clone(),
        };
        let state_path = worker_dir.join("worker.json");

        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker publish transaction: {error}"))?;
        let created = transaction
            .query_row(
                "SELECT 1 FROM workers WHERE worker_id=?1",
                [&prepared.worker_id],
                |_| Ok(()),
            )
            .optional()
            .map_err(|error| format!("inspect prior worker: {error}"))?
            .is_none();
        transaction
            .execute(
                "INSERT INTO workers(worker_id,name,description,tool_name,runner_kind,active_version,enabled,retired,health,created_at,updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,1,0,'healthy',?7,?7)
                 ON CONFLICT(worker_id) DO UPDATE SET
                    name=excluded.name, description=excluded.description,
                    tool_name=excluded.tool_name, runner_kind=excluded.runner_kind,
                    active_version=excluded.active_version, enabled=1, retired=0,
                    health='healthy', updated_at=excluded.updated_at",
                params![
                    prepared.worker_id,
                    prepared.bundle.name,
                    prepared.bundle.description,
                    prepared.tool_name,
                    prepared.bundle.runner.kind(),
                    prepared.version,
                    now,
                ],
            )
            .map_err(|error| format!("upsert worker index: {error}"))?;
        transaction
            .execute(
                "INSERT OR IGNORE INTO worker_versions(worker_id,version,manifest_json,content_hash,created_at)
                 VALUES (?1,?2,?3,?2,?4)",
                params![
                    prepared.worker_id,
                    prepared.version,
                    serde_json::to_string(&prepared.bundle).map_err(|error| error.to_string())?,
                    now,
                ],
            )
            .map_err(|error| format!("insert worker version: {error}"))?;
        transaction
            .execute(
                "INSERT INTO worker_routes(worker_id,worker_version,tool_name,description,routing_json,enabled,updated_at)
                 VALUES (?1,?2,?3,?4,?5,1,?6)
                 ON CONFLICT(worker_id) DO UPDATE SET
                    worker_version=excluded.worker_version,tool_name=excluded.tool_name,
                    description=excluded.description,routing_json=excluded.routing_json,
                    enabled=1,updated_at=excluded.updated_at",
                params![
                    prepared.worker_id,
                    prepared.version,
                    prepared.tool_name,
                    prepared.bundle.description,
                    serde_json::to_string(&prepared.bundle.routing)
                        .map_err(|error| error.to_string())?,
                    now,
                ],
            )
            .map_err(|error| format!("activate worker route: {error}"))?;
        let mut webhooks = Vec::new();
        replace_active_triggers(
            &transaction,
            &prepared.worker_id,
            &prepared.bundle.triggers,
            true,
            &mut webhooks,
        )?;
        insert_audit(
            &transaction,
            &prepared.worker_id,
            if created { "created" } else { "updated" },
            &json!({
                "version": prepared.version,
                "runner": prepared.bundle.runner.kind(),
                "contentHash": prepared.version,
                "provenance": prepared.bundle.provenance,
            }),
        )?;
        insert_health(
            &transaction,
            &prepared.worker_id,
            &prepared.version,
            "healthy",
            "activation",
            &json!({"verification":"verification.json"}),
        )?;
        // INVARIANT: the filesystem pointer is the publication linearization
        // point. Commit the rebuildable indexes first so a crash can leave the
        // database ahead of the canonical pointer, never the pointer ahead of
        // its durable indexes. Startup reconstruction resolves the former back
        // to the prior pointer.
        transaction
            .commit()
            .map_err(|error| format!("commit worker publish: {error}"))?;
        if let Err(error) = write_pointer(&state_path, &state) {
            let cleanup = version_cleanup.cleanup_now();
            let recovery = super::migration::rebuild_indexes(&self.root, &self.database);
            let cleanup_evidence = cleanup
                .err()
                .map(|cleanup_error| format!("; candidate cleanup also failed: {cleanup_error}"))
                .unwrap_or_default();
            return Err(match recovery {
                Ok(()) => format!(
                    "publish canonical worker pointer: {error}; restored indexes from filesystem state{cleanup_evidence}"
                ),
                Err(recovery_error) => format!(
                    "publish canonical worker pointer: {error}; index recovery also failed: {recovery_error}{cleanup_evidence}"
                ),
            });
        }
        version_cleanup.disarm();

        let worker = self
            .summary(&prepared.worker_id)?
            .ok_or_else(|| "published worker is missing from index".to_owned())?;
        Ok(UpsertOutcome {
            worker,
            version: prepared.version,
            created,
            replaced_worker_id: prepared.prior_state.map(|state| state.worker_id),
            webhooks,
        })
    }

    pub fn list(&self, include_retired: bool) -> Result<Vec<WorkerSummary>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT w.worker_id,w.name,w.description,w.tool_name,w.runner_kind,w.active_version,
                        w.enabled,w.retired,w.health,w.updated_at,
                        (SELECT COUNT(*) FROM worker_triggers t WHERE t.worker_id=w.worker_id AND t.enabled=1)
                 FROM workers w WHERE (?1=1 OR w.retired=0) ORDER BY w.updated_at DESC",
            )
            .map_err(|error| format!("prepare worker list: {error}"))?;
        let rows = statement
            .query_map([i64::from(include_retired)], row_summary)
            .map_err(|error| format!("query worker list: {error}"))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker list: {error}"))
    }

    pub fn summary(&self, worker_id: &str) -> Result<Option<WorkerSummary>, String> {
        self.connection()?
            .query_row(
                "SELECT w.worker_id,w.name,w.description,w.tool_name,w.runner_kind,w.active_version,
                        w.enabled,w.retired,w.health,w.updated_at,
                        (SELECT COUNT(*) FROM worker_triggers t WHERE t.worker_id=w.worker_id AND t.enabled=1)
                 FROM workers w WHERE w.worker_id=?1",
                [worker_id],
                row_summary,
            )
            .optional()
            .map_err(|error| format!("load worker summary: {error}"))
    }

    pub fn inspect(&self, worker_id: &str) -> Result<Value, String> {
        let active = self.load_active(worker_id)?;
        let connection = self.connection()?;
        let versions = {
            let mut statement = connection
                .prepare(
                    "SELECT version,content_hash,created_at FROM worker_versions
                     WHERE worker_id=?1 ORDER BY created_at DESC",
                )
                .map_err(|error| error.to_string())?;
            statement
                .query_map([worker_id], |row| {
                    Ok(json!({
                        "version": row.get::<_, String>(0)?,
                        "contentHash": row.get::<_, String>(1)?,
                        "createdAt": row.get::<_, String>(2)?,
                    }))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        let triggers = {
            let mut statement = connection
                .prepare(
                    "SELECT trigger_id,kind,config_json,token_hash,next_run_at,stream_cursor,enabled
                     FROM worker_triggers WHERE worker_id=?1 ORDER BY trigger_id",
                )
                .map_err(|error| error.to_string())?;
            statement
                .query_map([worker_id], |row| {
                    let config: String = row.get(2)?;
                    Ok(json!({
                        "triggerId": row.get::<_, String>(0)?,
                        "kind": row.get::<_, String>(1)?,
                        "configuration": serde_json::from_str::<Value>(&config).unwrap_or(Value::Null),
                        "tokenConfigured": row.get::<_, Option<String>>(3)?.is_some(),
                        "nextRunAt": row.get::<_, Option<String>>(4)?,
                        "streamCursor": row.get::<_, i64>(5)?,
                        "enabled": row.get::<_, i64>(6)? != 0,
                    }))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        let audit = self.audit(Some(worker_id), 100)?;
        let route = connection
            .query_row(
                "SELECT worker_version,tool_name,description,routing_json,enabled,updated_at
                 FROM worker_routes WHERE worker_id=?1",
                [worker_id],
                |row| {
                    let routing: String = row.get(3)?;
                    Ok(json!({
                        "workerVersion":row.get::<_, String>(0)?,
                        "toolName":row.get::<_, String>(1)?,
                        "description":row.get::<_, String>(2)?,
                        "routing":serde_json::from_str::<Value>(&routing).unwrap_or(Value::Null),
                        "enabled":row.get::<_, i64>(4)? != 0,
                        "updatedAt":row.get::<_, String>(5)?,
                    }))
                },
            )
            .optional()
            .map_err(|error| format!("load worker route: {error}"))?;
        let health_history = {
            let mut statement = connection
                .prepare(
                    "SELECT health_id,worker_version,status,source,details_json,recorded_at
                     FROM worker_health WHERE worker_id=?1 ORDER BY recorded_at DESC LIMIT 100",
                )
                .map_err(|error| error.to_string())?;
            statement
                .query_map([worker_id], |row| {
                    let details: String = row.get(4)?;
                    Ok(json!({
                        "healthId":row.get::<_, String>(0)?,
                        "workerVersion":row.get::<_, String>(1)?,
                        "status":row.get::<_, String>(2)?,
                        "source":row.get::<_, String>(3)?,
                        "details":serde_json::from_str::<Value>(&details).unwrap_or(Value::Null),
                        "recordedAt":row.get::<_, String>(5)?,
                    }))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        Ok(json!({
            "worker": active.summary,
            "bundle": active.bundle,
            "route": route,
            "versions": versions,
            "triggers": triggers,
            "healthHistory": health_history,
            "audit": audit,
            "versionDirectory": active.version_dir,
        }))
    }

    pub fn load_active(&self, worker_id: &str) -> Result<ActiveWorker, String> {
        let state = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let (bundle, version_dir) =
            self.load_verified_bundle(worker_id, &state.active_version, "active")?;
        let summary = self.summary_from_state_bundle(&state, &bundle)?;
        Ok(ActiveWorker {
            summary,
            bundle,
            version_dir,
        })
    }

    /// Load the active contract from the rebuildable index for pre-dispatch
    /// schema validation. Execution always follows with `load_version`, which
    /// verifies the canonical filesystem tree before running any code.
    pub fn load_indexed_active(&self, worker_id: &str) -> Result<ActiveWorker, String> {
        validate_identifier(worker_id, "workerId")?;
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        validate_content_version(&summary.active_version)?;
        let manifest: String = self
            .connection()?
            .query_row(
                "SELECT manifest_json FROM worker_versions WHERE worker_id=?1 AND version=?2",
                params![worker_id, summary.active_version],
                |row| row.get(0),
            )
            .map_err(|error| format!("load indexed worker manifest: {error}"))?;
        let bundle: WorkerBundle = serde_json::from_str(&manifest)
            .map_err(|error| format!("decode indexed worker manifest: {error}"))?;
        validate_bundle(&bundle)?;
        let version_dir = self
            .root
            .join(worker_id)
            .join("versions")
            .join(&summary.active_version);
        Ok(ActiveWorker {
            summary,
            bundle,
            version_dir,
        })
    }

    pub fn load_version(&self, worker_id: &str, version: &str) -> Result<ActiveWorker, String> {
        let mut state = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let (bundle, version_dir) = self.load_verified_bundle(worker_id, version, "worker")?;
        state.active_version = version.to_owned();
        let summary = self.summary_from_state_bundle(&state, &bundle)?;
        Ok(ActiveWorker {
            summary,
            bundle,
            version_dir,
        })
    }

    fn load_verified_bundle(
        &self,
        worker_id: &str,
        version: &str,
        context: &str,
    ) -> Result<(WorkerBundle, PathBuf), String> {
        validate_identifier(worker_id, "workerId")?;
        validate_content_version(version)?;
        let version_dir = self.root.join(worker_id).join("versions").join(version);
        let recorded = fs::read_to_string(version_dir.join("content.sha256"))
            .map_err(|error| format!("read {context} worker content hash: {error}"))?;
        if recorded.trim() != version {
            return Err(format!(
                "{context} worker version '{worker_id}@{version}' has a mismatched content.sha256"
            ));
        }
        let actual = tree_version(&version_dir)?;
        if actual != version {
            return Err(format!(
                "{context} worker version '{worker_id}@{version}' failed integrity verification: content resolves to {actual}"
            ));
        }
        let bundle: WorkerBundle = serde_json::from_slice(
            &fs::read(version_dir.join("manifest.json"))
                .map_err(|error| format!("read {context} worker manifest: {error}"))?,
        )
        .map_err(|error| format!("decode {context} worker manifest: {error}"))?;
        validate_bundle(&bundle)?;
        Ok((bundle, version_dir))
    }

    fn summary_from_state_bundle(
        &self,
        state: &WorkerState,
        bundle: &WorkerBundle,
    ) -> Result<WorkerSummary, String> {
        let tool_name = bundle
            .tool_name
            .clone()
            .ok_or_else(|| format!("worker '{}' has no toolName", state.worker_id))?;
        let trigger_count = self
            .connection()?
            .query_row(
                "SELECT COUNT(*) FROM worker_triggers WHERE worker_id=?1 AND enabled=1",
                [&state.worker_id],
                |row| row.get::<_, u64>(0),
            )
            .unwrap_or(0);
        Ok(WorkerSummary {
            worker_id: state.worker_id.clone(),
            name: bundle.name.clone(),
            description: bundle.description.clone(),
            tool_name,
            runner_kind: bundle.runner.kind().to_owned(),
            active_version: state.active_version.clone(),
            enabled: state.enabled,
            retired: state.retired,
            health: state.health.clone(),
            trigger_count,
            updated_at: state.updated_at.clone(),
        })
    }

    pub fn set_enabled(&self, worker_id: &str, enabled: bool) -> Result<WorkerSummary, String> {
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        if enabled && prior.retired {
            return Err("a retired worker must be rolled back before it can be enabled".to_owned());
        }
        let mut state = prior.clone();
        state.enabled = enabled;
        state.health = if enabled { "healthy" } else { "disabled" }.to_owned();
        state.failure = None;
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET enabled=?2,health=?3,updated_at=?4 WHERE worker_id=?1",
                    params![
                        worker_id,
                        i64::from(enabled),
                        if enabled { "healthy" } else { "disabled" },
                        state.updated_at,
                    ],
                )
                .map_err(|error| format!("update worker enablement: {error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            insert_audit(
                &transaction,
                worker_id,
                if enabled { "enabled" } else { "disabled" },
                &json!({"activeVersion":state.active_version}),
            )?;
            transaction
                .execute(
                    "UPDATE worker_routes SET enabled=?2,updated_at=?3 WHERE worker_id=?1",
                    params![worker_id, i64::from(enabled), state.updated_at],
                )
                .map_err(|error| format!("update worker route enablement: {error}"))?;
            transaction
                .execute(
                    "UPDATE worker_triggers
                     SET enabled=CASE
                        WHEN ?2=1 AND (kind!='webhook' OR token_hash IS NOT NULL) THEN 1
                        ELSE 0
                     END
                     WHERE worker_id=?1",
                    params![worker_id, i64::from(enabled)],
                )
                .map_err(|error| format!("update worker trigger enablement: {error}"))?;
            insert_health(
                &transaction,
                worker_id,
                &state.active_version,
                if enabled { "healthy" } else { "disabled" },
                "lifecycle",
                &json!({"action":if enabled { "enabled" } else { "disabled" }}),
            )?;
            transaction.commit().map_err(|error| error.to_string())
        })();
        if let Err(error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(error);
        }
        self.summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))
    }

    pub fn mark_failed(&self, worker_id: &str, source: &str, error: &str) -> Result<(), String> {
        validate_runtime_identifier(source, "worker failure source", 64)?;
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let mut state = prior.clone();
        state.enabled = false;
        state.health = "failed".to_owned();
        state.failure = Some(error.to_owned());
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|db_error| db_error.to_string())?;
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET enabled=0,health='failed',updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|db_error| format!("mark worker failed after {error}: {db_error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            insert_audit(
                &transaction,
                worker_id,
                "failed",
                &json!({"error":error,"source":source,"activeVersion":state.active_version}),
            )?;
            transaction
                .execute(
                    "UPDATE worker_routes SET enabled=0,updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|db_error| format!("disable failed worker route: {db_error}"))?;
            transaction
                .execute(
                    "UPDATE worker_triggers SET enabled=0 WHERE worker_id=?1",
                    [worker_id],
                )
                .map_err(|db_error| format!("disable failed worker triggers: {db_error}"))?;
            insert_health(
                &transaction,
                worker_id,
                &state.active_version,
                "failed",
                source,
                &json!({"error":error}),
            )?;
            transaction
                .commit()
                .map_err(|db_error| db_error.to_string())
        })();
        if let Err(db_error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(db_error);
        }
        Ok(())
    }

    pub fn rollback(
        &self,
        worker_id: &str,
        version: &str,
    ) -> Result<(WorkerSummary, Vec<WebhookCredential>), String> {
        let bundle = self.load_version(worker_id, version)?.bundle;
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let mut state = prior.clone();
        state.active_version = version.to_owned();
        state.enabled = true;
        state.retired = false;
        state.health = "healthy".to_owned();
        state.failure = None;
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let mut credentials = Vec::new();
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET name=?2,description=?3,tool_name=?4,runner_kind=?5,
                        active_version=?6,enabled=1,retired=0,health='healthy',updated_at=?7
                     WHERE worker_id=?1",
                    params![
                        worker_id,
                        bundle.name,
                        bundle.description,
                        bundle.tool_name,
                        bundle.runner.kind(),
                        version,
                        state.updated_at,
                    ],
                )
                .map_err(|error| format!("rollback worker: {error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            replace_active_triggers(
                &transaction,
                worker_id,
                &bundle.triggers,
                true,
                &mut credentials,
            )?;
            transaction
                .execute(
                    "INSERT INTO worker_routes(worker_id,worker_version,tool_name,description,routing_json,enabled,updated_at)
                     VALUES (?1,?2,?3,?4,?5,1,?6)
                     ON CONFLICT(worker_id) DO UPDATE SET worker_version=excluded.worker_version,
                        tool_name=excluded.tool_name,description=excluded.description,
                        routing_json=excluded.routing_json,enabled=1,updated_at=excluded.updated_at",
                    params![
                        worker_id,
                        version,
                        bundle.tool_name,
                        bundle.description,
                        serde_json::to_string(&bundle.routing).map_err(|error| error.to_string())?,
                        state.updated_at,
                    ],
                )
                .map_err(|error| format!("restore worker route during rollback: {error}"))?;
            insert_audit(
                &transaction,
                worker_id,
                "rolled_back",
                &json!({
                    "fromVersion":prior.active_version,
                    "toVersion":version,
                    "newWebhookCredentialsRequireInspection":credentials.iter().map(|item| &item.trigger_id).collect::<Vec<_>>(),
                }),
            )?;
            insert_health(
                &transaction,
                worker_id,
                version,
                "healthy",
                "rollback",
                &json!({"fromVersion":prior.active_version}),
            )?;
            transaction.commit().map_err(|error| error.to_string())
        })();
        if let Err(error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(error);
        }
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        Ok((summary, credentials))
    }

    pub fn retire(&self, worker_id: &str) -> Result<WorkerSummary, String> {
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let mut state = prior.clone();
        state.enabled = false;
        state.retired = true;
        state.health = "retired".to_owned();
        state.failure = None;
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET enabled=0,retired=1,health='retired',updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|error| format!("retire worker: {error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            transaction
                .execute(
                    "UPDATE worker_triggers SET enabled=0 WHERE worker_id=?1",
                    [worker_id],
                )
                .map_err(|error| format!("retire worker triggers: {error}"))?;
            transaction
                .execute(
                    "UPDATE worker_routes SET enabled=0,updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|error| format!("retire worker route: {error}"))?;
            insert_audit(
                &transaction,
                worker_id,
                "retired",
                &json!({"activeVersion":state.active_version}),
            )?;
            insert_health(
                &transaction,
                worker_id,
                &state.active_version,
                "retired",
                "lifecycle",
                &json!({"action":"retired"}),
            )?;
            transaction.commit().map_err(|error| error.to_string())
        })();
        if let Err(error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(error);
        }
        self.summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))
    }

    pub fn purge(&self, worker_id: &str) -> Result<bool, String> {
        validate_identifier(worker_id, "workerId")?;
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        if !summary.retired {
            return Err("a worker must be retired before permanent purge".to_owned());
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let worker_dir = self.root.join(worker_id);
        let purging_root = self.root.join(".purging");
        fs::create_dir_all(&purging_root).map_err(|error| error.to_string())?;
        let staged = purging_root.join(format!("{worker_id}-{}", uuid::Uuid::now_v7()));
        fs::rename(&worker_dir, &staged)
            .map_err(|error| format!("stage worker bundle for purge: {error}"))?;
        let result = (|| -> Result<usize, String> {
            transaction
                .execute("DELETE FROM worker_inbox WHERE worker_id=?1", [worker_id])
                .map_err(|error| format!("purge worker inbox: {error}"))?;
            transaction
                .execute(
                    "DELETE FROM worker_invocations WHERE worker_id=?1",
                    [worker_id],
                )
                .map_err(|error| format!("purge worker runs: {error}"))?;
            transaction
                .execute(
                    "DELETE FROM worker_causal_traces
                     WHERE trace_id NOT IN (SELECT DISTINCT trace_id FROM worker_trace_deliveries)",
                    [],
                )
                .map_err(|error| format!("purge orphaned worker traces: {error}"))?;
            let changed = transaction
                .execute("DELETE FROM workers WHERE worker_id=?1", [worker_id])
                .map_err(|error| format!("purge worker index: {error}"))?;
            insert_audit(
                &transaction,
                worker_id,
                "purged",
                &json!({"lastActiveVersion":summary.active_version}),
            )?;
            transaction.commit().map_err(|error| error.to_string())?;
            Ok(changed)
        })();
        let changed = match result {
            Ok(changed) => changed,
            Err(error) => {
                let _ = fs::rename(&staged, &worker_dir);
                return Err(error);
            }
        };
        if let Err(error) = fs::remove_dir_all(&staged) {
            return Err(format!(
                "worker was purged from the active index but its staged bundle could not be erased at {}: {error}",
                staged.display()
            ));
        }
        Ok(changed > 0)
    }

    pub fn set_stop_all(&self, stopped: bool) -> Result<(), String> {
        self.connection()?
            .execute(
                "UPDATE worker_runtime_settings SET value=?1 WHERE key='stop_all'",
                [if stopped { "true" } else { "false" }],
            )
            .map_err(|error| format!("update worker stop-all: {error}"))?;
        Ok(())
    }

    pub fn stop_all(&self) -> Result<bool, String> {
        self.connection()?
            .query_row(
                "SELECT value FROM worker_runtime_settings WHERE key='stop_all'",
                [],
                |row| row.get::<_, String>(0),
            )
            .map(|value| value == "true")
            .map_err(|error| format!("read worker stop-all: {error}"))
    }

    pub fn begin_invocation(
        &self,
        worker_id: &str,
        worker_version: &str,
        input: &Value,
        idempotency_key: &str,
        trace_id: &str,
        causal_depth: u32,
        trigger_kind: &str,
    ) -> Result<(InvocationRecord, bool), String> {
        validate_runtime_identifier(idempotency_key, "idempotency key", 256)?;
        validate_runtime_identifier(trace_id, "trace id", 256)?;
        validate_runtime_identifier(trigger_kind, "trigger kind", 64)?;
        if let Some(existing) = self.invocation_by_key(worker_id, idempotency_key)? {
            self.record_suppressed_delivery(
                trace_id,
                worker_id,
                trigger_kind,
                idempotency_key,
                causal_depth,
            )?;
            return Ok((existing, true));
        }
        let invocation_id = format!("worker_run_{}", uuid::Uuid::now_v7());
        let created_at = chrono::Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker invocation queue transaction: {error}"))?;
        let insert = transaction.execute(
                "INSERT INTO worker_invocations(invocation_id,worker_id,worker_version,status,input_json,idempotency_key,trace_id,causal_depth,trigger_kind,created_at)
                 VALUES (?1,?2,?3,'queued',?4,?5,?6,?7,?8,?9)",
                params![
                    invocation_id,
                    worker_id,
                    worker_version,
                    serde_json::to_string(input).map_err(|error| error.to_string())?,
                    idempotency_key,
                    trace_id,
                    causal_depth,
                    trigger_kind,
                    created_at,
                ],
            );
        if let Err(error) = insert {
            drop(transaction);
            if let Some(existing) = self.invocation_by_key(worker_id, idempotency_key)? {
                self.record_suppressed_delivery(
                    trace_id,
                    worker_id,
                    trigger_kind,
                    idempotency_key,
                    causal_depth,
                )?;
                return Ok((existing, true));
            }
            return Err(format!("queue worker invocation: {error}"));
        }
        upsert_causal_trace(
            &transaction,
            trace_id,
            Some(&invocation_id),
            causal_depth,
            false,
        )?;
        transaction
            .execute(
                "INSERT INTO worker_trace_deliveries(trace_id,worker_id,trigger_kind,idempotency_key,invocation_id,created_at)
                 VALUES (?1,?2,?3,?4,?5,?6)",
                params![
                    trace_id,
                    worker_id,
                    trigger_kind,
                    idempotency_key,
                    invocation_id,
                    created_at,
                ],
            )
            .map_err(|error| format!("record worker trace delivery: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit queued worker invocation: {error}"))?;
        let record = self
            .invocation(&invocation_id)?
            .ok_or_else(|| "queued worker invocation disappeared".to_owned())?;
        Ok((record, false))
    }

    pub fn claim_running(&self, invocation_id: &str) -> Result<bool, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker delivery attempt: {error}"))?;
        let started_at = chrono::Utc::now().to_rfc3339();
        let changed = transaction
            .execute(
                "UPDATE worker_invocations SET status='running',started_at=?2
                 WHERE invocation_id=?1 AND status='queued'",
                params![invocation_id, started_at],
            )
            .map_err(|error| format!("mark worker invocation running: {error}"))?;
        if changed == 1 {
            let attempt_number = transaction
                .query_row(
                    "SELECT COALESCE(MAX(attempt_number),0)+1 FROM worker_attempts WHERE invocation_id=?1",
                    [invocation_id],
                    |row| row.get::<_, u32>(0),
                )
                .map_err(|error| format!("number worker delivery attempt: {error}"))?;
            transaction
                .execute(
                    "INSERT INTO worker_attempts(attempt_id,invocation_id,attempt_number,status,started_at)
                     VALUES (?1,?2,?3,'running',?4)",
                    params![
                        format!("worker_attempt_{}", uuid::Uuid::now_v7()),
                        invocation_id,
                        attempt_number,
                        started_at,
                    ],
                )
                .map_err(|error| format!("record worker delivery attempt: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit worker delivery attempt: {error}"))?;
        Ok(changed == 1)
    }

    pub fn complete_invocation(
        &self,
        invocation_id: &str,
        worker_id: &str,
        result: Result<&Value, &str>,
    ) -> Result<InvocationRecord, String> {
        let (status, output, error, severity, inbox_result) = match result {
            Ok(output) => (
                "completed",
                Some(serde_json::to_string(output).map_err(|error| error.to_string())?),
                None,
                "info",
                json!({"status":"completed","output":output}),
            ),
            Err(error) => (
                "failed",
                None,
                Some(error.to_owned()),
                "error",
                json!({"status":"failed","error":error}),
            ),
        };
        let mut connection = self.connection()?;
        let tx = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let completed_at = chrono::Utc::now().to_rfc3339();
        let changed = tx
            .execute(
                "UPDATE worker_invocations SET status=?2,output_json=?3,error=?4,completed_at=?5
                 WHERE invocation_id=?1 AND status='running'",
                params![invocation_id, status, output, error, completed_at],
            )
            .map_err(|error| format!("complete worker invocation: {error}"))?;
        if changed != 1 {
            return Err(format!(
                "worker invocation '{invocation_id}' was not in a running state"
            ));
        }
        tx.execute(
            "UPDATE worker_attempts SET status=?2,completed_at=?3,error=?4
             WHERE attempt_id=(SELECT attempt_id FROM worker_attempts
                WHERE invocation_id=?1 AND status='running' ORDER BY attempt_number DESC LIMIT 1)",
            params![invocation_id, status, completed_at, error],
        )
        .map_err(|error| format!("complete worker delivery attempt: {error}"))?;
        tx.execute(
            "INSERT INTO worker_inbox(inbox_id,invocation_id,worker_id,severity,result_json,created_at)
             VALUES (?1,?2,?3,?4,?5,?6)",
            params![
                format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                invocation_id,
                worker_id,
                severity,
                serde_json::to_string(&inbox_result).map_err(|error| error.to_string())?,
                completed_at,
            ],
        )
        .map_err(|error| format!("record worker inbox result: {error}"))?;
        tx.commit().map_err(|error| error.to_string())?;
        self.invocation(invocation_id)?
            .ok_or_else(|| "completed worker invocation disappeared".to_owned())
    }

    pub fn invocation(&self, invocation_id: &str) -> Result<Option<InvocationRecord>, String> {
        self.connection()?
            .query_row(
                invocation_select("WHERE invocation_id=?1").as_str(),
                [invocation_id],
                row_invocation,
            )
            .optional()
            .map_err(|error| format!("load worker invocation: {error}"))
    }

    pub fn queued_invocations(&self, limit: u32) -> Result<Vec<InvocationRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} JOIN workers w ON w.worker_id=worker_invocations.worker_id
                     WHERE worker_invocations.status='queued' AND w.enabled=1 AND w.retired=0
                     ORDER BY worker_invocations.created_at LIMIT ?1",
                invocation_select_base()
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map([limit.min(1_000)], row_invocation)
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn runs(
        &self,
        worker_id: Option<&str>,
        limit: u32,
    ) -> Result<Vec<InvocationRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "{} WHERE (?1 IS NULL OR worker_id=?1) ORDER BY created_at DESC LIMIT ?2",
                invocation_select_base()
            ))
            .map_err(|error| error.to_string())?;
        statement
            .query_map(params![worker_id, limit.min(500)], row_invocation)
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn success_evidence(&self, worker_id: &str) -> Result<Value, String> {
        self.connection()?
            .query_row(
                "SELECT COUNT(*),MAX(completed_at) FROM worker_invocations
                 WHERE worker_id=?1 AND status='completed'",
                [worker_id],
                |row| {
                    Ok(json!({
                        "completedRuns": row.get::<_, u64>(0)?,
                        "lastCompletedAt": row.get::<_, Option<String>>(1)?,
                    }))
                },
            )
            .map_err(|error| format!("load worker success evidence: {error}"))
    }

    fn invocation_by_key(
        &self,
        worker_id: &str,
        key: &str,
    ) -> Result<Option<InvocationRecord>, String> {
        self.connection()?
            .query_row(
                invocation_select("WHERE worker_id=?1 AND idempotency_key=?2").as_str(),
                params![worker_id, key],
                row_invocation,
            )
            .optional()
            .map_err(|error| format!("load idempotent worker invocation: {error}"))
    }

    fn record_suppressed_delivery(
        &self,
        trace_id: &str,
        worker_id: &str,
        trigger_kind: &str,
        idempotency_key: &str,
        causal_depth: u32,
    ) -> Result<(), String> {
        self.record_trigger_suppression(
            trace_id,
            worker_id,
            trigger_kind,
            idempotency_key,
            causal_depth,
            "duplicate_delivery",
        )
    }

    pub fn record_trigger_suppression(
        &self,
        trace_id: &str,
        worker_id: &str,
        trigger_kind: &str,
        idempotency_key: &str,
        causal_depth: u32,
        reason: &str,
    ) -> Result<(), String> {
        validate_runtime_identifier(trace_id, "trace id", 256)?;
        validate_runtime_identifier(trigger_kind, "trigger kind", 64)?;
        validate_runtime_identifier(idempotency_key, "idempotency key", 256)?;
        validate_runtime_identifier(reason, "suppression reason", 64)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker loop-suppression record: {error}"))?;
        upsert_causal_trace(&transaction, trace_id, None, causal_depth, true)?;
        insert_audit(
            &transaction,
            worker_id,
            "delivery_suppressed",
            &json!({
                "traceId":trace_id,
                "triggerKind":trigger_kind,
                "idempotencyKey":idempotency_key,
                "reason":reason,
                "causalDepth":causal_depth,
            }),
        )?;
        transaction
            .commit()
            .map_err(|error| format!("commit worker loop suppression: {error}"))
    }

    pub fn attempts(&self, invocation_id: &str) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT attempt_id,attempt_number,status,started_at,completed_at,error
                 FROM worker_attempts WHERE invocation_id=?1 ORDER BY attempt_number",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([invocation_id], |row| {
                Ok(json!({
                    "attemptId":row.get::<_, String>(0)?,
                    "attemptNumber":row.get::<_, u32>(1)?,
                    "status":row.get::<_, String>(2)?,
                    "startedAt":row.get::<_, String>(3)?,
                    "completedAt":row.get::<_, Option<String>>(4)?,
                    "error":row.get::<_, Option<String>>(5)?,
                }))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn trace(&self, trace_id: &str) -> Result<Option<Value>, String> {
        self.connection()?
            .query_row(
                "SELECT trace_id,root_invocation_id,max_causal_depth,invocation_count,
                        suppressed_count,first_seen_at,last_seen_at
                 FROM worker_causal_traces WHERE trace_id=?1",
                [trace_id],
                |row| {
                    Ok(json!({
                        "traceId":row.get::<_, String>(0)?,
                        "rootInvocationId":row.get::<_, Option<String>>(1)?,
                        "maxCausalDepth":row.get::<_, u32>(2)?,
                        "invocationCount":row.get::<_, u32>(3)?,
                        "suppressedCount":row.get::<_, u32>(4)?,
                        "firstSeenAt":row.get::<_, String>(5)?,
                        "lastSeenAt":row.get::<_, String>(6)?,
                    }))
                },
            )
            .optional()
            .map_err(|error| format!("load worker causal trace: {error}"))
    }

    pub fn inbox(&self, worker_id: Option<&str>, limit: u32) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT inbox_id,invocation_id,worker_id,severity,result_json,seen,created_at
                 FROM worker_inbox WHERE (?1 IS NULL OR worker_id=?1)
                 ORDER BY created_at DESC LIMIT ?2",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map(params![worker_id, limit.min(500)], |row| {
                let result: String = row.get(4)?;
                Ok(json!({
                    "inboxId": row.get::<_, String>(0)?,
                    "invocationId": row.get::<_, String>(1)?,
                    "workerId": row.get::<_, String>(2)?,
                    "severity": row.get::<_, String>(3)?,
                    "result": serde_json::from_str::<Value>(&result).unwrap_or(Value::Null),
                    "seen": row.get::<_, i64>(5)? != 0,
                    "createdAt": row.get::<_, String>(6)?,
                }))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn record_system_inbox(
        &self,
        worker_id: &str,
        phase: &str,
        result: &Value,
    ) -> Result<(), String> {
        validate_runtime_identifier(phase, "system inbox phase", 64)?;
        self.connection()?
            .execute(
                "INSERT INTO worker_inbox(inbox_id,invocation_id,worker_id,severity,result_json,created_at)
                 VALUES (?1,?2,?3,'error',?4,?5)",
                params![
                    format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                    format!("worker_system_{phase}_{}", uuid::Uuid::now_v7()),
                    worker_id,
                    serde_json::to_string(result).map_err(|error| error.to_string())?,
                    chrono::Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("record worker system inbox result: {error}"))?;
        Ok(())
    }

    /// Claim notable unseen background results for transient prompt attachment.
    /// Errors are always notable; successful manual calls are already visible
    /// to their caller and are intentionally omitted.
    pub fn take_notable_unseen(
        &self,
        relevance_query: Option<&str>,
        limit: u32,
    ) -> Result<Vec<Value>, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let query_terms = relevance_query.map(terms).unwrap_or_default();
        let candidates = {
            let mut statement = transaction
                .prepare(
                    "SELECT i.inbox_id,i.invocation_id,i.worker_id,i.severity,i.result_json,
                            i.created_at,COALESCE(r.trigger_kind,'system'),w.name,w.description
                     FROM worker_inbox i
                     LEFT JOIN worker_invocations r ON r.invocation_id=i.invocation_id
                     JOIN workers w ON w.worker_id=i.worker_id
                     WHERE i.seen=0
                        AND (i.severity!='info' OR COALESCE(r.trigger_kind,'system')!='manual')
                     ORDER BY i.created_at DESC LIMIT 200",
                )
                .map_err(|error| error.to_string())?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, String>(8)?,
                    ))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        let mut selected = Vec::new();
        for (
            inbox_id,
            invocation_id,
            worker_id,
            severity,
            result,
            created_at,
            trigger,
            name,
            description,
        ) in candidates
        {
            let worker_terms = terms(&format!("{name} {description}"));
            let relevant = severity == "error"
                || query_terms.is_empty()
                || !query_terms.is_disjoint(&worker_terms);
            if !relevant {
                continue;
            }
            selected.push(json!({
                "inboxId":inbox_id,
                "invocationId":invocation_id,
                "workerId":worker_id,
                "workerName":name,
                "severity":severity,
                "triggerKind":trigger,
                "result":serde_json::from_str::<Value>(&result).unwrap_or(Value::Null),
                "seen":false,
                "createdAt":created_at,
            }));
            if selected.len() >= limit.min(32) as usize {
                break;
            }
        }
        for item in &selected {
            transaction
                .execute(
                    "UPDATE worker_inbox SET seen=1 WHERE inbox_id=?1 AND seen=0",
                    [item["inboxId"].as_str().unwrap_or_default()],
                )
                .map_err(|error| format!("mark worker inbox attachment seen: {error}"))?;
        }
        transaction.commit().map_err(|error| error.to_string())?;
        Ok(selected)
    }

    pub fn audit(&self, worker_id: Option<&str>, limit: u32) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT audit_id,worker_id,action,details_json,created_at
                 FROM worker_audit WHERE (?1 IS NULL OR worker_id=?1)
                 ORDER BY created_at DESC LIMIT ?2",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map(params![worker_id, limit.min(500)], |row| {
                let details: String = row.get(3)?;
                Ok(json!({
                    "auditId": row.get::<_, String>(0)?,
                    "workerId": row.get::<_, String>(1)?,
                    "action": row.get::<_, String>(2)?,
                    "details": serde_json::from_str::<Value>(&details).unwrap_or(Value::Null),
                    "createdAt": row.get::<_, String>(4)?,
                }))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn due_schedules(&self) -> Result<Vec<(String, WorkerTrigger, String)>, String> {
        let now = chrono::Utc::now().to_rfc3339();
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT t.worker_id,t.config_json,t.next_run_at FROM worker_triggers t
                 JOIN workers w ON w.worker_id=t.worker_id
                 WHERE t.kind='schedule' AND t.enabled=1 AND w.enabled=1 AND w.retired=0
                   AND t.next_run_at<=?1",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([now], |row| {
                let config: String = row.get(1)?;
                let trigger = serde_json::from_str(&config).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?;
                Ok((row.get(0)?, trigger, row.get(2)?))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn advance_schedule(
        &self,
        worker_id: &str,
        trigger_id: &str,
        every_seconds: u64,
    ) -> Result<(), String> {
        let connection = self.connection()?;
        let prior = connection
            .query_row(
                "SELECT next_run_at FROM worker_triggers WHERE worker_id=?1 AND trigger_id=?2",
                params![worker_id, trigger_id],
                |row| row.get::<_, String>(0),
            )
            .map_err(|error| format!("read worker schedule cursor: {error}"))?;
        let interval = chrono::Duration::seconds(
            i64::try_from(every_seconds).map_err(|_| "schedule interval is too large")?,
        );
        let mut next = chrono::DateTime::parse_from_rfc3339(&prior)
            .map_err(|error| format!("decode worker schedule cursor: {error}"))?
            .with_timezone(&chrono::Utc)
            + interval;
        while next <= chrono::Utc::now() {
            next += interval;
        }
        connection
            .execute(
                "UPDATE worker_triggers SET next_run_at=?3 WHERE worker_id=?1 AND trigger_id=?2",
                params![worker_id, trigger_id, next.to_rfc3339()],
            )
            .map_err(|error| format!("advance worker schedule: {error}"))?;
        Ok(())
    }

    pub fn event_triggers(&self) -> Result<Vec<(String, WorkerTrigger, i64)>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT t.worker_id,t.config_json,t.stream_cursor FROM worker_triggers t
                 JOIN workers w ON w.worker_id=t.worker_id
                 WHERE t.kind='engine_event' AND t.enabled=1 AND w.enabled=1 AND w.retired=0",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([], |row| {
                let config: String = row.get(1)?;
                let trigger = serde_json::from_str(&config).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?;
                Ok((row.get(0)?, trigger, row.get(2)?))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn update_stream_cursor(
        &self,
        worker_id: &str,
        trigger_id: &str,
        cursor: i64,
    ) -> Result<(), String> {
        self.connection()?
            .execute(
                "UPDATE worker_triggers SET stream_cursor=?3 WHERE worker_id=?1 AND trigger_id=?2",
                params![worker_id, trigger_id, cursor],
            )
            .map_err(|error| format!("advance worker event cursor: {error}"))?;
        Ok(())
    }

    pub fn verify_webhook(
        &self,
        worker_id: &str,
        trigger_id: &str,
        token: &str,
    ) -> Result<Value, String> {
        let row = self
            .connection()?
            .query_row(
                "SELECT t.config_json,t.token_hash FROM worker_triggers t
                 JOIN workers w ON w.worker_id=t.worker_id
                 WHERE t.worker_id=?1 AND t.trigger_id=?2 AND t.kind='webhook'
                   AND t.enabled=1 AND w.enabled=1 AND w.retired=0",
                params![worker_id, trigger_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(|error| format!("load worker webhook: {error}"))?
            .ok_or_else(|| "worker webhook was not found or is disabled".to_owned())?;
        if hash_secret(token) != row.1 {
            return Err("worker webhook token is invalid".to_owned());
        }
        let trigger: WorkerTrigger =
            serde_json::from_str(&row.0).map_err(|error| error.to_string())?;
        match trigger {
            WorkerTrigger::Webhook { input, .. } => Ok(input),
            _ => Err("stored trigger is not a webhook".to_owned()),
        }
    }

    pub fn rotate_webhook(
        &self,
        worker_id: &str,
        trigger_id: &str,
    ) -> Result<WebhookCredential, String> {
        let token = generate_token();
        let changed = self
            .connection()?
            .execute(
                "UPDATE worker_triggers SET token_hash=?3,enabled=1
                 WHERE worker_id=?1 AND trigger_id=?2 AND kind='webhook'",
                params![worker_id, trigger_id, hash_secret(&token)],
            )
            .map_err(|error| format!("rotate worker webhook token: {error}"))?;
        if changed == 0 {
            return Err("worker webhook was not found".to_owned());
        }
        Ok(WebhookCredential {
            trigger_id: trigger_id.to_owned(),
            path: format!("/engine/workers/webhooks/{worker_id}/{trigger_id}"),
            token,
        })
    }

    fn read_state(&self, worker_id: &str) -> Result<Option<WorkerState>, String> {
        validate_identifier(worker_id, "workerId")?;
        let path = self.root.join(worker_id).join("worker.json");
        if !path.exists() {
            return Ok(None);
        }
        serde_json::from_slice(&fs::read(path).map_err(|error| error.to_string())?)
            .map(Some)
            .map_err(|error| format!("decode worker state: {error}"))
    }

    fn closest_overlap(
        &self,
        bundle: &WorkerBundle,
        minimum_score: f64,
    ) -> Result<Option<String>, String> {
        let target_name = terms(&bundle.name);
        let target = terms(&format!(
            "{} {} {} {}",
            bundle.name,
            bundle.description,
            bundle.routing.intents.join(" "),
            bundle.routing.examples.join(" ")
        ));
        let mut best: Option<(f64, String)> = None;
        for worker in self.list(false)? {
            let Ok(active) = self.load_active(&worker.worker_id) else {
                continue;
            };
            let candidate_name = terms(&worker.name);
            let candidate = terms(&format!(
                "{} {} {} {}",
                worker.name,
                worker.description,
                active.bundle.routing.intents.join(" "),
                active.bundle.routing.examples.join(" ")
            ));
            let score = jaccard(&target_name, &candidate_name).max(jaccard(&target, &candidate));
            if score >= minimum_score && best.as_ref().is_none_or(|current| score > current.0) {
                best = Some((score, worker.worker_id));
            }
        }
        Ok(best.map(|(_, worker_id)| worker_id))
    }
}

pub(super) fn validate_bundle(bundle: &WorkerBundle) -> Result<(), String> {
    if bundle.schema_version != BUNDLE_SCHEMA {
        return Err(format!(
            "unsupported worker bundle schema '{}'",
            bundle.schema_version
        ));
    }
    if bundle.name.trim().is_empty() || bundle.description.trim().is_empty() {
        return Err("worker name and description are required".to_owned());
    }
    validate_object_schema(&bundle.input_schema, "inputSchema")?;
    validate_object_schema(&bundle.output_schema, "outputSchema")?;
    let mut trigger_ids = BTreeSet::new();
    for trigger in &bundle.triggers {
        validate_identifier(trigger.id(), "trigger id")?;
        if !trigger_ids.insert(trigger.id()) {
            return Err(format!("duplicate trigger id '{}'", trigger.id()));
        }
        match trigger {
            WorkerTrigger::Schedule { every_seconds, .. } if *every_seconds == 0 => {
                return Err("schedule everySeconds must be greater than zero".to_owned());
            }
            WorkerTrigger::EngineEvent { topic, .. } if topic.trim().is_empty() => {
                return Err("engine event topic must not be empty".to_owned());
            }
            WorkerTrigger::EngineEvent { filter, .. } if !filter.is_object() => {
                return Err("engine event filter must be a JSON object".to_owned());
            }
            WorkerTrigger::Schedule { id, input, .. } => {
                let function_id =
                    crate::engine::FunctionId::new(format!("worker_kernel::schedule_{id}"))
                        .map_err(|error| error.to_string())?;
                crate::engine::validate_engine_schema_payload(
                    &function_id,
                    "request",
                    &bundle.input_schema,
                    input,
                )
                .map_err(|error| {
                    format!("schedule trigger '{id}' input does not match inputSchema: {error}")
                })?;
            }
            _ => {}
        }
    }
    let mut secrets = BTreeSet::new();
    for binding in &bundle.secret_bindings {
        validate_identifier(binding.name(), "secret binding")?;
        if !secrets.insert(binding.name()) {
            return Err(format!("duplicate secret binding '{}'", binding.name()));
        }
    }
    for relative in bundle.files.keys() {
        let _ = safe_relative_path(relative)?;
    }
    match &bundle.runner {
        WorkerRunner::Agent {
            instructions,
            model,
        } => {
            if instructions.trim().is_empty() {
                return Err("agent runner instructions must not be empty".to_owned());
            }
            if model
                .as_deref()
                .is_some_and(|model| model.trim().is_empty())
            {
                return Err("agent runner model must not be empty when provided".to_owned());
            }
        }
        WorkerRunner::Command { command } => validate_command(command)?,
        WorkerRunner::Service {
            command,
            invoke_url,
            health_url,
        } => {
            validate_command(command)?;
            validate_resident_url(invoke_url, "invokeUrl")?;
            if let Some(health_url) = health_url {
                validate_resident_url(health_url, "healthUrl")?;
            }
        }
    }
    for dependency in &bundle.dependencies {
        validate_identifier(&dependency.name, "dependency name")?;
        if dependency.name.trim().is_empty()
            || dependency.source.trim().is_empty()
            || dependency.version.trim().is_empty()
        {
            return Err("dependencies require name, source, and exact version".to_owned());
        }
        if dependency.version.eq_ignore_ascii_case("latest")
            || dependency
                .version
                .chars()
                .any(|character| matches!(character, '*' | '^' | '~' | '<' | '>'))
        {
            return Err(format!(
                "dependency '{}' must lock an exact version or revision",
                dependency.name
            ));
        }
        if let Some(expected) = dependency.checksum.as_deref() {
            let checksum = expected.strip_prefix("sha256:").ok_or_else(|| {
                format!(
                    "dependency '{}' checksum must start with sha256:",
                    dependency.name
                )
            })?;
            if checksum.len() != 64
                || !checksum
                    .chars()
                    .all(|character| character.is_ascii_hexdigit())
            {
                return Err(format!(
                    "dependency '{}' checksum must be sha256 followed by 64 hex characters",
                    dependency.name
                ));
            }
        }
        if let Some(install) = &dependency.install {
            validate_worker_command(install, "dependency install")?;
        }
    }
    for test in &bundle.smoke_tests {
        validate_worker_command(test, "smoke test")?;
    }
    for check in &bundle.health_checks {
        validate_worker_command(check, "health check")?;
    }
    if bundle.provenance.is_empty() {
        return Err("worker provenance requires at least one source record".to_owned());
    }
    for provenance in &bundle.provenance {
        if provenance.source.trim().is_empty() {
            return Err("worker provenance source must not be empty".to_owned());
        }
    }
    Ok(())
}

fn validate_object_schema(schema: &Value, field: &'static str) -> Result<(), String> {
    if !schema.is_object() || schema.get("type").and_then(Value::as_str) != Some("object") {
        return Err(format!("{field} must be a JSON object schema"));
    }
    let function_id = crate::engine::FunctionId::new("worker_kernel::bundle_schema")
        .map_err(|error| error.to_string())?;
    crate::engine::validate_engine_schema_definition(&function_id, field, schema)
        .map_err(|error| format!("invalid {field}: {error}"))
}

fn validate_command(command: &[String]) -> Result<(), String> {
    if command.is_empty() || command[0].trim().is_empty() {
        return Err("worker command must contain a program".to_owned());
    }
    Ok(())
}

fn validate_worker_command(command: &WorkerCommand, field: &str) -> Result<(), String> {
    validate_command(&command.command)?;
    if command.timeout_seconds == 0 || command.timeout_seconds > MAX_INVOCATION_SECONDS {
        return Err(format!(
            "worker {field} timeoutSeconds must be between 1 and {}",
            MAX_INVOCATION_SECONDS
        ));
    }
    Ok(())
}

fn validate_resident_url(value: &str, field: &str) -> Result<(), String> {
    let url = url::Url::parse(value).map_err(|error| format!("resident {field}: {error}"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(format!("resident {field} must use http or https"));
    }
    let loopback = match url.host() {
        Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(url::Host::Ipv4(address)) => address.is_loopback(),
        Some(url::Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    };
    if !loopback {
        return Err(format!("resident {field} must target a loopback host"));
    }
    Ok(())
}

fn validate_identifier(value: &str, field: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 96
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
    {
        return Err(format!(
            "{field} must contain only ASCII letters, numbers, '-' or '_'"
        ));
    }
    Ok(())
}

fn validate_content_version(value: &str) -> Result<(), String> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("worker version must be a 64-character hexadecimal content hash".to_owned());
    }
    Ok(())
}

fn validate_runtime_identifier(value: &str, field: &str, max: usize) -> Result<(), String> {
    if value.trim().is_empty() || value.len() > max || value.chars().any(char::is_control) {
        return Err(format!(
            "worker {field} must be non-empty, at most {max} characters, and contain no control characters"
        ));
    }
    Ok(())
}

fn normalize_tool_name(value: &str) -> Result<String, String> {
    let mut value = value.replace('-', "_");
    if !value.starts_with("worker_") {
        value = format!("worker_{value}");
    }
    validate_identifier(&value, "toolName")?;
    Ok(value)
}

fn safe_relative_path(value: &str) -> Result<PathBuf, String> {
    let path = Path::new(value);
    if path.is_absolute() || value.is_empty() {
        return Err(format!("worker file path '{value}' must be relative"));
    }
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return Err(format!("worker file path '{value}' escapes its bundle"));
    }
    Ok(path.to_path_buf())
}

fn slug(value: &str) -> String {
    let mut result = String::new();
    let mut separator = false;
    for character in value.chars() {
        if character.is_ascii_alphanumeric() {
            if separator && !result.is_empty() {
                result.push('-');
            }
            result.push(character.to_ascii_lowercase());
            separator = false;
        } else {
            separator = true;
        }
    }
    if result.is_empty() {
        format!("worker-{}", &uuid::Uuid::now_v7().to_string()[..8])
    } else {
        result.truncate(80);
        result
    }
}

fn terms(value: &str) -> HashSet<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .map(str::to_ascii_lowercase)
        .filter(|term| term.len() > 2 || term.chars().all(|character| character.is_ascii_digit()))
        .collect()
}

fn jaccard(left: &HashSet<String>, right: &HashSet<String>) -> f64 {
    let union = left.union(right).count();
    if union == 0 {
        0.0
    } else {
        left.intersection(right).count() as f64 / union as f64
    }
}

fn write_json_atomic(path: &Path, value: &impl serde::Serialize) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temporary = path.with_extension(format!("tmp-{}", uuid::Uuid::now_v7()));
    fs::write(
        &temporary,
        serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?,
    )
    .map_err(|error| format!("write {}: {error}", temporary.display()))?;
    fs::rename(&temporary, path).map_err(|error| format!("activate {}: {error}", path.display()))
}

fn replace_active_triggers(
    connection: &Connection,
    worker_id: &str,
    triggers: &[WorkerTrigger],
    enabled: bool,
    new_webhooks: &mut Vec<WebhookCredential>,
) -> Result<(), String> {
    let prior = {
        let mut statement = connection
            .prepare(
                "SELECT trigger_id,kind,token_hash,next_run_at,stream_cursor
                 FROM worker_triggers WHERE worker_id=?1",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([worker_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    (
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, i64>(4)?,
                    ),
                ))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<HashMap<_, _>>>()
            .map_err(|error| error.to_string())?
    };
    connection
        .execute(
            "DELETE FROM worker_triggers WHERE worker_id=?1",
            [worker_id],
        )
        .map_err(|error| format!("replace worker triggers: {error}"))?;
    for trigger in triggers {
        let matching = prior
            .get(trigger.id())
            .filter(|(kind, _, _, _)| kind == trigger.kind());
        let mut token_hash = matching.and_then(|(_, token, _, _)| token.clone());
        if matches!(trigger, WorkerTrigger::Webhook { .. }) && token_hash.is_none() {
            let token = generate_token();
            token_hash = Some(hash_secret(&token));
            new_webhooks.push(WebhookCredential {
                trigger_id: trigger.id().to_owned(),
                path: format!("/engine/workers/webhooks/{worker_id}/{}", trigger.id()),
                token,
            });
        }
        let next_run_at = match trigger {
            WorkerTrigger::Schedule { every_seconds, .. } => matching
                .and_then(|(_, _, next, _)| next.clone())
                .or_else(|| {
                    Some(
                        (chrono::Utc::now()
                            + chrono::Duration::seconds(
                                i64::try_from(*every_seconds).unwrap_or(i64::MAX),
                            ))
                        .to_rfc3339(),
                    )
                }),
            _ => None,
        };
        let stream_cursor = if matches!(trigger, WorkerTrigger::EngineEvent { .. }) {
            matching.map_or(0, |(_, _, _, cursor)| *cursor)
        } else {
            0
        };
        connection
            .execute(
                "INSERT INTO worker_triggers(worker_id,trigger_id,kind,config_json,token_hash,next_run_at,stream_cursor,enabled)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                params![
                    worker_id,
                    trigger.id(),
                    trigger.kind(),
                    serde_json::to_string(trigger).map_err(|error| error.to_string())?,
                    token_hash,
                    next_run_at,
                    stream_cursor,
                    i64::from(enabled),
                ],
            )
            .map_err(|error| format!("insert worker trigger '{}': {error}", trigger.id()))?;
    }
    Ok(())
}

fn insert_audit(
    connection: &Connection,
    worker_id: &str,
    action: &str,
    details: &Value,
) -> Result<(), String> {
    connection
        .execute(
            "INSERT INTO worker_audit(audit_id,worker_id,action,details_json,created_at)
             VALUES (?1,?2,?3,?4,?5)",
            params![
                format!("worker_audit_{}", uuid::Uuid::now_v7()),
                worker_id,
                action,
                serde_json::to_string(details).map_err(|error| error.to_string())?,
                chrono::Utc::now().to_rfc3339(),
            ],
        )
        .map_err(|error| format!("record worker audit action '{action}': {error}"))?;
    Ok(())
}

fn insert_health(
    connection: &Connection,
    worker_id: &str,
    worker_version: &str,
    status: &str,
    source: &str,
    details: &Value,
) -> Result<(), String> {
    connection
        .execute(
            "INSERT INTO worker_health(health_id,worker_id,worker_version,status,source,details_json,recorded_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7)",
            params![
                format!("worker_health_{}", uuid::Uuid::now_v7()),
                worker_id,
                worker_version,
                status,
                source,
                serde_json::to_string(details).map_err(|error| error.to_string())?,
                chrono::Utc::now().to_rfc3339(),
            ],
        )
        .map_err(|error| format!("record worker health: {error}"))?;
    Ok(())
}

fn upsert_causal_trace(
    connection: &Connection,
    trace_id: &str,
    invocation_id: Option<&str>,
    causal_depth: u32,
    suppressed: bool,
) -> Result<(), String> {
    let now = chrono::Utc::now().to_rfc3339();
    connection
        .execute(
            "INSERT INTO worker_causal_traces(trace_id,root_invocation_id,max_causal_depth,
                invocation_count,suppressed_count,first_seen_at,last_seen_at)
             VALUES (?1,?2,?3,?4,?5,?6,?6)
             ON CONFLICT(trace_id) DO UPDATE SET
                root_invocation_id=COALESCE(worker_causal_traces.root_invocation_id,excluded.root_invocation_id),
                max_causal_depth=MAX(worker_causal_traces.max_causal_depth,excluded.max_causal_depth),
                invocation_count=worker_causal_traces.invocation_count+excluded.invocation_count,
                suppressed_count=worker_causal_traces.suppressed_count+excluded.suppressed_count,
                last_seen_at=excluded.last_seen_at",
            params![
                trace_id,
                invocation_id,
                causal_depth,
                i64::from(!suppressed),
                i64::from(suppressed),
                now,
            ],
        )
        .map_err(|error| format!("record worker causal trace: {error}"))?;
    Ok(())
}

fn tree_version(root: &Path) -> Result<String, String> {
    let mut files = walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("hash worker tree: {error}"))?;
    files.retain(|entry| {
        let is_root_hash = entry
            .path()
            .strip_prefix(root)
            .is_ok_and(|relative| relative == Path::new("content.sha256"));
        (entry.file_type().is_file() || entry.file_type().is_symlink()) && !is_root_hash
    });
    files.sort_by(|left, right| left.path().cmp(right.path()));
    let mut digest = Sha256::new();
    for entry in files {
        let relative = entry
            .path()
            .strip_prefix(root)
            .map_err(|error| error.to_string())?;
        digest.update(relative.to_string_lossy().as_bytes());
        digest.update([0]);
        if entry.file_type().is_symlink() {
            digest.update(
                fs::read_link(entry.path())
                    .map_err(|error| {
                        format!("hash worker symlink {}: {error}", entry.path().display())
                    })?
                    .to_string_lossy()
                    .as_bytes(),
            );
            digest.update([0xfe]);
        } else {
            digest.update(fs::read(entry.path()).map_err(|error| {
                format!("hash worker file {}: {error}", entry.path().display())
            })?);
            digest.update([0xff]);
        }
    }
    Ok(hex::encode(digest.finalize()))
}

fn row_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<WorkerSummary> {
    Ok(WorkerSummary {
        worker_id: row.get(0)?,
        name: row.get(1)?,
        description: row.get(2)?,
        tool_name: row.get(3)?,
        runner_kind: row.get(4)?,
        active_version: row.get(5)?,
        enabled: row.get::<_, i64>(6)? != 0,
        retired: row.get::<_, i64>(7)? != 0,
        health: row.get(8)?,
        updated_at: row.get(9)?,
        trigger_count: row.get(10)?,
    })
}

fn invocation_select(condition: &str) -> String {
    format!("{} {condition}", invocation_select_base())
}

fn invocation_select_base() -> &'static str {
    "SELECT worker_invocations.invocation_id,worker_invocations.worker_id,
            worker_invocations.worker_version,worker_invocations.status,
            worker_invocations.input_json,worker_invocations.output_json,
            worker_invocations.error,worker_invocations.idempotency_key,
            worker_invocations.trace_id,worker_invocations.causal_depth,
            worker_invocations.trigger_kind,
            (SELECT COUNT(*) FROM worker_attempts a
                WHERE a.invocation_id=worker_invocations.invocation_id),
            worker_invocations.created_at,
            worker_invocations.started_at,worker_invocations.completed_at
     FROM worker_invocations"
}

fn row_invocation(row: &rusqlite::Row<'_>) -> rusqlite::Result<InvocationRecord> {
    let input: String = row.get(4)?;
    let output: Option<String> = row.get(5)?;
    Ok(InvocationRecord {
        invocation_id: row.get(0)?,
        worker_id: row.get(1)?,
        worker_version: row.get(2)?,
        status: row.get(3)?,
        input: serde_json::from_str(&input).unwrap_or(Value::Null),
        output: output.and_then(|value| serde_json::from_str(&value).ok()),
        error: row.get(6)?,
        idempotency_key: row.get(7)?,
        trace_id: row.get(8)?,
        causal_depth: row.get(9)?,
        trigger_kind: row.get(10)?,
        attempt_count: row.get(11)?,
        created_at: row.get(12)?,
        started_at: row.get(13)?,
        completed_at: row.get(14)?,
    })
}

fn generate_token() -> String {
    let mut bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    format!("trwh_{}", hex::encode(bytes))
}

fn hash_secret(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::worker_kernel::types::{WorkerRunner, WorkerTrigger};

    fn bundle() -> WorkerBundle {
        WorkerBundle {
            schema_version: BUNDLE_SCHEMA.to_owned(),
            worker_id: None,
            name: "Recent Research".to_owned(),
            description: "Research a topic across recent sources".to_owned(),
            tool_name: None,
            input_schema: json!({"type":"object","properties":{"topic":{"type":"string"}}}),
            output_schema: json!({"type":"object"}),
            runner: WorkerRunner::Command {
                command: vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()],
            },
            files: Default::default(),
            dependencies: Vec::new(),
            triggers: vec![WorkerTrigger::Webhook {
                id: "research".to_owned(),
                input: json!({}),
            }],
            secret_bindings: Vec::new(),
            smoke_tests: Vec::new(),
            health_checks: Vec::new(),
            provenance: vec![super::super::super::types::SourceProvenance {
                source: "test:worker-store".to_owned(),
                revision: Some("1".to_owned()),
                checksum: None,
            }],
            routing: Default::default(),
        }
    }

    #[test]
    fn prepare_and_publish_is_atomic_and_versioned() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut candidate = bundle();
        candidate.files.insert(
            "content.sha256".to_owned(),
            "worker-owned content".to_owned(),
        );
        let mut prepared = store.prepare(candidate, None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let version = prepared.version.clone();
        let outcome = store.publish(prepared).unwrap();

        assert!(outcome.created);
        assert_eq!(outcome.worker.active_version, version);
        assert_eq!(outcome.webhooks.len(), 1);
        assert!(store.load_active("recent-research").is_ok());
        let inspection = store.inspect("recent-research").unwrap();
        assert_eq!(inspection["route"]["workerVersion"], version);
        assert_eq!(inspection["route"]["enabled"], true);
        assert_eq!(inspection["healthHistory"][0]["status"], "healthy");
    }

    #[test]
    fn prepare_normalizes_a_plain_tool_name_without_an_authoring_retry() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut candidate = bundle();
        candidate.tool_name = Some("last30days-research".to_owned());

        let prepared = store.prepare(candidate, None).unwrap();

        assert_eq!(
            prepared.bundle.tool_name.as_deref(),
            Some("worker_last30days_research")
        );
    }

    #[test]
    fn first_schema_open_snapshots_legacy_profile_and_restores_it() {
        let temp = tempfile::tempdir().unwrap();
        let profile = temp.path().join("profiles/user/profile.toml");
        fs::create_dir_all(profile.parent().unwrap()).unwrap();
        fs::write(&profile, "[settings]\nautonomousWorkers = false\n").unwrap();
        let legacy_database = temp.path().join("internal/database/tron.sqlite");
        fs::create_dir_all(legacy_database.parent().unwrap()).unwrap();
        let connection = Connection::open(&legacy_database).unwrap();
        connection
            .execute("CREATE TABLE legacy(value TEXT NOT NULL)", [])
            .unwrap();
        connection
            .execute("INSERT INTO legacy VALUES('before-worker-schema')", [])
            .unwrap();
        drop(connection);
        let worker_database = temp.path().join("internal/database/workers.sqlite");
        assert!(!worker_database.exists());

        let store = WorkerStore::open(temp.path().to_path_buf(), "user").unwrap();
        assert!(worker_database.is_file());
        let snapshots = super::super::snapshot::list_snapshots(temp.path()).unwrap();
        assert_eq!(snapshots.len(), 1);
        super::super::snapshot::verify_snapshot(&snapshots[0]).unwrap();
        fs::write(&profile, "[settings]\nautonomousWorkers = true\n").unwrap();
        drop(store);

        let recovery =
            super::super::snapshot::restore_snapshot(&snapshots[0], temp.path()).unwrap();
        assert!(recovery.join("internal/database/workers.sqlite").is_file());
        assert_eq!(
            fs::read_to_string(&profile).unwrap(),
            "[settings]\nautonomousWorkers = false\n"
        );
        let restored = Connection::open(&legacy_database).unwrap();
        assert_eq!(
            restored
                .query_row("SELECT value FROM legacy", [], |row| row
                    .get::<_, String>(0))
                .unwrap(),
            "before-worker-schema"
        );
        assert!(!worker_database.exists());
    }

    #[test]
    fn failed_candidate_can_be_abandoned_without_changing_active_version() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut first = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut first).unwrap();
        let active = first.version.clone();
        let _ = store.publish(first).unwrap();
        let mut next = bundle();
        next.description.push_str(" with citations");
        let candidate = store.prepare(next, Some("recent-research")).unwrap();
        store.abandon(&candidate);

        assert_eq!(
            store
                .summary("recent-research")
                .unwrap()
                .unwrap()
                .active_version,
            active
        );
    }

    #[test]
    fn database_publication_failure_removes_the_unpublished_version_tree() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut first = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut first).unwrap();
        let first = store.publish(first).unwrap();

        let mut colliding = bundle();
        colliding.worker_id = Some("distinct-worker".to_owned());
        colliding.name = "Distinct Formatting Utility".to_owned();
        colliding.description = "Formats archival documents into a stable layout".to_owned();
        colliding.tool_name = Some(first.worker.tool_name.clone());
        let mut prepared = store.prepare(colliding, None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let unpublished_directory = store
            .root
            .join("distinct-worker")
            .join("versions")
            .join(&prepared.version);

        assert!(store.publish(prepared).is_err());
        assert!(!unpublished_directory.exists());
        assert!(!store.root.join("distinct-worker").exists());
        assert!(store.read_state("distinct-worker").unwrap().is_none());
        assert_eq!(
            store
                .summary(&first.worker.worker_id)
                .unwrap()
                .unwrap()
                .active_version,
            first.version
        );
    }

    #[test]
    fn pointer_publication_failure_cleans_candidate_before_index_reconstruction() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut first = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut first).unwrap();
        let first = store.publish(first).unwrap();

        let mut updated = bundle();
        updated.description.push_str(" with a pointer failure test");
        let mut candidate = store
            .prepare(updated, Some(&first.worker.worker_id))
            .unwrap();
        store.finalize(&mut candidate).unwrap();
        let candidate_version = candidate.version.clone();
        let candidate_directory = store
            .root
            .join(&first.worker.worker_id)
            .join("versions")
            .join(&candidate_version);

        let error = store
            .publish_with_pointer_writer(candidate, |_path, _state| {
                Err("injected canonical pointer failure".to_owned())
            })
            .unwrap_err();

        assert!(error.contains("injected canonical pointer failure"));
        assert!(error.contains("restored indexes from filesystem state"));
        assert!(!candidate_directory.exists());
        let inspection = store.inspect(&first.worker.worker_id).unwrap();
        assert_eq!(inspection["worker"]["activeVersion"], first.version);
        assert_eq!(inspection["route"]["workerVersion"], first.version);
        assert_eq!(inspection["versions"].as_array().unwrap().len(), 1);
        assert!(
            inspection["versions"]
                .as_array()
                .unwrap()
                .iter()
                .all(|version| version["version"] != candidate_version)
        );
    }

    #[test]
    fn semantic_overlap_updates_existing_worker_even_when_candidate_suggests_a_new_id() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut first = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut first).unwrap();
        let first = store.publish(first).unwrap();

        let mut overlapping = bundle();
        overlapping.worker_id = Some("duplicate-recent-research".to_owned());
        let prepared = store.prepare(overlapping, None).unwrap();

        assert_eq!(prepared.worker_id, first.worker.worker_id);
        assert_eq!(
            prepared
                .prior_state
                .as_ref()
                .map(|state| state.worker_id.as_str()),
            Some(first.worker.worker_id.as_str())
        );
    }

    #[test]
    fn crash_after_index_commit_before_pointer_keeps_prior_version_canonical() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut first = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut first).unwrap();
        let first_version = first.version.clone();
        store.publish(first).unwrap();
        let prior_state = store.read_state("recent-research").unwrap().unwrap();

        let mut updated = bundle();
        updated.description.push_str(" with crash-safe publication");
        let mut second = store.prepare(updated, Some("recent-research")).unwrap();
        store.finalize(&mut second).unwrap();
        let second_version = second.version.clone();
        store.publish(second).unwrap();
        assert_ne!(first_version, second_version);

        // Model a process death after the SQLite transaction commits but
        // before the atomic filesystem-pointer rename linearizes activation.
        write_json_atomic(
            &temp
                .path()
                .join("workspace/workers/recent-research/worker.json"),
            &prior_state,
        )
        .unwrap();
        drop(store);

        let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        assert_eq!(
            reopened
                .summary("recent-research")
                .unwrap()
                .unwrap()
                .active_version,
            first_version
        );
        assert_eq!(
            reopened.inspect("recent-research").unwrap()["versions"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn traversal_in_worker_files_is_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut invalid = bundle();
        invalid
            .files
            .insert("../escape".to_owned(), "no".to_owned());
        assert!(store.prepare(invalid, None).is_err());
    }

    #[test]
    fn runner_and_check_configuration_is_validated_before_staging() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut remote_service = bundle();
        remote_service.runner = WorkerRunner::Service {
            command: vec!["worker-service".to_owned()],
            invoke_url: "https://example.com/invoke".to_owned(),
            health_url: None,
        };
        assert!(
            store
                .prepare(remote_service, None)
                .unwrap_err()
                .contains("loopback")
        );

        let mut unbounded_check = bundle();
        unbounded_check
            .health_checks
            .push(super::super::super::types::WorkerCommand {
                command: vec!["true".to_owned()],
                timeout_seconds: 0,
            });
        assert!(
            store
                .prepare(unbounded_check, None)
                .unwrap_err()
                .contains("timeoutSeconds")
        );

        let mut invalid_schedule = bundle();
        invalid_schedule.input_schema = json!({
            "type":"object",
            "additionalProperties":false,
            "required":["topic"],
            "properties":{"topic":{"type":"string"}}
        });
        invalid_schedule.triggers = vec![WorkerTrigger::Schedule {
            id: "invalid-input".to_owned(),
            every_seconds: 60,
            input: json!({}),
        }];
        assert!(
            store
                .prepare(invalid_schedule, None)
                .unwrap_err()
                .contains("does not match inputSchema")
        );
        assert!(!temp.path().join("workspace/workers/.staging").exists());
    }

    #[test]
    fn versions_are_immutable_rollback_restores_triggers_and_purge_leaves_audit() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut first = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut first).unwrap();
        let first_version = first.version.clone();
        let first_outcome = store.publish(first).unwrap();
        let first_token = first_outcome.webhooks[0].token.clone();

        let mut updated_bundle = bundle();
        updated_bundle.description.push_str(" with citations");
        updated_bundle.triggers = vec![WorkerTrigger::Schedule {
            id: "daily".to_owned(),
            every_seconds: 86_400,
            input: json!({"topic":"workers"}),
        }];
        let mut second = store
            .prepare(updated_bundle, Some("recent-research"))
            .unwrap();
        store.finalize(&mut second).unwrap();
        let second_version = second.version.clone();
        store.publish(second).unwrap();
        assert_ne!(first_version, second_version);

        let (rolled_back, credentials) = store.rollback("recent-research", &first_version).unwrap();
        assert_eq!(rolled_back.active_version, first_version);
        assert_eq!(credentials.len(), 1);
        assert_ne!(credentials[0].token, first_token);
        let inspection = store.inspect("recent-research").unwrap();
        assert_eq!(inspection["triggers"][0]["kind"], "webhook");
        assert_eq!(inspection["versions"].as_array().unwrap().len(), 2);

        let retired = store.retire("recent-research").unwrap();
        assert!(retired.retired);
        let retired_inspection = store.inspect("recent-research").unwrap();
        assert!(
            !retired_inspection["triggers"][0]["enabled"]
                .as_bool()
                .unwrap_or(true)
        );
        assert!(store.purge("recent-research").unwrap());
        assert!(store.summary("recent-research").unwrap().is_none());
        assert!(
            store
                .audit(Some("recent-research"), 20)
                .unwrap()
                .iter()
                .any(|item| item["action"] == "purged")
        );
    }

    #[test]
    fn canonical_version_tampering_and_non_hash_paths_are_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut prepared = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let outcome = store.publish(prepared).unwrap();
        let version_dir = temp
            .path()
            .join("workspace/workers/recent-research/versions")
            .join(&outcome.version);
        fs::write(
            version_dir.join("files/content.sha256"),
            "tampered worker-owned content",
        )
        .unwrap();

        let error = store.load_active("recent-research").unwrap_err();
        assert!(error.contains("failed integrity verification"), "{error}");
        let traversal = store
            .rollback("recent-research", "../../worker.json")
            .unwrap_err();
        assert!(traversal.contains("content hash"), "{traversal}");
        let worker_traversal = store.load_active("../recent-research").unwrap_err();
        assert!(worker_traversal.contains("workerId"), "{worker_traversal}");
    }

    #[test]
    fn index_reconstruction_recovers_canonical_bundle_and_interrupted_queue() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut prepared = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let outcome = store.publish(prepared).unwrap();
        let (queued, _) = store
            .begin_invocation(
                &outcome.worker.worker_id,
                &outcome.version,
                &json!({"topic":"recovery"}),
                "recovery-key",
                "trace-recovery",
                0,
                "schedule",
            )
            .unwrap();
        assert!(store.claim_running(&queued.invocation_id).unwrap());
        store
            .connection()
            .unwrap()
            .execute("DELETE FROM worker_triggers", [])
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute("DELETE FROM worker_versions", [])
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute("DELETE FROM workers", [])
            .unwrap();
        drop(store);

        let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        assert!(reopened.load_active("recent-research").is_ok());
        let rebuilt = reopened.inspect("recent-research").unwrap();
        assert_eq!(rebuilt["triggers"][0]["kind"], "webhook");
        assert_eq!(rebuilt["triggers"][0]["tokenConfigured"], false);
        assert_eq!(rebuilt["triggers"][0]["enabled"], false);
        reopened.set_enabled("recent-research", false).unwrap();
        reopened.set_enabled("recent-research", true).unwrap();
        assert_eq!(
            reopened.inspect("recent-research").unwrap()["triggers"][0]["enabled"],
            false,
            "profile enablement must not revive a rebuilt webhook without a token"
        );
        assert_eq!(
            reopened
                .invocation(&queued.invocation_id)
                .unwrap()
                .unwrap()
                .status,
            "queued"
        );
        let recovered_attempts = reopened.attempts(&queued.invocation_id).unwrap();
        assert_eq!(recovered_attempts.len(), 1);
        assert_eq!(recovered_attempts[0]["status"], "interrupted");
        assert!(reopened.claim_running(&queued.invocation_id).unwrap());
        let completed = reopened
            .complete_invocation(
                &queued.invocation_id,
                &outcome.worker.worker_id,
                Ok(&json!({"recovered":true})),
            )
            .unwrap();
        assert_eq!(completed.attempt_count, 2);
        let attempts = reopened.attempts(&queued.invocation_id).unwrap();
        assert_eq!(attempts.len(), 2);
        assert_eq!(attempts[1]["status"], "completed");
        let trace = reopened.trace("trace-recovery").unwrap().unwrap();
        assert_eq!(trace["invocationCount"], 1);
        assert_eq!(trace["maxCausalDepth"], 0);
        assert_eq!(
            reopened.inspect("recent-research").unwrap()["versions"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn notable_inbox_claims_background_results_once_and_keeps_manual_results() {
        let temp = tempfile::tempdir().unwrap();
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut prepared = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let outcome = store.publish(prepared).unwrap();
        for (key, trigger) in [("background", "schedule"), ("manual", "manual")] {
            let (run, _) = store
                .begin_invocation(
                    &outcome.worker.worker_id,
                    &outcome.version,
                    &json!({}),
                    key,
                    &format!("trace-{key}"),
                    0,
                    trigger,
                )
                .unwrap();
            assert!(store.claim_running(&run.invocation_id).unwrap());
            store
                .complete_invocation(
                    &run.invocation_id,
                    &outcome.worker.worker_id,
                    Ok(&json!({"ok":true})),
                )
                .unwrap();
        }
        store
            .record_system_inbox(
                &outcome.worker.worker_id,
                "resident_supervision",
                &json!({"status":"failed","phase":"resident_supervision"}),
            )
            .unwrap();
        let first = store
            .take_notable_unseen(Some("recent research"), 10)
            .unwrap();
        assert_eq!(first.len(), 2);
        assert!(first.iter().any(|item| item["triggerKind"] == "schedule"));
        assert!(first.iter().any(|item| {
            item["triggerKind"] == "system" && item["result"]["phase"] == "resident_supervision"
        }));
        assert!(
            store
                .take_notable_unseen(Some("recent research"), 10)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store
                .inbox(Some(&outcome.worker.worker_id), 10)
                .unwrap()
                .iter()
                .filter(|item| item["seen"] == false)
                .count(),
            1
        );
    }
}
