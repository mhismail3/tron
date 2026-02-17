//! Anthropic provider implementing the [`Provider`] trait.
//!
//! Builds and sends streaming requests to the Anthropic Messages API.
//! Supports API key and OAuth authentication, prompt caching with TTL breakpoints,
//! extended thinking (adaptive for Opus 4.6, budget-based for older models),
//! and effort levels.

use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use futures::stream::{self, StreamExt};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use serde_json::{json, Value};
use tracing::{debug, error, info, instrument, warn};

use tron_core::events::StreamEvent;
use tron_core::messages::Context;
use crate::models::types::ProviderType;
use crate::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::{compose_context_parts, compose_context_parts_grouped};
use crate::sse::parse_sse_lines;

use super::cache_pruning::{
    is_cache_cold, prune_tool_results_for_recache, DEFAULT_RECENT_TURNS, DEFAULT_TTL_MS,
};
use super::message_converter::convert_messages;
use super::message_sanitizer::sanitize_messages;
use super::stream_handler::{create_stream_state, process_sse_event};
use super::types::{
    get_claude_model, AnthropicAuth, AnthropicConfig, AnthropicMessageParam,
    AnthropicRequest, AnthropicSseEvent, AnthropicTool, CacheControl,
    SystemPromptBlock, DEFAULT_MAX_OUTPUT_TOKENS, OAUTH_SYSTEM_PROMPT_PREFIX,
};

/// Default base URL for the Anthropic API.
const DEFAULT_BASE_URL: &str = "https://api.anthropic.com";

/// Default SSE parser options.
static SSE_OPTIONS: crate::SseParserOptions = crate::SseParserOptions {
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
        let _ = headers.insert(
            "anthropic-version",
            HeaderValue::from_static(API_VERSION),
        );

        match &self.config.auth {
            AnthropicAuth::ApiKey { api_key } => {
                let _ = headers.insert(
                    "x-api-key",
                    HeaderValue::from_str(api_key).map_err(|e| ProviderError::Auth {
                        message: format!("Invalid API key header: {e}"),
                    })?,
                );
                // API key: only add thinking beta for models that need it
                if let Some(model_info) = get_claude_model(&self.config.model) {
                    if model_info.supports_thinking_beta_headers {
                        let _ = headers.insert(
                            "anthropic-beta",
                            HeaderValue::from_static("interleaved-thinking-2025-05-14"),
                        );
                    }
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
    /// For API key auth: returns a single string.
    /// For OAuth auth: returns an array of `SystemPromptBlock`s with cache breakpoints.
    fn build_system_param(&self, context: &Context) -> Option<Value> {
        if self.is_oauth() {
            self.build_oauth_system_param(context)
        } else {
            Self::build_simple_system_param(context)
        }
    }

    /// Build a simple string system prompt (API key mode).
    fn build_simple_system_param(context: &Context) -> Option<Value> {
        let parts = compose_context_parts(context);
        if parts.is_empty() {
            return None;
        }
        Some(json!(parts.join("\n\n")))
    }

    /// Build multi-block system prompt with cache breakpoints (OAuth mode).
    fn build_oauth_system_param(&self, context: &Context) -> Option<Value> {
        let grouped = compose_context_parts_grouped(context);

        let prefix = self
            .config
            .provider_settings
            .system_prompt_prefix
            .as_deref()
            .unwrap_or(OAUTH_SYSTEM_PROMPT_PREFIX);

        let mut blocks: Vec<SystemPromptBlock> = Vec::new();

        // OAuth prefix block
        blocks.push(SystemPromptBlock::text(prefix));

        // Stable blocks (system prompt, rules, memory)
        for part in &grouped.stable {
            blocks.push(SystemPromptBlock::text(part));
        }

        // Volatile blocks (dynamic rules, skills, subagent results, tasks)
        for part in &grouped.volatile {
            blocks.push(SystemPromptBlock::text(part));
        }

        if blocks.is_empty() {
            return None;
        }

        // Apply cache breakpoints
        if !grouped.volatile.is_empty() {
            // Breakpoint 2: Last stable block → 1h TTL
            let last_stable_idx = 1 + grouped.stable.len(); // +1 for prefix
            if last_stable_idx > 0 && last_stable_idx <= blocks.len() {
                blocks[last_stable_idx - 1].cache_control = Some(CacheControl {
                    cache_type: "ephemeral".into(),
                    ttl: Some("1h".into()),
                });
            }
            // Breakpoint 3: Last volatile block → 5m default
            if let Some(last) = blocks.last_mut() {
                last.cache_control = Some(CacheControl {
                    cache_type: "ephemeral".into(),
                    ttl: None,
                });
            }
        } else if !grouped.stable.is_empty() {
            // Only stable: last stable block → 1h TTL
            if let Some(last) = blocks.last_mut() {
                last.cache_control = Some(CacheControl {
                    cache_type: "ephemeral".into(),
                    ttl: Some("1h".into()),
                });
            }
        } else {
            // Only prefix → 5m default
            if let Some(last) = blocks.last_mut() {
                last.cache_control = Some(CacheControl {
                    cache_type: "ephemeral".into(),
                    ttl: None,
                });
            }
        }

        Some(serde_json::to_value(&blocks).unwrap_or_default())
    }

    /// Build tool definitions with cache breakpoints.
    fn build_tools(&self, context: &Context) -> Option<Vec<AnthropicTool>> {
        let tools = context.tools.as_ref()?;
        if tools.is_empty() {
            return None;
        }

        let mut anthropic_tools: Vec<AnthropicTool> = tools
            .iter()
            .map(|t| AnthropicTool {
                name: t.name.clone(),
                description: t.description.clone(),
                input_schema: serde_json::to_value(&t.parameters).unwrap_or_default(),
                cache_control: None,
            })
            .collect();

        // Breakpoint 1: Last tool → 1h TTL (OAuth only)
        if self.is_oauth() {
            if let Some(last) = anthropic_tools.last_mut() {
                last.cache_control = Some(CacheControl {
                    cache_type: "ephemeral".into(),
                    ttl: Some("1h".into()),
                });
            }
        }

        Some(anthropic_tools)
    }

    /// Build thinking configuration.
    fn build_thinking_config(&self, options: &ProviderStreamOptions) -> Option<Value> {
        if options.enable_thinking != Some(true) {
            return None;
        }

        let model_info = get_claude_model(&self.config.model);

        if model_info.is_some_and(|m| m.supports_adaptive_thinking) {
            Some(json!({ "type": "adaptive" }))
        } else {
            let budget = options.thinking_budget.unwrap_or_else(|| {
                model_info
                    .map_or(DEFAULT_MAX_OUTPUT_TOKENS / 4, |m| m.max_output / 4)
            });
            Some(json!({
                "type": "enabled",
                "budget_tokens": budget,
            }))
        }
    }

    /// Build output configuration (effort levels).
    fn build_output_config(&self, options: &ProviderStreamOptions) -> Option<Value> {
        let effort = options.effort_level.as_deref()?;
        let model_info = get_claude_model(&self.config.model)?;
        if !model_info.supports_effort {
            return None;
        }
        Some(json!({ "effort": effort }))
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
                if let Some(last_block) = msg.content.last_mut() {
                    if let Some(obj) = last_block.as_object_mut() {
                        let _ = obj.insert(
                            "cache_control".into(),
                            json!({"type": "ephemeral"}),
                        );
                    }
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
            tools: self.build_tools(context),
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
        let sanitized = sanitize_messages(context.messages.clone());
        let mut messages = convert_messages(&sanitized);

        // Cache cold detection and pruning (OAuth only)
        if self.is_oauth() && self.last_api_call_ms > 0 {
            if is_cache_cold(self.last_api_call_ms, DEFAULT_TTL_MS) {
                let msg_count = messages.len();
                messages = prune_tool_results_for_recache(&messages, DEFAULT_RECENT_TURNS);
                info!(
                    elapsed_ms = %now_ms().saturating_sub(self.last_api_call_ms),
                    message_count = msg_count,
                    "[CACHE] Cold — pruned old tool results"
                );
            } else {
                debug!(
                    elapsed_ms = %now_ms().saturating_sub(self.last_api_call_ms),
                    "[CACHE] Warm"
                );
            }
        }

        // Breakpoint 4: cache last user message (OAuth only)
        if self.is_oauth() {
            Self::apply_cache_to_last_user_message(&mut messages);
        }

        let request = self.build_request(context, options, messages);

        let base_url = self
            .config
            .base_url
            .as_deref()
            .unwrap_or(DEFAULT_BASE_URL);
        let url = format!("{base_url}/v1/messages");

        let headers = self.build_headers()?;
        let body = serde_json::to_value(&request).map_err(ProviderError::Json)?;

        debug!(
            model = %request.model,
            max_tokens = request.max_tokens,
            message_count = request.messages.len(),
            has_tools = request.tools.is_some(),
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
                .and_then(tron_core::retry::parse_retry_after_header);
            let body_text = response.text().await.unwrap_or_default();
            let (message, code, retryable) = parse_api_error(&body_text, status.as_u16());
            error!(
                status = status.as_u16(),
                code = code.as_deref().unwrap_or("unknown"),
                retryable,
                "Anthropic API error"
            );
            if status.as_u16() == 429 {
                return Err(ProviderError::RateLimited {
                    retry_after_ms: retry_after.unwrap_or(0),
                    message,
                });
            }
            return Err(ProviderError::Api {
                status: status.as_u16(),
                message,
                code,
                retryable,
            });
        }

        // Parse SSE stream
        let byte_stream = response.bytes_stream();
        let sse_lines = parse_sse_lines(byte_stream, &SSE_OPTIONS);

        let event_stream = sse_lines
            .scan(create_stream_state(), |state, line| {
                // Parse the SSE data as JSON
                let event: AnthropicSseEvent = match serde_json::from_str(&line) {
                    Ok(e) => e,
                    Err(e) => {
                        warn!(line = %line, error = %e, "Failed to parse SSE event");
                        return std::future::ready(Some(vec![]));
                    }
                };

                let events = process_sse_event(&event, state);
                std::future::ready(Some(events))
            })
            .flat_map(stream::iter)
            .map(Ok);

        Ok(Box::pin(event_stream))
    }
}

/// Current time in milliseconds since epoch.
#[allow(clippy::cast_possible_truncation)] // u128→u64 truncation won't happen before year 584 million
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Parse an API error response body.
fn parse_api_error(body: &str, status: u16) -> (String, Option<String>, bool) {
    if let Ok(json) = serde_json::from_str::<Value>(body) {
        let error = &json["error"];
        let message = error["message"]
            .as_str()
            .unwrap_or("Unknown error")
            .to_string();
        let code = error["type"].as_str().map(String::from);
        let retryable = status == 429 || status >= 500;
        (message, code, retryable)
    } else {
        (
            format!("HTTP {status}: {body}"),
            None,
            status == 429 || status >= 500,
        )
    }
}

#[async_trait]
impl Provider for AnthropicProvider {
    fn provider_type(&self) -> ProviderType {
        ProviderType::Anthropic
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    #[instrument(skip_all, fields(provider = "anthropic", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        let start_event = stream::once(async { Ok(StreamEvent::Start) });
        let inner_stream = match self.stream_internal(context, options).await {
            Ok(s) => s,
            Err(e) => {
                error!(error = %e, "Anthropic stream failed");
                return Err(e);
            }
        };
        Ok(Box::pin(start_event.chain(inner_stream)))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anthropic::types::AnthropicProviderSettings;

    fn test_config(auth: AnthropicAuth) -> AnthropicConfig {
        AnthropicConfig {
            model: "claude-opus-4-6".into(),
            auth,
            max_tokens: None,
            base_url: None,
            retry: None,
            provider_settings: AnthropicProviderSettings::default(),
        }
    }

    fn api_key_config() -> AnthropicConfig {
        test_config(AnthropicAuth::ApiKey {
            api_key: "sk-test-key".into(),
        })
    }

    fn oauth_config() -> AnthropicConfig {
        test_config(AnthropicAuth::OAuth {
            tokens: crate::auth::OAuthTokens {
                access_token: "at-test".into(),
                refresh_token: "rt-test".into(),
                expires_at: 9999999999999,
            },
            account_label: None,
        })
    }

    fn empty_context() -> Context {
        Context {
            system_prompt: None,
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        }
    }

    fn context_with_system(prompt: &str) -> Context {
        Context {
            system_prompt: Some(prompt.into()),
            ..empty_context()
        }
    }

    // ── Provider metadata ───────────────────────────────────────────────

    #[test]
    fn provider_type_is_anthropic() {
        let provider = AnthropicProvider::new(api_key_config());
        assert_eq!(provider.provider_type(), ProviderType::Anthropic);
    }

    #[test]
    fn provider_model_returns_config_model() {
        let provider = AnthropicProvider::new(api_key_config());
        assert_eq!(provider.model(), "claude-opus-4-6");
    }

    // ── is_oauth ────────────────────────────────────────────────────────

    #[test]
    fn is_oauth_true_for_oauth_auth() {
        let provider = AnthropicProvider::new(oauth_config());
        assert!(provider.is_oauth());
    }

    #[test]
    fn is_oauth_false_for_api_key() {
        let provider = AnthropicProvider::new(api_key_config());
        assert!(!provider.is_oauth());
    }

    // ── Headers ─────────────────────────────────────────────────────────

    #[test]
    fn headers_api_key() {
        let provider = AnthropicProvider::new(api_key_config());
        let headers = provider.build_headers().unwrap();
        assert!(headers.get("x-api-key").is_some());
        assert_eq!(headers["x-api-key"], "sk-test-key");
        assert_eq!(headers["anthropic-version"], API_VERSION);
    }

    #[test]
    fn headers_api_key_no_oauth_beta() {
        // Opus 4.6 with API key: no beta headers at all
        let provider = AnthropicProvider::new(api_key_config());
        let headers = provider.build_headers().unwrap();
        assert!(headers.get("anthropic-beta").is_none());
        assert!(headers.get("anthropic-dangerous-direct-browser-access").is_none());
    }

    #[test]
    fn headers_api_key_thinking_model() {
        // Haiku 4.5 with API key: thinking beta only, no OAuth beta
        let mut cfg = api_key_config();
        cfg.model = "claude-haiku-4-5-20251001".into();
        let provider = AnthropicProvider::new(cfg);
        let headers = provider.build_headers().unwrap();
        assert_eq!(
            headers["anthropic-beta"],
            "interleaved-thinking-2025-05-14"
        );
        assert!(headers.get("anthropic-dangerous-direct-browser-access").is_none());
    }

    #[test]
    fn headers_oauth() {
        let provider = AnthropicProvider::new(oauth_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(headers[AUTHORIZATION], "Bearer at-test");
        assert!(headers.get("x-api-key").is_none());
    }

    #[test]
    fn headers_oauth_has_browser_access() {
        let provider = AnthropicProvider::new(oauth_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(
            headers["anthropic-dangerous-direct-browser-access"],
            "true"
        );
    }

    #[test]
    fn headers_oauth_opus_46_has_oauth_beta_only() {
        // Opus 4.6 doesn't need thinking beta → only `oauth-2025-04-20`
        let provider = AnthropicProvider::new(oauth_config());
        let headers = provider.build_headers().unwrap();
        assert_eq!(headers["anthropic-beta"], "oauth-2025-04-20");
    }

    #[test]
    fn headers_oauth_haiku_45_has_full_beta() {
        // Haiku 4.5 needs thinking beta → full beta string with oauth prefix
        let mut cfg = oauth_config();
        cfg.model = "claude-haiku-4-5-20251001".into();
        let provider = AnthropicProvider::new(cfg);
        let headers = provider.build_headers().unwrap();
        let beta = headers["anthropic-beta"].to_str().unwrap();
        assert!(beta.contains("oauth-2025-04-20"), "must contain oauth beta");
        assert!(
            beta.contains("interleaved-thinking-2025-05-14"),
            "must contain thinking beta"
        );
    }

    #[test]
    fn headers_oauth_sonnet_45_has_full_beta() {
        let mut cfg = oauth_config();
        cfg.model = "claude-sonnet-4-5-20250929".into();
        let provider = AnthropicProvider::new(cfg);
        let headers = provider.build_headers().unwrap();
        let beta = headers["anthropic-beta"].to_str().unwrap();
        assert!(beta.starts_with("oauth-2025-04-20"));
    }

    #[test]
    fn headers_oauth_unknown_model_gets_full_beta() {
        // Unknown model → treat as needing thinking beta (safe default)
        let mut cfg = oauth_config();
        cfg.model = "claude-future-model".into();
        let provider = AnthropicProvider::new(cfg);
        let headers = provider.build_headers().unwrap();
        let beta = headers["anthropic-beta"].to_str().unwrap();
        assert!(beta.contains("oauth-2025-04-20"));
        assert!(beta.contains("interleaved-thinking"));
    }

    #[test]
    fn headers_oauth_custom_beta_from_settings() {
        let mut cfg = oauth_config();
        cfg.model = "claude-haiku-4-5-20251001".into();
        cfg.provider_settings.oauth_beta_headers =
            "oauth-2025-04-20,custom-beta-2025-06-01".into();
        let provider = AnthropicProvider::new(cfg);
        let headers = provider.build_headers().unwrap();
        assert_eq!(
            headers["anthropic-beta"],
            "oauth-2025-04-20,custom-beta-2025-06-01"
        );
    }

    // ── System prompt ───────────────────────────────────────────────────

    #[test]
    fn system_param_simple_api_key() {
        let provider = AnthropicProvider::new(api_key_config());
        let ctx = context_with_system("You are helpful.");
        let param = provider.build_system_param(&ctx).unwrap();
        assert_eq!(param.as_str().unwrap(), "You are helpful.");
    }

    #[test]
    fn system_param_empty_context() {
        let provider = AnthropicProvider::new(api_key_config());
        let ctx = empty_context();
        assert!(provider.build_system_param(&ctx).is_none());
    }

    #[test]
    fn system_param_oauth_has_prefix() {
        let provider = AnthropicProvider::new(oauth_config());
        let ctx = context_with_system("You are helpful.");
        let param = provider.build_system_param(&ctx).unwrap();
        let blocks: Vec<Value> = serde_json::from_value(param).unwrap();
        assert!(blocks.len() >= 2);
        assert!(blocks[0]["text"]
            .as_str()
            .unwrap()
            .contains("Claude Code"));
    }

    #[test]
    fn system_param_oauth_cache_breakpoints_stable_and_volatile() {
        let mut config = oauth_config();
        config.provider_settings.system_prompt_prefix = Some("Prefix".into());
        let provider = AnthropicProvider::new(config);
        let ctx = Context {
            system_prompt: Some("System".into()),
            rules_content: Some("Rules".into()),
            skill_context: Some("Skills".into()),
            ..empty_context()
        };
        let param = provider.build_system_param(&ctx).unwrap();
        let blocks: Vec<Value> = serde_json::from_value(param).unwrap();

        // Prefix + system + rules (stable) + skills (volatile)
        assert_eq!(blocks.len(), 4);

        // Breakpoint 2: last stable block (index 2 = rules) → 1h
        assert_eq!(blocks[2]["cache_control"]["ttl"], "1h");

        // Breakpoint 3: last volatile block (index 3 = skills) → ephemeral (no ttl)
        assert_eq!(blocks[3]["cache_control"]["type"], "ephemeral");
        assert!(blocks[3]["cache_control"].get("ttl").is_none()
            || blocks[3]["cache_control"]["ttl"].is_null());
    }

    #[test]
    fn system_param_oauth_only_stable() {
        let provider = AnthropicProvider::new(oauth_config());
        let ctx = Context {
            system_prompt: Some("System".into()),
            ..empty_context()
        };
        let param = provider.build_system_param(&ctx).unwrap();
        let blocks: Vec<Value> = serde_json::from_value(param).unwrap();

        // Last block should have 1h TTL (only stable)
        let last = blocks.last().unwrap();
        assert_eq!(last["cache_control"]["ttl"], "1h");
    }

    // ── Tools ───────────────────────────────────────────────────────────

    #[test]
    fn build_tools_none() {
        let provider = AnthropicProvider::new(api_key_config());
        let ctx = empty_context();
        assert!(provider.build_tools(&ctx).is_none());
    }

    #[test]
    fn build_tools_api_key_no_cache() {
        let provider = AnthropicProvider::new(api_key_config());
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
            ..empty_context()
        };
        let tools = provider.build_tools(&ctx).unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0].name, "bash");
        assert!(tools[0].cache_control.is_none()); // No cache for API key
    }

    #[test]
    fn build_tools_oauth_last_has_cache() {
        let provider = AnthropicProvider::new(oauth_config());
        let ctx = Context {
            tools: Some(vec![
                tron_core::tools::Tool {
                    name: "bash".into(),
                    description: "Run".into(),
                    parameters: tron_core::tools::ToolParameterSchema {
                        schema_type: "object".into(),
                        properties: None,
                        required: None,
                        description: None,
                        extra: Default::default(),
                    },
                },
                tron_core::tools::Tool {
                    name: "read".into(),
                    description: "Read".into(),
                    parameters: tron_core::tools::ToolParameterSchema {
                        schema_type: "object".into(),
                        properties: None,
                        required: None,
                        description: None,
                        extra: Default::default(),
                    },
                },
            ]),
            ..empty_context()
        };
        let tools = provider.build_tools(&ctx).unwrap();
        assert!(tools[0].cache_control.is_none()); // First tool: no cache
        assert_eq!(tools[1].cache_control.as_ref().unwrap().ttl.as_deref(), Some("1h"));
    }

    // ── Thinking config ─────────────────────────────────────────────────

    #[test]
    fn thinking_config_disabled() {
        let provider = AnthropicProvider::new(api_key_config());
        let options = ProviderStreamOptions::default();
        assert!(provider.build_thinking_config(&options).is_none());
    }

    #[test]
    fn thinking_config_adaptive_opus_46() {
        let provider = AnthropicProvider::new(api_key_config());
        let options = ProviderStreamOptions {
            enable_thinking: Some(true),
            ..Default::default()
        };
        let config = provider.build_thinking_config(&options).unwrap();
        assert_eq!(config["type"], "adaptive");
    }

    #[test]
    fn thinking_config_budget_older_model() {
        let mut cfg = api_key_config();
        cfg.model = "claude-sonnet-4-5-20250929".into();
        let provider = AnthropicProvider::new(cfg);
        let options = ProviderStreamOptions {
            enable_thinking: Some(true),
            thinking_budget: Some(8000),
            ..Default::default()
        };
        let config = provider.build_thinking_config(&options).unwrap();
        assert_eq!(config["type"], "enabled");
        assert_eq!(config["budget_tokens"], 8000);
    }

    #[test]
    fn thinking_config_budget_default() {
        let mut cfg = api_key_config();
        cfg.model = "claude-sonnet-4-5-20250929".into();
        let provider = AnthropicProvider::new(cfg);
        let options = ProviderStreamOptions {
            enable_thinking: Some(true),
            ..Default::default()
        };
        let config = provider.build_thinking_config(&options).unwrap();
        // Default: max_output / 4 = 64000 / 4 = 16000
        assert_eq!(config["budget_tokens"], 16000);
    }

    // ── Output config (effort) ──────────────────────────────────────────

    #[test]
    fn output_config_opus_46_with_effort() {
        let provider = AnthropicProvider::new(api_key_config());
        let options = ProviderStreamOptions {
            effort_level: Some("high".into()),
            ..Default::default()
        };
        let config = provider.build_output_config(&options).unwrap();
        assert_eq!(config["effort"], "high");
    }

    #[test]
    fn output_config_no_effort() {
        let provider = AnthropicProvider::new(api_key_config());
        let options = ProviderStreamOptions::default();
        assert!(provider.build_output_config(&options).is_none());
    }

    #[test]
    fn output_config_non_effort_model() {
        let mut cfg = api_key_config();
        cfg.model = "claude-sonnet-4-5-20250929".into();
        let provider = AnthropicProvider::new(cfg);
        let options = ProviderStreamOptions {
            effort_level: Some("high".into()),
            ..Default::default()
        };
        assert!(provider.build_output_config(&options).is_none());
    }

    // ── Max tokens ──────────────────────────────────────────────────────

    #[test]
    fn max_tokens_from_options() {
        let provider = AnthropicProvider::new(api_key_config());
        let options = ProviderStreamOptions {
            max_tokens: Some(4096),
            ..Default::default()
        };
        assert_eq!(provider.calculate_max_tokens(&options), 4096);
    }

    #[test]
    fn max_tokens_from_config() {
        let mut cfg = api_key_config();
        cfg.max_tokens = Some(8000);
        let provider = AnthropicProvider::new(cfg);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 8000);
    }

    #[test]
    fn max_tokens_from_model() {
        let provider = AnthropicProvider::new(api_key_config());
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.calculate_max_tokens(&options), 128_000); // Opus 4.6
    }

    // ── Request building ────────────────────────────────────────────────

    #[test]
    fn build_request_basic() {
        let provider = AnthropicProvider::new(api_key_config());
        let ctx = context_with_system("You are helpful.");
        let options = ProviderStreamOptions::default();
        let messages = convert_messages(&ctx.messages);
        let req = provider.build_request(&ctx, &options, messages);

        assert_eq!(req.model, "claude-opus-4-6");
        assert!(req.stream);
        assert!(req.system.is_some());
        assert!(req.thinking.is_none());
        assert!(req.output_config.is_none());
    }

    // ── API error parsing ───────────────────────────────────────────────

    #[test]
    fn parse_api_error_json() {
        let body = r#"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#;
        let (msg, code, retryable) = parse_api_error(body, 529);
        assert_eq!(msg, "Overloaded");
        assert_eq!(code.as_deref(), Some("overloaded_error"));
        assert!(retryable);
    }

    #[test]
    fn parse_api_error_non_json() {
        let (msg, code, retryable) = parse_api_error("Bad Gateway", 502);
        assert!(msg.contains("502"));
        assert!(code.is_none());
        assert!(retryable);
    }

    #[test]
    fn parse_api_error_400_not_retryable() {
        let body = r#"{"error":{"type":"invalid_request_error","message":"Bad request"}}"#;
        let (msg, _, retryable) = parse_api_error(body, 400);
        assert_eq!(msg, "Bad request");
        assert!(!retryable);
    }

    #[test]
    fn parse_api_error_429_retryable() {
        let body = r#"{"error":{"type":"rate_limit_error","message":"Rate limited"}}"#;
        let (_, _, retryable) = parse_api_error(body, 429);
        assert!(retryable);
    }

    // ── Cache breakpoint on last user message ───────────────────────────

    #[test]
    fn cache_last_user_message() {
        let mut messages = vec![
            AnthropicMessageParam {
                role: "user".into(),
                content: vec![json!({"type": "text", "text": "hello"})],
            },
            AnthropicMessageParam {
                role: "assistant".into(),
                content: vec![json!({"type": "text", "text": "hi"})],
            },
            AnthropicMessageParam {
                role: "user".into(),
                content: vec![json!({"type": "text", "text": "question"})],
            },
        ];
        AnthropicProvider::apply_cache_to_last_user_message(&mut messages);

        // Last user message (index 2) should have cache_control
        assert!(messages[2].content[0]["cache_control"].is_object());
        assert_eq!(messages[2].content[0]["cache_control"]["type"], "ephemeral");

        // First user message should NOT have cache_control
        assert!(messages[0].content[0].get("cache_control").is_none());
    }
}
