//! Metadata-only module lifecycle state.
//!
//! Module lifecycle owns durable `module_lifecycle_state` resources for
//! metadata-only enable, disable, quarantine, and rollback transitions after a
//! current-scope `module_install_decision` has reached `install_candidate`.
//! Follow-up requests reuse the scoped lifecycle resource and append a new
//! current-version-guarded pending transition instead of creating parallel
//! state or silently returning stale lifecycle metadata.
//! The provider-visible surface is limited to `capability::execute` operations
//! `module_lifecycle_request`, `module_lifecycle_decision`,
//! `module_lifecycle_list`, and `module_lifecycle_inspect`.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Lifecycle/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `payload_safety` | Unsafe-field, path, prompt, command, and token-like payload denial |
//! | `prerequisite` | Current-scope install-candidate prerequisite checks |
//! | `projection` | Bounded provider-safe lifecycle projections |
//! | `records` | Metadata-only transition payload, idempotency, and proof builders |
//! | `resource_store` | Resource inspection, lifecycle stream, and kind/schema helpers |
//! | `service` | Timestamp-injected request/decision/list/inspect behavior |
//! | `validation` | Text, ref, approval, lifecycle, and bounded metadata checks |
//! | `tests` | Schema, authority, replay, approval, prerequisite, and redaction regressions |
//!
//! # INVARIANT: lifecycle is metadata state only
//!
//! This domain stores state transitions only. It must not install modules,
//! execute module code, restore dependencies, run package managers, create
//! physical module workspaces, access networks, touch repo-managed
//! `packages/agent/skills`, expose raw commands/logs/env/code/file contents,
//! or treat approval evidence as authority without a current derived runtime
//! grant. Disabled and quarantined states fail closed through
//! `ensure_runtime_allowed` so later runtime slices can consult this domain
//! without executing modules here.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod approval_gate;
mod authority;
pub(crate) mod contract;
mod payload_safety;
mod prerequisite;
mod projection;
mod records;
mod resource_store;
pub(crate) mod service;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) use crate::engine::{MODULE_LIFECYCLE_STATE_KIND, MODULE_LIFECYCLE_STATE_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::MODULE_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
