//! Ollama provider implementing the [`Provider`] trait.
//!
//! Uses Ollama's `OpenAI` chat completions-compatible endpoint. No authentication
//! required — Ollama runs locally. Provides graceful error messages when Ollama
//! is not running or the model is not pulled.

use async_trait::async_trait;
use reqwest::header::{CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};
use tracing::{debug, error, instrument};

use crate::core::messages::Context;
use crate::llm::compose_context_parts;
use crate::llm::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};

use super::message_converter::{convert_messages, convert_tools};
use super::stream_handler::{ChatCompletionChunk, OllamaStreamState, process_chunk};
use super::types::{DEFAULT_BASE_URL, DEFAULT_MAX_OUTPUT_TOKENS, OllamaConfig, get_ollama_model};

/// SSE parser options — Ollama uses `[DONE]` marker, no remaining buffer processing.
static SSE_OPTIONS: crate::llm::SseParserOptions = crate::llm::SseParserOptions {
    process_remaining_buffer: false,
};

/// Ollama LLM provider — local inference, no auth.
pub struct OllamaProvider {
    config: OllamaConfig,
    client: reqwest::Client,
}

impl OllamaProvider {
    /// Create a new Ollama provider.
    #[must_use]
    pub fn new(config: OllamaConfig) -> Self {
        Self {
            config,
            client: reqwest::Client::new(),
        }
    }

    /// Create a new Ollama provider with a shared HTTP client.
    #[must_use]
    pub fn with_client(config: OllamaConfig, client: reqwest::Client) -> Self {
        Self { config, client }
    }

    /// Get the effective base URL.
    fn base_url(&self) -> &str {
        self.config.base_url.as_deref().unwrap_or(DEFAULT_BASE_URL)
    }

    /// Build HTTP headers — Content-Type only, no auth.
    fn build_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        let _ = headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers
    }

    /// Build the system prompt from context parts.
    fn build_system_prompt(context: &Context) -> Option<String> {
        let parts = compose_context_parts(context);
        if parts.is_empty() {
            return None;
        }
        Some(parts.join("\n\n"))
    }

    /// Calculate `max_tokens`: options → config → model registry fallback.
    fn calculate_max_tokens(&self, options: &ProviderStreamOptions) -> u32 {
        options.max_tokens.unwrap_or_else(|| {
            self.config.max_tokens.unwrap_or_else(|| {
                get_ollama_model(&self.config.model)
                    .map_or(DEFAULT_MAX_OUTPUT_TOKENS, |m| m.max_output)
            })
        })
    }

    /// Check if the current model supports images.
    fn model_supports_images(&self) -> bool {
        get_ollama_model(&self.config.model).is_some_and(|m| m.supports_images)
    }

    /// Check if the current model supports tools.
    fn model_supports_tools(&self) -> bool {
        get_ollama_model(&self.config.model).is_some_and(|m| m.supports_tools)
    }

    /// Build the request body for the chat completions API.
    fn build_request_body(&self, context: &Context, options: &ProviderStreamOptions) -> Value {
        let supports_images = self.model_supports_images();
        let messages = convert_messages(&context.messages, supports_images);

        let mut body = json!({
            "model": self.config.model,
            "max_tokens": self.calculate_max_tokens(options),
            "stream": true,
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

        body
    }

    /// Map reqwest connection errors to actionable Ollama-specific messages.
    fn map_connection_error(err: reqwest::Error, _model: &str) -> ProviderError {
        if err.is_connect() || err.is_timeout() {
            ProviderError::Api {
                status: 503,
                message: format!(
                    "Ollama is not running — start it with 'brew services start ollama' \
                     (attempted to reach {}). Original error: {err}",
                    DEFAULT_BASE_URL
                ),
                code: None,
                retryable: true,
            }
        } else {
            ProviderError::Http(err)
        }
    }

    /// Map HTTP error responses to actionable Ollama-specific messages.
    fn map_http_error(status: u16, body_text: &str, model: &str) -> ProviderError {
        if status == 404 {
            ProviderError::Api {
                status: 404,
                message: format!(
                    "Model '{model}' not found in Ollama — pull it with 'ollama pull {model}'"
                ),
                code: None,
                retryable: false,
            }
        } else {
            let err_info = crate::llm::error_parsing::parse_api_error(body_text, status);
            ProviderError::Api {
                status,
                message: format!("Ollama server error: {}", err_info.message),
                code: err_info.code,
                retryable: err_info.retryable,
            }
        }
    }

    /// Perform the streaming HTTP request and return the event stream.
    #[instrument(skip_all, fields(model = %self.config.model))]
    async fn stream_internal(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        let body = self.build_request_body(context, options);
        let url = format!("{}/v1/chat/completions", self.base_url());
        let headers = Self::build_headers();

        let msg_count = body["messages"]
            .as_array()
            .map_or(0, std::vec::Vec::len);
        debug!(
            model = %self.config.model,
            max_tokens = %body["max_tokens"],
            message_count = msg_count,
            has_tools = body.get("tools").is_some(),
            "Sending Ollama request"
        );

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .json(&body)
            .send()
            .await
            .map_err(|e| Self::map_connection_error(e, &self.config.model))?;

        let status = response.status();
        if !status.is_success() {
            let body_text = response.text().await.unwrap_or_default();
            error!(
                status = status.as_u16(),
                body = %body_text,
                "Ollama API error"
            );
            return Err(Self::map_http_error(
                status.as_u16(),
                &body_text,
                &self.config.model,
            ));
        }

        Ok(crate::llm::stream_pipeline::sse_to_event_stream::<
            ChatCompletionChunk,
            OllamaStreamState,
            _,
        >(
            response,
            &SSE_OPTIONS,
            OllamaStreamState::new(),
            process_chunk,
        ))
    }
}

#[async_trait]
impl Provider for OllamaProvider {
    fn provider_type(&self) -> crate::core::messages::Provider {
        crate::core::messages::Provider::Ollama
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    #[instrument(skip_all, fields(provider = "ollama", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        crate::llm::stream_pipeline::wrap_provider_stream(
            "ollama",
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

    fn test_config() -> OllamaConfig {
        OllamaConfig {
            model: "gemma4:e4b".into(),
            base_url: None,
            max_tokens: None,
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
    fn provider_type_is_ollama() {
        let provider = OllamaProvider::new(test_config());
        assert_eq!(
            provider.provider_type(),
            crate::core::messages::Provider::Ollama
        );
    }

    #[test]
    fn provider_model_returns_config_model() {
        let provider = OllamaProvider::new(test_config());
        assert_eq!(provider.model(), "gemma4:e4b");
    }

    // ── Base URL ─────────────────────────────────────────────────────────

    #[test]
    fn base_url_default() {
        let provider = OllamaProvider::new(test_config());
        assert_eq!(provider.base_url(), "http://localhost:11434");
    }

    #[test]
    fn base_url_custom() {
        let mut cfg = test_config();
        cfg.base_url = Some("http://192.168.1.100:11434".into());
        let provider = OllamaProvider::new(cfg);
        assert_eq!(provider.base_url(), "http://192.168.1.100:11434");
    }

    // ── Headers ──────────────────────────────────────────────────────────

    #[test]
    fn headers_has_content_type_only() {
        let headers = OllamaProvider::build_headers();
        assert_eq!(headers[CONTENT_TYPE], "application/json");
        assert!(headers.get("authorization").is_none());
    }

    // ── System prompt ────────────────────────────────────────────────────

    #[test]
    fn system_prompt_simple_string() {
        let ctx = context_with_system("You are helpful.");
        let prompt = OllamaProvider::build_system_prompt(&ctx).unwrap();
        assert_eq!(prompt, "You are helpful.");
    }

    #[test]
    fn system_prompt_empty_context_returns_none() {
        let ctx = Context::default();
        assert!(OllamaProvider::build_system_prompt(&ctx).is_none());
    }

    // ── Max tokens ───────────────────────────────────────────────────────

    #[test]
    fn max_tokens_from_options() {
        let provider = OllamaProvider::new(test_config());
        let options = ProviderStreamOptions {
            max_tokens: Some(4096),
            ..Default::default()
        };
        assert_eq!(provider.calculate_max_tokens(&options), 4096);
    }

    #[test]
    fn max_tokens_from_config() {
        let mut cfg = test_config();
        cfg.max_tokens = Some(2048);
        let provider = OllamaProvider::new(cfg);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 2048);
    }

    #[test]
    fn max_tokens_from_model_registry() {
        let provider = OllamaProvider::new(test_config());
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 8_192);
    }

    #[test]
    fn max_tokens_unknown_model_uses_default() {
        let mut cfg = test_config();
        cfg.model = "unknown-model".into();
        let provider = OllamaProvider::new(cfg);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), DEFAULT_MAX_OUTPUT_TOKENS);
    }

    // ── Model capabilities ───────────────────────────────────────────────

    #[test]
    fn e4b_supports_images_and_tools() {
        let provider = OllamaProvider::new(test_config());
        assert!(provider.model_supports_images());
        assert!(provider.model_supports_tools());
    }

    #[test]
    fn unknown_model_no_capabilities() {
        let mut cfg = test_config();
        cfg.model = "unknown".into();
        let provider = OllamaProvider::new(cfg);
        assert!(!provider.model_supports_images());
        assert!(!provider.model_supports_tools());
    }

    // ── Request body ─────────────────────────────────────────────────────

    #[test]
    fn request_body_basic() {
        let provider = OllamaProvider::new(test_config());
        let ctx = context_with_system("You are helpful.");
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);

        assert_eq!(body["model"], "gemma4:e4b");
        assert_eq!(body["stream"], true);
        assert_eq!(body["max_tokens"], 8_192);
        let msgs = body["messages"].as_array().unwrap();
        assert_eq!(msgs[0]["role"], "system");
        assert_eq!(msgs[0]["content"], "You are helpful.");
    }

    #[test]
    fn request_body_no_stream_options() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert!(body.get("stream_options").is_none());
    }

    #[test]
    fn request_body_uses_max_tokens_not_max_completion_tokens() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert!(body.get("max_tokens").is_some());
        assert!(body.get("max_completion_tokens").is_none());
    }

    #[test]
    fn request_body_with_tools() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context {
            tools: Some(vec![crate::core::tools::Tool {
                name: "bash".into(),
                description: "Run commands".into(),
                parameters: crate::core::tools::ToolParameterSchema {
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
    }

    #[test]
    fn request_body_no_tools_when_empty() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context {
            tools: Some(vec![]),
            ..Context::default()
        };
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert!(body.get("tools").is_none());
    }

    #[test]
    fn request_body_no_system_message_when_empty() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        let msgs = body["messages"].as_array().unwrap();
        assert!(msgs.is_empty() || msgs[0]["role"] != "system");
    }

    // ── URL construction ─────────────────────────────────────────────────

    #[test]
    fn request_url_default() {
        let provider = OllamaProvider::new(test_config());
        let url = format!("{}/v1/chat/completions", provider.base_url());
        assert_eq!(url, "http://localhost:11434/v1/chat/completions");
    }

    #[test]
    fn request_url_custom_base() {
        let mut cfg = test_config();
        cfg.base_url = Some("http://myserver:8080".into());
        let provider = OllamaProvider::new(cfg);
        let url = format!("{}/v1/chat/completions", provider.base_url());
        assert_eq!(url, "http://myserver:8080/v1/chat/completions");
    }
}
