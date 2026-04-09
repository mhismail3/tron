//! `JobManager` — unified facade for process and subagent lifecycle.
//!
//! Presents a single `JobManagerOps` interface over `ProcessManagerOps` (deterministic
//! shell commands) and `SubagentManager` (non-deterministic LLM agents). Job IDs are
//! routed by prefix: `proc-*` → process manager, everything else → subagent manager.

use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde_json::json;

use crate::tools::errors::ToolError;
use crate::tools::traits::{
    JobInfo, JobKind, JobManagerOps, JobResult, JobState, ManagedProcessResult,
    ProcessManagerOps, SubagentOps, WaitMode,
};
use crate::tools::utils::truncation::{truncate_tail, WAIT_OUTPUT_LIMIT};

/// Unified job manager delegating to process and subagent backends.
pub struct JobManager {
    process_manager: Arc<dyn ProcessManagerOps>,
    subagent_ops: Arc<dyn SubagentOps>,
}

impl JobManager {
    /// Create a new `JobManager` facade.
    pub fn new(
        process_manager: Arc<dyn ProcessManagerOps>,
        subagent_ops: Arc<dyn SubagentOps>,
    ) -> Self {
        Self {
            process_manager,
            subagent_ops,
        }
    }

    /// Returns true if the ID looks like a process ID (`proc-*` prefix).
    fn is_process_id(id: &str) -> bool {
        id.starts_with("proc-")
    }

    /// Convert a `ManagedProcessResult` to a `JobResult`.
    fn process_result_to_job(result: &ManagedProcessResult) -> JobResult {
        let success = !result.cancelled
            && !result.timed_out
            && result.exit_code.map_or(true, |c| c == 0);

        JobResult {
            id: result.process_id.clone(),
            kind: JobKind::Process,
            label: String::new(),
            output: result.output.clone(),
            success,
            duration_ms: result.duration_ms,
            details: Some(json!({
                "exit_code": result.exit_code,
                "timed_out": result.timed_out,
                "cancelled": result.cancelled,
                "blob_id": result.blob_id,
            })),
        }
    }
}

#[async_trait]
impl JobManagerOps for JobManager {
    fn list_jobs(&self, session_id: &str) -> Vec<JobInfo> {
        let mut jobs = Vec::new();

        // Processes
        for info in self.process_manager.list_processes(session_id) {
            let state = match info.state.as_str() {
                "completed" => JobState::Completed,
                "failed" => JobState::Failed,
                "cancelled" => JobState::Cancelled,
                _ => JobState::Running,
            };
            jobs.push(JobInfo {
                id: info.process_id,
                kind: JobKind::Process,
                label: info.label,
                state,
                elapsed_ms: info.elapsed_ms,
                session_id: info.session_id,
            });
        }

        // Subagents
        jobs.extend(self.subagent_ops.list_active_jobs(session_id));

        // Sort by elapsed_ms descending (most recent first = smallest elapsed).
        jobs.sort_by_key(|j| std::cmp::Reverse(j.elapsed_ms));

        jobs
    }

    async fn wait_for_jobs(
        &self,
        ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<JobResult>, ToolError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        // Deduplicate IDs.
        let mut seen = std::collections::HashSet::new();
        let unique_ids: Vec<&str> = ids
            .iter()
            .filter(|id| seen.insert(id.as_str()))
            .map(|id| id.as_str())
            .collect();

        // Partition by type.
        let (proc_ids, agent_ids): (Vec<&str>, Vec<&str>) =
            unique_ids.iter().partition(|id| Self::is_process_id(id));

        let deadline = Instant::now() + Duration::from_millis(timeout_ms);

        match mode {
            WaitMode::All => self.wait_all(&proc_ids, &agent_ids, deadline, timeout_ms).await,
            WaitMode::Any => self.wait_any(&proc_ids, &agent_ids, deadline, timeout_ms).await,
        }
    }

    fn cancel_job(&self, id: &str, user_initiated: bool) -> Result<(), ToolError> {
        if Self::is_process_id(id) {
            self.process_manager.cancel_process(id, user_initiated)
        } else {
            self.subagent_ops.cancel_subagent(id)
        }
    }
}

impl JobManager {
    async fn wait_all(
        &self,
        proc_ids: &[&str],
        agent_ids: &[&str],
        deadline: Instant,
        timeout_ms: u64,
    ) -> Result<Vec<JobResult>, ToolError> {
        let mut results = Vec::new();

        // Wait for processes.
        for &pid in proc_ids {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                results.push(JobResult {
                    id: pid.to_owned(),
                    kind: JobKind::Process,
                    label: String::new(),
                    output: format!("[STILL RUNNING after {timeout_ms}ms]"),
                    success: false,
                    duration_ms: timeout_ms,
                    details: None,
                });
                continue;
            }

            match self
                .process_manager
                .wait_for_process(pid, remaining.as_millis() as u64)
                .await
            {
                Ok(result) => results.push(Self::process_result_to_job(&result)),
                Err(ToolError::Timeout { .. }) => {
                    results.push(JobResult {
                        id: pid.to_owned(),
                        kind: JobKind::Process,
                        label: String::new(),
                        output: format!("[STILL RUNNING after {timeout_ms}ms]"),
                        success: false,
                        duration_ms: timeout_ms,
                        details: None,
                    });
                }
                Err(ToolError::Validation { .. }) => {
                    // Not found — include as error result rather than failing the whole wait.
                    results.push(JobResult {
                        id: pid.to_owned(),
                        kind: JobKind::Process,
                        label: String::new(),
                        output: format!("Job not found: {pid}"),
                        success: false,
                        duration_ms: 0,
                        details: None,
                    });
                }
                Err(e) => return Err(e),
            }
        }

        // Wait for agents.
        if !agent_ids.is_empty() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let agent_id_strings: Vec<String> =
                agent_ids.iter().map(|s| s.to_string()).collect();

            match self
                .subagent_ops
                .wait_for_agents(&agent_id_strings, WaitMode::All, remaining.as_millis() as u64)
                .await
            {
                Ok(agent_results) => {
                    for r in agent_results {
                        results.push(JobResult {
                            id: r.session_id.clone(),
                            kind: JobKind::Agent,
                            label: String::new(),
                            output: truncate_tail(&r.output, WAIT_OUTPUT_LIMIT),
                            success: r.status == "completed",
                            duration_ms: r.duration_ms,
                            details: Some(json!({
                                "token_usage": r.token_usage,
                                "status": r.status,
                            })),
                        });
                    }
                }
                Err(ToolError::Timeout { .. }) => {
                    // Add "still running" entries for agents that didn't complete.
                    for &aid in agent_ids {
                        let already_done = results.iter().any(|r| r.id == aid);
                        if !already_done {
                            results.push(JobResult {
                                id: aid.to_owned(),
                                kind: JobKind::Agent,
                                label: String::new(),
                                output: format!("[STILL RUNNING after {timeout_ms}ms]"),
                                success: false,
                                duration_ms: timeout_ms,
                                details: None,
                            });
                        }
                    }
                }
                Err(ToolError::Validation { .. }) => {
                    for &aid in agent_ids {
                        results.push(JobResult {
                            id: aid.to_owned(),
                            kind: JobKind::Agent,
                            label: String::new(),
                            output: format!("Job not found: {aid}"),
                            success: false,
                            duration_ms: 0,
                            details: None,
                        });
                    }
                }
                Err(e) => return Err(e),
            }
        }

        Ok(results)
    }

    async fn wait_any(
        &self,
        proc_ids: &[&str],
        agent_ids: &[&str],
        deadline: Instant,
        timeout_ms: u64,
    ) -> Result<Vec<JobResult>, ToolError> {
        // Check if any processes are already completed.
        for &pid in proc_ids {
            if let Some(result) = self.process_manager.get_result(pid) {
                return Ok(vec![Self::process_result_to_job(&result)]);
            }
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ToolError::Timeout { timeout_ms });
        }

        // Race all process waits and agent waits.
        let (result_tx, mut result_rx) = tokio::sync::mpsc::channel::<JobResult>(1);

        // Spawn process waiters.
        for &pid in proc_ids {
            let pm = self.process_manager.clone();
            let pid = pid.to_owned();
            let tx = result_tx.clone();
            let remaining_ms = remaining.as_millis() as u64;
            let _handle = tokio::spawn(async move {
                if let Ok(result) = pm.wait_for_process(&pid, remaining_ms).await {
                    let _ = tx.send(Self::process_result_to_job(&result)).await;
                }
            });
        }

        // Spawn agent waiter (if any).
        if !agent_ids.is_empty() {
            let sm = self.subagent_ops.clone();
            let agent_id_strings: Vec<String> =
                agent_ids.iter().map(|s| s.to_string()).collect();
            let tx = result_tx.clone();
            let remaining_ms = remaining.as_millis() as u64;
            let _handle = tokio::spawn(async move {
                if let Ok(agent_results) = sm
                    .wait_for_agents(&agent_id_strings, WaitMode::Any, remaining_ms)
                    .await
                {
                    for r in agent_results {
                        let _ = tx
                            .send(JobResult {
                                id: r.session_id.clone(),
                                kind: JobKind::Agent,
                                label: String::new(),
                                output: truncate_tail(&r.output, WAIT_OUTPUT_LIMIT),
                                success: r.status == "completed",
                                duration_ms: r.duration_ms,
                                details: Some(json!({
                                    "token_usage": r.token_usage,
                                    "status": r.status,
                                })),
                            })
                            .await;
                    }
                }
            });
        }

        drop(result_tx);

        match tokio::time::timeout(remaining, result_rx.recv()).await {
            Ok(Some(result)) => Ok(vec![result]),
            Ok(None) => Err(ToolError::Internal {
                message: "All wait tasks completed without result".into(),
            }),
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
    use crate::tools::traits::{
        ManagedProcessConfig, ManagedProcessHandle, ProcessInfo, ProcessKind,
        SubagentOps, SubagentResult,
    };
    use std::pin::Pin;

    // ── Mock ProcessManager ──

    struct MockProcessManager {
        processes: std::sync::Mutex<Vec<ProcessInfo>>,
        results: std::sync::Mutex<std::collections::HashMap<String, ManagedProcessResult>>,
    }

    impl MockProcessManager {
        fn new() -> Self {
            Self {
                processes: std::sync::Mutex::new(Vec::new()),
                results: std::sync::Mutex::new(std::collections::HashMap::new()),
            }
        }

        fn add_process(&self, info: ProcessInfo, result: Option<ManagedProcessResult>) {
            self.processes.lock().unwrap().push(info);
            if let Some(r) = result {
                let pid = r.process_id.clone();
                self.results.lock().unwrap().insert(pid, r);
            }
        }
    }

    #[async_trait]
    impl ProcessManagerOps for MockProcessManager {
        async fn spawn_managed(
            &self,
            _session_id: &str,
            _tool_call_id: &str,
            _config: ManagedProcessConfig,
            _task: Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>>,
        ) -> Result<ManagedProcessHandle, ToolError> {
            unimplemented!()
        }
        fn promote_to_background(&self, _process_id: &str) -> Result<(), ToolError> {
            unimplemented!()
        }
        fn cancel_process(&self, process_id: &str, _user_initiated: bool) -> Result<(), ToolError> {
            if self.results.lock().unwrap().contains_key(process_id)
                || self
                    .processes
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|p| p.process_id == process_id)
            {
                Ok(())
            } else {
                Err(ToolError::Validation {
                    message: format!("Process not found: {process_id}"),
                })
            }
        }
        fn list_processes(&self, session_id: &str) -> Vec<ProcessInfo> {
            self.processes
                .lock()
                .unwrap()
                .iter()
                .filter(|p| p.session_id == session_id)
                .cloned()
                .collect()
        }
        fn get_result(&self, process_id: &str) -> Option<ManagedProcessResult> {
            self.results.lock().unwrap().get(process_id).cloned()
        }
        fn find_by_label(&self, _session_id: &str, _label_prefix: &str) -> Option<String> {
            None
        }
        fn cancel_session_processes(&self, _session_id: &str) {}
        fn cancel_all(&self) {}
        async fn wait_for_process(
            &self,
            process_id: &str,
            _timeout_ms: u64,
        ) -> Result<ManagedProcessResult, ToolError> {
            self.results
                .lock()
                .unwrap()
                .get(process_id)
                .cloned()
                .ok_or_else(|| ToolError::Validation {
                    message: format!("Process not found: {process_id}"),
                })
        }
    }

    // ── Mock SubagentOps ──

    struct MockSubagentOps {
        agents: std::sync::Mutex<Vec<JobInfo>>,
        results: std::sync::Mutex<std::collections::HashMap<String, SubagentResult>>,
    }

    impl MockSubagentOps {
        fn new() -> Self {
            Self {
                agents: std::sync::Mutex::new(Vec::new()),
                results: std::sync::Mutex::new(std::collections::HashMap::new()),
            }
        }
    }

    #[async_trait]
    impl SubagentOps for MockSubagentOps {
        fn list_active_jobs(&self, parent_session_id: &str) -> Vec<JobInfo> {
            self.agents
                .lock()
                .unwrap()
                .iter()
                .filter(|j| j.session_id == parent_session_id)
                .cloned()
                .collect()
        }

        fn cancel_subagent(&self, session_id: &str) -> Result<(), ToolError> {
            if self
                .agents
                .lock()
                .unwrap()
                .iter()
                .any(|j| j.id == session_id)
            {
                Ok(())
            } else {
                Err(ToolError::Validation {
                    message: format!("Subagent not found: {session_id}"),
                })
            }
        }

        async fn wait_for_agents(
            &self,
            session_ids: &[String],
            _mode: WaitMode,
            _timeout_ms: u64,
        ) -> Result<Vec<SubagentResult>, ToolError> {
            let results = self.results.lock().unwrap();
            let mut out = Vec::new();
            for sid in session_ids {
                if let Some(r) = results.get(sid) {
                    out.push(r.clone());
                } else {
                    return Err(ToolError::Validation {
                        message: format!("Unknown subagent session: {sid}"),
                    });
                }
            }
            Ok(out)
        }

        fn get_subagent_result(&self, session_id: &str) -> Option<SubagentResult> {
            self.results.lock().unwrap().get(session_id).cloned()
        }
    }

    fn make_process_info(pid: &str, label: &str, state: &str, session: &str) -> ProcessInfo {
        ProcessInfo {
            process_id: pid.into(),
            label: label.into(),
            kind: ProcessKind::Shell,
            state: state.into(),
            elapsed_ms: 1000,
            session_id: session.into(),
            tool_call_id: "tc1".into(),
        }
    }

    fn make_process_result(pid: &str, output: &str, exit_code: i32) -> ManagedProcessResult {
        ManagedProcessResult {
            process_id: pid.into(),
            output: output.into(),
            exit_code: Some(exit_code),
            duration_ms: 500,
            timed_out: false,
            cancelled: false,
            blob_id: None,
            user_cancelled: false,
        }
    }

    fn make_mock_subagent_ops() -> Arc<MockSubagentOps> {
        Arc::new(MockSubagentOps::new())
    }

    // ── Tests ──

    #[test]
    fn is_process_id_detection() {
        assert!(JobManager::is_process_id("proc-abc123"));
        assert!(JobManager::is_process_id("proc-"));
        assert!(!JobManager::is_process_id("ses-abc123"));
        assert!(!JobManager::is_process_id("process-abc"));
        assert!(!JobManager::is_process_id(""));
    }

    #[test]
    fn process_result_to_job_success() {
        let result = make_process_result("proc-1", "build ok", 0);
        let job = JobManager::process_result_to_job(&result);
        assert_eq!(job.id, "proc-1");
        assert_eq!(job.kind, JobKind::Process);
        assert!(job.success);
        assert_eq!(job.output, "build ok");
        assert_eq!(job.duration_ms, 500);
        assert!(job.details.is_some());
        assert_eq!(job.details.as_ref().unwrap()["exit_code"], 0);
    }

    #[test]
    fn process_result_to_job_failure() {
        let result = make_process_result("proc-2", "error", 1);
        let job = JobManager::process_result_to_job(&result);
        assert!(!job.success);
        assert_eq!(job.details.as_ref().unwrap()["exit_code"], 1);
    }

    #[test]
    fn process_result_to_job_cancelled() {
        let mut result = make_process_result("proc-3", "", 0);
        result.cancelled = true;
        let job = JobManager::process_result_to_job(&result);
        assert!(!job.success);
    }

    #[test]
    fn list_jobs_empty() {
        let pm = Arc::new(MockProcessManager::new());
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);
        let jobs = jm.list_jobs("sess-1");
        assert!(jobs.is_empty());
    }

    #[test]
    fn list_jobs_processes_only() {
        let pm = Arc::new(MockProcessManager::new());
        pm.add_process(
            make_process_info("proc-a", "cargo build", "background", "sess-1"),
            None,
        );
        pm.add_process(
            make_process_info("proc-b", "npm test", "completed", "sess-1"),
            None,
        );
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        let jobs = jm.list_jobs("sess-1");
        assert_eq!(jobs.len(), 2);
        assert!(jobs.iter().all(|j| j.kind == JobKind::Process));
    }

    #[test]
    fn list_jobs_agents_only() {
        let pm = Arc::new(MockProcessManager::new());
        let sm = make_mock_subagent_ops();
        sm.agents.lock().unwrap().push(JobInfo {
            id: "ses-abc".into(),
            kind: JobKind::Agent,
            label: "Research task".into(),
            state: JobState::Running,
            elapsed_ms: 2000,
            session_id: "sess-1".into(),
        });
        let jm = JobManager::new(pm, sm);

        let jobs = jm.list_jobs("sess-1");
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].kind, JobKind::Agent);
        assert_eq!(jobs[0].id, "ses-abc");
    }

    #[test]
    fn list_jobs_mixed() {
        let pm = Arc::new(MockProcessManager::new());
        pm.add_process(
            make_process_info("proc-a", "build", "background", "sess-1"),
            None,
        );
        let sm = make_mock_subagent_ops();
        sm.agents.lock().unwrap().push(JobInfo {
            id: "ses-abc".into(),
            kind: JobKind::Agent,
            label: "Research task".into(),
            state: JobState::Running,
            elapsed_ms: 3000,
            session_id: "sess-1".into(),
        });
        let jm = JobManager::new(pm, sm);

        let jobs = jm.list_jobs("sess-1");
        assert_eq!(jobs.len(), 2);
        let kinds: Vec<_> = jobs.iter().map(|j| j.kind.clone()).collect();
        assert!(kinds.contains(&JobKind::Process));
        assert!(kinds.contains(&JobKind::Agent));
    }

    #[test]
    fn list_jobs_filters_by_session() {
        let pm = Arc::new(MockProcessManager::new());
        pm.add_process(
            make_process_info("proc-a", "cmd1", "background", "sess-1"),
            None,
        );
        pm.add_process(
            make_process_info("proc-b", "cmd2", "background", "sess-2"),
            None,
        );
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        let jobs = jm.list_jobs("sess-1");
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].id, "proc-a");
    }

    #[tokio::test]
    async fn wait_empty_ids_returns_empty() {
        let pm = Arc::new(MockProcessManager::new());
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        let results = jm.wait_for_jobs(&[], WaitMode::All, 5000).await.unwrap();
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn wait_for_process_ids() {
        let pm = Arc::new(MockProcessManager::new());
        pm.add_process(
            make_process_info("proc-a", "build", "completed", "s1"),
            Some(make_process_result("proc-a", "build ok", 0)),
        );
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        let results = jm
            .wait_for_jobs(&["proc-a".into()], WaitMode::All, 5000)
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].kind, JobKind::Process);
        assert_eq!(results[0].output, "build ok");
        assert!(results[0].success);
    }

    #[tokio::test]
    async fn wait_for_agent_ids() {
        let pm = Arc::new(MockProcessManager::new());
        let sm = make_mock_subagent_ops();
        sm.results.lock().unwrap().insert(
            "ses-123".into(),
            SubagentResult {
                session_id: "ses-123".into(),
                output: "Agent finished".into(),
                token_usage: Some(serde_json::json!({"input": 100, "output": 50})),
                duration_ms: 5000,
                status: "completed".into(),
                turns_executed: 3,
            },
        );
        let jm = JobManager::new(pm, sm);

        let results = jm
            .wait_for_jobs(&["ses-123".into()], WaitMode::All, 5000)
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].kind, JobKind::Agent);
        assert_eq!(results[0].output, "Agent finished");
        assert!(results[0].success);
        assert!(results[0].details.is_some());
    }

    #[tokio::test]
    async fn wait_for_mixed_ids() {
        let pm = Arc::new(MockProcessManager::new());
        pm.add_process(
            make_process_info("proc-a", "build", "completed", "s1"),
            Some(make_process_result("proc-a", "build ok", 0)),
        );
        let sm = make_mock_subagent_ops();
        sm.results.lock().unwrap().insert(
            "ses-123".into(),
            SubagentResult {
                session_id: "ses-123".into(),
                output: "Agent done".into(),
                token_usage: None,
                duration_ms: 3000,
                status: "completed".into(),
                turns_executed: 2,
            },
        );
        let jm = JobManager::new(pm, sm);

        let results = jm
            .wait_for_jobs(
                &["proc-a".into(), "ses-123".into()],
                WaitMode::All,
                5000,
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 2);
        let kinds: Vec<_> = results.iter().map(|r| r.kind.clone()).collect();
        assert!(kinds.contains(&JobKind::Process));
        assert!(kinds.contains(&JobKind::Agent));
    }

    #[tokio::test]
    async fn wait_unknown_id_returns_not_found_result() {
        let pm = Arc::new(MockProcessManager::new());
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        let results = jm
            .wait_for_jobs(&["proc-nonexistent".into()], WaitMode::All, 5000)
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert!(!results[0].success);
        assert!(results[0].output.contains("not found"));
    }

    #[tokio::test]
    async fn wait_duplicate_ids_deduplicates() {
        let pm = Arc::new(MockProcessManager::new());
        pm.add_process(
            make_process_info("proc-a", "test", "completed", "s1"),
            Some(make_process_result("proc-a", "ok", 0)),
        );
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        let results = jm
            .wait_for_jobs(
                &["proc-a".into(), "proc-a".into()],
                WaitMode::All,
                5000,
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
    }

    #[tokio::test]
    async fn cancel_process_routes_correctly() {
        let pm = Arc::new(MockProcessManager::new());
        pm.add_process(
            make_process_info("proc-a", "build", "background", "s1"),
            None,
        );
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        assert!(jm.cancel_job("proc-a", false).is_ok());
    }

    #[tokio::test]
    async fn cancel_agent_routes_correctly() {
        let pm = Arc::new(MockProcessManager::new());
        let sm = make_mock_subagent_ops();
        sm.agents.lock().unwrap().push(JobInfo {
            id: "ses-abc".into(),
            kind: JobKind::Agent,
            label: "task".into(),
            state: JobState::Running,
            elapsed_ms: 0,
            session_id: "s1".into(),
        });
        let jm = JobManager::new(pm, sm);

        assert!(jm.cancel_job("ses-abc", false).is_ok());
    }

    #[tokio::test]
    async fn cancel_unknown_returns_error() {
        let pm = Arc::new(MockProcessManager::new());
        let sm = make_mock_subagent_ops();
        let jm = JobManager::new(pm, sm);

        assert!(jm.cancel_job("proc-nonexistent", false).is_err());
        assert!(jm.cancel_job("ses-nonexistent", false).is_err());
    }
}
