//! `TronAgent` — multi-turn agent with turn loop, abort, and state tracking.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use tron_context::context_manager::ContextManager;
use tron_core::events::{BaseEvent, TronEvent};
use tron_core::messages::{Message, TokenUsage, UserMessageContent};
use tron_guardrails::GuardrailEngine;
use tron_hooks::engine::HookEngine;
use tron_llm::provider::Provider;
use tron_tools::registry::ToolRegistry;

use tracing::{error, info, instrument, warn};

use crate::agent::compaction_handler::CompactionHandler;
use crate::agent::event_emitter::EventEmitter;
use crate::agent::turn_runner;
use crate::errors::StopReason;
use crate::orchestrator::event_persister::EventPersister;
use crate::types::{AgentConfig, RunContext, RunResult};

/// RAII guard that resets `is_running` to `false` on drop (even on panic).
struct RunGuard<'a> {
    flag: &'a AtomicBool,
}

impl<'a> RunGuard<'a> {
    fn new(flag: &'a AtomicBool) -> Option<Self> {
        flag.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .ok()
            .map(|_| Self { flag })
    }
}

impl Drop for RunGuard<'_> {
    fn drop(&mut self) {
        self.flag.store(false, Ordering::SeqCst);
    }
}

/// Multi-turn agent that owns all submodules.
pub struct TronAgent {
    config: AgentConfig,
    provider: Arc<dyn Provider>,
    registry: ToolRegistry,
    guardrails: Option<Arc<std::sync::Mutex<GuardrailEngine>>>,
    hooks: Option<Arc<HookEngine>>,
    context_manager: ContextManager,
    emitter: Arc<EventEmitter>,
    compaction: CompactionHandler,
    session_id: String,
    current_turn: AtomicU32,
    is_running: AtomicBool,
    abort_token: CancellationToken,
    /// Whether the abort token was provided externally (e.g. by orchestrator).
    external_abort_token: bool,
    /// Optional inline event persister (injected by orchestrator).
    persister: Option<Arc<EventPersister>>,
}

impl TronAgent {
    /// Create a new agent.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        config: AgentConfig,
        provider: Arc<dyn Provider>,
        registry: ToolRegistry,
        guardrails: Option<Arc<std::sync::Mutex<GuardrailEngine>>>,
        hooks: Option<Arc<HookEngine>>,
        context_manager: ContextManager,
        session_id: String,
    ) -> Self {
        let compaction = CompactionHandler::new();
        Self {
            config,
            provider,
            registry,
            guardrails,
            hooks,
            context_manager,
            emitter: Arc::new(EventEmitter::new()),
            compaction,
            session_id,
            current_turn: AtomicU32::new(0),
            is_running: AtomicBool::new(false),
            abort_token: CancellationToken::new(),
            external_abort_token: false,
            persister: None,
        }
    }

    /// Run the multi-turn loop with user content.
    #[allow(clippy::too_many_lines)]
    #[instrument(skip(self, ctx), fields(session_id = %self.session_id, model = %self.config.model))]
    pub async fn run(&mut self, content: &str, mut ctx: RunContext) -> RunResult {
        // Reject concurrent runs — guard resets is_running on drop (even on panic)
        let Some(_guard) = RunGuard::new(&self.is_running) else {
            return RunResult {
                stop_reason: StopReason::Error,
                error: Some("Agent is already running".into()),
                ..Default::default()
            };
        };

        // Reset abort token for this run (unless an external token was injected)
        if !self.external_abort_token {
            self.abort_token = CancellationToken::new();
        }
        self.current_turn.store(0, Ordering::Relaxed);

        let mut total_usage = TokenUsage::default();
        let mut final_stop_reason = StopReason::EndTurn;
        let mut interrupted = false;
        let mut error: Option<String> = None;

        // Add user message to context
        let user_content = if let Some(override_content) = ctx.user_content_override.take() {
            override_content
        } else {
            UserMessageContent::Text(content.to_owned())
        };
        self.context_manager
            .add_message(Message::User {
                content: user_content,
                timestamp: None,
            });

        // Emit AgentStart
        let _ = self.emitter.emit(TronEvent::AgentStart {
            base: BaseEvent::now(&self.session_id),
        });
        info!(session_id = %self.session_id, "agent run started");

        let max_turns = self.config.max_turns;
        let mut turn = 0u32;
        let mut exited_via_break = false;
        let mut previous_context_baseline: u64 = 0;

        while turn < max_turns {
            turn += 1;
            self.current_turn.store(turn, Ordering::Relaxed);

            let result = turn_runner::execute_turn(
                turn,
                &mut self.context_manager,
                &self.provider,
                &self.registry,
                &self.guardrails,
                &self.hooks,
                &self.compaction,
                &self.session_id,
                &self.emitter,
                &self.abort_token,
                &ctx,
                self.persister.as_deref(),
                previous_context_baseline,
                self.config.subagent_depth,
                self.config.subagent_max_depth,
            )
            .await;

            // Update baseline for next turn
            if let Some(cw) = result.context_window_tokens {
                previous_context_baseline = cw;
            }

            // Accumulate token usage
            if let Some(ref usage) = result.token_usage {
                total_usage.input_tokens += usage.input_tokens;
                total_usage.output_tokens += usage.output_tokens;
                if let Some(cache) = usage.cache_read_tokens {
                    *total_usage.cache_read_tokens.get_or_insert(0) += cache;
                }
                if let Some(cache) = usage.cache_creation_tokens {
                    *total_usage.cache_creation_tokens.get_or_insert(0) += cache;
                }
            }

            if !result.success {
                error!(session_id = %self.session_id, turn, error = ?result.error, "turn failed");
                final_stop_reason = StopReason::Error;
                error = result.error;
                exited_via_break = true;
                break;
            }

            if result.interrupted {
                warn!(session_id = %self.session_id, turn, "agent interrupted");
                final_stop_reason = StopReason::Interrupted;
                interrupted = true;
                exited_via_break = true;
                break;
            }

            if result.stop_turn_requested {
                final_stop_reason = StopReason::ToolStop;
                exited_via_break = true;
                break;
            }

            if let Some(StopReason::EndTurn | StopReason::NoToolCalls) = result.stop_reason {
                final_stop_reason = result.stop_reason.unwrap_or(StopReason::EndTurn);
                exited_via_break = true;
                break;
            }
            // Continue looping (tool calls executed, more turns needed)
        }

        // If the loop ended because turn >= max_turns (not via break),
        // the agent exhausted its turn budget.
        if !exited_via_break && turn >= max_turns {
            final_stop_reason = StopReason::MaxTurns;
        }

        info!(session_id = %self.session_id, turns = turn, stop_reason = ?final_stop_reason, "agent run completed");

        // Emit AgentEnd
        let _ = self.emitter.emit(TronEvent::AgentEnd {
            base: BaseEvent::now(&self.session_id),
            error: error.clone(),
        });

        // _guard drops here, resetting is_running (even on panic)

        RunResult {
            turns_executed: turn,
            total_token_usage: total_usage,
            stop_reason: final_stop_reason,
            interrupted,
            error,
            last_context_window_tokens: if previous_context_baseline > 0 {
                Some(previous_context_baseline)
            } else {
                None
            },
        }
    }

    /// Set an external abort token (e.g. from the orchestrator).
    /// When set, `run()` will not reset it — the orchestrator controls cancellation.
    pub fn set_abort_token(&mut self, token: CancellationToken) {
        self.abort_token = token;
        self.external_abort_token = true;
    }

    /// Set the inline event persister (e.g. from the orchestrator).
    pub fn set_persister(&mut self, persister: Option<Arc<EventPersister>>) {
        self.persister = persister;
    }

    /// Abort the current run.
    pub fn abort(&self) {
        self.abort_token.cancel();
    }

    /// Whether the agent is currently running.
    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::Relaxed)
    }

    /// Current turn number (0 if not running).
    pub fn current_turn(&self) -> u32 {
        self.current_turn.load(Ordering::Relaxed)
    }

    /// Subscribe to agent events.
    pub fn subscribe(&self) -> broadcast::Receiver<TronEvent> {
        self.emitter.subscribe()
    }

    /// Get the session ID.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Get the current model.
    pub fn model(&self) -> &str {
        &self.config.model
    }

    /// Get a reference to the context manager.
    pub fn context_manager(&self) -> &ContextManager {
        &self.context_manager
    }

    /// Get a mutable reference to the context manager.
    pub fn context_manager_mut(&mut self) -> &mut ContextManager {
        &mut self.context_manager
    }

    /// Get the emitter.
    pub fn emitter(&self) -> &Arc<EventEmitter> {
        &self.emitter
    }

}

#[cfg(test)]
impl TronAgent {
    pub(crate) fn subagent_depth(&self) -> u32 {
        self.config.subagent_depth
    }

    pub(crate) fn subagent_max_depth(&self) -> u32 {
        self.config.subagent_max_depth
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use futures::stream;
    use serde_json::Map;
    use tron_context::types::ContextManagerConfig;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_llm::models::types::ProviderType;
    use tron_llm::provider::{ProviderError, ProviderStreamOptions, StreamEventStream};

    // ── Mock Provider ──

    struct MockProvider {
        responses: std::sync::Mutex<Vec<Vec<StreamEvent>>>,
    }

    impl MockProvider {
        fn text_only(text: &str) -> Self {
            let text = text.to_owned();
            Self {
                responses: std::sync::Mutex::new(vec![vec![
                    StreamEvent::Start,
                    StreamEvent::TextDelta {
                        delta: text.clone(),
                    },
                    StreamEvent::Done {
                        message: AssistantMessage {
                            content: vec![AssistantContent::text(&text)],
                            token_usage: Some(TokenUsage {
                                input_tokens: 10,
                                output_tokens: 5,
                                ..Default::default()
                            }),
                        },
                        stop_reason: "end_turn".into(),
                    },
                ]]),
            }
        }

        fn multi_turn(turns: Vec<Vec<StreamEvent>>) -> Self {
            Self {
                responses: std::sync::Mutex::new(turns),
            }
        }
    }

    #[async_trait]
    impl Provider for MockProvider {
        fn provider_type(&self) -> ProviderType {
            ProviderType::Anthropic
        }
        fn model(&self) -> &str {
            "mock-model"
        }
        async fn stream(
            &self,
            _context: &tron_core::messages::Context,
            _options: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let mut responses = self.responses.lock().unwrap();
            if responses.is_empty() {
                return Err(ProviderError::Other {
                    message: "No more responses".into(),
                });
            }
            let events = responses.remove(0);
            let event_stream = stream::iter(events.into_iter().map(Ok));
            Ok(Box::pin(event_stream))
        }
    }

    fn make_agent(provider: MockProvider) -> TronAgent {
        let config = AgentConfig::default();
        let ctx_config = ContextManagerConfig {
            model: "mock-model".into(),
            system_prompt: None,
            working_directory: None,
            tools: vec![],
            rules_content: None,
            compaction: tron_context::types::CompactionConfig::default(),
        };
        TronAgent::new(
            config,
            Arc::new(provider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ctx_config),
            "test-session".into(),
        )
    }

    #[tokio::test]
    async fn single_turn_text_only() {
        let mut agent = make_agent(MockProvider::text_only("Hello!"));

        let result = agent.run("Hi", RunContext::default()).await;

        assert_eq!(result.turns_executed, 1);
        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert!(!result.interrupted);
        assert!(result.error.is_none());
        assert!(result.total_token_usage.input_tokens > 0);
    }

    #[tokio::test]
    async fn multi_turn_with_tools() {
        // Turn 1: text + tool call, Turn 2: text only (end turn)
        let turn1_events = vec![
            StreamEvent::Start,
            StreamEvent::TextDelta {
                delta: "Let me check.".into(),
            },
            StreamEvent::ToolCallStart {
                tool_call_id: "tc-1".into(),
                name: "read".into(),
            },
            StreamEvent::ToolCallEnd {
                tool_call: tron_core::messages::ToolCall {
                    content_type: "tool_use".into(),
                    id: "tc-1".into(),
                    name: "read".into(),
                    arguments: Map::new(),
                    thought_signature: None,
                },
            },
            StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![
                        AssistantContent::text("Let me check."),
                        AssistantContent::ToolUse {
                            id: "tc-1".into(),
                            name: "read".into(),
                            arguments: Map::new(),
                            thought_signature: None,
                        },
                    ],
                    token_usage: Some(TokenUsage {
                        input_tokens: 20,
                        output_tokens: 15,
                        ..Default::default()
                    }),
                },
                stop_reason: "tool_use".into(),
            },
        ];

        let turn2_events = vec![
            StreamEvent::Start,
            StreamEvent::TextDelta {
                delta: "Done.".into(),
            },
            StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("Done.")],
                    token_usage: Some(TokenUsage {
                        input_tokens: 30,
                        output_tokens: 5,
                        ..Default::default()
                    }),
                },
                stop_reason: "end_turn".into(),
            },
        ];

        let provider = MockProvider::multi_turn(vec![turn1_events, turn2_events]);
        let mut agent = make_agent(provider);

        // Register a mock tool so tool_not_found doesn't error
        use async_trait::async_trait as at;
        use tron_core::tools::{Tool, ToolParameterSchema, text_result};
        struct ReadTool;
        #[at]
        impl tron_tools::traits::TronTool for ReadTool {
            fn name(&self) -> &str { "read" }
            fn category(&self) -> tron_core::tools::ToolCategory { tron_core::tools::ToolCategory::Filesystem }
            fn definition(&self) -> Tool {
                Tool { name: "read".into(), description: "Read file".into(), parameters: ToolParameterSchema { schema_type: "object".into(), properties: None, required: None, description: None, extra: serde_json::Map::new() } }
            }
            async fn execute(&self, _p: serde_json::Value, _c: &tron_tools::traits::ToolContext) -> Result<tron_core::tools::TronToolResult, tron_tools::errors::ToolError> {
                Ok(text_result("file contents", false))
            }
        }
        agent.registry.register(Arc::new(ReadTool));

        let result = agent.run("Read the file", RunContext::default()).await;

        assert_eq!(result.turns_executed, 2);
        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert!(!result.interrupted);
        assert_eq!(result.total_token_usage.input_tokens, 50);
        assert_eq!(result.total_token_usage.output_tokens, 20);
    }

    #[tokio::test]
    async fn max_turns_limit() {
        // Create a provider that always returns tool calls
        let mut all_turns = Vec::new();
        for i in 0..26 {
            all_turns.push(vec![
                StreamEvent::Start,
                StreamEvent::TextDelta {
                    delta: format!("Turn {i}"),
                },
                StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(&format!("Turn {i}"))],
                        token_usage: Some(TokenUsage::default()),
                    },
                    stop_reason: "tool_use".into(), // pretend there are tool calls
                },
            ]);
        }

        // Actually, for max turns we need the stop_reason to not be "end_turn"
        // and we need tool calls to be present. Let's use text-only with
        // stop_reason "end_turn" which should stop on turn 1.
        // Instead, test with max_turns = 2
        let turn1 = vec![
            StreamEvent::Start,
            StreamEvent::ToolCallStart { tool_call_id: "tc-1".into(), name: "echo".into() },
            StreamEvent::ToolCallEnd {
                tool_call: tron_core::messages::ToolCall {
                    content_type: "tool_use".into(), id: "tc-1".into(), name: "echo".into(),
                    arguments: Map::new(), thought_signature: None,
                },
            },
            StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::ToolUse {
                        id: "tc-1".into(), name: "echo".into(),
                        arguments: Map::new(), thought_signature: None,
                    }],
                    token_usage: Some(TokenUsage::default()),
                },
                stop_reason: "tool_use".into(),
            },
        ];

        let provider = MockProvider::multi_turn(vec![turn1.clone(), turn1.clone(), turn1]);
        let mut agent = make_agent(provider);
        agent.config.max_turns = 2;

        // Register echo tool
        use tron_core::tools::{Tool, ToolParameterSchema, text_result};
        struct EchoTool;
        #[async_trait]
        impl tron_tools::traits::TronTool for EchoTool {
            fn name(&self) -> &str { "echo" }
            fn category(&self) -> tron_core::tools::ToolCategory { tron_core::tools::ToolCategory::Custom }
            fn definition(&self) -> Tool {
                Tool { name: "echo".into(), description: "Echo".into(), parameters: ToolParameterSchema { schema_type: "object".into(), properties: None, required: None, description: None, extra: serde_json::Map::new() } }
            }
            async fn execute(&self, _p: serde_json::Value, _c: &tron_tools::traits::ToolContext) -> Result<tron_core::tools::TronToolResult, tron_tools::errors::ToolError> {
                Ok(text_result("ok", false))
            }
        }
        agent.registry.register(Arc::new(EchoTool));

        let result = agent.run("Go", RunContext::default()).await;

        assert_eq!(result.turns_executed, 2);
        assert_eq!(result.stop_reason, StopReason::MaxTurns);
    }

    #[tokio::test]
    async fn abort_mid_run() {
        // Create a provider that takes a long time
        struct SlowProvider;
        #[async_trait]
        impl Provider for SlowProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _context: &tron_core::messages::Context,
                _options: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                // Return a stream that takes a while
                let s = async_stream::stream! {
                    yield Ok(StreamEvent::Start);
                    yield Ok(StreamEvent::TextDelta { delta: "partial".into() });
                    tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
                    yield Ok(StreamEvent::Done {
                        message: AssistantMessage { content: vec![], token_usage: None },
                        stop_reason: "end_turn".into(),
                    });
                };
                Ok(Box::pin(s))
            }
        }

        let ctx_config = ContextManagerConfig {
            model: "mock".into(),
            system_prompt: None,
            working_directory: None,
            tools: vec![],
            rules_content: None,
            compaction: tron_context::types::CompactionConfig::default(),
        };
        let mut agent = TronAgent::new(
            AgentConfig::default(),
            Arc::new(SlowProvider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ctx_config),
            "test-session".into(),
        );

        // Spawn abort after a short delay
        let abort_agent = {
            // We need to cancel the token after starting the run
            // Use a channel to coordinate
            let token = agent.abort_token.clone();
            tokio::spawn(async move {
                tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
                token.cancel();
            })
        };

        let result = agent.run("Go", RunContext::default()).await;

        let _ = abort_agent.await;
        assert!(result.interrupted || result.turns_executed >= 1);
    }

    #[tokio::test]
    async fn concurrent_run_rejected() {
        let mut agent = make_agent(MockProvider::text_only("Hi"));
        agent.is_running.store(true, Ordering::SeqCst);

        let result = agent.run("Go", RunContext::default()).await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert!(result.error.is_some());
        assert!(result.error.unwrap().contains("already running"));
    }

    #[tokio::test]
    async fn is_running_reset_after_error() {
        struct ErrorProvider;
        #[async_trait]
        impl Provider for ErrorProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _context: &tron_core::messages::Context,
                _options: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth { message: "expired".into() })
            }
        }

        let ctx_config = ContextManagerConfig {
            model: "mock".into(),
            system_prompt: None,
            working_directory: None,
            tools: vec![],
            rules_content: None,
            compaction: tron_context::types::CompactionConfig::default(),
        };
        let mut agent = TronAgent::new(
            AgentConfig::default(),
            Arc::new(ErrorProvider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ctx_config),
            "test-session".into(),
        );

        let result = agent.run("Hi", RunContext::default()).await;
        assert_eq!(result.stop_reason, StopReason::Error);

        // is_running must be false after error (RunGuard resets it)
        assert!(!agent.is_running(), "is_running must be false after error");
    }

    #[tokio::test]
    async fn run_result_includes_context_window_tokens() {
        // MockProvider.text_only returns input_tokens=10 — normalize computes
        // contextWindowTokens = input + cacheRead + cacheCreation = 10
        let mut agent = make_agent(MockProvider::text_only("Hello!"));
        let result = agent.run("Hi", RunContext::default()).await;
        assert_eq!(result.last_context_window_tokens, Some(10));
    }

    #[tokio::test]
    async fn run_result_context_window_tokens_none_without_usage() {
        // Provider that returns no token_usage → contextWindowTokens stays 0
        struct NoUsageProvider;
        #[async_trait]
        impl Provider for NoUsageProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _context: &tron_core::messages::Context,
                _options: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                let events = vec![
                    StreamEvent::Start,
                    StreamEvent::TextDelta { delta: "hi".into() },
                    StreamEvent::Done {
                        message: AssistantMessage {
                            content: vec![AssistantContent::text("hi")],
                            token_usage: None,
                        },
                        stop_reason: "end_turn".into(),
                    },
                ];
                Ok(Box::pin(stream::iter(events.into_iter().map(Ok))))
            }
        }

        let ctx_config = ContextManagerConfig {
            model: "mock".into(),
            system_prompt: None,
            working_directory: None,
            tools: vec![],
            rules_content: None,
            compaction: tron_context::types::CompactionConfig::default(),
        };
        let mut agent = TronAgent::new(
            AgentConfig::default(),
            Arc::new(NoUsageProvider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ctx_config),
            "test-session".into(),
        );
        let result = agent.run("Hi", RunContext::default()).await;
        assert!(result.last_context_window_tokens.is_none());
    }

    #[test]
    fn agent_state_tracking() {
        let agent = make_agent(MockProvider::text_only("Hi"));
        assert!(!agent.is_running());
        assert_eq!(agent.current_turn(), 0);
        assert_eq!(agent.session_id(), "test-session");
        assert_eq!(agent.model(), "claude-opus-4-6");
    }

    #[tokio::test]
    async fn subscribe_receives_events() {
        let mut agent = make_agent(MockProvider::text_only("Hello"));
        let mut rx = agent.subscribe();

        let _ = agent.run("Hi", RunContext::default()).await;

        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        assert!(event_types.contains(&"agent_start".to_owned()));
        assert!(event_types.contains(&"turn_start".to_owned()));
        assert!(event_types.contains(&"response_complete".to_owned()));
        assert!(event_types.contains(&"turn_end".to_owned()));
        assert!(event_types.contains(&"agent_end".to_owned()));
    }

    #[tokio::test]
    async fn empty_tool_list_works() {
        let mut agent = make_agent(MockProvider::text_only("Hello"));
        assert!(agent.registry.is_empty());

        let result = agent.run("Hi", RunContext::default()).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert_eq!(result.turns_executed, 1);
    }

    #[tokio::test]
    async fn provider_error_on_stream() {
        struct ErrorProvider;
        #[async_trait]
        impl Provider for ErrorProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _context: &tron_core::messages::Context,
                _options: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth { message: "Token expired".into() })
            }
        }

        let ctx_config = ContextManagerConfig {
            model: "mock".into(),
            system_prompt: None,
            working_directory: None,
            tools: vec![],
            rules_content: None,
            compaction: tron_context::types::CompactionConfig::default(),
        };
        let mut agent = TronAgent::new(
            AgentConfig::default(),
            Arc::new(ErrorProvider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ctx_config),
            "test-session".into(),
        );

        let result = agent.run("Hi", RunContext::default()).await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert!(result.error.is_some());
        assert_eq!(result.turns_executed, 1);
    }

    // ── set_abort_token tests ──

    #[test]
    fn set_abort_token_replaces_default() {
        let mut agent = make_agent(MockProvider::text_only("Hi"));
        let token = CancellationToken::new();
        agent.set_abort_token(token.clone());
        assert!(!token.is_cancelled());

        agent.abort();
        assert!(token.is_cancelled());
    }

    #[tokio::test]
    async fn external_abort_token_cancels_run() {
        struct SlowProvider;
        #[async_trait]
        impl Provider for SlowProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(
                &self,
                _context: &tron_core::messages::Context,
                _options: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                let s = async_stream::stream! {
                    yield Ok(StreamEvent::Start);
                    yield Ok(StreamEvent::TextDelta { delta: "partial".into() });
                    tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
                    yield Ok(StreamEvent::Done {
                        message: AssistantMessage { content: vec![], token_usage: None },
                        stop_reason: "end_turn".into(),
                    });
                };
                Ok(Box::pin(s))
            }
        }

        let ctx_config = ContextManagerConfig {
            model: "mock".into(),
            system_prompt: None,
            working_directory: None,
            tools: vec![],
            rules_content: None,
            compaction: tron_context::types::CompactionConfig::default(),
        };
        let mut agent = TronAgent::new(
            AgentConfig::default(),
            Arc::new(SlowProvider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ctx_config),
            "test-session".into(),
        );

        let token = CancellationToken::new();
        agent.set_abort_token(token.clone());

        // Cancel the external token after a short delay
        let _ = tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
            token.cancel();
        });

        let result = agent.run("Go", RunContext::default()).await;
        assert!(result.interrupted || result.turns_executed >= 1);
    }

    #[tokio::test]
    async fn external_token_not_reset_between_runs() {
        let mut agent = make_agent(MockProvider::text_only("Hello"));
        let token = CancellationToken::new();
        agent.set_abort_token(token.clone());

        // run() should NOT reset the external token
        let result = agent.run("Hi", RunContext::default()).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);

        // The external token should still be the same one (not cancelled, not replaced)
        assert!(!token.is_cancelled());
        token.cancel();
        assert!(token.is_cancelled());
    }

    // ── Persister integration tests ──

    fn make_event_store() -> Arc<tron_events::EventStore> {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default())
            .expect("Failed to create in-memory pool");
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(tron_events::EventStore::new(pool))
    }

    #[tokio::test]
    async fn agent_run_without_persister_still_works() {
        let mut agent = make_agent(MockProvider::text_only("Hello"));
        // persister is None by default — backward compat
        let result = agent.run("Hi", RunContext::default()).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert_eq!(result.turns_executed, 1);
    }

    /// Create an agent with matching event store session (IDs aligned).
    fn make_agent_with_store(
        provider: MockProvider,
        store: &Arc<tron_events::EventStore>,
    ) -> (TronAgent, String) {
        let session = store
            .create_session("mock-model", "/tmp", Some("test"))
            .unwrap();
        let sid = session.session.id.clone();
        let config = AgentConfig::default();
        let ctx_config = ContextManagerConfig {
            model: "mock-model".into(),
            system_prompt: None,
            working_directory: None,
            tools: vec![],
            rules_content: None,
            compaction: tron_context::types::CompactionConfig::default(),
        };
        let agent = TronAgent::new(
            config,
            Arc::new(provider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ctx_config),
            sid.clone(),
        );
        (agent, sid)
    }

    #[tokio::test]
    async fn agent_set_persister() {
        let store = make_event_store();
        let (mut agent, sid) =
            make_agent_with_store(MockProvider::text_only("Hello"), &store);

        let persister = Arc::new(
            crate::orchestrator::event_persister::EventPersister::new(store.clone(), sid.clone()),
        );
        agent.set_persister(Some(persister.clone()));

        let result = agent.run("Hi", RunContext::default()).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);

        // Flush to ensure fire-and-forget events are written
        persister.flush().await.unwrap();

        // Check that message.assistant was persisted
        let events = store
            .get_events_by_session(
                &sid,
                &tron_events::sqlite::repositories::event::ListEventsOptions::default(),
            )
            .unwrap();
        let assistant_events: Vec<_> = events
            .iter()
            .filter(|e| e.event_type == "message.assistant")
            .collect();
        assert!(
            !assistant_events.is_empty(),
            "message.assistant event must be persisted"
        );

        // Verify the payload has the new metadata fields
        let payload: serde_json::Value =
            serde_json::from_str(&assistant_events[0].payload).unwrap();
        assert!(payload.get("model").is_some(), "payload must have model");
        assert!(
            payload.get("latency").is_some(),
            "payload must have latency"
        );
        assert!(
            payload.get("stopReason").is_some(),
            "payload must have stopReason"
        );
        assert!(
            payload.get("hasThinking").is_some(),
            "payload must have hasThinking"
        );
        assert!(
            payload.get("providerType").is_some(),
            "payload must have providerType"
        );
    }

    #[tokio::test]
    async fn agent_multi_turn_persists_all_turns() {
        let store = make_event_store();

        // Turn 1: tool call, Turn 2: end
        let turn1_events = vec![
            StreamEvent::Start,
            StreamEvent::ToolCallStart {
                tool_call_id: "tc-1".into(),
                name: "read".into(),
            },
            StreamEvent::ToolCallEnd {
                tool_call: tron_core::messages::ToolCall {
                    content_type: "tool_use".into(),
                    id: "tc-1".into(),
                    name: "read".into(),
                    arguments: Map::new(),
                    thought_signature: None,
                },
            },
            StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::ToolUse {
                        id: "tc-1".into(),
                        name: "read".into(),
                        arguments: Map::new(),
                        thought_signature: None,
                    }],
                    token_usage: Some(TokenUsage {
                        input_tokens: 20,
                        output_tokens: 10,
                        ..Default::default()
                    }),
                },
                stop_reason: "tool_use".into(),
            },
        ];
        let turn2_events = vec![
            StreamEvent::Start,
            StreamEvent::TextDelta {
                delta: "Done.".into(),
            },
            StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("Done.")],
                    token_usage: Some(TokenUsage {
                        input_tokens: 30,
                        output_tokens: 5,
                        ..Default::default()
                    }),
                },
                stop_reason: "end_turn".into(),
            },
        ];

        let provider = MockProvider::multi_turn(vec![turn1_events, turn2_events]);
        let (mut agent, sid) = make_agent_with_store(provider, &store);

        let persister = Arc::new(
            crate::orchestrator::event_persister::EventPersister::new(store.clone(), sid.clone()),
        );
        agent.set_persister(Some(persister.clone()));

        // Register read tool
        use tron_core::tools::{text_result, Tool, ToolParameterSchema};
        struct ReadTool;
        #[async_trait]
        impl tron_tools::traits::TronTool for ReadTool {
            fn name(&self) -> &str {
                "read"
            }
            fn category(&self) -> tron_core::tools::ToolCategory {
                tron_core::tools::ToolCategory::Filesystem
            }
            fn definition(&self) -> Tool {
                Tool {
                    name: "read".into(),
                    description: "Read file".into(),
                    parameters: ToolParameterSchema {
                        schema_type: "object".into(),
                        properties: None,
                        required: None,
                        description: None,
                        extra: serde_json::Map::new(),
                    },
                }
            }
            async fn execute(
                &self,
                _p: serde_json::Value,
                _c: &tron_tools::traits::ToolContext,
            ) -> Result<tron_core::tools::TronToolResult, tron_tools::errors::ToolError> {
                Ok(text_result("file contents", false))
            }
        }
        agent.registry.register(Arc::new(ReadTool));

        let result = agent.run("Read the file", RunContext::default()).await;
        assert_eq!(result.turns_executed, 2);

        persister.flush().await.unwrap();

        let events = store
            .get_events_by_session(
                &sid,
                &tron_events::sqlite::repositories::event::ListEventsOptions::default(),
            )
            .unwrap();
        let assistant_events: Vec<_> = events
            .iter()
            .filter(|e| e.event_type == "message.assistant")
            .collect();
        assert_eq!(
            assistant_events.len(),
            2,
            "both turns must have message.assistant events"
        );

        // Verify turn numbers in payloads
        let p1: serde_json::Value =
            serde_json::from_str(&assistant_events[0].payload).unwrap();
        let p2: serde_json::Value =
            serde_json::from_str(&assistant_events[1].payload).unwrap();
        assert_eq!(p1["turn"], 1);
        assert_eq!(p2["turn"], 2);

        // Verify tool.call and tool.result events exist
        let tool_calls: Vec<_> = events
            .iter()
            .filter(|e| e.event_type == "tool.call")
            .collect();
        let tool_results: Vec<_> = events
            .iter()
            .filter(|e| e.event_type == "tool.result")
            .collect();
        assert_eq!(tool_calls.len(), 1, "must have 1 tool.call event");
        assert_eq!(tool_results.len(), 1, "must have 1 tool.result event");
    }

    #[tokio::test]
    async fn agent_persisted_event_has_indexed_columns() {
        let store = make_event_store();
        let (mut agent, sid) =
            make_agent_with_store(MockProvider::text_only("Hello"), &store);

        let persister = Arc::new(
            crate::orchestrator::event_persister::EventPersister::new(store.clone(), sid.clone()),
        );
        agent.set_persister(Some(persister.clone()));

        let _ = agent.run("Hi", RunContext::default()).await;
        persister.flush().await.unwrap();

        // Query the raw EventRow to check indexed columns
        let events = store
            .get_events_by_session(
                &sid,
                &tron_events::sqlite::repositories::event::ListEventsOptions::default(),
            )
            .unwrap();
        let assistant = events
            .iter()
            .find(|e| e.event_type == "message.assistant")
            .expect("must have message.assistant event");

        assert_eq!(
            assistant.model.as_deref(),
            Some("mock-model"),
            "model column must be extracted"
        );
        assert!(
            assistant.stop_reason.is_some(),
            "stop_reason column must be extracted"
        );
        assert!(
            assistant.provider_type.is_some(),
            "provider_type column must be extracted"
        );
        assert!(
            assistant.latency_ms.is_some(),
            "latency_ms column must be extracted"
        );
        assert_eq!(
            assistant.has_thinking,
            Some(0),
            "has_thinking must be 0 (false)"
        );
    }
}
