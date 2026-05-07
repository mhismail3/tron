use super::*;

use crate::server::rpc::handlers::memory as rpc_memory;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    match method {
        "memory.retain" => retain_value(&invocation.payload, invocation, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("memory method {method} is not engine-owned"),
        }),
    }
}

async fn retain_value(
    payload: &Value,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let lease_id = super::acquire_invocation_lease(
        invocation,
        deps,
        "session",
        format!("session:{session_id}:memory-retain"),
        300_000,
    )
    .await?;
    let result = rpc_memory::trigger_retain(
        &rpc_memory::RetainDeps::from_rpc(&deps.rpc_context),
        session_id,
        rpc_memory::RetainSource::Manual,
    )
    .await;
    super::release_invocation_lease_after(deps, lease_id, result).await
}
