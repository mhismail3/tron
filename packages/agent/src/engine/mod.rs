//! # engine
//!
//! In-process live capability fabric for the Tron agent.
//!
//! This module is the foundation for the engine redesign documented in
//! `packages/agent/docs/engine-redesign/`. The public `/engine` protocol is
//! worker/client transport over canonical capabilities; model providers do not
//! see that transport surface directly. Agents receive the capability-domain
//! `execute` orchestrator over this same live catalog.
//! The core invariants are:
//!
//! - the catalog is live, revisioned, and discoverable;
//! - workers own the functions and triggers they register;
//! - mutating capabilities require idempotency metadata;
//! - invocations carry actor, authority grant id, catalog revision, trace,
//!   session, workspace, idempotency, and optional parent/trigger context into a
//!   pluggable engine ledger; invocation prepare resolves that grant from the
//!   engine-owned grant store before any handler runs;
//! - declared request/response schemas are enforced before/after handlers;
//! - session capabilities can be explicitly promoted to workspace/system scope;
//! - `EngineHost` exposes privileged `engine::*` transport functions for live
//!   worker/client discovery, inspection, cursor watch, delegated invocation,
//!   and promotion;
//! - `EngineHostHandle` gives server startup and runtime services an intent-shaped
//!   boundary that prepares under lock, executes direct and delegated handlers
//!   outside the lock, and finishes ledger/idempotency bookkeeping under lock;
//! - model-facing agents discover, inspect, and invoke live canonical
//!   capabilities only through the capability-domain primitives; internal
//!   clients preflight schema/authority before creating approval records, and
//!   agents cannot resolve approvals themselves;
//! - canonical domain functions such as `events::append`,
//!   `filesystem::create_dir`, and `skills::activate` are the only executable
//!   domain surface;
//! - stream, state, queue, approval, catalog, grant, worker, observability, and
//!   generated-UI workers plus the generic `resource` kernel are registered as
//!   first-class primitive workers with in-memory and SQLite-backed stores
//!   scoped outside the production event-store migration;
//! - approval is a first-class primitive: high-risk agent-visible functions can
//!   pause into `approval::*` records and scoped stream events before execution,
//!   idempotency is scoped by target function/session/workspace/caller key, and
//!   `approval::resolve` remains a user/client-owned primitive routed through
//!   `EngineHostHandle` so the stored invocation resumes in one trace;
//! - resource leases and compensation contracts are first-class primitives for
//!   high-risk shared-state mutations, so the host can acquire/release one
//!   domain resource from payload fields plus causal context such as `sessionId`,
//!   record auditable rollback/compensation state, and avoid blocking the whole
//!   host or inventing per-handler locks;
//! - typed resources are the durable object substrate: artifacts, goals, claims,
//!   evidence, decisions, generated UI surfaces, worker packages, and
//!   materialized files are modeled as versioned resources with links and
//!   events instead of separate persistence planes;
//! - generated UI surfaces are fixed-catalog `ui_surface` resources; the engine
//!   can author deterministic target surfaces from substrate projections,
//!   validate/refresh/expire generated versions, and clients render the
//!   declared component tree while submitting stored action ids through
//!   `ui::submit_action` so the engine reconstructs and authorizes the target
//!   capability invocation;
//! - durable-output capabilities declare output contracts and finish validation
//!   requires canonical resource refs for every resource-backed path;
//! - the trigger runtime records trigger metadata, transport/domain authority
//!   scopes, and prepare failures before invoking in-process functions, and
//!   `DeliveryMode::Enqueue` durably hands work to the queue primitive;
//! - the local external-worker runtime speaks the `/engine/workers` loopback
//!   protocol, registers scoped functions/triggers, publishes streams only
//!   through `stream::publish`, cleans volatile workers on disconnect, marks
//!   durable disconnected workers unhealthy, treats engine-issued scoped
//!   worker tokens from `worker::spawn` as selectable session-generated
//!   implementations once healthy, classifies socket loss separately from
//!   application handler failures, and supplies the sandbox-created worker path
//!   used by `worker::spawn`;
//! - queued non-mutating worker transport failures retry through queue
//!   lifecycle truth without committing a failed target invocation row.
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

pub mod approval;
pub mod capabilities;
pub mod compensation;
pub mod discovery;
pub mod errors;
pub mod external;
pub mod grants;
pub mod host;
pub mod ids;
pub mod invocation;
pub mod leases;
pub mod ledger;
pub mod policy;
pub mod primitives;
pub mod protocol;
pub mod queue;
pub mod registry;
pub mod resources;
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
pub use grants::{
    DeriveGrant, EngineGrant, EngineGrantEvent, EngineGrantLifecycle, EngineGrantStoreBackend,
    InMemoryEngineGrantStore, ListGrants, SqliteEngineGrantStore,
};
pub use host::{CatalogWatchRequest, CatalogWatchResponse, EngineHost, EngineHostHandle};
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
    CatalogSnapshot, RegisterFunction, RegisterTrigger, WORKER_PROTOCOL_VERSION, WorkerAuthPolicy,
    WorkerCatalogChange, WorkerDisconnect, WorkerHealth, WorkerHeartbeat, WorkerHello,
    WorkerIdentity, WorkerInvocationResult, WorkerInvoke, WorkerLifecycleEvent,
    WorkerProtocolMessage, WorkerRegistrationMode, WorkerStreamPublish, WorkerVisibility,
};
pub use queue::{
    EngineQueueDrainer, EngineQueueItem, EngineQueueRuntime, EnqueueInvocation,
    InMemoryEngineQueueStore, QueueItemStatus, SqliteEngineQueueStore,
};
pub use registry::LiveCatalog;
pub use resources::{
    CreateResource, EngineResource, EngineResourceEvent, EngineResourceInspection,
    EngineResourceLink, EngineResourceLocation, EngineResourceScope, EngineResourceTypeDefinition,
    EngineResourceVersion, EngineResourceVersioningMode, HARNESS_DOC_KIND, HARNESS_DOC_SCHEMA_ID,
    InMemoryEngineResourceStore, LinkResources, ListResources, RegisterResourceType,
    SqliteEngineResourceStore, UpdateResource,
};
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
    CatalogSubjectKind, CompensationContract, CompensationKind, DeliveryMode,
    DurableOutputContract, EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision,
    IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind, Provenance,
    ReplayBehavior, ResourceLeaseFailureBehavior, ResourceLeaseRequirement, RiskLevel,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
    WorkerKind, WorkerLifecycleState, WorkerRevision,
};

#[cfg(test)]
mod tests;
