use super::*;

#[test]
fn message_only_tokens_subtracts_overhead() {
    let deps = MockDeps::new(vec![]);
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert_eq!(engine.message_only_tokens(), 78_500);
}

#[test]
fn message_only_tokens_saturates_at_zero() {
    let deps = MockDeps::new(vec![]).with_tokens(500, 100_000);
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert_eq!(engine.message_only_tokens(), 0);
}

// ========================================================================
// estimate_tokens_after_compaction
// ========================================================================

#[test]
fn estimate_after_compaction_components() {
    let deps = MockDeps::new(vec![]);
    let engine = CompactionEngine::new(0.70, 5, deps);
    let preserved = [Message::user("msg1"), Message::user("msg2")];

    let result = engine.estimate_tokens_after_compaction("Short summary", &preserved);

    // summary: ceil(13/4) = 4, context: 50, ack: 50, preserved: 2 * 100 = 200
    assert_eq!(result, 304);
}

#[test]
fn token_estimation_uses_deps() {
    let deps = MockDeps {
        messages: Mutex::new(RefCell::new(vec![])),
        current_tokens: 80_000,
        context_limit: 100_000,
        system_prompt_tokens: 1_000,
        capabilities_tokens: 500,
        message_token_value: 250,
        token_fn: None,
    };
    let engine = CompactionEngine::new(0.70, 5, deps);
    let preserved = [Message::user("test")];
    let result = engine.estimate_tokens_after_compaction("s", &preserved);
    // summary: 1, context: 50, ack: 50, preserved: 250
    assert_eq!(result, 351);
}

// ========================================================================
// Integration: no orphaned capability results
// ========================================================================

/// Assert that every `CapabilityResult` in `messages` has a preceding `Assistant`
/// containing a `CapabilityInvocation` with the matching ID.
fn assert_no_orphaned_capability_results(messages: &[Message]) {
    for (i, msg) in messages.iter().enumerate() {
        if let Message::CapabilityResult { invocation_id, .. } = msg {
            let has_matching_capability_invocation = (0..i).rev().any(|j| {
                if let Message::Assistant { content, .. } = &messages[j] {
                    content.iter().any(|c| {
                        if let AssistantContent::CapabilityInvocation { id, .. } = c {
                            id == invocation_id
                        } else {
                            false
                        }
                    })
                } else {
                    false
                }
            });
            assert!(
                has_matching_capability_invocation,
                "CapabilityResult(invocation_id={invocation_id}) at index {i} has no \
                 preceding Assistant with matching CapabilityInvocation"
            );
        }
    }
}

#[tokio::test]
async fn execute_compaction_no_orphaned_capability_results() {
    let msgs = vec![
        Message::user("q1"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc2", "tc3"]),
        capability_result("tc2"),
        capability_result("tc3"),
        Message::user("q3"),
        Message::assistant("final"),
    ];
    // 3 turns, preserve 1
    let deps = MockDeps::new(msgs);
    let engine = CompactionEngine::new(0.70, 1, deps);
    let summarizer = MockSummarizer::new("Summary of capability usage");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert!(result.success);

    assert_no_orphaned_capability_results(&engine.deps.get_messages());
}

#[tokio::test]
async fn execute_turn_based_no_orphans() {
    // ModelCapability-heavy conversation, preserve 2 turns
    let msgs = vec![
        Message::user("q1"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::assistant("r1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc2", "tc3"]),
        capability_result("tc2"),
        capability_result("tc3"),
        Message::assistant("r2"),
        Message::user("q3"),
        Message::assistant("r3"),
    ];
    let deps = MockDeps::new(msgs);
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert!(result.success);
    assert_no_orphaned_capability_results(&engine.deps.get_messages());
}

// ========================================================================
// 65K context window — local-model ceiling (Ollama)
//
// Ollama sessions run with `num_ctx = 65_536` and the default compaction
// threshold of 0.70. These tests pin the split-point math and capability-result
// sizer at that window so the local path is parametrically covered.
// ========================================================================

const LOCAL_CTX_LIMIT: u64 = 65_536;
const DEFAULT_COMPACT_THRESHOLD: f64 = 0.70;

#[test]
fn local_window_all_turns_fit_under_budget() {
    // Budget = threshold * context_limit = 0.70 * 65_536 ≈ 45_875 tokens.
    // 12 messages × 3_500 tokens = 6 turns × 7_000 tokens = 42_000 — all fit.
    // With preserve_recent=10 (> turn count), the turn cap never kicks in, so
    // the budget alone governs and all turns are preserved → split = 0.
    let msgs: Vec<Message> = (0..12)
        .map(|i| {
            if i % 2 == 0 {
                Message::user(format!("Q{}", i / 2))
            } else {
                Message::assistant(format!("A{}", i / 2))
            }
        })
        .collect();
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(50_000, LOCAL_CTX_LIMIT)
        .with_token_fn(|_| 3_500);
    let engine = CompactionEngine::new(DEFAULT_COMPACT_THRESHOLD, 10, deps);
    assert_eq!(engine.compute_split_point(&msgs), 0);
}

#[test]
fn local_window_budget_caps_preserved_turns() {
    // Budget = 0.70 * 65_536 ≈ 45_875 tokens. 20 messages × 4_000 tokens
    // each = 10 turns × 8_000 tokens:
    //   - 5 turns × 8_000 = 40_000 ≤ 45_875 → fit
    //   - 6th turn pushes total to 48_000 > 45_875 AND turns_seen=5>0 → stop
    // With preserve_recent=10 (≥ turn count), budget is the binding constraint.
    // Expect split at message index 10 (first 10 compacted, last 10 preserved).
    let msgs: Vec<Message> = (0..20)
        .map(|i| {
            if i % 2 == 0 {
                Message::user(format!("Q{}", i / 2))
            } else {
                Message::assistant(format!("A{}", i / 2))
            }
        })
        .collect();
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(60_000, LOCAL_CTX_LIMIT)
        .with_token_fn(|_| 4_000);
    let engine = CompactionEngine::new(DEFAULT_COMPACT_THRESHOLD, 10, deps);
    assert_eq!(
        engine.compute_split_point(&msgs),
        10,
        "budget should cap at 5 turns (10 messages)"
    );
}
