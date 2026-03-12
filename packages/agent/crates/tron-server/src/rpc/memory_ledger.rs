//! Shared memory-ledger pipeline used by manual and automatic writes.

mod snapshot;
mod write_service;

use std::sync::Arc;

pub(crate) use snapshot::CycleSnapshot;
#[cfg(test)]
pub(crate) use snapshot::user_message_len;
pub use snapshot::{build_cycle_snapshot, cron_assistant_text_len, prepare_cron_transcript};
pub use write_service::execute_ledger_write;

/// Dependencies for the shared ledger write pipeline.
pub struct LedgerWriteDeps {
    /// Event store for reading session history and persisting ledger events.
    pub event_store: Arc<tron_events::EventStore>,
    /// Subagent manager for spawning LLM summarizer sessions.
    pub subagent_manager:
        Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    /// Embedding controller for fire-and-forget semantic vector indexing.
    pub embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    /// Shutdown coordinator for tracking in-flight embedding tasks.
    pub shutdown_coordinator: Option<Arc<crate::shutdown::ShutdownCoordinator>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use futures::stream;
    use serde_json::json;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_core::messages::{Message, UserMessageContent};
    use tron_events::types::payloads::memory::MemoryLedgerPayload;
    use tron_llm::models::types::Provider as LlmProvider;
    use tron_llm::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };

    const LEDGER_JSON: &str =
        r#"{"title":"Ledger test","entryType":"research","input":"test","actions":["done"]}"#;

    #[tokio::test]
    async fn cycle_snapshot_without_boundary_returns_full_range() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/project", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Hi"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 5, "outputTokens": 3}
            }),
            parent_id: None,
        });

        let cycle = build_cycle_snapshot(&ctx.event_store, &sid)
            .unwrap()
            .expect("cycle");

        assert_eq!(cycle.first_turn, 1);
        assert_eq!(cycle.last_turn, 1);
        assert_eq!(cycle.messages.len(), 2);
        assert_eq!(
            cycle.first_event_id,
            ctx.event_store
                .get_events_by_session(
                    &sid,
                    &tron_events::sqlite::repositories::event::ListEventsOptions {
                        limit: None,
                        offset: None,
                    },
                )
                .unwrap()
                .first()
                .unwrap()
                .id
        );
    }

    #[tokio::test]
    async fn cycle_snapshot_uses_boundary_turn_range_instead_of_rescanning_history() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/project", Some("test"))
            .unwrap();

        for turn in 1..=3 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"content": format!("Request {turn}")}),
                parent_id: None,
            });
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: json!({
                    "content": [{"type": "text", "text": format!("Response {turn}")}],
                    "turn": turn,
                    "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
                }),
                parent_id: None,
            });
        }

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({
                "turnRange": {"firstTurn": 1, "lastTurn": 3},
                "title": "First three turns"
            }),
            parent_id: None,
        });

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Fourth request"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Fourth response"}],
                "turn": 4,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        let cycle = build_cycle_snapshot(&ctx.event_store, &sid)
            .unwrap()
            .expect("cycle");

        assert_eq!(cycle.first_turn, 4);
        assert_eq!(cycle.last_turn, 4);
        assert_eq!(cycle.messages.len(), 2);
        match &cycle.messages[0] {
            Message::User { content, .. } => match content {
                UserMessageContent::Text(text) => assert_eq!(text, "Fourth request"),
                UserMessageContent::Blocks(_) => panic!("expected text user message"),
            },
            other => panic!("expected user message, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn cycle_snapshot_skips_assistant_only_tail() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/project", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({
                "turnRange": {"firstTurn": 1, "lastTurn": 1},
                "title": "Boundary"
            }),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "orphan"}],
                "turn": 2
            }),
            parent_id: None,
        });

        assert!(
            build_cycle_snapshot(&ctx.event_store, &sid)
                .unwrap()
                .is_none()
        );
    }

    struct LedgerMockProvider;

    #[async_trait::async_trait]
    impl Provider for LedgerMockProvider {
        fn provider_type(&self) -> LlmProvider {
            LlmProvider::Anthropic
        }

        fn model(&self) -> &'static str {
            "mock-ledger"
        }

        async fn stream(
            &self,
            _context: &tron_core::messages::Context,
            _options: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let stream = stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: LEDGER_JSON.into(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(LEDGER_JSON)],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ]);
            Ok(Box::pin(stream))
        }
    }

    struct LedgerMockProviderFactory;

    #[async_trait::async_trait]
    impl ProviderFactory for LedgerMockProviderFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(Arc::new(LedgerMockProvider))
        }
    }

    #[tokio::test]
    async fn execute_ledger_write_uses_session_working_directory() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp/real-working-dir", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Do the work"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Completed the work"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        let broadcast = Arc::new(tron_runtime::EventEmitter::new());
        let subagent = Arc::new(
            tron_runtime::orchestrator::subagent_manager::SubagentManager::new(
                ctx.session_manager.clone(),
                ctx.event_store.clone(),
                broadcast,
                Arc::new(LedgerMockProviderFactory),
                None,
                None,
            ),
        );
        subagent.set_tool_factory(Arc::new(tron_tools::registry::ToolRegistry::new));

        let deps = LedgerWriteDeps {
            event_store: ctx.event_store.clone(),
            subagent_manager: Some(subagent),
            embedding_controller: None,
            shutdown_coordinator: None,
        };

        let result = execute_ledger_write(&sid, &deps, "auto").await;
        assert!(result.written, "expected ledger write to succeed");

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["memory.ledger"], Some(10))
            .unwrap();
        let payload: MemoryLedgerPayload = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload.working_directory, "/tmp/real-working-dir");
        assert_eq!(payload.source, "auto");
    }
}
