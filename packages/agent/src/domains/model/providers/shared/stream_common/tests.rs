use super::*;

// ── new / default ───────────────────────────────────────────────

#[test]
fn new_accumulator_is_empty() {
    let acc = StreamAccumulator::new();
    assert!(acc.accumulated_text.is_empty());
    assert!(acc.accumulated_thinking.is_empty());
    assert!(acc.accumulated_signature.is_empty());
    assert!(!acc.text_started);
    assert!(!acc.thinking_started);
    assert!(acc.capability_invocations.is_empty());
    assert_eq!(acc.input_tokens, 0);
    assert_eq!(acc.output_tokens, 0);
}

#[test]
fn default_matches_new() {
    let a = StreamAccumulator::new();
    let b = StreamAccumulator::default();
    assert_eq!(a.accumulated_text, b.accumulated_text);
    assert_eq!(a.text_started, b.text_started);
}

// ── process_text_delta ──────────────────────────────────────────

#[test]
fn text_delta_emits_start_on_first_call() {
    let mut acc = StreamAccumulator::new();
    let events = acc.process_text_delta("hello");
    assert_eq!(events.len(), 2);
    assert!(matches!(events[0], StreamEvent::TextStart));
    assert!(matches!(&events[1], StreamEvent::TextDelta { delta } if delta == "hello"));
    assert!(acc.text_started);
    assert_eq!(acc.accumulated_text, "hello");
}

#[test]
fn text_delta_only_delta_on_subsequent() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.process_text_delta("hello");
    let events = acc.process_text_delta(" world");
    assert_eq!(events.len(), 1);
    assert!(matches!(&events[0], StreamEvent::TextDelta { delta } if delta == " world"));
    assert_eq!(acc.accumulated_text, "hello world");
}

// ── process_thinking_delta ──────────────────────────────────────

#[test]
fn thinking_delta_emits_start_on_first_call() {
    let mut acc = StreamAccumulator::new();
    let events = acc.process_thinking_delta("thinking...");
    assert_eq!(events.len(), 2);
    assert!(matches!(events[0], StreamEvent::ThinkingStart));
    assert!(matches!(&events[1], StreamEvent::ThinkingDelta { delta } if delta == "thinking..."));
    assert!(acc.thinking_started);
    assert_eq!(acc.accumulated_thinking, "thinking...");
}

#[test]
fn thinking_delta_only_delta_on_subsequent() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.process_thinking_delta("first");
    let events = acc.process_thinking_delta(" second");
    assert_eq!(events.len(), 1);
    assert!(matches!(&events[0], StreamEvent::ThinkingDelta { delta } if delta == " second"));
    assert_eq!(acc.accumulated_thinking, "first second");
}

// ── mark_text_started / mark_thinking_started ───────────────────

#[test]
fn mark_text_started_returns_event_once() {
    let mut acc = StreamAccumulator::new();
    assert!(acc.mark_text_started().is_some());
    assert!(acc.mark_text_started().is_none());
}

#[test]
fn mark_thinking_started_returns_event_once() {
    let mut acc = StreamAccumulator::new();
    assert!(acc.mark_thinking_started().is_some());
    assert!(acc.mark_thinking_started().is_none());
}

// ── accumulate_text / accumulate_thinking / accumulate_signature ─

#[test]
fn accumulate_text_does_not_emit_events() {
    let mut acc = StreamAccumulator::new();
    assert!(acc.accumulate_text("silent").is_none());
    assert_eq!(acc.accumulated_text, "silent");
    assert!(!acc.text_started);
}

#[test]
fn accumulate_thinking_does_not_emit_events() {
    let mut acc = StreamAccumulator::new();
    assert!(acc.accumulate_thinking("silent thought").is_none());
    assert_eq!(acc.accumulated_thinking, "silent thought");
    assert!(!acc.thinking_started);
}

#[test]
fn accumulate_signature_appends() {
    let mut acc = StreamAccumulator::new();
    acc.accumulate_signature("part1");
    acc.accumulate_signature("_part2");
    assert_eq!(acc.accumulated_signature, "part1_part2");
}

// ── capability invocation lifecycle ─────────────────────────────────────────

#[test]
fn start_capability_invocation_emits_start_event() {
    let mut acc = StreamAccumulator::new();
    let events = acc.start_capability_invocation("call_1".into(), "execute".into());
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftStart {
            invocation_id,
            name,
        } => {
            assert_eq!(invocation_id, "call_1");
            assert_eq!(name, "execute");
        }
        _ => panic!("expected CapabilityInvocationDraftStart"),
    }
    assert_eq!(acc.capability_invocations.len(), 1);
}

#[test]
fn append_tool_args_emits_delta() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
    let events = acc.append_tool_args("call_1", r#"{"cmd":"#);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id,
            arguments_delta,
        } => {
            assert_eq!(invocation_id, "call_1");
            assert_eq!(arguments_delta, r#"{"cmd":"#);
        }
        _ => panic!("expected CapabilityInvocationDraftDelta"),
    }
    assert_eq!(acc.capability_invocations[0].args, r#"{"cmd":"#);
}

#[test]
fn append_tool_args_unknown_id_returns_empty() {
    let mut acc = StreamAccumulator::new();
    let events = acc.append_tool_args("unknown", "data");
    assert!(events.is_empty());
}

#[test]
fn text_delta_over_limit_emits_error_and_clears_buffer() {
    let mut acc = StreamAccumulator::new();
    let events = acc.process_text_delta(&"x".repeat(MAX_STREAM_ACCUMULATED_TEXT_BYTES + 1));

    assert!(matches!(
        &events[..],
        [StreamEvent::Error { error }] if error.contains("stream text buffer exceeded maximum size")
    ));
    assert!(acc.accumulated_text.is_empty());
}

#[test]
fn thinking_delta_over_limit_emits_error_and_clears_buffer() {
    let mut acc = StreamAccumulator::new();
    let events = acc.process_thinking_delta(&"x".repeat(MAX_STREAM_ACCUMULATED_THINKING_BYTES + 1));

    assert!(matches!(
        &events[..],
        [StreamEvent::Error { error }] if error.contains("stream thinking buffer exceeded maximum size")
    ));
    assert!(acc.accumulated_thinking.is_empty());
}

#[test]
fn capability_argument_over_limit_emits_error_and_clears_buffer() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
    let events = acc.append_tool_args(
        "call_1",
        &"x".repeat(MAX_STREAM_CAPABILITY_ARGUMENT_BYTES + 1),
    );

    assert!(matches!(
        &events[..],
        [StreamEvent::Error { error }]
            if error.contains("stream capability argument buffer exceeded maximum size")
    ));
    assert_eq!(acc.capability_invocations()[0].args, "");
}

#[test]
fn active_capability_invocation_limit_rejects_fanout() {
    let mut acc = StreamAccumulator::new();
    for index in 0..MAX_ACTIVE_STREAM_CAPABILITY_INVOCATIONS {
        let events = acc.start_capability_invocation(format!("call_{index}"), "execute".into());
        assert!(matches!(
            &events[..],
            [StreamEvent::CapabilityInvocationDraftStart { .. }]
        ));
    }

    let events = acc.start_capability_invocation("overflow".into(), "execute".into());
    assert!(matches!(
        &events[..],
        [StreamEvent::Error { error }]
            if error.contains("active stream capability invocation limit exceeded")
    ));
}

#[test]
fn finish_capability_invocation_emits_end_with_parsed_args() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
    let _ = acc.append_tool_args("call_1", r#"{"cmd":"ls"}"#);
    let events = acc.finish_capability_invocation("call_1");
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        } => {
            assert_eq!(capability_invocation.id, "call_1");
            assert_eq!(capability_invocation.name, "execute");
            assert_eq!(capability_invocation.arguments["cmd"], "ls");
        }
        _ => panic!("expected CapabilityInvocationDraftEnd"),
    }
    assert!(acc.capability_invocations.is_empty());
}

#[test]
fn finish_capability_invocation_unknown_id_returns_empty() {
    let mut acc = StreamAccumulator::new();
    let events = acc.finish_capability_invocation("unknown");
    assert!(events.is_empty());
}

#[test]
fn finish_capability_invocation_empty_args_gives_empty_map() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
    let events = acc.finish_capability_invocation("call_1");
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        } => {
            assert!(capability_invocation.arguments.is_empty());
        }
        _ => panic!("expected CapabilityInvocationDraftEnd"),
    }
}

#[test]
fn finish_capability_invocation_malformed_args_emits_error() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
    let _ = acc.append_tool_args("call_1", "not json");
    let events = acc.finish_capability_invocation_with_provider("call_1", Some("anthropic"));
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::Error { error } => {
            assert!(error.contains("anthropic capability invocation arguments"));
            assert!(error.contains("malformed JSON"));
        }
        _ => panic!("expected Error"),
    }
}

#[test]
fn finish_capability_invocation_with_thought_signature() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
    let _ = acc.append_tool_args("call_1", r#"{"cmd":"ls"}"#);
    let args: Map<String, serde_json::Value> = serde_json::from_str(r#"{"cmd":"ls"}"#).unwrap();
    let events = acc.finish_capability_invocation_with("call_1", args, Some("sig-abc".into()));
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        } => {
            assert_eq!(
                capability_invocation.thought_signature.as_deref(),
                Some("sig-abc")
            );
        }
        _ => panic!("expected CapabilityInvocationDraftEnd"),
    }
}

// ── close_thinking / close_text ─────────────────────────────────

#[test]
fn close_thinking_emits_end_when_started() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.process_thinking_delta("thought");
    let events = acc.close_thinking(Some("sig".into()));
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::ThinkingEnd {
            thinking,
            signature,
        } => {
            assert_eq!(thinking, "thought");
            assert_eq!(signature.as_deref(), Some("sig"));
        }
        _ => panic!("expected ThinkingEnd"),
    }
    assert!(!acc.thinking_started);
}

#[test]
fn close_thinking_noop_when_not_started() {
    let mut acc = StreamAccumulator::new();
    let events = acc.close_thinking(None);
    assert!(events.is_empty());
}

#[test]
fn close_text_emits_end_when_started() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.process_text_delta("hello");
    let events = acc.close_text(None);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::TextEnd { text, signature } => {
            assert_eq!(text, "hello");
            assert!(signature.is_none());
        }
        _ => panic!("expected TextEnd"),
    }
    assert!(!acc.text_started);
}

#[test]
fn close_text_noop_when_not_started() {
    let mut acc = StreamAccumulator::new();
    let events = acc.close_text(None);
    assert!(events.is_empty());
}

// ── take helpers ────────────────────────────────────────────────

#[test]
fn take_text_resets_buffer_and_flag() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.process_text_delta("data");
    let text = acc.take_text();
    assert_eq!(text, "data");
    assert!(acc.accumulated_text.is_empty());
    assert!(!acc.text_started);
}

#[test]
fn take_thinking_resets_buffer_and_flag() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.process_thinking_delta("thought");
    let text = acc.take_thinking();
    assert_eq!(text, "thought");
    assert!(acc.accumulated_thinking.is_empty());
    assert!(!acc.thinking_started);
}

#[test]
fn take_signature_returns_none_when_empty() {
    let mut acc = StreamAccumulator::new();
    assert!(acc.take_signature().is_none());
}

#[test]
fn take_signature_returns_some_and_resets() {
    let mut acc = StreamAccumulator::new();
    acc.accumulate_signature("sig123");
    let sig = acc.take_signature();
    assert_eq!(sig.as_deref(), Some("sig123"));
    assert!(acc.accumulated_signature.is_empty());
}

// ── token tracking ──────────────────────────────────────────────

#[test]
fn set_tokens_updates_counts() {
    let mut acc = StreamAccumulator::new();
    acc.set_tokens(100, 50);
    assert_eq!(acc.input_tokens, 100);
    assert_eq!(acc.output_tokens, 50);
}

// ── capability_invocations accessor ─────────────────────────────────────────

#[test]
fn capability_invocations_returns_active_calls() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("a".into(), "tool_a".into());
    let _ = acc.start_capability_invocation("b".into(), "tool_b".into());
    assert_eq!(acc.capability_invocations().len(), 2);
    let _ = acc.finish_capability_invocation("a");
    assert_eq!(acc.capability_invocations().len(), 1);
    assert_eq!(acc.capability_invocations()[0].id, "b");
}

#[test]
fn capability_invocation_mut_returns_mutable_ref() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
    let tc = acc.capability_invocation_mut("call_1").unwrap();
    tc.args.push_str("modified");
    assert_eq!(acc.capability_invocations()[0].args, "modified");
}

// ── full lifecycle ──────────────────────────────────────────────

#[test]
fn full_text_lifecycle() {
    let mut acc = StreamAccumulator::new();
    let e1 = acc.process_text_delta("Hello ");
    let e2 = acc.process_text_delta("world");
    let e3 = acc.close_text(None);

    assert_eq!(e1.len(), 2); // TextStart + TextDelta
    assert_eq!(e2.len(), 1); // TextDelta only
    assert_eq!(e3.len(), 1); // TextEnd
    match &e3[0] {
        StreamEvent::TextEnd { text, .. } => assert_eq!(text, "Hello world"),
        _ => panic!("expected TextEnd"),
    }
}

#[test]
fn full_thinking_then_text_lifecycle() {
    let mut acc = StreamAccumulator::new();
    let _ = acc.process_thinking_delta("Let me think");
    let close_events = acc.close_thinking(Some("sig".into()));
    assert_eq!(close_events.len(), 1);

    let text_events = acc.process_text_delta("The answer");
    assert_eq!(text_events.len(), 2); // TextStart + TextDelta
}

#[test]
fn full_capability_invocation_lifecycle() {
    let mut acc = StreamAccumulator::new();
    let start = acc.start_capability_invocation("call_1".into(), "execute".into());
    let d1 = acc.append_tool_args("call_1", r#"{"cm"#);
    let d2 = acc.append_tool_args("call_1", r#"d":"ls"}"#);
    let end = acc.finish_capability_invocation("call_1");

    assert_eq!(start.len(), 1);
    assert_eq!(d1.len(), 1);
    assert_eq!(d2.len(), 1);
    assert_eq!(end.len(), 1);
    match &end[0] {
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        } => {
            assert_eq!(capability_invocation.id, "call_1");
            assert_eq!(capability_invocation.arguments["cmd"], "ls");
        }
        _ => panic!("expected CapabilityInvocationDraftEnd"),
    }
}
