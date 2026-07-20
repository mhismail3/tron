//! Generic engine resource kernel.
//!
//! Resources are the durable object model for the worker-first engine. Generic
//! artifacts, decisions, claims, evidence, UI surfaces, context-control state,
//! memory, and private devices use versioned payloads, links,
//! lifecycle state, policy, provenance, and auditable events. Worker bundles
//! and operational records are owned by `domains::worker_kernel`, not encoded
//! as proposal-era resource types.
//!
//! Ownership is split by concern: `types` holds public substrate structs,
//! `definitions` and the type-definition modules register engine-owned
//! substrate kinds, `validation` enforces the generic resource contract,
//! `versions` owns payload hashing/current-version helpers, `ui_surface`
//! validates the runtime UI surface payload, and `store` contains the in-memory
//! and SQLite persistence implementations. Feature composition can register
//! feature-owned definitions and reconcile source-owned payloads through the
//! host boundary; the engine neither enumerates feature records nor imports
//! their domain contracts.

mod context_control_definitions;
mod definitions;
mod device_definitions;
mod memory_definitions;
mod store;
mod types;
mod ui_surface;
mod validation;
mod versions;

pub(crate) use context_control_definitions::{
    CONTEXT_CONTROL_ACTION_PAYLOAD_SCHEMA_VERSION, CONTEXT_CONTROL_EPOCH_PAYLOAD_SCHEMA_VERSION,
    CONTEXT_CONTROL_SNAPSHOT_PAYLOAD_SCHEMA_VERSION, CONTEXT_EXCLUSION_PAYLOAD_SCHEMA_VERSION,
    CONTEXT_POLICY_SNAPSHOT_PAYLOAD_SCHEMA_VERSION, CONTEXT_SURVIVOR_PAYLOAD_SCHEMA_VERSION,
};
pub use definitions::builtin_resource_type_definitions;
pub use store::{InMemoryEngineResourceStore, SqliteEngineResourceStore};
pub use types::*;
pub(crate) use ui_surface::validate_ui_surface_payload;
