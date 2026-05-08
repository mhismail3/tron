//! auth domain worker.
//!
//! This module owns canonical function execution for the auth namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Credential reads/writes, OAuth flow mutation, account selection, and auth
//! stream publication live in `operations/`; this root only registers the auth
//! worker and exposes the OAuth flow module.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) mod stream;
pub(crate) use deps::Deps;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        super::domain_worker_module(
            "auth",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod flows;
