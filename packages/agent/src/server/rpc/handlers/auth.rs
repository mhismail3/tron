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
    save_named_api_key,
};
use crate::llm::auth::types::{
    ActiveCredential, GoogleOAuthEndpoint, OAuthTokens, ProviderAuth, ServiceAuth,
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
        .map_or(4, |i| {
            // Find second dash for "sk-ant-..." style keys
            key[i + 1..]
                .find('-')
                .map_or(i + 1, |j| i + 1 + j + 1)
        })
        .min(10);
    let suffix_start = key.len().saturating_sub(4);
    format!("{}...{}", &key[..prefix_end], &key[suffix_start..])
}

// ─── Masked state builder ────────────────────────────────────────────────────

/// Build the masked auth state response from raw storage.
fn build_masked_state(auth_path: &Path) -> Value {
    let storage = load_auth_storage(auth_path);

    let mut providers = serde_json::Map::new();

    for &provider in KNOWN_PROVIDERS {
        if provider == "google" {
            let google = storage
                .as_ref()
                .and_then(crate::llm::auth::types::AuthStorage::get_google_auth);

            // Also load migrated base ProviderAuth for consistent array-based fields
            let migrated_base = crate::llm::auth::storage::get_provider_auth(auth_path, "google");

            let mut info = serde_json::Map::new();
            if let Some(ref g) = google {
                let base = migrated_base.as_ref().unwrap_or(&g.base);

                // Derive hasApiKey from api_keys[] (post-migration)
                let has_api_keys = base.api_keys.as_ref().is_some_and(|k| !k.is_empty());
                // Fall back to legacy for Google (may not have been migrated via get_provider_auth
                // since Google uses get_google_provider_auth which doesn't run migration)
                let has_key = has_api_keys || g.base.api_key.is_some();
                let _ = info.insert("hasApiKey".into(), json!(has_key));
                if let Some(first_key) = base.api_keys.as_ref().and_then(|k| k.first()) {
                    let _ = info.insert("apiKeyHint".into(), json!(mask_key(&first_key.key)));
                } else if let Some(ref key) = g.base.api_key {
                    let _ = info.insert("apiKeyHint".into(), json!(mask_key(key)));
                }

                // Derive hasOAuth from accounts[]
                let has_accounts = base.accounts.as_ref().is_some_and(|a| !a.is_empty());
                let _ = info.insert("hasOAuth".into(), json!(has_accounts || g.base.oauth.is_some()));

                // Google-specific fields
                if let Some(ref ep) = g.endpoint {
                    let ep_str = match ep {
                        GoogleOAuthEndpoint::CloudCodeAssist => "cloud-code-assist",
                        GoogleOAuthEndpoint::Antigravity => "antigravity",
                    };
                    let _ = info.insert("endpoint".into(), json!(ep_str));
                }
                if let Some(ref pid) = g.project_id {
                    let _ = info.insert("projectId".into(), json!(pid));
                }
                let _ = info.insert("hasClientId".into(), json!(g.client_id.is_some()));
                let _ = info.insert("hasClientSecret".into(), json!(g.client_secret.is_some()));

                // Accounts
                let accounts = build_accounts_list(base);
                let _ = info.insert("accounts".into(), json!(accounts));

                // Named API keys (masked)
                let api_keys: Vec<Value> = base
                    .api_keys
                    .as_ref()
                    .map(|keys| {
                        keys.iter()
                            .map(|k| json!({"label": k.label, "keyHint": mask_key(&k.key)}))
                            .collect()
                    })
                    .unwrap_or_default();
                let _ = info.insert("apiKeys".into(), json!(api_keys));

                // Effective active credential: explicit selection, or fallback to first available
                let effective_active = crate::llm::auth::resolve_credential(base, None)
                    .map(|resolved| match resolved {
                        crate::llm::auth::ResolvedCredential::OAuthAccount(acct) => {
                            crate::llm::auth::ActiveCredential::OAuth {
                                label: acct.label.clone(),
                            }
                        }
                        crate::llm::auth::ResolvedCredential::ApiKey(key) => {
                            crate::llm::auth::ActiveCredential::ApiKey {
                                label: key.label.clone(),
                            }
                        }
                    });
                if let Some(active) = effective_active {
                    let _ = info.insert(
                        "activeCredential".into(),
                        serde_json::to_value(&active).unwrap_or(json!(null)),
                    );
                }
            } else {
                let _ = info.insert("hasApiKey".into(), json!(false));
                let _ = info.insert("hasOAuth".into(), json!(false));
                let _ = info.insert("hasClientId".into(), json!(false));
                let _ = info.insert("hasClientSecret".into(), json!(false));
                let _ = info.insert("accounts".into(), json!([]));
                let _ = info.insert("apiKeys".into(), json!([]));
            }

            let _ = providers.insert(provider.to_string(), Value::Object(info));
        } else {
            // Use get_provider_auth (runs migration) instead of raw storage
            let pa = crate::llm::auth::storage::get_provider_auth(auth_path, provider);

            let mut info = serde_json::Map::new();
            if let Some(ref pa) = pa {
                // Derive hasApiKey from api_keys[] (post-migration)
                let has_api_keys = pa.api_keys.as_ref().is_some_and(|k| !k.is_empty());
                let _ = info.insert("hasApiKey".into(), json!(has_api_keys));
                // Backward compat: apiKeyHint from first named key
                if let Some(first_key) = pa.api_keys.as_ref().and_then(|k| k.first()) {
                    let _ = info.insert("apiKeyHint".into(), json!(mask_key(&first_key.key)));
                }

                // Derive hasOAuth from accounts[]
                let has_accounts = pa.accounts.as_ref().is_some_and(|a| !a.is_empty());
                let _ = info.insert("hasOAuth".into(), json!(has_accounts));

                // Backward compat: oauthExpiresAt/isOAuthExpired from first account
                if let Some(first_acct) = pa.accounts.as_ref().and_then(|a| a.first()) {
                    let _ = info.insert("oauthExpiresAt".into(), json!(first_acct.oauth.expires_at));
                    let is_expired = crate::llm::auth::types::now_ms() >= first_acct.oauth.expires_at;
                    let _ = info.insert("isOAuthExpired".into(), json!(is_expired));
                }

                // Accounts list (OAuth)
                let accounts = build_accounts_list(pa);
                let _ = info.insert("accounts".into(), json!(accounts));

                // Named API keys (masked)
                let api_keys: Vec<Value> = pa
                    .api_keys
                    .as_ref()
                    .map(|keys| {
                        keys.iter()
                            .map(|k| {
                                json!({
                                    "label": k.label,
                                    "keyHint": mask_key(&k.key),
                                })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let _ = info.insert("apiKeys".into(), json!(api_keys));

                // Effective active credential: explicit selection, or fallback to first available
                let effective_active = crate::llm::auth::resolve_credential(pa, None)
                    .map(|resolved| match resolved {
                        crate::llm::auth::ResolvedCredential::OAuthAccount(acct) => {
                            crate::llm::auth::ActiveCredential::OAuth {
                                label: acct.label.clone(),
                            }
                        }
                        crate::llm::auth::ResolvedCredential::ApiKey(key) => {
                            crate::llm::auth::ActiveCredential::ApiKey {
                                label: key.label.clone(),
                            }
                        }
                    });
                if let Some(active) = effective_active {
                    let _ = info.insert(
                        "activeCredential".into(),
                        serde_json::to_value(&active).unwrap_or(json!(null)),
                    );
                }
            } else {
                let _ = info.insert("hasApiKey".into(), json!(false));
                let _ = info.insert("hasOAuth".into(), json!(false));
                let _ = info.insert("accounts".into(), json!([]));
                let _ = info.insert("apiKeys".into(), json!([]));
            }

            let _ = providers.insert(provider.to_string(), Value::Object(info));
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
                || svc.api_keys.as_ref().is_some_and(|k| !k.is_empty());
            let _ = info.insert("hasApiKey".into(), json!(has_key));
            if let Some(ref key) = svc.api_key {
                let _ = info.insert("apiKeyHint".into(), json!(mask_key(key)));
            } else if let Some(ref keys) = svc.api_keys
                && let Some(first) = keys.first()
            {
                let _ = info.insert("apiKeyHint".into(), json!(mask_key(first)));
            }
        } else {
            let _ = info.insert("hasApiKey".into(), json!(false));
        }
        let _ = services.insert(service.to_string(), Value::Object(info));
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
    /// PKCE code verifier (Anthropic) or random state (OpenAI) for this flow.
    pub verifier: String,
    /// OAuth provider name (e.g., "anthropic", "openai-codex").
    pub provider: String,
    /// When this flow was initiated.
    pub created_at: std::time::Instant,
}

/// Providers that support OAuth login.
const OAUTH_PROVIDERS: &[&str] = &["anthropic", "openai-codex"];

/// Begin an OAuth flow: generate PKCE (Anthropic) or state (OpenAI), return auth URL + flow ID.
pub struct OAuthBeginHandler;

#[async_trait]
impl MethodHandler for OAuthBeginHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.oauthBegin"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = require_string_param(params.as_ref(), "provider")?;

        let (auth_url, verifier_or_state) = match provider.as_str() {
            "anthropic" => {
                let pair = crate::llm::auth::pkce::generate_pkce();
                let config = crate::llm::auth::anthropic::default_config();
                // Use verifier as state (matches tron login CLI behavior)
                let url = crate::llm::auth::anthropic::get_authorization_url_with_state(
                    &config, &pair.challenge, Some(&pair.verifier),
                );
                (url, pair.verifier)
            }
            "openai-codex" => {
                let pair = crate::llm::auth::pkce::generate_pkce();
                let config = crate::llm::auth::openai::default_config();
                let url = crate::llm::auth::openai::get_authorization_url_with_state(
                    &config, &pair.challenge, Some(&pair.verifier),
                );
                (url, pair.verifier)
            }
            _ => {
                return Err(RpcError::InvalidParams {
                    message: format!(
                        "OAuth login supported for: {}. Got: {provider}",
                        OAUTH_PROVIDERS.join(", "),
                    ),
                });
            }
        };

        let flow_id = uuid::Uuid::now_v7().to_string();

        let mut flows = ctx.oauth_flows.lock().await;

        // Lazy cleanup: remove expired flows (>10 minutes)
        flows.retain(|_, f| f.created_at.elapsed() < std::time::Duration::from_secs(600));

        let _ = flows.insert(
            flow_id.clone(),
            PendingOAuthFlow {
                verifier: verifier_or_state,
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

        // Exchange code for tokens (provider-specific)
        let tokens = match flow.provider.as_str() {
            "anthropic" => {
                let config = crate::llm::auth::anthropic::default_config();
                // Pass verifier as state (matches tron login CLI behavior)
                crate::llm::auth::anthropic::exchange_code_for_tokens(
                    &config, &code, &flow.verifier, Some(&flow.verifier),
                )
                .await
            }
            "openai-codex" => {
                let config = crate::llm::auth::openai::default_config();
                crate::llm::auth::openai::exchange_code_for_tokens(
                    &config, &code, &flow.verifier,
                )
                .await
            }
            _ => {
                return Err(RpcError::InvalidParams {
                    message: format!("Unsupported OAuth provider: {}", flow.provider),
                });
            }
        }
        .map_err(|e| RpcError::Internal {
            message: format!("Token exchange failed: {e}"),
        })?;

        // Save tokens to auth.json (under the correct provider key)
        let auth_path = ctx.auth_path.clone();
        let provider_key = flow.provider.clone();
        let label_clone = label.clone();
        let tokens_clone = tokens.clone();
        let masked_state = ctx
            .run_blocking("auth.oauthComplete", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to acquire auth lock: {e}"),
                })?;

                crate::llm::auth::storage::save_account_oauth_tokens(
                    &auth_path,
                    &provider_key,
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

// ─── Set Active Credential ──────────────────────────────────────────────────

/// Set the active credential for a provider.
pub struct SetActiveCredentialHandler;

#[async_trait]
impl MethodHandler for SetActiveCredentialHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.setActive"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = require_string_param(params.as_ref(), "provider")?;

        let cred_val = params
            .as_ref()
            .and_then(|p| p.get("credential"))
            .ok_or_else(|| RpcError::InvalidParams {
                message: "Missing required parameter: credential".into(),
            })?;

        let credential: ActiveCredential =
            serde_json::from_value(cred_val.clone()).map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid credential: {e}"),
            })?;

        let auth_path = ctx.auth_path.clone();
        let masked_state = ctx
            .run_blocking("auth.setActive", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to acquire auth lock: {e}"),
                })?;

                crate::llm::auth::storage::set_active_credential(&auth_path, &provider, &credential)
                    .map_err(|e| RpcError::InvalidParams {
                        message: format!("Failed to set active credential: {e}"),
                    })?;

                Ok(build_masked_state(&auth_path))
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

// ─── Remove Account ─────────────────────────────────────────────────────────

/// Remove a specific OAuth account by label.
pub struct RemoveAccountHandler;

#[async_trait]
impl MethodHandler for RemoveAccountHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.removeAccount"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = require_string_param(params.as_ref(), "provider")?;
        let label = require_string_param(params.as_ref(), "label")?;

        let auth_path = ctx.auth_path.clone();
        let masked_state = ctx
            .run_blocking("auth.removeAccount", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to acquire auth lock: {e}"),
                })?;

                crate::llm::auth::storage::remove_account(&auth_path, &provider, &label)
                    .map_err(|e| RpcError::Internal {
                        message: format!("Failed to remove account: {e}"),
                    })?;

                Ok(build_masked_state(&auth_path))
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

// ─── Remove API Key ─────────────────────────────────────────────────────────

/// Remove a specific named API key by label.
pub struct RemoveApiKeyHandler;

#[async_trait]
impl MethodHandler for RemoveApiKeyHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.removeApiKey"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let provider = require_string_param(params.as_ref(), "provider")?;
        let label = require_string_param(params.as_ref(), "label")?;

        let auth_path = ctx.auth_path.clone();
        let masked_state = ctx
            .run_blocking("auth.removeApiKey", move || {
                let _lock = acquire_auth_file_lock(&auth_path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to acquire auth lock: {e}"),
                })?;

                crate::llm::auth::storage::remove_named_api_key(&auth_path, &provider, &label)
                    .map_err(|e| RpcError::Internal {
                        message: format!("Failed to remove API key: {e}"),
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
    // If apiKeyLabel is present, stores as named key in api_keys[].
    // Otherwise, stores as legacy api_key (will be migrated on next read).
    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            // Clear all API keys (both legacy and named)
            let mut storage = load_auth_storage(auth_path).unwrap_or_default();
            if let Some(mut pa) = storage.get_provider_auth(provider) {
                pa.api_key = None;
                pa.api_keys = None;
                // Clear active if it pointed to an API key
                if matches!(pa.active_credential, Some(ActiveCredential::ApiKey { .. })) {
                    pa.active_credential = None;
                }
                storage.set_provider_auth(provider, &pa);
                save_auth_storage(auth_path, &mut storage).map_err(|e| RpcError::Internal {
                    message: format!("Failed to save auth: {e}"),
                })?;
            }
        } else if let Some(key) = api_key_val.as_str() {
            // Use provided label, or generate a default
            let label = params
                .get("apiKeyLabel")
                .and_then(|v| v.as_str())
                .unwrap_or("(default)");
            save_named_api_key(auth_path, provider, label, key).map_err(|e| {
                RpcError::Internal {
                    message: format!("Failed to save API key: {e}"),
                }
            })?;
        }
    }

    // Handle OAuth tokens
    if let Some(oauth) = params.get("oauth") {
        if oauth.is_null() {
            // Clear all OAuth (both legacy and accounts)
            let mut storage = load_auth_storage(auth_path).unwrap_or_default();
            if let Some(mut pa) = storage.get_provider_auth(provider) {
                pa.oauth = None;
                pa.accounts = None;
                if matches!(pa.active_credential, Some(ActiveCredential::OAuth { .. })) {
                    pa.active_credential = None;
                }
                storage.set_provider_auth(provider, &pa);
                save_auth_storage(auth_path, &mut storage).map_err(|e| RpcError::Internal {
                    message: format!("Failed to save auth: {e}"),
                })?;
            }
        } else {
            // Save as account with default label
            let tokens = parse_oauth_tokens(oauth)?;
            crate::llm::auth::storage::save_account_oauth_tokens(
                auth_path, provider, "(default)", &tokens,
            )
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to save OAuth tokens: {e}"),
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
        .and_then(serde_json::Value::as_i64)
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
    use crate::llm::auth::types::{AuthStorage, GoogleProviderAuth};
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
        save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-abcdefghijklmnop")
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
        save_named_api_key(&ctx.auth_path, "minimax", "(test)", "short").unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["providers"]["minimax"]["apiKeyHint"], "***");
    }

    #[tokio::test]
    async fn auth_get_masks_key_correctly_long_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-verylongkeyvalue1234")
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
        crate::llm::auth::storage::save_account_oauth_tokens(&ctx.auth_path, "anthropic", "(test)", &tokens).unwrap();

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
        crate::llm::auth::storage::save_account_oauth_tokens(&ctx.auth_path, "anthropic", "(test)", &tokens).unwrap();

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

        // Verify on disk (migration moves legacy api_key → api_keys[])
        let pa = crate::llm::auth::storage::get_provider_auth(&ctx.auth_path, "anthropic").unwrap();
        // Legacy field is cleared after migration
        assert!(pa.api_key.is_none());
        // Key is now in api_keys[] under "(default)" label
        let api_keys = pa.api_keys.unwrap();
        assert_eq!(api_keys[0].key, "sk-ant-api03-newkey123456789");
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
                        "expiresAt": 9_999_999_999_999_i64
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
                        "expiresAt": 9_999_999_999_999_i64
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
        save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-clearme123456789").unwrap();

        let result = ClearAuthHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["providers"]["anthropic"]["hasApiKey"], false);
    }

    #[tokio::test]
    async fn auth_clear_preserves_other_providers() {
        let (ctx, _dir) = make_ctx_with_temp_auth();

        save_named_api_key(&ctx.auth_path, "anthropic", "(test)", "sk-ant-api03-keep12345678901").unwrap();
        save_named_api_key(&ctx.auth_path, "openai-codex", "(test)", "sk-proj-remove12345678901").unwrap();

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
            .handle(Some(json!({"provider": "unknown-provider"})), &ctx)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("OAuth login supported for"));
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
            let _ = flows.insert(
                "expired-flow".to_string(),
                PendingOAuthFlow {
                    verifier: "v".to_string(),
                    provider: "anthropic".to_string(),
                    created_at: std::time::Instant::now().checked_sub(std::time::Duration::from_secs(700)).unwrap(),
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
            let _ = flows.insert(
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
            let _ = flows.insert(
                flow_id.to_string(),
                PendingOAuthFlow {
                    verifier: "v".to_string(),
                    provider: "anthropic".to_string(),
                    created_at: std::time::Instant::now().checked_sub(std::time::Duration::from_secs(700)).unwrap(),
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
            let _ = flows.insert(
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

    // ── auth.oauthBegin (OpenAI) ──

    #[tokio::test]
    async fn oauth_begin_openai_returns_flow_id_and_auth_url() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "openai-codex"})), &ctx)
            .await
            .unwrap();

        assert!(result["flowId"].as_str().is_some());
        assert!(!result["flowId"].as_str().unwrap().is_empty());
        assert!(result["authUrl"].as_str().is_some());
        assert!(!result["authUrl"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn oauth_begin_openai_auth_url_contains_openai_endpoint() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "openai-codex"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("auth.openai.com"), "URL should use OpenAI auth endpoint");
    }

    #[tokio::test]
    async fn oauth_begin_openai_auth_url_has_pkce() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "openai-codex"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("code_challenge="), "OpenAI should use PKCE code_challenge");
        assert!(url.contains("code_challenge_method=S256"), "OpenAI should use S256");
    }

    #[tokio::test]
    async fn oauth_begin_openai_auth_url_contains_state() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "openai-codex"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("state="), "OpenAI auth URL must contain state parameter");
    }

    #[tokio::test]
    async fn oauth_begin_openai_auth_url_contains_required_params() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "openai-codex"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("response_type=code"));
        assert!(url.contains("client_id="));
        assert!(url.contains("redirect_uri="));
        assert!(url.contains("scope="));
    }

    #[tokio::test]
    async fn oauth_begin_openai_stores_correct_provider_in_flow() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "openai-codex"})), &ctx)
            .await
            .unwrap();

        let flow_id = result["flowId"].as_str().unwrap();
        let flows = ctx.oauth_flows.lock().await;
        assert!(flows.contains_key(flow_id));
        assert_eq!(flows[flow_id].provider, "openai-codex");
    }

    #[tokio::test]
    async fn oauth_begin_anthropic_still_returns_pkce() {
        // Regression: ensure Anthropic flows still use PKCE after multi-provider change
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = OAuthBeginHandler
            .handle(Some(json!({"provider": "anthropic"})), &ctx)
            .await
            .unwrap();

        let url = result["authUrl"].as_str().unwrap();
        assert!(url.contains("claude.ai"), "Anthropic URL should use claude.ai");
        assert!(url.contains("code_challenge="), "Anthropic should use PKCE");
        assert!(url.contains("code_challenge_method=S256"), "Anthropic should use S256");
    }

    // ── auth.setActive ──

    #[tokio::test]
    async fn auth_set_active_oauth() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let tokens = OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: crate::llm::auth::types::now_ms() + 3_600_000,
        };
        crate::llm::auth::storage::save_account_oauth_tokens(
            &ctx.auth_path, "anthropic", "main", &tokens,
        )
        .unwrap();

        let result = SetActiveCredentialHandler
            .handle(
                Some(json!({"provider": "anthropic", "credential": {"type": "oauth", "label": "main"}})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(
            result["providers"]["anthropic"]["activeCredential"]["type"],
            "oauth"
        );
        assert_eq!(
            result["providers"]["anthropic"]["activeCredential"]["label"],
            "main"
        );
    }

    #[tokio::test]
    async fn auth_set_active_api_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        crate::llm::auth::storage::save_named_api_key(
            &ctx.auth_path, "anthropic", "work", "sk-123",
        )
        .unwrap();

        let result = SetActiveCredentialHandler
            .handle(
                Some(json!({"provider": "anthropic", "credential": {"type": "apiKey", "label": "work"}})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(
            result["providers"]["anthropic"]["activeCredential"]["type"],
            "apiKey"
        );
    }

    #[tokio::test]
    async fn auth_set_active_nonexistent_errors() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let err = SetActiveCredentialHandler
            .handle(
                Some(json!({"provider": "anthropic", "credential": {"type": "oauth", "label": "nope"}})),
                &ctx,
            )
            .await
            .unwrap_err();

        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    // ── auth.removeAccount ──

    #[tokio::test]
    async fn auth_remove_account() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let tokens = OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: crate::llm::auth::types::now_ms() + 3_600_000,
        };
        crate::llm::auth::storage::save_account_oauth_tokens(
            &ctx.auth_path, "anthropic", "del-me", &tokens,
        )
        .unwrap();

        let result = RemoveAccountHandler
            .handle(
                Some(json!({"provider": "anthropic", "label": "del-me"})),
                &ctx,
            )
            .await
            .unwrap();

        let accounts = result["providers"]["anthropic"]["accounts"].as_array().unwrap();
        assert!(accounts.is_empty());
    }

    #[tokio::test]
    async fn auth_remove_account_clears_active() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let tokens = OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: crate::llm::auth::types::now_ms() + 3_600_000,
        };
        crate::llm::auth::storage::save_account_oauth_tokens(
            &ctx.auth_path, "anthropic", "active-one", &tokens,
        )
        .unwrap();
        crate::llm::auth::storage::set_active_credential(
            &ctx.auth_path,
            "anthropic",
            &ActiveCredential::OAuth { label: "active-one".into() },
        )
        .unwrap();

        let result = RemoveAccountHandler
            .handle(
                Some(json!({"provider": "anthropic", "label": "active-one"})),
                &ctx,
            )
            .await
            .unwrap();

        assert!(result["providers"]["anthropic"]["activeCredential"].is_null());
    }

    // ── auth.removeApiKey ──

    #[tokio::test]
    async fn auth_remove_api_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        crate::llm::auth::storage::save_named_api_key(
            &ctx.auth_path, "anthropic", "del-me", "sk-123",
        )
        .unwrap();

        let result = RemoveApiKeyHandler
            .handle(
                Some(json!({"provider": "anthropic", "label": "del-me"})),
                &ctx,
            )
            .await
            .unwrap();

        let api_keys = result["providers"]["anthropic"]["apiKeys"].as_array().unwrap();
        assert!(api_keys.is_empty());
    }

    // ── auth.get response shape ──

    #[tokio::test]
    async fn auth_get_returns_api_keys_and_active_credential() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        crate::llm::auth::storage::save_named_api_key(
            &ctx.auth_path, "anthropic", "work", "sk-ant-api03-workkey123456789",
        )
        .unwrap();
        crate::llm::auth::storage::set_active_credential(
            &ctx.auth_path,
            "anthropic",
            &ActiveCredential::ApiKey { label: "work".into() },
        )
        .unwrap();

        let result = GetAuthHandler.handle(None, &ctx).await.unwrap();

        let api_keys = result["providers"]["anthropic"]["apiKeys"].as_array().unwrap();
        assert_eq!(api_keys.len(), 1);
        assert_eq!(api_keys[0]["label"], "work");
        assert!(api_keys[0]["keyHint"].as_str().unwrap().contains("..."));

        assert_eq!(
            result["providers"]["anthropic"]["activeCredential"]["type"],
            "apiKey"
        );
    }

    // ── auth.update with apiKeyLabel ──

    #[tokio::test]
    async fn auth_update_with_api_key_label_creates_named_key() {
        let (ctx, _dir) = make_ctx_with_temp_auth();
        let result = UpdateAuthHandler
            .handle(
                Some(json!({
                    "provider": "anthropic",
                    "apiKey": "sk-ant-api03-namedkey123456789",
                    "apiKeyLabel": "work"
                })),
                &ctx,
            )
            .await
            .unwrap();

        let api_keys = result["providers"]["anthropic"]["apiKeys"].as_array().unwrap();
        assert_eq!(api_keys.len(), 1);
        assert_eq!(api_keys[0]["label"], "work");
    }
}
