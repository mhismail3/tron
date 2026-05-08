use serde_json::Value;

use crate::server::capabilities::errors::CapabilityError;
use crate::server::services::context::ServerCapabilityContext;
use crate::server::transport::engine::{
    EngineTransportBuildRequest, EngineTransportContext, EngineTransportKind,
    EngineTransportRequest, build_engine_transport_request, dispatch_engine_transport_request,
    params_or_empty,
};
use crate::server::transport::json_rpc::types::{JsonRpcRequest, JsonRpcResponse};

use crate::server::transport::json_rpc::registry::JsonRpcTransportRegistry;

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
    let params_payload = params_or_empty(request.params.clone());
    build_engine_transport_request(EngineTransportBuildRequest {
        correlation_id: request.id.clone(),
        transport: EngineTransportKind::JsonRpc,
        public_method: request.method.clone(),
        context: context_from_payload(&params_payload),
        params_payload,
    })
}

pub(super) fn capability_error_response(id: &str, error: CapabilityError) -> JsonRpcResponse {
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

fn context_from_payload(payload: &Value) -> EngineTransportContext {
    EngineTransportContext {
        session_id: extract_string(payload, "sessionId"),
        workspace_id: extract_string(payload, "workspaceId"),
        trace_id: extract_string(payload, "traceId"),
        parent_invocation_id: extract_string(payload, "parentInvocationId"),
        authority_scopes: payload
            .get("authorityScopes")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(ToOwned::to_owned)
                    .collect()
            })
            .unwrap_or_default(),
    }
}
