use serde_json::{Value, json};

use crate::engine::{ActorKind, CausalContext, TraceId};
use crate::server::capabilities::catalog::{self, TransportIdempotencyMode};
use crate::server::capabilities::error_mapping::engine_error_to_capability_error;
use crate::server::capabilities::errors::CapabilityError;
use crate::server::services::context::ServerCapabilityContext;
use crate::server::transport::json_rpc::registry::JsonRpcTransportRegistry;
use crate::server::transport::json_rpc::types::{JsonRpcRequest, JsonRpcResponse};

use super::SYSTEM_AUTHORITY_GRANT;
use crate::server::transport::engine::{EngineTransportRequest, dispatch_engine_transport_request};

/// Dispatch one registered JSON-RPC transport method through its engine trigger.
pub async fn dispatch_engine_json_rpc_method(
    registry: &JsonRpcTransportRegistry,
    ctx: &ServerCapabilityContext,
    request: &JsonRpcRequest,
) -> JsonRpcResponse {
    let envelope = match request_to_engine_transport(registry, request) {
        Ok(Some(envelope)) => envelope,
        Ok(None) => {
            return capability_error_response(
                &request.id,
                CapabilityError::Internal {
                    message: format!(
                        "registered JSON-RPC method {} has no engine trigger",
                        request.method
                    ),
                },
            );
        }
        Err(error) => return capability_error_response(&request.id, error),
    };

    let correlation_id = envelope.correlation_id.clone();
    match dispatch_engine_transport_request(ctx, envelope).await {
        Ok(value) => JsonRpcResponse::success(&correlation_id, value),
        Err(error) => capability_error_response(&correlation_id, error),
    }
}

/// Translate a JSON-RPC `engine.*` wire request into the protocol-neutral engine envelope.
pub(super) fn request_to_engine_transport(
    registry: &JsonRpcTransportRegistry,
    request: &JsonRpcRequest,
) -> Result<Option<EngineTransportRequest>, CapabilityError> {
    if !registry.has_method(&request.method) {
        return Ok(None);
    }
    let spec = catalog::public_json_rpc_spec_for_method(&request.method)
        .map_err(engine_error_to_capability_error)?;
    let Some(spec) = spec else {
        return Ok(None);
    };
    let params_payload = payload_for_json_rpc_method(spec.method, request.params.clone())?;
    reject_noncanonical_target(spec.method, &params_payload)?;
    let domain_authority_scope = spec
        .authority_scope
        .ok_or_else(|| CapabilityError::Internal {
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
                let key = extract_string(&params_payload, "idempotencyKey").ok_or_else(|| {
                    CapabilityError::InvalidParams {
                        message: format!(
                            "{} requires non-empty explicit idempotencyKey",
                            spec.method
                        ),
                    }
                })?;
                if key.trim().is_empty() {
                    return Err(CapabilityError::InvalidParams {
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
    let payload = strip_transport_only_fields(spec.method, params_payload);

    Ok(Some(EngineTransportRequest {
        correlation_id: request.id.clone(),
        transport: "json_rpc".to_owned(),
        public_method: request.method.clone(),
        function_id: spec.function_id,
        trigger_id: catalog::json_rpc_trigger_id_for_method(spec.method)
            .map_err(engine_error_to_capability_error)?,
        payload,
        causal_context,
    }))
}

pub(super) fn payload_for_json_rpc_method(
    method: &'static str,
    params: Option<Value>,
) -> Result<Value, CapabilityError> {
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

fn reject_noncanonical_target(method: &str, payload: &Value) -> Result<(), CapabilityError> {
    if method != "engine.invoke" {
        return Ok(());
    }
    let Some(function_id) = extract_string(payload, "functionId") else {
        return Ok(());
    };
    let Some((namespace, operation)) = function_id.split_once("::") else {
        return Err(CapabilityError::InvalidParams {
            message: "engine.invoke requires a canonical function id".to_owned(),
        });
    };
    if namespace == "rpc"
        || namespace.is_empty()
        || operation.is_empty()
        || function_id.contains('.')
    {
        return Err(CapabilityError::InvalidParams {
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

fn capability_error_response(id: &str, error: CapabilityError) -> JsonRpcResponse {
    let sanitized_msg = crate::server::capabilities::validation::sanitize_error_message(&error);
    let mut body = crate::server::transport::json_rpc::errors::to_error_body(&error);
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
