//! JSON-RPC wire-format types for the engine WebSocket transport.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Incoming RPC request from a client.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsonRpcRequest {
    /// Unique request identifier.
    pub id: String,
    /// Public transport method name, such as `engine.invoke`.
    pub method: String,
    /// Optional parameters object.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

/// Outgoing RPC response to a client.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    /// Echoed request identifier.
    pub id: String,
    /// Whether the call succeeded.
    pub success: bool,
    /// Result payload (present when `success == true`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// Error payload (present when `success == false`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcErrorBody>,
}

/// Structured error body inside an `JsonRpcResponse`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonRpcErrorBody {
    /// Machine-readable error code (e.g. `SESSION_NOT_FOUND`).
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Optional structured details.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

/// Server-pushed event.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsonRpcEvent {
    /// Event type (e.g. `agent.text_delta`).
    #[serde(rename = "type")]
    pub event_type: String,
    /// Associated session, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
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
}

impl JsonRpcResponse {
    /// Build a success response.
    pub fn success(id: impl Into<String>, result: Value) -> Self {
        Self {
            id: id.into(),
            success: true,
            result: Some(result),
            error: None,
        }
    }

    /// Build an error response.
    pub fn error(
        id: impl Into<String>,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            success: false,
            result: None,
            error: Some(JsonRpcErrorBody {
                code: code.into(),
                message: message.into(),
                details: None,
            }),
        }
    }

    /// Build an error response with structured details.
    pub fn error_with_details(
        id: impl Into<String>,
        code: impl Into<String>,
        message: impl Into<String>,
        details: Value,
    ) -> Self {
        Self {
            id: id.into(),
            success: false,
            result: None,
            error: Some(JsonRpcErrorBody {
                code: code.into(),
                message: message.into(),
                details: Some(details),
            }),
        }
    }
}

impl JsonRpcEvent {
    /// Create a new event with the current UTC timestamp.
    pub fn new(
        event_type: impl Into<String>,
        session_id: Option<String>,
        data: Option<Value>,
    ) -> Self {
        Self {
            event_type: event_type.into(),
            session_id,
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            data,
            run_id: None,
            sequence: None,
        }
    }

    /// Attach a run ID.
    #[must_use]
    pub fn with_run_id(mut self, run_id: impl Into<String>) -> Self {
        self.run_id = Some(run_id.into());
        self
    }

    /// Attach a sequence number.
    #[must_use]
    pub fn with_sequence(mut self, seq: Option<i64>) -> Self {
        self.sequence = seq;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── JsonRpcRequest serde ────────────────────────────────────────────

    #[test]
    fn request_roundtrip_with_params() {
        let req = JsonRpcRequest {
            id: "req_1".into(),
            method: "engine.invoke".into(),
            params: Some(
                json!({"functionId": "session::create", "payload": {"workingDirectory": "/tmp"}}),
            ),
        };
        let json = serde_json::to_string(&req).unwrap();
        let back: JsonRpcRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, "req_1");
        assert_eq!(back.method, "engine.invoke");
        assert!(back.params.is_some());
    }

    #[test]
    fn request_roundtrip_without_params() {
        let req = JsonRpcRequest {
            id: "req_2".into(),
            method: "engine.discover".into(),
            params: None,
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(!json.contains("params"));
        let back: JsonRpcRequest = serde_json::from_str(&json).unwrap();
        assert!(back.params.is_none());
    }

    #[test]
    fn request_with_extra_field_still_parses() {
        let raw = r#"{"id": "req_3", "method": "engine.invoke", "params": {"functionId": "agent::prompt", "payload": {"prompt": "hi"}, "idempotencyKey": "xyz"}}"#;
        let req: JsonRpcRequest = serde_json::from_str(raw).unwrap();
        assert_eq!(req.id, "req_3");
        assert_eq!(req.method, "engine.invoke");
    }

    // ── JsonRpcResponse success ─────────────────────────────────────────

    #[test]
    fn response_success_serde() {
        let resp = JsonRpcResponse::success("req_1", json!({"sessionId": "sess_1"}));
        let json = serde_json::to_string(&resp).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["id"], "req_1");
        assert_eq!(v["success"], true);
        assert!(v["result"].is_object());
        assert!(v.get("error").is_none());
    }

    #[test]
    fn response_success_has_no_error_field() {
        let resp = JsonRpcResponse::success("r1", json!(42));
        let json = serde_json::to_string(&resp).unwrap();
        assert!(!json.contains("error"));
    }

    // ── JsonRpcResponse error ───────────────────────────────────────────

    #[test]
    fn response_error_serde() {
        let resp = JsonRpcResponse::error("req_2", "SESSION_NOT_FOUND", "No such session");
        let json = serde_json::to_string(&resp).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["id"], "req_2");
        assert_eq!(v["success"], false);
        assert!(v.get("result").is_none());
        assert_eq!(v["error"]["code"], "SESSION_NOT_FOUND");
        assert_eq!(v["error"]["message"], "No such session");
        assert!(v["error"].get("details").is_none());
    }

    #[test]
    fn response_error_has_no_result_field() {
        let resp = JsonRpcResponse::error("r1", "ERR", "msg");
        let json = serde_json::to_string(&resp).unwrap();
        assert!(!json.contains("result"));
    }

    // ── JsonRpcResponse error_with_details ──────────────────────────────

    #[test]
    fn response_error_with_details_serde() {
        let resp = JsonRpcResponse::error_with_details(
            "req_3",
            "INVALID_PARAMS",
            "Bad param",
            json!({"field": "path"}),
        );
        let json = serde_json::to_string(&resp).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["error"]["details"]["field"], "path");
    }

    // ── JsonRpcErrorBody ────────────────────────────────────────────────

    #[test]
    fn error_body_roundtrip() {
        let body = JsonRpcErrorBody {
            code: "INTERNAL_ERROR".into(),
            message: "Something went wrong".into(),
            details: Some(json!({"trace": "abc"})),
        };
        let json = serde_json::to_string(&body).unwrap();
        let back: JsonRpcErrorBody = serde_json::from_str(&json).unwrap();
        assert_eq!(back.code, "INTERNAL_ERROR");
        assert_eq!(back.details.unwrap()["trace"], "abc");
    }

    #[test]
    fn error_body_without_details() {
        let body = JsonRpcErrorBody {
            code: "NOT_FOUND".into(),
            message: "gone".into(),
            details: None,
        };
        let json = serde_json::to_string(&body).unwrap();
        assert!(!json.contains("details"));
    }

    // ── JsonRpcEvent ────────────────────────────────────────────────────

    #[test]
    fn event_roundtrip_with_all_fields() {
        let ev = JsonRpcEvent {
            event_type: "agent.text_delta".into(),
            session_id: Some("sess_1".into()),
            timestamp: "2026-02-13T15:30:00.000Z".into(),
            data: Some(json!({"text": "hello"})),
            run_id: Some("run_1".into()),
            sequence: Some(42),
        };
        let json = serde_json::to_string(&ev).unwrap();
        let back: JsonRpcEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back.event_type, "agent.text_delta");
        assert_eq!(back.session_id.as_deref(), Some("sess_1"));
        assert_eq!(back.run_id.as_deref(), Some("run_1"));
    }

    #[test]
    fn event_roundtrip_minimal() {
        let ev = JsonRpcEvent {
            event_type: "system.ready".into(),
            session_id: None,
            timestamp: "2026-01-01T00:00:00.000Z".into(),
            data: None,
            run_id: None,
            sequence: None,
        };
        let json = serde_json::to_string(&ev).unwrap();
        assert!(!json.contains("sessionId"));
        assert!(!json.contains("data"));
        assert!(!json.contains("runId"));
    }

    #[test]
    fn event_new_sets_timestamp() {
        let ev = JsonRpcEvent::new("test.event", None, None);
        assert!(!ev.timestamp.is_empty());
        assert!(ev.run_id.is_none());
    }

    #[test]
    fn event_with_run_id() {
        let ev = JsonRpcEvent::new("test.event", Some("s1".into()), None).with_run_id("run_42");
        assert_eq!(ev.run_id.as_deref(), Some("run_42"));
    }

    #[test]
    fn event_type_field_serializes_as_type() {
        let ev = JsonRpcEvent::new("agent.start", None, None);
        let json = serde_json::to_string(&ev).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert!(v.get("type").is_some());
        assert!(v.get("event_type").is_none());
        assert!(v.get("eventType").is_none());
    }

    // ── Wire format fixture tests ───────────────────────────────────

    #[test]
    fn wire_format_request() {
        let raw = r#"{"id": "req_1", "method": "engine.invoke", "params": {"functionId": "session::create", "payload": {"workingDirectory": "/tmp"}}}"#;
        let req: JsonRpcRequest = serde_json::from_str(raw).unwrap();
        assert_eq!(req.id, "req_1");
        assert_eq!(req.method, "engine.invoke");
        let params = req.params.unwrap();
        assert_eq!(params["functionId"], "session::create");
        assert_eq!(params["payload"]["workingDirectory"], "/tmp");
    }

    #[test]
    fn wire_format_success_response() {
        let raw = r#"{"id": "req_1", "success": true, "result": {"sessionId": "sess_123"}}"#;
        let resp: JsonRpcResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.id, "req_1");
        assert!(resp.success);
        assert_eq!(resp.result.unwrap()["sessionId"], "sess_123");
        assert!(resp.error.is_none());
    }

    #[test]
    fn wire_format_error_response() {
        let raw = r#"{"id": "req_1", "success": false, "error": {"code": "SESSION_NOT_FOUND", "message": "No session", "details": null}}"#;
        let resp: JsonRpcResponse = serde_json::from_str(raw).unwrap();
        assert!(!resp.success);
        assert!(resp.result.is_none());
        let err = resp.error.unwrap();
        assert_eq!(err.code, "SESSION_NOT_FOUND");
        assert_eq!(err.message, "No session");
    }

    #[test]
    fn wire_format_event() {
        let raw = r#"{"type": "agent.text_delta", "sessionId": "sess_123", "timestamp": "2026-02-13T15:30:00.000Z", "data": {"text": "hi"}, "runId": "run_456"}"#;
        let ev: JsonRpcEvent = serde_json::from_str(raw).unwrap();
        assert_eq!(ev.event_type, "agent.text_delta");
        assert_eq!(ev.session_id.as_deref(), Some("sess_123"));
        assert_eq!(ev.run_id.as_deref(), Some("run_456"));
        assert_eq!(ev.data.unwrap()["text"], "hi");
    }

    #[test]
    fn wire_format_extra_fields_ignored() {
        let raw = r#"{"id": "req_5", "method": "engine.invoke", "params": {}, "extra": true}"#;
        let req: JsonRpcRequest = serde_json::from_str(raw).unwrap();
        assert_eq!(req.id, "req_5");
    }

    #[test]
    fn response_success_constructor_fields() {
        let resp = JsonRpcResponse::success("id1", json!({"ok": true}));
        assert_eq!(resp.id, "id1");
        assert!(resp.success);
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["ok"], true);
    }

    #[test]
    fn response_error_constructor_fields() {
        let resp = JsonRpcResponse::error("id2", "CODE", "msg");
        assert_eq!(resp.id, "id2");
        assert!(!resp.success);
        assert!(resp.result.is_none());
        let err = resp.error.unwrap();
        assert_eq!(err.code, "CODE");
        assert_eq!(err.message, "msg");
        assert!(err.details.is_none());
    }

    #[test]
    fn error_with_details_constructor_fields() {
        let resp = JsonRpcResponse::error_with_details("id3", "C", "m", json!({"x": 1}));
        let err = resp.error.unwrap();
        assert_eq!(err.details.unwrap()["x"], 1);
    }

    // ── JsonRpcEvent sequence tests ──

    #[test]
    fn rpc_event_sequence_serialized() {
        let ev = JsonRpcEvent::new("test.event", Some("s1".into()), None).with_sequence(Some(5));
        let json = serde_json::to_string(&ev).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["sequence"], 5);
    }

    #[test]
    fn rpc_event_no_sequence_omitted() {
        let ev = JsonRpcEvent::new("test.event", Some("s1".into()), None);
        assert!(ev.sequence.is_none());
        let json = serde_json::to_string(&ev).unwrap();
        assert!(!json.contains("sequence"));
    }
}
