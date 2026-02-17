//! Google/Gemini OAuth implementation.
//!
//! Supports two endpoints:
//! - **Cloud Code Assist**: Production endpoint requiring project discovery.
//! - **Antigravity**: Free tier/sandbox with default project fallback.

use super::errors::AuthError;
use super::types::{
    GoogleAuth, GoogleOAuthEndpoint, OAuthConfig, OAuthTokens, ServerAuth,
    calculate_expires_at, now_ms,
};

/// Default project for Antigravity free tier.
pub const ANTIGRAVITY_DEFAULT_PROJECT: &str = "rising-fact-p41fc";

/// Cloud Code Assist OAuth configuration.
pub fn cloud_code_assist_config() -> GoogleOAuthConfig {
    GoogleOAuthConfig {
        oauth: OAuthConfig {
            auth_url: "https://accounts.google.com/o/oauth2/v2/auth".to_string(),
            token_url: "https://oauth2.googleapis.com/token".to_string(),
            redirect_uri: "http://localhost:45289".to_string(),
            client_id: String::new(),
            client_secret: None,
            scopes: vec![
                "https://www.googleapis.com/auth/cloud-platform".to_string(),
                "https://www.googleapis.com/auth/userinfo.email".to_string(),
                "openid".to_string(),
            ],
            token_expiry_buffer_seconds: 300,
        },
        api_endpoint: "https://cloudcode-pa.googleapis.com".to_string(),
        api_version: "v1internal".to_string(),
    }
}

/// Antigravity OAuth configuration.
pub fn antigravity_config() -> GoogleOAuthConfig {
    GoogleOAuthConfig {
        oauth: OAuthConfig {
            auth_url: "https://accounts.google.com/o/oauth2/v2/auth".to_string(),
            token_url: "https://oauth2.googleapis.com/token".to_string(),
            redirect_uri: "http://localhost:51121/oauth-callback".to_string(),
            client_id: String::new(),
            client_secret: None,
            scopes: vec![
                "https://www.googleapis.com/auth/cloud-platform".to_string(),
                "https://www.googleapis.com/auth/userinfo.email".to_string(),
                "https://www.googleapis.com/auth/userinfo.profile".to_string(),
                "https://www.googleapis.com/auth/cclog".to_string(),
                "https://www.googleapis.com/auth/experimentsandconfigs".to_string(),
                "openid".to_string(),
            ],
            token_expiry_buffer_seconds: 300,
        },
        api_endpoint: "https://daily-cloudcode-pa.sandbox.googleapis.com".to_string(),
        api_version: "v1internal".to_string(),
    }
}

/// Get the appropriate config for a Google OAuth endpoint.
pub fn get_config(endpoint: GoogleOAuthEndpoint) -> GoogleOAuthConfig {
    match endpoint {
        GoogleOAuthEndpoint::CloudCodeAssist => cloud_code_assist_config(),
        GoogleOAuthEndpoint::Antigravity => antigravity_config(),
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
        urlencoded(&config.oauth.client_id),
        urlencoded(&config.oauth.redirect_uri),
        urlencoded(&config.oauth.scopes.join(" ")),
        urlencoded(challenge),
    )
}

/// Exchange authorization code for tokens.
#[tracing::instrument(skip_all)]
pub async fn exchange_code_for_tokens(
    config: &GoogleOAuthConfig,
    code: &str,
    verifier: &str,
) -> Result<OAuthTokens, AuthError> {
    exchange_code_for_tokens_with_client(config, code, verifier, &reqwest::Client::new()).await
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
    let body_with_secret: Vec<(&str, &str)> = if let Some(ref secret) = config.oauth.client_secret
    {
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
        expires_at: calculate_expires_at(
            data.expires_in,
            config.oauth.token_expiry_buffer_seconds,
        ),
    })
}

/// Refresh an expired OAuth token.
#[tracing::instrument(skip_all, fields(provider = "google"))]
pub async fn refresh_token(
    config: &GoogleOAuthConfig,
    refresh_token: &str,
) -> Result<OAuthTokens, AuthError> {
    refresh_token_with_client(config, refresh_token, &reqwest::Client::new()).await
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
    let body_with_secret: Vec<(&str, &str)> = if let Some(ref secret) = config.oauth.client_secret
    {
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
        expires_at: calculate_expires_at(
            data.expires_in,
            config.oauth.token_expiry_buffer_seconds,
        ),
    })
}

/// Check if a token looks like a Google OAuth token.
///
/// Google access tokens start with `ya29.` or are JWTs (3 dot-separated parts).
pub fn is_oauth_token(token: &str) -> bool {
    token.starts_with("ya29.") || token.split('.').count() == 3
}

/// Build the Gemini API URL for a model action.
///
/// OAuth uses `/{api_version}:{action}` (model in request body).
/// API key uses `/v1beta/models/{model}:{action}` (standard Gemini format).
pub fn get_api_url(auth: &GoogleAuth, model: &str, action: &str) -> String {
    if auth.auth.is_oauth() {
        let endpoint = auth
            .api_endpoint
            .as_deref()
            .unwrap_or("https://cloudcode-pa.googleapis.com");
        let version = auth.api_version.as_deref().unwrap_or("v1internal");
        format!("{endpoint}/{version}:{action}")
    } else {
        format!(
            "https://generativelanguage.googleapis.com/v1beta/models/{model}:{action}"
        )
    }
}

/// Build request headers for Gemini API calls.
pub fn get_api_headers(auth: &GoogleAuth) -> Vec<(String, String)> {
    let mut headers = vec![("Content-Type".to_string(), "application/json".to_string())];

    match &auth.auth {
        ServerAuth::OAuth { access_token, .. } => {
            headers.push(("Authorization".to_string(), format!("Bearer {access_token}")));
        }
        ServerAuth::ApiKey { api_key } => {
            headers.push(("x-goog-api-key".to_string(), api_key.clone()));
        }
    }

    if let Some(project) = &auth.project_id {
        headers.push(("x-goog-user-project".to_string(), project.clone()));
    }

    headers
}

/// Load server auth from auth storage.
///
/// Priority:
/// 1. `env_token` (pre-configured OAuth token)
/// 2. OAuth tokens from `auth.json` (auto-refresh if expired)
/// 3. `env_api_key` (env var API key)
/// 4. API key from `auth.json`
#[tracing::instrument(skip_all, fields(provider = "google"))]
pub async fn load_server_auth(
    auth_path: &std::path::Path,
    env_token: Option<&str>,
    env_api_key: Option<&str>,
) -> Result<Option<GoogleAuth>, AuthError> {
    load_server_auth_with_client(auth_path, env_token, env_api_key, &reqwest::Client::new()).await
}

/// Load server auth using a shared HTTP client for token refresh.
#[tracing::instrument(skip_all, fields(provider = "google"))]
pub async fn load_server_auth_with_client(
    auth_path: &std::path::Path,
    env_token: Option<&str>,
    env_api_key: Option<&str>,
    client: &reqwest::Client,
) -> Result<Option<GoogleAuth>, AuthError> {
    // 1. Env var OAuth token
    if let Some(token) = env_token {
        return Ok(Some(GoogleAuth {
            auth: ServerAuth::OAuth {
                access_token: token.to_string(),
                refresh_token: String::new(),
                expires_at: i64::MAX,
                account_label: None,
            },
            endpoint: None,
            api_endpoint: None,
            api_version: None,
            project_id: None,
        }));
    }

    // 2. OAuth from auth.json
    let gpa = super::storage::get_google_provider_auth(auth_path);
    if let Some(ref gpa) = gpa {
        if let Some(oauth) = &gpa.base.oauth {
            let endpoint = gpa.endpoint.unwrap_or(GoogleOAuthEndpoint::Antigravity);
            let cfg = get_config(endpoint);

            // Use stored client credentials for refresh
            let cfg_with_creds = GoogleOAuthConfig {
                oauth: OAuthConfig {
                    client_id: gpa.client_id.clone().unwrap_or(cfg.oauth.client_id),
                    client_secret: gpa.client_secret.clone().or(cfg.oauth.client_secret),
                    ..cfg.oauth
                },
                ..cfg
            };

            match maybe_refresh_tokens(oauth, &cfg_with_creds, client).await {
                Ok((tokens, refreshed)) => {
                    if refreshed {
                        tracing::info!("persisting refreshed Google tokens");
                        // Update the stored OAuth tokens in the google provider auth
                        let mut updated_gpa = gpa.clone();
                        updated_gpa.base.oauth = Some(tokens.clone());
                        let _ = super::storage::save_google_provider_auth(
                            auth_path, &updated_gpa,
                        );
                    }
                    return Ok(Some(GoogleAuth {
                        auth: ServerAuth::from_oauth(&tokens, None),
                        endpoint: Some(endpoint),
                        api_endpoint: Some(cfg_with_creds.api_endpoint),
                        api_version: Some(cfg_with_creds.api_version),
                        project_id: gpa.project_id.clone(),
                    }));
                }
                Err(e) => {
                    tracing::warn!("Google OAuth refresh failed: {e}");
                }
            }
        }
    }

    // 3. Env var API key
    if let Some(key) = env_api_key {
        return Ok(Some(GoogleAuth {
            auth: ServerAuth::from_api_key(key),
            endpoint: None,
            api_endpoint: None,
            api_version: None,
            project_id: None,
        }));
    }

    // 4. API key from auth.json
    if let Some(gpa) = &gpa {
        if let Some(key) = &gpa.base.api_key {
            return Ok(Some(GoogleAuth {
                auth: ServerAuth::from_api_key(key),
                endpoint: None,
                api_endpoint: None,
                api_version: None,
                project_id: None,
            }));
        }
    }

    Ok(None)
}

/// Refresh tokens if expired, returning `(tokens, was_refreshed)`.
async fn maybe_refresh_tokens(
    tokens: &OAuthTokens,
    config: &GoogleOAuthConfig,
    client: &reqwest::Client,
) -> Result<(OAuthTokens, bool), AuthError> {
    let buffer_ms = config.oauth.token_expiry_buffer_seconds * 1000;
    if now_ms() + buffer_ms < tokens.expires_at {
        return Ok((tokens.clone(), false));
    }

    tracing::info!("Google OAuth token expired, refreshing...");
    match refresh_token_with_client(config, &tokens.refresh_token, client).await {
        Ok(new_tokens) => {
            metrics::counter!("auth_refresh_total", "provider" => "google", "status" => "success").increment(1);
            Ok((new_tokens, true))
        }
        Err(e) => {
            metrics::counter!("auth_refresh_total", "provider" => "google", "status" => "failure").increment(1);
            Err(e)
        }
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
    endpoint: GoogleOAuthEndpoint,
) -> Result<(), AuthError> {
    let mut gpa = super::storage::get_google_provider_auth(auth_path)
        .unwrap_or_default();
    gpa.client_id = Some(client_id.to_string());
    gpa.client_secret = Some(client_secret.to_string());
    gpa.endpoint = Some(endpoint);
    super::storage::save_google_provider_auth(auth_path, &gpa)
}

/// Get stored Google OAuth credentials.
pub fn get_oauth_credentials(
    auth_path: &std::path::Path,
) -> Option<(String, String)> {
    let gpa = super::storage::get_google_provider_auth(auth_path)?;
    let id = gpa.client_id?;
    let secret = gpa.client_secret?;
    Some((id, secret))
}

/// Simple URL encoding.
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
    use crate::auth::types::GoogleProviderAuth;

    #[test]
    fn cloud_code_assist_config_values() {
        let cfg = cloud_code_assist_config();
        assert!(cfg.oauth.auth_url.contains("accounts.google.com"));
        assert!(cfg.api_endpoint.contains("cloudcode-pa"));
        assert_eq!(cfg.api_version, "v1internal");
    }

    #[test]
    fn antigravity_config_values() {
        let cfg = antigravity_config();
        assert!(cfg.api_endpoint.contains("sandbox"));
        assert!(cfg.oauth.scopes.len() > 3);
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

    #[test]
    fn api_url_oauth_format() {
        let auth = GoogleAuth {
            auth: ServerAuth::OAuth {
                access_token: "tok".to_string(),
                refresh_token: "ref".to_string(),
                expires_at: 0,
                account_label: None,
            },
            endpoint: Some(GoogleOAuthEndpoint::CloudCodeAssist),
            api_endpoint: Some("https://cloudcode-pa.googleapis.com".to_string()),
            api_version: Some("v1internal".to_string()),
            project_id: Some("proj-123".to_string()),
        };
        let url = get_api_url(&auth, "gemini-2.0-flash", "generateContent");
        assert_eq!(
            url,
            "https://cloudcode-pa.googleapis.com/v1internal:generateContent"
        );
    }

    #[test]
    fn api_url_api_key_format() {
        let auth = GoogleAuth {
            auth: ServerAuth::from_api_key("key-123"),
            endpoint: None,
            api_endpoint: None,
            api_version: None,
            project_id: None,
        };
        let url = get_api_url(&auth, "gemini-2.0-flash", "generateContent");
        assert_eq!(
            url,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
        );
    }

    #[test]
    fn api_headers_oauth() {
        let auth = GoogleAuth {
            auth: ServerAuth::OAuth {
                access_token: "ya29.abc".to_string(),
                refresh_token: "ref".to_string(),
                expires_at: 0,
                account_label: None,
            },
            endpoint: None,
            api_endpoint: None,
            api_version: None,
            project_id: Some("my-proj".to_string()),
        };
        let headers = get_api_headers(&auth);
        assert!(headers.iter().any(|(k, v)| k == "Authorization" && v.contains("ya29.abc")));
        assert!(headers.iter().any(|(k, v)| k == "x-goog-user-project" && v == "my-proj"));
    }

    #[test]
    fn api_headers_api_key() {
        let auth = GoogleAuth {
            auth: ServerAuth::from_api_key("key-123"),
            endpoint: None,
            api_endpoint: None,
            api_version: None,
            project_id: None,
        };
        let headers = get_api_headers(&auth);
        assert!(headers.iter().any(|(k, v)| k == "x-goog-api-key" && v == "key-123"));
        assert!(!headers.iter().any(|(k, _)| k == "x-goog-user-project"));
    }

    #[tokio::test]
    async fn load_server_auth_env_token() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let result = load_server_auth(&path, Some("env-tok"), None)
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(auth.auth.is_oauth());
        assert_eq!(auth.auth.token(), "env-tok");
    }

    #[tokio::test]
    async fn load_server_auth_env_api_key() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        let result = load_server_auth(&path, None, Some("env-key"))
            .await
            .unwrap();
        let auth = result.unwrap();
        assert!(!auth.auth.is_oauth());
        assert_eq!(auth.auth.token(), "env-key");
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

        let gpa = GoogleProviderAuth {
            base: crate::auth::types::ProviderAuth {
                oauth: Some(OAuthTokens {
                    access_token: "ya29.fresh".to_string(),
                    refresh_token: "ref".to_string(),
                    expires_at: now_ms() + 3_600_000,
                }),
                ..Default::default()
            },
            endpoint: Some(GoogleOAuthEndpoint::Antigravity),
            ..Default::default()
        };
        crate::auth::storage::save_google_provider_auth(&path, &gpa).unwrap();

        let result = load_server_auth(&path, None, None).await.unwrap();
        let auth = result.unwrap();
        assert_eq!(auth.auth.token(), "ya29.fresh");
        assert_eq!(auth.endpoint, Some(GoogleOAuthEndpoint::Antigravity));
    }

    #[test]
    fn save_and_get_oauth_credentials() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("auth.json");

        save_oauth_credentials(
            &path,
            "my-client-id",
            "my-secret",
            GoogleOAuthEndpoint::CloudCodeAssist,
        )
        .unwrap();

        let (id, secret) = get_oauth_credentials(&path).unwrap();
        assert_eq!(id, "my-client-id");
        assert_eq!(secret, "my-secret");
    }
}
