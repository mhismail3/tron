//! Anthropic provider implementing the [`Provider`] trait.
//!
//! Builds and sends streaming requests to the Anthropic Messages API.
//! Supports API key and OAuth authentication, prompt caching with TTL breakpoints,
//! extended thinking (adaptive for Opus 4.6, budget-based for older models),
//! and effort levels.

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};
use tracing::{debug, error, info, instrument};

use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::messages::Context;

use super::cache_pruning::{
    DEFAULT_RECENT_TURNS, DEFAULT_TTL_MS, is_cache_cold, prune_tool_results_for_recache,
};
use super::message_converter::convert_messages;
use super::message_sanitizer::sanitize_messages;
use super::stream_handler::{create_stream_state, process_sse_event};
use super::types::{
    AnthropicAuth, AnthropicConfig, AnthropicMessageParam, AnthropicRequest, AnthropicSseEvent,
    AnthropicTool, CacheControl, DEFAULT_MAX_OUTPUT_TOKENS, OAUTH_SYSTEM_PROMPT_PREFIX,
    get_claude_model,
};

/// Default base URL for the Anthropic API.
const DEFAULT_BASE_URL: &str = "https://api.anthropic.com";

/// Default SSE parser options.
static SSE_OPTIONS: crate::domains::model::providers::SseParserOptions =
    crate::domains::model::providers::SseParserOptions {
        process_remaining_buffer: true,
    };

/// API version header value.
const API_VERSION: &str = "2023-06-01";

/// Anthropic LLM provider.
pub struct AnthropicProvider {
    /// Configuration.
    config: AnthropicConfig,
    /// HTTP client.
    client: reqwest::Client,
    /// Timestamp of last API call (milliseconds since epoch).
    last_api_call_ms: u64,
}

impl AnthropicProvider {
    /// Create a new Anthropic provider.
    #[must_use]
    pub fn new(config: AnthropicConfig) -> Self {
        Self {
            config,
            client: reqwest::Client::new(),
            last_api_call_ms: 0,
        }
    }

    /// Create a new Anthropic provider with a shared HTTP client.
    #[must_use]
    pub fn with_client(config: AnthropicConfig, client: reqwest::Client) -> Self {
        Self {
            config,
            client,
            last_api_call_ms: 0,
        }
    }

    /// Whether this provider uses OAuth authentication.
    fn is_oauth(&self) -> bool {
        matches!(self.config.auth, AnthropicAuth::OAuth { .. })
    }

    /// Build HTTP headers for the request.
    ///
    /// OAuth requests require:
    /// - `anthropic-beta: oauth-2025-04-20,...` (always includes the OAuth beta)
    /// - `anthropic-dangerous-direct-browser-access: true`
    ///
    /// API key requests only add `anthropic-beta` for models needing thinking beta.
    fn build_headers(&self) -> ProviderResult<HeaderMap> {
        let mut headers = HeaderMap::new();
        let _ = headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        let _ = headers.insert("anthropic-version", HeaderValue::from_static(API_VERSION));

        match &self.config.auth {
            AnthropicAuth::ApiKey { api_key } => {
                let _ = headers.insert(
                    "x-api-key",
                    HeaderValue::from_str(api_key).map_err(|e| ProviderError::Auth {
                        message: format!("Invalid API key header: {e}"),
                    })?,
                );
                // API key: only add thinking beta for models that need it
                if let Some(model_info) = get_claude_model(&self.config.model)
                    && model_info.supports_thinking_beta_headers
                {
                    let _ = headers.insert(
                        "anthropic-beta",
                        HeaderValue::from_static("interleaved-thinking-2025-05-14"),
                    );
                }
            }
            AnthropicAuth::OAuth { tokens, .. } => {
                let auth_value = format!("Bearer {}", tokens.access_token);
                let _ = headers.insert(
                    AUTHORIZATION,
                    HeaderValue::from_str(&auth_value).map_err(|e| ProviderError::Auth {
                        message: format!("Invalid OAuth header: {e}"),
                    })?,
                );
                // OAuth: always add browser access header
                let _ = headers.insert(
                    "anthropic-dangerous-direct-browser-access",
                    HeaderValue::from_static("true"),
                );
                // OAuth: beta headers — full set for models needing thinking beta,
                // just `oauth-2025-04-20` for models that don't (e.g., Opus 4.6)
                let model_info = get_claude_model(&self.config.model);
                let needs_thinking_beta =
                    model_info.is_none_or(|m| m.supports_thinking_beta_headers);
                let beta_value = if needs_thinking_beta {
                    &self.config.provider_settings.oauth_beta_headers
                } else {
                    "oauth-2025-04-20"
                };
                let _ = headers.insert(
                    "anthropic-beta",
                    HeaderValue::from_str(beta_value).map_err(|e| ProviderError::Auth {
                        message: format!("Invalid beta header: {e}"),
                    })?,
                );
            }
        }

        Ok(headers)
    }

    /// Build the system prompt parameter.
    ///
    /// Returns an array of `SystemPromptBlock`s with cache breakpoints for all auth types.
    /// OAuth auth gets a prefix block; API key auth does not.
    fn build_system_param(&self, context: &Context) -> Option<Value> {
        let prefix = if self.is_oauth() {
            Some(
                self.config
                    .provider_settings
                    .system_prompt_prefix
                    .as_deref()
                    .unwrap_or(OAUTH_SYSTEM_PROMPT_PREFIX),
            )
        } else {
            None
        };
        super::message_converter::build_system_prompt_for_provider(context, prefix)
    }

    /// Build tool definitions with cache breakpoints.
    #[allow(clippy::unused_self)]
    fn build_tools(&self, context: &Context) -> Option<Vec<AnthropicTool>> {
        let capabilities = context.capabilities.as_ref()?;
        if capabilities.is_empty() {
            return None;
        }

        let mut anthropic_capabilities: Vec<AnthropicTool> = capabilities
            .iter()
            .map(|t| AnthropicTool {
                name: t.name.clone(),
                description: t.description.clone(),
                input_schema: serde_json::to_value(&t.parameters).unwrap_or_default(),
                cache_control: None,
            })
            .collect();

        // Breakpoint 1: Last tool → 1h TTL
        if let Some(last) = anthropic_capabilities.last_mut() {
            last.cache_control = Some(CacheControl {
                cache_type: "ephemeral".into(),
                ttl: Some("1h".into()),
            });
        }

        Some(anthropic_capabilities)
    }

    /// Build thinking configuration.
    fn build_thinking_config(&self, options: &ProviderStreamOptions) -> Option<Value> {
        if options.enable_thinking != Some(true) {
            return None;
        }

        let model_info = get_claude_model(&self.config.model);

        // Model must support thinking (e.g., claude-3-haiku does not).
        if !model_info.is_some_and(|m| m.supports_thinking) {
            return None;
        }

        if model_info.is_some_and(|m| m.supports_adaptive_thinking) {
            let mut obj = json!({ "type": "adaptive" });
            // Opus 4.7+ omits thinking content by default; we opt in to "summarized"
            // so thinking blocks remain visible in chat (matches Opus 4.6 default).
            if let Some(display) = model_info.and_then(|m| m.thinking_display)
                && let Some(map) = obj.as_object_mut()
            {
                let _ = map.insert("display".into(), json!(display));
            }
            Some(obj)
        } else {
            let budget = options.thinking_budget.unwrap_or_else(|| {
                model_info.map_or(DEFAULT_MAX_OUTPUT_TOKENS / 4, |m| m.max_output / 4)
            });
            Some(json!({
                "type": "enabled",
                "budget_tokens": budget,
            }))
        }
    }

    /// Build output configuration (effort levels).
    fn build_output_config(&self, options: &ProviderStreamOptions) -> Option<Value> {
        let effort = options.effort_level.as_ref()?;
        let model_info = get_claude_model(&self.config.model)?;
        if !model_info.supports_effort {
            return None;
        }
        Some(json!({ "effort": effort.as_str() }))
    }

    /// Calculate `max_tokens` for the request.
    fn calculate_max_tokens(&self, options: &ProviderStreamOptions) -> u32 {
        options.max_tokens.unwrap_or_else(|| {
            self.config.max_tokens.unwrap_or_else(|| {
                get_claude_model(&self.config.model)
                    .map_or(DEFAULT_MAX_OUTPUT_TOKENS, |m| m.max_output)
            })
        })
    }

    /// Apply cache control to the last user message (Breakpoint 4: 5m TTL).
    fn apply_cache_to_last_user_message(messages: &mut [AnthropicMessageParam]) {
        for msg in messages.iter_mut().rev() {
            if msg.role == "user" && !msg.content.is_empty() {
                if let Some(last_block) = msg.content.last_mut()
                    && let Some(obj) = last_block.as_object_mut()
                {
                    let _ = obj.insert("cache_control".into(), json!({"type": "ephemeral"}));
                }
                break;
            }
        }
    }

    /// Build the request body.
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
            system: self.build_system_param(context),
            capabilities: self.build_tools(context),
            stream: true,
            thinking: self.build_thinking_config(options),
            output_config: self.build_output_config(options),
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
        let sanitized = sanitize_messages(context.messages.to_vec());
        let mut messages = convert_messages(&sanitized);

        // Cache cold detection and pruning
        if self.last_api_call_ms > 0 {
            if is_cache_cold(self.last_api_call_ms, DEFAULT_TTL_MS) {
                let msg_count = messages.len();
                messages = prune_tool_results_for_recache(&messages, DEFAULT_RECENT_TURNS);
                info!(
                    elapsed_ms = %now_ms().saturating_sub(self.last_api_call_ms),
                    message_count = msg_count,
                    "[CACHE] Cold — pruned old Anthropic tool results"
                );
            } else {
                debug!(
                    elapsed_ms = %now_ms().saturating_sub(self.last_api_call_ms),
                    "[CACHE] Warm"
                );
            }
        }

        // Breakpoint 4: cache last user message
        Self::apply_cache_to_last_user_message(&mut messages);

        let request = self.build_request(context, options, messages);

        let base_url = self.config.base_url.as_deref().unwrap_or(DEFAULT_BASE_URL);
        let url = format!("{base_url}/v1/messages");

        let headers = self.build_headers()?;
        let body = serde_json::to_value(&request).map_err(ProviderError::Json)?;

        debug!(
            model = %request.model,
            max_tokens = request.max_tokens,
            message_count = request.messages.len(),
            has_tools = request.capabilities.is_some(),
            has_thinking = request.thinking.is_some(),
            "Sending Anthropic request"
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
                "Anthropic API error"
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
                AnthropicSseEvent,
                _,
                _,
            >(
                response,
                &SSE_OPTIONS,
                create_stream_state(),
                process_sse_event,
            ),
        )
    }
}

/// Current time in milliseconds since epoch (as `u64` for elapsed-time logging).
#[allow(clippy::cast_sign_loss)]
fn now_ms() -> u64 {
    crate::domains::auth::provider_credentials::now_ms() as u64
}

#[async_trait]
impl Provider for AnthropicProvider {
    fn provider_type(&self) -> crate::shared::messages::Provider {
        crate::shared::messages::Provider::Anthropic
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    fn audit_payload(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<serde_json::Value> {
        let sanitized = sanitize_messages(context.messages.to_vec());
        let mut messages = convert_messages(&sanitized);
        if self.last_api_call_ms > 0 && is_cache_cold(self.last_api_call_ms, DEFAULT_TTL_MS) {
            messages = prune_tool_results_for_recache(&messages, DEFAULT_RECENT_TURNS);
        }
        Self::apply_cache_to_last_user_message(&mut messages);
        serde_json::to_value(self.build_request(context, options, messages))
            .map_err(ProviderError::Json)
    }

    #[instrument(skip_all, fields(provider = "anthropic", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        crate::domains::model::providers::stream_pipeline::wrap_provider_stream(
            "anthropic",
            self.stream_internal(context, options).await,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[path = "provider/tests.rs"]
mod tests;
