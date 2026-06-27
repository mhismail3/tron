//! Generic module activity cockpit projection.
//!
//! Module activity owns no durable state. It aggregates existing module-plane
//! resource facts into a bounded, inspect-only cockpit projection for native
//! clients. The projection deliberately stays above package semantics: status
//! is derived from resource lifecycle and explicit metadata fields already
//! stored by module registry, proposal, validation, install, dependency,
//! lifecycle, and runtime domains.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | System-visible read-only cockpit projection contract |
//! | `projection` | Bounded redaction and status derivation from module resources |
//! | `service` | Resource list/inspect aggregation over existing module facts |
//! | `tests` | State derivation, redaction, registration, and source guards |
//!
//! # INVARIANT: cockpit activity is projection only
//!
//! This domain must not create, mutate, install, activate, execute, restore
//! dependencies, run package managers, access networks, mint approval evidence,
//! expose raw commands/logs/env/code/file contents, raw grant/authority ids,
//! raw trace/invocation ids, or touch repo-managed `packages/agent/skills`.

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
