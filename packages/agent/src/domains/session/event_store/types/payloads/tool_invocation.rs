//! Tool-invocation payload validators used before durable persistence.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::protocol::events::ToolEventIdentity;

/// Payload for `tool.invocation.started` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolInvocationStartedPayload {
    /// Tool invocation ID.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Model-facing tool name.
    pub tool_name: String,
    /// Primitive arguments.
    pub arguments: Value,
    /// Turn number.
    pub turn: i64,
    /// Tool identity used by active clients. The event type remains a
    /// protocol/storage label only.
    #[serde(flatten, default)]
    pub tool_identity: ToolEventIdentity,
}

/// Payload for `tool.invocation.completed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolInvocationCompletedPayload {
    /// Tool invocation ID this result corresponds to.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Model-facing tool name.
    pub tool_name: String,
    /// Durable result content. Direct-worker success stores only its
    /// provider-tool association or an already compact receipt/reference; the
    /// canonical typed body remains in the worker invocation ledger.
    pub content: String,
    /// Model-facing reconstruction content. When present, active clients keep
    /// rendering `content`, while session reconstruction feeds this richer
    /// content back to providers for the next turn.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_context_content: Option<String>,
    /// Whether the tool invocation errored.
    pub is_error: bool,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Result metadata such as `exitCode`, path, trace id, status, or duration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Tool identity used by active clients. The event type remains a
    /// protocol/storage label only.
    #[serde(flatten, default)]
    pub tool_identity: ToolEventIdentity,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full_identity() -> ToolEventIdentity {
        ToolEventIdentity {
            trace_id: Some("trace-test".into()),
            root_invocation_id: Some("root-test".into()),
            theme_color: Some("#10B981".into()),
            presentation_hints: Some(serde_json::json!({
                "displayName": "Write File",
                "chipTitle": "Write File",
                "icon": "doc.badge.plus",
                "themeColor": "#10B981"
            })),
        }
    }

    #[test]
    fn tool_started_payload_serializes_tool_identity() {
        let p = ToolInvocationStartedPayload {
            invocation_id: "call-1".into(),
            tool_name: "filesystem_write".into(),
            arguments: serde_json::json!({}),
            turn: 3,
            tool_identity: full_identity(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["invocationId"], "call-1");
        assert_eq!(v["toolName"], "filesystem_write");
        assert_eq!(v["traceId"], "trace-test");
        assert_eq!(v["rootInvocationId"], "root-test");
        assert_eq!(v["presentationHints"]["displayName"], "Write File");
    }

    #[test]
    fn tool_completed_payload_serializes_tool_identity() {
        let p = ToolInvocationCompletedPayload {
            invocation_id: "call-1".into(),
            tool_name: "filesystem_write".into(),
            content: "ok".into(),
            model_context_content: Some("ok\nmetadata".into()),
            is_error: false,
            duration: 42,
            details: None,
            tool_identity: full_identity(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["invocationId"], "call-1");
        assert_eq!(v["modelContextContent"], "ok\nmetadata");
        assert_eq!(v["toolName"], "filesystem_write");
        assert_eq!(v["traceId"], "trace-test");
        assert_eq!(v["presentationHints"]["icon"], "doc.badge.plus");
    }
}
