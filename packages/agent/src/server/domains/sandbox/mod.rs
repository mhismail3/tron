//! sandbox domain worker.
//!
//! This module owns canonical function execution for the sandbox namespace and keeps
//! domain contracts, services, sandbox-created worker launch, and tests beside
//! the worker that uses them.

use std::time::{Duration, Instant};

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use serde_json::Value;
use serde_json::json;
use tokio::process::Command;
use tokio::time::sleep;

use crate::engine::{ActorContext, ActorKind, FunctionId, Invocation, WorkerId};
use crate::server::domains::worker::DomainRegistrationContext;
use crate::server::domains::worker::DomainWorkerModule;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::{opt_array, opt_string, opt_u64};

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

async fn spawn_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let worker_id = require_string_param(Some(payload), "workerId")?;
    let command = require_string_param(Some(payload), "command")?;
    let args = string_array(payload, "args")?;
    let expected_function_ids = string_array(payload, "expectedFunctionIds")?;
    let timeout_ms = opt_u64(Some(payload), "timeoutMs", 10_000).clamp(100, 60_000);
    let visibility = opt_string(Some(payload), "visibility").unwrap_or_else(|| "session".into());
    let session_id = opt_string(Some(payload), "sessionId")
        .or_else(|| invocation.causal_context.session_id.clone());
    let workspace_id = opt_string(Some(payload), "workspaceId")
        .or_else(|| invocation.causal_context.workspace_id.clone());
    if visibility == "session" && session_id.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "sandbox::spawn_worker requires sessionId for session-visible workers".into(),
        });
    }
    if visibility == "workspace" && workspace_id.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "sandbox::spawn_worker requires workspaceId for workspace-visible workers"
                .into(),
        });
    }
    if !matches!(visibility.as_str(), "session" | "workspace" | "system") {
        return Err(CapabilityError::InvalidParams {
            message: "visibility must be one of session, workspace, or system".into(),
        });
    }
    let working_directory = opt_string(Some(payload), "workingDirectory");
    if let Some(directory) = &working_directory {
        let path = std::path::Path::new(directory);
        if !path.is_dir() {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "workingDirectory does not exist or is not a directory: {directory}"
                ),
            });
        }
    }

    let endpoint = sandbox_service::worker_endpoint_from_origin(&deps.origin);
    let mut command_builder = Command::new(&command);
    command_builder
        .args(&args)
        .kill_on_drop(true)
        .env("TRON_ENGINE_WORKER_ENDPOINT", &endpoint)
        .env("TRON_ENGINE_WORKER_ID", &worker_id)
        .env("TRON_ENGINE_WORKER_VISIBILITY", &visibility)
        .env("TRON_ENGINE_WORKER_AUTH_POLICY", "loopback_bearer");
    if let Some(session_id) = &session_id {
        command_builder.env("TRON_ENGINE_SESSION_ID", session_id);
    }
    if let Some(workspace_id) = &workspace_id {
        command_builder.env("TRON_ENGINE_WORKSPACE_ID", workspace_id);
    }
    if let Some(directory) = &working_directory {
        command_builder.current_dir(directory);
    }

    let mut child = command_builder.spawn().map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            CapabilityError::NotAvailable {
                message: format!("sandbox worker command not found: {command}"),
            }
        } else {
            CapabilityError::Internal {
                message: format!("failed to spawn sandbox worker command: {error}"),
            }
        }
    })?;
    let process_id = child.id();

    let wait_result = wait_for_worker_registration(
        deps,
        &worker_id,
        &expected_function_ids,
        Duration::from_millis(timeout_ms),
        &mut child,
    )
    .await;

    let (registered_function_ids, catalog_revision) = match wait_result {
        Ok(value) => value,
        Err(error) => {
            let _ = child.kill().await;
            cleanup_partial_worker_registration(deps, &worker_id).await;
            return Err(error);
        }
    };

    deps.worker_processes.insert(worker_id.clone(), child).await;
    Ok(json!({
        "workerId": worker_id,
        "processId": process_id,
        "registeredFunctionIds": registered_function_ids,
        "catalogRevision": catalog_revision,
        "visibility": visibility,
        "workerEndpoint": endpoint,
        "streamTopic": contract::STREAM_TOPICS[0],
    }))
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

async fn wait_for_worker_registration(
    deps: &Deps,
    worker_id: &str,
    expected_function_ids: &[String],
    timeout: Duration,
    child: &mut tokio::process::Child,
) -> Result<(Vec<String>, u64), CapabilityError> {
    let worker_id =
        WorkerId::new(worker_id.to_owned()).map_err(|error| CapabilityError::InvalidParams {
            message: format!("invalid workerId: {error}"),
        })?;
    let expected = expected_function_ids
        .iter()
        .map(|id| {
            FunctionId::new(id.clone()).map_err(|error| CapabilityError::InvalidParams {
                message: format!("invalid expectedFunctionIds entry: {error}"),
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let started = Instant::now();
    loop {
        let registered = sandbox_worker_function_ids(deps, &worker_id).await;
        let worker_registered = deps.engine_host.inspect_worker(&worker_id).await.is_ok();
        let expected_ready = expected
            .iter()
            .all(|id| registered.iter().any(|actual| actual == id));
        if worker_registered && (expected.is_empty() || expected_ready) {
            return Ok((
                registered
                    .into_iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>(),
                deps.engine_host.catalog_revision().await.0,
            ));
        }
        if let Some(status) = child
            .try_wait()
            .map_err(|error| CapabilityError::Internal {
                message: format!("failed to inspect sandbox worker process: {error}"),
            })?
        {
            return Err(CapabilityError::Internal {
                message: format!(
                    "sandbox worker process exited before registration completed with status {status}"
                ),
            });
        }
        if started.elapsed() >= timeout {
            return Err(CapabilityError::Internal {
                message: format!("sandbox worker {worker_id} did not register before timeout"),
            });
        }
        sleep(Duration::from_millis(50)).await;
    }
}

async fn sandbox_worker_function_ids(deps: &Deps, worker_id: &WorkerId) -> Vec<FunctionId> {
    let actor = ActorContext::new(
        crate::engine::ActorId::new("sandbox-spawn-worker").expect("valid static actor id"),
        ActorKind::System,
        crate::engine::AuthorityGrantId::new("sandbox-spawn-worker")
            .expect("valid static authority id"),
    );
    deps.engine_host
        .discover(&crate::engine::FunctionQuery {
            actor: Some(actor),
            include_internal: true,
            ..crate::engine::FunctionQuery::default()
        })
        .await
        .into_iter()
        .filter(|function| &function.owner_worker == worker_id)
        .map(|function| function.id)
        .collect()
}

async fn cleanup_partial_worker_registration(deps: &Deps, worker_id: &str) {
    if let Ok(id) = WorkerId::new(worker_id.to_owned()) {
        deps.worker_processes.kill(worker_id).await;
        if let Ok(worker) = deps.engine_host.inspect_worker(&id).await {
            let _ = deps
                .engine_host
                .unregister_worker(&id, worker.owner_actor.as_str())
                .await;
        }
    }
}

fn string_array(payload: &Value, key: &str) -> Result<Vec<String>, CapabilityError> {
    opt_array(Some(payload), key)
        .map(|items| {
            items
                .iter()
                .map(|item| {
                    item.as_str().map(ToOwned::to_owned).ok_or_else(|| {
                        CapabilityError::InvalidParams {
                            message: format!("Parameter '{key}' entries must be strings"),
                        }
                    })
                })
                .collect()
        })
        .unwrap_or_else(|| Ok(Vec::new()))
}
