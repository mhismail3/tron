use super::*;

use crate::server::rpc::handlers::memory as rpc_memory;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    match method {
        "memory.retain" => retain_value(&invocation.payload, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("memory method {method} is not engine-owned"),
        }),
    }
}

async fn retain_value(payload: &Value, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    rpc_memory::trigger_retain(
        &rpc_memory::RetainDeps::from_rpc(&deps.rpc_context),
        session_id,
        rpc_memory::RetainSource::Manual,
    )
    .await
}
