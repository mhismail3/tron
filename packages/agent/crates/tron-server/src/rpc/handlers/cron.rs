//! Cron scheduling RPC handlers.
//!
//! Eight methods for managing cron jobs and viewing execution history:
//!
//! - `cron.list` — List jobs (filterable by enabled/tags/workspace)
//! - `cron.get` — Get a single job with runtime state and recent runs
//! - `cron.create` — Create a new job
//! - `cron.update` — Partial-update an existing job
//! - `cron.delete` — Delete a job (preserves run history)
//! - `cron.run` — Trigger immediate execution
//! - `cron.status` — Scheduler health/status
//! - `cron.getRuns` — Paginated run history for a job

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::{require_param, require_string_param};
use crate::rpc::registry::MethodHandler;

fn scheduler(ctx: &RpcContext) -> Result<&std::sync::Arc<tron_cron::CronScheduler>, RpcError> {
    ctx.cron_scheduler.as_ref().ok_or(RpcError::NotAvailable {
        message: "Cron scheduler not available".into(),
    })
}

// ── cron.list ───────────────────────────────────────────────────────

/// List cron jobs with optional filters.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;
        let jobs = sched.jobs();

        let enabled_filter = params
            .as_ref()
            .and_then(|p| p.get("enabled"))
            .and_then(|v| v.as_bool());

        let tag_filter = params
            .as_ref()
            .and_then(|p| p.get("tags"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect::<Vec<_>>()
            });

        let workspace_filter = params
            .as_ref()
            .and_then(|p| p.get("workspaceId"))
            .and_then(|v| v.as_str());

        let filtered: Vec<_> = jobs
            .values()
            .filter(|j| {
                if let Some(enabled) = enabled_filter {
                    if j.enabled != enabled {
                        return false;
                    }
                }
                if let Some(ref tags) = tag_filter {
                    if !tags.iter().any(|t| j.tags.contains(t)) {
                        return false;
                    }
                }
                if let Some(ws) = workspace_filter {
                    if j.workspace_id.as_deref() != Some(ws) {
                        return false;
                    }
                }
                true
            })
            .collect();

        let runtime_states: Vec<_> = filtered
            .iter()
            .filter_map(|j| sched.get_runtime_state(&j.id))
            .map(|rs| {
                serde_json::json!({
                    "jobId": rs.job_id,
                    "nextRunAt": rs.next_run_at,
                    "lastRunAt": rs.last_run_at,
                    "consecutiveFailures": rs.consecutive_failures,
                    "runningSince": rs.running_since,
                })
            })
            .collect();

        Ok(serde_json::json!({
            "jobs": serde_json::to_value(&filtered).map_err(|e| RpcError::Internal { message: e.to_string() })?,
            "runtimeState": runtime_states,
        }))
    }
}

// ── cron.get ────────────────────────────────────────────────────────

/// Get a single cron job with runtime state and recent runs.
pub struct GetHandler;

#[async_trait]
impl MethodHandler for GetHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;
        let job_id = require_string_param(params.as_ref(), "jobId")?;

        let jobs = sched.jobs();
        let job = jobs.get(&job_id).ok_or_else(|| RpcError::NotFound {
            code: "NOT_FOUND".into(),
            message: format!("Job not found: {job_id}"),
        })?;

        let runtime_state = sched.get_runtime_state(&job_id);
        let (recent_runs, _total) =
            tron_cron::store::get_runs(sched.pool(), Some(&job_id), None, 10, 0).map_err(
                |e| RpcError::Internal {
                    message: e.to_string(),
                },
            )?;

        Ok(serde_json::json!({
            "job": serde_json::to_value(job).map_err(|e| RpcError::Internal { message: e.to_string() })?,
            "runtimeState": runtime_state.map(|rs| serde_json::json!({
                "jobId": rs.job_id,
                "nextRunAt": rs.next_run_at,
                "lastRunAt": rs.last_run_at,
                "consecutiveFailures": rs.consecutive_failures,
                "runningSince": rs.running_since,
            })),
            "recentRuns": serde_json::to_value(&recent_runs).map_err(|e| RpcError::Internal { message: e.to_string() })?,
        }))
    }
}

// ── cron.create ─────────────────────────────────────────────────────

/// Create a new cron job.
pub struct CreateHandler;

#[async_trait]
impl MethodHandler for CreateHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;
        let params = params.ok_or(RpcError::InvalidParams {
            message: "Missing parameters".into(),
        })?;

        let job_param = require_param(Some(&params), "job")?;

        // Parse partial job from params (sans id/timestamps)
        let name = job_param
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or(RpcError::InvalidParams {
                message: "Missing required field: name".into(),
            })?;

        let schedule: tron_cron::types::Schedule =
            serde_json::from_value(job_param.get("schedule").cloned().ok_or(
                RpcError::InvalidParams {
                    message: "Missing required field: schedule".into(),
                },
            )?)
            .map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid schedule: {e}"),
            })?;

        let payload: tron_cron::types::Payload =
            serde_json::from_value(job_param.get("payload").cloned().ok_or(
                RpcError::InvalidParams {
                    message: "Missing required field: payload".into(),
                },
            )?)
            .map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid payload: {e}"),
            })?;

        let delivery: Vec<tron_cron::types::Delivery> = job_param
            .get("delivery")
            .map(|v| serde_json::from_value(v.clone()))
            .transpose()
            .map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid delivery: {e}"),
            })?
            .unwrap_or_default();

        let now = chrono::Utc::now();
        let job = tron_cron::CronJob {
            id: format!("cron_{}", uuid::Uuid::now_v7()),
            name: name.to_owned(),
            description: job_param
                .get("description")
                .and_then(|v| v.as_str())
                .map(String::from),
            enabled: job_param
                .get("enabled")
                .and_then(|v| v.as_bool())
                .unwrap_or(true),
            schedule,
            payload,
            delivery,
            overlap_policy: job_param
                .get("overlapPolicy")
                .map(|v| serde_json::from_value(v.clone()))
                .transpose()
                .map_err(|e| RpcError::InvalidParams {
                    message: format!("Invalid overlapPolicy: {e}"),
                })?
                .unwrap_or_default(),
            misfire_policy: job_param
                .get("misfirePolicy")
                .map(|v| serde_json::from_value(v.clone()))
                .transpose()
                .map_err(|e| RpcError::InvalidParams {
                    message: format!("Invalid misfirePolicy: {e}"),
                })?
                .unwrap_or_default(),
            max_retries: job_param
                .get("maxRetries")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
            auto_disable_after: job_param
                .get("autoDisableAfter")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
            stuck_timeout_secs: job_param
                .get("stuckTimeoutSecs")
                .and_then(|v| v.as_u64())
                .unwrap_or(7200),
            tags: job_param
                .get("tags")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default(),
            workspace_id: job_param
                .get("workspaceId")
                .and_then(|v| v.as_str())
                .map(String::from),
            created_at: now,
            updated_at: now,
        };

        // Validate
        tron_cron::config::validate_job(&job).map_err(|e| RpcError::InvalidParams {
            message: e.to_string(),
        })?;

        // Acquire config lock, load, add, save, sync
        let _guard = sched.config_lock().lock().await;

        // Check name uniqueness
        if tron_cron::store::name_exists(sched.pool(), &job.name, None)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
        {
            return Err(RpcError::Custom {
                code: "ALREADY_EXISTS".into(),
                message: format!("Job with name '{}' already exists", job.name),
                details: None,
            });
        }

        let mut config =
            tron_cron::config::load_config(sched.config_path()).map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        config.jobs.push(job.clone());

        tron_cron::config::save_config(sched.config_path(), &config).map_err(|e| {
            RpcError::Internal {
                message: e.to_string(),
            }
        })?;

        // Sync to SQLite
        tron_cron::store::upsert_job(sched.pool(), &job).map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        // Compute and set next_run_at
        let next = tron_cron::schedule::compute_next_run(&job.schedule, now);
        let _ = tron_cron::store::update_next_run_at(sched.pool(), &job.id, next);

        // Update in-memory scheduler state
        sched.reload_job(job.clone());
        sched.update_runtime(tron_cron::JobRuntimeState {
            job_id: job.id.clone(),
            next_run_at: next,
            last_run_at: None,
            consecutive_failures: 0,
            running_since: None,
        });

        drop(_guard);
        sched.reschedule_notify().notify_one();

        Ok(serde_json::json!({
            "job": serde_json::to_value(&job).map_err(|e| RpcError::Internal { message: e.to_string() })?,
        }))
    }
}

// ── cron.update ─────────────────────────────────────────────────────

/// Partial-update an existing cron job.
pub struct UpdateHandler;

#[async_trait]
impl MethodHandler for UpdateHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;
        let params = params.ok_or(RpcError::InvalidParams {
            message: "Missing parameters".into(),
        })?;
        let job_id = require_string_param(Some(&params), "jobId")?;

        let _guard = sched.config_lock().lock().await;

        let mut config =
            tron_cron::config::load_config(sched.config_path()).map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let job = config
            .jobs
            .iter_mut()
            .find(|j| j.id == job_id)
            .ok_or_else(|| RpcError::NotFound {
                code: "NOT_FOUND".into(),
                message: format!("Job not found: {job_id}"),
            })?;

        // Apply partial updates
        if let Some(name) = params.get("name").and_then(|v| v.as_str()) {
            // Check uniqueness (excluding self)
            if tron_cron::store::name_exists(sched.pool(), name, Some(&job_id))
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?
            {
                return Err(RpcError::Custom {
                    code: "ALREADY_EXISTS".into(),
                    message: format!("Job with name '{name}' already exists"),
                    details: None,
                });
            }
            job.name = name.to_owned();
        }
        if let Some(desc) = params.get("description") {
            job.description = desc.as_str().map(String::from);
        }
        if let Some(enabled) = params.get("enabled").and_then(|v| v.as_bool()) {
            job.enabled = enabled;
        }
        if let Some(sched_val) = params.get("schedule") {
            job.schedule = serde_json::from_value(sched_val.clone()).map_err(|e| {
                RpcError::InvalidParams {
                    message: format!("Invalid schedule: {e}"),
                }
            })?;
        }
        if let Some(payload_val) = params.get("payload") {
            job.payload = serde_json::from_value(payload_val.clone()).map_err(|e| {
                RpcError::InvalidParams {
                    message: format!("Invalid payload: {e}"),
                }
            })?;
        }
        if let Some(delivery_val) = params.get("delivery") {
            job.delivery = serde_json::from_value(delivery_val.clone()).map_err(|e| {
                RpcError::InvalidParams {
                    message: format!("Invalid delivery: {e}"),
                }
            })?;
        }
        if let Some(v) = params.get("overlapPolicy") {
            job.overlap_policy = serde_json::from_value(v.clone()).map_err(|e| {
                RpcError::InvalidParams {
                    message: format!("Invalid overlapPolicy: {e}"),
                }
            })?;
        }
        if let Some(v) = params.get("misfirePolicy") {
            job.misfire_policy = serde_json::from_value(v.clone()).map_err(|e| {
                RpcError::InvalidParams {
                    message: format!("Invalid misfirePolicy: {e}"),
                }
            })?;
        }
        if let Some(v) = params.get("maxRetries").and_then(|v| v.as_u64()) {
            job.max_retries = v as u32;
        }
        if let Some(v) = params.get("autoDisableAfter").and_then(|v| v.as_u64()) {
            job.auto_disable_after = v as u32;
        }
        if let Some(v) = params.get("stuckTimeoutSecs").and_then(|v| v.as_u64()) {
            job.stuck_timeout_secs = v;
        }
        if let Some(tags) = params.get("tags").and_then(|v| v.as_array()) {
            job.tags = tags
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect();
        }
        if let Some(ws) = params.get("workspaceId") {
            job.workspace_id = ws.as_str().map(String::from);
        }

        job.updated_at = chrono::Utc::now();

        // Re-validate
        tron_cron::config::validate_job(job).map_err(|e| RpcError::InvalidParams {
            message: e.to_string(),
        })?;

        let updated_job = job.clone();

        // Save and sync
        tron_cron::config::save_config(sched.config_path(), &config).map_err(|e| {
            RpcError::Internal {
                message: e.to_string(),
            }
        })?;

        tron_cron::store::upsert_job(sched.pool(), &updated_job).map_err(|e| {
            RpcError::Internal {
                message: e.to_string(),
            }
        })?;

        // Recompute next_run_at
        let now = chrono::Utc::now();
        let next = tron_cron::schedule::compute_next_run(&updated_job.schedule, now);
        let _ = tron_cron::store::update_next_run_at(sched.pool(), &updated_job.id, next);

        sched.reload_job(updated_job.clone());
        if let Some(mut rs) = sched.get_runtime_state(&updated_job.id) {
            rs.next_run_at = next;
            sched.update_runtime(rs);
        }

        drop(_guard);
        sched.reschedule_notify().notify_one();

        Ok(serde_json::json!({
            "job": serde_json::to_value(&updated_job).map_err(|e| RpcError::Internal { message: e.to_string() })?,
        }))
    }
}

// ── cron.delete ─────────────────────────────────────────────────────

/// Delete a cron job (preserves run history).
pub struct DeleteHandler;

#[async_trait]
impl MethodHandler for DeleteHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.delete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;
        let job_id = require_string_param(params.as_ref(), "jobId")?;

        let _guard = sched.config_lock().lock().await;

        let mut config =
            tron_cron::config::load_config(sched.config_path()).map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let before_len = config.jobs.len();
        config.jobs.retain(|j| j.id != job_id);
        if config.jobs.len() == before_len {
            return Err(RpcError::NotFound {
                code: "NOT_FOUND".into(),
                message: format!("Job not found: {job_id}"),
            });
        }

        tron_cron::config::save_config(sched.config_path(), &config).map_err(|e| {
            RpcError::Internal {
                message: e.to_string(),
            }
        })?;

        // Delete from SQLite (runs preserved via ON DELETE SET NULL)
        let _ =
            tron_cron::store::delete_job(sched.pool(), &job_id).map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        // Remove from in-memory state
        sched.remove_job(&job_id);

        drop(_guard);
        sched.reschedule_notify().notify_one();

        Ok(serde_json::json!({ "deleted": true }))
    }
}

// ── cron.run ────────────────────────────────────────────────────────

/// Trigger immediate execution of a cron job.
pub struct RunHandler;

#[async_trait]
impl MethodHandler for RunHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.run"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;
        let job_id = require_string_param(params.as_ref(), "jobId")?;

        let jobs = sched.jobs();
        let _job = jobs.get(&job_id).ok_or_else(|| RpcError::NotFound {
            code: "NOT_FOUND".into(),
            message: format!("Job not found: {job_id}"),
        })?;

        // Set next_run_at to now to trigger on next tick
        let now = chrono::Utc::now();
        let _ = tron_cron::store::update_next_run_at(sched.pool(), &job_id, Some(now));

        if let Some(mut rs) = sched.get_runtime_state(&job_id) {
            rs.next_run_at = Some(now);
            sched.update_runtime(rs);
        }

        sched.reschedule_notify().notify_one();

        Ok(serde_json::json!({
            "triggered": true,
            "jobId": job_id,
        }))
    }
}

// ── cron.status ─────────────────────────────────────────────────────

/// Return cron scheduler health and status.
pub struct StatusHandler;

#[async_trait]
impl MethodHandler for StatusHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.status"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;

        Ok(serde_json::json!({
            "running": true,
            "jobCount": sched.job_count(),
            "activeRuns": sched.active_run_count(),
            "nextWakeup": sched.next_wakeup(),
            "executionLimit": 10,
        }))
    }
}

// ── cron.getRuns ─────────────────────────────────────────────────────

/// Return paginated run history for a cron job.
pub struct GetRunsHandler;

#[async_trait]
impl MethodHandler for GetRunsHandler {
    #[instrument(skip(self, ctx), fields(method = "cron.getRuns"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let sched = scheduler(ctx)?;
        let job_id = require_string_param(params.as_ref(), "jobId")?;

        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(|v| v.as_u64())
            .unwrap_or(20) as u32;

        let offset = params
            .as_ref()
            .and_then(|p| p.get("offset"))
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as u32;

        let status_filter = params
            .as_ref()
            .and_then(|p| p.get("status"))
            .and_then(|v| v.as_str());

        let (runs, total) = tron_cron::store::get_runs(
            sched.pool(),
            Some(&job_id),
            status_filter,
            limit,
            offset,
        )
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        Ok(serde_json::json!({
            "runs": serde_json::to_value(&runs).map_err(|e| RpcError::Internal { message: e.to_string() })?,
            "total": total,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;

    #[tokio::test]
    async fn status_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let err = StatusHandler.handle(None, &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn list_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let err = ListHandler.handle(None, &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn get_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let params = serde_json::json!({"jobId": "cron_1"});
        let err = GetHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn create_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let params = serde_json::json!({"job": {}});
        let err = CreateHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn delete_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let params = serde_json::json!({"jobId": "cron_1"});
        let err = DeleteHandler
            .handle(Some(params), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn run_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let params = serde_json::json!({"jobId": "cron_1"});
        let err = RunHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn get_runs_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let params = serde_json::json!({"jobId": "cron_1"});
        let err = GetRunsHandler
            .handle(Some(params), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn update_without_scheduler_returns_not_available() {
        let ctx = make_test_context();
        let params = serde_json::json!({"jobId": "cron_1"});
        let err = UpdateHandler
            .handle(Some(params), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    // ── Tests with a real scheduler ─────────────────────────────────

    fn make_cron_context() -> (RpcContext, tempfile::TempDir) {
        let pool =
            tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
            let _ = tron_cron::migrations::run_migrations(&conn).unwrap();
        }

        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("jobs.json");

        let cancel = tokio_util::sync::CancellationToken::new();
        let deps = tron_cron::ExecutorDeps {
            agent_executor: None,
            broadcaster: std::sync::OnceLock::new(),
            push_notifier: None,
            event_injector: None,
            http_client: reqwest::Client::new(),
            pool: pool.clone(),
            output_dir: dir.path().join("outputs"),
        };

        let scheduler = std::sync::Arc::new(tron_cron::CronScheduler::new(
            pool.clone(),
            std::sync::Arc::new(tron_cron::SystemClock),
            deps,
            config_path,
            cancel,
        ));

        let mut ctx = make_test_context();
        ctx.cron_scheduler = Some(scheduler);
        (ctx, dir)
    }

    #[tokio::test]
    async fn status_returns_info() {
        let (ctx, _dir) = make_cron_context();
        let result = StatusHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["running"], true);
        assert_eq!(result["jobCount"], 0);
        assert_eq!(result["activeRuns"], 0);
    }

    #[tokio::test]
    async fn list_empty() {
        let (ctx, _dir) = make_cron_context();
        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["jobs"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn create_and_list_job() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({
            "job": {
                "name": "Test Job",
                "schedule": {"type": "every", "intervalSecs": 60},
                "payload": {"type": "shellCommand", "command": "echo hi"},
            }
        });
        let result = CreateHandler.handle(Some(params), &ctx).await.unwrap();
        let job_id = result["job"]["id"].as_str().unwrap().to_string();
        assert!(job_id.starts_with("cron_"));

        // List should return the job
        let list = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(list["jobs"].as_array().unwrap().len(), 1);

        // Get should return the job
        let get_params = serde_json::json!({"jobId": job_id});
        let get_result = GetHandler.handle(Some(get_params), &ctx).await.unwrap();
        assert_eq!(get_result["job"]["name"], "Test Job");
    }

    #[tokio::test]
    async fn create_job_missing_name() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({
            "job": {
                "schedule": {"type": "every", "intervalSecs": 60},
                "payload": {"type": "shellCommand", "command": "echo hi"},
            }
        });
        let err = CreateHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn create_job_duplicate_name() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({
            "job": {
                "name": "Dupe",
                "schedule": {"type": "every", "intervalSecs": 60},
                "payload": {"type": "shellCommand", "command": "echo hi"},
            }
        });
        let _ = CreateHandler
            .handle(Some(params.clone()), &ctx)
            .await
            .unwrap();
        let err = CreateHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "ALREADY_EXISTS");
    }

    #[tokio::test]
    async fn update_job() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({
            "job": {
                "name": "Updatable",
                "schedule": {"type": "every", "intervalSecs": 60},
                "payload": {"type": "shellCommand", "command": "echo hi"},
            }
        });
        let result = CreateHandler.handle(Some(params), &ctx).await.unwrap();
        let job_id = result["job"]["id"].as_str().unwrap().to_string();

        let update_params = serde_json::json!({
            "jobId": job_id,
            "name": "Updated Name",
            "enabled": false,
        });
        let updated = UpdateHandler
            .handle(Some(update_params), &ctx)
            .await
            .unwrap();
        assert_eq!(updated["job"]["name"], "Updated Name");
        assert_eq!(updated["job"]["enabled"], false);
    }

    #[tokio::test]
    async fn update_nonexistent_job() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({"jobId": "cron_nonexistent", "name": "x"});
        let err = UpdateHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn delete_job() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({
            "job": {
                "name": "Deletable",
                "schedule": {"type": "every", "intervalSecs": 60},
                "payload": {"type": "shellCommand", "command": "echo hi"},
            }
        });
        let result = CreateHandler.handle(Some(params), &ctx).await.unwrap();
        let job_id = result["job"]["id"].as_str().unwrap().to_string();

        let del_params = serde_json::json!({"jobId": job_id});
        let deleted = DeleteHandler.handle(Some(del_params), &ctx).await.unwrap();
        assert_eq!(deleted["deleted"], true);

        // List should be empty
        let list = ListHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(list["jobs"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn delete_nonexistent_job() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({"jobId": "cron_nonexistent"});
        let err = DeleteHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn run_nonexistent_job() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({"jobId": "cron_nonexistent"});
        let err = RunHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn get_runs_empty() {
        let (ctx, _dir) = make_cron_context();
        let params = serde_json::json!({"jobId": "cron_1"});
        let result = GetRunsHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["runs"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn list_filters_by_enabled() {
        let (ctx, _dir) = make_cron_context();

        // Create enabled job
        let _ = CreateHandler
            .handle(
                Some(serde_json::json!({
                    "job": {
                        "name": "Enabled",
                        "schedule": {"type": "every", "intervalSecs": 60},
                        "payload": {"type": "shellCommand", "command": "echo hi"},
                        "enabled": true,
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        // Create disabled job
        let _ = CreateHandler
            .handle(
                Some(serde_json::json!({
                    "job": {
                        "name": "Disabled",
                        "schedule": {"type": "every", "intervalSecs": 60},
                        "payload": {"type": "shellCommand", "command": "echo hi"},
                        "enabled": false,
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        let list_enabled = ListHandler
            .handle(Some(serde_json::json!({"enabled": true})), &ctx)
            .await
            .unwrap();
        assert_eq!(list_enabled["jobs"].as_array().unwrap().len(), 1);

        let list_disabled = ListHandler
            .handle(Some(serde_json::json!({"enabled": false})), &ctx)
            .await
            .unwrap();
        assert_eq!(list_disabled["jobs"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn run_triggers_job() {
        let (ctx, _dir) = make_cron_context();
        let create_result = CreateHandler
            .handle(
                Some(serde_json::json!({
                    "job": {
                        "name": "Runnable",
                        "schedule": {"type": "every", "intervalSecs": 3600},
                        "payload": {"type": "shellCommand", "command": "echo hi"},
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();
        let job_id = create_result["job"]["id"].as_str().unwrap().to_string();

        let run_result = RunHandler
            .handle(Some(serde_json::json!({"jobId": job_id})), &ctx)
            .await
            .unwrap();
        assert_eq!(run_result["triggered"], true);
    }
}
