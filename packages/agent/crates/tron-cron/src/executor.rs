//! Payload execution: shell commands, webhooks, agent turns, system events.
//!
//! Uses callback traits for dependency injection — the binary crate provides
//! real implementations, tests use mocks.

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;
use tron_events::ConnectionPool;

use crate::errors::CronError;
use crate::types::{CronJob, CronRun, ExecutionOutput, Payload, RunStatus};

/// Execute an isolated agent turn. Implemented in `tron-agent/main.rs`.
#[async_trait]
pub trait AgentTurnExecutor: Send + Sync {
    /// Run a prompt and return the result.
    async fn execute(
        &self,
        prompt: &str,
        model: Option<&str>,
        workspace_id: Option<&str>,
        system_prompt: Option<&str>,
        cancel: CancellationToken,
    ) -> Result<AgentTurnResult, CronError>;
}

/// Result of an agent turn execution.
pub struct AgentTurnResult {
    /// Session ID for the agent turn.
    pub session_id: String,
    /// Agent output text.
    pub output: String,
    /// Whether the output was truncated.
    pub output_truncated: bool,
}

/// Broadcast events to WebSocket clients.
#[async_trait]
pub trait EventBroadcaster: Send + Sync {
    /// Broadcast a cron run result.
    async fn broadcast_cron_result(&self, job: &CronJob, run: &CronRun);
    /// Broadcast a generic cron event.
    async fn broadcast_cron_event(&self, event_type: &str, payload: serde_json::Value);
}

/// Send push notifications via APNS.
#[async_trait]
pub trait PushNotifier: Send + Sync {
    /// Send a push notification.
    async fn notify(&self, title: &str, body: &str) -> Result<(), CronError>;
}

/// Inject a system event into an existing session.
#[async_trait]
pub trait SystemEventInjector: Send + Sync {
    /// Inject a message into a session.
    async fn inject(&self, session_id: &str, message: &str) -> Result<(), CronError>;
    /// Check if a session exists.
    async fn session_exists(&self, session_id: &str) -> bool;
}

/// Dependencies for the executor (trait objects injected from the binary).
pub struct ExecutorDeps {
    /// Agent turn executor (None if no auth).
    pub agent_executor: Option<Arc<dyn AgentTurnExecutor>>,
    /// WebSocket broadcaster. Uses `OnceLock` because it's set after server
    /// creation (the `BroadcastManager` comes from `TronServer`), but before
    /// the scheduler starts.
    pub broadcaster: std::sync::OnceLock<Arc<dyn EventBroadcaster>>,
    /// Push notification sender.
    pub push_notifier: Option<Arc<dyn PushNotifier>>,
    /// System event injector.
    pub event_injector: Option<Arc<dyn SystemEventInjector>>,
    /// Shared HTTP client.
    pub http_client: reqwest::Client,
    /// Database connection pool.
    pub pool: ConnectionPool,
    /// Directory for full output files (`~/.tron/artifacts/cron/outputs/`).
    pub output_dir: PathBuf,
}

/// Execute a job payload and return the result.
pub async fn execute_payload(
    job: &CronJob,
    deps: &ExecutorDeps,
    cancel: CancellationToken,
) -> Result<ExecutionOutput, CronError> {
    match &job.payload {
        Payload::ShellCommand {
            command,
            working_directory,
            timeout_secs,
        } => {
            execute_shell(
                command,
                working_directory.as_deref(),
                *timeout_secs,
                &deps.output_dir,
                &job.id,
                cancel,
            )
            .await
        }
        Payload::Webhook {
            url,
            method,
            headers,
            body,
            timeout_secs,
        } => {
            execute_webhook(
                url,
                method,
                headers.as_ref(),
                body.as_ref(),
                *timeout_secs,
                &deps.http_client,
                cancel,
            )
            .await
        }
        Payload::AgentTurn {
            prompt,
            model,
            workspace_id,
            system_prompt,
        } => {
            let executor = deps
                .agent_executor
                .as_ref()
                .ok_or_else(|| CronError::Execution("agent executor not available".into()))?;
            let result = executor
                .execute(
                    prompt,
                    model.as_deref(),
                    workspace_id.as_deref(),
                    system_prompt.as_deref(),
                    cancel,
                )
                .await?;
            Ok(ExecutionOutput {
                stdout: result.output,
                stderr: String::new(),
                exit_code: Some(0),
                truncated: result.output_truncated,
                timed_out: false,
                session_id: Some(result.session_id),
            })
        }
        Payload::SystemEvent {
            session_id,
            message,
        } => {
            let injector = deps
                .event_injector
                .as_ref()
                .ok_or_else(|| CronError::Execution("system event injector not available".into()))?;
            if !injector.session_exists(session_id).await {
                return Err(CronError::Execution(format!(
                    "session not found: {session_id}"
                )));
            }
            injector.inject(session_id, message).await?;
            Ok(ExecutionOutput::default())
        }
    }
}

/// Execute with retry logic.
pub async fn execute_with_retries(
    job: &CronJob,
    deps: &ExecutorDeps,
    run_id: &str,
    started_at: chrono::DateTime<chrono::Utc>,
    completed_at_fn: impl Fn() -> chrono::DateTime<chrono::Utc>,
    cancel: CancellationToken,
) -> CronRun {
    let mut attempt = 0u32;
    loop {
        // Re-check job is still enabled before retries
        if attempt > 0 {
            if let Ok(false) = crate::store::is_job_enabled(&deps.pool, &job.id) {
                return make_run(
                    run_id,
                    &job.id,
                    &job.name,
                    started_at,
                    Some(completed_at_fn()),
                    RunStatus::Cancelled,
                    attempt,
                    None,
                    Some("job disabled during retry".into()),
                );
            }
        }

        let result = execute_payload(job, deps, cancel.clone()).await;

        match result {
            Ok(output) => {
                let now = completed_at_fn();
                let duration = (now - started_at).num_milliseconds();
                return CronRun {
                    id: run_id.into(),
                    job_id: Some(job.id.clone()),
                    job_name: job.name.clone(),
                    status: RunStatus::Completed,
                    started_at,
                    completed_at: Some(now),
                    duration_ms: Some(duration),
                    output: Some(truncate_output(&output.stdout, 4096)),
                    output_truncated: output.truncated || output.stdout.len() > 4096,
                    error: None,
                    exit_code: output.exit_code,
                    attempt,
                    session_id: output.session_id,
                    delivery_status: None,
                };
            }
            Err(ref e) if attempt >= job.max_retries => {
                let now = completed_at_fn();
                let duration = (now - started_at).num_milliseconds();
                let status = if matches!(e, CronError::TimedOut) {
                    RunStatus::TimedOut
                } else {
                    RunStatus::Failed
                };
                return CronRun {
                    id: run_id.into(),
                    job_id: Some(job.id.clone()),
                    job_name: job.name.clone(),
                    status,
                    started_at,
                    completed_at: Some(now),
                    duration_ms: Some(duration),
                    output: None,
                    output_truncated: false,
                    error: Some(e.to_string()),
                    exit_code: None,
                    attempt,
                    session_id: None,
                    delivery_status: None,
                };
            }
            Err(e) => {
                // Exponential backoff: 1s, 2s, 4s, 8s... capped at 60s
                let delay = Duration::from_secs((1u64 << attempt).min(60));
                attempt += 1;
                tracing::warn!(
                    job_id = %job.id,
                    attempt,
                    delay_secs = delay.as_secs(),
                    error = %e,
                    "retrying"
                );

                tokio::select! {
                    () = tokio::time::sleep(delay) => {}
                    () = cancel.cancelled() => {
                        return make_run(
                            run_id,
                            &job.id,
                            &job.name,
                            started_at,
                            Some(completed_at_fn()),
                            RunStatus::Cancelled,
                            attempt,
                            None,
                            Some("shutdown during retry backoff".into()),
                        );
                    }
                }
            }
        }
    }
}

async fn execute_shell(
    command: &str,
    working_dir: Option<&str>,
    timeout_secs: u64,
    output_dir: &std::path::Path,
    run_id: &str,
    cancel: CancellationToken,
) -> Result<ExecutionOutput, CronError> {
    let dir = working_dir
        .map(String::from)
        .unwrap_or_else(|| std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()));

    let mut cmd = tokio::process::Command::new("bash");
    cmd.arg("-c")
        .arg(command)
        .current_dir(&dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    // Create new process group so we can kill all children on timeout/cancel.
    // `tokio::process::Command` supports `process_group` since it wraps std's Command.
    #[cfg(unix)]
    cmd.process_group(0);

    let mut child = cmd
        .spawn()
        .map_err(|e| CronError::Execution(format!("failed to spawn: {e}")))?;

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    const MAX_OUTPUT: usize = 1_048_576; // 1MB
    let stdout_task = tokio::spawn(read_bounded(stdout, MAX_OUTPUT));
    let stderr_task = tokio::spawn(read_bounded(stderr, MAX_OUTPUT));

    let result = tokio::select! {
        r = tokio::time::timeout(Duration::from_secs(timeout_secs), child.wait()) => {
            match r {
                Ok(Ok(status)) => {
                    let (out, out_trunc) = stdout_task.await.map_err(|e| CronError::Execution(e.to_string()))??;
                    let (err, err_trunc) = stderr_task.await.map_err(|e| CronError::Execution(e.to_string()))??;
                    let output = ExecutionOutput {
                        stdout: out,
                        stderr: err,
                        exit_code: status.code(),
                        truncated: out_trunc || err_trunc,
                        timed_out: false,
                        session_id: None,
                    };

                    // Write full output to file if truncated
                    if output.truncated {
                        write_output_file(output_dir, run_id, &output.stdout, &output.stderr);
                    }

                    // Non-zero exit code is a failure — but SIGPIPE (141) is expected
                    // when we truncated output (the reader closed, so writes to the pipe fail).
                    let is_sigpipe_from_truncation =
                        output.truncated && status.code() == Some(141);
                    if status.code() != Some(0) && !is_sigpipe_from_truncation {
                        return Err(CronError::Execution(format!(
                            "exit code {}: {}", status.code().unwrap_or(-1),
                            if output.stderr.is_empty() { &output.stdout } else { &output.stderr }
                        )));
                    }

                    Ok(output)
                }
                Ok(Err(e)) => Err(CronError::Execution(e.to_string())),
                Err(_) => {
                    kill_child(&mut child);
                    Err(CronError::TimedOut)
                }
            }
        }
        () = cancel.cancelled() => {
            kill_child(&mut child);
            Err(CronError::Cancelled("shutdown".into()))
        }
    };

    result
}

/// Kill a child process and its entire process group.
///
/// On Unix, sends SIGTERM to the process group (negative PID), then SIGKILL
/// after 2 seconds if still alive. On non-Unix, falls back to `kill()`.
#[allow(unsafe_code)]
fn kill_child(child: &mut tokio::process::Child) {
    #[cfg(unix)]
    {
        if let Some(pid) = child.id() {
            // SAFETY: sending signals to process groups is a standard Unix operation.
            // The negative PID targets the entire process group created by process_group(0).
            unsafe {
                libc::kill(-(pid as i32), libc::SIGTERM);
            }
            let pid_copy = pid;
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(2));
                unsafe {
                    libc::kill(-(pid_copy as i32), libc::SIGKILL);
                }
            });
        }
    }
    #[cfg(not(unix))]
    {
        // Fallback: just kill the direct child
        let _ = child.start_kill();
    }
}

async fn execute_webhook(
    url: &str,
    method: &str,
    headers: Option<&serde_json::Map<String, serde_json::Value>>,
    body: Option<&serde_json::Value>,
    timeout_secs: u64,
    client: &reqwest::Client,
    cancel: CancellationToken,
) -> Result<ExecutionOutput, CronError> {
    let mut req = match method {
        "GET" => client.get(url),
        "POST" => client.post(url),
        "PUT" => client.put(url),
        "PATCH" => client.patch(url),
        "DELETE" => client.delete(url),
        _ => return Err(CronError::Validation(format!("invalid method: {method}"))),
    };

    req = req.timeout(Duration::from_secs(timeout_secs));

    if let Some(hdrs) = headers {
        for (k, v) in hdrs {
            if let Some(s) = v.as_str() {
                req = req.header(k.as_str(), s);
            }
        }
    }

    if let Some(b) = body {
        req = req.json(b);
    }

    let resp = tokio::select! {
        r = req.send() => r.map_err(|e| CronError::Execution(format!("HTTP error: {e}")))?,
        () = cancel.cancelled() => return Err(CronError::Cancelled("shutdown".into())),
    };

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| CronError::Execution(format!("response read error: {e}")))?;

    if !status.is_success() {
        return Err(CronError::Execution(format!(
            "HTTP {}: {}",
            status.as_u16(),
            truncate_output(&text, 1024)
        )));
    }

    Ok(ExecutionOutput {
        stdout: text,
        stderr: String::new(),
        exit_code: None,
        truncated: false,
        timed_out: false,
        session_id: None,
    })
}

async fn read_bounded(
    mut reader: impl tokio::io::AsyncRead + Unpin,
    max: usize,
) -> Result<(String, bool), CronError> {
    let mut buf = Vec::with_capacity(max.min(65536));
    let mut limited = (&mut reader).take(max as u64);
    tokio::io::copy(&mut limited, &mut buf)
        .await
        .map_err(|e| CronError::Execution(format!("read error: {e}")))?;
    let truncated = buf.len() >= max;
    Ok((String::from_utf8_lossy(&buf).into_owned(), truncated))
}

fn write_output_file(dir: &std::path::Path, run_id: &str, stdout: &str, stderr: &str) {
    let _ = std::fs::create_dir_all(dir);
    let path = dir.join(format!("{run_id}.log"));
    let content = format!("=== STDOUT ===\n{stdout}\n=== STDERR ===\n{stderr}");
    let _ = std::fs::write(path, content);
}

fn truncate_output(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}... (truncated)", &s[..max])
    }
}

fn make_run(
    run_id: &str,
    job_id: &str,
    job_name: &str,
    started_at: chrono::DateTime<chrono::Utc>,
    completed_at: Option<chrono::DateTime<chrono::Utc>>,
    status: RunStatus,
    attempt: u32,
    output: Option<String>,
    error: Option<String>,
) -> CronRun {
    let duration_ms = completed_at.map(|c| (c - started_at).num_milliseconds());
    CronRun {
        id: run_id.into(),
        job_id: Some(job_id.into()),
        job_name: job_name.into(),
        status,
        started_at,
        completed_at,
        duration_ms,
        output,
        output_truncated: false,
        error,
        exit_code: None,
        attempt,
        session_id: None,
        delivery_status: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::*;

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
            workspace_id: None,
            created_at: chrono::Utc::now(),
            updated_at: chrono::Utc::now(),
        }
    }

    fn make_test_deps() -> ExecutorDeps {
        let pool =
            tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
            crate::migrations::run_migrations(&conn).unwrap();
        }
        ExecutorDeps {
            agent_executor: None,
            broadcaster: std::sync::OnceLock::new(),
            push_notifier: None,
            event_injector: None,
            http_client: reqwest::Client::new(),
            pool,
            output_dir: std::env::temp_dir().join("tron-cron-test-outputs"),
        }
    }

    #[tokio::test]
    async fn shell_command_captures_stdout() {
        let output = execute_shell(
            "echo hello",
            Some("/tmp"),
            10,
            &std::env::temp_dir(),
            "test_run",
            CancellationToken::new(),
        )
        .await
        .unwrap();
        assert_eq!(output.stdout.trim(), "hello");
    }

    #[tokio::test]
    async fn shell_command_exit_code() {
        let result = execute_shell(
            "exit 42",
            Some("/tmp"),
            10,
            &std::env::temp_dir(),
            "test_run",
            CancellationToken::new(),
        )
        .await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("exit code 42"));
    }

    #[tokio::test]
    async fn shell_command_timeout() {
        let result = execute_shell(
            "sleep 60",
            Some("/tmp"),
            1,
            &std::env::temp_dir(),
            "test_run",
            CancellationToken::new(),
        )
        .await;
        assert!(matches!(result, Err(CronError::TimedOut)));
    }

    #[tokio::test]
    async fn shell_command_kill_on_cancel() {
        let cancel = CancellationToken::new();
        let cancel2 = cancel.clone();

        let handle = tokio::spawn(async move {
            execute_shell(
                "sleep 60",
                Some("/tmp"),
                300,
                &std::env::temp_dir(),
                "test_run",
                cancel2,
            )
            .await
        });

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
            &std::env::temp_dir(),
            "test_run",
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
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("not available"));
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
        let output = execute_shell(
            "echo err >&2",
            Some("/tmp"),
            10,
            &std::env::temp_dir(),
            "test_run",
            CancellationToken::new(),
        )
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
            &std::env::temp_dir(),
            "test_bounded",
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
            _cancel: CancellationToken,
        ) -> Result<AgentTurnResult, CronError> {
            let mut guard = self.response.lock();
            std::mem::replace(&mut *guard, Err(CronError::Execution("already consumed".into())))
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
    impl crate::executor::SystemEventInjector for MockInjector {
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
        assert!(result.unwrap_err().to_string().contains("session not found"));
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
            let _ = crate::store::increment_consecutive_failures(&deps.pool, "cron_auto");
        }
        let failures = crate::store::get_runtime_state(&deps.pool, "cron_auto")
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
}
