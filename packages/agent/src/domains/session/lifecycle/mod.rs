//! Session lifecycle services and operation wrappers.
//!
//! This module owns the tool-facing lifecycle commands for sessions.
//! Durable truth is still the session event store. Commands use
//! [`SessionManager`] when a mutation must also update reconstructed-session
//! cache state; durable-only mutations may call the event-store facade directly.
//! The tool owner retires runtime projections according to mutation
//! semantics: archive clears active compaction state but preserves live event
//! sequencing for a reversible unarchive, while delete clears both.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `archive` | Archive, unarchive, and batch archive stale sessions through `ended_at`. |
//! | `create` | Normalize working directories, transactionally prepare optional branch/worktree placement, create durable sessions, project first creation, initialize sequence counters, and start optional mailbox curation. |
//! | `delete` | Delete a session through the session manager and clear session-scoped runtime projections. |
//! | `fork` | Fork from an explicit event or session head and initialize the child runtime sequence counter. |
//! | `operations` | JSON parameter parsing for lifecycle tool entry points. |
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
//! - Archive clears the active compaction handler but preserves the live
//!   sequence counter so unarchive cannot reuse a provider-visible sequence.
//!   Permanent delete clears both projections; shutdown clears all remaining
//!   process-local projections.
//! - Ordinary and agent-created visible tasks share the same post-commit
//!   `session.created` projection and asynchronous mailbox-curation entry
//!   point; idempotent task replay does not duplicate that projection.
//! - Source-control placement is admitted only during session creation. Git
//!   preparation is serialized, bounded, and compensated if the durable
//!   session transaction fails; the persisted working directory is always the
//!   checkout the agent actually receives.

use crate::shared::protocol::events::{BaseEvent, TronEvent};

use crate::domains::session::Deps;

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
    pub(crate) source_control:
        Option<crate::domains::filesystem::source_control::SessionSourceControlRequest>,
}

pub(crate) struct SessionLifecycleService;

mod archive;
mod create;
mod delete;
mod fork;
mod operations;

pub(crate) use create::project_created_session;
pub(crate) use operations::{
    session_archive_older_than_value, session_archive_value, session_create_value,
    session_delete_value, session_fork_value, session_unarchive_value,
};

#[cfg(test)]
mod tests;
