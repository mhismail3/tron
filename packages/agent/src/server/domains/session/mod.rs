//! session domain worker.
//!
//! This module owns canonical function execution for the session namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Lifecycle, history, reconstruction, archive/delete, and export operation
//! bodies live in `operations/`; command/query/reconstruct services remain
//! nearby and take the narrowed `SessionDeps` bundle.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        super::domain_worker_module(
            "session",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod commands;
pub mod context;
pub(crate) mod queries;
pub(crate) mod reconstruct;
