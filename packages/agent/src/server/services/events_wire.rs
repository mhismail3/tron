//! Event wire-format helpers.
//!
//! Canonical `events::*` capabilities and stream pumps use these helpers when
//! they need the WebSocket JSON shape expected by clients.

use crate::events::sqlite::row_types::EventRow;
use serde_json::Value;

/// WebSocket-compatible event payload used by server capability streams.
pub(crate) type ServerEventPayload = crate::server::transport::json_rpc::types::JsonRpcEvent;

/// Convert an `EventRow` to wire format (camelCase).
pub(crate) fn event_row_to_wire(row: &EventRow) -> Value {
    let mut obj = serde_json::json!({
        "id": row.id,
        "type": row.event_type,
        "sessionId": row.session_id,
        "timestamp": row.timestamp,
        "sequence": row.sequence,
        "depth": row.depth,
        "workspaceId": row.workspace_id,
    });

    let m = obj.as_object_mut().expect("just created as object");

    if let Some(ref parent_id) = row.parent_id {
        let _ = m.insert("parentId".into(), Value::String(parent_id.clone()));
    }
    if let Some(ref role) = row.role {
        let _ = m.insert("role".into(), Value::String(role.clone()));
    }
    if let Some(ref tool_name) = row.tool_name {
        let _ = m.insert("toolName".into(), Value::String(tool_name.clone()));
    }
    if let Some(ref tool_call_id) = row.tool_call_id {
        let _ = m.insert("toolCallId".into(), Value::String(tool_call_id.clone()));
    }
    if let Some(turn) = row.turn {
        let _ = m.insert("turn".into(), Value::Number(turn.into()));
    }
    if let Some(input_tokens) = row.input_tokens {
        let _ = m.insert("inputTokens".into(), Value::Number(input_tokens.into()));
    }
    if let Some(output_tokens) = row.output_tokens {
        let _ = m.insert("outputTokens".into(), Value::Number(output_tokens.into()));
    }
    if let Some(ref model) = row.model {
        let _ = m.insert("model".into(), Value::String(model.clone()));
    }
    if let Some(latency_ms) = row.latency_ms {
        let _ = m.insert("latency".into(), Value::Number(latency_ms.into()));
    }
    if let Some(ref stop_reason) = row.stop_reason {
        let _ = m.insert("stopReason".into(), Value::String(stop_reason.clone()));
    }
    if let Some(has_thinking) = row.has_thinking {
        let _ = m.insert("hasThinking".into(), Value::Bool(has_thinking != 0));
    }
    if let Some(ref provider_type) = row.provider_type {
        let _ = m.insert("providerType".into(), Value::String(provider_type.clone()));
    }
    if let Some(cost) = row.cost {
        let _ = m.insert("cost".into(), serde_json::json!(cost));
    }

    // Parse payload JSON string into a Value
    if let Ok(payload) = serde_json::from_str::<Value>(&row.payload) {
        let _ = m.insert("payload".into(), payload);
    }

    obj
}
