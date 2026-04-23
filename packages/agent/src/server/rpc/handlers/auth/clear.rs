use super::*;

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
                    clear_provider_auth(&auth_path, provider).map_err(map_auth_error)?;
                } else if let Some(ref service) = service {
                    clear_service_auth(&auth_path, service).map_err(map_auth_error)?;
                }

                build_masked_state(&auth_path).map_err(map_auth_error)
            })
            .await?;

        broadcast_auth_updated(ctx, &masked_state).await;
        Ok(masked_state)
    }
}

fn clear_service_auth(auth_path: &Path, service: &str) -> Result<(), crate::llm::auth::errors::AuthError> {
    let Some(mut storage) = load_auth_storage(auth_path)? else {
        return Ok(());
    };
    if let Some(ref mut services) = storage.services {
        let _: Option<_> = services.remove(service);
    }
    save_auth_storage(auth_path, &mut storage)
}
