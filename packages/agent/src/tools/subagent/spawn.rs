//! `SpawnSubagent` tool — launches child agent sessions.
//!
//! Spawns a subagent with the given task, mode, and configuration.
//! Supports blocking (wait for result within timeout) and non-blocking (return session ID) modes.
//!
//! Tool restrictions: `deniedTools` (string array) removes named tools from the
//! subagent's registry. `denyAllTools` (boolean) removes all tools for text-only
//! agents. Both are hard-enforced via `AgentFactory` registry removal.

use std::sync::Arc;

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use async_trait::async_trait;
use serde_json::{Value, json};

use crate::tools::errors::ToolError;
use crate::tools::traits::{SubagentConfig, SubagentMode, SubagentSpawner, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{
    get_optional_bool, get_optional_string, get_optional_u64, validate_required_string,
};

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

fn process_id_for_mode(mode: &SubagentMode) -> &'static str {
    match mode {
        SubagentMode::InProcess => "spawnSubagent.inProcess",
        SubagentMode::Tmux => "spawnSubagent.tmux",
    }
}

fn process_for_mode(mode: &SubagentMode) -> crate::core::profile::ProcessSpec {
    crate::core::profile::active_process_spec(process_id_for_mode(mode))
        .expect("active profile must define SpawnSubagent process specs")
}

fn default_timeout_ms_for_mode(mode: &SubagentMode) -> u64 {
    let process = process_for_mode(mode);
    process
        .timeout_ms
        .or(process.blocking_timeout_ms)
        .expect("SpawnSubagent process must define timeoutMs or blockingTimeoutMs")
}

fn default_max_turns_for_mode(mode: &SubagentMode) -> u32 {
    process_for_mode(mode)
        .max_turns
        .expect("SpawnSubagent process must define maxTurns")
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
        let default_timeout = default_timeout_ms_for_mode(&SubagentMode::InProcess);
        ToolSchemaBuilder::new(
            "SpawnSubagent",
            format!("Spawn an agent to handle a specific task. Blocks for up to `timeout` milliseconds (default {default_timeout} ms). \
If the subagent completes within the timeout, the result is returned inline. If it's still running, \
it automatically moves to the background and results are injected on your next turn.\n\n\
**Execution Modes:**\n\
**1. In-Process (default):** Runs in the same process, sharing the event store.\n\
**2. Tmux:** Runs in a separate tmux session. Always fire-and-forget.\n\n\
Parameters:\n\
- **task**: The task description for the agent (required)\n\
- **mode**: 'inProcess' (default) or 'tmux'\n\
- **timeout**: How long to block before auto-backgrounding in ms (default: {default_timeout}). Set 0 to background immediately.\n\
- **model**, **systemPrompt**, **deniedTools**, **denyAllTools**, **skills**, **workingDirectory**, **maxTurns**: Optional overrides\n\
- **deniedTools**: Array of tool names to remove from the subagent's registry\n\
- **denyAllTools**: Set true for text-only agents (removes all tools)\n\n\
Returns (when completed within timeout):\n\
- Full output, token usage, duration statistics, status",
            ),
        )
        .required_property("task", json!({"type": "string", "description": "Task/prompt for the subagent"}))
        .property("mode", json!({"type": "string", "enum": ["inProcess", "tmux"], "description": "Execution mode"}))
        .property("model", json!({"type": "string", "description": "Override model for the subagent"}))
        .property("systemPrompt", json!({"type": "string", "description": "Custom system prompt"}))
        .property("deniedTools", json!({"type": "array", "items": {"type": "string"}, "description": "Tool names to remove from the subagent's registry."}))
        .property("denyAllTools", json!({"type": "boolean", "description": "Remove all tools (text-only agent). Takes precedence over deniedTools."}))
        .property("skills", json!({"type": "array", "items": {"type": "string"}, "description": "Skills to enable"}))
        .property("workingDirectory", json!({"type": "string", "description": "Working directory"}))
        .property("maxTurns", json!({"type": "number", "description": "Maximum turns before stopping"}))
        .property("timeout", json!({"type": "number", "description": format!("How long to block before auto-backgrounding, in milliseconds (default {default_timeout}). Set 0 to background immediately.")}))
        .property("maxDepth", json!({"type": "number", "description": "Maximum nesting depth for child subagents (0 = no children)"}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let task = match validate_required_string(&params, "task", "task description") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let mode_str = get_optional_string(&params, "mode").unwrap_or_else(|| "inProcess".into());
        let mode = match mode_str.as_str() {
            "inProcess" => SubagentMode::InProcess,
            "tmux" => SubagentMode::Tmux,
            _ => {
                return Ok(error_result(format!(
                    "Invalid mode: \"{mode_str}\". Must be \"inProcess\" or \"tmux\"."
                )));
            }
        };

        let timeout_ms = get_optional_u64(&params, "timeout")
            .unwrap_or_else(|| default_timeout_ms_for_mode(&mode));
        let blocking_timeout_ms = if timeout_ms > 0 {
            Some(timeout_ms)
        } else {
            None
        };
        let default_turns = if mode == SubagentMode::Tmux {
            default_max_turns_for_mode(&SubagentMode::Tmux)
        } else {
            default_max_turns_for_mode(&SubagentMode::InProcess)
        };
        #[allow(clippy::cast_possible_truncation)]
        let max_turns = get_optional_u64(&params, "maxTurns").map_or(default_turns, |v| v as u32);

        let model = get_optional_string(&params, "model");
        let system_prompt = get_optional_string(&params, "systemPrompt");
        let working_directory = get_optional_string(&params, "workingDirectory")
            .unwrap_or_else(|| ctx.working_directory.clone());
        let denied_tools = if get_optional_bool(&params, "denyAllTools") == Some(true) {
            ctx.all_tool_names.clone()
        } else if let Some(arr) = params.get("deniedTools").and_then(Value::as_array) {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        } else {
            vec![]
        };
        let skills = params.get("skills").and_then(Value::as_array).map(|arr| {
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
            blocking_timeout_ms,
            model,
            parent_session_id: Some(ctx.session_id.clone()),
            system_prompt,
            working_directory,
            max_turns,
            timeout_ms,
            denied_tools,
            skills,
            max_depth: user_max_depth,
            current_depth: ctx.subagent_depth + 1,
            tool_call_id: Some(ctx.tool_call_id.clone()),
        };

        let task_preview = crate::core::text::truncate_str(&task, 120);
        ctx.emit_progress(Some(format!("spawning subagent: {task_preview}")), None)
            .await;

        match self.spawner.spawn(config).await {
            Ok(handle) => {
                if let Some(output) = handle.output {
                    // Completed within blocking timeout.
                    let turns = handle.turns_executed.unwrap_or(0);
                    ctx.emit_progress(
                        Some(format!("subagent completed ({turns} turns)")),
                        Some(1.0),
                    )
                    .await;
                    Ok(TronToolResult {
                        content: ToolResultBody::Blocks(vec![
                            crate::core::content::ToolResultContent::text(&output),
                        ]),
                        details: Some(json!({
                            "sessionId": handle.session_id,
                            "success": handle.success.unwrap_or(true),
                            "totalTurns": turns,
                            "resultSummary": crate::core::text::truncate_str(&output, 200),
                            "tokenUsage": handle.token_usage,
                        })),
                        is_error: None,
                        stop_turn: None,
                    })
                } else {
                    // Auto-backgrounded or non-blocking.
                    ctx.emit_progress(
                        Some(format!("subagent backgrounded: {}", handle.session_id)),
                        None,
                    )
                    .await;
                    Ok(TronToolResult {
                        content: ToolResultBody::Blocks(vec![
                            crate::core::content::ToolResultContent::text(format!(
                                "Subagent spawned: {}\nTask: {}\n\n\
                                 Results will be automatically available at your next turn. \
                                 Only use the Wait tool if you need the output before proceeding.",
                                handle.session_id, task
                            )),
                        ]),
                        details: Some(json!({
                            "sessionId": handle.session_id,
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
    use crate::tools::testutil::{extract_text, make_ctx};
    use crate::tools::traits::{SubagentHandle, SubagentResult, WaitMode};

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
                output: if config.blocking_timeout_ms.is_some() {
                    Some("task completed".into())
                } else {
                    None
                },
                token_usage: if config.blocking_timeout_ms.is_some() {
                    Some(json!({"input": 100, "output": 50}))
                } else {
                    None
                },
                turns_executed: if config.blocking_timeout_ms.is_some() {
                    Some(3)
                } else {
                    None
                },
                success: if config.blocking_timeout_ms.is_some() {
                    Some(true)
                } else {
                    None
                },
            })
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

    #[tokio::test]
    async fn default_is_blocking_with_default_timeout() {
        // Default behavior (no timeout param) should block with default timeout
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("task completed"), "got: {text}");
        let d = r.details.unwrap();
        assert_eq!(d["sessionId"], "sub-1");
    }

    #[tokio::test]
    async fn explicit_timeout_blocks() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"task": "do something", "timeout": 300_000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("task completed"));
    }

    #[tokio::test]
    async fn zero_timeout_returns_session_id() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something", "timeout": 0}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("sub-1"));
    }

    #[tokio::test]
    async fn tmux_mode() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"task": "do something", "mode": "tmux", "timeout": 0}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn invalid_mode_error() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(
                json!({"task": "do something", "mode": "invalid"}),
                &make_ctx(),
            )
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
            .execute(
                json!({"task": "t", "systemPrompt": "Be helpful"}),
                &make_ctx(),
            )
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
            .execute(
                json!({"task": "t", "skills": ["skill1", "skill2"]}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn denied_tools_array_parsed_and_forwarded() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let _ = tool
            .execute(
                json!({"task": "t", "deniedTools": ["Bash", "Write"]}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert_eq!(
            config.denied_tools,
            vec!["Bash".to_string(), "Write".to_string()]
        );
    }

    #[tokio::test]
    async fn deny_all_tools_populates_all_tool_names() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let mut ctx = make_ctx();
        ctx.all_tool_names = vec!["Read".into(), "Write".into(), "Bash".into()];
        let _ = tool
            .execute(json!({"task": "t", "denyAllTools": true}), &ctx)
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert_eq!(
            config.denied_tools,
            vec!["Read".to_string(), "Write".to_string(), "Bash".to_string()]
        );
    }

    #[tokio::test]
    async fn no_denial_params_results_in_empty_denied_tools() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let _ = tool
            .execute(json!({"task": "t"}), &make_ctx())
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert!(config.denied_tools.is_empty());
    }

    #[tokio::test]
    async fn deny_all_takes_precedence_over_denied_tools_array() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let mut ctx = make_ctx();
        ctx.all_tool_names = vec!["Read".into(), "Write".into()];
        let _ = tool
            .execute(
                json!({"task": "t", "denyAllTools": true, "deniedTools": ["Read"]}),
                &ctx,
            )
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert_eq!(
            config.denied_tools,
            vec!["Read".to_string(), "Write".to_string()]
        );
    }

    #[tokio::test]
    async fn denied_tools_non_string_elements_skipped() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let _ = tool
            .execute(
                json!({"task": "t", "deniedTools": ["Bash", 123, null, "Write"]}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert_eq!(
            config.denied_tools,
            vec!["Bash".to_string(), "Write".to_string()]
        );
    }

    #[tokio::test]
    async fn deny_all_tools_false_ignored() {
        let spawner = Arc::new(CapturingSpawner::new());
        let tool = SpawnSubagentTool::new(spawner.clone());
        let mut ctx = make_ctx();
        ctx.all_tool_names = vec!["Read".into()];
        let _ = tool
            .execute(json!({"task": "t", "denyAllTools": false}), &ctx)
            .await
            .unwrap();
        let config = spawner.captured_config();
        assert!(config.denied_tools.is_empty());
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
    async fn blocking_details_include_all_structured_fields() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["sessionId"], "sub-1");
        assert_eq!(d["success"], true);
        assert_eq!(d["totalTurns"], 3);
        assert!(d["resultSummary"].is_string());
        assert!(d["tokenUsage"].is_object());
    }

    #[tokio::test]
    async fn nonblocking_details_minimal() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "do something", "timeout": 0}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["sessionId"], "sub-1");
        // Non-blocking should NOT have these fields
        assert!(d.get("success").is_none());
        assert!(d.get("totalTurns").is_none());
    }

    #[tokio::test]
    async fn token_usage_in_blocking_result() {
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let r = tool
            .execute(json!({"task": "t", "timeout": 300_000}), &make_ctx())
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
                output: if config.blocking_timeout_ms.is_some() {
                    Some("done".into())
                } else {
                    None
                },
                token_usage: None,
                turns_executed: if config.blocking_timeout_ms.is_some() {
                    Some(1)
                } else {
                    None
                },
                success: if config.blocking_timeout_ms.is_some() {
                    Some(true)
                } else {
                    None
                },
            })
        }
        async fn wait_for_agents(
            &self,
            _: &[String],
            _: WaitMode,
            _: u64,
        ) -> Result<Vec<SubagentResult>, ToolError> {
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
            workspace_id: None,
            output_tx: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            event_emitter: None,
            event_persister: None,
            turn: 0,
            all_tool_names: vec![],
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

    // ── Progress event tests ──

    #[tokio::test]
    async fn spawn_emits_start_and_completed_progress_events() {
        let (ctx, store, session_id) = crate::tools::testutil::make_ctx_with_persister().await;
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let _ = tool
            .execute(json!({"task": "investigate a thing"}), &ctx)
            .await
            .unwrap();

        let events = crate::tools::testutil::drain_progress_events(&store, &session_id).await;
        assert!(
            events.len() >= 2,
            "expected start + completed, got {events:?}"
        );
        let messages: Vec<String> = events
            .iter()
            .filter_map(|e| e["message"].as_str().map(String::from))
            .collect();
        assert!(
            messages.iter().any(|m| m.starts_with("spawning subagent")),
            "missing start message: {messages:?}"
        );
        assert!(
            messages.iter().any(|m| m.contains("completed")),
            "missing completed message: {messages:?}"
        );
        // Completed event should carry percent=1.0.
        let completed = events
            .iter()
            .find(|e| e["message"].as_str().unwrap_or("").contains("completed"))
            .expect("completed event present");
        assert_eq!(completed["percent"], serde_json::json!(1.0));
    }

    #[tokio::test]
    async fn spawn_nonblocking_emits_backgrounded_progress() {
        let (ctx, store, session_id) = crate::tools::testutil::make_ctx_with_persister().await;
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::success()));
        let _ = tool
            .execute(json!({"task": "run later", "timeout": 0}), &ctx)
            .await
            .unwrap();

        let events = crate::tools::testutil::drain_progress_events(&store, &session_id).await;
        let messages: Vec<String> = events
            .iter()
            .filter_map(|e| e["message"].as_str().map(String::from))
            .collect();
        assert!(
            messages.iter().any(|m| m.contains("backgrounded")),
            "expected backgrounded progress: {messages:?}"
        );
    }

    #[tokio::test]
    async fn spawn_failure_emits_no_completion_progress() {
        let (ctx, store, session_id) = crate::tools::testutil::make_ctx_with_persister().await;
        let tool = SpawnSubagentTool::new(Arc::new(MockSpawner::failing()));
        let _ = tool.execute(json!({"task": "doomed"}), &ctx).await.unwrap();

        let events = crate::tools::testutil::drain_progress_events(&store, &session_id).await;
        // Start event fired before spawn(); no completed/backgrounded after failure.
        for e in &events {
            let msg = e["message"].as_str().unwrap_or("");
            assert!(
                !msg.contains("completed") && !msg.contains("backgrounded"),
                "failure must not emit terminal progress: {msg}"
            );
        }
    }
}
