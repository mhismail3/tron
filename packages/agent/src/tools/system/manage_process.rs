//! `ManageJob` tool — list and cancel background jobs (processes and subagents).
//!
//! Status/result retrieval is handled by the `Wait` tool.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::tools::errors::ToolError;
use crate::tools::traits::{JobKind, JobManagerOps, JobState, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{get_optional_string, validate_required_string};

/// Tool for listing and cancelling background jobs.
pub struct ManageJobTool {
    job_manager: Arc<dyn JobManagerOps>,
}

impl ManageJobTool {
    /// Create a new `ManageJob` tool.
    pub fn new(job_manager: Arc<dyn JobManagerOps>) -> Self {
        Self { job_manager }
    }
}

#[async_trait]
impl TronTool for ManageJobTool {
    fn name(&self) -> &str {
        "ManageJob"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Shell
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "ManageJob",
            "Manage background jobs (processes and sub-agents). List active jobs or cancel a running job.\n\
             Use the Wait tool to block on jobs and retrieve their results.",
        )
        .required_property(
            "action",
            json!({
                "type": "string",
                "enum": ["list", "cancel"],
                "description": "Action to perform: 'list' shows all active/recent jobs, 'cancel' stops a specific job"
            }),
        )
        .property(
            "id",
            json!({
                "type": "string",
                "description": "Job ID to cancel (process ID or sub-agent session ID). Required for 'cancel' action."
            }),
        )
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "action") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        match action.as_str() {
            "list" => self.handle_list(ctx),
            "cancel" => self.handle_cancel(&params),
            other => Ok(error_result(format!(
                "Unknown action: '{other}'. Supported: list, cancel."
            ))),
        }
    }
}

impl ManageJobTool {
    fn handle_list(&self, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let jobs = self.job_manager.list_jobs(&ctx.session_id);
        if jobs.is_empty() {
            return Ok(TronToolResult {
                content: ToolResultBody::Text("No active jobs for this session.".into()),
                details: Some(json!({"jobs": []})),
                is_error: None,
                stop_turn: None,
            });
        }

        let mut lines = Vec::new();
        for j in &jobs {
            let kind_tag = match j.kind {
                JobKind::Process => "Process",
                JobKind::Agent => "Agent",
            };
            let state_str = match j.state {
                JobState::Running => "running",
                JobState::Completed => "completed",
                JobState::Failed => "failed",
                JobState::Cancelled => "cancelled",
            };
            lines.push(format!(
                "- [{kind_tag}] **{}** (`{}`) — {state_str} ({:.1}s)",
                j.label,
                j.id,
                j.elapsed_ms as f64 / 1000.0
            ));
        }

        Ok(TronToolResult {
            content: ToolResultBody::Text(lines.join("\n")),
            details: Some(json!({"jobs": jobs})),
            is_error: None,
            stop_turn: None,
        })
    }

    fn handle_cancel(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let id = match get_optional_string(params, "id") {
            Some(id) => id,
            None => return Ok(error_result("Missing 'id' for cancel action.")),
        };

        match self.job_manager.cancel_job(&id, false) {
            Ok(()) => Ok(TronToolResult {
                content: ToolResultBody::Text(format!("Job `{id}` cancelled.")),
                details: Some(json!({"id": id, "cancelled": true})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Failed to cancel: {e}"))),
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::testutil::{extract_text, make_ctx};
    use crate::tools::traits::{JobInfo, JobResult, WaitMode};

    // ── Mock JobManager ──

    struct MockJM {
        jobs: std::sync::Mutex<Vec<JobInfo>>,
        cancel_ok: bool,
    }

    impl MockJM {
        fn empty() -> Self {
            Self {
                jobs: std::sync::Mutex::new(Vec::new()),
                cancel_ok: true,
            }
        }

        fn with_jobs(jobs: Vec<JobInfo>) -> Self {
            Self {
                jobs: std::sync::Mutex::new(jobs),
                cancel_ok: true,
            }
        }

        fn cancel_fails() -> Self {
            Self {
                jobs: std::sync::Mutex::new(Vec::new()),
                cancel_ok: false,
            }
        }
    }

    #[async_trait]
    impl JobManagerOps for MockJM {
        fn list_jobs(&self, _session_id: &str) -> Vec<JobInfo> {
            self.jobs.lock().unwrap().clone()
        }
        async fn wait_for_jobs(
            &self,
            _ids: &[String],
            _mode: WaitMode,
            _timeout_ms: u64,
        ) -> Result<Vec<JobResult>, ToolError> {
            Ok(Vec::new())
        }
        fn cancel_job(&self, _id: &str, _user_initiated: bool) -> Result<(), ToolError> {
            if self.cancel_ok {
                Ok(())
            } else {
                Err(ToolError::Validation {
                    message: "Not found".into(),
                })
            }
        }
    }

    // ── Schema ──

    #[test]
    fn manage_job_schema() {
        let jm = Arc::new(MockJM::empty());
        let tool = ManageJobTool::new(jm);
        assert_eq!(tool.name(), "ManageJob");
        assert_eq!(tool.category(), ToolCategory::Shell);
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        assert!(props.contains_key("action"));
        assert!(props.contains_key("id"));
        let required = def.parameters.required.as_ref().unwrap();
        assert!(required.contains(&"action".to_string()));
    }

    // ── List ──

    #[tokio::test]
    async fn list_empty() {
        let jm = Arc::new(MockJM::empty());
        let tool = ManageJobTool::new(jm);
        let r = tool
            .execute(json!({"action": "list"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("No active jobs"));
    }

    #[tokio::test]
    async fn list_mixed_jobs() {
        let jobs = vec![
            JobInfo {
                id: "proc-a".into(),
                kind: JobKind::Process,
                label: "cargo build".into(),
                state: JobState::Running,
                elapsed_ms: 5000,
                session_id: "sess-1".into(),
            },
            JobInfo {
                id: "ses-b".into(),
                kind: JobKind::Agent,
                label: "Research".into(),
                state: JobState::Completed,
                elapsed_ms: 10000,
                session_id: "sess-1".into(),
            },
        ];
        let jm = Arc::new(MockJM::with_jobs(jobs));
        let tool = ManageJobTool::new(jm);
        let r = tool
            .execute(json!({"action": "list"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("[Process]"));
        assert!(text.contains("[Agent]"));
        assert!(text.contains("cargo build"));
        assert!(text.contains("Research"));
    }

    // ── Cancel ──

    #[tokio::test]
    async fn cancel_success() {
        let jm = Arc::new(MockJM::empty());
        let tool = ManageJobTool::new(jm);
        let r = tool
            .execute(json!({"action": "cancel", "id": "proc-a"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("cancelled"));
    }

    #[tokio::test]
    async fn cancel_missing_id() {
        let jm = Arc::new(MockJM::empty());
        let tool = ManageJobTool::new(jm);
        let r = tool
            .execute(json!({"action": "cancel"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn cancel_not_found() {
        let jm = Arc::new(MockJM::cancel_fails());
        let tool = ManageJobTool::new(jm);
        let r = tool
            .execute(json!({"action": "cancel", "id": "proc-nope"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    // ── Validation ──

    #[tokio::test]
    async fn unknown_action() {
        let jm = Arc::new(MockJM::empty());
        let tool = ManageJobTool::new(jm);
        let r = tool
            .execute(json!({"action": "foo"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_action() {
        let jm = Arc::new(MockJM::empty());
        let tool = ManageJobTool::new(jm);
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
