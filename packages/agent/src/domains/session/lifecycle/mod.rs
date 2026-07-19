//! Session lifecycle services and operation wrappers.
//!
//! This module owns the capability-facing lifecycle commands for sessions.
//! Durable truth is still the session event store. Commands use
//! [`SessionManager`] when a mutation must also update reconstructed-session
//! cache state; durable-only mutations may call the event-store facade directly.
//! The capability owner retires runtime projections according to mutation
//! semantics: archive clears active compaction state but preserves live event
//! sequencing for a reversible unarchive, while delete clears both.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `archive` | Archive, unarchive, and batch archive stale sessions through `ended_at`. |
//! | `create` | Normalize working directories, create durable sessions, and initialize runtime sequence counters. |
//! | `delete` | Delete a session through the session manager and clear session-scoped runtime projections. |
//! | `fork` | Resolve safe completed-turn fork points, validate source scope, and initialize the child runtime sequence counter. |
//! | `operations` | JSON parameter parsing for lifecycle capability entry points. |
//!
//! ## Invariants
//!
//! - Session lifecycle commands mutate durable truth through the session
//!   event-store facade; [`SessionManager`] coordinates cache-affecting changes.
//! - Archive/unarchive is reversible session-row state (`ended_at`); it does
//!   not delete event history.
//! - Deleting a session is the only physical event-row cleanup path and is
//!   scoped to that session's own events. Fork-inherited ancestor history stays
//!   owned by the source session.
//! - Message deletion is represented by a `message.deleted` event, never by
//!   physically deleting one event from the log.
//! - Public forks resolve to persisted `stream.turn_end` boundaries in the
//!   requested source session. Assistant selectors normalize to their matching
//!   terminal boundary; arbitrary internal events are rejected.
//! - Invoking session/workspace scope must match the source. Durable engine
//!   idempotency plus deterministic identities and a root-event-bound immutable
//!   request fingerprint makes ambiguous retries converge on one child session
//!   even after the source advances. Replay lookup precedes mutable source-head
//!   validation.
//! - Archive clears the active compaction handler but preserves the live
//!   sequence counter so unarchive cannot reuse a provider-visible sequence.
//!   Permanent delete clears both projections; shutdown clears all remaining
//!   process-local projections.

use crate::shared::protocol::events::{BaseEvent, TronEvent};

use crate::domains::session::Deps;

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
}

pub(crate) struct ForkSessionRequest {
    pub(crate) session_id: String,
    pub(crate) from_event_id: Option<String>,
    pub(crate) expected_head_event_id: Option<String>,
    pub(crate) title: Option<String>,
    pub(crate) causal_session_id: Option<String>,
    pub(crate) causal_workspace_id: Option<String>,
    pub(crate) idempotency_key: Option<String>,
}

pub(crate) struct SessionLifecycleService;

mod archive;
mod create;
mod delete;
mod fork;
mod operations;

pub(crate) use operations::{
    session_archive_older_than_value, session_archive_value, session_create_value,
    session_delete_value, session_fork_value, session_unarchive_value,
};

#[cfg(test)]
mod tests;
