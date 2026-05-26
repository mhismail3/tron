//! Parent-side process isolation for JavaScript program execution.

use std::env;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::protocol::{
    PROGRAM_WORKER_PROTOCOL_VERSION, ParentToProgramWorker, ProgramWorkerToParent,
};
use super::runtime::{
    ProgramExecutor, ProgramRunRequest, ProgramRunResult, ProgramRuntimeError, ProgramToolHost,
    QuickJsProgramExecutor, failed_result_for_request,
};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
const STDERR_CAP_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug)]
pub(crate) struct ProcessProgramExecutor {
    worker_path: Option<PathBuf>,
    startup_timeout: Duration,
}

impl Default for ProcessProgramExecutor {
    fn default() -> Self {
        Self {
            worker_path: resolve_worker_path(),
            startup_timeout: STARTUP_TIMEOUT,
        }
    }
}

impl ProgramExecutor for ProcessProgramExecutor {
    fn execute(
        &self,
        request: ProgramRunRequest,
        tool_host: Arc<dyn ProgramToolHost>,
    ) -> Result<ProgramRunResult, ProgramRuntimeError> {
        let Some(worker_path) = self.worker_path.clone() else {
            return Ok(failed_result_for_request(
                &request,
                "worker_disconnected",
                ProgramRuntimeError::new(
                    "PROGRAM_WORKER_NOT_FOUND",
                    "tron-program-worker executable was not found beside the current binary",
                ),
            ));
        };
        if !worker_path.is_file() {
            return Ok(failed_result_for_request(
                &request,
                "worker_disconnected",
                ProgramRuntimeError::new(
                    "PROGRAM_WORKER_NOT_FOUND",
                    format!(
                        "program worker executable does not exist: {}",
                        worker_path.display()
                    ),
                ),
            ));
        }
        self.execute_with_path(worker_path, request, tool_host)
    }
}

impl ProcessProgramExecutor {
    fn execute_with_path(
        &self,
        worker_path: PathBuf,
        request: ProgramRunRequest,
        tool_host: Arc<dyn ProgramToolHost>,
    ) -> Result<ProgramRunResult, ProgramRuntimeError> {
        let limits = request.limits_value();
        let timeout = limits
            .get("timeoutMs")
            .and_then(Value::as_u64)
            .map(Duration::from_millis)
            .unwrap_or(Duration::from_secs(2));
        let cwd = tempfile::tempdir().map_err(|error| {
            ProgramRuntimeError::new(
                "PROGRAM_WORKER_TEMP_DIR_FAILED",
                format!("create program worker cwd: {error}"),
            )
        })?;
        let mut child = spawn_worker(&worker_path, cwd.path()).map_err(|error| {
            ProgramRuntimeError::new(
                "PROGRAM_WORKER_START_FAILED",
                format!("start program worker: {error}"),
            )
        })?;
        let Some(stdin) = child.stdin.take() else {
            terminate_child(&mut child);
            return Ok(failed_result_for_request(
                &request,
                "worker_disconnected",
                ProgramRuntimeError::new("PROGRAM_WORKER_STDIN_MISSING", "worker stdin missing"),
            ));
        };
        let Some(stdout) = child.stdout.take() else {
            terminate_child(&mut child);
            return Ok(failed_result_for_request(
                &request,
                "worker_disconnected",
                ProgramRuntimeError::new("PROGRAM_WORKER_STDOUT_MISSING", "worker stdout missing"),
            ));
        };
        let stderr = child.stderr.take();
        let stderr_handle = stderr.map(capture_stderr);
        let mut writer = stdin;
        let (line_tx, line_rx) = mpsc::channel();
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                let message = match line {
                    Ok(line) => serde_json::from_str::<ProgramWorkerToParent>(&line)
                        .map_err(|error| format!("decode worker message: {error}")),
                    Err(error) => Err(format!("read worker stdout: {error}")),
                };
                if line_tx.send(message).is_err() {
                    return;
                }
            }
        });

        match recv_worker_message(&line_rx, self.startup_timeout) {
            Ok(ProgramWorkerToParent::Ready { protocol_version })
                if protocol_version == PROGRAM_WORKER_PROTOCOL_VERSION => {}
            Ok(other) => {
                terminate_child(&mut child);
                return Ok(failed_result_for_request(
                    &request,
                    "worker_disconnected",
                    ProgramRuntimeError::new(
                        "PROGRAM_WORKER_READY_INVALID",
                        format!("unexpected first worker message: {other:?}"),
                    ),
                ));
            }
            Err(error) => {
                terminate_child(&mut child);
                return Ok(failed_result_for_request(
                    &request,
                    "worker_disconnected",
                    error,
                ));
            }
        }

        if let Err(error) = write_parent_message(
            &mut writer,
            &ParentToProgramWorker::Run {
                request: Box::new(request.clone()),
            },
        ) {
            terminate_child(&mut child);
            return Ok(failed_result_for_request(
                &request,
                "worker_disconnected",
                error,
            ));
        }

        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                let _ = write_parent_message(
                    &mut writer,
                    &ParentToProgramWorker::Cancel {
                        reason: "timeout".to_owned(),
                    },
                );
                terminate_child(&mut child);
                return Ok(failed_result_for_request(
                    &request,
                    "timeout",
                    ProgramRuntimeError::new(
                        "PROGRAM_WORKER_TIMEOUT",
                        "program worker exceeded timeout",
                    ),
                ));
            }
            match recv_worker_message(&line_rx, remaining) {
                Ok(ProgramWorkerToParent::HostCall { id, payload }) => {
                    let response = match tool_host.call(payload) {
                        Ok(value) => ParentToProgramWorker::HostResult { id, value },
                        Err(error) => ParentToProgramWorker::HostError {
                            id,
                            code: error.code,
                            message: error.message,
                            details: error.details,
                        },
                    };
                    if let Err(error) = write_parent_message(&mut writer, &response) {
                        terminate_child(&mut child);
                        return Ok(failed_result_for_request(
                            &request,
                            "worker_disconnected",
                            error,
                        ));
                    }
                }
                Ok(ProgramWorkerToParent::Result { result }) => {
                    let _ = child.wait();
                    let _ = stderr_handle.map(|handle| handle.join());
                    return Ok(*result);
                }
                Ok(ProgramWorkerToParent::WorkerError {
                    code,
                    message,
                    details,
                }) => {
                    terminate_child(&mut child);
                    return Ok(failed_result_for_request(
                        &request,
                        "failed",
                        ProgramRuntimeError::new(&code, message)
                            .with_details(details.unwrap_or(Value::Null)),
                    ));
                }
                Ok(ProgramWorkerToParent::Ready { .. }) => {}
                Err(error) => {
                    terminate_child(&mut child);
                    let _ = stderr_handle.map(|handle| handle.join());
                    return Ok(failed_result_for_request(
                        &request,
                        "worker_disconnected",
                        error,
                    ));
                }
            }
        }
    }
}

pub(super) fn worker_process_main() -> ExitCode {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let reader = Arc::new(Mutex::new(BufReader::new(stdin)));
    let writer = Arc::new(Mutex::new(stdout));
    if write_worker_message(
        &writer,
        &ProgramWorkerToParent::Ready {
            protocol_version: PROGRAM_WORKER_PROTOCOL_VERSION,
        },
    )
    .is_err()
    {
        return ExitCode::from(2);
    }
    let message = match read_parent_message(&reader) {
        Ok(message) => message,
        Err(error) => {
            let _ = write_worker_message(
                &writer,
                &ProgramWorkerToParent::WorkerError {
                    code: error.code,
                    message: error.message,
                    details: error.details,
                },
            );
            return ExitCode::from(2);
        }
    };
    let ParentToProgramWorker::Run { request } = message else {
        let _ = write_worker_message(
            &writer,
            &ProgramWorkerToParent::WorkerError {
                code: "PROGRAM_WORKER_EXPECTED_RUN".to_owned(),
                message: "first parent message must be run".to_owned(),
                details: None,
            },
        );
        return ExitCode::from(2);
    };
    let host = Arc::new(WorkerProcessToolHost::new(reader, writer.clone()));
    let result = QuickJsProgramExecutor::default().execute(*request, host);
    let message = match result {
        Ok(result) => ProgramWorkerToParent::Result {
            result: Box::new(result),
        },
        Err(error) => ProgramWorkerToParent::WorkerError {
            code: error.code,
            message: error.message,
            details: error.details,
        },
    };
    if write_worker_message(&writer, &message).is_err() {
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}

struct WorkerProcessToolHost {
    reader: Arc<Mutex<BufReader<std::io::Stdin>>>,
    writer: Arc<Mutex<std::io::Stdout>>,
    next_id: AtomicU64,
}

impl WorkerProcessToolHost {
    fn new(
        reader: Arc<Mutex<BufReader<std::io::Stdin>>>,
        writer: Arc<Mutex<std::io::Stdout>>,
    ) -> Self {
        Self {
            reader,
            writer,
            next_id: AtomicU64::new(1),
        }
    }
}

impl ProgramToolHost for WorkerProcessToolHost {
    fn call(&self, payload: Value) -> Result<Value, ProgramRuntimeError> {
        let id = format!(
            "program_host_call_{}",
            self.next_id.fetch_add(1, Ordering::SeqCst)
        );
        write_worker_message(
            &self.writer,
            &ProgramWorkerToParent::HostCall {
                id: id.clone(),
                payload,
            },
        )?;
        match read_parent_message(&self.reader)? {
            ParentToProgramWorker::HostResult {
                id: response_id,
                value,
            } if response_id == id => Ok(value),
            ParentToProgramWorker::HostError {
                id: response_id,
                code,
                message,
                details,
            } if response_id == id => Err(ProgramRuntimeError::new(&code, message)
                .with_details(details.unwrap_or(Value::Null))),
            ParentToProgramWorker::Cancel { reason } => Err(ProgramRuntimeError::new(
                "PROGRAM_CANCELLED",
                format!("program cancelled: {reason}"),
            )),
            other => Err(ProgramRuntimeError::new(
                "PROGRAM_WORKER_PROTOCOL_ERROR",
                format!("unexpected parent response: {other:?}"),
            )),
        }
    }
}

fn spawn_worker(path: &PathBuf, cwd: &std::path::Path) -> std::io::Result<Child> {
    let mut command = Command::new(path);
    command
        .env_clear()
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command.spawn()
}

fn terminate_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn recv_worker_message(
    rx: &mpsc::Receiver<Result<ProgramWorkerToParent, String>>,
    timeout: Duration,
) -> Result<ProgramWorkerToParent, ProgramRuntimeError> {
    match rx.recv_timeout(timeout) {
        Ok(Ok(message)) => Ok(message),
        Ok(Err(message)) => Err(ProgramRuntimeError::new(
            "PROGRAM_WORKER_PROTOCOL_ERROR",
            message,
        )),
        Err(mpsc::RecvTimeoutError::Timeout) => Err(ProgramRuntimeError::new(
            "PROGRAM_WORKER_TIMEOUT",
            "program worker did not respond before timeout",
        )),
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(ProgramRuntimeError::new(
            "PROGRAM_WORKER_DISCONNECTED",
            "program worker stdout closed",
        )),
    }
}

fn write_parent_message(
    writer: &mut std::process::ChildStdin,
    message: &ParentToProgramWorker,
) -> Result<(), ProgramRuntimeError> {
    let encoded = serde_json::to_string(message).map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_PROTOCOL_ERROR",
            format!("encode parent message: {error}"),
        )
    })?;
    writeln!(writer, "{encoded}").map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_DISCONNECTED",
            format!("write program worker stdin: {error}"),
        )
    })?;
    writer.flush().map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_DISCONNECTED",
            format!("flush program worker stdin: {error}"),
        )
    })
}

fn write_worker_message(
    writer: &Arc<Mutex<std::io::Stdout>>,
    message: &ProgramWorkerToParent,
) -> Result<(), ProgramRuntimeError> {
    let encoded = serde_json::to_string(message).map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_PROTOCOL_ERROR",
            format!("encode worker message: {error}"),
        )
    })?;
    let mut writer = writer.lock().map_err(|_| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_PROTOCOL_ERROR",
            "worker stdout mutex poisoned",
        )
    })?;
    writeln!(writer, "{encoded}").map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_DISCONNECTED",
            format!("write worker stdout: {error}"),
        )
    })?;
    writer.flush().map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_DISCONNECTED",
            format!("flush worker stdout: {error}"),
        )
    })
}

fn read_parent_message(
    reader: &Arc<Mutex<BufReader<std::io::Stdin>>>,
) -> Result<ParentToProgramWorker, ProgramRuntimeError> {
    let mut line = String::new();
    let mut reader = reader.lock().map_err(|_| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_PROTOCOL_ERROR",
            "worker stdin mutex poisoned",
        )
    })?;
    let bytes = reader.read_line(&mut line).map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_DISCONNECTED",
            format!("read worker stdin: {error}"),
        )
    })?;
    if bytes == 0 {
        return Err(ProgramRuntimeError::new(
            "PROGRAM_WORKER_DISCONNECTED",
            "parent stdin closed",
        ));
    }
    serde_json::from_str(line.trim_end()).map_err(|error| {
        ProgramRuntimeError::new(
            "PROGRAM_WORKER_PROTOCOL_ERROR",
            format!("decode parent message: {error}"),
        )
    })
}

fn capture_stderr(stderr: std::process::ChildStderr) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let mut reader = BufReader::new(stderr);
        let mut captured = String::new();
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    if captured.len() < STDERR_CAP_BYTES {
                        let remaining = STDERR_CAP_BYTES - captured.len();
                        captured.push_str(&line.chars().take(remaining).collect::<String>());
                    }
                }
                Err(_) => break,
            }
        }
        captured
    })
}

fn resolve_worker_path() -> Option<PathBuf> {
    if let Ok(path) = env::var("TRON_PROGRAM_WORKER_BIN")
        && !path.trim().is_empty()
    {
        return Some(PathBuf::from(path));
    }
    let exe = env::current_exe().ok()?;
    let mut dir = exe.parent()?.to_path_buf();
    if dir.file_name().and_then(|name| name.to_str()) == Some("deps")
        && let Some(parent) = dir.parent()
    {
        dir = parent.to_path_buf();
    }
    let name = if cfg!(windows) {
        "tron-program-worker.exe"
    } else {
        "tron-program-worker"
    };
    Some(dir.join(name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    struct NoopToolHost;

    impl ProgramToolHost for NoopToolHost {
        fn call(&self, _payload: Value) -> Result<Value, ProgramRuntimeError> {
            Ok(json!({}))
        }
    }

    fn request() -> ProgramRunRequest {
        ProgramRunRequest {
            language: "javascript".to_owned(),
            code: "return args;".to_owned(),
            args: json!({"ok": true}),
            allowed_contracts: Vec::new(),
            allowed_implementations: Vec::new(),
            timeout_ms: Some(50),
            budget: None,
            idempotency_key: Some("test-program".to_owned()),
            reason: None,
        }
    }

    #[test]
    fn missing_program_worker_returns_structured_failed_run() {
        let executor = ProcessProgramExecutor {
            worker_path: Some(PathBuf::from("/definitely/not/tron-program-worker")),
            startup_timeout: Duration::from_millis(5),
        };

        let result = executor
            .execute(request(), Arc::new(NoopToolHost))
            .expect("missing worker is represented as a failed program run");

        assert_eq!(result.status, "worker_disconnected");
        assert_eq!(
            result
                .error
                .as_ref()
                .and_then(|error| error.get("code"))
                .and_then(Value::as_str),
            Some("PROGRAM_WORKER_NOT_FOUND")
        );
        assert!(result.program_run_id.starts_with("program_run_"));
        assert!(result.child_invocations.is_empty());
    }
}
