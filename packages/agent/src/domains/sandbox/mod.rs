//! sandbox domain worker.
//!
//! This module owns canonical function execution for the sandbox namespace and
//! keeps domain contracts, services, sandbox-created worker launch/stop
//! lifecycle, and tests beside the worker that uses them. Spawned workers are
//! local `/engine/workers` participants with a derived child grant and scoped
//! endpoint/token environment; cleanup routes through `worker::disconnect` and
//! lifecycle events publish to `sandbox.lifecycle`.

use std::path::Path;
use std::time::{Duration, Instant};

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use serde_json::Value;
use serde_json::json;
use tokio::process::Command;
use tokio::time::sleep;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, FunctionId,
    Invocation, TraceId, WorkerId,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{CapabilityError, NOT_FOUND};
use crate::shared::server::params::{opt_array, opt_string, opt_u64};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        let mut module = crate::domains::worker::domain_worker_module(
            "sandbox",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )?;
        module.worker = module.worker.with_namespace_claim("worker");
        Ok(module)
    }
}

pub(crate) mod service;

use crate::domains::sandbox::service as sandbox_service;
use crate::shared::server::params::require_string_param;

async fn list_spawned_workers(deps: &Deps) -> Result<Value, CapabilityError> {
    Ok(json!({ "workers": deps.worker_processes.list().await }))
}

async fn get_spawned_worker(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let worker_id = require_string_param(Some(&invocation.payload), "workerId")?;
    Ok(json!({ "worker": deps.worker_processes.get(&worker_id).await }))
}

async fn stop_spawned_worker(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let worker_id = require_string_param(Some(&invocation.payload), "workerId")?;
    let reason =
        opt_string(Some(&invocation.payload), "reason").unwrap_or_else(|| "requested".into());
    let mut record = deps
        .worker_processes
        .stop(&worker_id, Some(reason.as_str()))
        .await
        .ok_or_else(|| CapabilityError::NotFound {
            code: NOT_FOUND.into(),
            message: format!("sandbox worker not found: {worker_id}"),
        })?;

    disconnect_worker_via_engine(deps, invocation, &worker_id, &reason).await?;
    record.catalog_revision = deps.engine_host.catalog_revision().await.0;
    publish_sandbox_lifecycle_event(deps, invocation, "sandbox.worker_stopped", &record).await?;

    Ok(json!({
        "worker": record,
        "catalogRevision": deps.engine_host.catalog_revision().await.0,
        "stopped": true,
        "streamTopic": contract::STREAM_TOPICS[0],
    }))
}

async fn spawn_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let worker_id = require_string_param(Some(payload), "workerId")?;
    let command = require_string_param(Some(payload), "command")?;
    let args = string_array(payload, "args")?;
    let expected_function_ids = string_array(payload, "expectedFunctionIds")?;
    if expected_function_ids.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "worker::spawn requires expectedFunctionIds to derive a worker grant"
                .to_owned(),
        });
    }
    let timeout_ms = opt_u64(Some(payload), "timeoutMs", 10_000).clamp(100, 60_000);
    let visibility = opt_string(Some(payload), "visibility").unwrap_or_else(|| "session".into());
    let session_id = opt_string(Some(payload), "sessionId")
        .or_else(|| invocation.causal_context.session_id.clone());
    let workspace_id = opt_string(Some(payload), "workspaceId")
        .or_else(|| invocation.causal_context.workspace_id.clone());
    if visibility == "session" && session_id.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "worker::spawn requires sessionId for session-visible workers".into(),
        });
    }
    if visibility == "workspace" && workspace_id.is_none() {
        return Err(CapabilityError::InvalidParams {
            message: "worker::spawn requires workspaceId for workspace-visible workers".into(),
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
    let derived_grant = derive_sandbox_worker_grant(
        deps,
        invocation,
        &worker_id,
        &expected_function_ids,
        working_directory.as_deref(),
        payload,
    )
    .await?;

    let endpoint = sandbox_service::worker_endpoint_from_origin(&deps.origin);
    let auth_path = deps.auth_path.clone();
    let bearer_token = run_blocking_task("sandbox.spawn_worker.load_worker_token", move || {
        read_worker_bearer_token(&auth_path)
    })
    .await?;
    let mut command_builder = Command::new(&command);
    command_builder
        .args(&args)
        .kill_on_drop(true)
        .env("TRON_ENGINE_WORKER_ENDPOINT", &endpoint)
        .env("TRON_ENGINE_BEARER_TOKEN", &bearer_token)
        .env("TRON_ENGINE_WORKER_ID", &worker_id)
        .env("TRON_ENGINE_WORKER_VISIBILITY", &visibility)
        .env("TRON_ENGINE_WORKER_AUTH_POLICY", "loopback_bearer")
        .env(
            "TRON_ENGINE_WORKER_TOKEN",
            sandbox_worker_token_json(
                &worker_id,
                &expected_function_ids,
                &derived_grant,
                visibility.as_str(),
                session_id.as_deref(),
                workspace_id.as_deref(),
            )?,
        )
        .env(
            "TRON_ENGINE_WORKER_PROTOCOL_VERSION",
            crate::engine::protocol::WORKER_PROTOCOL_VERSION.to_string(),
        );
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

    let record = sandbox_service::SandboxWorkerRecord {
        worker_id: worker_id.clone(),
        process_id,
        command: command.clone(),
        args: args.clone(),
        working_directory: working_directory.clone(),
        visibility: visibility.clone(),
        session_id: session_id.clone(),
        workspace_id: workspace_id.clone(),
        expected_function_ids: expected_function_ids.clone(),
        registered_function_ids: registered_function_ids.clone(),
        catalog_revision,
        worker_endpoint: endpoint.clone(),
        status: "running".to_owned(),
        started_at: chrono::Utc::now(),
        stopped_at: None,
        last_error: None,
    };
    deps.worker_processes.insert(record.clone(), child).await;
    publish_sandbox_lifecycle_event(deps, invocation, "sandbox.worker_spawned", &record).await?;
    Ok(json!({
        "workerId": worker_id,
        "authorityGrantId": derived_grant["grantId"],
        "authorityGrantRevision": derived_grant["revision"],
        "processId": process_id,
        "registeredFunctionIds": registered_function_ids,
        "catalogRevision": catalog_revision,
        "visibility": visibility,
        "workerEndpoint": endpoint,
        "streamTopic": contract::STREAM_TOPICS[0],
    }))
}

async fn derive_sandbox_worker_grant(
    deps: &Deps,
    invocation: &Invocation,
    worker_id: &str,
    expected_function_ids: &[String],
    working_directory: Option<&str>,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let allowed_namespaces = expected_function_namespaces(expected_function_ids)?;
    let grant_id = format!("sandbox-worker:{worker_id}");
    let mut context = CausalContext::new(
        ActorId::new("sandbox-spawn-worker").map_err(engine_invalid_params)?,
        ActorKind::System,
        AuthorityGrantId::new("sandbox-spawn-worker").map_err(engine_invalid_params)?,
        invocation.causal_context.trace_id.clone(),
    )
    .with_scope("grant.write")
    .with_idempotency_key(format!(
        "sandbox-worker-grant:{worker_id}:{}",
        invocation.id
    ));
    if let Some(session_id) = invocation.causal_context.session_id.clone() {
        context = context.with_session_id(session_id);
    }
    if let Some(workspace_id) = invocation.causal_context.workspace_id.clone() {
        context = context.with_workspace_id(workspace_id);
    }
    let grant_payload = json!({
        "grantId": grant_id,
        "parentGrantId": invocation.causal_context.authority_grant_id.as_str(),
        "subjectWorkerId": worker_id,
        "allowedCapabilities": expected_function_ids,
        "allowedNamespaces": allowed_namespaces,
        "allowedAuthorityScopes": optional_string_array_or(payload, "allowedAuthorityScopes", vec!["*".to_owned()])?,
        "allowedResourceKinds": optional_string_array_or(payload, "allowedResourceKinds", vec!["*".to_owned()])?,
        "resourceSelectors": optional_string_array_or(payload, "resourceSelectors", vec!["*".to_owned()])?,
        "fileRoots": optional_string_array_or(
            payload,
            "fileRoots",
            vec![working_directory.unwrap_or("*").to_owned()],
        )?,
        "networkPolicy": opt_string(Some(payload), "networkPolicy").unwrap_or_else(|| "loopback".to_owned()),
        "maxRisk": opt_string(Some(payload), "maxRisk").unwrap_or_else(|| "medium".to_owned()),
        "budget": payload.get("budget").cloned().unwrap_or_else(|| json!({})),
        "canDelegate": false,
        "approvalRequired": payload.get("approvalRequired").and_then(Value::as_bool).unwrap_or(false),
        "provenance": {
            "source": "worker::spawn",
            "workerId": worker_id,
            "parentInvocationId": invocation.id.as_str(),
        },
    });
    let result = deps
        .engine_host
        .invoke(
            Invocation::new_sync(
                FunctionId::new("grant::derive").map_err(engine_invalid_params)?,
                grant_payload,
                context,
            )
            .with_delivery_mode(DeliveryMode::Sync),
        )
        .await;
    if let Some(error) = result.error {
        return Err(engine_internal(error));
    }
    result
        .value
        .and_then(|value| value.get("grant").cloned())
        .ok_or_else(|| CapabilityError::Internal {
            message: "grant::derive did not return a grant".to_owned(),
        })
}

fn sandbox_worker_token_json(
    worker_id: &str,
    expected_function_ids: &[String],
    grant: &Value,
    visibility: &str,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Result<String, CapabilityError> {
    let token = json!({
        "pluginId": format!("session_generated.{worker_id}"),
        "namespaceClaims": expected_function_namespaces(expected_function_ids)?,
        "authorityGrantId": grant["grantId"],
        "authorityGrantRevision": grant["revision"],
        "authorityGrantHash": format!("grant:{}:{}", grant["grantId"].as_str().unwrap_or_default(), grant["revision"].as_u64().unwrap_or_default()),
        "resourceSelectors": grant["resourceSelectors"],
        "visibilityCeiling": visibility,
        "trustTier": "session_generated",
        "sessionId": session_id,
        "workspaceId": workspace_id,
        "expiresAt": grant["expiresAt"],
        "signatureStatus": "engine_issued",
    });
    serde_json::to_string(&token).map_err(|error| CapabilityError::Internal {
        message: format!("failed to serialize sandbox worker token: {error}"),
    })
}

fn read_worker_bearer_token(path: &Path) -> Result<String, CapabilityError> {
    let text = std::fs::read_to_string(path).map_err(|error| CapabilityError::NotAvailable {
        message: format!(
            "sandbox worker auth token is unavailable at {}: {error}",
            path.display()
        ),
    })?;
    let value: Value = serde_json::from_str(&text).map_err(|error| CapabilityError::Internal {
        message: format!("sandbox worker auth token file is invalid JSON: {error}"),
    })?;
    let token = value
        .get("bearerToken")
        .and_then(Value::as_str)
        .filter(|token| !token.trim().is_empty())
        .ok_or_else(|| CapabilityError::NotAvailable {
            message: "sandbox worker auth token file does not contain bearerToken".to_owned(),
        })?;
    Ok(token.to_owned())
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
        let _ = disconnect_worker_id_via_engine(deps, &id, "spawn cleanup").await;
    }
}

async fn disconnect_worker_via_engine(
    deps: &Deps,
    invocation: &Invocation,
    worker_id: &str,
    reason: &str,
) -> Result<(), CapabilityError> {
    let worker_id = WorkerId::new(worker_id.to_owned()).map_err(engine_invalid_params)?;
    disconnect_worker_id_with_context(deps, Some(invocation), &worker_id, reason).await
}

async fn disconnect_worker_id_via_engine(
    deps: &Deps,
    worker_id: &WorkerId,
    reason: &str,
) -> Result<(), CapabilityError> {
    disconnect_worker_id_with_context(deps, None, worker_id, reason).await
}

async fn disconnect_worker_id_with_context(
    deps: &Deps,
    parent: Option<&Invocation>,
    worker_id: &WorkerId,
    reason: &str,
) -> Result<(), CapabilityError> {
    match deps.engine_host.worker_is_volatile(worker_id).await {
        Some(true) => {}
        None => return Ok(()),
        Some(false) => {
            return Err(CapabilityError::Internal {
                message: format!(
                    "worker::disconnect can only disconnect volatile workers ({worker_id})"
                ),
            });
        }
    }
    let trace_id = parent
        .map(|invocation| invocation.causal_context.trace_id.clone())
        .unwrap_or_else(TraceId::generate);
    let mut context = CausalContext::new(
        ActorId::new("sandbox-lifecycle").map_err(engine_internal)?,
        ActorKind::System,
        AuthorityGrantId::new("sandbox-lifecycle").map_err(engine_internal)?,
        trace_id,
    )
    .with_scope("worker.write")
    .with_scope(ENGINE_INTERNAL_INVOKE_SCOPE)
    .with_idempotency_key(format!(
        "sandbox-worker-disconnect:{worker_id}:{}",
        parent
            .map(|invocation| invocation.id.as_str().to_owned())
            .unwrap_or_else(|| reason.to_owned())
    ));
    if let Some(parent) = parent {
        context = context.with_parent_invocation(parent.id.clone());
        if let Some(session_id) = parent.causal_context.session_id.clone() {
            context = context.with_session_id(session_id);
        }
        if let Some(workspace_id) = parent.causal_context.workspace_id.clone() {
            context = context.with_workspace_id(workspace_id);
        }
    }
    let result = deps
        .engine_host
        .invoke(
            Invocation::new_sync(
                FunctionId::new("worker::disconnect").map_err(engine_internal)?,
                json!({"workerId": worker_id.as_str(), "reason": reason}),
                context,
            )
            .with_delivery_mode(DeliveryMode::Sync),
        )
        .await;
    if let Some(error) = result.error {
        return Err(engine_internal(error));
    }
    Ok(())
}

async fn publish_sandbox_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    record: &sandbox_service::SandboxWorkerRecord,
) -> Result<(), CapabilityError> {
    let mut context = CausalContext::new(
        ActorId::new("sandbox-lifecycle").map_err(engine_internal)?,
        ActorKind::System,
        AuthorityGrantId::new("sandbox-lifecycle").map_err(engine_internal)?,
        invocation.causal_context.trace_id.clone(),
    )
    .with_scope("stream.write")
    .with_scope(ENGINE_INTERNAL_INVOKE_SCOPE)
    .with_parent_invocation(invocation.id.clone())
    .with_idempotency_key(format!(
        "sandbox-lifecycle:{event_type}:{}:{}",
        record.worker_id,
        invocation.id.as_str()
    ));
    if let Some(session_id) = record
        .session_id
        .clone()
        .or_else(|| invocation.causal_context.session_id.clone())
    {
        context = context.with_session_id(session_id);
    }
    if let Some(workspace_id) = record
        .workspace_id
        .clone()
        .or_else(|| invocation.causal_context.workspace_id.clone())
    {
        context = context.with_workspace_id(workspace_id);
    }
    let mut payload = json!({
        "topic": contract::STREAM_TOPICS[0],
        "payload": {
            "eventType": event_type,
            "worker": record,
        },
        "visibility": record.visibility.clone(),
        "producer": "sandbox",
    });
    if let Some(session_id) = record.session_id.clone() {
        payload["sessionId"] = Value::String(session_id);
    }
    if let Some(workspace_id) = record.workspace_id.clone() {
        payload["workspaceId"] = Value::String(workspace_id);
    }
    let result = deps
        .engine_host
        .invoke(
            Invocation::new_sync(
                FunctionId::new("stream::publish").map_err(engine_internal)?,
                payload,
                context,
            )
            .with_delivery_mode(DeliveryMode::Sync),
        )
        .await;
    if let Some(error) = result.error {
        return Err(engine_internal(error));
    }
    Ok(())
}

fn engine_invalid_params(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: error.to_string(),
    }
}

fn engine_internal(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
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

fn optional_string_array_or(
    payload: &Value,
    key: &str,
    default: Vec<String>,
) -> Result<Vec<String>, CapabilityError> {
    let values = string_array(payload, key)?;
    if values.is_empty() {
        Ok(default)
    } else {
        Ok(values)
    }
}

fn expected_function_namespaces(
    expected_function_ids: &[String],
) -> Result<Vec<String>, CapabilityError> {
    let mut namespaces = expected_function_ids
        .iter()
        .map(|function_id| {
            function_id
                .split_once("::")
                .map(|(namespace, _)| namespace)
                .filter(|namespace| !namespace.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: format!(
                        "expectedFunctionIds entry must be namespace::operation: {function_id}"
                    ),
                })
        })
        .collect::<Result<Vec<_>, _>>()?;
    namespaces.sort();
    namespaces.dedup();
    Ok(namespaces)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_bearer_token_is_loaded_from_auth_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        std::fs::write(
            &path,
            r#"{"version":1,"bearerToken":"worker-token","providers":{},"services":{}}"#,
        )
        .unwrap();

        assert_eq!(read_worker_bearer_token(&path).unwrap(), "worker-token");
    }

    #[test]
    fn worker_bearer_token_requires_current_token_field() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        std::fs::write(&path, r#"{"version":1}"#).unwrap();

        let error = read_worker_bearer_token(&path).unwrap_err();
        assert!(error.to_string().contains("bearerToken"));
    }
}
