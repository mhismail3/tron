//! RPC wire-format types matching the iOS WebSocket protocol.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Incoming RPC request from a client.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RpcRequest {
    /// Unique request identifier.
    pub id: String,
    /// Method name (e.g. `session.create`).
    pub method: String,
    /// Optional parameters object.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
    /// Optional idempotency key for deduplication.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

/// Outgoing RPC response to a client.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RpcResponse {
    /// Echoed request identifier.
    pub id: String,
    /// Whether the call succeeded.
    pub success: bool,
    /// Result payload (present when `success == true`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// Error payload (present when `success == false`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcErrorBody>,
}

/// Structured error body inside an `RpcResponse`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RpcErrorBody {
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
pub struct RpcEvent {
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
}

impl RpcResponse {
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
    pub fn error(id: impl Into<String>, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            success: false,
            result: None,
            error: Some(RpcErrorBody {
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
            error: Some(RpcErrorBody {
                code: code.into(),
                message: message.into(),
                details: Some(details),
            }),
        }
    }
}

impl RpcEvent {
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
        }
    }

    /// Attach a run ID.
    #[must_use]
    pub fn with_run_id(mut self, run_id: impl Into<String>) -> Self {
        self.run_id = Some(run_id.into());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── RpcRequest serde ────────────────────────────────────────────

    #[test]
    fn request_roundtrip_with_params() {
        let req = RpcRequest {
            id: "req_1".into(),
            method: "session.create".into(),
            params: Some(json!({"workingDirectory": "/tmp"})),
            idempotency_key: None,
        };
        let json = serde_json::to_string(&req).unwrap();
        let back: RpcRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, "req_1");
        assert_eq!(back.method, "session.create");
        assert!(back.params.is_some());
        assert!(back.idempotency_key.is_none());
    }

    #[test]
    fn request_roundtrip_without_params() {
        let req = RpcRequest {
            id: "req_2".into(),
            method: "system.ping".into(),
            params: None,
            idempotency_key: None,
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(!json.contains("params"));
        let back: RpcRequest = serde_json::from_str(&json).unwrap();
        assert!(back.params.is_none());
    }

    #[test]
    fn request_with_idempotency_key() {
        let req = RpcRequest {
            id: "req_3".into(),
            method: "agent.prompt".into(),
            params: Some(json!({"prompt": "hi"})),
            idempotency_key: Some("idem_abc".into()),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("idempotencyKey"));
        let back: RpcRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(back.idempotency_key.as_deref(), Some("idem_abc"));
    }

    // ── RpcResponse success ─────────────────────────────────────────

    #[test]
    fn response_success_serde() {
        let resp = RpcResponse::success("req_1", json!({"sessionId": "sess_1"}));
        let json = serde_json::to_string(&resp).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["id"], "req_1");
        assert_eq!(v["success"], true);
        assert!(v["result"].is_object());
        assert!(v.get("error").is_none());
    }

    #[test]
    fn response_success_has_no_error_field() {
        let resp = RpcResponse::success("r1", json!(42));
        let json = serde_json::to_string(&resp).unwrap();
        assert!(!json.contains("error"));
    }

    // ── RpcResponse error ───────────────────────────────────────────

    #[test]
    fn response_error_serde() {
        let resp = RpcResponse::error("req_2", "SESSION_NOT_FOUND", "No such session");
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
        let resp = RpcResponse::error("r1", "ERR", "msg");
        let json = serde_json::to_string(&resp).unwrap();
        assert!(!json.contains("result"));
    }

    // ── RpcResponse error_with_details ──────────────────────────────

    #[test]
    fn response_error_with_details_serde() {
        let resp = RpcResponse::error_with_details(
            "req_3",
            "INVALID_PARAMS",
            "Bad param",
            json!({"field": "path"}),
        );
        let json = serde_json::to_string(&resp).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["error"]["details"]["field"], "path");
    }

    // ── RpcErrorBody ────────────────────────────────────────────────

    #[test]
    fn error_body_roundtrip() {
        let body = RpcErrorBody {
            code: "INTERNAL_ERROR".into(),
            message: "Something went wrong".into(),
            details: Some(json!({"trace": "abc"})),
        };
        let json = serde_json::to_string(&body).unwrap();
        let back: RpcErrorBody = serde_json::from_str(&json).unwrap();
        assert_eq!(back.code, "INTERNAL_ERROR");
        assert_eq!(back.details.unwrap()["trace"], "abc");
    }

    #[test]
    fn error_body_without_details() {
        let body = RpcErrorBody {
            code: "NOT_FOUND".into(),
            message: "gone".into(),
            details: None,
        };
        let json = serde_json::to_string(&body).unwrap();
        assert!(!json.contains("details"));
    }

    // ── RpcEvent ────────────────────────────────────────────────────

    #[test]
    fn event_roundtrip_with_all_fields() {
        let ev = RpcEvent {
            event_type: "agent.text_delta".into(),
            session_id: Some("sess_1".into()),
            timestamp: "2026-02-13T15:30:00.000Z".into(),
            data: Some(json!({"text": "hello"})),
            run_id: Some("run_1".into()),
        };
        let json = serde_json::to_string(&ev).unwrap();
        let back: RpcEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back.event_type, "agent.text_delta");
        assert_eq!(back.session_id.as_deref(), Some("sess_1"));
        assert_eq!(back.run_id.as_deref(), Some("run_1"));
    }

    #[test]
    fn event_roundtrip_minimal() {
        let ev = RpcEvent {
            event_type: "system.ready".into(),
            session_id: None,
            timestamp: "2026-01-01T00:00:00.000Z".into(),
            data: None,
            run_id: None,
        };
        let json = serde_json::to_string(&ev).unwrap();
        assert!(!json.contains("sessionId"));
        assert!(!json.contains("data"));
        assert!(!json.contains("runId"));
    }

    #[test]
    fn event_new_sets_timestamp() {
        let ev = RpcEvent::new("test.event", None, None);
        assert!(!ev.timestamp.is_empty());
        assert!(ev.run_id.is_none());
    }

    #[test]
    fn event_with_run_id() {
        let ev = RpcEvent::new("test.event", Some("s1".into()), None).with_run_id("run_42");
        assert_eq!(ev.run_id.as_deref(), Some("run_42"));
    }

    #[test]
    fn event_type_field_serializes_as_type() {
        let ev = RpcEvent::new("agent.start", None, None);
        let json = serde_json::to_string(&ev).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert!(v.get("type").is_some());
        assert!(v.get("event_type").is_none());
        assert!(v.get("eventType").is_none());
    }

    // ── Wire format fixture tests ───────────────────────────────────

    #[test]
    fn wire_format_request() {
        let raw = r#"{"id": "req_1", "method": "session.create", "params": {"workingDirectory": "/tmp"}}"#;
        let req: RpcRequest = serde_json::from_str(raw).unwrap();
        assert_eq!(req.id, "req_1");
        assert_eq!(req.method, "session.create");
        assert_eq!(req.params.unwrap()["workingDirectory"], "/tmp");
    }

    #[test]
    fn wire_format_success_response() {
        let raw = r#"{"id": "req_1", "success": true, "result": {"sessionId": "sess_123"}}"#;
        let resp: RpcResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.id, "req_1");
        assert!(resp.success);
        assert_eq!(resp.result.unwrap()["sessionId"], "sess_123");
        assert!(resp.error.is_none());
    }

    #[test]
    fn wire_format_error_response() {
        let raw = r#"{"id": "req_1", "success": false, "error": {"code": "SESSION_NOT_FOUND", "message": "No session", "details": null}}"#;
        let resp: RpcResponse = serde_json::from_str(raw).unwrap();
        assert!(!resp.success);
        assert!(resp.result.is_none());
        let err = resp.error.unwrap();
        assert_eq!(err.code, "SESSION_NOT_FOUND");
        assert_eq!(err.message, "No session");
    }

    #[test]
    fn wire_format_event() {
        let raw = r#"{"type": "agent.text_delta", "sessionId": "sess_123", "timestamp": "2026-02-13T15:30:00.000Z", "data": {"text": "hi"}, "runId": "run_456"}"#;
        let ev: RpcEvent = serde_json::from_str(raw).unwrap();
        assert_eq!(ev.event_type, "agent.text_delta");
        assert_eq!(ev.session_id.as_deref(), Some("sess_123"));
        assert_eq!(ev.run_id.as_deref(), Some("run_456"));
        assert_eq!(ev.data.unwrap()["text"], "hi");
    }

    #[test]
    fn wire_format_request_with_idempotency_key() {
        let raw = r#"{"id": "req_5", "method": "agent.prompt", "params": {}, "idempotencyKey": "abc123"}"#;
        let req: RpcRequest = serde_json::from_str(raw).unwrap();
        assert_eq!(req.idempotency_key.as_deref(), Some("abc123"));
    }

    #[test]
    fn response_success_constructor_fields() {
        let resp = RpcResponse::success("id1", json!({"ok": true}));
        assert_eq!(resp.id, "id1");
        assert!(resp.success);
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["ok"], true);
    }

    #[test]
    fn response_error_constructor_fields() {
        let resp = RpcResponse::error("id2", "CODE", "msg");
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
        let resp = RpcResponse::error_with_details("id3", "C", "m", json!({"x": 1}));
        let err = resp.error.unwrap();
        assert_eq!(err.details.unwrap()["x"], 1);
    }
}
