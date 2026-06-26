//! Provider request audit DTOs persisted before model streaming starts.
//!
//! `model.provider_request` rows are the provider-audit section source for
//! canonical replay manifests. The DTO is protocol-owned because the turn loop
//! persists it before the provider stream opens and replay later reads it from
//! durable session events without importing provider internals.
//! The same module owns metadata-only reasoning/status evidence so request and
//! response payloads can audit requested reasoning level, stop/status, thinking
//! presence, and reasoning token counts without storing raw provider reasoning
//! content or generated summaries.
//! Provenance marker: provider-audit section source for canonical replay manifests.

use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use super::messages::{Provider, TokenUsage};
use crate::shared::foundation::redaction::redact_sensitive_content;

/// Canonical format marker for provider request audit events.
pub const MODEL_PROVIDER_REQUEST_AUDIT_FORMAT: &str = "tron.model_provider_request.v1";
/// Canonical format marker for provider reasoning/status evidence.
pub const MODEL_PROVIDER_REASONING_STATUS_EVIDENCE_FORMAT: &str =
    "tron.model_provider_reasoning_status_evidence.v1";
/// Session-event type that owns provider request audit persistence.
pub const MODEL_PROVIDER_REQUEST_AUDIT_EVENT_TYPE: &str = "model.provider_request";
/// Session-event log is the replay source for provider reasoning/status evidence.
pub const MODEL_PROVIDER_REASONING_REPLAY_SOURCE: &str = "session_event_log";
/// Maximum serialized JSON size accepted for a single provider request audit body.
///
/// Provider audit rows are durable replay inputs, but they are not a bulk blob
/// transport. Oversized request envelopes should fail before the provider stream
/// opens so replay never has a response without the matching request.
pub const MAX_PROVIDER_AUDIT_PAYLOAD_BYTES: usize = 1_048_576;
/// Maximum provider-supplied status label length stored in evidence metadata.
pub const MAX_REASONING_STATUS_LABEL_CHARS: usize = 128;

/// Provider audit payload validation failure.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProviderAuditPayloadError {
    /// Serialized payload exceeded [`MAX_PROVIDER_AUDIT_PAYLOAD_BYTES`].
    #[error(
        "provider request audit payload is too large: {actual_bytes} bytes exceeds {max_bytes} bytes"
    )]
    TooLarge {
        /// Actual serialized size in bytes.
        actual_bytes: usize,
        /// Maximum accepted serialized size in bytes.
        max_bytes: usize,
    },
    /// Serialized size could not be calculated.
    #[error("failed to serialize provider request audit payload: {0}")]
    Serialize(String),
}

/// Whether an audit body is an exact provider request or a provider-neutral snapshot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderAuditPayloadKind {
    /// The body matches the provider's request envelope before the HTTP stream opens.
    ExactProviderEnvelope,
    /// The body is a provider-independent snapshot for providers without an exact envelope.
    ProviderIndependentSnapshot,
}

/// Provider request body captured for replay/audit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAuditPayload {
    /// Body classification.
    pub kind: ProviderAuditPayloadKind,
    /// JSON body. Exact envelopes are stored as the provider would send them.
    pub body: Value,
}

impl ProviderAuditPayload {
    /// Build an exact provider-envelope audit body.
    #[must_use]
    pub fn exact_provider_envelope(body: Value) -> Self {
        Self {
            kind: ProviderAuditPayloadKind::ExactProviderEnvelope,
            body,
        }
    }

    /// Build a provider-independent snapshot audit body.
    #[must_use]
    pub fn provider_independent_snapshot(body: Value) -> Self {
        Self {
            kind: ProviderAuditPayloadKind::ProviderIndependentSnapshot,
            body,
        }
    }

    /// Return a redacted payload if its serialized size stays within the audit
    /// boundary.
    ///
    /// Provider audit payloads must never be the first place a raw secret is
    /// durably persisted. Providers should avoid including headers/auth fields
    /// in request bodies, and this method is the boundary backstop before the
    /// event store writes `model.provider_request`.
    pub fn redacted_and_bounded(self) -> Result<Self, ProviderAuditPayloadError> {
        let payload = Self {
            kind: self.kind,
            body: redact_sensitive_json(self.body),
        };
        let actual_bytes = serde_json::to_vec(&payload)
            .map_err(|error| ProviderAuditPayloadError::Serialize(error.to_string()))?
            .len();
        if actual_bytes > MAX_PROVIDER_AUDIT_PAYLOAD_BYTES {
            return Err(ProviderAuditPayloadError::TooLarge {
                actual_bytes,
                max_bytes: MAX_PROVIDER_AUDIT_PAYLOAD_BYTES,
            });
        }
        Ok(payload)
    }
}

/// Provider/reasoning response phase represented by metadata-only evidence.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelProviderReasoningStatusPhase {
    /// Request audit captured before opening the provider stream.
    RequestAudit,
    /// Completed assistant message metadata.
    MessageAssistant,
    /// Turn-end stream metadata.
    TurnEnd,
}

/// Metadata-only evidence for provider reasoning/status behavior.
///
/// The evidence intentionally records facts about reasoning/status handling, not
/// reasoning content. Raw thinking text, provider-native reasoning payloads, and
/// synthetic summaries stay out of this projection.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProviderReasoningStatusEvidence {
    /// Format marker for this evidence projection.
    pub format: String,
    /// Event/persistence phase that emitted the evidence.
    pub phase: ModelProviderReasoningStatusPhase,
    /// Canonical provider enum.
    pub provider_type: Provider,
    /// Provider label used by runtime metrics.
    pub provider_name: String,
    /// Model identifier.
    pub model: String,
    /// Canonical reasoning level requested for the provider call.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requested_reasoning_level: Option<String>,
    /// Status facts, excluding raw reasoning text.
    pub status: ModelProviderReasoningStatusFacts,
    /// Token-count facts relevant to reasoning/thinking accounting.
    pub tokens: ModelProviderReasoningTokenEvidence,
    /// Durable audit and replay refs.
    pub refs: ModelProviderReasoningRefs,
    /// Explicit metadata-only policy proof.
    pub safety: ModelProviderReasoningSafetyEvidence,
}

/// Provider status facts that are safe to persist in metadata projections.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProviderReasoningStatusFacts {
    /// Whether a response status/stop reason was available.
    pub status_emitted: bool,
    /// Bounded provider stop/status label, when available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_reason: Option<String>,
    /// Whether visible thinking blocks were emitted by the provider stream.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_emitted: Option<bool>,
}

/// Reasoning/thinking token accounting evidence.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProviderReasoningTokenEvidence {
    /// Whether provider token usage was available for the phase.
    pub token_usage_available: bool,
    /// Hidden reasoning output tokens reported by the provider.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_output_tokens: Option<u64>,
    /// Provider thinking tokens reported separately.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thought_tokens: Option<u64>,
    /// Provider-reported total tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<u64>,
}

/// Durable refs for joining reasoning/status evidence back to replay inputs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProviderReasoningRefs {
    /// Session event type for the durable provider request audit.
    pub provider_audit_event_type: String,
    /// Provider request audit format marker.
    pub provider_audit_format: String,
    /// Provider request audit payload kind, when this evidence is attached to
    /// the request-audit event itself.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_audit_payload_kind: Option<ProviderAuditPayloadKind>,
    /// Runtime trace id, when the caller has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Parent invocation id, when this provider turn was nested.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_invocation_id: Option<String>,
    /// Replay source for this evidence.
    pub replay_source: String,
}

/// Explicit redaction/projection proof for reasoning/status evidence.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProviderReasoningSafetyEvidence {
    /// Projection policy for the evidence object.
    pub projection: String,
    /// Raw reasoning/thinking text handling.
    pub raw_reasoning_text: String,
    /// Synthetic summary handling.
    pub synthetic_reasoning_summary: String,
    /// Provider-native raw reasoning payload handling.
    pub provider_reasoning_payload: String,
    /// Secret/token-like material handling.
    pub sensitive_material: String,
    /// Unsafe or absolute path handling.
    pub path_material: String,
}

impl ModelProviderReasoningStatusEvidence {
    /// Build request-time reasoning/status evidence from the provider audit.
    #[allow(clippy::too_many_arguments)]
    #[must_use]
    pub fn request_audit(
        provider_type: Provider,
        provider_name: impl Into<String>,
        model: impl Into<String>,
        requested_reasoning_level: Option<String>,
        provider_audit_payload_kind: ProviderAuditPayloadKind,
        trace_id: Option<String>,
        parent_invocation_id: Option<String>,
    ) -> Self {
        Self::new(
            ModelProviderReasoningStatusPhase::RequestAudit,
            provider_type,
            provider_name,
            model,
            requested_reasoning_level,
            ModelProviderReasoningStatusFacts {
                status_emitted: false,
                stop_reason: None,
                thinking_emitted: None,
            },
            ModelProviderReasoningTokenEvidence::unavailable(),
            Some(provider_audit_payload_kind),
            trace_id,
            parent_invocation_id,
        )
    }

    /// Build response-time reasoning/status evidence.
    #[allow(clippy::too_many_arguments)]
    #[must_use]
    pub fn response(
        phase: ModelProviderReasoningStatusPhase,
        provider_type: Provider,
        provider_name: impl Into<String>,
        model: impl Into<String>,
        requested_reasoning_level: Option<String>,
        stop_reason: impl AsRef<str>,
        thinking_emitted: bool,
        token_usage: Option<&TokenUsage>,
        trace_id: Option<String>,
        parent_invocation_id: Option<String>,
    ) -> Self {
        Self::new(
            phase,
            provider_type,
            provider_name,
            model,
            requested_reasoning_level,
            ModelProviderReasoningStatusFacts {
                status_emitted: true,
                stop_reason: Some(bounded_status_label(stop_reason.as_ref())),
                thinking_emitted: Some(thinking_emitted),
            },
            ModelProviderReasoningTokenEvidence::from_token_usage(token_usage),
            None,
            trace_id,
            parent_invocation_id,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn new(
        phase: ModelProviderReasoningStatusPhase,
        provider_type: Provider,
        provider_name: impl Into<String>,
        model: impl Into<String>,
        requested_reasoning_level: Option<String>,
        status: ModelProviderReasoningStatusFacts,
        tokens: ModelProviderReasoningTokenEvidence,
        provider_audit_payload_kind: Option<ProviderAuditPayloadKind>,
        trace_id: Option<String>,
        parent_invocation_id: Option<String>,
    ) -> Self {
        Self {
            format: MODEL_PROVIDER_REASONING_STATUS_EVIDENCE_FORMAT.to_owned(),
            phase,
            provider_type,
            provider_name: provider_name.into(),
            model: model.into(),
            requested_reasoning_level,
            status,
            tokens,
            refs: ModelProviderReasoningRefs {
                provider_audit_event_type: MODEL_PROVIDER_REQUEST_AUDIT_EVENT_TYPE.to_owned(),
                provider_audit_format: MODEL_PROVIDER_REQUEST_AUDIT_FORMAT.to_owned(),
                provider_audit_payload_kind,
                trace_id: trace_id.map(|id| bounded_status_label(&id)),
                parent_invocation_id: parent_invocation_id.map(|id| bounded_status_label(&id)),
                replay_source: MODEL_PROVIDER_REASONING_REPLAY_SOURCE.to_owned(),
            },
            safety: ModelProviderReasoningSafetyEvidence::metadata_only(),
        }
    }
}

impl ModelProviderReasoningTokenEvidence {
    fn unavailable() -> Self {
        Self {
            token_usage_available: false,
            reasoning_output_tokens: None,
            thought_tokens: None,
            total_tokens: None,
        }
    }

    fn from_token_usage(token_usage: Option<&TokenUsage>) -> Self {
        let Some(token_usage) = token_usage else {
            return Self::unavailable();
        };
        Self {
            token_usage_available: true,
            reasoning_output_tokens: token_usage.reasoning_output_tokens,
            thought_tokens: token_usage.thought_tokens,
            total_tokens: token_usage.total_tokens,
        }
    }
}

impl ModelProviderReasoningSafetyEvidence {
    fn metadata_only() -> Self {
        Self {
            projection: "metadata_only".to_owned(),
            raw_reasoning_text: "omitted".to_owned(),
            synthetic_reasoning_summary: "omitted".to_owned(),
            provider_reasoning_payload: "redacted_or_omitted".to_owned(),
            sensitive_material: "redacted".to_owned(),
            path_material: "redacted".to_owned(),
        }
    }
}

/// Recursively redact sensitive strings inside a JSON value.
#[must_use]
pub fn redact_sensitive_json(value: Value) -> Value {
    redact_sensitive_json_for_key(None, value)
}

fn redact_sensitive_json_for_key(key: Option<&str>, value: Value) -> Value {
    match value {
        Value::String(text) => {
            if key.is_some_and(is_raw_reasoning_string_key) {
                return Value::String("[omitted:provider-reasoning-payload]".to_owned());
            }
            Value::String(redact_provider_audit_text(&text))
        }
        Value::Array(values) => {
            if key.is_some_and(is_raw_reasoning_container_key) {
                return Value::String("[omitted:provider-reasoning-payload]".to_owned());
            }
            Value::Array(
                values
                    .into_iter()
                    .map(|value| redact_sensitive_json_for_key(None, value))
                    .collect(),
            )
        }
        Value::Object(map) => {
            if key.is_some_and(is_raw_reasoning_container_key) {
                return Value::String("[omitted:provider-reasoning-payload]".to_owned());
            }
            Value::Object(
                map.into_iter()
                    .map(|(key, value)| {
                        let redacted = redact_sensitive_json_for_key(Some(&key), value);
                        (key, redacted)
                    })
                    .collect(),
            )
        }
        other => other,
    }
}

fn redact_provider_audit_text(text: &str) -> String {
    static ABSOLUTE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(/(?:Users|home|private|tmp|var|Volumes)/[^\s"',}\]]+)"#)
            .unwrap()
    });
    static UNSAFE_RELATIVE_PATHS: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"(^|[\s"'=:,\[])(\.\.(?:/|\\)[^\s"',}\]]*)"#).unwrap());

    let redacted = redact_sensitive_content(text);
    let redacted = ABSOLUTE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string();
    UNSAFE_RELATIVE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string()
}

fn is_raw_reasoning_string_key(key: &str) -> bool {
    matches!(
        canonical_key(key).as_str(),
        "thinking"
            | "thinkingtext"
            | "thinkingcontent"
            | "reasoningcontent"
            | "rawreasoning"
            | "rawreasoningtext"
            | "rawreasoningpayload"
            | "chainofthought"
            | "thoughts"
    )
}

fn is_raw_reasoning_container_key(key: &str) -> bool {
    matches!(
        canonical_key(key).as_str(),
        "thinkingcontent"
            | "reasoningcontent"
            | "rawreasoning"
            | "rawreasoningtext"
            | "rawreasoningpayload"
            | "chainofthought"
            | "thoughts"
    )
}

fn canonical_key(key: &str) -> String {
    key.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn bounded_status_label(value: &str) -> String {
    let redacted = redact_provider_audit_text(value);
    let mut chars = redacted.chars();
    let mut bounded = String::new();
    for _ in 0..MAX_REASONING_STATUS_LABEL_CHARS {
        if let Some(ch) = chars.next() {
            bounded.push(ch);
        } else {
            return bounded;
        }
    }
    if chars.next().is_some() {
        bounded.push_str("...");
    }
    bounded
}

/// Durable audit payload written as `model.provider_request`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProviderRequestAudit {
    /// Format marker.
    pub format: String,
    /// Canonical provider enum.
    pub provider_type: Provider,
    /// Provider label used by runtime metrics.
    pub provider_name: String,
    /// Model identifier.
    pub model: String,
    /// Effective context window used for the turn.
    pub context_window: u64,
    /// Session id used for prompt-cache routing and replay joins.
    pub session_id: String,
    /// Canonical reasoning level, when requested.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_level: Option<String>,
    /// Number of provider-visible messages in the request context.
    pub message_count: usize,
    /// Number of provider-visible capabilities in the request context.
    pub capability_count: usize,
    /// Provider stream options produced by the model responder boundary.
    pub stream_options: Value,
    /// Provider request envelope or provider-independent request-input snapshot.
    pub provider_request: ProviderAuditPayload,
    /// Metadata-only reasoning/status evidence for this request audit.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_status_evidence: Option<ModelProviderReasoningStatusEvidence>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn provider_audit_payload_redacts_nested_secrets() {
        let payload = ProviderAuditPayload::exact_provider_envelope(json!({
            "headers": {
                "authorization": "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
            },
            "body": [
                {"apiKey": "sk-proj-abcdefghijklmnopqrstuvwxyz"},
                "access_token=access-token-1234567890"
            ]
        }));

        let redacted = payload.redacted_and_bounded().unwrap();
        let body = redacted.body.to_string();

        assert!(!body.contains("abcdefghijklmnopqrstuvwxyz0123456789"));
        assert!(!body.contains("sk-proj-abcdefghijklmnopqrstuvwxyz"));
        assert!(!body.contains("access-token-1234567890"));
        assert!(body.contains("Bearer ****"));
        assert!(body.contains("sk-proj-****"));
        assert!(body.contains("access_token=****"));
    }

    #[test]
    fn provider_audit_payload_omits_raw_reasoning_and_redacts_paths() {
        let payload = ProviderAuditPayload::provider_independent_snapshot(json!({
            "messages": [{
                "type": "thinking",
                "thinking": "raw hidden reasoning from provider",
                "debugPath": "/tmp/tron-provider/raw-reasoning.log"
            }],
            "providerDebug": {
                "reasoning_content": {
                    "text": "provider native chain of thought"
                },
                "chainOfThought": ["first hidden step", "second hidden step"],
                "unsafe": "../escape/provider.json"
            },
            "headers": {
                "authorization": "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
            }
        }));

        let redacted = payload.redacted_and_bounded().unwrap();
        let body = redacted.body.to_string();

        for forbidden in [
            "raw hidden reasoning",
            "provider native chain",
            "first hidden step",
            "/tmp/tron-provider",
            "../escape",
            "abcdefghijklmnopqrstuvwxyz0123456789",
        ] {
            assert!(
                !body.contains(forbidden),
                "provider audit leaked {forbidden}: {body}"
            );
        }
        assert!(body.contains("[omitted:provider-reasoning-payload]"));
        assert!(body.contains("[redacted-path]"));
        assert!(body.contains("Bearer ****"));
    }

    #[test]
    fn reasoning_status_evidence_is_metadata_only() {
        let usage = TokenUsage {
            input_tokens: 12,
            output_tokens: 34,
            reasoning_output_tokens: Some(5),
            thought_tokens: Some(6),
            total_tokens: Some(46),
            provider_type: Some(Provider::OpenAi),
            ..Default::default()
        };

        let evidence = ModelProviderReasoningStatusEvidence::response(
            ModelProviderReasoningStatusPhase::MessageAssistant,
            Provider::OpenAi,
            "openai",
            "gpt-5.5",
            Some("high".to_owned()),
            "stop /tmp/tron-provider/raw.txt with Bearer abcdefghijklmnopqrstuvwxyz0123456789",
            true,
            Some(&usage),
            Some("trace-1".to_owned()),
            Some("invoke-1".to_owned()),
        );
        let json = serde_json::to_value(evidence).unwrap();
        let body = json.to_string();

        assert_eq!(
            json["format"],
            MODEL_PROVIDER_REASONING_STATUS_EVIDENCE_FORMAT
        );
        assert_eq!(json["requestedReasoningLevel"], "high");
        assert_eq!(json["status"]["thinkingEmitted"], true);
        assert_eq!(json["tokens"]["reasoningOutputTokens"], 5);
        assert_eq!(json["tokens"]["thoughtTokens"], 6);
        assert_eq!(json["safety"]["rawReasoningText"], "omitted");
        assert_eq!(json["safety"]["syntheticReasoningSummary"], "omitted");
        assert!(!body.contains("/tmp/tron-provider"));
        assert!(!body.contains("abcdefghijklmnopqrstuvwxyz0123456789"));
        assert!(body.contains("[redacted-path]"));
        assert!(body.contains("Bearer ****"));
    }

    #[test]
    fn provider_audit_payload_rejects_oversized_body() {
        let payload =
            ProviderAuditPayload::provider_independent_snapshot(json!({"body": "x".repeat(
                MAX_PROVIDER_AUDIT_PAYLOAD_BYTES + 1
            )}));

        let error = payload.redacted_and_bounded().unwrap_err();

        assert!(matches!(
            error,
            ProviderAuditPayloadError::TooLarge {
                max_bytes: MAX_PROVIDER_AUDIT_PAYLOAD_BYTES,
                ..
            }
        ));
    }
}

impl ModelProviderRequestAudit {
    /// Build a canonical model-provider audit payload.
    #[must_use]
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        provider_type: Provider,
        provider_name: impl Into<String>,
        model: impl Into<String>,
        context_window: u64,
        session_id: impl Into<String>,
        reasoning_level: Option<String>,
        message_count: usize,
        capability_count: usize,
        stream_options: Value,
        provider_request: ProviderAuditPayload,
        trace_id: Option<String>,
        parent_invocation_id: Option<String>,
    ) -> Self {
        let provider_name = provider_name.into();
        let model = model.into();
        let session_id = session_id.into();
        let reasoning_status_evidence = Some(ModelProviderReasoningStatusEvidence::request_audit(
            provider_type,
            provider_name.clone(),
            model.clone(),
            reasoning_level.clone(),
            provider_request.kind.clone(),
            trace_id,
            parent_invocation_id,
        ));
        Self {
            format: MODEL_PROVIDER_REQUEST_AUDIT_FORMAT.to_owned(),
            provider_type,
            provider_name,
            model,
            context_window,
            session_id,
            reasoning_level,
            message_count,
            capability_count,
            stream_options,
            provider_request,
            reasoning_status_evidence,
        }
    }
}
