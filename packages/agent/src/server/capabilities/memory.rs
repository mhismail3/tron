use super::*;

use crate::server::rpc::memory_retain as rpc_memory;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    match method {
        "memory.retain" => retain_value(&invocation.payload, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("memory method {method} is not engine-owned"),
        }),
    }
}

async fn retain_value(payload: &Value, deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
    rpc_memory::trigger_manual_retain(Some(payload), &deps.rpc_context).await
}
