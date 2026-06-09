//! High-level transactional `EventStore` API.
//!
//! Composes all repository operations into atomic, session-centric methods.
//! Every write method runs inside a single `SQLite` transaction — callers
//! never observe partial state.

use serde_json::Value;

use std::collections::HashMap;
use std::sync::{Mutex, Weak};

use crate::domains::session::event_store::sqlite::connection::ConnectionPool;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::{EventRow, SessionRow};

mod auxiliary;
mod event_log;
mod locking;
mod logs;
mod session_lifecycle;
mod state;
mod trace_log;

pub use self::state::event_rows_to_session_events;
pub use logs::{ClientLogEntry, ClientLogIngestResult, LogEntry, LogSessionFilter, RecentLogQuery};

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
/// All write methods are transactional — they run inside `SAVEPOINT`/`RELEASE`
/// blocks so callers never see partial state.
///
/// INVARIANT: session writes are serialized per-session via in-process mutex
/// locks (`with_session_write_lock`). Global mutations use a separate global
/// lock. `SQLite` `UNIQUE(session_id, sequence)` enforces ordering at the DB level.
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
