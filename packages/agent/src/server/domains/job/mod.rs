//! job domain worker.
//!
//! This module owns canonical function execution for the job namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Queue-backed start/cancel operations and hidden apply bodies live in
//! `operations/`; this root only registers the job worker.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) mod stream;
pub(crate) use deps::Deps;
pub(crate) use operations::hidden_function_registrations;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let mut module = {
        let domain_deps = Deps::from_engine(deps);
        super::domain_worker_module(
            "job",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }?;
    module
        .functions
        .extend(hidden_function_registrations(deps)?);
    Ok(module)
}
