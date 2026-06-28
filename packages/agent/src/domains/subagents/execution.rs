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
const DELEGATED_MODEL_POLICY: &str = "accepted_jobs_program_execution_v1";
const DELEGATED_WORKER_KIND: &str = "module_program_execution";
const DELEGATED_MODULE_PACK: &str = "jobs_program_execution";
const MAX_RUNNING_PER_SCOPE: usize = 1;

pub(crate) enum SubagentLaunchPlan {
    Replay(Value),
    StartModuleProgram(Value),
}

#[derive(Clone)]
struct LaunchIdentity {
    task_id: String,
    resource_id: String,
    idempotency_key: String,
    scope: EngineResourceScope,
}

pub(crate) async fn plan_subagent_launch_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<SubagentLaunchPlan, CapabilityError> {
    let identity = launch_identity(deps, invocation, payload, "subagent_launch").await?;
    if let Some(replay) = launch_replay(deps, &identity, "subagent_launch").await? {
        return Ok(SubagentLaunchPlan::Replay(replay));
    }
    ensure_concurrency_available(deps, &identity.scope).await?;
    Ok(SubagentLaunchPlan::StartModuleProgram(
        module_program_execution_payload(invocation, payload, &identity)?,
    ))
}

pub(crate) async fn launch_subagent_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    delegated_start: &Value,
) -> Result<Value, CapabilityError> {
    let identity = launch_identity(deps, invocation, payload, "subagent_launch").await?;
    if let Some(replay) = launch_replay(deps, &identity, "subagent_launch").await? {
        return Ok(replay);
    }
    ensure_concurrency_available(deps, &identity.scope).await?;
    let delegated = delegated_start_record(delegated_start)?;
    let now = Utc::now().to_rfc3339();
    validate_launch_context(payload)?;

    validate_summary_is_not_raw_payload(
        "objectiveSummary",
        &required_string(payload, "objectiveSummary")?,
    )?;
    validate_summary_is_not_raw_payload(
        "promptSummary",
        &required_string(payload, "promptSummary")?,
    )?;
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
    let handoff_refs = optional_array(payload, "handoffRefs")?.unwrap_or_default();
    validate_context_handoff_refs(&handoff_refs)?;
    let trace_refs =
        optional_array(payload, "traceRefs")?.unwrap_or_else(|| trace_refs(invocation));
    let replay_refs =
        optional_array(payload, "replayRefs")?.unwrap_or_else(|| replay_refs(invocation));
    validate_refs("traceRefs", &trace_refs)?;
    validate_refs("replayRefs", &replay_refs)?;

    let record = json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": "running",
        "taskId": identity.task_id,
        "parent": parent_record(invocation),
        "scope": scope_record(&identity.scope),
        "objectiveSummary": objective_summary,
        "promptSummary": prompt_summary,
        "createdAt": now,
        "updatedAt": now,
        "refs": {
            "trace": trace_refs,
            "replay": replay_refs,
            "evidence": evidence_refs,
            "outputs": output_refs,
            "handoff": handoff_refs
        },
        "result": {
            "kind": "delegated_module_pending",
            "status": "running",
            "summary": "Delegated module task is running; result merge requires explicit review.",
            "mergeProposal": merge_proposal_record(&delegated, "pending")
        },
        "error": Value::Null,
        "authority": authority_record(invocation),
        "delegation": delegated.clone(),
        "execution": execution_record(invocation, &delegated),
        "activation": activation_proof(true),
        "network": network_proof(),
        "redaction": {"policy": "summary-only; raw prompts/results/tool logs are not persisted"},
        "limits": {
            "maxSummaryBytes": MAX_SUMMARY_BYTES,
            "maxRefItems": MAX_REF_ITEMS,
            "maxPlaceholderBytes": MAX_PLACEHOLDER_BYTES,
            "maxTotalPayloadBytes": MAX_TOTAL_PAYLOAD_BYTES,
            "maxRunningPerScope": MAX_RUNNING_PER_SCOPE
        },
        "idempotency": {"key": identity.idempotency_key},
        "revision": 1
    });
    validate_task_payload(&record)?;
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(identity.resource_id.clone()),
            kind: SUBAGENT_TASK_KIND.to_owned(),
            schema_id: Some(SUBAGENT_TASK_SCHEMA_ID.to_owned()),
            scope: identity.scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("running".to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": WRITE_SCOPE,
                "modelPolicy": DELEGATED_MODEL_POLICY,
                "activation": "delegated_module_program_execution",
                "execution": "accepted_module_pack"
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
            "taskId": identity.resource_id,
            "modelPolicy": DELEGATED_MODEL_POLICY,
            "workerStarted": true,
            "jobStarted": true,
            "resultMerged": false
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
        "resourceRefs": [
            resource_ref(&resource, "subagent_task"),
            delegated["moduleRuntimeRef"].clone(),
            delegated["jobRef"].clone(),
            delegated["programExecutionRef"].clone()
        ],
        "execution": execution_readback_proof(),
        "delegation": delegated,
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
        "workerCancelRequested": true,
        "jobCancelRequested": true,
        "processSignalSent": false
    });
    record["result"] = json!({
        "kind": "cancelled",
        "status": "cancelled",
        "summary": "Delegated subagent cancellation was requested through the module job binding.",
        "mergeProposal": Value::Null
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
        json!({"state": "cancelled", "workerCancelRequested": true, "jobCancelRequested": true}),
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

pub(crate) async fn delegated_module_followup_payload(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
) -> Result<Value, CapabilityError> {
    let (_inspection, version, current) =
        inspect_current_task(deps, invocation, payload, operation).await?;
    if operation == "subagent_cancel" {
        if let Some(expected) = optional_string(payload, "expectedSubagentTaskVersionId")? {
            if expected != version.version_id {
                return Err(invalid("subagent task version is stale"));
            }
        }
    }
    let delegation = current
        .get("delegation")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            invalid(format!(
                "{operation} subagent task has no delegated module refs"
            ))
        })?;
    let module_runtime_resource_id = delegation
        .get("moduleRuntimeResourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{operation} missing module runtime ref")))?;
    let job_resource_id = delegation
        .get("jobResourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{operation} missing delegated job ref")))?;
    let mut followup = json!({
        "moduleRuntimeResourceId": module_runtime_resource_id,
        "jobResourceId": job_resource_id
    });
    if let Some(version_id) = delegation
        .get("moduleRuntimeVersionId")
        .and_then(Value::as_str)
    {
        followup["expectedModuleRuntimeVersionId"] = json!(version_id);
    }
    if let Some(reason) = optional_string(payload, "reason")? {
        followup["reason"] = json!(bounded_text("reason", &reason, MAX_SUMMARY_BYTES)?);
    }
    if let Some(key) = optional_string(payload, "idempotencyKey")? {
        followup["idempotencyKey"] = json!(key);
    }
    Ok(followup)
}

pub(crate) async fn result_subagent_from_module_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    module_details: &Value,
) -> Result<Value, CapabilityError> {
    let (inspection, version, current) =
        inspect_current_task(deps, invocation, payload, "subagent_result").await?;
    let task = inspected_task(&inspection.resource, &version, &current);
    let proposal = merge_proposal_from_module(module_details)?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_result",
        "status": module_details.get("status").and_then(Value::as_str).unwrap_or(inspection.resource.lifecycle.as_str()),
        "subagentTaskResourceId": inspection.resource.resource_id,
        "subagentTaskVersionId": version.version_id,
        "result": {
            "kind": "merge_proposal",
            "status": proposal["status"].clone(),
            "summary": "Delegated subagent result is ready for explicit parent review.",
            "mergeProposal": proposal
        },
        "error": task["payload"]["error"].clone(),
        "refs": task["payload"]["refs"].clone(),
        "delegation": projected_delegation(current.get("delegation")),
        "resourceRefs": [
            version_ref(&inspection.resource, &version, "subagent_task"),
            proposal["moduleRuntimeRef"].clone(),
            proposal["jobRef"].clone()
        ],
        "projection": {
            "rawPayloadReturned": false,
            "resultMergePerformed": false,
            "parentConversationMutated": false
        },
        "execution": execution_readback_proof(),
        "network": network_proof()
    }))
}

pub(crate) fn status_subagent_from_module_value(
    subagent_status: Value,
    module_details: &Value,
) -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_status",
        "status": module_details.get("status").and_then(Value::as_str).unwrap_or("unknown"),
        "subagentTaskResourceId": subagent_status["subagentTaskResourceId"].clone(),
        "subagentTaskVersionId": subagent_status["subagentTaskVersionId"].clone(),
        "task": subagent_status["task"].clone(),
        "delegatedModule": redacted_module_details(module_details),
        "resourceRefs": subagent_status["resourceRefs"].clone(),
        "execution": execution_readback_proof(),
        "network": network_proof()
    })
}

async fn launch_identity(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
) -> Result<LaunchIdentity, CapabilityError> {
    let grant = inspect_grant(deps, invocation, operation).await?;
    require_write_grant(&grant, operation)?;
    require_delegated_policy(payload)?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let task_id = optional_string(payload, "taskId")?
        .map(|value| bounded_text("taskId", &value, 128))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let resource_id = task_resource_id(&scope, &task_id, &idempotency_key);
    Ok(LaunchIdentity {
        task_id,
        resource_id,
        idempotency_key,
        scope,
    })
}

async fn launch_replay(
    deps: &Deps,
    identity: &LaunchIdentity,
    operation: &str,
) -> Result<Option<Value>, CapabilityError> {
    let Some(existing) = deps
        .engine_host
        .inspect_resource(&identity.resource_id)
        .await
        .map_err(engine_error)?
    else {
        return Ok(None);
    };
    ensure_subagent_task(&existing, &format!("{operation} replay"))?;
    ensure_scope(&existing, &identity.scope, &format!("{operation} replay"))?;
    let (version, current) = current_payload(&existing, &format!("{operation} replay"))?;
    Ok(Some(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": operation,
        "status": existing.resource.lifecycle,
        "idempotentReplay": true,
        "subagentTaskResourceId": identity.resource_id,
        "subagentTaskVersionId": version.version_id,
        "resourceRefs": [version_ref(&existing.resource, version, "subagent_task")],
        "delegation": projected_delegation(current.get("delegation")),
        "execution": execution_readback_proof(),
        "network": network_proof()
    })))
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

fn require_delegated_policy(payload: &Value) -> Result<(), CapabilityError> {
    let policy = required_string(payload, "modelPolicy")?;
    if policy != DELEGATED_MODEL_POLICY {
        return Err(policy_error(format!(
            "subagent_launch requires explicit modelPolicy {DELEGATED_MODEL_POLICY}"
        )));
    }
    require_exact_choice(payload, "workerKind", DELEGATED_WORKER_KIND)?;
    require_exact_choice(payload, "modulePackId", DELEGATED_MODULE_PACK)?;
    Ok(())
}

fn require_exact_choice(
    payload: &Value,
    field: &str,
    expected: &str,
) -> Result<(), CapabilityError> {
    let actual = required_string(payload, field)?;
    if actual == "*" || actual.ends_with(":*") || actual != expected {
        return Err(policy_error(format!(
            "subagent_launch requires explicit {field} {expected}"
        )));
    }
    Ok(())
}

fn module_program_execution_payload(
    invocation: &Invocation,
    payload: &Value,
    identity: &LaunchIdentity,
) -> Result<Value, CapabilityError> {
    validate_launch_context(payload)?;
    let mut value = json!({
        "operation": "module_program_execution_start",
        "moduleLifecycleResourceId": required_string(payload, "moduleLifecycleResourceId")?,
        "runtimeRequestId": required_string(payload, "runtimeRequestId")?,
        "runtimeKind": optional_string(payload, "runtimeKind")?.unwrap_or_else(|| DELEGATED_MODULE_PACK.to_owned()),
        "runtimeLabel": optional_string(payload, "runtimeLabel")?.unwrap_or_else(|| "Subagent delegated module program execution".to_owned()),
        "command": required_string(payload, "command")?,
        "runtimeId": required_string(payload, "runtimeId")?,
        "languageId": required_string(payload, "languageId")?,
        "programFingerprint": required_string(payload, "programFingerprint")?,
        "networkPolicy": "none",
        "reason": bounded_text("objectiveSummary", &required_string(payload, "objectiveSummary")?, MAX_SUMMARY_BYTES)?,
        "evidenceRefs": delegated_evidence_refs(payload, identity, invocation)?,
        "inputRefs": optional_array(payload, "inputRefs")?.unwrap_or_default(),
        "sourceRefs": optional_array(payload, "sourceRefs")?.unwrap_or_default(),
        "idempotencyKey": identity.idempotency_key
    });
    copy_optional_u64(payload, &mut value, "timeoutMs")?;
    copy_optional_u64(payload, &mut value, "maxOutputBytes")?;
    copy_optional_u64(payload, &mut value, "cleanupAfterSeconds")?;
    copy_optional_string(payload, &mut value, "programId")?;
    copy_optional_string(payload, &mut value, "programLabel")?;
    copy_optional_string(payload, &mut value, "programSummary")?;
    copy_optional_string(payload, &mut value, "inputFingerprint")?;
    copy_optional_ref(payload, &mut value, "sourceRef");
    copy_optional_ref(payload, &mut value, "inputRef");
    Ok(value)
}

fn validate_launch_context(payload: &Value) -> Result<(), CapabilityError> {
    for field in ["objectiveSummary", "promptSummary"] {
        let value = required_string(payload, field)?;
        validate_summary_is_not_raw_payload(field, &value)?;
    }
    let handoff_refs = optional_array(payload, "handoffRefs")?.unwrap_or_default();
    validate_context_handoff_refs(&handoff_refs)?;
    for field in ["inputRefs", "sourceRefs", "evidenceRefs", "outputRefs"] {
        validate_refs(field, &optional_array(payload, field)?.unwrap_or_default())?;
    }
    for field in ["inputRef", "sourceRef"] {
        if let Some(value) = payload.get(field) {
            validate_refs(field, std::slice::from_ref(value))?;
            validate_context_handoff_refs(std::slice::from_ref(value))?;
        }
    }
    Ok(())
}

fn delegated_evidence_refs(
    payload: &Value,
    identity: &LaunchIdentity,
    invocation: &Invocation,
) -> Result<Vec<Value>, CapabilityError> {
    let mut refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    refs.push(json!({
        "kind": SUBAGENT_TASK_KIND,
        "resourceId": identity.resource_id,
        "role": "parent_subagent_task"
    }));
    refs.push(json!({
        "kind": "trace",
        "id": invocation.causal_context.trace_id.as_str(),
        "role": "delegation_trace"
    }));
    validate_refs("evidenceRefs", &refs)?;
    Ok(refs)
}

fn delegated_start_record(value: &Value) -> Result<Value, CapabilityError> {
    let runtime = value
        .get("moduleRuntime")
        .ok_or_else(|| invalid("delegated module start omitted module runtime"))?;
    let program = value
        .get("programExecution")
        .ok_or_else(|| invalid("delegated module start omitted program execution"))?;
    let job = value
        .pointer("/job/job")
        .ok_or_else(|| invalid("delegated module start omitted job"))?;
    let module_runtime_resource_id = runtime
        .get("moduleRuntimeResourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("delegated module start omitted module runtime resource id"))?;
    let module_runtime_version_id = runtime
        .get("moduleRuntimeVersionId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("delegated module start omitted module runtime version id"))?;
    let job_resource_id = job
        .get("jobResourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("delegated module start omitted job resource id"))?;
    let job_version_id = job
        .get("jobVersionId")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let program_execution_resource_id = program
        .get("programExecutionResourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("delegated module start omitted program execution resource id"))?;
    let program_execution_version_id = program
        .get("programExecutionVersionId")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    Ok(json!({
        "workerKind": DELEGATED_WORKER_KIND,
        "modulePackId": DELEGATED_MODULE_PACK,
        "moduleRuntimeResourceId": module_runtime_resource_id,
        "moduleRuntimeVersionId": module_runtime_version_id,
        "jobResourceId": job_resource_id,
        "jobVersionId": job_version_id,
        "programExecutionResourceId": program_execution_resource_id,
        "programExecutionVersionId": program_execution_version_id,
        "moduleRuntimeRef": {
            "kind": "module_runtime_state",
            "resourceId": module_runtime_resource_id,
            "versionId": module_runtime_version_id,
            "role": "delegated_module_runtime"
        },
        "jobRef": {
            "kind": "job_process",
            "resourceId": job_resource_id,
            "versionId": job_version_id,
            "role": "delegated_job_process"
        },
        "programExecutionRef": {
            "kind": "program_execution_record",
            "resourceId": program_execution_resource_id,
            "versionId": program_execution_version_id,
            "role": "program_execution_metadata"
        },
        "binding": {
            "runtimeJobBindingRequired": true,
            "validatedBy": "module_program_execution_status_or_cancel"
        },
        "providerSafety": {
            "rawPromptStored": false,
            "rawResultStored": false,
            "rawCommandReturned": false,
            "rawOutputReturned": false,
            "toolLogsStored": false,
            "localPathsStored": false
        }
    }))
}

fn merge_proposal_record(delegated: &Value, status: &str) -> Value {
    json!({
        "kind": "subagent_result_merge_proposal",
        "status": status,
        "reviewRequired": true,
        "parentConversationMutated": false,
        "moduleRuntimeRef": delegated["moduleRuntimeRef"].clone(),
        "jobRef": delegated["jobRef"].clone(),
        "programExecutionRef": delegated["programExecutionRef"].clone(),
        "rawResultReturned": false,
        "rawOutputReturned": false
    })
}

fn merge_proposal_from_module(module_details: &Value) -> Result<Value, CapabilityError> {
    let runtime = module_details
        .pointer("/moduleRuntime/moduleRuntime")
        .ok_or_else(|| invalid("module status omitted runtime summary"))?;
    let job = module_details
        .pointer("/job/job")
        .ok_or_else(|| invalid("module status omitted job summary"))?;
    let status = module_details
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    Ok(json!({
        "kind": "subagent_result_merge_proposal",
        "status": status,
        "reviewRequired": true,
        "parentConversationMutated": false,
        "moduleRuntimeRef": {
            "kind": "module_runtime_state",
            "resourceId": runtime.get("resourceId").and_then(Value::as_str).unwrap_or("unknown"),
            "versionId": runtime.get("versionId").and_then(Value::as_str).unwrap_or("unknown"),
            "role": "delegated_module_runtime"
        },
        "jobRef": {
            "kind": "job_process",
            "resourceId": job.get("jobResourceId").and_then(Value::as_str).unwrap_or("unknown"),
            "versionId": job.get("jobVersionId").and_then(Value::as_str).unwrap_or("unknown"),
            "role": "delegated_job_process"
        },
        "outputRef": job.get("output").cloned().unwrap_or(Value::Null),
        "terminal": job.get("terminal").cloned().unwrap_or(Value::Null),
        "rawResultReturned": false,
        "rawOutputReturned": false
    }))
}

fn redacted_module_details(module_details: &Value) -> Value {
    json!({
        "status": module_details.get("status").and_then(Value::as_str),
        "moduleRuntime": module_details.pointer("/moduleRuntime/moduleRuntime").cloned().unwrap_or(Value::Null),
        "job": module_details.pointer("/job/job").cloned().unwrap_or(Value::Null),
        "providerSafety": module_details.get("providerSafety").cloned().unwrap_or(Value::Null),
        "rawPayloadReturned": false
    })
}

fn projected_delegation(value: Option<&Value>) -> Value {
    let Some(delegation) = value.and_then(Value::as_object) else {
        return Value::Null;
    };
    json!({
        "workerKind": delegation.get("workerKind").and_then(Value::as_str),
        "modulePackId": delegation.get("modulePackId").and_then(Value::as_str),
        "moduleRuntimeRef": delegation.get("moduleRuntimeRef").cloned().unwrap_or(Value::Null),
        "jobRef": delegation.get("jobRef").cloned().unwrap_or(Value::Null),
        "programExecutionRef": delegation.get("programExecutionRef").cloned().unwrap_or(Value::Null),
        "binding": delegation.get("binding").cloned().unwrap_or(Value::Null),
        "providerSafety": delegation.get("providerSafety").cloned().unwrap_or(Value::Null)
    })
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
                "activation": activation_proof(true),
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

fn execution_record(invocation: &Invocation, delegated: &Value) -> Value {
    json!({
        "schemaVersion": "tron.subagent_execution.v1",
        "modelPolicy": DELEGATED_MODEL_POLICY,
        "profilePolicy": {"mode": "delegated-module-pack", "settingsMigrationRequired": false},
        "concurrency": {
            "maxRunningPerScope": MAX_RUNNING_PER_SCOPE,
            "scopeKind": invocation.causal_context.session_id.as_ref().map(|_| "session").unwrap_or("workspace")
        },
        "worker": {
            "kind": DELEGATED_WORKER_KIND,
            "modulePackId": DELEGATED_MODULE_PACK,
            "started": true
        },
        "job": {
            "backing": "module_program_execution",
            "jobStarted": true,
            "jobResourceId": delegated.get("jobResourceId").cloned().unwrap_or(Value::Null),
            "processStarted": true
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
        "modelPolicy": DELEGATED_MODEL_POLICY,
        "workerStarted": true,
        "jobStarted": true,
        "processStarted": true,
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

fn activation_proof(started: bool) -> Value {
    json!({
        "performed": started,
        "subagentStarted": started,
        "workerStarted": started,
        "jobStarted": started,
        "processStarted": started,
        "catalogRegistration": false,
        "toolExecution": false,
        "resultMerged": false
    })
}

fn network_proof() -> Value {
    json!({"performed": false, "requiredPolicy": "none"})
}

fn copy_optional_string(
    source: &Value,
    target: &mut Value,
    field: &str,
) -> Result<(), CapabilityError> {
    if let Some(value) = optional_string(source, field)? {
        target[field] = json!(value);
    }
    Ok(())
}

fn copy_optional_u64(
    source: &Value,
    target: &mut Value,
    field: &str,
) -> Result<(), CapabilityError> {
    if let Some(value) = optional_u64(source, field)? {
        target[field] = json!(value);
    }
    Ok(())
}

fn copy_optional_ref(source: &Value, target: &mut Value, field: &str) {
    if let Some(value) = source.get(field) {
        target[field] = value.clone();
    }
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
