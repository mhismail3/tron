//! Generic engine resource kernel.
//!
//! Resources are the durable object model for the primitive engine. Artifacts,
//! goals, claims, evidence, decisions, approval requests/decisions, UI
//! surfaces, catalog-discovery reports, module manifests, harness docs, inert
//! procedural records, procedural activation request/decision evidence, media
//! artifacts, repository/import/program-execution metadata records, and files
//! become typed resources with versioned payloads, links, lifecycle state,
//! policy, provenance, and auditable events. Streams, indexes, and
//! control-plane summaries are projections over this store.
//!
//! Ownership is split by concern: `types` holds public substrate structs,
//! `definitions` and the type-definition modules register accepted resource
//! kinds, `validation` enforces the generic resource contract, `versions` owns
//! payload hashing/current-version helpers, `ui_surface` validates the runtime
//! UI surface payload, and `store` contains the in-memory and SQLite persistence
//! implementations. Feature composition supplies source-owned resource
//! payloads through the host reconciliation boundary; the engine neither
//! enumerates feature records nor imports their domain contracts.

mod capability_binding_definitions;
mod context_control_definitions;
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
mod web_research_definitions;

pub(crate) use capability_binding_definitions::{
    CAPABILITY_BINDING_DECISION_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_BINDING_POLICY_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_BINDING_REQUEST_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_REPLACEMENT_CANDIDATE_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_ROUTE_ACTIVATION_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_ROUTE_BINDING_PAYLOAD_SCHEMA_VERSION, CAPABILITY_ROUTE_EVENT_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_ROUTE_ROLLBACK_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_SHADOW_TRIAL_DECISION_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_SHADOW_TRIAL_REQUEST_PAYLOAD_SCHEMA_VERSION,
    CAPABILITY_SHADOW_TRIAL_RUN_PAYLOAD_SCHEMA_VERSION,
};
pub(crate) use context_control_definitions::{
    CONTEXT_CONTROL_ACTION_PAYLOAD_SCHEMA_VERSION, CONTEXT_CONTROL_EPOCH_PAYLOAD_SCHEMA_VERSION,
    CONTEXT_CONTROL_SNAPSHOT_PAYLOAD_SCHEMA_VERSION, CONTEXT_EXCLUSION_PAYLOAD_SCHEMA_VERSION,
    CONTEXT_POLICY_SNAPSHOT_PAYLOAD_SCHEMA_VERSION, CONTEXT_SURVIVOR_PAYLOAD_SCHEMA_VERSION,
};
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
pub(crate) use module_runtime_definitions::MODULE_RUNTIME_STATE_PAYLOAD_SCHEMA_VERSION;
pub(crate) use module_validation_definitions::MODULE_VALIDATION_REPORT_PAYLOAD_SCHEMA_VERSION;
pub use store::{InMemoryEngineResourceStore, SqliteEngineResourceStore};
pub use types::*;
pub(crate) use ui_surface::validate_ui_surface_payload;
pub(crate) use web_research_definitions::{
    WEB_RESEARCH_REQUEST_PAYLOAD_SCHEMA_VERSION, WEB_RESEARCH_REVIEW_PAYLOAD_SCHEMA_VERSION,
    WEB_RESEARCH_SOURCE_PAYLOAD_SCHEMA_VERSION,
};
