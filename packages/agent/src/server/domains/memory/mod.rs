//! memory domain worker.
//!
//! This module owns canonical function execution for the memory namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
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

use crate::server::domains::memory::retain as memory_retain;

async fn retain_value(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    memory_retain::trigger_manual_retain(Some(payload), &deps.server_context).await
}
