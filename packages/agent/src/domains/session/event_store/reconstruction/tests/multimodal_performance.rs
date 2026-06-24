use super::*;

// ── Multimodal user message reconstruction ──

#[test]
fn multimodal_user_message_reconstructs() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({
                "content": [
                    {"type": "text", "text": "look at this"},
                    {"type": "image", "data": "base64img", "mimeType": "image/png"}
                ],
                "imageCount": 1
            }),
        ),
    ];
    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].role, "user");
    // Content should be the array, not stringified
    let content = &msgs[0].content;
    let arr = content.as_array().expect("content should be array");
    assert_eq!(arr.len(), 2);
    assert_eq!(arr[0]["type"], "text");
    assert_eq!(arr[1]["type"], "image");
    assert_eq!(arr[1]["data"], "base64img");
}

#[test]
fn multimodal_user_content_merges_with_string() {
    // First user message is multimodal array, second is plain string
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({
                "content": [
                    {"type": "text", "text": "image here"},
                    {"type": "image", "data": "imgdata", "mimeType": "image/png"}
                ]
            }),
        ),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "follow up"}),
        ),
    ];
    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);
    // Consecutive user messages merge
    assert_eq!(msgs.len(), 1);
    let arr = msgs[0]
        .content
        .as_array()
        .expect("merged content should be array");
    // First array's blocks + second normalized to [{type:text, text:...}]
    assert_eq!(arr.len(), 3);
    assert_eq!(arr[0]["type"], "text");
    assert_eq!(arr[0]["text"], "image here");
    assert_eq!(arr[1]["type"], "image");
    assert_eq!(arr[2]["type"], "text");
    assert_eq!(arr[2]["text"], "follow up");
}

// ── H16: reconstruction performance budget ─────────────────────
//
// `reconstruct_from_events` runs a two-pass O(N) walk over every
// ancestor event. That's fine for today's session sizes (median
// ~100 events per session in practice), but users have reported
// tens-of-thousands-of-events sessions. The audit (H16) asked:
// "is reconstruction linear in event count, and does that matter?"
//
// Rather than guess, we measure. The tests below construct
// synthetic event chains at 100, 1 000, and 10 000 events and
// assert:
//
// 1. Reconstruction completes inside a generous wall-clock budget
//    (protects against quadratic regressions — e.g. a future
//    "look up capability args by scanning the full list" refactor).
// 2. Large chains still produce the expected aggregate message, turn,
//    and token state. Tiny per-event timing ratios are too scheduler-
//    sensitive for the full parallel suite, so the algorithmic guard is
//    the 10k wall-clock budget plus deterministic output assertions.
//
// These tests are cheap enough to run in debug (~10ms for 10k
// events on a local dev machine as of 2026-04-22) and protect the
// reconstruction hot path from silent algorithmic regressions.
// When median session size grows past 1k, revisit this budget
// and consider the snapshot-at-compaction-boundary scheme from
// the audit plan.

fn build_synthetic_chain(count: usize) -> Vec<SessionEvent> {
    let mut events = Vec::with_capacity(count + 1);
    events.push(session_start());
    // Alternate user / assistant so the test exercises the
    // consecutive-role merging path and capability-arg-lookup path.
    for i in 0..count {
        if i.is_multiple_of(2) {
            events.push(ev(
                EventType::MessageUser,
                serde_json::json!({"content": format!("user prompt {i}")}),
            ));
        } else {
            let turn = (i as i64 / 2) + 1;
            events.push(ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": format!("assistant reply {i}")}],
                    "turn": turn,
                    "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
                }),
            ));
        }
    }
    events
}

#[test]
fn reconstruct_completes_inside_budget_at_10k_events() {
    let events = build_synthetic_chain(10_000);
    let start = std::time::Instant::now();
    let result = reconstruct_from_events(&events);
    let elapsed = start.elapsed();

    // Generous 5s budget — a debug-mode quadratic regression on
    // 10k events would blow past this by orders of magnitude.
    // Release mode completes in well under 100ms on current
    // hardware; the wide margin is deliberate headroom for CI
    // runners and future event schema complexity.
    assert!(
        elapsed < std::time::Duration::from_secs(5),
        "reconstruction of 10k events took {elapsed:?} — possible quadratic regression"
    );
    // Sanity: the walk actually produced the messages we expect
    // so a silently-broken build doesn't pass the timing check.
    assert!(
        result.messages_with_event_ids.len() >= 5_000,
        "expected >=5000 messages, got {}",
        result.messages_with_event_ids.len()
    );
}

#[test]
fn reconstruct_large_chain_preserves_aggregate_state() {
    let small = build_synthetic_chain(100);
    let large = build_synthetic_chain(10_000);

    let small = reconstruct_from_events(&small);
    let large = reconstruct_from_events(&large);

    assert!(
        large.messages_with_event_ids.len() >= small.messages_with_event_ids.len() * 50,
        "large reconstruction should preserve proportional message output (small={}, large={})",
        small.messages_with_event_ids.len(),
        large.messages_with_event_ids.len()
    );
    assert_eq!(large.turn_count, 5_000);
    assert_eq!(large.token_usage.input_tokens, 50_000);
    assert_eq!(large.token_usage.output_tokens, 25_000);
}

#[test]
fn reconstruct_scales_to_1k_events() {
    // Middle-ground test: 1k is the size most real sessions cap
    // out at today; failures here are what a user would actually
    // notice as UI lag on reconnect.
    let events = build_synthetic_chain(1_000);
    let start = std::time::Instant::now();
    let result = reconstruct_from_events(&events);
    let elapsed = start.elapsed();

    assert!(
        elapsed < std::time::Duration::from_millis(500),
        "1k-event reconstruction took {elapsed:?} — user-perceptible"
    );
    assert!(result.messages_with_event_ids.len() >= 500);
}
