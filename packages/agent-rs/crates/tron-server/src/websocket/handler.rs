//! WebSocket message dispatch — parses incoming text as `RpcRequest` and
//! routes through the `MethodRegistry`.

use crate::rpc::context::RpcContext;
use crate::rpc::registry::MethodRegistry;
use crate::rpc::types::{RpcRequest, RpcResponse};
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
    let request: RpcRequest = match serde_json::from_str(message) {
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

    let mut response = registry.dispatch(request, ctx).await;
    if response.success
        && let Some(result) = response.result.as_mut()
    {
        crate::rpc::adapters::adapt_rpc_result_for_ios(&method, result, ctx);
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::rpc::errors::RpcError;
    use crate::rpc::registry::MethodHandler;
    use async_trait::async_trait;
    use serde_json::{Value, json};
    use tron_events::EventStore;
    use tron_runtime::orchestrator::orchestrator::Orchestrator;
    use tron_runtime::orchestrator::session_manager::SessionManager;

    fn make_test_ctx() -> RpcContext {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store.clone()));
        let orch = Arc::new(Orchestrator::new(mgr.clone(), 10));
        RpcContext {
            orchestrator: orch,
            session_manager: mgr,
            event_store: store,
            skill_registry: Arc::new(parking_lot::RwLock::new(
                tron_skills::registry::SkillRegistry::new(),
            )),
            task_pool: None,
            settings_path: std::path::PathBuf::from("/tmp/tron-test-settings.json"),
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            browser_service: None,
            transcription_engine: None,
            subagent_manager: None,
            embedding_controller: None,
            health_tracker: Arc::new(tron_llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
        }
    }

    struct EchoHandler;

    #[async_trait]
    impl MethodHandler for EchoHandler {
        async fn handle(
            &self,
            params: Option<Value>,
            _ctx: &RpcContext,
        ) -> Result<Value, RpcError> {
            Ok(params.unwrap_or(json!(null)))
        }
    }

    struct StaticHandler(Value);

    #[async_trait]
    impl MethodHandler for StaticHandler {
        async fn handle(
            &self,
            _params: Option<Value>,
            _ctx: &RpcContext,
        ) -> Result<Value, RpcError> {
            Ok(self.0.clone())
        }
    }

    fn registry_with_echo() -> MethodRegistry {
        let mut reg = MethodRegistry::new();
        reg.register("test.echo", EchoHandler);
        reg
    }

    #[tokio::test]
    async fn valid_request_dispatches() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r1","method":"test.echo","params":{"x":1}}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(resp.success);
        assert_eq!(resp.id, "r1");
        assert_eq!(resp.result.unwrap()["x"], 1);
    }

    #[tokio::test]
    async fn invalid_json_returns_error() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
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
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let result = handle_message("", &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn missing_method_returns_not_found() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r2","method":"no.such"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "METHOD_NOT_FOUND");
    }

    #[tokio::test]
    async fn response_preserves_request_id() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"unique_42","method":"test.echo"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert_eq!(resp.id, "unique_42");
    }

    #[tokio::test]
    async fn non_object_json_returns_error() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let result = handle_message("[1,2,3]", &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn json_missing_id_field() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"method":"test.echo"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.id, "unknown");
    }

    #[tokio::test]
    async fn json_missing_method_field() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r3"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        // Missing "method" → parse error since method is required
        assert!(!resp.success);
    }

    #[tokio::test]
    async fn request_with_null_params() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r4","method":"test.echo","params":null}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(resp.success);
        // null params → EchoHandler returns Value::Null → Some(Null)
        assert_eq!(resp.result, Some(serde_json::Value::Null));
    }

    #[tokio::test]
    async fn request_without_params_field() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r5","method":"test.echo"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(resp.success);
        // No params → EchoHandler returns Value::Null → Some(Null)
        assert_eq!(resp.result, Some(serde_json::Value::Null));
    }

    #[tokio::test]
    async fn handler_error_propagates() {
        struct FailHandler;

        #[async_trait]
        impl MethodHandler for FailHandler {
            async fn handle(
                &self,
                _params: Option<Value>,
                _ctx: &RpcContext,
            ) -> Result<Value, RpcError> {
                Err(RpcError::Internal {
                    message: "boom".into(),
                })
            }
        }

        let mut reg = MethodRegistry::new();
        reg.register("test.fail", FailHandler);
        let ctx = make_test_ctx();

        let msg = r#"{"id":"r6","method":"test.fail"}"#;
        let result = handle_message(msg, &reg, &ctx).await;
        let resp = result.response;
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INTERNAL_ERROR");
    }

    #[tokio::test]
    async fn large_params_handled() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let large_val = "x".repeat(10_000);
        let msg = format!(r#"{{"id":"r7","method":"test.echo","params":{{"big":"{large_val}"}}}}"#);
        let handle_result = handle_message(&msg, &reg, &ctx).await;
        let resp = handle_result.response;
        assert!(resp.success);
        let result = resp.result.unwrap();
        assert_eq!(result["big"].as_str().unwrap().len(), 10_000);
    }

    #[tokio::test]
    async fn settings_get_is_adapted_in_websocket_handler() {
        let mut reg = MethodRegistry::new();
        reg.register(
            "settings.get",
            StaticHandler(json!({
                "models": {"default": "claude-opus-4-6"},
                "server": {"maxConcurrentSessions": 7, "defaultWorkspace": "/tmp"},
                "context": {
                    "compactor": {"maxTokens": 160000, "preserveRecentCount": 8},
                    "memory": {"ledger": {}, "autoInject": {}},
                    "rules": {},
                    "tasks": {}
                },
                "tools": {}
            })),
        );
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r8","method":"settings.get"}"#;
        let result = handle_message(msg, &reg, &ctx)
            .await
            .response
            .result
            .unwrap();
        assert_eq!(result["defaultModel"], "claude-opus-4-6");
        assert_eq!(result["maxConcurrentSessions"], 7);
        assert_eq!(result["defaultWorkspace"], "/tmp");
        assert!(result["compaction"]["preserveRecentTurns"].is_number());
        assert!(result["memory"].is_object());
    }

    #[tokio::test]
    async fn skill_list_is_adapted_in_websocket_handler() {
        let mut reg = MethodRegistry::new();
        reg.register(
            "skill.list",
            StaticHandler(json!({
                "skills": [{"name": "alpha"}, {"name": "beta"}]
            })),
        );
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r9","method":"skill.list"}"#;
        let result = handle_message(msg, &reg, &ctx)
            .await
            .response
            .result
            .unwrap();
        assert_eq!(result["totalCount"], 2);
    }

    #[tokio::test]
    async fn session_get_history_task_manager_output_is_adapted() {
        let raw_task_json = serde_json::to_string(&json!({
            "tasks": [{"id": "task-1", "title": "Review PR", "status": "pending"}],
            "count": 1
        }))
        .unwrap();

        let mut reg = MethodRegistry::new();
        reg.register(
            "session.getHistory",
            StaticHandler(json!({
                "messages": [{
                    "id": "m1",
                    "role": "tool",
                    "toolUse": {"name": "TaskManager"},
                    "content": {"content": raw_task_json}
                }],
                "hasMore": false
            })),
        );
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r10","method":"session.getHistory"}"#;
        let result = handle_message(msg, &reg, &ctx)
            .await
            .response
            .result
            .unwrap();
        let rendered = result["messages"][0]["content"]["content"]
            .as_str()
            .unwrap();
        assert!(
            rendered.contains("Tasks"),
            "expected adapted TaskManager text"
        );
        assert!(
            !rendered.trim_start().starts_with('{'),
            "expected non-JSON adapted TaskManager text"
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
