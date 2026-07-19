use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DELEGATION_KIND,
    DELEGATION_SCHEMA_ID, EngineResourceInspection, EngineResourceScope, FunctionId, Invocation,
    ListResources, PublishStreamEvent, TraceId, UpdateResource, VisibilityScope, WorkerId,
};
use crate::shared::protocol::events::TronEvent;
use crate::shared::server::errors::CapabilityError;

use super::{Deps, contract, projection};

const SCHEMA_VERSION: &str = "tron.delegation.v1";
const MAX_ACTIVE_PER_PARENT: usize = 3;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "start" => |invocation, deps| { start(invocation, deps).await },
        "list" => |invocation, deps| { list(invocation, deps).await },
        "inspect" => |invocation, deps| { inspect(invocation, deps).await },
        "cancel" => |invocation, deps| { cancel(invocation, deps).await },
        "accept_result" => |invocation, deps| { accept_result(invocation, deps).await },
    ];
}

pub(crate) async fn list(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = required_string(&invocation.payload, "sessionId")?;
    require_causal_session(invocation, &session_id)?;
    let scope = EngineResourceScope::Session(session_id);
    repair_scope(deps, &scope).await?;
    let mut active = Vec::new();
    let mut active_ids = HashSet::new();
    for state in ["preparing", "running", "result_ready"] {
        let resources = deps
            .engine_host
            .list_resources(ListResources {
                kind: Some(DELEGATION_KIND.to_owned()),
                scope: Some(scope.clone()),
                lifecycle: Some(state.to_owned()),
                limit: MAX_ACTIVE_PER_PARENT,
            })
            .await
            .map_err(engine_error)?;
        for resource in resources {
            active_ids.insert(resource.resource_id.clone());
            if let Some(inspection) = deps
                .engine_host
                .inspect_resource(&resource.resource_id)
                .await
                .map_err(engine_error)?
            {
                let (version, payload) = current(&inspection)?;
                active.push(projection::summary(&inspection.resource, version, payload));
            }
        }
    }
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(DELEGATION_KIND.to_owned()),
            scope: Some(scope),
            lifecycle: None,
            limit: 14,
        })
        .await
        .map_err(engine_error)?;
    let source_limit_reached = resources.len() == 14;
    let mut recent = Vec::new();
    for resource in resources
        .into_iter()
        .filter(|resource| !active_ids.contains(&resource.resource_id))
    {
        if recent.len() == 10 {
            break;
        }
        if let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            let (version, payload) = current(&inspection)?;
            recent.push(projection::summary(&inspection.resource, version, payload));
        }
    }
    let mut delegations = active.clone();
    delegations.extend(recent.clone());
    Ok(
        json!({"schemaVersion": SCHEMA_VERSION, "active": active, "recent": recent, "delegations": delegations, "truncated": source_limit_reached}),
    )
}

pub(crate) async fn start(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let parent_session_id = required_string(&invocation.payload, "sessionId")?;
    require_causal_session(invocation, &parent_session_id)?;
    let objective = bounded(
        required_string(&invocation.payload, "objectiveSummary")?,
        2_000,
        "objectiveSummary",
    )?;
    let criteria = string_array(&invocation.payload, "successCriteria", 12, 500)?;
    let handoff_refs = invocation
        .payload
        .get("handoffRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    validate_handoff_refs(&handoff_refs)?;
    let idempotency_key = required_string(&invocation.payload, "idempotencyKey")?;
    let scope = EngineResourceScope::Session(parent_session_id.clone());
    let resource_id = delegation_id(&parent_session_id, &idempotency_key);
    let admission = deps.start_admission.lock().await;

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        let (_, existing_payload) = current(&existing)?;
        if existing_payload["objectiveSummary"] != json!(objective)
            || existing_payload["successCriteria"] != json!(criteria)
            || existing_payload["handoffRefs"] != json!(handoff_refs)
        {
            return Err(invalid(
                "idempotencyKey was already used for a different delegation handoff",
            ));
        }
        repair_stale(deps, &existing, false).await?;
        let replay = deps
            .engine_host
            .inspect_resource(&resource_id)
            .await
            .map_err(engine_error)?
            .ok_or_else(|| internal("delegation replay disappeared"))?;
        let (version, payload) = current(&replay)?;
        return Ok(response(&replay.resource, version, payload, true));
    }
    ensure_capacity(deps, &scope).await?;
    let parent = deps
        .event_store
        .get_session(&parent_session_id)
        .map_err(|error| internal(error.to_string()))?
        .ok_or_else(|| invalid("parent session was not found"))?;
    let now = Utc::now().to_rfc3339();
    let child_session_id = deterministic_child_session_id(&resource_id);
    let prepared = json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": "preparing",
        "parentSessionId": parent_session_id,
        "childSessionId": child_session_id,
        "childRunId": Value::Null,
        "objectiveSummary": objective,
        "successCriteria": criteria,
        "handoffRefs": handoff_refs,
        "resultSummary": Value::Null,
        "resultRefs": [],
        "failure": Value::Null,
        "authority": {"workspace": "shared_read_only", "network": "none", "canDelegate": false},
        "limits": {"maxDepth": 1, "maxConcurrentPerParent": MAX_ACTIVE_PER_PARENT},
        "idempotencyKey": idempotency_key,
        "cancelIdempotencyKey": Value::Null,
        "acceptIdempotencyKey": Value::Null,
        "createdAt": now,
        "updatedAt": now,
        "revision": 1
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: DELEGATION_KIND.to_owned(),
            schema_id: Some(DELEGATION_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: WorkerId::new(contract::WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("preparing".to_owned()),
            policy: json!({"owner": contract::WORKER, "resultAcceptanceRequired": true}),
            initial_payload: Some(prepared),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let prepared_version = resource
        .current_version_id
        .clone()
        .ok_or_else(|| internal("prepared delegation has no version"))?;
    let child_session_id = match deps.session_manager.create_session_with_id(
        &child_session_id,
        &parent.latest_model,
        &parent.working_directory,
        Some(&format!("Delegated: {}", truncate_title(&objective))),
    ) {
        Ok(session_id) => session_id,
        Err(error) => {
            terminalize_failed(
                deps,
                invocation,
                &resource_id,
                &prepared_version,
                &error.to_string(),
            )
            .await?;
            return Err(internal(error.to_string()));
        }
    };
    deps.orchestrator
        .init_sequence_counter(&child_session_id, 0);
    let mut running = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| internal("prepared delegation disappeared"))?
        .versions
        .into_iter()
        .find(|version| version.version_id == prepared_version)
        .ok_or_else(|| internal("prepared version disappeared"))?
        .payload;
    running["state"] = json!("running");
    running["childSessionId"] = json!(child_session_id);
    running["updatedAt"] = json!(Utc::now().to_rfc3339());
    running["revision"] = json!(2);
    let running_version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(prepared_version),
            lifecycle: Some("running".to_owned()),
            payload: running,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    drop(admission);
    publish_changed(
        deps,
        &parent_session_id,
        &resource_id,
        invocation.causal_context.trace_id.clone(),
        Some(invocation.id.clone()),
    )
    .await;

    let receiver = deps.orchestrator.subscribe();
    let prompt = handoff_prompt(&objective, &criteria, &handoff_refs)?;
    let prompt_result = invoke_child_prompt(invocation, deps, &child_session_id, &prompt).await;
    let acknowledged = match prompt_result {
        Ok(value) => value,
        Err(error) => {
            terminalize_failed(
                deps,
                invocation,
                &resource_id,
                &running_version.version_id,
                &error.to_string(),
            )
            .await?;
            return Err(error);
        }
    };
    let run_id = acknowledged
        .get("runId")
        .and_then(Value::as_str)
        .ok_or_else(|| internal("child prompt returned no runId"))?
        .to_owned();
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| internal("running delegation disappeared"))?;
    let (current_version, current_payload) = current(&inspection)?;
    let mut with_run = current_payload.clone();
    with_run["childRunId"] = json!(run_id);
    with_run["updatedAt"] = json!(Utc::now().to_rfc3339());
    with_run["revision"] = json!(3);
    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(current_version.version_id.clone()),
            lifecycle: Some("running".to_owned()),
            payload: with_run,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    spawn_reconciler(
        deps.clone(),
        receiver,
        resource_id.clone(),
        child_session_id,
        run_id.clone(),
        version.version_id,
        invocation.causal_context.trace_id.clone(),
    );
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| internal("delegation disappeared"))?;
    let (version, payload) = current(&inspection)?;
    Ok(response(&inspection.resource, version, payload, false))
}

pub(crate) async fn inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let inspection = scoped_inspection(invocation, deps).await?;
    repair_stale(deps, &inspection, false).await?;
    let inspection = scoped_inspection(invocation, deps).await?;
    let (version, payload) = current(&inspection)?;
    Ok(response(&inspection.resource, version, payload, false))
}

pub(crate) async fn cancel(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let inspection = scoped_inspection(invocation, deps).await?;
    repair_stale(deps, &inspection, false).await?;
    let inspection = scoped_inspection(invocation, deps).await?;
    let (version, payload) = current(&inspection)?;
    let operation_key = required_string(&invocation.payload, "idempotencyKey")?;
    if inspection.resource.lifecycle == "cancelled"
        && payload["cancelIdempotencyKey"].as_str() == Some(operation_key.as_str())
    {
        return Ok(response(&inspection.resource, version, payload, true));
    }
    require_expected(&invocation.payload, version)?;
    if inspection.resource.lifecycle != "running" {
        return Err(invalid("only a running delegation can be cancelled"));
    }
    let child = payload["childSessionId"]
        .as_str()
        .ok_or_else(|| internal("running delegation has no child session"))?;
    let run = payload["childRunId"]
        .as_str()
        .ok_or_else(|| invalid("child run has not been admitted yet"))?;
    let aborted = deps
        .orchestrator
        .abort_run(child, run)
        .map_err(|error| invalid(error.to_string()))?;
    if !aborted {
        repair_stale(deps, &inspection, false).await?;
        return Err(invalid(
            "child run already ended; inspect the reconciled delegation result",
        ));
    }
    let mut next = payload.clone();
    next["state"] = json!("cancelled");
    next["cancelIdempotencyKey"] = json!(operation_key);
    next["updatedAt"] = json!(Utc::now().to_rfc3339());
    next["revision"] = json!(next["revision"].as_u64().unwrap_or(1) + 1);
    let updated = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: inspection.resource.resource_id.clone(),
            expected_current_version_id: Some(version.version_id.clone()),
            lifecycle: Some("cancelled".to_owned()),
            payload: next,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let refreshed = deps
        .engine_host
        .inspect_resource(&inspection.resource.resource_id)
        .await
        .map_err(engine_error)?
        .unwrap();
    publish_changed(
        deps,
        &required_string(&invocation.payload, "sessionId")?,
        &inspection.resource.resource_id,
        invocation.causal_context.trace_id.clone(),
        Some(invocation.id.clone()),
    )
    .await;
    Ok(response(
        &refreshed.resource,
        &updated,
        &updated.payload,
        false,
    ))
}

pub(crate) async fn accept_result(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let inspection = scoped_inspection(invocation, deps).await?;
    let (version, payload) = current(&inspection)?;
    let operation_key = required_string(&invocation.payload, "idempotencyKey")?;
    if inspection.resource.lifecycle == "accepted"
        && payload["acceptIdempotencyKey"].as_str() == Some(operation_key.as_str())
    {
        return Ok(response(&inspection.resource, version, payload, true));
    }
    require_expected(&invocation.payload, version)?;
    if inspection.resource.lifecycle != "result_ready" {
        return Err(invalid("delegation result is not ready"));
    }
    let mut next = payload.clone();
    next["state"] = json!("accepted");
    next["acceptIdempotencyKey"] = json!(operation_key);
    next["updatedAt"] = json!(Utc::now().to_rfc3339());
    next["revision"] = json!(next["revision"].as_u64().unwrap_or(1) + 1);
    let updated = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: inspection.resource.resource_id.clone(),
            expected_current_version_id: Some(version.version_id.clone()),
            lifecycle: Some("accepted".to_owned()),
            payload: next,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let refreshed = deps
        .engine_host
        .inspect_resource(&inspection.resource.resource_id)
        .await
        .map_err(engine_error)?
        .unwrap();
    publish_changed(
        deps,
        &required_string(&invocation.payload, "sessionId")?,
        &inspection.resource.resource_id,
        invocation.causal_context.trace_id.clone(),
        Some(invocation.id.clone()),
    )
    .await;
    Ok(response(
        &refreshed.resource,
        &updated,
        &updated.payload,
        false,
    ))
}

fn spawn_reconciler(
    deps: Deps,
    mut receiver: tokio::sync::broadcast::Receiver<TronEvent>,
    resource_id: String,
    child_session_id: String,
    child_run_id: String,
    expected_version: String,
    trace_id: TraceId,
) {
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(TronEvent::AgentEnd { base, error }) if base.session_id == child_session_id => {
                    let _ = reconcile_terminal(
                        &deps,
                        &resource_id,
                        &expected_version,
                        &child_session_id,
                        &child_run_id,
                        error,
                        trace_id,
                    )
                    .await;
                    break;
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    if let Ok(Some(inspection)) =
                        deps.engine_host.inspect_resource(&resource_id).await
                    {
                        let _ = repair_stale(&deps, &inspection, false).await;
                        publish_changed(
                            &deps,
                            inspection.resource.scope.value(),
                            &resource_id,
                            trace_id.clone(),
                            None,
                        )
                        .await;
                    }
                }
                Ok(_) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}

async fn reconcile_terminal(
    deps: &Deps,
    resource_id: &str,
    expected_version: &str,
    child_session_id: &str,
    child_run_id: &str,
    error: Option<String>,
    trace_id: TraceId,
) -> crate::engine::Result<()> {
    let Some(inspection) = deps.engine_host.inspect_resource(resource_id).await? else {
        return Ok(());
    };
    if inspection.resource.current_version_id.as_deref() != Some(expected_version)
        || inspection.resource.lifecycle != "running"
    {
        return Ok(());
    }
    let (_, payload) = current_engine(&inspection)?;
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let result_refs = child_result_refs(deps, child_session_id, child_run_id)
        .await
        .map_err(|error| crate::engine::EngineError::LedgerFailure {
            operation: "delegation.reconcile.agent_result",
            message: error.to_string(),
        })?;
    let mut next = payload.clone();
    let (state, summary) = if error.is_some() {
        (
            "failed",
            "Delegated child execution failed; inspect audit evidence for diagnostics.".to_owned(),
        )
    } else if let Some(summary) =
        completed_run_summary(&deps.event_store, child_session_id, child_run_id)
    {
        ("result_ready", summary)
    } else {
        (
            "failed",
            "Child run ended without a durable exact-run turn boundary.".to_owned(),
        )
    };
    next["state"] = json!(state);
    next["resultSummary"] = json!(summary);
    next["resultRefs"] = json!(result_refs);
    next["updatedAt"] = json!(Utc::now().to_rfc3339());
    next["revision"] = json!(next["revision"].as_u64().unwrap_or(1) + 1);
    let _ = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.to_owned(),
            expected_current_version_id: Some(expected_version.to_owned()),
            lifecycle: Some(state.to_owned()),
            payload: next,
            state: None,
            locations: Vec::new(),
            trace_id: trace_id.clone(),
            invocation_id: None,
        })
        .await?;
    publish_changed(
        deps,
        payload["parentSessionId"].as_str().unwrap_or_default(),
        resource_id,
        trace_id,
        None,
    )
    .await;
    Ok(())
}

async fn invoke_child_prompt(
    invocation: &Invocation,
    deps: &Deps,
    child_session_id: &str,
    prompt: &str,
) -> Result<Value, CapabilityError> {
    let context = CausalContext::new(
        ActorId::new("system:delegation").map_err(engine_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_error)?,
        invocation.causal_context.trace_id.clone(),
    )
    .with_scope("agent.write")
    .with_session_id(child_session_id.to_owned())
    .with_parent_invocation(invocation.id.clone())
    .with_idempotency_key(format!("delegation-child-prompt:{}", invocation.id));
    let child = Invocation::new_sync(
        FunctionId::new("agent::prompt_delegated").map_err(engine_error)?,
        json!({
            "sessionId": child_session_id, "prompt": prompt, "executionPolicy": "read_only"
        }),
        context,
    );
    let result = deps.engine_host.invoke(child).await;
    crate::shared::server::error_mapping::result_to_capability_value(result)
}

async fn scoped_inspection(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<EngineResourceInspection, CapabilityError> {
    let session_id = required_string(&invocation.payload, "sessionId")?;
    require_causal_session(invocation, &session_id)?;
    let id = required_string(&invocation.payload, "delegationResourceId")?;
    let inspection = deps
        .engine_host
        .inspect_resource(&id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("delegation was not found"))?;
    if inspection.resource.kind != DELEGATION_KIND
        || inspection.resource.schema_id.as_str() != DELEGATION_SCHEMA_ID
        || inspection.resource.scope != EngineResourceScope::Session(session_id)
    {
        return Err(invalid("delegation is outside the current session"));
    }
    Ok(inspection)
}

async fn ensure_capacity(deps: &Deps, scope: &EngineResourceScope) -> Result<(), CapabilityError> {
    repair_scope(deps, scope).await?;
    let mut active = 0;
    for state in ["preparing", "running", "result_ready"] {
        active += deps
            .engine_host
            .list_resources(ListResources {
                kind: Some(DELEGATION_KIND.to_owned()),
                scope: Some(scope.clone()),
                lifecycle: Some(state.to_owned()),
                limit: MAX_ACTIVE_PER_PARENT + 1,
            })
            .await
            .map_err(engine_error)?
            .len();
    }
    if active >= MAX_ACTIVE_PER_PARENT {
        return Err(invalid("delegation concurrency limit reached (3)"));
    }
    Ok(())
}

pub(crate) async fn repair_scope(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<(), CapabilityError> {
    for state in ["preparing", "running"] {
        let resources = deps
            .engine_host
            .list_resources(ListResources {
                kind: Some(DELEGATION_KIND.to_owned()),
                scope: Some(scope.clone()),
                lifecycle: Some(state.to_owned()),
                limit: 64,
            })
            .await
            .map_err(engine_error)?;
        for resource in resources {
            if let Some(inspection) = deps
                .engine_host
                .inspect_resource(&resource.resource_id)
                .await
                .map_err(engine_error)?
            {
                repair_stale(deps, &inspection, false).await?;
            }
        }
    }
    Ok(())
}

async fn repair_stale(
    deps: &Deps,
    inspection: &EngineResourceInspection,
    replaying_prepare: bool,
) -> Result<(), CapabilityError> {
    let (version, payload) = current(inspection)?;
    if inspection.resource.lifecycle == "preparing" {
        let updated_at = payload["updatedAt"]
            .as_str()
            .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok());
        let stale = replaying_prepare
            || updated_at.is_none_or(|value| {
                Utc::now()
                    .signed_duration_since(value.with_timezone(&Utc))
                    .num_seconds()
                    >= 30
            });
        if !stale {
            return Ok(());
        }
        return repair_terminal(
            deps,
            inspection,
            version,
            "failed",
            "Delegation preparation was interrupted before child session admission.",
            Vec::new(),
        )
        .await;
    }
    if inspection.resource.lifecycle != "running" {
        return Ok(());
    }
    let Some(child) = payload["childSessionId"].as_str() else {
        return repair_terminal(
            deps,
            inspection,
            version,
            "failed",
            "Running delegation has no child session identity.",
            Vec::new(),
        )
        .await;
    };
    let expected_run = payload["childRunId"].as_str();
    if expected_run.is_some() && deps.orchestrator.get_run_id(child).as_deref() == expected_run {
        return Ok(());
    }
    let refs = match expected_run {
        Some(run) => child_result_refs(deps, child, run).await?,
        None => Vec::new(),
    };
    if !refs.is_empty()
        && let Some(summary) =
            expected_run.and_then(|run| completed_run_summary(&deps.event_store, child, run))
    {
        repair_terminal(deps, inspection, version, "result_ready", &summary, refs).await
    } else {
        repair_terminal(
            deps,
            inspection,
            version,
            "failed",
            "Child execution ended or was interrupted without a usable result.",
            refs,
        )
        .await
    }
}

async fn repair_terminal(
    deps: &Deps,
    inspection: &EngineResourceInspection,
    version: &crate::engine::EngineResourceVersion,
    state: &str,
    summary: &str,
    result_refs: Vec<Value>,
) -> Result<(), CapabilityError> {
    let mut next = version.payload.clone();
    next["state"] = json!(state);
    next["resultSummary"] = json!(summary);
    next["resultRefs"] = json!(result_refs);
    next["updatedAt"] = json!(Utc::now().to_rfc3339());
    next["revision"] = json!(next["revision"].as_u64().unwrap_or(1) + 1);
    let parent_session_id = next["parentSessionId"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    deps.engine_host
        .update_resource(UpdateResource {
            resource_id: inspection.resource.resource_id.clone(),
            expected_current_version_id: Some(version.version_id.clone()),
            lifecycle: Some(state.to_owned()),
            payload: next,
            state: None,
            locations: Vec::new(),
            trace_id: inspection.resource.trace_id.clone(),
            invocation_id: None,
        })
        .await
        .map_err(engine_error)?;
    publish_changed(
        deps,
        &parent_session_id,
        &inspection.resource.resource_id,
        inspection.resource.trace_id.clone(),
        None,
    )
    .await;
    Ok(())
}

async fn child_result_refs(
    deps: &Deps,
    child: &str,
    expected_run_id: &str,
) -> Result<Vec<Value>, CapabilityError> {
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some("agent_result".to_owned()),
            scope: Some(EngineResourceScope::Session(child.to_owned())),
            lifecycle: None,
            limit: 8,
        })
        .await
        .map_err(engine_error)?;
    let mut refs = Vec::new();
    for resource in resources {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        let (version, payload) = current(&inspection)?;
        let exact_terminal_success = inspection.resource.lifecycle == "final"
            && payload.pointer("/metadata/runId").and_then(Value::as_str) == Some(expected_run_id)
            && !payload
                .pointer("/metadata/interrupted")
                .and_then(Value::as_bool)
                .unwrap_or(true);
        if exact_terminal_success {
            refs.push(json!({
                "resourceId": resource.resource_id, "kind": resource.kind, "versionId": version.version_id,
            }));
        }
    }
    Ok(refs)
}

fn current(
    inspection: &EngineResourceInspection,
) -> Result<(&crate::engine::EngineResourceVersion, &Value), CapabilityError> {
    current_engine(inspection).map_err(engine_error)
}
fn current_engine(
    inspection: &EngineResourceInspection,
) -> crate::engine::Result<(&crate::engine::EngineResourceVersion, &Value)> {
    let id = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| crate::engine::EngineError::LedgerFailure {
            operation: "delegation.current",
            message: "resource has no current version".to_owned(),
        })?;
    let version = inspection
        .versions
        .iter()
        .find(|item| item.version_id == id)
        .ok_or_else(|| crate::engine::EngineError::LedgerFailure {
            operation: "delegation.current",
            message: "current version is missing".to_owned(),
        })?;
    Ok((version, &version.payload))
}

fn response(
    resource: &crate::engine::EngineResource,
    version: &crate::engine::EngineResourceVersion,
    payload: &Value,
    replayed: bool,
) -> Value {
    json!({"schemaVersion": SCHEMA_VERSION, "replayed": replayed, "delegation": projection::summary(resource, version, payload)})
}
fn require_expected(
    payload: &Value,
    version: &crate::engine::EngineResourceVersion,
) -> Result<(), CapabilityError> {
    if required_string(payload, "expectedVersionId")? != version.version_id {
        return Err(invalid("delegation version is stale"));
    }
    Ok(())
}
fn require_causal_session(
    invocation: &Invocation,
    session_id: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.session_id.as_deref() != Some(session_id) {
        return Err(invalid("sessionId must match causal session"));
    }
    Ok(())
}
fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| invalid(format!("{field} is required")))
}
fn bounded(value: String, max: usize, field: &str) -> Result<String, CapabilityError> {
    if value.len() > max {
        Err(invalid(format!("{field} exceeds {max} bytes")))
    } else {
        Ok(value)
    }
}
fn string_array(
    payload: &Value,
    field: &str,
    max_items: usize,
    max_len: usize,
) -> Result<Vec<String>, CapabilityError> {
    let values = payload
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| invalid(format!("{field} is required")))?;
    if values.is_empty() || values.len() > max_items {
        return Err(invalid(format!(
            "{field} must contain 1..={max_items} items"
        )));
    }
    values
        .iter()
        .map(|v| {
            v.as_str()
                .ok_or_else(|| invalid(format!("{field} items must be strings")))
                .and_then(|v| bounded(v.trim().to_owned(), max_len, field))
        })
        .collect()
}

fn validate_handoff_refs(refs: &[Value]) -> Result<(), CapabilityError> {
    if refs.len() > 32 {
        return Err(invalid("handoffRefs exceeds 32 items"));
    }
    for reference in refs {
        let object = reference
            .as_object()
            .ok_or_else(|| invalid("handoffRefs items must be objects"))?;
        if object
            .keys()
            .any(|key| !matches!(key.as_str(), "kind" | "id" | "versionId"))
        {
            return Err(invalid(
                "handoffRefs accepts only kind, id, and optional versionId",
            ));
        }
        for field in ["kind", "id"] {
            let value = object
                .get(field)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| invalid(format!("handoffRefs.{field} is required")))?;
            if value.len() > 256 || value.contains('*') {
                return Err(invalid(format!("handoffRefs.{field} is invalid")));
            }
        }
        if let Some(version) = object.get("versionId") {
            let version = version
                .as_str()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| invalid("handoffRefs.versionId must be a nonempty string"))?;
            if version.len() > 256 || version.contains('*') {
                return Err(invalid("handoffRefs.versionId is invalid"));
            }
        }
    }
    Ok(())
}
fn delegation_id(session: &str, key: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(SCHEMA_VERSION);
    hash.update([0]);
    hash.update(session);
    hash.update([0]);
    hash.update(key);
    format!("{DELEGATION_KIND}:{}", hex::encode(hash.finalize()))
}
fn deterministic_child_session_id(resource_id: &str) -> String {
    let digest = hex::encode(Sha256::digest(resource_id.as_bytes()));
    format!("sess_delegation_{}", &digest[..32])
}
fn truncate_title(value: &str) -> String {
    value.chars().take(60).collect()
}
fn handoff_prompt(
    objective: &str,
    criteria: &[String],
    refs: &[Value],
) -> Result<String, CapabilityError> {
    Ok(format!(
        "You are a bounded delegated child agent. Work read-only and do not use network access.\n\nObjective: {objective}\n\nSuccess criteria:\n{}\n\nAuthorized evidence references:\n{}\n\nReturn a concise result. It remains isolated until the parent explicitly accepts it. Do not mutate parent state.",
        criteria
            .iter()
            .map(|v| format!("- {v}"))
            .collect::<Vec<_>>()
            .join("\n"),
        serde_json::to_string(refs).map_err(|e| internal(e.to_string()))?
    ))
}
fn completed_run_summary(
    store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    expected_run_id: &str,
) -> Option<String> {
    let events = store
        .get_events_by_type(session_id, &["message.assistant", "stream.turn_end"], None)
        .ok()?;
    let boundary = events.iter().rev().find(|event| {
        event.event_type == "stream.turn_end"
            && serde_json::from_str::<Value>(&event.payload)
                .ok()
                .and_then(|payload| {
                    payload
                        .get("runId")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                })
                .as_deref()
                == Some(expected_run_id)
    })?;
    let assistant = events.iter().rev().find(|event| {
        event.event_type == "message.assistant"
            && event.sequence < boundary.sequence
            && event.turn == boundary.turn
    })?;
    let payload: Value = serde_json::from_str(&assistant.payload).ok()?;
    let content = payload.get("content")?;
    let text = match content {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| {
                block
                    .get("text")
                    .and_then(Value::as_str)
                    .or_else(|| block.get("content").and_then(Value::as_str))
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    Some(text.chars().take(4_000).collect())
}
async fn terminalize_failed(
    deps: &Deps,
    invocation: &Invocation,
    id: &str,
    expected: &str,
    message: &str,
) -> Result<(), CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| internal("delegation disappeared"))?;
    let (_, payload) = current(&inspection)?;
    let mut next = payload.clone();
    next["state"] = json!("failed");
    next["failure"] = json!({"message": message});
    next["updatedAt"] = json!(Utc::now().to_rfc3339());
    next["revision"] = json!(next["revision"].as_u64().unwrap_or(1) + 1);
    let parent_session_id = next["parentSessionId"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    deps.engine_host
        .update_resource(UpdateResource {
            resource_id: id.to_owned(),
            expected_current_version_id: Some(expected.to_owned()),
            lifecycle: Some("failed".to_owned()),
            payload: next,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_changed(
        deps,
        &parent_session_id,
        id,
        invocation.causal_context.trace_id.clone(),
        Some(invocation.id.clone()),
    )
    .await;
    Ok(())
}
async fn publish_changed(
    deps: &Deps,
    session_id: &str,
    id: &str,
    trace_id: TraceId,
    parent_invocation_id: Option<crate::engine::InvocationId>,
) {
    let _ = deps.engine_host.publish_stream_event(PublishStreamEvent {
        topic: contract::TOPIC.to_owned(),
        payload: json!({"type": "delegation.changed", "workflowRef": {"kind": "delegation", "id": id}}),
        visibility: VisibilityScope::Session,
        session_id: Some(session_id.to_owned()),
        workspace_id: None,
        producer: contract::WORKER.to_owned(),
        trace_id: Some(trace_id),
        parent_invocation_id,
    }).await;
}
fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}
fn engine_error(error: impl std::fmt::Display) -> CapabilityError {
    internal(error.to_string())
}
