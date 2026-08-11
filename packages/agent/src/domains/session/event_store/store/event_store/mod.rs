//! High-level transactional `EventStore` API.
//!
//! Composes all repository operations into atomic, session-centric methods.
//! Every write method runs inside a single `SQLite` transaction — callers
//! never observe partial state. Session-local lifecycle batches commit every
//! row with one parent chain or roll back the entire batch. The event log is
//! append-only except for the
//! session-scoped cleanup performed by [`EventStore::delete_session`];
//! individual message removal is represented by a durable `message.deleted`
//! event and applied during reconstruction.
//! Model and reasoning selection use the same session write lock and transaction
//! as their timeline events, so metadata, reconstruction, and audit history
//! cannot diverge.
//! Coordination message history uses stable keyset pages, while unread-message
//! and correspondent projections expose count-backed offset pages. Team and
//! native clients can therefore remain bounded without making old durable
//! communication evidence unreachable.

use serde_json::Value;

use std::collections::HashMap;
use std::sync::{Mutex, Weak};

use crate::domains::session::event_store::sqlite::connection::ConnectionPool;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::{EventRow, SessionRow};

mod auxiliary;
mod coordination;
mod deliveries;
mod event_log;
mod locking;
mod logs;
mod organization;
mod session_lifecycle;
mod state;
mod terminal;
mod user_input;

#[allow(unused_imports)]
pub(crate) use coordination::{
    AgentCorrespondentPage, AgentCorrespondentRecord, AgentMessageDisposition,
    AgentMessageMetadataPage, AgentMessageMetadataRecord, CoordinationDependencyEdge,
    CoordinationDependencyEdgeKind, CoordinationTargetKind, CoordinationTerminalEvidence,
    CoordinationWaitAdmission, CoordinationWaitDependency, CoordinationWaitMemberRecord,
    CoordinationWaitMode, CoordinationWaitRecord, CoordinationWaitResolution,
    CoordinationWaitTarget, MaterializedAgentMessage, NewAgentMessageMetadata, NewCoordinationWait,
};
pub(crate) use deliveries::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliveryRecord, AgentDeliverySourceKind,
    AgentDeliveryTarget, AgentDeliveryWakePolicy, AgentMailboxScope, AgentWaitMode,
    MAX_DELIVERIES_PER_TURN, NewAgentDelivery, NewAgentTaskDelivery, NewAgentWait,
    NewWorkerResultTaskDelivery, WorkerTerminalEvidence,
};
pub use logs::{ClientLogEntry, ClientLogIngestResult, LogEntry, LogSessionFilter, RecentLogQuery};
pub use organization::{
    SESSION_ORGANIZATION_GROUP_TAG_PREFIX, SessionOrganizationArchiveAction,
    SessionOrganizationMutation, SessionOrganizationSnapshot, session_organization_from_tags,
};
pub(crate) use terminal::TerminalRecord;
pub(crate) use user_input::UserInputRequestState;

/// Result of creating a new session.
#[derive(Debug)]
pub struct CreateSessionResult {
    /// The created session.
    pub session: SessionRow,
    /// The root `session.start` event.
    pub root_event: EventRow,
}

/// Result of forking a session.
#[derive(Debug)]
pub struct ForkResult {
    /// The newly created (forked) session.
    pub session: SessionRow,
    /// The root `session.fork` event.
    pub fork_event: EventRow,
}

/// Options for appending an event.
pub struct AppendOptions<'a> {
    /// Session to append to.
    pub session_id: &'a str,
    /// Event type.
    pub event_type: EventType,
    /// Event payload (JSON).
    pub payload: Value,
    /// Explicit parent. If `None`, chains from session head.
    pub parent_id: Option<&'a str>,
    /// Pre-assigned sequence number. When `None` (the usual case), the
    /// sequence is allocated inside the append transaction via
    /// `SELECT MAX(sequence) + 1` — safe under the session write lock
    /// (serializes within-process) and the C3 `AgentDbLock` flock
    /// (serializes across-process). See the `INVARIANT:` block in
    /// `append_event_in_tx_with_identity` for the full correctness argument.
    pub sequence: Option<i64>,
}

/// One event in an atomic, session-local append batch.
pub(crate) struct AppendBatchItem {
    pub(crate) event_type: EventType,
    pub(crate) payload: Value,
    pub(crate) sequence: Option<i64>,
}

/// Options for forking a session.
#[derive(Default)]
pub struct ForkOptions<'a> {
    /// Optional model override for the fork.
    pub model: Option<&'a str>,
    /// Optional title for the forked session.
    pub title: Option<&'a str>,
}

/// High-level `EventStore` wrapping a connection pool and all repositories.
///
/// All write methods are transactional, so callers never see partial state.
///
/// INVARIANT: session writes are serialized per-session via in-process mutex
/// locks (`with_session_write_lock`). Global mutations use a separate global
/// lock. `SQLite` `UNIQUE(session_id, sequence)` enforces ordering at the DB
/// level. Physical event deletion is only valid inside `delete_session`, after
/// the owning session row is selected by ID.
pub struct EventStore {
    pool: ConnectionPool,
    global_write_lock: Mutex<()>,
    session_write_locks: Mutex<HashMap<String, Weak<Mutex<()>>>>,
}

impl EventStore {
    /// Create a new `EventStore` with the given connection pool.
    pub fn new(pool: ConnectionPool) -> Self {
        Self {
            pool,
            global_write_lock: Mutex::new(()),
            session_write_locks: Mutex::new(HashMap::new()),
        }
    }
}

#[cfg(test)]
mod tests;
