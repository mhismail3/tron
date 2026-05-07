//! Main cron scheduling loop.
//!
//! [`CronScheduler`] owns the in-memory job state, the scheduling timer,
//! config file watcher, engine trigger projection, and execution task spawner.
//! It coordinates between the config file (canonical definitions), `SQLite`
//! (runtime state), the engine trigger runtime (causal scheduled-fire path),
//! and the executor (payload execution).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use crate::events::ConnectionPool;
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::cron::clock::Clock;
use crate::cron::config::{self, FileFingerprint};
use crate::cron::delivery;
use crate::cron::errors::CronError;
use crate::cron::executor::{self, ExecutorDeps};
use crate::cron::schedule::compute_next_run;
use crate::cron::store;
use crate::cron::types::{CronJob, JobRuntimeState, MisfirePolicy, OverlapPolicy, RunStatus};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, DeliveryMode, EngineHostHandle, EngineTriggerRuntime,
    FunctionId, IdempotencyKeySource, Provenance, TriggerDefinition, TriggerDispatchRequest,
    TriggerId, TriggerTypeId, VisibilityScope, WorkerId,
};

/// Concurrency limit for heavyweight payloads (`AgentTurn`, `ShellCommand`).
///
/// Keeps enough budget that a concurrent flood of lightweight webhook /
/// system-event jobs cannot starve agent work — see [`DEFAULT_DELIVERY_LIMIT`]
/// and [`CronScheduler::semaphore_for_payload`].
const DEFAULT_EXECUTION_LIMIT: usize = 10;

/// Concurrency limit for lightweight delivery payloads (`Webhook`,
/// `SystemEvent`).
///
/// Larger than [`DEFAULT_EXECUTION_LIMIT`] because HTTP callouts and
/// single-event injections are cheap and mostly I/O-bound, so a wider pool
/// absorbs bursts (e.g. fan-out webhooks) without back-pressuring agent work.
const DEFAULT_DELIVERY_LIMIT: usize = 20;

/// Shared in-memory runtime state map, accessible from spawned tasks.
type RuntimeMap = Arc<parking_lot::RwLock<HashMap<String, JobRuntimeState>>>;

/// Main cron scheduler.
pub struct CronScheduler {
    pool: ConnectionPool,
    clock: Arc<dyn Clock>,
    /// In-memory job definitions (synced from file).
    jobs: parking_lot::RwLock<HashMap<String, CronJob>>,
    /// Runtime state per job (synced from `SQLite`). Arc-wrapped for sharing
    /// with spawned execution tasks.
    runtime: RuntimeMap,
    /// Serializes all access to `automations.json`.
    config_lock: tokio::sync::Mutex<()>,
    /// Wakes scheduler when config file changes.
    config_notify: Arc<tokio::sync::Notify>,
    /// Wakes scheduler when RPC mutates a job.
    reschedule_notify: Arc<tokio::sync::Notify>,
    /// Shutdown signal.
    cancel: CancellationToken,
    /// Concurrency limiter for heavyweight payloads (`AgentTurn`,
    /// `ShellCommand`).
    ///
    /// INVARIANT: acquired only via [`Self::semaphore_for_payload`]; never
    /// shared with lightweight delivery jobs so a webhook burst cannot
    /// starve agent work.
    execution_semaphore: Arc<tokio::sync::Semaphore>,
    /// Concurrency limiter for lightweight delivery payloads (`Webhook`,
    /// `SystemEvent`).
    ///
    /// Sized independently from [`Self::execution_semaphore`] — see
    /// [`DEFAULT_DELIVERY_LIMIT`].
    delivery_semaphore: Arc<tokio::sync::Semaphore>,
    /// Executor dependencies.
    deps: Arc<ExecutorDeps>,
    /// Live engine host used by scheduled cron fires.
    ///
    /// INVARIANT: when this is set, scheduled fires route through
    /// `EngineTriggerRuntime`; if startup forgets to attach it, due fires fail
    /// closed instead of bypassing engine policy and causal ledger recording.
    engine_host: OnceLock<EngineHostHandle>,
    /// Spawned cron execution tasks.
    active_tasks: tokio::sync::Mutex<tokio::task::JoinSet<()>>,
    /// Path to `automations.json`.
    config_path: PathBuf,
    /// Path to `automations.json.bak` beside the automations config.
    backup_path: PathBuf,
}

impl CronScheduler {
    /// Create a new scheduler.
    pub fn new(
        pool: ConnectionPool,
        clock: Arc<dyn Clock>,
        deps: ExecutorDeps,
        config_path: PathBuf,
        backup_path: PathBuf,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            pool,
            clock,
            jobs: parking_lot::RwLock::new(HashMap::new()),
            runtime: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            config_lock: tokio::sync::Mutex::new(()),
            config_notify: Arc::new(tokio::sync::Notify::new()),
            reschedule_notify: Arc::new(tokio::sync::Notify::new()),
            cancel,
            execution_semaphore: Arc::new(tokio::sync::Semaphore::new(DEFAULT_EXECUTION_LIMIT)),
            delivery_semaphore: Arc::new(tokio::sync::Semaphore::new(DEFAULT_DELIVERY_LIMIT)),
            deps: Arc::new(deps),
            engine_host: OnceLock::new(),
            active_tasks: tokio::sync::Mutex::new(tokio::task::JoinSet::new()),
            config_path,
            backup_path,
        }
    }

    /// Set the WebSocket broadcaster (must be called before `start()`).
    ///
    /// The broadcaster comes from `TronServer`, which is created after the
    /// scheduler. Uses `OnceLock` internally — calling twice is a no-op.
    pub fn set_broadcaster(&self, broadcaster: Arc<dyn crate::cron::executor::EventBroadcaster>) {
        let _ = self.deps.broadcaster.set(broadcaster);
    }

    /// Attach the engine host used for scheduled trigger dispatch.
    ///
    /// The scheduler is constructed before the engine transport is attached.
    /// Production startup must call this after `cron::*` functions are
    /// registered and before `start()`.
    pub fn set_engine_host(&self, handle: EngineHostHandle) {
        let _ = self.engine_host.set(handle);
    }

    /// Get the reschedule notify handle for cron capability functions.
    pub fn reschedule_notify(&self) -> Arc<tokio::sync::Notify> {
        self.reschedule_notify.clone()
    }

    /// Get the config lock used to serialize cron config access.
    pub fn config_lock(&self) -> &tokio::sync::Mutex<()> {
        &self.config_lock
    }

    /// Get the config file path.
    pub fn config_path(&self) -> &std::path::Path {
        &self.config_path
    }

    /// Get the path to the backup config file.
    pub fn backup_path(&self) -> &std::path::Path {
        &self.backup_path
    }

    /// Get the connection pool.
    pub fn pool(&self) -> &ConnectionPool {
        &self.pool
    }

    /// Get the clock.
    pub fn clock(&self) -> &dyn Clock {
        &*self.clock
    }

    /// Get current job count.
    pub fn job_count(&self) -> usize {
        self.jobs.read().len()
    }

    /// Get the in-memory jobs snapshot.
    pub fn jobs(&self) -> HashMap<String, CronJob> {
        self.jobs.read().clone()
    }

    /// Read-only access to jobs without cloning the entire map.
    pub fn with_jobs<T>(&self, f: impl FnOnce(&HashMap<String, CronJob>) -> T) -> T {
        f(&self.jobs.read())
    }

    /// Get a single job by ID (avoids cloning the entire map).
    pub fn get_job(&self, job_id: &str) -> Option<CronJob> {
        self.jobs.read().get(job_id).cloned()
    }

    /// Build the live engine trigger id for a cron job.
    pub fn schedule_trigger_id(job_id: &str) -> crate::engine::Result<TriggerId> {
        TriggerId::new(format!("cron_schedule:{job_id}"))
    }

    /// Build the live engine trigger definition for a cron job.
    pub fn schedule_trigger_definition(job: &CronJob) -> crate::engine::Result<TriggerDefinition> {
        let mut trigger = TriggerDefinition::new(
            Self::schedule_trigger_id(&job.id)?,
            WorkerId::new("cron")?,
            TriggerTypeId::new("cron_schedule")?,
            FunctionId::new("cron::scheduled_fire")?,
            AuthorityGrantId::new("cron-scheduler")?,
        )
        .with_delivery_mode(DeliveryMode::Sync);
        trigger.visibility = VisibilityScope::Internal;
        trigger.idempotency_key_strategy = Some(IdempotencyKeySource::TriggerDerived);
        trigger.provenance = Provenance::system();
        trigger.config = serde_json::json!({
            "jobId": job.id,
            "jobName": job.name,
            "enabled": job.enabled,
            "payloadKind": job.payload.kind_name(),
            "workspaceId": job.workspace_id,
            "schedule": job.schedule,
            "overlapPolicy": job.overlap_policy,
            "misfirePolicy": job.misfire_policy,
        });
        Ok(trigger)
    }

    /// Get runtime state for a job.
    pub fn get_runtime_state(&self, job_id: &str) -> Option<JobRuntimeState> {
        self.runtime.read().get(job_id).cloned()
    }

    /// Reload a single job into in-memory state (after RPC mutation).
    pub fn reload_job(&self, job: CronJob) {
        let _ = self.jobs.write().insert(job.id.clone(), job);
    }

    /// Remove a job from in-memory state.
    pub fn remove_job(&self, job_id: &str) {
        let _ = self.jobs.write().remove(job_id);
        let _ = self.runtime.write().remove(job_id);
    }

    /// Update runtime state for a job in memory.
    pub fn update_runtime(&self, state: JobRuntimeState) {
        let _ = self.runtime.write().insert(state.job_id.clone(), state);
    }

    /// Get an Arc handle to the runtime map (for spawned execution tasks).
    fn runtime_ref(&self) -> RuntimeMap {
        self.runtime.clone()
    }

    /// Get next wakeup time across all enabled jobs.
    pub fn next_wakeup(&self) -> Option<DateTime<Utc>> {
        self.runtime
            .read()
            .values()
            .filter_map(|s| s.next_run_at)
            .min()
    }

    /// Count currently running executions across both the execution and
    /// delivery pools.
    pub fn active_run_count(&self) -> usize {
        (DEFAULT_EXECUTION_LIMIT - self.execution_semaphore.available_permits())
            + (DEFAULT_DELIVERY_LIMIT - self.delivery_semaphore.available_permits())
    }

    /// Pick the right concurrency pool for a payload.
    ///
    /// `AgentTurn` and `ShellCommand` spawn child processes / model calls
    /// that can dominate compute for minutes — they share the
    /// [execution](`Self::execution_semaphore`) pool so we can bound the
    /// total heavyweight work in flight.
    ///
    /// `Webhook` and `SystemEvent` are fast I/O — they share the
    /// [delivery](`Self::delivery_semaphore`) pool so a burst of them cannot
    /// eat every execution permit and starve agent work.
    fn semaphore_for_payload(
        &self,
        payload: &crate::cron::types::Payload,
    ) -> Arc<tokio::sync::Semaphore> {
        use crate::cron::types::Payload;
        match payload {
            Payload::AgentTurn { .. } | Payload::ShellCommand { .. } => {
                self.execution_semaphore.clone()
            }
            Payload::Webhook { .. } | Payload::SystemEvent { .. } => {
                self.delivery_semaphore.clone()
            }
        }
    }

    /// Start the scheduler and config watcher. Returns join handles.
    pub fn start(self: Arc<Self>) -> (JoinHandle<()>, JoinHandle<()>) {
        let sched = self.clone();
        let watcher = self.clone();

        let sched_handle = tokio::spawn(async move { sched.run_scheduler().await });
        let watcher_handle = tokio::spawn(async move { watcher.run_config_watcher().await });

        (sched_handle, watcher_handle)
    }

    /// Initial startup: load config, sync to DB, handle misfires.
    async fn startup(&self) -> Result<(), CronError> {
        // Ensure directories exist
        if let Some(parent) = self.config_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let _guard = self.config_lock.lock().await;

        // Load config, recovering from SQLite-stored definitions if both
        // config files are corrupt.
        let config = match config::load_config(&self.config_path, &self.backup_path) {
            Ok(c) => c,
            Err(e) => {
                tracing::error!(
                    error = %e,
                    "config file corrupt and backup recovery failed, recovering from SQLite definitions"
                );
                // Reconstruct config from SQLite-stored job definitions
                let jobs = store::list_all_jobs(&self.pool)?;
                if jobs.is_empty() {
                    tracing::warn!(
                        "no jobs found in SQLite recovery source, starting with empty config"
                    );
                }

                // Broadcast config error event if broadcaster is available
                if let Some(broadcaster) = self.deps.broadcaster.get() {
                    let payload = serde_json::json!({
                        "error": e.to_string(),
                        "recoveredFromSqlite": !jobs.is_empty(),
                        "jobCount": jobs.len(),
                    });
                    let broadcaster = broadcaster.clone();
                    drop(tokio::spawn(async move {
                        broadcaster
                            .broadcast_cron_event("cron.configError", payload)
                            .await;
                    }));
                }

                crate::cron::types::CronConfig { version: 1, jobs }
            }
        };

        // Validate jobs
        for job in &config.jobs {
            if let Err(e) = config::validate_job(job) {
                tracing::warn!(job_id = %job.id, error = %e, "invalid job in config, skipping");
            }
        }

        // Sync to SQLite
        let (added, updated, removed) = store::sync_from_config(&self.pool, &config.jobs)?;
        tracing::info!(added, updated, removed, "config synced to database");

        // Load into memory
        {
            let mut jobs = self.jobs.write();
            for job in &config.jobs {
                let _ = jobs.insert(job.id.clone(), job.clone());
            }
        }

        // Clean up orphaned run records from previous server instance
        let now = self.clock.now_utc();
        if let Ok(orphaned) = store::complete_orphaned_runs(&self.pool, now, "server restarted")
            && orphaned > 0
        {
            tracing::info!(
                count = orphaned,
                "cleaned up orphaned run records from previous instance"
            );
        }

        // Detect stuck jobs
        self.detect_stuck_jobs()?;

        // Apply misfire policy and compute next_run_at
        for job in &config.jobs {
            if !job.enabled {
                continue;
            }

            let state = store::get_runtime_state(&self.pool, &job.id)?;
            let next_run_at = state.as_ref().and_then(|s| s.next_run_at);

            let new_next = if let Some(next) = next_run_at {
                if next < now {
                    match job.misfire_policy {
                        MisfirePolicy::Skip => compute_next_run(&job.schedule, now),
                        MisfirePolicy::RunOnce => {
                            tracing::info!(
                                job_id = %job.id,
                                missed_at = %next,
                                "misfire: scheduling immediate run"
                            );
                            Some(now)
                        }
                    }
                } else {
                    Some(next)
                }
            } else {
                compute_next_run(&job.schedule, now)
            };

            let _ = store::update_next_run_at(&self.pool, &job.id, new_next)?;
            let _ = self.runtime.write().insert(
                job.id.clone(),
                JobRuntimeState {
                    job_id: job.id.clone(),
                    next_run_at: new_next,
                    last_run_at: state.as_ref().and_then(|s| s.last_run_at),
                    consecutive_failures: state.as_ref().map_or(0, |s| s.consecutive_failures),
                    running_since: state.as_ref().and_then(|s| s.running_since),
                },
            );
        }

        self.project_engine_triggers_for_jobs(&config.jobs).await?;

        Ok(())
    }

    /// Main scheduling loop.
    async fn run_scheduler(self: Arc<Self>) {
        if let Err(e) = self.startup().await {
            tracing::error!(error = %e, "cron scheduler startup failed");
            return;
        }

        tracing::info!(job_count = self.job_count(), "cron scheduler started");

        let mut last_maintenance = self.clock.now_utc();
        loop {
            let now = self.clock.now_utc();

            // Compute sleep duration until next job
            let sleep_duration = self.next_wakeup().map_or(Duration::from_secs(60), |next| {
                let diff = next - now;
                if diff.num_milliseconds() <= 0 {
                    Duration::from_millis(0)
                } else {
                    Duration::from_millis(diff.num_milliseconds().min(60_000) as u64)
                }
            });

            tokio::select! {
                () = tokio::time::sleep(sleep_duration) => {
                    let now = self.clock.now_utc();
                    let grace = chrono::Duration::milliseconds(50);

                    // Collect due jobs with their exact scheduled_at times
                    let due_jobs: Vec<(CronJob, DateTime<Utc>)> = {
                        let jobs = self.jobs.read();
                        let runtime = self.runtime.read();
                        jobs.values()
                            .filter(|j| j.enabled)
                            .filter_map(|j| {
                                runtime.get(&j.id)
                                    .and_then(|s| s.next_run_at)
                                    .filter(|next| *next <= now + grace)
                                    .map(|scheduled_at| (j.clone(), scheduled_at))
                            })
                            .collect()
                    };

                    // Stagger: if >5 due jobs, sort by SHA-256(job_id) for
                    // deterministic order, insert 100ms delays between spawns
                    // to prevent thundering herd.
                    let mut due_jobs = due_jobs;
                    if due_jobs.len() > 5 {
                        due_jobs.sort_by_cached_key(|(j, _)| {
                            let hash: [u8; 32] = Sha256::digest(j.id.as_bytes()).into();
                            hash
                        });
                    }

                    for (i, (job, scheduled_at)) in due_jobs.iter().enumerate() {
                        if i > 0 && due_jobs.len() > 5 {
                            tokio::time::sleep(Duration::from_millis(100)).await;
                        }
                        if let Err(error) = self.fire_due_job(job, *scheduled_at).await {
                            tracing::error!(
                                job_id = %job.id,
                                scheduled_at = %scheduled_at,
                                error = %error,
                                "cron scheduled fire failed"
                            );
                        }
                    }

                    // Periodic maintenance (every 5 minutes)
                    if (now - last_maintenance).num_seconds() >= 300 {
                        if let Err(e) = self.detect_stuck_jobs() {
                            tracing::error!(error = %e, "stuck job detection failed");
                        }
                        let cutoff = now - chrono::Duration::days(7);
                        if let Err(e) = store::gc_old_runs(&self.pool, cutoff, 100) {
                            tracing::error!(error = %e, "garbage collection failed");
                        }
                        last_maintenance = now;
                    }

                    // Drain completed tasks
                    self.drain_completed_tasks().await;
                }

                () = self.config_notify.notified() => {
                    if let Err(e) = self.reload_config().await {
                        tracing::warn!(error = %e, "config reload failed");
                    }
                }

                () = self.reschedule_notify.notified() => {
                    // Just recompute sleep duration on next iteration
                }

                () = self.cancel.cancelled() => {
                    tracing::info!("cron scheduler shutting down");
                    let mut active_tasks = self.active_tasks.lock().await;
                    while let Some(result) = active_tasks.join_next().await {
                        if let Err(e) = result {
                            tracing::warn!(error = %e, "cron task error during shutdown");
                        }
                    }
                    break;
                }
            }
        }
    }

    /// Config file watcher (poll-based, every 5 seconds).
    async fn run_config_watcher(self: Arc<Self>) {
        let mut last_fp = FileFingerprint::compute(&self.config_path);

        loop {
            tokio::select! {
                () = tokio::time::sleep(Duration::from_secs(5)) => {
                    let current_fp = FileFingerprint::compute(&self.config_path);
                    if current_fp != last_fp {
                        tracing::info!("config file change detected");
                        self.config_notify.notify_one();
                        last_fp = current_fp;
                    }
                }
                () = self.cancel.cancelled() => break,
            }
        }
    }

    /// Reload config from disk and sync to memory + `SQLite`.
    async fn reload_config(&self) -> Result<(), CronError> {
        let _guard = self.config_lock.lock().await;
        let config = config::load_config(&self.config_path, &self.backup_path)?;
        let (added, updated, removed) = store::sync_from_config(&self.pool, &config.jobs)?;
        tracing::info!(added, updated, removed, "config reloaded");

        let config_ids: std::collections::HashSet<String> =
            config.jobs.iter().map(|j| j.id.clone()).collect();
        let now = self.clock.now_utc();

        let removed_ids = {
            // Update in-memory state.
            let mut jobs = self.jobs.write();

            // Remove jobs no longer in config.
            let removed_ids: Vec<String> = jobs
                .keys()
                .filter(|id| !config_ids.contains(*id))
                .cloned()
                .collect();
            jobs.retain(|id, _| config_ids.contains(id));

            // Add/update jobs from config.
            for job in config.jobs {
                if job.enabled {
                    let schedule_changed = jobs
                        .get(&job.id)
                        .is_none_or(|old| old.schedule != job.schedule);
                    let has_runtime = self
                        .runtime
                        .read()
                        .get(&job.id)
                        .and_then(|s| s.next_run_at)
                        .is_some();

                    if schedule_changed || !has_runtime {
                        let next = compute_next_run(&job.schedule, now);
                        if let Err(e) = store::update_next_run_at(&self.pool, &job.id, next) {
                            tracing::error!(job_id = %job.id, error = %e, "failed to update next_run_at during reload");
                        } else {
                            let _ = self
                                .runtime
                                .write()
                                .entry(job.id.clone())
                                .and_modify(|s| s.next_run_at = next)
                                .or_insert(JobRuntimeState {
                                    job_id: job.id.clone(),
                                    next_run_at: next,
                                    last_run_at: None,
                                    consecutive_failures: 0,
                                    running_since: None,
                                });
                        }
                    }
                }
                let _ = jobs.insert(job.id.clone(), job);
            }
            removed_ids
        };

        for job_id in removed_ids {
            self.unproject_engine_trigger(&job_id).await?;
        }
        self.project_engine_triggers_for_current_jobs().await?;

        Ok(())
    }

    /// Detect and clear stuck jobs.
    fn detect_stuck_jobs(&self) -> Result<(), CronError> {
        let now = self.clock.now_utc();
        let candidates = store::get_stuck_candidates(&self.pool)?;

        for (job_id, since, timeout_secs) in candidates {
            let elapsed = (now - since).num_seconds() as u64;
            if elapsed > timeout_secs {
                tracing::warn!(
                    job_id = %job_id,
                    elapsed_secs = elapsed,
                    timeout_secs,
                    "stuck job detected, clearing"
                );

                // Update the original running run record(s) to timed_out
                let error_msg = "stuck job cleared on startup/maintenance";
                let updated = store::complete_stuck_runs(&self.pool, &job_id, now, error_msg)
                    .unwrap_or_else(|e| {
                        tracing::error!(job_id = %job_id, error = %e, "failed to complete stuck runs");
                        0
                    });

                // If no records found (edge case: record deleted or DB inconsistency),
                // create a synthetic timed_out record for audit trail
                if updated == 0 {
                    let run_id = format!("cronrun_{}", Uuid::now_v7());
                    if let Err(e) = store::insert_run(&self.pool, &run_id, &job_id, "stuck", since)
                    {
                        tracing::error!(job_id = %job_id, error = %e, "failed to insert synthetic stuck run");
                    }
                    let run = crate::cron::types::CronRun {
                        id: run_id,
                        job_id: Some(job_id.clone()),
                        job_name: "stuck".into(),
                        status: RunStatus::TimedOut,
                        started_at: since,
                        completed_at: Some(now),
                        duration_ms: Some((now - since).num_milliseconds()),
                        output: None,
                        output_truncated: false,
                        error: Some(error_msg.into()),
                        exit_code: None,
                        attempt: 0,
                        session_id: None,
                        delivery_status: None,
                    };
                    if let Err(e) = store::complete_run(&self.pool, &run) {
                        tracing::error!(job_id = %job_id, error = %e, "failed to complete synthetic stuck run");
                    }
                }

                store::clear_running_since(&self.pool, &job_id)?;
                let _ = self
                    .runtime
                    .write()
                    .entry(job_id.clone())
                    .and_modify(|s| s.running_since = None);
                if let Err(e) = store::increment_consecutive_failures(&self.pool, &job_id) {
                    tracing::error!(job_id = %job_id, error = %e, "failed to increment consecutive failures for stuck job");
                }
            }
        }

        Ok(())
    }
}

impl CronScheduler {
    async fn fire_due_job(
        &self,
        job: &CronJob,
        scheduled_at: DateTime<Utc>,
    ) -> Result<(), CronError> {
        let Some(handle) = self.engine_host.get() else {
            #[cfg(test)]
            {
                // Unit tests exercise scheduler timing without bootstrapping
                // the full engine catalog; production builds fail closed below.
                return self
                    .start_due_job(job.clone(), scheduled_at)
                    .await
                    .map(|_| ());
            }
            #[cfg(not(test))]
            return Err(CronError::Execution(
                "engine host missing for cron scheduled trigger dispatch".into(),
            ));
        };
        let trigger_id = Self::schedule_trigger_id(&job.id)
            .map_err(|error| CronError::Execution(error.to_string()))?;
        let mut request = TriggerDispatchRequest::new(
            trigger_id,
            serde_json::json!({
                "jobId": job.id,
                "scheduledAt": scheduled_at,
            }),
            ActorId::new("cron-scheduler")
                .map_err(|error| CronError::Execution(error.to_string()))?,
            ActorKind::System,
        );
        request.authority_scopes = vec!["cron.write".to_owned()];
        request.idempotency_key = Some(format!(
            "cron-schedule:v1:{}:{}",
            job.id,
            scheduled_at.timestamp_millis()
        ));
        request.delivery_mode = Some(DeliveryMode::Sync);
        let result = EngineTriggerRuntime::dispatch(handle, request).await;
        if let Some(error) = result.error {
            return Err(CronError::Execution(error.to_string()));
        }
        Ok(())
    }

    /// Start a due cron job after scheduler or engine-trigger validation.
    pub async fn start_due_job(
        &self,
        job: CronJob,
        scheduled_at: DateTime<Utc>,
    ) -> Result<CronScheduledFireOutcome, CronError> {
        if job.overlap_policy == OverlapPolicy::Skip
            && let Ok(running) = store::count_running_runs(&self.pool, &job.id)
            && running > 0
        {
            tracing::debug!(job_id = %job.id, "skipping overlapping execution");
            if let Some(next) = compute_next_run(&job.schedule, scheduled_at) {
                store::update_next_run_at(&self.pool, &job.id, Some(next))?;
                let _ = self
                    .runtime
                    .write()
                    .entry(job.id.clone())
                    .and_modify(|state| state.next_run_at = Some(next));
                return Ok(CronScheduledFireOutcome::SkippedOverlap {
                    job_id: job.id,
                    next_run_at: Some(next),
                });
            }
        }

        let sem = self.semaphore_for_payload(&job.payload);
        let permit = sem.try_acquire_owned().map_err(|_| {
            CronError::Execution(format!(
                "concurrency pool saturated for {} payload",
                job.payload.kind_name()
            ))
        })?;

        let job_id = job.id.clone();
        let is_oneshot = matches!(job.schedule, crate::cron::types::Schedule::OneShot { .. });
        let next = compute_next_run(&job.schedule, scheduled_at);
        store::update_next_run_at(&self.pool, &job_id, next)?;
        let _ = self
            .runtime
            .write()
            .entry(job_id.clone())
            .and_modify(|state| state.next_run_at = next);

        if is_oneshot {
            store::disable_job(&self.pool, &job_id)?;
            let _ = self
                .jobs
                .write()
                .entry(job_id.clone())
                .and_modify(|state| state.enabled = false);
        }

        let deps = self.deps.clone();
        let pool = self.pool.clone();
        let clock = self.clock.clone();
        let cancel = self.cancel.child_token();
        let runtime = self.runtime_ref();
        let spawned_job = job.clone();
        self.active_tasks.lock().await.spawn(async move {
            let _permit = permit;
            execute_job(&spawned_job, &deps, &pool, clock.as_ref(), cancel, &runtime).await;
        });

        Ok(CronScheduledFireOutcome::Started {
            job_id,
            next_run_at: next,
        })
    }

    async fn project_engine_triggers_for_current_jobs(&self) -> Result<(), CronError> {
        let jobs = self.jobs();
        let jobs: Vec<_> = jobs.values().cloned().collect();
        self.project_engine_triggers_for_jobs(&jobs).await
    }

    async fn project_engine_triggers_for_jobs(&self, jobs: &[CronJob]) -> Result<(), CronError> {
        let Some(handle) = self.engine_host.get() else {
            return Ok(());
        };
        for job in jobs {
            let trigger = Self::schedule_trigger_definition(job)
                .map_err(|error| CronError::Execution(error.to_string()))?;
            handle
                .register_trigger(trigger, false)
                .await
                .map_err(|error| CronError::Execution(error.to_string()))?;
        }
        Ok(())
    }

    async fn unproject_engine_trigger(&self, job_id: &str) -> Result<(), CronError> {
        let Some(handle) = self.engine_host.get() else {
            return Ok(());
        };
        let trigger_id = Self::schedule_trigger_id(job_id)
            .map_err(|error| CronError::Execution(error.to_string()))?;
        let owner =
            WorkerId::new("cron").map_err(|error| CronError::Execution(error.to_string()))?;
        handle
            .unregister_trigger(&trigger_id, &owner)
            .await
            .map_err(|error| CronError::Execution(error.to_string()))?;
        Ok(())
    }

    async fn drain_completed_tasks(&self) {
        let mut active_tasks = self.active_tasks.lock().await;
        while active_tasks.try_join_next().is_some() {}
    }
}

/// Result of accepting a scheduled cron fire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CronScheduledFireOutcome {
    /// The job was started and a task was spawned.
    Started {
        /// Job id.
        job_id: String,
        /// Next scheduled run after the accepted fire.
        next_run_at: Option<DateTime<Utc>>,
    },
    /// The job was skipped because another run is already active.
    SkippedOverlap {
        /// Job id.
        job_id: String,
        /// Next scheduled run after the skipped fire.
        next_run_at: Option<DateTime<Utc>>,
    },
}

/// Execute a single job (runs in a spawned task).
async fn execute_job(
    job: &CronJob,
    deps: &ExecutorDeps,
    pool: &ConnectionPool,
    clock: &dyn Clock,
    cancel: CancellationToken,
    runtime: &RuntimeMap,
) {
    let run_id = format!("cronrun_{}", Uuid::now_v7());
    let started_at = clock.now_utc();

    // Record running state (DB + in-memory)
    if let Err(e) = store::insert_run(pool, &run_id, &job.id, &job.name, started_at) {
        tracing::error!(job_id = %job.id, error = %e, "failed to insert run record");
        return;
    }
    if let Err(e) = store::set_running_since(pool, &job.id, started_at) {
        tracing::error!(job_id = %job.id, error = %e, "failed to set running_since");
    }
    let _ = runtime
        .write()
        .entry(job.id.clone())
        .and_modify(|s| s.running_since = Some(started_at));

    // Execute with retries
    let clock_ref: &dyn Clock = clock;
    let run = executor::execute_with_retries(
        job,
        deps,
        &run_id,
        started_at,
        || clock_ref.now_utc(),
        cancel,
    )
    .await;

    // Update run record (DB + in-memory)
    if let Err(e) = store::complete_run(pool, &run) {
        tracing::error!(job_id = %job.id, run_id = %run_id, error = %e, "failed to complete run record");
    }
    if let Err(e) = store::clear_running_since(pool, &job.id) {
        tracing::error!(job_id = %job.id, error = %e, "failed to clear running_since");
    }
    if let Err(e) = store::update_last_run_at(pool, &job.id, clock.now_utc()) {
        tracing::error!(job_id = %job.id, error = %e, "failed to update last_run_at");
    }
    let _ = runtime.write().entry(job.id.clone()).and_modify(|s| {
        s.running_since = None;
        s.last_run_at = Some(clock.now_utc());
    });

    // Update consecutive failures
    if run.status == RunStatus::Completed {
        if let Err(e) = store::reset_consecutive_failures(pool, &job.id) {
            tracing::error!(job_id = %job.id, error = %e, "failed to reset consecutive failures");
        }
    } else if let Ok(failures) = store::increment_consecutive_failures(pool, &job.id)
        && job.auto_disable_after > 0
        && failures >= job.auto_disable_after
    {
        if let Err(e) = store::disable_job(pool, &job.id) {
            tracing::error!(job_id = %job.id, error = %e, "failed to auto-disable job");
        }
        tracing::warn!(
            job_id = %job.id,
            job_name = %job.name,
            failures,
            "auto-disabled job after consecutive failures"
        );
        // Notify via push if available
        if let Some(ref notifier) = deps.push_notifier {
            if let Err(e) =
                notifier
                    .notify(
                        &format!("Cron job '{}' auto-disabled", job.name),
                        &format!(
                            "Disabled after {failures} consecutive failures. Re-enable manually.",
                        ),
                    )
                    .await
            {
                tracing::error!(job_id = %job.id, error = %e, "failed to send auto-disable notification");
            }
        }
        // Broadcast event for WebSocket clients
        if let Some(broadcaster) = deps.broadcaster.get() {
            broadcaster
                .broadcast_cron_event(
                    "cron.jobAutoDisabled",
                    serde_json::json!({
                        "jobId": job.id,
                        "jobName": job.name,
                        "consecutiveFailures": failures,
                    }),
                )
                .await;
        }
    }

    // Deliver results
    delivery::deliver(job, &run, deps).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cron::clock::FakeClock;
    use crate::cron::types::*;

    fn setup() -> (
        ConnectionPool,
        Arc<FakeClock>,
        PathBuf,
        PathBuf,
        CancellationToken,
        tempfile::TempDir,
    ) {
        let pool =
            crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
            crate::events::run_migrations(&conn).unwrap();
        }
        let clock = Arc::new(FakeClock::new(
            DateTime::parse_from_rfc3339("2026-02-23T12:00:00Z")
                .unwrap()
                .to_utc(),
        ));
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("automations.json");
        let backup_path = dir.path().join("automations.json.bak");
        let cancel = CancellationToken::new();
        (pool, clock, config_path, backup_path, cancel, dir)
    }

    fn make_deps(pool: &ConnectionPool) -> ExecutorDeps {
        ExecutorDeps {
            agent_executor: None,
            broadcaster: std::sync::OnceLock::new(),
            push_notifier: None,
            event_injector: None,
            http_client: reqwest::Client::new(),
            pool: pool.clone(),
        }
    }

    #[tokio::test]
    async fn scheduler_starts_and_stops() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool,
            clock,
            deps,
            config_path,
            backup_path,
            cancel.clone(),
        ));

        let (h1, h2) = scheduler.start();

        // Let it run briefly
        tokio::time::sleep(Duration::from_millis(100)).await;

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }

    #[tokio::test]
    async fn scheduler_loads_config_on_startup() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();

        // Write a config file
        let job = CronJob {
            id: "cron_1".into(),
            name: "Test".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let config = CronConfig {
            version: 1,
            jobs: vec![job],
        };
        config::save_config(&config_path, &backup_path, &config).unwrap();

        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool,
            clock,
            deps,
            config_path,
            backup_path,
            cancel.clone(),
        ));

        let sched_ref = scheduler.clone();
        let (h1, h2) = scheduler.start();
        tokio::time::sleep(Duration::from_millis(200)).await;

        assert_eq!(sched_ref.job_count(), 1);
        assert!(sched_ref.next_wakeup().is_some());

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }

    #[tokio::test]
    async fn scheduler_does_not_double_fire() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();

        // Set clock to 1ms before 13:00 UTC
        clock.set(
            DateTime::parse_from_rfc3339("2026-02-23T12:59:59.999Z")
                .unwrap()
                .to_utc(),
        );

        let job = CronJob {
            id: "cron_daily".into(),
            name: "Daily 1pm".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Cron {
                expression: "0 13 * * *".into(),
                timezone: "UTC".into(),
            },
            payload: Payload::ShellCommand {
                command: "echo fired".into(),
                working_directory: None,
                timeout_secs: 10,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::Allow,
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let config = CronConfig {
            version: 1,
            jobs: vec![job],
        };
        config::save_config(&config_path, &backup_path, &config).unwrap();

        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool.clone(),
            clock.clone(),
            deps,
            config_path,
            backup_path,
            cancel.clone(),
        ));

        let notify = scheduler.reschedule_notify();
        let (h1, h2) = scheduler.clone().start();
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Advance to exactly 13:00 and wake the scheduler
        clock.set(
            DateTime::parse_from_rfc3339("2026-02-23T13:00:00Z")
                .unwrap()
                .to_utc(),
        );
        notify.notify_one();
        tokio::time::sleep(Duration::from_millis(500)).await;

        // Wake again to give it a chance to double-fire
        notify.notify_one();
        tokio::time::sleep(Duration::from_millis(500)).await;

        // Verify: exactly 1 run, and next_run_at is tomorrow
        let (_runs, total) = store::get_runs(&pool, Some("cron_daily"), None, 10, 0).unwrap();
        assert_eq!(total, 1, "expected exactly 1 run, got {total}");

        let state = scheduler.get_runtime_state("cron_daily").unwrap();
        let next = state.next_run_at.expect("next_run_at should be set");
        let tomorrow_1pm = DateTime::parse_from_rfc3339("2026-02-24T13:00:00Z")
            .unwrap()
            .to_utc();
        assert_eq!(
            next, tomorrow_1pm,
            "next_run_at should be tomorrow at 13:00"
        );

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }

    #[tokio::test]
    async fn reload_config_preserves_next_run_at() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();

        let job = CronJob {
            id: "cron_preserve".into(),
            name: "Preserve Test".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Cron {
                expression: "0 9 * * *".into(),
                timezone: "UTC".into(),
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let config = CronConfig {
            version: 1,
            jobs: vec![job],
        };
        config::save_config(&config_path, &backup_path, &config).unwrap();

        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool.clone(),
            clock.clone(),
            deps,
            config_path.clone(),
            backup_path.clone(),
            cancel.clone(),
        ));

        let (h1, h2) = scheduler.clone().start();
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Capture next_run_at after startup
        let before = scheduler
            .get_runtime_state("cron_preserve")
            .unwrap()
            .next_run_at
            .expect("should have next_run_at");

        // Trigger config reload (same content — no schedule change)
        scheduler.config_notify.notify_one();
        tokio::time::sleep(Duration::from_millis(200)).await;

        let after = scheduler
            .get_runtime_state("cron_preserve")
            .unwrap()
            .next_run_at
            .expect("should still have next_run_at");

        assert_eq!(
            before, after,
            "next_run_at should be preserved on reload with no schedule change"
        );

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }

    #[tokio::test]
    async fn reload_config_recomputes_on_schedule_change() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();

        let job = CronJob {
            id: "cron_change".into(),
            name: "Change Test".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Cron {
                expression: "0 9 * * *".into(),
                timezone: "UTC".into(),
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let config = CronConfig {
            version: 1,
            jobs: vec![job.clone()],
        };
        config::save_config(&config_path, &backup_path, &config).unwrap();

        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool.clone(),
            clock.clone(),
            deps,
            config_path.clone(),
            backup_path.clone(),
            cancel.clone(),
        ));

        let (h1, h2) = scheduler.clone().start();
        tokio::time::sleep(Duration::from_millis(200)).await;

        let before = scheduler
            .get_runtime_state("cron_change")
            .unwrap()
            .next_run_at
            .expect("should have next_run_at");

        // Change schedule from 9 AM to 10 AM
        let mut updated_job = job;
        updated_job.schedule = Schedule::Cron {
            expression: "0 10 * * *".into(),
            timezone: "UTC".into(),
        };
        let new_config = CronConfig {
            version: 1,
            jobs: vec![updated_job],
        };
        config::save_config(&config_path, &backup_path, &new_config).unwrap();

        scheduler.config_notify.notify_one();
        tokio::time::sleep(Duration::from_millis(200)).await;

        let after = scheduler
            .get_runtime_state("cron_change")
            .unwrap()
            .next_run_at
            .expect("should still have next_run_at");

        assert_ne!(
            before, after,
            "next_run_at should change when schedule changes"
        );
        // Clock is at 12:00, so next 10 AM should be tomorrow
        let tomorrow_10am = DateTime::parse_from_rfc3339("2026-02-24T10:00:00Z")
            .unwrap()
            .to_utc();
        assert_eq!(after, tomorrow_10am);

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }

    #[tokio::test]
    async fn scheduler_reschedule_notify_wakes() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool,
            clock,
            deps,
            config_path,
            backup_path,
            cancel.clone(),
        ));

        let notify = scheduler.reschedule_notify();
        let (h1, h2) = scheduler.clone().start();
        tokio::time::sleep(Duration::from_millis(100)).await;

        // This should not deadlock — the scheduler should wake up
        notify.notify_one();
        tokio::time::sleep(Duration::from_millis(100)).await;

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }

    #[test]
    fn detect_stuck_updates_original_run() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = CronScheduler::new(
            pool.clone(),
            clock.clone(),
            deps,
            config_path,
            backup_path,
            cancel,
        );

        // Insert a job with running_since 3 hours ago (timeout is 7200s = 2h)
        let job = CronJob {
            id: "cron_stuck".into(),
            name: "Stuck".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        store::upsert_job(&pool, &job).unwrap();

        let three_hours_ago = clock.now_utc() - chrono::Duration::hours(3);
        store::set_running_since(&pool, "cron_stuck", three_hours_ago).unwrap();

        // Insert the original running run record
        store::insert_run(&pool, "run_orig", "cron_stuck", "Stuck", three_hours_ago).unwrap();

        scheduler.detect_stuck_jobs().unwrap();

        // Original run should be timed_out — no extra records
        let (runs, total) = store::get_runs(&pool, Some("cron_stuck"), None, 10, 0).unwrap();
        assert_eq!(total, 1, "should have exactly 1 run, not a duplicate");
        assert_eq!(runs[0].id, "run_orig");
        assert_eq!(runs[0].status, RunStatus::TimedOut);
        assert!(runs[0].completed_at.is_some());
    }

    #[test]
    fn detect_stuck_creates_synthetic_when_no_run() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = CronScheduler::new(
            pool.clone(),
            clock.clone(),
            deps,
            config_path,
            backup_path,
            cancel,
        );

        let job = CronJob {
            id: "cron_ghost".into(),
            name: "Ghost".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        store::upsert_job(&pool, &job).unwrap();

        let three_hours_ago = clock.now_utc() - chrono::Duration::hours(3);
        store::set_running_since(&pool, "cron_ghost", three_hours_ago).unwrap();
        // No run record exists

        scheduler.detect_stuck_jobs().unwrap();

        // Should create a synthetic timed_out record
        let (runs, total) = store::get_runs(&pool, Some("cron_ghost"), None, 10, 0).unwrap();
        assert_eq!(total, 1);
        assert_eq!(runs[0].status, RunStatus::TimedOut);
    }

    #[tokio::test]
    async fn startup_cleans_orphaned_runs() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();

        // Pre-populate with a job and orphaned running runs
        let job = CronJob {
            id: "cron_orphan".into(),
            name: "Orphan".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };

        // Config must include the job so sync doesn't delete it (and NULL the run job_ids)
        let config = CronConfig {
            version: 1,
            jobs: vec![job.clone()],
        };
        crate::cron::config::save_config(&config_path, &backup_path, &config).unwrap();

        store::upsert_job(&pool, &job).unwrap();
        store::insert_run(&pool, "orphan_1", "cron_orphan", "Orphan", Utc::now()).unwrap();
        store::insert_run(&pool, "orphan_2", "cron_orphan", "Orphan", Utc::now()).unwrap();

        assert_eq!(store::count_running_runs(&pool, "cron_orphan").unwrap(), 2);

        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool.clone(),
            clock,
            deps,
            config_path,
            backup_path,
            cancel.clone(),
        ));
        let (h1, h2) = scheduler.start();
        tokio::time::sleep(Duration::from_millis(200)).await;

        // All orphaned runs should be failed
        assert_eq!(store::count_running_runs(&pool, "cron_orphan").unwrap(), 0);
        let (runs, _) = store::get_runs(&pool, Some("cron_orphan"), Some("failed"), 10, 0).unwrap();
        assert_eq!(runs.len(), 2);

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }

    #[test]
    fn overlap_unblocked_after_stuck_detection() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = CronScheduler::new(
            pool.clone(),
            clock.clone(),
            deps,
            config_path,
            backup_path,
            cancel,
        );

        let job = CronJob {
            id: "cron_overlap".into(),
            name: "Overlap".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::Skip,
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        store::upsert_job(&pool, &job).unwrap();

        let three_hours_ago = clock.now_utc() - chrono::Duration::hours(3);
        store::set_running_since(&pool, "cron_overlap", three_hours_ago).unwrap();
        store::insert_run(&pool, "run_old", "cron_overlap", "Overlap", three_hours_ago).unwrap();

        // Overlap check blocks new runs
        assert_eq!(store::count_running_runs(&pool, "cron_overlap").unwrap(), 1);

        scheduler.detect_stuck_jobs().unwrap();

        // After stuck detection, overlap check should pass
        assert_eq!(store::count_running_runs(&pool, "cron_overlap").unwrap(), 0);
    }

    #[test]
    fn with_jobs_provides_read_access() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = CronScheduler::new(pool, clock, deps, config_path, backup_path, cancel);

        let job = CronJob {
            id: "cron_wj".into(),
            name: "WithJobs".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        scheduler.reload_job(job);

        let count = scheduler.with_jobs(std::collections::HashMap::len);
        assert_eq!(count, 1);
    }

    #[test]
    fn get_job_returns_none_for_missing() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = CronScheduler::new(pool, clock, deps, config_path, backup_path, cancel);

        assert!(scheduler.get_job("nonexistent").is_none());
    }

    /// INVARIANT: a flood of webhook / system-event jobs must not exhaust the
    /// execution budget used by agent / shell work. We split the global
    /// semaphore into two pools so an AgentTurn or ShellCommand always has
    /// dedicated capacity even when every delivery-pool slot is claimed.
    #[tokio::test]
    async fn agent_job_bypasses_delivery_queue() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = CronScheduler::new(pool, clock, deps, config_path, backup_path, cancel);

        // Saturate the delivery pool — simulate a webhook flood that has
        // claimed every lightweight-delivery permit.
        let delivery_sema = scheduler.delivery_semaphore.clone();
        let mut held_delivery = Vec::new();
        while let Ok(permit) = delivery_sema.clone().try_acquire_owned() {
            held_delivery.push(permit);
        }
        assert_eq!(
            delivery_sema.available_permits(),
            0,
            "test precondition: delivery pool must be fully saturated"
        );

        // An AgentTurn job acquires from the EXECUTION pool, which is
        // independent of the delivery pool — it must still get a permit.
        let agent_payload = Payload::AgentTurn {
            prompt: "diagnose".into(),
            model: None,
            workspace_id: None,
            system_prompt: None,
        };
        let agent_sema = scheduler.semaphore_for_payload(&agent_payload);
        let agent_permit = agent_sema
            .try_acquire_owned()
            .expect("agent job must not be starved by saturated delivery queue");

        // ShellCommand shares the execution pool with AgentTurn — also unblocked.
        let shell_payload = Payload::ShellCommand {
            command: "echo hi".into(),
            working_directory: None,
            timeout_secs: 300,
        };
        let shell_sema = scheduler.semaphore_for_payload(&shell_payload);
        let shell_permit = shell_sema
            .try_acquire_owned()
            .expect("shell command must not be starved by saturated delivery queue");

        // Webhook and SystemEvent both draw from the delivery pool — BOTH
        // must resolve to the same semaphore as the saturated one.
        let webhook_payload = Payload::Webhook {
            url: "https://example.invalid/hook".into(),
            method: "POST".into(),
            headers: None,
            body: None,
            timeout_secs: 30,
        };
        let system_event_payload = Payload::SystemEvent {
            session_id: "sess_x".into(),
            message: "note".into(),
        };
        assert!(
            Arc::ptr_eq(
                &scheduler.semaphore_for_payload(&webhook_payload),
                &scheduler.delivery_semaphore
            ),
            "Webhook must route to the delivery semaphore"
        );
        assert!(
            Arc::ptr_eq(
                &scheduler.semaphore_for_payload(&system_event_payload),
                &scheduler.delivery_semaphore
            ),
            "SystemEvent must route to the delivery semaphore"
        );
        assert!(
            Arc::ptr_eq(
                &scheduler.semaphore_for_payload(&agent_payload),
                &scheduler.execution_semaphore
            ),
            "AgentTurn must route to the execution semaphore"
        );
        assert!(
            Arc::ptr_eq(
                &scheduler.semaphore_for_payload(&shell_payload),
                &scheduler.execution_semaphore
            ),
            "ShellCommand must route to the execution semaphore"
        );

        drop(agent_permit);
        drop(shell_permit);
        drop(held_delivery);
    }

    #[test]
    fn get_job_returns_existing() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();
        let deps = make_deps(&pool);
        let scheduler = CronScheduler::new(pool, clock, deps, config_path, backup_path, cancel);

        let job = CronJob {
            id: "cron_gj".into(),
            name: "GetJob".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        scheduler.reload_job(job);

        let result = scheduler.get_job("cron_gj");
        assert!(result.is_some());
        assert_eq!(result.unwrap().name, "GetJob");
    }

    // ── Auto-disable notification tests ───────────────────────────────

    /// Mock push notifier that records calls.
    struct MockPushNotifier {
        calls: parking_lot::Mutex<Vec<(String, String)>>,
    }

    impl MockPushNotifier {
        fn new() -> Self {
            Self {
                calls: parking_lot::Mutex::new(vec![]),
            }
        }
    }

    #[async_trait::async_trait]
    impl executor::PushNotifier for MockPushNotifier {
        async fn notify(&self, title: &str, body: &str) -> Result<(), CronError> {
            self.calls.lock().push((title.to_owned(), body.to_owned()));
            Ok(())
        }
    }

    /// Mock event broadcaster that records calls.
    struct MockEventBroadcaster {
        events: parking_lot::Mutex<Vec<(String, serde_json::Value)>>,
    }

    impl MockEventBroadcaster {
        fn new() -> Self {
            Self {
                events: parking_lot::Mutex::new(vec![]),
            }
        }
    }

    #[async_trait::async_trait]
    impl executor::EventBroadcaster for MockEventBroadcaster {
        async fn broadcast_cron_result(&self, _job: &CronJob, _run: &crate::cron::types::CronRun) {}
        async fn broadcast_cron_event(&self, event_type: &str, payload: serde_json::Value) {
            self.events.lock().push((event_type.to_owned(), payload));
        }
    }

    fn make_failing_job(auto_disable_after: u32) -> CronJob {
        CronJob {
            id: "cron_fail".into(),
            name: "FailJob".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "exit 1".into(),
                working_directory: Some("/tmp".into()),
                timeout_secs: 5,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[tokio::test]
    async fn auto_disable_sends_push_notification() {
        let (pool, clock, _, _, _, _dir) = setup();
        let notifier = Arc::new(MockPushNotifier::new());
        let broadcaster = Arc::new(MockEventBroadcaster::new());

        let deps = ExecutorDeps {
            agent_executor: None,
            broadcaster: {
                let lock = std::sync::OnceLock::new();
                let _ = lock.set(broadcaster.clone() as Arc<dyn executor::EventBroadcaster>);
                lock
            },
            push_notifier: Some(notifier.clone()),
            event_injector: None,
            http_client: reqwest::Client::new(),
            pool: pool.clone(),
        };

        let job = make_failing_job(1); // auto-disable after 1 failure
        // Insert job in DB so store operations work
        store::upsert_job(&pool, &job).unwrap();

        let runtime: RuntimeMap = Arc::new(parking_lot::RwLock::new(HashMap::new()));
        runtime.write().insert(
            job.id.clone(),
            JobRuntimeState {
                job_id: job.id.clone(),
                next_run_at: None,
                last_run_at: None,
                consecutive_failures: 0,
                running_since: None,
            },
        );

        execute_job(
            &job,
            &deps,
            &pool,
            clock.as_ref(),
            CancellationToken::new(),
            &runtime,
        )
        .await;

        // Verify push notification was sent
        let calls = notifier.calls.lock();
        assert_eq!(
            calls.len(),
            1,
            "should have sent exactly 1 push notification"
        );
        assert!(
            calls[0].0.contains("FailJob"),
            "notification title should contain job name"
        );
        assert!(
            calls[0].1.contains('1'),
            "notification body should contain failure count"
        );
    }

    #[tokio::test]
    async fn auto_disable_broadcasts_event() {
        let (pool, clock, _, _, _, _dir) = setup();
        let broadcaster = Arc::new(MockEventBroadcaster::new());

        let deps = ExecutorDeps {
            agent_executor: None,
            broadcaster: {
                let lock = std::sync::OnceLock::new();
                let _ = lock.set(broadcaster.clone() as Arc<dyn executor::EventBroadcaster>);
                lock
            },
            push_notifier: None,
            event_injector: None,
            http_client: reqwest::Client::new(),
            pool: pool.clone(),
        };

        let job = make_failing_job(1);
        store::upsert_job(&pool, &job).unwrap();

        let runtime: RuntimeMap = Arc::new(parking_lot::RwLock::new(HashMap::new()));
        runtime.write().insert(
            job.id.clone(),
            JobRuntimeState {
                job_id: job.id.clone(),
                next_run_at: None,
                last_run_at: None,
                consecutive_failures: 0,
                running_since: None,
            },
        );

        execute_job(
            &job,
            &deps,
            &pool,
            clock.as_ref(),
            CancellationToken::new(),
            &runtime,
        )
        .await;

        // Verify broadcast event
        let events = broadcaster.events.lock();
        assert_eq!(events.len(), 1, "should have broadcast exactly 1 event");
        assert_eq!(events[0].0, "cron.jobAutoDisabled");
        assert_eq!(events[0].1["jobName"], "FailJob");
        assert_eq!(events[0].1["jobId"], "cron_fail");
    }

    #[tokio::test]
    async fn auto_disable_works_without_notifier() {
        let (pool, clock, _, _, _, _dir) = setup();

        let deps = make_deps(&pool); // No notifier, no broadcaster

        let job = make_failing_job(1);
        store::upsert_job(&pool, &job).unwrap();

        let runtime: RuntimeMap = Arc::new(parking_lot::RwLock::new(HashMap::new()));
        runtime.write().insert(
            job.id.clone(),
            JobRuntimeState {
                job_id: job.id.clone(),
                next_run_at: None,
                last_run_at: None,
                consecutive_failures: 0,
                running_since: None,
            },
        );

        // Should not panic even without notifier or broadcaster
        execute_job(
            &job,
            &deps,
            &pool,
            clock.as_ref(),
            CancellationToken::new(),
            &runtime,
        )
        .await;

        // Verify job was disabled in DB
        let conn = pool.get().unwrap();
        let enabled: bool = conn
            .query_row(
                "SELECT enabled FROM cron_jobs WHERE id = 'cron_fail'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            !enabled,
            "job should be disabled after auto_disable_after failures"
        );
    }
}
