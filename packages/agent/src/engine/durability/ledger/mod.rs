//! Durable ledger contracts for engine causality and idempotency.
//!
//! The ledger is intentionally narrower than the live catalog. It persists
//! audit records, invocation attempts, idempotency reservations/results, catalog
//! changes, and the current durable external-worker catalog definitions needed
//! to fail closed across process restarts without pretending disconnected
//! sockets still have executable handlers. Session replay reads invocation rows
//! and idempotency entries through this ledger boundary so replay does not query
//! SQLite internals from domain code.
//!
//! The SQLite implementation keeps schema and query operations in
//! `sqlite_store`, with row decoding helpers split into `sqlite_store::rows` so
//! persistence behavior remains owned by this module without oversized files.

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::{FunctionId, InvocationId, WorkerId};
use crate::engine::kernel::types::{
    CatalogChange, CatalogRevision, FunctionDefinition, FunctionRevision, IdempotencyScope,
    ReplayBehavior, WorkerDefinition,
};

mod memory;
mod outcome;
mod sqlite_codec;
mod sqlite_store;

pub use memory::InMemoryEngineLedgerStore;
pub use outcome::{StoredEngineError, StoredInvocationOutcome};
pub use sqlite_store::SqliteEngineLedgerStore;

use sqlite_codec::ledger_failure;

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
    fn upsert_durable_worker_definition(&mut self, definition: &WorkerDefinition) -> Result<()>;

    /// Remove a durable external worker definition and its owned functions.
    fn remove_durable_worker_definition(&mut self, worker_id: &WorkerId) -> Result<()>;

    /// List durable external worker definitions persisted for restart.
    fn list_durable_worker_definitions(&self) -> Result<Vec<WorkerDefinition>>;

    /// Store the current definition for a durable external function.
    fn upsert_durable_function_definition(&mut self, definition: &FunctionDefinition)
    -> Result<()>;

    /// Remove a durable external function definition.
    fn remove_durable_function_definition(&mut self, function_id: &FunctionId) -> Result<()>;

    /// List durable external function definitions persisted for restart.
    fn list_durable_function_definitions(&self) -> Result<Vec<FunctionDefinition>>;

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
