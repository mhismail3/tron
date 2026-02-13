//! API provider settings.
//!
//! Configuration for LLM provider authentication endpoints (Anthropic, `OpenAI`,
//! Google). Each provider has its own OAuth URLs, client IDs, and scopes.

use serde::{Deserialize, Serialize};

/// Container for all API provider settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ApiSettings {
    /// Anthropic/Claude API settings.
    pub anthropic: AnthropicApiSettings,
    /// `OpenAI` Codex API settings (optional — absent if not configured).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub openai_codex: Option<OpenAiCodexApiSettings>,
    /// Google Gemini API settings (optional — absent if not configured).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub google: Option<GoogleApiSettings>,
}

/// Anthropic API and OAuth settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AnthropicApiSettings {
    /// OAuth authorization URL.
    pub auth_url: String,
    /// OAuth token exchange URL.
    pub token_url: String,
    /// OAuth redirect URI.
    pub redirect_uri: String,
    /// OAuth client ID.
    pub client_id: String,
    /// OAuth scopes requested.
    pub scopes: Vec<String>,
    /// System prompt prefix for OAuth-authenticated requests.
    pub system_prompt_prefix: String,
    /// Beta headers sent with OAuth requests.
    pub oauth_beta_headers: String,
    /// Seconds before token expiry to trigger refresh.
    pub token_expiry_buffer_seconds: u64,
}

impl Default for AnthropicApiSettings {
    fn default() -> Self {
        Self {
            auth_url: "https://claude.ai/oauth/authorize".to_string(),
            token_url: "https://console.anthropic.com/v1/oauth/token".to_string(),
            redirect_uri: "https://console.anthropic.com/oauth/code/callback".to_string(),
            client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e".to_string(),
            scopes: vec![
                "org:create_api_key".to_string(),
                "user:profile".to_string(),
                "user:inference".to_string(),
            ],
            system_prompt_prefix:
                "You are Claude Code, Anthropic's official CLI for Claude.".to_string(),
            oauth_beta_headers: "oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14".to_string(),
            token_expiry_buffer_seconds: 300,
        }
    }
}

/// Default reasoning effort for `OpenAI` models.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReasoningEffort {
    /// Low reasoning effort.
    Low,
    /// Medium reasoning effort.
    #[default]
    Medium,
    /// High reasoning effort.
    High,
    /// Extra-high reasoning effort.
    Xhigh,
}

/// `OpenAI` Codex API and OAuth settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OpenAiCodexApiSettings {
    /// OAuth authorization URL.
    pub auth_url: String,
    /// OAuth token exchange URL.
    pub token_url: String,
    /// OAuth client ID.
    pub client_id: String,
    /// OAuth scopes requested.
    pub scopes: Vec<String>,
    /// Base URL for the API.
    pub base_url: String,
    /// Seconds before token expiry to trigger refresh.
    pub token_expiry_buffer_seconds: u64,
    /// Default reasoning effort level.
    pub default_reasoning_effort: ReasoningEffort,
}

impl Default for OpenAiCodexApiSettings {
    fn default() -> Self {
        Self {
            auth_url: "https://auth.openai.com/oauth/authorize".to_string(),
            token_url: "https://auth.openai.com/oauth/token".to_string(),
            client_id: "app_EMoamEEZ73f0CkXaXp7hrann".to_string(),
            scopes: vec![
                "openid".to_string(),
                "profile".to_string(),
                "email".to_string(),
                "offline_access".to_string(),
            ],
            base_url: "https://chatgpt.com/backend-api".to_string(),
            token_expiry_buffer_seconds: 300,
            default_reasoning_effort: ReasoningEffort::Medium,
        }
    }
}

/// Google API endpoint variant.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum GoogleEndpoint {
    /// Cloud Code Assist (production).
    #[default]
    #[serde(rename = "cloud-code-assist")]
    CloudCodeAssist,
    /// Antigravity (sandbox/free tier).
    #[serde(rename = "antigravity")]
    Antigravity,
}

/// Google Gemini API and OAuth settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GoogleApiSettings {
    /// OAuth authorization URL.
    pub auth_url: String,
    /// OAuth token exchange URL.
    pub token_url: String,
    /// OAuth scopes requested.
    pub scopes: Vec<String>,
    /// OAuth redirect URI.
    pub redirect_uri: String,
    /// Seconds before token expiry to trigger refresh.
    pub token_expiry_buffer_seconds: u64,
    /// API endpoint base URL.
    pub api_endpoint: String,
    /// API version string.
    pub api_version: String,
    /// Which Google endpoint to use.
    pub default_endpoint: GoogleEndpoint,
}

impl Default for GoogleApiSettings {
    fn default() -> Self {
        Self {
            auth_url: "https://accounts.google.com/o/oauth2/v2/auth".to_string(),
            token_url: "https://oauth2.googleapis.com/token".to_string(),
            scopes: vec![
                "https://www.googleapis.com/auth/cloud-platform".to_string(),
                "https://www.googleapis.com/auth/userinfo.email".to_string(),
                "openid".to_string(),
            ],
            redirect_uri: "http://localhost:45289".to_string(),
            token_expiry_buffer_seconds: 300,
            api_endpoint: "https://cloudcode-pa.googleapis.com".to_string(),
            api_version: "v1internal".to_string(),
            default_endpoint: GoogleEndpoint::CloudCodeAssist,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_defaults() {
        let api = ApiSettings::default();
        assert!(api.openai_codex.is_none());
        assert!(api.google.is_none());
        assert_eq!(
            api.anthropic.client_id,
            "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        );
    }

    #[test]
    fn anthropic_defaults() {
        let a = AnthropicApiSettings::default();
        assert_eq!(a.auth_url, "https://claude.ai/oauth/authorize");
        assert_eq!(a.token_expiry_buffer_seconds, 300);
        assert_eq!(a.scopes.len(), 3);
    }

    #[test]
    fn anthropic_serde_roundtrip() {
        let a = AnthropicApiSettings::default();
        let json = serde_json::to_value(&a).unwrap();
        assert_eq!(json["authUrl"], "https://claude.ai/oauth/authorize");
        assert_eq!(json["tokenExpiryBufferSeconds"], 300);
        let back: AnthropicApiSettings = serde_json::from_value(json).unwrap();
        assert_eq!(back.auth_url, a.auth_url);
    }

    #[test]
    fn openai_codex_defaults() {
        let o = OpenAiCodexApiSettings::default();
        assert_eq!(o.client_id, "app_EMoamEEZ73f0CkXaXp7hrann");
        assert_eq!(o.default_reasoning_effort, ReasoningEffort::Medium);
    }

    #[test]
    fn reasoning_effort_serde() {
        let json = serde_json::to_string(&ReasoningEffort::Xhigh).unwrap();
        assert_eq!(json, "\"xhigh\"");
        let back: ReasoningEffort = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ReasoningEffort::Xhigh);
    }

    #[test]
    fn google_endpoint_serde() {
        let json = serde_json::to_string(&GoogleEndpoint::CloudCodeAssist).unwrap();
        assert_eq!(json, "\"cloud-code-assist\"");
        let back: GoogleEndpoint = serde_json::from_str(&json).unwrap();
        assert_eq!(back, GoogleEndpoint::CloudCodeAssist);

        let json2 = serde_json::to_string(&GoogleEndpoint::Antigravity).unwrap();
        assert_eq!(json2, "\"antigravity\"");
    }

    #[test]
    fn google_defaults() {
        let g = GoogleApiSettings::default();
        assert_eq!(g.default_endpoint, GoogleEndpoint::CloudCodeAssist);
        assert_eq!(g.redirect_uri, "http://localhost:45289");
    }

    #[test]
    fn api_settings_omits_null_sections() {
        let api = ApiSettings::default();
        let json = serde_json::to_value(&api).unwrap();
        assert!(json.get("openaiCodex").is_none());
        assert!(json.get("google").is_none());
        assert!(json.get("anthropic").is_some());
    }

    #[test]
    fn api_settings_with_optional_providers() {
        let json = serde_json::json!({
            "anthropic": {},
            "openaiCodex": {
                "clientId": "custom-id"
            }
        });
        let api: ApiSettings = serde_json::from_value(json).unwrap();
        assert!(api.openai_codex.is_some());
        assert_eq!(api.openai_codex.unwrap().client_id, "custom-id");
    }
}
