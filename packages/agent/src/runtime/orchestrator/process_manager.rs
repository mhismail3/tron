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
use crate::tools::utils::truncation::{
    truncate_head_tail, HEAD_CHARS, INLINE_OUTPUT_LIMIT, TAIL_CHARS,
};
use crate::events::{EventStore, EventType};
use crate::runtime::agent::event_emitter::EventEmitter;
use crate::tools::errors::ToolError;
use crate::tools::traits::{
    BackgroundReason, ManagedProcessConfig, ManagedProcessHandle, ManagedProcessResult,
    ProcessInfo, ProcessManagerOps, ProcessState,
};

mod tracking;

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

    fn cancel_process(&self, process_id: &str) -> Result<(), ToolError> {
        let tracker = self
            .processes
            .get(process_id)
            .ok_or_else(|| ToolError::Validation {
                message: format!("Process not found: {process_id}"),
            })?;

        let state = tracker.state.lock().clone();
        match state {
            ProcessState::Foreground | ProcessState::Background => {
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
mod tests {
    use super::*;
    use crate::tools::traits::ProcessKind;
    use std::time::Duration;

    fn make_config(label: &str) -> ManagedProcessConfig {
        ManagedProcessConfig {
            label: label.into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            blocking_timeout_ms: None,
            sandbox: false,
        }
    }

    fn make_blocking_config(label: &str) -> ManagedProcessConfig {
        ManagedProcessConfig {
            label: label.into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            blocking_timeout_ms: Some(60_000),
            sandbox: false,
        }
    }

    fn make_instant_result(pid: &str) -> ManagedProcessResult {
        ManagedProcessResult {
            process_id: pid.into(),
            output: "done".into(),
            exit_code: Some(0),
            duration_ms: 0,
            timed_out: false,
            cancelled: false,
            blob_id: None,
        }
    }

    fn boxed_immediate(output: &str, exit_code: i32) -> Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>> {
        let output = output.to_owned();
        Box::pin(async move {
            ManagedProcessResult {
                process_id: String::new(), // PM's task wrapper doesn't use this
                output,
                exit_code: Some(exit_code),
                duration_ms: 0,
                timed_out: false,
                cancelled: false,
                blob_id: None,
            }
        })
    }

    fn boxed_delayed(ms: u64, output: &str) -> Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>> {
        let output = output.to_owned();
        Box::pin(async move {
            tokio::time::sleep(Duration::from_millis(ms)).await;
            ManagedProcessResult {
                process_id: String::new(),
                output,
                exit_code: Some(0),
                duration_ms: ms,
                timed_out: false,
                cancelled: false,
                blob_id: None,
            }
        })
    }

    fn boxed_cancellable(cancel: CancellationToken) -> Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>> {
        Box::pin(async move {
            cancel.cancelled().await;
            ManagedProcessResult {
                process_id: String::new(),
                output: String::new(),
                exit_code: None,
                duration_ms: 0,
                timed_out: false,
                cancelled: true,
                blob_id: None,
            }
        })
    }

    // ── Foreground spawning ──

    #[tokio::test]
    async fn spawn_foreground_blocks_until_complete() {
        let pm = ProcessManager::new();
        let start = Instant::now();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("test"), boxed_delayed(100, "ok"))
            .await
            .unwrap();
        let elapsed = start.elapsed();
        assert!(elapsed >= Duration::from_millis(80), "should have blocked ~100ms");
        assert!(handle.result.is_some());
    }

    #[tokio::test]
    async fn spawn_foreground_returns_correct_result() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("echo"), boxed_immediate("hello", 0))
            .await
            .unwrap();
        let result = handle.result.unwrap();
        assert_eq!(result.output, "hello");
        assert_eq!(result.exit_code, Some(0));
        assert!(!result.timed_out);
        assert!(!result.cancelled);
    }

    #[tokio::test]
    async fn spawn_foreground_short_task() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("fast"), boxed_immediate("ok", 0))
            .await
            .unwrap();
        assert!(handle.result.is_some());
        assert_eq!(handle.result.unwrap().output, "ok");
    }

    #[tokio::test]
    async fn spawn_foreground_failed_exit_code() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("fail"), boxed_immediate("error", 1))
            .await
            .unwrap();
        let result = handle.result.unwrap();
        assert_eq!(result.exit_code, Some(1));
        // State should be Failed.
        let info = pm.list_processes("s1");
        assert_eq!(info[0].state, "failed");
    }

    // ── Background spawning ──

    #[tokio::test]
    async fn spawn_background_returns_immediately() {
        let pm = ProcessManager::new();
        let start = Instant::now();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("slow"), boxed_delayed(500, "done"))
            .await
            .unwrap();
        let elapsed = start.elapsed();
        assert!(elapsed < Duration::from_millis(50), "should not have blocked");
        assert!(handle.result.is_none());
        assert!(!handle.process_id.is_empty());
    }

    #[tokio::test]
    async fn spawn_background_handle_has_process_id() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("bg"), boxed_delayed(50, "ok"))
            .await
            .unwrap();
        assert!(handle.process_id.starts_with("proc-"));
    }

    #[tokio::test]
    async fn spawn_background_result_available_after_completion() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("bg"), boxed_delayed(50, "done"))
            .await
            .unwrap();

        // Result not available immediately.
        assert!(pm.get_result(&handle.process_id).is_none());

        // Wait for completion.
        tokio::time::sleep(Duration::from_millis(150)).await;

        let result = pm.get_result(&handle.process_id);
        assert!(result.is_some());
        assert_eq!(result.unwrap().output, "done");
    }

    #[tokio::test]
    async fn concurrent_background_processes() {
        let pm = ProcessManager::new();
        let mut handles = Vec::new();
        for i in 0..5 {
            let h = pm
                .spawn_managed(
                    "s1",
                    &format!("tc{i}"),
                    make_config(&format!("cmd-{i}")),
                    boxed_delayed(50, &format!("result-{i}")),
                )
                .await
                .unwrap();
            handles.push(h);
        }

        assert_eq!(pm.list_processes("s1").len(), 5);

        // Wait for all to complete.
        tokio::time::sleep(Duration::from_millis(200)).await;

        for (i, h) in handles.iter().enumerate() {
            let result = pm.get_result(&h.process_id).unwrap();
            assert_eq!(result.output, format!("result-{i}"));
        }
    }

    // ── Foreground-to-background promotion ──

    #[tokio::test]
    async fn promote_foreground_unblocks_caller() {
        let pm = Arc::new(ProcessManager::new());
        let pm2 = pm.clone();

        // Spawn foreground with a long-running task.
        let fg_handle = tokio::spawn(async move {
            pm2.spawn_managed("s1", "tc1", make_blocking_config("long"), boxed_delayed(5000, "done"))
                .await
                .unwrap()
        });

        // Give it a moment to start.
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Find the process and promote it.
        let processes = pm.list_processes("s1");
        assert_eq!(processes.len(), 1);
        let pid = &processes[0].process_id;
        assert_eq!(processes[0].state, "foreground");

        pm.promote_to_background(pid).unwrap();

        // The foreground call should return quickly now.
        let handle = tokio::time::timeout(Duration::from_millis(200), fg_handle)
            .await
            .expect("should have returned after promotion")
            .unwrap();

        assert!(handle.result.is_none(), "promoted handle should not have result");
    }

    #[tokio::test]
    async fn promote_then_process_completes_in_background() {
        let pm = Arc::new(ProcessManager::new());
        let pm2 = pm.clone();

        let fg_handle = tokio::spawn(async move {
            pm2.spawn_managed("s1", "tc1", make_blocking_config("cmd"), boxed_delayed(200, "bg-done"))
                .await
                .unwrap()
        });

        tokio::time::sleep(Duration::from_millis(30)).await;

        let processes = pm.list_processes("s1");
        let pid = processes[0].process_id.clone();
        pm.promote_to_background(&pid).unwrap();

        let handle = fg_handle.await.unwrap();
        assert!(handle.result.is_none());

        // Process should still complete in background.
        tokio::time::sleep(Duration::from_millis(300)).await;

        let result = pm.get_result(&pid);
        assert!(result.is_some());
        assert_eq!(result.unwrap().output, "bg-done");
    }

    #[tokio::test]
    async fn promote_nonexistent_returns_error() {
        let pm = ProcessManager::new();
        let err = pm.promote_to_background("proc-nonexistent").unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    #[tokio::test]
    async fn promote_already_background_returns_error() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("bg"), boxed_delayed(500, "ok"))
            .await
            .unwrap();
        let err = pm.promote_to_background(&handle.process_id).unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    #[tokio::test]
    async fn promote_already_completed_returns_error() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("fast"), boxed_immediate("ok", 0))
            .await
            .unwrap();
        // Process is already completed.
        let err = pm.promote_to_background(&handle.process_id).unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    // ── Cancellation ──

    #[tokio::test]
    async fn cancel_running_process_fires_token() {
        let pm = ProcessManager::new();
        let inner_cancel = CancellationToken::new();
        let handle = pm
            .spawn_managed(
                "s1",
                "tc1",
                make_config("cancellable"),
                boxed_cancellable(inner_cancel.clone()),
            )
            .await
            .unwrap();

        assert!(!inner_cancel.is_cancelled());
        pm.cancel_process(&handle.process_id).unwrap();

        // The PM cancellation should cause the task to complete.
        tokio::time::sleep(Duration::from_millis(50)).await;

        let result = pm.get_result(&handle.process_id);
        assert!(result.is_some());
        assert!(result.unwrap().cancelled);
    }

    #[tokio::test]
    async fn cancel_completed_process_is_noop() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("done"), boxed_immediate("ok", 0))
            .await
            .unwrap();
        // Should not error.
        pm.cancel_process(&handle.process_id).unwrap();
    }

    #[tokio::test]
    async fn cancel_nonexistent_returns_error() {
        let pm = ProcessManager::new();
        let err = pm.cancel_process("proc-nonexistent").unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    #[tokio::test]
    async fn cancel_session_processes_cancels_all_for_session() {
        let pm = ProcessManager::new();
        pm.spawn_managed("s1", "tc1", make_config("a"), boxed_delayed(5000, "a"))
            .await
            .unwrap();
        pm.spawn_managed("s1", "tc2", make_config("b"), boxed_delayed(5000, "b"))
            .await
            .unwrap();
        pm.spawn_managed("s2", "tc3", make_config("c"), boxed_delayed(5000, "c"))
            .await
            .unwrap();

        pm.cancel_session_processes("s1");

        // s1 processes should be gone.
        assert!(pm.list_processes("s1").is_empty());
        // s2 should still be there.
        assert_eq!(pm.list_processes("s2").len(), 1);
    }

    #[tokio::test]
    async fn cancel_all_cancels_everything() {
        let pm = ProcessManager::new();
        pm.spawn_managed("s1", "tc1", make_config("a"), boxed_delayed(5000, "a"))
            .await
            .unwrap();
        pm.spawn_managed("s2", "tc2", make_config("b"), boxed_delayed(5000, "b"))
            .await
            .unwrap();

        pm.cancel_all();

        assert!(pm.list_processes("s1").is_empty());
        assert!(pm.list_processes("s2").is_empty());
    }

    // ── Listing & querying ──

    #[tokio::test]
    async fn list_processes_filters_by_session() {
        let pm = ProcessManager::new();
        pm.spawn_managed("s1", "tc1", make_config("a"), boxed_delayed(500, "a"))
            .await
            .unwrap();
        pm.spawn_managed("s2", "tc2", make_config("b"), boxed_delayed(500, "b"))
            .await
            .unwrap();

        let s1_procs = pm.list_processes("s1");
        assert_eq!(s1_procs.len(), 1);
        assert_eq!(s1_procs[0].label, "a");

        let s2_procs = pm.list_processes("s2");
        assert_eq!(s2_procs.len(), 1);
        assert_eq!(s2_procs[0].label, "b");
    }

    #[tokio::test]
    async fn list_processes_empty_session() {
        let pm = ProcessManager::new();
        assert!(pm.list_processes("nonexistent").is_empty());
    }

    #[tokio::test]
    async fn list_processes_includes_recently_completed() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("fast"), boxed_immediate("ok", 0))
            .await
            .unwrap();

        // Just completed — should still be in list.
        let procs = pm.list_processes("s1");
        assert_eq!(procs.len(), 1);
        assert_eq!(procs[0].state, "completed");
    }

    #[tokio::test]
    async fn get_result_returns_none_while_running() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("slow"), boxed_delayed(500, "ok"))
            .await
            .unwrap();
        assert!(pm.get_result(&handle.process_id).is_none());
    }

    #[tokio::test]
    async fn get_result_returns_some_after_completion() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("fast"), boxed_immediate("done", 0))
            .await
            .unwrap();
        let result = pm.get_result(&handle.process_id);
        assert!(result.is_some());
        assert_eq!(result.unwrap().output, "done");
    }

    #[tokio::test]
    async fn get_result_nonexistent_returns_none() {
        let pm = ProcessManager::new();
        assert!(pm.get_result("proc-nonexistent").is_none());
    }

    // ── find_by_label ──

    #[tokio::test]
    async fn find_by_label_matches_prefix() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed(
                "s1",
                "tc1",
                ManagedProcessConfig {
                    label: "display_stream:stream-123".into(),
                    kind: ProcessKind::DisplayStream,
                    timeout_ms: None,
                    blocking_timeout_ms: None,
                    sandbox: false,
                },
                boxed_delayed(500, "ok"),
            )
            .await
            .unwrap();

        let found = pm.find_by_label("s1", "display_stream:");
        assert_eq!(found, Some(handle.process_id));
    }

    #[tokio::test]
    async fn find_by_label_wrong_session_returns_none() {
        let pm = ProcessManager::new();
        pm.spawn_managed(
            "s1",
            "tc1",
            ManagedProcessConfig {
                label: "display_stream:stream-1".into(),
                kind: ProcessKind::DisplayStream,
                timeout_ms: None,
                blocking_timeout_ms: None,
                sandbox: false,
            },
            boxed_delayed(500, "ok"),
        )
        .await
        .unwrap();

        assert!(pm.find_by_label("s2", "display_stream:").is_none());
    }

    #[tokio::test]
    async fn find_by_label_completed_not_returned() {
        let pm = ProcessManager::new();
        pm.spawn_managed(
            "s1",
            "tc1",
            ManagedProcessConfig {
                label: "display_stream:stream-1".into(),
                kind: ProcessKind::DisplayStream,
                timeout_ms: None,
                blocking_timeout_ms: Some(60_000),
                sandbox: false,
            },
            boxed_immediate("ok", 0),
        )
        .await
        .unwrap();

        // Completed processes should not be found by label.
        assert!(pm.find_by_label("s1", "display_stream:").is_none());
    }

    // ── Timeout ──

    #[tokio::test]
    async fn blocking_timeout_auto_backgrounds() {
        let pm = ProcessManager::new();
        let config = ManagedProcessConfig {
            label: "timeout-test".into(),
            kind: ProcessKind::Shell,
            timeout_ms: Some(5000),
            blocking_timeout_ms: Some(100), // auto-background after 100ms
            sandbox: false,
        };
        let start = std::time::Instant::now();
        let handle = pm
            .spawn_managed("s1", "tc1", config, boxed_delayed(5000, "late"))
            .await
            .unwrap();

        // Should have returned due to blocking timeout (auto-backgrounded).
        let elapsed = start.elapsed();
        assert!(elapsed < std::time::Duration::from_millis(1000), "should return quickly after 100ms blocking timeout");
        assert!(handle.result.is_none(), "auto-backgrounded: no inline result");
    }

    #[tokio::test]
    async fn foreground_no_timeout_completes_normally() {
        let pm = ProcessManager::new();
        let config = ManagedProcessConfig {
            label: "no-timeout".into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            blocking_timeout_ms: Some(60_000),
            sandbox: false,
        };
        let handle = pm
            .spawn_managed("s1", "tc1", config, boxed_delayed(100, "done"))
            .await
            .unwrap();
        assert_eq!(handle.result.unwrap().output, "done");
    }

    // ── Process ID format ──

    #[tokio::test]
    async fn process_id_format_valid() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("test"), boxed_immediate("ok", 0))
            .await
            .unwrap();
        assert!(handle.process_id.starts_with("proc-"));
        // After "proc-", the rest should be a valid UUID.
        let uuid_part = &handle.process_id[5..];
        assert!(Uuid::parse_str(uuid_part).is_ok());
    }

    // ── Promotion race with completion ──

    #[tokio::test]
    async fn promote_race_with_completion() {
        // If the process completes just before promotion, promotion should fail gracefully.
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_blocking_config("fast"), boxed_immediate("done", 0))
            .await
            .unwrap();

        // Process is already completed.
        let result = pm.promote_to_background(&handle.process_id);
        assert!(result.is_err());
    }

    // ── wait_for_process ──

    #[tokio::test]
    async fn wait_already_completed() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("fast"), boxed_immediate("done", 0))
            .await
            .unwrap();

        // Give the background task a moment to complete.
        tokio::time::sleep(Duration::from_millis(50)).await;

        let result = pm.wait_for_process(&handle.process_id, 1000).await.unwrap();
        assert_eq!(result.output, "done");
        assert_eq!(result.exit_code, Some(0));
    }

    #[tokio::test]
    async fn wait_completes_within_timeout() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("slow"), boxed_delayed(50, "finished"))
            .await
            .unwrap();

        let result = pm.wait_for_process(&handle.process_id, 5000).await.unwrap();
        assert_eq!(result.output, "finished");
    }

    #[tokio::test]
    async fn wait_timeout_returns_error() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("very-slow"), boxed_delayed(5000, "late"))
            .await
            .unwrap();

        let err = pm.wait_for_process(&handle.process_id, 50).await;
        assert!(err.is_err());
        match err.unwrap_err() {
            ToolError::Timeout { timeout_ms } => assert_eq!(timeout_ms, 50),
            other => panic!("expected Timeout, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn wait_for_cancelled_process() {
        let pm = ProcessManager::new();
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("cancel-me"), boxed_delayed(5000, "nope"))
            .await
            .unwrap();

        pm.cancel_process(&handle.process_id).unwrap();
        // Give cancellation a moment to propagate.
        tokio::time::sleep(Duration::from_millis(50)).await;

        let result = pm.wait_for_process(&handle.process_id, 1000).await.unwrap();
        assert!(result.cancelled);
    }

    #[tokio::test]
    async fn wait_unknown_process_returns_error() {
        let pm = ProcessManager::new();
        let err = pm.wait_for_process("proc-nonexistent", 1000).await;
        assert!(err.is_err());
        match err.unwrap_err() {
            ToolError::Validation { message } => assert!(message.contains("not found")),
            other => panic!("expected Validation, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn wait_concurrent_waiters_both_get_result() {
        let pm = Arc::new(ProcessManager::new());
        let handle = pm
            .spawn_managed("s1", "tc1", make_config("shared"), boxed_delayed(50, "shared-result"))
            .await
            .unwrap();
        let pid = handle.process_id.clone();

        let pm1 = pm.clone();
        let pid1 = pid.clone();
        let w1 = tokio::spawn(async move { pm1.wait_for_process(&pid1, 5000).await });

        let pm2 = pm.clone();
        let pid2 = pid;
        let w2 = tokio::spawn(async move { pm2.wait_for_process(&pid2, 5000).await });

        let r1 = w1.await.unwrap().unwrap();
        let r2 = w2.await.unwrap().unwrap();
        assert_eq!(r1.output, "shared-result");
        assert_eq!(r2.output, "shared-result");
    }
}
