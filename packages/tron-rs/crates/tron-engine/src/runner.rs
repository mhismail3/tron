use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures::{FutureExt, StreamExt};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use tracing::{error, instrument, warn};

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
use crate::truncate;
use tron_core::hooks::{HookResult, HookType};

const DEFAULT_TOOL_TIMEOUT: Duration = Duration::from_secs(120);
const DEFAULT_MAX_RUN_DURATION: Duration = Duration::from_secs(3600);

/// Configuration for the agent runner.
pub struct RunnerConfig {
    pub max_turns_per_prompt: u32,
    pub stream_options: StreamOptions,
    pub abort_timeout_ms: u64,
    pub max_run_duration: Duration,
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
            max_run_duration: DEFAULT_MAX_RUN_DURATION,
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
    tool_timeout: Duration,
    working_directory: PathBuf,
}

impl TurnRunner {
    pub fn new(
        provider: Arc<dyn LlmProvider>,
        tool_registry: Arc<ToolRegistry>,
        hook_engine: Arc<HookEngine>,
        db: Database,
        event_tx: broadcast::Sender<AgentEvent>,
        working_directory: PathBuf,
    ) -> Self {
        Self {
            provider,
            tool_registry,
            hook_engine,
            event_repo: EventRepo::new(db.clone()),
            session_repo: SessionRepo::new(db),
            event_tx,
            tool_timeout: DEFAULT_TOOL_TIMEOUT,
            working_directory,
        }
    }

    pub fn with_tool_timeout(mut self, timeout: Duration) -> Self {
        self.tool_timeout = timeout;
        self
    }

    fn send_event(&self, event: AgentEvent) {
        if self.event_tx.send(event).is_err() {
            warn!("no event receivers — event dropped");
        }
    }

    /// Execute a single LLM turn. Returns the assistant message and whether to continue (tool_use).
    #[instrument(skip(self, p), fields(session_id = %p.session_id, turn = p.turn))]
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
        self.send_event(AgentEvent::TurnStart {
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
                    self.send_event(AgentEvent::TextDelta {
                        session_id: session_id.clone(),
                        agent_id: agent_id.clone(),
                        delta,
                    });
                }
                StreamEvent::ThinkingDelta { delta } => {
                    self.send_event(AgentEvent::ThinkingDelta {
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
        self.send_event(AgentEvent::TurnComplete {
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
                    working_directory: self.working_directory.clone(),
                    agent_id: agent_id.clone(),
                    parent_agent_id: None,
                    abort_signal: cancel.clone(),
                };
                let sid = session_id.clone();
                let aid = agent_id.clone();
                let tx = self.event_tx.clone();
                let timeout = self.tool_timeout;

                handles.push(tokio::spawn(async move {
                    if tx
                        .send(AgentEvent::ToolStart {
                            session_id: sid.clone(),
                            agent_id: aid.clone(),
                            tool_call_id: tc_clone.id.clone(),
                            tool_name: tc_clone.name.clone(),
                        })
                        .is_err()
                    {
                        warn!(tool = %tc_clone.name, "no event receivers — tool_start dropped");
                    }

                    let start = Instant::now();
                    let result = tokio::time::timeout(
                        timeout,
                        std::panic::AssertUnwindSafe(
                            tool_clone.execute(tc_clone.arguments.clone(), &tool_ctx),
                        )
                        .catch_unwind(),
                    )
                    .await;
                    let duration = start.elapsed();

                    let (content, is_error) = match result {
                        Ok(Ok(Ok(r))) => (r.content, r.is_error),
                        Ok(Ok(Err(e))) => (e.to_string(), true),
                        Ok(Err(panic)) => {
                            let msg = panic_message(&panic);
                            error!(
                                tool = %tc_clone.name,
                                panic = %msg,
                                "tool panicked during execution"
                            );
                            ("Internal error: tool crashed".into(), true)
                        }
                        Err(_) => {
                            warn!(
                                tool = %tc_clone.name,
                                timeout_secs = timeout.as_secs(),
                                "tool timed out"
                            );
                            (format!("Tool timed out after {}s", timeout.as_secs()), true)
                        }
                    };

                    let max = truncate::max_output_for_tool(&tc_clone.name);
                    let content = truncate::truncate_output(&content, max);

                    if tx
                        .send(AgentEvent::ToolEnd {
                            session_id: sid,
                            agent_id: aid,
                            tool_call_id: tc_clone.id.clone(),
                            result_preview: content.chars().take(200).collect(),
                            duration_ms: duration.as_millis() as u64,
                        })
                        .is_err()
                    {
                        warn!(tool = %tc_clone.name, "no event receivers — tool_end dropped");
                    }

                    Message::tool_result(tc_clone.id, if is_error { format!("[error] {content}") } else { content })
                }));
            }

            for (i, handle) in handles.into_iter().enumerate() {
                match handle.await {
                    Ok(msg) => results.push(msg),
                    Err(join_err) => {
                        let tc = concurrent[i];
                        error!(
                            tool = %tc.name,
                            error = %join_err,
                            "tool task failed"
                        );
                        results.push(Message::tool_result(
                            tc.id.clone(),
                            "[error] Tool execution failed",
                        ));
                    }
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
            self.send_event(AgentEvent::ToolStart {
                session_id: session_id.clone(),
                agent_id: agent_id.clone(),
                tool_call_id: tc.id.clone(),
                tool_name: tc.name.clone(),
            });

            let tool_ctx = ToolContext {
                session_id: session_id.clone(),
                working_directory: self.working_directory.clone(),
                agent_id: agent_id.clone(),
                parent_agent_id: None,
                abort_signal: cancel.clone(),
            };

            let start = Instant::now();
            let result = tokio::time::timeout(
                self.tool_timeout,
                std::panic::AssertUnwindSafe(tool.execute(tc.arguments.clone(), &tool_ctx))
                    .catch_unwind(),
            )
            .await;
            let duration = start.elapsed();

            let (content, is_error) = match result {
                Ok(Ok(Ok(r))) => (r.content, r.is_error),
                Ok(Ok(Err(e))) => (e.to_string(), true),
                Ok(Err(panic)) => {
                    let msg = panic_message(&panic);
                    error!(
                        tool = %tc.name,
                        panic = %msg,
                        "tool panicked during execution"
                    );
                    ("Internal error: tool crashed".into(), true)
                }
                Err(_) => {
                    warn!(
                        tool = %tc.name,
                        timeout_secs = self.tool_timeout.as_secs(),
                        "tool timed out"
                    );
                    (format!("Tool timed out after {}s", self.tool_timeout.as_secs()), true)
                }
            };

            let max = truncate::max_output_for_tool(&tc.name);
            let content = truncate::truncate_output(&content, max);

            // Persist tool events
            let tool_call_payload = serde_json::json!({
                "tool_call_id": tc.id,
                "tool_name": tc.name,
                "arguments": tc.arguments,
            });
            if let Err(e) = self.event_repo.append(
                session_id,
                workspace_id,
                PersistenceEventType::ToolCall,
                tool_call_payload,
            ) {
                error!(error = %e, tool = %tc.name, "failed to persist tool call event");
            }

            let tool_result_payload = serde_json::json!({
                "tool_call_id": tc.id,
                "content": content,
                "is_error": is_error,
                "duration_ms": duration.as_millis() as u64,
            });
            if let Err(e) = self.event_repo.append(
                session_id,
                workspace_id,
                PersistenceEventType::ToolResult,
                tool_result_payload,
            ) {
                error!(error = %e, tool = %tc.name, "failed to persist tool result event");
            }

            self.send_event(AgentEvent::ToolEnd {
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

fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
    panic
        .downcast_ref::<String>()
        .map(|s| s.as_str())
        .or_else(|| panic.downcast_ref::<&str>().copied())
        .unwrap_or("unknown panic")
        .to_string()
}

/// Result of a single turn.
#[derive(Debug)]
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
    #[instrument(skip(self, context_manager, messages, cancel), fields(session_id = %session_id, agent_id = %agent_id))]
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
        let run_start = Instant::now();

        loop {
            if cancel.is_cancelled() {
                return Err(EngineError::Aborted);
            }

            if turn > self.config.max_turns_per_prompt {
                return Err(EngineError::MaxTurnsExceeded(self.config.max_turns_per_prompt));
            }

            let elapsed = run_start.elapsed();
            if elapsed >= self.config.max_run_duration {
                warn!(
                    elapsed_secs = elapsed.as_secs(),
                    max_secs = self.config.max_run_duration.as_secs(),
                    "agent run exceeded max duration"
                );
                return Err(EngineError::RunTimeout(self.config.max_run_duration));
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

        // Emit AgentComplete → AgentReady (strict ordering — iOS depends on this)
        if self
            .event_tx
            .send(AgentEvent::AgentComplete {
                session_id: session_id.clone(),
                agent_id: agent_id.clone(),
            })
            .is_err()
        {
            warn!("no event receivers — agent_complete dropped");
        }
        if self
            .event_tx
            .send(AgentEvent::AgentReady {
                session_id: session_id.clone(),
                agent_id: agent_id.clone(),
            })
            .is_err()
        {
            warn!("no event receivers — agent_ready dropped");
        }

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
            PathBuf::from("/tmp"),
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
            PathBuf::from("/tmp"),
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
            PathBuf::from("/tmp"),
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
            PathBuf::from("/tmp"),
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

    #[tokio::test]
    async fn tool_timeout_returns_error_result() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        // Provider returns a tool call to our slow tool
        let tool_call = ToolCallBlock {
            id: tron_core::ids::ToolCallId::new(),
            name: "SlowTool".into(),
            arguments: serde_json::json!({}),
            thought_signature: None,
        };

        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::Stream(vec![
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
            ]),
            MockResponse::stream_text("After tool timeout"),
        ]));

        // Register a tool that takes forever
        let mut tool_registry = ToolRegistry::new();
        tool_registry.register(
            Arc::new(SlowTool),
            crate::registry::ToolSource::BuiltIn,
        );

        let hook_engine = Arc::new(HookEngine::new());
        let context_config = ContextConfig {
            project_root: std::path::PathBuf::from("/tmp"),
            working_directory: std::path::PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        // Set tool timeout to 50ms (tool sleeps for 10s)
        let turn_runner = TurnRunner::new(
            provider,
            Arc::new(tool_registry),
            hook_engine,
            db,
            tx.clone(),
            PathBuf::from("/tmp"),
        )
        .with_tool_timeout(Duration::from_millis(50));

        let runner_config = RunnerConfig::default();
        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        let mut messages = vec![Message::user_text("Call the slow tool")];
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

        // Should complete (the tool timed out but agent continued with error result)
        assert!(result.is_ok());

        // One of the messages should contain the timeout error
        let has_timeout_msg = messages.iter().any(|m| {
            if let Message::ToolResult(tr) = m {
                tr.content.iter().any(|c| {
                    if let tron_core::messages::ToolResultContent::Text { text } = c {
                        text.contains("timed out")
                    } else {
                        false
                    }
                })
            } else {
                false
            }
        });
        assert!(has_timeout_msg, "Expected a tool timeout error message in: {messages:?}");
    }

    #[tokio::test]
    async fn run_duration_timeout() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        // Provider returns tool calls with delay to consume time
        let tool_call = ToolCallBlock {
            id: tron_core::ids::ToolCallId::new(),
            name: "Read".into(),
            arguments: serde_json::json!({"file_path": "/tmp/test.txt"}),
            thought_signature: None,
        };

        let mut responses = Vec::new();
        for _ in 0..10 {
            responses.push(MockResponse::delayed(
                Duration::from_millis(30),
                MockResponse::Stream(vec![
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
                ]),
            ));
        }

        let provider = Arc::new(MockProvider::new(responses));
        let mut tool_registry = ToolRegistry::new();
        tool_registry.register(
            Arc::new(crate::tools::read::ReadTool),
            crate::registry::ToolSource::BuiltIn,
        );

        let hook_engine = Arc::new(HookEngine::new());
        let runner_config = RunnerConfig {
            max_turns_per_prompt: 50,
            max_run_duration: Duration::from_millis(100), // Very short
            ..Default::default()
        };
        let context_config = ContextConfig {
            project_root: std::path::PathBuf::from("/tmp"),
            working_directory: std::path::PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        tokio::fs::write("/tmp/test.txt", "test").await.ok();

        let turn_runner = TurnRunner::new(
            provider,
            Arc::new(tool_registry),
            hook_engine,
            db,
            tx.clone(),
            PathBuf::from("/tmp"),
        );

        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        let mut messages = vec![Message::user_text("Keep reading")];
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

        assert!(
            matches!(result, Err(EngineError::RunTimeout(_))),
            "expected RunTimeout, got: {result:?}"
        );
    }

    #[test]
    fn runner_config_defaults() {
        let config = RunnerConfig::default();
        assert_eq!(config.max_turns_per_prompt, 50);
        assert_eq!(config.max_run_duration, Duration::from_secs(3600));
    }

    #[test]
    fn tool_timeout_default() {
        let (db, _, _) = setup();
        let (tx, _rx) = broadcast::channel(100);
        let provider = Arc::new(MockProvider::new(vec![]));
        let tool_registry = Arc::new(ToolRegistry::new());
        let hook_engine = Arc::new(HookEngine::new());
        let runner = TurnRunner::new(provider, tool_registry, hook_engine, db, tx, PathBuf::from("/tmp"));
        assert_eq!(runner.tool_timeout, Duration::from_secs(120));
    }

    // --- Mock tools ---

    struct SlowTool;

    #[async_trait::async_trait]
    impl tron_core::tools::Tool for SlowTool {
        fn name(&self) -> &str {
            "SlowTool"
        }
        fn description(&self) -> &str {
            "A tool that takes forever"
        }
        fn parameters_schema(&self) -> serde_json::Value {
            serde_json::json!({"type": "object"})
        }
        fn execution_mode(&self) -> ExecutionMode {
            ExecutionMode::Sequential
        }
        async fn execute(
            &self,
            _args: serde_json::Value,
            _ctx: &ToolContext,
        ) -> Result<tron_core::tools::ToolResult, tron_core::tools::ToolError> {
            tokio::time::sleep(Duration::from_secs(10)).await;
            Ok(tron_core::tools::ToolResult {
                content: "done".into(),
                is_error: false,
                content_type: tron_core::tools::ContentType::Text,
                duration: Duration::from_secs(10),
            })
        }
    }

    struct PanicTool;

    #[async_trait::async_trait]
    impl tron_core::tools::Tool for PanicTool {
        fn name(&self) -> &str {
            "PanicTool"
        }
        fn description(&self) -> &str {
            "A tool that panics"
        }
        fn parameters_schema(&self) -> serde_json::Value {
            serde_json::json!({"type": "object"})
        }
        fn execution_mode(&self) -> ExecutionMode {
            ExecutionMode::Sequential
        }
        async fn execute(
            &self,
            _args: serde_json::Value,
            _ctx: &ToolContext,
        ) -> Result<tron_core::tools::ToolResult, tron_core::tools::ToolError> {
            panic!("tool exploded!");
        }
    }

    struct CaptureWorkDirTool {
        captured: Arc<std::sync::Mutex<Option<PathBuf>>>,
    }

    #[async_trait::async_trait]
    impl tron_core::tools::Tool for CaptureWorkDirTool {
        fn name(&self) -> &str {
            "CaptureWorkDir"
        }
        fn description(&self) -> &str {
            "Captures working directory"
        }
        fn parameters_schema(&self) -> serde_json::Value {
            serde_json::json!({"type": "object"})
        }
        fn execution_mode(&self) -> ExecutionMode {
            ExecutionMode::Sequential
        }
        async fn execute(
            &self,
            _args: serde_json::Value,
            ctx: &ToolContext,
        ) -> Result<tron_core::tools::ToolResult, tron_core::tools::ToolError> {
            *self.captured.lock().unwrap() = Some(ctx.working_directory.clone());
            Ok(tron_core::tools::ToolResult {
                content: "captured".into(),
                is_error: false,
                content_type: tron_core::tools::ContentType::Text,
                duration: Duration::ZERO,
            })
        }
    }

    struct LargeOutputTool {
        output_size: usize,
    }

    #[async_trait::async_trait]
    impl tron_core::tools::Tool for LargeOutputTool {
        fn name(&self) -> &str {
            "LargeOutput"
        }
        fn description(&self) -> &str {
            "Returns large output"
        }
        fn parameters_schema(&self) -> serde_json::Value {
            serde_json::json!({"type": "object"})
        }
        fn execution_mode(&self) -> ExecutionMode {
            ExecutionMode::Sequential
        }
        async fn execute(
            &self,
            _args: serde_json::Value,
            _ctx: &ToolContext,
        ) -> Result<tron_core::tools::ToolResult, tron_core::tools::ToolError> {
            Ok(tron_core::tools::ToolResult {
                content: "x".repeat(self.output_size),
                is_error: false,
                content_type: tron_core::tools::ContentType::Text,
                duration: Duration::ZERO,
            })
        }
    }

    // --- Helper to build a tool-call mock response ---

    fn tool_call_response(_tool_name: &str, tool_call: &ToolCallBlock) -> MockResponse {
        MockResponse::Stream(vec![
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
        ])
    }

    fn tool_result_text(msg: &Message) -> Option<String> {
        if let Message::ToolResult(tr) = msg {
            for c in &tr.content {
                if let tron_core::messages::ToolResultContent::Text { text } = c {
                    return Some(text.clone());
                }
            }
        }
        None
    }

    // --- Phase 5 tests ---

    #[tokio::test]
    async fn working_directory_propagated_to_tool_context() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        let captured = Arc::new(std::sync::Mutex::new(None));
        let capture_tool = Arc::new(CaptureWorkDirTool {
            captured: captured.clone(),
        });

        let tool_call = ToolCallBlock {
            id: tron_core::ids::ToolCallId::new(),
            name: "CaptureWorkDir".into(),
            arguments: serde_json::json!({}),
            thought_signature: None,
        };

        let provider = Arc::new(MockProvider::new(vec![
            tool_call_response("CaptureWorkDir", &tool_call),
            MockResponse::stream_text("done"),
        ]));

        let mut tool_registry = ToolRegistry::new();
        tool_registry.register(capture_tool, crate::registry::ToolSource::BuiltIn);

        let hook_engine = Arc::new(HookEngine::new());
        let context_config = ContextConfig {
            project_root: PathBuf::from("/home/user/project"),
            working_directory: PathBuf::from("/home/user/project"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        let turn_runner = TurnRunner::new(
            provider,
            Arc::new(tool_registry),
            hook_engine,
            db,
            tx.clone(),
            PathBuf::from("/home/user/project"),
        );

        let runner_config = RunnerConfig::default();
        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        let mut messages = vec![Message::user_text("capture dir")];
        let result = agent_runner
            .run(&context_manager, &mut messages, &sess_id, &agent_id, &ws_id, &cancel)
            .await;

        assert!(result.is_ok());
        let captured_dir = captured.lock().unwrap().clone();
        assert_eq!(
            captured_dir,
            Some(PathBuf::from("/home/user/project")),
            "working_directory must be propagated to tool context"
        );
    }

    #[tokio::test]
    async fn tool_panic_returns_error_not_crash() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        let tool_call = ToolCallBlock {
            id: tron_core::ids::ToolCallId::new(),
            name: "PanicTool".into(),
            arguments: serde_json::json!({}),
            thought_signature: None,
        };

        let provider = Arc::new(MockProvider::new(vec![
            tool_call_response("PanicTool", &tool_call),
            MockResponse::stream_text("recovered from panic"),
        ]));

        let mut tool_registry = ToolRegistry::new();
        tool_registry.register(Arc::new(PanicTool), crate::registry::ToolSource::BuiltIn);

        let hook_engine = Arc::new(HookEngine::new());
        let context_config = ContextConfig {
            project_root: PathBuf::from("/tmp"),
            working_directory: PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        let turn_runner = TurnRunner::new(
            provider,
            Arc::new(tool_registry),
            hook_engine,
            db,
            tx.clone(),
            PathBuf::from("/tmp"),
        );

        let runner_config = RunnerConfig::default();
        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        let mut messages = vec![Message::user_text("use the panic tool")];
        let result = agent_runner
            .run(&context_manager, &mut messages, &sess_id, &agent_id, &ws_id, &cancel)
            .await;

        // Agent should complete successfully (panic was caught)
        assert!(result.is_ok(), "agent should not crash on tool panic: {result:?}");

        // One of the messages should contain the crash error
        let has_crash_msg = messages
            .iter()
            .filter_map(tool_result_text)
            .any(|text| text.contains("Internal error") || text.contains("crashed"));
        assert!(has_crash_msg, "expected crash error message in: {messages:?}");
    }

    #[tokio::test]
    async fn event_send_continues_without_receivers() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::stream_text("Hello!"),
        ]));

        let tool_registry = Arc::new(ToolRegistry::new());
        let hook_engine = Arc::new(HookEngine::new());
        let context_config = ContextConfig {
            project_root: PathBuf::from("/tmp"),
            working_directory: PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        let turn_runner = TurnRunner::new(
            provider,
            tool_registry,
            hook_engine,
            db,
            tx.clone(),
            PathBuf::from("/tmp"),
        );

        // Drop all receivers so send() returns Err
        drop(_rx);

        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();
        let mut messages = vec![Message::user_text("Hello!")];

        // Should complete without error even though no receivers
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
            .await;

        assert!(result.is_ok(), "turn should succeed even without event receivers: {result:?}");
    }

    #[tokio::test]
    async fn tool_output_truncated_when_too_large() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        let tool_call = ToolCallBlock {
            id: tron_core::ids::ToolCallId::new(),
            name: "LargeOutput".into(),
            arguments: serde_json::json!({}),
            thought_signature: None,
        };

        let provider = Arc::new(MockProvider::new(vec![
            tool_call_response("LargeOutput", &tool_call),
            MockResponse::stream_text("done"),
        ]));

        let output_size = 512 * 1024; // 512KB — exceeds 256KB default
        let mut tool_registry = ToolRegistry::new();
        tool_registry.register(
            Arc::new(LargeOutputTool { output_size }),
            crate::registry::ToolSource::BuiltIn,
        );

        let hook_engine = Arc::new(HookEngine::new());
        let context_config = ContextConfig {
            project_root: PathBuf::from("/tmp"),
            working_directory: PathBuf::from("/tmp"),
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        let turn_runner = TurnRunner::new(
            provider,
            Arc::new(tool_registry),
            hook_engine,
            db,
            tx.clone(),
            PathBuf::from("/tmp"),
        );

        let runner_config = RunnerConfig::default();
        let agent_runner = AgentRunner::new(turn_runner, runner_config, tx);
        let agent_id = AgentId::new();
        let cancel = CancellationToken::new();

        let mut messages = vec![Message::user_text("generate large output")];
        let result = agent_runner
            .run(&context_manager, &mut messages, &sess_id, &agent_id, &ws_id, &cancel)
            .await;

        assert!(result.is_ok());

        // Find the tool result message and verify it was truncated
        let tool_result = messages
            .iter()
            .filter_map(tool_result_text)
            .find(|text| text.contains("truncated") || text.len() < output_size);
        assert!(
            tool_result.is_some(),
            "expected truncated output in messages"
        );

        let text = tool_result.unwrap();
        assert!(
            text.contains("[truncated:"),
            "expected truncation marker, got len={}",
            text.len()
        );
        // Truncated output should be much smaller than 512KB
        assert!(
            text.len() < 300 * 1024,
            "output should be truncated to ~256KB, got {} bytes",
            text.len()
        );
    }
}
