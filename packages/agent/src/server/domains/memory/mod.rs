//! memory domain worker.
//!
//! This module owns canonical function execution for the memory namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! The `memory::retain` and hidden `memory::auto_retain_fire` operation bodies
//! live in `operations/`; summarization, persistence, and auto-retain policy
//! remain in the `retain` service tree.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;

use crate::server::domains::worker::DomainRegistrationContext;
use crate::server::domains::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::server::domains::worker::domain_worker_module(
            "memory",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod retain;
