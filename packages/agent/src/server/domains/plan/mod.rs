//! plan domain worker.
//!
//! This module owns canonical function execution for the plan namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod spec;

use super::*;
#[derive(Clone)]
pub(crate) struct Deps {
    session_manager: Arc<SessionManager>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            session_manager: deps.session_manager.clone(),
        }
    }
}

pub(super) async fn handle(
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

fn plan_set_value(
    params: Option<&Value>,
    deps: &Deps,
    enabled: bool,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    deps.session_manager.set_plan_mode(&session_id, enabled);
    Ok(json!({ "planMode": enabled }))
}

fn plan_get_state_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    Ok(json!({
        "planMode": deps.session_manager.is_plan_mode(&session_id),
    }))
}
