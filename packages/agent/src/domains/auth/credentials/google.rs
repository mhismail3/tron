//! Google/Gemini OAuth implementation.
//!
//! Supports OAuth (standard Gemini API) and direct API key authentication.

use super::errors::AuthError;
#[cfg(test)]
use super::types::now_ms;
use super::types::{GoogleAuth, OAuthConfig, OAuthTokens, ServerAuth, calculate_expires_at};

/// Default Google OAuth configuration for the standard Gemini API.
///
/// Users provide their own GCP OAuth `client_id` (and optionally `client_secret`).
/// Tokens are used against `generativelanguage.googleapis.com` with Bearer auth.
pub fn cloud_code_assist_config() -> GoogleOAuthConfig {
    GoogleOAuthConfig {
        oauth: OAuthConfig {
            auth_url: "https://accounts.google.com/o/oauth2/v2/auth".to_string(),
            token_url: "https://oauth2.googleapis.com/token".to_string(),
            redirect_uri: "http://localhost:45289".to_string(),
            client_id: String::new(),
            client_secret: None,
            scopes: vec!["https://www.googleapis.com/auth/generative-language".to_string()],
            token_expiry_buffer_seconds: 300,
        },
        api_endpoint: "https://generativelanguage.googleapis.com".to_string(),
        api_version: "v1beta".to_string(),
    }
}

/// Google OAuth configuration with API endpoint info.
#[derive(Clone, Debug)]
pub struct GoogleOAuthConfig {
    /// Base OAuth configuration.
    pub oauth: OAuthConfig,
    /// API endpoint URL.
    pub api_endpoint: String,
    /// API version string.
    pub api_version: String,
}

/// Build the authorization URL for browser redirect.
pub fn get_authorization_url(config: &GoogleOAuthConfig, challenge: &str) -> String {
    format!(
        "{}?response_type=code&client_id={}&redirect_uri={}&scope={}&code_challenge={}&code_challenge_method=S256&access_type=offline&prompt=consent",
        config.oauth.auth_url,
        super::urlencoded(&config.oauth.client_id),
        super::urlencoded(&config.oauth.redirect_uri),
        super::urlencoded(&config.oauth.scopes.join(" ")),
        super::urlencoded(challenge),
    )
}

/// Exchange authorization code for tokens.
#[tracing::instrument(skip_all)]
pub async fn exchange_code_for_tokens(
    config: &GoogleOAuthConfig,
    code: &str,
    verifier: &str,
) -> Result<OAuthTokens, AuthError> {
    exchange_code_for_tokens_with_client(config, code, verifier, super::shared_auth_client()).await
}

/// Exchange authorization code for tokens using a shared HTTP client.
#[tracing::instrument(skip_all)]
pub async fn exchange_code_for_tokens_with_client(
    config: &GoogleOAuthConfig,
    code: &str,
    verifier: &str,
    client: &reqwest::Client,
) -> Result<OAuthTokens, AuthError> {
    let body = [
        ("grant_type", "authorization_code"),
        ("client_id", &config.oauth.client_id),
        ("code", code),
        ("redirect_uri", &config.oauth.redirect_uri),
        ("code_verifier", verifier),
    ];
    let body_with_secret: Vec<(&str, &str)> = if let Some(ref secret) = config.oauth.client_secret {
        let mut b = body.to_vec();
        b.push(("client_secret", secret));
        b
    } else {
        body.to_vec()
    };

    let resp = client
        .post(&config.oauth.token_url)
        .form(&body_with_secret)
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

    let data: GoogleTokenResponse = resp.json().await?;
    let refresh = data.refresh_token.unwrap_or_default();

    Ok(OAuthTokens {
        access_token: data.access_token,
        refresh_token: refresh,
        expires_at: calculate_expires_at(data.expires_in, config.oauth.token_expiry_buffer_seconds),
    })
}

/// Refresh an expired OAuth token.
#[tracing::instrument(skip_all, fields(provider = "google"))]
pub async fn refresh_token(
    config: &GoogleOAuthConfig,
    refresh_token: &str,
) -> Result<OAuthTokens, AuthError> {
    refresh_token_with_client(config, refresh_token, super::shared_auth_client()).await
}

/// Refresh an expired OAuth token using a shared HTTP client.
#[tracing::instrument(skip_all, fields(provider = "google"))]
pub async fn refresh_token_with_client(
    config: &GoogleOAuthConfig,
    refresh_token: &str,
    client: &reqwest::Client,
) -> Result<OAuthTokens, AuthError> {
    let body = [
        ("grant_type", "refresh_token"),
        ("client_id", &config.oauth.client_id),
        ("refresh_token", refresh_token),
    ];
    let body_with_secret: Vec<(&str, &str)> = if let Some(ref secret) = config.oauth.client_secret {
        let mut b = body.to_vec();
        b.push(("client_secret", secret));
        b
    } else {
        body.to_vec()
    };

    let resp = client
        .post(&config.oauth.token_url)
        .form(&body_with_secret)
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

    let data: GoogleTokenResponse = resp.json().await?;
    Ok(OAuthTokens {
        access_token: data.access_token,
        refresh_token: data
            .refresh_token
            .unwrap_or_else(|| refresh_token.to_string()),
        expires_at: calculate_expires_at(data.expires_in, config.oauth.token_expiry_buffer_seconds),
    })
}

/// Check if a token looks like a Google OAuth token.
///
/// Google access tokens start with `ya29.` or are JWTs (3 dot-separated parts).
pub fn is_oauth_token(token: &str) -> bool {
    token.starts_with("ya29.") || token.split('.').count() == 3
}

/// Load server auth from auth storage.
///
/// Priority:
/// 1. OAuth tokens from `auth.json` (auto-refresh if expired)
/// 2. API key from `auth.json`
#[tracing::instrument(skip_all, fields(provider = "google"))]
pub async fn load_server_auth(
    auth_path: &std::path::Path,
) -> Result<Option<GoogleAuth>, AuthError> {
    load_server_auth_with_client(auth_path, None, super::shared_auth_client()).await
}

/// Load server auth using a shared HTTP client for token refresh.
///
/// Uses [`super::resolve_credential`] to determine which credential to use:
/// 1. `credential_override` (session pinning)
/// 2. `active_credential` (user selection)
/// 3. Default credential: `accounts[0]` → `api_keys[0]`
#[tracing::instrument(skip_all, fields(provider = "google"))]
pub async fn load_server_auth_with_client(
    auth_path: &std::path::Path,
    credential_override: Option<&super::types::ActiveCredential>,
    client: &reqwest::Client,
) -> Result<Option<GoogleAuth>, AuthError> {
    // Strict parse: a retired `endpoint` field or any other unknown key
    // surfaces as `AuthError::MalformedProviderAuth` with re-auth guidance.
    let gpa = super::storage::try_get_google_provider_auth(auth_path)?;
    let Some(ref gpa) = gpa else {
        return Ok(None);
    };

    let Some(resolved) = super::resolve_credential(&gpa.base, credential_override) else {
        return Ok(None);
    };

    match resolved {
        super::ResolvedCredential::OAuthAccount(acct) => {
            let cfg = cloud_code_assist_config();
            let client_id = gpa.client_id.clone().ok_or_else(|| AuthError::NotConfigured(
                "Google OAuth requires a client_id — configure one in Settings > Providers > Google".into(),
            ))?;

            let cfg_with_creds = GoogleOAuthConfig {
                oauth: OAuthConfig {
                    client_id,
                    client_secret: gpa.client_secret.clone().or(cfg.oauth.client_secret),
                    ..cfg.oauth
                },
                ..cfg
            };

            match maybe_refresh_tokens(auth_path, &acct.label, &acct.oauth, &cfg_with_creds, client)
                .await
            {
                Ok((tokens, _refreshed)) => Ok(Some(GoogleAuth {
                    auth: ServerAuth::from_oauth(&tokens),
                    project_id: gpa.project_id.clone(),
                })),
                Err(e) => {
                    tracing::warn!("Google OAuth refresh failed: {e}");
                    Err(e)
                }
            }
        }
        super::ResolvedCredential::ApiKey(key) => Ok(Some(GoogleAuth {
            auth: ServerAuth::from_api_key(&key.key),
            project_id: None,
        })),
    }
}

/// Read the current tokens for a specific Google account from auth.json.
///
/// Returns `None` both when the provider is not configured and when the
/// account does not exist. A malformed auth file surfaces as `None` here; the
/// outer `load_server_auth_with_client` path has already parsed the provider
/// strictly before entering refresh, and the later persist path will refuse to
/// overwrite a malformed file.
fn read_tokens_from_disk(auth_path: &std::path::Path, account_label: &str) -> Option<OAuthTokens> {
    let gpa = super::storage::get_google_provider_auth(auth_path)
        .ok()
        .flatten()?;
    gpa.base
        .accounts?
        .into_iter()
        .find(|a| a.label == account_label)
        .map(|a| a.oauth)
}

/// Save refreshed Google tokens back to auth.json.
///
/// Called while holding the auth file lock.
fn persist_tokens(
    auth_path: &std::path::Path,
    account_label: &str,
    tokens: &OAuthTokens,
) -> Result<(), AuthError> {
    tracing::info!(
        account = account_label,
        "persisting refreshed Google tokens"
    );
    super::storage::save_account_oauth_tokens(auth_path, "google", account_label, tokens)
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
    config: &GoogleOAuthConfig,
    client: &reqwest::Client,
) -> Result<(OAuthTokens, bool), AuthError> {
    use std::sync::OnceLock;
    use tokio::sync::Mutex as TokioMutex;

    static REFRESH_LOCK: OnceLock<TokioMutex<()>> = OnceLock::new();

    let buffer_ms = config.oauth.token_expiry_buffer_seconds * 1000;
    if super::types::now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    let lock = REFRESH_LOCK.get_or_init(|| TokioMutex::new(()));
    let _guard = lock.lock().await;

    if super::types::now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    let _file_lock = super::storage::acquire_auth_file_lock(auth_path).map_err(AuthError::Io)?;

    let disk_tokens = read_tokens_from_disk(auth_path, account_label);
    if let Some(ref dt) = disk_tokens
        && super::types::now_ms() + buffer_ms < dt.expires_at
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
                config.oauth.token_expiry_buffer_seconds,
                "google",
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
            tracing::info!(
                "Google refresh token consumed by another process, re-reading auth.json"
            );

            let retry_tokens = read_tokens_from_disk(&auth_path, &account_label_owned);
            match retry_tokens {
                Some(rt) if super::types::now_ms() + buffer_ms < rt.expires_at => Ok((rt, true)),
                Some(rt) => {
                    tracing::info!("retrying Google refresh with updated token from disk");
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

/// Google token endpoint response.
#[derive(serde::Deserialize)]
struct GoogleTokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: i64,
}

/// Save Google OAuth credentials (client ID and secret).
pub fn save_oauth_credentials(
    auth_path: &std::path::Path,
    client_id: &str,
    client_secret: &str,
) -> Result<(), AuthError> {
    let mut gpa = super::storage::get_google_provider_auth(auth_path)?.unwrap_or_default();
    gpa.client_id = Some(client_id.to_string());
    gpa.client_secret = Some(client_secret.to_string());
    super::storage::save_google_provider_auth(auth_path, &gpa)
}

/// Get stored Google OAuth credentials.
///
/// Returns `None` when auth.json is missing, when Google is not configured,
/// or when either `clientId`/`clientSecret` is absent. A malformed auth file
/// also surfaces as `None` here — this is a best-effort getter used only by
/// the OAuth UI flow to pre-populate fields; the top-level load path
/// (`load_server_auth`) propagates parse errors via `try_get_google_provider_auth`.
pub fn get_oauth_credentials(auth_path: &std::path::Path) -> Option<(String, String)> {
    let gpa = super::storage::get_google_provider_auth(auth_path)
        .ok()
        .flatten()?;
    let id = gpa.client_id?;
    let secret = gpa.client_secret?;
    Some((id, secret))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cloud_code_assist_config_values() {
        let cfg = cloud_code_assist_config();
        assert!(cfg.oauth.auth_url.contains("accounts.google.com"));
        assert!(
            cfg.api_endpoint
                .contains("generativelanguage.googleapis.com")
        );
        assert_eq!(cfg.api_version, "v1beta");
    }

    #[test]
    fn is_oauth_token_patterns() {
        assert!(is_oauth_token("ya29.abc123"));
        assert!(is_oauth_token("header.payload.signature")); // JWT-like
        assert!(!is_oauth_token("sk-123"));
        assert!(!is_oauth_token("simple-key"));
        assert!(!is_oauth_token(""));
    }

    #[test]
    fn authorization_url_has_offline_access() {
        let cfg = cloud_code_assist_config();
        let url = get_authorization_url(&cfg, "challenge");
        assert!(url.contains("access_type=offline"));
        assert!(url.contains("prompt=consent"));
    }

    #[tokio::test]
    async fn load_server_auth_only_reads_from_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save API key via named key path
        crate::domains::auth::credentials::storage::save_named_api_key(
            &path,
            "google",
            "(test)",
            "file-api-key",
        )
        .unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.auth.token(), "file-api-key");
    }

    #[tokio::test]
    async fn load_server_auth_oauth_from_file_only() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save OAuth tokens via account path
        let tokens = OAuthTokens {
            access_token: "ya29.file-oauth".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path, "google", "(test)", &tokens,
        )
        .unwrap();

        // Set client_id (required for OAuth)
        let mut gpa = crate::domains::auth::credentials::storage::get_google_provider_auth(&path)
            .unwrap()
            .unwrap_or_default();
        gpa.client_id = Some("test-client-id".to_string());
        crate::domains::auth::credentials::storage::save_google_provider_auth(&path, &gpa).unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert!(auth.auth.is_oauth());
        assert_eq!(auth.auth.token(), "ya29.file-oauth");
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

        // Save OAuth tokens via account path
        let tokens = OAuthTokens {
            access_token: "ya29.fresh".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path, "google", "(test)", &tokens,
        )
        .unwrap();

        // Set client_id (required for OAuth)
        let mut gpa = crate::domains::auth::credentials::storage::get_google_provider_auth(&path)
            .unwrap()
            .unwrap_or_default();
        gpa.client_id = Some("test-client-id".to_string());
        crate::domains::auth::credentials::storage::save_google_provider_auth(&path, &gpa).unwrap();

        let result = load_server_auth(&path).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.auth.token(), "ya29.fresh");
    }

    #[tokio::test]
    async fn load_server_auth_missing_client_id_returns_error() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Save OAuth tokens but NO client_id
        let tokens = OAuthTokens {
            access_token: "ya29.test".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path, "google", "(test)", &tokens,
        )
        .unwrap();

        let result = load_server_auth(&path).await;
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(
            err.contains("client_id"),
            "error should mention client_id: {err}"
        );
    }

    /// R3: retired auth.json files with `endpoint: "antigravity"` (from the
    /// pre-CCA era) must fail to load. The strict `GoogleProviderAuth`
    /// deserializer rejects unknown fields, and `load_server_auth`
    /// surfaces that as `AuthError::MalformedProviderAuth` with re-auth
    /// guidance. The old "silently ignores endpoint and uses CCA anyway"
    /// behavior is gone.
    #[tokio::test]
    async fn load_server_auth_rejects_retired_antigravity_auth_json() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        // Write a raw auth.json with the retired antigravity shape. We
        // can't go through `save_google_provider_auth` because that type
        // no longer serializes `endpoint`.
        let raw = serde_json::json!({
            "version": 1,
            "providers": {
                "google": {
                    "clientId": "retired-client",
                    "endpoint": "antigravity",
                    "accounts": [{
                        "label": "(test)",
                        "oauth": {
                            "accessToken": "ya29.retired",
                            "refreshToken": "ref",
                            "expiresAt": now_ms() + 3_600_000,
                        }
                    }]
                }
            },
            "lastUpdated": "2025-01-01T00:00:00Z"
        });
        std::fs::write(&path, serde_json::to_string_pretty(&raw).unwrap()).unwrap();

        let err = load_server_auth(&path).await.unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("endpoint"),
            "error must name the retired `endpoint` field, got: {msg}"
        );
        assert!(
            msg.contains("tron auth google"),
            "error must include re-auth guidance, got: {msg}"
        );
    }

    #[test]
    fn stale_refresh_errors_detected() {
        let err = AuthError::OAuth {
            status: 400,
            message: r#"{"error":"invalid_grant"}"#.to_string(),
        };
        assert!(is_stale_token_error(&err));
    }

    #[test]
    fn non_stale_refresh_errors_not_detected() {
        assert!(!is_stale_token_error(&AuthError::OAuth {
            status: 400,
            message: "bad_request".to_string(),
        }));
        assert!(!is_stale_token_error(&AuthError::OAuth {
            status: 401,
            message: "invalid_grant".to_string(),
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
            "google",
            "user@example.com",
            &tokens,
        )
        .unwrap();

        let loaded = read_tokens_from_disk(&path, "user@example.com").unwrap();
        assert_eq!(loaded.access_token, "disk-tok");

        assert!(read_tokens_from_disk(&path, "nonexistent").is_none());
    }

    #[tokio::test]
    async fn maybe_refresh_uses_disk_tokens_after_lock() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let expired = OAuthTokens {
            access_token: "expired-tok".to_string(),
            refresh_token: "old-ref".to_string(),
            expires_at: 0,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "google",
            "user@example.com",
            &expired,
        )
        .unwrap();

        let fresh = OAuthTokens {
            access_token: "fresh-tok".to_string(),
            refresh_token: "new-ref".to_string(),
            expires_at: now_ms() + 3_600_000,
        };
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            &path,
            "google",
            "user@example.com",
            &fresh,
        )
        .unwrap();

        let mut cfg = cloud_code_assist_config();
        cfg.oauth.client_id = "client-id".to_string();
        let client = reqwest::Client::new();
        let (tokens, refreshed) =
            maybe_refresh_tokens(&path, "user@example.com", &expired, &cfg, &client)
                .await
                .unwrap();

        assert!(refreshed);
        assert_eq!(tokens.access_token, "fresh-tok");
    }

    #[test]
    fn save_and_get_oauth_credentials() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        save_oauth_credentials(&path, "my-client-id", "my-secret").unwrap();

        let (id, secret) = get_oauth_credentials(&path).unwrap();
        assert_eq!(id, "my-client-id");
        assert_eq!(secret, "my-secret");
    }
}
