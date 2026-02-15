use std::sync::Arc;
use std::time::Instant;

use futures::StreamExt;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use tron_core::events::{AgentEvent, PersistenceEventType};
use tron_core::ids::{AgentId, SessionId, WorkspaceId};
use tron_core::messages::{AssistantMessage, Message, StopReason, ToolCallBlock};
use tron_core::provider::{LlmProvider, StreamOptions};
use tron_core::stream::StreamEvent;
use tron_core::tokens::{AccumulatedTokens, TokenRecord, TokenUsage};
use tron_core::tools::{ExecutionMode, ToolContext};
use tron_store::events::EventRepo;
use tron_store::sessions::SessionRepo;
use tron_store::Database;

use crate::context::ContextManager;
use crate::error::EngineError;
use crate::hooks::{HookContext, HookEngine};
use crate::registry::ToolRegistry;
use tron_core::hooks::{HookResult, HookType};

/// Configuration for the agent runner.
pub struct RunnerConfig {
    pub max_turns_per_prompt: u32,
    pub stream_options: StreamOptions,
    pub abort_timeout_ms: u64,
}

/// Parameters for a single turn execution.
pub struct TurnParams<'a> {
    pub context_manager: &'a ContextManager,
    pub messages: &'a mut Vec<Message>,
    pub session_id: &'a SessionId,
    pub agent_id: &'a AgentId,
    pub workspace_id: &'a WorkspaceId,
    pub turn: u32,
    pub previous_context_baseline: u32,
    pub options: &'a StreamOptions,
    pub cancel: &'a CancellationToken,
}

impl Default for RunnerConfig {
    fn default() -> Self {
        Self {
            max_turns_per_prompt: 50,
            stream_options: StreamOptions::default(),
            abort_timeout_ms: 5000,
        }
    }
}

/// Runs a single agent turn: build context → stream → accumulate → persist → tool execution.
pub struct TurnRunner {
    provider: Arc<dyn LlmProvider>,
    tool_registry: Arc<ToolRegistry>,
    hook_engine: Arc<HookEngine>,
    event_repo: EventRepo,
    session_repo: SessionRepo,
    event_tx: broadcast::Sender<AgentEvent>,
}

impl TurnRunner {
    pub fn new(
        provider: Arc<dyn LlmProvider>,
        tool_registry: Arc<ToolRegistry>,
        hook_engine: Arc<HookEngine>,
        db: Database,
        event_tx: broadcast::Sender<AgentEvent>,
    ) -> Self {
        Self {
            provider,
            tool_registry,
            hook_engine,
            event_repo: EventRepo::new(db.clone()),
            session_repo: SessionRepo::new(db),
            event_tx,
        }
    }

    /// Execute a single LLM turn. Returns the assistant message and whether to continue (tool_use).
    pub async fn execute_turn(&self, p: TurnParams<'_>) -> Result<TurnResult, EngineError> {
        let TurnParams {
            context_manager,
            messages,
            session_id,
            agent_id,
            workspace_id,
            turn,
            previous_context_baseline,
            options,
            cancel,
        } = p;

        // 1. Emit TurnStart
        let _ = self.event_tx.send(AgentEvent::TurnStart {
            session_id: session_id.clone(),
            agent_id: agent_id.clone(),
            turn,
        });

        // 2. Build context
        let tool_defs = self.tool_registry.definitions();
        let ctx = context_manager.build_context(
            messages.clone(),
            tool_defs,
            workspace_id,
            Some(session_id),
        );

        // 3. Stream from provider
        let mut stream = self.provider.stream(&ctx, options).await?;

        // 4. Accumulate stream events
        let mut assistant_msg: Option<AssistantMessage> = None;
        let mut stop_reason = StopReason::EndTurn;
        let mut usage = TokenUsage::default();

        while let Some(event) = stream.next().await {
            if cancel.is_cancelled() {
                return Err(EngineError::Aborted);
            }

            match event {
                StreamEvent::TextDelta { delta } => {
                    let _ = self.event_tx.send(AgentEvent::TextDelta {
                        session_id: session_id.clone(),
                        agent_id: agent_id.clone(),
                        delta,
                    });
                }
                StreamEvent::ThinkingDelta { delta } => {
                    let _ = self.event_tx.send(AgentEvent::ThinkingDelta {
                        session_id: session_id.clone(),
                        agent_id: agent_id.clone(),
                        delta,
                    });
                }
                StreamEvent::Done { message, stop_reason: sr } => {
                    stop_reason = sr;
                    if let Some(u) = &message.usage {
                        usage = u.clone();
                    }
                    assistant_msg = Some(message);
                }
                StreamEvent::Error { error } => {
                    return Err(EngineError::Gateway(error));
                }
                _ => {}
            }
        }

        let assistant_msg = assistant_msg.ok_or_else(|| {
            EngineError::Internal("Stream ended without Done event".into())
        })?;

        // 5. Build token record
        let token_record = TokenRecord::from_usage(
            &usage,
            previous_context_baseline,
            turn,
            session_id.clone(),
        );

        // 6. Persist assistant message event
        let payload = serde_json::to_value(&assistant_msg)
            .map_err(|e| EngineError::Internal(format!("Failed to serialize message: {e}")))?;
        self.event_repo
            .append(
                session_id,
                workspace_id,
                PersistenceEventType::MessageAssistant,
                payload,
            )
            .map_err(EngineError::Store)?;

        // 7. Persist turn end event
        let turn_end_payload = serde_json::json!({
            "turn": turn,
            "token_record": token_record,
            "stop_reason": stop_reason,
        });
        self.event_repo
            .append(
                session_id,
                workspace_id,
                PersistenceEventType::StreamTurnEnd,
                turn_end_payload,
            )
            .map_err(EngineError::Store)?;

        // 8. Update session token accumulators
        let mut accumulated = AccumulatedTokens::default();
        accumulated.accumulate(&token_record);
        self.session_repo
            .update_tokens(session_id, &accumulated)
            .map_err(EngineError::Store)?;

        // 9. Emit TurnComplete
        let _ = self.event_tx.send(AgentEvent::TurnComplete {
            session_id: session_id.clone(),
            agent_id: agent_id.clone(),
            turn,
            usage,
        });

        // 10. Check for tool calls
        let tool_calls: Vec<ToolCallBlock> = assistant_msg.tool_calls().into_iter().cloned().collect();
        let has_tool_calls = !tool_calls.is_empty();

        // Add assistant message to history
        messages.push(Message::Assistant(assistant_msg.clone()));

        // 11. Execute tool calls if present (with hook integration)
        if has_tool_calls {
            let tool_results = self
                .execute_tools(
                    &tool_calls,
                    session_id,
                    agent_id,
                    workspace_id,
                    cancel,
                )
                .await?;

            for result in tool_results {
                messages.push(result);
            }
        }

        Ok(TurnResult {
            assistant_message: assistant_msg,
            token_record,
            stop_reason,
            has_tool_calls,
        })
    }

    /// Execute tool calls with smart concurrent/sequential scheduling.
    async fn execute_tools(
        &self,
        tool_calls: &[ToolCallBlock],
        session_id: &SessionId,
        agent_id: &AgentId,
        workspace_id: &WorkspaceId,
        cancel: &CancellationToken,
    ) -> Result<Vec<Message>, EngineError> {
        let mut results = Vec::new();

        // Separate into concurrent and sequential tool calls
        let mut concurrent = Vec::new();
        let mut sequential = Vec::new();

        for tc in tool_calls {
            let tool = self.tool_registry.get(&tc.name);
            let mode = tool
                .as_ref()
                .map(|t| t.execution_mode())
                .unwrap_or(ExecutionMode::Sequential);

            match mode {
                ExecutionMode::Concurrent => concurrent.push(tc),
                ExecutionMode::Sequential => sequential.push(tc),
            }
        }

        // Execute concurrent tools in parallel
        if !concurrent.is_empty() {
            let mut handles = Vec::new();
            for tc in &concurrent {
                let tool = match self.tool_registry.get(&tc.name) {
                    Some(t) => t,
                    None => {
                        results.push(make_error_result(tc, "Unknown tool"));
                        continue;
                    }
                };

                let tc_clone = (*tc).clone();
                let tool_clone = Arc::clone(&tool);
                let tool_ctx = ToolContext {
                    session_id: session_id.clone(),
                    working_directory: std::path::PathBuf::from("/tmp"), // TODO: from context
                    agent_id: agent_id.clone(),
                    parent_agent_id: None,
                    abort_signal: cancel.clone(),
                };
                let sid = session_id.clone();
                let aid = agent_id.clone();
                let tx = self.event_tx.clone();

                handles.push(tokio::spawn(async move {
                    let _ = tx.send(AgentEvent::ToolStart {
                        session_id: sid.clone(),
                        agent_id: aid.clone(),
                        tool_call_id: tc_clone.id.clone(),
                        tool_name: tc_clone.name.clone(),
                    });

                    let start = Instant::now();
                    let result = tool_clone.execute(tc_clone.arguments.clone(), &tool_ctx).await;
                    let duration = start.elapsed();

                    let (content, is_error) = match result {
                        Ok(r) => (r.content, r.is_error),
                        Err(e) => (e.to_string(), true),
                    };

                    let _ = tx.send(AgentEvent::ToolEnd {
                        session_id: sid,
                        agent_id: aid,
                        tool_call_id: tc_clone.id.clone(),
                        result_preview: content.chars().take(200).collect(),
                        duration_ms: duration.as_millis() as u64,
                    });

                    Message::tool_result(tc_clone.id, if is_error { format!("[error] {content}") } else { content })
                }));
            }

            for handle in handles {
                if let Ok(msg) = handle.await {
                    results.push(msg);
                }
            }
        }

        // Execute sequential tools one at a time
        for tc in &sequential {
            let tool = match self.tool_registry.get(&tc.name) {
                Some(t) => t,
                None => {
                    results.push(make_error_result(tc, "Unknown tool"));
                    continue;
                }
            };

            // PreToolUse hook (blocking)
            let hook_ctx = HookContext {
                hook_type: HookType::PreToolUse,
                session_id: session_id.to_string(),
                agent_id: agent_id.to_string(),
                tool_name: Some(tc.name.clone()),
                tool_args: Some(tc.arguments.clone()),
                prompt: None,
                timestamp: chrono::Utc::now().to_rfc3339(),
            };
            let hook_result = self.hook_engine.execute_blocking(&hook_ctx).await;
            if let HookResult::Block { reason } = hook_result {
                results.push(Message::tool_result(
                    tc.id.clone(),
                    format!("[error] Tool blocked by hook: {reason}"),
                ));
                continue;
            }

            // Emit ToolStart
            let _ = self.event_tx.send(AgentEvent::ToolStart {
                session_id: session_id.clone(),
                agent_id: agent_id.clone(),
                tool_call_id: tc.id.clone(),
                tool_name: tc.name.clone(),
            });

            let tool_ctx = ToolContext {
                session_id: session_id.clone(),
                working_directory: std::path::PathBuf::from("/tmp"), // TODO: from context
                agent_id: agent_id.clone(),
                parent_agent_id: None,
                abort_signal: cancel.clone(),
            };

            let start = Instant::now();
            let result = tool.execute(tc.arguments.clone(), &tool_ctx).await;
            let duration = start.elapsed();

            let (content, is_error) = match result {
                Ok(r) => (r.content, r.is_error),
                Err(e) => (e.to_string(), true),
            };

            // Persist tool events
            let tool_call_payload = serde_json::json!({
                "tool_call_id": tc.id,
                "tool_name": tc.name,
                "arguments": tc.arguments,
            });
            let _ = self.event_repo.append(
                session_id,
                workspace_id,
                PersistenceEventType::ToolCall,
                tool_call_payload,
            );

            let tool_result_payload = serde_json::json!({
                "tool_call_id": tc.id,
                "content": content,
                "is_error": is_error,
                "duration_ms": duration.as_millis() as u64,
            });
            let _ = self.event_repo.append(
                session_id,
                workspace_id,
                PersistenceEventType::ToolResult,
                tool_result_payload,
            );

            let _ = self.event_tx.send(AgentEvent::ToolEnd {
                session_id: session_id.clone(),
                agent_id: agent_id.clone(),
                tool_call_id: tc.id.clone(),
                result_preview: content.chars().take(200).collect(),
                duration_ms: duration.as_millis() as u64,
            });

            // PostToolUse hook (background)
            let post_hook_ctx = HookContext {
                hook_type: HookType::PostToolUse,
                session_id: session_id.to_string(),
                agent_id: agent_id.to_string(),
                tool_name: Some(tc.name.clone()),
                tool_args: Some(tc.arguments.clone()),
                prompt: None,
                timestamp: chrono::Utc::now().to_rfc3339(),
            };
            drop(self.hook_engine.execute_background(post_hook_ctx));

            results.push(Message::tool_result(
                tc.id.clone(),
                if is_error { format!("[error] {content}") } else { content },
            ));
        }

        Ok(results)
    }
}

fn make_error_result(tc: &ToolCallBlock, msg: &str) -> Message {
    Message::tool_result(tc.id.clone(), format!("[error] {msg}: {}", tc.name))
}

/// Result of a single turn.
pub struct TurnResult {
    pub assistant_message: AssistantMessage,
    pub token_record: TokenRecord,
    pub stop_reason: StopReason,
    pub has_tool_calls: bool,
}

/// The agent runner manages the multi-turn loop for a single prompt.
pub struct AgentRunner {
    turn_runner: TurnRunner,
    config: RunnerConfig,
    event_tx: broadcast::Sender<AgentEvent>,
}

impl AgentRunner {
    pub fn new(
        turn_runner: TurnRunner,
        config: RunnerConfig,
        event_tx: broadcast::Sender<AgentEvent>,
    ) -> Self {
        Self {
            turn_runner,
            config,
            event_tx,
        }
    }

    /// Run the agent loop for a single user prompt.
    /// Loops through LLM turns until stop_reason is end_turn or max turns reached.
    pub async fn run(
        &self,
        context_manager: &ContextManager,
        messages: &mut Vec<Message>,
        session_id: &SessionId,
        agent_id: &AgentId,
        workspace_id: &WorkspaceId,
        cancel: &CancellationToken,
    ) -> Result<(), EngineError> {
        let mut turn = 1u32;
        let mut previous_context_baseline = 0u32;

        loop {
            if cancel.is_cancelled() {
                return Err(EngineError::Aborted);
            }

            if turn > self.config.max_turns_per_prompt {
                return Err(EngineError::MaxTurnsExceeded(self.config.max_turns_per_prompt));
            }

            let result = self
                .turn_runner
                .execute_turn(TurnParams {
                    context_manager,
                    messages,
                    session_id,
                    agent_id,
                    workspace_id,
                    turn,
                    previous_context_baseline,
                    options: &self.config.stream_options,
                    cancel,
                })
                .await?;

            previous_context_baseline = result.token_record.computed.context_window_tokens;

            if !result.has_tool_calls {
                break;
            }

            turn += 1;
        }

        // Emit AgentComplete → AgentReady (strict ordering)
        let _ = self.event_tx.send(AgentEvent::AgentComplete {
            session_id: session_id.clone(),
            agent_id: agent_id.clone(),
        });
        let _ = self.event_tx.send(AgentEvent::AgentReady {
            session_id: session_id.clone(),
            agent_id: agent_id.clone(),
        });

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::ContextConfig;
    use tron_core::messages::AssistantContent;
    use tron_llm::mock::{MockProvider, MockResponse};
    use tron_store::workspaces::WorkspaceRepo;

    fn setup() -> (Database, WorkspaceId, SessionId) {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        let sess_repo = SessionRepo::new(db.clone());
        let session = sess_repo
            .create(&ws.id, "claude-opus-4-6", "anthropic", "/tmp")
            .unwrap();
        (db, ws.id, session.id)
    }

    #[tokio::test]
    async fn single_turn_text_response() {
        let (db, ws_id, sess_id) = setup();
        let (tx, mut rx) = broadcast::channel(100);

        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::stream_text("Hello! I'm here to help."),
        ]));

        let tool_registry = Arc::new(ToolRegistry::new());
        let hook_engine = Arc::new(HookEngine::new());
        let config = ContextConfig {
            project_root: std::path::PathBuf::from("/tmp"),
            working_directory: std::path::PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(config);

        let turn_runner = TurnRunner::new(
            provider,
            tool_registry,
            hook_engine,
            db,
            tx.clone(),
        );

        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();
        let mut messages = vec![Message::user_text("Hello!")];

        let result = turn_runner
            .execute_turn(TurnParams {
                context_manager: &context_manager,
                messages: &mut messages,
                session_id: &sess_id,
                agent_id: &agent_id,
                workspace_id: &ws_id,
                turn: 1,
                previous_context_baseline: 0,
                options: &StreamOptions::default(),
                cancel: &cancel,
            })
            .await
            .unwrap();

        assert!(!result.has_tool_calls);
        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert!(result.assistant_message.text_content().contains("Hello"));

        // Verify events were emitted
        let mut events = Vec::new();
        while let Ok(evt) = rx.try_recv() {
            events.push(evt.event_type().to_string());
        }
        assert!(events.contains(&"turn_start".to_string()));
        assert!(events.contains(&"turn_complete".to_string()));
    }

    #[tokio::test]
    async fn multi_turn_with_tool_use() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        // First response: tool use, second response: text
        let tool_call = ToolCallBlock {
            id: tron_core::ids::ToolCallId::new(),
            name: "Read".into(),
            arguments: serde_json::json!({"file_path": "/tmp/test.txt"}),
            thought_signature: None,
        };

        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::Stream(vec![
                StreamEvent::Start,
                StreamEvent::ToolCallStart {
                    tool_call_id: tool_call.id.clone(),
                    name: "Read".into(),
                },
                StreamEvent::ToolCallEnd {
                    tool_call: tool_call.clone(),
                },
                StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::ToolCall(tool_call.clone())],
                        usage: Some(TokenUsage::default()),
                        stop_reason: Some(StopReason::ToolUse),
                    },
                    stop_reason: StopReason::ToolUse,
                },
            ]),
            MockResponse::stream_text("The file contains: test content."),
        ]));

        // Register Read tool
        let mut tool_registry = ToolRegistry::new();
        tool_registry.register(
            Arc::new(crate::tools::read::ReadTool),
            crate::registry::ToolSource::BuiltIn,
        );

        let hook_engine = Arc::new(HookEngine::new());
        let runner_config = RunnerConfig::default();
        let context_config = ContextConfig {
            project_root: std::path::PathBuf::from("/tmp"),
            working_directory: std::path::PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        let turn_runner = TurnRunner::new(
            provider,
            Arc::new(tool_registry),
            hook_engine,
            db,
            tx.clone(),
        );

        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        // Create test file
        tokio::fs::write("/tmp/test.txt", "test content").await.ok();

        let mut messages = vec![Message::user_text("Read /tmp/test.txt")];
        let result = agent_runner
            .run(
                &context_manager,
                &mut messages,
                &sess_id,
                &agent_id,
                &ws_id,
                &cancel,
            )
            .await;

        assert!(result.is_ok());
        // Messages should include: user, assistant (tool_use), tool_result, assistant (text)
        assert!(messages.len() >= 3);
    }

    #[tokio::test]
    async fn abort_cancels_run() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        // Provider that returns slowly (many events)
        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::stream_text("This should be cut short."),
        ]));

        let tool_registry = Arc::new(ToolRegistry::new());
        let hook_engine = Arc::new(HookEngine::new());
        let config = ContextConfig {
            project_root: std::path::PathBuf::from("/tmp"),
            working_directory: std::path::PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(config);

        let turn_runner = TurnRunner::new(
            provider,
            tool_registry,
            hook_engine,
            db,
            tx.clone(),
        );

        let runner_config = RunnerConfig::default();
        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        // Cancel before running
        cancel.cancel();

        let mut messages = vec![Message::user_text("Hello")];
        let result = agent_runner
            .run(
                &context_manager,
                &mut messages,
                &sess_id,
                &agent_id,
                &ws_id,
                &cancel,
            )
            .await;

        assert!(matches!(result, Err(EngineError::Aborted)));
    }

    #[tokio::test]
    async fn max_turns_exceeded() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        // Provider that always returns tool_use (infinite loop)
        let tool_call = ToolCallBlock {
            id: tron_core::ids::ToolCallId::new(),
            name: "Read".into(),
            arguments: serde_json::json!({"file_path": "/tmp/test.txt"}),
            thought_signature: None,
        };

        let mut responses = Vec::new();
        for _ in 0..5 {
            responses.push(MockResponse::Stream(vec![
                StreamEvent::Start,
                StreamEvent::ToolCallEnd {
                    tool_call: tool_call.clone(),
                },
                StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::ToolCall(tool_call.clone())],
                        usage: Some(TokenUsage::default()),
                        stop_reason: Some(StopReason::ToolUse),
                    },
                    stop_reason: StopReason::ToolUse,
                },
            ]));
        }

        let provider = Arc::new(MockProvider::new(responses));
        let mut tool_registry = ToolRegistry::new();
        tool_registry.register(
            Arc::new(crate::tools::read::ReadTool),
            crate::registry::ToolSource::BuiltIn,
        );

        let hook_engine = Arc::new(HookEngine::new());
        let runner_config = RunnerConfig {
            max_turns_per_prompt: 3,
            ..Default::default()
        };
        let context_config = ContextConfig {
            project_root: std::path::PathBuf::from("/tmp"),
            working_directory: std::path::PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        // Create test file for Read tool
        tokio::fs::write("/tmp/test.txt", "test").await.ok();

        let turn_runner = TurnRunner::new(
            provider,
            Arc::new(tool_registry),
            hook_engine,
            db,
            tx.clone(),
        );

        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        let mut messages = vec![Message::user_text("Read a file")];
        let result = agent_runner
            .run(
                &context_manager,
                &mut messages,
                &sess_id,
                &agent_id,
                &ws_id,
                &cancel,
            )
            .await;

        assert!(matches!(result, Err(EngineError::MaxTurnsExceeded(3))));
    }
}
