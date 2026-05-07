//! WebSocket message dispatch — parses incoming text as `RpcRequest` and
//! routes through the `MethodRegistry`.

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::registry::MethodRegistry;
use crate::server::rpc::types::{RpcRequest, RpcResponse};
use serde_json::json;
use tracing::{debug, instrument, warn};

/// Fallback JSON for when response serialization itself fails.
const SERIALIZATION_FALLBACK: &str = r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal serialization error"}}"#;

/// Result of handling a WebSocket message.
pub struct HandleResult {
    /// Serialized JSON response to send back.
    pub response_json: String,
    /// The RPC method that was called (empty if parse failed).
    pub method: String,
    /// Typed response (for extracting structured data without re-parsing).
    pub response: RpcResponse,
}

/// Handle an incoming WebSocket text message.
///
/// Parses the message as an `RpcRequest`, dispatches to the registry, and
/// returns the serialized `RpcResponse` along with the method name.
#[instrument(skip_all, fields(method, session_id))]
pub async fn handle_message(
    message: &str,
    registry: &MethodRegistry,
    ctx: &RpcContext,
) -> HandleResult {
    handle_message_with_transport(message, registry, ctx, None).await
}

/// Handle an incoming WebSocket message with a transport discriminator for
/// migration idempotency keys that need per-connection isolation.
#[instrument(skip_all, fields(method, session_id))]
pub async fn handle_message_with_transport(
    message: &str,
    registry: &MethodRegistry,
    ctx: &RpcContext,
    transport_id: Option<&str>,
) -> HandleResult {
    let mut request: RpcRequest = match serde_json::from_str(message) {
        Ok(r) => r,
        Err(e) => {
            warn!("invalid JSON received");
            let resp =
                RpcResponse::error("unknown", "INVALID_PARAMS", format!("Invalid JSON: {e}"));
            let json = serde_json::to_string(&resp).unwrap_or_else(|e| {
                tracing::error!(error = %e, "Failed to serialize error response");
                SERIALIZATION_FALLBACK.to_string()
            });
            return HandleResult {
                response_json: json,
                method: String::new(),
                response: resp,
            };
        }
    };

    attach_transport_context(&mut request, transport_id);
    let method = request.method.clone();
    let id = &request.id;
    let _ = tracing::Span::current().record("method", method.as_str());
    if let Some(sid) = request
        .params
        .as_ref()
        .and_then(|p| p.get("sessionId"))
        .and_then(|v| v.as_str())
    {
        let _ = tracing::Span::current().record("session_id", sid);
    }
    debug!(method, id, "dispatching RPC");

    if !registry.has_method(&method) {
        warn!(method, "unknown RPC method");
    }

    let response = registry.dispatch(request, ctx).await;
    let json = serde_json::to_string(&response).unwrap_or_else(|e| {
        tracing::error!(error = %e, "Failed to serialize response");
        SERIALIZATION_FALLBACK.to_string()
    });
    HandleResult {
        response_json: json,
        method,
        response,
    }
}

fn attach_transport_context(request: &mut RpcRequest, transport_id: Option<&str>) {
    let Some(transport_id) = transport_id else {
        return;
    };
    if request.method != "session.create" {
        return;
    }
    let payload = request.params.get_or_insert_with(|| json!({}));
    let Some(object) = payload.as_object_mut() else {
        return;
    };
    object.insert(
        "__rpcContext".to_owned(),
        json!({
            "transportId": transport_id,
        }),
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::events::EventStore;
    use crate::runtime::orchestrator::orchestrator::Orchestrator;
    use crate::runtime::orchestrator::session_manager::SessionManager;
    use serde_json::json;

    fn make_test_ctx() -> RpcContext {
        let pool =
            crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store.clone()));
        let orch = Arc::new(Orchestrator::new(mgr.clone()));
        let home = crate::server::rpc::test_support::unique_tron_home();
        let settings_path = crate::server::rpc::test_support::test_user_profile_path(&home);
        let profile_runtime = crate::server::rpc::test_support::test_profile_runtime(&home);
        let auth_path = crate::server::rpc::test_support::test_auth_path(&home);
        RpcContext {
            orchestrator: orch,
            session_manager: mgr,
            event_store: store,
            engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
            skill_registry: Arc::new(parking_lot::RwLock::new(
                crate::skills::registry::SkillRegistry::new(),
            )),
            memory_registry: Arc::new(parking_lot::Mutex::new(
                crate::runtime::memory::MemoryRegistry::new(),
            )),
            settings_path,
            profile_runtime,
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            transcription_engine: std::sync::Arc::new(std::sync::OnceLock::new()),
            subagent_manager: None,
            health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            codex_app_server: None,
            worktree_coordinator: None,
            device_request_broker: None,
            context_artifacts: Arc::new(
                crate::server::rpc::session_context::ContextArtifactsService::new(),
            ),
            auth_path,
            broadcast_manager: None,
            oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
            mcp_router: None,
            display_stream_registry: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            hook_abort_tracker: Arc::new(
                crate::runtime::hooks::abort_tracker::HookAbortTracker::new(),
            ),
            ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
            onboarded_marker_path: std::path::PathBuf::from("/tmp/tron-test-onboarded.marker"),
            release_fetcher: None,
            updater_state_path: std::path::PathBuf::from("/tmp/tron-test-updater-state.json"),
        }
    }

    fn registry_with_transport(ctx: &RpcContext) -> MethodRegistry {
        let mut reg = MethodRegistry::new();
        crate::server::rpc::bindings::register_all(&mut reg);
        crate::server::rpc::engine_bridge::register_rpc_worker_for_context(ctx, &reg).unwrap();
        reg
    }

    #[tokio::test]
    async fn valid_request_dispatches() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let msg = r#"{"id":"r1","method":"system.ping","params":{"protocolVersion":1}}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(resp.success);
        assert_eq!(resp.id, "r1");
        assert_eq!(resp.result.unwrap()["pong"], true);
    }

    #[tokio::test]
    async fn invalid_json_returns_error() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let result = handle_message("not json at all", &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.id, "unknown");
        let err = resp.error.unwrap();
        assert_eq!(err.code, "INVALID_PARAMS");
        assert!(err.message.contains("Invalid JSON"));
    }

    #[tokio::test]
    async fn empty_message_returns_error() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let result = handle_message("", &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn missing_method_returns_not_found() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let msg = r#"{"id":"r2","method":"no.such"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "METHOD_NOT_FOUND");
    }

    #[tokio::test]
    async fn response_preserves_request_id() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let msg = r#"{"id":"unique_42","method":"system.ping","params":{"protocolVersion":1}}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert_eq!(resp.id, "unique_42");
    }

    #[tokio::test]
    async fn non_object_json_returns_error() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let result = handle_message("[1,2,3]", &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn json_missing_id_field() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let msg = r#"{"method":"system.ping","params":{"protocolVersion":1}}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.id, "unknown");
    }

    #[tokio::test]
    async fn json_missing_method_field() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let msg = r#"{"id":"r3"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        // Missing "method" → parse error since method is required
        assert!(!resp.success);
    }

    #[tokio::test]
    async fn request_with_null_params() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let msg = r#"{"id":"r4","method":"system.ping","params":null}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn request_without_params_field() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let msg = r#"{"id":"r5","method":"system.ping"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn engine_error_propagates() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);

        let msg = r#"{"id":"r6","method":"system.ping","params":{}}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn large_params_handled() {
        let ctx = make_test_ctx();
        let reg = registry_with_transport(&ctx);
        let large_val = "x".repeat(10_000);
        let msg = format!(
            r#"{{"id":"r7","method":"settings.resetToDefaults","params":{{"big":"{large_val}"}}}}"#
        );
        let handle_result = handle_message(&msg, &reg, &ctx).await;
        let resp = handle_result.response;
        assert!(resp.success, "{:?}", resp.error);
        let result = resp.result.unwrap();
        assert!(result.is_object());
    }

    #[test]
    fn session_create_transport_context_overwrites_client_payload() {
        let mut request = RpcRequest {
            id: "1".to_owned(),
            method: "session.create".to_owned(),
            params: Some(json!({
                "workingDirectory": "/tmp",
                "__rpcContext": {"transportId": "client-supplied"}
            })),
        };

        attach_transport_context(&mut request, Some("ws-client-a"));

        let params = request.params.unwrap();
        assert_eq!(
            params["__rpcContext"]["transportId"].as_str(),
            Some("ws-client-a")
        );
    }

    #[test]
    fn serialization_fallback_is_valid_json() {
        let parsed: serde_json::Value = serde_json::from_str(SERIALIZATION_FALLBACK).unwrap();
        assert_eq!(parsed["error"]["code"], -32603);
        assert!(
            parsed["error"]["message"]
                .as_str()
                .unwrap()
                .contains("serialization")
        );
    }
}
