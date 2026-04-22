use super::*;
use super::oauth::parse_oauth_tokens;

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
                save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)?;
            }
        } else if let Some(key) = api_key_val.as_str() {
            // Use provided label, or generate a default
            let label = params
                .get("apiKeyLabel")
                .and_then(|v| v.as_str())
                .unwrap_or("(default)");
            save_named_api_key(auth_path, provider, label, key).map_err(map_auth_error)?;
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
                save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)?;
            }
        } else {
            // Save as account with default label
            let tokens = parse_oauth_tokens(oauth)?;
            crate::llm::auth::storage::save_account_oauth_tokens(
                auth_path, provider, "(default)", &tokens,
            )
            .map_err(map_auth_error)?;
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
    save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)?;

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
        } else if let Some(key) = api_key_val.as_str()
            && !key.is_empty()
        {
            let _ = services.insert(service.to_string(), ServiceAuth::from_single(key));
        }
    }

    save_auth_storage(auth_path, &mut storage).map_err(map_auth_error)?;

    Ok(())
}
