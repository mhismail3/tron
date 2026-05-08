//! Thin startup hook for server-owned engine domain registration.
//!
//! Transport setup delegates to `server::domains::registration` so the client
//! protocol layer does not know individual domain workers, hidden apply
//! functions, or tool worker internals.

use crate::engine::Result as EngineResult;
use crate::server::shared::context::ServerCapabilityContext;

/// Register server-owned domain workers, canonical functions, and trigger types.
pub fn register_server_domains_for_context(ctx: &ServerCapabilityContext) -> EngineResult<()> {
    crate::server::domains::registration::register_domain_workers_for_context(ctx)
}
