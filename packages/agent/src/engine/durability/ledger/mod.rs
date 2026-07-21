//! Durable ledger contracts for engine causality and idempotency.
//!
//! The ledger is intentionally narrower than the live catalog. It persists
//! invocation attempts, idempotency reservations/results, and one monotonic
//! catalog revision. Callable definitions are rebuilt from fixed bootstrap contracts and
//! canonical worker bundles rather than duplicated in this ledger. Session
//! replay reads invocation rows and idempotency entries through this boundary so
//! replay does not query SQLite internals from domain code.
//!
//! The SQLite implementation keeps schema and query operations in
//! `sqlite_store`, with row decoding helpers split into `sqlite_store::rows` so
//! persistence behavior remains owned by this module without oversized files.
//! Live invocation results are returned unchanged to the current caller. Audit
//! rows and idempotency outcomes use a field-aware redacted copy, so one-time
//! credentials cannot enter SQLite, payload blobs, replay exports, or later
//! idempotent replays. Both ledger implementations apply that policy at their
//! storage boundary even when a caller manually constructs a record.
//! The worker-first retirement migration removes historical authority, lease,
//! compensation, produced-resource, and generic-trigger records in one
//! transaction while preserving causal and outcome evidence.
//! Duplicate handling has one contract: a matching key, payload, and function
//! revision returns the stored result; conflicts and unfinished attempts fail.
//! There is no configurable replay-policy plane.

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::{FunctionId, InvocationId};
use crate::engine::kernel::types::{CatalogRevision, FunctionRevision, IdempotencyScope};

mod memory;
mod outcome;
mod sqlite_codec;
mod sqlite_store;

pub use memory::InMemoryEngineLedgerStore;
pub use outcome::{StoredEngineError, StoredInvocationOutcome};
pub use sqlite_store::SqliteEngineLedgerStore;

use sqlite_codec::ledger_failure;

/// Rebuild the invocation ledger without columns owned by retired execution
/// planes. The caller owns the surrounding worker-first retirement transaction.
pub(crate) fn retire_legacy_invocation_columns(
    transaction: &rusqlite::Transaction<'_>,
) -> std::result::Result<bool, String> {
    let retired_columns = [
        "authority_grant_id",
        "authority_scopes_json",
        "resource_lease_ids_json",
        "compensation_status",
        "produced_resource_refs_json",
        "delivery_mode_json",
        "trigger_id",
    ];
    let mut statement = transaction
        .prepare("PRAGMA table_info(engine_invocations)")
        .map_err(|error| format!("inspect invocation columns: {error}"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("query invocation columns: {error}"))?
        .collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()
        .map_err(|error| format!("decode invocation columns: {error}"))?;
    drop(statement);
    if columns.is_empty()
        || retired_columns
            .iter()
            .all(|column| !columns.contains(*column))
    {
        return Ok(false);
    }
    let retained = [
        "invocation_id",
        "function_id",
        "worker_id",
        "function_revision",
        "catalog_revision",
        "actor_id",
        "actor_kind_json",
        "trace_id",
        "parent_invocation_id",
        "session_id",
        "workspace_id",
        "idempotency_scope_kind",
        "idempotency_scope_value",
        "idempotency_key",
        "replayed_from",
        "succeeded",
        "result_json",
        "error_json",
        "timestamp",
    ];
    for column in retained {
        if !columns.contains(column) {
            return Err(format!(
                "cannot retire invocation observations: retained column {column} is missing"
            ));
        }
    }
    let column_list = retained.join(",");
    transaction
        .execute_batch(
            "DROP TABLE IF EXISTS engine_invocations__worker_first_retirement;
             ALTER TABLE engine_invocations RENAME TO engine_invocations__worker_first_retirement;
             DROP INDEX IF EXISTS idx_engine_invocations_trace;",
        )
        .map_err(|error| format!("stage invocation ledger rebuild: {error}"))?;
    transaction
        .execute_batch(sqlite_codec::INVOCATION_TABLE_SCHEMA)
        .map_err(|error| format!("create worker-first invocation ledger: {error}"))?;
    transaction
        .execute(
            &format!(
                "INSERT INTO engine_invocations ({column_list}) \
                 SELECT {column_list} FROM engine_invocations__worker_first_retirement"
            ),
            [],
        )
        .map_err(|error| format!("copy retained invocation rows: {error}"))?;
    transaction
        .execute_batch(
            "DROP TABLE engine_invocations__worker_first_retirement;
             CREATE INDEX idx_engine_invocations_trace ON engine_invocations(trace_id);",
        )
        .map_err(|error| format!("finish invocation ledger rebuild: {error}"))?;
    Ok(true)
}

/// Remove the retired configurable duplicate-policy column while preserving
/// every idempotency key, fingerprint, status, and outcome row.
pub(crate) fn retire_legacy_idempotency_replay_column(
    connection: &rusqlite::Connection,
) -> std::result::Result<bool, String> {
    let table_exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='engine_idempotency_entries')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("inspect idempotency table: {error}"))?;
    if !table_exists {
        return Ok(false);
    }
    let mut statement = connection
        .prepare("PRAGMA table_info(engine_idempotency_entries)")
        .map_err(|error| format!("inspect idempotency columns: {error}"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("query idempotency columns: {error}"))?
        .collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()
        .map_err(|error| format!("read idempotency columns: {error}"))?;
    drop(statement);
    if !columns.contains("replay_behavior_json") {
        return Ok(false);
    }
    connection
        .execute_batch("ALTER TABLE engine_idempotency_entries DROP COLUMN replay_behavior_json;")
        .map_err(|error| format!("retire idempotency replay column: {error}"))?;
    Ok(true)
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
    /// Read the durable monotonic catalog revision.
    fn catalog_revision(&self) -> Result<CatalogRevision>;

    /// Atomically advance the durable catalog revision.
    fn advance_catalog_revision(
        &mut self,
        expected: CatalogRevision,
        next: CatalogRevision,
    ) -> Result<()>;

    /// Append an invocation record.
    fn append_invocation(&mut self, record: &InvocationRecord) -> Result<()>;

    /// List invocation records in write order.
    fn list_invocations(&self) -> Result<Vec<InvocationRecord>>;

    /// List invocation records for one session in durable write order.
    fn list_invocations_by_session(&self, session_id: &str) -> Result<Vec<InvocationRecord>>;

    /// List idempotency entries that explain invocations for one session.
    fn list_idempotency_by_session(&self, session_id: &str) -> Result<Vec<IdempotencyEntry>>;

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
