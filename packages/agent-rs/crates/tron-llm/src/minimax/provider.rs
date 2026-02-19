//! `MiniMax` provider implementing the [`Provider`] trait.
//!
//! Uses `MiniMax`'s Anthropic-compatible endpoint with Bearer auth.
//! Reuses Anthropic message converter, stream handler, and SSE types.
//! No OAuth, no prompt caching, no image support, no adaptive thinking.

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};
use tracing::{debug, error, instrument, warn};

use crate::anthropic::message_converter::convert_messages;
use crate::anthropic::message_sanitizer::sanitize_messages;
use crate::anthropic::stream_handler::{create_stream_state_for, process_sse_event};
use crate::anthropic::types::{
    AnthropicMessageParam, AnthropicRequest, AnthropicSseEvent, AnthropicTool,
};
use tron_core::messages::Provider as ProviderType;
use crate::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::compose_context_parts;
use tron_core::messages::Context;

use super::types::{DEFAULT_BASE_URL, DEFAULT_MAX_OUTPUT_TOKENS, MiniMaxAuth, MiniMaxConfig, get_minimax_model};

/// API version header value (Anthropic-compatible).
const API_VERSION: &str = "2023-06-01";

/// Default SSE parser options.
static SSE_OPTIONS: crate::SseParserOptions = crate::SseParserOptions {
    process_remaining_buffer: true,
};

/// `MiniMax` LLM provider.
pub struct MiniMaxProvider {
    config: MiniMaxConfig,
    client: reqwest::Client,
}

impl MiniMaxProvider {
    /// Create a new `MiniMax` provider.
    #[must_use]
    pub fn new(config: MiniMaxConfig) -> Self {
        Self {
            config,
            client: reqwest::Client::new(),
        }
    }

    /// Create a new `MiniMax` provider with a shared HTTP client.
    #[must_use]
    pub fn with_client(config: MiniMaxConfig, client: reqwest::Client) -> Self {
        Self { config, client }
    }

    /// Build HTTP headers for the request.
    ///
    /// `MiniMax` uses Bearer auth (not x-api-key), no beta headers, no browser access.
    fn build_headers(&self) -> ProviderResult<HeaderMap> {
        let mut headers = HeaderMap::new();
        let _ = headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        let _ = headers.insert("anthropic-version", HeaderValue::from_static(API_VERSION));

        match &self.config.auth {
            MiniMaxAuth::ApiKey { api_key } => {
                let auth_value = format!("Bearer {api_key}");
                let _ = headers.insert(
                    AUTHORIZATION,
                    HeaderValue::from_str(&auth_value).map_err(|e| ProviderError::Auth {
                        message: format!("Invalid API key header: {e}"),
                    })?,
                );
            }
        }

        Ok(headers)
    }

    /// Build the system prompt parameter — plain string, no cache breakpoints.
    fn build_system_param(context: &Context) -> Option<Value> {
        let parts = compose_context_parts(context);
        if parts.is_empty() {
            return None;
        }
        Some(json!(parts.join("\n\n")))
    }

    /// Build tool definitions without cache control.
    fn build_tools(context: &Context) -> Option<Vec<AnthropicTool>> {
        let tools = context.tools.as_ref()?;
        if tools.is_empty() {
            return None;
        }

        let anthropic_tools: Vec<AnthropicTool> = tools
            .iter()
            .map(|t| AnthropicTool {
                name: t.name.clone(),
                description: t.description.clone(),
                input_schema: serde_json::to_value(&t.parameters).unwrap_or_default(),
                cache_control: None,
            })
            .collect();

        Some(anthropic_tools)
    }

    /// Build thinking configuration — enabled only, never adaptive.
    fn build_thinking_config(options: &ProviderStreamOptions) -> Option<Value> {
        if options.enable_thinking != Some(true) {
            return None;
        }

        let budget = options.thinking_budget.unwrap_or(DEFAULT_MAX_OUTPUT_TOKENS / 4);
        Some(json!({
            "type": "enabled",
            "budget_tokens": budget,
        }))
    }

    /// Calculate `max_tokens`: options → config → model registry fallback.
    fn calculate_max_tokens(&self, options: &ProviderStreamOptions) -> u32 {
        options.max_tokens.unwrap_or_else(|| {
            self.config.max_tokens.unwrap_or_else(|| {
                get_minimax_model(&self.config.model)
                    .map_or(DEFAULT_MAX_OUTPUT_TOKENS, |m| m.max_output)
            })
        })
    }

    /// Strip image content blocks from messages (`MiniMax` doesn't support images).
    fn strip_images(messages: &mut [AnthropicMessageParam]) {
        let mut warned = false;
        for msg in messages.iter_mut() {
            let had_images = msg.content.len();
            msg.content.retain(|block| {
                block
                    .get("type")
                    .and_then(Value::as_str)
                    .is_none_or(|t| t != "image")
            });
            if !warned && msg.content.len() < had_images {
                warn!("Stripped image content blocks — MiniMax does not support images");
                warned = true;
            }
        }
    }

    /// Build the request body — no `output_config`, no `cache_control`.
    fn build_request(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
        messages: Vec<AnthropicMessageParam>,
    ) -> AnthropicRequest {
        AnthropicRequest {
            model: self.config.model.clone(),
            max_tokens: self.calculate_max_tokens(options),
            messages,
            system: Self::build_system_param(context),
            tools: Self::build_tools(context),
            stream: true,
            thinking: Self::build_thinking_config(options),
            output_config: None,
            stop_sequences: options.stop_sequences.clone(),
        }
    }

    /// Perform the streaming HTTP request and return the event stream.
    #[instrument(skip_all, fields(model = %self.config.model))]
    async fn stream_internal(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        let sanitized = sanitize_messages(context.messages.clone());
        let mut messages = convert_messages(&sanitized);

        // Strip images — MiniMax doesn't support them
        Self::strip_images(&mut messages);

        let request = self.build_request(context, options, messages);

        let base_url = self.config.base_url.as_deref().unwrap_or(DEFAULT_BASE_URL);
        let url = format!("{base_url}/v1/messages");

        let headers = self.build_headers()?;
        let body = serde_json::to_value(&request).map_err(ProviderError::Json)?;

        debug!(
            model = %request.model,
            max_tokens = request.max_tokens,
            message_count = request.messages.len(),
            has_tools = request.tools.is_some(),
            has_thinking = request.thinking.is_some(),
            "Sending MiniMax request"
        );

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .json(&body)
            .send()
            .await
            .map_err(ProviderError::Http)?;

        let status = response.status();
        if !status.is_success() {
            let retry_after = response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(tron_core::retry::parse_retry_after_header);
            let body_text = response.text().await.unwrap_or_default();
            let err_info = crate::error_parsing::parse_api_error(&body_text, status.as_u16());
            error!(
                status = status.as_u16(),
                code = err_info.code.as_deref().unwrap_or("unknown"),
                retryable = err_info.retryable,
                "MiniMax API error"
            );
            if status.as_u16() == 429 {
                return Err(ProviderError::RateLimited {
                    retry_after_ms: retry_after.unwrap_or(0),
                    message: err_info.message,
                });
            }
            return Err(ProviderError::Api {
                status: status.as_u16(),
                message: err_info.message,
                code: err_info.code,
                retryable: err_info.retryable,
            });
        }

        Ok(crate::stream_pipeline::sse_to_event_stream::<AnthropicSseEvent, _, _>(
            response,
            &SSE_OPTIONS,
            create_stream_state_for(tron_core::messages::ProviderType::MiniMax),
            process_sse_event,
        ))
    }
}

#[async_trait]
impl Provider for MiniMaxProvider {
    fn provider_type(&self) -> ProviderType {
        ProviderType::MiniMax
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    #[instrument(skip_all, fields(provider = "minimax", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        crate::stream_pipeline::wrap_provider_stream(
            "minimax",
            self.stream_internal(context, options).await,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anthropic::types::AnthropicMessageParam;
    use serde_json::json;

    fn test_config() -> MiniMaxConfig {
        MiniMaxConfig {
            model: "MiniMax-M2.5".into(),
            auth: MiniMaxAuth::ApiKey {
                api_key: "test-key".into(),
            },
            max_tokens: None,
            base_url: None,
            retry: None,
        }
    }

    fn context_with_system(prompt: &str) -> Context {
        Context {
            system_prompt: Some(prompt.into()),
            ..Context::default()
        }
    }

    // ── Provider metadata ───────────────────────────────────────────────

    #[test]
    fn provider_type_is_minimax() {
        let provider = MiniMaxProvider::new(test_config());
        assert_eq!(provider.provider_type(), ProviderType::MiniMax);
    }

    #[test]
    fn provider_model_returns_config_model() {
        let provider = MiniMaxProvider::new(test_config());
        assert_eq!(provider.model(), "MiniMax-M2.5");
    }

    // ── Headers ─────────────────────────────────────────────────────────

    #[test]
    fn headers_has_bearer_auth() {
        let provider = MiniMaxProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(headers[AUTHORIZATION], "Bearer test-key");
    }

    #[test]
    fn headers_has_anthropic_version() {
        let provider = MiniMaxProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(headers["anthropic-version"], API_VERSION);
    }

    #[test]
    fn headers_has_content_type() {
        let provider = MiniMaxProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(headers[CONTENT_TYPE], "application/json");
    }

    #[test]
    fn headers_no_x_api_key() {
        let provider = MiniMaxProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert!(headers.get("x-api-key").is_none());
    }

    #[test]
    fn headers_no_anthropic_beta() {
        let provider = MiniMaxProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert!(headers.get("anthropic-beta").is_none());
    }

    #[test]
    fn headers_no_browser_access() {
        let provider = MiniMaxProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert!(
            headers
                .get("anthropic-dangerous-direct-browser-access")
                .is_none()
        );
    }

    // ── System prompt ───────────────────────────────────────────────────

    #[test]
    fn system_param_simple_string() {
        let ctx = context_with_system("You are helpful.");
        let param = MiniMaxProvider::build_system_param(&ctx).unwrap();
        assert_eq!(param.as_str().unwrap(), "You are helpful.");
    }

    #[test]
    fn system_param_empty_context_returns_none() {
        let ctx = Context::default();
        assert!(MiniMaxProvider::build_system_param(&ctx).is_none());
    }

    // ── Tools ───────────────────────────────────────────────────────────

    #[test]
    fn build_tools_no_cache_control() {
        let ctx = Context {
            tools: Some(vec![tron_core::tools::Tool {
                name: "bash".into(),
                description: "Run commands".into(),
                parameters: tron_core::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: Default::default(),
                },
            }]),
            ..Context::default()
        };
        let tools = MiniMaxProvider::build_tools(&ctx).unwrap();
        assert_eq!(tools.len(), 1);
        assert!(tools[0].cache_control.is_none());
    }

    #[test]
    fn build_tools_empty_returns_none() {
        let ctx = Context {
            tools: Some(vec![]),
            ..Context::default()
        };
        assert!(MiniMaxProvider::build_tools(&ctx).is_none());
    }

    // ── Thinking config ─────────────────────────────────────────────────

    #[test]
    fn thinking_config_disabled() {
        let options = ProviderStreamOptions::default();
        assert!(MiniMaxProvider::build_thinking_config(&options).is_none());
    }

    #[test]
    fn thinking_config_enabled_not_adaptive() {
        let options = ProviderStreamOptions {
            enable_thinking: Some(true),
            ..Default::default()
        };
        let config = MiniMaxProvider::build_thinking_config(&options).unwrap();
        assert_eq!(config["type"], "enabled");
        assert!(config.get("budget_tokens").is_some());
        assert_ne!(config["type"], "adaptive");
    }

    #[test]
    fn thinking_config_custom_budget() {
        let options = ProviderStreamOptions {
            enable_thinking: Some(true),
            thinking_budget: Some(8000),
            ..Default::default()
        };
        let config = MiniMaxProvider::build_thinking_config(&options).unwrap();
        assert_eq!(config["budget_tokens"], 8000);
    }

    // ── Max tokens ──────────────────────────────────────────────────────

    #[test]
    fn max_tokens_from_options() {
        let provider = MiniMaxProvider::new(test_config());
        let options = ProviderStreamOptions {
            max_tokens: Some(4096),
            ..Default::default()
        };
        assert_eq!(provider.calculate_max_tokens(&options), 4096);
    }

    #[test]
    fn max_tokens_from_config() {
        let mut cfg = test_config();
        cfg.max_tokens = Some(8000);
        let provider = MiniMaxProvider::new(cfg);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 8000);
    }

    #[test]
    fn max_tokens_from_model_registry() {
        let provider = MiniMaxProvider::new(test_config());
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 128_000);
    }

    // ── Request building ────────────────────────────────────────────────

    #[test]
    fn build_request_basic() {
        let provider = MiniMaxProvider::new(test_config());
        let ctx = context_with_system("You are helpful.");
        let options = ProviderStreamOptions::default();
        let messages = convert_messages(&ctx.messages);
        let req = provider.build_request(&ctx, &options, messages);

        assert_eq!(req.model, "MiniMax-M2.5");
        assert!(req.stream);
        assert!(req.system.is_some());
        assert!(req.thinking.is_none());
        assert!(req.output_config.is_none());
    }

    // ── Image stripping ─────────────────────────────────────────────────

    #[test]
    fn strip_images_removes_image_content() {
        let mut messages = vec![AnthropicMessageParam {
            role: "user".into(),
            content: vec![
                json!({"type": "text", "text": "Look at this"}),
                json!({"type": "image", "source": {"type": "base64", "data": "..."}}),
            ],
        }];
        MiniMaxProvider::strip_images(&mut messages);
        assert_eq!(messages[0].content.len(), 1);
        assert_eq!(messages[0].content[0]["type"], "text");
    }

    #[test]
    fn strip_images_preserves_text() {
        let mut messages = vec![AnthropicMessageParam {
            role: "user".into(),
            content: vec![
                json!({"type": "text", "text": "hello"}),
                json!({"type": "text", "text": "world"}),
            ],
        }];
        MiniMaxProvider::strip_images(&mut messages);
        assert_eq!(messages[0].content.len(), 2);
    }

    #[test]
    fn strip_images_empty_messages_unchanged() {
        let mut messages = vec![AnthropicMessageParam {
            role: "user".into(),
            content: vec![json!({"type": "text", "text": "hello"})],
        }];
        MiniMaxProvider::strip_images(&mut messages);
        assert_eq!(messages[0].content.len(), 1);
    }

    // ── parse_api_error (via shared crate::error_parsing) ─────────────
}
