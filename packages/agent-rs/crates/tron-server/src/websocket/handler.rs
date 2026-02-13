//! WebSocket message dispatch — parses incoming text as `RpcRequest` and
//! routes through the `MethodRegistry`.

use tron_rpc::context::RpcContext;
use tron_rpc::registry::MethodRegistry;
use tron_rpc::types::{RpcRequest, RpcResponse};

/// Handle an incoming WebSocket text message.
///
/// Parses the message as an `RpcRequest`, dispatches to the registry, and
/// returns the serialized `RpcResponse` as a JSON string.
pub async fn handle_message(
    message: &str,
    registry: &MethodRegistry,
    ctx: &RpcContext,
) -> String {
    let request: RpcRequest = match serde_json::from_str(message) {
        Ok(r) => r,
        Err(e) => {
            let resp =
                RpcResponse::error("unknown", "INVALID_PARAMS", format!("Invalid JSON: {e}"));
            return serde_json::to_string(&resp).unwrap_or_default();
        }
    };

    let response = registry.dispatch(request, ctx).await;
    serde_json::to_string(&response).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use async_trait::async_trait;
    use serde_json::{json, Value};
    use tron_events::EventStore;
    use tron_rpc::errors::RpcError;
    use tron_rpc::registry::MethodHandler;
    use tron_runtime::orchestrator::orchestrator::Orchestrator;
    use tron_runtime::orchestrator::session_manager::SessionManager;

    fn make_test_ctx() -> RpcContext {
        let pool =
            tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            tron_events::run_migrations(&conn).unwrap();
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
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(resp.success);
        assert_eq!(resp.id, "r1");
        assert_eq!(resp.result.unwrap()["x"], 1);
    }

    #[tokio::test]
    async fn invalid_json_returns_error() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let resp_str = handle_message("not json at all", &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
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
        let resp_str = handle_message("", &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn missing_method_returns_not_found() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r2","method":"no.such"}"#;
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "METHOD_NOT_FOUND");
    }

    #[tokio::test]
    async fn response_preserves_request_id() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"unique_42","method":"test.echo"}"#;
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert_eq!(resp.id, "unique_42");
    }

    #[tokio::test]
    async fn non_object_json_returns_error() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let resp_str = handle_message("[1,2,3]", &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn json_missing_id_field() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"method":"test.echo"}"#;
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(!resp.success);
        assert_eq!(resp.id, "unknown");
    }

    #[tokio::test]
    async fn json_missing_method_field() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r3"}"#;
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        // Missing "method" → parse error since method is required
        assert!(!resp.success);
    }

    #[tokio::test]
    async fn request_with_null_params() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r4","method":"test.echo","params":null}"#;
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(resp.success);
        // null params → EchoHandler returns null → serde roundtrip drops Some(Null) to None
        let v: serde_json::Value = serde_json::from_str(&resp_str).unwrap();
        assert!(v["result"].is_null());
    }

    #[tokio::test]
    async fn request_without_params_field() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let msg = r#"{"id":"r5","method":"test.echo"}"#;
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(resp.success);
        // No params → EchoHandler returns null → serde roundtrip drops to None
        let v: serde_json::Value = serde_json::from_str(&resp_str).unwrap();
        assert!(v["result"].is_null());
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
        let resp_str = handle_message(msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INTERNAL_ERROR");
    }

    #[tokio::test]
    async fn large_params_handled() {
        let reg = registry_with_echo();
        let ctx = make_test_ctx();
        let large_val = "x".repeat(10_000);
        let msg = format!(r#"{{"id":"r7","method":"test.echo","params":{{"big":"{large_val}"}}}}"#);
        let resp_str = handle_message(&msg, &reg, &ctx).await;
        let resp: RpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(resp.success);
        let result = resp.result.unwrap();
        assert_eq!(result["big"].as_str().unwrap().len(), 10_000);
    }
}
