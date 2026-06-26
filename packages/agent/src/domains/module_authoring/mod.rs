//! Inert module proposal authoring workspace foundation.
//!
//! Module authoring owns durable `module_proposal` resources for autonomous
//! agents to draft bounded proposals in current session/workspace scope. The
//! provider-visible surface is limited to `capability::execute` operations
//! `module_proposal_record`, `module_proposal_list`, and
//! `module_proposal_inspect`. Proposals are metadata-only, resource-backed, and
//! intentionally non-installable/non-executable.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Module-authoring/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe proposal projections |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Text, ref, lifecycle, idempotency, and unsafe-field checks |
//! | `tests` | Schema, authority, replay, redaction, and side-effect regressions |
//!
//! # INVARIANT: proposals do not become installed modules
//!
//! This domain stores proposal metadata only. It must not create a physical
//! module workspace directory, install dependencies, run commands, execute code,
//! touch repo-managed `packages/agent/skills`, access networks, inject prompts,
//! or expose raw proposal bodies. Later gates own validation reports, install
//! review, activation, execution, and UI.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
pub(crate) mod contract;
mod projection;
pub(crate) mod service;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) use crate::engine::{MODULE_PROPOSAL_KIND, MODULE_PROPOSAL_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::MODULE_AUTHORING_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
