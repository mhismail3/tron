//! Pure JSON-RPC transport registry.
//!
//! The registry owns method-name existence, JSON-depth validation, timeout
//! policy, metrics, and sanitized wire errors. It does not own business
//! behavior: every registered method is a transport alias that dispatches
//! through a `json_rpc` trigger into a canonical engine capability.

use std::collections::HashMap;
use std::time::Duration;

use metrics::{counter, histogram};
use tracing::warn;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors;
use crate::server::rpc::types::{RpcRequest, RpcResponse};

/// Execution contract for a JSON-RPC transport binding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportExecutionPolicy {
    /// Cheap async work. A timeout may cancel the future before side effects.
    Quick,
    /// Potentially blocking read-only work. A timeout may leave the read
    /// finishing in the background, but it must not mutate durable state.
    BlockingRead,
    /// Mutating work. The registry does not apply the generic transport
    /// timeout because blocking side effects cannot be aborted once started.
    Mutating,
}

impl TransportExecutionPolicy {
    fn timeout(self, default: Duration) -> Option<Duration> {
        match self {
            Self::Quick | Self::BlockingRead => Some(default),
            Self::Mutating => None,
        }
    }
}

/// One JSON-RPC method alias bound to a canonical engine trigger.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonRpcTransportBinding {
    /// Legacy or canonical public JSON-RPC method name.
    pub method: String,
    /// Timeout policy for the transport call.
    pub policy: TransportExecutionPolicy,
}

/// Registry mapping JSON-RPC method names to transport bindings.
pub struct MethodRegistry {
    bindings: HashMap<String, JsonRpcTransportBinding>,
    transport_timeout: Duration,
}

impl MethodRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            bindings: HashMap::new(),
            transport_timeout: Self::TRANSPORT_TIMEOUT,
        }
    }

    /// Register a JSON-RPC alias using its default transport policy.
    pub fn register(&mut self, method: &str) {
        self.register_with_policy(method, Self::policy_for_method(method));
    }

    /// Register a JSON-RPC alias with an explicit execution policy.
    pub fn register_with_policy(&mut self, method: &str, policy: TransportExecutionPolicy) {
        let _ = self.bindings.insert(
            method.to_owned(),
            JsonRpcTransportBinding {
                method: method.to_owned(),
                policy,
            },
        );
    }

    /// Maximum time a single quick/read JSON-RPC transport is allowed to run.
    const TRANSPORT_TIMEOUT: Duration = Duration::from_secs(60);

    /// Build a registry with a custom timeout for timeout-policy tests.
    #[cfg(test)]
    pub(crate) fn with_transport_timeout(timeout: Duration) -> Self {
        Self {
            bindings: HashMap::new(),
            transport_timeout: timeout,
        }
    }

    /// Dispatch a request through the canonical engine trigger for the alias.
    pub async fn dispatch(&self, request: RpcRequest, ctx: &RpcContext) -> RpcResponse {
        let method = request.method.clone();
        counter!("rpc_requests_total", "method" => method.clone()).increment(1);

        let Some(binding) = self.bindings.get(&method) else {
            counter!("rpc_errors_total", "method" => method.clone(), "error_type" => "method_not_found").increment(1);
            return RpcResponse::error(
                &request.id,
                errors::METHOD_NOT_FOUND,
                format!("Method '{method}' not found"),
            );
        };

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
        let response = match binding.policy.timeout(self.transport_timeout) {
            Some(timeout) => {
                match tokio::time::timeout(
                    timeout,
                    crate::server::rpc::engine_bridge::dispatch_json_rpc_transport(
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
                            "RPC transport timed out after {:?}",
                            self.transport_timeout
                        );
                        record_dispatch_duration(&method, start);
                        return RpcResponse::error(
                            &request.id,
                            errors::INTERNAL_ERROR,
                            format!("JSON-RPC transport for '{method}' timed out"),
                        );
                    }
                }
            }
            None => {
                crate::server::rpc::engine_bridge::dispatch_json_rpc_transport(self, ctx, &request)
                    .await
            }
        };

        if let Some(error) = &response.error {
            counter!("rpc_errors_total", "method" => method.clone(), "error_type" => error.code.clone()).increment(1);
        }
        record_dispatch_duration(&method, start);
        response
    }

    /// List all registered method names (sorted).
    pub fn methods(&self) -> Vec<String> {
        let mut names: Vec<String> = self.bindings.keys().cloned().collect();
        names.sort();
        names
    }

    /// Check whether a method is registered.
    pub fn has_method(&self, method: &str) -> bool {
        self.bindings.contains_key(method)
    }

    /// Return the configured execution policy for a registered method.
    pub fn method_policy(&self, method: &str) -> Option<TransportExecutionPolicy> {
        self.bindings.get(method).map(|entry| entry.policy)
    }

    /// Test-only guardrail: every registered method is now a transport binding.
    #[cfg(test)]
    pub fn is_transport_binding(&self, method: &str) -> bool {
        self.has_method(method)
    }

    fn policy_for_method(method: &str) -> TransportExecutionPolicy {
        if matches!(
            method,
            "engine.discover"
                | "engine.inspect"
                | "engine.watch"
                | "system.ping"
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
            return TransportExecutionPolicy::Quick;
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
            || method.starts_with("system.checkForUpdates")
            || method.starts_with("system.getUpdateStatus")
        {
            return TransportExecutionPolicy::BlockingRead;
        }

        TransportExecutionPolicy::Mutating
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
    use crate::server::rpc::bindings;
    use crate::server::rpc::test_support::make_test_context;
    use serde_json::json;

    fn make_request(id: &str, method: &str, params: Option<serde_json::Value>) -> RpcRequest {
        RpcRequest {
            id: id.into(),
            method: method.into(),
            params,
        }
    }

    #[test]
    fn registry_classifies_core_execution_policies() {
        let mut reg = MethodRegistry::new();
        reg.register("system.ping");
        reg.register("settings.get");
        reg.register("settings.update");

        assert_eq!(
            reg.method_policy("system.ping"),
            Some(TransportExecutionPolicy::Quick)
        );
        assert_eq!(
            reg.method_policy("settings.get"),
            Some(TransportExecutionPolicy::BlockingRead)
        );
        assert_eq!(
            reg.method_policy("settings.update"),
            Some(TransportExecutionPolicy::Mutating)
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
    async fn dispatch_json_depth_error_preserves_request_id() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        reg.register("system.ping");

        let mut value = json!({});
        for _ in 0..(crate::server::rpc::validation::MAX_JSON_DEPTH + 1) {
            value = json!({ "nested": value });
        }
        let resp = reg
            .dispatch(make_request("r-depth", "system.ping", Some(value)), &ctx)
            .await;

        assert!(!resp.success);
        assert_eq!(resp.id, "r-depth");
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_methods() {
        let mut reg = MethodRegistry::new();
        reg.register("b.method");
        reg.register("a.method");

        let methods = reg.methods();
        assert_eq!(methods, vec!["a.method", "b.method"]);
    }

    #[tokio::test]
    async fn has_method_check() {
        let mut reg = MethodRegistry::new();
        reg.register("system.ping");

        assert!(reg.has_method("system.ping"));
        assert!(!reg.has_method("system.pong"));
        assert!(reg.is_transport_binding("system.ping"));
    }

    #[test]
    fn default_registry_is_empty() {
        let reg = MethodRegistry::default();
        assert!(reg.methods().is_empty());
    }

    #[test]
    fn register_overwrites_previous_policy() {
        let mut reg = MethodRegistry::new();
        reg.register_with_policy("system.ping", TransportExecutionPolicy::Mutating);
        reg.register("system.ping");

        assert_eq!(
            reg.method_policy("system.ping"),
            Some(TransportExecutionPolicy::Quick)
        );
    }

    #[tokio::test]
    async fn transport_dispatch_success() {
        let ctx = make_test_context();
        let mut reg = MethodRegistry::new();
        bindings::register_all(&mut reg);
        crate::server::rpc::engine_bridge::register_rpc_worker_for_context(&ctx, &reg).unwrap();

        let resp = reg
            .dispatch(
                make_request(
                    "r1",
                    "system.ping",
                    Some(json!({"protocolVersion": crate::server::rpc::protocol::CURRENT_PROTOCOL_VERSION})),
                ),
                &ctx,
            )
            .await;

        assert!(resp.success, "{:?}", resp.error);
        assert_eq!(resp.id, "r1");
        assert_eq!(resp.result.unwrap()["pong"], true);
    }

    #[tokio::test]
    async fn transport_timeout_returns_error_for_quick_aliases() {
        struct SlowEngineFunction {
            delay: std::time::Duration,
        }

        #[async_trait::async_trait]
        impl crate::engine::InProcessFunctionHandler for SlowEngineFunction {
            async fn invoke(
                &self,
                _invocation: crate::engine::Invocation,
            ) -> Result<serde_json::Value, crate::engine::EngineError> {
                tokio::time::sleep(self.delay).await;
                Ok(json!({"done": true}))
            }
        }

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
                Some(std::sync::Arc::new(SlowEngineFunction {
                    delay: std::time::Duration::from_millis(30),
                })),
                false,
            )
            .unwrap();

        let mut reg = MethodRegistry::with_transport_timeout(std::time::Duration::from_millis(1));
        reg.register("system.ping");
        let resp = reg
            .dispatch(
                make_request(
                    "r-timeout",
                    "system.ping",
                    Some(json!({"protocolVersion": 1})),
                ),
                &ctx,
            )
            .await;

        assert!(!resp.success);
        assert_eq!(resp.id, "r-timeout");
        let err = resp.error.unwrap();
        assert_eq!(err.code, "INTERNAL_ERROR");
        assert!(err.message.contains("timed out"));
    }
}
