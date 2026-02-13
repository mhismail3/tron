//! `WaitForAgents` tool — waits for subagent completion.
//!
//! Waits for one or more subagent sessions to complete, with configurable
//! mode (all/any) and timeout.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{SubagentSpawner, ToolContext, TronTool, WaitMode};
use crate::utils::validation::get_optional_string;

const DEFAULT_TIMEOUT_MS: u64 = 300_000; // 5 minutes

/// The `WaitForAgents` tool waits for subagent sessions to complete.
pub struct WaitForAgentsTool {
    spawner: Arc<dyn SubagentSpawner>,
}

impl WaitForAgentsTool {
    /// Create a new `WaitForAgents` tool with the given spawner.
    pub fn new(spawner: Arc<dyn SubagentSpawner>) -> Self {
        Self { spawner }
    }
}

#[async_trait]
impl TronTool for WaitForAgentsTool {
    fn name(&self) -> &str {
        "WaitForAgents"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "WaitForAgents".into(),
            description: "Wait for one or more subagent sessions to complete.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("sessionIds".into(), json!({"type": "array", "items": {"type": "string"}, "description": "Session IDs to wait for"}));
                    let _ = m.insert("mode".into(), json!({"type": "string", "enum": ["all", "any"], "description": "Wait mode: all or any (default: all)"}));
                    let _ = m.insert("timeout".into(), json!({"type": "number", "description": "Timeout in milliseconds (default: 300000)"}));
                    m
                }),
                required: Some(vec!["sessionIds".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let session_ids = match params.get("sessionIds").and_then(Value::as_array) {
            Some(arr) => arr
                .iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect::<Vec<_>>(),
            None => return Ok(error_result("Missing required parameter: sessionIds")),
        };

        if session_ids.is_empty() {
            return Ok(error_result("sessionIds must contain at least one session ID"));
        }

        let mode_str = get_optional_string(&params, "mode").unwrap_or_else(|| "all".into());
        let mode = match mode_str.as_str() {
            "all" => WaitMode::All,
            "any" => WaitMode::Any,
            _ => return Ok(error_result(format!(
                "Invalid mode: \"{mode_str}\". Must be \"all\" or \"any\"."
            ))),
        };

        let timeout_ms = params
            .get("timeout")
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_TIMEOUT_MS);

        match self
            .spawner
            .wait_for_agents(&session_ids, mode.clone(), timeout_ms)
            .await
        {
            Ok(results) => {
                let summary = results
                    .iter()
                    .map(|r| {
                        let truncated = if r.output.len() > 200 {
                            format!("{}...", &r.output[..200])
                        } else {
                            r.output.clone()
                        };
                        format!(
                            "[{}] {} ({}ms): {}",
                            r.status, r.session_id, r.duration_ms, truncated
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n");

                let details: Vec<Value> = results
                    .iter()
                    .map(|r| {
                        json!({
                            "sessionId": r.session_id,
                            "status": r.status,
                            "durationMs": r.duration_ms,
                            "tokenUsage": r.token_usage,
                        })
                    })
                    .collect();

                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(summary),
                    ]),
                    details: Some(json!({
                        "mode": mode,
                        "results": details,
                    })),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(error_result(format!("Wait failed: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{SubagentConfig, SubagentHandle, SubagentResult};

    struct MockSpawner {
        should_fail: bool,
    }

    impl MockSpawner {
        fn success() -> Self {
            Self { should_fail: false }
        }

        fn failing() -> Self {
            Self { should_fail: true }
        }
    }

    #[async_trait]
    impl SubagentSpawner for MockSpawner {
        async fn spawn(&self, _config: SubagentConfig) -> Result<SubagentHandle, ToolError> {
            Ok(SubagentHandle {
                session_id: "sub-1".into(),
                output: None,
                token_usage: None,
            })
        }

        async fn query_agent(
            &self,
            _session_id: &str,
            _query_type: &str,
            _limit: Option<u32>,
        ) -> Result<Value, ToolError> {
            Ok(json!({}))
        }

        async fn wait_for_agents(
            &self,
            session_ids: &[String],
            _mode: WaitMode,
            _timeout_ms: u64,
        ) -> Result<Vec<SubagentResult>, ToolError> {
            if self.should_fail {
                return Err(ToolError::Timeout {
                    timeout_ms: 300_000,
                });
            }
            Ok(session_ids
                .iter()
                .map(|sid| SubagentResult {
                    session_id: sid.clone(),
                    output: "done".into(),
                    token_usage: Some(json!({"input": 10})),
                    duration_ms: 1000,
                    status: "completed".into(),
                })
                .collect())
        }
    }

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
        }
    }

    fn extract_text(result: &TronToolResult) -> String {
        match &result.content {
            ToolResultBody::Text(t) => t.clone(),
            ToolResultBody::Blocks(blocks) => blocks
                .iter()
                .filter_map(|b| match b {
                    tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join(""),
        }
    }

    #[tokio::test]
    async fn wait_all_mode() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"sessionIds": ["sub-1", "sub-2"]}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("sub-1"));
        assert!(text.contains("sub-2"));
    }

    #[tokio::test]
    async fn wait_any_mode() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"sessionIds": ["sub-1"], "mode": "any"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn default_mode_is_all() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionIds": ["sub-1"]}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["mode"], "all");
    }

    #[tokio::test]
    async fn custom_timeout() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"sessionIds": ["sub-1"], "timeout": 60000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn missing_session_ids_error() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn empty_session_ids_error() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionIds": []}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_mode_error() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"sessionIds": ["sub-1"], "mode": "invalid"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn wait_failure() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::failing()));
        let r = tool
            .execute(json!({"sessionIds": ["sub-1"]}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Wait failed"));
    }

    #[tokio::test]
    async fn results_include_details() {
        let tool = WaitForAgentsTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionIds": ["sub-1"]}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        let results = d["results"].as_array().unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["sessionId"], "sub-1");
        assert_eq!(results[0]["status"], "completed");
    }
}
