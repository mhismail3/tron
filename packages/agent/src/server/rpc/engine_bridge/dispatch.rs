use async_trait::async_trait;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{ActorKind, CausalContext, FunctionId, Invocation, TraceId};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::registry::{MethodHandler, MethodRegistry};
use crate::server::rpc::types::{RpcRequest, RpcResponse};

use super::specs::{self, RpcIdempotencyMode, RpcMigrationState};
use super::{RPC_AUTHORITY_GRANT, engine_error_to_rpc, result_to_rpc};

/// Fully typed invocation envelope produced by the JSON-RPC transport trigger.
#[derive(Clone, Debug, PartialEq)]
pub struct RpcEngineInvocation {
    /// Original JSON-RPC request id.
    pub request_id: String,
    /// Original JSON-RPC method.
    pub method: String,
    /// Engine function id (`rpc::<method>`).
    pub function_id: FunctionId,
    /// Payload delivered to the engine function.
    pub params_payload: Value,
    /// Causal authority and trace metadata for the engine invocation.
    pub causal_context: CausalContext,
}

impl RpcEngineInvocation {
    /// Build a generic-trigger envelope if the method is migrated to generic
    /// dispatch. Handler-only or custom methods return `Ok(None)`.
    pub fn from_request(
        registry: &MethodRegistry,
        ctx: &RpcContext,
        request: &RpcRequest,
    ) -> Result<Option<Self>, RpcError> {
        let spec = specs::capability_spec_for_method(registry, &request.method)
            .map_err(engine_error_to_rpc)?;
        let Some(spec) = spec else {
            return Ok(None);
        };
        if spec.migration_state != RpcMigrationState::GenericTrigger {
            return Ok(None);
        }

        let params_payload = payload_for_rpc_method(ctx, spec.method, request.params.clone());
        let authority_scope = spec.authority_scope.ok_or_else(|| RpcError::Internal {
            message: format!(
                "generic RPC trigger {} is missing an authority scope",
                spec.method
            ),
        })?;
        let mut causal_context = rpc_causal_context_for_scope(authority_scope);
        if let Some(session_id) = extract_string(&params_payload, "sessionId") {
            causal_context = causal_context.with_session_id(session_id);
        }
        if let Some(workspace_id) = extract_string(&params_payload, "workspaceId") {
            causal_context = causal_context.with_workspace_id(workspace_id);
        }
        if spec.effect_class.is_mutating() {
            match spec.idempotency_mode {
                RpcIdempotencyMode::JsonRpcRequestIdSeed => {
                    let key =
                        derive_json_rpc_idempotency_key(spec.method, &request.id, &params_payload)?;
                    causal_context = causal_context.with_idempotency_key(key);
                }
                RpcIdempotencyMode::ExplicitRequired => {
                    return Err(RpcError::InvalidParams {
                        message: format!("{} requires explicit engine idempotency", spec.method),
                    });
                }
                RpcIdempotencyMode::NotRequired => {}
            }
        }

        Ok(Some(Self {
            request_id: request.id.clone(),
            method: request.method.clone(),
            function_id: spec.function_id,
            params_payload,
            causal_context,
        }))
    }
}

/// Return a response only for methods served by the generic RPC trigger.
pub async fn try_dispatch_generic_rpc(
    registry: &MethodRegistry,
    ctx: &RpcContext,
    request: &RpcRequest,
) -> Option<RpcResponse> {
    let envelope = match RpcEngineInvocation::from_request(registry, ctx, request) {
        Ok(Some(envelope)) => envelope,
        Ok(None) => return None,
        Err(error) => return Some(rpc_error_response(&request.id, error)),
    };

    let invocation = Invocation::new_sync(
        envelope.function_id,
        envelope.params_payload,
        envelope.causal_context,
    );
    let result = ctx.engine_host.invoke(invocation).await;
    Some(match result_to_rpc(result) {
        Ok(value) => RpcResponse::success(&envelope.request_id, value),
        Err(error) => rpc_error_response(&envelope.request_id, error),
    })
}

/// Marker handler for methods that must be intercepted by
/// [`try_dispatch_generic_rpc`].
pub struct RpcGenericTriggerHandler {
    method: &'static str,
}

impl RpcGenericTriggerHandler {
    /// Build a marker for one generic-triggered RPC method.
    #[must_use]
    pub fn new(method: &'static str) -> Self {
        Self { method }
    }
}

#[async_trait]
impl MethodHandler for RpcGenericTriggerHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Err(RpcError::Internal {
            message: format!(
                "generic RPC trigger marker for {} executed; registry interception failed",
                self.method
            ),
        })
    }

    #[cfg(test)]
    fn is_generic_trigger_marker(&self) -> bool {
        true
    }
}

pub(super) fn payload_for_rpc_method(
    ctx: &RpcContext,
    method: &'static str,
    params: Option<Value>,
) -> Value {
    if method == "settings.resetToDefaults" {
        return json!({});
    }
    let mut payload = params.unwrap_or_else(|| json!({}));
    if !payload.is_object() {
        return payload;
    }
    if method == "system.getInfo" {
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "__rpcContext".to_owned(),
                json!({
                    "onboardedMarkerPath": ctx.onboarded_marker_path.to_string_lossy(),
                }),
            );
        }
    }
    if method == "model.list" {
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "__rpcContext".to_owned(),
                json!({
                    "authPath": ctx.auth_path.to_string_lossy(),
                }),
            );
        }
    }
    payload
}

#[cfg(test)]
pub(super) fn rpc_causal_context() -> CausalContext {
    rpc_causal_context_for_scope(super::RPC_READ_AUTHORITY)
}

pub(super) fn rpc_causal_context_for_scope(scope: &str) -> CausalContext {
    CausalContext::new(
        specs::actor_id("rpc-client").expect("valid static rpc actor id"),
        ActorKind::Client,
        specs::grant_id(RPC_AUTHORITY_GRANT).expect("valid static rpc grant id"),
        TraceId::generate(),
    )
    .with_scope(scope)
}

fn rpc_error_response(id: &str, error: RpcError) -> RpcResponse {
    let sanitized_msg = crate::server::rpc::validation::sanitize_error_message(&error);
    let mut body = error.to_error_body();
    body.message = sanitized_msg;
    RpcResponse {
        id: id.to_owned(),
        success: false,
        result: None,
        error: Some(body),
    }
}

fn extract_string(payload: &Value, key: &str) -> Option<String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn derive_json_rpc_idempotency_key(
    method: &str,
    request_id: &str,
    payload: &Value,
) -> Result<String, RpcError> {
    if request_id.trim().is_empty() {
        return Err(RpcError::InvalidParams {
            message: format!("{method} requires a non-empty JSON-RPC request id"),
        });
    }
    let seed = json!({
        "method": method,
        "requestId": request_id,
        "payload": payload,
    });
    let mut canonical = String::new();
    write_canonical_json(&seed, &mut canonical);
    let digest = Sha256::digest(canonical.as_bytes());
    Ok(format!("json-rpc:v1:{}", hex::encode(digest)))
}

fn write_canonical_json(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => out.push_str(&value.to_string()),
        Value::String(value) => {
            let encoded = serde_json::to_string(value).expect("string serialization cannot fail");
            out.push_str(&encoded);
        }
        Value::Array(values) => {
            out.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical_json(value, out);
            }
            out.push(']');
        }
        Value::Object(values) => {
            out.push('{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                let encoded = serde_json::to_string(key).expect("string serialization cannot fail");
                out.push_str(&encoded);
                out.push(':');
                write_canonical_json(
                    values.get(key).expect("key was collected from this object"),
                    out,
                );
            }
            out.push('}');
        }
    }
}
