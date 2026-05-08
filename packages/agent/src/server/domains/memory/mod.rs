//! memory domain worker.
//!
//! This module owns canonical function execution for the memory namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! The `memory::retain` operation body lives in `operations/`; summarization,
//! persistence, and auto-retain policy remain in the `retain` service tree.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "memory",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::memory_handler,
    )
}

pub(crate) mod retain;
