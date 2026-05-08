//! Operation binding for the codex_app worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    _invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "codex_app::status" => codex_app_status_value(deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("codex app method {method} is not engine-owned"),
        }),
    }
}
