//! Auth handlers: get, update, clear, oauthBegin, oauthComplete.
//!
//! Manages provider API keys and OAuth tokens stored in `auth.json`.
//! All handlers return masked key hints — full secrets are never sent over the wire.
//!
//! ## Submodules
//!
//! | Module    | Handlers |
//! |-----------|----------|
//! | `get`     | `GetAuthHandler` — read masked auth state |
//! | `update`  | `UpdateAuthHandler` — set keys/tokens for providers and services |
//! | `clear`   | `ClearAuthHandler` — wipe provider or service credentials |
//! | `oauth`   | `OAuthBeginHandler`, `OAuthCompleteHandler` — OAuth PKCE flows |
//! | `account` | `RenameAccountHandler`, `SetActiveCredentialHandler`, `RemoveAccountHandler`, `RemoveApiKeyHandler` |

use std::collections::HashMap;
use std::path::Path;

use async_trait::async_trait;
use serde_json::{Value, json};
use tracing::instrument;

use crate::llm::auth::storage::{
    acquire_auth_file_lock, clear_provider_auth, load_auth_storage, load_or_init_for_write,
    save_auth_storage, save_named_api_key,
};
use crate::llm::auth::types::{
    AccountEntry, ActiveCredential, ApiKeyEntry, OAuthTokens, ProviderAuth, ServiceAuth,
};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{map_auth_error, opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;
use crate::server::rpc::types::RpcEvent;

mod account;
mod clear;
mod get;
mod oauth;
mod update;

pub use account::{
    RemoveAccountHandler, RemoveApiKeyHandler, RenameAccountHandler, SetActiveCredentialHandler,
};
pub use clear::ClearAuthHandler;
pub use get::GetAuthHandler;
pub use oauth::{OAuthBeginHandler, OAuthCompleteHandler, PendingOAuthFlow};
pub use update::UpdateAuthHandler;

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
            key[i + 1..].find('-').map_or(i + 1, |j| i + 1 + j + 1)
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
    let effective_active =
        crate::llm::auth::resolve_credential(pa, None).map(|resolved| match resolved {
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

    info
}

/// Build the masked auth state response from raw storage.
///
/// Returns `Err` if the auth file exists but is malformed — callers surface
/// the error to the client rather than silently showing an empty auth state
/// (which would lead a user to believe they have no credentials when they
/// really have a broken file on disk).
fn build_masked_state(auth_path: &Path) -> Result<Value, crate::llm::auth::errors::AuthError> {
    let storage = load_auth_storage(auth_path)?;

    let mut providers = serde_json::Map::new();

    for &provider in KNOWN_PROVIDERS {
        if provider == "google" {
            let google = storage
                .as_ref()
                .and_then(crate::llm::auth::types::AuthStorage::get_google_auth);

            let info = if let Some(ref g) = google {
                let mut info = build_provider_info(&g.base);

                // Google-specific OAuth configuration fields
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
            let pa = storage.as_ref().and_then(|s| s.get_provider_auth(provider));

            let info = if let Some(ref pa) = pa {
                let mut info = build_provider_info(pa);

                // Top-level OAuth expiry from first account — used by iOS to show
                // quick expiry status without expanding the accounts list
                if let Some(first_acct) = pa.accounts.as_ref().and_then(|a| a.first()) {
                    let _ =
                        info.insert("oauthExpiresAt".into(), json!(first_acct.oauth.expires_at));
                    let is_expired =
                        crate::llm::auth::types::now_ms() >= first_acct.oauth.expires_at;
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
        let svc = storage.as_ref().and_then(|s| s.get_service_auth(service));

        let mut info = serde_json::Map::new();
        if let Some(svc) = svc {
            // INVARIANT: svc.api_keys is non-empty (enforced by ServiceAuth
            // deserializer — empty arrays and single-field legacy shapes
            // are rejected at auth.json load time).
            let first = svc
                .api_keys
                .first()
                .expect("ServiceAuth.api_keys non-empty invariant");
            let _ = info.insert("hasApiKey".into(), json!(true));
            let _ = info.insert("apiKeyHint".into(), json!(mask_key(first)));
        } else {
            let _ = info.insert("hasApiKey".into(), json!(false));
        }
        let _ = services.insert(service.to_string(), Value::Object(info));
    }

    Ok(json!({
        "providers": Value::Object(providers),
        "services": Value::Object(services),
    }))
}

/// Build accounts list from provider auth (masked).
fn build_accounts_list(pa: &ProviderAuth) -> Vec<Value> {
    pa.accounts
        .as_ref()
        .map(|accts| {
            accts
                .iter()
                .map(|a| {
                    let is_expired = crate::llm::auth::types::now_ms() >= a.oauth.expires_at;
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

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
#[path = "../auth_tests.rs"]
mod tests;
