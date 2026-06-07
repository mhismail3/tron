//! Error event payloads: agent, capability, provider.

use serde::{Deserialize, Serialize};

/// Payload for `error.agent` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorAgentPayload {
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Whether the user can recover.
    pub recoverable: bool,
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
    /// Seconds to wait before retrying.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after: Option<i64>,
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
        });
        let parsed: ErrorProviderPayload = serde_json::from_value(raw).unwrap();
        assert_eq!(parsed.category, "rate_limit");
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
