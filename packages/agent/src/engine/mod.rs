//! # engine
//!
//! In-process primitive execution fabric for the Tron agent.
//!
//! The public `/engine` protocol is client and worker transport over canonical
//! engine functions. Model providers do not see that transport surface
//! directly; agents receive one model-facing capability, `execute`, which
//! routes through this fabric and records durable invocation/trace evidence.
//! The core invariants are:
//!
//! - the catalog is live, revisioned, and discoverable;
//! - workers own the functions and triggers they register;
//! - mutating capabilities require idempotency metadata;
//! - invocations carry actor, authority grant id, catalog revision, trace,
//!   session, workspace, idempotency, optional parent/trigger context, and
//!   trusted runtime metadata such as working directory and provider provenance
//!   into a pluggable engine ledger; invocation prepare resolves that grant from
//!   the engine-owned grant store before any handler runs;
//! - declared request/response schemas are enforced before/after handlers;
//! - session capabilities can be explicitly promoted to workspace/system scope;
//! - `EngineHost` exposes privileged `engine::*` transport functions for live
//!   worker/client discovery, inspection, cursor watch, delegated invocation,
//!   and promotion;
//! - `EngineHostHandle` gives server startup and runtime services an intent-shaped
//!   boundary that prepares under lock, executes direct and delegated handlers
//!   outside the lock, and finishes ledger/idempotency bookkeeping under lock;
//! - model-facing agents act through the capability-domain `execute` primitive;
//!   retained registration policy checks infrastructure contracts such as
//!   idempotency, schema shape, resource leases, and compensation;
//! - registered domain functions are loop infrastructure only; retired product
//!   domains are not part of startup registration on this branch;
//! - stream, state, queue, catalog, grant, worker, trace records, generated UI,
//!   and the generic `resource` kernel are retained only where still needed by
//!   the primitive loop or awaiting their teardown scorecard rows;
//! - resource leases and compensation contracts are first-class primitives for
//!   shared-state mutations, so the host can acquire/release one domain resource
//!   from payload fields plus causal context such as `sessionId`, record
//!   auditable rollback/compensation state for direct and host-dispatched
//!   functions, and avoid blocking the whole host or inventing per-handler locks;
//! - typed resources are the durable object substrate: artifacts, goals, claims,
//!   evidence, decisions, generated UI surfaces, trace records, and
//!   materialized files are modeled as versioned resources with links and
//!   events instead of separate persistence planes;
//! - runtime UI surfaces are schema-versioned `ui_surface` resources; the
//!   engine stores and validates the declared component tree while
//!   `ui::submit_action` records generic action submissions without
//!   server-authored target routing;
//! - durable-output capabilities declare output contracts and finish validation
//!   requires canonical resource refs for every resource-backed path;
//! - the trigger runtime records trigger metadata, transport/domain authority
//!   scopes, and prepare failures before invoking in-process functions;
//!   `DeliveryMode::Void` is limited to the private trigger runtime path for
//!   explicit low-risk loss-tolerant targets, trigger cascades carry depth/path
//!   budgets that fail closed, and `DeliveryMode::Enqueue` durably hands work
//!   plus runtime metadata to the queue primitive;
//! - the local external-worker runtime speaks the `/engine/workers` loopback
//!   protocol, registers scoped functions/triggers, publishes streams only
//!   through `stream::publish`, cleans volatile workers on disconnect, marks
//!   durable disconnected workers unhealthy, hydrates durable external-worker
//!   definitions from SQLite restart as stopped/unhealthy until the socket
//!   reconnects, and classifies socket loss separately from application handler
//!   failures;
//! - queue receipts retain inspectable delivery truth: current lease state,
//!   retry/dead-letter/cancellation status, delivery and result invocation ids,
//!   replay refs, errors, resource lease ids, and compensation refs are stored
//!   on the queue item instead of living only in stream logs; queued
//!   non-mutating worker transport failures retry through queue lifecycle truth
//!   without committing a failed target invocation row.
//!
//! # INVARIANT: one production execution shape
//!
//! Production behavior must enter the fabric as a canonical engine function.
//! The `/engine` protocol exposes worker/client discovery, inspection, watch,
//! invocation, promotion, and stream subscription messages. Production engine
//! modules must not call handler-shaped transport shortcuts.
//!
//! ## Module Position
//!
//! Depends on: `serde`, `serde_json`, `async_trait`, `thiserror`, `chrono`,
//! `sha2`, `hex`, and `rusqlite` for the isolated durable ledger store.
//! Does not depend on transport handlers, session stores, provider code,
//! capability domains, or settings. Server-owned services register those
//! subsystems as in-process workers at startup without making the engine core
//! depend on them.
//!
//! ## Test Ownership
//!
//! Engine tests live in `engine/tests/` by substrate concern. `tests/mod.rs`
//! is declaration-only, `tests/support.rs` owns shared fixtures, and behavior
//! tests belong in the focused file for their concern instead of a catch-all
//! root.

#![deny(unsafe_code)]

pub mod authority;
pub mod catalog;
pub mod durability;
pub mod invocation;
pub mod kernel;
pub mod primitives;
pub mod runtime;

pub use authority::compensation::{
    EngineCompensationRecord, EngineCompensationStatus, InMemoryEngineCompensationStore,
    SqliteEngineCompensationStore,
};
pub use authority::grants::{
    DeriveGrant, EngineGrant, EngineGrantEvent, EngineGrantLifecycle, EngineGrantStoreBackend,
    InMemoryEngineGrantStore, ListGrants, SqliteEngineGrantStore,
};
pub use authority::leases::{
    AcquireResourceLease, EngineResourceLease, EngineResourceLeaseStatus,
    InMemoryEngineResourceLeaseStore, SqliteEngineResourceLeaseStore,
};
pub use catalog::capabilities::AgentCapabilityClient;
pub use catalog::discovery::{ActorContext, ActorKind, FunctionQuery};
pub use catalog::registry::LiveCatalog;
pub use durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, InMemoryEngineLedgerStore,
    SqliteEngineLedgerStore, StoredEngineError, StoredInvocationOutcome,
};
pub use durability::queue::{
    EngineQueueAttemptRecord, EngineQueueDrainer, EngineQueueItem, EngineQueueRuntime,
    EnqueueInvocation, InMemoryEngineQueueStore, QueueAttemptOutcome, QueueItemStatus,
    SqliteEngineQueueStore,
};
pub use durability::resources::{
    CreateResource, EngineResource, EngineResourceEvent, EngineResourceInspection,
    EngineResourceLink, EngineResourceLocation, EngineResourceScope, EngineResourceTypeDefinition,
    EngineResourceVersion, EngineResourceVersioningMode, InMemoryEngineResourceStore,
    LinkResources, ListResources, RegisterResourceType, SqliteEngineResourceStore, UpdateResource,
};
pub use durability::state::{
    EngineStateEntry, EngineStateScope, InMemoryEngineStateStore, SqliteEngineStateStore,
};
pub use durability::streams::{
    EngineStreamEvent, EngineStreamPage, EngineStreamSubscription, InMemoryEngineStreamStore,
    PublishStreamEvent, SqliteEngineStreamStore, StreamActorScope, StreamCursor,
};
pub use invocation::host::{
    CatalogWatchRequest, CatalogWatchResponse, EngineHost, EngineHostHandle,
};
pub use invocation::model::{
    CausalContext, InProcessFunctionHandler, Invocation, InvocationRecord, InvocationResult,
};
pub use kernel::errors::{EngineError, Result};
pub use kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
pub use kernel::types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, CompensationContract, CompensationKind, DeliveryMode,
    DurableOutputContract, EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision,
    IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind, Provenance,
    ReplayBehavior, ResourceLeaseFailureBehavior, ResourceLeaseRequirement, RiskLevel,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
    WorkerKind, WorkerLifecycleState, WorkerRevision,
};
pub use runtime::external_workers::{EngineExternalWorkerRuntime, ExternalWorkerConnection};
pub use runtime::triggers::{EngineTriggerRuntime, TriggerDispatchRequest};
pub use runtime::worker_protocol::{
    CatalogSnapshot, RegisterFunction, RegisterTrigger, WORKER_PROTOCOL_VERSION, WorkerAuthPolicy,
    WorkerCatalogChange, WorkerDisconnect, WorkerHealth, WorkerHeartbeat, WorkerHello,
    WorkerIdentity, WorkerInvocationResult, WorkerInvoke, WorkerLifecycleEvent,
    WorkerProtocolMessage, WorkerRegistrationMode, WorkerStreamPublish, WorkerVisibility,
};

#[cfg(test)]
mod tests;
