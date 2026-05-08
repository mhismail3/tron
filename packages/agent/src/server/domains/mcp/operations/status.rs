//! MCP workflow operations.
use super::*;

pub(crate) fn require_router(
    deps: &Deps,
) -> Result<&Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>, CapabilityError> {
    deps.mcp_router.as_ref().ok_or(CapabilityError::Internal {
        message: "MCP is not configured on this server".into(),
    })
}

pub(crate) async fn mcp_status_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let router = require_router(deps)?;
    let guard = router.read().await;
    let status = guard.status();
    serde_json::to_value(status).map_err(|e| CapabilityError::Internal {
        message: e.to_string(),
    })
}
