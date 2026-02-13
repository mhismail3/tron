//! Agent runner — wraps `TronAgent` with orchestrator integration.
//!
//! Handles skill injection, background hook draining, and
//! the critical `agent.complete` → `agent.ready` ordering.

use std::sync::Arc;

use tron_core::events::{BaseEvent, TronEvent};
use tron_hooks::engine::HookEngine;

use crate::agent::event_emitter::EventEmitter;
use crate::agent::tron_agent::TronAgent;
use crate::types::{RunContext, RunResult};

/// Run an agent with orchestrator integration.
///
/// This wraps `TronAgent::run` with:
/// 1. Pre-run: drain background hooks from previous run
/// 2. Build and inject `RunContext` (skills, tasks, subagent results)
/// 3. Execute `agent.run(content, ctx)`
/// 4. Post-run: emit `agent.complete`
/// 5. Post-run: drain background hooks
/// 6. Post-run: emit `agent.ready` (MUST be after `agent.complete`)
pub async fn run_agent(
    agent: &mut TronAgent,
    content: &str,
    ctx: RunContext,
    hooks: &Option<Arc<HookEngine>>,
    broadcast: &Arc<EventEmitter>,
) -> RunResult {
    let session_id = agent.session_id().to_owned();

    // 1. Drain background hooks from previous run
    if let Some(hook_engine) = hooks {
        hook_engine.wait_for_background().await;
    }

    // 2. Forward agent events to broadcast channel
    let mut agent_rx = agent.subscribe();
    let broadcast_clone = broadcast.clone();
    let forward_handle = tokio::spawn(async move {
        while let Ok(event) = agent_rx.recv().await {
            broadcast_clone.emit(event);
        }
    });

    // 3. Run the agent
    let result = agent.run(content, ctx).await;

    // Stop event forwarding
    forward_handle.abort();

    // 4. Emit agent.complete (via the broadcast channel)
    broadcast.emit(TronEvent::AgentEnd {
        base: BaseEvent::now(&session_id),
        error: result.error.clone(),
    });

    // 5. Drain background hooks
    if let Some(hook_engine) = hooks {
        hook_engine.wait_for_background().await;
    }

    // 6. Emit agent.ready — MUST be AFTER agent.complete
    broadcast.emit(TronEvent::AgentReady {
        base: BaseEvent::now(&session_id),
    });

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use crate::errors::StopReason;
    use futures::stream;
    use tron_context::context_manager::ContextManager;
    use tron_context::types::ContextManagerConfig;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::ProviderType;
    use tron_llm::provider::{ProviderError, ProviderStreamOptions, StreamEventStream};
    use tron_tools::registry::ToolRegistry;

    use crate::types::AgentConfig;

    struct MockProvider;
    #[async_trait]
    impl tron_llm::provider::Provider for MockProvider {
        fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
        fn model(&self) -> &str { "mock" }
        async fn stream(&self, _c: &tron_core::messages::Context, _o: &ProviderStreamOptions)
            -> Result<StreamEventStream, ProviderError> {
            let s = stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta { delta: "Hello".into() }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("Hello")],
                        token_usage: Some(TokenUsage { input_tokens: 10, output_tokens: 5, ..Default::default() }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ]);
            Ok(Box::pin(s))
        }
    }

    fn make_agent() -> TronAgent {
        TronAgent::new(
            AgentConfig::default(),
            Arc::new(MockProvider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ContextManagerConfig {
                model: "mock".into(),
                system_prompt: None,
                working_directory: None,
                tools: vec![],
                rules_content: None,
                compaction: tron_context::types::CompactionConfig::default(),
            }),
            "test-session".into(),
        )
    }

    #[tokio::test]
    async fn run_agent_emits_complete_then_ready() {
        let mut agent = make_agent();
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(
            &mut agent,
            "Hello",
            RunContext::default(),
            &None,
            &broadcast,
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert_eq!(result.turns_executed, 1);

        // Collect broadcast events
        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        // agent.complete (agent_end) must come before agent.ready
        let complete_pos = event_types.iter().position(|t| t == "agent_end");
        let ready_pos = event_types.iter().position(|t| t == "agent_ready");

        assert!(complete_pos.is_some(), "agent_end must be emitted");
        assert!(ready_pos.is_some(), "agent_ready must be emitted");
        assert!(
            complete_pos.unwrap() < ready_pos.unwrap(),
            "agent_end must come before agent_ready"
        );
    }

    #[tokio::test]
    async fn run_agent_with_skill_context() {
        let mut agent = make_agent();
        let broadcast = Arc::new(EventEmitter::new());

        let ctx = RunContext {
            skill_context: Some("You are a code reviewer.".into()),
            ..Default::default()
        };

        let result = run_agent(&mut agent, "Review code", ctx, &None, &broadcast).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);
    }

    #[tokio::test]
    async fn run_agent_with_task_context() {
        let mut agent = make_agent();
        let broadcast = Arc::new(EventEmitter::new());

        let ctx = RunContext {
            task_context: Some("Active tasks: Fix bug #123".into()),
            ..Default::default()
        };

        let result = run_agent(&mut agent, "What tasks?", ctx, &None, &broadcast).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);
    }

    #[tokio::test]
    async fn run_agent_error_still_emits_ready() {
        struct ErrorProvider;
        #[async_trait]
        impl tron_llm::provider::Provider for ErrorProvider {
            fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
            fn model(&self) -> &str { "mock" }
            async fn stream(&self, _c: &tron_core::messages::Context, _o: &ProviderStreamOptions)
                -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth { message: "expired".into() })
            }
        }

        let mut agent = TronAgent::new(
            AgentConfig::default(),
            Arc::new(ErrorProvider),
            ToolRegistry::new(),
            None,
            None,
            ContextManager::new(ContextManagerConfig {
                model: "mock".into(),
                system_prompt: None,
                working_directory: None,
                tools: vec![],
                rules_content: None,
                compaction: tron_context::types::CompactionConfig::default(),
            }),
            "test-session".into(),
        );

        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hi", RunContext::default(), &None, &broadcast).await;
        assert_eq!(result.stop_reason, StopReason::Error);

        // Should still emit agent_ready after error
        let mut saw_ready = false;
        while let Ok(event) = rx.try_recv() {
            if event.event_type() == "agent_ready" {
                saw_ready = true;
            }
        }
        assert!(saw_ready, "agent_ready must be emitted even after error");
    }
}
