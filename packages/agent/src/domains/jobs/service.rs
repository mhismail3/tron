use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineHostHandle, EngineResource, EngineResourceInspection,
    EngineResourceScope, EngineResourceVersion, LinkResources, ListResources, UpdateResource,
    WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, internal, invalid_params};
use super::runtime::{JobRuntime, SpawnProcessRequest};
use super::support::{
    current_payload, list_limit, max_output_bytes, optional_string, optional_u64,
    publish_lifecycle_event, replay_refs, resource_policy, resource_ref, resource_scope,
    sha256_hex, timeout_ms, to_value, trace_refs, trusted_working_directory, version_ref,
};
use super::types::{
    EXECUTION_OUTPUT_KIND, EXECUTION_OUTPUT_SCHEMA_ID, JOB_SCHEMA_VERSION, JobAuthorityRecord,
    JobCancellationRecord, JobCommandRecord, JobLimitsRecord, JobOutputRef, JobProcessRecord,
    JobRunOutcome, JobState, JobTerminalRecord, JobWorkingDirectory,
};
use super::{JOB_PROCESS_KIND, JOB_PROCESS_SCHEMA_ID, WORKER};

pub(crate) async fn start_job_value(
    engine_host: &EngineHostHandle,
    shutdown_coordinator: Option<
        std::sync::Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>,
    >,
    runtime: JobRuntime,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let command = super::support::required_string(payload, "command")?;
    if command.trim().is_empty() {
        return Err(invalid_params("job_start command must not be empty"));
    }
    let working_directory = trusted_working_directory(invocation)?;
    let grant = ensure_no_network_grant(engine_host, invocation).await?;
    let timeout_ms = timeout_ms(payload)?;
    let max_output_bytes = max_output_bytes(payload)?;
    let now = Utc::now();
    let job_resource_id = format!("job_process:{}", invocation.id.as_str());
    let retention = json!({
        "mode": "explicit",
        "cleanupAfterSeconds": optional_u64(payload, "cleanupAfterSeconds")?
    });
    let record = JobProcessRecord {
        schema_version: JOB_SCHEMA_VERSION.to_owned(),
        state: JobState::Running,
        command: JobCommandRecord {
            kind: "shell_command".to_owned(),
            command: command.clone(),
            working_directory: JobWorkingDirectory {
                root: "trusted_runtime_metadata".to_owned(),
                canonical_path: working_directory.display().to_string(),
            },
            network_policy: grant.network_policy.clone(),
        },
        authority: JobAuthorityRecord {
            actor_id: invocation.causal_context.actor_id.as_str().to_owned(),
            authority_grant_id: invocation
                .causal_context
                .authority_grant_id
                .as_str()
                .to_owned(),
            authority_scopes: invocation.causal_context.authority_scopes.clone(),
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
        },
        limits: JobLimitsRecord {
            timeout_ms,
            max_output_bytes,
        },
        retention,
        created_at: now,
        started_at: now,
        completed_at: None,
        cancellation: JobCancellationRecord {
            requested: false,
            requested_at: None,
            requested_by: None,
            reason: None,
        },
        terminal: None,
        output: None,
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        revision: 1,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(job_resource_id.clone()),
            kind: JOB_PROCESS_KIND.to_owned(),
            schema_id: Some(JOB_PROCESS_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(JobState::Running.as_str().to_owned()),
            policy: resource_policy(),
            initial_payload: Some(to_value(&record, "job process")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let job_version_id = resource
        .current_version_id
        .clone()
        .ok_or_else(|| internal("job process resource was created without an initial version"))?;

    let process_id = match runtime
        .spawn_process(SpawnProcessRequest {
            engine_host: engine_host.clone(),
            shutdown_coordinator,
            invocation: invocation.clone(),
            job_resource_id: job_resource_id.clone(),
            command,
            working_directory,
            timeout_ms,
            max_output_bytes,
        })
        .await
    {
        Ok(process_id) => process_id,
        Err(error) => {
            let outcome = JobRunOutcome {
                state: JobState::Failed,
                exit_code: None,
                timed_out: false,
                cancelled: false,
                stdout: String::new(),
                stderr: error.to_string(),
                stdout_truncated: false,
                stderr_truncated: false,
                duration_ms: 0,
                error: Some("process spawn failed".to_owned()),
            };
            let _ =
                finalize_job_from_runtime(engine_host, invocation, &job_resource_id, outcome).await;
            return Err(error);
        }
    };
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "jobs.started",
        json!({
            "jobResourceId": job_resource_id,
            "jobVersionId": job_version_id,
            "state": JobState::Running.as_str(),
            "processId": process_id,
            "resourceRefs": [resource_ref(&resource, "job_process")]
        }),
    )
    .await?;

    Ok(json!({
        "schemaVersion": JOB_SCHEMA_VERSION,
        "status": JobState::Running.as_str(),
        "jobResourceId": resource.resource_id,
        "jobVersionId": job_version_id,
        "streamCursor": cursor.0,
        "processId": process_id,
        "resourceRefs": [resource_ref(&resource, "job_process")]
    }))
}

pub(crate) async fn status_job_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let inspection = require_job(engine_host, invocation, payload).await?;
    let (version_id, record) = job_record(&inspection)?;
    Ok(json!({
        "schemaVersion": JOB_SCHEMA_VERSION,
        "status": record.state.as_str(),
        "job": job_summary(&inspection.resource, &version_id, &record),
        "resourceRefs": [resource_ref(&inspection.resource, "job_process")]
    }))
}

pub(crate) async fn list_jobs_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let lifecycle = optional_string(payload, "state")?;
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(JOB_PROCESS_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle,
            limit: list_limit(payload)?,
        })
        .await
        .map_err(engine_error)?;
    let mut jobs = Vec::new();
    for resource in resources {
        if let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            let (version_id, record) = job_record(&inspection)?;
            jobs.push(job_summary(&inspection.resource, &version_id, &record));
        }
    }
    Ok(json!({
        "schemaVersion": JOB_SCHEMA_VERSION,
        "status": "ok",
        "jobs": jobs
    }))
}

pub(crate) async fn log_job_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let inspection = require_job(engine_host, invocation, payload).await?;
    let (version_id, record) = job_record(&inspection)?;
    Ok(json!({
        "schemaVersion": JOB_SCHEMA_VERSION,
        "status": record.state.as_str(),
        "jobResourceId": inspection.resource.resource_id,
        "jobVersionId": version_id,
        "stdoutPreview": record.output.as_ref().map(|output| output.stdout_preview.as_str()).unwrap_or(""),
        "stderrPreview": record.output.as_ref().map(|output| output.stderr_preview.as_str()).unwrap_or(""),
        "outputResourceId": record.output.as_ref().map(|output| output.output_resource_id.as_str()),
        "outputVersionId": record.output.as_ref().map(|output| output.output_version_id.as_str()),
        "outputTruncated": record.output.as_ref().is_some_and(|output| output.output_truncated),
        "resourceRefs": [resource_ref(&inspection.resource, "job_process")]
    }))
}

pub(crate) async fn cancel_job_value(
    engine_host: &EngineHostHandle,
    runtime: JobRuntime,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let inspection = require_job(engine_host, invocation, payload).await?;
    let (current_version_id, mut record) = job_record(&inspection)?;
    if record.state.is_terminal() {
        return Ok(json!({
            "schemaVersion": JOB_SCHEMA_VERSION,
            "status": "already_terminal",
            "state": record.state.as_str(),
            "jobResourceId": inspection.resource.resource_id,
            "jobVersionId": current_version_id,
            "idempotent": true,
            "resourceRefs": [resource_ref(&inspection.resource, "job_process")]
        }));
    }
    record.state = JobState::Cancelled;
    record.completed_at = Some(Utc::now());
    record.cancellation = JobCancellationRecord {
        requested: true,
        requested_at: record.completed_at,
        requested_by: Some(invocation.causal_context.actor_id.as_str().to_owned()),
        reason: optional_string(payload, "reason")?,
    };
    record.terminal = Some(JobTerminalRecord {
        status: JobState::Cancelled.as_str().to_owned(),
        exit_code: None,
        timed_out: false,
        cancelled: true,
        error: Some("process cancellation requested".to_owned()),
    });
    record.revision += 1;
    let version = update_job_record(
        engine_host,
        invocation,
        &inspection.resource.resource_id,
        Some(current_version_id.clone()),
        &record,
    )
    .await?;
    let runtime_had_job = runtime.cancel(&inspection.resource.resource_id).await;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "jobs.cancelled",
        json!({
            "jobResourceId": inspection.resource.resource_id,
            "jobVersionId": version.version_id,
            "state": JobState::Cancelled.as_str(),
            "runtimeHadJob": runtime_had_job,
            "reason": record.cancellation.reason.clone()
        }),
    )
    .await?;

    Ok(json!({
        "schemaVersion": JOB_SCHEMA_VERSION,
        "status": JobState::Cancelled.as_str(),
        "jobResourceId": inspection.resource.resource_id,
        "jobVersionId": version.version_id,
        "streamCursor": cursor.0,
        "idempotent": false,
        "runtimeHadJob": runtime_had_job,
        "resourceRefs": [version_ref(&inspection.resource, &version, "job_process")]
    }))
}

pub(crate) async fn cleanup_jobs_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let older_than = optional_u64(payload, "olderThanSeconds")?.unwrap_or(0);
    let cutoff = Utc::now() - ChronoDuration::seconds(older_than as i64);
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(JOB_PROCESS_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: None,
            limit: list_limit(payload)?,
        })
        .await
        .map_err(engine_error)?;
    let mut archived = Vec::new();
    for resource in resources {
        let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        let (current_version_id, mut record) = job_record(&inspection)?;
        if !record.state.is_terminal() || record.state == JobState::Archived {
            continue;
        }
        if record
            .completed_at
            .as_ref()
            .is_some_and(|completed_at| completed_at > &cutoff)
        {
            continue;
        }
        record.state = JobState::Archived;
        record.revision += 1;
        let version = update_job_record(
            engine_host,
            invocation,
            &inspection.resource.resource_id,
            Some(current_version_id),
            &record,
        )
        .await?;
        archived.push(json!({
            "jobResourceId": inspection.resource.resource_id,
            "jobVersionId": version.version_id
        }));
        let _ = publish_lifecycle_event(
            engine_host,
            invocation,
            "jobs.archived",
            json!({
                "jobResourceId": inspection.resource.resource_id,
                "jobVersionId": version.version_id
            }),
        )
        .await;
    }

    Ok(json!({
        "schemaVersion": JOB_SCHEMA_VERSION,
        "status": "ok",
        "archivedCount": archived.len(),
        "archived": archived
    }))
}

pub(super) async fn finalize_job_from_runtime(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    job_resource_id: &str,
    outcome: JobRunOutcome,
) -> Result<(), CapabilityError> {
    let Some(inspection) = engine_host
        .inspect_resource(job_resource_id)
        .await
        .map_err(engine_error)?
    else {
        return Err(invalid_params(format!(
            "job resource {job_resource_id} was not found"
        )));
    };
    let (current_version_id, mut record) = job_record(&inspection)?;
    if record.state.is_terminal() {
        return Ok(());
    }

    let output_bytes = format!("{}\n{}", outcome.stdout, outcome.stderr).into_bytes();
    let output_payload = json!({
        "schemaVersion": "tron.jobs.execution_output.v1",
        "stdoutPreview": outcome.stdout.clone(),
        "stderrPreview": outcome.stderr.clone(),
        "exitCode": outcome.exit_code.unwrap_or(-1),
        "exitCodeKnown": outcome.exit_code.is_some(),
        "durationMs": outcome.duration_ms,
        "timedOut": outcome.timed_out,
        "outputTruncated": outcome.stdout_truncated || outcome.stderr_truncated,
        "redactionPolicy": {
            "mode": "bounded_preview",
            "maxOutputBytes": record.limits.max_output_bytes
        },
        "metadata": {
            "jobResourceId": job_resource_id,
            "commandKind": record.command.kind.clone(),
            "networkPolicy": record.command.network_policy.clone(),
            "stdoutTruncated": outcome.stdout_truncated,
            "stderrTruncated": outcome.stderr_truncated,
            "cancelled": outcome.cancelled,
            "error": outcome.error.clone()
        }
    });
    let output_resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!("execution_output:{job_resource_id}")),
            kind: EXECUTION_OUTPUT_KIND.to_owned(),
            schema_id: Some(EXECUTION_OUTPUT_SCHEMA_ID.to_owned()),
            scope: inspection.resource.scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("retained".to_owned()),
            policy: json!({
                "owner": WORKER,
                "retention": "job_lifecycle",
                "redaction": {"mode": "bounded_preview"}
            }),
            initial_payload: Some(output_payload),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let output_version_id = output_resource
        .current_version_id
        .clone()
        .ok_or_else(|| internal("execution output resource was created without a version"))?;
    let output_version = output_resource_version(engine_host, &output_resource).await?;
    engine_host
        .link_resources(LinkResources {
            source_resource_id: inspection.resource.resource_id.clone(),
            target_resource_id: output_resource.resource_id.clone(),
            relation: "produced_output".to_owned(),
            metadata: json!({
                "state": outcome.state.as_str(),
                "durationMs": outcome.duration_ms
            }),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;

    record.state = outcome.state.clone();
    record.completed_at = Some(Utc::now());
    record.terminal = Some(JobTerminalRecord {
        status: outcome.state.as_str().to_owned(),
        exit_code: outcome.exit_code,
        timed_out: outcome.timed_out,
        cancelled: outcome.cancelled,
        error: outcome.error.clone(),
    });
    record.output = Some(JobOutputRef {
        output_resource_id: output_resource.resource_id.clone(),
        output_version_id,
        content_hash: sha256_hex(&output_bytes),
        stdout_preview: outcome.stdout,
        stderr_preview: outcome.stderr,
        output_truncated: outcome.stdout_truncated || outcome.stderr_truncated,
        duration_ms: outcome.duration_ms,
        exit_code: outcome.exit_code,
    });
    record.revision += 1;
    let job_version = update_job_record(
        engine_host,
        invocation,
        &inspection.resource.resource_id,
        Some(current_version_id),
        &record,
    )
    .await?;
    let event_type = match &record.state {
        JobState::Completed => "jobs.completed",
        JobState::Failed => "jobs.failed",
        JobState::TimedOut => "jobs.timed_out",
        JobState::Cancelled => "jobs.cancelled",
        JobState::Running | JobState::Archived => "jobs.updated",
    };
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        event_type,
        json!({
            "jobResourceId": inspection.resource.resource_id,
            "jobVersionId": job_version.version_id,
            "outputResourceId": output_resource.resource_id,
            "outputVersionId": output_version.version_id,
            "state": record.state.as_str(),
            "exitCode": record.terminal.as_ref().and_then(|terminal| terminal.exit_code),
            "durationMs": record.output.as_ref().map(|output| output.duration_ms),
            "outputTruncated": record.output.as_ref().is_some_and(|output| output.output_truncated)
        }),
    )
    .await;
    Ok(())
}

async fn ensure_no_network_grant(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
) -> Result<crate::engine::EngineGrant, CapabilityError> {
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(|error| internal(format!("inspect job authority grant: {error}")))?
        .ok_or_else(|| invalid_params("job_start authority grant was not found"))?;
    if grant.network_policy != "none" {
        return Err(invalid_params(
            "job_start requires an authority grant with networkPolicy none",
        ));
    }
    Ok(grant)
}

async fn require_job(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<EngineResourceInspection, CapabilityError> {
    let job_resource_id = super::support::required_string(payload, "jobResourceId")?;
    let inspection = engine_host
        .inspect_resource(&job_resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("job resource {job_resource_id} was not found")))?;
    if inspection.resource.kind != JOB_PROCESS_KIND {
        return Err(invalid_params(format!(
            "resource {job_resource_id} is not a job_process resource"
        )));
    }
    ensure_scope(invocation, &inspection.resource.scope)?;
    Ok(inspection)
}

fn ensure_scope(
    invocation: &crate::engine::Invocation,
    resource_scope_value: &EngineResourceScope,
) -> Result<(), CapabilityError> {
    let expected = resource_scope(invocation);
    if &expected != resource_scope_value {
        return Err(invalid_params("job resource is outside invocation scope"));
    }
    Ok(())
}

fn job_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, JobProcessRecord), CapabilityError> {
    let (version_id, payload) =
        current_payload(inspection).ok_or_else(|| invalid_params("job resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| internal(format!("decode job resource payload: {error}")))?;
    Ok((version_id, record))
}

async fn update_job_record(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    job_resource_id: &str,
    expected_current_version_id: Option<String>,
    record: &JobProcessRecord,
) -> Result<EngineResourceVersion, CapabilityError> {
    engine_host
        .update_resource(UpdateResource {
            resource_id: job_resource_id.to_owned(),
            expected_current_version_id,
            lifecycle: Some(record.state.as_str().to_owned()),
            payload: to_value(record, "job process update")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

async fn output_resource_version(
    engine_host: &EngineHostHandle,
    output_resource: &EngineResource,
) -> Result<EngineResourceVersion, CapabilityError> {
    let inspection = engine_host
        .inspect_resource(&output_resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| internal("execution output resource disappeared after creation"))?;
    let version_id = output_resource
        .current_version_id
        .as_ref()
        .ok_or_else(|| internal("execution output resource has no current version"))?;
    inspection
        .versions
        .into_iter()
        .find(|version| &version.version_id == version_id)
        .ok_or_else(|| internal("execution output current version was not found"))
}

fn job_summary(resource: &EngineResource, version_id: &str, record: &JobProcessRecord) -> Value {
    json!({
        "jobResourceId": resource.resource_id,
        "jobVersionId": version_id,
        "state": record.state.as_str(),
        "command": {
            "kind": record.command.kind.clone(),
            "workingDirectory": record.command.working_directory.canonical_path.clone(),
            "networkPolicy": record.command.network_policy.clone()
        },
        "limits": record.limits.clone(),
        "createdAt": record.created_at,
        "startedAt": record.started_at,
        "completedAt": record.completed_at,
        "cancellation": record.cancellation.clone(),
        "terminal": record.terminal.clone(),
        "output": record.output.clone(),
        "traceRefs": record.trace_refs.clone(),
        "replayRefs": record.replay_refs.clone(),
        "revision": record.revision
    })
}

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}
