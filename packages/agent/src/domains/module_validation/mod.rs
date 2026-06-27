//! Inert module contract validation report foundation.
//!
//! Module validation owns durable `module_validation_report` resources for
//! bounded module contract-test harness evidence in current session/workspace
//! scope. The provider-visible surface is limited to `capability::execute`
//! operations `module_validation_record`, `module_validation_list`, and
//! `module_validation_inspect`. Reports are metadata-only, resource-backed, and
//! intentionally non-installable/non-executable. They store supplied refs,
//! fingerprints, parity checks, docs/tests evidence, command/result refs, and
//! failure evidence without running commands or module code.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Module-validation/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe validation report projections |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Text, ref, parity, evidence, idempotency, and unsafe-field checks |
//! | `tests` | Schema, authority, replay, redaction, and side-effect regressions |
//!
//! # INVARIANT: validation reports do not execute module code
//!
//! This domain stores validation evidence metadata only. It must not create a
//! physical module workspace directory, install dependencies, run commands,
//! execute code, touch repo-managed `packages/agent/skills`, access networks,
//! inject prompts, expose raw logs/commands/env/code/file contents, or leak
//! rejected raw payload material through trace records. Later gates own install
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

pub(crate) use crate::engine::{MODULE_VALIDATION_REPORT_KIND, MODULE_VALIDATION_REPORT_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::MODULE_VALIDATION_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
