use super::*;

use crate::server::capabilities::params::require_string_param;
use crate::server::services::sandbox_service;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    match method {
        "sandbox::start_container" => run_container_command("start", &invocation.payload).await,
        "sandbox::stop_container" => run_container_command("stop", &invocation.payload).await,
        "sandbox::kill_container" => run_container_command("kill", &invocation.payload).await,
        "sandbox::remove_container" => remove_container(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("sandbox method {method} is not engine-owned"),
        }),
    }
}

async fn run_container_command(action: &str, payload: &Value) -> Result<Value, CapabilityError> {
    let name = require_string_param(Some(payload), "name")?;
    sandbox_service::run_container_command(action, &name).await
}

async fn remove_container(
    payload: &Value,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let name = require_string_param(Some(payload), "name")?;
    sandbox_service::remove_container_runtime_best_effort(&name).await;

    let metadata_path = sandbox_service::containers_json_path();
    let name_for_metadata = name.clone();
    deps.capability_context
        .run_blocking("sandbox.remove_container_metadata", move || {
            sandbox_service::remove_container_metadata_at(&metadata_path, &name_for_metadata)
        })
        .await?;

    Ok(json!({ "success": true }))
}
