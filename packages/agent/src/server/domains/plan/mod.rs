//! plan domain worker.
//!
//! This module owns canonical function execution for the plan namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "plan",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::plan_handler,
    )
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
