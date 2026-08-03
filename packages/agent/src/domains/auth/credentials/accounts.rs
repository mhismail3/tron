//! Auth workflow operations.
use super::{KNOWN_PROVIDERS, acquire_auth_file_lock, clear_provider_auth, map_auth_error};
use super::{
    build_masked_state, publish_auth_updated, update_google_provider, update_standard_provider,
};
use crate::domains::auth::Deps;
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::ToolError;
use crate::shared::server::params::opt_string;
use serde_json::Value;

pub(crate) async fn auth_get(deps: &Deps) -> Result<Value, ToolError> {
    let auth_path = deps.auth_path.clone();
    run_blocking_task("auth::get", move || {
        build_masked_state(&auth_path).map_err(map_auth_error)
    })
    .await
}

pub(crate) async fn auth_update(invocation: &Invocation, deps: &Deps) -> Result<Value, ToolError> {
    let payload = &invocation.payload;
    let provider = opt_string(Some(payload), "provider");
    if provider.is_none() {
        return Err(ToolError::InvalidParams {
            message: "Missing required parameter: provider".into(),
        });
    }

    let auth_path = deps.auth_path.clone();
    let payload = payload.clone();
    let masked_state = run_blocking_task("auth::update", move || {
        let _lock = acquire_auth_file_lock(&auth_path).map_err(|error| ToolError::Internal {
            message: format!("Failed to acquire auth lock: {error}"),
        })?;

        if let Some(ref provider) = provider {
            if !KNOWN_PROVIDERS.contains(&provider.as_str()) {
                return Err(ToolError::InvalidParams {
                    message: format!("Unknown provider: {provider}"),
                });
            }
            if provider == "google" {
                update_google_provider(&auth_path, Some(&payload))?;
            } else {
                update_standard_provider(&auth_path, provider, Some(&payload))?;
            }
        }

        build_masked_state(&auth_path).map_err(map_auth_error)
    })
    .await?;

    publish_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

pub(crate) async fn auth_clear(invocation: &Invocation, deps: &Deps) -> Result<Value, ToolError> {
    let payload = &invocation.payload;
    let provider = opt_string(Some(payload), "provider");
    if provider.is_none() {
        return Err(ToolError::InvalidParams {
            message: "Missing required parameter: provider".into(),
        });
    }

    let auth_path = deps.auth_path.clone();
    let masked_state = run_blocking_task("auth::clear", move || {
        let _lock = acquire_auth_file_lock(&auth_path).map_err(|error| ToolError::Internal {
            message: format!("Failed to acquire auth lock: {error}"),
        })?;

        if let Some(ref provider) = provider {
            clear_provider_auth(&auth_path, provider).map_err(map_auth_error)?;
        }

        build_masked_state(&auth_path).map_err(map_auth_error)
    })
    .await?;

    publish_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}
