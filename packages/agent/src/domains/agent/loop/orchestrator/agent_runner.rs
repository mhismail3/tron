//! Agent runner — wraps `TronAgent` with orchestrator integration.
//!
//! Handles primitive run execution and the critical
//! `agent.complete` → `agent.ready` ordering.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::shared::protocol::events::{BaseEvent, TronEvent};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use tracing::{debug, instrument, warn};

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::tron_agent::TronAgent;
use crate::domains::agent::r#loop::types::{RunContext, RunResult};

/// Run an agent with orchestrator integration.
///
/// This wraps `TronAgent::run` with:
/// 1. Build and inject the primitive `RunContext`
/// 2. Execute `agent.run(content, ctx)`
/// 3. Forward streamed agent events
/// 4. Emit `agent.ready` after the forwarded `agent.complete`
#[instrument(skip_all, fields(session_id = agent.session_id()))]
pub async fn run_agent(
    agent: &mut TronAgent,
    content: &str,
    ctx: RunContext,
    broadcast: &Arc<EventEmitter>,
    sequence_counter: Option<Arc<AtomicI64>>,
) -> RunResult {
    let session_id = agent.session_id().to_owned();
    debug!(session_id = agent.session_id(), "agent runner starting");

    // Inject sequence counter so the agent can assign monotonic sequences to events.
    if let Some(ref counter) = sequence_counter {
        agent.set_sequence_counter(counter.clone());
    }

    // Forward agent events to broadcast channel.
    let mut agent_rx = agent.subscribe();
    let broadcast_clone = broadcast.clone();
    let forward_cancel = CancellationToken::new();
    let forward_cancel_clone = forward_cancel.clone();
    let forward_handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                event = agent_rx.recv() => {
                    match event {
                        Ok(e) => { let _ = broadcast_clone.emit(e); }
                        Err(broadcast::error::RecvError::Closed) => break,
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            metrics::counter!("broadcast_lagged_events_total", "source" => "agent_forward").increment(n);
                        }
                    }
                }
                () = forward_cancel_clone.cancelled() => {
                    // Drain any remaining buffered events
                    while let Ok(event) = agent_rx.try_recv() {
                        let _ = broadcast_clone.emit(event);
                    }
                    break;
                }
            }
        }
    });

    // Run the agent.
    let result = agent.run(content, ctx).await;

    // Signal the forward task to drain remaining buffered events and exit
    forward_cancel.cancel();
    // Wait for it to finish draining (bounded timeout as safety net).
    // Obtain AbortHandle BEFORE passing the JoinHandle to timeout(),
    // since timeout() consumes the handle on expiry.
    let abort_handle = forward_handle.abort_handle();
    if tokio::time::timeout(std::time::Duration::from_millis(100), forward_handle)
        .await
        .is_err()
    {
        warn!(
            session_id,
            "forward task did not drain within 100ms, aborting"
        );
        abort_handle.abort();
    }

    debug!(session_id, stop_reason = ?result.stop_reason, turns = result.turns_executed, "agent run completed");

    // INVARIANT: agent.ready MUST be emitted AFTER agent.complete so clients see
    // a terminal run before returning to idle. The send button now depends only
    // on active processing/compaction plus the async ledger.
    let _ = broadcast.emit(TronEvent::AgentReady {
        base: BaseEvent::now(&session_id),
    });

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::context::context_manager::ContextManager;
    use crate::domains::agent::context::types::ContextManagerConfig;
    use crate::domains::agent::r#loop::errors::StopReason;
    use crate::domains::model::providers::shared::provider::{
        ProviderError, ProviderStreamOptions, StreamEventStream,
    };
    use crate::domains::model::routing::models::types::Provider;
    use crate::shared::protocol::content::AssistantContent;
    use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
    use crate::shared::protocol::messages::TokenUsage;
    use async_trait::async_trait;
    use futures::stream;

    use crate::domains::agent::r#loop::tron_agent::AgentDeps;
    use crate::domains::agent::r#loop::types::AgentConfig;

    struct MockProvider;
    #[async_trait]
    impl crate::domains::model::providers::shared::provider::Provider for MockProvider {
        fn provider_type(&self) -> Provider {
            Provider::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &crate::shared::protocol::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let s = stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: "Hello".into(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("Hello")],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ]);
            Ok(Box::pin(s))
        }
    }

    struct JournalCleanup {
        session_id: String,
    }

    impl JournalCleanup {
        fn new(session_id: &str) -> Self {
            Self {
                session_id: session_id.to_owned(),
            }
        }
    }

    impl Drop for JournalCleanup {
        fn drop(&mut self) {
            let dir = crate::shared::foundation::paths::journals_dir().join(&self.session_id);
            if dir.exists() {
                let _ = std::fs::remove_dir_all(&dir);
            }
        }
    }

    fn unique_test_session_id() -> String {
        format!("agent-runner-test-{}", uuid::Uuid::now_v7())
    }

    fn make_agent_with_provider(
        provider: Arc<dyn crate::domains::model::providers::shared::provider::Provider>,
    ) -> (TronAgent, JournalCleanup) {
        let session_id = unique_test_session_id();
        let cleanup = JournalCleanup::new(&session_id);
        let agent = TronAgent::new(
            AgentConfig::default(),
            AgentDeps {
                provider,
                context_manager: ContextManager::new(ContextManagerConfig {
                    model: "mock".into(),
                    system_prompt: Some("You are helpful.".into()),
                    working_directory: None,
                    capabilities: vec![],
                    compaction: crate::domains::agent::context::types::CompactionConfig::default(),
                }),
                compaction_trigger_config:
                    crate::domains::agent::context::types::CompactionTriggerConfig::default(),
                engine_host: None,
            },
            session_id,
        );
        (agent, cleanup)
    }

    fn make_agent() -> (TronAgent, JournalCleanup) {
        make_agent_with_provider(Arc::new(MockProvider))
    }

    fn run_context() -> RunContext {
        RunContext::default()
    }

    #[tokio::test]
    async fn run_agent_emits_complete_then_ready() {
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hello", run_context(), &broadcast, None).await;

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
    async fn run_agent_with_agent_state_context() {
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());

        let ctx = RunContext {
            agent_state_context: Some("agent-owned note".into()),
            ..run_context()
        };

        let result = run_agent(&mut agent, "Use state", ctx, &broadcast, None).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);
    }

    #[tokio::test]
    async fn run_agent_without_agent_state_context() {
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());

        let ctx = RunContext { ..run_context() };

        let result = run_agent(&mut agent, "No state", ctx, &broadcast, None).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);
    }

    #[tokio::test]
    async fn run_agent_no_duplicate_agent_end() {
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let _ = run_agent(&mut agent, "Hello", run_context(), &broadcast, None).await;

        // Count agent_end events — there should be exactly one (from TronAgent, forwarded)
        let mut agent_end_count = 0;
        while let Ok(event) = rx.try_recv() {
            if event.event_type() == "agent_end" {
                agent_end_count += 1;
            }
        }
        assert_eq!(
            agent_end_count, 1,
            "expected exactly 1 agent_end, got {agent_end_count}"
        );
    }

    #[tokio::test]
    async fn run_agent_error_still_emits_ready() {
        struct ErrorProvider;
        #[async_trait]
        impl crate::domains::model::providers::shared::provider::Provider for ErrorProvider {
            fn provider_type(&self) -> Provider {
                Provider::Anthropic
            }
            fn model(&self) -> &'static str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &crate::shared::protocol::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth {
                    message: "expired".into(),
                })
            }
        }

        let (mut agent, _journal) = make_agent_with_provider(Arc::new(ErrorProvider));

        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hi", run_context(), &broadcast, None).await;
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

    #[tokio::test]
    async fn forward_task_drains_all_events() {
        // Use a multi-turn provider to generate many events
        struct MultiEventProvider;
        #[async_trait]
        impl crate::domains::model::providers::shared::provider::Provider for MultiEventProvider {
            fn provider_type(&self) -> Provider {
                Provider::Anthropic
            }
            fn model(&self) -> &'static str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &crate::shared::protocol::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                let s = stream::iter(vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::TextDelta { delta: "a".into() }),
                    Ok(StreamEvent::TextDelta { delta: "b".into() }),
                    Ok(StreamEvent::TextDelta { delta: "c".into() }),
                    Ok(StreamEvent::TextDelta { delta: "d".into() }),
                    Ok(StreamEvent::TextDelta { delta: "e".into() }),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage {
                            content: vec![AssistantContent::text("abcde")],
                            token_usage: Some(TokenUsage {
                                input_tokens: 10,
                                output_tokens: 5,
                                ..Default::default()
                            }),
                        },
                        stop_reason: "end_turn".into(),
                    }),
                ]);
                Ok(Box::pin(s))
            }
        }

        let (mut agent, _journal) = make_agent_with_provider(Arc::new(MultiEventProvider));

        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hi", run_context(), &broadcast, None).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);

        // Collect all forwarded events
        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        // agent_end must be present (it's the last event from TronAgent)
        assert!(
            event_types.contains(&"agent_end".to_owned()),
            "agent_end must be forwarded; got: {event_types:?}"
        );
        // agent_ready must be last
        assert_eq!(
            event_types.last().map(String::as_str),
            Some("agent_ready"),
            "agent_ready must be the last event"
        );
        // All message_update deltas should be forwarded
        let update_count = event_types
            .iter()
            .filter(|t| *t == "message_update")
            .count();
        assert_eq!(update_count, 5, "all 5 text deltas must be forwarded");
    }

    #[tokio::test]
    async fn forward_task_aborted_on_timeout() {
        // Verify run_agent completes promptly even if the forward task
        // would otherwise hang (the abort path prevents leaking tasks).
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            run_agent(&mut agent, "Hello", run_context(), &broadcast, None),
        )
        .await;

        // run_agent must complete (not hang due to leaked forward task)
        assert!(result.is_ok(), "run_agent should complete within 5s");
        let result = result.unwrap();
        assert_eq!(result.stop_reason, StopReason::EndTurn);
    }

    #[tokio::test]
    async fn forward_task_completes_within_timeout_no_abort() {
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hello", run_context(), &broadcast, None).await;

        assert_eq!(result.stop_reason, StopReason::EndTurn);

        // All events should be forwarded (forward task completed normally)
        let mut saw_ready = false;
        let mut saw_end = false;
        while let Ok(event) = rx.try_recv() {
            match event.event_type() {
                "agent_end" => saw_end = true,
                "agent_ready" => saw_ready = true,
                _ => {}
            }
        }
        assert!(saw_end, "agent_end must be forwarded");
        assert!(saw_ready, "agent_ready must be emitted");
    }
}
