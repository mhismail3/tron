//! Generic engine resource kernel.
//!
//! Resources are the collapsed durable object model for the modular engine.
//! Artifacts, goals, claims, evidence, decisions, UI surfaces, worker packages,
//! and materialized files all become typed resources with versioned payloads,
//! links, lifecycle state, policy, provenance, and auditable events. Streams,
//! indexes, and control-plane summaries are projections over this store.
//!
//! Ownership is split by concern: `types` holds public substrate structs,
//! `definitions` registers built-in resource kinds, `validation` enforces the
//! generic resource contract, `versions` owns payload hashing/current-version
//! helpers, `ui_surface` validates the fixed generated-UI resource payload, and
//! `store` contains the in-memory and SQLite persistence implementations.

mod definitions;
mod store;
mod types;
mod ui_surface;
mod validation;
mod versions;

pub use definitions::builtin_resource_type_definitions;
pub use store::{InMemoryEngineResourceStore, SqliteEngineResourceStore};
pub use types::*;
pub use ui_surface::ui_component_catalog;
pub(crate) use ui_surface::validate_ui_surface_payload;
