//! Auth workflow operations.
use super::*;

pub(crate) async fn auth_get(deps: &Deps) -> Result<Value, CapabilityError> {
    let auth_path = deps.auth_path.clone();
    run_blocking_task("auth::get", move || {
        build_masked_state(&auth_path).map_err(map_auth_error)
    })
    .await
}

pub(crate) async fn auth_update(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let provider = opt_string(Some(payload), "provider");
    let service = opt_string(Some(payload), "service");

    if provider.is_none() && service.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "Missing required parameter: provider or service".into(),
        });
    }

    let auth_path = deps.auth_path.clone();
    let payload = payload.clone();
    let masked_state = run_blocking_task("auth::update", move || {
        let _lock =
            acquire_auth_file_lock(&auth_path).map_err(|error| CapabilityError::Internal {
                message: format!("Failed to acquire auth lock: {error}"),
            })?;

        if let Some(ref provider) = provider {
            if !KNOWN_PROVIDERS.contains(&provider.as_str()) {
                return Err(CapabilityError::InvalidParams {
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

    publish_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

pub(crate) async fn auth_clear(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let provider = opt_string(Some(payload), "provider");
    let service = opt_string(Some(payload), "service");

    if provider.is_none() && service.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "Missing required parameter: provider or service".into(),
        });
    }

    let auth_path = deps.auth_path.clone();
    let masked_state = run_blocking_task("auth::clear", move || {
        let _lock =
            acquire_auth_file_lock(&auth_path).map_err(|error| CapabilityError::Internal {
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

    publish_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}
