//! `ManageAutomations` tool — cron job management.
//!
//! Routes automation actions to the [`CronDelegate`] trait. Supports
//! 8 actions for creating, managing, and monitoring scheduled jobs.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::errors::ToolError;
use crate::traits::{CronDelegate, ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
use crate::utils::validation::validate_required_string;

const VALID_ACTIONS: &[&str] = &[
    "list",
    "get",
    "create",
    "update",
    "delete",
    "trigger",
    "status",
    "get_runs",
];

/// The `ManageAutomations` tool manages scheduled cron jobs.
pub struct ManageAutomationsTool {
    delegate: Arc<dyn CronDelegate>,
}

impl ManageAutomationsTool {
    /// Create a new `ManageAutomations` tool with the given delegate.
    pub fn new(delegate: Arc<dyn CronDelegate>) -> Self {
        Self { delegate }
    }
}

#[async_trait]
impl TronTool for ManageAutomationsTool {
    fn name(&self) -> &str {
        "ManageAutomations"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "ManageAutomations",
            "Manage scheduled automations (cron jobs) that run on a timer. Automations execute \
payloads (shell commands, agent turns, webhooks, or system events) on a schedule and \
deliver results via WebSocket, push notification, or webhook.\n\n\
## IMPORTANT: Use AskUserQuestion to Clarify\n\
Before creating or updating automations, use the AskUserQuestion tool to confirm details \
the user hasn't specified. Key questions to ask:\n\
- **Schedule**: What time/frequency? What timezone? (Default to user's local timezone, not UTC)\n\
- **Payload type**: Shell command vs agent turn vs webhook?\n\
- **Specific payload details**: What command to run? What prompt for the agent?\n\
- **Delivery**: Should results be pushed to their phone (apns), shown silently, or sent to a webhook?\n\
- **Failure handling**: What to do on overlap or misfire?\n\n\
Only skip asking if the user has been completely explicit about all parameters.\n\n\
## Best Practices\n\
- Use `list` first to check for existing automations before creating duplicates\n\
- Confirm with the user before `delete` — it cannot be undone\n\
- After `create`, summarize what was created (name, schedule in human-readable form, payload)\n\
- For `agentTurn` payloads, write clear, detailed prompts — the agent session runs without user interaction\n\
- Prefer cron expressions with timezones for time-of-day schedules; use interval for polling-style jobs\n\n\
## Schedule Types\n\
- **cron**: Standard 5-field cron expression with timezone (e.g. \"0 9 * * 1-5\" = weekdays at 9am)\n\
- **every**: Fixed interval in seconds (min 10). E.g. 3600 = every hour\n\
- **oneShot**: Fire once at a specific ISO 8601 datetime, then auto-disable\n\n\
## Payload Types\n\
- **agentTurn**: Run an isolated agent session with a prompt (most powerful — can use all tools)\n\
- **shellCommand**: Execute a shell command with optional working directory and timeout\n\
- **webhook**: Make an HTTP request (GET/POST/PUT/PATCH/DELETE) with optional headers and body\n\
- **systemEvent**: Inject a message into an existing session by session ID\n\n\
## Delivery Options\n\
- **silent**: No notification (default)\n\
- **websocket**: Push result to connected clients in real-time\n\
- **apns**: Send push notification to user's phone\n\
- **webhook**: POST result to a URL\n\n\
## Actions\n\n\
- **list**: List automations. Optional: enabled (bool), tags (string[]), workspaceId\n\
- **get**: Get automation details + runtime state + recent runs. Required: jobId\n\
- **create**: Create automation. Required: name, schedule, payload. Optional: description, \
delivery, overlapPolicy, misfirePolicy, maxRetries, autoDisableAfter, tags, workspaceId\n\
- **update**: Partial-update automation. Required: jobId. Optional: any job field\n\
- **delete**: Delete automation (preserves run history). Required: jobId\n\
- **trigger**: Trigger immediate execution. Required: jobId\n\
- **status**: Get scheduler health (job count, active runs, next wakeup)\n\
- **get_runs**: Get paginated run history. Required: jobId. Optional: limit, offset, status\n\n\
## Schedule Format Examples\n\
- Cron: `{\"type\": \"cron\", \"expression\": \"0 9 * * 1-5\", \"timezone\": \"America/New_York\"}`\n\
- Interval: `{\"type\": \"every\", \"intervalSecs\": 3600}`\n\
- One-shot: `{\"type\": \"oneShot\", \"at\": \"2025-03-01T12:00:00Z\"}`\n\n\
## Payload Format Examples\n\
- Shell: `{\"type\": \"shellCommand\", \"command\": \"echo hello\", \"timeoutSecs\": 300}`\n\
- Agent: `{\"type\": \"agentTurn\", \"prompt\": \"Summarize today's logs\"}`\n\
- Webhook: `{\"type\": \"webhook\", \"url\": \"https://...\", \"method\": \"POST\"}`\n\n\
## Delivery Format Examples\n\
- Silent: `[]` (empty array or omit)\n\
- Push + WebSocket: `[{\"type\": \"apns\"}, {\"type\": \"websocket\"}]`\n\
- Webhook: `[{\"type\": \"webhook\", \"url\": \"https://...\"}]`",
        )
        .required_property("action", json!({
            "type": "string",
            "enum": VALID_ACTIONS,
            "description": "The automation management action to perform"
        }))
        .property("jobId", json!({"type": "string", "description": "Job ID (required for get, update, delete, trigger, get_runs)"}))
        .property("name", json!({"type": "string", "description": "Job name (required for create)"}))
        .property("description", json!({"type": "string"}))
        .property("enabled", json!({"type": "boolean"}))
        .property("schedule", json!({"type": "object", "description": "Schedule definition (required for create)"}))
        .property("payload", json!({"type": "object", "description": "Payload definition (required for create)"}))
        .property("delivery", json!({"type": "array", "items": {"type": "object"}, "description": "Delivery targets (silent, webSocket, apns, webhook)"}))
        .property("overlapPolicy", json!({"type": "string", "enum": ["skip", "allow"]}))
        .property("misfirePolicy", json!({"type": "string", "enum": ["skip", "runOnce"]}))
        .property("maxRetries", json!({"type": "number"}))
        .property("autoDisableAfter", json!({"type": "number"}))
        .property("tags", json!({"type": "array", "items": {"type": "string"}}))
        .property("workspaceId", json!({"type": "string"}))
        .property("limit", json!({"type": "number"}))
        .property("offset", json!({"type": "number"}))
        .property("status", json!({"type": "string", "description": "Filter runs by status (for get_runs)"}))
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "automation action") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        if !VALID_ACTIONS.contains(&action.as_str()) {
            return Ok(error_result(format!(
                "Invalid action: \"{action}\". Valid actions: {}",
                VALID_ACTIONS.join(", ")
            )));
        }

        match self.delegate.execute_action(&action, params.clone()).await {
            Ok(result) => {
                let output =
                    serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string());
                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(output),
                    ]),
                    details: Some(json!({"action": action})),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(error_result(format!("ManageAutomations error: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{extract_text, make_ctx};

    struct MockDelegate;

    #[async_trait]
    impl CronDelegate for MockDelegate {
        async fn execute_action(&self, action: &str, _params: Value) -> Result<Value, ToolError> {
            Ok(json!({"action": action, "success": true}))
        }
    }

    struct ErrorDelegate;

    #[async_trait]
    impl CronDelegate for ErrorDelegate {
        async fn execute_action(&self, _action: &str, _params: Value) -> Result<Value, ToolError> {
            Err(ToolError::Internal {
                message: "delegate error".into(),
            })
        }
    }

    #[tokio::test]
    async fn list_action() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "list"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("list"));
    }

    #[tokio::test]
    async fn create_action() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(
                json!({
                    "action": "create",
                    "name": "Test",
                    "schedule": {"type": "every", "intervalSecs": 60},
                    "payload": {"type": "shellCommand", "command": "echo hi"},
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn get_action() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "get", "jobId": "cron_1"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn all_actions_dispatch() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        for action in VALID_ACTIONS {
            let r = tool
                .execute(json!({"action": action}), &make_ctx())
                .await
                .unwrap();
            assert!(r.is_error.is_none(), "Action {action} failed");
        }
    }

    #[tokio::test]
    async fn missing_action_error() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_action_error() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "invalid"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid action"));
    }

    #[tokio::test]
    async fn delegate_error() {
        let tool = ManageAutomationsTool::new(Arc::new(ErrorDelegate));
        let r = tool
            .execute(json!({"action": "create"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn trigger_action() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "trigger", "jobId": "cron_1"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn status_action() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "status"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn get_runs_action() {
        let tool = ManageAutomationsTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(
                json!({"action": "get_runs", "jobId": "cron_1", "limit": 10}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }
}
