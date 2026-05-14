//! Job workflow operations.
use super::Invocation;
use crate::domains::capability_support::implementations::traits::WaitMode;
use crate::domains::job::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(crate) fn job_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    if let Some(ref jm) = deps.job_manager {
        Ok(json!({ "jobs": jm.list_jobs(&session_id) }))
    } else if let Some(ref pm) = deps.process_manager {
        Ok(json!({ "jobs": pm.list_processes(&session_id) }))
    } else {
        Ok(json!({ "jobs": [] }))
    }
}

pub(crate) async fn job_wait_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let job_ids = params
        .and_then(|p| p.get("jobIds"))
        .and_then(Value::as_array)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "Missing required param: jobIds".to_owned(),
        })?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: "jobIds must contain only strings".to_owned(),
                })
        })
        .collect::<Result<Vec<_>, _>>()?;
    if job_ids.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "jobIds must not be empty".to_owned(),
        });
    }
    let timeout_ms = params
        .and_then(|p| p.get("timeoutMs"))
        .and_then(Value::as_u64)
        .unwrap_or(300_000);
    let mode = match params
        .and_then(|p| p.get("mode"))
        .and_then(Value::as_str)
        .unwrap_or("all")
    {
        "all" => WaitMode::All,
        "any" => WaitMode::Any,
        other => {
            return Err(CapabilityError::InvalidParams {
                message: format!("mode must be 'all' or 'any', got '{other}'"),
            });
        }
    };
    let manager = deps
        .job_manager
        .as_ref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Job manager not available".to_owned(),
        })?;
    let results = manager
        .wait_for_jobs(&job_ids, mode, timeout_ms)
        .await
        .map_err(|error| CapabilityError::Internal {
            message: format!("Failed to wait for jobs: {error}"),
        })?;
    Ok(json!({
        "sessionId": session_id,
        "jobIds": job_ids,
        "results": results,
        "complete": !results.is_empty()
    }))
}

pub(crate) fn job_stream_output_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let job_id = require_string_param(params, "jobId")?;
    let offset = params
        .and_then(|p| p.get("offset"))
        .and_then(Value::as_u64)
        .unwrap_or(0) as usize;
    let registry =
        deps.output_buffer_registry
            .as_ref()
            .ok_or_else(|| CapabilityError::Internal {
                message: "Output buffer registry not available".into(),
            })?;
    let (buffer, invocation_id) =
        registry
            .get(&job_id)
            .ok_or_else(|| CapabilityError::NotFound {
                code: "JOB_OUTPUT_NOT_FOUND".to_owned(),
                message: format!("No output buffer for job {job_id}"),
            })?;
    let (chunks, next_offset) = buffer.read_from(offset);
    Ok(json!({
        "jobId": job_id,
        "invocationId": invocation_id,
        "chunks": chunks,
        "nextOffset": next_offset,
        "closed": buffer.is_closed(),
        "totalBytes": buffer.total_bytes(),
        "droppedChunks": buffer.dropped_chunks()
    }))
}

pub(crate) fn persist_user_action(
    event_store: &Arc<crate::domains::session::event_store::EventStore>,
    session_id: &str,
    job_id: &str,
    action: &str,
    label: &str,
) {
    match event_store.append(&crate::domains::session::event_store::AppendOptions {
        session_id,
        event_type: crate::domains::session::event_store::EventType::NotificationUserJobAction,
        payload: json!({
            "jobId": job_id,
            "action": action,
            "label": label,
        }),
        parent_id: None,
        sequence: None,
    }) {
        Ok(event) => tracing::info!(
            job_id,
            action,
            session_id,
            event_id = %event.id,
            "persisted user job action"
        ),
        Err(error) => tracing::error!(
            job_id,
            action,
            session_id,
            error = %error,
            "failed to persist user job action"
        ),
    }
}

pub(crate) async fn publish_job_stream(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    job_id: &str,
    action: &str,
) {
    crate::domains::job::stream::JobStreamPublisher::new(&deps.engine_host)
        .status(invocation, session_id, job_id, action)
        .await;
}
