use super::*;
use crate::shared::events::BaseEvent;

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
    acc.append_thinking("step 1 ");
    acc.append_thinking("step 2");
    assert_eq!(acc.thinking, "step 1 step 2");
}

#[test]
fn append_thinking_updates_content_sequence() {
    let mut acc = TurnAccumulator::new();
    acc.append_thinking("think");
    assert_eq!(acc.content_sequence.len(), 1);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::Thinking(t) if t == "think"
    ));
}

#[test]
fn interleaved_text_and_thinking_creates_separate_sequence_items() {
    let mut acc = TurnAccumulator::new();
    acc.append_thinking("hmm");
    acc.append_text("answer");
    assert_eq!(acc.content_sequence.len(), 2);
    assert!(matches!(
        &acc.content_sequence[0],
        ContentSequenceItem::Thinking(_)
    ));
    assert!(matches!(
        &acc.content_sequence[1],
        ContentSequenceItem::Text(_)
    ));
}

#[test]
fn add_capability_invocation_generating() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute");
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
    acc.add_capability_generating("tc_1", "execute");
    acc.update_capability_started("tc_1", Some(&serde_json::json!({"command": "ls"})));
    assert_eq!(acc.capability_invocations[0].status, "running");
    assert!(acc.capability_invocations[0].arguments.is_some());
    assert!(acc.capability_invocations[0].started_at.is_some());
}

#[test]
fn update_capability_completed_success() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute");
    acc.update_capability_started("tc_1", None);
    acc.update_capability_completed("tc_1", Some("output"), false);
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
    acc.add_capability_generating("tc_1", "execute");
    acc.update_capability_started("tc_1", None);
    acc.update_capability_completed("tc_1", Some("command not found"), true);
    assert_eq!(acc.capability_invocations[0].status, "error");
    assert!(acc.capability_invocations[0].is_error);
}

#[test]
fn update_capability_unknown_id_is_noop() {
    let mut acc = TurnAccumulator::new();
    acc.update_capability_started("unknown", None);
    acc.update_capability_completed("unknown", None, false);
    assert!(acc.capability_invocations.is_empty());
}

#[test]
fn multiple_capability_invocations_tracked_independently() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute");
    acc.add_capability_generating("tc_2", "inspect");
    acc.update_capability_started("tc_1", None);
    acc.update_capability_completed("tc_1", Some("ok"), false);
    acc.update_capability_started("tc_2", None);

    assert_eq!(acc.capability_invocations.len(), 2);
    assert_eq!(acc.capability_invocations[0].status, "completed");
    assert_eq!(acc.capability_invocations[1].status, "running");
}

#[test]
fn text_after_capability_creates_new_text_item() {
    let mut acc = TurnAccumulator::new();
    acc.append_text("before ");
    acc.add_capability_generating("tc_1", "execute");
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
    acc.add_capability_generating("tc_1", "execute");
    let (text, capabilities, sequence) = acc.to_json();
    assert_eq!(text, "hello");
    assert!(capabilities.is_array());
    assert_eq!(capabilities.as_array().unwrap().len(), 1);
    assert!(sequence.is_array());
}

// ── ContentSequenceItem::to_json key tests (Phase 1 fix) ──

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
    let item = ContentSequenceItem::Thinking("hmm".into());
    let json = item.to_json();
    assert_eq!(json["type"], "thinking");
    assert_eq!(json["thinking"], "hmm");
    assert!(json.get("content").is_none());
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

// ── Streaming output tests (Phase 2) ──

#[test]
fn capability_streaming_output_accumulates() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute");
    acc.update_capability_started("tc_1", None);
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
    acc.add_capability_generating("tc_1", "execute");
    acc.update_capability_started("tc_1", None);
    acc.capability_invocations[0].streaming_output = Some("partial output".into());
    let (_, capabilities, _) = acc.to_json();
    assert_eq!(capabilities[0]["streamingOutput"], "partial output");
}

#[test]
fn capability_streaming_output_omitted_when_none() {
    let mut acc = TurnAccumulator::new();
    acc.add_capability_generating("tc_1", "execute");
    let (_, capabilities, _) = acc.to_json();
    assert!(capabilities[0].get("streamingOutput").is_none());
}

// ── TurnAccumulatorMap tests ──

#[test]
fn map_create_and_get() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    let state = map.get_state("s1");
    assert!(state.is_some());
}

#[test]
fn map_get_nonexistent_returns_none() {
    let map = TurnAccumulatorMap::new();
    assert!(map.get_state("missing").is_none());
}

#[test]
fn map_turn_start_resets_existing() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    map.handle_text_delta("s1", "old text");
    map.handle_turn_start("s1");
    let (text, _, _) = map.get_state("s1").unwrap();
    assert!(text.is_empty());
}

#[test]
fn map_agent_end_removes_accumulator() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    map.handle_text_delta("s1", "hello");
    map.handle_agent_end("s1");
    assert!(map.get_state("s1").is_none());
}

#[test]
fn map_turn_end_removes_accumulator() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    map.handle_text_delta("s1", "hello");
    map.handle_turn_end("s1");
    assert!(map.get_state("s1").is_none());
}

#[test]
fn map_text_delta_without_turn_start_is_noop() {
    let map = TurnAccumulatorMap::new();
    map.handle_text_delta("s1", "orphan");
    assert!(map.get_state("s1").is_none());
}

#[test]
fn map_full_event_sequence() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    map.handle_thinking_delta("s1", "let me think...");
    map.handle_text_delta("s1", "The answer is ");
    map.handle_text_delta("s1", "42");
    map.handle_capability_generating("s1", "tc_1", "execute");
    map.handle_capability_started("s1", "tc_1", None);
    map.handle_capability_completed("s1", "tc_1", Some("output"), false);
    map.handle_text_delta("s1", " and more");

    let (text, capabilities, sequence) = map.get_state("s1").unwrap();
    assert_eq!(text, "The answer is 42 and more");
    assert_eq!(capabilities.as_array().unwrap().len(), 1);
    assert_eq!(capabilities[0]["status"], "completed");
    let seq = sequence.as_array().unwrap();
    assert_eq!(seq.len(), 4); // thinking, text, capability_ref, text
}

#[test]
fn map_capability_streaming_output() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    map.handle_capability_generating("s1", "tc_1", "execute");
    map.handle_capability_started("s1", "tc_1", None);
    map.handle_capability_output("s1", "tc_1", "partial ");
    map.handle_capability_output("s1", "tc_1", "output");
    let (_, capabilities, _) = map.get_state("s1").unwrap();
    assert_eq!(capabilities[0]["streamingOutput"], "partial output");
}

#[test]
fn map_independent_sessions() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    map.handle_turn_start("s2");
    map.handle_text_delta("s1", "session 1");
    map.handle_text_delta("s2", "session 2");

    let (text1, _, _) = map.get_state("s1").unwrap();
    let (text2, _, _) = map.get_state("s2").unwrap();
    assert_eq!(text1, "session 1");
    assert_eq!(text2, "session 2");
}

#[test]
fn map_agent_end_one_session_doesnt_affect_other() {
    let map = TurnAccumulatorMap::new();
    map.handle_turn_start("s1");
    map.handle_turn_start("s2");
    map.handle_text_delta("s1", "s1");
    map.handle_text_delta("s2", "s2");
    map.handle_agent_end("s1");

    assert!(map.get_state("s1").is_none());
    assert!(map.get_state("s2").is_some());
}

// ── Integration: update_from_event tests ──

#[test]
fn update_from_turn_start_event() {
    let map = TurnAccumulatorMap::new();
    let event = TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    };
    map.update_from_event(&event);
    assert!(map.get_state("s1").is_some());
}

#[test]
fn update_from_message_update_event() {
    let map = TurnAccumulatorMap::new();
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hello".into(),
    });
    let (text, _, _) = map.get_state("s1").unwrap();
    assert_eq!(text, "hello");
}

#[test]
fn update_from_thinking_delta_event() {
    let map = TurnAccumulatorMap::new();
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::ThinkingDelta {
        base: BaseEvent::now("s1"),
        delta: "hmm".into(),
    });
    let (_, _, sequence) = map.get_state("s1").unwrap();
    let seq = sequence.as_array().unwrap();
    assert_eq!(seq.len(), 1);
    assert_eq!(seq[0]["type"], "thinking");
}

#[test]
fn update_from_capability_lifecycle_events() {
    let map = TurnAccumulatorMap::new();
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::CapabilityInvocationGenerating {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationStarted {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        arguments: None,
        capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationCompleted {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        duration: 100,
        is_error: Some(false),
        result: None,
        capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
    });
    let (_, capabilities, _) = map.get_state("s1").unwrap();
    assert_eq!(capabilities[0]["status"], "completed");
}

#[test]
fn update_from_capability_invocation_output_event() {
    let map = TurnAccumulatorMap::new();
    map.update_from_event(&TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    });
    map.update_from_event(&TronEvent::CapabilityInvocationGenerating {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
    });
    map.update_from_event(&TronEvent::CapabilityInvocationStarted {
        base: BaseEvent::now("s1"),
        invocation_id: "tc_1".into(),
        model_primitive_name: "execute".into(),
        arguments: None,
        capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
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
    let (_, capabilities, _) = map.get_state("s1").unwrap();
    assert_eq!(capabilities[0]["streamingOutput"], "line 1\nline 2\n");
}

#[test]
fn update_from_agent_end_clears() {
    let map = TurnAccumulatorMap::new();
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
    assert!(map.get_state("s1").is_none());
}

#[test]
fn update_from_turn_end_clears() {
    let map = TurnAccumulatorMap::new();
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
    assert!(map.get_state("s1").is_none());
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
    assert!(map.get_state("s1").is_none());
}
