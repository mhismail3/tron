use std::path::Path;
use std::sync::Arc;
#[cfg(test)]
use std::sync::atomic::AtomicBool;

use thiserror::Error;
use tokio_util::sync::CancellationToken;

use super::compiler::{CompileError, SourceKind, compile_typescript};
#[cfg(test)]
use super::evaluator::{Broker, EvaluationError, NoopBroker, evaluate};
use super::process_evaluator::{
    AsyncBroker, CodeHelper, ProcessEvaluationError, evaluate_in_helper,
};
use super::store::{CodeRuntimeStore, StoreError};
use super::types::{
    CellStatus, CodeInspect, CodeReset, CodeRunRequest, CodeRunResult, RuntimeLimits,
};

/// Failure before a cell can produce a durable terminal result.
#[derive(Debug, Error)]
pub enum CodeRuntimeError {
    /// Required identity/idempotency input is absent.
    #[error("invalid code request: {0}")]
    InvalidRequest(String),
    /// Source is too large or is not within the admitted TypeScript subset.
    #[error(transparent)]
    Compile(#[from] CompileError),
    /// Durable store admission/reconciliation failed.
    #[error("code runtime storage failed: {0}")]
    Storage(String),
    /// The disposable helper disappeared before it could produce durable
    /// terminal evidence. Retrying the same invocation resumes the same cell.
    #[error("code runtime helper failed: {0}")]
    Helper(String),
}

impl From<StoreError> for CodeRuntimeError {
    fn from(error: StoreError) -> Self {
        Self::Storage(error.to_string())
    }
}

/// Unadvertised engine service for persistent per-agent code journals.
#[derive(Clone)]
pub struct CodeRuntimeService {
    store: CodeRuntimeStore,
    helper: CodeHelper,
    limits: RuntimeLimits,
    #[cfg(test)]
    in_process_broker: Arc<dyn Broker>,
}

impl std::fmt::Debug for CodeRuntimeService {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodeRuntimeService")
            .field("store", &self.store)
            .field("helper", &self.helper)
            .field("limits", &self.limits)
            .finish_non_exhaustive()
    }
}

impl CodeRuntimeService {
    /// Open the production substrate with the installed sibling helper.
    pub fn open(database_path: impl AsRef<Path>) -> Result<Self, CodeRuntimeError> {
        Self::with_helper_and_limits(
            database_path,
            CodeHelper::installed().map_err(|error| CodeRuntimeError::Helper(error.to_string()))?,
            RuntimeLimits::default(),
        )
    }

    /// Open with an exact helper executable and explicit bounded policy.
    pub fn with_helper_and_limits(
        database_path: impl AsRef<Path>,
        helper: CodeHelper,
        limits: RuntimeLimits,
    ) -> Result<Self, CodeRuntimeError> {
        Ok(Self {
            store: CodeRuntimeStore::open(database_path)?,
            helper,
            limits,
            #[cfg(test)]
            in_process_broker: Arc::new(NoopBroker),
        })
    }

    #[cfg(test)]
    pub(crate) fn with_test_broker_and_limits(
        database_path: impl AsRef<Path>,
        broker: Arc<dyn Broker>,
        limits: RuntimeLimits,
    ) -> Result<Self, CodeRuntimeError> {
        let mut service = Self::with_helper_and_limits(
            database_path,
            CodeHelper::at("unused-test-helper"),
            limits,
        )?;
        service.in_process_broker = broker;
        Ok(service)
    }

    /// Current runtime limits.
    #[must_use]
    pub const fn limits(&self) -> &RuntimeLimits {
        &self.limits
    }

    /// Exact disposable helper used by cells and callable skill modules.
    #[must_use]
    pub const fn helper(&self) -> &CodeHelper {
        &self.helper
    }

    /// Run or recover one idempotent cell exclusively in the disposable helper.
    pub async fn run(
        &self,
        request: CodeRunRequest,
        broker: Arc<dyn AsyncBroker>,
        cancellation: &CancellationToken,
    ) -> Result<CodeRunResult, CodeRuntimeError> {
        validate_request(&request, &self.limits)?;
        let compiled = compile_typescript(&request.source, SourceKind::Cell)?;
        let (runtime, candidate, existing) = self.store.admit_cell(
            &request.agent_id,
            &request.invocation_key,
            request.assignment_id.as_deref(),
            &request.source,
            &compiled.source_digest,
            &compiled.javascript,
            &compiled.compiled_digest,
            &self.limits,
        )?;
        if existing && candidate.status != CellStatus::Running {
            return Ok(candidate.as_result(&runtime, true));
        }

        let committed = self.store.committed_cells(&runtime.runtime_id)?;
        let evaluated = evaluate_in_helper(
            &self.helper,
            self.store.clone(),
            &committed,
            &candidate,
            broker,
            &self.limits,
            cancellation,
        )
        .await;
        let terminal = match evaluated {
            Ok(outcome) => self.store.finish_cell(
                &candidate.cell_id,
                CellStatus::Committed,
                Some(&outcome.value),
                &outcome.output,
                None,
            )?,
            Err(error) if error.preserves_running_cell() => {
                return Err(CodeRuntimeError::Helper(safe_evaluation_error(&error)));
            }
            Err(error) => {
                let status = match error {
                    ProcessEvaluationError::Cancelled => CellStatus::Cancelled,
                    ProcessEvaluationError::TimedOut => CellStatus::TimedOut,
                    _ => CellStatus::Failed,
                };
                let message = safe_evaluation_error(&error);
                self.store
                    .finish_cell(&candidate.cell_id, status, None, &[], Some(&message))?
            }
        };
        Ok(terminal.as_result(&runtime, existing))
    }

    /// In-process evaluator retained only for deterministic unit tests of the
    /// compiler/journal semantics. No production handler calls this path.
    #[cfg(test)]
    pub(crate) fn run_in_process_for_test(
        &self,
        request: CodeRunRequest,
    ) -> Result<CodeRunResult, CodeRuntimeError> {
        self.run_in_process_with_cancellation_for_test(request, Arc::new(AtomicBool::new(false)))
    }

    #[cfg(test)]
    pub(crate) fn run_in_process_with_cancellation_for_test(
        &self,
        request: CodeRunRequest,
        cancelled: Arc<AtomicBool>,
    ) -> Result<CodeRunResult, CodeRuntimeError> {
        validate_request(&request, &self.limits)?;
        let compiled = compile_typescript(&request.source, SourceKind::Cell)?;
        let (runtime, candidate, existing) = self.store.admit_cell(
            &request.agent_id,
            &request.invocation_key,
            request.assignment_id.as_deref(),
            &request.source,
            &compiled.source_digest,
            &compiled.javascript,
            &compiled.compiled_digest,
            &self.limits,
        )?;
        if existing && candidate.status != CellStatus::Running {
            return Ok(candidate.as_result(&runtime, true));
        }
        let committed = self.store.committed_cells(&runtime.runtime_id)?;
        let evaluated = evaluate(
            self.store.clone(),
            &committed,
            &candidate,
            Arc::clone(&self.in_process_broker),
            &self.limits,
            cancelled,
        );
        let terminal = match evaluated {
            Ok(outcome) => self.store.finish_cell(
                &candidate.cell_id,
                CellStatus::Committed,
                Some(&outcome.value),
                &outcome.output,
                None,
            )?,
            Err(error) => {
                let status = match error {
                    EvaluationError::Cancelled => CellStatus::Cancelled,
                    EvaluationError::TimedOut | EvaluationError::Limit => CellStatus::TimedOut,
                    _ => CellStatus::Failed,
                };
                let message = safe_evaluation_error(&error);
                self.store
                    .finish_cell(&candidate.cell_id, status, None, &[], Some(&message))?
            }
        };
        Ok(terminal.as_result(&runtime, existing))
    }

    /// Inspect the current logical journal without creating one.
    pub fn inspect(&self, agent_id: &str) -> Result<CodeInspect, CodeRuntimeError> {
        if agent_id.trim().is_empty() {
            return Err(CodeRuntimeError::InvalidRequest(
                "agentId must not be empty".to_owned(),
            ));
        }
        self.store
            .inspect(agent_id, &self.limits)
            .map_err(CodeRuntimeError::from)
    }

    /// Retire the current journal and create a fresh explicit generation.
    ///
    /// Historical cells/results remain available as immutable audit evidence.
    pub fn reset(&self, agent_id: &str) -> Result<CodeReset, CodeRuntimeError> {
        if agent_id.trim().is_empty() {
            return Err(CodeRuntimeError::InvalidRequest(
                "agentId must not be empty".to_owned(),
            ));
        }
        let runtime = self.store.reset(agent_id)?;
        Ok(CodeReset {
            agent_id: runtime.agent_id,
            runtime_id: runtime.runtime_id,
            epoch: runtime.epoch,
        })
    }
}

fn validate_request(
    request: &CodeRunRequest,
    limits: &RuntimeLimits,
) -> Result<(), CodeRuntimeError> {
    if request.agent_id.trim().is_empty() {
        return Err(CodeRuntimeError::InvalidRequest(
            "agentId must not be empty".to_owned(),
        ));
    }
    if request.invocation_key.trim().is_empty() {
        return Err(CodeRuntimeError::InvalidRequest(
            "invocationKey must not be empty".to_owned(),
        ));
    }
    if request.source.len() > limits.max_source_bytes {
        return Err(CodeRuntimeError::InvalidRequest(format!(
            "source exceeds {} bytes",
            limits.max_source_bytes
        )));
    }
    Ok(())
}

fn safe_evaluation_error(error: &impl std::fmt::Display) -> String {
    let message = error.to_string();
    const MAX_DIAGNOSTIC_BYTES: usize = 8 * 1024;
    if message.len() <= MAX_DIAGNOSTIC_BYTES {
        message
    } else {
        let mut boundary = MAX_DIAGNOSTIC_BYTES;
        while !message.is_char_boundary(boundary) {
            boundary -= 1;
        }
        format!("{}…", &message[..boundary])
    }
}
