//! Core authentication types.
//!
//! Mirrors the TypeScript `AuthStorage` schema stored in `~/.tron/system/auth.json`.

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
/// carries `#[serde(deny_unknown_fields)]`. A legacy `endpoint` field
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

/// Top-level auth storage schema (`~/.tron/system/auth.json`).
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
    /// Preserves unknown top-level keys (e.g. "relay") through load/save round-trips.
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
    /// For strict error surfacing (e.g. legacy `endpoint` field), prefer
    /// [`Self::try_get_google_auth`], which returns the serde error.
    pub fn get_google_auth(&self) -> Option<GoogleProviderAuth> {
        self.providers
            .get("google")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
    }

    /// Get Google-specific provider auth, surfacing deserialization errors.
    /// Used by `load_server_auth` so a malformed `google` block produces an
    /// actionable `AuthError::MalformedProviderAuth` with re-auth guidance,
    /// rather than silently resembling an unconfigured provider.
    pub fn try_get_google_auth(&self) -> Result<Option<GoogleProviderAuth>, serde_json::Error> {
        match self.providers.get("google") {
            None => Ok(None),
            Some(v) => serde_json::from_value::<GoogleProviderAuth>(v.clone()).map(Some),
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
        assert!(pa.accounts.is_none());
        assert!(pa.api_keys.is_none());
        assert!(pa.active_credential.is_none());
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
            "accounts": [{"label":"test","oauth":{"accessToken":"ya29.abc","refreshToken":"r","expiresAt":0}}],
            "clientId": "cid",
            "clientSecret": "csec",
            "projectId": "my-project"
        }"#;
        let gpa: GoogleProviderAuth = serde_json::from_str(json).unwrap();
        assert_eq!(gpa.client_id.as_deref(), Some("cid"));
        assert_eq!(gpa.project_id.as_deref(), Some("my-project"));
        assert_eq!(gpa.base.accounts.as_ref().unwrap()[0].label, "test");
    }

    /// R3: legacy auth.json files carrying `endpoint: "antigravity"` (from
    /// before the CCA migration) must fail to load with an error naming
    /// the unknown field. The user has to re-authenticate.
    #[test]
    fn google_provider_auth_rejects_legacy_endpoint() {
        let json = r#"{
            "clientId": "cid",
            "endpoint": "antigravity",
            "projectId": "proj"
        }"#;
        let err = serde_json::from_str::<GoogleProviderAuth>(json).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("endpoint"),
            "error should name the legacy `endpoint` field, got: {msg}"
        );
    }

    /// R3 companion: completely unknown fields — not just `endpoint` — also
    /// fail to load, so no other legacy shape can slip through.
    #[test]
    fn google_provider_auth_rejects_arbitrary_unknown_field() {
        let json = r#"{
            "clientId": "cid",
            "somethingMadeUp": true
        }"#;
        assert!(serde_json::from_str::<GoogleProviderAuth>(json).is_err());
    }

    /// R2: `api_keys` is the canonical shape. Multiple keys are returned
    /// in the order they were configured — the provider picks the first
    /// by default and rotates on failure.
    #[test]
    fn service_auth_returns_all_api_keys() {
        let mut storage = AuthStorage::new();
        let mut services = HashMap::new();
        let _ = services.insert(
            "brave".to_string(),
            ServiceAuth {
                api_keys: vec!["first".to_string(), "second".to_string()],
            },
        );
        storage.services = Some(services);

        let keys = storage.get_service_api_keys("brave");
        assert_eq!(keys, vec!["first", "second"]);
    }

    #[test]
    fn service_auth_missing_returns_empty() {
        let storage = AuthStorage::new();
        assert!(storage.get_service_api_keys("nonexistent").is_empty());
    }

    /// R2: legacy `apiKey` single field is gone. An auth.json with only
    /// `apiKey: "..."` fails to load with an error naming the unknown
    /// field. Users must rewrite their auth.json to `apiKeys: ["..."]`.
    #[test]
    fn service_auth_rejects_legacy_api_key_field() {
        let json = r#"{"apiKey":"sk-legacy"}"#;
        let err = serde_json::from_str::<ServiceAuth>(json).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("apiKey") || msg.contains("apiKeys"),
            "error should name the problematic field, got: {msg}"
        );
    }

    /// R2: `apiKeys: []` is indistinguishable from an unconfigured service
    /// and is explicitly rejected.
    #[test]
    fn service_auth_rejects_empty_api_keys_array() {
        let json = r#"{"apiKeys":[]}"#;
        let err = serde_json::from_str::<ServiceAuth>(json).unwrap_err();
        assert!(err.to_string().contains("apiKeys"));
    }

    /// R2: a single-element `apiKeys` array loads cleanly — this is the
    /// canonical replacement for the old `apiKey` single-field shape.
    #[test]
    fn service_auth_accepts_single_element_api_keys() {
        let json = r#"{"apiKeys":["sk-one"]}"#;
        let svc: ServiceAuth = serde_json::from_str(json).unwrap();
        assert_eq!(svc.api_keys, vec!["sk-one"]);
    }

    /// R2: empty-string entries inside `apiKeys` are rejected (they would
    /// silently authenticate as anonymous).
    #[test]
    fn service_auth_rejects_empty_string_entry() {
        let json = r#"{"apiKeys":[""]}"#;
        assert!(serde_json::from_str::<ServiceAuth>(json).is_err());
    }

    #[test]
    fn auth_storage_roundtrip() {
        let mut storage = AuthStorage::new();
        let pa = ProviderAuth {
            api_keys: Some(vec![ApiKeyEntry {
                label: "(default)".to_string(),
                key: "sk-123".to_string(),
            }]),
            ..Default::default()
        };
        storage.set_provider_auth("anthropic", &pa);

        let json = serde_json::to_string(&storage).unwrap();
        let back: AuthStorage = serde_json::from_str(&json).unwrap();
        assert_eq!(back.version, 1);
        let restored = back.get_provider_auth("anthropic").unwrap();
        assert_eq!(restored.api_keys.as_ref().unwrap()[0].key, "sk-123");
    }

    #[test]
    fn auth_storage_get_google_auth() {
        let mut storage = AuthStorage::new();
        let gpa = GoogleProviderAuth {
            project_id: Some("proj".to_string()),
            ..Default::default()
        };
        storage.set_google_auth(&gpa);

        let restored = storage.get_google_auth().unwrap();
        assert_eq!(restored.project_id.as_deref(), Some("proj"));
    }

    #[test]
    fn server_auth_oauth() {
        let tokens = OAuthTokens {
            access_token: "tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: 999,
        };
        let sa = ServerAuth::from_oauth(&tokens);
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
    fn oauth_token_refresh_response_with_refresh_token() {
        let json = r#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#;
        let resp: OAuthTokenRefreshResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.access_token, "at");
        assert_eq!(resp.refresh_token.as_deref(), Some("rt"));
        assert_eq!(resp.expires_in, 3600);
    }

    #[test]
    fn oauth_token_refresh_response_without_refresh_token() {
        let json = r#"{"access_token":"at","expires_in":3600}"#;
        let resp: OAuthTokenRefreshResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.access_token, "at");
        assert!(resp.refresh_token.is_none());
    }

    #[test]
    fn now_ms_is_reasonable() {
        let ms = now_ms();
        // Should be after 2024-01-01 and before 2100-01-01
        assert!(ms > 1_704_067_200_000);
        assert!(ms < 4_102_444_800_000);
    }

    // ─── ApiKeyEntry ────────────────────────────────────────────────────

    #[test]
    fn api_key_entry_serde_roundtrip() {
        let entry = ApiKeyEntry {
            label: "work".to_string(),
            key: "sk-abc123".to_string(),
        };
        let json = serde_json::to_string(&entry).unwrap();
        let back: ApiKeyEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(back.label, "work");
        assert_eq!(back.key, "sk-abc123");
    }

    // ─── ActiveCredential ───────────────────────────────────────────────

    #[test]
    fn active_credential_oauth_serde() {
        let cred = ActiveCredential::OAuth {
            label: "personal".to_string(),
        };
        let json = serde_json::to_string(&cred).unwrap();
        assert!(json.contains(r#""type":"oauth""#));
        assert!(json.contains(r#""label":"personal""#));

        let back: ActiveCredential = serde_json::from_str(&json).unwrap();
        assert_eq!(
            back,
            ActiveCredential::OAuth {
                label: "personal".to_string()
            }
        );
    }

    #[test]
    fn active_credential_api_key_serde() {
        let cred = ActiveCredential::ApiKey {
            label: "work".to_string(),
        };
        let json = serde_json::to_string(&cred).unwrap();
        assert!(json.contains(r#""type":"apiKey""#));
        assert!(json.contains(r#""label":"work""#));

        let back: ActiveCredential = serde_json::from_str(&json).unwrap();
        assert_eq!(
            back,
            ActiveCredential::ApiKey {
                label: "work".to_string()
            }
        );
    }

    #[test]
    fn active_credential_equality() {
        let a = ActiveCredential::OAuth {
            label: "x".to_string(),
        };
        let b = ActiveCredential::OAuth {
            label: "x".to_string(),
        };
        let c = ActiveCredential::ApiKey {
            label: "x".to_string(),
        };
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    // ─── ProviderAuth new fields ────────────────────────────────────────

    #[test]
    fn provider_auth_with_api_keys() {
        let json =
            r#"{"apiKeys":[{"label":"work","key":"sk-123"},{"label":"personal","key":"sk-456"}]}"#;
        let pa: ProviderAuth = serde_json::from_str(json).unwrap();
        let keys = pa.api_keys.unwrap();
        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].label, "work");
        assert_eq!(keys[1].key, "sk-456");
    }

    #[test]
    fn provider_auth_with_active_credential() {
        let json = r#"{"activeCredential":{"type":"oauth","label":"main"}}"#;
        let pa: ProviderAuth = serde_json::from_str(json).unwrap();
        assert_eq!(
            pa.active_credential,
            Some(ActiveCredential::OAuth {
                label: "main".to_string()
            })
        );
    }

    #[test]
    fn provider_auth_all_fields_roundtrip() {
        let pa = ProviderAuth {
            accounts: Some(vec![AccountEntry {
                label: "acc1".to_string(),
                oauth: OAuthTokens {
                    access_token: "at".to_string(),
                    refresh_token: "rt".to_string(),
                    expires_at: 999,
                },
            }]),
            api_keys: Some(vec![ApiKeyEntry {
                label: "key1".to_string(),
                key: "sk-x".to_string(),
            }]),
            active_credential: Some(ActiveCredential::OAuth {
                label: "acc1".to_string(),
            }),
        };
        let json = serde_json::to_string(&pa).unwrap();
        let back: ProviderAuth = serde_json::from_str(&json).unwrap();
        assert_eq!(back.accounts.as_ref().unwrap().len(), 1);
        assert_eq!(back.api_keys.as_ref().unwrap().len(), 1);
        assert_eq!(
            back.active_credential,
            Some(ActiveCredential::OAuth {
                label: "acc1".to_string()
            })
        );
    }
}
