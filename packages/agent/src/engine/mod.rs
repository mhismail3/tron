//! # engine
//!
//! In-process live capability fabric for the Tron agent.
//!
//! This module is the Phase 1 foundation for the engine redesign documented in
//! `packages/agent/docs/engine-redesign/`. It now routes selected production
//! RPC reads and the first fully collapsed write groups through engine-owned
//! functions while tool, runtime, and broader client traffic remain on their
//! existing paths. The core invariants are:
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
//! - the RPC bridge registers `rpc::<method>` compatibility functions and
//!   `json_rpc` triggers so JSON-RPC can collapse into one transport over
//!   engine functions;
//! - the initial trigger runtime records trigger metadata and invokes
//!   in-process functions synchronously; queue, stream, cron, and external
//!   worker delivery stay deferred until this local fabric is solid.
//!
//! ## Module Position
//!
//! Depends on: `serde`, `serde_json`, `async_trait`, `thiserror`, `chrono`,
//! `sha2`, `hex`, and `rusqlite` for the isolated durable ledger adapter.
//! Does not depend on runtime, server, events, tools, or settings. Server-side
//! adapters register those subsystems as in-process workers at startup without
//! making the engine core depend on them.

#![deny(unsafe_code)]

pub mod discovery;
pub mod errors;
pub mod host;
pub mod ids;
pub mod invocation;
pub mod ledger;
pub mod policy;
pub mod registry;
pub mod schema;
pub mod triggers;
pub mod types;

pub use discovery::{ActorContext, ActorKind, FunctionQuery};
pub use errors::{EngineError, Result};
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
pub use ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, InMemoryEngineLedgerStore,
    SqliteEngineLedgerStore, StoredEngineError, StoredInvocationOutcome,
};
pub use registry::LiveCatalog;
pub use triggers::{EngineTriggerRuntime, TriggerDispatchRequest};
pub use types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, DeliveryMode, EffectClass, FunctionDefinition, FunctionHealth,
    FunctionRevision, IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind,
    Provenance, ReplayBehavior, RiskLevel, TriggerDefinition, TriggerRevision,
    TriggerTypeDefinition, VisibilityScope, WorkerDefinition, WorkerKind, WorkerLifecycleState,
    WorkerRevision,
};

#[cfg(test)]
mod tests;
