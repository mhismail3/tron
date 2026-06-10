//! Anthropic OAuth implementation.
//!
//! Handles PKCE-based OAuth flows, token exchange, refresh, and server auth
//! loading for the Anthropic API.

use super::errors::AuthError;
use super::types::{
    ActiveCredential, OAuthConfig, OAuthTokens, ServerAuth, calculate_expires_at, now_ms,
};

/// Default Anthropic OAuth settings (matching `tron login` CLI).
pub fn default_config() -> OAuthConfig {
    OAuthConfig {
        auth_url: "https://claude.ai/oauth/authorize".to_string(),
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
    get_authorization_url_with_state(config, challenge, None)
}

/// Build the authorization URL with an optional `state` parameter.
pub fn get_authorization_url_with_state(
    config: &OAuthConfig,
    challenge: &str,
    state: Option<&str>,
) -> String {
    let mut url = format!(
        "{}?code=true&response_type=code&client_id={}&redirect_uri={}&scope={}&code_challenge={}&code_challenge_method=S256",
        config.auth_url,
        super::urlencoded(&config.client_id),
        super::urlencoded(&config.redirect_uri),
        super::urlencoded(&config.scopes.join(" ")),
        super::urlencoded(challenge),
    );
    if let Some(s) = state {
        url.push_str("&state=");
        url.push_str(&super::urlencoded(s));
    }
    url
}

/// Exchange an authorization code for tokens.
#[tracing::instrument(skip_all)]
pub async fn exchange_code_for_tokens(
    config: &OAuthConfig,
    code: &str,
    verifier: &str,
    state: Option<&str>,
) -> Result<OAuthTokens, AuthError> {
    exchange_code_for_tokens_with_client(config, code, verifier, state, super::shared_auth_client())
        .await
}

/// Exchange an authorization code for tokens using a shared HTTP client.
#[tracing::instrument(skip_all)]
pub async fn exchange_code_for_tokens_with_client(
    config: &OAuthConfig,
    code: &str,
    verifier: &str,
    state: Option<&str>,
    client: &reqwest::Client,
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

    let resp = client.post(&config.token_url).json(&body).send().await?;

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
        refresh_token: data.refresh_token.unwrap_or_default(),
        expires_at: calculate_expires_at(data.expires_in, config.token_expiry_buffer_seconds),
    })
}

/// Refresh an expired OAuth token.
#[tracing::instrument(skip_all, fields(provider = "anthropic"))]
pub async fn refresh_token(
    config: &OAuthConfig,
    refresh_token: &str,
) -> Result<OAuthTokens, AuthError> {
    refresh_token_with_client(config, refresh_token, super::shared_auth_client()).await
}

/// Refresh an expired OAuth token using a shared HTTP client.
#[tracing::instrument(skip_all, fields(provider = "anthropic"))]
pub async fn refresh_token_with_client(
    config: &OAuthConfig,
    refresh_token: &str,
    client: &reqwest::Client,
) -> Result<OAuthTokens, AuthError> {
    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "client_id": config.client_id,
        "refresh_token": refresh_token,
    });

    let resp = client.post(&config.token_url).json(&body).send().await?;

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
        expires_at: calculate_expires_at(data.expires_in, config.token_expiry_buffer_seconds),
    })
}

/// Check if a token string looks like an Anthropic OAuth token.
pub fn is_oauth_token(token: &str) -> bool {
    token.starts_with("sk-ant-oat")
}

/// Load server auth from auth storage.
///
/// Uses [`super::resolve_credential`] to determine which credential to use:
/// 1. `credential_override` (session pinning)
/// 2. `active_credential` (user selection)
/// 3. Default credential: `accounts[0]` → `api_keys[0]`
///
/// OAuth tokens are auto-refreshed if expired.
#[tracing::instrument(skip_all, fields(provider = "anthropic"))]
pub async fn load_server_auth(
    auth_path: &std::path::Path,
    config: &OAuthConfig,
) -> Result<Option<ServerAuth>, AuthError> {
    load_server_auth_with_credential(auth_path, config, None).await
}

/// Load server auth with an optional credential override (for session pinning).
#[tracing::instrument(skip_all, fields(provider = "anthropic"))]
pub async fn load_server_auth_with_credential(
    auth_path: &std::path::Path,
    config: &OAuthConfig,
    credential_override: Option<&ActiveCredential>,
) -> Result<Option<ServerAuth>, AuthError> {
    load_server_auth_with_client(
        auth_path,
        config,
        credential_override,
        super::shared_auth_client(),
    )
    .await
}

/// Load server auth using a shared HTTP client for token refresh.
#[tracing::instrument(skip_all, fields(provider = "anthropic"))]
pub async fn load_server_auth_with_client(
    auth_path: &std::path::Path,
    config: &OAuthConfig,
    credential_override: Option<&ActiveCredential>,
    client: &reqwest::Client,
) -> Result<Option<ServerAuth>, AuthError> {
    let Some(pa) = super::storage::get_provider_auth(auth_path, "anthropic")? else {
        return Ok(None);
    };

    let Some(resolved) = super::resolve_credential(&pa, credential_override) else {
        return Ok(None);
    };

    match resolved {
        super::ResolvedCredential::OAuthAccount(acct) => {
            let (tokens, _refreshed) =
                maybe_refresh_tokens(auth_path, &acct.label, &acct.oauth, config, client).await?;
            Ok(Some(ServerAuth::from_oauth(&tokens)))
        }
        super::ResolvedCredential::ApiKey(key) => Ok(Some(ServerAuth::from_api_key(&key.key))),
    }
}

/// Read the current tokens for a specific account from auth.json.
///
/// Returns `None` both when the provider is not configured and when the
/// account does not exist. A malformed auth file surfaces as `None` here —
/// the caller is the refresh path, where the outer `maybe_refresh_tokens`
/// flow already holds tokens in-memory and treats a missing on-disk copy
/// as "other process didn't update", so masking a parse error is OK in
/// this narrow branch. Top-level load paths use `get_provider_auth`
/// directly and propagate the error.
fn read_tokens_from_disk(auth_path: &std::path::Path, account_label: &str) -> Option<OAuthTokens> {
    let pa = super::storage::get_provider_auth(auth_path, "anthropic")
        .ok()
        .flatten()?;
    pa.accounts?
        .into_iter()
        .find(|a| a.label == account_label)
        .map(|a| a.oauth)
}

/// Save refreshed tokens back to auth.json (called while holding file lock).
fn persist_tokens(
    auth_path: &std::path::Path,
    account_label: &str,
    tokens: &OAuthTokens,
) -> Result<(), AuthError> {
    tracing::info!(
        account = account_label,
        "persisting refreshed Anthropic account tokens"
    );
    super::storage::save_account_oauth_tokens(auth_path, "anthropic", account_label, tokens)
}

/// Check if a refresh failure indicates the refresh token was already consumed.
///
/// HTTP 400 with `invalid_grant` means the single-use refresh token was used
/// by another process/server between our read and our refresh attempt.
fn is_stale_token_error(e: &AuthError) -> bool {
    matches!(e, AuthError::OAuth { status: 400, message } if message.contains("invalid_grant"))
}

/// Refresh tokens if expired, returning `(tokens, was_refreshed)`.
///
/// Serializes concurrent refresh attempts with both a process-local lock
/// (for async tasks) and a file-level advisory lock (for multiple processes).
/// Re-reads from disk after acquiring the file lock in case another process
/// refreshed while we waited. On stale-token errors (HTTP 400 `invalid_grant`),
/// retries once with tokens re-read from disk.
async fn maybe_refresh_tokens(
    auth_path: &std::path::Path,
    account_label: &str,
    tokens: &OAuthTokens,
    config: &OAuthConfig,
    client: &reqwest::Client,
) -> Result<(OAuthTokens, bool), AuthError> {
    use std::sync::OnceLock;
    use tokio::sync::Mutex as TokioMutex;

    static REFRESH_LOCK: OnceLock<TokioMutex<()>> = OnceLock::new();

    let buffer_ms = config.token_expiry_buffer_seconds * 1000;
    if now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    // Serialize concurrent refresh attempts within this process
    let lock = REFRESH_LOCK.get_or_init(|| TokioMutex::new(()));
    let _guard = lock.lock().await;

    // Re-check expiry after acquiring process lock
    if now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    // Acquire file lock (cross-process safety)
    let _file_lock = super::storage::acquire_auth_file_lock(auth_path).map_err(AuthError::Io)?;

    // Re-read from disk — another process may have refreshed while we waited.
    // Also prefer disk tokens for refresh (may have a newer refresh_token).
    let disk_tokens = read_tokens_from_disk(auth_path, account_label);
    if let Some(ref dt) = disk_tokens
        && now_ms() + buffer_ms < dt.expires_at
    {
        return Ok((dt.clone(), true));
    }
    let effective_tokens = disk_tokens.unwrap_or_else(|| tokens.clone());

    let client = client.clone();
    let config = config.clone();
    let auth_path = auth_path.to_path_buf();
    let account_label_owned = account_label.to_string();

    let do_refresh = |tok: &OAuthTokens| {
        let client = client.clone();
        let config = config.clone();
        let tok = tok.clone();
        async move {
            super::refresh::maybe_refresh(
                &tok,
                config.token_expiry_buffer_seconds,
                "anthropic",
                |refresh_tok| {
                    let client = client.clone();
                    let config = config.clone();
                    let refresh_tok = refresh_tok.to_owned();
                    async move { refresh_token_with_client(&config, &refresh_tok, &client).await }
                },
            )
            .await
        }
    };

    match do_refresh(&effective_tokens).await {
        Ok((new_tokens, true)) => {
            persist_tokens(&auth_path, &account_label_owned, &new_tokens)?;
            Ok((new_tokens, true))
        }
        Ok(not_refreshed) => Ok(not_refreshed),
        Err(e) if is_stale_token_error(&e) => {
            tracing::info!("refresh token consumed by another process, re-reading auth.json");

            let retry_tokens = read_tokens_from_disk(&auth_path, &account_label_owned);
            match retry_tokens {
                Some(rt) if now_ms() + buffer_ms < rt.expires_at => Ok((rt, true)),
                Some(rt) => {
                    tracing::info!("retrying refresh with updated token from disk");
                    match do_refresh(&rt).await {
                        Ok((new_tokens, true)) => {
                            persist_tokens(&auth_path, &account_label_owned, &new_tokens)?;
                            Ok((new_tokens, true))
                        }
                        Ok(not_refreshed) => Ok(not_refreshed),
                        Err(retry_err) => Err(retry_err),
                    }
                }
                None => Err(e),
            }
        }
        Err(e) => Err(e),
    }
}

/// Token endpoint response.
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
    fn default_config_values() {
        let cfg = default_config();
        assert!(cfg.auth_url.contains("claude.ai"));
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

    // urlencoded tests moved to auth/mod.rs (single source of truth)

    #[tokio::test]
    async fn load_server_auth_only_reads_from_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save API key to auth.json
        crate::domains::auth::credentials::storage::save_named_api_key(
            &path,
            "anthropic",
            "(default)",
            "sk-file-key",
        )
        .unwrap();
        let cfg = default_config();

        let result = load_server_auth(&path, &cfg).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "sk-file-key");

        // Save OAuth tokens too — OAuth takes priority over API key (accounts before api_keys).
        let tokens = OAuthTokens {
            access_token: "oauth-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "test",
            &tokens,
        )
        .unwrap();

        let result = load_server_auth(&path, &cfg).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "oauth-tok");
    }

    #[tokio::test]
    async fn load_server_auth_api_key_default() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        crate::domains::auth::credentials::storage::save_named_api_key(
            &path,
            "anthropic",
            "(default)",
            "sk-123",
        )
        .unwrap();
        let cfg = default_config();

        let result = load_server_auth(&path, &cfg).await.unwrap();
        let auth = result.unwrap();
        assert!(!auth.is_oauth());
        assert_eq!(auth.token(), "sk-123");
    }

    #[tokio::test]
    async fn load_server_auth_none_when_empty() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");
        let cfg = default_config();

        let result = load_server_auth(&path, &cfg).await.unwrap();
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
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "test",
            &tokens,
        )
        .unwrap();

        let cfg = default_config();
        let result = load_server_auth(&path, &cfg).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "fresh-tok");
    }

    #[tokio::test]
    async fn load_server_auth_oauth_failure_does_not_use_api_key_default() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save expired OAuth tokens (will fail to refresh without network)
        let expired_tokens = OAuthTokens {
            access_token: "expired-tok".to_string(),
            refresh_token: "old-ref".to_string(),
            expires_at: 0, // long expired
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "test",
            &expired_tokens,
        )
        .unwrap();
        // Also save an API key (should NOT be used as the default while OAuth is present).
        crate::domains::auth::credentials::storage::save_named_api_key(
            &path,
            "anthropic",
            "(default)",
            "sk-should-not-use",
        )
        .unwrap();

        let cfg = default_config();
        let result = load_server_auth(&path, &cfg).await;

        // Should return Err (OAuth refresh failed), NOT Ok(Some(ApiKey))
        assert!(
            result.is_err(),
            "expected Err when OAuth refresh fails, got: {result:?}"
        );
    }

    #[tokio::test]
    async fn load_server_auth_uses_first_account() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

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
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "work",
            &tokens1,
        )
        .unwrap();
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "personal",
            &tokens2,
        )
        .unwrap();

        let cfg = default_config();
        let result = load_server_auth(&path, &cfg).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "work-tok");
    }

    #[tokio::test]
    async fn load_server_auth_single_account() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "tok-alice".to_string(),
            refresh_token: "ref-alice".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "alice",
            &tokens,
        )
        .unwrap();

        let cfg = default_config();
        let result = load_server_auth(&path, &cfg).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "tok-alice");
    }

    #[test]
    fn stale_token_error_detected() {
        let err = AuthError::OAuth {
            status: 400,
            message: r#"{"error":"invalid_grant"}"#.to_string(),
        };
        assert!(is_stale_token_error(&err));
    }

    #[test]
    fn non_stale_errors_not_detected() {
        assert!(!is_stale_token_error(&AuthError::OAuth {
            status: 400,
            message: "bad_request".to_string(),
        }));
        assert!(!is_stale_token_error(&AuthError::OAuth {
            status: 401,
            message: "invalid_grant".to_string(),
        }));
        assert!(!is_stale_token_error(&AuthError::OAuth {
            status: 503,
            message: "server_error".to_string(),
        }));
        assert!(!is_stale_token_error(&AuthError::Io(
            std::io::Error::other("test",)
        )));
    }

    #[test]
    fn read_tokens_from_disk_account() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "disk-tok".to_string(),
            refresh_token: "disk-ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "user@host",
            &tokens,
        )
        .unwrap();

        let loaded = read_tokens_from_disk(&path, "user@host").unwrap();
        assert_eq!(loaded.access_token, "disk-tok");

        assert!(read_tokens_from_disk(&path, "nonexistent").is_none());
    }

    #[tokio::test]
    async fn maybe_refresh_uses_disk_tokens_after_lock() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Write expired tokens initially
        let expired = OAuthTokens {
            access_token: "expired-tok".to_string(),
            refresh_token: "old-ref".to_string(),
            expires_at: 0,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "user@host",
            &expired,
        )
        .unwrap();

        // Simulate another process having refreshed: write fresh tokens to disk
        let fresh = OAuthTokens {
            access_token: "fresh-tok".to_string(),
            refresh_token: "new-ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "anthropic",
            "user@host",
            &fresh,
        )
        .unwrap();

        let cfg = default_config();
        let client = reqwest::Client::new();
        let (tokens, refreshed) = maybe_refresh_tokens(&path, "user@host", &expired, &cfg, &client)
            .await
            .unwrap();

        // Should return the fresh tokens from disk without making HTTP call
        assert!(refreshed);
        assert_eq!(tokens.access_token, "fresh-tok");
    }
}
