use super::*;
use crate::domains::cron::clock::FakeClock;
use crate::domains::cron::types::*;

fn setup() -> (
    ConnectionPool,
    Arc<FakeClock>,
    CancellationToken,
    tempfile::TempDir,
) {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    let clock = Arc::new(FakeClock::new(
        DateTime::parse_from_rfc3339("2026-02-23T12:00:00Z")
            .unwrap()
            .to_utc(),
    ));
    let dir = tempfile::tempdir().unwrap();
    let cancel = CancellationToken::new();
    (pool, clock, cancel, dir)
}

fn make_deps(pool: &ConnectionPool) -> ExecutorDeps {
    ExecutorDeps {
        agent_executor: None,
        event_publisher: std::sync::OnceLock::new(),
        push_notifier: None,
        event_injector: None,
        http_client: reqwest::Client::new(),
        pool: pool.clone(),
    }
}

#[tokio::test]
async fn scheduler_starts_and_stops() {
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = Arc::new(CronScheduler::new(pool, clock, deps, cancel.clone()));

    let (h1, h2) = scheduler.start();

    // Let it run briefly
    tokio::time::sleep(Duration::from_millis(100)).await;

    cancel.cancel();
    let _ = tokio::time::timeout(Duration::from_secs(5), h1).await;
    let _ = tokio::time::timeout(Duration::from_secs(5), h2).await;
}

#[tokio::test]
async fn scheduler_loads_schedule_truth_on_startup() {
    let (pool, clock, cancel, _dir) = setup();

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
        capability_restrictions: None,
        workspace_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    };
    let deps = make_deps(&pool);
    let scheduler = Arc::new(CronScheduler::new(pool, clock, deps, cancel.clone()));
    scheduler.set_test_schedule_truth(vec![job]);

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
    let (pool, clock, cancel, _dir) = setup();

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
        capability_restrictions: None,
        workspace_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    };
    let deps = make_deps(&pool);
    let scheduler = Arc::new(CronScheduler::new(
        pool.clone(),
        clock.clone(),
        deps,
        cancel.clone(),
    ));
    scheduler.set_test_schedule_truth(vec![job]);

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
async fn reload_schedule_truth_preserves_next_run_at() {
    let (pool, clock, cancel, _dir) = setup();

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
        capability_restrictions: None,
        workspace_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    };
    let deps = make_deps(&pool);
    let scheduler = Arc::new(CronScheduler::new(
        pool.clone(),
        clock.clone(),
        deps,
        cancel.clone(),
    ));
    scheduler.set_test_schedule_truth(vec![job]);

    let (h1, h2) = scheduler.clone().start();
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Capture next_run_at after startup
    let before = scheduler
        .get_runtime_state("cron_preserve")
        .unwrap()
        .next_run_at
        .expect("should have next_run_at");

    // Trigger schedule-truth reload (same content — no schedule change)
    scheduler.schedule_truth_notify.notify_one();
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
async fn reload_schedule_truth_recomputes_on_schedule_change() {
    let (pool, clock, cancel, _dir) = setup();

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
        capability_restrictions: None,
        workspace_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    };
    let deps = make_deps(&pool);
    let scheduler = Arc::new(CronScheduler::new(
        pool.clone(),
        clock.clone(),
        deps,
        cancel.clone(),
    ));
    scheduler.set_test_schedule_truth(vec![job.clone()]);

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
    scheduler.set_test_schedule_truth(vec![updated_job]);
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
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = Arc::new(CronScheduler::new(pool, clock, deps, cancel.clone()));

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
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = CronScheduler::new(pool.clone(), clock.clone(), deps, cancel);

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
        capability_restrictions: None,
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
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = CronScheduler::new(pool.clone(), clock.clone(), deps, cancel);

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
        capability_restrictions: None,
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
    let (pool, clock, cancel, _dir) = setup();

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
        capability_restrictions: None,
        workspace_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    };

    store::upsert_job(&pool, &job).unwrap();
    store::insert_run(&pool, "orphan_1", "cron_orphan", "Orphan", Utc::now()).unwrap();
    store::insert_run(&pool, "orphan_2", "cron_orphan", "Orphan", Utc::now()).unwrap();

    assert_eq!(store::count_running_runs(&pool, "cron_orphan").unwrap(), 2);

    let deps = make_deps(&pool);
    let scheduler = Arc::new(CronScheduler::new(
        pool.clone(),
        clock,
        deps,
        cancel.clone(),
    ));
    scheduler.set_test_schedule_truth(vec![job.clone()]);
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
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = CronScheduler::new(pool.clone(), clock.clone(), deps, cancel);

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
        capability_restrictions: None,
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
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = CronScheduler::new(pool, clock, deps, cancel);

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
        capability_restrictions: None,
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
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = CronScheduler::new(pool, clock, deps, cancel);

    assert!(scheduler.get_job("nonexistent").is_none());
}

/// INVARIANT: a flood of webhook / system-event jobs must not exhaust the
/// execution budget used by agent / shell work. We split the global
/// semaphore into two pools so an AgentTurn or ShellCommand always has
/// dedicated capacity even when every delivery-pool slot is claimed.
#[tokio::test]
async fn agent_job_bypasses_delivery_queue() {
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = CronScheduler::new(pool, clock, deps, cancel);

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
    let (pool, clock, cancel, _dir) = setup();
    let deps = make_deps(&pool);
    let scheduler = CronScheduler::new(pool, clock, deps, cancel);

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
        capability_restrictions: None,
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

/// Mock engine event publisher that records calls.
struct MockEventPublisher {
    events: parking_lot::Mutex<Vec<(String, serde_json::Value)>>,
}

impl MockEventPublisher {
    fn new() -> Self {
        Self {
            events: parking_lot::Mutex::new(vec![]),
        }
    }
}

#[async_trait::async_trait]
impl executor::EventPublisher for MockEventPublisher {
    async fn publish_cron_result(
        &self,
        _job: &CronJob,
        _run: &crate::domains::cron::types::CronRun,
    ) {
    }
    async fn publish_cron_event(&self, event_type: &str, payload: serde_json::Value) {
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
        capability_restrictions: None,
        workspace_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    }
}

#[tokio::test]
async fn auto_disable_sends_push_notification() {
    let (pool, clock, _cancel, _dir) = setup();
    let notifier = Arc::new(MockPushNotifier::new());
    let event_publisher = Arc::new(MockEventPublisher::new());

    let deps = ExecutorDeps {
        agent_executor: None,
        event_publisher: {
            let lock = std::sync::OnceLock::new();
            let _ = lock.set(event_publisher.clone() as Arc<dyn executor::EventPublisher>);
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
async fn auto_disable_publishes_event() {
    let (pool, clock, _cancel, _dir) = setup();
    let event_publisher = Arc::new(MockEventPublisher::new());

    let deps = ExecutorDeps {
        agent_executor: None,
        event_publisher: {
            let lock = std::sync::OnceLock::new();
            let _ = lock.set(event_publisher.clone() as Arc<dyn executor::EventPublisher>);
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

    // Verify published event.
    let events = event_publisher.events.lock();
    assert_eq!(events.len(), 1, "should have published exactly 1 event");
    assert_eq!(events[0].0, "cron.jobAutoDisabled");
    assert_eq!(events[0].1["jobName"], "FailJob");
    assert_eq!(events[0].1["jobId"], "cron_fail");
}

#[tokio::test]
async fn auto_disable_works_without_notifier() {
    let (pool, clock, _cancel, _dir) = setup();

    let deps = make_deps(&pool); // No notifier, no event_publisher

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

    // Should not panic even without notifier or event_publisher
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
