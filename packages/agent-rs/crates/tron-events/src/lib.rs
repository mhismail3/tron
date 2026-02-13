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
pub mod reconstruct;
pub mod sqlite;
pub mod store;
pub mod types;

pub use envelope::{
    create_event_envelope, BroadcastEventType, EventEnvelope, ALL_BROADCAST_EVENT_TYPES,
};
pub use errors::{EventStoreError, Result};
pub use factory::{EventChainBuilder, EventFactory};
pub use reconstruct::{
    reconstruct_from_events, ReconstructedTokenUsage, ReconstructionResult,
    COMPACTION_ACK_TEXT, COMPACTION_SUMMARY_PREFIX,
};
pub use sqlite::{
    new_file, new_in_memory, run_migrations, ConnectionConfig, ConnectionPool, PooledConnection,
};
pub use store::EventStore;
pub use types::{
    EventType, SessionEvent, SessionEventPayload, TokenUsage, ALL_EVENT_TYPES,
    Branch, Message, MessageWithEventId, SearchResult, SessionState,
    SessionSummary, Workspace,
};
