//! Auth handlers: get, update, clear, oauthBegin, oauthComplete.
//!
//! Manages provider API keys and OAuth tokens stored in `auth.json`.
//! All handlers return masked key hints — full secrets are never sent over the wire.

use std::collections::HashMap;
use std::path::Path;

use async_trait::async_trait;
use serde_json::{Value, json};
use tracing::instrument;

use crate::llm::auth::storage::{
    acquire_auth_file_lock, clear_provider_auth, load_auth_storage, save_auth_storage,
    save_provider_api_key, save_provider_oauth_tokens,
};
use crate::llm::auth::types::{
    AuthStorage, GoogleOAuthEndpoint, GoogleProviderAuth, OAuthTokens, ProviderAuth, ServiceAuth,
};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;
use crate::server::rpc::types::RpcEvent;

/// Known LLM provider identifiers.
const KNOWN_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google", "minimax", "kimi"];

/// Known service identifiers.
const KNOWN_SERVICES: &[&str] = &["brave", "exa"];

// ─── Masking ─────────────────────────────────────────────────────────────────

/// Mask an API key for safe display. Shows prefix up to second dash and last 4 chars.
fn mask_key(key: &str) -> String {
    if key.len() <= 8 {
        return "***".to_string();
    }
    let prefix_end = key
        .find('-')
        .map(|i| {
            // Find second dash for "sk-ant-..." style keys
            key[i + 1..]
                .find('-')
                .map(|j| i + 1 + j + 1)
                .unwrap_or(i + 1)
        })
        .unwrap_or(4)
        .min(10);
    let suffix_start = key.len().saturating_sub(4);
    format!("{}...{}", &key[..prefix_end], &key[suffix_start..])
}

// ─── Masked state builder ────────────────────────────────────────────────────

/// Build the masked auth state response from raw storage.
#[allow(unused_must_use)]
fn build_masked_state(auth_path: &Path) -> Value {
    let storage = load_auth_storage(auth_path);

    let mut providers = serde_json::Map::new();

    for &provider in KNOWN_PROVIDERS {
        if provider == "google" {
            let google = storage
                .as_ref()
                .and_then(|s| s.get_google_auth());

            let mut info = serde_json::Map::new();
            if let Some(ref g) = google {
                let has_key = g.base.api_key.is_some();
                let _ = info.insert("hasApiKey".into(), json!(has_key));
                if let Some(ref key) = g.base.api_key {
                    info.insert("apiKeyHint".into(), json!(mask_key(key)));
                }
                info.insert("hasOAuth".into(), json!(g.base.oauth.is_some()));

                // Google-specific fields
                if let Some(ref ep) = g.endpoint {
                    let ep_str = match ep {
                        GoogleOAuthEndpoint::CloudCodeAssist => "cloud-code-assist",
                        GoogleOAuthEndpoint::Antigravity => "antigravity",
                    };
                    info.insert("endpoint".into(), json!(ep_str));
                }
                if let Some(ref pid) = g.project_id {
                    info.insert("projectId".into(), json!(pid));
                }
                info.insert("hasClientId".into(), json!(g.client_id.is_some()));
                info.insert("hasClientSecret".into(), json!(g.client_secret.is_some()));

                // Accounts
                let accounts = build_accounts_list(&g.base);
                info.insert("accounts".into(), json!(accounts));
            } else {
                info.insert("hasApiKey".into(), json!(false));
                info.insert("hasOAuth".into(), json!(false));
                info.insert("hasClientId".into(), json!(false));
                info.insert("hasClientSecret".into(), json!(false));
                info.insert("accounts".into(), json!([]));
            }

            providers.insert(provider.to_string(), Value::Object(info));
        } else {
            let pa = storage
                .as_ref()
                .and_then(|s| s.get_provider_auth(provider));

            let mut info = serde_json::Map::new();
            if let Some(ref pa) = pa {
                info.insert("hasApiKey".into(), json!(pa.api_key.is_some()));
                if let Some(ref key) = pa.api_key {
                    info.insert("apiKeyHint".into(), json!(mask_key(key)));
                }
                info.insert("hasOAuth".into(), json!(pa.oauth.is_some()));

                if let Some(ref oauth) = pa.oauth {
                    info.insert("oauthExpiresAt".into(), json!(oauth.expires_at));
                    let is_expired =
                        crate::llm::auth::types::now_ms() >= oauth.expires_at;
                    info.insert("isOAuthExpired".into(), json!(is_expired));
                }

                let accounts = build_accounts_list(pa);
                info.insert("accounts".into(), json!(accounts));
            } else {
                info.insert("hasApiKey".into(), json!(false));
                info.insert("hasOAuth".into(), json!(false));
                info.insert("accounts".into(), json!([]));
            }

            providers.insert(provider.to_string(), Value::Object(info));
        }
    }

    // Services
    let mut services = serde_json::Map::new();
    for &service in KNOWN_SERVICES {
        let svc = storage
            .as_ref()
            .and_then(|s| s.get_service_auth(service));

        let mut info = serde_json::Map::new();
        if let Some(svc) = svc {
            let has_key = svc.api_key.is_some()
                || svc.api_keys.as_ref().map_or(false, |k| !k.is_empty());
            info.insert("hasApiKey".into(), json!(has_key));
            if let Some(ref key) = svc.api_key {
                info.insert("apiKeyHint".into(), json!(mask_key(key)));
            } else if let Some(ref keys) = svc.api_keys {
                if let Some(first) = keys.first() {
                    info.insert("apiKeyHint".into(), json!(mask_key(first)));
                }
            }
        } else {
            info.insert("hasApiKey".into(), json!(false));
        }
        services.insert(service.to_string(), Value::Object(info));
    }

    json!({
        "providers": Value::Object(providers),
        "services": Value::Object(services),
    })
}

/// Build accounts list from provider auth (masked).
fn build_accounts_list(pa: &ProviderAuth) -> Vec<Value> {
    pa.accounts
        .as_ref()
        .map(|accts| {
            accts
                .iter()
                .map(|a| {
                    let is_expired =
                        crate::llm::auth::types::now_ms() >= a.oauth.expires_at;
                    json!({
                        "label": a.label,
                        "expiresAt": a.oauth.expires_at,
                        "isExpired": is_expired,
                        "hasRefreshToken": !a.oauth.refresh_token.is_empty(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Broadcast the `auth.updated` event to all connected clients.
async fn broadcast_auth_updated(ctx: &RpcContext, masked_state: &Value) {
    if let Some(ref bm) = ctx.broadcast_manager {
        let event = RpcEvent::new("auth.updated", None, Some(masked_state.clone()));
        bm.broadcast_all(&event).await;
    }
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// Get masked auth state for all providers and services.
pub struct GetAuthHandler;

#[async_trait]
impl MethodHandler for GetAuthHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.get"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let auth_path = ctx.auth_path.clone();
        ctx.run_blocking("auth.get", move || Ok(build_masked_state(&auth_path)))
            .await
    }
}

/// Update auth for a provider or service.
pub struct UpdateAuthHandler;

#[async_trait]
impl MethodHandler for UpdateAuthHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = opt_string(params.as_ref(), "provider");
        let service = opt_string(params.as_ref(), "service");

        if provider.is_none() && service.is_none() {
            return Err(RpcError::InvalidParams {
                message: "Missing required parameter: provider or service".into(),
            });
        }

        let auth_path = ctx.auth_path.clone();
        let params_clone = params.clone();

        let masked_state = ctx
            .run_blocking("auth.update", move || {
                // Acquire file lock for write
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| {
                    RpcError::Internal {
                        message: format!("Failed to acquire auth lock: {e}"),
                    }
                })?;

                if let Some(ref provider) = provider {
                    // Validate provider name
                    if !KNOWN_PROVIDERS.contains(&provider.as_str()) {
                        return Err(RpcError::InvalidParams {
                            message: format!("Unknown provider: {provider}"),
                        });
                    }

                    if provider == "google" {
                        update_google_provider(&auth_path, params_clone.as_ref())?;
                    } else {
                        update_standard_provider(&auth_path, provider, params_clone.as_ref())?;
                    }
                } else if let Some(ref service) = service {
                    update_service(&auth_path, service, params_clone.as_ref())?;
                }

                Ok(build_masked_state(&auth_path))
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

/// Clear auth for a provider or service.
pub struct ClearAuthHandler;

#[async_trait]
impl MethodHandler for ClearAuthHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.clear"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = opt_string(params.as_ref(), "provider");
        let service = opt_string(params.as_ref(), "service");

        if provider.is_none() && service.is_none() {
            return Err(RpcError::InvalidParams {
                message: "Missing required parameter: provider or service".into(),
            });
        }

        let auth_path = ctx.auth_path.clone();

        let masked_state = ctx
            .run_blocking("auth.clear", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| {
                    RpcError::Internal {
                        message: format!("Failed to acquire auth lock: {e}"),
                    }
                })?;

                if let Some(ref provider) = provider {
                    clear_provider_auth(&auth_path, provider).map_err(|e| {
                        RpcError::Internal {
                            message: format!("Failed to clear provider auth: {e}"),
                        }
                    })?;
                } else if let Some(ref service) = service {
                    clear_service_auth(&auth_path, service).map_err(|e| {
                        RpcError::Internal {
                            message: format!("Failed to clear service auth: {e}"),
                        }
                    })?;
                }

                Ok(build_masked_state(&auth_path))
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

// ─── OAuth Flow ──────────────────────────────────────────────────────────────

/// In-memory state for a pending OAuth flow.
pub struct PendingOAuthFlow {
    pub verifier: String,
    pub provider: String,
    pub created_at: std::time::Instant,
}

/// Begin an OAuth flow: generate PKCE, return auth URL + flow ID.
pub struct OAuthBeginHandler;

#[async_trait]
impl MethodHandler for OAuthBeginHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.oauthBegin"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = require_string_param(params.as_ref(), "provider")?;
        if provider != "anthropic" {
            return Err(RpcError::InvalidParams {
                message: "OAuth login is only supported for anthropic".into(),
            });
        }

        let pair = crate::llm::auth::pkce::generate_pkce();
        let config = crate::llm::auth::anthropic::default_config();
        let flow_id = uuid::Uuid::now_v7().to_string();
        // Use verifier as state (matches tron login CLI behavior)
        let auth_url = crate::llm::auth::anthropic::get_authorization_url_with_state(
            &config, &pair.challenge, Some(&pair.verifier),
        );

        let mut flows = ctx.oauth_flows.lock().await;

        // Lazy cleanup: remove expired flows (>10 minutes)
        flows.retain(|_, f| f.created_at.elapsed() < std::time::Duration::from_secs(600));

        let _ = flows.insert(
            flow_id.clone(),
            PendingOAuthFlow {
                verifier: pair.verifier,
                provider,
                created_at: std::time::Instant::now(),
            },
        );

        Ok(json!({
            "flowId": flow_id,
            "authUrl": auth_url,
        }))
    }
}

/// Complete an OAuth flow: exchange code for tokens, save to auth.json.
pub struct OAuthCompleteHandler;

#[async_trait]
impl MethodHandler for OAuthCompleteHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.oauthComplete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let flow_id = require_string_param(params.as_ref(), "flowId")?;
        let code = require_string_param(params.as_ref(), "code")?;
        let label = require_string_param(params.as_ref(), "label")?;

        // Remove flow from map (single-use)
        let flow = {
            let mut flows = ctx.oauth_flows.lock().await;
            flows.remove(&flow_id)
        };

        let flow = flow.ok_or_else(|| RpcError::InvalidParams {
            message: "OAuth flow not found or expired".into(),
        })?;

        if flow.created_at.elapsed() > std::time::Duration::from_secs(600) {
            return Err(RpcError::InvalidParams {
                message: "OAuth flow expired".into(),
            });
        }

        // Exchange code for tokens (HTTP call to Anthropic)
        // Pass verifier as state (matches tron login CLI behavior)
        let config = crate::llm::auth::anthropic::default_config();
        let tokens = crate::llm::auth::anthropic::exchange_code_for_tokens(
            &config, &code, &flow.verifier, Some(&flow.verifier),
        )
        .await
        .map_err(|e| RpcError::Internal {
            message: format!("Token exchange failed: {e}"),
        })?;

        // Save tokens to auth.json
        let auth_path = ctx.auth_path.clone();
        let label_clone = label.clone();
        let tokens_clone = tokens.clone();
        let masked_state = ctx
            .run_blocking("auth.oauthComplete", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to acquire auth lock: {e}"),
                })?;

                crate::llm::auth::storage::save_account_oauth_tokens(
                    &auth_path,
                    "anthropic",
                    &label_clone,
                    &tokens_clone,
                )
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to save OAuth tokens: {e}"),
                })?;

                Ok(build_masked_state(&auth_path))
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

/// Rename an OAuth account label.
pub struct RenameAccountHandler;

#[async_trait]
impl MethodHandler for RenameAccountHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.renameAccount"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = require_string_param(params.as_ref(), "provider")?;
        let old_label = require_string_param(params.as_ref(), "oldLabel")?;
        let new_label = require_string_param(params.as_ref(), "newLabel")?;

        let auth_path = ctx.auth_path.clone();
        let masked_state = ctx
            .run_blocking("auth.renameAccount", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to acquire auth lock: {e}"),
                })?;

                crate::llm::auth::storage::rename_account(
                    &auth_path, &provider, &old_label, &new_label,
                )
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to rename account: {e}"),
                })?;

                Ok(build_masked_state(&auth_path))
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

// ─── Update helpers ──────────────────────────────────────────────────────────

fn update_standard_provider(
    auth_path: &Path,
    provider: &str,
    params: Option<&Value>,
) -> Result<(), RpcError> {
    let params = params.ok_or_else(|| RpcError::InvalidParams {
        message: "Missing parameters".into(),
    })?;

    // Handle API key: present string = set, null = clear, absent = preserve
    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            // Clear API key but preserve other fields
            let mut storage = load_auth_storage(auth_path).unwrap_or_default();
            if let Some(mut pa) = storage.get_provider_auth(provider) {
                pa.api_key = None;
                storage.set_provider_auth(provider, &pa);
                save_auth_storage(auth_path, &mut storage).map_err(|e| RpcError::Internal {
                    message: format!("Failed to save auth: {e}"),
                })?;
            }
        } else if let Some(key) = api_key_val.as_str() {
            save_provider_api_key(auth_path, provider, key).map_err(|e| RpcError::Internal {
                message: format!("Failed to save API key: {e}"),
            })?;
        }
    }

    // Handle OAuth tokens
    if let Some(oauth) = params.get("oauth") {
        if oauth.is_null() {
            let mut storage = load_auth_storage(auth_path).unwrap_or_default();
            if let Some(mut pa) = storage.get_provider_auth(provider) {
                pa.oauth = None;
                storage.set_provider_auth(provider, &pa);
                save_auth_storage(auth_path, &mut storage).map_err(|e| RpcError::Internal {
                    message: format!("Failed to save auth: {e}"),
                })?;
            }
        } else {
            let tokens = parse_oauth_tokens(oauth)?;
            save_provider_oauth_tokens(auth_path, provider, &tokens).map_err(|e| {
                RpcError::Internal {
                    message: format!("Failed to save OAuth tokens: {e}"),
                }
            })?;
        }
    }

    Ok(())
}

fn update_google_provider(
    auth_path: &Path,
    params: Option<&Value>,
) -> Result<(), RpcError> {
    let params = params.ok_or_else(|| RpcError::InvalidParams {
        message: "Missing parameters".into(),
    })?;

    // Load existing or default
    let mut storage = load_auth_storage(auth_path).unwrap_or_default();
    let mut google = storage.get_google_auth().unwrap_or_default();

    // API key
    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            google.base.api_key = None;
        } else if let Some(key) = api_key_val.as_str() {
            google.base.api_key = Some(key.to_string());
        }
    }

    // Client ID
    if let Some(val) = params.get("clientId") {
        if val.is_null() {
            google.client_id = None;
        } else if let Some(s) = val.as_str() {
            google.client_id = Some(s.to_string());
        }
    }

    // Client secret
    if let Some(val) = params.get("clientSecret") {
        if val.is_null() {
            google.client_secret = None;
        } else if let Some(s) = val.as_str() {
            google.client_secret = Some(s.to_string());
        }
    }

    // Endpoint
    if let Some(val) = params.get("endpoint") {
        if val.is_null() {
            google.endpoint = None;
        } else if let Some(s) = val.as_str() {
            google.endpoint = match s {
                "cloud-code-assist" => Some(GoogleOAuthEndpoint::CloudCodeAssist),
                "antigravity" => Some(GoogleOAuthEndpoint::Antigravity),
                _ => {
                    return Err(RpcError::InvalidParams {
                        message: format!("Unknown endpoint: {s}"),
                    })
                }
            };
        }
    }

    // Project ID
    if let Some(val) = params.get("projectId") {
        if val.is_null() {
            google.project_id = None;
        } else if let Some(s) = val.as_str() {
            google.project_id = Some(s.to_string());
        }
    }

    // OAuth
    if let Some(oauth) = params.get("oauth") {
        if oauth.is_null() {
            google.base.oauth = None;
        } else {
            let tokens = parse_oauth_tokens(oauth)?;
            google.base.oauth = Some(tokens);
        }
    }

    storage.set_google_auth(&google);
    save_auth_storage(auth_path, &mut storage).map_err(|e| RpcError::Internal {
        message: format!("Failed to save auth: {e}"),
    })?;

    Ok(())
}

fn update_service(
    auth_path: &Path,
    service: &str,
    params: Option<&Value>,
) -> Result<(), RpcError> {
    let params = params.ok_or_else(|| RpcError::InvalidParams {
        message: "Missing parameters".into(),
    })?;

    let mut storage = load_auth_storage(auth_path).unwrap_or_default();
    let services = storage.services.get_or_insert_with(HashMap::new);

    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            // Clear the service key
            let _ = services.remove(service);
        } else if let Some(key) = api_key_val.as_str() {
            let _ = services.insert(
                service.to_string(),
                ServiceAuth {
                    api_key: Some(key.to_string()),
                    api_keys: None,
                },
            );
        }
    }

    save_auth_storage(auth_path, &mut storage).map_err(|e| RpcError::Internal {
        message: format!("Failed to save auth: {e}"),
    })?;

    Ok(())
}

fn clear_service_auth(auth_path: &Path, service: &str) -> Result<(), crate::llm::auth::errors::AuthError> {
    let Some(mut storage) = load_auth_storage(auth_path) else {
        return Ok(());
    };
    if let Some(ref mut services) = storage.services {
        let _ = services.remove(service);
    }
    save_auth_storage(auth_path, &mut storage)
}

fn parse_oauth_tokens(oauth: &Value) -> Result<OAuthTokens, RpcError> {
    let access_token = oauth
        .get("accessToken")
        .and_then(|v| v.as_str())
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.accessToken is required".into(),
        })?
        .to_string();

    let refresh_token = oauth
        .get("refreshToken")
        .and_then(|v| v.as_str())
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.refreshToken is required".into(),
        })?
        .to_string();

    let expires_at = oauth
        .get("expiresAt")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.expiresAt is required (milliseconds)".into(),
        })?;

    Ok(OAuthTokens {
        access_token,
        refresh_token,
        expires_at,
    })
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::auth::storage::save_google_provider_auth;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use tempfile::TempDir;

    fn make_ctx_with_temp_auth() -> (RpcContext, TempDir) {
        let mut ctx = make_test_context();
        let dir = TempDir::new().unwrap();
        ctx.auth_path = dir.path().join("auth.json");
        (ctx, dir)
    }

    // ── mask_key ──

    #[test]
    fn mask_key_short() {
        assert_eq!(mask_key("abc"), "***");
        assert_eq!(mask_key("12345678"), "***");
    }

    #[test]
    fn mask_key_standard_anthropic() {
        let masked = mask_key("sk-ant-api03-abcdefghijklmnop");
        assert!(masked.starts_with("sk-ant-"));
        assert!(masked.ends_with("mnop"));
        assert!(masked.contains("..."));
    }

    #[test]
    fn mask_key_standard_openai() {
        let masked = mask_key("sk-proj-abcdefghijklmnop");
        assert!(masked.starts_with("sk-"));
        assert!(masked.ends_with("mnop"));
    }

    #[test]
    fn mask_key_empty() {
        assert_eq!(mask_key(""), "***");
    }

    // ── auth.get ──

    #[tokio::test]
    async fn auth_get_empty_returns_all_providers_unconfigured() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();

        let providers = result["providers"].as_object().unwrap();
        assert_eq!(providers.len(), 5);
        for &name in KNOWN_PROVIDERS {
            let p = &providers[name];
            assert_eq!(p["hasApiKey"], false);
            assert_eq!(p["hasOAuth"], false);
        }

        let services = result["services"].as_object().unwrap();
        assert_eq!(services.len(), 2);
        for &name in KNOWN_SERVICES {
            assert_eq!(services[name]["hasApiKey"], false);
        }
    }

    #[tokio::test]
    async fn auth_get_with_api_key_returns_masked_hint() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        save_provider_api_key(&ctx.auth_path, "anthropic", "sk-ant-api03-abcdefghijklmnop")
            .unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        let anthropic = &result["providers"]["anthropic"];
        assert_eq!(anthropic["hasApiKey"], true);
        let hint = anthropic["apiKeyHint"].as_str().unwrap();
        assert!(hint.contains("..."));
        assert!(!hint.contains("abcdefghijklmnop"));
    }

    #[tokio::test]
    async fn auth_get_masks_key_correctly_short_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        save_provider_api_key(&ctx.auth_path, "minimax", "short").unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["providers"]["minimax"]["apiKeyHint"], "***");
    }

    #[tokio::test]
    async fn auth_get_masks_key_correctly_long_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        save_provider_api_key(&ctx.auth_path, "anthropic", "sk-ant-api03-verylongkeyvalue1234")
            .unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        let hint = result["providers"]["anthropic"]["apiKeyHint"].as_str().unwrap();
        assert!(hint.starts_with("sk-ant-"));
        assert!(hint.ends_with("1234"));
    }

    #[tokio::test]
    async fn auth_get_shows_oauth_expiry_status() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let future_ms = crate::llm::auth::types::now_ms() + 3_600_000;
        let tokens = OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: future_ms,
        };
        save_provider_oauth_tokens(&ctx.auth_path, "anthropic", &tokens).unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        let anthropic = &result["providers"]["anthropic"];
        assert_eq!(anthropic["hasOAuth"], true);
        assert_eq!(anthropic["isOAuthExpired"], false);
    }

    #[tokio::test]
    async fn auth_get_shows_expired_oauth() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let tokens = OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: 0, // already expired
        };
        save_provider_oauth_tokens(&ctx.auth_path, "anthropic", &tokens).unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["providers"]["anthropic"]["isOAuthExpired"], true);
    }

    #[tokio::test]
    async fn auth_get_shows_accounts_list() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let tokens = OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: 1_700_000_000_000,
        };
        crate::llm::auth::storage::save_account_oauth_tokens(
            &ctx.auth_path,
            "anthropic",
            "moose@macbook",
            &tokens,
        )
        .unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        let accounts = result["providers"]["anthropic"]["accounts"].as_array().unwrap();
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0]["label"], "moose@macbook");
        assert_eq!(accounts[0]["expiresAt"], 1_700_000_000_000_i64);
    }

    #[tokio::test]
    async fn auth_get_google_returns_endpoint_and_project() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let gpa = GoogleProviderAuth {
            endpoint: Some(GoogleOAuthEndpoint::Antigravity),
            project_id: Some("my-project".into()),
            client_id: Some("cid".into()),
            client_secret: Some("csec".into()),
            ..Default::default()
        };
        save_google_provider_auth(&ctx.auth_path, &gpa).unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        let google = &result["providers"]["google"];
        assert_eq!(google["endpoint"], "antigravity");
        assert_eq!(google["projectId"], "my-project");
        assert_eq!(google["hasClientId"], true);
        assert_eq!(google["hasClientSecret"], true);
    }

    #[tokio::test]
    async fn auth_get_services_returns_brave_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        let mut storage = AuthStorage::new();
        let mut services = HashMap::new();
        let _ = services.insert(
            "brave".to_string(),
            ServiceAuth {
                api_key: Some("BSA-abcdefghijklmnop".into()),
                api_keys: None,
            },
        );
        storage.services = Some(services);
        save_auth_storage(&ctx.auth_path, &mut storage).unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        let brave = &result["services"]["brave"];
        assert_eq!(brave["hasApiKey"], true);
        let hint = brave["apiKeyHint"].as_str().unwrap();
        assert!(hint.contains("..."));
    }

    #[tokio::test]
    async fn auth_get_missing_file_returns_defaults() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        // Don't create any auth file
        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
        assert_eq!(result["services"]["brave"]["hasApiKey"], false);
    }

    // ── auth.update ──

    #[tokio::test]
    async fn auth_update_sets_api_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = UpdateAuthHandler
            .handle(
                Some(json!({"provider": "anthropic", "apiKey": "sk-ant-api03-newkey123456789"})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], true);
        let hint = result["providers"]["anthropic"]["apiKeyHint"].as_str().unwrap();
        assert!(hint.contains("..."));

        // Verify on disk
        let pa = crate::llm::auth::storage::get_provider_auth(&ctx.auth_path, "anthropic").unwrap();
        assert_eq!(pa.api_key.as_deref(), Some("sk-ant-api03-newkey123456789"));
    }

    #[tokio::test]
    async fn auth_update_sets_oauth_tokens() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = UpdateAuthHandler
            .handle(
                Some(json!({
                    "provider": "anthropic",
                    "oauth": {
                        "accessToken": "at-123",
                        "refreshToken": "rt-456",
                        "expiresAt": 9999999999999_i64
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["providers"]["anthropic"]["hasOAuth"], true);
        assert_eq!(result["providers"]["anthropic"]["isOAuthExpired"], false);
    }

    #[tokio::test]
    async fn auth_update_sets_google_with_all_fields() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = UpdateAuthHandler
            .handle(
                Some(json!({
                    "provider": "google",
                    "apiKey": "ya29.abcdefghijklmnop",
                    "clientId": "client-id-123",
                    "clientSecret": "client-secret-456",
                    "endpoint": "antigravity",
                    "projectId": "my-gcp-project"
                })),
                &ctx,
            )
            .await
            .unwrap();

        let google = &result["providers"]["google"];
        assert_eq!(google["hasApiKey"], true);
        assert_eq!(google["hasClientId"], true);
        assert_eq!(google["hasClientSecret"], true);
        assert_eq!(google["endpoint"], "antigravity");
        assert_eq!(google["projectId"], "my-gcp-project");
    }

    #[tokio::test]
    async fn auth_update_preserves_existing_fields() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        // Set API key first
        let _ = UpdateAuthHandler
            .handle(
                Some(json!({"provider": "anthropic", "apiKey": "sk-ant-api03-firstkey12345678"})),
                &ctx,
            )
            .await
            .unwrap();

        // Then set OAuth without touching API key
        let result = UpdateAuthHandler
            .handle(
                Some(json!({
                    "provider": "anthropic",
                    "oauth": {
                        "accessToken": "at",
                        "refreshToken": "rt",
                        "expiresAt": 9999999999999_i64
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        // Both should be present
        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], true);
        assert_eq!(result["providers"]["anthropic"]["hasOAuth"], true);
    }

    #[tokio::test]
    async fn auth_update_null_api_key_clears_it() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        // Set key first
        let _ = UpdateAuthHandler
            .handle(
                Some(json!({"provider": "anthropic", "apiKey": "sk-ant-api03-clearme123456789"})),
                &ctx,
            )
            .await
            .unwrap();

        // Clear with null
        let result = UpdateAuthHandler
            .handle(
                Some(json!({"provider": "anthropic", "apiKey": null})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
    }

    #[tokio::test]
    async fn auth_update_service_api_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = UpdateAuthHandler
            .handle(
                Some(json!({"service": "brave", "apiKey": "BSA-abcdefghijklmnop"})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["services"]["brave"]["hasApiKey"], true);
    }

    #[tokio::test]
    async fn auth_update_invalid_provider_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = UpdateAuthHandler
            .handle(
                Some(json!({"provider": "nonexistent", "apiKey": "key"})),
                &ctx,
            )
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("Unknown provider"));
    }

    #[tokio::test]
    async fn auth_update_missing_provider_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = UpdateAuthHandler
            .handle(Some(json!({"apiKey": "key"})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn auth_update_returns_updated_masked_state() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = UpdateAuthHandler
            .handle(
                Some(json!({"provider": "openai-codex", "apiKey": "sk-proj-abcdefghijklmnop"})),
                &ctx,
            )
            .await
            .unwrap();

        // Should contain all providers, not just the updated one
        assert_eq!(result["providers"].as_object().unwrap().len(), 5);
        assert_eq!(result["providers"]["openai-codex"]["hasApiKey"], true);
    }

    #[tokio::test]
    async fn auth_update_creates_file_if_missing() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        assert!(!ctx.auth_path.exists());

        let _ = UpdateAuthHandler
            .handle(
                Some(json!({"provider": "kimi", "apiKey": "kimi-key-abcdefghijklmnop"})),
                &ctx,
            )
            .await
            .unwrap();

        assert!(ctx.auth_path.exists());
    }

    // ── auth.clear ──

    #[tokio::test]
    async fn auth_clear_removes_provider() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        // Set up
        save_provider_api_key(&ctx.auth_path, "anthropic", "sk-ant-api03-clearme123456789").unwrap();

        let result = ClearAuthHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
    }

    #[tokio::test]
    async fn auth_clear_preserves_other_providers() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        save_provider_api_key(&ctx.auth_path, "anthropic", "sk-ant-api03-keep12345678901").unwrap();
        save_provider_api_key(&ctx.auth_path, "openai-codex", "sk-proj-remove12345678901").unwrap();

        let result = ClearAuthHandler
            .handle(Some(json!({"provider": "openai-codex"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], true);
        assert_eq!(result["providers"]["openai-codex"]["hasApiKey"], false);
    }

    #[tokio::test]
    async fn auth_clear_nonexistent_provider_is_ok() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = ClearAuthHandler
            .handle(Some(json!({"provider": "minimax"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["providers"]["minimax"]["hasApiKey"], false);
    }

    #[tokio::test]
    async fn auth_clear_service() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        // Set up
        let mut storage = AuthStorage::new();
        let mut services = HashMap::new();
        let _ = services.insert(
            "brave".to_string(),
            ServiceAuth {
                api_key: Some("BSA-key123456789012".into()),
                api_keys: None,
            },
        );
        storage.services = Some(services);
        save_auth_storage(&ctx.auth_path, &mut storage).unwrap();

        let result = ClearAuthHandler
            .handle(Some(json!({"service": "brave"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["services"]["brave"]["hasApiKey"], false);
    }

    #[tokio::test]
    async fn auth_clear_missing_file_is_ok() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        assert!(!ctx.auth_path.exists());

        let result = ClearAuthHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
    }

    // ── auth.oauthBegin ──

    #[tokio::test]
    async fn oauth_begin_returns_flow_id_and_auth_url() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        assert!(result["flowId"].as_str().is_some());
        assert!(!result["flowId"].as_str().unwrap().is_empty());
        assert!(result["authUrl"].as_str().is_some());
        assert!(!result["authUrl"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn oauth_begin_auth_url_contains_pkce_challenge() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("code_challenge="));
        assert!(url.contains("code_challenge_method=S256"));
    }

    #[tokio::test]
    async fn oauth_begin_auth_url_contains_client_id() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("client_id="));
    }

    #[tokio::test]
    async fn oauth_begin_auth_url_contains_redirect_uri() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("redirect_uri="));
    }

    #[tokio::test]
    async fn oauth_begin_auth_url_contains_scopes() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("scope="));
    }

    #[tokio::test]
    async fn oauth_begin_invalid_provider_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = OAuthBeginHandler
            .handle(Some(json!({"provider": "openai"})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("only supported for anthropic"));
    }

    #[tokio::test]
    async fn oauth_begin_missing_provider_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = OAuthBeginHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn oauth_begin_auth_url_contains_state() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("state="), "auth URL must contain state parameter");
    }

    #[tokio::test]
    async fn oauth_begin_stores_flow_in_context() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let flow_id = result["flowId"].as_str().unwrap();
        let flows = ctx.oauth_flows.lock().await;
        assert!(flows.contains_key(flow_id));
        assert_eq!(flows[flow_id].provider, "anthropic");
    }

    #[tokio::test]
    async fn oauth_begin_each_call_generates_unique_flow_id() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let r1 = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();
        let r2 = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        assert_ne!(r1["flowId"].as_str().unwrap(), r2["flowId"].as_str().unwrap());
    }

    #[tokio::test]
    async fn oauth_begin_cleans_up_expired_flows() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        // Insert an expired flow manually
        {
            let mut flows = ctx.oauth_flows.lock().await;
            flows.insert(
                "expired-flow".to_string(),
                PendingOAuthFlow {
                    verifier: "v".to_string(),
                    provider: "anthropic".to_string(),
                    created_at: std::time::Instant::now() - std::time::Duration::from_secs(700),
                },
            );
        }

        // Begin a new flow — should clean up expired
        let _ = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let flows = ctx.oauth_flows.lock().await;
        assert!(!flows.contains_key("expired-flow"));
    }

    // ── auth.oauthComplete ──

    #[tokio::test]
    async fn oauth_complete_invalid_flow_id_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = OAuthCompleteHandler
            .handle(
                Some(json!({"flowId": "nonexistent", "code": "abc", "label": "test"})),
                &ctx,
            )
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("not found or expired"));
    }

    #[tokio::test]
    async fn oauth_complete_missing_flow_id_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = OAuthCompleteHandler
            .handle(Some(json!({"code": "abc", "label": "test"})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn oauth_complete_missing_code_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = OAuthCompleteHandler
            .handle(Some(json!({"flowId": "abc", "label": "test"})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn oauth_complete_missing_label_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = OAuthCompleteHandler
            .handle(Some(json!({"flowId": "abc", "code": "test"})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn oauth_complete_flow_id_is_single_use() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        // Insert a flow manually
        let flow_id = "single-use-flow";
        {
            let mut flows = ctx.oauth_flows.lock().await;
            flows.insert(
                flow_id.to_string(),
                PendingOAuthFlow {
                    verifier: "v".to_string(),
                    provider: "anthropic".to_string(),
                    created_at: std::time::Instant::now(),
                },
            );
        }

        // First attempt removes the flow (will fail at token exchange since code is fake,
        // but the flow is already removed)
        let _ = OAuthCompleteHandler
            .handle(
                Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
                &ctx,
            )
            .await;

        // Second attempt should fail with "not found"
        let err = OAuthCompleteHandler
            .handle(
                Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
                &ctx,
            )
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("not found or expired"));
    }

    #[tokio::test]
    async fn oauth_complete_expired_flow_returns_error() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        let flow_id = "expired-flow";
        {
            let mut flows = ctx.oauth_flows.lock().await;
            flows.insert(
                flow_id.to_string(),
                PendingOAuthFlow {
                    verifier: "v".to_string(),
                    provider: "anthropic".to_string(),
                    created_at: std::time::Instant::now() - std::time::Duration::from_secs(700),
                },
            );
        }

        let err = OAuthCompleteHandler
            .handle(
                Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
                &ctx,
            )
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("expired"));
    }

    #[tokio::test]
    async fn oauth_complete_removes_flow_from_map() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        let flow_id = "will-be-removed";
        {
            let mut flows = ctx.oauth_flows.lock().await;
            flows.insert(
                flow_id.to_string(),
                PendingOAuthFlow {
                    verifier: "v".to_string(),
                    provider: "anthropic".to_string(),
                    created_at: std::time::Instant::now(),
                },
            );
        }

        // This will fail at token exchange (fake code) but flow should be removed
        let _ = OAuthCompleteHandler
            .handle(
                Some(json!({"flowId": flow_id, "code": "fake", "label": "test"})),
                &ctx,
            )
            .await;

        let flows = ctx.oauth_flows.lock().await;
        assert!(!flows.contains_key(flow_id));
    }
}
