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
/// 3. Default credential: `accounts[0]` → `api_keys[0]`
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
/// or no usable credential is available. Callers that need a display default
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
mod tests;
