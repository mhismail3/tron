//! Thin startup entrypoint for server-owned engine domain registration.
//!
//! Transport setup delegates to `domains::registration` so the client
//! protocol layer does not know individual domain workers, hidden apply
//! functions, or capability worker internals.

use crate::engine::Result as EngineResult;
use crate::shared::server::context::ServerRuntimeContext;

/// Register server-owned domain workers, canonical functions, and trigger types
/// for single-threaded setup/test contexts.
pub fn register_server_domains_for_context(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    crate::domains::registration::register_domain_workers_for_context(ctx)?;
    crate::transport::engine::contracts::register_engine_transport_triggers_for_context(ctx)
}

/// Register server-owned domain workers, canonical functions, and trigger types
/// during async server startup.
pub async fn register_server_domains_for_runtime_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<()> {
    crate::domains::registration::register_domain_workers_for_runtime_context(ctx).await?;
    crate::transport::engine::contracts::register_engine_transport_triggers_for_runtime_context(ctx)
        .await
}
