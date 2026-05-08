//! Auth workflow operations.
use super::*;

pub(crate) async fn write_auth_and_broadcast<F>(
    deps: &Deps,
    invocation: &Invocation,
    task_name: &'static str,
    mutate: F,
) -> Result<Value, CapabilityError>
where
    F: FnOnce(&Path) -> Result<(), CapabilityError> + Send + 'static,
{
    let auth_path = deps.auth_path.clone();
    let masked_state = run_blocking_task(task_name, move || {
        let _lock =
            acquire_auth_file_lock(&auth_path).map_err(|error| CapabilityError::Internal {
                message: format!("Failed to acquire auth lock: {error}"),
            })?;
        mutate(&auth_path)?;
        build_masked_state(&auth_path).map_err(map_auth_error)
    })
    .await?;
    broadcast_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

pub(crate) fn update_standard_provider(
    auth_path: &Path,
    provider: &str,
    params: Option<&Value>,
) -> Result<(), CapabilityError> {
    let params = params.ok_or_else(|| CapabilityError::InvalidParams {
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

pub(crate) fn update_google_provider(
    auth_path: &Path,
    params: Option<&Value>,
) -> Result<(), CapabilityError> {
    let params = params.ok_or_else(|| CapabilityError::InvalidParams {
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

pub(crate) fn update_service(
    auth_path: &Path,
    service: &str,
    params: Option<&Value>,
) -> Result<(), CapabilityError> {
    let params = params.ok_or_else(|| CapabilityError::InvalidParams {
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

pub(crate) fn clear_service_auth(
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

pub(crate) fn parse_oauth_tokens(oauth: &Value) -> Result<OAuthTokens, CapabilityError> {
    let access_token = oauth
        .get("accessToken")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "oauth.accessToken is required".into(),
        })?
        .to_owned();
    let refresh_token = oauth
        .get("refreshToken")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "oauth.refreshToken is required".into(),
        })?
        .to_owned();
    let expires_at = oauth
        .get("expiresAt")
        .and_then(Value::as_i64)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "oauth.expiresAt is required (milliseconds)".into(),
        })?;

    Ok(OAuthTokens {
        access_token,
        refresh_token,
        expires_at,
    })
}

pub(crate) fn api_key_label(params: &Value) -> &str {
    params
        .get("apiKeyLabel")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|label| !label.is_empty())
        .unwrap_or(DEFAULT_API_KEY_LABEL)
}

pub(crate) fn build_masked_state(
    auth_path: &Path,
) -> Result<Value, crate::llm::auth::errors::AuthError> {
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

pub(crate) fn empty_provider_info(google: bool) -> serde_json::Map<String, Value> {
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

pub(crate) fn build_provider_info(pa: &ProviderAuth) -> serde_json::Map<String, Value> {
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

pub(crate) fn build_accounts_list(pa: &ProviderAuth) -> Vec<Value> {
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

pub(crate) fn mask_key(key: &str) -> String {
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

pub(crate) async fn broadcast_auth_updated(
    deps: &Deps,
    invocation: &Invocation,
    masked_state: &Value,
) {
    crate::server::domains::auth::stream::AuthStreamPublisher::new(&deps.engine_host)
        .updated(invocation, masked_state)
        .await;
}
