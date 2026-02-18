//! Method registry and async dispatch.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use metrics::{counter, histogram};
use serde_json::Value;
use tracing::warn;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::types::{RpcRequest, RpcResponse};

/// Trait implemented by every RPC method handler.
#[async_trait]
pub trait MethodHandler: Send + Sync {
    /// Execute the handler with the given params and context.
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError>;
}

/// Registry mapping method names to handlers.
pub struct MethodRegistry {
    handlers: HashMap<String, Arc<dyn MethodHandler>>,
}

impl MethodRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            handlers: HashMap::new(),
        }
    }

    /// Register a handler for a method name.
    pub fn register(&mut self, method: &str, handler: impl MethodHandler + 'static) {
        let _ = self.handlers.insert(method.to_owned(), Arc::new(handler));
    }

    /// Maximum time a single RPC handler is allowed to run.
    const HANDLER_TIMEOUT: Duration = Duration::from_secs(60);

    /// Dispatch a request to the appropriate handler.
    pub async fn dispatch(&self, request: RpcRequest, ctx: &RpcContext) -> RpcResponse {
        let method = request.method.clone();
        counter!("rpc_requests_total", "method" => method.clone()).increment(1);

        let Some(handler) = self.handlers.get(&method) else {
            counter!("rpc_errors_total", "method" => method.clone(), "error_type" => "method_not_found").increment(1);
            return RpcResponse::error(
                &request.id,
                errors::METHOD_NOT_FOUND,
                format!("Method '{method}' not found"),
            );
        };

        let start = std::time::Instant::now();
        let result = tokio::time::timeout(
            Self::HANDLER_TIMEOUT,
            handler.handle(request.params, ctx),
        )
        .await;

        let response = match result {
            Ok(Ok(result)) => RpcResponse::success(&request.id, result),
            Ok(Err(err)) => {
                counter!("rpc_errors_total", "method" => method.clone(), "error_type" => err.code().to_owned()).increment(1);
                let body = err.to_error_body();
                RpcResponse {
                    id: request.id,
                    success: false,
                    result: None,
                    error: Some(body),
                }
            }
            Err(_elapsed) => {
                counter!("rpc_errors_total", "method" => method.clone(), "error_type" => "timeout").increment(1);
                tracing::error!(method, "RPC handler timed out after {:?}", Self::HANDLER_TIMEOUT);
                RpcResponse::error(
                    &request.id,
                    errors::INTERNAL_ERROR,
                    format!("Handler for '{method}' timed out"),
                )
            }
        };

        let duration = start.elapsed();
        histogram!("rpc_request_duration_seconds", "method" => method.clone())
            .record(duration.as_secs_f64());

        if duration.as_secs() >= 5 {
            warn!(
                method,
                duration_secs = duration.as_secs_f64(),
                "slow RPC request"
            );
        }

        response
    }

    /// List all registered method names (sorted).
    pub fn methods(&self) -> Vec<String> {
        let mut names: Vec<String> = self.handlers.keys().cloned().collect();
        names.sort();
        names
    }

    /// Check whether a method is registered.
    pub fn has_method(&self, method: &str) -> bool {
        self.handlers.contains_key(method)
    }
}

impl Default for MethodRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    // ── Test handler implementations ────────────────────────────────

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

    struct ParamCheckHandler;

    #[async_trait]
    impl MethodHandler for ParamCheckHandler {
        async fn handle(
            &self,
            params: Option<Value>,
            _ctx: &RpcContext,
        ) -> Result<Value, RpcError> {
            let p = params.ok_or_else(|| RpcError::InvalidParams {
                message: "params required".into(),
            })?;
            let name =
                p.get("name")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| RpcError::InvalidParams {
                        message: "Missing 'name'".into(),
                    })?;
            Ok(json!({ "hello": name }))
        }
    }

    fn make_request(id: &str, method: &str, params: Option<Value>) -> RpcRequest {
        RpcRequest {
            id: id.into(),
            method: method.into(),
            params,
            idempotency_key: None,
        }
    }

    // ── Tests ───────────────────────────────────────────────────────

    #[tokio::test]
    async fn register_and_dispatch_success() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("echo", EchoHandler);

        let resp = reg
            .dispatch(make_request("r1", "echo", Some(json!({"x": 1}))), &ctx)
            .await;

        assert!(resp.success);
        assert_eq!(resp.id, "r1");
        assert_eq!(resp.result.unwrap()["x"], 1);
    }

    #[tokio::test]
    async fn dispatch_method_not_found() {
        let ctx = make_test_context();
        let reg = MethodRegistry::new();

        let resp = reg
            .dispatch(make_request("r2", "no.such", None), &ctx)
            .await;

        assert!(!resp.success);
        let err = resp.error.unwrap();
        assert_eq!(err.code, "METHOD_NOT_FOUND");
        assert!(err.message.contains("no.such"));
    }

    #[tokio::test]
    async fn dispatch_handler_error() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("fail", FailHandler);

        let resp = reg.dispatch(make_request("r3", "fail", None), &ctx).await;

        assert!(!resp.success);
        assert_eq!(resp.error.unwrap().code, "INTERNAL_ERROR");
    }

    #[tokio::test]
    async fn list_methods() {
        let mut reg = MethodRegistry::new();
        reg.register("b.method", EchoHandler);
        reg.register("a.method", EchoHandler);

        let methods = reg.methods();
        assert_eq!(methods, vec!["a.method", "b.method"]);
    }

    #[tokio::test]
    async fn has_method_check() {
        let mut reg = MethodRegistry::new();
        reg.register("system.ping", EchoHandler);

        assert!(reg.has_method("system.ping"));
        assert!(!reg.has_method("system.pong"));
    }

    #[tokio::test]
    async fn multiple_handlers() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("echo", EchoHandler);
        reg.register("fail", FailHandler);

        let r1 = reg
            .dispatch(make_request("r1", "echo", Some(json!("hi"))), &ctx)
            .await;
        assert!(r1.success);

        let r2 = reg.dispatch(make_request("r2", "fail", None), &ctx).await;
        assert!(!r2.success);
    }

    #[tokio::test]
    async fn handler_with_param_validation() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("greet", ParamCheckHandler);

        // Missing params
        let r1 = reg.dispatch(make_request("r1", "greet", None), &ctx).await;
        assert!(!r1.success);
        assert_eq!(r1.error.unwrap().code, "INVALID_PARAMS");

        // Missing name
        let r2 = reg
            .dispatch(make_request("r2", "greet", Some(json!({}))), &ctx)
            .await;
        assert!(!r2.success);

        // Success
        let r3 = reg
            .dispatch(
                make_request("r3", "greet", Some(json!({"name": "alice"}))),
                &ctx,
            )
            .await;
        assert!(r3.success);
        assert_eq!(r3.result.unwrap()["hello"], "alice");
    }

    #[tokio::test]
    async fn dispatch_preserves_request_id() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("echo", EchoHandler);

        let resp = reg
            .dispatch(make_request("my-unique-id-42", "echo", None), &ctx)
            .await;
        assert_eq!(resp.id, "my-unique-id-42");
    }

    #[tokio::test]
    async fn dispatch_not_found_preserves_id() {
        let ctx = make_test_context();
        let reg = MethodRegistry::new();

        let resp = reg
            .dispatch(make_request("id-99", "missing", None), &ctx)
            .await;
        assert_eq!(resp.id, "id-99");
    }

    #[tokio::test]
    async fn dispatch_error_preserves_id() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("fail", FailHandler);

        let resp = reg
            .dispatch(make_request("id-err", "fail", None), &ctx)
            .await;
        assert_eq!(resp.id, "id-err");
    }

    #[test]
    fn default_registry_is_empty() {
        let reg = MethodRegistry::default();
        assert!(reg.methods().is_empty());
    }

    #[tokio::test]
    async fn register_overwrites_previous() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("test", EchoHandler);
        reg.register("test", FailHandler);

        let resp = reg.dispatch(make_request("r1", "test", None), &ctx).await;
        // FailHandler should have replaced EchoHandler
        assert!(!resp.success);
    }

    struct SlowHandler {
        delay: std::time::Duration,
    }

    #[async_trait]
    impl MethodHandler for SlowHandler {
        async fn handle(
            &self,
            _params: Option<Value>,
            _ctx: &RpcContext,
        ) -> Result<Value, RpcError> {
            tokio::time::sleep(self.delay).await;
            Ok(json!("done"))
        }
    }

    #[tokio::test]
    async fn dispatch_fast_handler_unaffected_by_timeout() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register(
            "fast",
            SlowHandler {
                delay: std::time::Duration::from_millis(1),
            },
        );

        let resp = reg
            .dispatch(make_request("r1", "fast", None), &ctx)
            .await;
        assert!(resp.success);
        assert_eq!(resp.result.unwrap(), "done");
    }

    #[tokio::test]
    async fn dispatch_timeout_returns_error() {
        // Use a custom registry with a very short timeout to test the timeout path
        // without actually waiting 60 seconds. We'll test indirectly by verifying
        // the timeout machinery works with tokio's pause feature.
        tokio::time::pause();

        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register(
            "slow",
            SlowHandler {
                delay: std::time::Duration::from_secs(120),
            },
        );

        let resp = reg
            .dispatch(make_request("r-timeout", "slow", None), &ctx)
            .await;

        assert!(!resp.success);
        assert_eq!(resp.id, "r-timeout");
        let err = resp.error.unwrap();
        assert_eq!(err.code, "INTERNAL_ERROR");
        assert!(err.message.contains("timed out"));
    }
}
