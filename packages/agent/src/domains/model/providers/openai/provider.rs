//! `OpenAI` provider implementing the [`Provider`] trait.
//!
//! Builds and sends streaming requests to the `OpenAI` Responses API.
//! Routes to either the Codex backend or the Platform API based on the active
//! OpenAI auth path and model profile. Supports OAuth and API key authentication,
//! automatic JWT account ID extraction (Codex only), token refresh before
//! expiry, and reasoning effort levels.
//!
//! # Authentication
//!
//! - **Codex endpoint**: OAuth Bearer tokens with automatic refresh.
//! - **Platform endpoint**: API keys only (no Codex-specific headers).
//!
//! # Context Injection
//!
//! Primitive context parts (agent soul, agent-owned state, environment, and
//! compact history) are injected as a `developer` message prepended to the
//! input. On the first turn, a clarification message is also prepended when the
//! provider needs extra guidance for the single `execute` primitive.

use async_trait::async_trait;
use base64::Engine as _;
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use tracing::{debug, error, info, instrument};

use crate::domains::model::providers::compose_context_parts;
use crate::domains::model::providers::provider::ReasoningEffort;
use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderResult, ProviderStreamOptions, StreamEventStream,
};
use crate::shared::messages::{Context, Message};

use super::message_converter::{
    convert_to_responses_input, convert_tools_v2, generate_capability_clarification_message,
};
use super::stream_handler::{create_stream_state, process_stream_event};
use super::types::{
    ApiEndpoint, MessageContent, OpenAIApiSettings, OpenAIAuth, OpenAIAuthPath, OpenAIConfig,
    OpenAIModelProfile, ReasoningConfig, ResponseTextConfig, ResponsesInputItem, ResponsesRequest,
    ResponsesSseEvent, get_openai_model_profile, openai_request_model_id,
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
static SSE_OPTIONS: crate::domains::model::providers::SseParserOptions =
    crate::domains::model::providers::SseParserOptions {
        process_remaining_buffer: false,
    };

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

    let Ok(payload_bytes) =
        base64::engine::general_purpose::STANDARD.decode(to_standard_base64(parts[1]))
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

/// OAuth token refresh response.
///
/// Uses the shared [`crate::domains::auth::provider_credentials::OAuthTokenRefreshResponse`] type.
type TokenResponse = crate::domains::auth::provider_credentials::OAuthTokenRefreshResponse;

/// Refresh OAuth tokens using the `refresh_token` grant.
///
/// Returns new tokens on success. The caller is responsible for persisting
/// the new tokens (e.g., via `crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens`).
#[instrument(skip_all)]
async fn refresh_tokens(
    refresh_token: &str,
    settings: &OpenAIApiSettings,
    client: &reqwest::Client,
) -> ProviderResult<crate::domains::auth::provider_credentials::OAuthTokens> {
    let token_url = settings.token_url.as_deref().unwrap_or(DEFAULT_TOKEN_URL);
    let client_id = settings.client_id.as_deref().unwrap_or(DEFAULT_CLIENT_ID);

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

    let new_tokens = crate::domains::auth::provider_credentials::OAuthTokens {
        access_token: data.access_token,
        refresh_token: data
            .refresh_token
            .unwrap_or_else(|| refresh_token.to_string()),
        expires_at: crate::domains::auth::provider_credentials::now_ms() + data.expires_in * 1000,
    };

    info!("Successfully refreshed OpenAI OAuth tokens");
    Ok(new_tokens)
}

// ─────────────────────────────────────────────────────────────────────────────
// Reasoning clamping
// ─────────────────────────────────────────────────────────────────────────────

/// Global reasoning hierarchy from lowest to highest.
/// "max" is a Tron-internal alias that maps to the highest available level.
const REASONING_HIERARCHY: &[&str] = &["none", "minimal", "low", "medium", "high", "xhigh", "max"];

fn reasoning_rank(effort: &str) -> usize {
    REASONING_HIERARCHY
        .iter()
        .position(|&h| h == effort)
        .unwrap_or_else(|| {
            REASONING_HIERARCHY
                .iter()
                .position(|&h| h == "medium")
                .expect("reasoning hierarchy includes medium")
        })
}

/// Clamp a reasoning effort to the closest supported level.
///
/// If `effort` is already in `levels`, returns it unchanged.
/// Otherwise finds the closest level by rank distance (prefers higher on tie
/// for "max"-like values, lower otherwise).
fn clamp_reasoning_effort(effort: &str, levels: &[&str]) -> String {
    if levels.contains(&effort) {
        return effort.to_string();
    }
    let effort_rank = reasoning_rank(effort);

    levels
        .iter()
        .min_by_key(|&&l| {
            let rank = reasoning_rank(l);
            let dist = (rank as i64 - effort_rank as i64).unsigned_abs();
            (dist, rank)
        })
        .map_or_else(|| "medium".to_string(), |s| (*s).to_string())
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` LLM provider for the Responses API.
pub struct OpenAIProvider {
    /// Provider configuration.
    config: OpenAIConfig,
    /// HTTP client (reused across requests).
    client: reqwest::Client,
    /// Resolved base URL.
    base_url: String,
    /// Which API endpoint (Codex vs Platform) this provider targets.
    api_endpoint: ApiEndpoint,
    /// Mutable OAuth token state (refreshed before each request).
    tokens: tokio::sync::Mutex<crate::domains::auth::provider_credentials::OAuthTokens>,
    /// API settings (token URL, client ID, etc.).
    provider_settings: OpenAIApiSettings,
}

impl OpenAIProvider {
    /// Resolve constructor fields shared between `new` and `with_client`.
    ///
    /// Effective endpoint depends on the active auth type:
    /// - **API key** → Platform API
    /// - **OAuth** → Codex backend
    fn resolve(
        config: &OpenAIConfig,
    ) -> (
        ApiEndpoint,
        String,
        crate::domains::auth::provider_credentials::OAuthTokens,
    ) {
        let auth_path = OpenAIAuthPath::from(&config.auth);
        let model_endpoint = get_openai_model_profile(&config.model, auth_path)
            .map_or_else(|| auth_path.endpoint(), |(_, profile)| profile.api_endpoint);

        let (api_endpoint, tokens) = match &config.auth {
            OpenAIAuth::OAuth { tokens } => (model_endpoint, tokens.clone()),
            OpenAIAuth::ApiKey { api_key } => (
                model_endpoint,
                crate::domains::auth::provider_credentials::OAuthTokens {
                    access_token: api_key.clone(),
                    refresh_token: String::new(),
                    expires_at: i64::MAX,
                },
            ),
        };

        let base_url = config
            .base_url
            .clone()
            .or_else(|| config.provider_settings.base_url.clone())
            .unwrap_or_else(|| api_endpoint.default_base_url().to_string());

        (api_endpoint, base_url, tokens)
    }

    /// Create a new `OpenAI` provider.
    #[must_use]
    pub fn new(config: OpenAIConfig) -> Self {
        let (api_endpoint, base_url, tokens) = Self::resolve(&config);
        let provider_settings = config.provider_settings.clone();

        info!(model = %config.model, base_url = %base_url, endpoint = ?api_endpoint, "OpenAI provider initialized");

        Self {
            config,
            client: reqwest::Client::new(),
            base_url,
            api_endpoint,
            tokens: tokio::sync::Mutex::new(tokens),
            provider_settings,
        }
    }

    /// Create a new `OpenAI` provider with a shared HTTP client.
    #[must_use]
    pub fn with_client(config: OpenAIConfig, client: reqwest::Client) -> Self {
        let (api_endpoint, base_url, tokens) = Self::resolve(&config);
        let provider_settings = config.provider_settings.clone();

        info!(model = %config.model, base_url = %base_url, endpoint = ?api_endpoint, "OpenAI provider initialized");

        Self {
            config,
            client,
            base_url,
            api_endpoint,
            tokens: tokio::sync::Mutex::new(tokens),
            provider_settings,
        }
    }

    /// Ensure OAuth tokens are valid, refreshing if necessary.
    #[instrument(skip_all)]
    async fn ensure_valid_tokens(&self) -> ProviderResult<()> {
        let mut tokens = self.tokens.lock().await;
        if crate::domains::auth::provider_credentials::should_refresh(
            &tokens,
            TOKEN_EXPIRY_BUFFER_MS,
        ) {
            let new_tokens =
                refresh_tokens(&tokens.refresh_token, &self.provider_settings, &self.client)
                    .await?;
            *tokens = new_tokens;
        }
        Ok(())
    }

    /// The active auth-path profile for this provider instance.
    fn active_profile(&self) -> Option<&'static OpenAIModelProfile> {
        let auth_path = OpenAIAuthPath::from(&self.config.auth);
        get_openai_model_profile(&self.config.model, auth_path).map(|(_, profile)| profile)
    }

    /// Build HTTP headers for the Responses API request.
    ///
    /// Codex endpoint requires extra headers (`openai-beta`, `openai-originator`,
    /// `chatgpt-account-id`). Platform endpoint uses only standard auth headers.
    fn build_headers(
        tokens: &crate::domains::auth::provider_credentials::OAuthTokens,
        api_endpoint: ApiEndpoint,
    ) -> ProviderResult<HeaderMap> {
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

        if api_endpoint == ApiEndpoint::Codex {
            let _ = headers.insert(
                "openai-beta",
                HeaderValue::from_static("responses=experimental"),
            );
            let _ = headers.insert(
                "openai-originator",
                HeaderValue::from_static("codex_cli_rs"),
            );

            let account_id = extract_account_id(&tokens.access_token);
            if !account_id.is_empty()
                && let Ok(val) = HeaderValue::from_str(&account_id)
            {
                let _ = headers.insert("chatgpt-account-id", val);
            }
        }

        Ok(headers)
    }

    /// Resolve the reasoning effort level from options -> config -> settings -> model default.
    ///
    /// After resolution, clamps to a level the model actually supports.
    fn resolve_reasoning_effort(&self, options: &ProviderStreamOptions) -> String {
        let raw = options
            .reasoning_effort
            .as_ref()
            .map(ReasoningEffort::as_str)
            .or(self.config.reasoning_effort.as_deref())
            .or(self.provider_settings.default_reasoning_effort.as_deref())
            .unwrap_or_else(|| {
                self.active_profile()
                    .map_or("medium", |profile| profile.default_reasoning_level)
            });

        if let Some(profile) = self.active_profile() {
            clamp_reasoning_effort(raw, profile.reasoning_levels)
        } else {
            raw.to_string()
        }
    }

    /// Determine if this is the first turn (no assistant messages in history).
    fn is_first_turn(messages: &[Message]) -> bool {
        !messages
            .iter()
            .any(|m| matches!(m, Message::Assistant { .. }))
    }

    /// Build the Responses API input array from the context.
    ///
    /// Converts messages, prepends execute clarification on the first turn,
    /// and injects primitive context parts as a developer message.
    fn build_input(
        context: &Context,
        include_capability_clarification: bool,
    ) -> Vec<ResponsesInputItem> {
        let mut input = convert_to_responses_input(&context.messages);

        // Prepend execute clarification on first turn before any assistant messages.
        if let Some(ref ctx_capabilities) = context.capabilities
            && include_capability_clarification
            && !ctx_capabilities.is_empty()
            && Self::is_first_turn(&context.messages)
        {
            let clarification = generate_capability_clarification_message(
                ctx_capabilities,
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

        // Inject primitive context parts as a developer message.
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

    /// Whether hosted tool search is available for this provider instance.
    ///
    /// Requires both: the model declares support AND we're on the Platform endpoint.
    /// ModelCapability search is not available on the Codex backend.
    fn model_supports_tool_search(&self) -> bool {
        self.api_endpoint == ApiEndpoint::Platform
            && self
                .active_profile()
                .is_some_and(|profile| profile.supports_tool_search)
    }

    /// Resolve and clamp max output tokens for the active profile.
    fn resolve_max_output_tokens(&self, options: &ProviderStreamOptions) -> Option<u32> {
        let requested = options.max_tokens.or(self.config.max_tokens)?;
        let Some(profile) = self.active_profile() else {
            return Some(requested);
        };
        Some(requested.min(profile.max_output.min(u64::from(u32::MAX)) as u32))
    }

    /// Resolve optional text verbosity controls for the active profile.
    fn resolve_text_config(&self) -> Option<ResponseTextConfig> {
        let profile = self.active_profile()?;
        if !profile.supports_verbosity {
            return None;
        }
        profile
            .default_verbosity
            .map(|verbosity| ResponseTextConfig {
                verbosity: verbosity.to_string(),
            })
    }

    /// Build the full [`ResponsesRequest`] from context and options.
    fn build_request(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ResponsesRequest {
        let reasoning_effort = self.resolve_reasoning_effort(options);
        let active_profile = self.active_profile();
        let supports_capabilities =
            active_profile.is_none_or(|profile| profile.supports_capabilities);
        let input = Self::build_input(context, supports_capabilities);
        let enable_tool_search = self.model_supports_tool_search();
        let capabilities = context
            .capabilities
            .as_ref()
            .filter(|_| supports_capabilities)
            .map(|t| convert_tools_v2(t, enable_tool_search));
        let reasoning = self
            .active_profile()
            .filter(|profile| profile.supports_reasoning)
            .map(|_| ReasoningConfig {
                effort: reasoning_effort,
                summary: "detailed".into(),
            });

        ResponsesRequest {
            model: openai_request_model_id(&self.config.model),
            input,
            instructions: options.provider_instructions.clone(),
            stream: true,
            store: false,
            temperature: options.temperature,
            capabilities,
            max_output_tokens: self.resolve_max_output_tokens(options),
            reasoning,
            text: self.resolve_text_config(),
            prompt_cache_key: options.prompt_cache_key.clone(),
        }
    }

    /// Internal streaming implementation.
    #[instrument(skip_all, fields(model = %self.config.model))]
    async fn stream_internal(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        if let Some(profile) = self.active_profile()
            && !profile.supports_streaming
        {
            return Err(ProviderError::Other {
                message: format!(
                    "OpenAI model '{}' is not supported by Tron's streaming Responses provider",
                    self.config.model
                ),
            });
        }

        debug!(
            model = %self.config.model,
            message_count = context.messages.len(),
            tool_count = context.capabilities.as_ref().map_or(0, Vec::len),
            "Starting OpenAI stream"
        );

        let tokens = self.tokens.lock().await;
        let headers = Self::build_headers(&tokens, self.api_endpoint)?;
        drop(tokens);

        let request = self.build_request(context, options);
        let url = format!("{}{}", self.base_url, self.api_endpoint.path());

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
                body = %body_text,
                retryable = err_info.retryable,
                "OpenAI API error"
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
                ResponsesSseEvent,
                _,
                _,
            >(
                response,
                &SSE_OPTIONS,
                create_stream_state(),
                process_stream_event,
            ),
        )
    }
}

#[async_trait]
impl Provider for OpenAIProvider {
    fn provider_type(&self) -> crate::shared::messages::Provider {
        crate::shared::messages::Provider::OpenAi
    }

    fn model(&self) -> &str {
        &self.config.model
    }

    fn context_window(&self) -> u64 {
        self.active_profile().map_or_else(
            || crate::domains::model::providers::model_context_window(&self.config.model),
            |profile| profile.context_window,
        )
    }

    fn audit_payload(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<serde_json::Value> {
        serde_json::to_value(self.build_request(context, options)).map_err(ProviderError::Json)
    }

    #[instrument(skip_all, fields(provider = "openai", model = %self.config.model))]
    async fn stream(
        &self,
        context: &Context,
        options: &ProviderStreamOptions,
    ) -> ProviderResult<StreamEventStream> {
        debug!(message_count = context.messages.len(), "starting stream");
        self.ensure_valid_tokens().await?;
        crate::domains::model::providers::stream_pipeline::wrap_provider_stream(
            "openai",
            self.stream_internal(context, options).await,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[path = "provider_tests.rs"]
mod tests;
