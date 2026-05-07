//! # engine
//!
//! In-process live capability fabric for the Tron agent.
//!
//! This module is the foundation for the engine redesign documented in
//! `packages/agent/docs/engine-redesign/`. Production JSON-RPC is increasingly
//! just a trigger transport into canonical domain functions, and agents now get
//! first-party tools over this same live catalog. The core invariants are:
//!
//! - the catalog is live, revisioned, and discoverable;
//! - workers own the functions and triggers they register;
//! - mutating capabilities require idempotency metadata;
//! - invocations carry actor, authority, catalog revision, trace, idempotency,
//!   and optional parent/trigger context into a pluggable engine ledger;
//! - declared request/response schemas are enforced before/after handlers;
//! - session capabilities can be explicitly promoted to workspace/system scope;
//! - `EngineHost` exposes privileged `engine::*` meta-capabilities for live
//!   discovery, inspection, cursor watch, delegated invocation, and promotion;
//! - `EngineHostHandle` gives server startup and adapters an intent-shaped
//!   boundary that prepares under lock, executes direct and delegated handlers
//!   outside the lock, and finishes ledger/idempotency bookkeeping under lock;
//! - agents use `AgentCapabilityClient` and engine tools to discover, inspect,
//!   watch, and invoke live canonical capabilities without frozen snapshots;
//! - the RPC bridge keeps legacy method names as trigger metadata while
//!   migrated methods execute as canonical domain functions such as
//!   `events::append`, `filesystem::create_dir`, and `skills::activate`;
//! - stream, state, and queue workers are registered as first-class primitive
//!   workers with in-memory and SQLite-backed stores scoped outside the
//!   production event-store migration;
//! - approval is a first-class primitive: high-risk agent-visible functions can
//!   pause into `approval::*` records and scoped stream events before execution;
//! - resource leases and compensation contracts are first-class primitives for
//!   high-risk shared-state mutations, so the host can acquire/release one
//!   domain resource, record auditable rollback/compensation state, and avoid
//!   blocking the whole host or inventing per-handler locks;
//! - the trigger runtime records trigger metadata, transport/domain authority
//!   scopes, and prepare failures before invoking in-process functions, and
//!   `DeliveryMode::Enqueue` durably hands work to the queue primitive;
//! - the local external-worker runtime speaks the loopback protocol, registers
//!   session-visible volatile functions/triggers, and unregisters them on
//!   disconnect; sandbox execution and remote workers remain deferred.
//!
//! # INVARIANT: one production execution shape
//!
//! Production behavior must enter the fabric as a canonical engine function.
//! JSON-RPC names are transport aliases, not executable `rpc::*` functions, and
//! production engine modules must not call old RPC `MethodHandler` adapters.
//! Legacy handler code may exist only as `#[cfg(test)]` wire fixtures.
//!
//! ## Module Position
//!
//! Depends on: `serde`, `serde_json`, `async_trait`, `thiserror`, `chrono`,
//! `sha2`, `hex`, and `rusqlite` for the isolated durable ledger adapter.
//! Does not depend on runtime, server, events, tools, or settings. Server-side
//! adapters register those subsystems as in-process workers at startup without
//! making the engine core depend on them.

#![deny(unsafe_code)]

pub mod approval;
pub mod capabilities;
pub mod compensation;
pub mod discovery;
pub mod errors;
pub mod external;
pub mod host;
pub mod ids;
pub mod invocation;
pub mod leases;
pub mod ledger;
pub mod policy;
pub mod protocol;
pub mod queue;
pub mod registry;
pub mod schema;
pub mod state;
pub mod streams;
pub mod triggers;
pub mod types;

pub use approval::{
    ApprovalDecision, ApprovalStatus, EngineApprovalRecord, EngineApprovalRequest,
    InMemoryEngineApprovalStore, SqliteEngineApprovalStore,
};
pub use capabilities::AgentCapabilityClient;
pub use compensation::{
    EngineCompensationRecord, EngineCompensationStatus, InMemoryEngineCompensationStore,
    SqliteEngineCompensationStore,
};
pub use discovery::{ActorContext, ActorKind, FunctionQuery};
pub use errors::{EngineError, Result};
pub use external::{EngineExternalWorkerRuntime, ExternalWorkerConnection};
pub use host::{
    EngineHost, EngineHostHandle, EngineWatchRequest, EngineWatchResponse,
    engine_ledger_path_for_event_db,
};
pub use ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
pub use invocation::{
    CausalContext, InProcessFunctionHandler, Invocation, InvocationRecord, InvocationResult,
};
pub use leases::{
    AcquireResourceLease, EngineResourceLease, EngineResourceLeaseStatus,
    InMemoryEngineResourceLeaseStore, SqliteEngineResourceLeaseStore,
};
pub use ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, InMemoryEngineLedgerStore,
    SqliteEngineLedgerStore, StoredEngineError, StoredInvocationOutcome,
};
pub use protocol::{
    CatalogSnapshot, RegisterFunction, RegisterTrigger, WORKER_PROTOCOL_VERSION,
    WorkerCatalogChange, WorkerDisconnect, WorkerHeartbeat, WorkerHello, WorkerInvocationResult,
    WorkerInvoke, WorkerProtocolMessage,
};
pub use queue::{
    EngineQueueDrainer, EngineQueueItem, EngineQueueRuntime, EnqueueInvocation,
    InMemoryEngineQueueStore, QueueItemStatus, SqliteEngineQueueStore,
};
pub use registry::LiveCatalog;
pub use state::{
    EngineStateEntry, EngineStateScope, InMemoryEngineStateStore, SqliteEngineStateStore,
};
pub use streams::{
    EngineStreamEvent, EngineStreamPage, EngineStreamSubscription, InMemoryEngineStreamStore,
    PublishStreamEvent, SqliteEngineStreamStore, StreamActorScope, StreamCursor,
};
pub use triggers::{EngineTriggerRuntime, TriggerDispatchRequest};
pub use types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, CompensationContract, CompensationKind, DeliveryMode, EffectClass,
    FunctionDefinition, FunctionHealth, FunctionRevision, IdempotencyContract,
    IdempotencyKeySource, IdempotencyScope, LedgerKind, Provenance, ReplayBehavior,
    ResourceLeaseFailureBehavior, ResourceLeaseRequirement, RiskLevel, TriggerDefinition,
    TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition, WorkerKind,
    WorkerLifecycleState, WorkerRevision,
};

#[cfg(test)]
mod tests;
