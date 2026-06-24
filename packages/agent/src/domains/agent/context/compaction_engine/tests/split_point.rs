use super::*;

#[test]
fn basic_3_turns_preserve_2() {
    // [U,A,U,A,U,A] — 3 turns, preserve 2
    let msgs = default_messages();
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 2, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 2); // preserve [U,A,U,A] = last 2 turns
}

#[test]
fn basic_5_turns_preserve_3() {
    let msgs: Vec<Message> = (0..10)
        .map(|i| {
            if i % 2 == 0 {
                Message::user(format!("Q{}", i / 2))
            } else {
                Message::assistant(format!("A{}", i / 2))
            }
        })
        .collect();
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 3, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 4); // preserve last 6 messages (3 turns)
}

#[test]
fn basic_preserve_all() {
    // [U,A,U,A] — 2 turns, preserve 5 (more than available)
    let msgs = vec![
        Message::user("a"),
        Message::assistant("b"),
        Message::user("c"),
        Message::assistant("d"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 5, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // preserve everything
}

#[test]
fn basic_single_turn() {
    let msgs = vec![Message::user("hi"), Message::assistant("hello")];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // 1 turn, preserve it all
}

#[test]
fn basic_preserve_zero() {
    let msgs = default_messages();
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 0, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 6); // summarize all
}

// ========================================================================
// compute_split_point — Category 2: ModelCapability-heavy turns
// ========================================================================

#[test]
fn capability_heavy_single_turn() {
    // [U, A(tc), TR, A(tc), TR, A(text)] — 1 turn = 6 messages
    let msgs = vec![
        Message::user("do stuff"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        assistant_with_capability_invocation(&["tc2"]),
        capability_result("tc2"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // 1 turn, preserve all
}

#[test]
fn capability_heavy_preserve_1_of_2() {
    // [U,A, U,A(tc),TR,TR,A] — 2 turns, preserve 1
    let msgs = vec![
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc2", "tc3"]),
        capability_result("tc2"),
        capability_result("tc3"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 2); // Last turn starts at U[2]
}

#[test]
fn parallel_capabilities_one_turn() {
    // [U, A(tc1,tc2), TR1, TR2, A] — 1 turn
    let msgs = vec![
        Message::user("do both"),
        assistant_with_capability_invocation(&["tc1", "tc2"]),
        capability_result("tc1"),
        capability_result("tc2"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // 1 turn, preserve all
}

#[test]
fn mixed_capability_and_simple() {
    // [U,A, U,A(tc),TR,A, U,A] — 3 turns, preserve 2
    let msgs = vec![
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::assistant("done capability"),
        Message::user("q3"),
        Message::assistant("r3"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 2, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 2); // Last 2 turns: [q2,A(tc),TR,A, q3,r3]
}

// ========================================================================
// compute_split_point — Category 3: Token cap
// ========================================================================

#[test]
fn token_cap_limits_turns() {
    // 3 turns, 500 tok per message, budget fits 2 turns
    let msgs = default_messages(); // 6 msgs, 3 turns
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(80_000, 3000)
        .with_token_fn(|_| 500);
    // budget = threshold * context_limit = 0.70 * 3000 = 2100. Each turn = 1000 tokens.
    // Turn 3 (last): 1000 ≤ 2100 → fits. Turn 2: 1000+1000=2000 ≤ 2100 → fits.
    // Turn 1: 1000+2000=3000 > 2100 and turns_seen=2 > 0 → stop.
    let engine = CompactionEngine::new(0.70, 3, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 2); // Budget only fits 2 of 3 requested turns
}

#[test]
fn token_cap_single_large_turn() {
    // 1 turn that exceeds budget — must still preserve it (guarantee at least 1)
    let msgs = vec![Message::user("big q"), Message::assistant("huge response")];
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(80_000, 100)
        .with_token_fn(|_| 5000);
    // budget = 0.70 * 100 = 70. Turn = 10000 tokens. But turns_seen==0 → include anyway.
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // Guarantee: at least 1 turn preserved
}

#[test]
fn token_cap_exact_fit() {
    let msgs = vec![
        Message::user("a"),
        Message::assistant("b"),
        Message::user("c"),
        Message::assistant("d"),
    ];
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(80_000, 2000)
        .with_token_fn(|_| 100);
    // budget = 0.70 * 2000 = 1400. Each turn = 200. 2 turns = 400 ≤ 1400 → fits.
    let engine = CompactionEngine::new(0.70, 2, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // Both turns fit
}

#[test]
fn token_cap_tiny_budget() {
    // Very small context_limit makes budget ≈ 0, but we still guarantee at least 1 turn.
    let msgs = vec![
        Message::user("a"),
        Message::assistant("b"),
        Message::user("c"),
        Message::assistant("d"),
    ];
    let deps = MockDeps::new(msgs.clone()).with_tokens(80_000, 1);
    // budget = 0.70 * 1 = 0 (truncated). Turn cost > 0, turns_seen==0 → include anyway.
    // After first turn, turns_seen=1 > 0, next turn exceeds budget → stop.
    let engine = CompactionEngine::new(0.70, 2, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 2); // Only 1 turn preserved despite requesting 2
}

#[test]
fn token_cap_partial_turn_excluded() {
    // 3 turns, middle one is huge, budget fits last turn but not middle + last
    let msgs = vec![
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        Message::assistant("huge response"),
        Message::user("q3"),
        Message::assistant("r3"),
    ];
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(80_000, 3000)
        .with_token_fn(|msg| {
            // Make the "huge response" assistant message very expensive
            if let Message::Assistant { content, .. } = msg
                && let Some(text) = content.first().and_then(|c| c.as_text())
                && text == "huge response"
            {
                return 5000;
            }
            100
        });
    // budget = 0.70 * 3000 = 2100
    // Turn 3 (last): [q3, r3] = 200 ≤ 2100 → fits. turns_seen=1.
    // Turn 2: [q2, huge] = 5100. 200+5100=5300 > 2100, turns_seen=1>0 → stop.
    let engine = CompactionEngine::new(0.70, 3, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 4); // Only last turn preserved
}

// ========================================================================
// compute_split_point — Category 4: Re-compaction
// ========================================================================

#[test]
fn recompact_skips_summary() {
    // [Summary_U, Ack_A, U, A, U, A, U, A] — summary + 3 real turns, preserve 2
    let msgs = vec![
        compaction_summary("Previous context"),
        Message::assistant("I understand the previous context."),
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        Message::assistant("r2"),
        Message::user("q3"),
        Message::assistant("r3"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 2, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 4); // Summary not counted, preserve last 2 real turns
}

#[test]
fn recompact_all_turns_fit() {
    // [Summary_U, Ack_A, U, A, U, A] — summary + 2 real turns, preserve 5
    let msgs = vec![
        compaction_summary("Previous context"),
        Message::assistant("Ack"),
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        Message::assistant("r2"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 5, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // Preserves everything including summary
}

#[test]
fn recompact_summary_only() {
    // [Summary_U, Ack_A] — no real turns, nothing to compact further
    let msgs = vec![
        compaction_summary("Previous context"),
        Message::assistant("Ack"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    // No real user turns, preserve everything (nothing meaningful to summarize)
    assert_eq!(split, 0);
}

#[test]
fn recompact_multiple_summaries() {
    // [S1, Ack1, S2, Ack2, U, A, U, A] — 2 real turns
    let msgs = vec![
        compaction_summary("First summary"),
        Message::assistant("Ack 1"),
        compaction_summary("Second summary"),
        Message::assistant("Ack 2"),
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        Message::assistant("r2"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 6); // Preserve last real turn only
}

// ========================================================================
// compute_split_point — Category 5: Orphaned CapabilityResult prevention
// ========================================================================

#[test]
fn orphan_split_on_user_is_clean() {
    // Turn-based split always lands on User, no fixup needed
    let msgs = vec![
        Message::user("q1"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::user("q2"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 3); // Lands on U[3], clean
    assert!(msgs[split].is_user());
}

#[test]
fn degenerate_leading_capability_result() {
    // [TR, U, A] — CapabilityResult before any User (shouldn't happen but must not panic)
    let msgs = vec![
        capability_result("tc_orphan"),
        Message::user("q"),
        Message::assistant("a"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 1); // Preserve from User onward
}

#[test]
fn degenerate_all_capability_results() {
    // [A(tc), TR, TR] — no user turns, preserve everything
    let msgs = vec![
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        capability_result("tc2"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // No user turns found, preserve everything
}

// ========================================================================
// compute_split_point — Category 6: Edge cases
// ========================================================================

#[test]
fn empty_messages() {
    let msgs: Vec<Message> = vec![];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 5, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0);
}

#[test]
fn single_user_no_response() {
    let msgs = vec![Message::user("hello")];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // Incomplete turn still preserved
}

#[test]
fn assistant_first() {
    // [A, U, A] — leading assistant is summarized
    let msgs = vec![
        Message::assistant("preamble"),
        Message::user("q"),
        Message::assistant("a"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 1); // Leading assistant summarized
}

#[test]
fn only_assistant_messages() {
    let msgs = vec![
        Message::assistant("a1"),
        Message::assistant("a2"),
        Message::assistant("a3"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // No user turns found, preserve everything
}

#[test]
fn preserve_turns_exceeds_total() {
    let msgs = vec![Message::user("hi"), Message::assistant("hello")];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 100, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // Preserve all
}

#[test]
fn huge_message_count() {
    // 1000 messages (500 turns), preserve 5
    let msgs: Vec<Message> = (0..1000)
        .map(|i| {
            if i % 2 == 0 {
                Message::user(format!("Q{}", i / 2))
            } else {
                Message::assistant(format!("A{}", i / 2))
            }
        })
        .collect();
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 5, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 990); // Last 10 messages = 5 turns
}
