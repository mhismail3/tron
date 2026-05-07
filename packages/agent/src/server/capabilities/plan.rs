use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
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

fn plan_set_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
    enabled: bool,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    deps.session_manager.set_plan_mode(&session_id, enabled);
    Ok(json!({ "planMode": enabled }))
}

fn plan_get_state_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    Ok(json!({
        "planMode": deps.session_manager.is_plan_mode(&session_id),
    }))
}
