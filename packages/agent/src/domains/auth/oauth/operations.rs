//! Auth workflow operations.
use super::{OAUTH_FLOW_TTL_SECS, OAUTH_PROVIDERS};
use crate::domains::auth::Deps;
use crate::domains::auth::credentials::{
    ActiveCredential, map_auth_error, write_auth_and_broadcast,
};
use crate::engine::Invocation;
use crate::shared::server::errors::ToolError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn auth_oauth_begin(payload: &Value, deps: &Deps) -> Result<Value, ToolError> {
    let provider = require_string_param(Some(payload), "provider")?;

    let flow = crate::domains::auth::oauth::flows::prepare_oauth_flow(&provider, &deps.auth_path)
        .map_err(map_auth_error)?
        .ok_or_else(|| ToolError::InvalidParams {
            message: if provider == "google" {
                "Google OAuth requires a client_id - configure it in Settings > Providers > Google"
                    .into()
            } else {
                format!(
                    "OAuth login supported for: {}. Got: {provider}",
                    OAUTH_PROVIDERS.join(", "),
                )
            },
        })?;

    let flow_id = uuid::Uuid::now_v7().to_string();
    let mut flows = deps.oauth_flows.lock().await;
    flows.retain(|_, flow| {
        flow.created_at.elapsed() < std::time::Duration::from_secs(OAUTH_FLOW_TTL_SECS)
    });
    let _ = flows.insert(
        flow_id.clone(),
        crate::domains::auth::oauth::flows::PendingOAuthFlow {
            verifier: flow.verifier,
            provider,
            created_at: std::time::Instant::now(),
        },
    );

    Ok(json!({
        "flowId": flow_id,
        "authUrl": flow.auth_url,
    }))
}

pub(crate) async fn auth_oauth_complete(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let payload = &invocation.payload;
    let flow_id = require_string_param(Some(payload), "flowId")?;
    let code = require_string_param(Some(payload), "code")?;
    let label = require_string_param(Some(payload), "label")?;

    let flow = {
        let mut flows = deps.oauth_flows.lock().await;
        flows.remove(&flow_id)
    }
    .ok_or_else(|| ToolError::InvalidParams {
        message: "OAuth flow not found or expired".into(),
    })?;

    if flow.created_at.elapsed() > std::time::Duration::from_secs(OAUTH_FLOW_TTL_SECS) {
        return Err(ToolError::InvalidParams {
            message: "OAuth flow expired".into(),
        });
    }

    let tokens = crate::domains::auth::oauth::flows::exchange_oauth_code(
        &flow.provider,
        &deps.auth_path,
        &code,
        &flow.verifier,
        None,
    )
    .await
    .map_err(map_auth_error)?
    .ok_or_else(|| {
        if flow.provider == "google" {
            ToolError::Internal {
                message: "Google client_id is no longer configured - cannot complete OAuth".into(),
            }
        } else {
            ToolError::InvalidParams {
                message: format!("Unsupported OAuth provider: {}", flow.provider),
            }
        }
    })?;

    let provider_key = flow.provider;
    write_auth_and_broadcast(deps, invocation, "auth::oauth_complete", move |auth_path| {
        crate::domains::auth::credentials::storage::save_account_oauth_tokens(
            auth_path,
            &provider_key,
            &label,
            &tokens,
        )
        .map_err(map_auth_error)
    })
    .await
}

pub(crate) async fn auth_rename_account(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let old_label = require_string_param(Some(payload), "oldLabel")?;
    let new_label = require_string_param(Some(payload), "newLabel")?;

    write_auth_and_broadcast(deps, invocation, "auth::rename_account", move |auth_path| {
        crate::domains::auth::credentials::storage::rename_account(
            auth_path, &provider, &old_label, &new_label,
        )
        .map_err(map_auth_error)
    })
    .await
}

pub(crate) async fn auth_set_active(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let cred_val = payload
        .get("credential")
        .ok_or_else(|| ToolError::InvalidParams {
            message: "Missing required parameter: credential".into(),
        })?;
    let credential: ActiveCredential =
        serde_json::from_value(cred_val.clone()).map_err(|error| ToolError::InvalidParams {
            message: format!("Invalid credential: {error}"),
        })?;

    write_auth_and_broadcast(deps, invocation, "auth::set_active", move |auth_path| {
        crate::domains::auth::credentials::storage::set_active_credential(
            auth_path,
            &provider,
            &credential,
        )
        .map_err(|error| ToolError::InvalidParams {
            message: format!("Failed to set active credential: {error}"),
        })
    })
    .await
}

pub(crate) async fn auth_remove_account(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let label = require_string_param(Some(payload), "label")?;
    write_auth_and_broadcast(deps, invocation, "auth::remove_account", move |auth_path| {
        crate::domains::auth::credentials::storage::remove_account(auth_path, &provider, &label)
            .map_err(map_auth_error)
    })
    .await
}

pub(crate) async fn auth_remove_api_key(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let label = require_string_param(Some(payload), "label")?;
    write_auth_and_broadcast(deps, invocation, "auth::remove_api_key", move |auth_path| {
        crate::domains::auth::credentials::storage::remove_named_api_key(
            auth_path, &provider, &label,
        )
        .map_err(map_auth_error)
    })
    .await
}
