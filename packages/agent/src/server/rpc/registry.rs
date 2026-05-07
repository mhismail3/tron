//! Method registry and async dispatch.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use metrics::{counter, histogram};
use serde_json::Value;
use tracing::warn;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::types::{RpcRequest, RpcResponse};

/// Execution contract for an RPC handler.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandlerExecutionPolicy {
    /// Cheap async work. A timeout may cancel the future before side effects.
    Quick,
    /// Potentially blocking read-only work. A timeout may leave the read
    /// finishing in the background, but it must not mutate durable state.
    BlockingRead,
    /// Mutating work. The registry does not apply the generic handler timeout
    /// because blocking side effects cannot be aborted once started.
    Mutating,
}

impl HandlerExecutionPolicy {
    fn timeout(self, default: Duration) -> Option<Duration> {
        match self {
            Self::Quick | Self::BlockingRead => Some(default),
            Self::Mutating => None,
        }
    }
}

/// Trait implemented by every RPC method handler.
#[async_trait]
pub trait MethodHandler: Send + Sync {
    /// Execute the handler with the given params and context.
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError>;

    /// Whether this handler is only a generic engine-trigger marker.
    #[cfg(test)]
    fn is_generic_trigger_marker(&self) -> bool {
        false
    }
}

struct HandlerEntry {
    handler: Arc<dyn MethodHandler>,
    policy: HandlerExecutionPolicy,
}

/// Registry mapping method names to handlers.
pub struct MethodRegistry {
    handlers: HashMap<String, HandlerEntry>,
    handler_timeout: Duration,
}

impl MethodRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            handlers: HashMap::new(),
            handler_timeout: Self::HANDLER_TIMEOUT,
        }
    }

    /// Register a handler for a method name.
    pub fn register(&mut self, method: &str, handler: impl MethodHandler + 'static) {
        self.register_with_policy(method, Self::policy_for_method(method), handler);
    }

    /// Register a handler with an explicit execution policy.
    pub fn register_with_policy(
        &mut self,
        method: &str,
        policy: HandlerExecutionPolicy,
        handler: impl MethodHandler + 'static,
    ) {
        let _ = self.handlers.insert(
            method.to_owned(),
            HandlerEntry {
                handler: Arc::new(handler),
                policy,
            },
        );
    }

    /// Maximum time a single RPC handler is allowed to run.
    const HANDLER_TIMEOUT: Duration = Duration::from_secs(60);

    /// Build a registry with a custom timeout for tests that intentionally
    /// exercise timeout policy or run broad parity checks under full-suite
    /// blocking-pool contention.
    #[cfg(test)]
    pub(crate) fn with_handler_timeout(timeout: Duration) -> Self {
        Self {
            handlers: HashMap::new(),
            handler_timeout: timeout,
        }
    }

    /// Dispatch a request to the appropriate handler.
    pub async fn dispatch(&self, request: RpcRequest, ctx: &RpcContext) -> RpcResponse {
        let method = request.method.clone();
        counter!("rpc_requests_total", "method" => method.clone()).increment(1);

        let Some(entry) = self.handlers.get(&method) else {
            counter!("rpc_errors_total", "method" => method.clone(), "error_type" => "method_not_found").increment(1);
            return RpcResponse::error(
                &request.id,
                errors::METHOD_NOT_FOUND,
                format!("Method '{method}' not found"),
            );
        };

        // Validate JSON depth before dispatching to handler
        if let Some(ref params) = request.params {
            if let Err(err) = crate::server::rpc::validation::validate_json_depth(
                params,
                crate::server::rpc::validation::MAX_JSON_DEPTH,
            ) {
                counter!("rpc_errors_total", "method" => method.clone(), "error_type" => "json_depth").increment(1);
                let body = err.to_error_body();
                return RpcResponse {
                    id: request.id,
                    success: false,
                    result: None,
                    error: Some(body),
                };
            }
        }

        let start = std::time::Instant::now();
        let generic_response = match entry.policy.timeout(self.handler_timeout) {
            Some(timeout) => {
                match tokio::time::timeout(
                    timeout,
                    crate::server::rpc::engine_bridge::try_dispatch_generic_rpc(
                        self, ctx, &request,
                    ),
                )
                .await
                {
                    Ok(response) => response,
                    Err(_elapsed) => {
                        counter!("rpc_errors_total", "method" => method.clone(), "error_type" => "timeout")
                            .increment(1);
                        tracing::error!(
                            method,
                            "RPC handler timed out after {:?}",
                            self.handler_timeout
                        );
                        record_dispatch_duration(&method, start);
                        return RpcResponse::error(
                            &request.id,
                            errors::INTERNAL_ERROR,
                            format!("Handler for '{method}' timed out"),
                        );
                    }
                }
            }
            None => {
                crate::server::rpc::engine_bridge::try_dispatch_generic_rpc(self, ctx, &request)
                    .await
            }
        };
        if let Some(response) = generic_response {
            if let Some(error) = &response.error {
                counter!("rpc_errors_total", "method" => method.clone(), "error_type" => error.code.clone()).increment(1);
            }
            record_dispatch_duration(&method, start);
            return response;
        }

        let result = match entry.policy.timeout(self.handler_timeout) {
            Some(timeout) => {
                tokio::time::timeout(timeout, entry.handler.handle(request.params, ctx))
                    .await
                    .map_err(|_| ())
            }
            None => Ok(entry.handler.handle(request.params, ctx).await),
        };

        let response = match result {
            Ok(Ok(result)) => RpcResponse::success(&request.id, result),
            Ok(Err(err)) => {
                counter!("rpc_errors_total", "method" => method.clone(), "error_type" => err.code().to_owned()).increment(1);
                // Log full error server-side, sanitize for client
                tracing::warn!(method, error = %err, "RPC handler returned error");
                let sanitized_msg = crate::server::rpc::validation::sanitize_error_message(&err);
                let mut body = err.to_error_body();
                body.message = sanitized_msg;
                RpcResponse {
                    id: request.id,
                    success: false,
                    result: None,
                    error: Some(body),
                }
            }
            Err(_elapsed) => {
                counter!("rpc_errors_total", "method" => method.clone(), "error_type" => "timeout")
                    .increment(1);
                tracing::error!(
                    method,
                    "RPC handler timed out after {:?}",
                    self.handler_timeout
                );
                RpcResponse::error(
                    &request.id,
                    errors::INTERNAL_ERROR,
                    format!("Handler for '{method}' timed out"),
                )
            }
        };

        record_dispatch_duration(&method, start);

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

    /// Return the configured execution policy for a registered method.
    pub fn method_policy(&self, method: &str) -> Option<HandlerExecutionPolicy> {
        self.handlers.get(method).map(|entry| entry.policy)
    }

    /// Test-only guardrail: generic-triggered methods must register marker
    /// handlers, not hidden method-specific business logic.
    #[cfg(test)]
    pub fn is_generic_trigger_marker(&self, method: &str) -> bool {
        self.handlers
            .get(method)
            .is_some_and(|entry| entry.handler.is_generic_trigger_marker())
    }

    fn policy_for_method(method: &str) -> HandlerExecutionPolicy {
        if matches!(
            method,
            "system.ping"
                | "system.getInfo"
                | "system.getDiagnostics"
                | "agent.status"
                | "browser.getStatus"
                | "codexApp.status"
                | "cron.status"
                | "context.shouldCompact"
                | "context.canAcceptTurn"
                | "mcp.status"
        ) {
            return HandlerExecutionPolicy::Quick;
        }

        if method.starts_with("settings.get")
            || method.starts_with("session.list")
            || method.starts_with("session.get")
            || method.starts_with("session.reconstruct")
            || method.starts_with("session.resume")
            || method.starts_with("session.export")
            || method.starts_with("events.get")
            || method.starts_with("model.list")
            || method.starts_with("blob.get")
            || method.starts_with("context.get")
            || method.starts_with("context.preview")
            || method.starts_with("logs.recent")
            || method.starts_with("mcp.list")
            || method.starts_with("skill.list")
            || method.starts_with("skill.get")
            || method.starts_with("skill.active")
            || method.starts_with("filesystem.list")
            || method.starts_with("filesystem.get")
            || method.starts_with("file.read")
            || method.starts_with("tree.")
            || method.starts_with("import.list")
            || method.starts_with("import.preview")
            || method.starts_with("git.list")
            || method.starts_with("worktree.get")
            || method.starts_with("worktree.is")
            || method.starts_with("worktree.list")
            || method.starts_with("repo.list")
            || method.starts_with("repo.get")
            || method.starts_with("sandbox.list")
            || method.starts_with("transcribe.list")
            || method.starts_with("plan.get")
            || method.starts_with("voiceNotes.list")
            || method.starts_with("notifications.list")
            || method.starts_with("promptHistory.list")
            || method.starts_with("promptSnippet.list")
            || method.starts_with("promptSnippet.get")
            || method.starts_with("cron.list")
            || method.starts_with("cron.get")
            || method.starts_with("cron.getRuns")
            || method.starts_with("job.list")
            || method.starts_with("auth.get")
            || method.starts_with("approval.get")
            || method.starts_with("approval.list")
            || method.starts_with("system.getUpdateStatus")
        {
            return HandlerExecutionPolicy::BlockingRead;
        }

        HandlerExecutionPolicy::Mutating
    }
}

fn record_dispatch_duration(method: &str, start: std::time::Instant) {
    let duration = start.elapsed();
    histogram!("rpc_request_duration_seconds", "method" => method.to_owned())
        .record(duration.as_secs_f64());

    if duration.as_secs() >= 5 {
        warn!(
            method,
            duration_secs = duration.as_secs_f64(),
            "slow RPC request"
        );
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
    use crate::server::rpc::handlers::test_helpers::make_test_context;
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

    #[test]
    fn registry_classifies_core_execution_policies() {
        let mut reg = MethodRegistry::new();
        reg.register("system.ping", EchoHandler);
        reg.register("settings.get", EchoHandler);
        reg.register("settings.update", EchoHandler);

        assert_eq!(
            reg.method_policy("system.ping"),
            Some(HandlerExecutionPolicy::Quick)
        );
        assert_eq!(
            reg.method_policy("settings.get"),
            Some(HandlerExecutionPolicy::BlockingRead)
        );
        assert_eq!(
            reg.method_policy("settings.update"),
            Some(HandlerExecutionPolicy::Mutating)
        );
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

    struct SlowEngineFunction {
        delay: std::time::Duration,
    }

    #[async_trait]
    impl crate::engine::InProcessFunctionHandler for SlowEngineFunction {
        async fn invoke(
            &self,
            _invocation: crate::engine::Invocation,
        ) -> Result<Value, crate::engine::EngineError> {
            tokio::time::sleep(self.delay).await;
            Ok(json!({"done": true}))
        }
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

        let resp = reg.dispatch(make_request("r1", "fast", None), &ctx).await;
        assert!(resp.success);
        assert_eq!(resp.result.unwrap(), "done");
    }

    #[tokio::test]
    async fn dispatch_timeout_returns_error() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::with_handler_timeout(std::time::Duration::from_millis(1));
        reg.register_with_policy(
            "slow",
            HandlerExecutionPolicy::Quick,
            SlowHandler {
                delay: std::time::Duration::from_millis(30),
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

    #[tokio::test]
    async fn generic_dispatch_preserves_registry_timeout() {
        let ctx = make_test_context();
        let definition = crate::engine::FunctionDefinition::new(
            crate::engine::FunctionId::new("system::ping").unwrap(),
            crate::engine::WorkerId::new("system").unwrap(),
            "slow test rpc ping".to_owned(),
            crate::engine::VisibilityScope::System,
            crate::engine::EffectClass::PureRead,
        )
        .with_required_authority(crate::engine::AuthorityRequirement::scope("system.read"));
        ctx.engine_host
            .register_function_for_setup(
                definition,
                Some(Arc::new(SlowEngineFunction {
                    delay: std::time::Duration::from_millis(30),
                })),
                false,
            )
            .unwrap();

        let mut reg = MethodRegistry::with_handler_timeout(std::time::Duration::from_millis(1));
        crate::server::rpc::handlers::register_all(&mut reg);
        let resp = reg
            .dispatch(
                make_request(
                    "r-generic-timeout",
                    "system.ping",
                    Some(json!({"protocolVersion": 1})),
                ),
                &ctx,
            )
            .await;

        assert!(!resp.success);
        assert_eq!(resp.id, "r-generic-timeout");
        let err = resp.error.unwrap();
        assert_eq!(err.code, "INTERNAL_ERROR");
        assert!(err.message.contains("timed out"));
    }

    #[tokio::test]
    async fn dispatch_mutating_policy_waits_instead_of_timing_out() {
        use std::sync::atomic::{AtomicBool, Ordering};

        struct MutatingHandler {
            changed: Arc<AtomicBool>,
        }

        #[async_trait]
        impl MethodHandler for MutatingHandler {
            async fn handle(
                &self,
                _params: Option<Value>,
                _ctx: &RpcContext,
            ) -> Result<Value, RpcError> {
                tokio::time::sleep(std::time::Duration::from_millis(30)).await;
                self.changed.store(true, Ordering::SeqCst);
                Ok(json!({"changed": true}))
            }
        }

        let ctx = make_test_context();
        let changed = Arc::new(AtomicBool::new(false));
        let mut reg = MethodRegistry::with_handler_timeout(std::time::Duration::from_millis(1));
        reg.register_with_policy(
            "test.mutate",
            HandlerExecutionPolicy::Mutating,
            MutatingHandler {
                changed: Arc::clone(&changed),
            },
        );

        let resp = reg
            .dispatch(make_request("r-mutating", "test.mutate", None), &ctx)
            .await;

        assert!(resp.success, "mutating handler must not timeout early");
        assert!(changed.load(Ordering::SeqCst));
    }
}
