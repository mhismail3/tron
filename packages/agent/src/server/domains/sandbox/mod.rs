//! sandbox domain worker.
//!
//! This module owns canonical function execution for the sandbox namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::server::domains::worker::DomainRegistrationContext;
use crate::server::domains::worker::DomainWorkerModule;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::server::domains::worker::domain_worker_module(
            "sandbox",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod service;

use crate::server::domains::sandbox::service as sandbox_service;
use crate::server::shared::params::require_string_param;

async fn list_containers(_deps: &Deps) -> Result<Value, CapabilityError> {
    let path = sandbox_service::containers_json_path();
    let mut containers = run_blocking_task("sandbox.list_containers.load_metadata", move || {
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

async fn remove_container(payload: &Value, _deps: &Deps) -> Result<Value, CapabilityError> {
    let name = require_string_param(Some(payload), "name")?;
    sandbox_service::remove_container_runtime_best_effort(&name).await;

    let metadata_path = sandbox_service::containers_json_path();
    let name_for_metadata = name.clone();
    run_blocking_task("sandbox.remove_container_metadata", move || {
        sandbox_service::remove_container_metadata_at(&metadata_path, &name_for_metadata)
    })
    .await?;

    Ok(json!({ "success": true }))
}
