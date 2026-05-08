//! Operation binding for the auth worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "auth::get" => auth_get(deps).await,
        "auth::update" => auth_update(invocation, deps).await,
        "auth::clear" => auth_clear(invocation, deps).await,
        "auth::oauth_begin" => auth_oauth_begin(&invocation.payload, deps).await,
        "auth::oauth_complete" => auth_oauth_complete(invocation, deps).await,
        "auth::rename_account" => auth_rename_account(invocation, deps).await,
        "auth::set_active" => auth_set_active(invocation, deps).await,
        "auth::remove_account" => auth_remove_account(invocation, deps).await,
        "auth::remove_api_key" => auth_remove_api_key(invocation, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("auth method {method} is not engine-owned"),
        }),
    }
}
