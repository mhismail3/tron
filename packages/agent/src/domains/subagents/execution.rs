use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, EngineGrant, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources, PublishStreamEvent, SUBAGENT_TASK_KIND,
    SUBAGENT_TASK_SCHEMA_ID, UpdateResource, VisibilityScope, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::projection::inspected_task;
use super::validation::*;
use super::{Deps, READ_SCOPE, SCHEMA_VERSION, SUBAGENT_TASK_TOPIC, WORKER, WRITE_SCOPE};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";
const PLACEHOLDER_MODEL_POLICY: &str = "bounded_placeholder_v1";
const MAX_RUNNING_PER_SCOPE: usize = 1;

pub(crate) async fn launch_subagent_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_grant(deps, invocation, "subagent_launch").await?;
    require_write_grant(&grant, "subagent_launch")?;
    require_placeholder_policy(payload)?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let now = Utc::now().to_rfc3339();
    let scope = resource_scope(invocation)?;
    let task_id = optional_string(payload, "taskId")?
        .map(|value| bounded_text("taskId", &value, 128))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let resource_id = task_resource_id(&scope, &task_id, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_subagent_task(&existing, "subagent_launch replay")?;
        ensure_scope(&existing, &scope, "subagent_launch replay")?;
        let (version, _) = current_payload(&existing, "subagent_launch replay")?;
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "subagent_launch",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "subagentTaskResourceId": resource_id,
            "subagentTaskVersionId": version.version_id,
            "resourceRefs": [version_ref(&existing.resource, version, "subagent_task")],
            "execution": execution_readback_proof(),
            "network": network_proof()
        }));
    }
    ensure_concurrency_available(deps, &scope).await?;

    let objective_summary = bounded_text(
        "objectiveSummary",
        &required_string(payload, "objectiveSummary")?,
        MAX_SUMMARY_BYTES,
    )?;
    let prompt_summary = bounded_text(
        "promptSummary",
        &required_string(payload, "promptSummary")?,
        MAX_SUMMARY_BYTES,
    )?;
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    let output_refs = optional_array(payload, "outputRefs")?.unwrap_or_default();
    validate_refs("evidenceRefs", &evidence_refs)?;
    validate_refs("outputRefs", &output_refs)?;
    let trace_refs =
        optional_array(payload, "traceRefs")?.unwrap_or_else(|| trace_refs(invocation));
    let replay_refs =
        optional_array(payload, "replayRefs")?.unwrap_or_else(|| replay_refs(invocation));
    validate_refs("traceRefs", &trace_refs)?;
    validate_refs("replayRefs", &replay_refs)?;

    let record = json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": "running",
        "taskId": task_id,
        "parent": parent_record(invocation),
        "scope": scope_record(&scope),
        "objectiveSummary": objective_summary,
        "promptSummary": prompt_summary,
        "createdAt": now,
        "updatedAt": now,
        "refs": {
            "trace": trace_refs,
            "replay": replay_refs,
            "evidence": evidence_refs,
            "outputs": output_refs
        },
        "result": Value::Null,
        "error": Value::Null,
        "authority": authority_record(invocation),
        "execution": execution_record(invocation),
        "activation": activation_proof(),
        "network": network_proof(),
        "redaction": {"policy": "summary-only; raw prompts/results are not persisted"},
        "limits": {
            "maxSummaryBytes": MAX_SUMMARY_BYTES,
            "maxRefItems": MAX_REF_ITEMS,
            "maxPlaceholderBytes": MAX_PLACEHOLDER_BYTES,
            "maxTotalPayloadBytes": MAX_TOTAL_PAYLOAD_BYTES,
            "maxRunningPerScope": MAX_RUNNING_PER_SCOPE
        },
        "idempotency": {"key": idempotency_key},
        "revision": 1
    });
    validate_task_payload(&record)?;
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: SUBAGENT_TASK_KIND.to_owned(),
            schema_id: Some(SUBAGENT_TASK_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("running".to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": WRITE_SCOPE,
                "modelPolicy": PLACEHOLDER_MODEL_POLICY,
                "activation": "record_only",
                "execution": "placeholder_no_spawn"
            }),
            initial_payload: Some(record),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_lifecycle_event(
        deps,
        invocation,
        "subagent_task.launched",
        &resource,
        json!({
            "state": resource.lifecycle,
            "taskId": resource_id,
            "modelPolicy": PLACEHOLDER_MODEL_POLICY,
            "workerStarted": false,
            "jobStarted": false
        }),
    )
    .await?;
    let version_id = resource.current_version_id.clone();
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_launch",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "subagentTaskResourceId": resource.resource_id,
        "subagentTaskVersionId": version_id,
        "resourceRefs": [resource_ref(&resource, "subagent_task")],
        "execution": execution_readback_proof(),
        "network": network_proof()
    }))
}

pub(crate) async fn status_subagent_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let (inspection, version, current) =
        inspect_current_task(deps, invocation, payload, "subagent_status").await?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_status",
        "status": inspection.resource.lifecycle,
        "subagentTaskResourceId": inspection.resource.resource_id,
        "subagentTaskVersionId": version.version_id,
        "task": inspected_task(&inspection.resource, &version, &current),
        "resourceRefs": [version_ref(&inspection.resource, &version, "subagent_task")],
        "execution": execution_readback_proof(),
        "network": network_proof()
    }))
}

pub(crate) async fn result_subagent_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let (inspection, version, current) =
        inspect_current_task(deps, invocation, payload, "subagent_result").await?;
    let task = inspected_task(&inspection.resource, &version, &current);
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_result",
        "status": inspection.resource.lifecycle,
        "subagentTaskResourceId": inspection.resource.resource_id,
        "subagentTaskVersionId": version.version_id,
        "result": task["payload"]["result"].clone(),
        "error": task["payload"]["error"].clone(),
        "refs": task["payload"]["refs"].clone(),
        "resourceRefs": [version_ref(&inspection.resource, &version, "subagent_task")],
        "projection": {"rawPayloadReturned": false, "resultMergePerformed": false},
        "execution": execution_readback_proof(),
        "network": network_proof()
    }))
}

pub(crate) async fn cancel_subagent_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_grant(deps, invocation, "subagent_cancel").await?;
    require_write_grant(&grant, "subagent_cancel")?;
    let resource_id = required_subagent_resource_id(payload, "subagent_cancel")?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing subagent task resource {resource_id}")))?;
    ensure_subagent_task(&inspection, "subagent_cancel")?;
    ensure_scope(&inspection, &scope, "subagent_cancel")?;
    let (current_version, current) = current_payload(&inspection, "subagent_cancel")?;
    if optional_string(payload, "expectedSubagentTaskVersionId")?
        .is_some_and(|expected| expected != current_version.version_id)
    {
        return Err(invalid("subagent task version is stale"));
    }
    if is_terminal(&inspection.resource.lifecycle) {
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "subagent_cancel",
            "status": inspection.resource.lifecycle,
            "subagentTaskResourceId": resource_id,
            "subagentTaskVersionId": current_version.version_id,
            "idempotent": true,
            "resourceRefs": [version_ref(&inspection.resource, current_version, "subagent_task")],
            "execution": execution_readback_proof(),
            "network": network_proof()
        }));
    }
    let reason = optional_string(payload, "reason")?
        .map(|value| bounded_text("reason", &value, MAX_SUMMARY_BYTES))
        .transpose()?
        .unwrap_or_else(|| "cancel requested".to_owned());
    let mut record = current.clone();
    record["state"] = json!("cancelled");
    record["updatedAt"] = json!(Utc::now().to_rfc3339());
    record["revision"] = json!(record["revision"].as_u64().unwrap_or(1).saturating_add(1));
    record["execution"]["cancellation"] = json!({
        "requested": true,
        "requestedAt": Utc::now().to_rfc3339(),
        "requestedBy": invocation.causal_context.actor_id.as_str(),
        "reason": reason,
        "workerCancelRequested": false,
        "jobCancelRequested": false,
        "processSignalSent": false
    });
    record["result"] = json!({
        "kind": "cancelled",
        "status": "cancelled",
        "summary": "Subagent placeholder lifecycle cancelled before worker execution."
    });
    validate_update_payload(&record)?;
    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(current_version.version_id.clone()),
            lifecycle: Some("cancelled".to_owned()),
            payload: record,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_lifecycle_event(
        deps,
        invocation,
        "subagent_task.cancelled",
        &inspection.resource,
        json!({"state": "cancelled", "workerCancelRequested": false, "jobCancelRequested": false}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_cancel",
        "status": "cancelled",
        "subagentTaskResourceId": resource_id,
        "subagentTaskVersionId": version.version_id,
        "idempotent": false,
        "resourceRefs": [version_ref(&inspection.resource, &version, "subagent_task")],
        "execution": execution_readback_proof(),
        "network": network_proof()
    }))
}

async fn inspect_current_task<'a>(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
) -> Result<(EngineResourceInspection, EngineResourceVersion, Value), CapabilityError> {
    let grant = inspect_grant(deps, invocation, operation).await?;
    require_read_grant(&grant, operation)?;
    let resource_id = required_subagent_resource_id(payload, operation)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing subagent task resource {resource_id}")))?;
    ensure_subagent_task(&inspection, operation)?;
    ensure_scope(&inspection, &scope, operation)?;
    let (version, current) = {
        let (version, current) = current_payload(&inspection, operation)?;
        (version.clone(), current.clone())
    };
    Ok((inspection, version, current))
}

async fn ensure_concurrency_available(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<(), CapabilityError> {
    let running = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(SUBAGENT_TASK_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some("running".to_owned()),
            limit: MAX_RUNNING_PER_SCOPE.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    if running.len() >= MAX_RUNNING_PER_SCOPE {
        return Err(policy(format!(
            "subagent_launch concurrency limit reached for current scope: {MAX_RUNNING_PER_SCOPE}"
        )));
    }
    Ok(())
}

async fn inspect_grant(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| policy(format!("{operation} authority grant was not found")))?;
    if grant.network_policy != "none" {
        return Err(policy(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

fn require_read_grant(grant: &EngineGrant, operation: &str) -> Result<(), CapabilityError> {
    require_explicit_grant_item(&grant.allowed_authority_scopes, READ_SCOPE, operation)?;
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_READ_SCOPE,
        operation,
    )?;
    require_explicit_grant_item(&grant.allowed_resource_kinds, SUBAGENT_TASK_KIND, operation)?;
    require_explicit_subagent_task_selector(&grant.resource_selectors, operation)
}

fn require_write_grant(grant: &EngineGrant, operation: &str) -> Result<(), CapabilityError> {
    require_read_grant(grant, operation)?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, WRITE_SCOPE, operation)?;
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_WRITE_SCOPE,
        operation,
    )
}

fn require_explicit_subagent_task_selector(
    selectors: &[String],
    operation: &str,
) -> Result<(), CapabilityError> {
    if let Some(selector) = selectors.iter().find(|selector| {
        let trimmed = selector.trim();
        trimmed == "*"
            || trimmed == "kind:*"
            || trimmed == "resource:*"
            || trimmed == "kind:"
            || trimmed == "resource:"
            || trimmed.ends_with(":*")
    }) {
        return Err(invalid(format!(
            "{operation} rejects broad resource selector {selector}"
        )));
    }
    let expected = format!("kind:{SUBAGENT_TASK_KIND}");
    if !selectors.iter().any(|selector| selector == &expected) {
        return Err(invalid(format!(
            "{operation} requires an explicit {expected} selector"
        )));
    }
    Ok(())
}

fn require_explicit_grant_item(
    values: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if values.iter().any(|value| value == "*") {
        return Err(invalid(format!("{operation} rejects wildcard grants")));
    }
    if !values.iter().any(|value| value == required) {
        return Err(invalid(format!(
            "{operation} requires explicit {required} grant"
        )));
    }
    Ok(())
}

fn require_placeholder_policy(payload: &Value) -> Result<(), CapabilityError> {
    let policy = required_string(payload, "modelPolicy")?;
    if policy != PLACEHOLDER_MODEL_POLICY {
        return Err(policy_error(format!(
            "subagent_launch requires explicit modelPolicy {PLACEHOLDER_MODEL_POLICY}"
        )));
    }
    Ok(())
}

fn required_subagent_resource_id(
    payload: &Value,
    operation: &str,
) -> Result<String, CapabilityError> {
    let resource_id = required_string(payload, "subagentTaskResourceId")?;
    if !resource_id.starts_with(&format!("{SUBAGENT_TASK_KIND}:")) {
        return Err(invalid(format!(
            "{operation} subagentTaskResourceId has unsupported resource kind"
        )));
    }
    Ok(resource_id)
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot inspect a subagent task outside the current scope"
        )));
    }
    Ok(())
}

fn ensure_subagent_task(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != SUBAGENT_TASK_KIND {
        return Err(invalid(format!(
            "{operation} expected {SUBAGENT_TASK_KIND}"
        )));
    }
    if inspection.resource.schema_id.as_str() != SUBAGENT_TASK_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {SUBAGENT_TASK_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn current_payload<'a>(
    inspection: &'a EngineResourceInspection,
    operation: &str,
) -> Result<(&'a EngineResourceVersion, &'a Value), CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid(format!("{operation} resource has no current version")))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid(format!("{operation} current version is missing")))?;
    Ok((version, &version.payload))
}

fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role
    })
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": version.version_id,
        "contentHash": version.content_hash,
        "role": role
    })
}

async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    resource: &EngineResource,
    payload: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: SUBAGENT_TASK_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "activation": activation_proof(),
                "network": network_proof()
            }),
            visibility: VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
}

fn task_resource_id(scope: &EngineResourceScope, task_id: &str, idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(task_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{SUBAGENT_TASK_KIND}:{}", hex::encode(hasher.finalize()))
}

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}

fn parent_record(invocation: &Invocation) -> Value {
    json!({
        "sessionId": invocation.causal_context.session_id,
        "workspaceId": invocation.causal_context.workspace_id,
        "traceId": invocation.causal_context.trace_id.as_str(),
        "parentInvocationId": invocation
            .causal_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str()),
        "actorId": invocation.causal_context.actor_id.as_str(),
        "actorKind": format!("{:?}", invocation.causal_context.actor_kind)
    })
}

fn scope_record(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [WRITE_SCOPE, READ_SCOPE, RESOURCE_WRITE_SCOPE, RESOURCE_READ_SCOPE],
        "resourceKind": SUBAGENT_TASK_KIND,
        "canDelegate": false
    })
}

fn execution_record(invocation: &Invocation) -> Value {
    json!({
        "schemaVersion": "tron.subagent_execution.v1",
        "modelPolicy": PLACEHOLDER_MODEL_POLICY,
        "profilePolicy": {"mode": "server-owned-placeholder", "settingsMigrationRequired": false},
        "concurrency": {
            "maxRunningPerScope": MAX_RUNNING_PER_SCOPE,
            "scopeKind": invocation.causal_context.session_id.as_ref().map(|_| "session").unwrap_or("workspace")
        },
        "worker": {
            "kind": "subagent_worker_placeholder",
            "started": false,
            "workerId": Value::Null
        },
        "job": {
            "backing": "job_lifecycle_placeholder",
            "jobStarted": false,
            "jobResourceId": Value::Null,
            "processStarted": false
        },
        "cancellation": {
            "supported": true,
            "requested": false,
            "workerCancelRequested": false,
            "jobCancelRequested": false,
            "processSignalSent": false
        },
        "result": {
            "resultResourceRequired": true,
            "resultMergePerformed": false,
            "rawResultPersisted": false
        },
        "sideEffects": {
            "toolExecution": false,
            "network": false,
            "browser": false,
            "packageLaunch": false,
            "catalogRegistration": false,
            "trustPromotion": false
        }
    })
}

fn execution_readback_proof() -> Value {
    json!({
        "modelPolicy": PLACEHOLDER_MODEL_POLICY,
        "workerStarted": false,
        "jobStarted": false,
        "processStarted": false,
        "toolExecution": false,
        "resultMerged": false
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({"traceId": invocation.causal_context.trace_id.as_str()})]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({"invocationId": invocation.id.as_str()})]
}

fn activation_proof() -> Value {
    json!({
        "performed": false,
        "subagentStarted": false,
        "workerStarted": false,
        "jobStarted": false,
        "processStarted": false,
        "catalogRegistration": false,
        "toolExecution": false,
        "resultMerged": false
    })
}

fn network_proof() -> Value {
    json!({"performed": false, "requiredPolicy": "none"})
}

fn is_terminal(state: &str) -> bool {
    matches!(state, "succeeded" | "failed" | "cancelled" | "archived")
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

fn policy(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Custom {
        code: "SUBAGENT_EXECUTION_POLICY_DENIED".to_owned(),
        message: message.into(),
        details: None,
    }
}

fn policy_error(message: impl Into<String>) -> CapabilityError {
    policy(message)
}
