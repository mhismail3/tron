//! Main cron scheduling loop.
//!
//! [`CronScheduler`] owns the in-memory job state, the scheduling timer,
//! config file watcher, and execution task spawner. It coordinates between
//! the config file (canonical definitions), SQLite (runtime state), and
//! the executor (payload execution).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tron_events::ConnectionPool;
use uuid::Uuid;

use crate::clock::Clock;
use crate::config::{self, FileFingerprint};
use crate::delivery;
use crate::errors::CronError;
use crate::executor::{self, ExecutorDeps};
use crate::schedule::compute_next_run;
use crate::store;
use crate::types::{CronJob, JobRuntimeState, MisfirePolicy, OverlapPolicy, RunStatus};

/// Default global execution concurrency limit.
const DEFAULT_EXECUTION_LIMIT: usize = 10;

/// Main cron scheduler.
pub struct CronScheduler {
    pool: ConnectionPool,
    clock: Arc<dyn Clock>,
    /// In-memory job definitions (synced from file).
    jobs: parking_lot::RwLock<HashMap<String, CronJob>>,
    /// Runtime state per job (synced from SQLite).
    runtime: parking_lot::RwLock<HashMap<String, JobRuntimeState>>,
    /// Serializes all access to `automations.json`.
    config_lock: tokio::sync::Mutex<()>,
    /// Wakes scheduler when config file changes.
    config_notify: Arc<tokio::sync::Notify>,
    /// Wakes scheduler when RPC mutates a job.
    reschedule_notify: Arc<tokio::sync::Notify>,
    /// Shutdown signal.
    cancel: CancellationToken,
    /// Global execution concurrency limiter.
    execution_semaphore: Arc<tokio::sync::Semaphore>,
    /// Executor dependencies.
    deps: Arc<ExecutorDeps>,
    /// Path to `automations.json`.
    config_path: PathBuf,
    /// Path to `automations.json.bak` (in deployment directory).
    backup_path: PathBuf,
    /// Whether this instance is the production server (port 9847).
    is_production: bool,
}

impl CronScheduler {
    /// Create a new scheduler.
    ///
    /// `is_production` controls whether `prod_only` jobs are eligible to run.
    /// Pass `true` for the production instance (port 9847), `false` otherwise.
    pub fn new(
        pool: ConnectionPool,
        clock: Arc<dyn Clock>,
        deps: ExecutorDeps,
        config_path: PathBuf,
        backup_path: PathBuf,
        cancel: CancellationToken,
        is_production: bool,
    ) -> Self {
        Self {
            pool,
            clock,
            jobs: parking_lot::RwLock::new(HashMap::new()),
            runtime: parking_lot::RwLock::new(HashMap::new()),
            config_lock: tokio::sync::Mutex::new(()),
            config_notify: Arc::new(tokio::sync::Notify::new()),
            reschedule_notify: Arc::new(tokio::sync::Notify::new()),
            cancel,
            execution_semaphore: Arc::new(tokio::sync::Semaphore::new(DEFAULT_EXECUTION_LIMIT)),
            deps: Arc::new(deps),
            config_path,
            backup_path,
            is_production,
        }
    }

    /// Set the WebSocket broadcaster (must be called before `start()`).
    ///
    /// The broadcaster comes from `TronServer`, which is created after the
    /// scheduler. Uses `OnceLock` internally — calling twice is a no-op.
    pub fn set_broadcaster(&self, broadcaster: Arc<dyn crate::executor::EventBroadcaster>) {
        let _ = self.deps.broadcaster.set(broadcaster);
    }

    /// Get the reschedule notify handle (for RPC handlers to wake the scheduler).
    pub fn reschedule_notify(&self) -> Arc<tokio::sync::Notify> {
        self.reschedule_notify.clone()
    }

    /// Get the config lock (for RPC handlers to serialize config access).
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

    /// Get runtime state for a job.
    pub fn get_runtime_state(&self, job_id: &str) -> Option<JobRuntimeState> {
        self.runtime.read().get(job_id).cloned()
    }

    /// Reload a single job into in-memory state (after RPC mutation).
    pub fn reload_job(&self, job: CronJob) {
        self.jobs.write().insert(job.id.clone(), job);
    }

    /// Remove a job from in-memory state.
    pub fn remove_job(&self, job_id: &str) {
        self.jobs.write().remove(job_id);
        self.runtime.write().remove(job_id);
    }

    /// Update runtime state for a job in memory.
    pub fn update_runtime(&self, state: JobRuntimeState) {
        self.runtime.write().insert(state.job_id.clone(), state);
    }

    /// Get next wakeup time across all enabled jobs.
    pub fn next_wakeup(&self) -> Option<DateTime<Utc>> {
        self.runtime
            .read()
            .values()
            .filter_map(|s| s.next_run_at)
            .min()
    }

    /// Count currently running executions.
    pub fn active_run_count(&self) -> usize {
        DEFAULT_EXECUTION_LIMIT - self.execution_semaphore.available_permits()
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

        // Load config (with SQLite fallback if file is corrupt)
        let config = match config::load_config(&self.config_path, &self.backup_path) {
            Ok(c) => c,
            Err(e) => {
                tracing::error!(
                    error = %e,
                    "config file corrupt and backup recovery failed, falling back to SQLite definitions"
                );
                // Reconstruct config from SQLite-stored job definitions
                let jobs = store::list_all_jobs(&self.pool)?;
                if jobs.is_empty() {
                    tracing::warn!("no jobs found in SQLite fallback, starting with empty config");
                }

                // Broadcast config error event if broadcaster is available
                if let Some(broadcaster) = self.deps.broadcaster.get() {
                    let payload = serde_json::json!({
                        "error": e.to_string(),
                        "recoveredFromSqlite": !jobs.is_empty(),
                        "jobCount": jobs.len(),
                    });
                    let broadcaster = broadcaster.clone();
                    tokio::spawn(async move {
                        broadcaster.broadcast_cron_event("cron.configError", payload).await;
                    });
                }

                crate::types::CronConfig {
                    version: 1,
                    jobs,
                }
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
                jobs.insert(job.id.clone(), job.clone());
            }
        }

        // Detect stuck jobs
        self.detect_stuck_jobs()?;

        // Apply misfire policy and compute next_run_at
        let now = self.clock.now_utc();
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

            store::update_next_run_at(&self.pool, &job.id, new_next)?;
            self.runtime.write().insert(
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

        Ok(())
    }

    /// Main scheduling loop.
    async fn run_scheduler(self: Arc<Self>) {
        if let Err(e) = self.startup().await {
            tracing::error!(error = %e, "cron scheduler startup failed");
            return;
        }

        tracing::info!(
            job_count = self.job_count(),
            "cron scheduler started"
        );

        let mut last_maintenance = self.clock.now_utc();
        let mut active_tasks: tokio::task::JoinSet<()> = tokio::task::JoinSet::new();

        loop {
            let now = self.clock.now_utc();

            // Compute sleep duration until next job
            let sleep_duration = self
                .next_wakeup()
                .map(|next| {
                    let diff = next - now;
                    if diff.num_milliseconds() <= 0 {
                        Duration::from_millis(0)
                    } else {
                        Duration::from_millis(diff.num_milliseconds().min(60_000) as u64)
                    }
                })
                .unwrap_or(Duration::from_secs(60));

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
                            .filter(|j| !j.prod_only || self.is_production)
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
                        // Check overlap policy
                        if job.overlap_policy == OverlapPolicy::Skip {
                            if let Ok(running) = store::count_running_runs(&self.pool, &job.id) {
                                if running > 0 {
                                    tracing::debug!(job_id = %job.id, "skipping overlapping execution");
                                    // Still update next_run_at
                                    if let Some(next) = compute_next_run(&job.schedule, *scheduled_at) {
                                        let _ = store::update_next_run_at(&self.pool, &job.id, Some(next));
                                        self.runtime.write().entry(job.id.clone()).and_modify(|s| s.next_run_at = Some(next));
                                    }
                                    continue;
                                }
                            }
                        }

                        // Acquire execution semaphore
                        let permit = match self.execution_semaphore.clone().try_acquire_owned() {
                            Ok(p) => p,
                            Err(_) => {
                                tracing::warn!(job_id = %job.id, "global execution limit reached, skipping");
                                continue;
                            }
                        };

                        // Capture job_id before moving job into the async block
                        let job_id = job.id.clone();
                        let is_oneshot = matches!(job.schedule, crate::types::Schedule::OneShot { .. });

                        // Update next_run_at immediately (before spawn)
                        let next = compute_next_run(&job.schedule, *scheduled_at);
                        let _ = store::update_next_run_at(&self.pool, &job_id, next);
                        self.runtime.write().entry(job_id.clone()).and_modify(|s| s.next_run_at = next);

                        // Auto-disable one-shot after scheduling
                        if is_oneshot {
                            let _ = store::disable_job(&self.pool, &job_id);
                            self.jobs.write().entry(job_id.clone()).and_modify(|j| j.enabled = false);
                        }

                        // Spawn execution
                        let job = job.clone();
                        let deps = self.deps.clone();
                        let pool = self.pool.clone();
                        let clock = self.clock.clone();
                        let cancel = self.cancel.child_token();

                        active_tasks.spawn(async move {
                            let _permit = permit;
                            execute_job(&job, &deps, &pool, clock.as_ref(), cancel).await;
                        });
                    }

                    // Periodic maintenance (every 5 minutes)
                    if (now - last_maintenance).num_seconds() >= 300 {
                        self.detect_stuck_jobs().ok();
                        let cutoff = now - chrono::Duration::days(7);
                        store::gc_old_runs(&self.pool, cutoff, 100).ok();
                        last_maintenance = now;
                    }

                    // Drain completed tasks
                    while active_tasks.try_join_next().is_some() {}
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

    /// Reload config from disk and sync to memory + SQLite.
    async fn reload_config(&self) -> Result<(), CronError> {
        let _guard = self.config_lock.lock().await;
        let config = config::load_config(&self.config_path, &self.backup_path)?;
        let (added, updated, removed) = store::sync_from_config(&self.pool, &config.jobs)?;
        tracing::info!(added, updated, removed, "config reloaded");

        // Update in-memory state
        let mut jobs = self.jobs.write();
        let config_ids: std::collections::HashSet<String> =
            config.jobs.iter().map(|j| j.id.clone()).collect();

        // Remove jobs no longer in config
        jobs.retain(|id, _| config_ids.contains(id));

        // Add/update jobs from config
        let now = self.clock.now_utc();
        for job in config.jobs {
            if job.enabled {
                let schedule_changed = jobs
                    .get(&job.id)
                    .map_or(true, |old| old.schedule != job.schedule);
                let has_runtime = self
                    .runtime
                    .read()
                    .get(&job.id)
                    .and_then(|s| s.next_run_at)
                    .is_some();

                if schedule_changed || !has_runtime {
                    let next = compute_next_run(&job.schedule, now);
                    let _ = store::update_next_run_at(&self.pool, &job.id, next);
                    self.runtime
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
            jobs.insert(job.id.clone(), job);
        }

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

                // Record a timed_out run
                let run_id = format!("cronrun_{}", Uuid::now_v7());
                let _ = store::insert_run(&self.pool, &run_id, &job_id, "stuck", since);
                let run = crate::types::CronRun {
                    id: run_id,
                    job_id: Some(job_id.clone()),
                    job_name: "stuck".into(),
                    status: RunStatus::TimedOut,
                    started_at: since,
                    completed_at: Some(now),
                    duration_ms: Some((now - since).num_milliseconds()),
                    output: None,
                    output_truncated: false,
                    error: Some("stuck job cleared on startup/maintenance".into()),
                    exit_code: None,
                    attempt: 0,
                    session_id: None,
                    delivery_status: None,
                };
                let _ = store::complete_run(&self.pool, &run);
                store::clear_running_since(&self.pool, &job_id)?;
                let _ = store::increment_consecutive_failures(&self.pool, &job_id);
            }
        }

        Ok(())
    }

}

/// Execute a single job (runs in a spawned task).
async fn execute_job(
    job: &CronJob,
    deps: &ExecutorDeps,
    pool: &ConnectionPool,
    clock: &dyn Clock,
    cancel: CancellationToken,
) {
    let run_id = format!("cronrun_{}", Uuid::now_v7());
    let started_at = clock.now_utc();

    // Record running state
    if let Err(e) = store::insert_run(pool, &run_id, &job.id, &job.name, started_at) {
        tracing::error!(job_id = %job.id, error = %e, "failed to insert run record");
        return;
    }
    let _ = store::set_running_since(pool, &job.id, started_at);

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

    // Update run record
    let _ = store::complete_run(pool, &run);
    let _ = store::clear_running_since(pool, &job.id);
    let _ = store::update_last_run_at(pool, &job.id, clock.now_utc());

    // Update consecutive failures
    if run.status == RunStatus::Completed {
        let _ = store::reset_consecutive_failures(pool, &job.id);
    } else {
        if let Ok(failures) = store::increment_consecutive_failures(pool, &job.id) {
            if job.auto_disable_after > 0 && failures >= job.auto_disable_after {
                let _ = store::disable_job(pool, &job.id);
                tracing::warn!(
                    job_id = %job.id,
                    failures,
                    "auto-disabled after consecutive failures"
                );
            }
        }
    }

    // Deliver results
    delivery::deliver(job, &run, deps).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::FakeClock;
    use crate::types::*;

    fn setup() -> (ConnectionPool, Arc<FakeClock>, PathBuf, PathBuf, CancellationToken, tempfile::TempDir) {
        let pool =
            tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
            crate::migrations::run_migrations(&conn).unwrap();
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
            true,
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
            prod_only: false,
            tags: vec![],
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
            true,
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
            prod_only: false,
            tags: vec![],
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
            true,
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
        assert_eq!(next, tomorrow_1pm, "next_run_at should be tomorrow at 13:00");

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
            prod_only: false,
            tags: vec![],
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
            true,
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

        assert_eq!(before, after, "next_run_at should be preserved on reload with no schedule change");

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
            prod_only: false,
            tags: vec![],
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
            true,
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

        assert_ne!(before, after, "next_run_at should change when schedule changes");
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
            true,
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

    #[tokio::test]
    async fn scheduler_skips_prod_only_on_non_prod() {
        let (pool, clock, config_path, backup_path, cancel, _dir) = setup();

        // Set clock so the job is immediately due
        clock.set(
            DateTime::parse_from_rfc3339("2026-02-23T13:00:00Z")
                .unwrap()
                .to_utc(),
        );

        let job = CronJob {
            id: "cron_prod_only".into(),
            name: "Prod Only Job".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo prod".into(),
                working_directory: None,
                timeout_secs: 10,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::Allow,
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            prod_only: true,
            tags: vec![],
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let config = CronConfig {
            version: 1,
            jobs: vec![job],
        };
        config::save_config(&config_path, &backup_path, &config).unwrap();

        // Create scheduler with is_production = false
        let deps = make_deps(&pool);
        let scheduler = Arc::new(CronScheduler::new(
            pool.clone(),
            clock.clone(),
            deps,
            config_path,
            backup_path,
            cancel.clone(),
            false,
        ));

        let notify = scheduler.reschedule_notify();
        let (h1, h2) = scheduler.clone().start();
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Wake the scheduler multiple times
        notify.notify_one();
        tokio::time::sleep(Duration::from_millis(500)).await;
        notify.notify_one();
        tokio::time::sleep(Duration::from_millis(500)).await;

        // No runs should have been created
        let (_runs, total) = store::get_runs(&pool, Some("cron_prod_only"), None, 10, 0).unwrap();
        assert_eq!(total, 0, "prod_only job should not fire on non-prod instance");

        cancel.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
    }
}
