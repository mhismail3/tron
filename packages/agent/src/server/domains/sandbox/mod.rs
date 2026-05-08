//! sandbox domain worker.
//!
//! This module owns canonical function execution for the sandbox namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;

use super::*;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "sandbox",
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::sandbox_handler,
    )
}
#[derive(Clone)]
pub(crate) struct Deps {
    capability_context: Arc<ServerCapabilityContext>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            capability_context: deps.capability_context.clone(),
        }
    }
}

pub(crate) mod service;

use crate::server::domains::sandbox::service as sandbox_service;
use crate::server::shared::params::require_string_param;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "sandbox::list_containers" => list_containers(deps).await,
        "sandbox::start_container" => run_container_command("start", &invocation.payload).await,
        "sandbox::stop_container" => run_container_command("stop", &invocation.payload).await,
        "sandbox::kill_container" => run_container_command("kill", &invocation.payload).await,
        "sandbox::remove_container" => remove_container(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("sandbox method {method} is not engine-owned"),
        }),
    }
}

async fn list_containers(deps: &Deps) -> Result<Value, CapabilityError> {
    let path = sandbox_service::containers_json_path();
    let mut containers = deps
        .capability_context
        .run_blocking("sandbox.list_containers.load_metadata", move || {
            sandbox_service::load_containers(&path)
        })
        .await?;
    let statuses = sandbox_service::query_container_statuses().await;
    for container in &mut containers {
        let name = container
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let status = statuses.get(name).cloned().unwrap_or_else(|| "gone".into());
        let _ = container
            .as_object_mut()
            .expect("container entry must be an object")
            .insert("status".into(), Value::String(status));
    }
    let host_ip = crate::settings::get_settings().server.tailscale_ip.clone();
    Ok(json!({
        "containers": containers,
        "hostIp": host_ip,
    }))
}

async fn run_container_command(action: &str, payload: &Value) -> Result<Value, CapabilityError> {
    let name = require_string_param(Some(payload), "name")?;
    sandbox_service::run_container_command(action, &name).await
}

async fn remove_container(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
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
