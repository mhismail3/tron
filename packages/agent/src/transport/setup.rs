//! Thin startup hook for server-owned engine domain registration.
//!
//! Transport setup delegates to `domains::registration` so the client
//! protocol layer does not know individual domain workers, hidden apply
//! functions, or tool worker internals.

use crate::engine::Result as EngineResult;
use crate::shared::server::context::ServerRuntimeContext;

/// Register server-owned domain workers, canonical functions, and trigger types.
pub fn register_server_domains_for_context(ctx: &ServerRuntimeContext) -> EngineResult<()> {
    crate::domains::registration::register_domain_workers_for_context(ctx)?;
    crate::transport::contracts::register_engine_transport_triggers_for_context(ctx)
}
