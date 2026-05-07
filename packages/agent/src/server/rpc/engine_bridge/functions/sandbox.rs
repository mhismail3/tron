use super::*;

use crate::server::rpc::params::require_string_param;
use crate::server::rpc::sandbox_service;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    match method {
        "sandbox.startContainer" => run_container_command("start", &invocation.payload).await,
        "sandbox.stopContainer" => run_container_command("stop", &invocation.payload).await,
        "sandbox.killContainer" => run_container_command("kill", &invocation.payload).await,
        "sandbox.removeContainer" => remove_container(&invocation.payload, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("sandbox method {method} is not engine-owned"),
        }),
    }
}

async fn run_container_command(action: &str, payload: &Value) -> Result<Value, RpcError> {
    let name = require_string_param(Some(payload), "name")?;
    sandbox_service::run_container_command(action, &name).await
}

async fn remove_container(payload: &Value, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let name = require_string_param(Some(payload), "name")?;
    sandbox_service::remove_container_runtime_best_effort(&name).await;

    let metadata_path = sandbox_service::containers_json_path();
    let name_for_metadata = name.clone();
    deps.rpc_context
        .run_blocking("sandbox.remove_container_metadata", move || {
            sandbox_service::remove_container_metadata_at(&metadata_path, &name_for_metadata)
        })
        .await?;

    Ok(json!({ "success": true }))
}
