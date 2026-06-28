//! Generic engine resource kernel.
//!
//! Resources are the durable object model for the primitive engine. Artifacts,
//! goals, claims, evidence, decisions, approval requests/decisions, UI
//! surfaces, catalog-discovery reports, module manifests, harness docs, inert
//! procedural records, media artifacts, repository/import/program-execution
//! metadata records, and files become typed resources with versioned payloads,
//! links, lifecycle state, policy, provenance, and auditable events. Streams,
//! indexes, and control-plane summaries are projections over this store.
//!
//! Ownership is split by concern: `types` holds public substrate structs,
//! `definitions` registers built-in resource kinds, `validation` enforces the
//! generic resource contract, `versions` owns payload hashing/current-version
//! helpers, domain definition modules own contract resource schemas including
//! module manifests, module validation reports, procedural
//! skill/rule/hook/procedure custody records, module dependency policy
//! metadata records, and media artifacts,
//! `ui_surface` validates the runtime UI surface payload, and `store` contains
//! the in-memory and SQLite persistence implementations.

mod definitions;
mod git_definitions;
mod goal_definitions;
mod import_history_definitions;
mod import_preview_definitions;
mod job_definitions;
mod media_definitions;
mod memory_definitions;
mod module_authoring_definitions;
mod module_dependencies_definitions;
mod module_install_definitions;
mod module_lifecycle_definitions;
mod module_registry_definitions;
mod module_registry_memory_manifest;
mod module_runtime_definitions;
mod module_validation_definitions;
mod notification_definitions;
mod procedural_definitions;
mod program_execution_definitions;
mod prompt_artifact_definitions;
mod repository_tree_definitions;
mod scheduler_definitions;
mod store;
mod subagent_definitions;
mod tool_source_definitions;
mod types;
mod ui_surface;
mod update_diagnostics_definitions;
mod validation;
mod versions;
mod web_definitions;

pub use definitions::builtin_resource_type_definitions;
pub(crate) use module_authoring_definitions::MODULE_PROPOSAL_PAYLOAD_SCHEMA_VERSION;
pub(crate) use module_dependencies_definitions::{
    MODULE_DEPENDENCY_DECISION_PAYLOAD_SCHEMA_VERSION,
    MODULE_DEPENDENCY_POLICY_PAYLOAD_SCHEMA_VERSION,
    MODULE_DEPENDENCY_REQUEST_PAYLOAD_SCHEMA_VERSION,
};
pub(crate) use module_install_definitions::{
    MODULE_INSTALL_DECISION_PAYLOAD_SCHEMA_VERSION, MODULE_INSTALL_REQUEST_PAYLOAD_SCHEMA_VERSION,
};
pub(crate) use module_lifecycle_definitions::MODULE_LIFECYCLE_STATE_PAYLOAD_SCHEMA_VERSION;
pub(crate) use module_registry_definitions::MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION;
pub(in crate::engine) use module_registry_definitions::builtin_module_manifest_resources;
pub(crate) use module_runtime_definitions::MODULE_RUNTIME_STATE_PAYLOAD_SCHEMA_VERSION;
pub(crate) use module_validation_definitions::MODULE_VALIDATION_REPORT_PAYLOAD_SCHEMA_VERSION;
pub use store::{InMemoryEngineResourceStore, SqliteEngineResourceStore};
pub use types::*;
pub(crate) use ui_surface::validate_ui_surface_payload;
