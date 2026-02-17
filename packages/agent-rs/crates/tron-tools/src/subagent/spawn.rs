//! `SpawnSubagent` tool — launches child agent sessions.
//!
//! Spawns a subagent with the given task, mode, and configuration.
//! Supports blocking (wait for result) and non-blocking (return session ID) modes.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{SubagentConfig, SubagentMode, SubagentSpawner, ToolContext, TronTool};
use crate::utils::validation::{get_optional_bool, get_optional_string, get_optional_u64, validate_required_string};

const DEFAULT_TIMEOUT_MS: u64 = 1_800_000; // 30 minutes
const DEFAULT_MAX_TURNS_IN_PROCESS: u32 = 50;
const DEFAULT_MAX_TURNS_TMUX: u32 = 100;

/// The `SpawnSubagent` tool launches child agent sessions.
pub struct SpawnSubagentTool {
    spawner: Arc<dyn SubagentSpawner>,
}

impl SpawnSubagentTool {
    /// Create a new `SpawnSubagent` tool with the given spawner.
    pub fn new(spawner: Arc<dyn SubagentSpawner>) -> Self {
        Self { spawner }
    }
}

#[async_trait]
impl TronTool for SpawnSubagentTool {
    fn name(&self) -> &str {
        "SpawnSubagent"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "SpawnSubagent".into(),
            description: "Spawn an agent to handle a specific task. Supports two execution modes:\n\n\
**1. In-Process Mode (default):**\n\
- Runs in the same process, sharing the event store\n\
- **Blocking by default**: Waits for completion and returns full results\n\
- Efficient for quick tasks (< 5 minutes)\n\
- Use `blocking: false` for fire-and-forget\n\n\
**2. Tmux Mode:**\n\
- Runs in a separate tmux session with its own process\n\
- Always fire-and-forget (returns immediately)\n\
- Persists beyond this conversation\n\
- Best for long-running tasks (hours/days)\n\n\
Parameters:\n\
- **task**: The task description for the agent (required)\n\
- **mode**: 'inProcess' (default) or 'tmux'\n\
- **blocking**: If true (default), waits for completion (inProcess only)\n\
- **timeout**: Max wait time in ms (default: 30 minutes, inProcess only)\n\
- **model**, **systemPrompt**, **toolDenials**, **skills**, **workingDirectory**, **maxTurns**: Optional overrides\n\
- **toolDenials**: Deny tools/patterns. Use { denyAll: true } for text-only agents\n\n\
Returns (when mode=inProcess and blocking=true):\n\
- Full output from the agent\n\
- Token usage and duration statistics\n\
- Success/failure status".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("task".into(), json!({"type": "string", "description": "Task/prompt for the subagent"}));
                    let _ = m.insert("mode".into(), json!({"type": "string", "enum": ["inProcess", "tmux"], "description": "Execution mode"}));
                    let _ = m.insert("model".into(), json!({"type": "string", "description": "Override model for the subagent"}));
                    let _ = m.insert("systemPrompt".into(), json!({"type": "string", "description": "Custom system prompt"}));
                    let _ = m.insert("toolDenials".into(), json!({"type": "object", "description": "Tool denial configuration"}));
                    let _ = m.insert("skills".into(), json!({"type": "array", "items": {"type": "string"}, "description": "Skills to enable"}));
                    let _ = m.insert("workingDirectory".into(), json!({"type": "string", "description": "Working directory"}));
                    let _ = m.insert("maxTurns".into(), json!({"type": "number", "description": "Maximum turns before stopping"}));
                    let _ = m.insert("blocking".into(), json!({"type": "boolean", "description": "Whether to wait for completion"}));
                    let _ = m.insert("timeout".into(), json!({"type": "number", "description": "Timeout in milliseconds when blocking"}));
                    let _ = m.insert("maxDepth".into(), json!({"type": "number", "description": "Maximum nesting depth for child subagents (0 = no children)"}));
                    m
                }),
                required: Some(vec!["task".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        params: Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let task = match validate_required_string(&params, "task", "task description") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let mode_str = get_optional_string(&params, "mode").unwrap_or_else(|| "inProcess".into());
        let mode = match mode_str.as_str() {
            "inProcess" => SubagentMode::InProcess,
            "tmux" => SubagentMode::Tmux,
            _ => return Ok(error_result(format!(
                "Invalid mode: \"{mode_str}\". Must be \"inProcess\" or \"tmux\"."
            ))),
        };

        let blocking = get_optional_bool(&params, "blocking").unwrap_or(mode == SubagentMode::InProcess);
        let timeout_ms = get_optional_u64(&params, "timeout").unwrap_or(DEFAULT_TIMEOUT_MS);
        let default_turns = if mode == SubagentMode::Tmux {
            DEFAULT_MAX_TURNS_TMUX
        } else {
            DEFAULT_MAX_TURNS_IN_PROCESS
        };
        #[allow(clippy::cast_possible_truncation)]
        let max_turns = get_optional_u64(&params, "maxTurns")
            .map_or(default_turns, |v| v as u32);

        let model = get_optional_string(&params, "model");
        let system_prompt = get_optional_string(&params, "systemPrompt");
        let working_directory = get_optional_string(&params, "workingDirectory")
            .unwrap_or_else(|| ctx.working_directory.clone());
        let tool_denials = params.get("toolDenials").cloned();
        let skills = params
            .get("skills")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(Value::as_str)
                    .map(String::from)
                    .collect()
            });

        // Remaining depth budget from context
        let remaining_depth = ctx.subagent_max_depth.saturating_sub(1);
        // LLM-provided maxDepth caps the remaining budget (default = remaining)
        #[allow(clippy::cast_possible_truncation)]
        let user_max_depth = get_optional_u64(&params, "maxDepth")
            .map_or(remaining_depth, |v| (v as u32).min(remaining_depth));

        let config = SubagentConfig {
            task: task.clone(),
            mode: mode.clone(),
            blocking,
            model,
            parent_session_id: Some(ctx.session_id.clone()),
            system_prompt,
            working_directory,
            max_turns,
            timeout_ms,
            tool_denials,
            skills,
            max_depth: user_max_depth,
            current_depth: ctx.subagent_depth + 1,
            tool_call_id: Some(ctx.tool_call_id.clone()),
        };

        match self.spawner.spawn(config).await {
            Ok(handle) => {
                if blocking {
                    let output = handle.output.unwrap_or_default();
                    Ok(TronToolResult {
                        content: ToolResultBody::Blocks(vec![
                            tron_core::content::ToolResultContent::text(&output),
                        ]),
                        details: Some(json!({
                            "sessionId": handle.session_id,
                            "blocking": true,
                            "tokenUsage": handle.token_usage,
                        })),
                        is_error: None,
                        stop_turn: None,
                    })
                } else {
                    Ok(TronToolResult {
                        content: ToolResultBody::Blocks(vec![
                            tron_core::content::ToolResultContent::text(
                                format!("Subagent spawned (session: {})", handle.session_id),
                            ),
                        ]),
                        details: Some(json!({
                            "sessionId": handle.session_id,
                            "success": true,
                            "blocking": false,
                        })),
                        is_error: None,
                        stop_turn: None,
                    })
                }
            }
            Err(e) => Ok(error_result(format!("Failed to spawn subagent: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{SubagentHandle, SubagentResult, WaitMode};

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
        async fn spawn(&self, config: SubagentConfig) -> Result<SubagentHandle, ToolError> {
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "spawn failed".into(),
                });
            }
            Ok(SubagentHandle {
                session_id: "sub-1".into(),
                output: if config.blocking {
                    Some("task completed".into())
                } else {
                    None
                },
                token_usage: if config.blocking {
                    Some(json!({"input": 100, "output": 50}))
                } else {
                    None
                },
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
    async fn blocking_in_process_default() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("task completed"));
        let d = r.details.unwrap();
        assert_eq!(d["blocking"], true);
        assert_eq!(d["sessionId"], "sub-1");
    }

    #[tokio::test]
    async fn non_blocking_returns_session_id() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something", "blocking": false}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("sub-1"));
        let d = r.details.unwrap();
        assert_eq!(d["blocking"], false);
        assert_eq!(d["success"], true);
    }

    #[tokio::test]
    async fn tmux_mode() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something", "mode": "tmux", "blocking": false}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn invalid_mode_error() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something", "mode": "invalid"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid mode"));
    }

    #[tokio::test]
    async fn missing_task_error() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn model_override_forwarded() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"task": "t", "model": "claude-sonnet-4-5-20250929"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn system_prompt_forwarded() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "t", "systemPrompt": "Be helpful"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn working_directory_defaults_to_ctx() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "t"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn skills_forwarded() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "t", "skills": ["skill1", "skill2"]}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn tool_denials_forwarded() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "t", "toolDenials": {"denyAll": true}}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn spawn_failure() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::failing()));
        let r = tool
            .execute(json!({"task": "t"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Failed to spawn"));
    }

    #[tokio::test]
    async fn token_usage_in_blocking_result() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "t"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["tokenUsage"].is_object());
    }

    // ── Depth propagation tests ──

    struct CapturingSpawner {
        captured: std::sync::Mutex<Option<SubagentConfig>>,
    }

    impl CapturingSpawner {
        fn new() -> Self {
            Self {
                captured: std::sync::Mutex::new(None),
            }
        }
        fn captured_config(&self) -> SubagentConfig {
            self.captured.lock().unwrap().clone().unwrap()
        }
    }

    #[async_trait]
    impl SubagentSpawner for CapturingSpawner {
        async fn spawn(&self, config: SubagentConfig) -> Result<SubagentHandle, ToolError> {
            *self.captured.lock().unwrap() = Some(config.clone());
            Ok(SubagentHandle {
                session_id: "sub-cap".into(),
                output: if config.blocking { Some("done".into()) } else { None },
                token_usage: None,
            })
        }
        async fn query_agent(&self, _: &str, _: &str, _: Option<u32>) -> Result<Value, ToolError> {
            Ok(json!({}))
        }
        async fn wait_for_agents(&self, _: &[String], _: WaitMode, _: u64) -> Result<Vec<SubagentResult>, ToolError> {
            Ok(vec![])
        }
    }

    fn make_ctx_with_depth(depth: u32, max_depth: u32) -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: depth,
            subagent_max_depth: max_depth,
        }
    }

    #[tokio::test]
    async fn spawn_root_agent_depth_zero() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let ctx = make_ctx_with_depth(0, 3);
        let _ = tool.execute(json!({"task": "t"}), &ctx).await.unwrap();
        let config = spawner.captured_config();
        assert_eq!(config.current_depth, 1, "child depth = parent + 1");
        assert_eq!(config.max_depth, 2, "child max_depth = parent_max - 1");
    }

    #[tokio::test]
    async fn spawn_reads_depth_from_context() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let ctx = make_ctx_with_depth(1, 2);
        let _ = tool.execute(json!({"task": "t"}), &ctx).await.unwrap();
        let config = spawner.captured_config();
        assert_eq!(config.current_depth, 2, "child depth = 1 + 1");
        assert_eq!(config.max_depth, 1, "child max_depth = 2 - 1");
    }

    #[tokio::test]
    async fn spawn_at_max_depth_gives_zero_remaining() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let ctx = make_ctx_with_depth(2, 1);
        let _ = tool.execute(json!({"task": "t"}), &ctx).await.unwrap();
        let config = spawner.captured_config();
        assert_eq!(config.current_depth, 3);
        assert_eq!(config.max_depth, 0, "no more nesting allowed");
    }

    #[tokio::test]
    async fn spawn_user_max_depth_caps_remaining() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let ctx = make_ctx_with_depth(0, 5);
        let _ = tool
            .execute(json!({"task": "t", "maxDepth": 1}), &ctx)
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert_eq!(config.max_depth, 1, "user cap of 1 < remaining 4");
    }

    #[tokio::test]
    async fn spawn_user_max_depth_cannot_exceed_remaining() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let ctx = make_ctx_with_depth(0, 2);
        let _ = tool
            .execute(json!({"task": "t", "maxDepth": 10}), &ctx)
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert_eq!(config.max_depth, 1, "capped to remaining depth (2-1=1)");
    }

    #[tokio::test]
    async fn spawn_sets_parent_session_id_from_context() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let ctx = make_ctx(); // session_id = "sess-1"
        let _ = tool.execute(json!({"task": "t"}), &ctx).await.unwrap();
        let config = spawner.captured_config();
        assert_eq!(
            config.parent_session_id,
            Some("sess-1".to_string()),
            "parent_session_id should come from ToolContext.session_id"
        );
    }
}
