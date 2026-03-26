//! MCP management RPC handlers.
//!
//! Seven handlers for managing MCP server lifecycle via RPC:
//! status, addServer, removeServer, enableServer, disableServer, restartServer, reload.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::mcp::types::McpServerConfig;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::registry::MethodHandler;
use crate::server::rpc::types::RpcEvent;

use super::{require_string_param, opt_string, opt_bool};

/// Helper: require that the router is configured.
fn require_router(ctx: &RpcContext) -> Result<&std::sync::Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>, RpcError> {
    ctx.mcp_router.as_ref().ok_or(RpcError::Internal {
        message: "MCP is not configured on this server".into(),
    })
}

/// Broadcast an `mcp.status_changed` event with current server statuses.
pub(crate) async fn broadcast_status_changed(ctx: &RpcContext) {
    let Some(ref router_arc) = ctx.mcp_router else { return };
    let Some(ref bm) = ctx.broadcast_manager else { return };

    let router = router_arc.read().await;
    let status = router.status();
    let event = RpcEvent::new(
        "mcp.status_changed",
        None,
        Some(serde_json::to_value(status).unwrap_or_default()),
    );
    bm.broadcast_all(&event).await;
}

// ─── mcp.status ──────────────────────────────────────────────────────────

pub struct McpStatusHandler;

#[async_trait]
impl MethodHandler for McpStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "mcp.status"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let router = require_router(ctx)?;
        let guard = router.read().await;
        let status = guard.status();
        serde_json::to_value(status).map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })
    }
}

// ─── mcp.addServer ───────────────────────────────────────────────────────

pub struct McpAddServerHandler;

#[async_trait]
impl MethodHandler for McpAddServerHandler {
    #[instrument(skip(self, ctx), fields(method = "mcp.addServer"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let router = require_router(ctx)?.clone();
        let name = require_string_param(params.as_ref(), "name")?;
        let command = opt_string(params.as_ref(), "command");
        let url = opt_string(params.as_ref(), "url");
        let enabled = opt_bool(params.as_ref(), "enabled").unwrap_or(true);

        let args: Vec<String> = params.as_ref()
            .and_then(|p| p.get("args"))
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();

        let env: std::collections::HashMap<String, String> = params.as_ref()
            .and_then(|p| p.get("env"))
            .and_then(Value::as_object)
            .map(|obj| obj.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect())
            .unwrap_or_default();

        let config = McpServerConfig {
            name,
            command,
            args,
            env,
            url,
            tool_timeout_ms: 30_000,
            enabled,
        };

        let mut guard = router.write().await;
        let tool_count = guard.add_server(config).await.map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
        drop(guard);

        broadcast_status_changed(ctx).await;

        Ok(serde_json::json!({
            "success": true,
            "toolCount": tool_count,
        }))
    }
}

// ─── mcp.removeServer ────────────────────────────────────────────────────

pub struct McpRemoveServerHandler;

#[async_trait]
impl MethodHandler for McpRemoveServerHandler {
    #[instrument(skip(self, ctx), fields(method = "mcp.removeServer"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let router = require_router(ctx)?.clone();
        let name = require_string_param(params.as_ref(), "name")?;

        let mut guard = router.write().await;
        guard.remove_server(&name).await;
        drop(guard);

        broadcast_status_changed(ctx).await;

        Ok(serde_json::json!({ "success": true }))
    }
}

// ─── mcp.enableServer ────────────────────────────────────────────────────

pub struct McpEnableServerHandler;

#[async_trait]
impl MethodHandler for McpEnableServerHandler {
    #[instrument(skip(self, ctx), fields(method = "mcp.enableServer"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let router = require_router(ctx)?.clone();
        let name = require_string_param(params.as_ref(), "name")?;

        let mut guard = router.write().await;
        guard.enable_server(&name).await.map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
        drop(guard);

        broadcast_status_changed(ctx).await;

        Ok(serde_json::json!({ "success": true }))
    }
}

// ─── mcp.disableServer ───────────────────────────────────────────────────

pub struct McpDisableServerHandler;

#[async_trait]
impl MethodHandler for McpDisableServerHandler {
    #[instrument(skip(self, ctx), fields(method = "mcp.disableServer"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let router = require_router(ctx)?.clone();
        let name = require_string_param(params.as_ref(), "name")?;

        let mut guard = router.write().await;
        guard.disable_server(&name).await.map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
        drop(guard);

        broadcast_status_changed(ctx).await;

        Ok(serde_json::json!({ "success": true }))
    }
}

// ─── mcp.restartServer ───────────────────────────────────────────────────

pub struct McpRestartServerHandler;

#[async_trait]
impl MethodHandler for McpRestartServerHandler {
    #[instrument(skip(self, ctx), fields(method = "mcp.restartServer"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let router = require_router(ctx)?.clone();
        let name = require_string_param(params.as_ref(), "name")?;

        let mut guard = router.write().await;
        let tool_count = guard.restart_server(&name).await.map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
        drop(guard);

        broadcast_status_changed(ctx).await;

        Ok(serde_json::json!({
            "success": true,
            "toolCount": tool_count,
        }))
    }
}

// ─── mcp.reload ──────────────────────────────────────────────────────────

pub struct McpReloadHandler;

#[async_trait]
impl MethodHandler for McpReloadHandler {
    #[instrument(skip(self, ctx), fields(method = "mcp.reload"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let router = require_router(ctx)?.clone();

        let mut guard = router.write().await;
        let server_count = guard.reload_from_settings().await.map_err(|e| RpcError::Internal {
            message: e,
        })?;
        drop(guard);

        broadcast_status_changed(ctx).await;

        Ok(serde_json::json!({
            "success": true,
            "serverCount": server_count,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;

    #[tokio::test]
    async fn status_returns_error_when_no_router() {
        let ctx = make_test_context();
        let result = McpStatusHandler.handle(None, &ctx).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn add_server_returns_error_when_no_router() {
        let ctx = make_test_context();
        let params = Some(serde_json::json!({"name": "test", "command": "echo"}));
        let result = McpAddServerHandler.handle(params, &ctx).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn remove_server_returns_error_when_no_router() {
        let ctx = make_test_context();
        let params = Some(serde_json::json!({"name": "test"}));
        let result = McpRemoveServerHandler.handle(params, &ctx).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn reload_returns_error_when_no_router() {
        let ctx = make_test_context();
        let result = McpReloadHandler.handle(None, &ctx).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn status_with_empty_router() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");
        let router = crate::mcp::router::McpRouter::new(Vec::new(), settings_path).await;
        let mut ctx = make_test_context();
        ctx.mcp_router = Some(std::sync::Arc::new(tokio::sync::RwLock::new(router)));

        let result = McpStatusHandler.handle(None, &ctx).await.unwrap();
        assert!(result.as_array().unwrap().is_empty());
    }
}
