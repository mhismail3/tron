//! Model response boundary.
//!
//! This module is the only non-provider surface that creates model responders,
//! opens model streams, applies provider retry policy, maps provider errors, and
//! records provider health. It also builds provider request audit payloads from
//! the same stream options used to open the provider stream. Agent loop code
//! depends on this boundary instead of provider factories, provider traits,
//! stream options, retry wrappers, or provider-native errors.

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
use crate::shared::protocol::model_audit::{ModelProviderRequestAudit, ProviderAuditPayload};
use crate::shared::server::failure::{
    FailureCategory, FailureEnvelope, FailureOrigin, MODEL_AUTH_ERROR,
    MODEL_PROVIDER_REQUEST_AUDIT_FAILED, MODEL_RESPONSE_ERROR, PROVIDER_SSE_PARSE_ERROR,
};

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

    /// Canonical spelling used in request and audit payloads.
    #[must_use]
    pub fn as_canonical_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::XHigh => "x_high",
            Self::Max => "max",
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
    failure: FailureEnvelope,
    cancelled: bool,
}

impl ModelResponseError {
    /// Create a non-retryable model response error for tests and canonical
    /// model-boundary failures that are not tied to a provider-native category.
    pub fn other(message: impl Into<String>) -> Self {
        let message = message.into();
        Self::from_failure(
            FailureEnvelope::new(
                MODEL_RESPONSE_ERROR,
                FailureCategory::Unknown,
                message,
                false,
                false,
                FailureOrigin::ModelResponder,
            ),
            false,
        )
    }

    /// Create a non-retryable auth error at the model boundary.
    pub fn auth(message: impl Into<String>) -> Self {
        let message = message.into();
        Self::from_failure(
            FailureEnvelope::new(
                MODEL_AUTH_ERROR,
                FailureCategory::Auth,
                message,
                false,
                true,
                FailureOrigin::ModelResponder,
            ),
            false,
        )
    }

    /// Create a non-retryable provider-request audit error.
    pub fn audit(message: impl Into<String>) -> Self {
        let message = message.into();
        Self::from_failure(
            FailureEnvelope::new(
                MODEL_PROVIDER_REQUEST_AUDIT_FAILED,
                FailureCategory::Internal,
                message,
                false,
                false,
                FailureOrigin::ModelResponder,
            ),
            false,
        )
    }

    fn from_failure(failure: FailureEnvelope, cancelled: bool) -> Self {
        Self {
            message: failure.message.clone(),
            failure,
            cancelled,
        }
    }

    fn from_provider_error(error: ProviderError, info: &ModelResponderInfo) -> Self {
        let cancelled = matches!(error, ProviderError::Cancelled);
        let failure = error.to_failure(info.provider_name, &info.model);
        Self::from_failure(failure, cancelled)
    }

    fn from_provider_stream_event_error(
        message: String,
        provider_name: &'static str,
        model: &str,
    ) -> Self {
        Self::from_failure(
            FailureEnvelope::new(
                PROVIDER_SSE_PARSE_ERROR,
                FailureCategory::Parse,
                message,
                false,
                true,
                FailureOrigin::ModelProvider,
            )
            .with_provider_model(provider_name, model)
            .with_error_type(Some("stream_event_error".to_owned()))
            .with_details(Some(serde_json::json!({ "kind": "stream_event_error" }))),
            false,
        )
    }

    /// Error category string for event emission.
    pub fn category(&self) -> &str {
        self.failure.category.as_str()
    }

    /// Whether this error is retryable.
    pub fn is_retryable(&self) -> bool {
        self.failure.retryable
    }

    /// Whether the request was cancelled.
    pub fn is_cancelled(&self) -> bool {
        self.cancelled
    }

    /// Canonical failure envelope for this model response error.
    pub fn failure(&self) -> &FailureEnvelope {
        &self.failure
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

    /// Build the durable provider-request audit payload for one model request.
    ///
    /// The default is a provider-independent snapshot for test responders and
    /// custom responders that are not backed by a provider implementation.
    fn request_audit(
        &self,
        request: &ModelResponseRequest,
    ) -> Result<ModelProviderRequestAudit, ModelResponseError> {
        let info = self.info();
        let stream_options =
            build_stream_options(request.reasoning_level.as_ref(), &request.session_id);
        let provider_request =
            ProviderAuditPayload::provider_independent_snapshot(serde_json::json!({
                "provider": info.provider_type.as_str(),
                "model": &info.model,
                "context": &request.context,
            }));
        build_request_audit(info, request, stream_options, provider_request)
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
            .map_err(|error| {
                ModelResponseError::from_provider_error(
                    error,
                    &ModelResponderInfo {
                        provider_type: crate::shared::protocol::messages::Provider::Unknown,
                        provider_name: "unknown",
                        model: model.to_owned(),
                        context_window: 0,
                    },
                )
            })?;
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

    fn request_audit(
        &self,
        request: &ModelResponseRequest,
    ) -> Result<ModelProviderRequestAudit, ModelResponseError> {
        let info = self.info();
        let stream_options =
            build_stream_options(request.reasoning_level.as_ref(), &request.session_id);
        let provider_request = self
            .provider
            .audit_payload(&request.context, &stream_options)
            .map_err(|error| ModelResponseError::from_provider_error(error, &info))?;
        build_request_audit(info, request, stream_options, provider_request)
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
                return Err(ModelResponseError::from_provider_error(error, &info));
            }
        };

        Ok(ModelResponse {
            stream: wrap_provider_stream(
                stream,
                info.provider_name,
                info.model.clone(),
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

fn build_request_audit(
    info: ModelResponderInfo,
    request: &ModelResponseRequest,
    stream_options: ProviderStreamOptions,
    provider_request: ProviderAuditPayload,
) -> Result<ModelProviderRequestAudit, ModelResponseError> {
    let stream_options = serde_json::to_value(stream_options).map_err(|error| {
        ModelResponseError::audit(format!(
            "failed to serialize provider stream options: {error}"
        ))
    })?;
    let reasoning_level = request
        .reasoning_level
        .as_ref()
        .map(ModelReasoningLevel::as_canonical_str)
        .map(str::to_owned);
    let capability_count = request.context.capabilities.as_ref().map_or(0, Vec::len);
    Ok(ModelProviderRequestAudit::new(
        info.provider_type,
        info.provider_name,
        info.model,
        info.context_window,
        request.session_id.clone(),
        reasoning_level,
        request.context.messages.len(),
        capability_count,
        stream_options,
        provider_request,
    ))
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
    model: String,
    health: Arc<ModelResponderHealth>,
    request_start: Instant,
) -> ModelResponseStream {
    Box::pin(async_stream::stream! {
        let mut stream = std::pin::pin!(stream);
        let mut saw_done = false;
        while let Some(item) = stream.next().await {
            match item {
                Ok(StreamEvent::Error { error }) => {
                    health.record_failure(provider_name);
                    histogram!("provider_request_duration_seconds", "provider" => provider_name)
                        .record(request_start.elapsed().as_secs_f64());
                    yield Err(ModelResponseError::from_provider_stream_event_error(
                        error,
                        provider_name,
                        &model,
                    ));
                    return;
                }
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
                    let info = ModelResponderInfo {
                        provider_type: crate::shared::protocol::messages::Provider::Unknown,
                        provider_name,
                        model: model.clone(),
                        context_window: 0,
                    };
                    yield Err(ModelResponseError::from_provider_error(error, &info));
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
    use crate::shared::protocol::messages::{Message, UserMessageContent};
    use crate::shared::protocol::model_audit::ProviderAuditPayloadKind;
    use futures::{StreamExt, stream};

    struct AuditProvider;

    #[async_trait]
    impl Provider for AuditProvider {
        fn provider_type(&self) -> crate::shared::protocol::messages::Provider {
            crate::shared::protocol::messages::Provider::OpenAi
        }

        fn model(&self) -> &str {
            "gpt-5.5-codex"
        }

        fn audit_payload(
            &self,
            _context: &Context,
            options: &ProviderStreamOptions,
        ) -> crate::domains::model::providers::shared::provider::ProviderResult<ProviderAuditPayload>
        {
            Ok(ProviderAuditPayload::exact_provider_envelope(
                serde_json::json!({
                    "model": self.model(),
                    "reasoningEffort": options.reasoning_effort.as_ref().map(ToString::to_string),
                    "promptCacheKey": options.prompt_cache_key.clone(),
                }),
            ))
        }

        async fn stream(
            &self,
            _context: &Context,
            _options: &ProviderStreamOptions,
        ) -> crate::domains::model::providers::shared::provider::ProviderResult<StreamEventStream>
        {
            Ok(Box::pin(stream::empty()))
        }
    }

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

    #[test]
    fn model_response_error_preserves_provider_failure_envelope() {
        let info = ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::OpenAi,
            provider_name: "openai",
            model: "gpt-5.5".to_owned(),
            context_window: 128_000,
        };
        let error = ModelResponseError::from_provider_error(
            ProviderError::Api {
                status: 429,
                message: "rate limit".to_owned(),
                code: Some("rate_limit_exceeded".to_owned()),
                retryable: true,
            },
            &info,
        );

        let failure = error.failure();

        assert_eq!(
            failure.code,
            crate::shared::server::failure::PROVIDER_API_ERROR
        );
        assert_eq!(failure.category, FailureCategory::Api);
        assert_eq!(failure.provider.as_deref(), Some("openai"));
        assert_eq!(failure.model.as_deref(), Some("gpt-5.5"));
        assert_eq!(failure.status_code, Some(429));
        assert_eq!(failure.error_type.as_deref(), Some("rate_limit_exceeded"));
        assert!(failure.retryable);
        assert!(failure.recoverable);
        assert_eq!(error.category(), "api");
        assert!(error.is_retryable());
    }

    #[test]
    fn model_response_error_auth_has_recoverable_canonical_failure() {
        let error = ModelResponseError::auth("sign in again");

        let failure = error.failure();

        assert_eq!(
            failure.code,
            crate::shared::server::failure::MODEL_AUTH_ERROR
        );
        assert_eq!(failure.category, FailureCategory::Auth);
        assert!(!failure.retryable);
        assert!(failure.recoverable);
    }

    #[tokio::test]
    async fn provider_stream_error_event_becomes_canonical_model_response_error() {
        let stream: StreamEventStream = Box::pin(stream::iter([Ok(StreamEvent::Error {
            error: "malformed provider stream JSON".into(),
        })]));
        let health = Arc::new(ModelResponderHealth::new());
        let mut wrapped = wrap_provider_stream(
            stream,
            "openai",
            "gpt-5.5".to_owned(),
            health,
            Instant::now(),
        );

        let item = wrapped.next().await.expect("stream item");
        let error = item.expect_err("stream error should become model response error");
        let failure = error.failure();

        assert_eq!(
            failure.code,
            crate::shared::server::failure::PROVIDER_SSE_PARSE_ERROR
        );
        assert_eq!(failure.category, FailureCategory::Parse);
        assert_eq!(failure.origin, FailureOrigin::ModelProvider);
        assert_eq!(failure.provider.as_deref(), Some("openai"));
        assert_eq!(failure.model.as_deref(), Some("gpt-5.5"));
        assert_eq!(failure.error_type.as_deref(), Some("stream_event_error"));
        assert_eq!(
            failure.details.as_ref().unwrap()["kind"],
            "stream_event_error"
        );
    }

    #[test]
    fn provider_backed_request_audit_uses_stream_options_and_exact_payload() {
        let responder = ProviderBackedModelResponder {
            provider: Arc::new(AuditProvider),
            health: Arc::new(ModelResponderHealth::new()),
        };
        let request = ModelResponseRequest {
            context: Context {
                messages: vec![Message::User {
                    content: UserMessageContent::Text("hello".to_owned()),
                    timestamp: None,
                }]
                .into(),
                ..Context::default()
            },
            session_id: "sess-1".to_owned(),
            reasoning_level: Some(ModelReasoningLevel::XHigh),
            cancel: CancellationToken::new(),
            retry_config: None,
        };

        let audit = responder.request_audit(&request).unwrap();

        assert_eq!(audit.format, "tron.model_provider_request.v1");
        assert_eq!(
            audit.provider_type,
            crate::shared::protocol::messages::Provider::OpenAi
        );
        assert_eq!(audit.provider_name, "openai");
        assert_eq!(audit.model, "gpt-5.5-codex");
        assert_eq!(audit.session_id, "sess-1");
        assert_eq!(audit.reasoning_level.as_deref(), Some("x_high"));
        assert_eq!(audit.message_count, 1);
        assert_eq!(audit.capability_count, 0);
        assert_eq!(
            audit.stream_options["promptCacheKey"],
            serde_json::json!("tron-session-sess-1")
        );
        assert_eq!(
            audit.stream_options["reasoningEffort"],
            serde_json::json!("xhigh")
        );
        assert_eq!(
            audit.provider_request.kind,
            ProviderAuditPayloadKind::ExactProviderEnvelope
        );
        assert_eq!(
            audit.provider_request.body["promptCacheKey"],
            serde_json::json!("tron-session-sess-1")
        );
    }
}
