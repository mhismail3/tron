//! Resource-backed truth helpers for cron schedules and run observations.
//!
//! Cron keeps a low-level SQLite cache for timer/runtime mechanics, but
//! operator-visible schedule definitions and completed run observations are
//! owned by `decision` and `evidence` resources. This boundary is the only place
//! cron composes resource capabilities directly. Truth reconstruction stays on
//! bounded resource-capability projections; the runtime cache is never product
//! truth and must not become a store reader.

use chrono::Utc;
use serde_json::{Value, json};

use crate::domains::cron::errors::CronError;
use crate::domains::cron::types::{CronJob, CronRun};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, FunctionId, Invocation,
    TraceId,
};
use crate::shared::server::errors::CapabilityError;

pub(crate) const CRON_SCHEDULE_DECISION_TYPE: &str = "cron_schedule";
pub(crate) const CRON_RUN_EVIDENCE_TYPE: &str = "cron_run";
pub(crate) const CRON_RESOURCE_TRUTH_SCAN_LIMIT: usize =
    crate::domains::resource_projection::MAX_RESOURCE_COLLECTION_LIMIT;

#[derive(Clone, Debug)]
pub(crate) struct CronScheduleRecord {
    pub(crate) resource_id: String,
    pub(crate) version_id: String,
    pub(crate) job: CronJob,
}

#[must_use]
pub(crate) fn schedule_decision_id(job_id: &str) -> String {
    format!("decision:cron-schedule:{job_id}")
}

#[must_use]
pub(crate) fn run_evidence_id(run_id: &str) -> String {
    format!("evidence:cron-run:{run_id}")
}

pub(crate) async fn list_schedule_records(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
) -> Result<Vec<CronScheduleRecord>, CapabilityError> {
    let listed = invoke_resource_capability(
        engine_host,
        parent,
        "resource::list",
        json!({"kind": "decision", "limit": CRON_RESOURCE_TRUTH_SCAN_LIMIT}),
        "list:schedules",
        "resource.read",
    )
    .await?;
    let mut records = Vec::new();
    for resource in listed
        .get("resources")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
    {
        if resource.get("lifecycle").and_then(Value::as_str) == Some("archived") {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        if !resource_id.starts_with("decision:cron-schedule:") {
            continue;
        }
        let Some(record) = inspect_schedule_record(engine_host, parent, resource_id).await? else {
            continue;
        };
        records.push(record);
    }
    records.sort_by(|a, b| {
        a.job
            .name
            .cmp(&b.job.name)
            .then_with(|| a.job.id.cmp(&b.job.id))
    });
    Ok(records)
}

pub(crate) async fn inspect_schedule_record(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    resource_id: &str,
) -> Result<Option<CronScheduleRecord>, CapabilityError> {
    let inspected = invoke_resource_capability(
        engine_host,
        parent,
        "resource::inspect",
        json!({"resourceId": resource_id}),
        &format!("inspect:schedule:{}", short_hash(resource_id)),
        "resource.read",
    )
    .await?;
    let Some(inspection) = inspected.get("inspection").filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    if inspection
        .get("resource")
        .and_then(|resource| resource.get("kind"))
        .and_then(Value::as_str)
        != Some("decision")
    {
        return Ok(None);
    }
    if inspection
        .get("resource")
        .and_then(|resource| resource.get("lifecycle"))
        .and_then(Value::as_str)
        == Some("archived")
    {
        return Ok(None);
    }
    let Some((version_id, payload)) = current_version_payload(inspection) else {
        return Ok(None);
    };
    let decision_type = payload
        .get("metadata")
        .and_then(|metadata| metadata.get("decisionType"))
        .and_then(Value::as_str);
    if decision_type != Some(CRON_SCHEDULE_DECISION_TYPE) {
        return Ok(None);
    }
    if payload.get("status").and_then(Value::as_str) == Some("deleted") {
        return Ok(None);
    }
    let job: CronJob = serde_json::from_value(payload.get("job").cloned().ok_or_else(|| {
        CapabilityError::Custom {
            code: "CRON_SCHEDULE_TRUTH_INVALID".to_owned(),
            message: format!("cron schedule decision {resource_id} is missing job payload"),
            details: None,
        }
    })?)
    .map_err(|error| CapabilityError::Custom {
        code: "CRON_SCHEDULE_TRUTH_INVALID".to_owned(),
        message: format!("cron schedule decision {resource_id} has invalid job payload: {error}"),
        details: None,
    })?;
    Ok(Some(CronScheduleRecord {
        resource_id: resource_id.to_owned(),
        version_id,
        job,
    }))
}

pub(crate) async fn name_exists(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    name: &str,
    excluding_job_id: Option<&str>,
) -> Result<bool, CapabilityError> {
    Ok(list_schedule_records(engine_host, parent)
        .await?
        .into_iter()
        .any(|record| record.job.name == name && excluding_job_id != Some(record.job.id.as_str())))
}

pub(crate) async fn list_run_evidence(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    job_id: &str,
    status_filter: Option<&str>,
    limit: u32,
    offset: u32,
) -> Result<(Vec<Value>, u32), CapabilityError> {
    let listed = invoke_resource_capability(
        engine_host,
        parent,
        "resource::list",
        json!({"kind": "evidence", "limit": CRON_RESOURCE_TRUTH_SCAN_LIMIT}),
        &format!("list:runs:{job_id}"),
        "resource.read",
    )
    .await?;
    let mut runs = Vec::new();
    for resource in listed
        .get("resources")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
    {
        if resource.get("lifecycle").and_then(Value::as_str) == Some("archived") {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        if !resource_id.starts_with("evidence:cron-run:") {
            continue;
        }
        let inspected = invoke_resource_capability(
            engine_host,
            parent,
            "resource::inspect",
            json!({"resourceId": resource_id}),
            &format!("inspect:run:{}", short_hash(resource_id)),
            "resource.read",
        )
        .await?;
        let Some(inspection) = inspected.get("inspection").filter(|value| !value.is_null()) else {
            continue;
        };
        let Some((_version, payload)) = current_version_payload(inspection) else {
            continue;
        };
        let metadata = payload
            .get("metadata")
            .cloned()
            .unwrap_or_else(|| json!({}));
        if metadata.get("evidenceType").and_then(Value::as_str) != Some(CRON_RUN_EVIDENCE_TYPE) {
            continue;
        }
        if metadata.get("cronJobId").and_then(Value::as_str) != Some(job_id) {
            continue;
        }
        let Some(run) = metadata.get("run").cloned() else {
            continue;
        };
        if let Some(status) = status_filter
            && run.get("status").and_then(Value::as_str) != Some(status)
        {
            continue;
        }
        let mut projected = run;
        projected["evidenceResourceId"] = json!(resource_id);
        runs.push(projected);
    }
    runs.sort_by(|a, b| {
        b.get("startedAt")
            .and_then(Value::as_str)
            .cmp(&a.get("startedAt").and_then(Value::as_str))
    });
    let total = runs.len() as u32;
    let start = offset as usize;
    let end = start.saturating_add(limit as usize).min(runs.len());
    let page = if start >= runs.len() {
        Vec::new()
    } else {
        runs[start..end].to_vec()
    };
    Ok((page, total))
}

pub(crate) async fn create_schedule_decision(
    engine_host: &EngineHostHandle,
    parent: &Invocation,
    job: &CronJob,
) -> Result<(String, String, Vec<Value>), CapabilityError> {
    let resource_id = schedule_decision_id(&job.id);
    let value = invoke_resource_capability(
        engine_host,
        Some(parent),
        "decision::create",
        json!({
            "resourceId": resource_id,
            "scope": scope_name(job),
            "workspaceId": job.workspace_id,
            "payload": schedule_payload(job, schedule_status(job))
        }),
        &format!("create:schedule:{}", job.id),
        "resource.write",
    )
    .await?;
    let version_id = value
        .get("resource")
        .and_then(|resource| resource.get("currentVersionId"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    Ok((resource_id, version_id, resource_refs(&value)))
}

pub(crate) async fn update_schedule_decision(
    engine_host: &EngineHostHandle,
    parent: &Invocation,
    record: &CronScheduleRecord,
    job: &CronJob,
) -> Result<Vec<Value>, CapabilityError> {
    let value = invoke_resource_capability(
        engine_host,
        Some(parent),
        "resource::update",
        json!({
            "resourceId": record.resource_id,
            "expectedCurrentVersionId": record.version_id,
            "lifecycle": "final",
            "payload": schedule_payload(job, schedule_status(job))
        }),
        &format!("update:schedule:{}", job.id),
        "resource.write",
    )
    .await?;
    Ok(resource_refs(&value))
}

pub(crate) async fn archive_schedule_decision(
    engine_host: &EngineHostHandle,
    parent: &Invocation,
    record: &CronScheduleRecord,
) -> Result<Vec<Value>, CapabilityError> {
    let value = invoke_resource_capability(
        engine_host,
        Some(parent),
        "resource::update",
        json!({
            "resourceId": record.resource_id,
            "expectedCurrentVersionId": record.version_id,
            "lifecycle": "archived",
            "payload": schedule_payload(&record.job, "deleted")
        }),
        &format!("archive:schedule:{}", record.job.id),
        "resource.write",
    )
    .await?;
    Ok(resource_refs(&value))
}

pub(crate) async fn set_schedule_enabled(
    engine_host: &EngineHostHandle,
    job_id: &str,
    enabled: bool,
    reason: &str,
) -> Result<(), CronError> {
    let resource_id = schedule_decision_id(job_id);
    let Some(record) = inspect_schedule_record_for_cron(engine_host, &resource_id).await? else {
        return Ok(());
    };
    if record.job.enabled == enabled {
        return Ok(());
    }
    let mut job = record.job.clone();
    job.enabled = enabled;
    job.updated_at = Utc::now();
    let value = invoke_resource_capability_for_cron(
        engine_host,
        "resource::update",
        json!({
            "resourceId": record.resource_id,
            "expectedCurrentVersionId": record.version_id,
            "lifecycle": "final",
            "payload": schedule_payload_with_reason(&job, schedule_status(&job), reason)
        }),
        &format!("set-enabled:{job_id}:{enabled}:{}", short_hash(reason)),
        "resource.write",
    )
    .await?;
    if value
        .get("resourceRefs")
        .and_then(Value::as_array)
        .is_none()
    {
        return Err(CronError::Execution(
            "cron schedule enabled update did not return resourceRefs".to_owned(),
        ));
    }
    Ok(())
}

pub(crate) async fn attach_run_evidence(
    engine_host: &EngineHostHandle,
    job: &CronJob,
    run: &CronRun,
) -> Result<(), CronError> {
    let target_resource_id = schedule_decision_id(&job.id);
    let value = invoke_resource_capability_for_cron(
        engine_host,
        "evidence::attach",
        json!({
            "resourceId": run_evidence_id(&run.id),
            "targetResourceId": target_resource_id,
            "relation": "evidence_for",
            "scope": scope_name(job),
            "workspaceId": job.workspace_id,
            "payload": {
                "summary": format!("Cron run {} for {} ended as {}", run.id, job.name, run.status.as_str()),
                "source": "cron",
                "resourceRef": schedule_decision_id(&job.id),
                "metadata": {
                    "evidenceType": CRON_RUN_EVIDENCE_TYPE,
                    "cronJobId": job.id,
                    "cronJobName": job.name,
                    "run": bounded_run_payload(run),
                    "recordedAt": Utc::now()
                }
            },
            "metadata": {
                "relation": "cron_run",
                "cronJobId": job.id,
                "cronRunId": run.id
            }
        }),
        &format!("evidence:run:{}", run.id),
        "resource.write",
    )
    .await?;
    if value
        .get("resourceRefs")
        .and_then(Value::as_array)
        .is_none()
    {
        return Err(CronError::Execution(
            "cron run evidence did not return resourceRefs".to_owned(),
        ));
    }
    Ok(())
}

fn schedule_payload(job: &CronJob, status: &str) -> Value {
    schedule_payload_with_reason(job, status, "schedule definition updated")
}

fn schedule_payload_with_reason(job: &CronJob, status: &str, reason: &str) -> Value {
    json!({
        "status": status,
        "summary": job.name,
        "job": job,
        "metadata": {
            "decisionType": CRON_SCHEDULE_DECISION_TYPE,
            "cronJobId": job.id,
            "payloadKind": job.payload.kind_name(),
            "enabled": job.enabled,
            "updatedAt": job.updated_at,
            "reason": reason
        }
    })
}

fn schedule_status(job: &CronJob) -> &'static str {
    if job.enabled { "active" } else { "disabled" }
}

fn bounded_run_payload(run: &CronRun) -> Value {
    let output = run.output.as_deref().map(|output| {
        const MAX_PREVIEW: usize = 8_192;
        if output.len() > MAX_PREVIEW {
            let preview: String = output.chars().take(MAX_PREVIEW).collect();
            format!("{preview}…")
        } else {
            output.to_owned()
        }
    });
    json!({
        "id": run.id,
        "jobId": run.job_id,
        "jobName": run.job_name,
        "status": run.status,
        "startedAt": run.started_at,
        "completedAt": run.completed_at,
        "durationMs": run.duration_ms,
        "output": output,
        "outputTruncated": run.output_truncated || run.output.as_ref().is_some_and(|value| value.len() > 8_192),
        "error": run.error,
        "exitCode": run.exit_code,
        "attempt": run.attempt,
        "sessionId": run.session_id,
        "modelRouting": run.model_routing,
        "deliveryStatus": run.delivery_status
    })
}

fn current_version_payload(inspection: &Value) -> Option<(String, Value)> {
    let current = inspection
        .get("resource")?
        .get("currentVersionId")?
        .as_str()?;
    let version = inspection
        .get("versions")?
        .as_array()?
        .iter()
        .find(|version| version.get("versionId").and_then(Value::as_str) == Some(current))?;
    Some((current.to_owned(), version.get("payload")?.clone()))
}

async fn inspect_schedule_record_for_cron(
    engine_host: &EngineHostHandle,
    resource_id: &str,
) -> Result<Option<CronScheduleRecord>, CronError> {
    let inspected = invoke_resource_capability_for_cron(
        engine_host,
        "resource::inspect",
        json!({"resourceId": resource_id}),
        &format!("inspect:schedule:{}", short_hash(resource_id)),
        "resource.read",
    )
    .await?;
    let Some(inspection) = inspected.get("inspection").filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    if inspection
        .get("resource")
        .and_then(|resource| resource.get("kind"))
        .and_then(Value::as_str)
        != Some("decision")
    {
        return Ok(None);
    }
    if inspection
        .get("resource")
        .and_then(|resource| resource.get("lifecycle"))
        .and_then(Value::as_str)
        == Some("archived")
    {
        return Ok(None);
    }
    let Some((version_id, payload)) = current_version_payload(inspection) else {
        return Ok(None);
    };
    if payload
        .get("metadata")
        .and_then(|metadata| metadata.get("decisionType"))
        .and_then(Value::as_str)
        != Some(CRON_SCHEDULE_DECISION_TYPE)
    {
        return Ok(None);
    }
    if payload.get("status").and_then(Value::as_str) == Some("deleted") {
        return Ok(None);
    }
    let job: CronJob = serde_json::from_value(payload.get("job").cloned().ok_or_else(|| {
        CronError::Execution(format!(
            "cron schedule decision {resource_id} is missing job payload"
        ))
    })?)
    .map_err(|error| {
        CronError::Execution(format!(
            "cron schedule decision {resource_id} has invalid job payload: {error}"
        ))
    })?;
    Ok(Some(CronScheduleRecord {
        resource_id: resource_id.to_owned(),
        version_id,
        job,
    }))
}

fn scope_name(job: &CronJob) -> &'static str {
    if job.workspace_id.is_some() {
        "workspace"
    } else {
        "system"
    }
}

fn resource_refs(value: &Value) -> Vec<Value> {
    value
        .get("resourceRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

async fn invoke_resource_capability(
    engine_host: &EngineHostHandle,
    parent: Option<&Invocation>,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
    scope: &str,
) -> Result<Value, CapabilityError> {
    let mut causal =
        cron_causal_context(parent, idempotency_label, scope).map_err(engine_capability_error)?;
    if let Some(parent) = parent {
        causal.parent_invocation_id = Some(parent.id.clone());
        if let Some(session_id) = &parent.causal_context.session_id {
            causal = causal.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &parent.causal_context.workspace_id {
            causal = causal.with_workspace_id(workspace_id.clone());
        }
    }
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(engine_capability_error)?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_capability_error(error));
    }
    result.value.ok_or_else(|| CapabilityError::Internal {
        message: format!("{function_id} returned no value"),
    })
}

async fn invoke_resource_capability_for_cron(
    engine_host: &EngineHostHandle,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
    scope: &str,
) -> Result<Value, CronError> {
    let causal = cron_causal_context(None, idempotency_label, scope)
        .map_err(|error| CronError::Execution(error.to_string()))?;
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id)
                .map_err(|error| CronError::Execution(error.to_string()))?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(CronError::Execution(error.to_string()));
    }
    result
        .value
        .ok_or_else(|| CronError::Execution(format!("{function_id} returned no value")))
}

fn cron_causal_context(
    parent: Option<&Invocation>,
    idempotency_label: &str,
    scope: &str,
) -> crate::engine::Result<CausalContext> {
    let trace = parent
        .map(|invocation| invocation.causal_context.trace_id.clone())
        .unwrap_or(TraceId::new("cron-resource-truth")?);
    let mut context = CausalContext::new(
        ActorId::new("system:cron")?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system")?,
        trace,
    )
    .with_scope(scope)
    .with_idempotency_key(format!(
        "cron:{}:{idempotency_label}",
        parent
            .map(|invocation| invocation.id.as_str())
            .unwrap_or("background")
    ));
    if parent.is_none() {
        context = context.with_session_id("system:cron");
    }
    Ok(context)
}

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "CRON_RESOURCE_TRUTH_OPERATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn short_hash(value: &str) -> String {
    use sha2::{Digest as _, Sha256};

    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    hex::encode(hasher.finalize())[..16].to_owned()
}
