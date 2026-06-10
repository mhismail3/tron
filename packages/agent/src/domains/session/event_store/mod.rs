//! # events
//!
//! Event sourcing engine with `SQLite` backend for the Tron agent.
//!
//! This is the largest subsystem, responsible for:
//!
//! - **Event types**: branch-local [`EventType`] enum for retained loop events
//! - **Session events**: [`SessionEvent`] flat struct with typed payload access
//! - **Event store**: High-level API for session creation, event append, ancestor walk, fork
//! - **`SQLite` backend**: `rusqlite` facade with repository pattern
//! - **Event factory**: Scoped event creation with auto-generated IDs and timestamps
//! - **Replay identities**: Explicit IDs/timestamps for deterministic replay/import tests
//! - **Provider request audits**: `model.provider_request` events persisted before model streams
//! - **Event chain builder**: Automates `parent_id` threading across sequential events
//! - **Message reconstructor**: Two-pass algorithm for rebuilding provider context from event
//!   history, preserving separate client display text and model-facing capability result text
//! - **Migrations**: Version-tracked SQL schema evolution
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `envelope` | Broadcast envelope creation and event type cataloging. |
//! | `factory` | Event ID creation and chain append helpers. |
//! | `identity` | Explicit event/session/workspace identities for replay-critical constructors. |
//! | `reconstruction` | Provider-context reconstruction from persisted event history. |
//! | `sqlite` | Connection, migration, repository, lock, and row-type boundary. |
//! | `store` | High-level transactional `EventStore` facade. |
//! | `trace` | Agent trace record types and query options. |
//! | `types` | Event payload, state, token, and generated event definitions. |
//!
//! ## Entry Points
//!
//! `EventStore` is the high-level transactional facade for session/event truth.
//! `EventFactory` and `EventChainBuilder` build append-ready events, while
//! `reconstruct_from_events` rebuilds provider-facing message context from the
//! durable event stream.
//!
//! ## Dependency Direction
//!
//! Depends on: shared protocol/foundation types, SQLite storage helpers, and
//! event payload DTOs. Depended on by session lifecycle/query/reconstruction,
//! the agent loop, logs/blob/message domains, and transport read surfaces.
//!
//! ## Invariants
//!
//! - This root uses normal folder-backed modules only and must not hide
//!   ownership behind `#[path]` aliases.
//! - SQLite row shape and migrations stay under the SQLite owner.
//! - Reconstruction is deterministic over persisted event order.
//! - `model.provider_request` is written before any provider stream opens.
//! - Replay/import paths use explicit identities instead of ambient time or
//!   UUID generation when durable IDs/timestamps must be stable.
//! - The event log is append-only for normal lifecycle operations. Archiving
//!   sets session-row `ended_at`, message deletion appends `message.deleted`,
//!   and physical event cleanup happens only when the owning session is
//!   explicitly deleted.
//!
//! ## Test Ownership
//!
//! Store tests live under `store/event_store/tests`; SQLite repository tests
//! live under their repository owners; reconstruction tests live under
//! `reconstruction/tests`.

#![deny(unsafe_code)]

pub mod envelope;
pub mod errors;
pub mod factory;
pub mod identity;
pub mod reconstruction;
pub mod redaction;
pub mod sqlite;
pub mod store;
pub mod trace;
pub mod types;

pub use envelope::{
    ALL_BROADCAST_EVENT_TYPES, BroadcastEventType, EventEnvelope, create_event_envelope,
};
pub use errors::{EventStoreError, Result};
pub use factory::{EventChainBuilder, EventFactory};
pub use identity::{
    EventIdentity, SessionCreationIdentity, SessionForkIdentity, SessionIdentity, WorkspaceIdentity,
};
pub use reconstruction::{
    COMPACTION_ACK_TEXT, COMPACTION_SUMMARY_PREFIX, ReconstructionResult, reconstruct_from_events,
};
pub use sqlite::repositories::event::ListEventsOptions;
pub use sqlite::repositories::session::{ActivitySummaryLine, ListSessionsOptions, MessagePreview};
pub use sqlite::row_types::{BlobRow, EventRow, SessionRow, WorkspaceRow};
pub use sqlite::{
    ConnectionConfig, ConnectionPool, DatabaseLock, LockError, MigrationResult, PooledConnection,
    acquire_database_lock, check_integrity, new_file, new_in_memory, run_migrations,
};
pub use store::{
    AppendOptions, ClientLogEntry, ClientLogIngestResult, CreateSessionResult, EventStore,
    ForkOptions, ForkResult, LogEntry, LogSessionFilter, RecentLogQuery,
    event_rows_to_session_events,
};
pub use trace::{AGENT_TRACE_VERSION, AgentTraceListOptions, AgentTraceRecord};
pub use types::{
    ALL_EVENT_TYPES, Branch, EventType, Message, MessageWithEventId, SessionEvent,
    SessionEventPayload, SessionState, SessionSummary, TokenTotals, TokenUsage, Workspace,
};
