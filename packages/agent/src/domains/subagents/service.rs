#![allow(dead_code)]

use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    ActorKind, CreateResource, EngineGrant, EngineResource, EngineResourceInspection,
    EngineResourceScope, EngineResourceVersion, Invocation, ListResources, PublishStreamEvent,
    SUBAGENT_TASK_KIND, SUBAGENT_TASK_SCHEMA_ID, UpdateResource, WorkerId,
    is_bootstrap_authority_grant_id,
};
use crate::shared::server::errors::CapabilityError;

use super::projection::{inspected_task, task_summary};
use super::validation::*;
use super::{Deps, READ_SCOPE, SCHEMA_VERSION, SUBAGENT_TASK_TOPIC, WORKER, WRITE_SCOPE};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";

/// Create an inert subagent task lifecycle record as trusted internal evidence.
pub(crate) async fn create_task_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_internal_write_authority(deps, invocation, "subagent task create").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let now = Utc::now().to_rfc3339();
    let task_id = optional_string(payload, "taskId")?
        .map(|value| bounded_text("taskId", &value, 128))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let state = optional_string(payload, "state")?.unwrap_or_else(|| "requested".to_owned());
    validate_state(&state)?;
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

    let scope = resource_scope(invocation)?;
    let mut record = json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": state,
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
        "activation": activation_proof(),
        "network": network_proof(),
        "redaction": {"policy": "summary-only; raw prompts/results are not persisted"},
        "limits": {
            "maxSummaryBytes": MAX_SUMMARY_BYTES,
            "maxRefItems": MAX_REF_ITEMS,
            "maxPlaceholderBytes": MAX_PLACEHOLDER_BYTES,
            "maxTotalPayloadBytes": MAX_TOTAL_PAYLOAD_BYTES
        },
        "idempotency": {"key": idempotency_key},
        "revision": 1
    });
    validate_task_payload(&record)?;
    let resource_id =
        task_resource_id(&scope, record["taskId"].as_str().unwrap(), &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_scope(&existing, &scope, "subagent_task_create replay")?;
        ensure_subagent_task(&existing, "subagent_task_create replay")?;
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "subagent_task_create",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "subagentTaskResourceId": resource_id,
            "resourceRefs": [current_resource_ref(&existing, "subagent_task")?],
            "activation": activation_proof(),
            "network": network_proof()
        }));
    }

    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: SUBAGENT_TASK_KIND.to_owned(),
            schema_id: Some(SUBAGENT_TASK_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(record["state"].as_str().unwrap_or("requested").to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": WRITE_SCOPE,
                "activation": "forbidden",
                "execution": "forbidden"
            }),
            initial_payload: Some(record.take()),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_lifecycle_event(
        deps,
        invocation,
        "subagent_task.created",
        &resource,
        json!({"state": resource.lifecycle, "taskId": task_id}),
    )
    .await?;

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_task_create",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "subagentTaskResourceId": resource.resource_id,
        "resourceRefs": [resource_ref(&resource, "subagent_task")],
        "activation": activation_proof(),
        "network": network_proof()
    }))
}

/// Update lifecycle metadata for an existing inert subagent task record.
pub(crate) async fn update_task_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_internal_write_authority(deps, invocation, "subagent task update").await?;
    let resource_id = required_string(payload, "subagentTaskResourceId")?;
    if !resource_id.starts_with(&format!("{SUBAGENT_TASK_KIND}:")) {
        return Err(invalid(
            "subagentTaskResourceId has unsupported resource kind",
        ));
    }
    let state = required_string(payload, "state")?;
    validate_state(&state)?;
    let scope = resource_scope(invocation)?;
    let mut inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing subagent task resource {resource_id}")))?;
    ensure_subagent_task(&inspection, "subagent_task_update")?;
    ensure_scope(&inspection, &scope, "subagent_task_update")?;
    let (current_version, current) = current_payload(&inspection, "subagent_task_update")?;
    if optional_string(payload, "expectedSubagentTaskVersionId")?
        .is_some_and(|expected| expected != current_version.version_id)
    {
        return Err(invalid("subagent task version is stale"));
    }

    let mut record = current.clone();
    record["state"] = json!(state);
    record["updatedAt"] = json!(Utc::now().to_rfc3339());
    record["revision"] = json!(record["revision"].as_u64().unwrap_or(1).saturating_add(1));
    if let Some(result) = optional_object(payload, "result")? {
        record["result"] = Value::Object(result);
    }
    if let Some(error) = optional_object(payload, "error")? {
        record["error"] = Value::Object(error);
    }
    if let Some(evidence_refs) = optional_array(payload, "evidenceRefs")? {
        validate_refs("evidenceRefs", &evidence_refs)?;
        record["refs"]["evidence"] = Value::Array(evidence_refs);
    }
    validate_update_payload(&record)?;
    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(current_version.version_id.clone()),
            lifecycle: Some(record["state"].as_str().unwrap_or("requested").to_owned()),
            payload: record,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = state.clone();
    inspection.resource.current_version_id = Some(version.version_id.clone());
    publish_lifecycle_event(
        deps,
        invocation,
        "subagent_task.updated",
        &inspection.resource,
        json!({"state": state}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_task_update",
        "status": state,
        "subagentTaskResourceId": resource_id,
        "subagentTaskVersionId": version.version_id,
        "resourceRefs": [version_ref(&inspection.resource, &version, "subagent_task")],
        "activation": activation_proof(),
        "network": network_proof()
    }))
}

pub(crate) async fn list_subagent_tasks_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "subagent_task_list").await?;
    require_read_kind_selector(&grant, "subagent_task_list")?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let state = optional_string(payload, "state")?;
    if let Some(state) = state.as_deref() {
        validate_state(state)?;
    }
    let lifecycle = match (include_archived, state) {
        (true, _) => None,
        (false, Some(state)) => Some(state),
        (false, None) => None,
    };
    let scope = resource_scope(invocation)?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(SUBAGENT_TASK_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle,
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut tasks = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_subagent_task(&inspection, "subagent_task_list")?;
        ensure_scope(&inspection, &scope, "subagent_task_list")?;
        let (version, payload) = current_payload(&inspection, "subagent_task_list")?;
        if !include_archived && inspection.resource.lifecycle == "archived" {
            continue;
        }
        tasks.push(task_summary(&inspection.resource, version, payload));
    }
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_task_list",
        "scope": scope_ref(&scope),
        "tasks": tasks,
        "limits": {
            "requestedLimit": limit,
            "returned": tasks.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "activation": activation_proof(),
        "network": network_proof()
    }))
}

pub(crate) async fn inspect_subagent_task_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "subagent_task_inspect").await?;
    require_read_kind_selector(&grant, "subagent_task_inspect")?;
    let resource_id = required_string(payload, "subagentTaskResourceId")?;
    if !resource_id.starts_with(&format!("{SUBAGENT_TASK_KIND}:")) {
        return Err(invalid(
            "subagentTaskResourceId has unsupported resource kind",
        ));
    }
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing subagent task resource {resource_id}")))?;
    ensure_subagent_task(&inspection, "subagent_task_inspect")?;
    ensure_scope(&inspection, &scope, "subagent_task_inspect")?;
    let (version, payload) = current_payload(&inspection, "subagent_task_inspect")?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_task_inspect",
        "scope": scope_ref(&scope),
        "task": inspected_task(&inspection.resource, version, payload),
        "activation": activation_proof(),
        "network": network_proof()
    }))
}

async fn ensure_internal_write_authority(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if !matches!(
        invocation.causal_context.actor_kind,
        ActorKind::System | ActorKind::Admin
    ) {
        return Err(policy(format!(
            "{operation} requires trusted internal system/admin authority"
        )));
    }
    if !invocation.causal_context.has_scope(WRITE_SCOPE)
        || !invocation.causal_context.has_scope(RESOURCE_WRITE_SCOPE)
    {
        return Err(policy(format!(
            "{operation} requires {WRITE_SCOPE} and {RESOURCE_WRITE_SCOPE}"
        )));
    }
    if is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id) {
        return Err(policy(format!(
            "{operation} requires a derived non-bootstrap grant"
        )));
    }
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| policy("unknown subagent task authority grant"))?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, WRITE_SCOPE, operation)?;
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_WRITE_SCOPE,
        operation,
    )?;
    require_explicit_grant_item(&grant.allowed_resource_kinds, SUBAGENT_TASK_KIND, operation)?;
    if grant.network_policy != "none" {
        return Err(policy(format!("{operation} requires networkPolicy none")));
    }
    Ok(())
}

async fn inspect_read_grant(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} authority grant was not found")))?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, READ_SCOPE, operation)?;
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_READ_SCOPE,
        operation,
    )?;
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

fn require_read_kind_selector(grant: &EngineGrant, operation: &str) -> Result<(), CapabilityError> {
    require_explicit_grant_item(&grant.allowed_resource_kinds, SUBAGENT_TASK_KIND, operation)?;
    if !allows_explicit_selector(&grant.resource_selectors) {
        return Err(invalid(format!(
            "{operation} requires an explicit kind:{SUBAGENT_TASK_KIND} selector"
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

fn allows_explicit_selector(values: &[String]) -> bool {
    values
        .iter()
        .any(|selector| selector == &format!("kind:{SUBAGENT_TASK_KIND}"))
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

fn current_resource_ref(
    inspection: &EngineResourceInspection,
    role: &str,
) -> Result<Value, CapabilityError> {
    let (version, _) = current_payload(inspection, "resource_ref")?;
    Ok(version_ref(&inspection.resource, version, role))
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
            visibility: crate::engine::VisibilityScope::System,
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

fn scope_ref(scope: &EngineResourceScope) -> Value {
    scope_record(scope)
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [WRITE_SCOPE, READ_SCOPE, RESOURCE_WRITE_SCOPE, RESOURCE_READ_SCOPE],
        "resourceKind": SUBAGENT_TASK_KIND
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
        "catalogRegistration": false,
        "toolExecution": false,
        "resultMerged": false
    })
}

fn network_proof() -> Value {
    json!({"performed": false, "requiredPolicy": "none"})
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

fn policy(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Custom {
        code: "SUBAGENT_TASK_POLICY_DENIED".to_owned(),
        message: message.into(),
        details: None,
    }
}
