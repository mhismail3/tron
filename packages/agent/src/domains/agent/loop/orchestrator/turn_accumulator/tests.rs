use super::*;
use crate::shared::protocol::content::ThinkingContentKind;
use crate::shared::protocol::events::{BaseEvent, CapabilityEventIdentity};

const EMPTY_IDENTITY: CapabilityEventIdentity = CapabilityEventIdentity {
    model_primitive_name: None,
    operation_name: None,
    trace_id: None,
    root_invocation_id: None,
    theme_color: None,
    presentation_hints: None,
};

fn begin(map: &TurnAccumulatorMap, session_id: &str) {
    map.begin_run(session_id, &format!("run-{session_id}"));
}

fn state(map: &TurnAccumulatorMap, session_id: &str) -> Option<(String, Value, Value)> {
    map.accumulators
        .lock()
        .get(session_id)
        .and_then(|session| session.turn.as_ref())
        .map(TurnAccumulator::to_json)
}

// ── TurnAccumulator unit tests ──

#[test]
fn new_accumulator_is_empty() {
    let acc = TurnAccumulator::new();
    assert!(acc.text.is_empty());
    assert!(acc.thinking.is_empty());
    assert!(acc.capability_invocations.is_empty());
    assert!(acc.content_sequence.is_empty());
}

#[test]
fn append_text_accumulates() {
    let mut acc = TurnAccumulator::new();
    acc.append_text("Hello ");
    acc.append_text("world");
    assert_eq!(acc.text, "Hello world");
}

#[test]
fn append_text_updates_content_sequence() {
    let mut acc = TurnAccumulator::new();
    acc.append_text("Hello ");
    acc.append_text("world");
    assert_eq!(acc.content_sequence.len(), 1);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::Text(t) if t == "Hello world"
    ));
}

#[test]
fn append_thinking_accumulates() {
    let mut acc = TurnAccumulator::new();
    acc.append_thinking("step 1 ", ThinkingContentKind::Thinking);
    acc.append_thinking("step 2", ThinkingContentKind::Thinking);
    assert_eq!(acc.thinking, "step 1 step 2");
}

#[test]
fn append_thinking_updates_content_sequence() {
    let mut acc = TurnAccumulator::new();
    acc.append_thinking("think", ThinkingContentKind::Thinking);
    assert_eq!(acc.content_sequence.len(), 1);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::Thinking { text, kind } if text == "think" && *kind == ThinkingContentKind::Thinking
    ));
}

#[test]
fn finish_thinking_replaces_current_thinking_snapshot() {
    let mut acc = TurnAccumulator::new();
    acc.append_thinking("summary ", ThinkingContentKind::Thinking);
    acc.append_thinking("delta", ThinkingContentKind::Thinking);
    acc.finish_thinking(
        "authoritative final thinking",
        ThinkingContentKind::Thinking,
    );

    assert_eq!(acc.thinking, "authoritative final thinking");
    assert_eq!(acc.content_sequence.len(), 1);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::Thinking { text, kind }
            if text == "authoritative final thinking" && *kind == ThinkingContentKind::Thinking
    ));
}

#[test]
fn thinking_end_event_replaces_accumulated_thinking() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::ThinkingDelta {
        base: BaseEvent::now("s1"),
        delta: "summary".into(),
        kind: ThinkingContentKind::Thinking,
    });
    map.update_from_event(&TronEvent::ThinkingEnd {
        base: BaseEvent::now("s1"),
        thinking: "full final thinking".into(),
        kind: ThinkingContentKind::Thinking,
    });

    let (_, _, sequence) = state(&map, "s1").unwrap();
    assert_eq!(sequence[0]["thinking"], "full final thinking");
}

#[test]
fn interleaved_text_and_thinking_creates_separate_sequence_items() {
    let mut acc = TurnAccumulator::new();
    acc.append_thinking("hmm", ThinkingContentKind::Thinking);
    acc.append_text("answer");
    assert_eq!(acc.content_sequence.len(), 2);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::Thinking { .. }
    ));
    assert!(matches!(
        &acc.content_sequence[1],
        ContentSequenceItem::Text(_)
    ));
}

#[test]
fn add_capability_invocation_generating() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    assert_eq!(acc.capability_invocations.len(), 1);
    assert_eq!(acc.capability_invocations[0].invocation_id, "tc_1");
    assert_eq!(
        acc.capability_invocations[0].model_primitive_name,
        "execute"
    );
    assert_eq!(acc.capability_invocations[0].status, "generating");
    assert_eq!(acc.content_sequence.len(), 1);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::CapabilityRef { invocation_id } if invocation_id == "tc_1"
    ));
}

#[test]
fn update_capability_started() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    acc.update_capability_started(
        "tc_1",
        Some(&serde_json::json!({"command": "ls"})),
        &EMPTY_IDENTITY,
    );
    assert_eq!(acc.capability_invocations[0].status, "running");
    assert!(acc.capability_invocations[0].arguments.is_some());
    assert!(acc.capability_invocations[0].started_at.is_some());
}

#[test]
fn update_capability_completed_success() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    acc.update_capability_started("tc_1", None, &EMPTY_IDENTITY);
    acc.update_capability_completed("tc_1", Some("output"), false, &EMPTY_IDENTITY);
    assert_eq!(acc.capability_invocations[0].status, "completed");
    assert_eq!(
        acc.capability_invocations[0].result.as_deref(),
        Some("output")
    );
    assert!(!acc.capability_invocations[0].is_error);
    assert!(acc.capability_invocations[0].completed_at.is_some());
}

#[test]
fn update_capability_completed_error() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    acc.update_capability_started("tc_1", None, &EMPTY_IDENTITY);
    acc.update_capability_completed("tc_1", Some("command not found"), true, &EMPTY_IDENTITY);
    assert_eq!(acc.capability_invocations[0].status, "error");
    assert!(acc.capability_invocations[0].is_error);
}

#[test]
fn update_capability_unknown_id_is_noop() {
    let mut acc = TurnAccumulator::new();
    acc.update_capability_started("unknown", None, &EMPTY_IDENTITY);
    acc.update_capability_completed("unknown", None, false, &EMPTY_IDENTITY);
    assert!(acc.capability_invocations.is_empty());
}

#[test]
fn multiple_capability_invocations_tracked_independently() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    acc.add_capability_generating("tc_2", "inspect", &EMPTY_IDENTITY);
    acc.update_capability_started("tc_1", None, &EMPTY_IDENTITY);
    acc.update_capability_completed("tc_1", Some("ok"), false, &EMPTY_IDENTITY);
    acc.update_capability_started("tc_2", None, &EMPTY_IDENTITY);

    assert_eq!(acc.capability_invocations.len(), 2);
    assert_eq!(acc.capability_invocations[0].status, "completed");
    assert_eq!(acc.capability_invocations[1].status, "running");
}

#[test]
fn text_after_capability_creates_new_text_item() {
    let mut acc = TurnAccumulator::new();
    acc.append_text("before ");
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    acc.append_text("after");
    assert_eq!(acc.content_sequence.len(), 3);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::Text(t) if t == "before "
    ));
    assert!(matches!(
        &acc.content_sequence[1],
        ContentSequenceItem::CapabilityRef { .. }
    ));
    assert!(matches!(
        &acc.content_sequence[2],
        ContentSequenceItem::Text(t) if t == "after"
    ));
}

#[test]
fn to_json_produces_expected_format() {
    let mut acc = TurnAccumulator::new();
    acc.append_text("hello");
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    let (text, capabilities, sequence) = acc.to_json();
    assert_eq!(text, "hello");
    assert!(capabilities.is_array());
    assert_eq!(capabilities.as_array().unwrap().len(), 1);
    assert!(sequence.is_array());
}

// ── ContentSequenceItem::to_json key tests ──

#[test]
fn to_json_text_uses_text_key() {
    let item = ContentSequenceItem::Text("hello".into());
    let json = item.to_json();
    assert_eq!(json["type"], "text");
    assert_eq!(json["text"], "hello");
    assert!(json.get("content").is_none());
}

#[test]
fn to_json_thinking_uses_thinking_key() {
    let item = ContentSequenceItem::Thinking {
        text: "hmm".into(),
        kind: ThinkingContentKind::Thinking,
    };
    let json = item.to_json();
    assert_eq!(json["type"], "thinking");
    assert_eq!(json["thinking"], "hmm");
    assert!(json.get("content").is_none());
}

#[test]
fn to_json_reasoning_summary_includes_kind() {
    let item = ContentSequenceItem::Thinking {
        text: "summary".into(),
        kind: ThinkingContentKind::ReasoningSummary,
    };
    let json = item.to_json();
    assert_eq!(json["type"], "thinking");
    assert_eq!(json["thinking"], "summary");
    assert_eq!(json["kind"], "reasoning_summary");
}

#[test]
fn to_json_capability_ref_uses_snake_case_type() {
    let item = ContentSequenceItem::CapabilityRef {
        invocation_id: "tc_1".into(),
    };
    let json = item.to_json();
    assert_eq!(json["type"], "capability_ref");
    assert_eq!(json["invocationId"], "tc_1");
}

// ── Streaming output tests ──

#[test]
fn capability_streaming_output_accumulates() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    acc.update_capability_started("tc_1", None, &EMPTY_IDENTITY);
    let tc = &mut acc.capability_invocations[0];
    let streaming = tc.streaming_output.get_or_insert_with(String::new);
    streaming.push_str("line 1\n");
    streaming.push_str("line 2\n");
    assert_eq!(
        acc.capability_invocations[0].streaming_output.as_deref(),
        Some("line 1\nline 2\n")
    );
}

#[test]
fn capability_streaming_output_included_in_json() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    acc.update_capability_started("tc_1", None, &EMPTY_IDENTITY);
    acc.capability_invocations[0].streaming_output = Some("partial output".into());
    let (_, capabilities, _) = acc.to_json();
    assert_eq!(capabilities[0]["streamingOutput"], "partial output");
}

#[test]
fn capability_streaming_output_omitted_when_none() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute", &EMPTY_IDENTITY);
    let (_, capabilities, _) = acc.to_json();
    assert!(capabilities[0].get("streamingOutput").is_none());
}

// ── TurnAccumulatorMap tests ──

#[test]
fn map_create_and_get() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.handle_turn_start("s1", None);
    let state = state(&map, "s1");
    assert!(state.is_some());
}

#[test]
fn map_snapshot_pairs_projected_state_with_emitted_sequence() {
    let map = TurnAccumulatorMap::new();
    map.begin_run("s1", "run-1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1").with_sequence(40),
        turn: 1,
    });
    map.update_from_event(&TronEvent::MessageUpdate {
        base: BaseEvent::now("s1").with_sequence(42),
        content: "covered text".into(),
    });

    let (text, _, _) = state(&map, "s1").unwrap();
    assert_eq!(text, "covered text");
    let snapshot = map.reconstruction_snapshot("s1", "run-1").unwrap();
    assert_eq!(snapshot.last_sequence, Some(42));
    assert_eq!(snapshot.generation, 1);
    assert!(snapshot.state.is_some());
}

#[test]
fn out_of_order_observation_invalidates_reconstruction_cursor() {
    let map = TurnAccumulatorMap::new();
    map.begin_run("s1", "run-1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1").with_sequence(40),
        turn: 1,
    });
    map.update_from_event(&TronEvent::MessageUpdate {
        base: BaseEvent::now("s1").with_sequence(42),
        content: "newer".into(),
    });
    map.update_from_event(&TronEvent::AgentStart {
        base: BaseEvent::now("s1").with_sequence(41),
    });

    let snapshot = map.reconstruction_snapshot("s1", "run-1").unwrap();
    assert_eq!(snapshot.last_sequence, None);
}

#[test]
fn response_complete_is_part_of_atomic_turn_snapshot() {
    let map = TurnAccumulatorMap::new();
    map.begin_run("s1", "run-1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1").with_sequence(1),
        turn: 1,
    });
    map.update_from_event(&TronEvent::MessageUpdate {
        base: BaseEvent::now("s1").with_sequence(2),
        content: "done".into(),
    });
    map.update_from_event(&TronEvent::ResponseComplete {
        base: BaseEvent::now("s1").with_sequence(3),
        turn: 1,
        stop_reason: "end_turn".into(),
        token_usage: None,
        has_capability_invocations: false,
        capability_invocation_count: 0,
        token_record: None,
        model: None,
    });

    let snapshot = map.reconstruction_snapshot("s1", "run-1").unwrap();
    assert_eq!(snapshot.last_sequence, Some(3));
    assert!(snapshot.state.unwrap().3);
}

#[test]
fn map_get_nonexistent_returns_none() {
    let map = TurnAccumulatorMap::new();
    assert!(state(&map, "missing").is_none());
}

#[test]
fn map_turn_start_resets_existing() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.handle_turn_start("s1", None);
    map.handle_text_delta("s1", "old text", None);
    map.handle_turn_start("s1", None);
    let (text, _, _) = state(&map, "s1").unwrap();
    assert!(text.is_empty());
}

#[test]
fn map_agent_end_removes_accumulator() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.handle_turn_start("s1", None);
    map.handle_text_delta("s1", "hello", None);
    map.handle_agent_end("s1", None);
    assert!(state(&map, "s1").is_none());
}

#[test]
fn map_turn_end_removes_accumulator() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.handle_turn_start("s1", None);
    map.handle_text_delta("s1", "hello", None);
    map.handle_turn_end("s1", None);
    assert!(state(&map, "s1").is_none());
}

#[test]
fn map_text_delta_without_turn_start_is_noop() {
    let map = TurnAccumulatorMap::new();
    map.handle_text_delta("s1", "orphan", None);
    assert!(state(&map, "s1").is_none());
}

#[test]
fn map_full_event_sequence() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.handle_turn_start("s1", None);
    map.handle_thinking_delta("s1", "let me think...", ThinkingContentKind::Thinking, None);
    map.handle_text_delta("s1", "The answer is ", None);
    map.handle_text_delta("s1", "42", None);
    map.handle_capability_generating("s1", "tc_1", "execute", &EMPTY_IDENTITY, None);
    map.handle_capability_started("s1", "tc_1", None, &EMPTY_IDENTITY, None);
    map.handle_capability_completed("s1", "tc_1", Some("output"), false, &EMPTY_IDENTITY, None);
    map.handle_text_delta("s1", " and more", None);

    let (text, capabilities, sequence) = state(&map, "s1").unwrap();
    assert_eq!(text, "The answer is 42 and more");
    assert_eq!(capabilities.as_array().unwrap().len(), 1);
    assert_eq!(capabilities[0]["status"], "completed");
    let seq = sequence.as_array().unwrap();
    assert_eq!(seq.len(), 4); // thinking, text, capability_ref, text
}

#[test]
fn map_capability_streaming_output() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.handle_turn_start("s1", None);
    map.handle_capability_generating("s1", "tc_1", "execute", &EMPTY_IDENTITY, None);
    map.handle_capability_started("s1", "tc_1", None, &EMPTY_IDENTITY, None);
    map.handle_capability_output("s1", "tc_1", "partial ", None);
    map.handle_capability_output("s1", "tc_1", "output", None);
    let (_, capabilities, _) = state(&map, "s1").unwrap();
    assert_eq!(capabilities[0]["streamingOutput"], "partial output");
}

#[test]
fn map_independent_sessions() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    begin(&map, "s2");
    map.handle_turn_start("s1", None);
    map.handle_turn_start("s2", None);
    map.handle_text_delta("s1", "session 1", None);
    map.handle_text_delta("s2", "session 2", None);

    let (text1, _, _) = state(&map, "s1").unwrap();
    let (text2, _, _) = state(&map, "s2").unwrap();
    assert_eq!(text1, "session 1");
    assert_eq!(text2, "session 2");
}

#[test]
fn map_agent_end_one_session_doesnt_affect_other() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    begin(&map, "s2");
    map.handle_turn_start("s1", None);
    map.handle_turn_start("s2", None);
    map.handle_text_delta("s1", "s1", None);
    map.handle_text_delta("s2", "s2", None);
    map.handle_agent_end("s1", None);

    assert!(state(&map, "s1").is_none());
    assert!(state(&map, "s2").is_some());
}

// ── Integration: update_from_event tests ──

#[test]
fn update_from_turn_start_event() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    let event = TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    };
    map.update_from_event(&event);
    assert!(state(&map, "s1").is_some());
}

#[test]
fn update_from_message_update_event() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hello".into(),
    });
    let (text, _, _) = state(&map, "s1").unwrap();
    assert_eq!(text, "hello");
}

#[test]
fn update_from_thinking_delta_event() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::ThinkingDelta {
        base: BaseEvent::now("s1"),
        delta: "hmm".into(),
        kind: ThinkingContentKind::Thinking,
    });
    let (_, _, sequence) = state(&map, "s1").unwrap();
    let seq = sequence.as_array().unwrap();
    assert_eq!(seq.len(), 1);
    assert_eq!(seq[0]["type"], "thinking");
}

#[test]
fn update_from_capability_lifecycle_events() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::CapabilityInvocationGenerating {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        capability_identity: crate::shared::protocol::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationStarted {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        arguments: None,
        capability_identity: crate::shared::protocol::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationCompleted {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        duration: 100,
        is_error: Some(false),
        result: None,
        capability_identity: crate::shared::protocol::events::CapabilityEventIdentity::default(),
    });
    let (_, capabilities, _) = state(&map, "s1").unwrap();
    assert_eq!(capabilities[0]["status"], "completed");
}

#[test]
fn update_from_capability_invocation_output_event() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::CapabilityInvocationGenerating {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        capability_identity: crate::shared::protocol::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationStarted {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        arguments: None,
        capability_identity: crate::shared::protocol::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationOutput {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        update: "line 1\n".into(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationOutput {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        update: "line 2\n".into(),
    });
    let (_, capabilities, _) = state(&map, "s1").unwrap();
    assert_eq!(capabilities[0]["streamingOutput"], "line 1\nline 2\n");
}

#[test]
fn update_from_agent_end_clears() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hi".into(),
    });
    map.update_from_event(&TronEvent::AgentEnd {
        base: BaseEvent::now("s1"),
        error: None,
    });
    assert!(state(&map, "s1").is_none());
}

#[test]
fn update_from_turn_end_clears() {
    let map = TurnAccumulatorMap::new();
    begin(&map, "s1");
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hi".into(),
    });
    map.update_from_event(&TronEvent::TurnEnd {
        base: BaseEvent::now("s1"),
        turn: 1,
        duration: 0,
        token_usage: None,
        token_record: None,
        cost: None,
        stop_reason: None,
        context_limit: None,
        model: None,
    });
    assert!(state(&map, "s1").is_none());
}

#[test]
fn terminal_markers_clear_state_until_matching_run_release() {
    let map = TurnAccumulatorMap::new();
    map.begin_run("s1", "run-1");
    assert!(map.commit_admission("s1", "run-1", 0));
    map.update_from_event(&TronEvent::CompactionStart {
        base: BaseEvent::now("s1").with_sequence(1),
        reason: crate::shared::protocol::events::CompactionReason::Manual,
        tokens_before: 1_000,
    });

    let compacting = map.reconstruction_snapshot("s1", "run-1").unwrap();
    assert!(compacting.admission_committed);
    assert_eq!(compacting.compaction_reason.as_deref(), Some("manual"));
    assert_eq!(compacting.last_sequence, Some(1));

    map.update_from_event(&TronEvent::AgentEnd {
        base: BaseEvent::now("s1").with_sequence(2),
        error: None,
    });
    let terminal = map.reconstruction_snapshot("s1", "run-1").unwrap();
    assert!(terminal.compaction_reason.is_none());
    assert!(terminal.state.is_none());
    assert_eq!(terminal.last_sequence, Some(2));

    map.finish_run("s1", "run-1");
    assert!(map.reconstruction_snapshot("s1", "run-1").is_none());
}

#[test]
fn capability_progress_and_run_status_are_reconstructed() {
    let map = TurnAccumulatorMap::new();
    map.begin_run("s1", "run-1");
    map.handle_turn_start("s1", Some(1));
    let identity = CapabilityEventIdentity {
        model_primitive_name: Some("execute".into()),
        operation_name: Some("process_run".into()),
        trace_id: Some("trace-1".into()),
        root_invocation_id: Some("root-1".into()),
        theme_color: Some("#00ffff".into()),
        presentation_hints: Some(serde_json::json!({"chipTitle": "Process"})),
    };
    map.handle_capability_generating("s1", "cap-1", "execute", &identity, Some(2));
    map.update_from_event(&TronEvent::CapabilityInvocationProgress {
        base: BaseEvent::now("s1").with_sequence(3),
        invocation_id: "cap-1".into(),
        message: Some("Halfway".into()),
        percent: Some(0.5),
        capability_identity: crate::shared::protocol::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityRunStatus {
        base: BaseEvent::now("s1").with_sequence(4),
        run_id: "async-1".into(),
        invocation_id: "cap-1".into(),
        status: "paused".into(),
        stream_topic: Some("topic-1".into()),
        child_invocations: vec!["child-1".into()],
        details: Some(serde_json::json!({ "reason": "approval" })),
        capability_identity: crate::shared::protocol::events::CapabilityEventIdentity::default(),
    });

    let (_, capabilities, _, _) = map
        .reconstruction_snapshot("s1", "run-1")
        .unwrap()
        .state
        .unwrap();
    assert_eq!(capabilities[0]["status"], "paused");
    assert_eq!(capabilities[0]["progressMessage"], "Run paused");
    assert_eq!(capabilities[0]["progressPercent"], 0.5);
    assert_eq!(capabilities[0]["operationName"], "process_run");
    assert_eq!(capabilities[0]["traceId"], "trace-1");
    assert_eq!(capabilities[0]["rootInvocationId"], "root-1");
    assert_eq!(capabilities[0]["themeColor"], "#00ffff");
    assert_eq!(capabilities[0]["presentationHints"]["chipTitle"], "Process");
    assert_eq!(capabilities[0]["details"]["runId"], "async-1");
    assert_eq!(
        capabilities[0]["details"]["runDetails"]["reason"],
        "approval"
    );

    map.update_from_event(&TronEvent::CapabilityRunStatus {
        base: BaseEvent::now("s1").with_sequence(5),
        run_id: "async-1".into(),
        invocation_id: "cap-1".into(),
        status: "failed".into(),
        stream_topic: Some("topic-1".into()),
        child_invocations: vec![],
        details: Some(serde_json::json!({ "reason": "exit" })),
        capability_identity: identity,
    });
    let (_, failed, _, _) = map
        .reconstruction_snapshot("s1", "run-1")
        .unwrap()
        .state
        .unwrap();
    assert_eq!(failed[0]["status"], "error");
    assert_eq!(failed[0]["isError"], true);
    assert!(failed[0].get("progressMessage").is_none());
    assert!(failed[0].get("progressPercent").is_none());
}

#[test]
fn finishing_stale_run_does_not_remove_replacement_projection() {
    let map = TurnAccumulatorMap::new();
    map.begin_run("s1", "run-1");
    map.begin_run("s1", "run-2");

    map.finish_run("s1", "run-1");

    assert!(map.reconstruction_snapshot("s1", "run-2").is_some());
}

#[test]
fn update_ignores_irrelevant_events() {
    let map = TurnAccumulatorMap::new();
    map.update_from_event(&TronEvent::AgentStart {
        base: BaseEvent::now("s1"),
    });
    map.update_from_event(&TronEvent::AgentReady {
        base: BaseEvent::now("s1"),
    });
    assert!(state(&map, "s1").is_none());
}
