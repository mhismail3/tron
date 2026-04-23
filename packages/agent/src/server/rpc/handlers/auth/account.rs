use super::*;

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
                .map_err(map_auth_error)?;

                build_masked_state(&auth_path).map_err(map_auth_error)
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

                // set_active_credential validates that the named
                // account/key actually exists for this provider; treat
                // failure as bad params, not an internal error. The
                // storage layer expresses "label not found" as
                // AuthError::Io with ErrorKind::NotFound which would
                // otherwise route through map_auth_error to
                // INTERNAL_ERROR.
                crate::llm::auth::storage::set_active_credential(&auth_path, &provider, &credential)
                    .map_err(|e| RpcError::InvalidParams {
                        message: format!("Failed to set active credential: {e}"),
                    })?;

                build_masked_state(&auth_path).map_err(map_auth_error)
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
                    .map_err(map_auth_error)?;

                build_masked_state(&auth_path).map_err(map_auth_error)
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
                    .map_err(map_auth_error)?;

                build_masked_state(&auth_path).map_err(map_auth_error)
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}
