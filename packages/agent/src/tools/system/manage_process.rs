//! `ManageProcess` tool — list, check, cancel background processes.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ProcessManagerOps, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{get_optional_string, validate_required_string};

/// Tool for managing background processes.
pub struct ManageProcessTool {
    process_manager: Arc<dyn ProcessManagerOps>,
}

impl ManageProcessTool {
    pub fn new(process_manager: Arc<dyn ProcessManagerOps>) -> Self {
        Self { process_manager }
    }
}

#[async_trait]
impl TronTool for ManageProcessTool {
    fn name(&self) -> &str {
        "ManageProcess"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Shell
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "ManageProcess",
            "Manage background processes. Check status, get results, or cancel running processes.",
        )
        .required_property(
            "action",
            json!({
                "type": "string",
                "enum": ["list", "status", "result", "cancel"],
                "description": "Action to perform"
            }),
        )
        .property(
            "processId",
            json!({
                "type": "string",
                "description": "Process ID (required for status, result, cancel)"
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
            "status" => self.handle_status(&params, ctx),
            "result" => self.handle_result(&params),
            "cancel" => self.handle_cancel(&params, ctx),
            other => Ok(error_result(format!(
                "Unknown action: '{other}'. Supported: list, status, result, cancel."
            ))),
        }
    }
}

impl ManageProcessTool {
    fn handle_list(&self, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let processes = self.process_manager.list_processes(&ctx.session_id);
        if processes.is_empty() {
            return Ok(TronToolResult {
                content: ToolResultBody::Text("No active or recent processes.".into()),
                details: Some(json!({"processes": []})),
                is_error: None,
                stop_turn: None,
            });
        }

        let mut lines = Vec::new();
        for p in &processes {
            lines.push(format!(
                "- **{}** (`{}`) — {} ({:.1}s)",
                p.label,
                p.process_id,
                p.state,
                p.elapsed_ms as f64 / 1000.0
            ));
        }

        Ok(TronToolResult {
            content: ToolResultBody::Text(lines.join("\n")),
            details: Some(json!({"processes": processes})),
            is_error: None,
            stop_turn: None,
        })
    }

    fn handle_status(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let process_id = match get_optional_string(params, "processId") {
            Some(id) => id,
            None => return Ok(error_result("Missing 'processId' for status action.")),
        };

        let processes = self.process_manager.list_processes(&ctx.session_id);
        match processes.iter().find(|p| p.process_id == process_id) {
            Some(p) => Ok(TronToolResult {
                content: ToolResultBody::Text(format!(
                    "Process `{}` (`{}`): {} ({:.1}s)",
                    p.label,
                    p.process_id,
                    p.state,
                    p.elapsed_ms as f64 / 1000.0
                )),
                details: Some(json!(p)),
                is_error: None,
                stop_turn: None,
            }),
            None => Ok(error_result(format!("Process not found: {process_id}"))),
        }
    }

    fn handle_result(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let process_id = match get_optional_string(params, "processId") {
            Some(id) => id,
            None => return Ok(error_result("Missing 'processId' for result action.")),
        };

        match self.process_manager.get_result(&process_id) {
            Some(result) => {
                let status = if result.cancelled {
                    "cancelled"
                } else if result.timed_out {
                    "timed out"
                } else if result.exit_code.map_or(false, |c| c != 0) {
                    "failed"
                } else {
                    "completed"
                };

                let mut text = format!("Process `{process_id}` {status}");
                if let Some(code) = result.exit_code {
                    text.push_str(&format!(" (exit code {code})"));
                }
                text.push_str(&format!(" in {:.1}s", result.duration_ms as f64 / 1000.0));
                if !result.output.is_empty() {
                    text.push_str(&format!("\n\nOutput:\n```\n{}\n```", result.output));
                }
                if let Some(ref blob_id) = result.blob_id {
                    text.push_str(&format!("\n\nFull output: `{blob_id}`"));
                }

                Ok(TronToolResult {
                    content: ToolResultBody::Text(text),
                    details: Some(json!(result)),
                    is_error: None,
                    stop_turn: None,
                })
            }
            None => Ok(TronToolResult {
                content: ToolResultBody::Text(format!(
                    "Process `{process_id}` is still running or not found."
                )),
                details: None,
                is_error: None,
                stop_turn: None,
            }),
        }
    }

    fn handle_cancel(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let process_id = match get_optional_string(params, "processId") {
            Some(id) => id,
            None => return Ok(error_result("Missing 'processId' for cancel action.")),
        };

        match self.process_manager.cancel_process(&process_id) {
            Ok(()) => Ok(TronToolResult {
                content: ToolResultBody::Text(format!("Process `{process_id}` cancelled.")),
                details: Some(json!({"processId": process_id, "cancelled": true})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Failed to cancel: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::orchestrator::process_manager::ProcessManager;
    use crate::tools::testutil::make_ctx;
    use crate::tools::traits::ProcessKind;

    fn make_pm_ctx() -> (Arc<ProcessManager>, ToolContext) {
        let pm = Arc::new(ProcessManager::new());
        let mut ctx = make_ctx();
        ctx.process_manager = Some(pm.clone());
        (pm, ctx)
    }

    fn boxed_delayed(ms: u64, output: &str) -> std::pin::Pin<Box<dyn std::future::Future<Output = crate::tools::traits::ManagedProcessResult> + Send>> {
        let output = output.to_owned();
        Box::pin(async move {
            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            crate::tools::traits::ManagedProcessResult {
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

    // ── Schema ──

    #[test]
    fn manage_process_schema_has_action_enum() {
        let pm = Arc::new(ProcessManager::new());
        let tool = ManageProcessTool::new(pm);
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        assert!(props.contains_key("action"));
        assert!(props.contains_key("processId"));
        let required = def.parameters.required.as_ref().unwrap();
        assert!(required.contains(&"action".to_string()));
    }

    #[test]
    fn manage_process_name_and_category() {
        let pm = Arc::new(ProcessManager::new());
        let tool = ManageProcessTool::new(pm);
        assert_eq!(tool.name(), "ManageProcess");
        assert_eq!(tool.category(), ToolCategory::Shell);
    }

    // ── List ──

    #[tokio::test]
    async fn manage_process_list_empty_session() {
        let (pm, ctx) = make_pm_ctx();
        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "list"}), &ctx).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn manage_process_list_returns_processes() {
        let (pm, ctx) = make_pm_ctx();

        let config = crate::tools::traits::ManagedProcessConfig {
            label: "test-cmd".into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            sandbox: false,
        };
        let _ = pm.spawn_managed("sess-1", "tc1", config, boxed_delayed(5000, "ok"), true).await.unwrap();

        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "list"}), &ctx).await.unwrap();
        let text = match &r.content {
            ToolResultBody::Text(t) => t.clone(),
            _ => String::new(),
        };
        assert!(text.contains("test-cmd"));
    }

    // ── Status ──

    #[tokio::test]
    async fn manage_process_status_not_found() {
        let (pm, ctx) = make_pm_ctx();
        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "status", "processId": "proc-nope"}), &ctx).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn manage_process_status_missing_id() {
        let (pm, ctx) = make_pm_ctx();
        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "status"}), &ctx).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    // ── Result ──

    #[tokio::test]
    async fn manage_process_result_still_running() {
        let (pm, ctx) = make_pm_ctx();
        let config = crate::tools::traits::ManagedProcessConfig {
            label: "slow".into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            sandbox: false,
        };
        let h = pm.spawn_managed("sess-1", "tc1", config, boxed_delayed(5000, "ok"), true).await.unwrap();

        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "result", "processId": h.process_id}), &ctx).await.unwrap();
        let text = match &r.content {
            ToolResultBody::Text(t) => t.clone(),
            _ => String::new(),
        };
        assert!(text.contains("still running"));
    }

    #[tokio::test]
    async fn manage_process_result_completed() {
        let (pm, ctx) = make_pm_ctx();
        let config = crate::tools::traits::ManagedProcessConfig {
            label: "fast".into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            sandbox: false,
        };
        let h = pm.spawn_managed("sess-1", "tc1", config, boxed_delayed(10, "done"), true).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "result", "processId": h.process_id}), &ctx).await.unwrap();
        let text = match &r.content {
            ToolResultBody::Text(t) => t.clone(),
            _ => String::new(),
        };
        assert!(text.contains("completed"));
        assert!(text.contains("done"));
    }

    // ── Cancel ──

    #[tokio::test]
    async fn manage_process_cancel_running() {
        let (pm, ctx) = make_pm_ctx();
        let config = crate::tools::traits::ManagedProcessConfig {
            label: "cancellable".into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            sandbox: false,
        };
        let h = pm.spawn_managed("sess-1", "tc1", config, boxed_delayed(5000, "ok"), true).await.unwrap();

        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "cancel", "processId": h.process_id}), &ctx).await.unwrap();
        assert!(r.is_error.is_none());
        let text = match &r.content {
            ToolResultBody::Text(t) => t.clone(),
            _ => String::new(),
        };
        assert!(text.contains("cancelled"));
    }

    #[tokio::test]
    async fn manage_process_cancel_not_found() {
        let (pm, ctx) = make_pm_ctx();
        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "cancel", "processId": "proc-nope"}), &ctx).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    // ── Validation ──

    #[tokio::test]
    async fn manage_process_unknown_action() {
        let (pm, ctx) = make_pm_ctx();
        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({"action": "foo"}), &ctx).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn manage_process_missing_action() {
        let (pm, ctx) = make_pm_ctx();
        let tool = ManageProcessTool::new(pm);
        let r = tool.execute(json!({}), &ctx).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
