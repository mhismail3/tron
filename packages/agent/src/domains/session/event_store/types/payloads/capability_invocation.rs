//! Capability invocation event payloads: started, progress, run lifecycle, completed.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::events::CapabilityEventIdentity;

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

/// Payload for `capability.invocation.progress` events.
///
/// Emitted by long-running primitive operations to keep clients from looking
/// frozen and to let users cancel work that's taking too long. Every field
/// except `invocation_id` is optional. For example, `process_run` may stream a
/// `message` with the latest stdout line, while future bounded operations may
/// set both `percent` and `message`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityInvocationProgressPayload {
    /// The capability invocation this progress update belongs to.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Free-form human-readable status ("downloaded 32 KiB", "turn 3 of 8").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Fractional completion in `[0.0, 1.0]` when a total is known. Operations
    /// without a bound leave this unset rather than guessing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub percent: Option<f64>,
    /// Turn number the progress belongs to.
    pub turn: i64,
    /// Capability identity used by active clients. The event type remains a
    /// protocol/storage label only.
    #[serde(flatten, default)]
    pub capability_identity: CapabilityEventIdentity,
}

/// Payload for `capability.run.status` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityRunStatusPayload {
    /// Durable async run id.
    #[serde(rename = "runId")]
    pub run_id: String,
    /// Owning capability invocation id.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Current run status.
    pub status: String,
    /// Optional stream topic.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream_topic: Option<String>,
    /// Child invocation ids linked to this run.
    pub child_invocations: Vec<String>,
    /// Optional redacted details.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Capability identity.
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

    #[test]
    fn capability_progress_serializes_camel_case_with_turn() {
        let p = CapabilityInvocationProgressPayload {
            invocation_id: "call-1".into(),
            message: Some("32 KiB of 120 KiB".into()),
            percent: Some(0.267),
            turn: 3,
            capability_identity: CapabilityEventIdentity::with_model_primitive("execute"),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["invocationId"], "call-1");
        assert_eq!(v["modelPrimitiveName"], "execute");
        assert_eq!(v["message"], "32 KiB of 120 KiB");
        assert_eq!(v["percent"], 0.267);
        assert_eq!(v["turn"], 3);
        assert!(v.get("invocation_id").is_none());
    }

    #[test]
    fn capability_progress_omits_optional_fields_when_none() {
        let p = CapabilityInvocationProgressPayload {
            invocation_id: "call-1".into(),
            message: None,
            percent: None,
            turn: 1,
            capability_identity: CapabilityEventIdentity::default(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert!(v.get("message").is_none(), "message should be omitted");
        assert!(v.get("percent").is_none(), "percent should be omitted");
        assert_eq!(v["invocationId"], "call-1");
        assert_eq!(v["turn"], 1);
    }

    #[test]
    fn capability_progress_roundtrip_preserves_fields() {
        let p = CapabilityInvocationProgressPayload {
            invocation_id: "c".into(),
            message: Some("m".into()),
            percent: Some(0.5),
            turn: 7,
            capability_identity: CapabilityEventIdentity::with_model_primitive("execute"),
        };
        let s = serde_json::to_string(&p).unwrap();
        let back: CapabilityInvocationProgressPayload = serde_json::from_str(&s).unwrap();
        assert_eq!(p, back);
    }
}
