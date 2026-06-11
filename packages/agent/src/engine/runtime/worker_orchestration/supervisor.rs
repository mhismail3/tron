use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration as StdDuration;

use async_trait::async_trait;
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt as _;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use super::contracts::validate_direct_path;
use super::process_resource::redact_text;
use crate::engine::kernel::errors::{EngineError, Result};

/// Launch request delivered to a process supervisor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerProcessStartRequest {
    /// Stable `worker_process` resource id.
    pub process_resource_id: String,
    /// Direct executable path.
    pub executable_path: PathBuf,
    /// Argument vector excluding the executable.
    pub argv: Vec<String>,
    /// Explicit environment entries. The caller already validated allowlists.
    pub env: BTreeMap<String, String>,
    /// Optional working directory.
    pub cwd: Option<PathBuf>,
    /// Bound used by supervisor startup.
    pub startup_timeout: StdDuration,
    /// Bound used by stop before kill.
    pub stop_timeout: StdDuration,
    /// Maximum stdout/stderr bytes retained for audit.
    pub max_log_capture_bytes: usize,
}

/// Redacted process handle details safe to persist.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerProcessHandle {
    /// Opaque id used by the supervisor for stop.
    pub supervisor_process_id: String,
    /// OS pid when one exists.
    pub pid: Option<u32>,
    /// Non-secret fingerprint of process id and pid.
    pub pid_fingerprint: String,
}

/// Result returned after a supervisor starts a process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerProcessStartResult {
    /// Redacted process handle.
    pub handle: WorkerProcessHandle,
    /// Redacted stdout snippet available at start.
    pub stdout_snippet: String,
    /// Redacted stderr snippet available at start.
    pub stderr_snippet: String,
    /// Whether captured output hit the configured byte cap.
    pub output_truncated: bool,
}

/// Result returned when a process is stopped.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerProcessStopResult {
    /// Terminal lifecycle status, normally `stopped` or `killed`.
    pub status: String,
    /// Optional exit code.
    pub exit_code: Option<i32>,
    /// Redacted stdout snippet.
    pub stdout_snippet: String,
    /// Redacted stderr snippet.
    pub stderr_snippet: String,
    /// Whether captured output hit the configured byte cap.
    pub output_truncated: bool,
}

/// Direct process supervisor boundary.
#[async_trait]
pub trait WorkerProcessSupervisor: Send + Sync {
    /// Start one direct executable invocation.
    async fn start(&self, request: WorkerProcessStartRequest) -> Result<WorkerProcessStartResult>;
    /// Stop one process, waiting for the graceful bound before force kill.
    async fn stop(
        &self,
        handle: WorkerProcessHandle,
        stop_timeout: StdDuration,
    ) -> Result<WorkerProcessStopResult>;
}

/// Replaceable supervisor registry shared by launch/stop tests and runtime.
#[derive(Clone)]
pub struct WorkerProcessSupervisorRegistry {
    supervisor: Arc<parking_lot::RwLock<Arc<dyn WorkerProcessSupervisor>>>,
}

impl WorkerProcessSupervisorRegistry {
    /// Create a registry backed by the production direct-exec supervisor.
    #[must_use]
    pub fn production() -> Self {
        Self {
            supervisor: Arc::new(parking_lot::RwLock::new(Arc::new(
                TokioWorkerProcessSupervisor::default(),
            ))),
        }
    }

    /// Return the current supervisor.
    #[must_use]
    pub fn supervisor(&self) -> Arc<dyn WorkerProcessSupervisor> {
        self.supervisor.read().clone()
    }

    /// Replace the supervisor. Tests use this for deterministic fake processes.
    pub fn set_supervisor(&self, supervisor: Arc<dyn WorkerProcessSupervisor>) {
        *self.supervisor.write() = supervisor;
    }
}

impl Default for WorkerProcessSupervisorRegistry {
    fn default() -> Self {
        Self::production()
    }
}

#[derive(Default)]
struct TokioWorkerProcessSupervisor {
    children: Mutex<BTreeMap<String, ManagedChild>>,
}

struct ManagedChild {
    child: Child,
    stdout: tokio::task::JoinHandle<(String, bool)>,
    stderr: tokio::task::JoinHandle<(String, bool)>,
}

#[async_trait]
impl WorkerProcessSupervisor for TokioWorkerProcessSupervisor {
    async fn start(&self, request: WorkerProcessStartRequest) -> Result<WorkerProcessStartResult> {
        validate_direct_path(
            "executable path",
            request.executable_path.to_string_lossy().as_ref(),
        )?;
        let mut command = Command::new(&request.executable_path);
        command.args(&request.argv);
        command.env_clear();
        command.envs(&request.env);
        if let Some(cwd) = &request.cwd {
            command.current_dir(cwd);
        }
        command.stdout(std::process::Stdio::piped());
        command.stderr(std::process::Stdio::piped());
        let mut child = command
            .spawn()
            .map_err(|error| EngineError::WorkerTransportFailure {
                code: "WORKER_PROCESS_START_FAILED".to_owned(),
                message: format!("worker process spawn failed: {error}"),
            })?;
        let pid = child.id();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let max = request.max_log_capture_bytes;
        let stdout = tokio::spawn(async move { capture_output(stdout, max).await });
        let stderr = tokio::spawn(async move { capture_output(stderr, max).await });
        let handle = WorkerProcessHandle {
            supervisor_process_id: request.process_resource_id.clone(),
            pid,
            pid_fingerprint: pid_fingerprint(&request.process_resource_id, pid),
        };
        self.children.lock().await.insert(
            request.process_resource_id,
            ManagedChild {
                child,
                stdout,
                stderr,
            },
        );
        Ok(WorkerProcessStartResult {
            handle,
            stdout_snippet: String::new(),
            stderr_snippet: String::new(),
            output_truncated: false,
        })
    }

    async fn stop(
        &self,
        handle: WorkerProcessHandle,
        stop_timeout: StdDuration,
    ) -> Result<WorkerProcessStopResult> {
        let Some(mut managed) = self
            .children
            .lock()
            .await
            .remove(&handle.supervisor_process_id)
        else {
            return Ok(WorkerProcessStopResult {
                status: "stopped".to_owned(),
                exit_code: None,
                stdout_snippet: String::new(),
                stderr_snippet: String::new(),
                output_truncated: false,
            });
        };
        let wait = tokio::time::timeout(stop_timeout, managed.child.wait()).await;
        let (status, exit_code) = match wait {
            Ok(Ok(status)) => ("stopped".to_owned(), status.code()),
            Ok(Err(error)) => {
                return Err(EngineError::WorkerTransportFailure {
                    code: "WORKER_PROCESS_STOP_FAILED".to_owned(),
                    message: format!("worker process wait failed: {error}"),
                });
            }
            Err(_) => {
                managed.child.start_kill().map_err(|error| {
                    EngineError::WorkerTransportFailure {
                        code: "WORKER_PROCESS_KILL_FAILED".to_owned(),
                        message: format!("worker process kill failed: {error}"),
                    }
                })?;
                let status = managed.child.wait().await.map_err(|error| {
                    EngineError::WorkerTransportFailure {
                        code: "WORKER_PROCESS_KILL_WAIT_FAILED".to_owned(),
                        message: format!("worker process kill wait failed: {error}"),
                    }
                })?;
                ("killed".to_owned(), status.code())
            }
        };
        let (stdout_snippet, stdout_truncated) = join_capture(managed.stdout).await;
        let (stderr_snippet, stderr_truncated) = join_capture(managed.stderr).await;
        Ok(WorkerProcessStopResult {
            status,
            exit_code,
            stdout_snippet,
            stderr_snippet,
            output_truncated: stdout_truncated || stderr_truncated,
        })
    }
}

async fn capture_output(
    stream: Option<impl tokio::io::AsyncRead + Unpin>,
    max: usize,
) -> (String, bool) {
    let Some(mut stream) = stream else {
        return (String::new(), false);
    };
    let mut bytes = Vec::new();
    let mut truncated = false;
    let mut buffer = [0_u8; 512];
    loop {
        match stream.read(&mut buffer).await {
            Ok(0) => break,
            Ok(read) => {
                if bytes.len() < max {
                    let remaining = max - bytes.len();
                    let take = remaining.min(read);
                    bytes.extend_from_slice(&buffer[..take]);
                    truncated |= take < read;
                } else {
                    truncated = true;
                }
            }
            Err(_) => break,
        }
    }
    (
        redact_text(&String::from_utf8_lossy(&bytes), max),
        truncated,
    )
}

async fn join_capture(handle: tokio::task::JoinHandle<(String, bool)>) -> (String, bool) {
    match tokio::time::timeout(StdDuration::from_millis(250), handle).await {
        Ok(Ok(captured)) => captured,
        _ => (String::new(), true),
    }
}

fn pid_fingerprint(process_resource_id: &str, pid: Option<u32>) -> String {
    let hash = hex::encode(Sha256::digest(
        format!("{process_resource_id}:{}", pid.unwrap_or_default()).as_bytes(),
    ));
    hash.chars().take(16).collect()
}
