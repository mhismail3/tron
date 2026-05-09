//! Kimi provider implementing the [`Provider`] trait.
//!
//! Uses Kimi's `OpenAI` chat completions-compatible endpoint with Bearer auth.
//! Custom message converter and stream handler for the chat completions wire format.

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};
use tracing::{debug, error, instrument};

use crate::domains::model::providers::compose_context_parts;
use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::messages::Context;

use super::message_converter::{convert_messages, convert_tools};
use super::stream_handler::{ChatCompletionChunk, KimiStreamState, process_chunk};
use super::types::{
    DEFAULT_BASE_URL, DEFAULT_MAX_OUTPUT_TOKENS, KimiAuth, KimiConfig, get_kimi_model,
};

/// SSE parser options — Kimi uses `[DONE]` marker, no remaining buffer processing.
static SSE_OPTIONS: crate::domains::model::providers::SseParserOptions =
    crate::domains::model::providers::SseParserOptions {
        process_remaining_buffer: false,
    };

/// Kimi LLM provider.
pub struct KimiProvider {
    config: KimiConfig,
    client: reqwest::Client,
}

impl KimiProvider {
    /// Create a new Kimi provider.
    #[must_use]
    pub fn new(config: KimiConfig) -> Self {
        Self {
            config,
            client: reqwest::Client::new(),
        }
    }

    /// Create a new Kimi provider with a shared HTTP client.
    #[must_use]
    pub fn with_client(config: KimiConfig, client: reqwest::Client) -> Self {
        Self { config, client }
    }

    /// Build HTTP headers — Bearer auth, Content-Type, no anthropic-version.
    fn build_headers(&self) -> ProviderResult<HeaderMap> {
        let mut headers = HeaderMap::new();
        let _ = headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));

        match &self.config.auth {
            KimiAuth::ApiKey { api_key } => {
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

    /// Build the system prompt — plain string from composed context parts.
    fn build_system_prompt(context: &Context) -> Option<String> {
        let parts = compose_context_parts(context);
        if parts.is_empty() {
            return None;
        }
        Some(parts.join("\n\n"))
    }

    /// Calculate `max_tokens`: options → config → model registry default.
    fn calculate_max_tokens(&self, options: &ProviderStreamOptions) -> u32 {
        options.max_tokens.unwrap_or_else(|| {
            self.config.max_tokens.unwrap_or_else(|| {
                get_kimi_model(&self.config.model)
                    .map_or(DEFAULT_MAX_OUTPUT_TOKENS, |m| m.max_output)
            })
        })
    }

    /// Check if the current model supports thinking.
    fn model_supports_thinking(&self) -> bool {
        get_kimi_model(&self.config.model).is_some_and(|m| m.supports_thinking)
    }

    /// Check if the current model supports images.
    fn model_supports_images(&self) -> bool {
        get_kimi_model(&self.config.model).is_some_and(|m| m.supports_images)
    }

    /// Check if the current model supports tools.
    fn model_supports_tools(&self) -> bool {
        get_kimi_model(&self.config.model).is_some_and(|m| m.supports_tools)
    }

    /// Build the request body for the chat completions API.
    fn build_request_body(&self, context: &Context, options: &ProviderStreamOptions) -> Value {
        let supports_images = self.model_supports_images();
        let messages = convert_messages(&context.messages, supports_images);

        let mut body = json!({
            "model": self.config.model,
            "max_completion_tokens": self.calculate_max_tokens(options),
            "stream": true,
            "stream_options": {"include_usage": true},
        });

        // System message goes first in the messages array
        let mut api_messages: Vec<Value> = Vec::new();
        if let Some(system) = Self::build_system_prompt(context) {
            api_messages.push(json!({"role": "system", "content": system}));
        }
        for msg in &messages {
            api_messages.push(serde_json::to_value(msg).unwrap_or_default());
        }
        body["messages"] = Value::Array(api_messages);

        // Tools (only for tool-capable models)
        if self.model_supports_tools()
            && let Some(ref tools) = context.tools
            && !tools.is_empty()
        {
            let tool_defs = convert_tools(tools);
            body["tools"] = serde_json::to_value(&tool_defs).unwrap_or_default();
        }

        // Thinking configuration (only for thinking-capable models)
        let thinking_enabled =
            options.enable_thinking == Some(true) && self.model_supports_thinking();
        if thinking_enabled {
            // Force temperature=1.0, top_p=0.95 when thinking is enabled (K2.5 constraint)
            body["temperature"] = json!(1.0);
            body["top_p"] = json!(0.95);
        }

        body
    }

    /// Perform the streaming HTTP request and return the event stream.
    #[instrument(skip_all, fields(model = %self.config.model))]
    async fn stream_internal(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        let body = self.build_request_body(context, options);

        let base_url = self.config.base_url.as_deref().unwrap_or(DEFAULT_BASE_URL);
        let url = format!("{base_url}/chat/completions");

        let headers = self.build_headers()?;

        let msg_count = body["messages"].as_array().map_or(0, std::vec::Vec::len);
        debug!(
            model = %self.config.model,
            max_tokens = %body["max_completion_tokens"],
            message_count = msg_count,
            has_tools = body.get("tools").is_some(),
            "Sending Kimi request"
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
                .and_then(crate::shared::retry::parse_retry_after_header);
            let body_text = response.text().await.unwrap_or_default();
            let err_info = crate::domains::model::providers::error_parsing::parse_api_error(
                &body_text,
                status.as_u16(),
            );
            error!(
                status = status.as_u16(),
                code = err_info.code.as_deref().unwrap_or("unknown"),
                retryable = err_info.retryable,
                "Kimi API error"
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

        Ok(
            crate::domains::model::providers::stream_pipeline::sse_to_event_stream::<
                ChatCompletionChunk,
                KimiStreamState,
                _,
            >(
                response,
                &SSE_OPTIONS,
                KimiStreamState::new(),
                process_chunk,
            ),
        )
    }
}

#[async_trait]
impl Provider for KimiProvider {
    fn provider_type(&self) -> crate::shared::messages::Provider {
        crate::shared::messages::Provider::Kimi
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    fn audit_payload(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<serde_json::Value> {
        Ok(self.build_request_body(context, options))
    }

    #[instrument(skip_all, fields(provider = "kimi", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        crate::domains::model::providers::stream_pipeline::wrap_provider_stream(
            "kimi",
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

    fn test_config() -> KimiConfig {
        KimiConfig {
            model: "kimi-k2.5".into(),
            auth: KimiAuth::ApiKey {
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

    // ── Provider metadata ────────────────────────────────────────────────

    #[test]
    fn provider_type_is_kimi() {
        let provider = KimiProvider::new(test_config());
        assert_eq!(
            provider.provider_type(),
            crate::shared::messages::Provider::Kimi
        );
    }

    #[test]
    fn provider_model_returns_config_model() {
        let provider = KimiProvider::new(test_config());
        assert_eq!(provider.model(), "kimi-k2.5");
    }

    // ── Headers ──────────────────────────────────────────────────────────

    #[test]
    fn headers_has_bearer_auth() {
        let provider = KimiProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(headers[AUTHORIZATION], "Bearer test-key");
    }

    #[test]
    fn headers_has_content_type() {
        let provider = KimiProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(headers[CONTENT_TYPE], "application/json");
    }

    #[test]
    fn headers_no_anthropic_version() {
        let provider = KimiProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert!(headers.get("anthropic-version").is_none());
    }

    #[test]
    fn headers_no_x_api_key() {
        let provider = KimiProvider::new(test_config());
        let headers = provider.build_headers().unwrap();
        assert!(headers.get("x-api-key").is_none());
    }

    // ── System prompt ────────────────────────────────────────────────────

    #[test]
    fn system_prompt_simple_string() {
        let ctx = context_with_system("You are helpful.");
        let prompt = KimiProvider::build_system_prompt(&ctx).unwrap();
        assert_eq!(prompt, "You are helpful.");
    }

    #[test]
    fn system_prompt_empty_context_returns_none() {
        let ctx = Context::default();
        assert!(KimiProvider::build_system_prompt(&ctx).is_none());
    }

    // ── Max tokens ───────────────────────────────────────────────────────

    #[test]
    fn max_tokens_from_options() {
        let provider = KimiProvider::new(test_config());
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
        let provider = KimiProvider::new(cfg);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 8000);
    }

    #[test]
    fn max_tokens_from_model_registry() {
        let provider = KimiProvider::new(test_config());
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 32_768);
    }

    #[test]
    fn max_tokens_retired_generation_model() {
        let mut cfg = test_config();
        cfg.model = "moonshot-v1-8k".into();
        let provider = KimiProvider::new(cfg);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 4_096);
    }

    // ── Model capabilities ───────────────────────────────────────────────

    #[test]
    fn k2_5_supports_all() {
        let provider = KimiProvider::new(test_config());
        assert!(provider.model_supports_thinking());
        assert!(provider.model_supports_images());
        assert!(provider.model_supports_tools());
    }

    #[test]
    fn moonshot_v1_supports_nothing() {
        let mut cfg = test_config();
        cfg.model = "moonshot-v1-8k".into();
        let provider = KimiProvider::new(cfg);
        assert!(!provider.model_supports_thinking());
        assert!(!provider.model_supports_images());
        assert!(!provider.model_supports_tools());
    }

    #[test]
    fn k2_0905_no_thinking_no_images() {
        let mut cfg = test_config();
        cfg.model = "kimi-k2-0905-preview".into();
        let provider = KimiProvider::new(cfg);
        assert!(!provider.model_supports_thinking());
        assert!(!provider.model_supports_images());
        assert!(provider.model_supports_tools());
    }

    // ── Request body ─────────────────────────────────────────────────────

    #[test]
    fn request_body_basic() {
        let provider = KimiProvider::new(test_config());
        let ctx = context_with_system("You are helpful.");
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);

        assert_eq!(body["model"], "kimi-k2.5");
        assert_eq!(body["stream"], true);
        assert_eq!(body["stream_options"]["include_usage"], true);
        assert_eq!(body["max_completion_tokens"], 32_768);
        // System message should be in messages array
        let msgs = body["messages"].as_array().unwrap();
        assert_eq!(msgs[0]["role"], "system");
        assert_eq!(msgs[0]["content"], "You are helpful.");
    }

    #[test]
    fn request_body_no_max_tokens_field() {
        let provider = KimiProvider::new(test_config());
        let ctx = context_with_system("test");
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);

        // Should use max_completion_tokens, NOT max_tokens
        assert!(body.get("max_tokens").is_none());
        assert!(body.get("max_completion_tokens").is_some());
    }

    #[test]
    fn request_body_with_tools() {
        let provider = KimiProvider::new(test_config());
        let ctx = Context {
            tools: Some(vec![crate::shared::tools::Tool {
                name: "bash".into(),
                description: "Run commands".into(),
                parameters: crate::shared::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::default(),
                },
            }]),
            ..Context::default()
        };
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        let tools = body["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["type"], "function");
        assert_eq!(tools[0]["function"]["name"], "bash");
    }

    #[test]
    fn request_body_no_tools_for_retired_generation_model() {
        let mut cfg = test_config();
        cfg.model = "moonshot-v1-8k".into();
        let provider = KimiProvider::new(cfg);
        let ctx = Context {
            tools: Some(vec![crate::shared::tools::Tool {
                name: "bash".into(),
                description: "Run commands".into(),
                parameters: crate::shared::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::default(),
                },
            }]),
            ..Context::default()
        };
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert!(body.get("tools").is_none());
    }

    #[test]
    fn request_body_thinking_forces_temperature() {
        let provider = KimiProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions {
            enable_thinking: Some(true),
            ..Default::default()
        };
        let body = provider.build_request_body(&ctx, &options);
        assert_eq!(body["temperature"], 1.0);
        assert_eq!(body["top_p"], 0.95);
    }

    #[test]
    fn request_body_no_thinking_no_temperature() {
        let provider = KimiProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert!(body.get("temperature").is_none());
    }

    #[test]
    fn request_body_no_thinking_for_non_thinking_model() {
        let mut cfg = test_config();
        cfg.model = "kimi-k2-0905-preview".into();
        let provider = KimiProvider::new(cfg);
        let ctx = Context::default();
        let options = ProviderStreamOptions {
            enable_thinking: Some(true),
            ..Default::default()
        };
        let body = provider.build_request_body(&ctx, &options);
        // Thinking not supported → no forced temperature
        assert!(body.get("temperature").is_none());
    }

    #[test]
    fn request_url_default() {
        let base_url = DEFAULT_BASE_URL;
        let url = format!("{base_url}/chat/completions");
        assert_eq!(url, "https://api.moonshot.ai/v1/chat/completions");
    }

    #[test]
    fn request_url_custom_base() {
        let mut cfg = test_config();
        cfg.base_url = Some("https://custom.api.com/v1".into());
        let base_url = cfg.base_url.as_deref().unwrap_or(DEFAULT_BASE_URL);
        let url = format!("{base_url}/chat/completions");
        assert_eq!(url, "https://custom.api.com/v1/chat/completions");
    }

    #[test]
    fn request_body_no_tools_when_empty() {
        let provider = KimiProvider::new(test_config());
        let ctx = Context {
            tools: Some(vec![]),
            ..Context::default()
        };
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert!(body.get("tools").is_none());
    }
}
