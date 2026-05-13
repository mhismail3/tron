//! Cron workflow operations.
use super::Utc;
use super::publish_cron_stream;
use crate::domains::cron::Deps;
use crate::domains::cron::{project_cron_trigger, scheduler};
use crate::engine::Invocation;
use crate::shared::server::error_mapping::map_cron_error;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::errors::to_json_value;
use crate::shared::server::params::opt_array;
use crate::shared::server::params::opt_bool;
use crate::shared::server::params::require_param;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn cron_list_value(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let enabled_filter = opt_bool(Some(payload), "enabled");
    let tag_filter = opt_array(Some(payload), "tags").map(|arr| {
        arr.iter()
            .filter_map(|value| value.as_str().map(String::from))
            .collect::<Vec<_>>()
    });
    let workspace_filter = payload
        .get("workspaceId")
        .and_then(Value::as_str)
        .map(String::from);
    let filtered: Vec<_> = sched.with_jobs(|jobs| {
        jobs.values()
            .filter(|job| {
                if let Some(enabled) = enabled_filter
                    && job.enabled != enabled
                {
                    return false;
                }
                if let Some(ref tags) = tag_filter
                    && !tags.iter().any(|tag| job.tags.contains(tag))
                {
                    return false;
                }
                if let Some(ref workspace) = workspace_filter
                    && job.workspace_id.as_deref() != Some(workspace)
                {
                    return false;
                }
                true
            })
            .cloned()
            .collect()
    });
    let runtime_states: Vec<_> = filtered
        .iter()
        .filter_map(|job| sched.get_runtime_state(&job.id))
        .map(|state| {
            json!({
                "jobId": state.job_id,
                "nextRunAt": state.next_run_at,
                "lastRunAt": state.last_run_at,
                "consecutiveFailures": state.consecutive_failures,
                "runningSince": state.running_since,
            })
        })
        .collect();
    Ok(json!({
        "jobs": to_json_value(&filtered)?,
        "runtimeState": runtime_states,
    }))
}

pub(crate) async fn cron_get_value(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let job_id = require_string_param(Some(payload), "jobId")?;
    let job = sched
        .get_job(&job_id)
        .ok_or_else(|| CapabilityError::NotFound {
            code: "NOT_FOUND".into(),
            message: format!("Job not found: {job_id}"),
        })?;
    let runtime_state = sched.get_runtime_state(&job_id);
    let (recent_runs, _total) =
        crate::domains::cron::store::get_runs(sched.pool(), Some(&job_id), None, 10, 0)
            .map_err(map_cron_error)?;
    Ok(json!({
        "job": to_json_value(&job)?,
        "runtimeState": runtime_state.map(|state| json!({
            "jobId": state.job_id,
            "nextRunAt": state.next_run_at,
            "lastRunAt": state.last_run_at,
            "consecutiveFailures": state.consecutive_failures,
            "runningSince": state.running_since,
        })),
        "recentRuns": to_json_value(&recent_runs)?,
    }))
}

pub(crate) async fn cron_create_value(
    payload: &Value,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let job_param = require_param(Some(payload), "job")?;
    let name =
        job_param
            .get("name")
            .and_then(Value::as_str)
            .ok_or(CapabilityError::InvalidParams {
                message: "Missing required field: name".into(),
            })?;
    let schedule = serde_json::from_value(job_param.get("schedule").cloned().ok_or(
        CapabilityError::InvalidParams {
            message: "Missing required field: schedule".into(),
        },
    )?)
    .map_err(|error| CapabilityError::InvalidParams {
        message: format!("Invalid schedule: {error}"),
    })?;
    let payload_value = serde_json::from_value(job_param.get("payload").cloned().ok_or(
        CapabilityError::InvalidParams {
            message: "Missing required field: payload".into(),
        },
    )?)
    .map_err(|error| CapabilityError::InvalidParams {
        message: format!("Invalid payload: {error}"),
    })?;
    let delivery = job_param
        .get("delivery")
        .map(|value| serde_json::from_value(value.clone()))
        .transpose()
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid delivery: {error}"),
        })?
        .unwrap_or_default();
    let now = Utc::now();
    let job = crate::domains::cron::CronJob {
        id: format!("cron_{}", uuid::Uuid::now_v7()),
        name: name.to_owned(),
        description: job_param
            .get("description")
            .and_then(Value::as_str)
            .map(String::from),
        enabled: job_param
            .get("enabled")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        schedule,
        payload: payload_value,
        delivery,
        overlap_policy: job_param
            .get("overlapPolicy")
            .map(|value| serde_json::from_value(value.clone()))
            .transpose()
            .map_err(|error| CapabilityError::InvalidParams {
                message: format!("Invalid overlapPolicy: {error}"),
            })?
            .unwrap_or_default(),
        misfire_policy: job_param
            .get("misfirePolicy")
            .map(|value| serde_json::from_value(value.clone()))
            .transpose()
            .map_err(|error| CapabilityError::InvalidParams {
                message: format!("Invalid misfirePolicy: {error}"),
            })?
            .unwrap_or_default(),
        max_retries: job_param
            .get("maxRetries")
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
        auto_disable_after: job_param
            .get("autoDisableAfter")
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
        stuck_timeout_secs: job_param
            .get("stuckTimeoutSecs")
            .and_then(Value::as_u64)
            .unwrap_or(7200),
        tags: job_param
            .get("tags")
            .and_then(Value::as_array)
            .map(|tags| {
                tags.iter()
                    .filter_map(|value| value.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default(),
        capability_restrictions: job_param
            .get("capabilityRestrictions")
            .map(|value| serde_json::from_value(value.clone()))
            .transpose()
            .map_err(|error| CapabilityError::InvalidParams {
                message: format!("Invalid capabilityRestrictions: {error}"),
            })?,
        workspace_id: job_param
            .get("workspaceId")
            .and_then(Value::as_str)
            .map(String::from),
        created_at: now,
        updated_at: now,
    };
    crate::domains::cron::config::validate_job(&job).map_err(|error| {
        CapabilityError::InvalidParams {
            message: error.to_string(),
        }
    })?;
    let _guard = sched.config_lock().lock().await;
    if crate::domains::cron::store::name_exists(sched.pool(), &job.name, None)
        .map_err(map_cron_error)?
    {
        return Err(CapabilityError::Custom {
            code: "ALREADY_EXISTS".into(),
            message: format!("Job with name '{}' already exists", job.name),
            details: None,
        });
    }
    let mut config =
        crate::domains::cron::config::load_config(sched.config_path(), sched.backup_path())
            .map_err(map_cron_error)?;
    config.jobs.push(job.clone());
    crate::domains::cron::config::save_config(sched.config_path(), sched.backup_path(), &config)
        .map_err(map_cron_error)?;
    crate::domains::cron::store::upsert_job(sched.pool(), &job).map_err(map_cron_error)?;
    let next = crate::domains::cron::schedule::compute_next_run(&job.schedule, now);
    let _ = crate::domains::cron::store::update_next_run_at(sched.pool(), &job.id, next);
    sched.reload_job(job.clone());
    sched.update_runtime(crate::domains::cron::JobRuntimeState {
        job_id: job.id.clone(),
        next_run_at: next,
        last_run_at: None,
        consecutive_failures: 0,
        running_since: None,
    });
    drop(_guard);
    sched.reschedule_notify().notify_one();
    project_cron_trigger(&deps.engine_host, &job)
        .await
        .map_err(crate::shared::server::error_mapping::engine_error_to_capability_error)?;
    publish_cron_stream(invocation, deps, "created", &job.id, None).await;
    Ok(json!({ "job": to_json_value(&job)? }))
}

pub(crate) async fn cron_update_value(
    payload: &Value,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let job_id = require_string_param(Some(payload), "jobId")?;
    let _guard = sched.config_lock().lock().await;
    let mut config =
        crate::domains::cron::config::load_config(sched.config_path(), sched.backup_path())
            .map_err(map_cron_error)?;
    let job = config
        .jobs
        .iter_mut()
        .find(|job| job.id == job_id)
        .ok_or_else(|| CapabilityError::NotFound {
            code: "NOT_FOUND".into(),
            message: format!("Job not found: {job_id}"),
        })?;
    if let Some(name) = payload.get("name").and_then(Value::as_str) {
        if crate::domains::cron::store::name_exists(sched.pool(), name, Some(&job_id))
            .map_err(map_cron_error)?
        {
            return Err(CapabilityError::Custom {
                code: "ALREADY_EXISTS".into(),
                message: format!("Job with name '{name}' already exists"),
                details: None,
            });
        }
        name.clone_into(&mut job.name);
    }
    if let Some(desc) = payload.get("description") {
        job.description = desc.as_str().map(String::from);
    }
    if let Some(enabled) = payload.get("enabled").and_then(Value::as_bool) {
        job.enabled = enabled;
    }
    if let Some(value) = payload.get("schedule") {
        job.schedule = serde_json::from_value(value.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid schedule: {error}"),
            }
        })?;
    }
    if let Some(value) = payload.get("payload") {
        job.payload = serde_json::from_value(value.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid payload: {error}"),
            }
        })?;
    }
    if let Some(value) = payload.get("delivery") {
        job.delivery = serde_json::from_value(value.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid delivery: {error}"),
            }
        })?;
    }
    if let Some(value) = payload.get("overlapPolicy") {
        job.overlap_policy = serde_json::from_value(value.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid overlapPolicy: {error}"),
            }
        })?;
    }
    if let Some(value) = payload.get("misfirePolicy") {
        job.misfire_policy = serde_json::from_value(value.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid misfirePolicy: {error}"),
            }
        })?;
    }
    if let Some(value) = payload.get("maxRetries").and_then(Value::as_u64) {
        job.max_retries = value as u32;
    }
    if let Some(value) = payload.get("autoDisableAfter").and_then(Value::as_u64) {
        job.auto_disable_after = value as u32;
    }
    if let Some(value) = payload.get("stuckTimeoutSecs").and_then(Value::as_u64) {
        job.stuck_timeout_secs = value;
    }
    if let Some(tags) = payload.get("tags").and_then(Value::as_array) {
        job.tags = tags
            .iter()
            .filter_map(|value| value.as_str().map(String::from))
            .collect();
    }
    if let Some(workspace) = payload.get("workspaceId") {
        job.workspace_id = workspace.as_str().map(String::from);
    }
    if let Some(value) = payload.get("capabilityRestrictions") {
        job.capability_restrictions = if value.is_null() {
            None
        } else {
            Some(serde_json::from_value(value.clone()).map_err(|error| {
                CapabilityError::InvalidParams {
                    message: format!("Invalid capabilityRestrictions: {error}"),
                }
            })?)
        };
    }
    job.updated_at = Utc::now();
    crate::domains::cron::config::validate_job(job).map_err(|error| {
        CapabilityError::InvalidParams {
            message: error.to_string(),
        }
    })?;
    let updated_job = job.clone();
    crate::domains::cron::config::save_config(sched.config_path(), sched.backup_path(), &config)
        .map_err(map_cron_error)?;
    crate::domains::cron::store::upsert_job(sched.pool(), &updated_job).map_err(map_cron_error)?;
    let now = Utc::now();
    let next = crate::domains::cron::schedule::compute_next_run(&updated_job.schedule, now);
    let _ = crate::domains::cron::store::update_next_run_at(sched.pool(), &updated_job.id, next);
    sched.reload_job(updated_job.clone());
    if let Some(mut runtime) = sched.get_runtime_state(&updated_job.id) {
        runtime.next_run_at = next;
        sched.update_runtime(runtime);
    }
    drop(_guard);
    sched.reschedule_notify().notify_one();
    project_cron_trigger(&deps.engine_host, &updated_job)
        .await
        .map_err(crate::shared::server::error_mapping::engine_error_to_capability_error)?;
    publish_cron_stream(invocation, deps, "updated", &updated_job.id, None).await;
    Ok(json!({ "job": to_json_value(&updated_job)? }))
}

pub(crate) async fn cron_delete_value(
    payload: &Value,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let sched = scheduler(deps)?;
    let job_id = require_string_param(Some(payload), "jobId")?;
    let _guard = sched.config_lock().lock().await;
    let mut config =
        crate::domains::cron::config::load_config(sched.config_path(), sched.backup_path())
            .map_err(map_cron_error)?;
    let before_len = config.jobs.len();
    config.jobs.retain(|job| job.id != job_id);
    if config.jobs.len() == before_len {
        return Err(CapabilityError::NotFound {
            code: "NOT_FOUND".into(),
            message: format!("Job not found: {job_id}"),
        });
    }
    crate::domains::cron::config::save_config(sched.config_path(), sched.backup_path(), &config)
        .map_err(map_cron_error)?;
    let _ =
        crate::domains::cron::store::delete_job(sched.pool(), &job_id).map_err(map_cron_error)?;
    sched.remove_job(&job_id);
    drop(_guard);
    sched.reschedule_notify().notify_one();
    publish_cron_stream(invocation, deps, "deleted", &job_id, None).await;
    Ok(json!({ "deleted": true }))
}
