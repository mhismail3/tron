//! mcp domain worker.
//!
//! This module owns canonical function execution for the mcp namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Server lifecycle commands, status reads, capability catalog refresh, and MCP tool
//! function handlers live in `operations/`; product MCP protocol handling stays
//! in the MCP runtime layer.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub mod product_protocol;
pub(crate) mod stream;
pub(crate) use deps::Deps;
pub use product_protocol::*;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "mcp",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}
