use super::*;
use crate::domains::agent::context::types::CompactionTriggerConfig;

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
