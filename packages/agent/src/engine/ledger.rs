//! Durable ledger contracts for engine causality and idempotency.
//!
//! The ledger is intentionally narrower than the live catalog. Catalog
//! definitions are still in-memory in this package; the ledger persists audit
//! records, invocation attempts, and idempotency reservations/results so
//! mutating capabilities can fail closed across process restarts.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;

use super::discovery::ActorKind;
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, WorkerId,
};
use super::invocation::{Invocation, InvocationRecord, InvocationResult};
use super::types::{
    CatalogChange, CatalogChangeClass, CatalogRevision, CatalogSubjectKind, DeliveryMode,
    FunctionRevision, IdempotencyScope, ReplayBehavior, VisibilityScope,
};

/// Stable projection of an engine error for persisted history.
#[derive(Clone, Debug, PartialEq, Serialize, serde::Deserialize)]
pub struct StoredEngineError {
    /// Stable error kind.
    pub kind: String,
    /// Human-readable error message.
    pub message: String,
    /// Structured details where the originating error exposes them.
    pub details: Value,
}

impl StoredEngineError {
    /// Project an [`EngineError`] into a stable stored representation.
    #[must_use]
    pub fn from_engine_error(error: &EngineError) -> Self {
        match error {
            EngineError::InvalidId { kind, value } => Self {
                kind: "invalid_id".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "kind": kind, "value": value }),
            },
            EngineError::InvalidFunctionId(value) => Self {
                kind: "invalid_function_id".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "value": value }),
            },
            EngineError::NotFound { kind, id } => Self {
                kind: "not_found".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "kind": kind, "id": id }),
            },
            EngineError::OwnerMismatch {
                kind,
                id,
                owner,
                attempted_owner,
            } => Self {
                kind: "owner_mismatch".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "kind": kind,
                    "id": id,
                    "owner": owner,
                    "attemptedOwner": attempted_owner,
                }),
            },
            EngineError::NamespaceDenied {
                worker_id,
                function_id,
            } => Self {
                kind: "namespace_denied".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "workerId": worker_id,
                    "functionId": function_id,
                }),
            },
            EngineError::StaleFunctionRevision {
                function_id,
                expected,
                actual,
            } => Self {
                kind: "stale_function_revision".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "expected": expected,
                    "actual": actual,
                }),
            },
            EngineError::UnsupportedDeliveryMode { mode } => Self {
                kind: "unsupported_delivery_mode".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "mode": mode }),
            },
            EngineError::DeliveryModeNotAllowed { function_id, mode } => Self {
                kind: "delivery_mode_not_allowed".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "functionId": function_id, "mode": mode }),
            },
            EngineError::IdempotencyConflict {
                function_id,
                key,
                reason,
            } => Self {
                kind: "idempotency_conflict".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "key": key,
                    "reason": reason,
                }),
            },
            EngineError::LedgerFailure { operation, message } => Self {
                kind: "ledger_failure".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "operation": operation, "message": message }),
            },
            EngineError::StoredInvocationError { kind, message } => Self {
                kind: "stored_invocation_error".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "kind": kind, "message": message }),
            },
            EngineError::InvalidSchema {
                function_id,
                direction,
                message,
            } => Self {
                kind: "invalid_schema".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "direction": direction,
                    "message": message,
                }),
            },
            EngineError::SchemaViolation {
                function_id,
                direction,
                path,
                message,
            } => Self {
                kind: "schema_violation".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "direction": direction,
                    "path": path,
                    "message": message,
                }),
            },
            EngineError::InvalidVisibilityPromotion {
                function_id,
                target,
                reason,
            } => Self {
                kind: "invalid_visibility_promotion".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "target": target,
                    "reason": reason,
                }),
            },
            EngineError::PolicyViolation(message) => Self {
                kind: "policy_violation".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "message": message }),
            },
            EngineError::NotRoutable {
                function_id,
                reason,
            } => Self {
                kind: "not_routable".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({
                    "functionId": function_id,
                    "reason": reason,
                }),
            },
            EngineError::HandlerFailed(message) => Self {
                kind: "handler_failed".to_owned(),
                message: error.to_string(),
                details: serde_json::json!({ "message": message }),
            },
        }
    }

    /// Convert a stored error into an engine result error for replay.
    #[must_use]
    pub fn to_replay_error(&self) -> EngineError {
        EngineError::StoredInvocationError {
            kind: self.kind.clone(),
            message: self.message.clone(),
        }
    }
}

/// Stable stored invocation outcome.
#[derive(Clone, Debug, PartialEq, Serialize, serde::Deserialize)]
pub struct StoredInvocationOutcome {
    /// Successful result value.
    pub value: Option<Value>,
    /// Stable error projection.
    pub error: Option<StoredEngineError>,
}

impl StoredInvocationOutcome {
    /// Project an invocation result into stable storage.
    #[must_use]
    pub fn from_result(result: &InvocationResult) -> Self {
        Self {
            value: result.value.clone(),
            error: result
                .error
                .as_ref()
                .map(StoredEngineError::from_engine_error),
        }
    }

    /// Rebuild a replay result for the current invocation.
    #[must_use]
    pub fn to_replay_result(
        &self,
        invocation: &Invocation,
        worker_id: WorkerId,
        function_revision: FunctionRevision,
        catalog_revision: CatalogRevision,
        replayed_from: InvocationId,
    ) -> InvocationResult {
        InvocationResult {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id,
            function_revision,
            catalog_revision,
            trace_id: invocation.causal_context.trace_id.clone(),
            value: self
                .value
                .clone()
                .or(Some(Value::Null))
                .filter(|_| self.error.is_none()),
            error: self.error.as_ref().map(StoredEngineError::to_replay_error),
            replayed_from: Some(replayed_from),
        }
    }
}

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
            .map_err(|err| sqlite_err("initialize_schema", err))
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
                    outcome_value_json: row.get(10)?,
                    outcome_error_json: row.get(11)?,
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

    fn append_invocation(&mut self, record: &InvocationRecord) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_invocations
                   (invocation_id, function_id, worker_id, function_revision,
                    catalog_revision, actor_id, actor_kind_json, authority_grant_id,
                    authority_scopes_json, trace_id, parent_invocation_id, trigger_id,
                    delivery_mode_json, idempotency_scope_kind, idempotency_scope_value,
                    idempotency_key, replayed_from, succeeded, result_json,
                    error_json, timestamp)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                         ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)",
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
                    to_json_string("append_invocation.delivery_mode", &record.delivery_mode)?,
                    record
                        .idempotency_scope
                        .as_ref()
                        .map(|scope| scope.kind.as_str()),
                    record
                        .idempotency_scope
                        .as_ref()
                        .map(|scope| scope.value.as_str()),
                    record.idempotency_key.as_deref(),
                    record.replayed_from.as_ref().map(InvocationId::as_str),
                    i64::from(record.succeeded),
                    optional_json_string("append_invocation.result", &record.result_value)?,
                    optional_stored_error_json("append_invocation.error", record.error.as_ref())?,
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
                        delivery_mode_json, idempotency_scope_kind, idempotency_scope_value,
                        idempotency_key, replayed_from, succeeded, result_json,
                        error_json, timestamp
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
                delivery_mode_json: row.get(12).map_err(|err| sqlite_err("inv.delivery", err))?,
                idempotency_scope_kind: row
                    .get(13)
                    .map_err(|err| sqlite_err("inv.scope_kind", err))?,
                idempotency_scope_value: row
                    .get(14)
                    .map_err(|err| sqlite_err("inv.scope_value", err))?,
                idempotency_key: row
                    .get(15)
                    .map_err(|err| sqlite_err("inv.idempotency_key", err))?,
                replayed_from: row
                    .get(16)
                    .map_err(|err| sqlite_err("inv.replayed_from", err))?,
                succeeded: row
                    .get(17)
                    .map_err(|err| sqlite_err("inv.succeeded", err))?,
                result_json: row.get(18).map_err(|err| sqlite_err("inv.result", err))?,
                error_json: row.get(19).map_err(|err| sqlite_err("inv.error", err))?,
                timestamp: row
                    .get(20)
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
                    optional_json_string("complete_idempotency.value", &outcome.value)?,
                    optional_json_string("complete_idempotency.error", &outcome.error)?,
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

const SQLITE_SCHEMA: &str = r#"
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS engine_catalog_changes (
  id              TEXT PRIMARY KEY,
  before_revision INTEGER NOT NULL,
  after_revision  INTEGER NOT NULL,
  kind_json       TEXT NOT NULL,
  subject_id      TEXT NOT NULL,
  subject_kind_json TEXT NOT NULL,
  class_json      TEXT NOT NULL,
  visibility_json TEXT NOT NULL,
  session_id      TEXT,
  workspace_id    TEXT,
  owner_worker_id TEXT,
  timestamp       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS engine_invocations (
  invocation_id            TEXT PRIMARY KEY,
  function_id              TEXT NOT NULL,
  worker_id                TEXT NOT NULL,
  function_revision        INTEGER NOT NULL,
  catalog_revision         INTEGER NOT NULL,
  actor_id                 TEXT NOT NULL,
  actor_kind_json          TEXT NOT NULL,
  authority_grant_id       TEXT NOT NULL,
  authority_scopes_json    TEXT NOT NULL,
  trace_id                 TEXT NOT NULL,
  parent_invocation_id     TEXT,
  trigger_id               TEXT,
  delivery_mode_json       TEXT NOT NULL,
  idempotency_scope_kind   TEXT,
  idempotency_scope_value  TEXT,
  idempotency_key          TEXT,
  replayed_from            TEXT,
  succeeded                INTEGER NOT NULL CHECK (succeeded IN (0, 1)),
  result_json              TEXT,
  error_json               TEXT,
  timestamp                TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS engine_idempotency_entries (
  function_id           TEXT NOT NULL,
  scope_kind            TEXT NOT NULL,
  scope_value           TEXT NOT NULL,
  idempotency_key       TEXT NOT NULL,
  payload_fingerprint   TEXT NOT NULL,
  function_revision     INTEGER NOT NULL,
  replay_behavior_json  TEXT NOT NULL,
  status_json           TEXT NOT NULL,
  first_invocation_id   TEXT NOT NULL,
  latest_invocation_id  TEXT NOT NULL,
  outcome_value_json    TEXT,
  outcome_error_json    TEXT,
  created_at            TEXT NOT NULL,
  updated_at            TEXT NOT NULL,
  PRIMARY KEY (function_id, scope_kind, scope_value, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_engine_invocations_trace
  ON engine_invocations(trace_id);

CREATE INDEX IF NOT EXISTS idx_engine_catalog_changes_after
  ON engine_catalog_changes(after_revision);
"#;

struct RawCatalogChangeRow {
    id: String,
    before_revision: u64,
    after_revision: u64,
    kind_json: String,
    subject_id: String,
    subject_kind_json: String,
    class_json: String,
    visibility_json: String,
    session_id: Option<String>,
    workspace_id: Option<String>,
    owner_worker_id: Option<String>,
    timestamp: String,
}

struct RawInvocationRow {
    invocation_id: String,
    function_id: String,
    worker_id: String,
    function_revision: u64,
    catalog_revision: u64,
    actor_id: String,
    actor_kind_json: String,
    authority_grant_id: String,
    authority_scopes_json: String,
    trace_id: String,
    parent_invocation_id: Option<String>,
    trigger_id: Option<String>,
    delivery_mode_json: String,
    idempotency_scope_kind: Option<String>,
    idempotency_scope_value: Option<String>,
    idempotency_key: Option<String>,
    replayed_from: Option<String>,
    succeeded: i64,
    result_json: Option<String>,
    error_json: Option<String>,
    timestamp: String,
}

struct RawIdempotencyRow {
    function_id: String,
    scope_kind: String,
    scope_value: String,
    idempotency_key: String,
    payload_fingerprint: String,
    function_revision: u64,
    replay_behavior_json: String,
    status_json: String,
    first_invocation_id: String,
    latest_invocation_id: String,
    outcome_value_json: Option<String>,
    outcome_error_json: Option<String>,
    created_at: String,
    updated_at: String,
}

fn raw_catalog_change(row: RawCatalogChangeRow) -> Result<CatalogChange> {
    Ok(CatalogChange {
        id: row.id,
        before: CatalogRevision(row.before_revision),
        after: CatalogRevision(row.after_revision),
        kind: from_json_string("catalog_change.kind", &row.kind_json)?,
        subject_id: row.subject_id,
        subject_kind: from_json_string::<CatalogSubjectKind>(
            "catalog_change.subject_kind",
            &row.subject_kind_json,
        )?,
        class: from_json_string::<CatalogChangeClass>("catalog_change.class", &row.class_json)?,
        visibility: from_json_string::<VisibilityScope>(
            "catalog_change.visibility",
            &row.visibility_json,
        )?,
        session_id: row.session_id,
        workspace_id: row.workspace_id,
        owner_worker: row.owner_worker_id.map(WorkerId::new).transpose()?,
        timestamp: parse_time("catalog_change.timestamp", &row.timestamp)?,
    })
}

fn raw_invocation_record(row: RawInvocationRow) -> Result<InvocationRecord> {
    let error: Option<StoredEngineError> =
        optional_from_json_string("invocation.error", &row.error_json)?;
    Ok(InvocationRecord {
        invocation_id: InvocationId::new(row.invocation_id)?,
        function_id: FunctionId::new(row.function_id)?,
        worker_id: WorkerId::new(row.worker_id)?,
        function_revision: FunctionRevision(row.function_revision),
        catalog_revision: CatalogRevision(row.catalog_revision),
        actor_id: ActorId::new(row.actor_id)?,
        actor_kind: from_json_string::<ActorKind>("invocation.actor_kind", &row.actor_kind_json)?,
        authority_grant_id: AuthorityGrantId::new(row.authority_grant_id)?,
        authority_scopes: from_json_string(
            "invocation.authority_scopes",
            &row.authority_scopes_json,
        )?,
        trace_id: TraceId::new(row.trace_id)?,
        parent_invocation_id: row
            .parent_invocation_id
            .map(InvocationId::new)
            .transpose()?,
        trigger_id: row.trigger_id.map(TriggerId::new).transpose()?,
        delivery_mode: from_json_string::<DeliveryMode>(
            "invocation.delivery_mode",
            &row.delivery_mode_json,
        )?,
        idempotency_key: row.idempotency_key,
        idempotency_scope: match (row.idempotency_scope_kind, row.idempotency_scope_value) {
            (Some(kind), Some(value)) => Some(IdempotencyScope::new(kind, value)),
            _ => None,
        },
        replayed_from: row.replayed_from.map(InvocationId::new).transpose()?,
        succeeded: row.succeeded == 1,
        result_value: optional_from_json_string("invocation.result", &row.result_json)?,
        error: error.map(|stored| stored.to_replay_error()),
        timestamp: parse_time("invocation.timestamp", &row.timestamp)?,
    })
}

fn raw_idempotency_entry(row: RawIdempotencyRow) -> Result<IdempotencyEntry> {
    Ok(IdempotencyEntry {
        key: IdempotencyKey {
            function_id: FunctionId::new(row.function_id)?,
            scope: IdempotencyScope::new(row.scope_kind, row.scope_value),
            key: row.idempotency_key,
        },
        payload_fingerprint: row.payload_fingerprint,
        function_revision: FunctionRevision(row.function_revision),
        replay_behavior: from_json_string(
            "idempotency.replay_behavior",
            &row.replay_behavior_json,
        )?,
        status: from_json_string("idempotency.status", &row.status_json)?,
        first_invocation_id: InvocationId::new(row.first_invocation_id)?,
        latest_invocation_id: InvocationId::new(row.latest_invocation_id)?,
        outcome: match (row.outcome_value_json, row.outcome_error_json) {
            (value, error) if value.is_some() || error.is_some() => Some(StoredInvocationOutcome {
                value: optional_from_json_string("idempotency.outcome_value", &value)?,
                error: optional_from_json_string("idempotency.outcome_error", &error)?,
            }),
            _ => None,
        },
        created_at: parse_time("idempotency.created_at", &row.created_at)?,
        updated_at: parse_time("idempotency.updated_at", &row.updated_at)?,
    })
}

fn optional_stored_error_json(
    operation: &'static str,
    error: Option<&EngineError>,
) -> Result<Option<String>> {
    error
        .map(StoredEngineError::from_engine_error)
        .as_ref()
        .map(|stored| to_json_string(operation, stored))
        .transpose()
}

fn optional_json_string<T: Serialize>(
    operation: &'static str,
    value: &Option<T>,
) -> Result<Option<String>> {
    value
        .as_ref()
        .map(|value| to_json_string(operation, value))
        .transpose()
}

fn optional_from_json_string<T: DeserializeOwned>(
    operation: &'static str,
    value: &Option<String>,
) -> Result<Option<T>> {
    value
        .as_ref()
        .map(|value| from_json_string(operation, value))
        .transpose()
}

fn to_json_string<T: Serialize>(operation: &'static str, value: &T) -> Result<String> {
    serde_json::to_string(value).map_err(|err| EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    })
}

fn from_json_string<T: DeserializeOwned>(operation: &'static str, value: &str) -> Result<T> {
    serde_json::from_str(value).map_err(|err| EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    })
}

fn parse_time(operation: &'static str, value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|err| EngineError::LedgerFailure {
            operation,
            message: err.to_string(),
        })
}

fn sqlite_err(operation: &'static str, err: rusqlite::Error) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    }
}

fn ledger_failure(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}
