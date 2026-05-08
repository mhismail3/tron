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
pub(crate) mod operations;
pub(crate) use deps::Deps;
pub(crate) use operations::register_builtin_tools_for_setup;

use crate::server::domains::worker::DomainRegistrationContext;
use crate::server::domains::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::server::domains::worker::domain_worker_module(
            "tool",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod interactive_enrichment;
