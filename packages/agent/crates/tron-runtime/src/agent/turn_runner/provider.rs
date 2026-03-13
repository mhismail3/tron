use std::sync::Arc;

use tokio_util::sync::CancellationToken;
use tron_core::messages::Context;
use tron_core::retry::RetryConfig;
use tron_llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
use tron_llm::{StreamFactory, StreamRetryConfig, with_provider_retry};

use crate::types::{ReasoningLevel, RunContext};

pub(super) fn build_stream_options(run_context: &RunContext) -> ProviderStreamOptions {
    ProviderStreamOptions {
        enable_thinking: Some(true),
        effort_level: run_context
            .reasoning_level
            .as_ref()
            .and_then(ReasoningLevel::as_anthropic_effort),
        reasoning_effort: run_context
            .reasoning_level
            .as_ref()
            .map(ReasoningLevel::as_openai_reasoning),
        thinking_level: run_context
            .reasoning_level
            .as_ref()
            .map(|r| r.as_gemini_thinking_level().to_owned()),
        ..Default::default()
    }
}

pub(super) async fn open_stream(
    provider: &Arc<dyn Provider>,
    context: Context,
    stream_options: ProviderStreamOptions,
    cancel: &CancellationToken,
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
            cancel_token: Some(cancel.clone()),
        };
        Ok(with_provider_retry(factory, retry_cfg))
    } else {
        provider.stream(&context, &stream_options).await
    }
}
