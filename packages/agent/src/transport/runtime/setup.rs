//! Thin startup entrypoint for server-owned engine domain registration.
//!
//! Transport setup delegates to `domains::registration` so the client
//! protocol layer does not know individual domain workers, hidden apply
//! functions, or capability worker internals. Domain lifecycle tasks activate
//! only after canonical domain registration succeeds.

use crate::engine::Result as EngineResult;
use crate::shared::server::context::ServerRuntimeContext;

/// Register server-owned domain workers and canonical functions
/// for single-threaded setup/test contexts.
pub fn register_server_domains_for_context(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    let activation = crate::domains::registration::register_domain_workers_for_context(ctx)?;
    activation.activate();
    Ok(())
}

/// Register server-owned domain workers and canonical functions
/// during async server startup.
pub async fn register_server_domains_for_runtime_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<()> {
    let activation =
        crate::domains::registration::register_domain_workers_for_runtime_context(ctx).await?;
    activation.activate();
    Ok(())
}
