//! Metadata-only capability binding policy and shadow-trial custody.
//!
//! Capability binding owns durable `capability_binding_request`,
//! `capability_binding_decision`, `capability_binding_policy`, and
//! `capability_shadow_trial_*` resources for future capability replacement
//! governance. It records who asked to shadow, extend, or replace one
//! `capability::execute` operation, what evidence and authority constraints are
//! required, what decision was made, what metadata-only policy exists for later
//! slices, and the first bounded `git_status` shadow replacement trial. It does
//! not route execution, hot-swap modules, activate packages, or change dispatch.
//!
//! The provider-visible surface is limited to `capability::execute` operations
//! `capability_binding_request_record`, `capability_binding_request_list`,
//! `capability_binding_request_inspect`, `capability_binding_decision_record`,
//! `capability_binding_decision_list`, `capability_binding_decision_inspect`,
//! `capability_binding_policy_activate`, `capability_binding_policy_list`, and
//! `capability_binding_policy_inspect`, plus
//! `capability_shadow_trial_request_record`,
//! `capability_shadow_trial_decision_record`,
//! `capability_shadow_trial_run_record`, and
//! `capability_shadow_trial_evidence_inspect`. Native cockpit clients also get
//! one read-only `capability_binding::cockpit_overview` projection that
//! summarizes total/returned operations, list and bounded resource-scan
//! completeness, redacted operation ownership, replacement target, readiness,
//! and scoped binding/shadow-trial state without exposing raw resource ids or
//! changing routing. The `capability_binding` domain owns the projection, not
//! the operations being described.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Binding/resource grant and exact selector checks |
//! | `cockpit_visibility` | Redacted Engine Cockpit projection over registry metadata and binding records |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `payload_safety` | Unsafe-field, path, prompt, command, and token denial |
//! | `projection` | Bounded provider-safe request, decision, and policy projections |
//! | `records` | Metadata-only payload, idempotency, audit, and side-effect proof builders |
//! | `resource_store` | Resource inspection, lifecycle stream, kind/schema helpers |
//! | `service` | Timestamp-injected record/list/inspect/activate behavior |
//! | `shadow_trial` | Metadata-only governed `git_status` shadow trial records and evidence comparison |
//! | `validation` | Text, ref, registry-derived target metadata, binding-mode, authority, and stale-guard checks |
//! | `tests` | Schema, authority, replay, stale guard, locked-class, shadow-trial, and no-routing regressions |
//!
//! # INVARIANT: binding policy is governance metadata only
//!
//! This domain stores review and policy metadata only. It must not route
//! `capability::execute`, install or activate modules, execute module code,
//! restore dependencies, run package managers, mutate manifests, create
//! physical workspaces, access networks, touch repo-managed
//! `packages/agent/skills`, expose raw commands/logs/env/code/file contents,
//! or return raw grant/authority ids. Target operation owner/class metadata is
//! derived from the server-owned execute registry; caller-supplied owner/class
//! assertions must match it. `kernel_locked` and `governance_locked` operations
//! cannot request `replace`; `adapter_replaceable` and `module_owned` requests
//! are accepted only as strict metadata proposals with runtime routing disabled
//! in this slice.
//! Shadow trials are narrower: this slice accepts only the read-only
//! `git_status` target and stores deterministic candidate-adapter descriptions
//! and provider-safe projections for comparison. It never executes candidate
//! module code or changes live operation routing. Cockpit visibility follows
//! the same fail-closed rule: if operation-list limits or bounded resource
//! scans make the projection partial, it reports truncation/degraded scan state
//! instead of presenting lower-bound facts as complete.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
mod cockpit_visibility;
pub(crate) mod contract;
mod payload_safety;
mod projection;
mod records;
mod resource_store;
pub(crate) mod service;
pub(crate) mod shadow_trial;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
        }
    }
}

pub(crate) use crate::engine::{
    CAPABILITY_BINDING_DECISION_KIND, CAPABILITY_BINDING_DECISION_SCHEMA_ID,
    CAPABILITY_BINDING_POLICY_KIND, CAPABILITY_BINDING_POLICY_SCHEMA_ID,
    CAPABILITY_BINDING_REQUEST_KIND, CAPABILITY_BINDING_REQUEST_SCHEMA_ID,
    CAPABILITY_SHADOW_TRIAL_DECISION_KIND, CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND, CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID,
    CAPABILITY_SHADOW_TRIAL_REQUEST_KIND, CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID,
    CAPABILITY_SHADOW_TRIAL_RUN_KIND, CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID,
};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::CAPABILITY_BINDING_LIFECYCLE_TOPIC],
        service::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
