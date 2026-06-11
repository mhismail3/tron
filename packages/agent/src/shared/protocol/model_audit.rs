//! Provider request audit DTOs persisted before model streaming starts.
//!
//! `model.provider_request` rows are the provider-audit section source for
//! canonical replay manifests. The DTO is protocol-owned because the turn loop
//! persists it before the provider stream opens and replay later reads it from
//! durable session events without importing provider internals.
//! Provider audit payloads are redacted and size-checked before persistence so
//! request audit remains useful without becoming credential or unbounded payload
//! storage.
//! Provenance marker: provider-audit section source for canonical replay manifests.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::foundation::redaction::redact_sensitive_json;

use super::messages::Provider;

/// Canonical format marker for provider request audit events.
pub const MODEL_PROVIDER_REQUEST_AUDIT_FORMAT: &str = "tron.model_provider_request.v1";
/// Maximum serialized provider request payload persisted for one model call.
pub const MAX_PROVIDER_AUDIT_PAYLOAD_BYTES: usize = 64 * 1024;

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

    /// Redact credentials and verify the serialized body stays bounded before
    /// the payload can be persisted as a durable provider-request audit event.
    pub fn redacted_and_bounded(self) -> Result<Self, ProviderAuditPayloadError> {
        let body = redact_sensitive_json(&self.body);
        let serialized_len = serde_json::to_vec(&body)
            .map_err(|error| ProviderAuditPayloadError::Serialize(error.to_string()))?
            .len();
        if serialized_len > MAX_PROVIDER_AUDIT_PAYLOAD_BYTES {
            return Err(ProviderAuditPayloadError::TooLarge {
                bytes: serialized_len,
                max_bytes: MAX_PROVIDER_AUDIT_PAYLOAD_BYTES,
            });
        }
        Ok(Self {
            kind: self.kind,
            body,
        })
    }
}

/// Provider audit validation error.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ProviderAuditPayloadError {
    /// JSON serialization failed while measuring the payload.
    #[error("provider audit payload serialization failed: {0}")]
    Serialize(String),
    /// Payload is too large to persist safely.
    #[error("provider audit payload is too large: {bytes} bytes exceeds {max_bytes} bytes")]
    TooLarge {
        /// Serialized payload size.
        bytes: usize,
        /// Allowed serialized payload size.
        max_bytes: usize,
    },
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn provider_audit_payload_redacts_secret_fields() {
        let payload = ProviderAuditPayload::exact_provider_envelope(json!({
            "model": "gpt-5.5",
            "headers": {
                "Authorization": "Bearer abcdefghijklmnopqrstuvwxyz",
                "x-api-key": "sk-proj-abcdefghijklmnopqrstuvwxyz"
            },
            "access_token": "access-token-1234567890",
            "refreshToken": "refresh-token-1234567890"
        }))
        .redacted_and_bounded()
        .unwrap();

        let text = payload.body.to_string();
        for secret in [
            "abcdefghijklmnopqrstuvwxyz",
            "access-token-1234567890",
            "refresh-token-1234567890",
        ] {
            assert!(!text.contains(secret), "secret leaked: {secret}");
        }
        assert_eq!(payload.body["headers"]["Authorization"], "****");
        assert_eq!(payload.body["headers"]["x-api-key"], "****");
        assert_eq!(payload.body["access_token"], "****");
        assert_eq!(payload.body["refreshToken"], "****");
    }

    #[test]
    fn provider_audit_payload_rejects_oversized_body() {
        let payload = ProviderAuditPayload::provider_independent_snapshot(json!({
            "body": "x".repeat(MAX_PROVIDER_AUDIT_PAYLOAD_BYTES + 1)
        }));

        let err = payload.redacted_and_bounded().unwrap_err();
        assert!(matches!(err, ProviderAuditPayloadError::TooLarge { .. }));
    }
}
