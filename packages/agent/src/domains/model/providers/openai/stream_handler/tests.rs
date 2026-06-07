use super::*;
use crate::domains::model::providers::openai::types::{
    OutputContent, OutputItemType, ResponsesOutputItem, ResponsesResponse, ResponsesUsage,
    SseEventType,
};

fn text_delta_event(delta: &str) -> ResponsesSseEvent {
    ResponsesSseEvent {
        event_type: SseEventType::OutputTextDelta,
        delta: Some(delta.into()),
        ..Default::default()
    }
}

fn function_call_added_event(call_id: &str, name: &str) -> ResponsesSseEvent {
    ResponsesSseEvent {
        event_type: SseEventType::OutputItemAdded,
        item: Some(ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some(call_id.into()),
            name: Some(name.into()),
            ..Default::default()
        }),
        ..Default::default()
    }
}

fn function_args_delta_event(call_id: &str, delta: &str) -> ResponsesSseEvent {
    ResponsesSseEvent {
        event_type: SseEventType::FunctionCallArgsDelta,
        call_id: Some(call_id.into()),
        delta: Some(delta.into()),
        ..Default::default()
    }
}

fn reasoning_added_event() -> ResponsesSseEvent {
    ResponsesSseEvent {
        event_type: SseEventType::OutputItemAdded,
        item: Some(ResponsesOutputItem {
            item_type: OutputItemType::Reasoning,
            ..Default::default()
        }),
        ..Default::default()
    }
}

fn reasoning_summary_delta_event(delta: &str) -> ResponsesSseEvent {
    ResponsesSseEvent {
        event_type: SseEventType::ReasoningSummaryTextDelta,
        delta: Some(delta.into()),
        ..Default::default()
    }
}

fn completed_event(
    output: Vec<ResponsesOutputItem>,
    usage: Option<ResponsesUsage>,
) -> ResponsesSseEvent {
    ResponsesSseEvent {
        event_type: SseEventType::Completed,
        response: Some(ResponsesResponse {
            id: Some("resp-123".into()),
            output,
            usage,
        }),
        ..Default::default()
    }
}

// ── create_stream_state ────────────────────────────────────────

#[test]
fn initial_state_is_empty() {
    let state = create_stream_state();
    assert!(state.acc.accumulated_text.is_empty());
    assert!(state.acc.accumulated_thinking.is_empty());
    assert!(state.capability_invocations.is_empty());
    assert_eq!(state.acc.input_tokens, 0);
    assert_eq!(state.acc.output_tokens, 0);
    assert!(!state.acc.text_started);
    assert!(!state.acc.thinking_started);
    assert!(!state.capability_argument_failed);
}

// ── Text streaming ─────────────────────────────────────────────

#[test]
fn emits_text_start_on_first_delta() {
    let mut state = create_stream_state();
    let events = process_stream_event(&text_delta_event("Hello"), &mut state);

    assert_eq!(events.len(), 2);
    assert_eq!(events[0], StreamEvent::TextStart);
    assert_eq!(
        events[1],
        StreamEvent::TextDelta {
            delta: "Hello".into()
        }
    );
    assert!(state.acc.text_started);
    assert_eq!(state.acc.accumulated_text, "Hello");
}

#[test]
fn emits_only_delta_on_subsequent() {
    let mut state = create_stream_state();
    state.acc.text_started = true;
    state.acc.accumulated_text = "Hello".into();

    let events = process_stream_event(&text_delta_event(" world"), &mut state);

    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0],
        StreamEvent::TextDelta {
            delta: " world".into()
        }
    );
    assert_eq!(state.acc.accumulated_text, "Hello world");
}

#[test]
fn ignores_text_delta_without_content() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::OutputTextDelta,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
}

// ── Capability invocation streaming ────────────────────────────────────────

#[test]
fn emits_toolcall_start_on_function_call_added() {
    let mut state = create_stream_state();
    let events = process_stream_event(
        &function_call_added_event("call_123", "read_file"),
        &mut state,
    );

    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0],
        StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "call_123".into(),
            name: "read_file".into(),
        }
    );
    assert!(state.capability_invocations.contains_key("call_123"));
}

#[test]
fn accumulates_function_call_arguments() {
    let mut state = create_stream_state();
    state.capability_invocations.insert(
        "call_123".into(),
        CapabilityInvocationDraftState {
            id: "call_123".into(),
            name: "read_file".into(),
            args: String::new(),
        },
    );

    let events = process_stream_event(
        &function_args_delta_event("call_123", r#"{"path":"/test.txt"}"#),
        &mut state,
    );

    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0],
        StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "call_123".into(),
            arguments_delta: r#"{"path":"/test.txt"}"#.into(),
        }
    );
    assert_eq!(
        state.capability_invocations["call_123"].args,
        r#"{"path":"/test.txt"}"#
    );
}

#[test]
fn accumulates_args_delta_before_added_event() {
    let mut state = create_stream_state();
    let events = process_stream_event(
        &function_args_delta_event(
            "call_late",
            r#"{"operation":"process_run","command":"date"}"#,
        ),
        &mut state,
    );
    assert_eq!(events.len(), 1);
    assert_eq!(
        state.capability_invocations["call_late"].args,
        r#"{"operation":"process_run","command":"date"}"#
    );

    let events = process_stream_event(
        &function_call_added_event("call_late", "execute"),
        &mut state,
    );
    assert!(events.is_empty());
    assert_eq!(state.capability_invocations["call_late"].name, "execute");
    assert_eq!(
        state.capability_invocations["call_late"].args,
        r#"{"operation":"process_run","command":"date"}"#
    );
}

// ── Reasoning streaming ────────────────────────────────────────

#[test]
fn emits_thinking_start_on_reasoning_item() {
    let mut state = create_stream_state();
    let events = process_stream_event(&reasoning_added_event(), &mut state);

    assert_eq!(events.len(), 1);
    assert_eq!(events[0], StreamEvent::ThinkingStart);
    assert!(state.acc.thinking_started);
}

#[test]
fn emits_thinking_delta_for_reasoning_summary() {
    let mut state = create_stream_state();
    state.acc.thinking_started = true;

    let events = process_stream_event(&reasoning_summary_delta_event("Analyzing..."), &mut state);

    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0],
        StreamEvent::ThinkingDelta {
            delta: "Analyzing...".into()
        }
    );
    assert_eq!(state.acc.accumulated_thinking, "Analyzing...");
}

#[test]
fn deduplicates_reasoning_text() {
    let mut state = create_stream_state();
    state.acc.thinking_started = true;
    state.seen_thinking_texts.insert("Already seen".into());

    let events = process_stream_event(&reasoning_summary_delta_event("Already seen"), &mut state);
    assert!(events.is_empty());
}

#[test]
fn handles_reasoning_from_output_item_done() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::OutputItemDone,
        item: Some(ResponsesOutputItem {
            item_type: OutputItemType::Reasoning,
            summary: Some(vec![OutputContent {
                content_type: "summary_text".into(),
                text: Some("The approach is correct.".into()),
            }]),
            ..Default::default()
        }),
        ..Default::default()
    };

    let events = process_stream_event(&event, &mut state);
    let types: Vec<_> = events
        .iter()
        .map(|e| match e {
            StreamEvent::ThinkingStart => "thinking_start",
            StreamEvent::ThinkingDelta { .. } => "thinking_delta",
            _ => "other",
        })
        .collect();
    assert_eq!(types, vec!["thinking_start", "thinking_delta"]);
    assert_eq!(state.acc.accumulated_thinking, "The approach is correct.");
}

#[test]
fn skips_output_item_done_if_already_accumulated() {
    let mut state = create_stream_state();
    state.acc.accumulated_thinking = "Already accumulated".into();

    let event = ResponsesSseEvent {
        event_type: SseEventType::OutputItemDone,
        item: Some(ResponsesOutputItem {
            item_type: OutputItemType::Reasoning,
            summary: Some(vec![OutputContent {
                content_type: "summary_text".into(),
                text: Some("Different text".into()),
            }]),
            ..Default::default()
        }),
        ..Default::default()
    };

    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
    assert_eq!(state.acc.accumulated_thinking, "Already accumulated");
}

// ── response.completed ─────────────────────────────────────────

#[test]
fn completed_emits_text_end_and_done() {
    let mut state = create_stream_state();
    state.acc.text_started = true;
    state.acc.accumulated_text = "Hello world".into();

    let event = completed_event(
        vec![ResponsesOutputItem {
            item_type: OutputItemType::Message,
            content: Some(vec![OutputContent {
                content_type: "output_text".into(),
                text: Some("Hello world".into()),
            }]),
            ..Default::default()
        }],
        Some(ResponsesUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        }),
    );

    let events = process_stream_event(&event, &mut state);
    let types: Vec<&str> = events
        .iter()
        .map(|e| match e {
            StreamEvent::TextEnd { .. } => "text_end",
            StreamEvent::Done { .. } => "done",
            _ => "other",
        })
        .collect();
    assert!(types.contains(&"text_end"));
    assert!(types.contains(&"done"));

    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    if let Some(StreamEvent::Done {
        message,
        stop_reason,
    }) = done
    {
        assert_eq!(message.content.len(), 1);
        assert_eq!(message.token_usage.as_ref().unwrap().input_tokens, 100);
        assert_eq!(message.token_usage.as_ref().unwrap().output_tokens, 50);
        assert_eq!(stop_reason, "end_turn");
    }
}

#[test]
fn completed_emits_toolcall_end_with_capability_invocation_stop_reason() {
    let mut state = create_stream_state();
    state.capability_invocations.insert(
        "call_abc".into(),
        CapabilityInvocationDraftState {
            id: "call_abc".into(),
            name: "read_file".into(),
            args: r#"{"path":"/test.txt"}"#.into(),
        },
    );

    let event = completed_event(
        vec![ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some("call_abc".into()),
            name: Some("read_file".into()),
            arguments: Some(r#"{"path":"/test.txt"}"#.into()),
            ..Default::default()
        }],
        Some(ResponsesUsage {
            input_tokens: 50,
            output_tokens: 30,
            ..Default::default()
        }),
    );

    let events = process_stream_event(&event, &mut state);
    let capability_completed = events
        .iter()
        .find(|e| matches!(e, StreamEvent::CapabilityInvocationDraftEnd { .. }));
    assert!(capability_completed.is_some());

    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    if let Some(StreamEvent::Done { stop_reason, .. }) = done {
        assert_eq!(stop_reason, "capability_invocation");
    }
}

#[test]
fn output_item_done_emits_toolcall_end_with_arguments() {
    let mut state = create_stream_state();
    let _ = process_stream_event(
        &function_call_added_event("call_abc", "execute"),
        &mut state,
    );

    let event = ResponsesSseEvent {
        event_type: SseEventType::OutputItemDone,
        item: Some(ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some("call_abc".into()),
            name: Some("execute".into()),
            arguments: Some(r#"{"operation":"process_run","command":"date"}"#.into()),
            ..Default::default()
        }),
        ..Default::default()
    };

    let events = process_stream_event(&event, &mut state);
    let capability_completed = events
        .iter()
        .find(|e| matches!(e, StreamEvent::CapabilityInvocationDraftEnd { .. }));
    assert!(capability_completed.is_some());
    if let Some(StreamEvent::CapabilityInvocationDraftEnd {
        capability_invocation,
    }) = capability_completed
    {
        assert_eq!(capability_invocation.name, "execute");
        assert_eq!(
            capability_invocation
                .arguments
                .get("operation")
                .and_then(|value| value.as_str()),
            Some("process_run")
        );
        assert_eq!(
            capability_invocation
                .arguments
                .get("command")
                .and_then(|value| value.as_str()),
            Some("date")
        );
    }
}

#[test]
fn output_item_done_with_malformed_arguments_fails_closed() {
    let mut state = create_stream_state();
    let _ = process_stream_event(
        &function_call_added_event("call_bad", "execute"),
        &mut state,
    );

    let event = ResponsesSseEvent {
        event_type: SseEventType::OutputItemDone,
        item: Some(ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some("call_bad".into()),
            name: Some("execute".into()),
            arguments: Some("not json".into()),
            ..Default::default()
        }),
        ..Default::default()
    };

    let events = process_stream_event(&event, &mut state);
    assert!(
            events
                .iter()
                .any(|event| matches!(event, StreamEvent::Error { error } if error.contains("malformed JSON") && error.contains("call_bad")))
        );
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, StreamEvent::CapabilityInvocationDraftEnd { .. }))
    );
}

#[test]
fn completed_with_thinking_emits_thinking_end_before_done() {
    let mut state = create_stream_state();
    state.acc.thinking_started = true;
    state.acc.accumulated_thinking = "Some reasoning".into();
    state.acc.text_started = true;
    state.acc.accumulated_text = "The answer".into();

    let event = completed_event(
        vec![ResponsesOutputItem {
            item_type: OutputItemType::Message,
            content: Some(vec![OutputContent {
                content_type: "output_text".into(),
                text: Some("The answer".into()),
            }]),
            ..Default::default()
        }],
        Some(ResponsesUsage {
            input_tokens: 50,
            output_tokens: 30,
            ..Default::default()
        }),
    );

    let events = process_stream_event(&event, &mut state);
    let types: Vec<&str> = events
        .iter()
        .map(|e| match e {
            StreamEvent::ThinkingEnd { .. } => "thinking_end",
            StreamEvent::TextEnd { .. } => "text_end",
            StreamEvent::Done { .. } => "done",
            _ => "other",
        })
        .collect();
    let thinking_idx = types.iter().position(|t| *t == "thinking_end").unwrap();
    let done_idx = types.iter().position(|t| *t == "done").unwrap();
    assert!(thinking_idx < done_idx);

    // Done message should have both thinking and text
    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    if let Some(StreamEvent::Done { message, .. }) = done {
        assert_eq!(message.content.len(), 2);
    }
}

#[test]
fn completed_malformed_function_call_arguments_emit_error_without_invocation() {
    let mut state = create_stream_state();
    let event = completed_event(
        vec![ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some("call_bad".into()),
            name: Some("execute".into()),
            arguments: Some("not json".into()),
            ..Default::default()
        }],
        Some(ResponsesUsage {
            input_tokens: 50,
            output_tokens: 30,
            ..Default::default()
        }),
    );

    let events = process_stream_event(&event, &mut state);
    assert!(
            events
                .iter()
                .any(|event| matches!(event, StreamEvent::Error { error } if error.contains("openai capability invocation arguments") && error.contains("execute") && error.contains("call_bad")))
        );
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, StreamEvent::CapabilityInvocationDraftEnd { .. }))
    );
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, StreamEvent::Done { .. }))
    );
}

#[test]
fn completed_empty_response_is_handled() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::Completed,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
}

#[test]
fn completed_discovers_capability_invocations_not_seen_in_deltas() {
    let mut state = create_stream_state();
    let event = completed_event(
        vec![ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some("call_new".into()),
            name: Some("write_file".into()),
            arguments: Some(r#"{"path":"/out.txt","content":"data"}"#.into()),
            ..Default::default()
        }],
        Some(ResponsesUsage {
            input_tokens: 50,
            output_tokens: 30,
            ..Default::default()
        }),
    );

    let events = process_stream_event(&event, &mut state);
    let capability_completed = events
        .iter()
        .find(|e| matches!(e, StreamEvent::CapabilityInvocationDraftEnd { .. }));
    assert!(capability_completed.is_some());
    if let Some(StreamEvent::CapabilityInvocationDraftEnd {
        capability_invocation,
    }) = capability_completed
    {
        assert_eq!(capability_invocation.name, "write_file");
    }

    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    if let Some(StreamEvent::Done { stop_reason, .. }) = done {
        assert_eq!(stop_reason, "capability_invocation");
    }
}

#[test]
fn duplicate_output_item_added_emits_toolcall_start_once() {
    let mut state = create_stream_state();
    let events1 = process_stream_event(
        &function_call_added_event("call_dup", "read_file"),
        &mut state,
    );
    assert_eq!(events1.len(), 1);
    assert!(matches!(
        &events1[0],
        StreamEvent::CapabilityInvocationDraftStart { .. }
    ));

    // Second OutputItemAdded for the same call_id should NOT emit CapabilityInvocationDraftStart
    let events2 = process_stream_event(
        &function_call_added_event("call_dup", "read_file"),
        &mut state,
    );
    assert!(
        events2.is_empty(),
        "duplicate OutputItemAdded should not emit CapabilityInvocationDraftStart"
    );
    // State should still have exactly one entry
    assert_eq!(state.capability_invocations.len(), 1);
}

// ── ModelCapability search events ────────────────────────────────────────

#[test]
fn tool_search_searching_returns_empty() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::ToolSearchCallSearching,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
}

#[test]
fn tool_search_completed_returns_empty() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::ToolSearchCallCompleted,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
}

#[test]
fn computer_call_completed_returns_empty() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::ComputerCallCompleted,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
}

// ── Unknown events ─────────────────────────────────────────────

#[test]
fn unknown_event_type_returns_empty() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::Unknown,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
}

// ── reasoning_summary_part.added ───────────────────────────────

#[test]
fn reasoning_summary_part_added_emits_thinking_start() {
    let mut state = create_stream_state();
    let event = ResponsesSseEvent {
        event_type: SseEventType::ReasoningSummaryPartAdded,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0], StreamEvent::ThinkingStart);
}

#[test]
fn reasoning_summary_part_added_noop_when_already_started() {
    let mut state = create_stream_state();
    state.acc.thinking_started = true;
    let event = ResponsesSseEvent {
        event_type: SseEventType::ReasoningSummaryPartAdded,
        ..Default::default()
    };
    let events = process_stream_event(&event, &mut state);
    assert!(events.is_empty());
}

// ── Token usage in done message ────────────────────────────────

#[test]
fn done_event_has_openai_provider_type() {
    let mut state = create_stream_state();
    state.acc.text_started = true;
    state.acc.accumulated_text = "test".into();

    let event = completed_event(
        vec![],
        Some(ResponsesUsage {
            input_tokens: 10,
            output_tokens: 5,
            ..Default::default()
        }),
    );

    let events = process_stream_event(&event, &mut state);
    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    if let Some(StreamEvent::Done { message, .. }) = done {
        assert_eq!(
            message.token_usage.as_ref().unwrap().provider_type,
            Some(crate::shared::messages::Provider::OpenAi)
        );
    }
}

// ── Full reasoning text (response.reasoning_text.delta) ───────

fn reasoning_text_delta_event(delta: &str) -> ResponsesSseEvent {
    ResponsesSseEvent {
        event_type: SseEventType::ReasoningTextDelta,
        delta: Some(delta.into()),
        ..Default::default()
    }
}

#[test]
fn reasoning_text_delta_emits_thinking_events() {
    let mut state = create_stream_state();
    let events = process_stream_event(
        &reasoning_text_delta_event("Let me think about this..."),
        &mut state,
    );

    assert_eq!(events.len(), 2);
    assert_eq!(events[0], StreamEvent::ThinkingStart);
    assert_eq!(
        events[1],
        StreamEvent::ThinkingDelta {
            delta: "Let me think about this...".into()
        }
    );
    assert!(state.has_reasoning_text);
    assert!(state.acc.thinking_started);
    assert_eq!(state.acc.accumulated_thinking, "Let me think about this...");
}

#[test]
fn reasoning_text_replaces_prior_summary() {
    let mut state = create_stream_state();
    // First, receive a summary delta
    let _ = process_stream_event(
        &reasoning_summary_delta_event("**Short summary**"),
        &mut state,
    );
    assert_eq!(state.acc.accumulated_thinking, "**Short summary**");

    // Then receive full reasoning text — should replace summary
    let events = process_stream_event(
        &reasoning_text_delta_event("Full reasoning content here..."),
        &mut state,
    );

    assert!(state.has_reasoning_text);
    assert_eq!(
        state.acc.accumulated_thinking,
        "Full reasoning content here..."
    );
    // Should emit ThinkingDelta (ThinkingStart already emitted by summary)
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0],
        StreamEvent::ThinkingDelta {
            delta: "Full reasoning content here...".into()
        }
    );
}

#[test]
fn summary_skipped_when_reasoning_text_active() {
    let mut state = create_stream_state();
    // Receive full reasoning text first
    let _ = process_stream_event(&reasoning_text_delta_event("Full reasoning..."), &mut state);

    // Summary delta should be ignored
    let events = process_stream_event(&reasoning_summary_delta_event("**Summary**"), &mut state);
    assert!(events.is_empty());
    assert_eq!(state.acc.accumulated_thinking, "Full reasoning...");
}

#[test]
fn reasoning_text_accumulates_multiple_deltas() {
    let mut state = create_stream_state();
    let _ = process_stream_event(&reasoning_text_delta_event("First part. "), &mut state);
    let _ = process_stream_event(&reasoning_text_delta_event("Second part."), &mut state);
    assert_eq!(state.acc.accumulated_thinking, "First part. Second part.");
}
