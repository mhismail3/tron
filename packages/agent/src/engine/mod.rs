//! # Worker-first engine kernel
//!
//! This crate-private fabric provides typed invocation, durable state and
//! events and authenticated transport primitives. Persistent workers are
//! owned by domains::worker_kernel; model-facing calls use direct typed
//! functions.
//!
//! ## Boundaries
//!
//! | Module | Fixed responsibility |
//! |--------|----------------------|
//! | catalog | Live typed function definitions and discovery |
//! | invocation | Typed dispatch, schemas, causal traces, and ledgers |
//! | durability | SQLite/in-memory state, streams, and invocation ledgers |
//! | primitives | Direct durable state and stream stores |
//!
//! ## Invariants
//!
//! - Trusted-local agent and worker invocations carry identities, provenance,
//!   hashes, and traces as observable evidence, not permission objects.
//! - Remote clients and external transports remain authenticated.
//! - Requests and responses are validated against the registered JSON schemas.
//! - Durable mutation and invocation delivery retain idempotency and causal truth.
//! - Product scheduling, worker lifecycle, version switching, inbox delivery,
//!   and loop suppression belong to the worker kernel, not parallel engine
//!   proposal or metadata planes.
//!
//! Engine behavior enters as a canonical typed function. Code outside engine/
//! uses the narrow re-exports below rather than its internals.

#![deny(unsafe_code)]

pub(crate) mod catalog;
pub(crate) mod durability;
pub(crate) mod invocation;
pub(crate) mod kernel;
pub(crate) mod primitives;

pub use catalog::discovery::{ActorContext, ActorKind};
pub use durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, StoredEngineError, StoredInvocationOutcome,
};
pub(crate) use durability::replay::EngineReplaySnapshot;
pub use durability::state::{EngineStateEntry, EngineStateScope};
pub use durability::streams::{
    EngineStreamEvent, EngineStreamPage, PublishStreamEvent, StreamActorScope, StreamCursor,
};
pub use invocation::host::EngineHostHandle;
pub use invocation::model::{
    CausalContext, InProcessFunctionHandler, Invocation, InvocationRecord, InvocationResult,
};
pub use kernel::errors::{EngineError, Result};
pub use kernel::ids::{ActorId, FunctionId, InvocationId, TraceId, WorkerId};
pub(crate) use kernel::schema::validate_payload as validate_engine_schema_payload;
pub(crate) use kernel::schema::validate_schema_definition as validate_engine_schema_definition;
pub use kernel::types::{
    CatalogRevision, DedupeScope, DirectWorkerToolContract, EffectClass, FunctionDefinition,
    FunctionRevision, FunctionVisibility, IdempotencyContract, IdempotencyScope, ModelToolAudience,
    ModelToolContract, RiskLevel, StreamVisibility,
};

#[cfg(test)]
mod tests;
