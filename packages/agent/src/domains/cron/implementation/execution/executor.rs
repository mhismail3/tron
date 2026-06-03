//! Payload execution: shell commands, webhooks, agent turns, system events.
//!
//! Uses callback traits for dependency injection — the binary crate provides
//! real implementations, tests use mocks.
//!
//! NOTE: `let _ =` on kill/signal calls is intentional — the process may have
//! already exited. On I/O reads, the output may be capped or the pipe closed.

use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use crate::domains::session::event_store::ConnectionPool;
use async_trait::async_trait;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;

use crate::domains::cron::errors::CronError;
use crate::domains::cron::types::{
    CapabilityRestrictions, CronJob, CronRun, ExecutionOutput, Payload, RunStatus,
};
use crate::domains::model::presets::{ModelPreset, ModelRoutingPresentation};

/// Execute an isolated agent turn. Implemented in `main.rs`.
#[async_trait]
pub trait AgentTurnExecutor: Send + Sync {
    /// Run a prompt and return the result.
    async fn execute(
        &self,
        prompt: &str,
        model: Option<&str>,
        model_preset: Option<ModelPreset>,
        workspace_id: Option<&str>,
        system_prompt: Option<&str>,
        capability_restrictions: Option<&CapabilityRestrictions>,
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
    /// Selected model routing presentation.
    pub model_routing: Option<ModelRoutingPresentation>,
}

/// Publish cron events to engine streams.
#[async_trait]
pub trait EventPublisher: Send + Sync {
    /// Publish a cron run result.
    async fn publish_cron_result(&self, job: &CronJob, run: &CronRun);
    /// Publish a generic cron event.
    async fn publish_cron_event(&self, event_type: &str, payload: serde_json::Value);
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
    /// Cron event publisher. Uses `OnceLock` because it's set after server
    /// creation, but before the scheduler starts.
    pub event_publisher: std::sync::OnceLock<Arc<dyn EventPublisher>>,
    /// Push notification sender.
    pub push_notifier: Option<Arc<dyn PushNotifier>>,
    /// System event injector.
    pub event_injector: Option<Arc<dyn SystemEventInjector>>,
    /// Shared HTTP client.
    pub http_client: reqwest::Client,
    /// Database connection pool.
    pub pool: ConnectionPool,
}

/// Execute a job payload and return the result.
pub async fn execute_payload(
    job: &CronJob,
    deps: &ExecutorDeps,
    cancel: CancellationToken,
) -> Result<ExecutionOutput, CronError> {
    // Capability restrictions apply to AgentTurn execution policies only.
    // Direct cron payload types are governed by cron payload validation and job
    // permissions, not contract/implementation/plugin policy.

    match &job.payload {
        Payload::ShellCommand {
            command,
            working_directory,
            timeout_secs,
        } => execute_shell(command, working_directory.as_deref(), *timeout_secs, cancel).await,
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
            model_preset,
            workspace_id,
            system_prompt,
            ..
        } => {
            let executor = deps
                .agent_executor
                .as_ref()
                .ok_or_else(|| CronError::Execution("agent executor not available".into()))?;
            let result = executor
                .execute(
                    prompt,
                    model.as_deref(),
                    *model_preset,
                    workspace_id.as_deref(),
                    system_prompt.as_deref(),
                    job.capability_restrictions.as_ref(),
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
                model_routing: result.model_routing,
            })
        }
        Payload::SystemEvent {
            session_id,
            message,
        } => {
            let injector = deps.event_injector.as_ref().ok_or_else(|| {
                CronError::Execution("system event injector not available".into())
            })?;
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
        if attempt > 0
            && let Ok(false) = crate::domains::cron::store::is_job_enabled(&deps.pool, &job.id)
        {
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
                    output: Some(output.stdout),
                    output_truncated: output.truncated,
                    error: None,
                    exit_code: output.exit_code,
                    attempt,
                    session_id: output.session_id,
                    model_routing: output.model_routing,
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
                    model_routing: None,
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
    cancel: CancellationToken,
) -> Result<ExecutionOutput, CronError> {
    const MAX_OUTPUT: usize = 1_048_576; // 1MB
    let dir = working_dir.map_or_else(crate::shared::paths::home_dir, String::from);

    let mut cmd = tokio::process::Command::new("bash");
    let _ = cmd
        .arg("-c")
        .arg(command)
        .current_dir(&dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    // Create new process group so we can kill all children on timeout/cancel.
    #[cfg(unix)]
    let _ = cmd.process_group(0);

    let mut child = cmd
        .spawn()
        .map_err(|e| CronError::Execution(format!("failed to spawn: {e}")))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| CronError::Execution("failed to capture stdout".into()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| CronError::Execution("failed to capture stderr".into()))?;

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
                        model_routing: None,
                    };

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
                let _ = libc::kill(-(pid as i32), libc::SIGTERM);
            }
            let pid_copy = pid;
            let _ = std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(2));
                unsafe {
                    let _ = libc::kill(-(pid_copy as i32), libc::SIGKILL);
                }
            });
        }
    }
    #[cfg(not(unix))]
    {
        // Non-Unix cleanup path: kill the direct child.
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
        model_routing: None,
    })
}

async fn read_bounded(
    mut reader: impl tokio::io::AsyncRead + Unpin,
    max: usize,
) -> Result<(String, bool), CronError> {
    let mut buf = Vec::with_capacity(max.min(65536));
    let mut limited = (&mut reader).take(max as u64);
    let _ = tokio::io::copy(&mut limited, &mut buf)
        .await
        .map_err(|e| CronError::Execution(format!("read error: {e}")))?;
    let truncated = buf.len() >= max;
    Ok((String::from_utf8_lossy(&buf).into_owned(), truncated))
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
        model_routing: None,
        delivery_status: None,
    }
}

#[cfg(test)]
#[path = "executor/tests.rs"]
mod tests;
