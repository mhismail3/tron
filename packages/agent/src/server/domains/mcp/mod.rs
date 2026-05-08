//! mcp domain worker.
//!
//! This module owns canonical function execution for the mcp namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Server lifecycle commands, status reads, tool catalog refresh, and MCP tool
//! function handlers live in `operations/`; product MCP protocol handling stays
//! in the MCP runtime layer.

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
        "mcp",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::mcp_handler,
    )
}
