use serde_json::{Value, json};

use crate::engine::{
    ActorKind, CausalContext, EngineTriggerRuntime, FunctionId, TraceId, TriggerDispatchRequest,
    TriggerId,
};
use crate::server::capabilities::catalog::{self, TransportIdempotencyMode};
use crate::server::services::context::ServerCapabilityContext;
use crate::server::transport::json_rpc::errors::RpcError;
use crate::server::transport::json_rpc::registry::JsonRpcTransportRegistry;
use crate::server::transport::json_rpc::types::{JsonRpcRequest, JsonRpcResponse};

use super::{SYSTEM_AUTHORITY_GRANT, engine_error_to_rpc, result_to_rpc};

/// Fully typed invocation envelope produced by the JSON-RPC transport trigger.
#[derive(Clone, Debug, PartialEq)]
pub struct JsonRpcEngineInvocation {
    /// Original JSON-RPC request id.
    pub request_id: String,
    /// Original JSON-RPC method.
    pub method: String,
    /// Canonical domain function id targeted by the JSON-RPC trigger.
    pub function_id: FunctionId,
    /// JSON-RPC trigger id that caused the invocation.
    pub trigger_id: TriggerId,
    /// Payload delivered to the engine function.
    pub params_payload: Value,
    /// Causal authority and trace metadata for the engine invocation.
    pub causal_context: CausalContext,
}

impl JsonRpcEngineInvocation {
    /// Build the trigger envelope for a public `engine.*` transport method.
    pub fn from_request(
        registry: &JsonRpcTransportRegistry,
        _ctx: &ServerCapabilityContext,
        request: &JsonRpcRequest,
    ) -> Result<Option<Self>, RpcError> {
        let spec = catalog::public_json_rpc_spec_for_method(registry, &request.method)
            .map_err(engine_error_to_rpc)?;
        let Some(spec) = spec else {
            return Ok(None);
        };
        let params_payload = payload_for_json_rpc_method(spec.method, request.params.clone())?;
        reject_noncanonical_target(spec.method, &params_payload)?;
        let domain_authority_scope = spec.authority_scope.ok_or_else(|| RpcError::Internal {
            message: format!(
                "engine transport method {} is missing an authority scope",
                spec.method
            ),
        })?;
        let mut causal_context =
            transport_causal_context_for_method(spec.method, domain_authority_scope);
        if spec.method == "engine.promote" {
            causal_context = causal_context
                .with_scope("engine.promote.workspace")
                .with_scope("engine.promote.system");
        }
        if spec.method == "engine.invoke" {
            for scope in target_authority_scopes_for_engine_invoke(&params_payload) {
                causal_context = causal_context.with_scope(scope);
            }
        }
        if let Some(session_id) = extract_string(&params_payload, "sessionId") {
            causal_context = causal_context.with_session_id(session_id);
        }
        if let Some(workspace_id) = extract_string(&params_payload, "workspaceId") {
            causal_context = causal_context.with_workspace_id(workspace_id);
        }
        if spec.effect_class.is_mutating() {
            match spec.idempotency_mode {
                TransportIdempotencyMode::ExplicitRequired => {
                    let key =
                        extract_string(&params_payload, "idempotencyKey").ok_or_else(|| {
                            RpcError::InvalidParams {
                                message: format!(
                                    "{} requires non-empty explicit idempotencyKey",
                                    spec.method
                                ),
                            }
                        })?;
                    if key.trim().is_empty() {
                        return Err(RpcError::InvalidParams {
                            message: format!(
                                "{} requires non-empty explicit idempotencyKey",
                                spec.method
                            ),
                        });
                    }
                    causal_context = causal_context.with_idempotency_key(key);
                }
                TransportIdempotencyMode::NotRequired => {}
            }
        }
        let params_payload = strip_transport_only_fields(spec.method, params_payload);

        Ok(Some(Self {
            request_id: request.id.clone(),
            method: request.method.clone(),
            function_id: spec.function_id,
            trigger_id: catalog::json_rpc_trigger_id_for_method(spec.method)
                .map_err(engine_error_to_rpc)?,
            params_payload,
            causal_context,
        }))
    }
}

/// Dispatch one registered JSON-RPC transport method through its engine trigger.
pub async fn dispatch_json_rpc_transport(
    registry: &JsonRpcTransportRegistry,
    ctx: &ServerCapabilityContext,
    request: &JsonRpcRequest,
) -> JsonRpcResponse {
    let envelope = match JsonRpcEngineInvocation::from_request(registry, ctx, request) {
        Ok(Some(envelope)) => envelope,
        Ok(None) => {
            return rpc_error_response(
                &request.id,
                RpcError::Internal {
                    message: format!(
                        "registered JSON-RPC method {} has no engine trigger",
                        request.method
                    ),
                },
            );
        }
        Err(error) => return rpc_error_response(&request.id, error),
    };

    let actor_id = envelope.causal_context.actor_id.clone();
    let actor_kind = envelope.causal_context.actor_kind;
    let authority_scopes = envelope.causal_context.authority_scopes.clone();
    let trace_id = Some(envelope.causal_context.trace_id.clone());
    let session_id = envelope.causal_context.session_id.clone();
    let workspace_id = envelope.causal_context.workspace_id.clone();
    let idempotency_key = envelope.causal_context.idempotency_key.clone();
    let mut dispatch = TriggerDispatchRequest::new(
        envelope.trigger_id,
        envelope.params_payload,
        actor_id,
        actor_kind,
    );
    dispatch.authority_scopes = authority_scopes;
    dispatch.trace_id = trace_id;
    dispatch.session_id = session_id;
    dispatch.workspace_id = workspace_id;
    dispatch.idempotency_key = idempotency_key;
    let result = EngineTriggerRuntime::dispatch(&ctx.engine_host, dispatch).await;
    match result_to_rpc(result) {
        Ok(value) => JsonRpcResponse::success(&envelope.request_id, value),
        Err(error) => rpc_error_response(&envelope.request_id, error),
    }
}

pub(super) fn payload_for_json_rpc_method(
    method: &'static str,
    params: Option<Value>,
) -> Result<Value, RpcError> {
    let _ = method;
    Ok(params.unwrap_or_else(|| json!({})))
}

fn transport_causal_context_for_method(method: &str, scope: &str) -> CausalContext {
    let actor_kind = if method == "engine.promote" {
        ActorKind::User
    } else {
        ActorKind::Client
    };
    let actor_id = if method == "engine.promote" {
        "engine-user"
    } else {
        "engine-client"
    };
    CausalContext::new(
        catalog::actor_id(actor_id).expect("valid static transport actor id"),
        actor_kind,
        catalog::grant_id(SYSTEM_AUTHORITY_GRANT).expect("valid static transport grant id"),
        TraceId::generate(),
    )
    .with_scope(scope)
}

fn reject_noncanonical_target(method: &str, payload: &Value) -> Result<(), RpcError> {
    if method != "engine.invoke" {
        return Ok(());
    }
    let Some(function_id) = extract_string(payload, "functionId") else {
        return Ok(());
    };
    if function_id
        .split_once("::")
        .is_some_and(|(namespace, _)| namespace == "rpc")
    {
        return Err(RpcError::InvalidParams {
            message: "engine.invoke requires a canonical function id".to_owned(),
        });
    }
    Ok(())
}

fn target_authority_scopes_for_engine_invoke(payload: &Value) -> Vec<String> {
    let Some(function_id) = extract_string(payload, "functionId") else {
        return Vec::new();
    };
    let Some((namespace, _operation)) = function_id.split_once("::") else {
        return Vec::new();
    };
    match namespace {
        "engine" => vec![
            "engine.read".to_owned(),
            "engine.promote.workspace".to_owned(),
            "engine.promote.system".to_owned(),
        ],
        "approval" => vec!["approval.read".to_owned(), "approval.resolve".to_owned()],
        other => vec![format!("{other}.read"), format!("{other}.write")],
    }
}

fn strip_transport_only_fields(method: &str, mut payload: Value) -> Value {
    if method.starts_with("engine.") && method != "engine.promote" {
        if let Some(object) = payload.as_object_mut() {
            let _ = object.remove("sessionId");
            let _ = object.remove("workspaceId");
        }
    }
    if method == "engine.promote" {
        if let Some(object) = payload.as_object_mut() {
            let _ = object.remove("idempotencyKey");
        }
    }
    payload
}

fn rpc_error_response(id: &str, error: RpcError) -> JsonRpcResponse {
    let sanitized_msg =
        crate::server::transport::json_rpc::validation::sanitize_error_message(&error);
    let mut body = error.to_error_body();
    body.message = sanitized_msg;
    JsonRpcResponse {
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
