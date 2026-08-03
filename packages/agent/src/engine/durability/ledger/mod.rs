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
//! Duplicate handling has one contract: a matching key, payload, and function
//! revision returns the stored result; conflicts and unfinished attempts fail.
//! There is no configurable replay-policy plane.
//! The concrete scope codec accepts only profile-global and non-empty session
//! values; every unknown or partial persisted pair fails closed.

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

/// Fully scoped idempotency key.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
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
#[derive(Clone, Debug, PartialEq)]
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
