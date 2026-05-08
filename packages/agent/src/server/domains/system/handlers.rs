//! Operation binding for the system worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
    allow_server_context: bool,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "system::ping" => ping_value(Some(payload)),
        "system::get_info" => Ok(system_info_value(payload, deps, allow_server_context)),
        "system::get_diagnostics" => system_diagnostics_value(deps),
        "system::get_update_status" => system_update_status_value(deps).await,
        "system::check_for_updates" => system_check_for_updates_value(deps).await,
        "system::shutdown" => system_shutdown_value(deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("system method {method} is not engine-owned"),
        }),
    }
}
