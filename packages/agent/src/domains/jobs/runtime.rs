use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use tokio::task::{JoinError, JoinHandle};

use crate::app::lifecycle::shutdown::ShutdownCoordinator;
use crate::engine::{EngineHostHandle, Invocation};
use crate::shared::server::errors::CapabilityError;

use super::errors::{internal, invalid_params};
use super::service;
use super::types::{JobRunOutcome, JobState};

const POLL_INTERVAL: Duration = Duration::from_millis(20);
const PROCESS_GROUP_TERM_GRACE: Duration = Duration::from_millis(100);
const CHILD_WAIT_GRACE: Duration = Duration::from_millis(500);
const OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(500);

#[derive(Clone, Default)]
pub(crate) struct JobRuntime {
    running: Arc<Mutex<HashMap<String, RunningJob>>>,
}

#[derive(Clone)]
struct RunningJob {
    child: Arc<Mutex<Child>>,
    process_group_id: Option<i32>,
    cancel_requested: Arc<AtomicBool>,
    cancel_delivered: Arc<AtomicBool>,
    direct_exit_observed: Arc<AtomicBool>,
    output_pending: Arc<AtomicBool>,
    direct_exit_status: Arc<Mutex<Option<std::process::ExitStatus>>>,
    cancel_reason: Arc<Mutex<Option<String>>>,
}

#[derive(Clone, Default)]
struct OutputBuffer {
    inner: Arc<Mutex<OutputState>>,
}

#[derive(Default)]
struct OutputState {
    bytes: Vec<u8>,
    truncated: bool,
}

struct CapturedOutput {
    text: String,
    truncated: bool,
}

pub(crate) enum CancelRequestResult {
    Requested,
    CompletionPending,
    NotRunning,
    CleanupUnknown(String),
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
        let running = RunningJob {
            child: Arc::clone(&child),
            process_group_id: process_id.and_then(process_group_id_for_child),
            cancel_requested: Arc::new(AtomicBool::new(false)),
            cancel_delivered: Arc::new(AtomicBool::new(false)),
            direct_exit_observed: Arc::new(AtomicBool::new(false)),
            output_pending: Arc::new(AtomicBool::new(true)),
            direct_exit_status: Arc::new(Mutex::new(None)),
            cancel_reason: Arc::new(Mutex::new(None)),
        };
        self.running
            .lock()
            .await
            .insert(request.job_resource_id.clone(), running.clone());

        let shutdown_coordinator = request.shutdown_coordinator.clone();
        let runtime = self.clone();
        let task = tokio::spawn(async move {
            runtime
                .run_process_to_terminal(request, running, stdout, stderr)
                .await;
        });
        if let Some(shutdown) = &shutdown_coordinator {
            shutdown.register_task(task);
        } else {
            drop(task);
        }
        Ok(process_id)
    }

    pub(crate) async fn request_cancel(
        &self,
        job_resource_id: &str,
        reason: Option<String>,
    ) -> CancelRequestResult {
        let Some(running) = self.running.lock().await.get(job_resource_id).cloned() else {
            return CancelRequestResult::NotRunning;
        };
        let exit_observed = match observe_direct_exit(&running).await {
            Ok(observed) => observed,
            Err(error) => return CancelRequestResult::CleanupUnknown(error),
        };
        if exit_observed && !running.output_pending.load(Ordering::SeqCst) {
            return CancelRequestResult::CompletionPending;
        }

        match signal_process_group(running.process_group_id, "TERM") {
            ProcessSignalResult::Delivered => {
                running.cancel_delivered.store(true, Ordering::SeqCst);
                *running.cancel_reason.lock().await = reason;
                running.cancel_requested.store(true, Ordering::SeqCst);
                CancelRequestResult::Requested
            }
            ProcessSignalResult::NoSuchProcess if exit_observed => {
                CancelRequestResult::CompletionPending
            }
            ProcessSignalResult::NoSuchProcess => {
                if kill_direct_child(&running).await {
                    *running.cancel_reason.lock().await = reason;
                    running.cancel_requested.store(true, Ordering::SeqCst);
                    CancelRequestResult::Requested
                } else {
                    CancelRequestResult::CleanupUnknown(
                        "job process group was not found and direct child was not killable"
                            .to_owned(),
                    )
                }
            }
            ProcessSignalResult::Unsupported => CancelRequestResult::CleanupUnknown(
                "job runtime cannot signal process groups on this platform".to_owned(),
            ),
            ProcessSignalResult::Failed(error) => CancelRequestResult::CleanupUnknown(error),
        }
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
            let _ = self.request_cancel(job, Some(reason.to_owned())).await;
        }
        tracing::info!(
            component = "jobs",
            job_count = jobs.len(),
            reason,
            "requested cancellation for running jobs"
        );
    }

    pub(crate) async fn owns_job(&self, job_resource_id: &str) -> bool {
        self.running.lock().await.contains_key(job_resource_id)
    }

    async fn run_process_to_terminal(
        &self,
        request: SpawnProcessRequest,
        running: RunningJob,
        stdout: impl AsyncRead + Send + Unpin + 'static,
        stderr: impl AsyncRead + Send + Unpin + 'static,
    ) {
        let outcome = wait_for_terminal(
            &running,
            stdout,
            stderr,
            request.timeout_ms,
            request.max_output_bytes,
        )
        .await;

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
        self.running.lock().await.remove(&request.job_resource_id);
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

enum TerminalCause {
    Exited,
    TimedOut,
    Cancelled,
    Failed,
}

async fn wait_for_terminal(
    running: &RunningJob,
    stdout: impl AsyncRead + Send + Unpin + 'static,
    stderr: impl AsyncRead + Send + Unpin + 'static,
    timeout_ms: u64,
    max_output_bytes: usize,
) -> JobRunOutcome {
    let started = Instant::now();
    let stdout_buffer = OutputBuffer::default();
    let stderr_buffer = OutputBuffer::default();
    let mut stdout_task = tokio::spawn(read_bounded(
        stdout,
        max_output_bytes,
        stdout_buffer.clone(),
    ));
    let mut stderr_task = tokio::spawn(read_bounded(
        stderr,
        max_output_bytes,
        stderr_buffer.clone(),
    ));
    let mut direct_exit = None;
    let mut stdout_output = None;
    let mut stderr_output = None;
    let timeout = tokio::time::sleep(Duration::from_millis(timeout_ms));
    tokio::pin!(timeout);

    let (terminal, cleanup_error) = loop {
        update_output_pending(running, &stdout_output, &stderr_output);
        if direct_exit.is_some() && stdout_output.is_some() && stderr_output.is_some() {
            break (TerminalCause::Exited, None);
        }

        tokio::select! {
            result = &mut stdout_task, if stdout_output.is_none() => {
                stdout_output = Some(captured_from_join(result));
            }
            result = &mut stderr_task, if stderr_output.is_none() => {
                stderr_output = Some(captured_from_join(result));
            }
            _ = &mut timeout => {
                let cleanup_error = terminate_for_terminal(running, "timeout").await;
                break (TerminalCause::TimedOut, cleanup_error);
            }
            () = tokio::time::sleep(POLL_INTERVAL) => {
                if direct_exit.is_none() {
                    direct_exit = direct_exit_status(running).await;
                    if direct_exit.is_none() {
                        match running.child.lock().await.try_wait() {
                            Ok(Some(status)) => {
                                record_direct_exit(running, status).await;
                                direct_exit = Some(status);
                            }
                            Ok(None) => {}
                            Err(error) => {
                                break (
                                    TerminalCause::Failed,
                                    Some(format!("inspect direct job child: {error}")),
                                );
                            }
                        }
                    }
                }
                if running.cancel_requested.load(Ordering::SeqCst) {
                    let cleanup_error = terminate_for_terminal(running, "cancel").await;
                    break (TerminalCause::Cancelled, cleanup_error);
                }
            }
        }
    };

    let stdout = finish_reader(&mut stdout_task, stdout_output, &stdout_buffer).await;
    let stderr = finish_reader(&mut stderr_task, stderr_output, &stderr_buffer).await;
    running.output_pending.store(false, Ordering::SeqCst);

    let cleanup_suffix = cleanup_error
        .map(|error| format!("; cleanup: {error}"))
        .unwrap_or_default();
    let duration_ms = duration_ms(started.elapsed());
    match terminal {
        TerminalCause::Exited => {
            let status = direct_exit.expect("exited terminal requires direct status");
            JobRunOutcome {
                state: if status.success() {
                    JobState::Completed
                } else {
                    JobState::Failed
                },
                exit_code: status.code(),
                timed_out: false,
                cancelled: false,
                cancellation_reason: None,
                stdout: stdout.text,
                stderr: stderr.text,
                stdout_truncated: stdout.truncated,
                stderr_truncated: stderr.truncated,
                duration_ms,
                error: if status.success() {
                    None
                } else {
                    Some(format!(
                        "process exited with non-zero status{cleanup_suffix}"
                    ))
                },
            }
        }
        TerminalCause::TimedOut => JobRunOutcome {
            state: JobState::TimedOut,
            exit_code: None,
            timed_out: true,
            cancelled: false,
            cancellation_reason: None,
            stdout: stdout.text,
            stderr: stderr.text,
            stdout_truncated: stdout.truncated,
            stderr_truncated: stderr.truncated,
            duration_ms,
            error: Some(format!("process timed out and was killed{cleanup_suffix}")),
        },
        TerminalCause::Cancelled => JobRunOutcome {
            state: JobState::Cancelled,
            exit_code: None,
            timed_out: false,
            cancelled: true,
            cancellation_reason: running.cancel_reason.lock().await.clone(),
            stdout: stdout.text,
            stderr: stderr.text,
            stdout_truncated: stdout.truncated,
            stderr_truncated: stderr.truncated,
            duration_ms,
            error: Some(format!("process was cancelled{cleanup_suffix}")),
        },
        TerminalCause::Failed => JobRunOutcome {
            state: JobState::Failed,
            exit_code: None,
            timed_out: false,
            cancelled: running.cancel_requested.load(Ordering::SeqCst),
            cancellation_reason: running.cancel_reason.lock().await.clone(),
            stdout: stdout.text,
            stderr: stderr.text,
            stdout_truncated: stdout.truncated,
            stderr_truncated: stderr.truncated,
            duration_ms,
            error: cleanup_suffix
                .strip_prefix("; cleanup: ")
                .map(str::to_owned)
                .or_else(|| Some("job runtime failed before terminal status".to_owned())),
        },
    }
}

async fn observe_direct_exit(running: &RunningJob) -> Result<bool, String> {
    if running.direct_exit_observed.load(Ordering::SeqCst) {
        return Ok(true);
    }
    let mut child = running.child.lock().await;
    match child.try_wait() {
        Ok(Some(status)) => {
            drop(child);
            record_direct_exit(running, status).await;
            Ok(true)
        }
        Ok(None) => Ok(false),
        Err(error) => Err(format!("inspect direct job child: {error}")),
    }
}

async fn kill_direct_child(running: &RunningJob) -> bool {
    let mut child = running.child.lock().await;
    match child.try_wait() {
        Ok(Some(status)) => {
            drop(child);
            record_direct_exit(running, status).await;
            false
        }
        Ok(None) => child.start_kill().is_ok(),
        Err(_) => false,
    }
}

async fn record_direct_exit(running: &RunningJob, status: std::process::ExitStatus) {
    running.direct_exit_observed.store(true, Ordering::SeqCst);
    *running.direct_exit_status.lock().await = Some(status);
}

async fn direct_exit_status(running: &RunningJob) -> Option<std::process::ExitStatus> {
    *running.direct_exit_status.lock().await
}

async fn terminate_for_terminal(running: &RunningJob, reason: &str) -> Option<String> {
    let mut errors = Vec::new();
    match signal_process_group(running.process_group_id, "TERM") {
        ProcessSignalResult::Delivered => {
            running.cancel_delivered.store(true, Ordering::SeqCst);
        }
        ProcessSignalResult::NoSuchProcess => {}
        ProcessSignalResult::Unsupported => {
            errors.push(format!(
                "{reason} could not signal process group on this platform"
            ));
        }
        ProcessSignalResult::Failed(error) => errors.push(error),
    }
    tokio::time::sleep(PROCESS_GROUP_TERM_GRACE).await;
    match signal_process_group(running.process_group_id, "KILL") {
        ProcessSignalResult::Delivered | ProcessSignalResult::NoSuchProcess => {}
        ProcessSignalResult::Unsupported => {}
        ProcessSignalResult::Failed(error) => errors.push(error),
    }

    if !running.direct_exit_observed.load(Ordering::SeqCst) {
        let mut child = running.child.lock().await;
        match tokio::time::timeout(CHILD_WAIT_GRACE, child.wait()).await {
            Ok(Ok(status)) => {
                drop(child);
                record_direct_exit(running, status).await;
            }
            Ok(Err(error)) => errors.push(format!("wait for direct child after {reason}: {error}")),
            Err(_) => errors.push(format!("direct child did not exit after {reason} signal")),
        }
    }

    if errors.is_empty() {
        None
    } else {
        Some(errors.join("; "))
    }
}

fn update_output_pending(
    running: &RunningJob,
    stdout: &Option<CapturedOutput>,
    stderr: &Option<CapturedOutput>,
) {
    running
        .output_pending
        .store(stdout.is_none() || stderr.is_none(), Ordering::SeqCst);
}

async fn finish_reader(
    task: &mut JoinHandle<CapturedOutput>,
    current: Option<CapturedOutput>,
    buffer: &OutputBuffer,
) -> CapturedOutput {
    if let Some(output) = current {
        return output;
    }
    match tokio::time::timeout(OUTPUT_DRAIN_GRACE, &mut *task).await {
        Ok(result) => captured_from_join(result),
        Err(_) => {
            task.abort();
            buffer.mark_truncated().await;
            buffer.snapshot().await
        }
    }
}

fn captured_from_join(result: Result<CapturedOutput, JoinError>) -> CapturedOutput {
    result.unwrap_or_else(|_| CapturedOutput {
        text: String::new(),
        truncated: true,
    })
}

impl OutputBuffer {
    async fn append(&self, bytes: &[u8], max_bytes: usize) {
        let mut inner = self.inner.lock().await;
        let remaining = max_bytes.saturating_sub(inner.bytes.len());
        if remaining > 0 {
            inner
                .bytes
                .extend_from_slice(&bytes[..bytes.len().min(remaining)]);
        }
        if bytes.len() > remaining {
            inner.truncated = true;
        }
    }

    async fn mark_truncated(&self) {
        self.inner.lock().await.truncated = true;
    }

    async fn snapshot(&self) -> CapturedOutput {
        let inner = self.inner.lock().await;
        CapturedOutput {
            text: String::from_utf8_lossy(&inner.bytes).into_owned(),
            truncated: inner.truncated,
        }
    }
}

async fn read_bounded<R>(mut reader: R, max_bytes: usize, buffer: OutputBuffer) -> CapturedOutput
where
    R: AsyncRead + Unpin,
{
    let mut buf = [0_u8; 8192];
    loop {
        match reader.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => {
                buffer.append(&buf[..n], max_bytes).await;
            }
            Err(_) => {
                buffer.mark_truncated().await;
                break;
            }
        }
    }
    buffer.snapshot().await
}

enum ProcessSignalResult {
    Delivered,
    NoSuchProcess,
    Unsupported,
    Failed(String),
}

#[cfg(unix)]
fn signal_process_group(process_group_id: Option<i32>, signal: &str) -> ProcessSignalResult {
    let Some(process_group_id) = process_group_id else {
        return ProcessSignalResult::Unsupported;
    };
    let output = std::process::Command::new("/bin/kill")
        .arg(format!("-{signal}"))
        .arg("--")
        .arg(format!("-{process_group_id}"))
        .output();
    match output {
        Ok(output) if output.status.success() => ProcessSignalResult::Delivered,
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
            if stderr.contains("No such process") {
                ProcessSignalResult::NoSuchProcess
            } else {
                ProcessSignalResult::Failed(format!(
                    "signal process group {process_group_id} with {signal}: {}",
                    stderr.trim()
                ))
            }
        }
        Err(error) => ProcessSignalResult::Failed(format!(
            "spawn /bin/kill for process group {process_group_id} with {signal}: {error}"
        )),
    }
}

#[cfg(not(unix))]
fn signal_process_group(_process_group_id: Option<i32>, _signal: &str) -> ProcessSignalResult {
    ProcessSignalResult::Unsupported
}

#[cfg(unix)]
fn process_group_id_for_child(process_id: u32) -> Option<i32> {
    i32::try_from(process_id).ok()
}

#[cfg(not(unix))]
fn process_group_id_for_child(_process_id: u32) -> Option<i32> {
    None
}

#[cfg(unix)]
fn configure_owned_process_group(command: &mut Command) {
    command.process_group(0);
}

#[cfg(not(unix))]
fn configure_owned_process_group(_command: &mut Command) {}

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
    configure_owned_process_group(&mut cmd);
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
