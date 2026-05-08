//! Operation binding for the skills worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "skills::list" => Ok(skill_list_value(Some(payload), deps)),
        "skills::get" => skill_get_value(Some(payload), deps),
        "skills::refresh" => skill_refresh_value(Some(payload), deps).await,
        "skills::activate" => skill_activate_value(Some(payload), deps),
        "skills::deactivate" => skill_deactivate_value(Some(payload), deps),
        "skills::active" => skill_active_value(Some(payload), deps),
        _ => Err(CapabilityError::Internal {
            message: format!("skills method {method} is not engine-owned"),
        }),
    }
}
