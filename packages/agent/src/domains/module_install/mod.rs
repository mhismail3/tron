//! Metadata-only module install review gate.
//!
//! Module install owns durable `module_install_request` and
//! `module_install_decision` resources for the user-governed transition from a
//! passed `module_validation_report` into an install-candidate decision. The
//! provider-visible surface is limited to `capability::execute` operations
//! `module_install_request_record`, `module_install_request_list`,
//! `module_install_request_inspect`, `module_install_decision_record`,
//! `module_install_decision_list`, and `module_install_decision_inspect`.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `approval_gate` | Approval freshness and module-install decision authority checks |
//! | `authority` | Module-install/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `payload_safety` | Unsafe-field, path, prompt, command, and token-like payload denial |
//! | `prerequisite` | Current-scope passed `module_validation_report` prerequisite checks |
//! | `projection` | Bounded provider-safe request and decision projections |
//! | `records` | Metadata-only request/decision payload, idempotency, and proof builders |
//! | `resource_store` | Resource inspection, lifecycle stream, and kind/schema helpers |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Text, ref, approval, lifecycle, and bounded metadata checks |
//! | `tests` | Schema, authority, replay, approval, prerequisite, and redaction regressions |
//!
//! # INVARIANT: install candidates are metadata gate state only
//!
//! This domain stores review-gate metadata only. It must not install modules,
//! enable modules, execute module code, restore dependencies, run package
//! managers, create physical module workspaces, access networks, touch
//! repo-managed `packages/agent/skills`, expose raw commands/logs/env/code/file
//! contents, or treat approval evidence as authority without a current derived
//! runtime grant.

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

pub(crate) use crate::engine::{
    MODULE_INSTALL_DECISION_KIND, MODULE_INSTALL_DECISION_SCHEMA_ID, MODULE_INSTALL_REQUEST_KIND,
    MODULE_INSTALL_REQUEST_SCHEMA_ID,
};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::MODULE_INSTALL_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
