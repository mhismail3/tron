//! API provider settings.
//!
//! Configuration for LLM provider endpoints. Cloud providers (Anthropic,
//! `OpenAI`) have OAuth URLs, client IDs, and scopes. Local providers
//! (Ollama) only need a base URL.

use serde::{Deserialize, Serialize};

/// Container for all API provider settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ApiSettings {
    /// Anthropic/Claude API settings.
    pub anthropic: AnthropicApiSettings,
    /// `OpenAI` Codex API settings (optional — absent if not configured).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub openai_codex: Option<OpenAiCodexApiSettings>,
    /// `MiniMax` API settings (optional — absent if not configured).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minimax: Option<MiniMaxApiSettings>,
    /// Kimi API settings (optional — absent if not configured).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kimi: Option<KimiApiSettings>,
    /// Ollama API settings (optional — absent if not configured).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ollama: Option<OllamaApiSettings>,
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

/// `MiniMax` API settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MiniMaxApiSettings {
    /// Base URL for the `MiniMax` Anthropic-compatible API.
    pub base_url: String,
}

impl Default for MiniMaxApiSettings {
    fn default() -> Self {
        Self {
            base_url: "https://api.minimax.io/anthropic".to_string(),
        }
    }
}

/// Kimi (Moonshot AI) API settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KimiApiSettings {
    /// Base URL for the Kimi API.
    pub base_url: String,
}

impl Default for KimiApiSettings {
    fn default() -> Self {
        Self {
            base_url: "https://api.moonshot.ai/v1".to_string(),
        }
    }
}

/// Ollama API settings (local models via Ollama).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OllamaApiSettings {
    /// Base URL for the Ollama API (default: `http://localhost:11434`).
    pub base_url: String,
}

impl Default for OllamaApiSettings {
    fn default() -> Self {
        Self {
            base_url: "http://localhost:11434".to_string(),
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

    /// R1: retired `google` field was removed and `deny_unknown_fields` was
    /// added — any profile settings payload that still carries `google: {...}` must
    /// fail to load with an error naming the unknown field.
    #[test]
    fn google_field_rejected_on_load() {
        let json = serde_json::json!({
            "anthropic": {},
            "google": {
                "clientId": "ignored"
            }
        });
        let err = serde_json::from_value::<ApiSettings>(json).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("google"),
            "error should name the unknown `google` field, got: {msg}"
        );
    }

    /// Companion to `google_field_rejected_on_load`: totally-unknown fields
    /// also fail, guarding against future tolerant parser branches.
    #[test]
    fn unknown_provider_field_rejected() {
        let json = serde_json::json!({
            "anthropic": {},
            "someFutureProvider": {}
        });
        assert!(serde_json::from_value::<ApiSettings>(json).is_err());
    }

    #[test]
    fn api_settings_minimax_optional() {
        let api = ApiSettings::default();
        assert!(api.minimax.is_none());
    }

    #[test]
    fn api_settings_minimax_serde() {
        let json = serde_json::json!({
            "anthropic": {},
            "minimax": {
                "baseUrl": "https://custom.minimax.io/anthropic"
            }
        });
        let api: ApiSettings = serde_json::from_value(json).unwrap();
        assert!(api.minimax.is_some());
        assert_eq!(
            api.minimax.unwrap().base_url,
            "https://custom.minimax.io/anthropic"
        );
    }

    #[test]
    fn minimax_defaults() {
        let m = MiniMaxApiSettings::default();
        assert!(m.base_url.starts_with("https://api.minimax.io"));
    }

    #[test]
    fn api_settings_kimi_optional() {
        let api = ApiSettings::default();
        assert!(api.kimi.is_none());
    }

    #[test]
    fn api_settings_kimi_serde() {
        let json = serde_json::json!({
            "anthropic": {},
            "kimi": {
                "baseUrl": "https://custom.moonshot.ai/v1"
            }
        });
        let api: ApiSettings = serde_json::from_value(json).unwrap();
        assert!(api.kimi.is_some());
        assert_eq!(api.kimi.unwrap().base_url, "https://custom.moonshot.ai/v1");
    }

    #[test]
    fn kimi_defaults() {
        let k = KimiApiSettings::default();
        assert!(k.base_url.starts_with("https://api.moonshot.ai"));
    }

    #[test]
    fn api_settings_ollama_optional() {
        let api = ApiSettings::default();
        assert!(api.ollama.is_none());
    }

    #[test]
    fn api_settings_ollama_serde() {
        let json = serde_json::json!({
            "anthropic": {},
            "ollama": {
                "baseUrl": "http://192.168.1.100:11434"
            }
        });
        let api: ApiSettings = serde_json::from_value(json).unwrap();
        assert!(api.ollama.is_some());
        assert_eq!(api.ollama.unwrap().base_url, "http://192.168.1.100:11434");
    }

    #[test]
    fn ollama_defaults() {
        let o = OllamaApiSettings::default();
        assert_eq!(o.base_url, "http://localhost:11434");
    }

    #[test]
    fn api_settings_omits_null_sections() {
        let api = ApiSettings::default();
        let json = serde_json::to_value(&api).unwrap();
        assert!(json.get("openaiCodex").is_none());
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
