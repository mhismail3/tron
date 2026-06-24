//! # engine
//!
//! In-process primitive execution fabric for the Tron agent.
//!
//! The public `/engine` protocol is client and worker transport over canonical
//! engine functions. Model providers do not see that transport surface
//! directly; agents receive one model-facing capability, `execute`, which
//! routes through this fabric and records durable invocation/trace evidence.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`authority`] | Grants, leases, compensation, and authorization policy |
//! | [`catalog`] | Live catalog registry, discovery, capability views, and revision changes |
//! | [`durability`] | SQLite/in-memory ledgers, queues, resources, streams, state, and traces |
//! | [`invocation`] | Host handle, invocation records, handler dispatch, and model-facing context |
//! | [`kernel`] | Engine ids, definitions, shared types, and error model |
//! | [`primitives`] | Engine-native primitive workers such as resource/grant/ui support |
//! | [`runtime`] | Trigger dispatch, external-worker runtime, and worker protocol DTOs |
//!
//! ## Entry Points
//!
//! - [`EngineHost`] owns the in-process catalog, policy checks, invocation
//!   lifecycle, idempotency, ledgers, queues, streams, resources, grants, and
//!   runtime handles.
//! - [`EngineHostHandle`] is the intent-shaped boundary used by transports,
//!   startup, and domain services.
//! - [`EngineTriggerRuntime`] dispatches trigger-originated work through the
//!   same canonical invocation lifecycle as direct requests.
//! - [`EngineExternalWorkerRuntime`] owns loopback external-worker connection,
//!   registration, health, and invocation proxy state.
//!
//! ## Invariants
//!
//! - the catalog is live, revisioned, and discoverable;
//! - workers own the functions and triggers they register;
//! - mutating capabilities require idempotency metadata;
//! - engine submodules are crate-private implementation. Code outside
//!   `engine/` must use the narrow facade re-exports in this module instead of
//!   importing catalog, durability, invocation, kernel, primitive, or runtime
//!   internals directly;
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
//!   read-only grant inspection through the handle is reserved for domain
//!   workers that must enforce policy against the active stored grant without
//!   importing grant-store internals;
//! - model-facing agents act through the capability-domain `execute` primitive;
//!   retained registration policy checks infrastructure contracts such as
//!   idempotency, schema shape, resource leases, and compensation;
//! - registered domain functions are loop infrastructure only; retired product
//!   domains are not part of startup registration on this branch;
//! - stream, state, queue, catalog, grant, worker, trace records, generated UI,
//!   and the generic `resource` kernel are retained only where covered by the
//!   primitive loop and the completed cleanup/ownership scorecards;
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
//!   without committing a failed target invocation row;
//! - queue resource governance is owned by the queue substrate: active
//!   ready/leased depth, list page size, and serialized payload size are capped
//!   before storage so worker bursts backpressure at the durable receipt
//!   boundary rather than inside provider or transport code.
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

pub(crate) mod authority;
pub(crate) mod catalog;
pub(crate) mod durability;
pub(crate) mod invocation;
pub(crate) mod kernel;
pub(crate) mod primitives;
pub(crate) mod runtime;

pub use authority::compensation::{EngineCompensationRecord, EngineCompensationStatus};
pub use authority::grants::{
    ConsumeGrantInvocationBudget, DeriveGrant, EngineGrant, EngineGrantEvent, EngineGrantLifecycle,
    ListGrants,
};
pub use authority::leases::{AcquireResourceLease, EngineResourceLease, EngineResourceLeaseStatus};
pub use catalog::capabilities::AgentCapabilityClient;
pub use catalog::discovery::{ActorContext, ActorKind, FunctionQuery};
pub use catalog::registry::LiveCatalog;
pub use durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, StoredEngineError, StoredInvocationOutcome,
};
pub use durability::queue::{
    EngineQueueAttemptRecord, EngineQueueDrainer, EngineQueueItem, EngineQueueRuntime,
    EnqueueInvocation, MAX_ACTIVE_QUEUE_ITEMS_PER_QUEUE, MAX_QUEUE_LIST_PAGE_SIZE,
    MAX_QUEUE_PAYLOAD_BYTES, QueueAttemptOutcome, QueueItemStatus,
};
pub(crate) use durability::replay::EngineReplaySnapshot;
#[cfg(test)]
pub(crate) use durability::resources::builtin_resource_type_definitions;
pub use durability::resources::{
    APPROVAL_DECISION_KIND, APPROVAL_DECISION_SCHEMA_ID, APPROVAL_REQUEST_KIND,
    APPROVAL_REQUEST_SCHEMA_ID, CATALOG_DISCOVERY_REPORT_KIND, CATALOG_DISCOVERY_REPORT_SCHEMA_ID,
    CreateResource, EngineResource, EngineResourceEvent, EngineResourceInspection,
    EngineResourceLink, EngineResourceLocation, EngineResourceScope, EngineResourceTypeDefinition,
    EngineResourceVersion, EngineResourceVersioningMode, GIT_BRANCH_START_KIND,
    GIT_BRANCH_START_SCHEMA_ID, GIT_COMMIT_KIND, GIT_COMMIT_SCHEMA_ID, GIT_INDEX_CHANGE_KIND,
    GIT_INDEX_CHANGE_SCHEMA_ID, GOAL_ANSWER_KIND, GOAL_ANSWER_SCHEMA_ID, JOB_PROCESS_KIND,
    JOB_PROCESS_SCHEMA_ID, LinkResources, ListResources, MEMORY_ENGINE_KIND,
    MEMORY_ENGINE_SCHEMA_ID, MEMORY_EVAL_RUN_KIND, MEMORY_EVAL_RUN_SCHEMA_ID,
    MEMORY_MIGRATION_ENVELOPE_KIND, MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID, MEMORY_POLICY_KIND,
    MEMORY_POLICY_SCHEMA_ID, MEMORY_PROMPT_TRACE_KIND, MEMORY_PROMPT_TRACE_SCHEMA_ID,
    MEMORY_RECORD_KIND, MEMORY_RECORD_SCHEMA_ID, RegisterResourceType, UI_SURFACE_KIND,
    USER_QUESTION_KIND, USER_QUESTION_SCHEMA_ID, UpdateResource, WEB_ROBOTS_POLICY_KIND,
    WEB_ROBOTS_POLICY_SCHEMA_ID, WEB_SOURCE_KIND, WEB_SOURCE_SCHEMA_ID,
};
pub use durability::state::{EngineStateEntry, EngineStateScope};
pub use durability::streams::{
    EngineStreamEvent, EngineStreamPage, EngineStreamSubscription, PublishStreamEvent,
    StreamActorScope, StreamCursor,
};
pub use invocation::host::{
    CatalogWatchRequest, CatalogWatchResponse, EngineHost, EngineHostHandle,
};
pub use invocation::model::{
    CausalContext, InProcessFunctionHandler, Invocation, InvocationRecord, InvocationResult,
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TRIGGER_DEPTH,
    RUNTIME_METADATA_TRIGGER_PATH, RUNTIME_METADATA_TURN, RUNTIME_METADATA_WORKING_DIRECTORY,
};
pub use kernel::errors::{EngineError, Result};
pub use kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
pub use kernel::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
pub use kernel::types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, CompensationContract, CompensationKind, DeliveryMode,
    DurableOutputContract, EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision,
    IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind, Provenance,
    ReplayBehavior, ResourceLeaseFailureBehavior, ResourceLeaseRequirement, RiskLevel,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
    WorkerKind, WorkerLifecycleState, WorkerRevision,
};
pub use runtime::external_workers::{
    EngineExternalWorkerRuntime, ExternalWorkerConnection, ExternalWorkerInvoker,
};
pub use runtime::triggers::{EngineTriggerRuntime, TriggerDispatchRequest};
pub use runtime::worker_protocol::{
    CatalogSnapshot, RegisterFunction, RegisterTrigger, ScopedWorkerToken, WORKER_PROTOCOL_VERSION,
    WorkerAuthPolicy, WorkerCatalogChange, WorkerDisconnect, WorkerHealth, WorkerHeartbeat,
    WorkerHello, WorkerIdentity, WorkerInvocationResult, WorkerInvoke, WorkerLifecycleEvent,
    WorkerProtocolMessage, WorkerRegistrationMode, WorkerStreamPublish, WorkerVisibility,
};

/// Return whether a grant id is one of the engine-owned bootstrap roots.
#[must_use]
pub(crate) fn is_bootstrap_authority_grant_id(grant_id: &AuthorityGrantId) -> bool {
    authority::grants::BOOTSTRAP_GRANT_IDS
        .iter()
        .any(|bootstrap| grant_id.as_str() == *bootstrap)
}

#[cfg(test)]
mod tests;
