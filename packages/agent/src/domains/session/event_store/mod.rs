//! # events
//!
//! Event sourcing engine with `SQLite` backend for the Tron agent.
//!
//! This is the largest subsystem, responsible for:
//!
//! - **Event types**: branch-local [`EventType`] enum for retained loop events
//! - **Session events**: [`SessionEvent`] flat struct with opaque JSON payloads
//! - **Event store**: High-level API for session creation, event append, ancestor walk, fork
//! - **`SQLite` backend**: `rusqlite` facade with repository pattern
//! - **Replay identities**: Explicit IDs/timestamps for deterministic replay/import tests
//! - **Provider request audits**: bounded `model.provider_request` structure and
//!   digest evidence persisted before model streams without duplicating bulk media
//! - **Logs**: bounded operational log queries
//! - **Message reconstructor**: Two-pass algorithm for rebuilding provider context from event
//!   history, preserving separate client display text and model-facing tool result text
//! - **Schema**: Transactional installation of the one current SQL shape
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `envelope` | Broadcast envelope creation and event type cataloging. |
//! | `identity` | Explicit event/session/workspace identities for replay-critical constructors. |
//! | `reconstruction` | Provider-context reconstruction from persisted event history. |
//! | `sqlite` | Connection, schema, repository, lock, and row-type boundary. |
//! | `store` | High-level transactional `EventStore` facade. |
//! | `trace` | Agent trace record types and query options. |
//! | `types` | Event payload, state, token, and generated event definitions. |
//!
//! ## Entry Points
//!
//! `EventStore` is the high-level transactional facade for session/event truth.
//! Its create, fork, and append methods own current identity generation,
//! automatic parent/sequence allocation, and durable writes; explicit-identity
//! variants preserve deterministic replay. `reconstruct_from_events` rebuilds
//! provider-facing message context from the durable event stream.
//!
//! ## Dependency Direction
//!
//! Depends on: shared protocol/foundation types, SQLite storage helpers, and
//! event payload DTOs. Shared protocol owns event wire DTO shape; SQLite
//! projections only construct those neutral values. Depended on by session
//! lifecycle/query/reconstruction, the agent loop, logs/blob/message domains,
//! and transport read surfaces.
//!
//! ## Invariants
//!
//! - This root uses normal folder-backed modules only and must not hide
//!   ownership behind `#[path]` aliases.
//! - SQLite row shape and schema installation stay under the SQLite owner.
//! - Public event DTOs stay shared-protocol-owned; crate-private session-list
//!   projections are not reexported through the persistence owner.
//! - Reconstruction is deterministic over persisted event order.
//! - Persisted event rows are decoded through the owning SQLite connection so
//!   inline and blob-backed payloads share one resolution path.
//! - `model.provider_request` is written before any provider stream opens.
//! - Provider audit events project bulk strings to byte-count and digest
//!   evidence; provider request bytes remain owned by the model boundary.
//! - Log query filters are applied in the storage owner so diagnostics callers
//!   cannot silently broaden session/workspace/trace scope.
//! - Durable event payloads and client logs call the shared foundation
//!   redaction policy directly. JSON redaction retains field context so opaque
//!   values under exact credential keys are masked before storage; the session
//!   domain does not shadow that owner.
//! - Session roots, forks, and generic appends are created only through
//!   `EventStore`; no parallel factory or manual chain-head owner exists.
//! - Replay/import paths use explicit identities instead of ambient time or
//!   UUID generation when durable IDs/timestamps must be stable.
//! - The event log is append-only for normal lifecycle operations. Archiving
//!   sets session-row `ended_at`, message deletion appends `message.deleted`,
//!   and physical event cleanup happens only when the owning session is
//!   explicitly deleted.
//! - Asynchronous worker-owned session naming uses a storage-level
//!   compare-and-set that updates only a null or blank title, so a delayed
//!   policy result cannot overwrite an explicit concurrent user/model title.
//! - Session organization remains canonical session-row state: ordinary tags
//!   are labels, exactly one reserved tag encodes the group, and archive state
//!   remains `ended_at`. Closed worker intents acquire sorted session locks and
//!   commit the entire target batch or none of it while preserving system tags.
//!   Omitted label/group patches preserve canonical values; explicit null is
//!   reserved for clearing the group.
//!
//! ## Test Ownership
//!
//! Store tests live under `store/event_store/tests`; SQLite repository tests
//! live under their repository owners; reconstruction tests live under
//! `reconstruction/tests`.

#![deny(unsafe_code)]

pub mod envelope;
pub mod errors;
pub mod identity;
pub mod reconstruction;
pub mod sqlite;
pub mod store;
pub mod types;

pub use envelope::{
    ALL_BROADCAST_EVENT_TYPES, BroadcastEventType, EventEnvelope, create_event_envelope,
};
pub use errors::{EventStoreError, Result};
pub use identity::{
    EventIdentity, SessionCreationIdentity, SessionForkIdentity, SessionIdentity, WorkspaceIdentity,
};
pub use reconstruction::{
    COMPACTION_ACK_TEXT, COMPACTION_SUMMARY_PREFIX, ReconstructionResult, reconstruct_from_events,
};
pub use sqlite::repositories::event::ListEventsOptions;
pub use sqlite::repositories::session::ListSessionsOptions;
pub use sqlite::row_types::{BlobRow, EventRow, SessionRow, WorkspaceRow};
pub use sqlite::{
    ConnectionConfig, ConnectionPool, DatabaseLock, LockError, PooledConnection,
    acquire_database_lock, check_integrity, ensure_schema, new_file, new_in_memory,
};
pub(crate) use store::AppendBatchItem;
pub use store::{
    AppendOptions, ClientLogEntry, ClientLogIngestResult, CreateSessionResult, EventStore,
    ForkOptions, ForkResult, LogEntry, LogSessionFilter, RecentLogQuery,
    SESSION_ORGANIZATION_GROUP_TAG_PREFIX, SessionOrganizationArchiveAction,
    SessionOrganizationMutation, SessionOrganizationSnapshot, session_organization_from_tags,
};
pub use types::{
    EventType, Message, MessageWithEventId, SessionEvent, SessionState, TokenTotals, TokenUsage,
};
