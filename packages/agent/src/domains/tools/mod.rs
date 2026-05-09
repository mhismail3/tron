//! tools domain worker.
//!
//! This module owns canonical function execution for the tools namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Built-in tool registration, result delivery, and concrete tool invocation
//! handlers live in `operations/`; model-facing schemas are projected from the
//! live engine catalog.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod implementations;
pub(crate) mod operations;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        let mut registrations =
            handlers::function_registrations(contract::capabilities()?, domain_deps)?;
        registrations.extend(operations::builtin_function_registrations(deps)?);
        crate::domains::worker::domain_worker_module("tool", contract::STREAM_TOPICS, registrations)
    }
}

pub(crate) mod interactive_enrichment;
