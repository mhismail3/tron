//! Generic engine resource kernel.
//!
//! Resources are the durable object model for the primitive engine. Artifacts,
//! goals, claims, evidence, decisions, generated capability definitions,
//! agent-authored memories/rules, UI surfaces, harness docs, and files become
//! typed resources with versioned payloads, links, lifecycle state, policy,
//! provenance, and auditable events.
//! Streams, indexes, and control-plane summaries are projections over this
//! store.
//!
//! Ownership is split by concern: `types` holds public substrate structs,
//! `definitions` registers built-in resource kinds, `agent_record_definitions`
//! and `worker_schedule_definitions` hold large schema groups, `validation`
//! enforces the generic resource contract, `versions` owns payload
//! hashing/current-version helpers, `ui_surface` validates the runtime UI
//! surface payload, and `store` contains the in-memory and SQLite persistence
//! implementations.

mod agent_record_definitions;
mod definitions;
mod store;
mod types;
mod ui_surface;
mod validation;
mod versions;
mod worker_schedule_definitions;

pub use definitions::builtin_resource_type_definitions;
pub use store::{InMemoryEngineResourceStore, SqliteEngineResourceStore};
pub use types::*;
pub(crate) use ui_surface::validate_ui_surface_payload;
