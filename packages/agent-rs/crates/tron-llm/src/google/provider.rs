//! Google Gemini provider implementing the [`Provider`] trait.
//!
//! Supports three authentication modes:
//! - **Cloud Code Assist** (OAuth) — uses `cloudcode-pa.googleapis.com` with project ID
//! - **Antigravity** (OAuth) — uses `daily-cloudcode-pa.sandbox.googleapis.com` with wrapper format
//! - **API Key** — uses `generativelanguage.googleapis.com` directly
//!
//! # Thinking Configuration
//!
//! Gemini 3 models use discrete `thinkingLevel` values (minimal/low/medium/high).
//! Gemini 2.5 models use a `thinkingBudget` in tokens (0-32768).
//! The provider detects the model family and applies the correct format.
//!
//! # Temperature Enforcement
//!
//! Gemini 3 models require `temperature=1.0`. Any other value is overridden
//! with a warning.

use async_trait::async_trait;
use futures::stream::{self, StreamExt};
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use tracing::{debug, error, info, instrument, warn};

use crate::auth::{OAuthTokens, calculate_expires_at, should_refresh};
use crate::compose_context_parts;
use crate::models::types::ProviderType;
use crate::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::sse::parse_sse_lines;
use tron_core::events::StreamEvent;
use tron_core::messages::Context;

use super::message_converter::{convert_messages, convert_tools};
use super::stream_handler::{create_stream_state, process_stream_chunk};
use super::types::{
    ANTIGRAVITY_ENDPOINT, ANTIGRAVITY_VERSION, CLOUD_CODE_ASSIST_ENDPOINT,
    CLOUD_CODE_ASSIST_VERSION, DEFAULT_API_KEY_BASE_URL, DEFAULT_MAX_OUTPUT_TOKENS,
    GenerationConfig, GoogleApiSettings, GoogleAuth, GoogleConfig, GoogleOAuthEndpoint,
    SystemInstruction, SystemPart, ThinkingConfig, default_safety_settings, get_gemini_model,
    is_gemini_3_model, map_to_antigravity_model,
};

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Default Google OAuth token URL.
const DEFAULT_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";

/// Token refresh buffer in milliseconds (5 minutes).
const TOKEN_REFRESH_BUFFER_MS: i64 = 300_000;

/// SSE parser options for the Gemini API.
///
/// Gemini may have unparsed buffer content when the stream ends, so we
/// process remaining buffer to avoid losing the final chunk.
static SSE_OPTIONS: crate::SseParserOptions = crate::SseParserOptions {
    process_remaining_buffer: true,
};

// ─────────────────────────────────────────────────────────────────────────────
// Auth helpers
// ─────────────────────────────────────────────────────────────────────────────

/// OAuth token refresh response.
#[derive(serde::Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: i64,
}

/// Refresh Google OAuth tokens.
#[instrument(skip_all)]
async fn refresh_tokens(
    tokens: &OAuthTokens,
    settings: &GoogleApiSettings,
    client: &reqwest::Client,
) -> ProviderResult<OAuthTokens> {
    let token_url = settings.token_url.as_deref().unwrap_or(DEFAULT_TOKEN_URL);

    let client_id = settings.client_id.as_deref().ok_or(ProviderError::Auth {
        message: "Google OAuth client_id required for token refresh".into(),
    })?;
    let client_secret = settings
        .client_secret
        .as_deref()
        .ok_or(ProviderError::Auth {
            message: "Google OAuth client_secret required for token refresh".into(),
        })?;

    info!("Refreshing Google OAuth tokens");

    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": tokens.refresh_token,
        "client_id": client_id,
        "client_secret": client_secret,
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
            message: format!("Google token refresh failed: {status} - {error_text}"),
        });
    }

    let data: TokenResponse = response.json().await.map_err(ProviderError::Http)?;
    let expires_at = calculate_expires_at(data.expires_in, 0);

    Ok(OAuthTokens {
        access_token: data.access_token,
        refresh_token: data
            .refresh_token
            .unwrap_or_else(|| tokens.refresh_token.clone()),
        expires_at,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

/// Google Gemini LLM provider.
pub struct GoogleProvider {
    /// Provider configuration.
    config: GoogleConfig,
    /// HTTP client (reused across requests).
    client: reqwest::Client,
    /// Mutable OAuth token state (refreshed before each request).
    tokens: Option<tokio::sync::Mutex<OAuthTokens>>,
    /// OAuth endpoint variant.
    endpoint: Option<GoogleOAuthEndpoint>,
    /// Google Cloud project ID (Cloud Code Assist only).
    project_id: Option<String>,
}

impl GoogleProvider {
    /// Create a new Google provider.
    #[must_use]
    pub fn new(config: GoogleConfig) -> Self {
        let (tokens, endpoint, project_id) = match &config.auth {
            GoogleAuth::Oauth {
                tokens,
                endpoint,
                project_id,
            } => (
                Some(tokio::sync::Mutex::new(tokens.clone())),
                Some(*endpoint),
                project_id.clone(),
            ),
            GoogleAuth::ApiKey { .. } => (None, None, None),
        };

        info!(
            model = %config.model,
            auth_type = match &config.auth {
                GoogleAuth::Oauth { .. } => "oauth",
                GoogleAuth::ApiKey { .. } => "api_key",
            },
            endpoint = ?endpoint,
            "Google provider initialized"
        );

        Self {
            config,
            client: reqwest::Client::new(),
            tokens,
            endpoint,
            project_id,
        }
    }

    /// Create a new Google provider with a shared HTTP client.
    #[must_use]
    pub fn with_client(config: GoogleConfig, client: reqwest::Client) -> Self {
        let (tokens, endpoint, project_id) = match &config.auth {
            GoogleAuth::Oauth {
                tokens,
                endpoint,
                project_id,
            } => (
                Some(tokio::sync::Mutex::new(tokens.clone())),
                Some(*endpoint),
                project_id.clone(),
            ),
            GoogleAuth::ApiKey { .. } => (None, None, None),
        };

        info!(
            model = %config.model,
            auth_type = match &config.auth {
                GoogleAuth::Oauth { .. } => "oauth",
                GoogleAuth::ApiKey { .. } => "api_key",
            },
            endpoint = ?endpoint,
            "Google provider initialized"
        );

        Self {
            config,
            client,
            tokens,
            endpoint,
            project_id,
        }
    }

    /// Ensure OAuth tokens are valid, refreshing if necessary.
    #[instrument(skip_all)]
    async fn ensure_valid_tokens(&self) -> ProviderResult<()> {
        let Some(ref token_mutex) = self.tokens else {
            return Ok(()); // API key auth, no tokens to refresh
        };

        let mut tokens = token_mutex.lock().await;
        if should_refresh(&tokens, TOKEN_REFRESH_BUFFER_MS) {
            let new_tokens =
                refresh_tokens(&tokens, &self.config.provider_settings, &self.client).await?;
            *tokens = new_tokens;
        }
        Ok(())
    }

    /// Get the API URL for a given action.
    fn get_api_url(&self, action: &str) -> String {
        match &self.config.auth {
            GoogleAuth::Oauth { .. } => {
                let (base, version) = match self.endpoint {
                    Some(GoogleOAuthEndpoint::Antigravity) => {
                        (ANTIGRAVITY_ENDPOINT, ANTIGRAVITY_VERSION)
                    }
                    _ => (CLOUD_CODE_ASSIST_ENDPOINT, CLOUD_CODE_ASSIST_VERSION),
                };
                format!("{base}/{version}:{action}?alt=sse")
            }
            GoogleAuth::ApiKey { api_key } => {
                let base = self
                    .config
                    .base_url
                    .as_deref()
                    .unwrap_or(DEFAULT_API_KEY_BASE_URL);
                format!(
                    "{base}/models/{}:{action}?key={api_key}&alt=sse",
                    self.config.model
                )
            }
        }
    }

    /// Build HTTP headers for the request.
    async fn build_headers(&self) -> ProviderResult<HeaderMap> {
        let mut headers = HeaderMap::new();

        let _ = headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));

        match &self.config.auth {
            GoogleAuth::Oauth { .. } => {
                let token_mutex = self.tokens.as_ref().ok_or_else(|| ProviderError::Auth {
                    message: "OAuth tokens not initialized".into(),
                })?;
                let tokens = token_mutex.lock().await;
                let auth_value = format!("Bearer {}", tokens.access_token);
                let _ = headers.insert(
                    AUTHORIZATION,
                    HeaderValue::from_str(&auth_value).map_err(|e| ProviderError::Auth {
                        message: format!("Invalid authorization header: {e}"),
                    })?,
                );

                match self.endpoint {
                    Some(GoogleOAuthEndpoint::Antigravity) => {
                        let _ =
                            headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
                    }
                    _ => {
                        // Cloud Code Assist requires project ID header
                        if let Some(ref pid) = self.project_id {
                            if let Ok(val) = HeaderValue::from_str(pid) {
                                let _ = headers.insert("x-goog-user-project", val);
                            }
                        }
                    }
                }

                let _ = headers.insert(
                    "user-agent",
                    HeaderValue::from_static("tron-ai-agent/1.0.0"),
                );
                let _ = headers.insert(
                    "x-goog-api-client",
                    HeaderValue::from_static("gl-rust/1.0.0"),
                );
            }
            GoogleAuth::ApiKey { .. } => {
                // API key is in the URL, no auth header needed
            }
        }

        Ok(headers)
    }

    /// Build the generation config.
    fn build_generation_config(&self, options: &ProviderStreamOptions) -> GenerationConfig {
        let model = &self.config.model;
        let is_gemini3 = is_gemini_3_model(model);

        let max_tokens = options
            .max_tokens
            .or(self.config.max_tokens)
            .unwrap_or_else(|| {
                get_gemini_model(model).map_or(DEFAULT_MAX_OUTPUT_TOKENS, |m| m.max_output)
            });

        let temperature = if is_gemini3 {
            let temp = options.temperature.or(self.config.temperature);
            if let Some(t) = temp {
                if (t - 1.0).abs() > f64::EPSILON {
                    warn!(
                        requested = t,
                        "Gemini 3 requires temperature=1.0, overriding"
                    );
                }
            }
            Some(1.0)
        } else {
            options.temperature.or(self.config.temperature)
        };

        GenerationConfig {
            max_output_tokens: Some(max_tokens),
            temperature,
            top_p: None,
            top_k: None,
            stop_sequences: None,
        }
    }

    /// Build thinking configuration based on model family.
    ///
    /// Per-request options (`thinking_level`, `gemini_thinking_budget`) override
    /// provider-level config, allowing the turn runner to pass through the user's
    /// reasoning level selection.
    fn build_thinking_config(
        &self,
        is_gemini3: bool,
        options: &ProviderStreamOptions,
    ) -> Option<ThinkingConfig> {
        let model_info = get_gemini_model(&self.config.model);
        if model_info.is_some_and(|m| !m.supports_thinking) {
            return None;
        }

        if is_gemini3 {
            // Per-request thinking_level overrides provider config
            let level = if let Some(ref level_str) = options.thinking_level {
                level_str.clone()
            } else {
                self.config.thinking_level.as_ref().map_or_else(
                    || {
                        model_info
                            .and_then(|m| m.default_thinking_level.as_ref())
                            .map_or_else(|| "HIGH".to_string(), |l| l.to_api_string().to_string())
                    },
                    |l| l.to_api_string().to_string(),
                )
            };
            Some(ThinkingConfig {
                include_thoughts: Some(true),
                thinking_level: Some(level),
                thinking_budget: None,
            })
        } else {
            // Per-request budget overrides provider config
            let budget = options
                .gemini_thinking_budget
                .or(self.config.thinking_budget)
                .unwrap_or(10_000);
            Some(ThinkingConfig {
                include_thoughts: Some(true),
                thinking_level: None,
                thinking_budget: Some(budget),
            })
        }
    }

    /// Build the request body for OAuth endpoints.
    fn build_oauth_request_body(
        &self,
        context: &Context,
        gen_config: &GenerationConfig,
        thinking_config: Option<&ThinkingConfig>,
    ) -> serde_json::Value {
        let contents = convert_messages(context);
        let tools = context.tools.as_ref().map(|t| convert_tools(t));
        let safety_settings = self
            .config
            .safety_settings
            .clone()
            .unwrap_or_else(default_safety_settings);

        let system_instruction = Self::build_system_instruction(context);

        let mut inner = serde_json::json!({
            "contents": contents,
            "generationConfig": gen_config,
            "safetySettings": safety_settings,
        });

        if let Some(tc) = thinking_config {
            inner["thinkingConfig"] = serde_json::to_value(tc).unwrap_or_default();
        }

        if let Some(tools) = tools {
            inner["tools"] = serde_json::to_value(tools).unwrap_or_default();
        }

        if let Some(si) = system_instruction {
            inner["systemInstruction"] = serde_json::to_value(si).unwrap_or_default();
        }

        if let Some(GoogleOAuthEndpoint::Antigravity) = self.endpoint {
            let project = self.project_id.as_deref().unwrap_or("");
            let model = map_to_antigravity_model(&self.config.model);

            serde_json::json!({
                "project": project,
                "model": model,
                "request": inner,
                "requestType": "agent",
                "userAgent": "antigravity",
                "requestId": format!("agent-{}", uuid::Uuid::now_v7()),
            })
        } else {
            // Cloud Code Assist: model goes in request body
            inner["model"] = serde_json::json!(format!("models/{}", self.config.model));
            inner
        }
    }

    /// Build the request body for API key endpoints.
    fn build_api_key_request_body(
        &self,
        context: &Context,
        gen_config: &GenerationConfig,
        thinking_config: Option<&ThinkingConfig>,
    ) -> serde_json::Value {
        let contents = convert_messages(context);
        let tools = context.tools.as_ref().map(|t| convert_tools(t));
        let safety_settings = self
            .config
            .safety_settings
            .clone()
            .unwrap_or_else(default_safety_settings);

        let system_instruction = Self::build_system_instruction(context);

        let mut body = serde_json::json!({
            "contents": contents,
            "generationConfig": gen_config,
            "safetySettings": safety_settings,
        });

        if let Some(tc) = thinking_config {
            body["thinkingConfig"] = serde_json::to_value(tc).unwrap_or_default();
        }

        if let Some(tools) = tools {
            body["tools"] = serde_json::to_value(tools).unwrap_or_default();
        }

        if let Some(si) = system_instruction {
            body["systemInstruction"] = serde_json::to_value(si).unwrap_or_default();
        }

        body
    }

    /// Build system instruction from context.
    fn build_system_instruction(context: &Context) -> Option<SystemInstruction> {
        let mut parts_text = Vec::new();

        if let Some(ref sp) = context.system_prompt {
            parts_text.push(sp.clone());
        }

        let context_parts = compose_context_parts(context);
        if !context_parts.is_empty() {
            parts_text.push(context_parts.join("\n\n"));
        }

        if parts_text.is_empty() {
            return None;
        }

        Some(SystemInstruction {
            parts: vec![SystemPart {
                text: parts_text.join("\n\n"),
            }],
        })
    }

    /// Internal streaming implementation.
    #[instrument(skip_all, fields(model = %self.config.model))]
    async fn stream_internal(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        let gen_config = self.build_generation_config(options);
        let is_gemini3 = is_gemini_3_model(&self.config.model);
        let thinking_config = self.build_thinking_config(is_gemini3, options);

        debug!(
            model = %self.config.model,
            message_count = context.messages.len(),
            tool_count = context.tools.as_ref().map_or(0, Vec::len),
            max_tokens = ?gen_config.max_output_tokens,
            "Starting Gemini stream"
        );

        let headers = self.build_headers().await?;

        let body = match &self.config.auth {
            GoogleAuth::Oauth { .. } => {
                self.build_oauth_request_body(context, &gen_config, thinking_config.as_ref())
            }
            GoogleAuth::ApiKey { .. } => {
                self.build_api_key_request_body(context, &gen_config, thinking_config.as_ref())
            }
        };

        let url = self.get_api_url("streamGenerateContent");

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
                "Google API error"
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

        let byte_stream = response.bytes_stream();
        let sse_lines = parse_sse_lines(byte_stream, &SSE_OPTIONS);

        let event_stream = sse_lines
            .scan(create_stream_state(), |state, line| {
                let chunk = match serde_json::from_str(&line) {
                    Ok(c) => c,
                    Err(e) => {
                        warn!(line = %line, error = %e, "Failed to parse Gemini SSE chunk");
                        return std::future::ready(Some(vec![]));
                    }
                };
                let events = process_stream_chunk(&chunk, state);
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
        let code = error["status"].as_str().map(String::from);
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
impl Provider for GoogleProvider {
    fn provider_type(&self) -> ProviderType {
        ProviderType::Google
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    #[instrument(skip_all, fields(provider = "google", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        self.ensure_valid_tokens().await?;

        let start_event = stream::once(async { Ok(StreamEvent::Start) });
        let inner_stream = match self.stream_internal(context, options).await {
            Ok(s) => s,
            Err(e) => {
                error!(error = %e, "Google stream failed");
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

    fn oauth_tokens() -> OAuthTokens {
        OAuthTokens {
            access_token: "ya29.test".into(),
            refresh_token: "rt-test".into(),
            expires_at: crate::auth::now_ms() + 3_600_000, // 1 hour
        }
    }

    fn oauth_config() -> GoogleConfig {
        GoogleConfig {
            model: "gemini-3-pro-preview".into(),
            auth: GoogleAuth::Oauth {
                tokens: oauth_tokens(),
                endpoint: GoogleOAuthEndpoint::CloudCodeAssist,
                project_id: Some("my-project".into()),
            },
            max_tokens: None,
            temperature: None,
            base_url: None,
            thinking_level: None,
            thinking_budget: None,
            safety_settings: None,
            provider_settings: GoogleApiSettings::default(),
        }
    }

    fn api_key_config() -> GoogleConfig {
        GoogleConfig {
            model: "gemini-2.5-flash".into(),
            auth: GoogleAuth::ApiKey {
                api_key: "AIza-test-key".into(),
            },
            max_tokens: None,
            temperature: None,
            base_url: None,
            thinking_level: None,
            thinking_budget: None,
            safety_settings: None,
            provider_settings: GoogleApiSettings::default(),
        }
    }

    // ── Provider metadata ─────────────────────────────────────────────

    #[test]
    fn provider_type_is_google() {
        let provider = GoogleProvider::new(oauth_config());
        assert_eq!(provider.provider_type(), ProviderType::Google);
    }

    #[test]
    fn provider_model_returns_config_model() {
        let provider = GoogleProvider::new(oauth_config());
        assert_eq!(provider.model(), "gemini-3-pro-preview");
    }

    // ── API URL construction ──────────────────────────────────────────

    #[test]
    fn api_url_cloud_code_assist() {
        let provider = GoogleProvider::new(oauth_config());
        let url = provider.get_api_url("streamGenerateContent");
        assert!(url.starts_with(CLOUD_CODE_ASSIST_ENDPOINT));
        assert!(url.contains("v1internal:streamGenerateContent"));
        assert!(url.contains("alt=sse"));
    }

    #[test]
    fn api_url_antigravity() {
        let mut config = oauth_config();
        config.auth = GoogleAuth::Oauth {
            tokens: oauth_tokens(),
            endpoint: GoogleOAuthEndpoint::Antigravity,
            project_id: None,
        };
        let provider = GoogleProvider::new(config);
        let url = provider.get_api_url("streamGenerateContent");
        assert!(url.starts_with(ANTIGRAVITY_ENDPOINT));
        assert!(url.contains("v1internal:streamGenerateContent"));
    }

    #[test]
    fn api_url_api_key() {
        let provider = GoogleProvider::new(api_key_config());
        let url = provider.get_api_url("streamGenerateContent");
        assert!(url.contains("generativelanguage.googleapis.com"));
        assert!(url.contains("models/gemini-2.5-flash"));
        assert!(url.contains("key=AIza-test-key"));
    }

    #[test]
    fn api_url_api_key_custom_base() {
        let mut config = api_key_config();
        config.base_url = Some("https://custom.api.com/v1".into());
        let provider = GoogleProvider::new(config);
        let url = provider.get_api_url("streamGenerateContent");
        assert!(url.starts_with("https://custom.api.com/v1"));
    }

    // ── Generation config ─────────────────────────────────────────────

    #[test]
    fn gen_config_gemini3_forces_temperature_1() {
        let provider = GoogleProvider::new(oauth_config());
        let options = ProviderStreamOptions {
            temperature: Some(0.7),
            ..Default::default()
        };
        let gc = provider.build_generation_config(&options);
        assert_eq!(gc.temperature, Some(1.0));
    }

    #[test]
    fn gen_config_gemini25_preserves_temperature() {
        let provider = GoogleProvider::new(api_key_config());
        let options = ProviderStreamOptions {
            temperature: Some(0.7),
            ..Default::default()
        };
        let gc = provider.build_generation_config(&options);
        assert_eq!(gc.temperature, Some(0.7));
    }

    #[test]
    fn gen_config_max_tokens_from_options() {
        let provider = GoogleProvider::new(oauth_config());
        let options = ProviderStreamOptions {
            max_tokens: Some(8192),
            ..Default::default()
        };
        let gc = provider.build_generation_config(&options);
        assert_eq!(gc.max_output_tokens, Some(8192));
    }

    #[test]
    fn gen_config_max_tokens_from_config() {
        let mut config = oauth_config();
        config.max_tokens = Some(4096);
        let provider = GoogleProvider::new(config);
        let gc = provider.build_generation_config(&ProviderStreamOptions::default());
        assert_eq!(gc.max_output_tokens, Some(4096));
    }

    #[test]
    fn gen_config_max_tokens_from_model_default() {
        let provider = GoogleProvider::new(oauth_config());
        let gc = provider.build_generation_config(&ProviderStreamOptions::default());
        assert_eq!(gc.max_output_tokens, Some(65_536)); // gemini-3-pro-preview default
    }

    // ── Thinking config ───────────────────────────────────────────────

    #[test]
    fn thinking_config_gemini3_uses_level() {
        let provider = GoogleProvider::new(oauth_config());
        let opts = ProviderStreamOptions::default();
        let tc = provider.build_thinking_config(true, &opts).unwrap();
        assert_eq!(tc.include_thoughts, Some(true));
        assert_eq!(tc.thinking_level.as_deref(), Some("HIGH"));
        assert!(tc.thinking_budget.is_none());
    }

    #[test]
    fn thinking_config_gemini3_custom_level() {
        let mut config = oauth_config();
        config.thinking_level = Some(crate::google::types::GeminiThinkingLevel::Low);
        let provider = GoogleProvider::new(config);
        let opts = ProviderStreamOptions::default();
        let tc = provider.build_thinking_config(true, &opts).unwrap();
        assert_eq!(tc.thinking_level.as_deref(), Some("LOW"));
    }

    #[test]
    fn thinking_config_gemini3_per_request_level_overrides_config() {
        let mut config = oauth_config();
        config.thinking_level = Some(crate::google::types::GeminiThinkingLevel::Low);
        let provider = GoogleProvider::new(config);
        let opts = ProviderStreamOptions {
            thinking_level: Some("THINKING_MEDIUM".into()),
            ..Default::default()
        };
        let tc = provider.build_thinking_config(true, &opts).unwrap();
        assert_eq!(tc.thinking_level.as_deref(), Some("THINKING_MEDIUM"));
    }

    #[test]
    fn thinking_config_gemini25_uses_budget() {
        let provider = GoogleProvider::new(api_key_config());
        let opts = ProviderStreamOptions::default();
        let tc = provider.build_thinking_config(false, &opts).unwrap();
        assert_eq!(tc.include_thoughts, Some(true));
        assert!(tc.thinking_level.is_none());
        assert_eq!(tc.thinking_budget, Some(10_000));
    }

    #[test]
    fn thinking_config_gemini25_custom_budget() {
        let mut config = api_key_config();
        config.thinking_budget = Some(20_000);
        let provider = GoogleProvider::new(config);
        let opts = ProviderStreamOptions::default();
        let tc = provider.build_thinking_config(false, &opts).unwrap();
        assert_eq!(tc.thinking_budget, Some(20_000));
    }

    #[test]
    fn thinking_config_gemini25_per_request_budget_overrides_config() {
        let mut config = api_key_config();
        config.thinking_budget = Some(20_000);
        let provider = GoogleProvider::new(config);
        let opts = ProviderStreamOptions {
            gemini_thinking_budget: Some(5_000),
            ..Default::default()
        };
        let tc = provider.build_thinking_config(false, &opts).unwrap();
        assert_eq!(tc.thinking_budget, Some(5_000));
    }

    #[test]
    fn thinking_config_none_for_non_thinking_model() {
        let mut config = api_key_config();
        config.model = "gemini-2.5-flash-lite".into();
        let provider = GoogleProvider::new(config);
        let opts = ProviderStreamOptions::default();
        let tc = provider.build_thinking_config(false, &opts);
        assert!(tc.is_none());
    }

    #[test]
    fn thinking_config_none_for_gemini3_flash() {
        let mut config = api_key_config();
        config.model = "gemini-3-flash-preview".into();
        let provider = GoogleProvider::new(config);
        let opts = ProviderStreamOptions::default();
        let tc = provider.build_thinking_config(true, &opts);
        assert!(
            tc.is_none(),
            "gemini-3-flash-preview should not send thinkingConfig"
        );
    }

    // ── System instruction ────────────────────────────────────────────

    #[test]
    fn system_instruction_empty_when_no_context() {
        let context = Context {
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
        };
        let si = GoogleProvider::build_system_instruction(&context);
        assert!(si.is_none());
    }

    #[test]
    fn system_instruction_from_prompt() {
        let context = Context {
            system_prompt: Some("You are helpful.".into()),
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let si = GoogleProvider::build_system_instruction(&context).unwrap();
        assert_eq!(si.parts.len(), 1);
        assert!(si.parts[0].text.contains("You are helpful."));
    }

    // ── Request body construction ─────────────────────────────────────

    #[test]
    fn oauth_request_body_cloud_code_assist() {
        let provider = GoogleProvider::new(oauth_config());
        let context = Context {
            system_prompt: Some("Be helpful".into()),
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let opts = ProviderStreamOptions::default();
        let gc = provider.build_generation_config(&opts);
        let tc = provider.build_thinking_config(true, &opts);
        let body = provider.build_oauth_request_body(&context, &gc, tc.as_ref());

        // Cloud Code Assist format: model in body
        assert!(body["model"].as_str().unwrap().starts_with("models/"));
        assert!(body.get("generationConfig").is_some());
        assert!(body.get("safetySettings").is_some());
        assert!(body.get("thinkingConfig").is_some());
    }

    #[test]
    fn oauth_request_body_antigravity() {
        let mut config = oauth_config();
        config.auth = GoogleAuth::Oauth {
            tokens: oauth_tokens(),
            endpoint: GoogleOAuthEndpoint::Antigravity,
            project_id: Some("my-project".into()),
        };
        let provider = GoogleProvider::new(config);
        let context = Context {
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
        };
        let opts = ProviderStreamOptions::default();
        let gc = provider.build_generation_config(&opts);
        let tc = provider.build_thinking_config(true, &opts);
        let body = provider.build_oauth_request_body(&context, &gc, tc.as_ref());

        // Antigravity wrapper format
        assert_eq!(body["project"], "my-project");
        assert_eq!(body["model"], "gemini-3-pro-high"); // mapped model name
        assert_eq!(body["requestType"], "agent");
        assert_eq!(body["userAgent"], "antigravity");
        assert!(body["requestId"].as_str().unwrap().starts_with("agent-"));
        assert!(body.get("request").is_some());
    }

    #[test]
    fn oauth_request_body_antigravity_empty_project() {
        let mut config = oauth_config();
        config.auth = GoogleAuth::Oauth {
            tokens: oauth_tokens(),
            endpoint: GoogleOAuthEndpoint::Antigravity,
            project_id: None,
        };
        let provider = GoogleProvider::new(config);
        let context = Context {
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
        };
        let opts = ProviderStreamOptions::default();
        let gc = provider.build_generation_config(&opts);
        let tc = provider.build_thinking_config(true, &opts);
        let body = provider.build_oauth_request_body(&context, &gc, tc.as_ref());

        // No project ID → empty string (matches TS: `oauthAuth.projectId || ''`)
        assert_eq!(body["project"], "");
    }

    #[test]
    fn api_key_request_body() {
        let provider = GoogleProvider::new(api_key_config());
        let context = Context {
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
        };
        let opts = ProviderStreamOptions::default();
        let gc = provider.build_generation_config(&opts);
        let tc = provider.build_thinking_config(false, &opts);
        let body = provider.build_api_key_request_body(&context, &gc, tc.as_ref());

        assert!(body.get("contents").is_some());
        assert!(body.get("generationConfig").is_some());
        assert!(body.get("safetySettings").is_some());
        // No model in body for API key (it's in the URL)
        assert!(body.get("model").is_none());
    }

    // ── parse_api_error ───────────────────────────────────────────────

    #[test]
    fn parse_api_error_json() {
        let body = r#"{"error":{"status":"NOT_FOUND","message":"Model not found"}}"#;
        let (msg, code, retryable) = parse_api_error(body, 404);
        assert_eq!(msg, "Model not found");
        assert_eq!(code.as_deref(), Some("NOT_FOUND"));
        assert!(!retryable);
    }

    #[test]
    fn parse_api_error_non_json() {
        let (msg, code, retryable) = parse_api_error("Bad Gateway", 502);
        assert!(msg.contains("502"));
        assert!(code.is_none());
        assert!(retryable);
    }

    #[test]
    fn parse_api_error_429_retryable() {
        let body = r#"{"error":{"message":"Rate limited"}}"#;
        let (_, _, retryable) = parse_api_error(body, 429);
        assert!(retryable);
    }

    // ── Token refresh (mock server) ──────────────────────────────────

    #[tokio::test]
    async fn refresh_tokens_success() {
        let server = wiremock::MockServer::start().await;

        wiremock::Mock::given(wiremock::matchers::method("POST"))
            .and(wiremock::matchers::path("/token"))
            .respond_with(
                wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "access_token": "ya29.new",
                    "refresh_token": "rt-new",
                    "expires_in": 3600
                })),
            )
            .mount(&server)
            .await;

        let settings = GoogleApiSettings {
            token_url: Some(format!("{}/token", server.uri())),
            client_id: Some("cid".into()),
            client_secret: Some("csec".into()),
        };

        let tokens = OAuthTokens {
            access_token: "ya29.old".into(),
            refresh_token: "rt-old".into(),
            expires_at: 0,
        };

        let client = reqwest::Client::new();
        let new_tokens = refresh_tokens(&tokens, &settings, &client).await.unwrap();

        assert_eq!(new_tokens.access_token, "ya29.new");
        assert_eq!(new_tokens.refresh_token, "rt-new");
        assert!(new_tokens.expires_at > crate::auth::now_ms());
    }

    #[tokio::test]
    async fn refresh_tokens_preserves_old_refresh_token() {
        let server = wiremock::MockServer::start().await;

        wiremock::Mock::given(wiremock::matchers::method("POST"))
            .and(wiremock::matchers::path("/token"))
            .respond_with(
                wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "access_token": "ya29.new",
                    "expires_in": 3600
                })),
            )
            .mount(&server)
            .await;

        let settings = GoogleApiSettings {
            token_url: Some(format!("{}/token", server.uri())),
            client_id: Some("cid".into()),
            client_secret: Some("csec".into()),
        };

        let tokens = OAuthTokens {
            access_token: "ya29.old".into(),
            refresh_token: "rt-keep-me".into(),
            expires_at: 0,
        };

        let client = reqwest::Client::new();
        let new_tokens = refresh_tokens(&tokens, &settings, &client).await.unwrap();
        assert_eq!(new_tokens.refresh_token, "rt-keep-me");
    }

    #[tokio::test]
    async fn refresh_tokens_failure() {
        let server = wiremock::MockServer::start().await;

        wiremock::Mock::given(wiremock::matchers::method("POST"))
            .respond_with(wiremock::ResponseTemplate::new(401).set_body_string("Unauthorized"))
            .mount(&server)
            .await;

        let settings = GoogleApiSettings {
            token_url: Some(format!("{}/token", server.uri())),
            client_id: Some("cid".into()),
            client_secret: Some("csec".into()),
        };

        let tokens = OAuthTokens {
            access_token: "ya29.old".into(),
            refresh_token: "rt-old".into(),
            expires_at: 0,
        };

        let client = reqwest::Client::new();
        let result = refresh_tokens(&tokens, &settings, &client).await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ProviderError::Auth { .. }));
    }

    #[tokio::test]
    async fn refresh_tokens_requires_client_id() {
        let settings = GoogleApiSettings::default(); // No client_id
        let tokens = oauth_tokens();
        let client = reqwest::Client::new();
        let result = refresh_tokens(&tokens, &settings, &client).await;
        assert!(result.is_err());
    }

    // ── ensure_valid_tokens ──────────────────────────────────────────

    #[tokio::test]
    async fn ensure_valid_tokens_skips_for_api_key() {
        let provider = GoogleProvider::new(api_key_config());
        let result = provider.ensure_valid_tokens().await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn ensure_valid_tokens_skips_refresh_when_valid() {
        let provider = GoogleProvider::new(oauth_config());
        let result = provider.ensure_valid_tokens().await;
        assert!(result.is_ok());
    }
}
