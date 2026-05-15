//! Capability invocation event payloads: started, progress, pause/run lifecycle, completed.

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
/// Emitted by long-running capability calls (`process::run`, `web::fetch`,
/// `agent::spawn_subagent`, …) to keep
/// iOS chips from looking frozen and to let users cancel work that's taking
/// too long. Every field except `invocation_id` is optional — capabilities pick
/// whichever fit their work: process::run streams a `message` with the latest stdout
/// line; web::fetch sets both `percent` (bytes/total) and `message` ("32 KiB of
/// 120 KiB"); subagent execution sets `message` with the child turn count.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityInvocationProgressPayload {
    /// The capability invocation this progress update belongs to.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Free-form human-readable status ("downloaded 32 KiB", "turn 3 of 8").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Fractional completion in `[0.0, 1.0]` when a total is known. Capabilities
    /// without a bound (process::run heartbeat, indefinite subagent) leave this unset
    /// rather than guessing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub percent: Option<f64>,
    /// Turn number the progress belongs to.
    pub turn: i64,
    /// Capability identity used by active clients. The event type remains a
    /// protocol/storage label only.
    #[serde(flatten, default)]
    pub capability_identity: CapabilityEventIdentity,
}

/// Payload for `capability.pause.requested` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityPauseRequestedPayload {
    /// Durable pause id.
    #[serde(rename = "pauseId")]
    pub pause_id: String,
    /// Owning capability invocation id.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Pause kind, for example `user_input` or `approval`.
    pub kind: String,
    /// Current pause status.
    pub status: String,
    /// Prompt/schema-specific payload rendered by the client.
    pub prompt_payload: Value,
    /// Optional resume schema.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resume_schema: Option<Value>,
    /// Who can resolve this pause.
    pub answer_authority: String,
    /// Optional expiry timestamp.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    /// Capability identity.
    #[serde(flatten, default)]
    pub capability_identity: CapabilityEventIdentity,
}

/// Payload for `capability.pause.resolved` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityPauseResolvedPayload {
    /// Durable pause id.
    #[serde(rename = "pauseId")]
    pub pause_id: String,
    /// Owning capability invocation id.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Terminal status.
    pub status: String,
    /// Optional redacted resolution metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<Value>,
    /// Capability identity.
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
    /// Capability-specific metadata (e.g. `web::fetch`: url, status, `fromCache`, `responseHeaders`;
    /// `process::run`: `exitCode`, command, `durationMs`).
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
            contract_id: Some("filesystem::read_file".into()),
            implementation_id: Some("first_party.filesystem.v1.read_file".into()),
            function_id: Some("filesystem::read_file".into()),
            plugin_id: Some("first_party.filesystem".into()),
            worker_id: Some("filesystem-worker".into()),
            schema_digest: Some("sha256:test".into()),
            catalog_revision: Some(7),
            trust_tier: Some("first_party_signed".into()),
            risk_level: Some("low".into()),
            effect_class: Some("read".into()),
            trace_id: Some("trace-test".into()),
            root_invocation_id: Some("root-test".into()),
            binding_decision_id: Some("binding-test".into()),
            theme_color: Some("#10B981".into()),
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
        assert_eq!(v["contractId"], "filesystem::read_file");
        assert_eq!(v["implementationId"], "first_party.filesystem.v1.read_file");
        assert_eq!(v["schemaDigest"], "sha256:test");
        assert_eq!(v["catalogRevision"], 7);
        assert_eq!(v["bindingDecisionId"], "binding-test");
    }

    #[test]
    fn capability_completed_payload_serializes_capability_identity() {
        let p = CapabilityInvocationCompletedPayload {
            invocation_id: "call-1".into(),
            content: "ok".into(),
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
        assert_eq!(v["modelPrimitiveName"], "execute");
        assert_eq!(v["contractId"], "filesystem::read_file");
        assert_eq!(v["bindingDecisionId"], "binding-test");
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
