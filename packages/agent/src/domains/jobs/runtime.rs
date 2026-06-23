use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::app::lifecycle::shutdown::ShutdownCoordinator;
use crate::engine::{EngineHostHandle, Invocation};
use crate::shared::server::errors::CapabilityError;

use super::errors::{internal, invalid_params};
use super::service;
use super::types::{JobRunOutcome, JobState};

#[derive(Clone, Default)]
pub(crate) struct JobRuntime {
    running: Arc<Mutex<HashMap<String, RunningJob>>>,
}

#[derive(Clone)]
struct RunningJob {
    child: Arc<Mutex<Child>>,
    cancel_requested: Arc<AtomicBool>,
}

struct CapturedOutput {
    text: String,
    truncated: bool,
}

impl JobRuntime {
    pub(crate) async fn spawn_process(
        &self,
        request: SpawnProcessRequest,
    ) -> Result<Option<u32>, CapabilityError> {
        let mut command =
            network_denied_shell_command(&request.command, request.working_directory.clone())?;
        command
            .kill_on_drop(true)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let mut child = command
            .spawn()
            .map_err(|error| internal(format!("spawn job process: {error}")))?;
        let process_id = child.id();
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| internal("spawned job process did not expose stdout"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| internal("spawned job process did not expose stderr"))?;
        let child = Arc::new(Mutex::new(child));
        let cancel_requested = Arc::new(AtomicBool::new(false));
        self.running.lock().await.insert(
            request.job_resource_id.clone(),
            RunningJob {
                child: Arc::clone(&child),
                cancel_requested: Arc::clone(&cancel_requested),
            },
        );

        let shutdown_coordinator = request.shutdown_coordinator.clone();
        let runtime = self.clone();
        let task = tokio::spawn(async move {
            runtime
                .run_process_to_terminal(request, child, cancel_requested, stdout, stderr)
                .await;
        });
        if let Some(shutdown) = &shutdown_coordinator {
            shutdown.register_task(task);
        } else {
            drop(task);
        }
        Ok(process_id)
    }

    pub(crate) async fn cancel(&self, job_resource_id: &str) -> bool {
        let Some(running) = self.running.lock().await.get(job_resource_id).cloned() else {
            return false;
        };
        running.cancel_requested.store(true, Ordering::SeqCst);
        if let Ok(mut child) = running.child.try_lock() {
            let _ = child.start_kill();
        }
        true
    }

    pub(crate) async fn cancel_all(&self, reason: &str) {
        let jobs = self
            .running
            .lock()
            .await
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for job in &jobs {
            let _ = self.cancel(job).await;
        }
        tracing::info!(
            component = "jobs",
            job_count = jobs.len(),
            reason,
            "requested cancellation for running jobs"
        );
    }

    async fn run_process_to_terminal(
        &self,
        request: SpawnProcessRequest,
        child: Arc<Mutex<Child>>,
        cancel_requested: Arc<AtomicBool>,
        stdout: impl AsyncRead + Send + Unpin + 'static,
        stderr: impl AsyncRead + Send + Unpin + 'static,
    ) {
        let started = Instant::now();
        let stdout_task = tokio::spawn(read_bounded(stdout, request.max_output_bytes));
        let stderr_task = tokio::spawn(read_bounded(stderr, request.max_output_bytes));
        let wait = wait_for_exit(
            Arc::clone(&child),
            Arc::clone(&cancel_requested),
            Duration::from_millis(request.timeout_ms),
        )
        .await;
        let stdout = stdout_task.await.unwrap_or_else(|_| CapturedOutput {
            text: String::new(),
            truncated: true,
            // Join errors should not hide the job terminal state.
        });
        let stderr = stderr_task.await.unwrap_or_else(|_| CapturedOutput {
            text: String::new(),
            truncated: true,
        });
        self.running.lock().await.remove(&request.job_resource_id);

        let outcome = match wait {
            WaitResult::Exited(status) => {
                let exit_code = status.code();
                JobRunOutcome {
                    state: if status.success() {
                        JobState::Completed
                    } else {
                        JobState::Failed
                    },
                    exit_code,
                    timed_out: false,
                    cancelled: cancel_requested.load(Ordering::SeqCst),
                    stdout: stdout.text,
                    stderr: stderr.text,
                    stdout_truncated: stdout.truncated,
                    stderr_truncated: stderr.truncated,
                    duration_ms: duration_ms(started.elapsed()),
                    error: if status.success() {
                        None
                    } else {
                        Some("process exited with non-zero status".to_owned())
                    },
                }
            }
            WaitResult::TimedOut => JobRunOutcome {
                state: JobState::TimedOut,
                exit_code: None,
                timed_out: true,
                cancelled: false,
                stdout: stdout.text,
                stderr: stderr.text,
                stdout_truncated: stdout.truncated,
                stderr_truncated: stderr.truncated,
                duration_ms: duration_ms(started.elapsed()),
                error: Some("process timed out and was killed".to_owned()),
            },
            WaitResult::Cancelled => JobRunOutcome {
                state: JobState::Cancelled,
                exit_code: None,
                timed_out: false,
                cancelled: true,
                stdout: stdout.text,
                stderr: stderr.text,
                stdout_truncated: stdout.truncated,
                stderr_truncated: stderr.truncated,
                duration_ms: duration_ms(started.elapsed()),
                error: Some("process was cancelled".to_owned()),
            },
            WaitResult::Failed(error) => JobRunOutcome {
                state: JobState::Failed,
                exit_code: None,
                timed_out: false,
                cancelled: cancel_requested.load(Ordering::SeqCst),
                stdout: stdout.text,
                stderr: stderr.text,
                stdout_truncated: stdout.truncated,
                stderr_truncated: stderr.truncated,
                duration_ms: duration_ms(started.elapsed()),
                error: Some(error),
            },
        };

        if let Err(error) = service::finalize_job_from_runtime(
            &request.engine_host,
            &request.invocation,
            &request.job_resource_id,
            outcome,
        )
        .await
        {
            tracing::warn!(
                component = "jobs",
                job_resource_id = request.job_resource_id,
                error = %error,
                "failed to finalize job process"
            );
        }
    }
}

pub(crate) struct SpawnProcessRequest {
    pub(crate) engine_host: EngineHostHandle,
    pub(crate) shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    pub(crate) invocation: Invocation,
    pub(crate) job_resource_id: String,
    pub(crate) command: String,
    pub(crate) working_directory: PathBuf,
    pub(crate) timeout_ms: u64,
    pub(crate) max_output_bytes: usize,
}

enum WaitResult {
    Exited(std::process::ExitStatus),
    TimedOut,
    Cancelled,
    Failed(String),
}

async fn wait_for_exit(
    child: Arc<Mutex<Child>>,
    cancel_requested: Arc<AtomicBool>,
    timeout: Duration,
) -> WaitResult {
    let started = Instant::now();
    loop {
        if cancel_requested.load(Ordering::SeqCst) {
            let mut child = child.lock().await;
            let _ = child.start_kill();
            let _ = child.wait().await;
            return WaitResult::Cancelled;
        }
        if started.elapsed() >= timeout {
            let mut child = child.lock().await;
            let _ = child.start_kill();
            let _ = child.wait().await;
            return WaitResult::TimedOut;
        }
        {
            let mut child = child.lock().await;
            match child.try_wait() {
                Ok(Some(status)) => return WaitResult::Exited(status),
                Ok(None) => {}
                Err(error) => return WaitResult::Failed(error.to_string()),
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn read_bounded<R>(mut reader: R, max_bytes: usize) -> CapturedOutput
where
    R: AsyncRead + Unpin,
{
    let mut output = Vec::new();
    let mut buf = [0_u8; 8192];
    let mut truncated = false;
    loop {
        match reader.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => {
                let remaining = max_bytes.saturating_sub(output.len());
                if remaining > 0 {
                    output.extend_from_slice(&buf[..n.min(remaining)]);
                }
                if n > remaining {
                    truncated = true;
                }
            }
            Err(_) => {
                truncated = true;
                break;
            }
        }
    }
    CapturedOutput {
        text: String::from_utf8_lossy(&output).into_owned(),
        truncated,
    }
}

#[cfg(target_os = "macos")]
fn network_denied_shell_command(command: &str, root: PathBuf) -> Result<Command, CapabilityError> {
    let sandbox = std::path::Path::new("/usr/bin/sandbox-exec");
    if !sandbox.exists() {
        return Err(invalid_params(
            "job_start cannot enforce networkPolicy none because sandbox-exec is unavailable",
        ));
    }
    let mut cmd = Command::new(sandbox);
    cmd.arg("-p")
        .arg("(version 1)\n(allow default)\n(deny network*)")
        .arg("/bin/sh")
        .arg("-lc")
        .arg(command)
        .current_dir(root);
    Ok(cmd)
}

#[cfg(not(target_os = "macos"))]
fn network_denied_shell_command(
    _command: &str,
    _root: PathBuf,
) -> Result<Command, CapabilityError> {
    Err(invalid_params(
        "job_start cannot enforce networkPolicy none on this platform",
    ))
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_micros().div_ceil(1000) as u64
}
