//! Domain-specific dependency bundle for the mcp worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) mcp_router: Option<Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            mcp_router: deps.mcp_router.clone(),
        }
    }
}
