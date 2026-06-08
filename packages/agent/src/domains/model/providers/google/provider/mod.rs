//! Google Gemini provider implementing the [`Provider`] trait.
//!
//! Supports two authentication modes:
//! - **OAuth** — uses `generativelanguage.googleapis.com` with Bearer token + project ID
//! - **API Key** — uses `generativelanguage.googleapis.com` with `?key=` query param
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
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use tracing::{debug, error, info, instrument, warn};

use crate::domains::auth::credentials::{OAuthTokens, calculate_expires_at, should_refresh};
use crate::domains::model::providers::shared::compose_context_parts;
use crate::domains::model::providers::shared::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::protocol::messages::Context;

use super::message_converter::{convert_messages, convert_tools};
use super::stream_handler::{create_stream_state, process_stream_chunk};
use super::types::{
    DEFAULT_API_KEY_BASE_URL, DEFAULT_MAX_OUTPUT_TOKENS, GeminiStreamChunk, GenerationConfig,
    GoogleApiSettings, GoogleAuth, GoogleConfig, SystemInstruction, SystemPart, ThinkingConfig,
    default_safety_settings, get_gemini_model, is_gemini_3_model,
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
static SSE_OPTIONS: crate::domains::model::providers::shared::SseParserOptions =
    crate::domains::model::providers::shared::SseParserOptions {
        process_remaining_buffer: true,
    };

// ─────────────────────────────────────────────────────────────────────────────
// Auth helpers
// ─────────────────────────────────────────────────────────────────────────────

/// OAuth token refresh response.
///
/// Uses the shared [`crate::domains::auth::credentials::OAuthTokenRefreshResponse`] type.
type TokenResponse = crate::domains::auth::credentials::OAuthTokenRefreshResponse;

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
    /// Google Cloud project ID (OAuth only, for quota attribution).
    project_id: Option<String>,
}

impl GoogleProvider {
    /// Create a new Google provider.
    #[must_use]
    pub fn new(config: GoogleConfig) -> Self {
        Self::with_client(config, reqwest::Client::new())
    }

    /// Create a new Google provider with a shared HTTP client.
    #[must_use]
    pub fn with_client(config: GoogleConfig, client: reqwest::Client) -> Self {
        let (tokens, project_id) = match &config.auth {
            GoogleAuth::Oauth {
                tokens, project_id, ..
            } => (
                Some(tokio::sync::Mutex::new(tokens.clone())),
                project_id.clone(),
            ),
            GoogleAuth::ApiKey { .. } => (None, None),
        };

        info!(
            model = %config.model,
            auth_type = match &config.auth {
                GoogleAuth::Oauth { .. } => "oauth",
                GoogleAuth::ApiKey { .. } => "api_key",
            },
            "Google provider initialized"
        );

        Self {
            config,
            client,
            tokens,
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
        let base = self
            .config
            .base_url
            .as_deref()
            .unwrap_or(DEFAULT_API_KEY_BASE_URL);
        match &self.config.auth {
            GoogleAuth::Oauth { .. } => {
                format!("{base}/models/{}:{action}?alt=sse", self.config.model)
            }
            GoogleAuth::ApiKey { api_key } => {
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

                // Project ID header for quota attribution
                if let Some(ref pid) = self.project_id
                    && let Ok(val) = HeaderValue::from_str(pid)
                {
                    let _ = headers.insert("x-goog-user-project", val);
                }
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
                #[allow(clippy::cast_possible_truncation)]
                get_gemini_model(model).map_or(DEFAULT_MAX_OUTPUT_TOKENS, |m| m.max_output as u32)
            });

        let temperature = if is_gemini3 {
            let temp = options.temperature.or(self.config.temperature);
            if let Some(t) = temp
                && (t - 1.0).abs() > f64::EPSILON
            {
                warn!(
                    requested = t,
                    "Gemini 3 requires temperature=1.0, overriding"
                );
            }
            Some(1.0)
        } else {
            options.temperature.or(self.config.temperature)
        };

        let thinking_config = self.build_thinking_config(is_gemini3, options);

        GenerationConfig {
            max_output_tokens: Some(max_tokens),
            temperature,
            top_p: None,
            top_k: None,
            stop_sequences: None,
            thinking_config,
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

    /// Build the request body (same format for both OAuth and API key).
    ///
    /// Model is always in the URL, not the body.
    fn build_request_body(
        &self,
        context: &Context,
        gen_config: &GenerationConfig,
    ) -> serde_json::Value {
        let contents = convert_messages(context);
        let capabilities = context.capabilities.as_ref().map(|t| convert_tools(t));
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

        if let Some(capabilities) = capabilities {
            body["tools"] = serde_json::to_value(capabilities).unwrap_or_default();
        }

        if let Some(si) = system_instruction {
            body["systemInstruction"] = serde_json::to_value(si).unwrap_or_default();
        }

        body
    }

    /// Build system instruction from context.
    fn build_system_instruction(context: &Context) -> Option<SystemInstruction> {
        let context_parts = compose_context_parts(context);
        if context_parts.is_empty() {
            return None;
        }

        Some(SystemInstruction {
            parts: vec![SystemPart {
                text: context_parts.join("\n\n"),
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

        debug!(
            model = %self.config.model,
            message_count = context.messages.len(),
            tool_count = context.capabilities.as_ref().map_or(0, Vec::len),
            max_tokens = ?gen_config.max_output_tokens,
            "Starting Gemini stream"
        );

        let headers = self.build_headers().await?;

        let body = self.build_request_body(context, &gen_config);

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
                .and_then(crate::shared::foundation::retry::parse_retry_after_header);
            let body_text = response.text().await.unwrap_or_default();
            let err_info = crate::domains::model::providers::shared::error_parsing::parse_api_error(
                &body_text,
                status.as_u16(),
            );
            error!(
                status = status.as_u16(),
                code = err_info.code.as_deref().unwrap_or("unknown"),
                retryable = err_info.retryable,
                "Google API error"
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
            crate::domains::model::providers::shared::stream_pipeline::sse_to_event_stream::<
                GeminiStreamChunk,
                _,
                _,
            >(
                response,
                &SSE_OPTIONS,
                create_stream_state(),
                process_stream_chunk,
            ),
        )
    }
}

#[async_trait]
impl Provider for GoogleProvider {
    fn provider_type(&self) -> crate::shared::protocol::messages::Provider {
        crate::shared::protocol::messages::Provider::Google
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    fn audit_payload(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<serde_json::Value> {
        let gen_config = self.build_generation_config(options);
        Ok(self.build_request_body(context, &gen_config))
    }

    #[instrument(skip_all, fields(provider = "google", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        self.ensure_valid_tokens().await?;
        crate::domains::model::providers::shared::stream_pipeline::wrap_provider_stream(
            "google",
            self.stream_internal(context, options).await,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests;
