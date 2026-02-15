use secrecy::SecretString;
use serde::{Deserialize, Serialize};

/// Wraps an API key with secrecy protection (zeroized on drop, redacted in Debug).
#[derive(Clone)]
pub struct ApiKey(pub SecretString);

impl std::fmt::Debug for ApiKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ApiKey([REDACTED])")
    }
}

/// OAuth tokens with secrecy protection.
#[derive(Clone)]
pub struct OAuthTokens {
    pub access_token: SecretString,
    pub refresh_token: SecretString,
    /// Unix timestamp in milliseconds when access_token expires.
    pub expires_at: i64,
}

impl std::fmt::Debug for OAuthTokens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OAuthTokens")
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

/// How we authenticate with a provider.
#[derive(Clone, Debug)]
pub enum AuthMethod {
    ApiKey(ApiKey),
    OAuth(OAuthTokens),
}

/// Supported LLM providers.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum ProviderType {
    #[default]
    Anthropic,
    OpenAI,
    Google,
}

impl std::fmt::Display for ProviderType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Anthropic => f.write_str("anthropic"),
            Self::OpenAI => f.write_str("openai"),
            Self::Google => f.write_str("google"),
        }
    }
}

// --- OAuth Config Types (all 3 providers, verbatim from TS) ---

pub struct AnthropicOAuthConfig {
    pub auth_url: &'static str,
    pub token_url: &'static str,
    pub redirect_uri: &'static str,
    pub client_id: &'static str,
    pub scopes: &'static [&'static str],
    pub system_prompt_prefix: &'static str,
    pub oauth_beta_headers: &'static str,
    pub token_expiry_buffer_seconds: u64,
}

pub const ANTHROPIC_OAUTH: AnthropicOAuthConfig = AnthropicOAuthConfig {
    auth_url: "https://claude.ai/oauth/authorize",
    token_url: "https://console.anthropic.com/v1/oauth/token",
    redirect_uri: "https://console.anthropic.com/oauth/code/callback",
    client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    scopes: &["org:create_api_key", "user:profile", "user:inference"],
    system_prompt_prefix: "You are Claude Code, Anthropic's official CLI for Claude.",
    oauth_beta_headers: "oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14",
    token_expiry_buffer_seconds: 300,
};

pub struct OpenAIOAuthConfig {
    pub auth_url: &'static str,
    pub token_url: &'static str,
    pub client_id: &'static str,
    pub scopes: &'static [&'static str],
    pub base_url: &'static str,
    pub token_expiry_buffer_seconds: u64,
    pub default_reasoning_effort: &'static str,
    pub originator: &'static str,
    pub beta_header: &'static str,
}

pub const OPENAI_OAUTH: OpenAIOAuthConfig = OpenAIOAuthConfig {
    auth_url: "https://auth.openai.com/oauth/authorize",
    token_url: "https://auth.openai.com/oauth/token",
    client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
    scopes: &["openid", "profile", "email", "offline_access"],
    base_url: "https://chatgpt.com/backend-api",
    token_expiry_buffer_seconds: 300,
    default_reasoning_effort: "medium",
    originator: "codex_cli_rs",
    beta_header: "responses=experimental",
};

pub struct GoogleOAuthConfig {
    pub auth_url: &'static str,
    pub token_url: &'static str,
    pub scopes_cloud_code: &'static [&'static str],
    pub scopes_antigravity: &'static [&'static str],
    pub redirect_uri_cloud_code: &'static str,
    pub redirect_uri_antigravity: &'static str,
    pub api_endpoint_cloud_code: &'static str,
    pub api_endpoint_antigravity: &'static str,
    pub api_version: &'static str,
    pub antigravity_default_project: &'static str,
    pub token_expiry_buffer_seconds: u64,
}

pub const GOOGLE_OAUTH: GoogleOAuthConfig = GoogleOAuthConfig {
    auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: "https://oauth2.googleapis.com/token",
    scopes_cloud_code: &[
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "openid",
    ],
    scopes_antigravity: &[
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "openid",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ],
    redirect_uri_cloud_code: "http://localhost:45289",
    redirect_uri_antigravity: "http://localhost:51121/oauth-callback",
    api_endpoint_cloud_code: "https://cloudcode-pa.googleapis.com",
    api_endpoint_antigravity: "https://daily-cloudcode-pa.sandbox.googleapis.com",
    api_version: "v1internal",
    antigravity_default_project: "rising-fact-p41fc",
    token_expiry_buffer_seconds: 300,
};

/// Environment variable names for each provider.
pub mod env_vars {
    pub const CLAUDE_CODE_OAUTH_TOKEN: &str = "CLAUDE_CODE_OAUTH_TOKEN";
    pub const ANTHROPIC_API_KEY: &str = "ANTHROPIC_API_KEY";
    pub const OPENAI_OAUTH_TOKEN: &str = "OPENAI_OAUTH_TOKEN";
    pub const OPENAI_API_KEY: &str = "OPENAI_API_KEY";
    pub const GOOGLE_OAUTH_TOKEN: &str = "GOOGLE_OAUTH_TOKEN";
    pub const GOOGLE_API_KEY: &str = "GOOGLE_API_KEY";
    pub const GEMINI_API_KEY: &str = "GEMINI_API_KEY";
    pub const GOOGLE_CLOUD_PROJECT: &str = "GOOGLE_CLOUD_PROJECT";
}

#[cfg(test)]
mod tests {
    use super::*;
    use secrecy::ExposeSecret;

    #[test]
    fn provider_type_display() {
        assert_eq!(ProviderType::Anthropic.to_string(), "anthropic");
        assert_eq!(ProviderType::OpenAI.to_string(), "openai");
        assert_eq!(ProviderType::Google.to_string(), "google");
    }

    #[test]
    fn provider_type_serde() {
        let json = serde_json::to_string(&ProviderType::Anthropic).unwrap();
        assert_eq!(json, r#""anthropic""#);
        let parsed: ProviderType = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, ProviderType::Anthropic);
    }

    #[test]
    fn api_key_debug_redacted() {
        let key = ApiKey(SecretString::from("sk-ant-12345"));
        let debug = format!("{:?}", key);
        assert!(!debug.contains("sk-ant"), "key leaked in debug: {debug}");
        assert!(debug.contains("REDACTED"));
    }

    #[test]
    fn oauth_tokens_debug_redacted() {
        let tokens = OAuthTokens {
            access_token: SecretString::from("access-secret"),
            refresh_token: SecretString::from("refresh-secret"),
            expires_at: 1700000000000,
        };
        let debug = format!("{:?}", tokens);
        assert!(!debug.contains("access-secret"), "token leaked: {debug}");
        assert!(!debug.contains("refresh-secret"), "token leaked: {debug}");
    }

    #[test]
    fn api_key_expose_secret() {
        let key = ApiKey(SecretString::from("sk-ant-12345"));
        assert_eq!(key.0.expose_secret(), "sk-ant-12345");
    }

    #[test]
    fn anthropic_oauth_config_values() {
        assert_eq!(ANTHROPIC_OAUTH.client_id, "9d1c250a-e61b-44d9-88ed-5944d1962f5e");
        assert_eq!(ANTHROPIC_OAUTH.token_expiry_buffer_seconds, 300);
        assert_eq!(ANTHROPIC_OAUTH.scopes.len(), 3);
    }

    #[test]
    fn openai_oauth_config_values() {
        assert_eq!(OPENAI_OAUTH.client_id, "app_EMoamEEZ73f0CkXaXp7hrann");
        assert_eq!(OPENAI_OAUTH.originator, "codex_cli_rs");
    }

    #[test]
    fn google_oauth_config_values() {
        assert_eq!(GOOGLE_OAUTH.antigravity_default_project, "rising-fact-p41fc");
        assert_eq!(GOOGLE_OAUTH.api_version, "v1internal");
        assert!(GOOGLE_OAUTH.scopes_antigravity.len() > GOOGLE_OAUTH.scopes_cloud_code.len());
    }
}
