//! Metadata-only module dependency request and policy custody.
//!
//! Module dependencies owns durable `module_dependency_request`,
//! `module_dependency_decision`, and `module_dependency_policy` resources for
//! recording dependency needs, review decisions, and approved metadata policy
//! activation. The provider-visible surface is limited to `capability::execute`
//! operations `module_dependency_request_record`,
//! `module_dependency_request_list`, `module_dependency_request_inspect`,
//! `module_dependency_decision_record`, `module_dependency_decision_list`,
//! `module_dependency_decision_inspect`, `module_dependency_policy_activate`,
//! `module_dependency_policy_list`, and `module_dependency_policy_inspect`.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Module-dependency/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `payload_safety` | Unsafe-field, path, prompt, command, artifact, and token denial |
//! | `projection` | Bounded provider-safe request, decision, and policy projections |
//! | `records` | Metadata-only payload, idempotency, and side-effect proof builders |
//! | `resource_store` | Resource inspection, lifecycle stream, kind/schema helpers |
//! | `service` | Timestamp-injected record/list/inspect/activate behavior |
//! | `validation` | Text, ref, risk, parity, review, and bounded metadata checks |
//! | `tests` | Schema, authority, replay, parity, denial, and redaction regressions |
//!
//! # INVARIANT: policy activation is metadata only
//!
//! This domain never restores, installs, resolves, downloads, or executes
//! dependencies. It does not mutate `Cargo.toml`, `Cargo.lock`, package
//! manifests, repo-managed `packages/agent/skills`, runtime files, or network
//! state. Policy activation means an approved bounded metadata policy is
//! available for later module-pack/runtime work under `networkPolicy: none`.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
pub(crate) mod contract;
mod payload_safety;
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
    MODULE_DEPENDENCY_DECISION_KIND, MODULE_DEPENDENCY_DECISION_SCHEMA_ID,
    MODULE_DEPENDENCY_POLICY_KIND, MODULE_DEPENDENCY_POLICY_SCHEMA_ID,
    MODULE_DEPENDENCY_REQUEST_KIND, MODULE_DEPENDENCY_REQUEST_SCHEMA_ID,
};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::MODULE_DEPENDENCY_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
