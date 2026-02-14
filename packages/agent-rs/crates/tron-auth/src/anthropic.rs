//! Anthropic OAuth implementation.
//!
//! Handles PKCE-based OAuth flows, token exchange, refresh, and server auth
//! loading for the Anthropic API.

use crate::errors::AuthError;
use crate::types::{OAuthConfig, OAuthTokens, ServerAuth, calculate_expires_at, now_ms};

/// Default Anthropic OAuth settings (matching TypeScript defaults).
pub fn default_config() -> OAuthConfig {
    OAuthConfig {
        auth_url: "https://console.anthropic.com/oauth/authorize".to_string(),
        token_url: "https://console.anthropic.com/v1/oauth/token".to_string(),
        redirect_uri: "https://console.anthropic.com/oauth/code/callback".to_string(),
        client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e".to_string(),
        client_secret: None,
        scopes: vec![
            "org:create_api_key".to_string(),
            "user:profile".to_string(),
            "user:inference".to_string(),
        ],
        token_expiry_buffer_seconds: 300,
    }
}

/// Build the authorization URL for browser redirect.
pub fn get_authorization_url(config: &OAuthConfig, challenge: &str) -> String {
    format!(
        "{}?response_type=code&client_id={}&redirect_uri={}&scope={}&code_challenge={}&code_challenge_method=S256",
        config.auth_url,
        urlencoded(&config.client_id),
        urlencoded(&config.redirect_uri),
        urlencoded(&config.scopes.join(" ")),
        urlencoded(challenge),
    )
}

/// Exchange an authorization code for tokens.
#[tracing::instrument(skip_all)]
pub async fn exchange_code_for_tokens(
    config: &OAuthConfig,
    code: &str,
    verifier: &str,
    state: Option<&str>,
) -> Result<OAuthTokens, AuthError> {
    let mut body = serde_json::json!({
        "grant_type": "authorization_code",
        "client_id": config.client_id,
        "code": code,
        "redirect_uri": config.redirect_uri,
        "code_verifier": verifier,
    });
    if let Some(s) = state {
        body["state"] = serde_json::Value::String(s.to_string());
    }

    let client = reqwest::Client::new();
    let resp = client
        .post(&config.token_url)
        .json(&body)
        .send()
        .await?;

    let status = resp.status().as_u16();
    if status != 200 {
        let text = resp.text().await.unwrap_or_default();
        return Err(AuthError::OAuth {
            status,
            message: text,
        });
    }

    let data: TokenResponse = resp.json().await?;
    Ok(OAuthTokens {
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: calculate_expires_at(
            data.expires_in,
            config.token_expiry_buffer_seconds,
        ),
    })
}

/// Refresh an expired OAuth token.
#[tracing::instrument(skip_all)]
pub async fn refresh_token(
    config: &OAuthConfig,
    refresh_token: &str,
) -> Result<OAuthTokens, AuthError> {
    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "client_id": config.client_id,
        "refresh_token": refresh_token,
    });

    let client = reqwest::Client::new();
    let resp = client
        .post(&config.token_url)
        .json(&body)
        .send()
        .await?;

    let status = resp.status().as_u16();
    if status != 200 {
        let text = resp.text().await.unwrap_or_default();
        return Err(AuthError::OAuth {
            status,
            message: text,
        });
    }

    let data: TokenResponse = resp.json().await?;
    Ok(OAuthTokens {
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: calculate_expires_at(
            data.expires_in,
            config.token_expiry_buffer_seconds,
        ),
    })
}

/// Check if a token string looks like an Anthropic OAuth token.
pub fn is_oauth_token(token: &str) -> bool {
    token.starts_with("sk-ant-oat")
}

/// Load server auth from auth storage.
///
/// Priority:
/// 1. `env_token` (pre-configured OAuth token, e.g. `CLAUDE_CODE_OAUTH_TOKEN`)
/// 2. Multi-account OAuth tokens (from `accounts[]`)
/// 3. Legacy single OAuth tokens
/// 4. API key
///
/// OAuth tokens are auto-refreshed if expired.
#[tracing::instrument(skip_all, fields(provider = "anthropic"))]
pub async fn load_server_auth(
    auth_path: &std::path::Path,
    config: &OAuthConfig,
    env_token: Option<&str>,
    preferred_account: Option<&str>,
) -> Result<Option<ServerAuth>, AuthError> {
    // 1. Env var token (long-lived, no refresh)
    if let Some(token) = env_token {
        return Ok(Some(ServerAuth::OAuth {
            access_token: token.to_string(),
            refresh_token: String::new(),
            expires_at: i64::MAX,
            account_label: None,
        }));
    }

    let Some(pa) = crate::storage::get_provider_auth(auth_path, "anthropic") else {
        return Ok(None);
    };

    // 2. Multi-account tokens
    if let Some(accounts) = &pa.accounts {
        if !accounts.is_empty() {
            let account = if let Some(label) = preferred_account {
                accounts.iter().find(|a| a.label == label)
            } else {
                None
            }
            .or_else(|| accounts.first());

            if let Some(acct) = account {
                let (tokens, refreshed) =
                    maybe_refresh_tokens(&acct.oauth, config).await?;
                if refreshed {
                    tracing::info!(account = %acct.label, "persisting refreshed account tokens");
                    let _ = crate::storage::save_account_oauth_tokens(
                        auth_path, "anthropic", &acct.label, &tokens,
                    );
                }
                return Ok(Some(ServerAuth::from_oauth(
                    &tokens,
                    Some(acct.label.clone()),
                )));
            }
        }
    }

    // 3. Legacy single OAuth
    if let Some(oauth) = &pa.oauth {
        match maybe_refresh_tokens(oauth, config).await {
            Ok((tokens, refreshed)) => {
                if refreshed {
                    tracing::info!("persisting refreshed provider tokens");
                    let _ = crate::storage::save_provider_oauth_tokens(
                        auth_path, "anthropic", &tokens,
                    );
                }
                return Ok(Some(ServerAuth::from_oauth(&tokens, None)));
            }
            Err(e) => {
                tracing::warn!("Anthropic OAuth refresh failed: {e}");
                // Fall through to API key
            }
        }
    }

    // 4. API key
    if let Some(key) = &pa.api_key {
        return Ok(Some(ServerAuth::from_api_key(key)));
    }

    Ok(None)
}

/// Refresh tokens if expired, returning `(tokens, was_refreshed)`.
async fn maybe_refresh_tokens(
    tokens: &OAuthTokens,
    config: &OAuthConfig,
) -> Result<(OAuthTokens, bool), AuthError> {
    let buffer_ms = config.token_expiry_buffer_seconds * 1000;
    if now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    tracing::info!("Anthropic OAuth token expired, refreshing...");
    let new_tokens = refresh_token(config, &tokens.refresh_token).await?;
    Ok((new_tokens, true))
}

/// Token endpoint response.
#[derive(serde::Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
    expires_in: i64,
}

/// Simple URL encoding for query parameters.
fn urlencoded(s: &str) -> String {
    s.replace('%', "%25")
        .replace(' ', "%20")
        .replace('&', "%26")
        .replace('=', "%3D")
        .replace('+', "%2B")
        .replace('/', "%2F")
        .replace(':', "%3A")
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_values() {
        let cfg = default_config();
        assert!(cfg.auth_url.contains("anthropic.com"));
        assert!(cfg.token_url.contains("oauth/token"));
        assert_eq!(cfg.token_expiry_buffer_seconds, 300);
        assert!(!cfg.scopes.is_empty());
    }

    #[test]
    fn is_oauth_token_valid() {
        assert!(is_oauth_token("sk-ant-oat-abc123"));
        assert!(!is_oauth_token("sk-ant-api-abc123"));
        assert!(!is_oauth_token("ya29.abc"));
        assert!(!is_oauth_token(""));
    }

    #[test]
    fn authorization_url_contains_required_params() {
        let cfg = default_config();
        let url = get_authorization_url(&cfg, "challenge123");
        assert!(url.contains("response_type=code"));
        assert!(url.contains("code_challenge=challenge123"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("redirect_uri="));
    }

    #[test]
    fn urlencoded_basic() {
        assert_eq!(urlencoded("hello world"), "hello%20world");
        assert_eq!(urlencoded("a&b=c"), "a%26b%3Dc");
    }

    #[tokio::test]
    async fn load_server_auth_env_token_priority() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");
        let cfg = default_config();

        let result = load_server_auth(&path, &cfg, Some("env-token"), None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "env-token");
    }

    #[tokio::test]
    async fn load_server_auth_api_key_fallback() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        crate::storage::save_provider_api_key(&path, "anthropic", "sk-123").unwrap();
        let cfg = default_config();

        let result = load_server_auth(&path, &cfg, None, None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(!auth.is_oauth());
        assert_eq!(auth.token(), "sk-123");
    }

    #[tokio::test]
    async fn load_server_auth_none_when_empty() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");
        let cfg = default_config();

        let result = load_server_auth(&path, &cfg, None, None)
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn load_server_auth_fresh_oauth_no_refresh() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save OAuth tokens that won't expire for a long time
        let tokens = OAuthTokens {
            access_token: "fresh-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000, // 1 hour from now
        };
        crate::storage::save_provider_oauth_tokens(&path, "anthropic", &tokens).unwrap();

        let cfg = default_config();
        let result = load_server_auth(&path, &cfg, None, None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "fresh-tok");
    }

    #[tokio::test]
    async fn load_server_auth_multi_account_preferred() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save two accounts with non-expired tokens
        let tokens1 = OAuthTokens {
            access_token: "work-tok".to_string(),
            refresh_token: "ref1".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        let tokens2 = OAuthTokens {
            access_token: "personal-tok".to_string(),
            refresh_token: "ref2".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::storage::save_account_oauth_tokens(&path, "anthropic", "work", &tokens1).unwrap();
        crate::storage::save_account_oauth_tokens(&path, "anthropic", "personal", &tokens2)
            .unwrap();

        let cfg = default_config();

        // Prefer "personal" account
        let result = load_server_auth(&path, &cfg, None, Some("personal"))
            .await
            .unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "personal-tok");

        // No preference → first account
        let result = load_server_auth(&path, &cfg, None, None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "work-tok");
    }
}
