//! `QueryAgent` tool — queries a running subagent.
//!
//! Queries the status, events, logs, or output of a subagent session.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{SubagentSpawner, ToolContext, TronTool};
use crate::utils::validation::{get_optional_u64, validate_required_string};

const VALID_QUERY_TYPES: &[&str] = &["status", "events", "logs", "output"];
const DEFAULT_LIMIT: u32 = 20;

/// The `QueryAgent` tool queries a running or completed subagent.
pub struct QueryAgentTool {
    spawner: Arc<dyn SubagentSpawner>,
}

impl QueryAgentTool {
    /// Create a new `QueryAgent` tool with the given spawner.
    pub fn new(spawner: Arc<dyn SubagentSpawner>) -> Self {
        Self { spawner }
    }
}

#[async_trait]
impl TronTool for QueryAgentTool {
    fn name(&self) -> &str {
        "QueryAgent"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "QueryAgent".into(),
            description: "Query the status, events, logs, or output of a spawned sub-agent.\n\n\
                Query types:\n\
                - **status**: Get current status (running/completed/failed), turn count, token usage, and task\n\
                - **events**: Get recent events from the sub-agent session\n\
                - **logs**: Get log entries from the sub-agent session\n\
                - **output**: Get the final assistant response (only available when completed)\n\n\
                Use this to monitor sub-agents you've spawned with SpawnSubagent.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("sessionId".into(), json!({"type": "string", "description": "Session ID of the subagent"}));
                    let _ = m.insert("queryType".into(), json!({"type": "string", "enum": VALID_QUERY_TYPES, "description": "Type of query"}));
                    let _ = m.insert("limit".into(), json!({"type": "number", "description": "Limit number of results (default: 20)"}));
                    m
                }),
                required: Some(vec!["sessionId".into(), "queryType".into()]),
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
        let session_id = match validate_required_string(&params, "sessionId", "session ID") {
            Ok(s) => s,
            Err(e) => return Ok(e),
        };

        let query_type = match validate_required_string(&params, "queryType", "query type") {
            Ok(q) => q,
            Err(e) => return Ok(e),
        };

        if !VALID_QUERY_TYPES.contains(&query_type.as_str()) {
            return Ok(error_result(format!(
                "Invalid queryType: \"{query_type}\". Valid types: {}",
                VALID_QUERY_TYPES.join(", ")
            )));
        }

        #[allow(clippy::cast_possible_truncation)]
        let limit = get_optional_u64(&params, "limit").map_or(DEFAULT_LIMIT, |v| v as u32);

        match self
            .spawner
            .query_agent(&session_id, &query_type, Some(limit))
            .await
        {
            Ok(result) => {
                let output = serde_json::to_string_pretty(&result)
                    .unwrap_or_else(|_| result.to_string());
                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(output),
                    ]),
                    details: Some(json!({
                        "sessionId": session_id,
                        "queryType": query_type,
                    })),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(error_result(format!("Query failed: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{SubagentConfig, SubagentHandle, SubagentResult, WaitMode};

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
            session_id: &str,
            query_type: &str,
            _limit: Option<u32>,
        ) -> Result<Value, ToolError> {
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "query failed".into(),
                });
            }
            Ok(json!({
                "sessionId": session_id,
                "queryType": query_type,
                "data": "result"
            }))
        }

        async fn wait_for_agents(
            &self,
            _session_ids: &[String],
            _mode: WaitMode,
            _timeout_ms: u64,
        ) -> Result<Vec<SubagentResult>, ToolError> {
            Ok(vec![])
        }
    }

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
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
    async fn status_query() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionId": "sub-1", "queryType": "status"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("status"));
    }

    #[tokio::test]
    async fn events_query() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionId": "sub-1", "queryType": "events"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn logs_query() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionId": "sub-1", "queryType": "logs"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn output_query() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionId": "sub-1", "queryType": "output"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn missing_session_id_error() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"queryType": "status"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_query_type_error() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionId": "sub-1"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_query_type_error() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"sessionId": "sub-1", "queryType": "invalid"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid queryType"));
    }

    #[tokio::test]
    async fn limit_forwarded() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"sessionId": "sub-1", "queryType": "events", "limit": 5}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn query_failure() {
        let tool = QueryAgentTool::new(Arc::new(MockSpawner::failing()));
        let r = tool
            .execute(json!({"sessionId": "sub-1", "queryType": "status"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Query failed"));
    }
}
