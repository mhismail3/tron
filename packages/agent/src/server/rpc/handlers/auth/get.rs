use super::*;

/// Get masked auth state for all providers and services.
pub struct GetAuthHandler;

#[async_trait]
impl MethodHandler for GetAuthHandler {
    #[instrument(skip(self, ctx), fields(method = "auth.get"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let auth_path = ctx.auth_path.clone();
        ctx.run_blocking("auth.get", move || {
            build_masked_state(&auth_path).map_err(map_auth_error)
        })
        .await
    }
}
