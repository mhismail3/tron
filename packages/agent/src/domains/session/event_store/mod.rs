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
//! - **Provider request audits**: bounded `tron.model_provider_request.v4`
//!   manifests plus redacted request evidence persisted before model streams
//!   without duplicating bulk media or message bodies
//! - **Agent coordination**: semantic message provenance/materialization,
//!   generalized assignment/worker/reply waits, plus legacy delivery/mailbox
//!   compatibility and crash recovery
//! - **Foreground user input**: pending/answered state derived from indexed
//!   tool lifecycle and structured user-message events
//! - **Native terminals**: bounded PTY launch metadata and 24-hour exited
//!   history indexes; terminal byte journals remain private filesystem state
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
//! - The append-only event is the sole durable request-context ledger. V4
//!   records ordered instructions, automatic-context provenance, message
//!   source sidecars, Agent Deliveries, environment, and exact tool selection;
//!   v2/v3 remain readable and no parallel context cache is installed.
//! - Semantic agent-message metadata and generalized coordination waits remain
//!   EventStore-owned state. Outgoing content is durable before scheduling;
//!   the typed transcript event is appended only at a provider-safe boundary,
//!   atomically with materialization. Wait registration atomically binds an
//!   already-satisfied fan-in to its current tool result; only a later
//!   satisfaction may own the single aggregate continuation. Legacy
//!   `agent_deliveries` and worker-only waits remain readable during their
//!   compatibility window. Per-target delivery ownership is exact to the
//!   registering wait's recipient session and, when known, stable agent; a
//!   manager or other authorized observer waiting on the same handle cannot
//!   suppress the delegator's independent automatic result.
//!   Opaque assignment, worker, and reply handles are normalized by the Engine
//!   into stable agent/execution dependencies plus immutable causal topology.
//!   Additive EventStore side tables retain that graph across restart, and the
//!   same immediate transaction rejects self, descendant-to-ancestor,
//!   reciprocal-reply, and mixed wait cycles before admitting pending work.
//!   Accepted assignment messages pair their passive delivery with a durable
//!   one-way supervisor hold. All provider leases exclude held rows; only the
//!   FIFO assignment supervisor releases the exact row after its Running state
//!   and attempt baseline are durable. Import replay cannot re-hold a released
//!   delivery.
//!   Assignment cancellation uses an exact uncapped wait predicate, and nested
//!   transcript promotion records an idempotent receipt so importer replay
//!   preserves the same visible session across a cross-store crash boundary.
//!   Agent-subtree cancellation retains delayed and leased deliveries while
//!   atomically making every wake for each exact transcript passive.
//!   A delivery lease is preparation, not observation; only durable assistant
//!   completion observes it, while setup failure or restart clears the lease
//!   for at-least-once redelivery.
//! - A paired-client result handoff creates its visible session and exact
//!   passive result grant in one transaction. The result invocation remains
//!   provenance, never a fabricated root of an agent-owned causal worker tree.
//! - A successful `request_user_input` completion is the only pending marker;
//!   its structured `message.user` answer resolves it. One partial unique
//!   index enforces one answer per session/invocation, with no pause table or
//!   process-local waiter to recover after reconnect or restart.
//! - Sender expiry is durably reconciled before delivery, mailbox, wake, and
//!   result-grant reads. Expired rows remain audit evidence but confer no
//!   result authority.
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
//! - At most one `running` terminal row exists per session. A restart marks
//!   running rows interrupted before serving clients; output bytes are never
//!   stored in SQLite and expired metadata/journals are purged together.
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
#[allow(unused_imports)]
pub(crate) use store::{
    AgentCorrespondentRecord, AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliveryRecord,
    AgentDeliverySourceKind, AgentDeliveryTarget, AgentDeliveryWakePolicy, AgentMailboxScope,
    AgentMessageDisposition, AgentMessageMetadataRecord, AgentWaitMode, AppendBatchItem,
    CoordinationDependencyEdge, CoordinationDependencyEdgeKind, CoordinationTargetKind,
    CoordinationTerminalEvidence, CoordinationWaitAdmission, CoordinationWaitDependency,
    CoordinationWaitMemberRecord, CoordinationWaitMode, CoordinationWaitRecord,
    CoordinationWaitResolution, CoordinationWaitTarget, MAX_DELIVERIES_PER_TURN,
    MaterializedAgentMessage, NewAgentDelivery, NewAgentMessageMetadata, NewAgentTaskDelivery,
    NewAgentWait, NewCoordinationWait, NewWorkerResultTaskDelivery, TerminalRecord,
    UserInputRequestState, WorkerTerminalEvidence,
};
pub use store::{
    AppendOptions, ClientLogEntry, ClientLogIngestResult, CreateSessionResult, EventStore,
    ForkOptions, ForkResult, LogEntry, LogSessionFilter, RecentLogQuery,
    SESSION_ORGANIZATION_GROUP_TAG_PREFIX, SessionOrganizationArchiveAction,
    SessionOrganizationMutation, SessionOrganizationSnapshot, session_organization_from_tags,
};
pub use types::{
    EventType, Message, MessageWithEventId, SessionEvent, SessionState, TokenTotals, TokenUsage,
};
