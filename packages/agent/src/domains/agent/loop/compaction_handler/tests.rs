use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;
use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::context::summarizer::Summarizer;
use crate::domains::agent::context::types::{
    CompactionConfig, CompactionTriggerConfig, ContextManagerConfig, ExtractedData, SummaryResult,
};
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::session::event_store::{EventStore, EventType};
use crate::shared::protocol::messages::{Message, UserMessageContent};

struct MarkerSummarizer {
    calls: Arc<AtomicUsize>,
}

#[async_trait::async_trait]
impl Summarizer for MarkerSummarizer {
    async fn summarize(
        &self,
        _messages: &[Message],
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(SummaryResult {
            narrative: "marker strategy summary".to_owned(),
            extracted_data: ExtractedData::default(),
        })
    }
}

fn make_event_store() -> Arc<EventStore> {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .expect("in-memory event store pool");
    {
        let conn = pool.get().expect("event store connection");
        crate::domains::session::event_store::run_migrations(&conn).expect("migrations");
    }
    Arc::new(EventStore::new(pool))
}

fn context_manager_with_three_turns() -> ContextManager {
    let older_context = "older-context-detail ".repeat(2_000);
    let recent_context = "recent-context-detail ".repeat(50);
    let mut manager = ContextManager::new(ContextManagerConfig {
        model: "test-model".into(),
        system_prompt: Some("soul".into()),
        working_directory: Some("/tmp".into()),
        capabilities: vec![],
        compaction: CompactionConfig {
            threshold: 0.70,
            preserve_recent_turns: 1,
            context_limit: 10_000,
        },
    });
    manager.set_messages(vec![
        Message::user(format!("older request one {older_context}")),
        Message::assistant(format!("older answer one {older_context}")),
        Message::user(format!("older request two {older_context}")),
        Message::assistant(format!("older answer two {older_context}")),
        Message::user(format!("recent request {recent_context}")),
        Message::assistant(format!("recent answer {recent_context}")),
    ]);
    manager
}

#[tokio::test]
async fn wait_returns_when_not_compacting() {
    let handler = CompactionHandler::new(CompactionTriggerConfig::default());
    handler
        .wait_for_compaction(std::time::Duration::from_millis(1))
        .await;
    assert!(!handler.is_compacting());
}

#[tokio::test]
async fn skipped_event_reports_no_durable_reduction() {
    let handler = CompactionHandler::new(CompactionTriggerConfig::default());
    let emitter = Arc::new(EventEmitter::new());
    let success = CompactionHandler::emit_compaction_events(
        Ok(crate::domains::agent::context::types::CompactionResult {
            success: true,
            tokens_before: 10,
            tokens_after: 10,
            compression_ratio: 1.0,
            preserved_turns: 0,
            summarized_turns: 0,
            preserved_messages: 0,
            summary: String::new(),
            extracted_data: None,
        }),
        std::time::Instant::now(),
        10,
        10,
        "s1",
        &emitter,
        CompactionReason::ThresholdExceeded,
        None,
        None,
        None,
    )
    .await;
    assert!(!success);
    assert!(!handler.is_compacting());
}

#[tokio::test]
async fn execute_uses_injected_summarizer_but_requires_context_control_proof() {
    let calls = Arc::new(AtomicUsize::new(0));
    let handler = CompactionHandler::with_summarizer(
        CompactionTriggerConfig::default(),
        Arc::new(MarkerSummarizer {
            calls: Arc::clone(&calls),
        }),
    );
    let store = make_event_store();
    let session = store
        .create_session("test-model", "/tmp", Some("compaction proof"), None)
        .expect("session");
    handler.set_persister(Arc::new(EventPersister::new(Arc::clone(&store))));
    let mut manager = context_manager_with_three_turns();
    let before_messages = manager.get_messages();
    let emitter = Arc::new(EventEmitter::new());

    let success = handler
        .execute_compaction(
            &mut manager,
            &session.session.id,
            &emitter,
            CompactionReason::Manual,
            None,
        )
        .await
        .unwrap();

    assert!(!success);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(manager.get_messages(), before_messages);
    assert!(!manager.get_messages().iter().any(|message| {
        matches!(
            message,
            Message::User {
                content: UserMessageContent::Text(text),
                ..
            } if message.is_compaction_summary() && text.contains("marker strategy summary")
        )
    }));
    let events = store
        .get_latest_events(&session.session.id, Some(20))
        .expect("events");
    assert!(
        events
            .iter()
            .all(|event| event.event_type != EventType::CompactBoundary.as_str()),
        "failed-proof compaction must not append a bare compact.boundary"
    );
}
