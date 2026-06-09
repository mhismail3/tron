//! Model response boundary.
//!
//! This module is the only non-provider surface that creates model responders,
//! opens model streams, applies provider retry policy, maps provider errors, and
//! records provider health. Agent loop code depends on this boundary instead of
//! provider factories, provider traits, stream options, retry wrappers, or
//! provider-native errors.

use std::pin::Pin;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use futures::{Stream, StreamExt};
use metrics::{counter, histogram};
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;
use tracing::warn;

use crate::domains::model::providers::shared::provider::{
    AnthropicEffortLevel, Provider, ProviderError, ProviderFactory, ProviderStreamOptions,
    ReasoningEffort, StreamEventStream,
};
use crate::domains::model::providers::shared::{
    ProviderHealthTracker, StreamFactory, StreamRetryConfig, with_provider_retry,
};
use crate::shared::foundation::retry::RetryConfig;
use crate::shared::protocol::events::StreamEvent;
use crate::shared::protocol::messages::Context;

/// Boxed stream returned by the model responder boundary.
pub type ModelResponseStream =
    Pin<Box<dyn Stream<Item = Result<StreamEvent, ModelResponseError>> + Send>>;

/// Provider-neutral reasoning level for model response requests.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelReasoningLevel {
    /// No reasoning.
    None,
    /// Low reasoning effort.
    Low,
    /// Medium reasoning effort.
    Medium,
    /// High reasoning effort.
    High,
    /// Extra-high reasoning effort.
    XHigh,
    /// Maximum reasoning effort.
    Max,
}

impl ModelReasoningLevel {
    /// Parse from the canonical request spelling.
    pub fn from_str_canonical(s: &str) -> Option<Self> {
        match s {
            "none" => Some(Self::None),
            "low" => Some(Self::Low),
            "medium" => Some(Self::Medium),
            "high" => Some(Self::High),
            "x_high" => Some(Self::XHigh),
            "max" => Some(Self::Max),
            _ => Option::None,
        }
    }

    fn as_gemini_thinking_level(&self) -> &str {
        match self {
            Self::None => "THINKING_DISABLED",
            Self::Low => "THINKING_LOW",
            Self::Medium => "THINKING_MEDIUM",
            Self::High | Self::XHigh | Self::Max => "THINKING_HIGH",
        }
    }

    fn as_anthropic_effort(&self) -> Option<AnthropicEffortLevel> {
        match self {
            Self::None => None,
            Self::Low => Some(AnthropicEffortLevel::Low),
            Self::Medium => Some(AnthropicEffortLevel::Medium),
            Self::High => Some(AnthropicEffortLevel::High),
            Self::XHigh => Some(AnthropicEffortLevel::Xhigh),
            Self::Max => Some(AnthropicEffortLevel::Max),
        }
    }

    fn as_openai_reasoning(&self) -> ReasoningEffort {
        match self {
            Self::None => ReasoningEffort::None,
            Self::Low => ReasoningEffort::Low,
            Self::Medium => ReasoningEffort::Medium,
            Self::High => ReasoningEffort::High,
            Self::XHigh => ReasoningEffort::Xhigh,
            Self::Max => ReasoningEffort::Max,
        }
    }
}

/// Canonical model response error exposed outside the model domain.
#[derive(Clone, Debug, thiserror::Error)]
#[error("{message}")]
pub struct ModelResponseError {
    message: String,
    category: String,
    retryable: bool,
    cancelled: bool,
}

impl ModelResponseError {
    /// Create a non-retryable model response error for tests and canonical
    /// model-boundary failures that are not tied to a provider-native category.
    pub fn other(message: impl Into<String>) -> Self {
        Self::new(message, "unknown", false, false)
    }

    /// Create a non-retryable auth error at the model boundary.
    pub fn auth(message: impl Into<String>) -> Self {
        Self::new(message, "auth", false, false)
    }

    fn new(
        message: impl Into<String>,
        category: impl Into<String>,
        retryable: bool,
        cancelled: bool,
    ) -> Self {
        Self {
            message: message.into(),
            category: category.into(),
            retryable,
            cancelled,
        }
    }

    /// Error category string for event emission.
    pub fn category(&self) -> &str {
        &self.category
    }

    /// Whether this error is retryable.
    pub fn is_retryable(&self) -> bool {
        self.retryable
    }

    /// Whether the request was cancelled.
    pub fn is_cancelled(&self) -> bool {
        self.cancelled
    }
}

impl From<ProviderError> for ModelResponseError {
    fn from(error: ProviderError) -> Self {
        let category = error.category().to_owned();
        let retryable = error.is_retryable();
        let cancelled = matches!(error, ProviderError::Cancelled);
        Self::new(error.to_string(), category, retryable, cancelled)
    }
}

/// Metadata for a responder instance.
#[derive(Clone, Debug)]
pub struct ModelResponderInfo {
    /// Canonical provider identity used in persisted protocol payloads.
    pub provider_type: crate::shared::protocol::messages::Provider,
    /// Provider label used by metrics.
    pub provider_name: &'static str,
    /// Model identifier used by the responder.
    pub model: String,
    /// Effective context window for the model/provider pair.
    pub context_window: u64,
}

/// Request for one model response stream.
pub struct ModelResponseRequest {
    /// Complete model context for the turn.
    pub context: Context,
    /// Session id used for prompt cache routing.
    pub session_id: String,
    /// Optional provider-neutral reasoning level.
    pub reasoning_level: Option<ModelReasoningLevel>,
    /// Cancellation token used while opening retryable streams.
    pub cancel: CancellationToken,
    /// Optional retry configuration for stream-open failures.
    pub retry_config: Option<RetryConfig>,
}

/// Open model response stream plus responder metadata.
pub struct ModelResponse {
    /// Responder metadata.
    pub info: ModelResponderInfo,
    /// Provider-neutral stream.
    pub stream: ModelResponseStream,
}

/// Shared model response health tracker.
pub struct ModelResponderHealth {
    inner: ProviderHealthTracker,
}

impl ModelResponderHealth {
    /// Create an empty health tracker.
    pub fn new() -> Self {
        Self {
            inner: ProviderHealthTracker::new(),
        }
    }

    fn record_success(&self, provider_name: &'static str) {
        self.inner.record_success(provider_name);
    }

    fn record_failure(&self, provider_name: &'static str) {
        self.inner.record_failure(provider_name);
    }
}

impl Default for ModelResponderHealth {
    fn default() -> Self {
        Self::new()
    }
}

/// Boundary consumed by the agent loop for model output.
#[async_trait]
pub trait ModelResponder: Send + Sync {
    /// Static metadata for this responder.
    fn info(&self) -> ModelResponderInfo;

    /// Effective context window for context management.
    fn context_window(&self) -> u64 {
        self.info().context_window
    }

    /// Model identifier.
    fn model(&self) -> String {
        self.info().model
    }

    /// Open one model response stream.
    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError>;
}

/// Factory for model responders.
#[async_trait]
pub trait ModelResponderFactory: Send + Sync {
    /// Create a responder for the given model id.
    async fn create_for_model(
        &self,
        model: &str,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError>;
}

/// Default model responder factory backed by the provider implementations.
pub struct DefaultModelResponderFactory {
    providers: crate::domains::model::providers::factory::DefaultProviderFactory,
    health: Arc<ModelResponderHealth>,
}

impl DefaultModelResponderFactory {
    /// Create a factory from current server settings.
    pub fn new(settings: &crate::domains::settings::TronSettings) -> Self {
        Self {
            providers: crate::domains::model::providers::factory::DefaultProviderFactory::new(
                settings,
            ),
            health: Arc::new(ModelResponderHealth::new()),
        }
    }

    /// Get a clone of the shared HTTP client.
    pub fn http_client(&self) -> reqwest::Client {
        self.providers.http_client()
    }
}

#[async_trait]
impl ModelResponderFactory for DefaultModelResponderFactory {
    async fn create_for_model(
        &self,
        model: &str,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        let provider = self
            .providers
            .create_for_model(model)
            .await
            .map_err(ModelResponseError::from)?;
        Ok(Arc::new(ProviderBackedModelResponder {
            provider,
            health: self.health.clone(),
        }))
    }
}

struct ProviderBackedModelResponder {
    provider: Arc<dyn Provider>,
    health: Arc<ModelResponderHealth>,
}

#[async_trait]
impl ModelResponder for ProviderBackedModelResponder {
    fn info(&self) -> ModelResponderInfo {
        let provider_type = self.provider.provider_type();
        ModelResponderInfo {
            provider_type,
            provider_name: provider_type.as_str(),
            model: self.provider.model().to_owned(),
            context_window: self.provider.context_window(),
        }
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let info = self.info();
        let request_start = Instant::now();
        counter!("provider_requests_total", "provider" => info.provider_name).increment(1);

        let stream_options =
            build_stream_options(request.reasoning_level.as_ref(), &request.session_id);
        let stream = match open_provider_stream(
            &self.provider,
            request.context,
            stream_options,
            request.cancel,
            request.retry_config.as_ref(),
        )
        .await
        {
            Ok(stream) => stream,
            Err(error) => {
                self.health.record_failure(info.provider_name);
                let category = error.category().to_owned();
                counter!("provider_errors_total", "provider" => info.provider_name, "status" => category.clone()).increment(1);
                histogram!("provider_request_duration_seconds", "provider" => info.provider_name)
                    .record(request_start.elapsed().as_secs_f64());
                warn!(
                    provider = %info.provider_name,
                    model = %info.model,
                    status = %category,
                    error = %error,
                    "provider stream error"
                );
                return Err(ModelResponseError::from(error));
            }
        };

        Ok(ModelResponse {
            stream: wrap_provider_stream(
                stream,
                info.provider_name,
                self.health.clone(),
                request_start,
            ),
            info,
        })
    }
}

fn build_stream_options(
    reasoning_level: Option<&ModelReasoningLevel>,
    session_id: &str,
) -> ProviderStreamOptions {
    ProviderStreamOptions {
        enable_thinking: Some(true),
        effort_level: reasoning_level.and_then(ModelReasoningLevel::as_anthropic_effort),
        reasoning_effort: reasoning_level.map(ModelReasoningLevel::as_openai_reasoning),
        thinking_level: reasoning_level.map(|r| r.as_gemini_thinking_level().to_owned()),
        provider_instructions: None,
        prompt_cache_key: Some(format!("tron-session-{session_id}")),
        ..Default::default()
    }
}

async fn open_provider_stream(
    provider: &Arc<dyn Provider>,
    context: Context,
    stream_options: ProviderStreamOptions,
    cancel: CancellationToken,
    retry_config: Option<&RetryConfig>,
) -> Result<StreamEventStream, ProviderError> {
    if let Some(retry) = retry_config {
        let provider = provider.clone();
        let context = Arc::new(context);
        let stream_options = Arc::new(stream_options);
        let factory: StreamFactory = Box::new(move || {
            let provider = provider.clone();
            let context = context.clone();
            let stream_options = stream_options.clone();
            Box::pin(async move { provider.stream(&context, &stream_options).await })
        });
        let retry_cfg = StreamRetryConfig {
            retry: retry.clone(),
            emit_retry_events: true,
            cancel_token: Some(cancel),
        };
        Ok(with_provider_retry(factory, retry_cfg))
    } else {
        provider.stream(&context, &stream_options).await
    }
}

fn wrap_provider_stream(
    stream: StreamEventStream,
    provider_name: &'static str,
    health: Arc<ModelResponderHealth>,
    request_start: Instant,
) -> ModelResponseStream {
    Box::pin(async_stream::stream! {
        let mut stream = std::pin::pin!(stream);
        let mut saw_done = false;
        while let Some(item) = stream.next().await {
            match item {
                Ok(event) => {
                    if matches!(event, StreamEvent::Done { .. }) {
                        saw_done = true;
                        health.record_success(provider_name);
                        histogram!("provider_request_duration_seconds", "provider" => provider_name)
                            .record(request_start.elapsed().as_secs_f64());
                    }
                    yield Ok(event);
                }
                Err(error) => {
                    health.record_failure(provider_name);
                    histogram!("provider_request_duration_seconds", "provider" => provider_name)
                        .record(request_start.elapsed().as_secs_f64());
                    yield Err(ModelResponseError::from(error));
                    return;
                }
            }
        }
        if !saw_done {
            health.record_failure(provider_name);
            histogram!("provider_request_duration_seconds", "provider" => provider_name)
                .record(request_start.elapsed().as_secs_f64());
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reasoning_level_serializes_as_snake_case() {
        assert_eq!(
            serde_json::to_string(&ModelReasoningLevel::None).unwrap(),
            "\"none\""
        );
        assert_eq!(
            serde_json::to_string(&ModelReasoningLevel::Low).unwrap(),
            "\"low\""
        );
        assert_eq!(
            serde_json::to_string(&ModelReasoningLevel::Medium).unwrap(),
            "\"medium\""
        );
        assert_eq!(
            serde_json::to_string(&ModelReasoningLevel::High).unwrap(),
            "\"high\""
        );
        assert_eq!(
            serde_json::to_string(&ModelReasoningLevel::XHigh).unwrap(),
            "\"x_high\""
        );
        assert_eq!(
            serde_json::to_string(&ModelReasoningLevel::Max).unwrap(),
            "\"max\""
        );
    }

    #[test]
    fn reasoning_level_accepts_only_canonical_request_spelling() {
        let level: ModelReasoningLevel = serde_json::from_str("\"x_high\"").unwrap();
        assert_eq!(level, ModelReasoningLevel::XHigh);
        assert_eq!(
            ModelReasoningLevel::from_str_canonical("x_high"),
            Some(ModelReasoningLevel::XHigh)
        );
        assert_eq!(ModelReasoningLevel::from_str_canonical("xhigh"), None);
        assert_eq!(ModelReasoningLevel::from_str_canonical("x-high"), None);
        assert_eq!(ModelReasoningLevel::from_str_canonical("HIGH"), None);
    }

    #[test]
    fn reasoning_level_maps_to_provider_options_inside_model_boundary() {
        assert_eq!(
            ModelReasoningLevel::None.as_gemini_thinking_level(),
            "THINKING_DISABLED"
        );
        assert_eq!(
            ModelReasoningLevel::Low.as_gemini_thinking_level(),
            "THINKING_LOW"
        );
        assert_eq!(
            ModelReasoningLevel::Medium.as_gemini_thinking_level(),
            "THINKING_MEDIUM"
        );
        assert_eq!(
            ModelReasoningLevel::High.as_gemini_thinking_level(),
            "THINKING_HIGH"
        );
        assert_eq!(
            ModelReasoningLevel::XHigh.as_gemini_thinking_level(),
            "THINKING_HIGH"
        );
        assert_eq!(
            ModelReasoningLevel::Max.as_gemini_thinking_level(),
            "THINKING_HIGH"
        );

        assert_eq!(ModelReasoningLevel::None.as_anthropic_effort(), None);
        assert_eq!(
            ModelReasoningLevel::Low.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Low)
        );
        assert_eq!(
            ModelReasoningLevel::Medium.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Medium)
        );
        assert_eq!(
            ModelReasoningLevel::High.as_anthropic_effort(),
            Some(AnthropicEffortLevel::High)
        );
        assert_eq!(
            ModelReasoningLevel::XHigh.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Xhigh)
        );
        assert_eq!(
            ModelReasoningLevel::Max.as_anthropic_effort(),
            Some(AnthropicEffortLevel::Max)
        );

        assert_eq!(
            ModelReasoningLevel::None.as_openai_reasoning(),
            ReasoningEffort::None
        );
        assert_eq!(
            ModelReasoningLevel::Low.as_openai_reasoning(),
            ReasoningEffort::Low
        );
        assert_eq!(
            ModelReasoningLevel::Medium.as_openai_reasoning(),
            ReasoningEffort::Medium
        );
        assert_eq!(
            ModelReasoningLevel::High.as_openai_reasoning(),
            ReasoningEffort::High
        );
        assert_eq!(
            ModelReasoningLevel::XHigh.as_openai_reasoning(),
            ReasoningEffort::Xhigh
        );
        assert_eq!(
            ModelReasoningLevel::Max.as_openai_reasoning(),
            ReasoningEffort::Max
        );
    }
}
