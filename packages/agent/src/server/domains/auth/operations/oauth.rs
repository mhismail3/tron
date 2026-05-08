//! Auth workflow operations.
use super::{
    ActiveCredential, OAUTH_FLOW_TTL_SECS, OAUTH_PROVIDERS, acquire_auth_file_lock, map_auth_error,
};
use super::{build_masked_state, publish_auth_updated, write_auth_and_broadcast};
use crate::engine::Invocation;
use crate::server::domains::auth::Deps;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn auth_oauth_begin(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
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
                    .ok_or_else(|| CapabilityError::InvalidParams {
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
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "OAuth login supported for: {}. Got: {provider}",
                    OAUTH_PROVIDERS.join(", "),
                ),
            });
        }
    };

    let flow_id = uuid::Uuid::now_v7().to_string();
    let mut flows = deps.oauth_flows.lock().await;
    flows.retain(|_, flow| {
        flow.created_at.elapsed() < std::time::Duration::from_secs(OAUTH_FLOW_TTL_SECS)
    });
    let _ = flows.insert(
        flow_id.clone(),
        crate::server::domains::auth::flows::PendingOAuthFlow {
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

pub(crate) async fn auth_oauth_complete(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let flow_id = require_string_param(Some(payload), "flowId")?;
    let code = require_string_param(Some(payload), "code")?;
    let label = require_string_param(Some(payload), "label")?;

    let flow = {
        let mut flows = deps.oauth_flows.lock().await;
        flows.remove(&flow_id)
    }
    .ok_or_else(|| CapabilityError::InvalidParams {
        message: "OAuth flow not found or expired".into(),
    })?;

    if flow.created_at.elapsed() > std::time::Duration::from_secs(OAUTH_FLOW_TTL_SECS) {
        return Err(CapabilityError::InvalidParams {
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
                .ok_or_else(|| CapabilityError::Internal {
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
            return Err(CapabilityError::InvalidParams {
                message: format!("Unsupported OAuth provider: {}", flow.provider),
            });
        }
    }
    .map_err(map_auth_error)?;

    let auth_path = deps.auth_path.clone();
    let provider_key = flow.provider;
    let masked_state = run_blocking_task("auth::oauth_complete", move || {
        let _lock =
            acquire_auth_file_lock(&auth_path).map_err(|error| CapabilityError::Internal {
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

    publish_auth_updated(deps, invocation, &masked_state).await;
    Ok(masked_state)
}

pub(crate) async fn auth_rename_account(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let old_label = require_string_param(Some(payload), "oldLabel")?;
    let new_label = require_string_param(Some(payload), "newLabel")?;

    write_auth_and_broadcast(deps, invocation, "auth::rename_account", move |auth_path| {
        crate::llm::auth::storage::rename_account(auth_path, &provider, &old_label, &new_label)
            .map_err(map_auth_error)
    })
    .await
}

pub(crate) async fn auth_set_active(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let cred_val = payload
        .get("credential")
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "Missing required parameter: credential".into(),
        })?;
    let credential: ActiveCredential =
        serde_json::from_value(cred_val.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid credential: {error}"),
            }
        })?;

    write_auth_and_broadcast(deps, invocation, "auth::set_active", move |auth_path| {
        crate::llm::auth::storage::set_active_credential(auth_path, &provider, &credential).map_err(
            |error| CapabilityError::InvalidParams {
                message: format!("Failed to set active credential: {error}"),
            },
        )
    })
    .await
}

pub(crate) async fn auth_remove_account(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let label = require_string_param(Some(payload), "label")?;
    write_auth_and_broadcast(deps, invocation, "auth::remove_account", move |auth_path| {
        crate::llm::auth::storage::remove_account(auth_path, &provider, &label)
            .map_err(map_auth_error)
    })
    .await
}

pub(crate) async fn auth_remove_api_key(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let provider = require_string_param(Some(payload), "provider")?;
    let label = require_string_param(Some(payload), "label")?;
    write_auth_and_broadcast(deps, invocation, "auth::remove_api_key", move |auth_path| {
        crate::llm::auth::storage::remove_named_api_key(auth_path, &provider, &label)
            .map_err(map_auth_error)
    })
    .await
}
