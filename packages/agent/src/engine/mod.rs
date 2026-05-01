//! # engine
//!
//! In-process live capability fabric for the Tron agent.
//!
//! This module is the Phase 1 foundation for the engine redesign documented in
//! `packages/agent/docs/engine-redesign/`. It does not route production RPC,
//! tool, runtime, or client traffic yet. Instead it proves the core invariants
//! in isolation:
//!
//! - the catalog is live, revisioned, and discoverable;
//! - workers own the functions and triggers they register;
//! - mutating capabilities require idempotency metadata;
//! - invocations carry actor, authority, catalog revision, trace, and optional
//!   parent/trigger context;
//! - Phase 1 executes only in-process synchronous calls.
//!
//! ## Module Position
//!
//! Depends on: `serde`, `serde_json`, `async_trait`, `thiserror`, `chrono`.
//! Does not depend on runtime, server, events, tools, or settings.
//! Future modules will adapt those subsystems into engine workers.

#![deny(unsafe_code)]

pub mod discovery;
pub mod errors;
pub mod ids;
pub mod invocation;
pub mod policy;
pub mod registry;
pub mod types;

pub use discovery::{ActorContext, ActorKind, FunctionQuery};
pub use errors::{EngineError, Result};
pub use ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
pub use invocation::{CausalContext, InProcessFunctionHandler, Invocation, InvocationResult};
pub use registry::LiveCatalog;
pub use types::{
    AuthorityRequirement, CatalogChange, CatalogChangeKind, CatalogRevision, DeliveryMode,
    EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision, IdempotencyContract,
    IdempotencyKeySource, LedgerKind, Provenance, ReplayBehavior, RiskLevel, TriggerDefinition,
    TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition, WorkerKind,
    WorkerLifecycleState, WorkerRevision,
};

#[cfg(test)]
mod tests;
