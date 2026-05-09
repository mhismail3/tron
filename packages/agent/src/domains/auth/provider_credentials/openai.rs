//! `OpenAI` OAuth implementation.
//!
//! Handles OAuth authorization, token exchange, refresh, and server auth loading
//! for the `OpenAI` (Codex) API.
//!
//! Uses PKCE (S256) like Anthropic, with a localhost redirect URI
//! (`http://localhost:1455/auth/callback`) for the callback.

use super::errors::AuthError;
use super::types::{
    ActiveCredential, OAuthConfig, OAuthTokens, ProviderAuth, ServerAuth, calculate_expires_at,
    now_ms,
};
use crate::domains::model::providers::openai::types::OpenAIAuthPath;

/// `OpenAI` token endpoint URL.
const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";

/// `OpenAI` OAuth authorization URL.
const AUTH_URL: &str = "https://auth.openai.com/oauth/authorize";

/// Default `OpenAI` OAuth client ID.
const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";

/// `OpenAI` OAuth redirect URI (localhost callback server).
const REDIRECT_URI: &str = "http://localhost:1455/auth/callback";

/// Default `OpenAI` OAuth scopes.
const SCOPES: &[&str] = &["openid", "profile", "email", "offline_access"];

/// Provider key in `auth.json` for `OpenAI` Codex.
///
/// Uses `openai-codex` to distinguish from `ChatGPT` subscriptions.
pub const PROVIDER_KEY: &str = "openai-codex";

/// Token expiry buffer in seconds.
const TOKEN_EXPIRY_BUFFER_SECONDS: i64 = 300;

/// Default `OpenAI` OAuth settings.
pub fn default_config() -> OAuthConfig {
    OAuthConfig {
        auth_url: AUTH_URL.to_string(),
        token_url: TOKEN_URL.to_string(),
        redirect_uri: REDIRECT_URI.to_string(),
        client_id: CLIENT_ID.to_string(),
        client_secret: None,
        scopes: SCOPES.iter().map(|s| (*s).to_string()).collect(),
        token_expiry_buffer_seconds: TOKEN_EXPIRY_BUFFER_SECONDS,
    }
}

/// Build the authorization URL for browser redirect.
pub fn get_authorization_url(config: &OAuthConfig, challenge: &str) -> String {
    get_authorization_url_with_state(config, challenge, None)
}

/// Build the authorization URL with PKCE challenge and optional `state` parameter.
pub fn get_authorization_url_with_state(
    config: &OAuthConfig,
    challenge: &str,
    state: Option<&str>,
) -> String {
    let mut url = format!(
        "{}?response_type=code&client_id={}&redirect_uri={}&scope={}&code_challenge={}&code_challenge_method=S256",
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
) -> Result<OAuthTokens, AuthError> {
    exchange_code_for_tokens_with_client(config, code, verifier, super::shared_auth_client()).await
}

/// Exchange an authorization code for tokens using a shared HTTP client.
#[tracing::instrument(skip_all)]
pub async fn exchange_code_for_tokens_with_client(
    config: &OAuthConfig,
    code: &str,
    verifier: &str,
    client: &reqwest::Client,
) -> Result<OAuthTokens, AuthError> {
    let body = serde_json::json!({
        "grant_type": "authorization_code",
        "client_id": config.client_id,
        "code": code,
        "redirect_uri": config.redirect_uri,
        "code_verifier": verifier,
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
        refresh_token: data.refresh_token.unwrap_or_default(),
        expires_at: calculate_expires_at(data.expires_in, config.token_expiry_buffer_seconds),
    })
}

/// Refresh an `OpenAI` OAuth token.
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn refresh_token(refresh_token: &str) -> Result<OAuthTokens, AuthError> {
    refresh_token_with_client(refresh_token, super::shared_auth_client()).await
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
/// Uses [`super::resolve_credential`] to determine which credential to use:
/// 1. `credential_override` (session pinning)
/// 2. `active_credential` (user selection)
/// 3. Fallback: `accounts[0]` → `api_keys[0]`
///
/// OAuth tokens are auto-refreshed if expired.
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn load_server_auth(
    auth_path: &std::path::Path,
) -> Result<Option<ServerAuth>, AuthError> {
    load_server_auth_with_credential(auth_path, None).await
}

/// Load server auth with an optional credential override (for session pinning).
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn load_server_auth_with_credential(
    auth_path: &std::path::Path,
    credential_override: Option<&ActiveCredential>,
) -> Result<Option<ServerAuth>, AuthError> {
    load_server_auth_with_client(auth_path, credential_override, super::shared_auth_client()).await
}

/// Load server auth using a shared HTTP client for token refresh.
#[tracing::instrument(skip_all, fields(provider = "openai"))]
pub async fn load_server_auth_with_client(
    auth_path: &std::path::Path,
    credential_override: Option<&ActiveCredential>,
    client: &reqwest::Client,
) -> Result<Option<ServerAuth>, AuthError> {
    let Some(pa) = super::storage::get_provider_auth(auth_path, PROVIDER_KEY)? else {
        return Ok(None);
    };

    let Some(resolved) = super::resolve_credential(&pa, credential_override) else {
        return Ok(None);
    };

    match resolved {
        super::ResolvedCredential::OAuthAccount(acct) => {
            let (tokens, _refreshed) =
                maybe_refresh_tokens(auth_path, &acct.label, &acct.oauth, client).await?;
            Ok(Some(ServerAuth::from_oauth(&tokens)))
        }
        super::ResolvedCredential::ApiKey(key) => Ok(Some(ServerAuth::from_api_key(&key.key))),
    }
}

/// Infer the active `OpenAI` auth path from an already-loaded provider auth.
///
/// This mirrors [`super::resolve_credential`] exactly, but stops before token
/// refresh so metadata lookups can cheaply choose the same profile as provider
/// creation.
#[must_use]
pub fn infer_auth_path_from_provider_auth(
    provider_auth: &ProviderAuth,
    credential_override: Option<&ActiveCredential>,
) -> Option<OpenAIAuthPath> {
    match super::resolve_credential(provider_auth, credential_override)? {
        super::ResolvedCredential::OAuthAccount(_) => Some(OpenAIAuthPath::ChatGptCodex),
        super::ResolvedCredential::ApiKey(_) => Some(OpenAIAuthPath::PlatformApiKey),
    }
}

/// Infer the active `OpenAI` auth path from `auth.json`.
///
/// Returns `None` if the provider is unconfigured, the auth file cannot be read,
/// or no usable credential is available. Callers that need a display fallback
/// should choose the conservative Codex profile.
#[must_use]
pub fn infer_auth_path(
    auth_path: &std::path::Path,
    credential_override: Option<&ActiveCredential>,
) -> Option<OpenAIAuthPath> {
    let provider_auth = super::storage::get_provider_auth(auth_path, PROVIDER_KEY)
        .ok()
        .flatten()?;
    infer_auth_path_from_provider_auth(&provider_auth, credential_override)
}

/// Read the current tokens for a specific account from auth.json.
///
/// Returns `None` both when the provider is not configured and when the
/// account does not exist. A malformed auth file surfaces as `None` here —
/// see the mirror doc comment in `anthropic.rs` for the rationale.
fn read_tokens_from_disk(auth_path: &std::path::Path, account_label: &str) -> Option<OAuthTokens> {
    let pa = super::storage::get_provider_auth(auth_path, PROVIDER_KEY)
        .ok()
        .flatten()?;
    pa.accounts?
        .into_iter()
        .find(|a| a.label == account_label)
        .map(|a| a.oauth)
}

/// Save refreshed tokens back to auth.json.
fn persist_tokens(auth_path: &std::path::Path, account_label: &str, tokens: &OAuthTokens) {
    tracing::info!(
        account = account_label,
        "persisting refreshed OpenAI account tokens"
    );
    if let Err(e) =
        super::storage::save_account_oauth_tokens(auth_path, PROVIDER_KEY, account_label, tokens)
    {
        tracing::warn!(error = %e, "failed to persist refreshed OpenAI tokens");
    }
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
    client: &reqwest::Client,
) -> Result<(OAuthTokens, bool), AuthError> {
    use std::sync::OnceLock;
    use tokio::sync::Mutex as TokioMutex;

    static REFRESH_LOCK: OnceLock<TokioMutex<()>> = OnceLock::new();

    let buffer_ms = TOKEN_EXPIRY_BUFFER_SECONDS * 1000;
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
    let disk_tokens = read_tokens_from_disk(auth_path, account_label);
    if let Some(ref dt) = disk_tokens
        && now_ms() + buffer_ms < dt.expires_at
    {
        return Ok((dt.clone(), true));
    }
    let effective_tokens = disk_tokens.unwrap_or_else(|| tokens.clone());

    let client = client.clone();
    let auth_path = auth_path.to_path_buf();
    let account_label_owned = account_label.to_string();

    let do_refresh = |tok: &OAuthTokens| {
        let client = client.clone();
        let tok = tok.clone();
        async move {
            super::refresh::maybe_refresh(
                &tok,
                TOKEN_EXPIRY_BUFFER_SECONDS,
                "openai",
                |refresh_tok| {
                    let client = client.clone();
                    let refresh_tok = refresh_tok.to_owned();
                    async move { refresh_token_with_client(&refresh_tok, &client).await }
                },
            )
            .await
        }
    };

    match do_refresh(&effective_tokens).await {
        Ok((new_tokens, true)) => {
            persist_tokens(&auth_path, &account_label_owned, &new_tokens);
            Ok((new_tokens, true))
        }
        Ok(not_refreshed) => Ok(not_refreshed),
        Err(e) if is_stale_token_error(&e) => {
            tracing::info!(
                "OpenAI refresh token consumed by another process, re-reading auth.json"
            );

            let retry_tokens = read_tokens_from_disk(&auth_path, &account_label_owned);
            match retry_tokens {
                Some(rt) if now_ms() + buffer_ms < rt.expires_at => Ok((rt, true)),
                Some(rt) => {
                    tracing::info!("retrying OpenAI refresh with updated token from disk");
                    match do_refresh(&rt).await {
                        Ok((new_tokens, true)) => {
                            persist_tokens(&auth_path, &account_label_owned, &new_tokens);
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

    #[test]
    fn infer_auth_path_prefers_active_credential() {
        let provider_auth = ProviderAuth {
            accounts: Some(vec![super::super::types::AccountEntry {
                label: "chatgpt".into(),
                oauth: OAuthTokens {
                    access_token: "tok".into(),
                    refresh_token: "ref".into(),
                    expires_at: now_ms() + 3_600_000,
                },
            }]),
            api_keys: Some(vec![super::super::types::ApiKeyEntry {
                label: "platform".into(),
                key: "sk-test".into(),
            }]),
            active_credential: Some(ActiveCredential::ApiKey {
                label: "platform".into(),
            }),
        };

        assert_eq!(
            infer_auth_path_from_provider_auth(&provider_auth, None),
            Some(OpenAIAuthPath::PlatformApiKey)
        );
    }

    #[test]
    fn infer_auth_path_fallback_prefers_oauth_before_api_key() {
        let provider_auth = ProviderAuth {
            accounts: Some(vec![super::super::types::AccountEntry {
                label: "chatgpt".into(),
                oauth: OAuthTokens {
                    access_token: "tok".into(),
                    refresh_token: "ref".into(),
                    expires_at: now_ms() + 3_600_000,
                },
            }]),
            api_keys: Some(vec![super::super::types::ApiKeyEntry {
                label: "platform".into(),
                key: "sk-test".into(),
            }]),
            active_credential: None,
        };

        assert_eq!(
            infer_auth_path_from_provider_auth(&provider_auth, None),
            Some(OpenAIAuthPath::ChatGptCodex)
        );
    }

    // ─── default_config tests ───────────────────────────────────────────

    #[test]
    fn default_config_values() {
        let cfg = default_config();
        assert!(cfg.auth_url.contains("auth.openai.com"));
        assert!(cfg.token_url.contains("auth.openai.com"));
        assert_eq!(cfg.client_id, "app_EMoamEEZ73f0CkXaXp7hrann");
        assert!(cfg.client_secret.is_none());
        assert!(cfg.scopes.contains(&"openid".to_string()));
        assert!(cfg.scopes.contains(&"profile".to_string()));
        assert!(cfg.scopes.contains(&"email".to_string()));
        assert!(cfg.scopes.contains(&"offline_access".to_string()));
        assert_eq!(cfg.token_expiry_buffer_seconds, 300);
    }

    // ─── authorization URL tests ────────────────────────────────────────

    #[test]
    fn authorization_url_contains_required_params() {
        let cfg = default_config();
        let url = get_authorization_url(&cfg, "challenge123");
        assert!(url.contains("response_type=code"));
        assert!(url.contains(&cfg.client_id));
        assert!(url.contains("redirect_uri="));
        assert!(url.contains("scope="));
        assert!(url.contains("code_challenge=challenge123"));
        assert!(url.contains("code_challenge_method=S256"));
    }

    #[test]
    fn authorization_url_with_state() {
        let cfg = default_config();
        let url = get_authorization_url_with_state(&cfg, "challenge", Some("my-state-123"));
        assert!(url.contains("state=my-state-123"));
    }

    #[test]
    fn authorization_url_without_state() {
        let cfg = default_config();
        let url = get_authorization_url_with_state(&cfg, "challenge", None);
        assert!(!url.contains("state="));
    }

    #[test]
    fn authorization_url_starts_with_auth_endpoint() {
        let cfg = default_config();
        let url = get_authorization_url(&cfg, "challenge");
        assert!(url.starts_with("https://auth.openai.com/oauth/authorize?"));
    }

    // ─── load_server_auth ────────────────────────────────────────────────

    #[tokio::test]
    async fn load_server_auth_oauth_from_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "oauth-from-file".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "test",
            &tokens,
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "oauth-from-file");
    }

    #[tokio::test]
    async fn load_server_auth_api_key_from_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        crate::domains::auth::provider_credentials::storage::save_named_api_key(
            &path,
            PROVIDER_KEY,
            "(default)",
            "sk-file-key",
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "sk-file-key");
    }

    #[tokio::test]
    async fn load_server_auth_none_when_empty() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let result = load_server_auth(&path).await.unwrap();
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
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "test",
            &tokens,
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "fresh-openai-tok");
    }

    // ─── load_server_auth: accounts support ─────────────────────────────

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
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "work",
            &tokens1,
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "personal",
            &tokens2,
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
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
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "alice",
            &tokens,
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.is_oauth());
        assert_eq!(auth.token(), "tok-alice");
    }

    #[tokio::test]
    async fn load_server_auth_oauth_failure_does_not_fallback_to_api_key() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save expired OAuth account (will fail to refresh without network)
        let expired = OAuthTokens {
            access_token: "expired-tok".to_string(),
            refresh_token: "old-ref".to_string(),
            expires_at: 0, // long expired
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "test",
            &expired,
        )
        .unwrap();
        // Also save an API key (should NOT be used as fallback)
        crate::domains::auth::provider_credentials::storage::save_named_api_key(
            &path,
            PROVIDER_KEY,
            "(default)",
            "sk-should-not-use",
        )
        .unwrap();

        let result = load_server_auth(&path).await;

        // Should return Err (OAuth refresh failed), NOT Ok(Some(ApiKey))
        assert!(
            result.is_err(),
            "expected Err when OAuth refresh fails, got: {result:?}"
        );
    }

    // ─── read_tokens_from_disk ──────────────────────────────────────────

    #[test]
    fn read_tokens_from_disk_account() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "disk-tok".to_string(),
            refresh_token: "disk-ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "user@host",
            &tokens,
        )
        .unwrap();

        let loaded = read_tokens_from_disk(&path, "user@host").unwrap();
        assert_eq!(loaded.access_token, "disk-tok");

        assert!(read_tokens_from_disk(&path, "nonexistent").is_none());
    }

    // ─── stale token detection ──────────────────────────────────────────

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

    // ─── maybe_refresh_tokens with disk re-read ─────────────────────────

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
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
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
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "user@host",
            &fresh,
        )
        .unwrap();

        let client = reqwest::Client::new();
        let (tokens, refreshed) = maybe_refresh_tokens(&path, "user@host", &expired, &client)
            .await
            .unwrap();

        // Should return the fresh tokens from disk without making HTTP call
        assert!(refreshed);
        assert_eq!(tokens.access_token, "fresh-tok");
    }

    // ─── active_credential selection ────────────────────────────────────

    #[tokio::test]
    async fn load_server_auth_active_credential_selects_specific_account() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens1 = OAuthTokens {
            access_token: "first-tok".to_string(),
            refresh_token: "ref1".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        let tokens2 = OAuthTokens {
            access_token: "second-tok".to_string(),
            refresh_token: "ref2".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "first",
            &tokens1,
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "second",
            &tokens2,
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::set_active_credential(
            &path,
            PROVIDER_KEY,
            &ActiveCredential::OAuth {
                label: "second".to_string(),
            },
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "second-tok");
    }

    #[tokio::test]
    async fn load_server_auth_active_credential_selects_api_key() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "oauth-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "main",
            &tokens,
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::save_named_api_key(
            &path,
            PROVIDER_KEY,
            "work",
            "sk-work-key",
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::set_active_credential(
            &path,
            PROVIDER_KEY,
            &ActiveCredential::ApiKey {
                label: "work".to_string(),
            },
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert!(!auth.is_oauth());
        assert_eq!(auth.token(), "sk-work-key");
    }

    #[tokio::test]
    async fn load_server_auth_deleted_active_falls_back_to_first() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "remaining-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "remaining",
            &tokens,
        )
        .unwrap();

        // Set active to a non-existent account (simulates deletion without clearing active)
        // Manually write the active_credential since set_active_credential validates
        let mut storage =
            crate::domains::auth::provider_credentials::storage::load_auth_storage(&path)
                .unwrap()
                .expect("auth storage written in test setup");
        let mut pa = storage.get_provider_auth(PROVIDER_KEY).unwrap();
        pa.active_credential = Some(ActiveCredential::OAuth {
            label: "deleted".to_string(),
        });
        storage.set_provider_auth(PROVIDER_KEY, &pa);
        crate::domains::auth::provider_credentials::storage::save_auth_storage(&path, &mut storage)
            .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "remaining-tok");
    }

    // ─── credential_override (session pinning) ──────────────────────────

    #[tokio::test]
    async fn load_server_auth_override_beats_active() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens1 = OAuthTokens {
            access_token: "active-tok".to_string(),
            refresh_token: "ref1".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        let tokens2 = OAuthTokens {
            access_token: "pinned-tok".to_string(),
            refresh_token: "ref2".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "active-acct",
            &tokens1,
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "pinned-acct",
            &tokens2,
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::set_active_credential(
            &path,
            PROVIDER_KEY,
            &ActiveCredential::OAuth {
                label: "active-acct".to_string(),
            },
        )
        .unwrap();

        // Override should beat the active credential
        let override_cred = ActiveCredential::OAuth {
            label: "pinned-acct".to_string(),
        };
        let result = load_server_auth_with_credential(&path, Some(&override_cred))
            .await
            .unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "pinned-tok");
    }

    #[tokio::test]
    async fn load_server_auth_override_deleted_falls_to_active() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let tokens = OAuthTokens {
            access_token: "active-tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
            &path,
            PROVIDER_KEY,
            "active-acct",
            &tokens,
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::set_active_credential(
            &path,
            PROVIDER_KEY,
            &ActiveCredential::OAuth {
                label: "active-acct".to_string(),
            },
        )
        .unwrap();

        // Override points to a deleted credential
        let override_cred = ActiveCredential::OAuth {
            label: "deleted".to_string(),
        };
        let result = load_server_auth_with_credential(&path, Some(&override_cred))
            .await
            .unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "active-tok");
    }

    #[tokio::test]
    async fn load_server_auth_no_active_no_override_uses_first() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        crate::domains::auth::provider_credentials::storage::save_named_api_key(
            &path,
            PROVIDER_KEY,
            "key1",
            "sk-first",
        )
        .unwrap();
        crate::domains::auth::provider_credentials::storage::save_named_api_key(
            &path,
            PROVIDER_KEY,
            "key2",
            "sk-second",
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.token(), "sk-first");
    }
}
