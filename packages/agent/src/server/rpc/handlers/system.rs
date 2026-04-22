//! System handlers: ping, getInfo, shutdown.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{CLIENT_VERSION_UNSUPPORTED, RpcError};
use crate::server::rpc::registry::MethodHandler;

/// Current RPC wire-protocol version.
///
/// Bumped only on breaking changes — fields that old clients can
/// silently ignore do not bump this. The current version is documented
/// in the iOS client's handshake and any value `>= MIN_CLIENT_PROTOCOL_VERSION`
/// is accepted.
pub const CURRENT_PROTOCOL_VERSION: u32 = 1;

/// Minimum `protocolVersion` the server will accept from a client that
/// explicitly advertises one. Clients that omit `protocolVersion` are
/// treated as pre-handshake and accepted — this is the backward-compat
/// path for the legacy iOS builds that existed before L6 landed.
pub const MIN_CLIENT_PROTOCOL_VERSION: u32 = 1;

/// Returns a pong with the current server timestamp.
///
/// When the client sends `{ protocolVersion, clientVersion? }`, the
/// handler also performs a compatibility check:
/// - `protocolVersion < MIN_CLIENT_PROTOCOL_VERSION` →
///   [`RpcError::Custom`] with code [`CLIENT_VERSION_UNSUPPORTED`] and
///   details pointing the client at the upgrade path.
/// - `protocolVersion >= MIN_CLIENT_PROTOCOL_VERSION` → success reply
///   that echoes the server's protocol version so a future client can
///   feature-gate on it.
/// - No params / no `protocolVersion` → backward-compatible reply (no
///   version fields required, no error).
pub struct PingHandler;

#[async_trait]
impl MethodHandler for PingHandler {
    #[instrument(skip(self, _ctx), fields(method = "system.ping"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let client_protocol = params
            .as_ref()
            .and_then(|p| p.get("protocolVersion"))
            .and_then(Value::as_u64)
            .map(|v| v as u32);
        let client_version = params
            .as_ref()
            .and_then(|p| p.get("clientVersion"))
            .and_then(Value::as_str)
            .map(String::from);

        if let Some(v) = client_protocol
            && v < MIN_CLIENT_PROTOCOL_VERSION
        {
            // Explicit rejection with an actionable message. Details
            // carry the numeric versions so the iOS UI can render an
            // "upgrade required" dialog with the exact numbers.
            return Err(RpcError::Custom {
                code: CLIENT_VERSION_UNSUPPORTED.to_string(),
                message: format!(
                    "Client protocol version {v} is below the minimum supported version \
                     {MIN_CLIENT_PROTOCOL_VERSION}. Please upgrade the Tron client."
                ),
                details: Some(serde_json::json!({
                    "clientProtocolVersion": v,
                    "minClientProtocolVersion": MIN_CLIENT_PROTOCOL_VERSION,
                    "serverProtocolVersion": CURRENT_PROTOCOL_VERSION,
                    "serverVersion": env!("CARGO_PKG_VERSION"),
                    "clientVersion": client_version,
                })),
            });
        }

        Ok(serde_json::json!({
            "pong": true,
            "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            "serverVersion": env!("CARGO_PKG_VERSION"),
            "serverProtocolVersion": CURRENT_PROTOCOL_VERSION,
            "minClientProtocolVersion": MIN_CLIENT_PROTOCOL_VERSION,
            "compatible": true,
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
            "runtime": "agent",
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
    use crate::server::rpc::handlers::test_helpers::make_test_context;

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
        assert_eq!(result["runtime"], "agent");
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
            .create_session("m", "/tmp", Some("t"), None)
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
        assert_eq!(result["runtime"], "agent");
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
            .create_session("model", "/tmp", Some("test"), None)
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

    // ── L6: version handshake ──────────────────────────────────────

    /// Legacy clients (pre-L6) that don't advertise a protocol version
    /// must still succeed — otherwise we brick the field devices.
    #[tokio::test]
    async fn ping_without_protocol_version_is_accepted() {
        let ctx = make_test_context();
        let result = PingHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
        assert_eq!(
            result["serverProtocolVersion"].as_u64().unwrap(),
            u64::from(CURRENT_PROTOCOL_VERSION),
        );
    }

    /// Stale client that explicitly advertises a too-old protocol
    /// version must be rejected with CLIENT_VERSION_UNSUPPORTED and
    /// details that name both versions so the iOS UI can render an
    /// actionable upgrade prompt.
    #[tokio::test]
    async fn stale_client_rejected_with_clear_error() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": 0u32,
            "clientVersion": "0.0.1-legacy",
        });
        let err = PingHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), CLIENT_VERSION_UNSUPPORTED);

        let body = err.to_error_body();
        assert_eq!(body.code, CLIENT_VERSION_UNSUPPORTED);
        let details = body.details.expect("details must be present");
        assert_eq!(details["clientProtocolVersion"].as_u64().unwrap(), 0);
        assert_eq!(
            details["minClientProtocolVersion"].as_u64().unwrap(),
            u64::from(MIN_CLIENT_PROTOCOL_VERSION),
        );
        assert_eq!(
            details["serverProtocolVersion"].as_u64().unwrap(),
            u64::from(CURRENT_PROTOCOL_VERSION),
        );
        assert_eq!(details["clientVersion"], "0.0.1-legacy");

        // Human-readable message names both numbers.
        assert!(body.message.contains("0"));
        assert!(body.message.contains(&MIN_CLIENT_PROTOCOL_VERSION.to_string()));
        assert!(body.message.to_lowercase().contains("upgrade"));
    }

    /// Client advertising the current protocol version receives a
    /// successful pong with `compatible: true` and the echoed protocol
    /// numbers so it can feature-gate on them.
    #[tokio::test]
    async fn current_client_accepted_with_version_echo() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": CURRENT_PROTOCOL_VERSION,
            "clientVersion": "1.2.3",
        });
        let result = PingHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
        assert_eq!(
            result["serverProtocolVersion"].as_u64().unwrap(),
            u64::from(CURRENT_PROTOCOL_VERSION),
        );
        assert_eq!(
            result["minClientProtocolVersion"].as_u64().unwrap(),
            u64::from(MIN_CLIENT_PROTOCOL_VERSION),
        );
    }

    /// Clients from the future (higher protocol version than the
    /// server) are still accepted — the server degrades gracefully and
    /// expects the client to feature-gate on `serverProtocolVersion`.
    /// If we rejected them, rolling out a newer iOS build before the
    /// server would brick everyone.
    #[tokio::test]
    async fn future_client_is_accepted_gracefully() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": CURRENT_PROTOCOL_VERSION + 42,
            "clientVersion": "99.0.0",
        });
        let result = PingHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
    }

    /// A client that sends garbage in `protocolVersion` (wrong type) is
    /// treated as if the field were absent — backward-compatible fail-
    /// open, not an outright rejection. The client's subsequent RPCs
    /// will fail the first time they hit a breaking change; the ping
    /// itself should not be the gate for every typo.
    #[tokio::test]
    async fn malformed_protocol_version_does_not_panic_and_accepts() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": "not a number",
        });
        let result = PingHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
    }
}
