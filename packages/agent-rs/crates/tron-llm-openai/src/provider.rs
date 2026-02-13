//! `OpenAI` provider implementing the [`Provider`] trait.
//!
//! Builds and sends streaming requests to the `OpenAI` Responses API (Codex endpoint).
//! Supports OAuth authentication with automatic JWT account ID extraction,
//! token refresh before expiry, and reasoning effort levels.
//!
//! # Authentication
//!
//! OAuth only -- the Codex endpoint requires OAuth Bearer tokens. On every stream
//! request, the provider checks if the access token is about to expire and
//! refreshes it automatically.
//!
//! # Context Injection
//!
//! Context parts (rules, memory, skills, tasks) are injected as a `developer`
//! message prepended to the input. On the first turn (no assistant messages yet),
//! a tool clarification message is also prepended.

use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine as _;
use futures::stream::{self, StreamExt};
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_TYPE};
use tracing::{debug, info, warn};

use tron_core::events::StreamEvent;
use tron_core::messages::{Context, Message};
use tron_llm::compose_context_parts;
use tron_llm::models::types::ProviderType;
use tron_llm::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use tron_llm::sse::parse_sse_lines;

use crate::message_converter::{
    convert_to_responses_input, convert_tools, generate_tool_clarification_message,
};
use crate::stream_handler::{create_stream_state, process_stream_event};
use crate::types::{
    get_openai_model, MessageContent, OpenAIApiSettings, OpenAIAuth, OpenAIConfig,
    ReasoningConfig, ResponsesInputItem, ResponsesRequest, ResponsesSseEvent, DEFAULT_BASE_URL,
};

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Default OAuth token endpoint.
const DEFAULT_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";

/// Default OAuth client ID.
const DEFAULT_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";

/// Buffer before token expiry to trigger refresh (milliseconds).
const TOKEN_EXPIRY_BUFFER_MS: i64 = 300 * 1000;

/// SSE parser options for the Responses API.
///
/// `OpenAI` uses an explicit `[DONE]` marker, so we don't need to process
/// remaining buffer content when the stream ends.
static SSE_OPTIONS: tron_llm::SseParserOptions = tron_llm::SseParserOptions {
    process_remaining_buffer: false,
};

/// Default system instructions for the Codex endpoint.
///
/// The `ChatGPT` backend validates these instructions exactly -- they cannot be
/// modified. Loaded from `codex-instructions.md` at compile time.
const DEFAULT_INSTRUCTIONS: &str = include_str!("prompts/codex-instructions.md");

// ─────────────────────────────────────────────────────────────────────────────
// Auth helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Extract the `ChatGPT` account ID from a JWT access token.
///
/// Decodes the JWT payload and looks for the `chatgpt_account_id` field
/// in the `https://api.openai.com/auth` claims object.
///
/// Returns an empty string on any parsing failure (malformed JWT, missing
/// claims, etc.) -- the request can still proceed without the account ID.
pub fn extract_account_id(token: &str) -> String {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() < 2 {
        return String::new();
    }

    let Ok(payload_bytes) = base64::engine::general_purpose::STANDARD
        .decode(to_standard_base64(parts[1]))
    else {
        return String::new();
    };

    let Ok(payload_str) = std::str::from_utf8(&payload_bytes) else {
        return String::new();
    };

    let Ok(payload) = serde_json::from_str::<serde_json::Value>(payload_str) else {
        return String::new();
    };

    payload
        .get("https://api.openai.com/auth")
        .and_then(|auth| auth.get("chatgpt_account_id"))
        .and_then(|id| id.as_str())
        .unwrap_or("")
        .to_string()
}

/// Convert base64url encoding to standard base64 (with padding).
fn to_standard_base64(input: &str) -> String {
    let standard: String = input
        .chars()
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            c => c,
        })
        .collect();

    // Add padding to make length a multiple of 4
    match standard.len() % 4 {
        2 => format!("{standard}=="),
        3 => format!("{standard}="),
        _ => standard,
    }
}

/// Check if OAuth tokens need to be refreshed.
///
/// Returns `true` if the current time is within the expiry buffer
/// of the token's `expires_at` timestamp (milliseconds since epoch).
pub fn should_refresh_tokens(expires_at: i64) -> bool {
    let now_ms = now_millis();
    now_ms > expires_at.saturating_sub(TOKEN_EXPIRY_BUFFER_MS)
}

/// OAuth token refresh response.
#[derive(serde::Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
    expires_in: i64,
}

/// Refresh OAuth tokens using the `refresh_token` grant.
///
/// Returns new tokens on success. The caller is responsible for persisting
/// the new tokens (e.g., via `tron_auth::save_provider_oauth_tokens`).
async fn refresh_tokens(
    refresh_token: &str,
    settings: &OpenAIApiSettings,
    client: &reqwest::Client,
) -> ProviderResult<tron_auth::OAuthTokens> {
    let token_url = settings
        .token_url
        .as_deref()
        .unwrap_or(DEFAULT_TOKEN_URL);
    let client_id = settings
        .client_id
        .as_deref()
        .unwrap_or(DEFAULT_CLIENT_ID);

    info!("Refreshing OpenAI OAuth tokens");

    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    });

    let response = client
        .post(token_url)
        .header(CONTENT_TYPE, "application/json")
        .json(&body)
        .send()
        .await
        .map_err(ProviderError::Http)?;

    if !response.status().is_success() {
        let status = response.status().as_u16();
        let error_text = response.text().await.unwrap_or_default();
        return Err(ProviderError::Auth {
            message: format!("Token refresh failed: {status} - {error_text}"),
        });
    }

    let data: TokenResponse = response.json().await.map_err(ProviderError::Http)?;

    let new_tokens = tron_auth::OAuthTokens {
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: now_millis() + data.expires_in * 1000,
    };

    info!("Successfully refreshed OpenAI OAuth tokens");
    Ok(new_tokens)
}

/// Current time in milliseconds since epoch.
#[allow(clippy::cast_possible_truncation)] // u128->i64 truncation won't happen before year ~292 million
fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` LLM provider for the Responses API (Codex endpoint).
pub struct OpenAIProvider {
    /// Provider configuration.
    config: OpenAIConfig,
    /// HTTP client (reused across requests).
    client: reqwest::Client,
    /// Resolved base URL.
    base_url: String,
    /// Mutable OAuth token state (refreshed before each request).
    tokens: tokio::sync::Mutex<tron_auth::OAuthTokens>,
    /// API settings (token URL, client ID, etc.).
    provider_settings: OpenAIApiSettings,
}

impl OpenAIProvider {
    /// Create a new `OpenAI` provider.
    #[must_use]
    pub fn new(config: OpenAIConfig) -> Self {
        let base_url = config
            .base_url
            .clone()
            .or_else(|| config.provider_settings.base_url.clone())
            .unwrap_or_else(|| DEFAULT_BASE_URL.to_string());

        let tokens = match &config.auth {
            OpenAIAuth::OAuth { tokens } => tokens.clone(),
        };

        let provider_settings = config.provider_settings.clone();

        info!(model = %config.model, base_url = %base_url, "OpenAI provider initialized");

        Self {
            config,
            client: reqwest::Client::new(),
            base_url,
            tokens: tokio::sync::Mutex::new(tokens),
            provider_settings,
        }
    }

    /// Ensure OAuth tokens are valid, refreshing if necessary.
    async fn ensure_valid_tokens(&self) -> ProviderResult<()> {
        let mut tokens = self.tokens.lock().await;
        if should_refresh_tokens(tokens.expires_at) {
            let new_tokens =
                refresh_tokens(&tokens.refresh_token, &self.provider_settings, &self.client)
                    .await?;
            *tokens = new_tokens;
        }
        Ok(())
    }

    /// Build HTTP headers for the Responses API request.
    fn build_headers(tokens: &tron_auth::OAuthTokens) -> ProviderResult<HeaderMap> {
        let mut headers = HeaderMap::new();

        let auth_value = format!("Bearer {}", tokens.access_token);
        let _ = headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&auth_value).map_err(|e| ProviderError::Auth {
                message: format!("Invalid authorization header: {e}"),
            })?,
        );
        let _ = headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        let _ = headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
        let _ = headers.insert(
            "openai-beta",
            HeaderValue::from_static("responses=experimental"),
        );
        let _ = headers.insert(
            "openai-originator",
            HeaderValue::from_static("codex_cli_rs"),
        );

        let account_id = extract_account_id(&tokens.access_token);
        if !account_id.is_empty() {
            if let Ok(val) = HeaderValue::from_str(&account_id) {
                let _ = headers.insert("chatgpt-account-id", val);
            }
        }

        Ok(headers)
    }

    /// Resolve the reasoning effort level from options -> config -> settings -> model default.
    fn resolve_reasoning_effort(&self, options: &ProviderStreamOptions) -> String {
        options
            .reasoning_effort
            .as_deref()
            .or(self.config.reasoning_effort.as_deref())
            .or(self.provider_settings.default_reasoning_effort.as_deref())
            .unwrap_or_else(|| {
                get_openai_model(&self.config.model).map_or("medium", |m| m.default_reasoning_level)
            })
            .to_string()
    }

    /// Determine if this is the first turn (no assistant messages in history).
    fn is_first_turn(messages: &[Message]) -> bool {
        !messages
            .iter()
            .any(|m| matches!(m, Message::Assistant { .. }))
    }

    /// Build the Responses API input array from the context.
    ///
    /// Converts messages, prepends a tool clarification on the first turn,
    /// and injects context parts (rules, memory, skills, tasks) as a developer message.
    fn build_input(context: &Context) -> Vec<ResponsesInputItem> {
        let mut input = convert_to_responses_input(&context.messages);

        // Prepend tool clarification on first turn (before any assistant messages)
        if let Some(ref ctx_tools) = context.tools {
            if !ctx_tools.is_empty() && Self::is_first_turn(&context.messages) {
                let clarification = generate_tool_clarification_message(
                    ctx_tools,
                    context.working_directory.as_deref(),
                );
                input.insert(
                    0,
                    ResponsesInputItem::Message {
                        role: "user".into(),
                        content: vec![MessageContent::InputText {
                            text: clarification,
                        }],
                        id: None,
                    },
                );
                debug!("Prepended tool clarification message (first turn)");
            }
        }

        // Inject context parts as developer message (rules, memory, skills, tasks)
        let context_parts = compose_context_parts(context);
        if !context_parts.is_empty() {
            input.insert(
                0,
                ResponsesInputItem::Message {
                    role: "developer".into(),
                    content: vec![MessageContent::InputText {
                        text: context_parts.join("\n\n"),
                    }],
                    id: None,
                },
            );
        }

        input
    }

    /// Build the full [`ResponsesRequest`] from context and options.
    fn build_request(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ResponsesRequest {
        let reasoning_effort = self.resolve_reasoning_effort(options);
        let input = Self::build_input(context);
        let tools = context.tools.as_ref().map(|t| convert_tools(t));

        ResponsesRequest {
            model: self.config.model.clone(),
            input,
            instructions: Some(DEFAULT_INSTRUCTIONS.to_string()),
            stream: true,
            store: false,
            temperature: options.temperature,
            tools,
            max_output_tokens: options.max_tokens,
            reasoning: Some(ReasoningConfig {
                effort: reasoning_effort,
                summary: "detailed".into(),
            }),
        }
    }

    /// Internal streaming implementation.
    async fn stream_internal(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(
            model = %self.config.model,
            message_count = context.messages.len(),
            tool_count = context.tools.as_ref().map_or(0, Vec::len),
            "Starting OpenAI stream"
        );

        let tokens = self.tokens.lock().await;
        let headers = Self::build_headers(&tokens)?;
        drop(tokens);

        let request = self.build_request(context, options);
        let url = format!("{}/codex/responses", self.base_url);

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .json(&request)
            .send()
            .await
            .map_err(ProviderError::Http)?;

        let status = response.status();
        if !status.is_success() {
            let body_text = response.text().await.unwrap_or_default();
            let (message, code, retryable) = parse_api_error(&body_text, status.as_u16());
            return Err(ProviderError::Api {
                status: status.as_u16(),
                message,
                code,
                retryable,
            });
        }

        let byte_stream = response.bytes_stream();
        let sse_lines = parse_sse_lines(byte_stream, &SSE_OPTIONS);

        let event_stream = sse_lines
            .scan(create_stream_state(), |state, line| {
                let event: ResponsesSseEvent = match serde_json::from_str(&line) {
                    Ok(e) => e,
                    Err(e) => {
                        warn!(line = %line, error = %e, "Failed to parse OpenAI SSE event");
                        return std::future::ready(Some(vec![]));
                    }
                };
                let events = process_stream_event(&event, state);
                std::future::ready(Some(events))
            })
            .flat_map(stream::iter)
            .map(Ok);

        Ok(Box::pin(event_stream))
    }
}

/// Parse an API error response body.
fn parse_api_error(body: &str, status: u16) -> (String, Option<String>, bool) {
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(body) {
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
impl Provider for OpenAIProvider {
    fn provider_type(&self) -> ProviderType {
        ProviderType::OpenAi
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        // Ensure tokens are valid before starting
        self.ensure_valid_tokens().await?;

        let start_event = stream::once(async { Ok(StreamEvent::Start) });
        let inner_stream = self.stream_internal(context, options).await?;
        Ok(Box::pin(start_event.chain(inner_stream)))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::OpenAIApiSettings;

    fn test_tokens() -> tron_auth::OAuthTokens {
        tron_auth::OAuthTokens {
            access_token: "test-token".into(),
            refresh_token: "test-refresh".into(),
            expires_at: now_millis() + 3_600_000, // 1 hour from now
        }
    }

    fn test_config() -> OpenAIConfig {
        OpenAIConfig {
            model: "gpt-5.3-codex".into(),
            auth: OpenAIAuth::OAuth {
                tokens: test_tokens(),
            },
            max_tokens: None,
            temperature: None,
            base_url: None,
            reasoning_effort: None,
            provider_settings: OpenAIApiSettings::default(),
        }
    }

    /// Encode a string as base64url (no padding) for building test JWTs.
    fn base64url_encode(input: &str) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(input.as_bytes())
    }

    // ── Provider metadata ─────────────────────────────────────────────

    #[test]
    fn provider_type_is_openai() {
        let provider = OpenAIProvider::new(test_config());
        assert_eq!(provider.provider_type(), ProviderType::OpenAi);
    }

    #[test]
    fn provider_model_returns_config_model() {
        let provider = OpenAIProvider::new(test_config());
        assert_eq!(provider.model(), "gpt-5.3-codex");
    }

    #[test]
    fn provider_base_url_default() {
        let provider = OpenAIProvider::new(test_config());
        assert_eq!(provider.base_url, DEFAULT_BASE_URL);
    }

    #[test]
    fn provider_base_url_from_config() {
        let mut config = test_config();
        config.base_url = Some("https://custom.api.com".into());
        let provider = OpenAIProvider::new(config);
        assert_eq!(provider.base_url, "https://custom.api.com");
    }

    #[test]
    fn provider_base_url_from_settings() {
        let mut config = test_config();
        config.provider_settings.base_url = Some("https://settings.api.com".into());
        let provider = OpenAIProvider::new(config);
        assert_eq!(provider.base_url, "https://settings.api.com");
    }

    #[test]
    fn provider_base_url_config_overrides_settings() {
        let mut config = test_config();
        config.base_url = Some("https://config.api.com".into());
        config.provider_settings.base_url = Some("https://settings.api.com".into());
        let provider = OpenAIProvider::new(config);
        assert_eq!(provider.base_url, "https://config.api.com");
    }

    // ── extract_account_id ────────────────────────────────────────────

    #[test]
    fn extract_account_id_from_valid_jwt() {
        let header = base64url_encode(r#"{"alg":"RS256","typ":"JWT"}"#);
        let payload = base64url_encode(
            r#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123456"}}"#,
        );
        let token = format!("{header}.{payload}.signature");
        assert_eq!(extract_account_id(&token), "acct_123456");
    }

    #[test]
    fn extract_account_id_empty_for_missing_claims() {
        let header = base64url_encode(r#"{"alg":"RS256"}"#);
        let payload = base64url_encode(r#"{"sub":"user123"}"#);
        let token = format!("{header}.{payload}.sig");
        assert_eq!(extract_account_id(&token), "");
    }

    #[test]
    fn extract_account_id_empty_for_invalid_jwt() {
        assert_eq!(extract_account_id("not-a-jwt"), "");
        assert_eq!(extract_account_id(""), "");
    }

    #[test]
    fn extract_account_id_empty_for_invalid_json() {
        let header = base64url_encode(r#"{"alg":"RS256"}"#);
        let payload = base64url_encode("not json");
        let token = format!("{header}.{payload}.sig");
        assert_eq!(extract_account_id(&token), "");
    }

    #[test]
    fn extract_account_id_empty_for_missing_auth_object() {
        let header = base64url_encode(r#"{"alg":"RS256"}"#);
        let payload = base64url_encode(r#"{"https://api.openai.com/auth":{}}"#);
        let token = format!("{header}.{payload}.sig");
        assert_eq!(extract_account_id(&token), "");
    }

    // ── should_refresh_tokens ─────────────────────────────────────────

    #[test]
    fn should_refresh_when_expired() {
        let expires_at = now_millis().saturating_sub(600_000);
        assert!(should_refresh_tokens(expires_at));
    }

    #[test]
    fn should_refresh_within_buffer() {
        // Expires in 2 minutes (within 5-minute buffer)
        let expires_at = now_millis() + 120_000;
        assert!(should_refresh_tokens(expires_at));
    }

    #[test]
    fn should_not_refresh_when_valid() {
        // Expires in 1 hour
        let expires_at = now_millis() + 3_600_000;
        assert!(!should_refresh_tokens(expires_at));
    }

    #[test]
    fn should_refresh_at_exact_boundary() {
        // Expires exactly at the buffer boundary
        let expires_at = now_millis() + TOKEN_EXPIRY_BUFFER_MS;
        // At the exact boundary, now_ms > expires_at - buffer => now_ms > now_ms => false
        assert!(!should_refresh_tokens(expires_at));
    }

    // ── build_headers ────────────────────────────────────────────────

    #[test]
    fn build_headers_has_required_fields() {
        let tokens = test_tokens();
        let headers = OpenAIProvider::build_headers(&tokens).unwrap();

        assert_eq!(
            headers[AUTHORIZATION].to_str().unwrap(),
            "Bearer test-token"
        );
        assert_eq!(headers[CONTENT_TYPE], "application/json");
        assert_eq!(headers[ACCEPT], "text/event-stream");
        assert_eq!(headers["openai-beta"], "responses=experimental");
        assert_eq!(headers["openai-originator"], "codex_cli_rs");
    }

    #[test]
    fn build_headers_includes_account_id() {
        let header = base64url_encode(r#"{"alg":"RS256"}"#);
        let payload = base64url_encode(
            r#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_789"}}"#,
        );
        let jwt = format!("{header}.{payload}.sig");

        let tokens = tron_auth::OAuthTokens {
            access_token: jwt,
            refresh_token: "rt".into(),
            expires_at: 9_999_999_999_999,
        };

        let headers = OpenAIProvider::build_headers(&tokens).unwrap();
        assert_eq!(headers["chatgpt-account-id"], "acct_789");
    }

    #[test]
    fn build_headers_omits_account_id_for_non_jwt() {
        let tokens = tron_auth::OAuthTokens {
            access_token: "simple-token".into(),
            refresh_token: "rt".into(),
            expires_at: 9_999_999_999_999,
        };

        let headers = OpenAIProvider::build_headers(&tokens).unwrap();
        assert!(headers.get("chatgpt-account-id").is_none());
    }

    // ── resolve_reasoning_effort ──────────────────────────────────────

    #[test]
    fn reasoning_effort_from_options() {
        let provider = OpenAIProvider::new(test_config());
        let options = ProviderStreamOptions {
            reasoning_effort: Some("high".into()),
            ..Default::default()
        };
        assert_eq!(provider.resolve_reasoning_effort(&options), "high");
    }

    #[test]
    fn reasoning_effort_from_config() {
        let mut config = test_config();
        config.reasoning_effort = Some("xhigh".into());
        let provider = OpenAIProvider::new(config);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.resolve_reasoning_effort(&options), "xhigh");
    }

    #[test]
    fn reasoning_effort_from_settings() {
        let mut config = test_config();
        config.provider_settings.default_reasoning_effort = Some("low".into());
        let provider = OpenAIProvider::new(config);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.resolve_reasoning_effort(&options), "low");
    }

    #[test]
    fn reasoning_effort_from_model_default() {
        let provider = OpenAIProvider::new(test_config());
        let options = ProviderStreamOptions::default();
        // gpt-5.3-codex default is "medium"
        assert_eq!(provider.resolve_reasoning_effort(&options), "medium");
    }

    #[test]
    fn reasoning_effort_options_overrides_config() {
        let mut config = test_config();
        config.reasoning_effort = Some("low".into());
        let provider = OpenAIProvider::new(config);
        let options = ProviderStreamOptions {
            reasoning_effort: Some("max".into()),
            ..Default::default()
        };
        assert_eq!(provider.resolve_reasoning_effort(&options), "max");
    }

    #[test]
    fn reasoning_effort_config_overrides_settings() {
        let mut config = test_config();
        config.reasoning_effort = Some("high".into());
        config.provider_settings.default_reasoning_effort = Some("low".into());
        let provider = OpenAIProvider::new(config);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.resolve_reasoning_effort(&options), "high");
    }

    #[test]
    fn reasoning_effort_unknown_model_defaults_to_medium() {
        let mut config = test_config();
        config.model = "unknown-model".into();
        let provider = OpenAIProvider::new(config);
        let options = ProviderStreamOptions::default();
        assert_eq!(provider.resolve_reasoning_effort(&options), "medium");
    }

    // ── is_first_turn ────────────────────────────────────────────────

    #[test]
    fn first_turn_empty_messages() {
        assert!(OpenAIProvider::is_first_turn(&[]));
    }

    #[test]
    fn first_turn_only_user_messages() {
        let messages = vec![Message::user("Hello")];
        assert!(OpenAIProvider::is_first_turn(&messages));
    }

    #[test]
    fn not_first_turn_with_assistant() {
        use tron_core::content::AssistantContent;
        let messages = vec![
            Message::user("Hello"),
            Message::Assistant {
                content: vec![AssistantContent::text("Hi")],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ];
        assert!(!OpenAIProvider::is_first_turn(&messages));
    }

    // ── parse_api_error ───────────────────────────────────────────────

    #[test]
    fn parse_api_error_json() {
        let body = r#"{"error":{"type":"server_error","message":"Internal error"}}"#;
        let (msg, code, retryable) = parse_api_error(body, 500);
        assert_eq!(msg, "Internal error");
        assert_eq!(code.as_deref(), Some("server_error"));
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
        let body = r#"{"error":{"type":"invalid_request","message":"Bad request"}}"#;
        let (msg, _, retryable) = parse_api_error(body, 400);
        assert_eq!(msg, "Bad request");
        assert!(!retryable);
    }

    #[test]
    fn parse_api_error_429_retryable() {
        let body = r#"{"error":{"type":"rate_limit","message":"Too many requests"}}"#;
        let (_, _, retryable) = parse_api_error(body, 429);
        assert!(retryable);
    }

    #[test]
    fn parse_api_error_missing_fields() {
        let body = r#"{"error":{}}"#;
        let (msg, code, _) = parse_api_error(body, 400);
        assert_eq!(msg, "Unknown error");
        assert!(code.is_none());
    }

    // ── to_standard_base64 ──────────────────────────────────────────

    #[test]
    fn base64url_to_standard_replaces_chars() {
        let result = to_standard_base64("abc-def_ghi");
        assert_eq!(result, "abc+def/ghi=");
    }

    #[test]
    fn base64url_to_standard_adds_padding() {
        assert_eq!(to_standard_base64("YQ"), "YQ==");
        assert_eq!(to_standard_base64("YWI"), "YWI=");
        assert_eq!(to_standard_base64("YWJj"), "YWJj");
    }

    // ── Token refresh (mock server) ──────────────────────────────────

    #[tokio::test]
    async fn refresh_tokens_success() {
        let server = wiremock::MockServer::start().await;

        wiremock::Mock::given(wiremock::matchers::method("POST"))
            .and(wiremock::matchers::path("/oauth/token"))
            .respond_with(wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "new-access-token",
                "refresh_token": "new-refresh-token",
                "expires_in": 3600
            })))
            .mount(&server)
            .await;

        let settings = OpenAIApiSettings {
            token_url: Some(format!("{}/oauth/token", server.uri())),
            ..Default::default()
        };

        let client = reqwest::Client::new();
        let tokens = refresh_tokens("old-refresh-token", &settings, &client)
            .await
            .unwrap();

        assert_eq!(tokens.access_token, "new-access-token");
        assert_eq!(tokens.refresh_token, "new-refresh-token");
        assert!(tokens.expires_at > now_millis());
    }

    #[tokio::test]
    async fn refresh_tokens_failure() {
        let server = wiremock::MockServer::start().await;

        wiremock::Mock::given(wiremock::matchers::method("POST"))
            .and(wiremock::matchers::path("/oauth/token"))
            .respond_with(wiremock::ResponseTemplate::new(401).set_body_string("Unauthorized"))
            .mount(&server)
            .await;

        let settings = OpenAIApiSettings {
            token_url: Some(format!("{}/oauth/token", server.uri())),
            ..Default::default()
        };

        let client = reqwest::Client::new();
        let result = refresh_tokens("bad-token", &settings, &client).await;

        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ProviderError::Auth { .. }));
        assert!(err.to_string().contains("401"));
    }

    // ── ensure_valid_tokens ──────────────────────────────────────────

    #[tokio::test]
    async fn ensure_valid_tokens_skips_refresh_when_valid() {
        let provider = OpenAIProvider::new(test_config());
        // Tokens expire in 1 hour, no refresh needed
        let result = provider.ensure_valid_tokens().await;
        assert!(result.is_ok());
    }

    // ── DEFAULT_INSTRUCTIONS ─────────────────────────────────────────

    #[test]
    fn instructions_not_empty() {
        assert!(!DEFAULT_INSTRUCTIONS.is_empty());
        assert!(DEFAULT_INSTRUCTIONS.contains("Codex"));
    }
}
