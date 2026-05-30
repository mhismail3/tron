use super::*;
use crate::domains::cron::types::*;

fn make_shell_job(cmd: &str) -> CronJob {
    CronJob {
        id: "cron_test".into(),
        name: "Test".into(),
        description: None,
        enabled: true,
        schedule: Schedule::Every {
            interval_secs: 60,
            anchor: None,
        },
        payload: Payload::ShellCommand {
            command: cmd.into(),
            working_directory: None,
            timeout_secs: 10,
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
        created_at: chrono::Utc::now(),
        updated_at: chrono::Utc::now(),
    }
}

fn make_test_deps() -> ExecutorDeps {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    ExecutorDeps {
        agent_executor: None,
        event_publisher: std::sync::OnceLock::new(),
        push_notifier: None,
        event_injector: None,
        http_client: reqwest::Client::new(),
        pool,
    }
}

#[tokio::test]
async fn shell_command_captures_stdout() {
    let output = execute_shell("echo hello", Some("/tmp"), 10, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(output.stdout.trim(), "hello");
}

#[tokio::test]
async fn shell_command_exit_code() {
    let result = execute_shell("exit 42", Some("/tmp"), 10, CancellationToken::new()).await;
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("exit code 42"));
}

#[tokio::test]
async fn shell_command_timeout() {
    let result = execute_shell("sleep 60", Some("/tmp"), 1, CancellationToken::new()).await;
    assert!(matches!(result, Err(CronError::TimedOut)));
}

#[tokio::test]
async fn shell_command_kill_on_cancel() {
    let cancel = CancellationToken::new();
    let cancel2 = cancel.clone();

    let handle =
        tokio::spawn(async move { execute_shell("sleep 60", Some("/tmp"), 300, cancel2).await });

    tokio::time::sleep(Duration::from_millis(100)).await;
    cancel.cancel();

    let result = handle.await.unwrap();
    assert!(matches!(result, Err(CronError::Cancelled(_))));
}

#[tokio::test]
async fn shell_command_working_directory() {
    let dir = tempfile::tempdir().unwrap();
    let output = execute_shell(
        "pwd",
        Some(dir.path().to_str().unwrap()),
        10,
        CancellationToken::new(),
    )
    .await
    .unwrap();
    assert!(output.stdout.trim().contains(dir.path().to_str().unwrap()));
}

#[tokio::test]
async fn agent_turn_no_executor_available() {
    let deps = make_test_deps();
    let job = CronJob {
        payload: Payload::AgentTurn {
            prompt: "hello".into(),
            model: None,
            workspace_id: None,
            system_prompt: None,
        },
        ..make_shell_job("echo")
    };
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("not available"));
}

#[tokio::test]
async fn system_event_missing_injector() {
    let deps = make_test_deps();
    let job = CronJob {
        payload: Payload::SystemEvent {
            session_id: "sess_1".into(),
            message: "hello".into(),
        },
        ..make_shell_job("echo")
    };
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn shell_command_captures_stderr() {
    let output = execute_shell("echo err >&2", Some("/tmp"), 10, CancellationToken::new())
        .await
        .unwrap();
    assert!(output.stderr.trim().contains("err"));
}

#[tokio::test]
async fn shell_command_output_bounded() {
    // Generate 2MB of output — should be truncated to ~1MB
    let output = execute_shell(
        "dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\0' 'A'",
        Some("/tmp"),
        30,
        CancellationToken::new(),
    )
    .await
    .unwrap();
    assert!(output.truncated);
    assert!(output.stdout.len() <= 1_048_576);
}

// ── Mock AgentTurnExecutor ──────────────────────────────────────

struct MockAgentExecutor {
    response: parking_lot::Mutex<Result<AgentTurnResult, CronError>>,
}

impl MockAgentExecutor {
    fn success(output: &str) -> Self {
        Self {
            response: parking_lot::Mutex::new(Ok(AgentTurnResult {
                session_id: "sess_mock".into(),
                output: output.into(),
                output_truncated: false,
            })),
        }
    }

    fn failure(msg: &str) -> Self {
        Self {
            response: parking_lot::Mutex::new(Err(CronError::Execution(msg.into()))),
        }
    }
}

#[async_trait::async_trait]
impl AgentTurnExecutor for MockAgentExecutor {
    async fn execute(
        &self,
        _prompt: &str,
        _model: Option<&str>,
        _workspace_id: Option<&str>,
        _system_prompt: Option<&str>,
        _capability_restrictions: Option<&CapabilityRestrictions>,
        _cancel: CancellationToken,
    ) -> Result<AgentTurnResult, CronError> {
        let mut guard = self.response.lock();
        std::mem::replace(
            &mut *guard,
            Err(CronError::Execution("already consumed".into())),
        )
    }
}

#[tokio::test]
async fn agent_turn_success() {
    let mut deps = make_test_deps();
    deps.agent_executor = Some(Arc::new(MockAgentExecutor::success("hello world")));

    let job = CronJob {
        payload: Payload::AgentTurn {
            prompt: "say hello".into(),
            model: None,
            workspace_id: None,
            system_prompt: None,
        },
        ..make_shell_job("echo")
    };
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_ok());
    let output = result.unwrap();
    assert_eq!(output.stdout, "hello world");
    assert_eq!(output.session_id, Some("sess_mock".to_string()));
}

#[tokio::test]
async fn agent_turn_failure_propagates() {
    let mut deps = make_test_deps();
    deps.agent_executor = Some(Arc::new(MockAgentExecutor::failure("model overloaded")));

    let job = CronJob {
        payload: Payload::AgentTurn {
            prompt: "say hello".into(),
            model: None,
            workspace_id: None,
            system_prompt: None,
        },
        ..make_shell_job("echo")
    };
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("model overloaded"));
}

// ── Mock SystemEventInjector ────────────────────────────────────

struct MockInjector {
    session_exists: bool,
}

#[async_trait::async_trait]
impl crate::domains::cron::executor::SystemEventInjector for MockInjector {
    async fn inject(&self, _session_id: &str, _message: &str) -> Result<(), CronError> {
        Ok(())
    }

    async fn session_exists(&self, _session_id: &str) -> bool {
        self.session_exists
    }
}

#[tokio::test]
async fn system_event_success() {
    let mut deps = make_test_deps();
    deps.event_injector = Some(Arc::new(MockInjector {
        session_exists: true,
    }));

    let job = CronJob {
        payload: Payload::SystemEvent {
            session_id: "sess_1".into(),
            message: "cron triggered".into(),
        },
        ..make_shell_job("echo")
    };
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn system_event_missing_session() {
    let mut deps = make_test_deps();
    deps.event_injector = Some(Arc::new(MockInjector {
        session_exists: false,
    }));

    let job = CronJob {
        payload: Payload::SystemEvent {
            session_id: "nonexistent".into(),
            message: "hello".into(),
        },
        ..make_shell_job("echo")
    };
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_err());
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("session not found")
    );
}

// ── Retry logic ─────────────────────────────────────────────────

#[tokio::test]
async fn retry_max_retries_exhausted() {
    let deps = make_test_deps();
    // Job always fails, 2 retries → 3 attempts total → still fail
    let mut job = CronJob {
        payload: Payload::ShellCommand {
            command: "exit 1".into(),
            working_directory: Some("/tmp".into()),
            timeout_secs: 5,
        },
        ..make_shell_job("exit 1")
    };
    job.max_retries = 2;

    let run = execute_with_retries(
        &job,
        &deps,
        "run_1",
        chrono::Utc::now(),
        chrono::Utc::now,
        CancellationToken::new(),
    )
    .await;
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.attempt, 2); // 0-indexed: 0, 1, 2 = 3 attempts
}

#[tokio::test]
async fn retry_respects_cancel() {
    let cancel = CancellationToken::new();
    let cancel2 = cancel.clone();

    let mut job = make_shell_job("exit 1");
    job.max_retries = 10; // Many retries — should be cancelled during backoff

    let deps = make_test_deps();
    let handle = tokio::spawn(async move {
        execute_with_retries(
            &job,
            &deps,
            "run_cancel",
            chrono::Utc::now(),
            chrono::Utc::now,
            cancel2,
        )
        .await
    });

    // Cancel during the first retry backoff
    tokio::time::sleep(Duration::from_millis(200)).await;
    cancel.cancel();

    let run = handle.await.unwrap();
    assert_eq!(run.status, RunStatus::Cancelled);
}

#[tokio::test]
async fn auto_disable_after_failures() {
    let deps = make_test_deps();
    // Insert a job in the DB for the executor to update
    let conn = deps.pool.get().unwrap();
    conn.execute(
        "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, auto_disable_after)
             VALUES ('cron_auto', 'Auto Test', '{}', '{}', 3)",
        [],
    )
    .unwrap();
    drop(conn);

    // Run the executor logic that handles auto-disable
    for _ in 0..3 {
        let _ =
            crate::domains::cron::store::increment_consecutive_failures(&deps.pool, "cron_auto");
    }
    let failures = crate::domains::cron::store::get_runtime_state(&deps.pool, "cron_auto")
        .unwrap()
        .unwrap()
        .consecutive_failures;
    assert_eq!(failures, 3);

    // After 3 consecutive failures with auto_disable_after=3, should be disabled
    // (the scheduler checks this; here we verify the store tracks it correctly)
    let conn = deps.pool.get().unwrap();
    let enabled: bool = conn
        .query_row(
            "SELECT enabled FROM cron_jobs WHERE id = 'cron_auto'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    // Store doesn't auto-disable; the scheduler does. So it's still enabled.
    assert!(enabled);
}

// ── Cron payload execution ───────────────────────────────────────────────

#[tokio::test]
async fn shell_command_allowed_when_no_restrictions() {
    let output = execute_shell("echo hi", Some("/tmp"), 10, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(output.stdout.trim(), "hi");
}

#[tokio::test]
async fn direct_payload_ignores_agent_contract_restrictions() {
    let deps = make_test_deps();
    let mut job = make_shell_job("echo allowed");
    job.capability_restrictions = Some(CapabilityRestrictions {
        allowed_contracts: Some(vec!["filesystem::read_file".into()]),
    });
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn agent_turn_not_blocked_by_payload_capability() {
    let mut deps = make_test_deps();
    deps.agent_executor = Some(Arc::new(MockAgentExecutor::success("ok")));
    let mut job = CronJob {
        payload: Payload::AgentTurn {
            prompt: "hello".into(),
            model: None,
            workspace_id: None,
            system_prompt: None,
        },
        ..make_shell_job("echo")
    };
    // Contract restrictions are applied inside the spawned agent execution policy.
    job.capability_restrictions = Some(CapabilityRestrictions {
        allowed_contracts: Some(vec!["filesystem::read_file".into()]),
    });
    let result = execute_payload(&job, &deps, CancellationToken::new()).await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn webhook_invalid_method() {
    let result = execute_webhook(
        "https://example.com",
        "INVALID",
        None,
        None,
        5,
        &reqwest::Client::new(),
        CancellationToken::new(),
    )
    .await;
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("invalid method"));
}

// ── H18: retry re-reads job.enabled per iteration ───────────────
//
// Regression coverage for the plan-H18 fix. The production path
// (execute_with_retries, ~line 200) re-queries is_job_enabled from
// the DB at the top of every retry iteration so a mid-retry
// `jobs.setEnabled(false)` engine capability causes the next attempt to abort
// with Cancelled/`"job disabled during retry"` rather than Failed.

fn insert_enabled_job_row(pool: &ConnectionPool, job_id: &str, enabled: bool) {
    let conn = pool.get().unwrap();
    conn.execute(
        "INSERT INTO cron_jobs (id, name, schedule_json, payload_json, enabled)
             VALUES (?1, 'T', '{}', '{}', ?2)",
        rusqlite::params![job_id, enabled],
    )
    .unwrap();
}

fn set_job_enabled(pool: &ConnectionPool, job_id: &str, enabled: bool) {
    let conn = pool.get().unwrap();
    conn.execute(
        "UPDATE cron_jobs SET enabled = ?1 WHERE id = ?2",
        rusqlite::params![enabled, job_id],
    )
    .unwrap();
}

#[tokio::test]
async fn disable_between_retries_aborts_cleanly() {
    // Job always fails; max_retries allows several attempts. Before
    // execute_with_retries spins up, the row is enabled. Immediately
    // after the first attempt returns, we flip it to disabled. The
    // next iteration's pre-check (is_job_enabled) must short-circuit
    // to RunStatus::Cancelled rather than continuing to retry.
    let deps = make_test_deps();
    let mut job = make_shell_job("exit 1");
    job.id = "cron_disable_between".into();
    job.max_retries = 5;
    // Fast failure (exit 1) so we don't need long sleeps.
    insert_enabled_job_row(&deps.pool, &job.id, true);

    // Flip the row to disabled from a concurrent task. The first
    // attempt takes a few ms; by the time the loop wakes for the
    // second iteration, the row is already disabled.
    let pool = deps.pool.clone();
    let job_id = job.id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        set_job_enabled(&pool, &job_id, false);
    });

    let run = execute_with_retries(
        &job,
        &deps,
        "run_h18_a",
        chrono::Utc::now(),
        chrono::Utc::now,
        CancellationToken::new(),
    )
    .await;

    assert_eq!(
        run.status,
        RunStatus::Cancelled,
        "disabled mid-retry must yield Cancelled, not Failed/TimedOut: {run:?}"
    );
    assert_eq!(
        run.error.as_deref(),
        Some("job disabled during retry"),
        "error distinguishes this from shutdown cancel: {run:?}"
    );
    // Must have aborted BEFORE exhausting max_retries. Exact attempt
    // depends on backoff timing; what matters is we're below the cap.
    assert!(
        run.attempt < job.max_retries,
        "aborted before exhaustion: attempt={} max={}",
        run.attempt,
        job.max_retries
    );
}

#[tokio::test]
async fn abort_status_distinct_from_failure() {
    // Two runs of the same failing command: one where the job stays
    // enabled and exhausts retries (Failed), one where the job is
    // disabled after the first attempt (Cancelled). Pins the
    // abort-vs-fail distinction the plan calls out.
    let deps = make_test_deps();

    // Run A: stays enabled, exhausts retries → Failed
    let mut job_a = make_shell_job("exit 1");
    job_a.id = "cron_abort_a".into();
    job_a.max_retries = 1;
    insert_enabled_job_row(&deps.pool, &job_a.id, true);
    let a = execute_with_retries(
        &job_a,
        &deps,
        "run_h18_fail",
        chrono::Utc::now(),
        chrono::Utc::now,
        CancellationToken::new(),
    )
    .await;
    assert_eq!(a.status, RunStatus::Failed, "enabled run exhausts → Failed");

    // Run B: disabled mid-retry → Cancelled.
    let mut job_b = make_shell_job("exit 1");
    job_b.id = "cron_abort_b".into();
    job_b.max_retries = 5;
    insert_enabled_job_row(&deps.pool, &job_b.id, true);
    let pool_disable = deps.pool.clone();
    let job_id = job_b.id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        set_job_enabled(&pool_disable, &job_id, false);
    });
    let b = execute_with_retries(
        &job_b,
        &deps,
        "run_h18_cancel",
        chrono::Utc::now(),
        chrono::Utc::now,
        CancellationToken::new(),
    )
    .await;
    assert_eq!(b.status, RunStatus::Cancelled, "disabled run → Cancelled");

    assert_ne!(
        a.status, b.status,
        "Cancelled and Failed must remain distinct"
    );
}

#[tokio::test]
async fn disable_during_attempt_completes_attempt_then_aborts() {
    // If the job is flipped to disabled WHILE attempt 0 is running,
    // the current attempt is NOT interrupted (intentional: capability invocations
    // and subagent turns often have side effects; we don't kill
    // them mid-run). Instead, the retry-loop pre-check on the NEXT
    // iteration short-circuits to Cancelled. If the attempt
    // happens to succeed, status is Completed — the attempt wins.
    let deps = make_test_deps();
    let mut job = make_shell_job("sleep 0.2; exit 1");
    job.id = "cron_during_attempt".into();
    job.max_retries = 5;
    insert_enabled_job_row(&deps.pool, &job.id, true);

    // Flip to disabled DURING attempt 0 (the command sleeps 200ms).
    let pool_disable = deps.pool.clone();
    let job_id = job.id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        set_job_enabled(&pool_disable, &job_id, false);
    });

    let run = execute_with_retries(
        &job,
        &deps,
        "run_h18_during",
        chrono::Utc::now(),
        chrono::Utc::now,
        CancellationToken::new(),
    )
    .await;

    // The failing attempt completes (exit 1), then the retry-loop
    // pre-check sees disabled and returns Cancelled.
    assert_eq!(
        run.status,
        RunStatus::Cancelled,
        "attempt ran to completion, next iteration aborted: {run:?}"
    );
    assert_eq!(run.error.as_deref(), Some("job disabled during retry"));
    assert!(
        run.attempt >= 1,
        "must have completed at least attempt 0 before aborting: {run:?}"
    );
}
