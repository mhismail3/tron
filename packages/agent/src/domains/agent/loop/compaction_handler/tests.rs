use super::*;
use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::context::types::{
    CompactionConfig, CompactionTriggerConfig, ContextManagerConfig, ExtractedData, SummaryResult,
};
use crate::shared::protocol::messages::{Message, UserMessageContent};

struct InjectedSummarizer;

#[async_trait::async_trait]
impl Summarizer for InjectedSummarizer {
    async fn summarize(
        &self,
        _messages: &[Message],
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
        Ok(SummaryResult {
            extracted_data: ExtractedData::default(),
            narrative: "summary from injected compaction strategy".to_owned(),
        })
    }
}

fn compactable_manager() -> ContextManager {
    let mut manager = ContextManager::new(ContextManagerConfig {
        model: "test-model".to_owned(),
        system_prompt: Some("soul".to_owned()),
        working_directory: Some("/tmp".to_owned()),
        capabilities: vec![],
        compaction: CompactionConfig {
            threshold: 0.70,
            preserve_recent_turns: 1,
            context_limit: 10_000,
        },
    });
    manager.add_message(Message::user("Older turn that should be summarized"));
    manager.add_message(Message::assistant("Older assistant response"));
    manager.add_message(Message::user("Recent turn that should be preserved"));
    manager.add_message(Message::assistant("Recent assistant response"));
    manager.set_api_context_tokens(8_000);
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
async fn execute_compaction_uses_injected_summarizer_strategy() {
    let handler = CompactionHandler::with_summarizer(
        CompactionTriggerConfig::default(),
        Arc::new(InjectedSummarizer),
    );
    let mut manager = compactable_manager();
    let emitter = Arc::new(EventEmitter::new());

    let success = handler
        .execute_compaction(
            &mut manager,
            "strategy-session",
            &emitter,
            CompactionReason::Manual,
            None,
        )
        .await
        .expect("execute compaction with injected summarizer");

    assert!(success);
    let messages = manager.get_messages();
    match &messages[0] {
        Message::User {
            content: UserMessageContent::Text(text),
            ..
        } => {
            assert!(text.contains("summary from injected compaction strategy"));
        }
        other => panic!("expected compaction summary user message, got {other:?}"),
    }
    assert!(
        messages
            .iter()
            .any(|message| matches!(message, Message::User {
                content: UserMessageContent::Text(text),
                ..
            } if text.contains("Recent turn that should be preserved")))
    );
}
