//! Cron workflow operations.
use super::*;

pub(crate) async fn cron_run_value(
    payload: &Value,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let job_id = require_string_param(Some(payload), "jobId")?;
    let _job = sched
        .get_job(&job_id)
        .ok_or_else(|| CapabilityError::NotFound {
            code: "NOT_FOUND".into(),
            message: format!("Job not found: {job_id}"),
        })?;
    let now = Utc::now();
    let _ = crate::cron::store::update_next_run_at(sched.pool(), &job_id, Some(now));
    if let Some(mut runtime) = sched.get_runtime_state(&job_id) {
        runtime.next_run_at = Some(now);
        sched.update_runtime(runtime);
    }
    sched.reschedule_notify().notify_one();
    publish_cron_stream(
        invocation,
        deps,
        "triggered",
        &job_id,
        Some(now.to_rfc3339()),
    )
    .await;
    Ok(json!({
        "triggered": true,
        "jobId": job_id,
    }))
}

pub(crate) async fn cron_scheduled_fire_value(
    payload: &Value,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let job_id = require_string_param(Some(payload), "jobId")?;
    let scheduled_at = payload
        .get("scheduledAt")
        .and_then(Value::as_str)
        .map(|value| {
            chrono::DateTime::parse_from_rfc3339(value)
                .map(|dt| dt.with_timezone(&Utc))
                .map_err(|error| CapabilityError::InvalidParams {
                    message: format!("Invalid scheduledAt: {error}"),
                })
        })
        .transpose()?
        .or_else(|| {
            payload
                .get("scheduledAt")
                .and_then(Value::as_i64)
                .and_then(chrono::DateTime::<Utc>::from_timestamp_millis)
        })
        .unwrap_or_else(Utc::now);
    let job = sched
        .get_job(&job_id)
        .ok_or_else(|| CapabilityError::NotFound {
            code: "NOT_FOUND".into(),
            message: format!("Job not found: {job_id}"),
        })?;
    let outcome = sched
        .start_due_job(job, scheduled_at)
        .await
        .map_err(map_cron_error)?;
    publish_cron_stream(
        invocation,
        deps,
        "scheduled_fire",
        &job_id,
        Some(scheduled_at.to_rfc3339()),
    )
    .await;
    match outcome {
        crate::cron::scheduler::CronScheduledFireOutcome::Started {
            job_id,
            next_run_at,
        } => Ok(json!({
            "started": true,
            "skipped": false,
            "jobId": job_id,
            "scheduledAt": scheduled_at,
            "nextRunAt": next_run_at,
        })),
        crate::cron::scheduler::CronScheduledFireOutcome::SkippedOverlap {
            job_id,
            next_run_at,
        } => Ok(json!({
            "started": false,
            "skipped": true,
            "reason": "overlap",
            "jobId": job_id,
            "scheduledAt": scheduled_at,
            "nextRunAt": next_run_at,
        })),
    }
}

pub(crate) async fn cron_status_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    Ok(json!({
        "running": true,
        "jobCount": sched.job_count(),
        "activeRuns": sched.active_run_count(),
        "nextWakeup": sched.next_wakeup(),
        "executionLimit": 10,
    }))
}

pub(crate) async fn cron_get_runs_value(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let job_id = require_string_param(Some(payload), "jobId")?;
    let limit = opt_u64(Some(payload), "limit", 20) as u32;
    let offset = opt_u64(Some(payload), "offset", 0) as u32;
    let status_filter = payload.get("status").and_then(Value::as_str);
    let (runs, total) =
        crate::cron::store::get_runs(sched.pool(), Some(&job_id), status_filter, limit, offset)
            .map_err(map_cron_error)?;
    Ok(json!({
        "runs": to_json_value(&runs)?,
        "total": total,
    }))
}
