//! Disposable-helper execution with durable nested-call replay.
//!
//! QuickJS never runs in the server process on this path. The parent owns the
//! cell/call journal, answers one correlated broker request at a time, and
//! keeps the helper in an isolated process group. Dropping or cancelling the
//! invocation therefore terminates the complete helper tree while a server
//! crash leaves the admitted cell and any completed nested effects available
//! for exact replay.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde_json::Value;
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio_util::sync::CancellationToken;

use super::evaluator::{BrokerError, BrokerRequest, EvaluationOutcome, builtin};
use super::helper::{HELPER_PROTOCOL_VERSION, HelperBrokerResponse, HelperCommand, HelperEvent};
use super::store::{CallRow, CellRow, CodeRuntimeStore, StoreError};
use super::types::RuntimeLimits;
use crate::domains::host::process_custody::ProcessTree;

const MAX_PROTOCOL_FRAME_BYTES: usize = 4 * 1_048_576;
const MAX_HELPER_STDERR_BYTES: usize = 64 * 1024;
const HELPER_EXIT_GRACE: Duration = Duration::from_secs(2);

/// Async authority boundary used only by the parent process.
///
/// Implementations must deduplicate every effect by `request.call_id`. The
/// parent may repeat a call after losing the helper between effect completion
/// and response import.
#[async_trait]
pub trait AsyncBroker: Send + Sync {
    /// Execute one closed, engine-admitted operation.
    async fn call(&self, request: &BrokerRequest) -> Result<Value, BrokerError>;
}

/// Rejecting broker useful for code which needs computation only.
#[derive(Debug, Default)]
pub struct RejectingAsyncBroker;

#[async_trait]
impl AsyncBroker for RejectingAsyncBroker {
    async fn call(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        Err(BrokerError::new(format!(
            "broker operation '{}' is unavailable",
            request.operation
        )))
    }
}

/// Child-helper evaluation failure.
#[derive(Debug, Error)]
pub(crate) enum ProcessEvaluationError {
    #[error("code helper I/O failed: {0}")]
    Io(String),
    #[error("code helper protocol failed: {0}")]
    Protocol(String),
    #[error("code helper exited before a terminal result{0}")]
    HelperExited(String),
    #[error("code helper evaluation failed: {0}")]
    JavaScript(String),
    #[error("code execution was cancelled")]
    Cancelled,
    #[error("code execution exceeded its wall-clock limit")]
    TimedOut,
    #[error(transparent)]
    Store(#[from] StoreError),
}

impl ProcessEvaluationError {
    /// A process disappearance is intentionally left nonterminal so startup or
    /// a duplicate invocation can resume the same durable cell.
    pub(crate) const fn preserves_running_cell(&self) -> bool {
        matches!(self, Self::Io(_) | Self::HelperExited(_))
    }
}

/// Explicit helper binary location.
#[derive(Clone, Debug)]
pub struct CodeHelper {
    path: PathBuf,
    arguments: Vec<String>,
}

impl CodeHelper {
    /// Use an exact executable path. Resolution never consults `PATH`.
    pub fn at(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            arguments: Vec::new(),
        }
    }

    /// Resolve the helper as a hidden mode of this exact Tron executable.
    ///
    /// Reusing the installed binary preserves a single build/sign/install
    /// artifact and makes helper/server protocol skew impossible while still
    /// retaining OS-process isolation.
    pub fn installed() -> Result<Self, std::io::Error> {
        let executable = std::env::current_exe()?;
        Ok(Self {
            path: executable,
            arguments: vec!["code-runtime-helper".to_owned()],
        })
    }

    /// Exact helper path used for diagnostics and packaging tests.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.path);
        command.args(&self.arguments);
        command
    }
}

struct DurableBridge {
    store: CodeRuntimeStore,
    broker: Arc<dyn AsyncBroker>,
    replay: Vec<CallRow>,
    replay_cursor: usize,
    candidate_cell_id: String,
    candidate_ordinal: u64,
    prior_candidate_calls: usize,
    total_calls: usize,
    limits: RuntimeLimits,
}

impl DurableBridge {
    async fn invoke(
        &mut self,
        global_ordinal: u64,
        operation: String,
        input: Value,
    ) -> Result<Value, ProcessEvaluationError> {
        if usize::try_from(global_ordinal).unwrap_or(usize::MAX) != self.total_calls {
            return Err(ProcessEvaluationError::Protocol(format!(
                "non-monotonic broker ordinal {global_ordinal}; expected {}",
                self.total_calls
            )));
        }
        if self.total_calls >= self.limits.max_calls_per_evaluation {
            return Err(ProcessEvaluationError::Protocol(
                "broker call limit exceeded".to_owned(),
            ));
        }
        self.total_calls += 1;

        let row = if self.replay_cursor < self.replay.len() {
            let row = self.replay[self.replay_cursor].clone();
            self.replay_cursor += 1;
            self.store.verify_call(&row, &operation, &input)?;
            row
        } else if let Some(row) = self
            .store
            .load_call(&self.candidate_cell_id, self.candidate_ordinal)?
        {
            self.store.verify_call(&row, &operation, &input)?;
            self.candidate_ordinal = self.candidate_ordinal.saturating_add(1);
            row
        } else {
            let row = self.store.admit_call(
                &self.candidate_cell_id,
                self.candidate_ordinal,
                &operation,
                &input,
            )?;
            self.candidate_ordinal = self.candidate_ordinal.saturating_add(1);
            row
        };

        match row.status.as_str() {
            "completed" => row.result.ok_or_else(|| {
                ProcessEvaluationError::Protocol(
                    "completed broker call has no durable result".to_owned(),
                )
            }),
            "failed" => Err(ProcessEvaluationError::JavaScript(
                row.error
                    .unwrap_or_else(|| "journaled broker call failed".to_owned()),
            )),
            "admitted" => {
                let request = BrokerRequest {
                    call_id: row.call_id.clone(),
                    operation,
                    input,
                };
                let outcome = match builtin(&request) {
                    Some(outcome) => outcome,
                    None => self.broker.call(&request).await,
                };
                match outcome {
                    Ok(value) => {
                        self.store.finish_call(&row.call_id, Ok(&value))?;
                        Ok(value)
                    }
                    Err(error) => {
                        self.store
                            .finish_call(&row.call_id, Err(error.message.as_str()))?;
                        Err(ProcessEvaluationError::JavaScript(error.message))
                    }
                }
            }
            status => Err(ProcessEvaluationError::Protocol(format!(
                "unknown durable broker status '{status}'"
            ))),
        }
    }

    fn verify_complete(&self) -> Result<(), ProcessEvaluationError> {
        if self.replay_cursor != self.replay.len() {
            return Err(ProcessEvaluationError::Protocol(
                "replay emitted fewer calls than the committed journal".to_owned(),
            ));
        }
        if usize::try_from(self.candidate_ordinal).unwrap_or(usize::MAX)
            < self.prior_candidate_calls
        {
            return Err(ProcessEvaluationError::Protocol(
                "candidate replay emitted fewer calls than its admitted journal".to_owned(),
            ));
        }
        Ok(())
    }
}

pub(crate) async fn evaluate_in_helper(
    helper: &CodeHelper,
    store: CodeRuntimeStore,
    committed: &[CellRow],
    candidate: &CellRow,
    broker: Arc<dyn AsyncBroker>,
    limits: &RuntimeLimits,
    cancellation: &CancellationToken,
) -> Result<EvaluationOutcome, ProcessEvaluationError> {
    let mut replay = Vec::new();
    for cell in committed {
        replay.extend(store.calls_for_cell(&cell.cell_id)?);
    }
    let prior_candidate_calls = store.calls_for_cell(&candidate.cell_id)?.len();
    let mut bridge = DurableBridge {
        store,
        broker,
        replay,
        replay_cursor: 0,
        candidate_cell_id: candidate.cell_id.clone(),
        candidate_ordinal: 0,
        prior_candidate_calls,
        total_calls: 0,
        limits: limits.clone(),
    };

    let mut command = helper.command();
    command
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = ProcessTree::spawn(&mut command)
        .map_err(|error| ProcessEvaluationError::Io(format!("start helper: {error}")))?;
    let mut stdin = child
        .take_stdin()
        .ok_or_else(|| ProcessEvaluationError::Io("helper stdin was not captured".to_owned()))?;
    let stdout = child
        .take_stdout()
        .ok_or_else(|| ProcessEvaluationError::Io("helper stdout was not captured".to_owned()))?;
    let stderr = child
        .take_stderr()
        .ok_or_else(|| ProcessEvaluationError::Io("helper stderr was not captured".to_owned()))?;
    let stderr_task = tokio::spawn(drain_bounded(stderr, MAX_HELPER_STDERR_BYTES));
    let command = HelperCommand::Evaluate {
        version: HELPER_PROTOCOL_VERSION,
        request_id: candidate.cell_id.clone(),
        committed_source: committed
            .iter()
            .map(|cell| cell.compiled.as_str())
            .collect::<Vec<_>>()
            .join("\n;\n"),
        candidate_source: candidate.compiled.clone(),
        limits: limits.clone(),
    };
    write_frame(&mut stdin, &command).await?;
    let mut stdout = BufReader::new(stdout);
    let deadline = Instant::now() + Duration::from_millis(limits.wall_time_ms.saturating_add(500));

    let outcome = loop {
        let frame = tokio::select! {
            biased;
            () = cancellation.cancelled() => {
                child.terminate().await;
                break Err(ProcessEvaluationError::Cancelled);
            }
            frame = tokio::time::timeout_at(deadline.into(), read_frame(&mut stdout)) => {
                match frame {
                    Ok(frame) => frame?,
                    Err(_) => {
                        child.terminate().await;
                        break Err(ProcessEvaluationError::TimedOut);
                    }
                }
            }
        };
        let Some(frame) = frame else {
            let status = child.try_wait().ok().flatten();
            let detail = helper_exit_detail(status.as_ref(), &[]);
            break Err(ProcessEvaluationError::HelperExited(detail));
        };
        let event: HelperEvent = serde_json::from_slice(&frame)
            .map_err(|error| ProcessEvaluationError::Protocol(error.to_string()))?;
        match event {
            HelperEvent::BrokerRequest {
                version,
                request_id,
                ordinal,
                operation,
                input,
            } => {
                validate_correlation(version, &request_id, &candidate.cell_id)?;
                let response = match bridge.invoke(ordinal, operation, input).await {
                    Ok(value) => HelperBrokerResponse::BrokerResponse {
                        version,
                        request_id,
                        ordinal,
                        value: Some(value),
                        error: None,
                    },
                    Err(error) => HelperBrokerResponse::BrokerResponse {
                        version,
                        request_id,
                        ordinal,
                        value: None,
                        error: Some(error.to_string()),
                    },
                };
                write_frame(&mut stdin, &response).await?;
            }
            HelperEvent::Complete {
                version,
                request_id,
                ok,
                value,
                output,
                error,
            } => {
                validate_correlation(version, &request_id, &candidate.cell_id)?;
                bridge.verify_complete()?;
                if ok {
                    break Ok(EvaluationOutcome {
                        value: value.unwrap_or(Value::Null),
                        output,
                    });
                }
                let message = error.unwrap_or_else(|| "helper reported failure".to_owned());
                if message.contains("timed out") {
                    break Err(ProcessEvaluationError::TimedOut);
                }
                break Err(ProcessEvaluationError::JavaScript(message));
            }
        }
    };

    if child.try_wait().ok().flatten().is_none() {
        match tokio::time::timeout(HELPER_EXIT_GRACE, child.wait()).await {
            Ok(Ok(_)) => child.disarm_after_reap(),
            _ => child.terminate().await,
        }
    } else {
        child.disarm_after_reap();
    }
    let _stderr = finish_stderr(stderr_task).await;
    outcome
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn invoke_skill_in_helper(
    helper: &CodeHelper,
    module_name: &str,
    module_source: &str,
    source_digest: &str,
    state_namespace: &str,
    invocation_key: &str,
    input: &Value,
    broker: Arc<dyn AsyncBroker>,
    limits: &RuntimeLimits,
    cancellation: &CancellationToken,
) -> Result<EvaluationOutcome, ProcessEvaluationError> {
    let request_id =
        super::compiler::digest(format!("skill:{source_digest}:{invocation_key}").as_bytes());
    let mut command = helper.command();
    command
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = ProcessTree::spawn(&mut command)
        .map_err(|error| ProcessEvaluationError::Io(format!("start helper: {error}")))?;
    let mut stdin = child
        .take_stdin()
        .ok_or_else(|| ProcessEvaluationError::Io("helper stdin was not captured".to_owned()))?;
    let stdout = child
        .take_stdout()
        .ok_or_else(|| ProcessEvaluationError::Io("helper stdout was not captured".to_owned()))?;
    let stderr = child
        .take_stderr()
        .ok_or_else(|| ProcessEvaluationError::Io("helper stderr was not captured".to_owned()))?;
    let stderr_task = tokio::spawn(drain_bounded(stderr, MAX_HELPER_STDERR_BYTES));
    let command = HelperCommand::InvokeSkill {
        version: HELPER_PROTOCOL_VERSION,
        request_id: request_id.clone(),
        module_name: module_name.to_owned(),
        module_source: module_source.to_owned(),
        input: input.clone(),
        limits: limits.clone(),
    };
    write_frame(&mut stdin, &command).await?;
    let mut stdout = BufReader::new(stdout);
    let deadline = Instant::now() + Duration::from_millis(limits.wall_time_ms.saturating_add(500));
    let mut expected_ordinal = 0_u64;

    let outcome = loop {
        let frame = tokio::select! {
            biased;
            () = cancellation.cancelled() => {
                child.terminate().await;
                break Err(ProcessEvaluationError::Cancelled);
            }
            frame = tokio::time::timeout_at(deadline.into(), read_frame(&mut stdout)) => {
                match frame {
                    Ok(frame) => frame?,
                    Err(_) => {
                        child.terminate().await;
                        break Err(ProcessEvaluationError::TimedOut);
                    }
                }
            }
        };
        let Some(frame) = frame else {
            let status = child.try_wait().ok().flatten();
            break Err(ProcessEvaluationError::HelperExited(helper_exit_detail(
                status.as_ref(),
                &[],
            )));
        };
        let event: HelperEvent = serde_json::from_slice(&frame)
            .map_err(|error| ProcessEvaluationError::Protocol(error.to_string()))?;
        match event {
            HelperEvent::BrokerRequest {
                version,
                request_id: event_request_id,
                ordinal,
                operation,
                mut input,
            } => {
                validate_correlation(version, &event_request_id, &request_id)?;
                if ordinal != expected_ordinal
                    || usize::try_from(ordinal).unwrap_or(usize::MAX)
                        >= limits.max_calls_per_evaluation
                {
                    return Err(ProcessEvaluationError::Protocol(
                        "skill broker ordinals are not monotonic or exceed their bound".to_owned(),
                    ));
                }
                expected_ordinal = expected_ordinal.saturating_add(1);
                if operation.starts_with("state.") {
                    let object = input.as_object_mut().ok_or_else(|| {
                        ProcessEvaluationError::Protocol(
                            "skill state operations require object input".to_owned(),
                        )
                    })?;
                    object.insert(
                        "namespace".to_owned(),
                        Value::String(state_namespace.to_owned()),
                    );
                }
                let request = BrokerRequest {
                    call_id: super::compiler::digest(
                        format!("{source_digest}:{invocation_key}:{ordinal}").as_bytes(),
                    ),
                    operation,
                    input,
                };
                let result = match builtin(&request) {
                    Some(result) => result,
                    None => broker.call(&request).await,
                };
                let response = match result {
                    Ok(value) => HelperBrokerResponse::BrokerResponse {
                        version,
                        request_id: event_request_id,
                        ordinal,
                        value: Some(value),
                        error: None,
                    },
                    Err(error) => HelperBrokerResponse::BrokerResponse {
                        version,
                        request_id: event_request_id,
                        ordinal,
                        value: None,
                        error: Some(error.message),
                    },
                };
                write_frame(&mut stdin, &response).await?;
            }
            HelperEvent::Complete {
                version,
                request_id: event_request_id,
                ok,
                value,
                output,
                error,
            } => {
                validate_correlation(version, &event_request_id, &request_id)?;
                if ok {
                    break Ok(EvaluationOutcome {
                        value: value.unwrap_or(Value::Null),
                        output,
                    });
                }
                let message = error.unwrap_or_else(|| "helper reported failure".to_owned());
                if message.contains("timed out") {
                    break Err(ProcessEvaluationError::TimedOut);
                }
                break Err(ProcessEvaluationError::JavaScript(message));
            }
        }
    };

    if child.try_wait().ok().flatten().is_none() {
        match tokio::time::timeout(HELPER_EXIT_GRACE, child.wait()).await {
            Ok(Ok(_)) => child.disarm_after_reap(),
            _ => child.terminate().await,
        }
    } else {
        child.disarm_after_reap();
    }
    let _stderr = finish_stderr(stderr_task).await;
    outcome
}

fn validate_correlation(
    version: u32,
    request_id: &str,
    expected_request_id: &str,
) -> Result<(), ProcessEvaluationError> {
    if version != HELPER_PROTOCOL_VERSION {
        return Err(ProcessEvaluationError::Protocol(format!(
            "unsupported helper protocol version {version}"
        )));
    }
    if request_id != expected_request_id {
        return Err(ProcessEvaluationError::Protocol(
            "helper request correlation mismatch".to_owned(),
        ));
    }
    Ok(())
}

async fn write_frame(
    writer: &mut (impl tokio::io::AsyncWrite + Unpin),
    value: &impl serde::Serialize,
) -> Result<(), ProcessEvaluationError> {
    let mut bytes = serde_json::to_vec(value)
        .map_err(|error| ProcessEvaluationError::Protocol(error.to_string()))?;
    if bytes.len() > MAX_PROTOCOL_FRAME_BYTES {
        return Err(ProcessEvaluationError::Protocol(
            "helper protocol frame exceeds its bound".to_owned(),
        ));
    }
    bytes.push(b'\n');
    writer
        .write_all(&bytes)
        .await
        .map_err(|error| ProcessEvaluationError::Io(error.to_string()))?;
    writer
        .flush()
        .await
        .map_err(|error| ProcessEvaluationError::Io(error.to_string()))
}

async fn read_frame(
    reader: &mut (impl tokio::io::AsyncBufRead + Unpin),
) -> Result<Option<Vec<u8>>, ProcessEvaluationError> {
    let mut frame = Vec::new();
    let bytes = reader
        .read_until(b'\n', &mut frame)
        .await
        .map_err(|error| ProcessEvaluationError::Io(error.to_string()))?;
    if bytes == 0 {
        return Ok(None);
    }
    if frame.len() > MAX_PROTOCOL_FRAME_BYTES {
        return Err(ProcessEvaluationError::Protocol(
            "helper protocol frame exceeds its bound".to_owned(),
        ));
    }
    if frame.last() == Some(&b'\n') {
        frame.pop();
    }
    Ok(Some(frame))
}

async fn drain_bounded(
    mut reader: impl AsyncRead + Unpin,
    maximum: usize,
) -> Result<Vec<u8>, std::io::Error> {
    let mut retained = Vec::new();
    let mut chunk = [0_u8; 8 * 1024];
    loop {
        let read = reader.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        let remaining = maximum.saturating_sub(retained.len());
        retained.extend_from_slice(&chunk[..remaining.min(read)]);
    }
    Ok(retained)
}

async fn finish_stderr(task: tokio::task::JoinHandle<Result<Vec<u8>, std::io::Error>>) -> Vec<u8> {
    task.await.ok().and_then(Result::ok).unwrap_or_default()
}

fn helper_exit_detail(status: Option<&std::process::ExitStatus>, stderr: &[u8]) -> String {
    let mut detail = String::new();
    if let Some(status) = status {
        detail.push_str(&format!(" (status {status})"));
    }
    let stderr = String::from_utf8_lossy(stderr);
    let stderr = stderr.trim();
    if !stderr.is_empty() {
        detail.push_str(": ");
        detail.push_str(stderr);
    }
    detail
}
