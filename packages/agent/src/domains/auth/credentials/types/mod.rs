//! Core authentication types.
//!
//! Mirrors the TypeScript `AuthStorage` schema stored in `~/.tron/profiles/auth.json`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::errors::AuthError;

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

/// A named API key entry.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ApiKeyEntry {
    /// Human-readable label (e.g., "work", "personal").
    pub label: String,
    /// The API key value.
    pub key: String,
}

/// Which credential is currently active for a provider.
///
/// Serializes as `{"type":"oauth","label":"personal"}` or
/// `{"type":"apiKey","label":"work"}`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ActiveCredential {
    /// An OAuth account identified by label.
    #[serde(rename = "oauth")]
    OAuth {
        /// The account label (e.g., "personal").
        label: String,
    },
    /// A named API key identified by label.
    #[serde(rename = "apiKey")]
    ApiKey {
        /// The API key label (e.g., "work").
        label: String,
    },
}

/// Which `OpenAI` authentication path is active.
///
/// Auth owns this decision because it is derived from the selected credential:
/// a named ChatGPT OAuth account uses the Codex backend, while a named API key
/// uses the direct OpenAI Platform API.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OpenAIAuthPath {
    /// Direct OpenAI Platform API key.
    PlatformApiKey,
    /// ChatGPT subscription OAuth token via the Codex backend.
    ChatGptCodex,
}

impl OpenAIAuthPath {
    /// Stable wire label for `model.list`.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PlatformApiKey => "platform-api-key",
            Self::ChatGptCodex => "chatgpt-codex",
        }
    }
}

/// Authentication for a single provider.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAuth {
    /// Named OAuth accounts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accounts: Option<Vec<AccountEntry>>,
    /// Named API keys.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_keys: Option<Vec<ApiKeyEntry>>,
    /// Which credential is currently active.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_credential: Option<ActiveCredential>,
}

/// Google-specific provider auth with Cloud Code Assist metadata.
///
/// Serializes and deserializes through `GoogleProviderAuthWire`, which
/// carries `#[serde(deny_unknown_fields)]`. A retired `endpoint` field
/// (left over from the pre-CCA "antigravity" era) fails to load with an
/// error naming the unknown field — users must re-authenticate via
/// `tron auth google`.
#[derive(Clone, Debug, Default)]
pub struct GoogleProviderAuth {
    /// Base provider auth fields.
    pub base: ProviderAuth,
    /// OAuth client ID (stored for refresh).
    pub client_id: Option<String>,
    /// OAuth client secret (stored for refresh).
    pub client_secret: Option<String>,
    /// Google Cloud project ID (required for Cloud Code Assist).
    pub project_id: Option<String>,
}

/// Flat wire shape for `GoogleProviderAuth`. Exists purely so we can use
/// `deny_unknown_fields` alongside the combined (base + Google-specific)
/// fields — `#[serde(flatten)]` is incompatible with deny_unknown_fields.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GoogleProviderAuthWire {
    #[serde(skip_serializing_if = "Option::is_none")]
    accounts: Option<Vec<AccountEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    api_keys: Option<Vec<ApiKeyEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    active_credential: Option<ActiveCredential>,
    #[serde(skip_serializing_if = "Option::is_none")]
    client_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    client_secret: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
}

impl From<GoogleProviderAuth> for GoogleProviderAuthWire {
    fn from(g: GoogleProviderAuth) -> Self {
        Self {
            accounts: g.base.accounts,
            api_keys: g.base.api_keys,
            active_credential: g.base.active_credential,
            client_id: g.client_id,
            client_secret: g.client_secret,
            project_id: g.project_id,
        }
    }
}

impl From<GoogleProviderAuthWire> for GoogleProviderAuth {
    fn from(w: GoogleProviderAuthWire) -> Self {
        Self {
            base: ProviderAuth {
                accounts: w.accounts,
                api_keys: w.api_keys,
                active_credential: w.active_credential,
            },
            client_id: w.client_id,
            client_secret: w.client_secret,
            project_id: w.project_id,
        }
    }
}

impl Serialize for GoogleProviderAuth {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        GoogleProviderAuthWire::from(self.clone()).serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for GoogleProviderAuth {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        GoogleProviderAuthWire::deserialize(deserializer).map(Into::into)
    }
}

/// API key auth for external services.
///
/// INVARIANT: `api_keys` is non-empty. An entry with zero keys is
/// indistinguishable from an unconfigured service and is rejected at
/// deserialization time via `deserialize_non_empty_keys`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceAuth {
    /// Configured API keys. The provider selects the first key by default
    /// and rotates on rate-limit / auth failures.
    #[serde(deserialize_with = "deserialize_non_empty_keys")]
    pub api_keys: Vec<String>,
}

impl ServiceAuth {
    /// Build a `ServiceAuth` from a single key. Panics if `key` is empty —
    /// callers should validate before construction.
    pub fn from_single(key: impl Into<String>) -> Self {
        let key = key.into();
        assert!(
            !key.is_empty(),
            "ServiceAuth::from_single requires a non-empty key"
        );
        Self {
            api_keys: vec![key],
        }
    }
}

fn deserialize_non_empty_keys<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as _;
    let keys = Vec::<String>::deserialize(deserializer)?;
    if keys.is_empty() {
        return Err(D::Error::custom(
            "apiKeys must contain at least one key; remove the service entry to clear it",
        ));
    }
    if keys.iter().any(String::is_empty) {
        return Err(D::Error::custom("apiKeys entries must be non-empty"));
    }
    Ok(keys)
}

/// Top-level auth storage schema (`~/.tron/profiles/auth.json`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthStorage {
    /// Schema version (always 1).
    pub version: u32,
    /// WebSocket bearer token used by paired iOS/Mac clients.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bearer_token: Option<String>,
    /// Per-provider auth configuration.
    pub providers: HashMap<String, serde_json::Value>,
    /// Per-service API key configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub services: Option<HashMap<String, ServiceAuth>>,
    /// ISO 8601 timestamp of last update.
    pub last_updated: String,
    /// Preserves unknown top-level keys through load/save round-trips.
    #[serde(flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

impl AuthStorage {
    /// Create a new empty auth storage.
    pub fn new() -> Self {
        Self {
            version: 1,
            bearer_token: None,
            providers: HashMap::new(),
            services: None,
            last_updated: chrono::Utc::now().to_rfc3339(),
            extra: HashMap::new(),
        }
    }

    /// Get typed provider auth for a given provider ID.
    pub fn get_provider_auth(&self, provider: &str) -> Option<ProviderAuth> {
        self.providers
            .get(provider)
            .and_then(|v| serde_json::from_value(v.clone()).ok())
    }

    /// Get Google-specific provider auth. Returns `None` if no `google`
    /// block exists OR if it fails to deserialize.
    ///
    /// For strict error surfacing (e.g. retired `endpoint` field), prefer
    /// [`Self::try_get_google_auth`], which returns an auth-boundary error.
    pub fn get_google_auth(&self) -> Option<GoogleProviderAuth> {
        self.providers
            .get("google")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
    }

    /// Get Google-specific provider auth, surfacing deserialization errors.
    /// Used by `load_server_auth` so a malformed `google` block produces an
    /// actionable `AuthError::MalformedProviderAuth` with re-auth guidance,
    /// rather than silently resembling an unconfigured provider.
    pub fn try_get_google_auth(&self) -> Result<Option<GoogleProviderAuth>, AuthError> {
        match self.providers.get("google") {
            None => Ok(None),
            Some(v) => serde_json::from_value::<GoogleProviderAuth>(v.clone())
                .map(Some)
                .map_err(|error| AuthError::MalformedProviderAuth {
                    provider: "google".to_string(),
                    details: error.to_string(),
                }),
        }
    }

    /// Set provider auth (replaces the entire provider entry).
    ///
    /// **Warning**: For Google, this drops `client_id`/`client_secret`/`project_id`
    /// because `ProviderAuth` doesn't include those fields. Use
    /// `save_provider_base` instead when mutating base fields on any provider.
    pub fn set_provider_auth(&mut self, provider: &str, auth: &ProviderAuth) {
        if let Ok(v) = serde_json::to_value(auth) {
            let _ = self.providers.insert(provider.to_string(), v);
        }
    }

    /// Save base `ProviderAuth` fields while preserving any provider-specific
    /// fields in the storage JSON (e.g. Google's `client_id`, `client_secret`,
    /// `project_id`).
    ///
    /// For non-Google providers this is equivalent to `set_provider_auth`.
    /// For Google, it re-reads the full `GoogleProviderAuth`, replaces only
    /// the `base` portion, and writes back the complete struct.
    pub fn save_provider_base(&mut self, provider: &str, pa: &ProviderAuth) {
        if provider == "google" {
            let mut gpa = self.get_google_auth().unwrap_or_default();
            gpa.base = pa.clone();
            self.set_google_auth(&gpa);
        } else {
            self.set_provider_auth(provider, pa);
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

    /// Get API keys for a service. Returns the stored `api_keys` vec, or
    /// an empty vec if the service isn't configured. Deserialization
    /// enforces non-empty keys so a present service always has ≥1 key.
    pub fn get_service_api_keys(&self, service: &str) -> Vec<String> {
        match self.get_service_auth(service) {
            Some(svc) => svc.api_keys.clone(),
            None => Vec::new(),
        }
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
    },
    /// API-key-based authentication.
    ApiKey {
        /// The API key.
        api_key: String,
    },
}

impl ServerAuth {
    /// Create from OAuth tokens.
    pub fn from_oauth(tokens: &OAuthTokens) -> Self {
        Self::OAuth {
            access_token: tokens.access_token.clone(),
            refresh_token: tokens.refresh_token.clone(),
            expires_at: tokens.expires_at,
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

/// OAuth token refresh response from any provider's token endpoint.
///
/// Uses `Option<String>` for `refresh_token` because some providers
/// (e.g., Google) may omit it when reusing the existing refresh token.
#[derive(Debug, serde::Deserialize)]
pub struct OAuthTokenRefreshResponse {
    /// New access token.
    pub access_token: String,
    /// New refresh token (absent when the provider reuses the existing one).
    pub refresh_token: Option<String>,
    /// Token lifetime in seconds.
    pub expires_in: i64,
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
mod tests;
