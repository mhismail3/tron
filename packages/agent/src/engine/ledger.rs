//! Durable ledger contracts for engine causality and idempotency.
//!
//! The ledger is intentionally narrower than the live catalog. It persists
//! audit records, invocation attempts, idempotency reservations/results, catalog
//! changes, and the current durable external-worker catalog definitions needed
//! to fail closed across process restarts without pretending disconnected
//! sockets still have executable handlers.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

use super::errors::Result;
use super::ids::{FunctionId, InvocationId, TriggerId, WorkerId};
use super::invocation::InvocationRecord;
use super::types::{
    CatalogChange, CatalogRevision, FunctionDefinition, FunctionRevision, IdempotencyScope,
    ReplayBehavior, WorkerDefinition,
};

mod outcome;
mod sqlite_codec;

pub use outcome::{StoredEngineError, StoredInvocationOutcome};

use sqlite_codec::{
    RawCatalogChangeRow, RawIdempotencyRow, RawInvocationRow, SQLITE_SCHEMA, ensure_column,
    ledger_failure, optional_stored_error_json, optional_stored_json_string, raw_catalog_change,
    raw_idempotency_entry, raw_invocation_record, resolve_optional_stored_json_string, sqlite_err,
    to_json_string,
};

/// Fully scoped idempotency key.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, serde::Deserialize)]
pub struct IdempotencyKey {
    /// Function the key belongs to.
    pub function_id: FunctionId,
    /// Concrete scope.
    pub scope: IdempotencyScope,
    /// Caller/engine/trigger supplied key.
    pub key: String,
}

/// Idempotency reservation state.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, serde::Deserialize)]
pub enum IdempotencyStatus {
    /// A handler has been allowed to run and has not completed its reservation.
    InProgress,
    /// A final outcome is persisted.
    Completed,
    /// The outcome is intentionally unknown and duplicates must not re-run.
    Unknown,
}

/// Persisted idempotency reservation/result.
#[derive(Clone, Debug, PartialEq, Serialize, serde::Deserialize)]
pub struct IdempotencyEntry {
    /// Fully scoped key.
    pub key: IdempotencyKey,
    /// Canonical payload fingerprint.
    pub payload_fingerprint: String,
    /// Function revision used for the original attempt.
    pub function_revision: FunctionRevision,
    /// Duplicate replay behavior.
    pub replay_behavior: ReplayBehavior,
    /// Current reservation status.
    pub status: IdempotencyStatus,
    /// First invocation that reserved the key.
    pub first_invocation_id: InvocationId,
    /// Latest invocation that touched the key.
    pub latest_invocation_id: InvocationId,
    /// Final outcome when completed.
    pub outcome: Option<StoredInvocationOutcome>,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
    /// Last update timestamp.
    pub updated_at: DateTime<Utc>,
}

/// Input for reserving an idempotency key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IdempotencyReservation {
    /// Fully scoped key.
    pub key: IdempotencyKey,
    /// Canonical payload fingerprint.
    pub payload_fingerprint: String,
    /// Function revision.
    pub function_revision: FunctionRevision,
    /// Duplicate replay behavior.
    pub replay_behavior: ReplayBehavior,
    /// Invocation attempting the reservation.
    pub invocation_id: InvocationId,
}

/// Result of an idempotency reservation attempt.
#[derive(Clone, Debug, PartialEq)]
pub enum IdempotencyReservationOutcome {
    /// This invocation owns a new reservation and may execute the handler.
    Reserved(IdempotencyEntry),
    /// A prior reservation/result exists and must be evaluated by policy.
    Existing(IdempotencyEntry),
}

/// Storage boundary for engine audit, invocation, and idempotency records.
pub trait EngineLedgerStore: Send {
    /// Append a catalog change record.
    fn append_catalog_change(&mut self, change: &CatalogChange) -> Result<()>;

    /// List all catalog changes in revision order.
    fn list_catalog_changes(&self) -> Result<Vec<CatalogChange>>;

    /// List catalog changes after a revision, up to `limit`.
    fn catalog_changes_after(
        &self,
        revision: CatalogRevision,
        limit: usize,
    ) -> Result<Vec<CatalogChange>>;

    /// Store the current definition for a durable external worker.
    fn upsert_durable_worker_definition(&mut self, _definition: &WorkerDefinition) -> Result<()> {
        Ok(())
    }

    /// Remove a durable external worker definition and its owned functions.
    fn remove_durable_worker_definition(&mut self, _worker_id: &WorkerId) -> Result<()> {
        Ok(())
    }

    /// List durable external worker definitions persisted for restart.
    fn list_durable_worker_definitions(&self) -> Result<Vec<WorkerDefinition>> {
        Ok(Vec::new())
    }

    /// Store the current definition for a durable external function.
    fn upsert_durable_function_definition(
        &mut self,
        _definition: &FunctionDefinition,
    ) -> Result<()> {
        Ok(())
    }

    /// Remove a durable external function definition.
    fn remove_durable_function_definition(&mut self, _function_id: &FunctionId) -> Result<()> {
        Ok(())
    }

    /// List durable external function definitions persisted for restart.
    fn list_durable_function_definitions(&self) -> Result<Vec<FunctionDefinition>> {
        Ok(Vec::new())
    }

    /// Append an invocation record.
    fn append_invocation(&mut self, record: &InvocationRecord) -> Result<()>;

    /// List invocation records in write order.
    fn list_invocations(&self) -> Result<Vec<InvocationRecord>>;

    /// Reserve an idempotency key before handler execution.
    fn reserve_idempotency(
        &mut self,
        reservation: IdempotencyReservation,
    ) -> Result<IdempotencyReservationOutcome>;

    /// Complete an idempotency reservation after handler execution.
    fn complete_idempotency(
        &mut self,
        key: &IdempotencyKey,
        invocation_id: &InvocationId,
        outcome: StoredInvocationOutcome,
    ) -> Result<()>;
}

/// In-memory ledger store used by `LiveCatalog::new`.
#[derive(Default)]
pub struct InMemoryEngineLedgerStore {
    catalog_changes: Vec<CatalogChange>,
    invocations: Vec<InvocationRecord>,
    idempotency: BTreeMap<IdempotencyKey, IdempotencyEntry>,
}

impl InMemoryEngineLedgerStore {
    /// Create an empty in-memory store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

impl EngineLedgerStore for InMemoryEngineLedgerStore {
    fn append_catalog_change(&mut self, change: &CatalogChange) -> Result<()> {
        self.catalog_changes.push(change.clone());
        Ok(())
    }

    fn list_catalog_changes(&self) -> Result<Vec<CatalogChange>> {
        Ok(self.catalog_changes.clone())
    }

    fn catalog_changes_after(
        &self,
        revision: CatalogRevision,
        limit: usize,
    ) -> Result<Vec<CatalogChange>> {
        Ok(self
            .catalog_changes
            .iter()
            .filter(|change| change.after > revision)
            .take(limit)
            .cloned()
            .collect())
    }

    fn append_invocation(&mut self, record: &InvocationRecord) -> Result<()> {
        self.invocations.push(record.clone());
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<InvocationRecord>> {
        Ok(self.invocations.clone())
    }

    fn reserve_idempotency(
        &mut self,
        reservation: IdempotencyReservation,
    ) -> Result<IdempotencyReservationOutcome> {
        if let Some(existing) = self.idempotency.get_mut(&reservation.key) {
            existing.latest_invocation_id = reservation.invocation_id;
            existing.updated_at = Utc::now();
            return Ok(IdempotencyReservationOutcome::Existing(existing.clone()));
        }

        let now = Utc::now();
        let entry = IdempotencyEntry {
            key: reservation.key,
            payload_fingerprint: reservation.payload_fingerprint,
            function_revision: reservation.function_revision,
            replay_behavior: reservation.replay_behavior,
            status: IdempotencyStatus::InProgress,
            first_invocation_id: reservation.invocation_id.clone(),
            latest_invocation_id: reservation.invocation_id,
            outcome: None,
            created_at: now,
            updated_at: now,
        };
        let _ = self.idempotency.insert(entry.key.clone(), entry.clone());
        Ok(IdempotencyReservationOutcome::Reserved(entry))
    }

    fn complete_idempotency(
        &mut self,
        key: &IdempotencyKey,
        invocation_id: &InvocationId,
        outcome: StoredInvocationOutcome,
    ) -> Result<()> {
        let entry = self
            .idempotency
            .get_mut(key)
            .ok_or_else(|| ledger_failure("complete_idempotency", "reservation not found"))?;
        entry.status = IdempotencyStatus::Completed;
        entry.latest_invocation_id = invocation_id.clone();
        entry.outcome = Some(outcome);
        entry.updated_at = Utc::now();
        Ok(())
    }
}

/// SQLite-backed engine ledger store for isolated WP2 tests and future host wiring.
pub struct SqliteEngineLedgerStore {
    conn: Connection,
}

impl SqliteEngineLedgerStore {
    /// Open an in-memory SQLite ledger.
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().map_err(|err| sqlite_err("open", err))?;
        Self::from_connection(conn)
    }

    /// Open a file-backed SQLite ledger.
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path).map_err(|err| sqlite_err("open", err))?;
        Self::from_connection(conn)
    }

    /// Wrap a connection and initialize the engine-ledger schema.
    pub fn from_connection(conn: Connection) -> Result<Self> {
        let store = Self { conn };
        store.initialize_schema()?;
        Ok(store)
    }

    /// Borrow the underlying connection for focused tests.
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    fn initialize_schema(&self) -> Result<()> {
        self.conn
            .execute_batch(SQLITE_SCHEMA)
            .map_err(|err| sqlite_err("initialize_schema", err))?;
        ensure_column(
            &self.conn,
            "engine_invocations",
            "resource_lease_ids_json",
            "TEXT NOT NULL DEFAULT '[]'",
        )?;
        ensure_column(
            &self.conn,
            "engine_invocations",
            "compensation_status",
            "TEXT",
        )?;
        ensure_column(
            &self.conn,
            "engine_invocations",
            "produced_resource_refs_json",
            "TEXT NOT NULL DEFAULT '[]'",
        )?;
        ensure_column(&self.conn, "engine_invocations", "session_id", "TEXT")?;
        ensure_column(&self.conn, "engine_invocations", "workspace_id", "TEXT")?;
        Ok(())
    }

    fn get_idempotency_entry(&self, key: &IdempotencyKey) -> Result<Option<IdempotencyEntry>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT function_id, scope_kind, scope_value, idempotency_key,
                        payload_fingerprint, function_revision, replay_behavior_json,
                        status_json, first_invocation_id, latest_invocation_id,
                        outcome_value_json, outcome_error_json, created_at, updated_at
                 FROM engine_idempotency_entries
                 WHERE function_id = ?1
                   AND scope_kind = ?2
                   AND scope_value = ?3
                   AND idempotency_key = ?4",
            )
            .map_err(|err| sqlite_err("get_idempotency_entry.prepare", err))?;

        stmt.query_row(
            params![
                key.function_id.as_str(),
                key.scope.kind,
                key.scope.value,
                key.key
            ],
            |row| {
                Ok(RawIdempotencyRow {
                    function_id: row.get(0)?,
                    scope_kind: row.get(1)?,
                    scope_value: row.get(2)?,
                    idempotency_key: row.get(3)?,
                    payload_fingerprint: row.get(4)?,
                    function_revision: row.get(5)?,
                    replay_behavior_json: row.get(6)?,
                    status_json: row.get(7)?,
                    first_invocation_id: row.get(8)?,
                    latest_invocation_id: row.get(9)?,
                    outcome_value_json: resolve_optional_stored_json_string(
                        &self.conn,
                        row.get(10)?,
                    )
                    .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
                    outcome_error_json: resolve_optional_stored_json_string(
                        &self.conn,
                        row.get(11)?,
                    )
                    .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
                    created_at: row.get(12)?,
                    updated_at: row.get(13)?,
                })
            },
        )
        .optional()
        .map_err(|err| sqlite_err("get_idempotency_entry.query", err))?
        .map(raw_idempotency_entry)
        .transpose()
    }
}

impl EngineLedgerStore for SqliteEngineLedgerStore {
    fn append_catalog_change(&mut self, change: &CatalogChange) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_catalog_changes
                   (id, before_revision, after_revision, kind_json, subject_id,
                    subject_kind_json, class_json, visibility_json, session_id,
                    workspace_id, owner_worker_id, timestamp)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    change.id,
                    change.before.0,
                    change.after.0,
                    to_json_string("append_catalog_change.kind", &change.kind)?,
                    change.subject_id,
                    to_json_string("append_catalog_change.subject_kind", &change.subject_kind)?,
                    to_json_string("append_catalog_change.class", &change.class)?,
                    to_json_string("append_catalog_change.visibility", &change.visibility)?,
                    change.session_id.as_deref(),
                    change.workspace_id.as_deref(),
                    change.owner_worker.as_ref().map(WorkerId::as_str),
                    change.timestamp.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("append_catalog_change", err))?;
        Ok(())
    }

    fn list_catalog_changes(&self) -> Result<Vec<CatalogChange>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, before_revision, after_revision, kind_json, subject_id,
                        subject_kind_json, class_json, visibility_json, session_id,
                        workspace_id, owner_worker_id, timestamp
                 FROM engine_catalog_changes
                 ORDER BY after_revision ASC",
            )
            .map_err(|err| sqlite_err("list_catalog_changes.prepare", err))?;
        let mut rows = stmt
            .query([])
            .map_err(|err| sqlite_err("list_catalog_changes.query", err))?;
        let mut changes = Vec::new();
        while let Some(row) = rows
            .next()
            .map_err(|err| sqlite_err("list_catalog_changes.next", err))?
        {
            changes.push(raw_catalog_change(RawCatalogChangeRow {
                id: row.get(0).map_err(|err| sqlite_err("catalog.id", err))?,
                before_revision: row
                    .get(1)
                    .map_err(|err| sqlite_err("catalog.before", err))?,
                after_revision: row.get(2).map_err(|err| sqlite_err("catalog.after", err))?,
                kind_json: row.get(3).map_err(|err| sqlite_err("catalog.kind", err))?,
                subject_id: row
                    .get(4)
                    .map_err(|err| sqlite_err("catalog.subject", err))?,
                subject_kind_json: row
                    .get(5)
                    .map_err(|err| sqlite_err("catalog.subject_kind", err))?,
                class_json: row.get(6).map_err(|err| sqlite_err("catalog.class", err))?,
                visibility_json: row
                    .get(7)
                    .map_err(|err| sqlite_err("catalog.visibility", err))?,
                session_id: row
                    .get(8)
                    .map_err(|err| sqlite_err("catalog.session", err))?,
                workspace_id: row
                    .get(9)
                    .map_err(|err| sqlite_err("catalog.workspace", err))?,
                owner_worker_id: row
                    .get(10)
                    .map_err(|err| sqlite_err("catalog.owner", err))?,
                timestamp: row
                    .get(11)
                    .map_err(|err| sqlite_err("catalog.timestamp", err))?,
            })?);
        }
        Ok(changes)
    }

    fn catalog_changes_after(
        &self,
        revision: CatalogRevision,
        limit: usize,
    ) -> Result<Vec<CatalogChange>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, before_revision, after_revision, kind_json, subject_id,
                        subject_kind_json, class_json, visibility_json, session_id,
                        workspace_id, owner_worker_id, timestamp
                 FROM engine_catalog_changes
                 WHERE after_revision > ?1
                 ORDER BY after_revision ASC
                 LIMIT ?2",
            )
            .map_err(|err| sqlite_err("catalog_changes_after.prepare", err))?;
        let mut rows = stmt
            .query(params![revision.0, limit as i64])
            .map_err(|err| sqlite_err("catalog_changes_after.query", err))?;
        let mut changes = Vec::new();
        while let Some(row) = rows
            .next()
            .map_err(|err| sqlite_err("catalog_changes_after.next", err))?
        {
            changes.push(raw_catalog_change(RawCatalogChangeRow {
                id: row.get(0).map_err(|err| sqlite_err("catalog.id", err))?,
                before_revision: row
                    .get(1)
                    .map_err(|err| sqlite_err("catalog.before", err))?,
                after_revision: row.get(2).map_err(|err| sqlite_err("catalog.after", err))?,
                kind_json: row.get(3).map_err(|err| sqlite_err("catalog.kind", err))?,
                subject_id: row
                    .get(4)
                    .map_err(|err| sqlite_err("catalog.subject", err))?,
                subject_kind_json: row
                    .get(5)
                    .map_err(|err| sqlite_err("catalog.subject_kind", err))?,
                class_json: row.get(6).map_err(|err| sqlite_err("catalog.class", err))?,
                visibility_json: row
                    .get(7)
                    .map_err(|err| sqlite_err("catalog.visibility", err))?,
                session_id: row
                    .get(8)
                    .map_err(|err| sqlite_err("catalog.session", err))?,
                workspace_id: row
                    .get(9)
                    .map_err(|err| sqlite_err("catalog.workspace", err))?,
                owner_worker_id: row
                    .get(10)
                    .map_err(|err| sqlite_err("catalog.owner", err))?,
                timestamp: row
                    .get(11)
                    .map_err(|err| sqlite_err("catalog.timestamp", err))?,
            })?);
        }
        Ok(changes)
    }

    fn upsert_durable_worker_definition(&mut self, definition: &WorkerDefinition) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        self.conn
            .execute(
                "INSERT INTO engine_catalog_workers
                   (worker_id, definition_json, updated_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(worker_id) DO UPDATE SET
                   definition_json = excluded.definition_json,
                   updated_at = excluded.updated_at",
                params![
                    definition.id.as_str(),
                    to_json_string("upsert_durable_worker_definition", definition)?,
                    now,
                ],
            )
            .map_err(|err| sqlite_err("upsert_durable_worker_definition", err))?;
        Ok(())
    }

    fn remove_durable_worker_definition(&mut self, worker_id: &WorkerId) -> Result<()> {
        self.conn
            .execute(
                "DELETE FROM engine_catalog_workers WHERE worker_id = ?1",
                params![worker_id.as_str()],
            )
            .map_err(|err| sqlite_err("remove_durable_worker_definition", err))?;
        self.conn
            .execute(
                "DELETE FROM engine_catalog_functions WHERE owner_worker_id = ?1",
                params![worker_id.as_str()],
            )
            .map_err(|err| sqlite_err("remove_durable_worker_functions", err))?;
        Ok(())
    }

    fn list_durable_worker_definitions(&self) -> Result<Vec<WorkerDefinition>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT definition_json
                 FROM engine_catalog_workers
                 ORDER BY worker_id ASC",
            )
            .map_err(|err| sqlite_err("list_durable_worker_definitions.prepare", err))?;
        let mut rows = stmt
            .query([])
            .map_err(|err| sqlite_err("list_durable_worker_definitions.query", err))?;
        let mut definitions = Vec::new();
        while let Some(row) = rows
            .next()
            .map_err(|err| sqlite_err("list_durable_worker_definitions.next", err))?
        {
            let definition_json: String = row
                .get(0)
                .map_err(|err| sqlite_err("durable_worker.definition", err))?;
            definitions.push(sqlite_codec::from_json_string(
                "list_durable_worker_definitions.definition",
                &definition_json,
            )?);
        }
        Ok(definitions)
    }

    fn upsert_durable_function_definition(
        &mut self,
        definition: &FunctionDefinition,
    ) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        self.conn
            .execute(
                "INSERT INTO engine_catalog_functions
                   (function_id, owner_worker_id, definition_json, updated_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(function_id) DO UPDATE SET
                   owner_worker_id = excluded.owner_worker_id,
                   definition_json = excluded.definition_json,
                   updated_at = excluded.updated_at",
                params![
                    definition.id.as_str(),
                    definition.owner_worker.as_str(),
                    to_json_string("upsert_durable_function_definition", definition)?,
                    now,
                ],
            )
            .map_err(|err| sqlite_err("upsert_durable_function_definition", err))?;
        Ok(())
    }

    fn remove_durable_function_definition(&mut self, function_id: &FunctionId) -> Result<()> {
        self.conn
            .execute(
                "DELETE FROM engine_catalog_functions WHERE function_id = ?1",
                params![function_id.as_str()],
            )
            .map_err(|err| sqlite_err("remove_durable_function_definition", err))?;
        Ok(())
    }

    fn list_durable_function_definitions(&self) -> Result<Vec<FunctionDefinition>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT definition_json
                 FROM engine_catalog_functions
                 ORDER BY function_id ASC",
            )
            .map_err(|err| sqlite_err("list_durable_function_definitions.prepare", err))?;
        let mut rows = stmt
            .query([])
            .map_err(|err| sqlite_err("list_durable_function_definitions.query", err))?;
        let mut definitions = Vec::new();
        while let Some(row) = rows
            .next()
            .map_err(|err| sqlite_err("list_durable_function_definitions.next", err))?
        {
            let definition_json: String = row
                .get(0)
                .map_err(|err| sqlite_err("durable_function.definition", err))?;
            definitions.push(sqlite_codec::from_json_string(
                "list_durable_function_definitions.definition",
                &definition_json,
            )?);
        }
        Ok(definitions)
    }

    fn append_invocation(&mut self, record: &InvocationRecord) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_invocations
                   (invocation_id, function_id, worker_id, function_revision,
                    catalog_revision, actor_id, actor_kind_json, authority_grant_id,
                    authority_scopes_json, trace_id, parent_invocation_id, trigger_id,
                    session_id, workspace_id, delivery_mode_json, idempotency_scope_kind,
                    idempotency_scope_value, resource_lease_ids_json, compensation_status,
                    produced_resource_refs_json, idempotency_key, replayed_from, succeeded,
                    result_json, error_json, timestamp)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                         ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23,
                         ?24, ?25, ?26)",
                params![
                    record.invocation_id.as_str(),
                    record.function_id.as_str(),
                    record.worker_id.as_str(),
                    record.function_revision.0,
                    record.catalog_revision.0,
                    record.actor_id.as_str(),
                    to_json_string("append_invocation.actor_kind", &record.actor_kind)?,
                    record.authority_grant_id.as_str(),
                    to_json_string(
                        "append_invocation.authority_scopes",
                        &record.authority_scopes
                    )?,
                    record.trace_id.as_str(),
                    record
                        .parent_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    record.trigger_id.as_ref().map(TriggerId::as_str),
                    record.session_id.as_deref(),
                    record.workspace_id.as_deref(),
                    to_json_string("append_invocation.delivery_mode", &record.delivery_mode)?,
                    record
                        .idempotency_scope
                        .as_ref()
                        .map(|scope| scope.kind.as_str()),
                    record
                        .idempotency_scope
                        .as_ref()
                        .map(|scope| scope.value.as_str()),
                    to_json_string(
                        "append_invocation.resource_lease_ids",
                        &record.resource_lease_ids
                    )?,
                    record.compensation_status.as_deref(),
                    to_json_string(
                        "append_invocation.produced_resource_refs",
                        &record.produced_resource_refs
                    )?,
                    record.idempotency_key.as_deref(),
                    record.replayed_from.as_ref().map(InvocationId::as_str),
                    i64::from(record.succeeded),
                    optional_stored_json_string(
                        &self.conn,
                        "engine_invocation",
                        record.invocation_id.as_str(),
                        "result",
                        &record.result_value,
                        Some(record.trace_id.to_string()),
                        record.session_id.clone(),
                        record.workspace_id.clone(),
                    )?,
                    optional_stored_error_json(
                        &self.conn,
                        "engine_invocation",
                        record.invocation_id.as_str(),
                        record.error.as_ref(),
                        Some(record.trace_id.to_string()),
                        record.session_id.clone(),
                        record.workspace_id.clone(),
                    )?,
                    record.timestamp.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("append_invocation", err))?;
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<InvocationRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT invocation_id, function_id, worker_id, function_revision,
                        catalog_revision, actor_id, actor_kind_json, authority_grant_id,
                        authority_scopes_json, trace_id, parent_invocation_id, trigger_id,
                        session_id, workspace_id, delivery_mode_json, idempotency_scope_kind,
                        idempotency_scope_value, resource_lease_ids_json, compensation_status,
                        produced_resource_refs_json, idempotency_key, replayed_from, succeeded,
                        result_json, error_json, timestamp
                 FROM engine_invocations
                 ORDER BY rowid ASC",
            )
            .map_err(|err| sqlite_err("list_invocations.prepare", err))?;
        let mut rows = stmt
            .query([])
            .map_err(|err| sqlite_err("list_invocations.query", err))?;
        let mut records = Vec::new();
        while let Some(row) = rows
            .next()
            .map_err(|err| sqlite_err("list_invocations.next", err))?
        {
            records.push(raw_invocation_record(RawInvocationRow {
                invocation_id: row.get(0).map_err(|err| sqlite_err("inv.id", err))?,
                function_id: row.get(1).map_err(|err| sqlite_err("inv.function", err))?,
                worker_id: row.get(2).map_err(|err| sqlite_err("inv.worker", err))?,
                function_revision: row
                    .get(3)
                    .map_err(|err| sqlite_err("inv.function_revision", err))?,
                catalog_revision: row
                    .get(4)
                    .map_err(|err| sqlite_err("inv.catalog_revision", err))?,
                actor_id: row.get(5).map_err(|err| sqlite_err("inv.actor", err))?,
                actor_kind_json: row
                    .get(6)
                    .map_err(|err| sqlite_err("inv.actor_kind", err))?,
                authority_grant_id: row.get(7).map_err(|err| sqlite_err("inv.grant", err))?,
                authority_scopes_json: row.get(8).map_err(|err| sqlite_err("inv.scopes", err))?,
                trace_id: row.get(9).map_err(|err| sqlite_err("inv.trace", err))?,
                parent_invocation_id: row.get(10).map_err(|err| sqlite_err("inv.parent", err))?,
                trigger_id: row.get(11).map_err(|err| sqlite_err("inv.trigger", err))?,
                session_id: row.get(12).map_err(|err| sqlite_err("inv.session", err))?,
                workspace_id: row
                    .get(13)
                    .map_err(|err| sqlite_err("inv.workspace", err))?,
                delivery_mode_json: row.get(14).map_err(|err| sqlite_err("inv.delivery", err))?,
                idempotency_scope_kind: row
                    .get(15)
                    .map_err(|err| sqlite_err("inv.scope_kind", err))?,
                idempotency_scope_value: row
                    .get(16)
                    .map_err(|err| sqlite_err("inv.scope_value", err))?,
                resource_lease_ids_json: row
                    .get(17)
                    .map_err(|err| sqlite_err("inv.resource_leases", err))?,
                compensation_status: row
                    .get(18)
                    .map_err(|err| sqlite_err("inv.compensation_status", err))?,
                produced_resource_refs_json: row
                    .get(19)
                    .map_err(|err| sqlite_err("inv.produced_resource_refs", err))?,
                idempotency_key: row
                    .get(20)
                    .map_err(|err| sqlite_err("inv.idempotency_key", err))?,
                replayed_from: row
                    .get(21)
                    .map_err(|err| sqlite_err("inv.replayed_from", err))?,
                succeeded: row
                    .get(22)
                    .map_err(|err| sqlite_err("inv.succeeded", err))?,
                result_json: resolve_optional_stored_json_string(
                    &self.conn,
                    row.get(23).map_err(|err| sqlite_err("inv.result", err))?,
                )?,
                error_json: resolve_optional_stored_json_string(
                    &self.conn,
                    row.get(24).map_err(|err| sqlite_err("inv.error", err))?,
                )?,
                timestamp: row
                    .get(25)
                    .map_err(|err| sqlite_err("inv.timestamp", err))?,
            })?);
        }
        Ok(records)
    }

    fn reserve_idempotency(
        &mut self,
        reservation: IdempotencyReservation,
    ) -> Result<IdempotencyReservationOutcome> {
        if let Some(mut existing) = self.get_idempotency_entry(&reservation.key)? {
            let updated_at = Utc::now();
            self.conn
                .execute(
                    "UPDATE engine_idempotency_entries
                     SET latest_invocation_id = ?5, updated_at = ?6
                     WHERE function_id = ?1
                       AND scope_kind = ?2
                       AND scope_value = ?3
                       AND idempotency_key = ?4",
                    params![
                        reservation.key.function_id.as_str(),
                        reservation.key.scope.kind,
                        reservation.key.scope.value,
                        reservation.key.key,
                        reservation.invocation_id.as_str(),
                        updated_at.to_rfc3339(),
                    ],
                )
                .map_err(|err| sqlite_err("reserve_idempotency.update_existing", err))?;
            existing.latest_invocation_id = reservation.invocation_id;
            existing.updated_at = updated_at;
            return Ok(IdempotencyReservationOutcome::Existing(existing));
        }

        let now = Utc::now();
        self.conn
            .execute(
                "INSERT INTO engine_idempotency_entries
                   (function_id, scope_kind, scope_value, idempotency_key,
                    payload_fingerprint, function_revision, replay_behavior_json,
                    status_json, first_invocation_id, latest_invocation_id,
                    created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    reservation.key.function_id.as_str(),
                    reservation.key.scope.kind,
                    reservation.key.scope.value,
                    reservation.key.key,
                    reservation.payload_fingerprint,
                    reservation.function_revision.0,
                    to_json_string(
                        "reserve_idempotency.replay_behavior",
                        &reservation.replay_behavior
                    )?,
                    to_json_string("reserve_idempotency.status", &IdempotencyStatus::InProgress)?,
                    reservation.invocation_id.as_str(),
                    reservation.invocation_id.as_str(),
                    now.to_rfc3339(),
                    now.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("reserve_idempotency.insert", err))?;

        let entry = self
            .get_idempotency_entry(&reservation.key)?
            .ok_or_else(|| ledger_failure("reserve_idempotency", "reservation insert vanished"))?;
        Ok(IdempotencyReservationOutcome::Reserved(entry))
    }

    fn complete_idempotency(
        &mut self,
        key: &IdempotencyKey,
        invocation_id: &InvocationId,
        outcome: StoredInvocationOutcome,
    ) -> Result<()> {
        let updated = self
            .conn
            .execute(
                "UPDATE engine_idempotency_entries
                 SET status_json = ?5,
                     latest_invocation_id = ?6,
                     outcome_value_json = ?7,
                     outcome_error_json = ?8,
                     updated_at = ?9
                 WHERE function_id = ?1
                   AND scope_kind = ?2
                   AND scope_value = ?3
                   AND idempotency_key = ?4",
                params![
                    key.function_id.as_str(),
                    key.scope.kind,
                    key.scope.value,
                    key.key,
                    to_json_string("complete_idempotency.status", &IdempotencyStatus::Completed)?,
                    invocation_id.as_str(),
                    optional_stored_json_string(
                        &self.conn,
                        "engine_idempotency",
                        &format!(
                            "{}:{}:{}:{}",
                            key.function_id.as_str(),
                            key.scope.kind,
                            key.scope.value,
                            key.key
                        ),
                        "outcome_value",
                        &outcome.value,
                        None,
                        None,
                        None,
                    )?,
                    optional_stored_json_string(
                        &self.conn,
                        "engine_idempotency",
                        &format!(
                            "{}:{}:{}:{}",
                            key.function_id.as_str(),
                            key.scope.kind,
                            key.scope.value,
                            key.key
                        ),
                        "outcome_error",
                        &outcome.error,
                        None,
                        None,
                        None,
                    )?,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("complete_idempotency", err))?;
        if updated == 0 {
            return Err(ledger_failure(
                "complete_idempotency",
                "reservation not found",
            ));
        }
        Ok(())
    }
}
