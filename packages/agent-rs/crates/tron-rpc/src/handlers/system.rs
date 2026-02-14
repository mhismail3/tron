//! System handlers: ping, getInfo, shutdown.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::registry::MethodHandler;

/// Returns a pong with the current server timestamp.
pub struct PingHandler;

#[async_trait]
impl MethodHandler for PingHandler {
    #[instrument(skip(self, _ctx), fields(method = "system.info"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({
            "pong": true,
            "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        }))
    }
}

/// Returns server version, platform, and capability information.
pub struct GetInfoHandler;

#[async_trait]
impl MethodHandler for GetInfoHandler {
    #[instrument(skip(self, ctx), fields(method = "system.getInfo"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let uptime = ctx.server_start_time.elapsed().as_secs();
        let active_sessions = ctx.orchestrator.active_session_count();

        Ok(serde_json::json!({
            "version": env!("CARGO_PKG_VERSION"),
            "uptime": uptime,
            "activeSessions": active_sessions,
            "platform": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "runtime": "agent-rs",
        }))
    }
}

/// Triggers a graceful shutdown of all active sessions.
pub struct ShutdownHandler;

#[async_trait]
impl MethodHandler for ShutdownHandler {
    #[instrument(skip(self, ctx), fields(method = "system.shutdown"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        ctx.orchestrator
            .shutdown()
            .await
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;
        Ok(serde_json::json!({ "acknowledged": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;

    #[tokio::test]
    async fn ping_returns_pong() {
        let ctx = make_test_context();
        let result = PingHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert!(result["timestamp"].is_string());
    }

    #[tokio::test]
    async fn get_info_returns_version() {
        let ctx = make_test_context();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert!(result["version"].is_string());
        assert!(result["platform"].is_string());
        assert_eq!(result["runtime"], "agent-rs");
    }

    #[tokio::test]
    async fn get_info_returns_uptime() {
        let ctx = make_test_context();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        let uptime = result["uptime"].as_u64().unwrap();
        assert!(uptime < 5);
    }

    #[tokio::test]
    async fn get_info_returns_active_sessions() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["activeSessions"], 1);
    }

    #[tokio::test]
    async fn get_info_retains_extra_fields() {
        let ctx = make_test_context();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert!(result["platform"].is_string());
        assert!(result["arch"].is_string());
        assert_eq!(result["runtime"], "agent-rs");
    }

    #[tokio::test]
    async fn shutdown_acknowledged() {
        let ctx = make_test_context();
        let result = ShutdownHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn shutdown_ends_active_sessions() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();
        assert_eq!(ctx.session_manager.active_count(), 1);

        let _ = ShutdownHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(ctx.session_manager.active_count(), 0);
    }

    #[tokio::test]
    async fn ping_timestamp_is_iso8601() {
        let ctx = make_test_context();
        let result = PingHandler.handle(None, &ctx).await.unwrap();
        let ts = result["timestamp"].as_str().unwrap();
        assert!(ts.contains('T'));
        assert!(ts.ends_with('Z'));
    }
}
