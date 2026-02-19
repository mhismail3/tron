//! # Provider Trait
//!
//! Core abstraction for LLM backends. Every provider (Anthropic, `OpenAI`, Google)
//! implements [`Provider`] to expose a unified streaming interface.
//!
//! The trait returns a boxed [`Stream`] of [`StreamEvent`]s, allowing the runtime
//! to process tokens incrementally regardless of the underlying API format.

use std::pin::Pin;
use std::sync::Arc;

use async_trait::async_trait;
use futures::Stream;
use serde::{Deserialize, Serialize};
use tron_core::events::StreamEvent;

use tron_core::messages::Provider as ProviderType;

// ─────────────────────────────────────────────────────────────────────────────
// Typed effort / reasoning enums
// ─────────────────────────────────────────────────────────────────────────────

/// Anthropic effort level for output configuration.
///
/// Controls how much effort the model puts into generating a response.
/// Valid values for the Anthropic API: `low`, `medium`, `high`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnthropicEffortLevel {
    /// Low effort.
    Low,
    /// Medium effort.
    Medium,
    /// High effort.
    High,
}

impl AnthropicEffortLevel {
    /// Returns the string representation for the API.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
        }
    }
}

impl std::fmt::Display for AnthropicEffortLevel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// `OpenAI` reasoning effort levels.
///
/// Controls how much reasoning the model performs before responding.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReasoningEffort {
    /// Low reasoning effort.
    Low,
    /// Medium reasoning effort.
    Medium,
    /// High reasoning effort.
    High,
    /// Extra high reasoning effort.
    Xhigh,
    /// Maximum reasoning effort.
    Max,
}

impl ReasoningEffort {
    /// Returns the string representation for the API.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Xhigh => "xhigh",
            Self::Max => "max",
        }
    }
}

impl std::fmt::Display for ReasoningEffort {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Result type alias for provider operations.
pub type ProviderResult<T> = Result<T, ProviderError>;

/// Boxed stream of [`StreamEvent`]s returned by [`Provider::stream`].
pub type StreamEventStream = Pin<Box<dyn Stream<Item = Result<StreamEvent, ProviderError>> + Send>>;

/// Errors that can occur during provider operations.
#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    /// HTTP request failed.
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    /// JSON serialization/deserialization failed.
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    /// SSE stream parsing failed.
    #[error("SSE parse error: {message}")]
    SseParse {
        /// Error description.
        message: String,
    },

    /// Authentication failed (expired token, invalid key, etc.).
    #[error("Auth error: {message}")]
    Auth {
        /// Error description.
        message: String,
    },

    /// Requested model is not supported by the registry.
    #[error("Unsupported model: {model}")]
    UnsupportedModel {
        /// The unsupported model identifier.
        model: String,
    },

    /// Rate limited by the provider.
    #[error("Rate limited: retry after {retry_after_ms}ms")]
    RateLimited {
        /// Suggested retry delay in milliseconds.
        retry_after_ms: u64,
        /// Error description.
        message: String,
    },

    /// Provider returned an API error.
    #[error("API error ({status}): {message}")]
    Api {
        /// HTTP status code.
        status: u16,
        /// Error description.
        message: String,
        /// Provider-specific error code.
        code: Option<String>,
        /// Whether this error can be retried.
        retryable: bool,
    },

    /// Stream was cancelled.
    #[error("Stream cancelled")]
    Cancelled,

    /// Provider-specific error.
    #[error("{message}")]
    Other {
        /// Error description.
        message: String,
    },
}

impl ProviderError {
    /// Whether this error is retryable.
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::Http(e) => {
                e.is_timeout()
                    || e.is_connect()
                    || e.status().is_some_and(|s| {
                        s == reqwest::StatusCode::TOO_MANY_REQUESTS || s.is_server_error()
                    })
            }
            Self::RateLimited { .. } => true,
            Self::Api { retryable, .. } => *retryable,
            Self::SseParse { .. }
            | Self::Auth { .. }
            | Self::UnsupportedModel { .. }
            | Self::Cancelled
            | Self::Json(_)
            | Self::Other { .. } => false,
        }
    }

    /// Extract retry-after delay in milliseconds, if available.
    pub fn retry_after_ms(&self) -> Option<u64> {
        match self {
            Self::RateLimited { retry_after_ms, .. } => Some(*retry_after_ms),
            _ => None,
        }
    }

    /// Error category string for event emission.
    pub fn category(&self) -> &str {
        match self {
            Self::Http(_) => "network",
            Self::Json(_) | Self::SseParse { .. } => "parse",
            Self::Auth { .. } => "auth",
            Self::UnsupportedModel { .. } => "invalid_model",
            Self::RateLimited { .. } => "rate_limit",
            Self::Api { .. } => "api",
            Self::Cancelled => "cancelled",
            Self::Other { .. } => "unknown",
        }
    }
}

/// Core LLM provider trait.
///
/// Implementors must be `Send + Sync` for use across async tasks.
/// The [`stream`](Provider::stream) method returns an async stream of
/// [`StreamEvent`]s that the runtime consumes incrementally.
#[async_trait]
pub trait Provider: Send + Sync {
    /// Provider identifier (e.g., `"anthropic"`, `"openai"`, `"google"`).
    fn provider_type(&self) -> ProviderType;

    /// Current model ID (e.g., `"claude-opus-4-6"`).
    fn model(&self) -> &str;

    /// Stream a response from the LLM.
    ///
    /// Returns a stream of [`StreamEvent`]s. The caller should consume events
    /// until [`StreamEvent::Done`] or [`StreamEvent::Error`] is received.
    async fn stream(
        &self,
        context: &tron_core::messages::Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream>;
}

/// Factory for creating providers on demand.
///
/// Called once per prompt to create a fresh provider matching the session's
/// current model. This ensures model switches take effect immediately and
/// OAuth tokens are always current.
#[async_trait]
pub trait ProviderFactory: Send + Sync {
    /// Create a provider for the given model ID.
    ///
    /// Returns `ProviderError::Auth` if no credentials are available for the
    /// model's provider type.
    async fn create_for_model(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError>;
}

/// Options for a provider stream request.
///
/// All fields are optional — providers use sensible defaults when not specified.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStreamOptions {
    /// Maximum tokens to generate.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,

    /// Sampling temperature (0.0 - 2.0).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,

    /// Stop sequences.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_sequences: Option<Vec<String>>,

    /// Enable extended thinking (Anthropic).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enable_thinking: Option<bool>,

    /// Thinking budget in tokens (Anthropic).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_budget: Option<u32>,

    /// Effort level (Anthropic — `low`, `medium`, `high`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort_level: Option<AnthropicEffortLevel>,

    /// Reasoning effort (`OpenAI` — `low`, `medium`, `high`, `xhigh`, `max`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<ReasoningEffort>,

    /// Top-p sampling.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f64>,

    /// Top-k sampling (Google).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_k: Option<u32>,

    /// Thinking level for Gemini 3 models (`"minimal"`, `"low"`, `"medium"`, `"high"`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_level: Option<String>,

    /// Thinking budget for Gemini 2.5 models (0-32768).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gemini_thinking_budget: Option<u32>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn provider_error_is_retryable_http_timeout() {
        let err = reqwest::Client::new()
            .get("http://[::1]:1")
            .timeout(std::time::Duration::from_nanos(1))
            .send()
            .await
            .unwrap_err();
        let provider_err = ProviderError::Http(err);
        // HTTP timeout/connect errors are retryable
        assert!(provider_err.is_retryable());
    }

    #[test]
    fn provider_error_rate_limited_is_retryable() {
        let err = ProviderError::RateLimited {
            retry_after_ms: 5000,
            message: "Too many requests".into(),
        };
        assert!(err.is_retryable());
        assert_eq!(err.retry_after_ms(), Some(5000));
        assert_eq!(err.category(), "rate_limit");
    }

    #[test]
    fn provider_error_api_retryable() {
        let err = ProviderError::Api {
            status: 500,
            message: "Internal server error".into(),
            code: None,
            retryable: true,
        };
        assert!(err.is_retryable());
        assert_eq!(err.category(), "api");
    }

    #[test]
    fn provider_error_api_not_retryable() {
        let err = ProviderError::Api {
            status: 400,
            message: "Bad request".into(),
            code: Some("invalid_request".into()),
            retryable: false,
        };
        assert!(!err.is_retryable());
    }

    #[test]
    fn provider_error_auth_not_retryable() {
        let err = ProviderError::Auth {
            message: "Token expired".into(),
        };
        assert!(!err.is_retryable());
        assert_eq!(err.category(), "auth");
        assert_eq!(err.retry_after_ms(), None);
    }

    #[test]
    fn provider_error_unsupported_model_not_retryable() {
        let err = ProviderError::UnsupportedModel {
            model: "bad-model".into(),
        };
        assert!(!err.is_retryable());
        assert_eq!(err.category(), "invalid_model");
        assert_eq!(err.to_string(), "Unsupported model: bad-model");
    }

    #[test]
    fn provider_error_cancelled_not_retryable() {
        let err = ProviderError::Cancelled;
        assert!(!err.is_retryable());
        assert_eq!(err.category(), "cancelled");
    }

    #[test]
    fn provider_error_display() {
        let err = ProviderError::Api {
            status: 429,
            message: "Rate limited".into(),
            code: None,
            retryable: true,
        };
        assert_eq!(err.to_string(), "API error (429): Rate limited");

        let err = ProviderError::SseParse {
            message: "unexpected EOF".into(),
        };
        assert_eq!(err.to_string(), "SSE parse error: unexpected EOF");
    }

    #[test]
    fn provider_stream_options_defaults() {
        let opts = ProviderStreamOptions::default();
        assert!(opts.max_tokens.is_none());
        assert!(opts.temperature.is_none());
        assert!(opts.stop_sequences.is_none());
        assert!(opts.enable_thinking.is_none());
    }

    #[test]
    fn provider_stream_options_serde_roundtrip() {
        let opts = ProviderStreamOptions {
            max_tokens: Some(4096),
            temperature: Some(0.7),
            enable_thinking: Some(true),
            thinking_budget: Some(10000),
            reasoning_effort: Some(ReasoningEffort::High),
            effort_level: Some(AnthropicEffortLevel::Medium),
            ..Default::default()
        };
        let json = serde_json::to_string(&opts).unwrap();
        let back: ProviderStreamOptions = serde_json::from_str(&json).unwrap();
        assert_eq!(back.max_tokens, Some(4096));
        assert_eq!(back.temperature, Some(0.7));
        assert_eq!(back.enable_thinking, Some(true));
        assert_eq!(back.thinking_budget, Some(10000));
        assert_eq!(back.reasoning_effort, Some(ReasoningEffort::High));
        assert_eq!(back.effort_level, Some(AnthropicEffortLevel::Medium));
    }

    // ── Effort / reasoning enum tests ──

    #[test]
    fn anthropic_effort_level_serde_roundtrip() {
        for (level, expected_str) in [
            (AnthropicEffortLevel::Low, "low"),
            (AnthropicEffortLevel::Medium, "medium"),
            (AnthropicEffortLevel::High, "high"),
        ] {
            let json = serde_json::to_string(&level).unwrap();
            assert_eq!(json, format!("\"{expected_str}\""));
            let back: AnthropicEffortLevel = serde_json::from_str(&json).unwrap();
            assert_eq!(back, level);
            assert_eq!(level.as_str(), expected_str);
            assert_eq!(level.to_string(), expected_str);
        }
    }

    #[test]
    fn reasoning_effort_serde_roundtrip() {
        for (effort, expected_str) in [
            (ReasoningEffort::Low, "low"),
            (ReasoningEffort::Medium, "medium"),
            (ReasoningEffort::High, "high"),
            (ReasoningEffort::Xhigh, "xhigh"),
            (ReasoningEffort::Max, "max"),
        ] {
            let json = serde_json::to_string(&effort).unwrap();
            assert_eq!(json, format!("\"{expected_str}\""));
            let back: ReasoningEffort = serde_json::from_str(&json).unwrap();
            assert_eq!(back, effort);
            assert_eq!(effort.as_str(), expected_str);
            assert_eq!(effort.to_string(), expected_str);
        }
    }

    #[test]
    fn invalid_effort_level_fails_deser() {
        let result = serde_json::from_str::<AnthropicEffortLevel>("\"xhigh\"");
        assert!(result.is_err());
    }

    #[test]
    fn invalid_reasoning_effort_fails_deser() {
        let result = serde_json::from_str::<ReasoningEffort>("\"ultra\"");
        assert!(result.is_err());
    }

    // ── ProviderFactory tests ──

    #[test]
    fn provider_factory_is_object_safe() {
        fn assert_object_safe(_: &dyn ProviderFactory) {}
        let _ = assert_object_safe;
    }

    #[test]
    fn provider_factory_send_sync() {
        fn assert_send_sync<T: Send + Sync + ?Sized>() {}
        assert_send_sync::<dyn ProviderFactory>();
    }

    #[test]
    fn provider_stream_options_skip_none_fields() {
        let opts = ProviderStreamOptions {
            max_tokens: Some(1000),
            ..Default::default()
        };
        let json = serde_json::to_value(&opts).unwrap();
        assert!(json.get("maxTokens").is_some());
        assert!(json.get("temperature").is_none());
        assert!(json.get("stopSequences").is_none());
    }
}
