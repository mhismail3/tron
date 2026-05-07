//! MCP RPC group.
//!
//! The public `mcp.*` JSON-RPC methods are marker-registered in
//! `handlers::mod` and execute through canonical engine functions under
//! `mcp::*`. MCP server lifecycle changes update the live capability catalog
//! and publish status changes through engine streams; WebSocket remains only a
//! delivery transport for the existing `mcp.status_changed` event shape.

#[cfg(test)]
mod tests {
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::{RpcErrorBody, RpcRequest, RpcResponse};
    use serde_json::{Value, json};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn next_request_id(method: &str) -> String {
        static NEXT_ID: AtomicUsize = AtomicUsize::new(1);
        format!("{method}-{}", NEXT_ID.fetch_add(1, Ordering::SeqCst))
    }

    async fn dispatch_mcp_response(
        ctx: &RpcContext,
        method: &str,
        params: Option<Value>,
    ) -> RpcResponse {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        crate::server::rpc::engine_bridge::register_rpc_worker_for_context(ctx, &registry).unwrap();
        registry
            .dispatch(
                RpcRequest {
                    id: next_request_id(method),
                    method: method.to_owned(),
                    params,
                },
                ctx,
            )
            .await
    }

    async fn dispatch_mcp_ok(ctx: &RpcContext, method: &str, params: Option<Value>) -> Value {
        let response = dispatch_mcp_response(ctx, method, params).await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_mcp_err(
        ctx: &RpcContext,
        method: &str,
        params: Option<Value>,
    ) -> RpcErrorBody {
        let response = dispatch_mcp_response(ctx, method, params).await;
        assert!(!response.success, "{method}: {:?}", response.result);
        response.error.unwrap()
    }

    #[tokio::test]
    async fn status_returns_error_when_no_router() {
        let ctx = make_test_context();
        let error = dispatch_mcp_err(&ctx, "mcp.status", Some(json!({}))).await;
        assert_eq!(error.message, "Internal error");
    }

    #[tokio::test]
    async fn add_server_returns_error_when_no_router() {
        let ctx = make_test_context();
        let error = dispatch_mcp_err(
            &ctx,
            "mcp.addServer",
            Some(json!({"name": "test", "command": "echo"})),
        )
        .await;
        assert_eq!(error.message, "Internal error");
    }

    #[tokio::test]
    async fn reload_returns_error_when_no_router() {
        let ctx = make_test_context();
        let error = dispatch_mcp_err(&ctx, "mcp.reload", Some(json!({}))).await;
        assert_eq!(error.message, "Internal error");
    }

    #[tokio::test]
    async fn status_with_empty_router() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).unwrap();
        let settings_path = home
            .join(crate::core::paths::dirs::PROFILES)
            .join(crate::core::profile::USER_PROFILE)
            .join(crate::core::paths::files::PROFILE_TOML);
        let router = crate::mcp::router::McpRouter::new(Vec::new(), settings_path, 0).await;
        let mut ctx = make_test_context();
        ctx.mcp_router = Some(Arc::new(tokio::sync::RwLock::new(router)));

        let result = dispatch_mcp_ok(&ctx, "mcp.status", Some(json!({}))).await;
        assert!(result.as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_tools_with_empty_router() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).unwrap();
        let settings_path = home
            .join(crate::core::paths::dirs::PROFILES)
            .join(crate::core::profile::USER_PROFILE)
            .join(crate::core::paths::files::PROFILE_TOML);
        let router = crate::mcp::router::McpRouter::new(Vec::new(), settings_path, 0).await;
        let mut ctx = make_test_context();
        ctx.mcp_router = Some(Arc::new(tokio::sync::RwLock::new(router)));

        let result = dispatch_mcp_ok(&ctx, "mcp.listTools", Some(json!({}))).await;
        assert!(result.as_array().unwrap().is_empty());
    }
}
