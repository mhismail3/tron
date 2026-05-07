//! WebSocket message dispatch — parses incoming text as `JsonRpcRequest` and
//! routes through the `JsonRpcTransportRegistry`.

use crate::server::services::context::ServerCapabilityContext;
use crate::server::transport::json_rpc::registry::JsonRpcTransportRegistry;
use crate::server::transport::json_rpc::types::{JsonRpcRequest, JsonRpcResponse};
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
    pub response: JsonRpcResponse,
}

/// Handle an incoming WebSocket text message.
///
/// Parses the message as an `JsonRpcRequest`, dispatches to the registry, and
/// returns the serialized `JsonRpcResponse` along with the method name.
#[instrument(skip_all, fields(method, session_id))]
pub async fn handle_message(
    message: &str,
    registry: &JsonRpcTransportRegistry,
    ctx: &ServerCapabilityContext,
) -> HandleResult {
    handle_message_with_transport(message, registry, ctx, None).await
}

/// Handle an incoming WebSocket message with the caller's connection id for
/// tracing. JSON-RPC request ids remain correlation ids only; capability
/// idempotency must be provided explicitly in `engine.invoke` payloads.
#[instrument(skip_all, fields(method, session_id))]
pub async fn handle_message_with_transport(
    message: &str,
    registry: &JsonRpcTransportRegistry,
    ctx: &ServerCapabilityContext,
    _transport_id: Option<&str>,
) -> HandleResult {
    let request: JsonRpcRequest = match serde_json::from_str(message) {
        Ok(r) => r,
        Err(e) => {
            warn!("invalid JSON received");
            let resp =
                JsonRpcResponse::error("unknown", "INVALID_PARAMS", format!("Invalid JSON: {e}"));
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

    let response = registry.dispatch(request, ctx).await;
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
