use super::*;

// ========================================================================
// preview
// ========================================================================

#[tokio::test]
async fn preview_generates_summary() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Test summary");

    let preview = engine.preview(&summarizer).await.unwrap();

    assert_eq!(preview.summary, "Test summary");
    assert_eq!(preview.tokens_before, 78_500);
}

#[tokio::test]
async fn preview_turn_based() {
    let deps = MockDeps::new(default_messages()); // 6 messages, 3 turns
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let preview = engine.preview(&summarizer).await.unwrap();

    assert_eq!(preview.preserved_messages, 4); // 2 turns = 4 messages
    assert_eq!(preview.summarized_messages, 2);
    assert_eq!(preview.preserved_turns, 2);
    assert_eq!(preview.summarized_turns, 1);
}

#[tokio::test]
async fn preview_with_extracted_data() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let preview = engine.preview(&summarizer).await.unwrap();
    assert!(preview.extracted_data.is_some());
}

#[tokio::test]
async fn preview_empty_messages() {
    let deps = MockDeps::new(vec![]);
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = PanicSummarizer;

    let preview = engine.preview(&summarizer).await.unwrap();
    assert_eq!(preview.preserved_messages, 0);
    assert_eq!(preview.summarized_messages, 0);
    assert_eq!(preview.summary, "");
}

// ========================================================================
// execute
// ========================================================================

#[tokio::test]
async fn execute_compaction_updates_messages() {
    let deps = MockDeps::new(default_messages()); // 6 messages, 3 turns
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Compacted summary");

    let result = engine.execute(&summarizer, None).await.unwrap();

    assert!(result.success);
    assert_eq!(result.summary, "Compacted summary");
    // 3 turns, preserve 2 → summarize first turn (2 msgs)
    // New: summary + ack + 4 preserved = 6
    let new_msgs = engine.deps.get_messages();
    assert_eq!(new_msgs.len(), 6);
}

#[tokio::test]
async fn execute_uses_edited_summary() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Original");

    let result = engine
        .execute(&summarizer, Some("User edited"))
        .await
        .unwrap();

    assert_eq!(result.summary, "User edited");
    assert!(result.extracted_data.is_none());
}

#[tokio::test]
async fn execute_returns_turn_counts() {
    let deps = MockDeps::new(default_messages()); // 3 turns
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert_eq!(result.preserved_turns, 2);
    assert_eq!(result.summarized_turns, 1);
}

#[tokio::test]
async fn execute_token_cap_reflected() {
    // 5 turns, budget fits 3, preserve=5
    let msgs: Vec<Message> = (0..10)
        .map(|i| {
            if i % 2 == 0 {
                Message::user(format!("Q{}", i / 2))
            } else {
                Message::assistant(format!("A{}", i / 2))
            }
        })
        .collect();
    let deps = MockDeps::new(msgs)
        .with_tokens(80_000, 860)
        .with_token_fn(|_| 100);
    // budget = 0.70 * 860 = 602. Each turn = 200 tokens.
    // Turn 5 (last): 200 ≤ 602 → fits. Turn 4: 400 ≤ 602 → fits. Turn 3: 600 ≤ 602 → fits.
    // Turn 2: 800 > 602, turns_seen=3>0 → stop.
    let engine = CompactionEngine::new(0.70, 5, deps);
    let summarizer = MockSummarizer::new("Summary");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert_eq!(result.preserved_turns, 3); // Budget limited to 3
}

#[tokio::test]
async fn execute_recompact_correct() {
    // Pre-compacted messages + 3 new turns, preserve 2
    let msgs = vec![
        compaction_summary("Previous context"),
        Message::assistant("Ack"),
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        Message::assistant("r2"),
        Message::user("q3"),
        Message::assistant("r3"),
    ];
    let deps = MockDeps::new(msgs);
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Re-compacted summary");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert!(result.success);
    assert_eq!(result.preserved_turns, 2);
    assert_eq!(result.summarized_turns, 1); // Only real turns in summarized portion
}

#[tokio::test]
async fn execute_summary_format() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let summarizer = MockSummarizer::new("The user worked on authentication.");

    let _ = engine.execute(&summarizer, None).await.unwrap();
    let new_msgs = engine.deps.get_messages();

    // Summary message
    match &new_msgs[0] {
        Message::User {
            content: UserMessageContent::Text(text),
            ..
        } => {
            assert!(text.starts_with(COMPACTION_SUMMARY_PREFIX));
            assert!(text.contains("The user worked on authentication."));
        }
        _ => panic!("Expected user text message"),
    }

    // Ack message
    match &new_msgs[1] {
        Message::Assistant { content, .. } => {
            assert_eq!(content.len(), 1);
            assert_eq!(content[0].as_text(), Some(COMPACTION_ACK_TEXT));
        }
        _ => panic!("Expected assistant message"),
    }
}

#[tokio::test]
async fn execute_preserve_zero() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 0, deps);
    let summarizer = MockSummarizer::new("Everything summarized");

    let result = engine.execute(&summarizer, None).await.unwrap();
    let new_msgs = engine.deps.get_messages();

    assert!(result.success);
    assert_eq!(result.preserved_turns, 0);
    assert_eq!(result.summarized_turns, 3);
    assert_eq!(new_msgs.len(), 2); // Only summary + ack
}

#[tokio::test]
async fn execute_skips_when_all_within_preserve_window() {
    let msgs = vec![Message::user("Hi"), Message::assistant("Hello")];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 5, deps);
    let summarizer = PanicSummarizer;

    let result = engine.execute(&summarizer, None).await.unwrap();

    assert!(!result.success);
    assert!(result.summary.is_empty());
    assert_eq!(result.tokens_before, result.tokens_after);
    assert_eq!(engine.deps.get_messages(), msgs);
}

#[tokio::test]
async fn execute_skips_when_summary_would_not_reduce_context() {
    let msgs = default_messages();
    let deps = MockDeps::new(msgs.clone()).with_tokens(1_700, 100_000);
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let result = engine.execute(&summarizer, None).await.unwrap();

    assert!(!result.success);
    assert!(result.tokens_after >= result.tokens_before);
    assert!(result.summary.is_empty());
    assert_eq!(engine.deps.get_messages(), msgs);
}

#[tokio::test]
async fn execute_returns_compression_ratio() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let summarizer = MockSummarizer::new("Short");

    let result = engine.execute(&summarizer, None).await.unwrap();

    assert!(result.compression_ratio > 0.0);
    assert!(result.compression_ratio <= 1.0);
}

// ========================================================================
// message_only_tokens
// ========================================================================
