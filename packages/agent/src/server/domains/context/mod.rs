//! context domain worker.
//!
//! This module owns canonical function execution for the context namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Snapshot, audit, compaction, and clear operation bindings live in
//! `operations/`; query/command services take the narrowed context deps.

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
            "context",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod commands;
pub(crate) mod queries;
pub(crate) mod service;
