use async_trait::async_trait;
use serde_json::{Value, json};

use crate::engine::{ActorKind, CausalContext, FunctionId, Invocation, TraceId};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::registry::{MethodHandler, MethodRegistry};
use crate::server::rpc::types::{RpcRequest, RpcResponse};

use super::specs::{self, RpcMigrationState};
use super::{RPC_AUTHORITY_GRANT, RPC_READ_AUTHORITY, engine_error_to_rpc, result_to_rpc};

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
        let mut causal_context = rpc_causal_context();
        if let Some(session_id) = extract_string(&params_payload, "sessionId") {
            causal_context = causal_context.with_session_id(session_id);
        }
        if let Some(workspace_id) = extract_string(&params_payload, "workspaceId") {
            causal_context = causal_context.with_workspace_id(workspace_id);
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
}

pub(super) fn payload_for_rpc_method(
    ctx: &RpcContext,
    method: &'static str,
    params: Option<Value>,
) -> Value {
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

pub(super) fn rpc_causal_context() -> CausalContext {
    CausalContext::new(
        specs::actor_id("rpc-client").expect("valid static rpc actor id"),
        ActorKind::Client,
        specs::grant_id(RPC_AUTHORITY_GRANT).expect("valid static rpc grant id"),
        TraceId::generate(),
    )
    .with_scope(RPC_READ_AUTHORITY)
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
