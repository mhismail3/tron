//! OpenAI endpoint, auth, and provider configuration types.

use serde::{Deserialize, Serialize};

use crate::domains::auth::credentials::OpenAIAuthPath;

/// Default base URL for the `OpenAI` Codex API.
pub const DEFAULT_BASE_URL: &str = "https://chatgpt.com/backend-api";

/// Default base URL for the `OpenAI` Platform API.
pub const DEFAULT_PLATFORM_BASE_URL: &str = "https://api.openai.com";

/// Default model.
pub const DEFAULT_MODEL: &str = "gpt-5.5";

/// Default max output tokens for unknown models.
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 128_000;

/// Maximum length for capability result output strings (16 KB).
///
/// The Codex endpoint has a per-output size limit. Results exceeding this
/// threshold are truncated with a `[truncated]` marker.
pub const TOOL_RESULT_MAX_LENGTH: usize = 16_384;

// ─────────────────────────────────────────────────────────────────────────────
// API Endpoint
// ─────────────────────────────────────────────────────────────────────────────

/// Which `OpenAI` API endpoint a resolved auth path targets.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApiEndpoint {
    /// `ChatGPT` Codex backend (`chatgpt.com/backend-api/codex/responses`).
    #[default]
    Codex,
    /// Standard Platform API (`api.openai.com/v1/responses`).
    Platform,
}

impl ApiEndpoint {
    /// Default base URL for this endpoint.
    #[must_use]
    pub fn default_base_url(self) -> &'static str {
        match self {
            Self::Codex => DEFAULT_BASE_URL,
            Self::Platform => DEFAULT_PLATFORM_BASE_URL,
        }
    }

    /// URL path suffix for this endpoint.
    #[must_use]
    pub fn path(self) -> &'static str {
        match self {
            Self::Codex => "/codex/responses",
            Self::Platform => "/v1/responses",
        }
    }
}

/// Endpoint used by an auth-owned OpenAI credential path.
#[must_use]
pub(crate) fn api_endpoint_for_auth_path(auth_path: OpenAIAuthPath) -> ApiEndpoint {
    match auth_path {
        OpenAIAuthPath::PlatformApiKey => ApiEndpoint::Platform,
        OpenAIAuthPath::ChatGptCodex => ApiEndpoint::Codex,
    }
}

impl From<&OpenAIAuth> for OpenAIAuthPath {
    fn from(auth: &OpenAIAuth) -> Self {
        match auth {
            OpenAIAuth::OAuth { .. } => Self::ChatGptCodex,
            OpenAIAuth::ApiKey { .. } => Self::PlatformApiKey,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Authentication
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` authentication.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum OpenAIAuth {
    /// OAuth authentication (Codex endpoint).
    #[serde(rename = "oauth")]
    OAuth {
        /// OAuth tokens.
        tokens: crate::domains::auth::credentials::OAuthTokens,
    },
    /// API key authentication (Platform endpoint).
    #[serde(rename = "api_key")]
    ApiKey {
        /// API key.
        api_key: String,
    },
}

/// `OpenAI` API settings (optional overrides).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIApiSettings {
    /// Base URL override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Token URL for OAuth refresh.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_url: Option<String>,
    /// OAuth client ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// Default reasoning effort.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` provider configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIConfig {
    /// Model ID.
    pub model: String,
    /// Authentication.
    pub auth: OpenAIAuth,
    /// Max output tokens override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    /// Temperature override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Base URL override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Reasoning effort override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    /// Provider-specific settings.
    #[serde(default)]
    pub provider_settings: OpenAIApiSettings,
}
