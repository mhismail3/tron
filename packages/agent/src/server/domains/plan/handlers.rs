//! Operation binding for the plan worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "plan::enter" => plan_set_value(Some(payload), deps, true),
        "plan::exit" => plan_set_value(Some(payload), deps, false),
        "plan::get_state" => plan_get_state_value(Some(payload), deps),
        _ => Err(CapabilityError::Internal {
            message: format!("plan method {method} is not engine-owned"),
        }),
    }
}
