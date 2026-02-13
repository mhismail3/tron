//! Core authentication types.
//!
//! Mirrors the TypeScript `AuthStorage` schema stored in `~/.tron/auth.json`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// OAuth token set returned by provider token endpoints.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OAuthTokens {
    /// The access token for API requests.
    pub access_token: String,
    /// The refresh token for obtaining new access tokens.
    pub refresh_token: String,
    /// Absolute expiration timestamp in **milliseconds** since Unix epoch.
    pub expires_at: i64,
}

/// A named account with OAuth credentials.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AccountEntry {
    /// Human-readable account label.
    pub label: String,
    /// OAuth tokens for this account.
    pub oauth: OAuthTokens,
}

/// Authentication for a single provider.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAuth {
    /// Legacy single OAuth token set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OAuthTokens>,
    /// API key (fallback auth method).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    /// Named accounts (takes priority over legacy `oauth`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accounts: Option<Vec<AccountEntry>>,
}

/// Google-specific provider auth with endpoint metadata.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleProviderAuth {
    /// Base provider auth fields.
    #[serde(flatten)]
    pub base: ProviderAuth,
    /// OAuth client ID (stored for refresh).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// OAuth client secret (stored for refresh).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_secret: Option<String>,
    /// Which Google endpoint was used for auth.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<GoogleOAuthEndpoint>,
    /// Google Cloud project ID (required for Cloud Code Assist).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
}

/// Google OAuth endpoint variant.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GoogleOAuthEndpoint {
    /// Production Cloud Code Assist.
    CloudCodeAssist,
    /// Free tier / sandbox.
    Antigravity,
}

/// API key auth for external services.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceAuth {
    /// Single API key (legacy).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    /// Multiple API keys (takes precedence over single).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_keys: Option<Vec<String>>,
}

/// Top-level auth storage schema (`~/.tron/auth.json`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthStorage {
    /// Schema version (always 1).
    pub version: u32,
    /// Per-provider auth configuration.
    pub providers: HashMap<String, serde_json::Value>,
    /// Per-service API key configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub services: Option<HashMap<String, ServiceAuth>>,
    /// ISO 8601 timestamp of last update.
    pub last_updated: String,
}

impl AuthStorage {
    /// Create a new empty auth storage.
    pub fn new() -> Self {
        Self {
            version: 1,
            providers: HashMap::new(),
            services: None,
            last_updated: chrono::Utc::now().to_rfc3339(),
        }
    }

    /// Get typed provider auth for a given provider ID.
    pub fn get_provider_auth(&self, provider: &str) -> Option<ProviderAuth> {
        self.providers
            .get(provider)
            .and_then(|v| serde_json::from_value(v.clone()).ok())
    }

    /// Get Google-specific provider auth.
    pub fn get_google_auth(&self) -> Option<GoogleProviderAuth> {
        self.providers
            .get("google")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
    }

    /// Set provider auth.
    pub fn set_provider_auth(&mut self, provider: &str, auth: &ProviderAuth) {
        if let Ok(v) = serde_json::to_value(auth) {
            let _ = self.providers.insert(provider.to_string(), v);
        }
    }

    /// Set Google-specific provider auth.
    pub fn set_google_auth(&mut self, auth: &GoogleProviderAuth) {
        if let Ok(v) = serde_json::to_value(auth) {
            let _ = self.providers.insert("google".to_string(), v);
        }
    }

    /// Get service auth for a given service ID.
    pub fn get_service_auth(&self, service: &str) -> Option<&ServiceAuth> {
        self.services.as_ref()?.get(service)
    }

    /// Get API keys for a service (prefers `api_keys` over single `api_key`).
    pub fn get_service_api_keys(&self, service: &str) -> Vec<String> {
        let Some(svc) = self.get_service_auth(service) else {
            return Vec::new();
        };
        if let Some(keys) = &svc.api_keys {
            if !keys.is_empty() {
                return keys.clone();
            }
        }
        if let Some(key) = &svc.api_key {
            return vec![key.clone()];
        }
        Vec::new()
    }
}

impl Default for AuthStorage {
    fn default() -> Self {
        Self::new()
    }
}

/// Runtime auth state for server operations.
///
/// Discriminated union: either OAuth-based or API-key-based auth.
#[derive(Clone, Debug)]
pub enum ServerAuth {
    /// OAuth-based authentication.
    OAuth {
        /// Access token for API requests.
        access_token: String,
        /// Refresh token for renewal.
        refresh_token: String,
        /// Expiration timestamp in milliseconds.
        expires_at: i64,
        /// Account label (for multi-account).
        account_label: Option<String>,
    },
    /// API-key-based authentication.
    ApiKey {
        /// The API key.
        api_key: String,
    },
}

impl ServerAuth {
    /// Create from OAuth tokens.
    pub fn from_oauth(tokens: &OAuthTokens, account_label: Option<String>) -> Self {
        Self::OAuth {
            access_token: tokens.access_token.clone(),
            refresh_token: tokens.refresh_token.clone(),
            expires_at: tokens.expires_at,
            account_label,
        }
    }

    /// Create from an API key.
    pub fn from_api_key(key: impl Into<String>) -> Self {
        Self::ApiKey {
            api_key: key.into(),
        }
    }

    /// Get the access token (for OAuth) or API key.
    pub fn token(&self) -> &str {
        match self {
            Self::OAuth { access_token, .. } => access_token,
            Self::ApiKey { api_key } => api_key,
        }
    }

    /// Check if this is OAuth auth.
    pub fn is_oauth(&self) -> bool {
        matches!(self, Self::OAuth { .. })
    }
}

/// Google-specific runtime auth.
#[derive(Clone, Debug)]
pub struct GoogleAuth {
    /// Base server auth.
    pub auth: ServerAuth,
    /// Which Google endpoint.
    pub endpoint: Option<GoogleOAuthEndpoint>,
    /// API base URL.
    pub api_endpoint: Option<String>,
    /// API version string.
    pub api_version: Option<String>,
    /// Google Cloud project ID.
    pub project_id: Option<String>,
}

/// OAuth configuration for a provider.
#[derive(Clone, Debug)]
pub struct OAuthConfig {
    /// Authorization URL for browser redirect.
    pub auth_url: String,
    /// Token exchange URL.
    pub token_url: String,
    /// OAuth redirect URI.
    pub redirect_uri: String,
    /// OAuth client ID.
    pub client_id: String,
    /// OAuth client secret (Google only).
    pub client_secret: Option<String>,
    /// OAuth scopes.
    pub scopes: Vec<String>,
    /// Buffer in seconds before expiry to trigger refresh.
    pub token_expiry_buffer_seconds: i64,
}

/// Current system time in milliseconds since Unix epoch.
pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// Check if OAuth tokens need refreshing.
pub fn should_refresh(tokens: &OAuthTokens, buffer_ms: i64) -> bool {
    now_ms() + buffer_ms >= tokens.expires_at
}

/// Calculate expiration timestamp from `expires_in` seconds.
pub fn calculate_expires_at(expires_in_seconds: i64, buffer_seconds: i64) -> i64 {
    now_ms() + (expires_in_seconds - buffer_seconds) * 1000
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oauth_tokens_serde_roundtrip() {
        let tokens = OAuthTokens {
            access_token: "sk-ant-oat-abc123".to_string(),
            refresh_token: "sk-ant-srt-xyz789".to_string(),
            expires_at: 1_700_000_000_000,
        };
        let json = serde_json::to_string(&tokens).unwrap();
        let back: OAuthTokens = serde_json::from_str(&json).unwrap();
        assert_eq!(back.access_token, "sk-ant-oat-abc123");
        assert_eq!(back.expires_at, 1_700_000_000_000);
    }

    #[test]
    fn oauth_tokens_camel_case() {
        let json = r#"{"accessToken":"tok","refreshToken":"ref","expiresAt":123}"#;
        let tokens: OAuthTokens = serde_json::from_str(json).unwrap();
        assert_eq!(tokens.access_token, "tok");
        assert_eq!(tokens.refresh_token, "ref");
        assert_eq!(tokens.expires_at, 123);
    }

    #[test]
    fn provider_auth_empty() {
        let pa = ProviderAuth::default();
        assert!(pa.oauth.is_none());
        assert!(pa.api_key.is_none());
        assert!(pa.accounts.is_none());
    }

    #[test]
    fn provider_auth_with_api_key() {
        let json = r#"{"apiKey":"sk-123"}"#;
        let pa: ProviderAuth = serde_json::from_str(json).unwrap();
        assert_eq!(pa.api_key.as_deref(), Some("sk-123"));
        assert!(pa.oauth.is_none());
    }

    #[test]
    fn provider_auth_with_accounts() {
        let json = r#"{"accounts":[{"label":"work","oauth":{"accessToken":"a","refreshToken":"r","expiresAt":0}}]}"#;
        let pa: ProviderAuth = serde_json::from_str(json).unwrap();
        let accounts = pa.accounts.unwrap();
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].label, "work");
    }

    #[test]
    fn google_provider_auth_serde() {
        let json = r#"{
            "oauth": {"accessToken":"ya29.abc","refreshToken":"r","expiresAt":0},
            "clientId": "cid",
            "clientSecret": "csec",
            "endpoint": "cloud-code-assist",
            "projectId": "my-project"
        }"#;
        let gpa: GoogleProviderAuth = serde_json::from_str(json).unwrap();
        assert_eq!(gpa.client_id.as_deref(), Some("cid"));
        assert_eq!(gpa.endpoint, Some(GoogleOAuthEndpoint::CloudCodeAssist));
        assert_eq!(gpa.project_id.as_deref(), Some("my-project"));
    }

    #[test]
    fn google_endpoint_serde() {
        let cca = serde_json::to_string(&GoogleOAuthEndpoint::CloudCodeAssist).unwrap();
        assert_eq!(cca, "\"cloud-code-assist\"");
        let ag = serde_json::to_string(&GoogleOAuthEndpoint::Antigravity).unwrap();
        assert_eq!(ag, "\"antigravity\"");

        let back: GoogleOAuthEndpoint = serde_json::from_str("\"antigravity\"").unwrap();
        assert_eq!(back, GoogleOAuthEndpoint::Antigravity);
    }

    #[test]
    fn service_auth_keys_priority() {
        let mut storage = AuthStorage::new();
        let mut services = HashMap::new();
        let _ = services.insert(
            "brave".to_string(),
            ServiceAuth {
                api_key: Some("single".to_string()),
                api_keys: Some(vec!["multi1".to_string(), "multi2".to_string()]),
            },
        );
        storage.services = Some(services);

        let keys = storage.get_service_api_keys("brave");
        assert_eq!(keys, vec!["multi1", "multi2"]);
    }

    #[test]
    fn service_auth_single_key_fallback() {
        let mut storage = AuthStorage::new();
        let mut services = HashMap::new();
        let _ = services.insert(
            "exa".to_string(),
            ServiceAuth {
                api_key: Some("single".to_string()),
                api_keys: None,
            },
        );
        storage.services = Some(services);

        let keys = storage.get_service_api_keys("exa");
        assert_eq!(keys, vec!["single"]);
    }

    #[test]
    fn service_auth_missing_returns_empty() {
        let storage = AuthStorage::new();
        assert!(storage.get_service_api_keys("nonexistent").is_empty());
    }

    #[test]
    fn auth_storage_roundtrip() {
        let mut storage = AuthStorage::new();
        let pa = ProviderAuth {
            api_key: Some("sk-123".to_string()),
            ..Default::default()
        };
        storage.set_provider_auth("anthropic", &pa);

        let json = serde_json::to_string(&storage).unwrap();
        let back: AuthStorage = serde_json::from_str(&json).unwrap();
        assert_eq!(back.version, 1);
        let restored = back.get_provider_auth("anthropic").unwrap();
        assert_eq!(restored.api_key.as_deref(), Some("sk-123"));
    }

    #[test]
    fn auth_storage_get_google_auth() {
        let mut storage = AuthStorage::new();
        let gpa = GoogleProviderAuth {
            endpoint: Some(GoogleOAuthEndpoint::Antigravity),
            project_id: Some("proj".to_string()),
            ..Default::default()
        };
        storage.set_google_auth(&gpa);

        let restored = storage.get_google_auth().unwrap();
        assert_eq!(restored.endpoint, Some(GoogleOAuthEndpoint::Antigravity));
        assert_eq!(restored.project_id.as_deref(), Some("proj"));
    }

    #[test]
    fn server_auth_oauth() {
        let tokens = OAuthTokens {
            access_token: "tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: 999,
        };
        let sa = ServerAuth::from_oauth(&tokens, Some("work".to_string()));
        assert!(sa.is_oauth());
        assert_eq!(sa.token(), "tok");
    }

    #[test]
    fn server_auth_api_key() {
        let sa = ServerAuth::from_api_key("sk-123");
        assert!(!sa.is_oauth());
        assert_eq!(sa.token(), "sk-123");
    }

    #[test]
    fn should_refresh_expired() {
        let tokens = OAuthTokens {
            access_token: "tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: 0,
        };
        assert!(should_refresh(&tokens, 0));
    }

    #[test]
    fn should_refresh_with_buffer() {
        let tokens = OAuthTokens {
            access_token: "tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 60_000, // 60s from now
        };
        // With 120s buffer (120_000ms), should need refresh
        assert!(should_refresh(&tokens, 120_000));
        // With 0 buffer, should NOT need refresh
        assert!(!should_refresh(&tokens, 0));
    }

    #[test]
    fn calculate_expires_at_basic() {
        let before = now_ms();
        let result = calculate_expires_at(3600, 300);
        let after = now_ms();

        // Should be approximately now + (3600 - 300) * 1000 = now + 3_300_000
        assert!(result >= before + 3_300_000);
        assert!(result <= after + 3_300_000);
    }

    #[test]
    fn now_ms_is_reasonable() {
        let ms = now_ms();
        // Should be after 2024-01-01 and before 2100-01-01
        assert!(ms > 1_704_067_200_000);
        assert!(ms < 4_102_444_800_000);
    }
}
