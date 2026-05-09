//! context domain worker.
//!
//! This module owns canonical function execution for the context namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Snapshot, audit, compaction, and clear operation bindings live in
//! `operations/`; query/command services take the narrowed context deps.
//! `queries/` is split into snapshot rendering, audit trace loading, payload
//! preview redaction, and context-manager preparation so read paths can be
//! followed without a central query blob.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "context",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod commands;
pub(crate) mod queries;
pub(crate) mod service;
