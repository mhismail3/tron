use std::path::{Path, PathBuf};

use chrono::Utc;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use tron_core::security::{env_vars, AuthMethod, ApiKey, OAuthTokens, ANTHROPIC_OAUTH};

/// Persisted auth file schema (matches TS server's auth.json).
#[derive(Debug, Serialize, Deserialize)]
pub struct AuthFile {
    #[serde(default)]
    pub accounts: Vec<AuthAccount>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oauth: Option<LegacyOAuth>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AuthAccount {
    pub provider: String,
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct LegacyOAuth {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
}

/// Resolve authentication for Anthropic, following the priority chain.
///
/// Priority:
/// 1. CLAUDE_CODE_OAUTH_TOKEN env var
/// 2. OAuth from auth file → accounts[] (with refresh)
/// 3. OAuth from auth file → legacy oauth field (with refresh)
/// 4. API key from auth file
/// 5. ANTHROPIC_API_KEY env var
/// 6. None
pub fn resolve_anthropic_auth(auth_file_path: &Path) -> Option<AuthMethod> {
    // 1. Env var OAuth token
    if let Ok(token) = std::env::var(env_vars::CLAUDE_CODE_OAUTH_TOKEN) {
        if !token.is_empty() {
            return Some(AuthMethod::OAuth(OAuthTokens {
                access_token: SecretString::from(token),
                refresh_token: SecretString::from(String::new()),
                expires_at: i64::MAX,
            }));
        }
    }

    // 2-4. Auth file
    if let Some(auth) = load_auth_file(auth_file_path) {
        // 2. accounts[] (newest first)
        for account in &auth.accounts {
            if account.provider == "anthropic" {
                return Some(AuthMethod::OAuth(OAuthTokens {
                    access_token: SecretString::from(account.access_token.clone()),
                    refresh_token: SecretString::from(account.refresh_token.clone()),
                    expires_at: account.expires_at,
                }));
            }
        }

        // 3. Legacy oauth field
        if let Some(oauth) = &auth.oauth {
            return Some(AuthMethod::OAuth(OAuthTokens {
                access_token: SecretString::from(oauth.access_token.clone()),
                refresh_token: SecretString::from(oauth.refresh_token.clone()),
                expires_at: oauth.expires_at,
            }));
        }

        // 4. API key from file
        if let Some(key) = &auth.api_key {
            if !key.is_empty() {
                return Some(AuthMethod::ApiKey(ApiKey(SecretString::from(key.clone()))));
            }
        }
    }

    // 5. Env var API key
    if let Ok(key) = std::env::var(env_vars::ANTHROPIC_API_KEY) {
        if !key.is_empty() {
            return Some(AuthMethod::ApiKey(ApiKey(SecretString::from(key))));
        }
    }

    None
}

/// Check if an OAuth token needs refresh (expired or within buffer).
pub fn needs_refresh(tokens: &OAuthTokens) -> bool {
    let now_ms = Utc::now().timestamp_millis();
    let buffer_ms = ANTHROPIC_OAUTH.token_expiry_buffer_seconds as i64 * 1000;
    tokens.expires_at - now_ms < buffer_ms
}

/// Detect if a token is OAuth-based (sk-ant-oat prefix).
pub fn is_oauth_token(token: &str) -> bool {
    token.starts_with("sk-ant-oat")
}

/// Build the OAuth beta headers for a request.
pub fn oauth_beta_headers(requires_thinking_beta: bool) -> &'static str {
    if requires_thinking_beta {
        ANTHROPIC_OAUTH.oauth_beta_headers
    } else {
        "oauth-2025-04-20"
    }
}

/// Default auth file path.
pub fn default_auth_file_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".tron/auth-rs.json")
}

fn load_auth_file(path: &Path) -> Option<AuthFile> {
    let content = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

/// Save updated tokens back to the auth file after a refresh.
pub fn save_auth_file(path: &Path, auth: &AuthFile) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(auth).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, e)
    })?;
    std::fs::write(path, json)
}

/// Refresh an OAuth token by POSTing to the token endpoint.
pub async fn refresh_token(
    refresh_token: &SecretString,
) -> Result<OAuthTokens, AuthError> {
    let client = reqwest::Client::new();
    let resp = client
        .post(ANTHROPIC_OAUTH.token_url)
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.expose_secret()),
            ("client_id", ANTHROPIC_OAUTH.client_id),
        ])
        .send()
        .await
        .map_err(|e| AuthError::NetworkError(e.to_string()))?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(AuthError::RefreshFailed(body));
    }

    let body: TokenResponse = resp
        .json()
        .await
        .map_err(|e| AuthError::ParseError(e.to_string()))?;

    let expires_at = Utc::now().timestamp_millis() + (body.expires_in as i64 * 1000);

    Ok(OAuthTokens {
        access_token: SecretString::from(body.access_token),
        refresh_token: SecretString::from(
            body.refresh_token
                .unwrap_or_else(|| refresh_token.expose_secret().to_string()),
        ),
        expires_at,
    })
}

#[derive(Deserialize)]
pub struct TokenResponse {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_in: u64,
}

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("token refresh failed: {0}")]
    RefreshFailed(String),
    #[error("network error: {0}")]
    NetworkError(String),
    #[error("parse error: {0}")]
    ParseError(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_auth_file(content: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tron-test-auth-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("auth-rs.json");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(content.as_bytes()).unwrap();
        path
    }

    #[test]
    fn resolve_from_accounts() {
        let path = temp_auth_file(r#"{
            "accounts": [
                {"provider": "anthropic", "access_token": "sk-ant-oat-xxx", "refresh_token": "rt-xxx", "expires_at": 9999999999999}
            ]
        }"#);

        let auth = resolve_anthropic_auth(&path);
        assert!(auth.is_some());
        assert!(matches!(auth.unwrap(), AuthMethod::OAuth(_)));
    }

    #[test]
    fn resolve_from_legacy_oauth() {
        let path = temp_auth_file(r#"{
            "accounts": [],
            "oauth": {"access_token": "sk-ant-oat-legacy", "refresh_token": "rt-legacy", "expires_at": 9999999999999}
        }"#);

        let auth = resolve_anthropic_auth(&path);
        assert!(auth.is_some());
        assert!(matches!(auth.unwrap(), AuthMethod::OAuth(_)));
    }

    #[test]
    fn resolve_from_api_key_in_file() {
        let path = temp_auth_file(r#"{
            "accounts": [],
            "api_key": "sk-ant-api123"
        }"#);

        let auth = resolve_anthropic_auth(&path);
        assert!(auth.is_some());
        assert!(matches!(auth.unwrap(), AuthMethod::ApiKey(_)));
    }

    #[test]
    fn resolve_missing_file_returns_none() {
        let path = PathBuf::from("/nonexistent/auth.json");
        // Clear env vars to ensure no fallback
        std::env::remove_var(env_vars::CLAUDE_CODE_OAUTH_TOKEN);
        std::env::remove_var(env_vars::ANTHROPIC_API_KEY);
        let auth = resolve_anthropic_auth(&path);
        assert!(auth.is_none());
    }

    #[test]
    fn is_oauth_token_detection() {
        assert!(is_oauth_token("sk-ant-oat-abc123"));
        assert!(!is_oauth_token("sk-ant-api123"));
        assert!(!is_oauth_token("random-key"));
    }

    #[test]
    fn oauth_beta_headers_by_model() {
        let full = oauth_beta_headers(true);
        assert!(full.contains("interleaved-thinking"));
        assert!(full.contains("oauth-2025-04-20"));

        let minimal = oauth_beta_headers(false);
        assert_eq!(minimal, "oauth-2025-04-20");
        assert!(!minimal.contains("interleaved-thinking"));
    }

    #[test]
    fn needs_refresh_expired_token() {
        let tokens = OAuthTokens {
            access_token: SecretString::from("test"),
            refresh_token: SecretString::from("test"),
            expires_at: 0, // long expired
        };
        assert!(needs_refresh(&tokens));
    }

    #[test]
    fn needs_refresh_fresh_token() {
        let tokens = OAuthTokens {
            access_token: SecretString::from("test"),
            refresh_token: SecretString::from("test"),
            expires_at: i64::MAX, // far future
        };
        assert!(!needs_refresh(&tokens));
    }

    #[test]
    fn save_and_load_auth_file() {
        let dir = std::env::temp_dir().join(format!("tron-test-auth-save-{}", uuid::Uuid::now_v7()));
        let path = dir.join("auth-rs.json");

        let auth = AuthFile {
            accounts: vec![AuthAccount {
                provider: "anthropic".into(),
                access_token: "token".into(),
                refresh_token: "refresh".into(),
                expires_at: 12345,
            }],
            oauth: None,
            api_key: None,
        };

        save_auth_file(&path, &auth).unwrap();

        let loaded = load_auth_file(&path).unwrap();
        assert_eq!(loaded.accounts.len(), 1);
        assert_eq!(loaded.accounts[0].access_token, "token");
    }
}
