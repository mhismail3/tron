//! `Wait` tool — blocks until one or more background jobs complete.
//!
//! Unified wait for both process jobs (`proc-*` IDs) and agent jobs
//! (subagent session IDs).

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::tools::errors::ToolError;
use crate::tools::traits::{JobKind, JobManagerOps, JobResult, ToolContext, TronTool, WaitMode};
use crate::tools::utils::truncation::{truncate_tail, WAIT_OUTPUT_LIMIT};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::get_optional_string;

const DEFAULT_TIMEOUT_MS: u64 = 300_000; // 5 minutes

/// The `Wait` tool blocks until background jobs complete.
pub struct WaitTool {
    job_manager: Arc<dyn JobManagerOps>,
}

impl WaitTool {
    /// Create a new `Wait` tool with the given job manager.
    pub fn new(job_manager: Arc<dyn JobManagerOps>) -> Self {
        Self { job_manager }
    }
}

#[async_trait]
impl TronTool for WaitTool {
    fn name(&self) -> &str {
        "Wait"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Wait",
            "Wait for background jobs (processes or sub-agents) to complete and get their results.\n\n\
             Use this when you need the output of a background command or sub-agent before proceeding.\n\n\
             Mode:\n\
             - 'all' (default): Wait for ALL jobs to complete\n\
             - 'any': Return as soon as ANY job completes\n\n\
             On timeout, returns partial results for completed jobs and '[STILL RUNNING]' markers for the rest.",
        )
        .required_property(
            "ids",
            json!({
                "type": "array",
                "items": {"type": "string"},
                "description": "Job IDs to wait for (process IDs like 'proc-...' or sub-agent session IDs)"
            }),
        )
        .property(
            "mode",
            json!({
                "type": "string",
                "enum": ["all", "any"],
                "description": "Wait mode: 'all' waits for every job, 'any' returns on first completion (default: all)"
            }),
        )
        .property(
            "timeout",
            json!({
                "type": "number",
                "description": "Timeout in milliseconds (default: 300000 = 5 minutes)"
            }),
        )
        .build()
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let ids = match params.get("ids").and_then(serde_json::Value::as_array) {
            Some(arr) => arr
                .iter()
                .filter_map(serde_json::Value::as_str)
                .map(String::from)
                .collect::<Vec<_>>(),
            None => return Ok(error_result("Missing required parameter: ids")),
        };

        if ids.is_empty() {
            return Ok(error_result("No job IDs specified. Provide at least one ID."));
        }

        let mode_str = get_optional_string(&params, "mode").unwrap_or_else(|| "all".into());
        let mode = match mode_str.as_str() {
            "all" => WaitMode::All,
            "any" => WaitMode::Any,
            other => {
                return Ok(error_result(format!(
                    "Invalid mode '{other}'. Use 'all' or 'any'."
                )));
            }
        };

        let timeout = params
            .get("timeout")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(DEFAULT_TIMEOUT_MS);

        let results = self.job_manager.wait_for_jobs(&ids, mode, timeout).await?;
        let output = format_results(&results);

        Ok(TronToolResult {
            content: ToolResultBody::Text(output),
            details: Some(json!({
                "jobCount": results.len(),
                "completed": results.iter().filter(|r| r.success).count(),
                "failed": results.iter().filter(|r| !r.success).count(),
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

/// Format job results as readable markdown.
fn format_results(results: &[JobResult]) -> String {
    if results.is_empty() {
        return "No results.".into();
    }

    let mut out = String::new();
    for (i, r) in results.iter().enumerate() {
        if i > 0 {
            out.push_str("\n---\n");
        }

        let kind_tag = match r.kind {
            JobKind::Process => "Process",
            JobKind::Agent => "Agent",
        };
        let status = if r.success { "completed" } else { "failed" };

        out.push_str(&format!("### [{kind_tag}] {status} ({id})\n", id = r.id));

        // Kind-specific details.
        match r.kind {
            JobKind::Process => {
                if let Some(ref details) = r.details {
                    if let Some(exit_code) = details.get("exit_code").and_then(|v| v.as_i64()) {
                        out.push_str(&format!("Exit code: {exit_code} | "));
                    }
                }
                out.push_str(&format!("Duration: {:.1}s\n", r.duration_ms as f64 / 1000.0));
            }
            JobKind::Agent => {
                if let Some(ref details) = r.details {
                    if let Some(turns) = details.get("turns").and_then(|v| v.as_u64()) {
                        out.push_str(&format!("Turns: {turns} | "));
                    }
                }
                out.push_str(&format!("Duration: {:.1}s\n", r.duration_ms as f64 / 1000.0));
            }
        }

        if !r.output.is_empty() {
            let display = truncate_tail(&r.output, WAIT_OUTPUT_LIMIT);
            out.push_str(&format!("\n{display}\n"));
        }

        // Show blob reference if full output is stored externally.
        if let Some(ref details) = r.details {
            if let Some(blob) = details.get("blob_id").and_then(|v| v.as_str()) {
                out.push_str(&format!("Full output stored as: {blob}\n"));
            }
        }
    }

    out
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::traits::JobInfo;

    // ── Mock JobManager ──

    struct MockJobManager {
        results: std::sync::Mutex<Vec<JobResult>>,
    }

    impl MockJobManager {
        fn new(results: Vec<JobResult>) -> Self {
            Self {
                results: std::sync::Mutex::new(results),
            }
        }
    }

    #[async_trait]
    impl JobManagerOps for MockJobManager {
        fn list_jobs(&self, _session_id: &str) -> Vec<JobInfo> {
            Vec::new()
        }
        async fn wait_for_jobs(
            &self,
            _ids: &[String],
            _mode: WaitMode,
            _timeout_ms: u64,
        ) -> Result<Vec<JobResult>, ToolError> {
            Ok(self.results.lock().unwrap().clone())
        }
        fn cancel_job(&self, _id: &str, _user_initiated: bool) -> Result<(), ToolError> {
            Ok(())
        }
    }

    fn make_tool_ctx() -> ToolContext {
        crate::tools::testutil::make_ctx()
    }

    #[test]
    fn wait_tool_schema() {
        let jm = Arc::new(MockJobManager::new(vec![]));
        let tool = WaitTool::new(jm);
        assert_eq!(tool.name(), "Wait");
        let def = tool.definition();
        assert_eq!(def.name, "Wait");
        assert!(!def.description.is_empty());
        // Verify parameters contain our expected fields.
        let schema_json = serde_json::to_value(&def.parameters).unwrap();
        let props = &schema_json["properties"];
        assert!(props.get("ids").is_some(), "missing ids param");
        assert!(props.get("mode").is_some(), "missing mode param");
        assert!(props.get("timeout").is_some(), "missing timeout param");
    }

    fn extract_text(result: &TronToolResult) -> String {
        crate::tools::testutil::extract_text(result)
    }

    #[tokio::test]
    async fn execute_empty_ids() {
        let jm = Arc::new(MockJobManager::new(vec![]));
        let tool = WaitTool::new(jm);
        let ctx = make_tool_ctx();

        let result = tool
            .execute(json!({"ids": []}), &ctx)
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert!(extract_text(&result).contains("No job IDs"));
    }

    #[tokio::test]
    async fn execute_missing_ids() {
        let jm = Arc::new(MockJobManager::new(vec![]));
        let tool = WaitTool::new(jm);
        let ctx = make_tool_ctx();

        let result = tool.execute(json!({}), &ctx).await.unwrap();
        assert_eq!(result.is_error, Some(true));
        assert!(extract_text(&result).contains("Missing"));
    }

    #[tokio::test]
    async fn execute_single_process() {
        let jm = Arc::new(MockJobManager::new(vec![JobResult {
            id: "proc-abc".into(),
            kind: JobKind::Process,
            label: "cargo build".into(),
            output: "build ok".into(),
            success: true,
            duration_ms: 5000,
            details: Some(json!({"exit_code": 0})),
        }]));
        let tool = WaitTool::new(jm);
        let ctx = make_tool_ctx();

        let result = tool
            .execute(json!({"ids": ["proc-abc"]}), &ctx)
            .await
            .unwrap();
        match &result.content {
            ToolResultBody::Text(t) => {
                assert!(t.contains("[Process]"));
                assert!(t.contains("proc-abc"));
                assert!(t.contains("build ok"));
                assert!(t.contains("Exit code: 0"));
            }
            _ => panic!("expected text"),
        }
    }

    #[tokio::test]
    async fn execute_single_agent() {
        let jm = Arc::new(MockJobManager::new(vec![JobResult {
            id: "ses-xyz".into(),
            kind: JobKind::Agent,
            label: "Research".into(),
            output: "Found patterns".into(),
            success: true,
            duration_ms: 32000,
            details: Some(json!({"turns": 5})),
        }]));
        let tool = WaitTool::new(jm);
        let ctx = make_tool_ctx();

        let result = tool
            .execute(json!({"ids": ["ses-xyz"]}), &ctx)
            .await
            .unwrap();
        match &result.content {
            ToolResultBody::Text(t) => {
                assert!(t.contains("[Agent]"));
                assert!(t.contains("ses-xyz"));
                assert!(t.contains("Turns: 5"));
                assert!(t.contains("Found patterns"));
            }
            _ => panic!("expected text"),
        }
    }

    #[tokio::test]
    async fn execute_mixed_formatting() {
        let jm = Arc::new(MockJobManager::new(vec![
            JobResult {
                id: "proc-a".into(),
                kind: JobKind::Process,
                label: "build".into(),
                output: "ok".into(),
                success: true,
                duration_ms: 1000,
                details: Some(json!({"exit_code": 0})),
            },
            JobResult {
                id: "ses-b".into(),
                kind: JobKind::Agent,
                label: "research".into(),
                output: "done".into(),
                success: true,
                duration_ms: 5000,
                details: Some(json!({"turns": 3})),
            },
        ]));
        let tool = WaitTool::new(jm);
        let ctx = make_tool_ctx();

        let result = tool
            .execute(json!({"ids": ["proc-a", "ses-b"]}), &ctx)
            .await
            .unwrap();
        match &result.content {
            ToolResultBody::Text(t) => {
                assert!(t.contains("[Process]"));
                assert!(t.contains("[Agent]"));
                assert!(t.contains("---")); // separator between results
            }
            _ => panic!("expected text"),
        }
    }

    #[tokio::test]
    async fn execute_invalid_mode() {
        let jm = Arc::new(MockJobManager::new(vec![]));
        let tool = WaitTool::new(jm);
        let ctx = make_tool_ctx();

        let result = tool
            .execute(json!({"ids": ["proc-a"], "mode": "invalid"}), &ctx)
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert!(extract_text(&result).contains("Invalid mode"));
    }

    #[test]
    fn format_results_empty() {
        assert_eq!(format_results(&[]), "No results.");
    }

    #[test]
    fn format_results_process_with_exit_code() {
        let results = vec![JobResult {
            id: "proc-1".into(),
            kind: JobKind::Process,
            label: "test".into(),
            output: "all passed".into(),
            success: true,
            duration_ms: 2500,
            details: Some(json!({"exit_code": 0})),
        }];
        let output = format_results(&results);
        assert!(output.contains("Exit code: 0"));
        assert!(output.contains("2.5s"));
        assert!(output.contains("all passed"));
    }

    #[test]
    fn format_results_still_running_marker() {
        let results = vec![JobResult {
            id: "proc-slow".into(),
            kind: JobKind::Process,
            label: String::new(),
            output: "[STILL RUNNING after 5000ms]".into(),
            success: false,
            duration_ms: 5000,
            details: None,
        }];
        let output = format_results(&results);
        assert!(output.contains("[STILL RUNNING"));
        assert!(output.contains("failed"));
    }
}
