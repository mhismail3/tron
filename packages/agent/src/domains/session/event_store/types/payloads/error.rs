//! Error event payloads: agent, capability, provider.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Payload for `error.agent` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorAgentPayload {
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Error category.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    /// Whether retrying the same request may succeed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retryable: Option<bool>,
    /// Whether the user can recover.
    pub recoverable: bool,
    /// Layer that classified the failure.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    /// Structured failure details. New rows include `details.failure`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

/// Payload for `error.capability` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorCapabilityPayload {
    /// Model-facing primitive name.
    #[serde(rename = "modelPrimitiveName")]
    pub model_primitive_name: String,
    /// Capability invocation ID.
    #[serde(rename = "invocationId")]
    pub invocation_id: String,
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Error category.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    /// Whether retrying the same request may succeed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retryable: Option<bool>,
    /// Whether the user can recover.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recoverable: Option<bool>,
    /// Layer that classified the failure.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    /// Structured failure details. New rows include `details.failure`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

/// Payload for `error.provider` events.
///
/// `category` is required — every emitter must classify the failure. Use
/// `"unknown"` as the literal classification when the originating layer
/// couldn't narrow it further (import transformer, historical rows). Missing
/// `category` is a bug: reject it at decode time so iOS
/// never has to guess what to render.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ErrorProviderPayload {
    /// Provider name.
    pub provider: String,
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Error category. Required. Use `"unknown"` when unclassified.
    pub category: String,
    /// Suggested action.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suggestion: Option<String>,
    /// Whether the error is retryable.
    pub retryable: bool,
    /// Whether the user can recover.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recoverable: Option<bool>,
    /// Layer that classified the failure.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    /// Structured failure details. New rows include `details.failure`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Provider HTTP status or equivalent status code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status_code: Option<u16>,
    /// Provider-specific error type/code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_type: Option<String>,
    /// Model id when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Seconds to wait before retrying.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after: Option<i64>,
    /// Milliseconds to wait before retrying when the canonical envelope has a
    /// precise value.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn error_provider_requires_category() {
        // Missing `category` must fail; there is no defaulting path.
        let raw = json!({
            "provider": "anthropic",
            "error": "rate limited",
            "retryable": true,
        });
        let err = serde_json::from_value::<ErrorProviderPayload>(raw)
            .expect_err("missing category must fail decode");
        assert!(
            err.to_string().contains("category"),
            "error should name the missing `category` field, got: {err}"
        );
    }

    #[test]
    fn error_provider_accepts_unknown_category() {
        // `"unknown"` is a valid category meaning "couldn't classify" — iOS
        // renders it as a generic-icon pill, not as plain text.
        let raw = json!({
            "provider": "anthropic",
            "error": "rate limited",
            "category": "unknown",
            "retryable": true,
        });
        let parsed: ErrorProviderPayload = serde_json::from_value(raw).unwrap();
        assert_eq!(parsed.category, "unknown");
    }

    #[test]
    fn error_provider_accepts_real_category() {
        let raw = json!({
            "provider": "anthropic",
            "error": "rate limited",
            "category": "rate_limit",
            "retryable": true,
            "recoverable": true,
            "origin": "model_provider",
            "statusCode": 429,
            "errorType": "rate_limit_exceeded",
            "model": "claude",
            "retryAfterMs": 1200,
            "details": {
                "failure": {
                    "code": "PROVIDER_RATE_LIMITED",
                    "category": "rate_limit"
                }
            },
        });
        let parsed: ErrorProviderPayload = serde_json::from_value(raw).unwrap();
        assert_eq!(parsed.category, "rate_limit");
        assert_eq!(parsed.recoverable, Some(true));
        assert_eq!(parsed.origin.as_deref(), Some("model_provider"));
        assert_eq!(parsed.status_code, Some(429));
        assert_eq!(parsed.error_type.as_deref(), Some("rate_limit_exceeded"));
        assert_eq!(parsed.model.as_deref(), Some("claude"));
        assert_eq!(parsed.retry_after_ms, Some(1200));
        assert_eq!(
            parsed.details.unwrap()["failure"]["code"],
            "PROVIDER_RATE_LIMITED"
        );
    }

    #[test]
    fn error_provider_rejects_unknown_fields() {
        let raw = json!({
            "provider": "anthropic",
            "error": "rate limited",
            "category": "unknown",
            "retryable": true,
            "someBogusField": "nope",
        });
        let err = serde_json::from_value::<ErrorProviderPayload>(raw)
            .expect_err("unknown fields must be rejected");
        assert!(
            err.to_string().contains("someBogusField"),
            "error should name the unknown field, got: {err}"
        );
    }
}
