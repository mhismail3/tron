//! Agent briefing projection for dashboard and chief-of-staff sheets.
//!
//! Agent briefing owns no durable state and creates no autonomy behavior. It is
//! a narrow read-only projection over existing server-owned facts, starting with
//! the accepted `module_activity::overview` projection. The output is shaped for
//! native UI narrative sections rather than operator diagnostics, while keeping
//! exact session/workspace scope semantics and provider-safe redaction.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | System-visible read-only briefing contract |
//! | `projection` | Bounded narrative section projection from existing facts |
//! | `service` | Trusted-scope read aggregation over module activity truth |
//! | `tests` | Redaction, scoping, policy, and static guard regressions |
//!
//! # INVARIANT: briefing is projection only
//!
//! This domain must not create, mutate, install, activate, execute, schedule,
//! learn, compact, clear, or otherwise change agent behavior. It must not expose
//! raw paths, commands, logs, prompt bodies, secrets, grant ids, authority ids,
//! trace ids, invocation ids, or token-like material.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod projection;
mod service;

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

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[],
        service::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
