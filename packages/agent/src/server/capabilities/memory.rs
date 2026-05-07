use super::*;

use crate::server::services::memory_retain as rpc_memory;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    match method {
        "memory::retain" => retain_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("memory method {method} is not engine-owned"),
        }),
    }
}

async fn retain_value(
    payload: &Value,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    rpc_memory::trigger_manual_retain(Some(payload), &deps.capability_context).await
}
