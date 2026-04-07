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
    AccountEntry, ActiveCredential, ApiKeyEntry, GoogleOAuthEndpoint, OAuthTokens, ProviderAuth,
    ServiceAuth,
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

/// Build the common provider info fields from a `ProviderAuth`.
///
/// Populates: `hasApiKey`, `apiKeyHint`, `hasOAuth`, `accounts`, `apiKeys`,
/// and `activeCredential`. These fields are consumed by the iOS settings UI
/// to render credential status for each provider.
fn build_provider_info(pa: &ProviderAuth) -> serde_json::Map<String, Value> {
    let mut info = serde_json::Map::new();

    let has_api_keys = pa.api_keys.as_ref().is_some_and(|k| !k.is_empty());
    let _ = info.insert("hasApiKey".into(), json!(has_api_keys));

    // First key hint — used by iOS to show a masked preview of the active key
    if let Some(first_key) = pa.api_keys.as_ref().and_then(|k| k.first()) {
        let _ = info.insert("apiKeyHint".into(), json!(mask_key(&first_key.key)));
    }

    let has_accounts = pa.accounts.as_ref().is_some_and(|a| !a.is_empty());
    let _ = info.insert("hasOAuth".into(), json!(has_accounts));

    let accounts = build_accounts_list(pa);
    let _ = info.insert("accounts".into(), json!(accounts));

    let api_keys: Vec<Value> = pa
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
    let effective_active = crate::llm::auth::resolve_credential(pa, None).map(|resolved| {
        match resolved {
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
        }
    });
    if let Some(active) = effective_active {
        let _ = info.insert(
            "activeCredential".into(),
            serde_json::to_value(&active).unwrap_or(json!(null)),
        );
    }

    info
}

/// Build the masked auth state response from raw storage.
fn build_masked_state(auth_path: &Path) -> Value {
    let storage = load_auth_storage(auth_path);

    let mut providers = serde_json::Map::new();

    for &provider in KNOWN_PROVIDERS {
        if provider == "google" {
            let google = storage
                .as_ref()
                .and_then(crate::llm::auth::types::AuthStorage::get_google_auth);

            let info = if let Some(ref g) = google {
                let mut info = build_provider_info(&g.base);

                // Google-specific OAuth configuration fields
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

                info
            } else {
                let mut info = serde_json::Map::new();
                let _ = info.insert("hasApiKey".into(), json!(false));
                let _ = info.insert("hasOAuth".into(), json!(false));
                let _ = info.insert("hasClientId".into(), json!(false));
                let _ = info.insert("hasClientSecret".into(), json!(false));
                let _ = info.insert("accounts".into(), json!([]));
                let _ = info.insert("apiKeys".into(), json!([]));
                info
            };

            let _ = providers.insert(provider.to_string(), Value::Object(info));
        } else {
            let pa = crate::llm::auth::storage::get_provider_auth(auth_path, provider);

            let info = if let Some(ref pa) = pa {
                let mut info = build_provider_info(pa);

                // Top-level OAuth expiry from first account — used by iOS to show
                // quick expiry status without expanding the accounts list
                if let Some(first_acct) = pa.accounts.as_ref().and_then(|a| a.first()) {
                    let _ = info.insert("oauthExpiresAt".into(), json!(first_acct.oauth.expires_at));
                    let is_expired = crate::llm::auth::types::now_ms() >= first_acct.oauth.expires_at;
                    let _ = info.insert("isOAuthExpired".into(), json!(is_expired));
                }

                info
            } else {
                let mut info = serde_json::Map::new();
                let _ = info.insert("hasApiKey".into(), json!(false));
                let _ = info.insert("hasOAuth".into(), json!(false));
                let _ = info.insert("accounts".into(), json!([]));
                let _ = info.insert("apiKeys".into(), json!([]));
                info
            };

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
    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            // Clear all API keys
            let mut storage = load_auth_storage(auth_path).unwrap_or_default();
            if let Some(mut pa) = storage.get_provider_auth(provider) {
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
            // Clear all OAuth accounts
            let mut storage = load_auth_storage(auth_path).unwrap_or_default();
            if let Some(mut pa) = storage.get_provider_auth(provider) {
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
            google.base.api_keys = None;
        } else if let Some(key) = api_key_val.as_str() {
            google.base.api_keys = Some(vec![ApiKeyEntry {
                label: "(default)".to_string(),
                key: key.to_string(),
            }]);
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
            google.base.accounts = None;
        } else {
            let tokens = parse_oauth_tokens(oauth)?;
            google.base.accounts = Some(vec![AccountEntry {
                label: "(default)".to_string(),
                oauth: tokens,
            }]);
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
#[path = "auth_tests.rs"]
mod tests;
