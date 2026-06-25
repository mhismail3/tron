//! Generic engine resource kernel.
//!
//! Resources are the durable object model for the primitive engine. Artifacts,
//! goals, claims, evidence, decisions, approval requests/decisions, UI
//! surfaces, catalog-discovery reports, harness docs, inert procedural records,
//! and files become typed resources with versioned payloads, links, lifecycle
//! state, policy, provenance, and auditable events. Streams, indexes, and
//! control-plane summaries are projections over this store.
//!
//! Ownership is split by concern: `types` holds public substrate structs,
//! `definitions` registers built-in resource kinds, `validation` enforces the
//! generic resource contract, `versions` owns payload hashing/current-version
//! helpers, domain definition modules own contract resource schemas including
//! procedural skill/rule/hook/procedure custody records,
//! `ui_surface` validates the runtime UI surface payload, and `store` contains
//! the in-memory and SQLite persistence implementations.

mod definitions;
mod git_definitions;
mod goal_definitions;
mod job_definitions;
mod memory_definitions;
mod notification_definitions;
mod procedural_definitions;
mod scheduler_definitions;
mod store;
mod subagent_definitions;
mod tool_source_definitions;
mod types;
mod ui_surface;
mod validation;
mod versions;
mod web_definitions;

pub use definitions::builtin_resource_type_definitions;
pub use store::{InMemoryEngineResourceStore, SqliteEngineResourceStore};
pub use types::*;
pub(crate) use ui_surface::validate_ui_surface_payload;
