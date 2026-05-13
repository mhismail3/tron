//! Ollama provider implementing the [`Provider`] trait.
//!
//! Uses Ollama's `OpenAI` chat completions-compatible endpoint for streaming, with
//! a pre-flight request via the native `/api/chat` endpoint to set the context window.
//!
//! # Context Window (`num_ctx`)
//!
//! Ollama's `/v1/chat/completions` endpoint **ignores** the `num_ctx` parameter —
//! it only works via the native `/api/chat` endpoint's `options.num_ctx` field.
//! Without this, Ollama defaults to a 4K context window, silently truncating
//! Tron's ~12K system prompt + capabilities, which destroys reasoning/thinking output.
//!
//! We solve this by sending a lightweight non-streaming request to `/api/chat`
//! with the desired `num_ctx` before the first streaming request. This forces
//! Ollama to (re)load the model with the correct KV cache size. Subsequent
//! requests via the OpenAI endpoint inherit this context size until Ollama
//! unloads the model.
//!
//! No authentication required — Ollama runs locally. Provides graceful error
//! messages when Ollama is not running or the model is not pulled.

use async_trait::async_trait;
use reqwest::header::{CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};
use tracing::{debug, error, info, instrument};

use crate::domains::model::providers::compose_context_parts;
use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::messages::Context;

use super::message_converter::{convert_messages, convert_tools};
use super::stream_handler::{OllamaChatChunk, OllamaStreamState, process_chunk};
use super::types::{
    DEFAULT_BASE_URL, DEFAULT_MAX_OUTPUT_TOKENS, DEFAULT_NUM_CTX, OllamaConfig, get_ollama_model,
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

    /// Get the target `num_ctx` for this model.
    fn target_num_ctx(&self) -> u32 {
        get_ollama_model(&self.config.model).map_or(DEFAULT_NUM_CTX, |m| {
            // Use the model's full context window, capped at 64K.
            // 64K ≈ 1.9 GB KV cache on E4B — comfortable on 24GB machines.
            (m.context_window as u32).min(65_536)
        })
    }

    /// Calculate `max_tokens`: options → config → model registry default.
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

    /// Check if the current model supports capabilities.
    fn model_supports_capabilities(&self) -> bool {
        get_ollama_model(&self.config.model).is_some_and(|m| m.supports_capabilities)
    }

    /// Build the request body for the chat completions API.
    /// Build the request body for Ollama's native `/api/chat` endpoint.
    ///
    /// Uses the native format (NOT OpenAI-compatible) because `/v1/chat/completions`
    /// ignores `num_ctx` and reloads the model at 4K context on every request.
    fn build_request_body(&self, context: &Context, options: &ProviderStreamOptions) -> Value {
        let supports_images = self.model_supports_images();
        let messages = convert_messages(&context.messages, supports_images);

        let num_ctx = self.target_num_ctx();

        let mut body = json!({
            "model": self.config.model,
            "stream": true,
            "options": {
                "num_ctx": num_ctx,
                "num_predict": self.calculate_max_tokens(options),
            },
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
        if self.model_supports_capabilities()
            && let Some(ref capabilities) = context.capabilities
            && !capabilities.is_empty()
        {
            let tool_defs = convert_tools(capabilities);
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
            let err_info =
                crate::domains::model::providers::error_parsing::parse_api_error(body_text, status);
            ProviderError::Api {
                status,
                message: format!("Ollama server error: {}", err_info.message),
                code: err_info.code,
                retryable: err_info.retryable,
            }
        }
    }

    /// Perform the streaming HTTP request and return the event stream.
    /// Perform the streaming HTTP request via Ollama's native `/api/chat` endpoint.
    ///
    /// Uses the native API (not OpenAI-compatible) because only the native
    /// endpoint respects `options.num_ctx` for context window configuration.
    /// The response is NDJSON (one JSON object per line), not SSE.
    #[instrument(skip_all, fields(model = %self.config.model))]
    async fn stream_internal(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        let body = self.build_request_body(context, options);
        let url = format!("{}/api/chat", self.base_url());
        let headers = Self::build_headers();

        let msg_count = body["messages"].as_array().map_or(0, std::vec::Vec::len);
        let tool_count = body
            .get("tools")
            .and_then(|t| t.as_array())
            .map_or(0, |a| a.len());
        let num_ctx = body["options"]["num_ctx"].as_u64().unwrap_or(0);
        info!(
            model = %self.config.model,
            num_ctx,
            num_predict = %body["options"]["num_predict"],
            message_count = msg_count,
            tool_count = tool_count,
            "Sending Ollama native API request"
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

        // Parse NDJSON stream (one JSON object per line, no SSE framing)
        Ok(ndjson_to_event_stream(response))
    }
}

#[async_trait]
impl Provider for OllamaProvider {
    fn provider_type(&self) -> crate::shared::messages::Provider {
        crate::shared::messages::Provider::Ollama
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

    #[instrument(skip_all, fields(provider = "ollama", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        crate::domains::model::providers::stream_pipeline::wrap_provider_stream(
            "ollama",
            self.stream_internal(context, options).await,
        )
    }
}

// ─── NDJSON stream parser ─────────────────────────────────────────────────────

/// Convert an NDJSON byte stream into a typed [`StreamEventStream`].
///
/// Ollama's native `/api/chat` streams one JSON object per line (NDJSON),
/// NOT Server-Sent Events. This parser buffers bytes, splits on newlines,
/// deserializes each line as an [`OllamaChatChunk`], and processes it through
/// the stream handler.
fn ndjson_to_event_stream(response: reqwest::Response) -> StreamEventStream {
    use bytes::BytesMut;
    use futures::stream::{self, StreamExt};

    let byte_stream = response.bytes_stream();

    let event_stream = futures::stream::unfold(
        (
            Box::pin(byte_stream)
                as std::pin::Pin<
                    Box<dyn futures::Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send>,
                >,
            OllamaStreamState::new(),
            BytesMut::with_capacity(8192),
        ),
        |(mut stream, mut state, mut buffer)| async move {
            loop {
                // Check buffer for a complete line
                if let Some(newline_pos) = buffer.iter().position(|&b| b == b'\n') {
                    let line_bytes = buffer.split_to(newline_pos + 1);
                    let line = match std::str::from_utf8(&line_bytes) {
                        Ok(s) => s.trim(),
                        Err(_) => continue,
                    };
                    if line.is_empty() {
                        continue;
                    }

                    let chunk: OllamaChatChunk = match serde_json::from_str(line) {
                        Ok(c) => c,
                        Err(e) => {
                            tracing::warn!(
                                error = %e,
                                line_preview = &line[..line.len().min(100)],
                                "Ollama: failed to parse NDJSON line"
                            );
                            continue;
                        }
                    };

                    let events = process_chunk(&chunk, &mut state);
                    if !events.is_empty() {
                        return Some((events, (stream, state, buffer)));
                    }
                    continue;
                }

                // Read next bytes from the HTTP response stream
                match StreamExt::next(&mut stream).await {
                    Some(Ok(bytes)) => {
                        buffer.extend_from_slice(&bytes);
                    }
                    Some(Err(e)) => {
                        tracing::warn!("Ollama NDJSON stream read error: {e}");
                        return None;
                    }
                    None => {
                        // Stream ended — process remaining buffer
                        if !buffer.is_empty() {
                            let line = match std::str::from_utf8(&buffer) {
                                Ok(s) => s.trim(),
                                Err(_) => return None,
                            };
                            if !line.is_empty() {
                                if let Ok(chunk) = serde_json::from_str::<OllamaChatChunk>(line) {
                                    let events = process_chunk(&chunk, &mut state);
                                    if !events.is_empty() {
                                        buffer.clear();
                                        return Some((events, (stream, state, buffer)));
                                    }
                                }
                            }
                        }
                        return None;
                    }
                }
            }
        },
    )
    .flat_map(stream::iter)
    .map(Ok);

    Box::pin(event_stream)
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
            crate::shared::messages::Provider::Ollama
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
        assert_eq!(
            provider.calculate_max_tokens(&options),
            DEFAULT_MAX_OUTPUT_TOKENS
        );
    }

    // ── Model capabilities ───────────────────────────────────────────────

    #[test]
    fn e4b_supports_images_and_tools() {
        let provider = OllamaProvider::new(test_config());
        assert!(provider.model_supports_images());
        assert!(provider.model_supports_capabilities());
    }

    #[test]
    fn unknown_model_no_capabilities() {
        let mut cfg = test_config();
        cfg.model = "unknown".into();
        let provider = OllamaProvider::new(cfg);
        assert!(!provider.model_supports_images());
        assert!(!provider.model_supports_capabilities());
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
        assert_eq!(body["options"]["num_predict"], 8_192);
        assert_eq!(body["options"]["num_ctx"], 65_536);
        let msgs = body["messages"].as_array().unwrap();
        assert_eq!(msgs[0]["role"], "system");
        assert_eq!(msgs[0]["content"], "You are helpful.");
    }

    #[test]
    fn request_body_includes_num_ctx_in_options() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        // num_ctx is inside the "options" object for the native API
        assert_eq!(body["options"]["num_ctx"], 65_536);
    }

    #[test]
    fn request_body_includes_num_predict_in_options() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert_eq!(body["options"]["num_predict"], 8_192);
    }

    // ── Context window (target_num_ctx) ───────────────────────────────

    #[test]
    fn target_num_ctx_known_model() {
        let provider = OllamaProvider::new(test_config());
        // E4B has 65K context window
        assert_eq!(provider.target_num_ctx(), 65_536);
    }

    #[test]
    fn target_num_ctx_unknown_model_uses_default() {
        let mut cfg = test_config();
        cfg.model = "unknown-model".into();
        let provider = OllamaProvider::new(cfg);
        assert_eq!(provider.target_num_ctx(), DEFAULT_NUM_CTX);
    }

    #[test]
    fn request_body_uses_native_format() {
        // Native API uses "options.num_predict" not "max_tokens"
        let provider = OllamaProvider::new(test_config());
        let ctx = Context::default();
        let options = ProviderStreamOptions::default();
        let body = provider.build_request_body(&ctx, &options);
        assert!(body.get("max_tokens").is_none());
        assert!(body.get("max_completion_tokens").is_none());
        assert!(body["options"]["num_predict"].is_number());
    }

    #[test]
    fn request_body_with_tools() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context {
            capabilities: Some(vec![crate::shared::model_capabilities::ModelCapability {
                name: "execute".into(),
                description: "Run commands".into(),
                parameters: crate::shared::model_capabilities::CapabilityParameterSchema {
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
        let capabilities = body["tools"].as_array().unwrap();
        assert_eq!(capabilities.len(), 1);
        assert_eq!(capabilities[0]["type"], "function");
    }

    #[test]
    fn request_body_no_tools_when_empty() {
        let provider = OllamaProvider::new(test_config());
        let ctx = Context {
            capabilities: Some(vec![]),
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
        let url = format!("{}/api/chat", provider.base_url());
        assert_eq!(url, "http://localhost:11434/api/chat");
    }

    #[test]
    fn request_url_custom_base() {
        let mut cfg = test_config();
        cfg.base_url = Some("http://myserver:8080".into());
        let provider = OllamaProvider::new(cfg);
        let url = format!("{}/api/chat", provider.base_url());
        assert_eq!(url, "http://myserver:8080/api/chat");
    }
}
