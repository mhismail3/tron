//! # tron-events
//!
//! Event sourcing engine with `SQLite` backend for the Tron agent.
//!
//! This is the largest subsystem, responsible for:
//!
//! - **Event types**: 58-variant [`EventType`] enum matching the TypeScript wire format exactly
//! - **Session events**: [`SessionEvent`] flat struct with typed payload access
//! - **Event store**: High-level API for session creation, event append, ancestor walk, fork
//! - **`SQLite` backend**: `rusqlite` facade with repository pattern
//! - **Event factory**: Scoped event creation with auto-generated IDs and timestamps
//! - **Event chain builder**: Automates `parent_id` threading across sequential events
//! - **Message reconstructor**: Two-pass algorithm for rebuilding messages from event history
//! - **Migrations**: Version-tracked SQL schema evolution

#![deny(unsafe_code)]

pub mod envelope;
pub mod errors;
pub mod factory;
pub mod memory;
pub mod reconstruct;
pub mod sqlite;
pub mod store;
pub mod types;

pub use envelope::{
    ALL_BROADCAST_EVENT_TYPES, BroadcastEventType, EventEnvelope, create_event_envelope,
};
pub use errors::{EventStoreError, Result};
pub use factory::{EventChainBuilder, EventFactory};
pub use reconstruct::{
    COMPACTION_ACK_TEXT, COMPACTION_SUMMARY_PREFIX, ReconstructedTokenUsage, ReconstructionResult,
    reconstruct_from_events,
};
pub use sqlite::repositories::device_token::RegisterTokenResult;
pub use sqlite::repositories::session::MessagePreview;
pub use sqlite::{
    ConnectionConfig, ConnectionPool, PooledConnection, new_file, new_in_memory, run_migrations,
};
pub use store::{AppendOptions, CreateSessionResult, EventStore, ForkOptions, ForkResult};
pub use types::{
    ALL_EVENT_TYPES, Branch, EventType, Message, MessageWithEventId, SearchResult, SessionEvent,
    SessionEventPayload, SessionState, SessionSummary, TokenUsage, Workspace,
};
