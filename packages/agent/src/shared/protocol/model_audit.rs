//! Provider request audit DTOs persisted before model streaming starts.
//!
//! `model.provider_request` rows are the provider-audit section source for
//! canonical replay manifests. The DTO is protocol-owned because the turn loop
//! persists it before the provider stream opens and replay later reads it from
//! durable session events without importing provider internals.
//! Provenance marker: provider-audit section source for canonical replay manifests.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use super::messages::Provider;
use crate::shared::foundation::redaction::redact_sensitive_content;

/// Canonical format marker for provider request audit events.
pub const MODEL_PROVIDER_REQUEST_AUDIT_FORMAT: &str = "tron.model_provider_request.v1";
/// Maximum serialized JSON size accepted for a single provider request audit body.
///
/// Provider audit rows are durable replay inputs, but they are not a bulk blob
/// transport. Oversized request envelopes should fail before the provider stream
/// opens so replay never has a response without the matching request.
pub const MAX_PROVIDER_AUDIT_PAYLOAD_BYTES: usize = 1_048_576;

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

/// Recursively redact sensitive strings inside a JSON value.
#[must_use]
pub fn redact_sensitive_json(value: Value) -> Value {
    match value {
        Value::String(text) => Value::String(redact_sensitive_content(&text)),
        Value::Array(values) => {
            Value::Array(values.into_iter().map(redact_sensitive_json).collect())
        }
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| (key, redact_sensitive_json(value)))
                .collect(),
        ),
        other => other,
    }
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
    ) -> Self {
        Self {
            format: MODEL_PROVIDER_REQUEST_AUDIT_FORMAT.to_owned(),
            provider_type,
            provider_name: provider_name.into(),
            model: model.into(),
            context_window,
            session_id: session_id.into(),
            reasoning_level,
            message_count,
            capability_count,
            stream_options,
            provider_request,
        }
    }
}
