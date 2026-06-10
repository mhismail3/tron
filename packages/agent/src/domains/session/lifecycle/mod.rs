//! Session lifecycle services and operation wrappers.
//!
//! This module owns the capability-facing lifecycle commands for sessions.
//! Durable truth is still the session event store: lifecycle commands delegate
//! to [`SessionManager`], which updates the event-store facade and then clears
//! reconstructable runtime projections such as sequence counters, compaction
//! handlers, and active-session cache entries.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `archive` | Archive, unarchive, and batch archive stale sessions through `ended_at`. |
//! | `create` | Normalize working directories, create durable sessions, and initialize runtime sequence counters. |
//! | `delete` | Delete a session through the session manager and clear session-scoped runtime projections. |
//! | `fork` | Fork from an explicit event or session head and initialize the child runtime sequence counter. |
//! | `operations` | JSON parameter parsing for lifecycle capability entry points. |
//!
//! ## Invariants
//!
//! - Session lifecycle commands mutate durable truth only through
//!   [`SessionManager`] and the session event-store facade.
//! - Archive/unarchive is reversible session-row state (`ended_at`); it does
//!   not delete event history.
//! - Deleting a session is the only physical event-row cleanup path and is
//!   scoped to that session's own events. Fork-inherited ancestor history stays
//!   owned by the source session.
//! - Message deletion is represented by a `message.deleted` event, never by
//!   physically deleting one event from the log.
//! - Runtime sequence counters and compaction handlers are projections and are
//!   removed after archive/delete, then rebuilt from event-store truth on
//!   resume/reconstruction.

use crate::shared::protocol::events::{BaseEvent, TronEvent};

use crate::domains::session::Deps;

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
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
