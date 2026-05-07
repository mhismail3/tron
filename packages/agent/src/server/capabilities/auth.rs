use std::collections::HashMap;
use std::path::Path;

use super::*;

use crate::llm::auth::storage::{
    acquire_auth_file_lock, clear_provider_auth, load_auth_storage, load_or_init_for_write,
    save_auth_storage, save_named_api_key,
};
use crate::llm::auth::types::{
    AccountEntry, ActiveCredential, ApiKeyEntry, OAuthTokens, ProviderAuth, ServiceAuth,
};
use crate::server::rpc::error_mapping::map_auth_error;
use crate::server::rpc::params::{opt_string, require_string_param};

const DEFAULT_API_KEY_LABEL: &str = "Default";
const KNOWN_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google", "minimax", "kimi"];
const KNOWN_SERVICES: &[&str] = &["brave", "exa"];
const OAUTH_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google"];
const OAUTH_FLOW_TTL_SECS: u64 = 600;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    match method {
        "auth.get" => auth_get(deps).await,
        "auth.update" => auth_update(invocation, deps).await,
        "auth.clear" => auth_clear(invocation, deps).await,
        "auth.oauthBegin" => auth_oauth_begin(&invocation.payload, deps).await,
        "auth.oauthComplete" => auth_oauth_complete(invocation, deps).await,
        "auth.renameAccount" => auth_rename_account(invocation, deps).await,
        "auth.setActive" => auth_set_active(invocation, deps).await,
        "auth.removeAccount" => auth_remove_account(invocation, deps).await,
        "auth.removeApiKey" => auth_remove_api_key(invocation, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("auth method {method} is not engine-owned"),
        }),
    }
}

async fn auth_get(deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
    let auth_path = deps.auth_path.clone();
    deps.rpc_context
        .run_blocking("auth.get", move || {
            build_masked_state(&auth_path).map_err(map_auth_error)
        })
        .await
}

async fn auth_update(
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let provider = opt_string(Some(payload), "provider");
    let service = opt_string(Some(payload), "service");

    if provider.is_none() && service.is_none() {
        return Err(RpcError::InvalidParams {
            message: "Missing required parameter: provider or service".into(),
        });
    }

    let auth_path = deps.auth_path.clone();
    let payload = payload.clone();
    let masked_state = deps
        .rpc_context
        .run_blocking("auth.update", move || {
            let _lock = acquire_auth_file_lock(&auth_path).map_err(|error| RpcError::Internal {
                message: format!("Failed to acquire auth lock: {error}"),
            })?;

            if let Some(ref provider) = provider {
                if !KNOWN_PROVIDERS.contains(&provider.as_str()) {
                    return Err(RpcError::InvalidParams {
                        message: format!("Unknown provider: {provider}"),
                    });
                }
                if provider == "google" {
                    update_google_provider(&auth_path, Some(&payload))?;
                } else {
                    update_standard_provider(&auth_path, provider, Some(&payload))?;
                }
            } else if let Some(ref service) = service {
                update_service(&auth_path, service, Some(&payload))?;
            }

            build_masked_state(&auth_path).map_err(map_auth_error)
        })
        .await?;

    broadcast_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

async fn auth_clear(
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let provider = opt_string(Some(payload), "provider");
    let service = opt_string(Some(payload), "service");

    if provider.is_none() && service.is_none() {
        return Err(RpcError::InvalidParams {
            message: "Missing required parameter: provider or service".into(),
        });
    }

    let auth_path = deps.auth_path.clone();
    let masked_state = deps
        .rpc_context
        .run_blocking("auth.clear", move || {
            let _lock = acquire_auth_file_lock(&auth_path).map_err(|error| RpcError::Internal {
                message: format!("Failed to acquire auth lock: {error}"),
            })?;

            if let Some(ref provider) = provider {
                clear_provider_auth(&auth_path, provider).map_err(map_auth_error)?;
            } else if let Some(ref service) = service {
                clear_service_auth(&auth_path, service).map_err(map_auth_error)?;
            }

            build_masked_state(&auth_path).map_err(map_auth_error)
        })
        .await?;

    broadcast_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

async fn auth_oauth_begin(payload: &Value, deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
    let provider = require_string_param(Some(payload), "provider")?;

    let (auth_url, verifier_or_state) = match provider.as_str() {
        "anthropic" => {
            let pair = crate::llm::auth::pkce::generate_pkce();
            let config = crate::llm::auth::anthropic::default_config();
            let url = crate::llm::auth::anthropic::get_authorization_url_with_state(
                &config,
                &pair.challenge,
                Some(&pair.verifier),
            );
            (url, pair.verifier)
        }
        "openai-codex" => {
            let pair = crate::llm::auth::pkce::generate_pkce();
            let config = crate::llm::auth::openai::default_config();
            let url = crate::llm::auth::openai::get_authorization_url_with_state(
                &config,
                &pair.challenge,
                Some(&pair.verifier),
            );
            (url, pair.verifier)
        }
        "google" => {
            let gpa = crate::llm::auth::storage::get_google_provider_auth(&deps.auth_path)
                .map_err(map_auth_error)?;
            let client_id =
                gpa.as_ref()
                    .and_then(|google| google.client_id.clone())
                    .ok_or_else(|| RpcError::InvalidParams {
                        message: "Google OAuth requires a client_id - configure it in Settings > Providers > Google".into(),
                    })?;
            let client_secret = gpa.and_then(|google| google.client_secret);

            let base_cfg = crate::llm::auth::google::cloud_code_assist_config();
            let config = crate::llm::auth::google::GoogleOAuthConfig {
                oauth: crate::llm::auth::types::OAuthConfig {
                    client_id,
                    client_secret,
                    ..base_cfg.oauth
                },
                ..base_cfg
            };

            let pair = crate::llm::auth::pkce::generate_pkce();
            let url = crate::llm::auth::google::get_authorization_url(&config, &pair.challenge);
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
    let mut flows = deps.rpc_context.oauth_flows.lock().await;
    flows.retain(|_, flow| {
        flow.created_at.elapsed() < std::time::Duration::from_secs(OAUTH_FLOW_TTL_SECS)
    });
    let _ = flows.insert(
        flow_id.clone(),
        crate::server::rpc::auth_flows::PendingOAuthFlow {
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

async fn auth_oauth_complete(
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let flow_id = require_string_param(Some(payload), "flowId")?;
    let code = require_string_param(Some(payload), "code")?;
    let label = require_string_param(Some(payload), "label")?;

    let flow = {
        let mut flows = deps.rpc_context.oauth_flows.lock().await;
        flows.remove(&flow_id)
    }
    .ok_or_else(|| RpcError::InvalidParams {
        message: "OAuth flow not found or expired".into(),
    })?;

    if flow.created_at.elapsed() > std::time::Duration::from_secs(OAUTH_FLOW_TTL_SECS) {
        return Err(RpcError::InvalidParams {
            message: "OAuth flow expired".into(),
        });
    }

    let tokens = match flow.provider.as_str() {
        "anthropic" => {
            let config = crate::llm::auth::anthropic::default_config();
            crate::llm::auth::anthropic::exchange_code_for_tokens(
                &config,
                &code,
                &flow.verifier,
                Some(&flow.verifier),
            )
            .await
        }
        "openai-codex" => {
            let config = crate::llm::auth::openai::default_config();
            crate::llm::auth::openai::exchange_code_for_tokens(&config, &code, &flow.verifier).await
        }
        "google" => {
            let gpa = crate::llm::auth::storage::get_google_provider_auth(&deps.auth_path)
                .map_err(map_auth_error)?;
            let client_id = gpa
                .as_ref()
                .and_then(|google| google.client_id.clone())
                .ok_or_else(|| RpcError::Internal {
                    message: "Google client_id is no longer configured - cannot complete OAuth"
                        .into(),
                })?;
            let client_secret = gpa.and_then(|google| google.client_secret);

            let base_cfg = crate::llm::auth::google::cloud_code_assist_config();
            let config = crate::llm::auth::google::GoogleOAuthConfig {
                oauth: crate::llm::auth::types::OAuthConfig {
                    client_id,
                    client_secret,
                    ..base_cfg.oauth
                },
                ..base_cfg
            };

            crate::llm::auth::google::exchange_code_for_tokens(&config, &code, &flow.verifier).await
        }
        _ => {
            return Err(RpcError::InvalidParams {
                message: format!("Unsupported OAuth provider: {}", flow.provider),
            });
        }
    }
    .map_err(map_auth_error)?;

    let auth_path = deps.auth_path.clone();
    let provider_key = flow.provider;
    let masked_state = deps
        .rpc_context
        .run_blocking("auth.oauthComplete", move || {
            let _lock = acquire_auth_file_lock(&auth_path).map_err(|error| RpcError::Internal {
                message: format!("Failed to acquire auth lock: {error}"),
            })?;

            crate::llm::auth::storage::save_account_oauth_tokens(
                &auth_path,
                &provider_key,
                &label,
                &tokens,
            )
            .map_err(map_auth_error)?;

            build_masked_state(&auth_path).map_err(map_auth_error)
        })
        .await?;

    broadcast_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

async fn auth_rename_account(
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let old_label = require_string_param(Some(payload), "oldLabel")?;
    let new_label = require_string_param(Some(payload), "newLabel")?;

    write_auth_and_broadcast(deps, invocation, "auth.renameAccount", move |auth_path| {
        crate::llm::auth::storage::rename_account(auth_path, &provider, &old_label, &new_label)
            .map_err(map_auth_error)
    })
    .await
}

async fn auth_set_active(
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let cred_val = payload
        .get("credential")
        .ok_or_else(|| RpcError::InvalidParams {
            message: "Missing required parameter: credential".into(),
        })?;
    let credential: ActiveCredential =
        serde_json::from_value(cred_val.clone()).map_err(|error| RpcError::InvalidParams {
            message: format!("Invalid credential: {error}"),
        })?;

    write_auth_and_broadcast(deps, invocation, "auth.setActive", move |auth_path| {
        crate::llm::auth::storage::set_active_credential(auth_path, &provider, &credential).map_err(
            |error| RpcError::InvalidParams {
                message: format!("Failed to set active credential: {error}"),
            },
        )
    })
    .await
}

async fn auth_remove_account(
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let label = require_string_param(Some(payload), "label")?;
    write_auth_and_broadcast(deps, invocation, "auth.removeAccount", move |auth_path| {
        crate::llm::auth::storage::remove_account(auth_path, &provider, &label)
            .map_err(map_auth_error)
    })
    .await
}

async fn auth_remove_api_key(
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let label = require_string_param(Some(payload), "label")?;
    write_auth_and_broadcast(deps, invocation, "auth.removeApiKey", move |auth_path| {
        crate::llm::auth::storage::remove_named_api_key(auth_path, &provider, &label)
            .map_err(map_auth_error)
    })
    .await
}

async fn write_auth_and_broadcast<F>(
    deps: &EngineCapabilityDeps,
    invocation: &Invocation,
    task_name: &'static str,
    mutate: F,
) -> Result<Value, RpcError>
where
    F: FnOnce(&Path) -> Result<(), RpcError> + Send + 'static,
{
    let auth_path = deps.auth_path.clone();
    let masked_state = deps
        .rpc_context
        .run_blocking(task_name, move || {
            let _lock = acquire_auth_file_lock(&auth_path).map_err(|error| RpcError::Internal {
                message: format!("Failed to acquire auth lock: {error}"),
            })?;
            mutate(&auth_path)?;
            build_masked_state(&auth_path).map_err(map_auth_error)
        })
        .await?;
    broadcast_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

fn update_standard_provider(
    auth_path: &Path,
    provider: &str,
    params: Option<&Value>,
) -> Result<(), RpcError> {
    let params = params.ok_or_else(|| RpcError::InvalidParams {
        message: "Missing parameters".into(),
    })?;

    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            let mut storage = load_or_init_for_write(auth_path).map_err(map_auth_error)?;
            if let Some(mut pa) = storage.get_provider_auth(provider) {
                pa.api_keys = None;
                if matches!(pa.active_credential, Some(ActiveCredential::ApiKey { .. })) {
                    pa.active_credential = None;
                }
                storage.set_provider_auth(provider, &pa);
                save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)?;
            }
        } else if let Some(key) = api_key_val.as_str() {
            let label = api_key_label(params);
            save_named_api_key(auth_path, provider, label, key).map_err(map_auth_error)?;
        }
    }

    if let Some(oauth) = params.get("oauth") {
        if oauth.is_null() {
            let mut storage = load_or_init_for_write(auth_path).map_err(map_auth_error)?;
            if let Some(mut pa) = storage.get_provider_auth(provider) {
                pa.accounts = None;
                if matches!(pa.active_credential, Some(ActiveCredential::OAuth { .. })) {
                    pa.active_credential = None;
                }
                storage.set_provider_auth(provider, &pa);
                save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)?;
            }
        } else {
            let tokens = parse_oauth_tokens(oauth)?;
            crate::llm::auth::storage::save_account_oauth_tokens(
                auth_path,
                provider,
                "(default)",
                &tokens,
            )
            .map_err(map_auth_error)?;
        }
    }

    Ok(())
}

fn update_google_provider(auth_path: &Path, params: Option<&Value>) -> Result<(), RpcError> {
    let params = params.ok_or_else(|| RpcError::InvalidParams {
        message: "Missing parameters".into(),
    })?;

    let mut storage = load_or_init_for_write(auth_path).map_err(map_auth_error)?;
    let mut google = storage.get_google_auth().unwrap_or_default();

    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            google.base.api_keys = None;
        } else if let Some(key) = api_key_val.as_str() {
            google.base.api_keys = Some(vec![ApiKeyEntry {
                label: api_key_label(params).to_string(),
                key: key.to_string(),
            }]);
        }
    }
    if let Some(val) = params.get("clientId") {
        google.client_id = val.as_str().map(ToOwned::to_owned);
    }
    if let Some(val) = params.get("clientSecret") {
        google.client_secret = val.as_str().map(ToOwned::to_owned);
    }
    if let Some(val) = params.get("projectId") {
        google.project_id = val.as_str().map(ToOwned::to_owned);
    }
    if let Some(oauth) = params.get("oauth") {
        if oauth.is_null() {
            google.base.accounts = None;
        } else {
            let tokens = parse_oauth_tokens(oauth)?;
            google.base.accounts = Some(vec![AccountEntry {
                label: "(default)".to_owned(),
                oauth: tokens,
            }]);
        }
    }

    storage.set_google_auth(&google);
    save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)
}

fn update_service(auth_path: &Path, service: &str, params: Option<&Value>) -> Result<(), RpcError> {
    let params = params.ok_or_else(|| RpcError::InvalidParams {
        message: "Missing parameters".into(),
    })?;

    let mut storage = load_or_init_for_write(auth_path).map_err(map_auth_error)?;
    let services = storage.services.get_or_insert_with(HashMap::new);

    if let Some(api_key_val) = params.get("apiKey") {
        if api_key_val.is_null() {
            let _: Option<_> = services.remove(service);
        } else if let Some(key) = api_key_val.as_str()
            && !key.is_empty()
        {
            let _: Option<_> = services.insert(service.to_owned(), ServiceAuth::from_single(key));
        }
    }

    save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)
}

fn clear_service_auth(
    auth_path: &Path,
    service: &str,
) -> Result<(), crate::llm::auth::errors::AuthError> {
    let Some(mut storage) = load_auth_storage(auth_path)? else {
        return Ok(());
    };
    if let Some(ref mut services) = storage.services {
        let _: Option<_> = services.remove(service);
    }
    save_auth_storage(auth_path, &mut storage)
}

fn parse_oauth_tokens(oauth: &Value) -> Result<OAuthTokens, RpcError> {
    let access_token = oauth
        .get("accessToken")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.accessToken is required".into(),
        })?
        .to_owned();
    let refresh_token = oauth
        .get("refreshToken")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.refreshToken is required".into(),
        })?
        .to_owned();
    let expires_at = oauth
        .get("expiresAt")
        .and_then(Value::as_i64)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "oauth.expiresAt is required (milliseconds)".into(),
        })?;

    Ok(OAuthTokens {
        access_token,
        refresh_token,
        expires_at,
    })
}

fn api_key_label(params: &Value) -> &str {
    params
        .get("apiKeyLabel")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|label| !label.is_empty())
        .unwrap_or(DEFAULT_API_KEY_LABEL)
}

fn build_masked_state(auth_path: &Path) -> Result<Value, crate::llm::auth::errors::AuthError> {
    let storage = load_auth_storage(auth_path)?;
    let mut providers = serde_json::Map::new();

    for &provider in KNOWN_PROVIDERS {
        if provider == "google" {
            let google = storage
                .as_ref()
                .and_then(crate::llm::auth::types::AuthStorage::get_google_auth);
            let info = if let Some(ref google) = google {
                let mut info = build_provider_info(&google.base);
                if let Some(ref project_id) = google.project_id {
                    let _ = info.insert("projectId".into(), json!(project_id));
                }
                let _ = info.insert("hasClientId".into(), json!(google.client_id.is_some()));
                let _ = info.insert(
                    "hasClientSecret".into(),
                    json!(google.client_secret.is_some()),
                );
                info
            } else {
                empty_provider_info(true)
            };
            let _ = providers.insert(provider.to_owned(), Value::Object(info));
        } else {
            let pa = storage
                .as_ref()
                .and_then(|storage| storage.get_provider_auth(provider));
            let info = if let Some(ref pa) = pa {
                let mut info = build_provider_info(pa);
                if let Some(first_acct) = pa.accounts.as_ref().and_then(|accounts| accounts.first())
                {
                    let _ =
                        info.insert("oauthExpiresAt".into(), json!(first_acct.oauth.expires_at));
                    let is_expired =
                        crate::llm::auth::types::now_ms() >= first_acct.oauth.expires_at;
                    let _ = info.insert("isOAuthExpired".into(), json!(is_expired));
                }
                info
            } else {
                empty_provider_info(false)
            };
            let _ = providers.insert(provider.to_owned(), Value::Object(info));
        }
    }

    let mut services = serde_json::Map::new();
    for &service in KNOWN_SERVICES {
        let svc = storage
            .as_ref()
            .and_then(|storage| storage.get_service_auth(service));
        let mut info = serde_json::Map::new();
        if let Some(svc) = svc {
            let first = svc
                .api_keys
                .first()
                .expect("ServiceAuth.api_keys non-empty invariant");
            let _ = info.insert("hasApiKey".into(), json!(true));
            let _ = info.insert("apiKeyHint".into(), json!(mask_key(first)));
        } else {
            let _ = info.insert("hasApiKey".into(), json!(false));
        }
        let _ = services.insert(service.to_owned(), Value::Object(info));
    }

    Ok(json!({
        "providers": Value::Object(providers),
        "services": Value::Object(services),
    }))
}

fn empty_provider_info(google: bool) -> serde_json::Map<String, Value> {
    let mut info = serde_json::Map::new();
    let _ = info.insert("hasApiKey".into(), json!(false));
    let _ = info.insert("hasOAuth".into(), json!(false));
    let _ = info.insert("accounts".into(), json!([]));
    let _ = info.insert("apiKeys".into(), json!([]));
    if google {
        let _ = info.insert("hasClientId".into(), json!(false));
        let _ = info.insert("hasClientSecret".into(), json!(false));
    }
    info
}

fn build_provider_info(pa: &ProviderAuth) -> serde_json::Map<String, Value> {
    let mut info = serde_json::Map::new();

    let has_api_keys = pa.api_keys.as_ref().is_some_and(|keys| !keys.is_empty());
    let _ = info.insert("hasApiKey".into(), json!(has_api_keys));
    if let Some(first_key) = pa.api_keys.as_ref().and_then(|keys| keys.first()) {
        let _ = info.insert("apiKeyHint".into(), json!(mask_key(&first_key.key)));
    }

    let has_accounts = pa
        .accounts
        .as_ref()
        .is_some_and(|accounts| !accounts.is_empty());
    let _ = info.insert("hasOAuth".into(), json!(has_accounts));
    let _ = info.insert("accounts".into(), json!(build_accounts_list(pa)));
    let api_keys: Vec<Value> = pa
        .api_keys
        .as_ref()
        .map(|keys| {
            keys.iter()
                .map(|key| json!({"label": key.label, "keyHint": mask_key(&key.key)}))
                .collect()
        })
        .unwrap_or_default();
    let _ = info.insert("apiKeys".into(), json!(api_keys));

    let effective_active =
        crate::llm::auth::resolve_credential(pa, None).map(|resolved| match resolved {
            crate::llm::auth::ResolvedCredential::OAuthAccount(account) => {
                crate::llm::auth::ActiveCredential::OAuth {
                    label: account.label.clone(),
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

fn build_accounts_list(pa: &ProviderAuth) -> Vec<Value> {
    pa.accounts
        .as_ref()
        .map(|accounts| {
            accounts
                .iter()
                .map(|account| {
                    let is_expired = crate::llm::auth::types::now_ms() >= account.oauth.expires_at;
                    json!({
                        "label": account.label,
                        "expiresAt": account.oauth.expires_at,
                        "isExpired": is_expired,
                        "hasRefreshToken": !account.oauth.refresh_token.is_empty(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn mask_key(key: &str) -> String {
    if key.len() <= 8 {
        return "***".to_owned();
    }
    let prefix_end = key
        .find('-')
        .map_or(4, |i| {
            key[i + 1..].find('-').map_or(i + 1, |j| i + 1 + j + 1)
        })
        .min(10);
    let suffix_start = key.len().saturating_sub(4);
    format!("{}...{}", &key[..prefix_end], &key[suffix_start..])
}

async fn broadcast_auth_updated(
    deps: &EngineCapabilityDeps,
    invocation: &Invocation,
    masked_state: &Value,
) {
    let event = RpcEvent::new("auth.updated", None, Some(masked_state.clone()));
    super::publish_rpc_event_or_broadcast(deps, "auth", "auth", event, Some(invocation)).await;
}
