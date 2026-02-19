//! `OpenAI` OAuth implementation.
//!
//! Handles token refresh and server auth loading for `OpenAI` (Codex) API.

use super::errors::AuthError;
use super::types::{OAuthTokens, ServerAuth, calculate_expires_at, now_ms};

/// `OpenAI` token endpoint URL.
const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";

/// Default `OpenAI` OAuth client ID.
const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";

/// Provider key in `auth.json` for `OpenAI` Codex.
///
/// Uses `openai-codex` to distinguish from `ChatGPT` subscriptions.
pub const PROVIDER_KEY: &str = "openai-codex";

/// Token expiry buffer in seconds.
const TOKEN_EXPIRY_BUFFER_SECONDS: i64 = 300;

/// Refresh an `OpenAI` OAuth token.
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn refresh_token(refresh_token: &str) -> Result<OAuthTokens, AuthError> {
    refresh_token_with_client(refresh_token, &reqwest::Client::new()).await
}

/// Refresh an `OpenAI` OAuth token using a shared HTTP client.
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn refresh_token_with_client(
    refresh_token: &str,
    client: &reqwest::Client,
) -> Result<OAuthTokens, AuthError> {
    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": refresh_token,
    });

    let resp = client.post(TOKEN_URL).json(&body).send().await?;

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
        refresh_token: data
            .refresh_token
            .unwrap_or_else(|| refresh_token.to_string()),
        expires_at: calculate_expires_at(data.expires_in, TOKEN_EXPIRY_BUFFER_SECONDS),
    })
}

/// Load server auth from auth storage.
///
/// Priority:
/// 1. `env_token` (pre-configured OAuth token, e.g. `OPENAI_OAUTH_TOKEN`)
/// 2. OAuth tokens from `auth.json` (provider key: `openai-codex`)
/// 3. `env_api_key` (e.g. `OPENAI_API_KEY`)
/// 4. API key from `auth.json`
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn load_server_auth(
    auth_path: &std::path::Path,
    env_token: Option<&str>,
    env_api_key: Option<&str>,
) -> Result<Option<ServerAuth>, AuthError> {
    load_server_auth_with_client(auth_path, env_token, env_api_key, &reqwest::Client::new()).await
}

/// Load server auth using a shared HTTP client for token refresh.
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn load_server_auth_with_client(
    auth_path: &std::path::Path,
    env_token: Option<&str>,
    env_api_key: Option<&str>,
    client: &reqwest::Client,
) -> Result<Option<ServerAuth>, AuthError> {
    // 1. Env var OAuth token
    if let Some(token) = env_token {
        return Ok(Some(ServerAuth::OAuth {
            access_token: token.to_string(),
            refresh_token: String::new(),
            expires_at: i64::MAX,
            account_label: None,
        }));
    }

    let pa = super::storage::get_provider_auth(auth_path, PROVIDER_KEY);

    // 2. OAuth tokens
    if let Some(ref pa) = pa {
        if let Some(oauth) = &pa.oauth {
            match maybe_refresh_tokens(oauth, client).await {
                Ok((tokens, refreshed)) => {
                    if refreshed {
                        tracing::info!("persisting refreshed OpenAI tokens");
                        let _ = super::storage::save_provider_oauth_tokens(
                            auth_path,
                            PROVIDER_KEY,
                            &tokens,
                        );
                    }
                    return Ok(Some(ServerAuth::from_oauth(&tokens, None)));
                }
                Err(e) => {
                    tracing::warn!("`OpenAI` OAuth refresh failed: {e}");
                }
            }
        }
    }

    // 3. Env var API key
    if let Some(key) = env_api_key {
        return Ok(Some(ServerAuth::from_api_key(key)));
    }

    // 4. API key from auth.json
    if let Some(pa) = &pa {
        if let Some(key) = &pa.api_key {
            return Ok(Some(ServerAuth::from_api_key(key)));
        }
    }

    Ok(None)
}

/// Refresh tokens if expired, returning `(tokens, was_refreshed)`.
async fn maybe_refresh_tokens(
    tokens: &OAuthTokens,
    client: &reqwest::Client,
) -> Result<(OAuthTokens, bool), AuthError> {
    let buffer_ms = TOKEN_EXPIRY_BUFFER_SECONDS * 1000;
    if now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    tracing::info!("`OpenAI` OAuth token expired, refreshing...");
    match refresh_token_with_client(&tokens.refresh_token, client).await {
        Ok(new_tokens) => {
            metrics::counter!("auth_refresh_total", "provider" => "openai", "status" => "success")
                .increment(1);
            Ok((new_tokens, true))
        }
        Err(e) => {
            metrics::counter!("auth_refresh_total", "provider" => "openai", "status" => "failure")
                .increment(1);
            Err(e)
        }
    }
}

/// `OpenAI` token endpoint response.
///
/// Uses the shared [`super::types::OAuthTokenRefreshResponse`] type.
type TokenResponse = super::types::OAuthTokenRefreshResponse;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_key_is_openai_codex() {
        assert_eq!(PROVIDER_KEY, "openai-codex");
    }

    #[tokio::test]
    async fn load_server_auth_env_token() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let result = load_server_auth(&path, Some("env-tok"), None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "env-tok");
    }

    #[tokio::test]
    async fn load_server_auth_env_api_key() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let result = load_server_auth(&path, None, Some("sk-openai"))
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(!auth.is_oauth());
        assert_eq!(auth.token(), "sk-openai");
    }

    #[tokio::test]
    async fn load_server_auth_api_key_from_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        crate::auth::storage::save_provider_api_key(&path, PROVIDER_KEY, "sk-file-key").unwrap();

        let result = load_server_auth(&path, None, None).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "sk-file-key");
    }

    #[tokio::test]
    async fn load_server_auth_none_when_empty() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let result = load_server_auth(&path, None, None).await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn load_server_auth_fresh_oauth() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "fresh-openai-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::auth::storage::save_provider_oauth_tokens(&path, PROVIDER_KEY, &tokens).unwrap();

        let result = load_server_auth(&path, None, None).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "fresh-openai-tok");
    }

    #[tokio::test]
    async fn env_token_takes_priority_over_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        crate::auth::storage::save_provider_api_key(&path, PROVIDER_KEY, "sk-file").unwrap();

        let result = load_server_auth(&path, Some("env-tok"), None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "env-tok");
    }
}
