//! Capability binding policy, shadow-trial custody, and scoped route control.
//!
//! Capability binding owns durable `capability_binding_request`,
//! `capability_binding_decision`, `capability_binding_policy`, and
//! `capability_shadow_trial_*` resources for capability replacement governance.
//! It also owns the governed route records that activate, disable, and roll
//! back scoped replacements. The first runtime route is deliberately narrow:
//! read-only `git_status` can be routed only after validated candidate,
//! shadow-trial, activation, rollback, exact-scope, and cockpit evidence
//! records exist. It does not hot-swap modules, activate packages, mutate
//! dispatch, restore dependencies, run package managers, or access networks.
//!
//! The provider-visible surface is limited to `capability::execute` operations
//! `capability_binding_request_record`, `capability_binding_request_list`,
//! `capability_binding_request_inspect`, `capability_binding_decision_record`,
//! `capability_binding_decision_list`, `capability_binding_decision_inspect`,
//! `capability_binding_policy_activate`, `capability_binding_policy_list`, and
//! `capability_binding_policy_inspect`, plus
//! `capability_binding_cockpit_overview`, plus
//! `capability_shadow_trial_request_record`,
//! `capability_shadow_trial_decision_record`,
//! `capability_shadow_trial_run_record`, and
//! `capability_shadow_trial_evidence_inspect`, plus
//! `capability_replacement_candidate_*`, `capability_route_binding_*`,
//! `capability_route_activate`, `capability_route_disable`,
//! `capability_route_rollback`, and `capability_route_event_*`. Native cockpit
//! clients also get one read-only `capability_binding::cockpit_overview`
//! projection; `capability_binding_cockpit_overview` delegates to the same
//! server-owned projection so native UI and model-facing capability inspection
//! share one source of truth. The projection accepts an exact `targetOperation`
//! filter so agents can inspect one operation's role, readiness, safe read-only
//! path, unavailable surfaces, and any exact follow-up evidence-inspect payloads
//! without scanning the whole operation pool. The durable projection can include
//! the complete operation set for UI/audit, while provider replay receives only
//! a bounded digest with coverage counts, family summaries, and representative
//! operation samples. The projection summarizes total/returned operations, list
//! and bounded resource-scan completeness, redacted operation ownership,
//! replacement target, readiness, and scoped binding/shadow-trial/route state.
//! Broad overview rows do not expose raw resource ids; targeted rows may expose
//! bounded exact shadow-evidence inspect payloads when that is the only
//! deterministic next step for the agent. The `capability_binding` domain owns
//! the projection, not the operations being described. Targeted rows also carry
//! a final-answer-ready readiness verdict, the read-only boundary that explains
//! engine audit persistence, and exact governed next-step operation names so
//! agents do not infer replacement workflows from broad catalog matches.
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
//! | `route` | Governed route candidate, binding, activation, event, rollback, and resolver logic |
//! | `service` | Timestamp-injected record/list/inspect/activate behavior |
//! | `shadow_trial` | Metadata-only governed `git_status` shadow trial records and evidence comparison |
//! | `validation` | Text, ref, registry-derived target metadata, binding-mode, authority, and stale-guard checks |
//! | `tests` | Schema, authority, replay, stale guard, locked-class, shadow-trial, and no-routing regressions |
//!
//! # INVARIANT: routing is governed, scoped, and reversible
//!
//! This domain stores review, policy, shadow, and route metadata, and it owns
//! route resolution for explicitly supported adapter replacements. It must not
//! install or activate modules, restore dependencies, run package managers,
//! mutate manifests, create physical workspaces, access networks, touch
//! repo-managed `packages/agent/skills`, expose raw commands/logs/env/code/file
//! contents, or return raw grant/authority ids. Target operation owner/class
//! metadata is derived from the server-owned execute registry; caller-supplied
//! owner/class assertions must match it. `kernel_locked` and
//! `governance_locked` operations cannot request or activate replacement.
//! Cockpit visibility follows a fail-closed rule: if operation-list limits or
//! bounded resource scans make the projection partial, it reports
//! truncation/degraded scan state instead of presenting lower-bound facts as
//! complete.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
mod cockpit_visibility;
pub(crate) mod contract;
mod payload_safety;
mod projection;
mod records;
mod resource_store;
pub(crate) mod route;
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
    CAPABILITY_REPLACEMENT_CANDIDATE_KIND, CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_ID,
    CAPABILITY_ROUTE_ACTIVATION_KIND, CAPABILITY_ROUTE_ACTIVATION_SCHEMA_ID,
    CAPABILITY_ROUTE_BINDING_KIND, CAPABILITY_ROUTE_BINDING_SCHEMA_ID, CAPABILITY_ROUTE_EVENT_KIND,
    CAPABILITY_ROUTE_EVENT_SCHEMA_ID, CAPABILITY_ROUTE_ROLLBACK_KIND,
    CAPABILITY_ROUTE_ROLLBACK_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
    CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
    CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_RUN_KIND,
    CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID,
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
