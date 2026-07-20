//! # Worker-first engine kernel
//!
//! This crate-private fabric provides typed invocation, durable state and
//! events, authenticated transport primitives, and the generic resource
//! substrate used by Tron's fixed infrastructure. Autonomous workers are
//! owned by domains::worker_kernel; model-facing calls use those direct typed
//! functions and never pass through an operation wrapper.
//!
//! ## Boundaries
//!
//! | Module | Fixed responsibility |
//! |--------|----------------------|
//! | catalog | Live typed function/worker definitions and discovery |
//! | invocation | Typed dispatch, schemas, causal traces, and ledgers |
//! | durability | SQLite/in-memory state, queues, streams, and resources |
//! | authority | Foundational grant/lease records for authenticated boundaries |
//! | primitives | Generic resource, state, stream, and transport primitives |
//! | runtime | Low-level trigger and external transport protocol support |
//!
//! ## Invariants
//!
//! - Trusted-local agent and worker invocations bypass authority checks without
//!   synthesizing grants; identities, provenance, hashes, and traces remain
//!   observable evidence.
//! - Remote clients and external transports remain authenticated.
//! - Requests and responses are validated against the registered JSON schemas.
//! - Durable mutation and queue delivery retain idempotency and causal truth.
//! - Product scheduling, worker lifecycle, version switching, inbox delivery,
//!   and loop suppression belong to the worker kernel, not parallel engine
//!   proposal or metadata planes.
//! - Source changes are never applied through this fabric without the worker
//!   kernel's separately recorded conversational approval boundary.
//!
//! Engine behavior enters as a canonical typed function. Code outside engine/
//! uses the narrow re-exports below rather than its internals.

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
pub use catalog::discovery::{ActorContext, ActorKind, FunctionQuery};
pub use durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, StoredEngineError, StoredInvocationOutcome,
};
pub use durability::queue::{
    EngineQueueAttemptRecord, EngineQueueDrainer, EngineQueueItem, EnqueueInvocation,
    MAX_ACTIVE_QUEUE_ITEMS_PER_QUEUE, MAX_QUEUE_LIST_PAGE_SIZE, MAX_QUEUE_PAYLOAD_BYTES,
    QueueAttemptOutcome, QueueItemStatus,
};
pub(crate) use durability::replay::EngineReplaySnapshot;
pub(crate) use durability::resources::CONTEXT_CONTROL_ACTION_PAYLOAD_SCHEMA_VERSION;
pub(crate) use durability::resources::CONTEXT_CONTROL_EPOCH_PAYLOAD_SCHEMA_VERSION;
pub(crate) use durability::resources::CONTEXT_CONTROL_SNAPSHOT_PAYLOAD_SCHEMA_VERSION;
pub(crate) use durability::resources::CONTEXT_EXCLUSION_PAYLOAD_SCHEMA_VERSION;
pub(crate) use durability::resources::CONTEXT_POLICY_SNAPSHOT_PAYLOAD_SCHEMA_VERSION;
pub(crate) use durability::resources::CONTEXT_SURVIVOR_PAYLOAD_SCHEMA_VERSION;
#[cfg(test)]
pub(crate) use durability::resources::builtin_resource_type_definitions;
pub use durability::resources::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_ACTION_SCHEMA_ID, CONTEXT_CONTROL_EPOCH_KIND,
    CONTEXT_CONTROL_EPOCH_SCHEMA_ID, CONTEXT_CONTROL_SNAPSHOT_KIND,
    CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID, CONTEXT_EXCLUSION_KIND, CONTEXT_EXCLUSION_SCHEMA_ID,
    CONTEXT_POLICY_SNAPSHOT_KIND, CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID, CONTEXT_SURVIVOR_KIND,
    CONTEXT_SURVIVOR_SCHEMA_ID, CreateResource, DEVICE_REGISTRATION_KIND,
    DEVICE_REGISTRATION_SCHEMA_ID, EngineResource, EngineResourceEvent, EngineResourceInspection,
    EngineResourceLink, EngineResourceLocation, EngineResourceScope, EngineResourceTypeDefinition,
    EngineResourceVersion, EngineResourceVersioningMode, LinkResources, ListResources,
    MEMORY_DECISION_KIND, MEMORY_DECISION_SCHEMA_ID, MEMORY_ENGINE_KIND, MEMORY_ENGINE_SCHEMA_ID,
    MEMORY_EVAL_RUN_KIND, MEMORY_EVAL_RUN_SCHEMA_ID, MEMORY_MIGRATION_ENVELOPE_KIND,
    MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID, MEMORY_POLICY_KIND, MEMORY_POLICY_SCHEMA_ID,
    MEMORY_PROMPT_TRACE_KIND, MEMORY_PROMPT_TRACE_SCHEMA_ID, MEMORY_QUERY_KIND,
    MEMORY_QUERY_SCHEMA_ID, MEMORY_RECORD_KIND, MEMORY_RECORD_SCHEMA_ID, RegisterResourceType,
    UI_SURFACE_KIND, UI_SURFACE_SCHEMA_ID, UI_SURFACE_SCHEMA_VERSION, UpdateResource,
};
pub use durability::state::{EngineStateEntry, EngineStateScope};
pub use durability::streams::{
    EngineStreamEvent, EngineStreamPage, EngineStreamSubscription, PublishStreamEvent,
    StreamActorScope, StreamCursor,
};
pub use invocation::host::{CatalogWatchRequest, CatalogWatchResponse, EngineHostHandle};
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
pub(crate) use kernel::schema::validate_payload as validate_engine_schema_payload;
pub(crate) use kernel::schema::validate_schema_definition as validate_engine_schema_definition;
pub use kernel::types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, CompensationContract, CompensationKind, DeliveryMode,
    DurableOutputContract, EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision,
    IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind, Provenance,
    ReplayBehavior, ResourceLeaseFailureBehavior, ResourceLeaseRequirement, RiskLevel,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
    WorkerKind, WorkerLifecycleState, WorkerRevision,
};
pub use runtime::external_workers::EngineExternalWorkerRuntime;
pub(crate) use runtime::external_workers::ExternalWorkerInvoker;
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
    authority::grants::is_bootstrap_grant_id(grant_id)
}

#[cfg(test)]
mod tests;
