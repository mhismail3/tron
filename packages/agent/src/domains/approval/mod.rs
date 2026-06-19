//! Approval and freshness evidence domain.
//!
//! This worker owns durable approval request and decision resources plus a
//! reusable fail-closed check path. Approval records are evidence gates: they
//! never mint authority, widen grants, or replace the engine authority store.
//! Future filesystem, jobs, git, web, memory, subagent, and scheduling packages
//! should consume this contract instead of adding private approval prompts.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Request, decision, and check capability contracts |
//! | `errors` | Domain-local error helpers |
//! | `handlers` | Operation binding table |
//! | `service` | Resource creation, decision recording, and checks |
//! | `support` | Payload parsing, lifecycle-stream, idempotency, and resource-ref helpers |
//! | `types` | Serializable request/decision/check records |
//!
//! # INVARIANT: approval is not authority
//!
//! An approved decision can satisfy a freshness/evidence requirement selected
//! by a future package, but execution permission still comes from existing
//! authority grants resolved by the engine host before handlers run.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod errors;
mod explanation;
mod handlers;
pub(crate) mod service;
mod support;
pub(crate) mod types;

pub(crate) const WORKER: &str = "approval";
pub(crate) const APPROVAL_LIFECYCLE_TOPIC: &str = "approval.lifecycle";
pub(crate) const READ_SCOPE: &str = "approval.read";
pub(crate) const WRITE_SCOPE: &str = "approval.write";

pub(crate) const APPROVAL_REQUEST_KIND: &str = "approval_request";
pub(crate) const APPROVAL_REQUEST_SCHEMA_ID: &str = "tron.resource.approval_request.v1";
pub(crate) const APPROVAL_DECISION_KIND: &str = "approval_decision";
pub(crate) const APPROVAL_DECISION_SCHEMA_ID: &str = "tron.resource.approval_decision.v1";

pub(crate) const REQUEST_FUNCTION: &str = "approval::request";
pub(crate) const DECIDE_FUNCTION: &str = "approval::decide";
pub(crate) const CHECK_FUNCTION: &str = "approval::check";

/// Approval dependencies narrowed from server setup.
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

/// Build the domain worker registration.
pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[APPROVAL_LIFECYCLE_TOPIC],
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
