//! Main cron scheduling loop.
//!
//! [`CronScheduler`] owns the in-memory job state, the scheduling timer,
//! engine trigger projection, and execution task spawner. It coordinates
//! decision-backed schedule truth, `SQLite` runtime cache, the engine trigger
//! runtime (causal scheduled-fire path), and the executor (payload execution).

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use crate::domains::session::event_store::ConnectionPool;
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::domains::cron::clock::Clock;
use crate::domains::cron::config;
use crate::domains::cron::delivery;
use crate::domains::cron::errors::CronError;
use crate::domains::cron::executor::{self, ExecutorDeps};
use crate::domains::cron::schedule::compute_next_run;
use crate::domains::cron::store;
use crate::domains::cron::types::{
    CronJob, JobRuntimeState, MisfirePolicy, OverlapPolicy, RunStatus,
};
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
    /// In-memory job definitions (synced from decision resources).
    jobs: parking_lot::RwLock<HashMap<String, CronJob>>,
    /// Runtime state per job (synced from `SQLite`). Arc-wrapped for sharing
    /// with spawned execution tasks.
    runtime: RuntimeMap,
    /// Serializes schedule truth projection into runtime cache.
    schedule_truth_lock: tokio::sync::Mutex<()>,
    /// Wakes scheduler when schedule truth should be reloaded.
    schedule_truth_notify: Arc<tokio::sync::Notify>,
    /// Wakes scheduler when engine capability mutates a job.
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
    /// In-memory schedule truth for scheduler unit tests.
    #[cfg(test)]
    test_schedule_truth: parking_lot::RwLock<Option<Vec<CronJob>>>,
}

impl CronScheduler {
    /// Create a new scheduler.
    pub fn new(
        pool: ConnectionPool,
        clock: Arc<dyn Clock>,
        deps: ExecutorDeps,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            pool,
            clock,
            jobs: parking_lot::RwLock::new(HashMap::new()),
            runtime: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            schedule_truth_lock: tokio::sync::Mutex::new(()),
            schedule_truth_notify: Arc::new(tokio::sync::Notify::new()),
            reschedule_notify: Arc::new(tokio::sync::Notify::new()),
            cancel,
            execution_semaphore: Arc::new(tokio::sync::Semaphore::new(DEFAULT_EXECUTION_LIMIT)),
            delivery_semaphore: Arc::new(tokio::sync::Semaphore::new(DEFAULT_DELIVERY_LIMIT)),
            deps: Arc::new(deps),
            engine_host: OnceLock::new(),
            active_tasks: tokio::sync::Mutex::new(tokio::task::JoinSet::new()),
            #[cfg(test)]
            test_schedule_truth: parking_lot::RwLock::new(None),
        }
    }

    /// Set the engine event publisher (must be called before `start()`).
    ///
    /// The event_publisher comes from `TronServer`, which is created after the
    /// scheduler. Uses `OnceLock` internally — calling twice is a no-op.
    pub fn set_event_publisher(
        &self,
        event_publisher: Arc<dyn crate::domains::cron::executor::EventPublisher>,
    ) {
        let _ = self.deps.event_publisher.set(event_publisher);
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

    /// Get the lock used to serialize schedule-truth projection.
    pub fn schedule_truth_lock(&self) -> &tokio::sync::Mutex<()> {
        &self.schedule_truth_lock
    }

    /// Get the connection pool.
    pub fn pool(&self) -> &ConnectionPool {
        &self.pool
    }

    /// Get the clock.
    pub fn clock(&self) -> &dyn Clock {
        &*self.clock
    }

    #[cfg(test)]
    fn set_test_schedule_truth(&self, jobs: Vec<CronJob>) {
        *self.test_schedule_truth.write() = Some(jobs);
        self.schedule_truth_notify.notify_one();
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

    /// Reload a single job into in-memory state (after engine capability mutation).
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
        payload: &crate::domains::cron::types::Payload,
    ) -> Arc<tokio::sync::Semaphore> {
        use crate::domains::cron::types::Payload;
        match payload {
            Payload::AgentTurn { .. } | Payload::ShellCommand { .. } => {
                self.execution_semaphore.clone()
            }
            Payload::Webhook { .. } | Payload::SystemEvent { .. } => {
                self.delivery_semaphore.clone()
            }
        }
    }

    /// Start the scheduler and schedule-truth watcher. Returns join handles.
    pub fn start(self: Arc<Self>) -> (JoinHandle<()>, JoinHandle<()>) {
        let sched = self.clone();
        let watcher = self.clone();

        let sched_handle = tokio::spawn(async move { sched.run_scheduler().await });
        let watcher_handle =
            tokio::spawn(async move { watcher.run_schedule_truth_watcher().await });

        (sched_handle, watcher_handle)
    }

    /// Initial startup: load schedule resources, sync runtime cache, handle misfires.
    async fn startup(&self) -> Result<(), CronError> {
        let _guard = self.schedule_truth_lock.lock().await;
        let jobs = self.load_schedule_truth().await?;

        // Validate jobs
        for job in &jobs {
            if let Err(e) = config::validate_job(job) {
                tracing::warn!(job_id = %job.id, error = %e, "invalid job in schedule resources, skipping");
            }
        }

        let (added, updated, removed) = store::sync_job_cache(&self.pool, &jobs)?;
        tracing::info!(
            added,
            updated,
            removed,
            "schedule resources synced to runtime cache"
        );

        // Load into memory
        {
            let mut job_map = self.jobs.write();
            job_map.clear();
            for job in &jobs {
                let _ = job_map.insert(job.id.clone(), job.clone());
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
        for job in &jobs {
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

        self.project_engine_triggers_for_jobs(&jobs).await?;

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

                () = self.schedule_truth_notify.notified() => {
                    if let Err(e) = self.reload_schedule_truth().await {
                        tracing::warn!(error = %e, "schedule resource reload failed");
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

    /// Reserved watcher slot for future resource watch integration.
    async fn run_schedule_truth_watcher(self: Arc<Self>) {
        self.cancel.cancelled().await;
    }

    /// Reload schedule resources and sync to memory + runtime cache.
    async fn reload_schedule_truth(&self) -> Result<(), CronError> {
        let _guard = self.schedule_truth_lock.lock().await;
        let jobs_from_truth = self.load_schedule_truth().await?;
        let (added, updated, removed) = store::sync_job_cache(&self.pool, &jobs_from_truth)?;
        tracing::info!(added, updated, removed, "schedule resources reloaded");

        let config_ids: HashSet<String> = jobs_from_truth.iter().map(|j| j.id.clone()).collect();
        let now = self.clock.now_utc();

        let removed_ids = {
            // Update in-memory state.
            let mut jobs = self.jobs.write();

            // Remove jobs no longer in schedule resources.
            let removed_ids: Vec<String> = jobs
                .keys()
                .filter(|id| !config_ids.contains(*id))
                .cloned()
                .collect();
            jobs.retain(|id, _| config_ids.contains(id));

            // Add/update jobs from schedule resources.
            for job in jobs_from_truth {
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

    async fn load_schedule_truth(&self) -> Result<Vec<CronJob>, CronError> {
        #[cfg(test)]
        if let Some(jobs) = self.test_schedule_truth.read().clone() {
            return Ok(jobs);
        }

        let Some(engine_host) = self.engine_host.get() else {
            tracing::warn!("cron scheduler started without engine host; no schedule truth loaded");
            return Ok(Vec::new());
        };
        crate::domains::cron::truth::list_schedule_records(engine_host, None)
            .await
            .map(|records| records.into_iter().map(|record| record.job).collect())
            .map_err(|error| CronError::Execution(error.to_string()))
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
                    let run = crate::domains::cron::types::CronRun {
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
                        model_routing: None,
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
        let is_oneshot = matches!(
            job.schedule,
            crate::domains::cron::types::Schedule::OneShot { .. }
        );
        let next = compute_next_run(&job.schedule, scheduled_at);
        store::update_next_run_at(&self.pool, &job_id, next)?;
        let _ = self
            .runtime
            .write()
            .entry(job_id.clone())
            .and_modify(|state| state.next_run_at = next);

        if is_oneshot {
            store::disable_job(&self.pool, &job_id)?;
            if let Some(engine_host) = self.engine_host.get()
                && let Err(error) = crate::domains::cron::truth::set_schedule_enabled(
                    engine_host,
                    &job_id,
                    false,
                    "one-shot schedule completed",
                )
                .await
            {
                tracing::error!(
                    job_id = %job_id,
                    error = %error,
                    "failed to disable one-shot schedule decision"
                );
            }
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
        // Publish event for engine stream subscribers.
        if let Some(event_publisher) = deps.event_publisher.get() {
            event_publisher
                .publish_cron_event(
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
#[path = "scheduler/tests.rs"]
mod tests;
