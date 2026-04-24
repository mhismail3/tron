//! `ProcessManager` — centralized management of deterministic tool processes.
//!
//! Analogous to `SubagentManager` for LLM invocations, this module manages the
//! lifecycle of deterministic processes spawned by tools (shell commands, display
//! streams, long-running operations). Supports foreground (blocking) and
//! background (non-blocking) execution, foreground-to-background promotion,
//! cancellation, and completion notifications.
//!
//! ## Key design decisions
//!
//! - **Boxed futures, not commands**: Tools wrap their work in a future and hand
//!   it to ProcessManager. PM doesn't know about ProcessRunner or StreamConfig.
//! - **Child CancellationTokens**: Each process gets its own token. Tools are
//!   responsible for passing session cancel through their future closure.
//! - **Oneshot promotion**: Foreground processes can be promoted to background
//!   via a oneshot channel that unblocks the awaiting tool call.

use std::pin::Pin;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use dashmap::DashMap;
use parking_lot::Mutex;
use tokio::sync::{Notify, oneshot};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use tracing::{debug, warn};

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{EventStore, EventType};
use crate::runtime::agent::event_emitter::EventEmitter;
use crate::tools::errors::ToolError;
use crate::tools::traits::{
    BackgroundReason, ManagedProcessConfig, ManagedProcessHandle, ManagedProcessResult,
    ProcessInfo, ProcessManagerOps, ProcessState,
};
use crate::tools::utils::truncation::{
    HEAD_CHARS, INLINE_OUTPUT_LIMIT, TAIL_CHARS, truncate_head_tail,
};

// =============================================================================
// TrackedProcess — internal state for a single managed process
// =============================================================================

struct TrackedProcess {
    process_id: String,
    session_id: String,
    tool_call_id: String,
    config: ManagedProcessConfig,
    state: Mutex<ProcessState>,
    started_at: Instant,
    done: Notify,
    result: Mutex<Option<ManagedProcessResult>>,
    cancel: CancellationToken,
    promote_tx: Mutex<Option<oneshot::Sender<()>>>,
    /// Set before cancellation if triggered by user action (iOS interrupt button).
    user_cancelled: std::sync::atomic::AtomicBool,
}

// =============================================================================
// ProcessManager
// =============================================================================

/// Centralized manager for deterministic tool processes.
pub struct ProcessManager {
    processes: DashMap<String, Arc<TrackedProcess>>,
    /// Event emitter for broadcasting process lifecycle events.
    broadcast: Option<Arc<EventEmitter>>,
    /// Event store for persisting process result notifications.
    event_store: Option<Arc<EventStore>>,
}

impl ProcessManager {
    /// Create a bare ProcessManager (for tests).
    pub fn new() -> Self {
        Self {
            processes: DashMap::new(),
            broadcast: None,
            event_store: None,
        }
    }

    /// Create a fully-wired ProcessManager with event emission and persistence.
    pub fn with_deps(broadcast: Arc<EventEmitter>, event_store: Arc<EventStore>) -> Self {
        Self {
            processes: DashMap::new(),
            broadcast: Some(broadcast),
            event_store: Some(event_store),
        }
    }

    fn generate_id() -> String {
        format!("proc-{}", Uuid::now_v7())
    }

    fn kind_string(kind: &crate::tools::traits::ProcessKind) -> String {
        match kind {
            crate::tools::traits::ProcessKind::Shell => "shell".into(),
            crate::tools::traits::ProcessKind::DisplayStream => "display_stream".into(),
            crate::tools::traits::ProcessKind::ToolOperation => "tool_operation".into(),
        }
    }

    fn state_string(state: &ProcessState) -> String {
        match state {
            ProcessState::Foreground => "foreground".into(),
            ProcessState::Background => "background".into(),
            ProcessState::Completed => "completed".into(),
            ProcessState::Failed => "failed".into(),
            ProcessState::Cancelled => "cancelled".into(),
        }
    }
}

#[async_trait]
impl ProcessManagerOps for ProcessManager {
    async fn spawn_managed(
        &self,
        session_id: &str,
        tool_call_id: &str,
        config: ManagedProcessConfig,
        task: Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>>,
    ) -> Result<ManagedProcessHandle, ToolError> {
        let process_id = Self::generate_id();
        let cancel = CancellationToken::new();
        let (promote_tx, promote_rx) = oneshot::channel();

        let blocking_ms = config.blocking_timeout_ms.unwrap_or(0);
        let background = blocking_ms == 0;

        let tracker = Arc::new(TrackedProcess {
            process_id: process_id.clone(),
            session_id: session_id.to_owned(),
            tool_call_id: tool_call_id.to_owned(),
            config,
            state: Mutex::new(if background {
                ProcessState::Background
            } else {
                ProcessState::Foreground
            }),
            started_at: Instant::now(),
            done: Notify::new(),
            result: Mutex::new(None),
            cancel: cancel.clone(),
            promote_tx: Mutex::new(Some(promote_tx)),
            user_cancelled: std::sync::atomic::AtomicBool::new(false),
        });

        let _ = self.processes.insert(process_id.clone(), tracker.clone());

        // Emit ProcessSpawned event.
        if let Some(ref broadcast) = self.broadcast {
            let _ = broadcast.emit(TronEvent::ProcessSpawned {
                base: BaseEvent::now(session_id),
                process_id: process_id.clone(),
                label: tracker.config.label.clone(),
                kind: Self::kind_string(&tracker.config.kind),
                background,
                tool_call_id: tool_call_id.to_owned(),
            });
        }

        // Spawn the actual work as a tokio task.
        let task_tracker = tracker.clone();
        let task_cancel = cancel.clone();
        let broadcast_for_completion = self.broadcast.clone();
        let event_store_for_completion = self.event_store.clone();
        let _handle = tokio::spawn(async move {
            // Run the future, but also listen for cancellation.
            let result = tokio::select! {
                biased;
                () = task_cancel.cancelled() => {
                    ManagedProcessResult {
                        process_id: task_tracker.process_id.clone(),
                        output: String::new(),
                        exit_code: None,
                        duration_ms: task_tracker.started_at.elapsed().as_millis() as u64,
                        timed_out: false,
                        cancelled: true,
                        blob_id: None,
                        user_cancelled: task_tracker.user_cancelled.load(std::sync::atomic::Ordering::Acquire),
                    }
                }
                result = task => {
                    result
                }
            };

            let new_state = if result.cancelled {
                ProcessState::Cancelled
            } else if result.exit_code.map_or(false, |c| c != 0) || result.timed_out {
                ProcessState::Failed
            } else {
                ProcessState::Completed
            };

            let success = matches!(new_state, ProcessState::Completed);

            // Truncate large output and store full content in blob.
            let (truncated_output, blob_id) = if result.output.len() > INLINE_OUTPUT_LIMIT {
                let blob_id = if let Some(ref store) = event_store_for_completion {
                    match crate::tools::traits::BlobStore::store(
                        store.as_ref(),
                        result.output.as_bytes(),
                        "text/plain",
                    )
                    .await
                    {
                        Ok(id) => Some(id),
                        Err(e) => {
                            warn!(error = %e, "blob store failed for process output");
                            None
                        }
                    }
                } else {
                    None
                };
                let truncated = truncate_head_tail(
                    &result.output,
                    INLINE_OUTPUT_LIMIT,
                    HEAD_CHARS,
                    TAIL_CHARS,
                    blob_id.as_deref(),
                );
                (truncated, blob_id)
            } else {
                (result.output.clone(), result.blob_id.clone())
            };

            let stored_result = ManagedProcessResult {
                output: truncated_output,
                blob_id: blob_id.clone(),
                ..result
            };

            *task_tracker.state.lock() = new_state;
            *task_tracker.result.lock() = Some(stored_result.clone());

            // Emit ProcessCompleted event.
            let completed_at = chrono::Utc::now().to_rfc3339();
            let result_summary = if stored_result.output.len() > 200 {
                format!("{}...", &stored_result.output[..200])
            } else {
                stored_result.output.clone()
            };
            if let Some(ref broadcast) = broadcast_for_completion {
                let _ = broadcast.emit(TronEvent::ProcessCompleted {
                    base: BaseEvent::now(&task_tracker.session_id),
                    parent_session_id: task_tracker.session_id.clone(),
                    process_id: task_tracker.process_id.clone(),
                    label: task_tracker.config.label.clone(),
                    success,
                    exit_code: stored_result.exit_code,
                    duration: stored_result.duration_ms,
                    result_summary: result_summary.clone(),
                    blob_id: blob_id.clone(),
                    completed_at: completed_at.clone(),
                });
            }

            // Persist notification.process_result for RunContext injection.
            if let Some(ref store) = event_store_for_completion {
                let output_for_context = if stored_result.output.len() > 4000 {
                    Some(format!("{}...", &stored_result.output[..4000]))
                } else if stored_result.output.is_empty() {
                    None
                } else {
                    Some(stored_result.output.clone())
                };

                let _ = store.append(&crate::events::AppendOptions {
                    session_id: &task_tracker.session_id,
                    event_type: EventType::NotificationProcessResult,
                    payload: serde_json::json!({
                        "parentSessionId": task_tracker.session_id,
                        "processId": task_tracker.process_id,
                        "label": task_tracker.config.label,
                        "resultSummary": result_summary,
                        "success": success,
                        "exitCode": stored_result.exit_code,
                        "duration": stored_result.duration_ms as i64,
                        "completedAt": completed_at,
                        "blobId": blob_id,
                        "output": output_for_context,
                    }),
                    parent_id: None,
                    sequence: None,
                });
                debug!(
                    process_id = %task_tracker.process_id,
                    label = %task_tracker.config.label,
                    success,
                    "persisted process result notification"
                );
            }

            task_tracker.done.notify_waiters();
        });

        if background {
            // Immediate background — return without blocking.
            return Ok(ManagedProcessHandle {
                process_id,
                result: None,
                backgrounded: Some(BackgroundReason::AutoTimeout),
            });
        }

        // Blocking: wait for completion, user-backgrounding, or blocking timeout.
        tokio::select! {
            biased;
            // Process completed within the blocking window.
            () = tracker.done.notified() => {
                let result = tracker.result.lock().clone();
                Ok(ManagedProcessHandle {
                    process_id,
                    result,
                    backgrounded: None,
                })
            }
            // User manually backgrounded from iOS.
            Ok(()) = promote_rx => {
                *tracker.state.lock() = ProcessState::Background;
                if let Some(ref broadcast) = self.broadcast {
                    let _ = broadcast.emit(TronEvent::JobBackgrounded {
                        base: BaseEvent::now(session_id),
                        job_id: process_id.clone(),
                        reason: "user_action".into(),
                        label: tracker.config.label.clone(),
                        tool_call_id: tool_call_id.to_owned(),
                    });
                }
                Ok(ManagedProcessHandle {
                    process_id,
                    result: None,
                    backgrounded: Some(BackgroundReason::UserAction),
                })
            }
            // Blocking timeout expired — auto-background.
            () = tokio::time::sleep(std::time::Duration::from_millis(blocking_ms)) => {
                *tracker.state.lock() = ProcessState::Background;
                if let Some(ref broadcast) = self.broadcast {
                    let _ = broadcast.emit(TronEvent::JobBackgrounded {
                        base: BaseEvent::now(session_id),
                        job_id: process_id.clone(),
                        reason: "auto_timeout".into(),
                        label: tracker.config.label.clone(),
                        tool_call_id: tool_call_id.to_owned(),
                    });
                }
                Ok(ManagedProcessHandle {
                    process_id,
                    result: None,
                    backgrounded: Some(BackgroundReason::AutoTimeout),
                })
            }
        }
    }

    fn promote_to_background(&self, process_id: &str) -> Result<(), ToolError> {
        let tracker = self
            .processes
            .get(process_id)
            .ok_or_else(|| ToolError::Validation {
                message: format!("Process not found: {process_id}"),
            })?;

        let state = tracker.state.lock().clone();
        match state {
            ProcessState::Foreground => {
                // Take the oneshot sender and fire it.
                let tx = tracker.promote_tx.lock().take();
                match tx {
                    Some(tx) => {
                        let _ = tx.send(());
                        Ok(())
                    }
                    None => Err(ToolError::Validation {
                        message: format!("Process {process_id} promotion channel already consumed"),
                    }),
                }
            }
            ProcessState::Background => Err(ToolError::Validation {
                message: format!("Process {process_id} is already in background"),
            }),
            ProcessState::Completed | ProcessState::Failed | ProcessState::Cancelled => {
                Err(ToolError::Validation {
                    message: format!("Process {process_id} has already finished"),
                })
            }
        }
    }

    fn cancel_process(&self, process_id: &str, user_initiated: bool) -> Result<(), ToolError> {
        let tracker = self
            .processes
            .get(process_id)
            .ok_or_else(|| ToolError::Validation {
                message: format!("Process not found: {process_id}"),
            })?;

        let state = tracker.state.lock().clone();
        match state {
            ProcessState::Foreground | ProcessState::Background => {
                if user_initiated {
                    tracker
                        .user_cancelled
                        .store(true, std::sync::atomic::Ordering::Release);
                }
                tracker.cancel.cancel();
                Ok(())
            }
            // Already done — no-op.
            ProcessState::Completed | ProcessState::Failed | ProcessState::Cancelled => Ok(()),
        }
    }

    fn list_processes(&self, session_id: &str) -> Vec<ProcessInfo> {
        // Clean up old completed processes (>5 minutes).
        let cutoff = Instant::now() - std::time::Duration::from_secs(300);
        self.processes.retain(|_, tracker| {
            let state = tracker.state.lock().clone();
            match state {
                ProcessState::Completed | ProcessState::Failed | ProcessState::Cancelled => {
                    tracker.started_at > cutoff
                }
                _ => true,
            }
        });

        self.processes
            .iter()
            .filter(|entry| entry.value().session_id == session_id)
            .map(|entry| {
                let t = entry.value();
                let state = t.state.lock().clone();
                ProcessInfo {
                    process_id: t.process_id.clone(),
                    label: t.config.label.clone(),
                    kind: t.config.kind.clone(),
                    state: Self::state_string(&state),
                    elapsed_ms: t.started_at.elapsed().as_millis() as u64,
                    session_id: t.session_id.clone(),
                    tool_call_id: t.tool_call_id.clone(),
                }
            })
            .collect()
    }

    fn get_result(&self, process_id: &str) -> Option<ManagedProcessResult> {
        self.processes
            .get(process_id)
            .and_then(|t| t.result.lock().clone())
    }

    fn find_by_label(&self, session_id: &str, label_prefix: &str) -> Option<String> {
        self.processes
            .iter()
            .find(|entry| {
                let t = entry.value();
                // Empty session_id matches any session (for RPC calls that don't know the session).
                let session_match = session_id.is_empty() || t.session_id == session_id;
                session_match
                    && t.config.label.starts_with(label_prefix)
                    && matches!(
                        *t.state.lock(),
                        ProcessState::Foreground | ProcessState::Background
                    )
            })
            .map(|entry| entry.key().clone())
    }

    fn cancel_session_processes(&self, session_id: &str) {
        let to_cancel: Vec<_> = self
            .processes
            .iter()
            .filter(|entry| entry.value().session_id == session_id)
            .map(|entry| entry.value().clone())
            .collect();

        for tracker in &to_cancel {
            tracker.cancel.cancel();
        }

        // Remove all processes for this session.
        self.processes
            .retain(|_, tracker| tracker.session_id != session_id);
    }

    fn cancel_all(&self) {
        for entry in self.processes.iter() {
            entry.value().cancel.cancel();
        }
        self.processes.clear();
    }

    async fn wait_for_process(
        &self,
        process_id: &str,
        timeout_ms: u64,
    ) -> Result<ManagedProcessResult, ToolError> {
        let tracker = self
            .processes
            .get(process_id)
            .ok_or_else(|| ToolError::Validation {
                message: format!("Process not found: {process_id}"),
            })?;

        // Check if already completed.
        {
            let result = tracker.result.lock();
            if let Some(ref r) = *result {
                return Ok(r.clone());
            }
        }

        // Wait for completion or timeout.
        let tracker = tracker.clone();
        match tokio::time::timeout(
            std::time::Duration::from_millis(timeout_ms),
            tracker.done.notified(),
        )
        .await
        {
            Ok(()) => {
                let result = tracker.result.lock();
                result.clone().ok_or_else(|| ToolError::Internal {
                    message: format!("Process {process_id} notified but no result available"),
                })
            }
            Err(_) => Err(ToolError::Timeout { timeout_ms }),
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
#[path = "process_manager_tests.rs"]
mod tests;
