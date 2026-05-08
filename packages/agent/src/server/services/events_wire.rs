//! Neutral server event payloads and wire conversion helpers.
//!
//! Domain capabilities and services publish [`ServerEventPayload`] values into
//! engine streams. Client transports convert those neutral payloads into their
//! own wire shapes at the boundary.

use crate::events::sqlite::row_types::EventRow;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Transport-neutral event payload used by server capability streams.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ServerEventPayload {
    /// Event type, e.g. `agent.text_delta`.
    #[serde(rename = "type")]
    pub event_type: String,
    /// Associated session, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Associated workspace, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// ISO-8601 timestamp.
    pub timestamp: String,
    /// Event payload.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    /// Associated run, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    /// Monotonic per-session sequence number.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sequence: Option<i64>,
    /// Engine trace id, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Parent engine invocation id, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_invocation_id: Option<String>,
    /// Durable source event id, when projected from persisted session truth.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_event_id: Option<String>,
    /// Durable source sequence, when projected from persisted session truth.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_sequence: Option<i64>,
    /// Engine stream cursor assigned at publication/poll time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream_cursor: Option<u64>,
}

impl ServerEventPayload {
    /// Create a new neutral server event with the current UTC timestamp.
    pub(crate) fn new(
        event_type: impl Into<String>,
        session_id: Option<String>,
        data: Option<Value>,
    ) -> Self {
        Self {
            event_type: event_type.into(),
            session_id,
            workspace_id: None,
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            data,
            run_id: None,
            sequence: None,
            trace_id: None,
            parent_invocation_id: None,
            source_event_id: None,
            source_sequence: None,
            stream_cursor: None,
        }
    }

    /// Convert to the current `/ws` event wire shape.
    pub(crate) fn to_json_rpc_event(
        &self,
    ) -> crate::server::transport::json_rpc::types::JsonRpcEvent {
        crate::server::transport::json_rpc::types::JsonRpcEvent {
            event_type: self.event_type.clone(),
            session_id: self.session_id.clone(),
            timestamp: self.timestamp.clone(),
            data: self.data.clone(),
            run_id: self.run_id.clone(),
            sequence: self.sequence,
        }
    }
}

/// Convert an `EventRow` to the neutral server event payload.
pub(crate) fn event_row_to_server_payload(row: &EventRow) -> ServerEventPayload {
    let data = serde_json::from_str::<Value>(&row.payload).ok();
    let mut payload =
        ServerEventPayload::new(row.event_type.clone(), Some(row.session_id.clone()), data);
    payload.workspace_id = Some(row.workspace_id.clone());
    payload.timestamp.clone_from(&row.timestamp);
    payload.sequence = Some(row.sequence);
    payload.source_event_id = Some(row.id.clone());
    payload.source_sequence = Some(row.sequence);
    payload
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn server_event_payload_is_not_json_rpc_event_shaped() {
        let mut payload = ServerEventPayload::new(
            "agent.updated",
            Some("session-1".to_owned()),
            Some(json!({"ok": true})),
        );
        payload.workspace_id = Some("workspace-1".to_owned());
        payload.trace_id = Some("trace-1".to_owned());
        payload.parent_invocation_id = Some("invocation-1".to_owned());
        payload.source_event_id = Some("event-1".to_owned());
        payload.source_sequence = Some(7);
        payload.stream_cursor = Some(42);

        let value = serde_json::to_value(&payload).unwrap();
        assert_eq!(value["type"], "agent.updated");
        assert_eq!(value["workspaceId"], "workspace-1");
        assert_eq!(value["traceId"], "trace-1");
        assert_eq!(value["parentInvocationId"], "invocation-1");
        assert_eq!(value["sourceEventId"], "event-1");
        assert_eq!(value["sourceSequence"], 7);
        assert_eq!(value["streamCursor"], 42);
        assert!(value.get("__rpcEvent").is_none());
    }

    #[test]
    fn json_rpc_conversion_preserves_current_ws_shape() {
        let mut payload = ServerEventPayload::new(
            "agent.updated",
            Some("session-1".to_owned()),
            Some(json!({"ok": true})),
        );
        payload.run_id = Some("run-1".to_owned());
        payload.sequence = Some(9);
        payload.trace_id = Some("trace-1".to_owned());

        let event = payload.to_json_rpc_event();
        assert_eq!(event.event_type, "agent.updated");
        assert_eq!(event.session_id.as_deref(), Some("session-1"));
        assert_eq!(event.run_id.as_deref(), Some("run-1"));
        assert_eq!(event.sequence, Some(9));
        assert_eq!(event.data, Some(json!({"ok": true})));
    }
}
