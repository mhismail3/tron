//! Capability-invocation payload validators used before durable persistence.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::protocol::events::CapabilityEventIdentity;

/// Payload for `capability.invocation.started` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityInvocationStartedPayload {
    /// Capability invocation ID.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Model-facing primitive name.
    pub name: String,
    /// Primitive arguments.
    pub arguments: Value,
    /// Turn number.
    pub turn: i64,
    /// Capability identity used by active clients. The event type remains a
    /// protocol/storage label only.
    #[serde(flatten, default)]
    pub capability_identity: CapabilityEventIdentity,
}

/// Payload for `capability.invocation.completed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityInvocationCompletedPayload {
    /// Capability invocation ID this result corresponds to.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Result content.
    pub content: String,
    /// Model-facing reconstruction content. When present, active clients keep
    /// rendering `content`, while session reconstruction feeds this richer
    /// content back to providers for the next turn.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_context_content: Option<String>,
    /// Whether the capability invocation errored.
    pub is_error: bool,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Files affected by the capability.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub affected_files: Option<Vec<String>>,
    /// Whether the content was truncated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
    /// Blob ID for truncated content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blob_id: Option<String>,
    /// Primitive-operation metadata such as `operation`, `exitCode`, path,
    /// trace id, status, or duration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Capability identity used by active clients. The event type remains a
    /// protocol/storage label only.
    #[serde(flatten, default)]
    pub capability_identity: CapabilityEventIdentity,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full_identity() -> CapabilityEventIdentity {
        CapabilityEventIdentity {
            model_primitive_name: Some("execute".into()),
            operation_name: Some("file_write".into()),
            trace_id: Some("trace-test".into()),
            root_invocation_id: Some("root-test".into()),
            theme_color: Some("#10B981".into()),
            presentation_hints: Some(serde_json::json!({
                "displayName": "Execute",
                "chipTitle": "Execute",
                "icon": "terminal",
                "themeColor": "#10B981"
            })),
        }
    }

    #[test]
    fn capability_started_payload_serializes_capability_identity() {
        let p = CapabilityInvocationStartedPayload {
            invocation_id: "call-1".into(),
            name: "execute".into(),
            arguments: serde_json::json!({}),
            turn: 3,
            capability_identity: full_identity(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["invocationId"], "call-1");
        assert_eq!(v["modelPrimitiveName"], "execute");
        assert_eq!(v["operationName"], "file_write");
        assert_eq!(v["traceId"], "trace-test");
        assert_eq!(v["rootInvocationId"], "root-test");
        assert_eq!(v["presentationHints"]["displayName"], "Execute");
    }

    #[test]
    fn capability_completed_payload_serializes_capability_identity() {
        let p = CapabilityInvocationCompletedPayload {
            invocation_id: "call-1".into(),
            content: "ok".into(),
            model_context_content: Some("ok\nmetadata".into()),
            is_error: false,
            duration: 42,
            affected_files: None,
            truncated: None,
            blob_id: None,
            details: None,
            capability_identity: full_identity(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["invocationId"], "call-1");
        assert_eq!(v["modelContextContent"], "ok\nmetadata");
        assert_eq!(v["modelPrimitiveName"], "execute");
        assert_eq!(v["operationName"], "file_write");
        assert_eq!(v["traceId"], "trace-test");
        assert_eq!(v["presentationHints"]["icon"], "terminal");
    }
}
