use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;
use crate::tools::errors::ToolError;
use crate::tools::traits::{SubagentResult, WaitMode};

use crate::tools::traits::{JobInfo, JobKind, JobState};

use super::{SpawnType, SubagentManager, TrackedSubagent};

impl SubagentManager {
    pub(super) fn register_subagent(
        &self,
        child_session_id: String,
        parent_session_id: String,
        task: String,
        spawn_type: SpawnType,
    ) -> (Arc<TrackedSubagent>, CancellationToken) {
        let cancel = CancellationToken::new();
        let tracker = Arc::new(TrackedSubagent {
            parent_session_id,
            task,
            spawn_type,
            started_at: Instant::now(),
            done: Notify::new(),
            result: Mutex::new(None),
            cancel: cancel.clone(),
        });

        let _ = self.subagents.insert(child_session_id, tracker.clone());
        (tracker, cancel)
    }

    pub(super) async fn wait_for_tracker_result(
        &self,
        tracker: &Arc<TrackedSubagent>,
        timeout_ms: u64,
    ) -> Result<Option<SubagentResult>, ToolError> {
        let timeout = Duration::from_millis(timeout_ms);
        let wait_result = tokio::time::timeout(timeout, tracker.done.notified()).await;

        if wait_result.is_err() {
            tracker.cancel.cancel();
            return Err(ToolError::Timeout { timeout_ms });
        }

        Ok(tracker.result.lock().clone())
    }

    /// Count active subagents of a given type.
    pub fn active_count_by_type(&self, spawn_type: &SpawnType) -> usize {
        self.subagents
            .iter()
            .filter(|entry| {
                entry.value().spawn_type == *spawn_type && entry.value().result.lock().is_none()
            })
            .count()
    }

    /// List all active subagents for a parent session as unified `JobInfo`.
    pub fn list_active_jobs(&self, parent_session_id: &str) -> Vec<JobInfo> {
        self.subagents
            .iter()
            .filter(|entry| {
                entry.value().parent_session_id == parent_session_id
            })
            .map(|entry| {
                let t = entry.value();
                let state = if t.result.lock().is_some() {
                    // Check the actual result for success/failure
                    match t.result.lock().as_ref().map(|r| r.status.as_str()) {
                        Some("completed") => JobState::Completed,
                        Some("failed") => JobState::Failed,
                        _ => JobState::Failed,
                    }
                } else if t.cancel.is_cancelled() {
                    JobState::Cancelled
                } else {
                    JobState::Running
                };
                JobInfo {
                    id: entry.key().clone(),
                    kind: JobKind::Agent,
                    label: t.task.clone(),
                    state,
                    elapsed_ms: t.started_at.elapsed().as_millis() as u64,
                    session_id: t.parent_session_id.clone(),
                }
            })
            .collect()
    }

    /// Cancel a specific subagent by session ID.
    ///
    /// Returns Ok(()) if the subagent was found and cancelled (or already finished).
    /// Returns error if the session ID is not found.
    pub fn cancel_subagent(&self, session_id: &str) -> Result<(), ToolError> {
        let tracker = self
            .subagents
            .get(session_id)
            .ok_or_else(|| ToolError::Validation {
                message: format!("Subagent not found: {session_id}"),
            })?;

        // If already completed, no-op.
        if tracker.result.lock().is_some() {
            return Ok(());
        }

        tracker.cancel.cancel();
        Ok(())
    }

    /// List active subsessions as `(session_id, task)` pairs.
    pub fn list_active_subsessions(&self) -> Vec<(String, String)> {
        self.subagents
            .iter()
            .filter(|entry| {
                entry.value().spawn_type == SpawnType::Subsession
                    && entry.value().result.lock().is_none()
            })
            .map(|entry| (entry.key().clone(), entry.value().task.clone()))
            .collect()
    }

    pub(super) async fn wait_for_agents_impl(
        &self,
        session_ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<SubagentResult>, ToolError> {
        if session_ids.is_empty() {
            return Err(ToolError::Validation {
                message: "No session IDs provided".into(),
            });
        }

        let timeout = Duration::from_millis(timeout_ms);
        let deadline = Instant::now() + timeout;

        match mode {
            WaitMode::All => {
                let mut results = Vec::with_capacity(session_ids.len());
                for sid in session_ids {
                    let tracker = self
                        .subagents
                        .get(sid)
                        .ok_or_else(|| ToolError::Validation {
                            message: format!("Unknown subagent session: {sid}"),
                        })?;

                    if let Some(result) = tracker.result.lock().clone() {
                        results.push(result);
                        continue;
                    }

                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(ToolError::Timeout { timeout_ms });
                    }

                    let wait = tokio::time::timeout(remaining, tracker.done.notified()).await;
                    if wait.is_err() {
                        return Err(ToolError::Timeout { timeout_ms });
                    }

                    results.push(tracker_result_or_unknown(&tracker, sid));
                }
                Ok(results)
            }
            WaitMode::Any => {
                let trackers: Vec<_> = session_ids
                    .iter()
                    .map(|sid| {
                        self.subagents
                            .get(sid)
                            .map(|tracker| (sid.clone(), tracker.clone()))
                    })
                    .collect::<Option<Vec<_>>>()
                    .ok_or_else(|| ToolError::Validation {
                        message: "One or more unknown subagent sessions".into(),
                    })?;

                for (sid, tracker) in &trackers {
                    if let Some(result) = tracker.result.lock().clone() {
                        return Ok(vec![result]);
                    }
                    let _ = sid;
                }

                let (result_tx, mut result_rx) = tokio::sync::mpsc::channel(1);
                for (sid, tracker) in trackers {
                    let tx = result_tx.clone();
                    drop(tokio::spawn(async move {
                        tracker.done.notified().await;
                        let _ = tx.send(tracker_result_or_unknown(&tracker, &sid)).await;
                    }));
                }
                drop(result_tx);

                match tokio::time::timeout(timeout, result_rx.recv()).await {
                    Ok(Some(result)) => Ok(vec![result]),
                    Ok(None) => Err(ToolError::Internal {
                        message: "All wait tasks completed without result".into(),
                    }),
                    Err(_) => Err(ToolError::Timeout { timeout_ms }),
                }
            }
        }
    }
}

fn tracker_result_or_unknown(tracker: &TrackedSubagent, session_id: &str) -> SubagentResult {
    tracker
        .result
        .lock()
        .clone()
        .unwrap_or_else(|| SubagentResult {
            session_id: session_id.to_owned(),
            output: String::new(),
            token_usage: None,
            duration_ms: 0,
            status: "unknown".into(),
        })
}
