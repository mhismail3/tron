//! API provider settings.
//!
//! Configuration that changes model-provider behavior at runtime. OAuth
//! endpoints and scopes are deliberately absent: the authentication domain
//! owns those protocol constants, and exposing duplicate settings that no
//! production caller reads would create a false configuration surface.

use serde::{Deserialize, Serialize};

/// Container for all API provider settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ApiSettings {
    /// Anthropic/Claude API settings.
    pub anthropic: AnthropicApiSettings,
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

/// Anthropic model-provider settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AnthropicApiSettings {
    /// OAuth client ID.
    pub client_id: String,
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
            client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e".to_string(),
            system_prompt_prefix:
                "You are Claude Code, Anthropic's official CLI for Claude.".to_string(),
            oauth_beta_headers: "oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14".to_string(),
            token_expiry_buffer_seconds: 300,
        }
    }
}

/// `MiniMax` API settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
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
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
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
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
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
        assert_eq!(
            api.anthropic.client_id,
            "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        );
    }

    #[test]
    fn anthropic_defaults() {
        let a = AnthropicApiSettings::default();
        assert!(!a.client_id.is_empty());
        assert_eq!(a.token_expiry_buffer_seconds, 300);
    }

    #[test]
    fn anthropic_serde_roundtrip() {
        let a = AnthropicApiSettings::default();
        let json = serde_json::to_value(&a).unwrap();
        assert_eq!(json["clientId"], a.client_id);
        assert_eq!(json["tokenExpiryBufferSeconds"], 300);
        let back: AnthropicApiSettings = serde_json::from_value(json).unwrap();
        assert_eq!(back.client_id, a.client_id);
    }

    #[test]
    fn authentication_protocol_fields_are_not_settings() {
        for retired in ["authUrl", "tokenUrl", "redirectUri", "scopes"] {
            let value = serde_json::Value::Object(serde_json::Map::from_iter([(
                retired.to_owned(),
                serde_json::json!("unused"),
            )]));
            assert!(serde_json::from_value::<AnthropicApiSettings>(value).is_err());
        }
    }

    /// Provider settings only accept the current provider-specific fields.
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
    fn unknown_nested_provider_field_rejected() {
        let json = serde_json::json!({
            "anthropic": {
                "clientId": "custom",
                "accidentalSetting": true
            }
        });
        let err = serde_json::from_value::<ApiSettings>(json).unwrap_err();
        assert!(err.to_string().contains("accidentalSetting"));
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
        assert!(json.get("minimax").is_none());
        assert!(json.get("anthropic").is_some());
    }
}
