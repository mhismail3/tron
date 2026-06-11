use super::*;
use crate::domains::model::providers::google::types::{
    FunctionCallData, GeminiApiError, GeminiCandidate, GeminiCandidateContent, HarmCategory,
    UsageMetadata,
};

fn empty_chunk() -> GeminiStreamChunk {
    GeminiStreamChunk::default()
}

// ── create_stream_state ──────────────────────────────────────────

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
    assert_eq!(state.capability_invocation_index, 0);
    assert!(!state.unique_prefix.is_empty());
}

// ── Error handling ───────────────────────────────────────────────

#[test]
fn api_error_emits_error_event() {
    let chunk = GeminiStreamChunk {
        error: Some(GeminiApiError {
            code: 429,
            message: "Rate limit".into(),
        }),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    let events = process_stream_chunk(&chunk, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::Error { error } => {
            assert!(error.contains("429"));
            assert!(error.contains("Rate limit"));
        }
        _ => panic!("Expected error event"),
    }
}

// ── Token usage ──────────────────────────────────────────────────

#[test]
fn updates_token_usage() {
    let chunk = GeminiStreamChunk {
        usage_metadata: Some(UsageMetadata {
            prompt_token_count: 100,
            candidates_token_count: 50,
            total_token_count: 150,
            ..Default::default()
        }),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    let _ = process_stream_chunk(&chunk, &mut state);
    assert_eq!(state.acc.input_tokens, 100);
    assert_eq!(state.acc.output_tokens, 50);
}

// ── Text streaming ───────────────────────────────────────────────

#[test]
fn emits_text_start_on_first_text() {
    let chunk = GeminiStreamChunk {
        candidates: Some(vec![GeminiCandidate {
            content: Some(GeminiCandidateContent {
                parts: vec![GeminiPart::Text {
                    text: "hello".into(),
                    thought: None,
                    thought_signature: None,
                }],
                role: Some("model".into()),
            }),
            finish_reason: None,
            safety_ratings: None,
        }]),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    let events = process_stream_chunk(&chunk, &mut state);
    assert!(matches!(events[0], StreamEvent::TextStart));
    assert!(matches!(&events[1], StreamEvent::TextDelta { delta } if delta == "hello"));
    assert!(state.acc.text_started);
}

#[test]
fn subsequent_text_only_emits_delta() {
    let chunk = GeminiStreamChunk {
        candidates: Some(vec![GeminiCandidate {
            content: Some(GeminiCandidateContent {
                parts: vec![GeminiPart::Text {
                    text: "more".into(),
                    thought: None,
                    thought_signature: None,
                }],
                role: Some("model".into()),
            }),
            finish_reason: None,
            safety_ratings: None,
        }]),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    state.acc.text_started = true;
    let events = process_stream_chunk(&chunk, &mut state);
    assert_eq!(events.len(), 1);
    assert!(matches!(&events[0], StreamEvent::TextDelta { .. }));
}

// ── Thinking streaming ───────────────────────────────────────────

#[test]
fn emits_thinking_start_on_first_thinking() {
    let chunk = GeminiStreamChunk {
        candidates: Some(vec![GeminiCandidate {
            content: Some(GeminiCandidateContent {
                parts: vec![GeminiPart::Text {
                    text: "thinking...".into(),
                    thought: Some(true),
                    thought_signature: None,
                }],
                role: Some("model".into()),
            }),
            finish_reason: None,
            safety_ratings: None,
        }]),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    let events = process_stream_chunk(&chunk, &mut state);
    assert!(matches!(events[0], StreamEvent::ThinkingStart));
    assert!(matches!(&events[1], StreamEvent::ThinkingDelta { delta } if delta == "thinking..."));
}

#[test]
fn thinking_to_text_transition_emits_thinking_end() {
    let chunk = GeminiStreamChunk {
        candidates: Some(vec![GeminiCandidate {
            content: Some(GeminiCandidateContent {
                parts: vec![GeminiPart::Text {
                    text: "answer".into(),
                    thought: None,
                    thought_signature: None,
                }],
                role: Some("model".into()),
            }),
            finish_reason: None,
            safety_ratings: None,
        }]),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    state.acc.thinking_started = true;
    state.acc.accumulated_thinking = "prior thinking".into();
    let events = process_stream_chunk(&chunk, &mut state);
    assert!(
        matches!(&events[0], StreamEvent::ThinkingEnd { thinking, .. } if thinking == "prior thinking")
    );
    assert!(matches!(events[1], StreamEvent::TextStart));
}

// ── Function calls ───────────────────────────────────────────────

#[test]
fn emits_toolcall_events_for_function_call() {
    let chunk = GeminiStreamChunk {
        candidates: Some(vec![GeminiCandidate {
            content: Some(GeminiCandidateContent {
                parts: vec![GeminiPart::FunctionCall {
                    function_call: FunctionCallData {
                        name: "execute".into(),
                        args: serde_json::json!({"command": "ls"}),
                    },
                    thought_signature: Some("sig-123".into()),
                }],
                role: Some("model".into()),
            }),
            finish_reason: None,
            safety_ratings: None,
        }]),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    let events = process_stream_chunk(&chunk, &mut state);
    assert_eq!(events.len(), 3); // start, delta, end
    assert!(
        matches!(&events[0], StreamEvent::CapabilityInvocationDraftStart { name, .. } if name == "execute")
    );
    assert!(
        matches!(&events[2], StreamEvent::CapabilityInvocationDraftEnd { capability_invocation } if capability_invocation.thought_signature.as_deref() == Some("sig-123"))
    );
    assert_eq!(state.capability_invocations.len(), 1);
}

#[test]
fn non_object_function_call_arguments_fail_closed() {
    let mut state = create_stream_state();
    let fc = FunctionCallData {
        name: "execute".into(),
        args: serde_json::json!(["not", "an", "object"]),
    };
    let events = process_function_call(&fc, None, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::Error { error } => {
            assert!(error.contains("google capability invocation arguments"));
            assert!(error.contains("received array"));
        }
        _ => panic!("expected Error"),
    }
    assert!(state.capability_invocations.is_empty());
}

#[test]
fn invocation_id_uses_unique_prefix() {
    let mut state = create_stream_state();
    state.unique_prefix = "abcd1234".into();
    let fc = FunctionCallData {
        name: "test".into(),
        args: serde_json::json!({}),
    };
    let events = process_function_call(&fc, None, &mut state);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftStart { invocation_id, .. } => {
            assert!(invocation_id.starts_with("call_abcd1234_"));
        }
        _ => panic!("Expected toolcall start"),
    }
}

// ── Finish reason ────────────────────────────────────────────────

#[test]
fn finish_stop_emits_done_with_end_turn() {
    let chunk = GeminiStreamChunk {
        candidates: Some(vec![GeminiCandidate {
            content: None,
            finish_reason: Some("STOP".into()),
            safety_ratings: None,
        }]),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    state.acc.text_started = true;
    state.acc.accumulated_text = "hello".into();
    let events = process_stream_chunk(&chunk, &mut state);
    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    assert!(done.is_some());
    match done.unwrap() {
        StreamEvent::Done { stop_reason, .. } => assert_eq!(stop_reason, "end_turn"),
        _ => unreachable!(),
    }
}

#[test]
fn finish_max_tokens_maps_correctly() {
    assert_eq!(map_google_stop_reason("MAX_TOKENS"), "max_tokens");
}

#[test]
fn finish_safety_emits_safety_block() {
    let chunk = GeminiStreamChunk {
        candidates: Some(vec![GeminiCandidate {
            content: None,
            finish_reason: Some("SAFETY".into()),
            safety_ratings: Some(vec![SafetyRating {
                category: HarmCategory::Harassment,
                probability: HarmProbability::High,
            }]),
        }]),
        ..empty_chunk()
    };
    let mut state = create_stream_state();
    let events = process_stream_chunk(&chunk, &mut state);
    let block_event = events
        .iter()
        .find(|e| matches!(e, StreamEvent::SafetyBlock { .. }));
    assert!(block_event.is_some());
}

// ── Done event content ───────────────────────────────────────────

#[test]
fn done_includes_thinking_and_text_content() {
    let mut state = create_stream_state();
    state.acc.accumulated_thinking = "thought".into();
    state.acc.accumulated_text = "answer".into();
    state.acc.text_started = true;
    let events = handle_finish("STOP", None, &mut state);
    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    match done.unwrap() {
        StreamEvent::Done { message, .. } => {
            assert_eq!(message.content.len(), 2); // thinking + text
            assert!(message.token_usage.is_some());
            assert_eq!(
                message.token_usage.as_ref().unwrap().provider_type,
                Some(Provider::Google)
            );
        }
        _ => unreachable!(),
    }
}

#[test]
fn done_includes_capability_invocations() {
    let mut state = create_stream_state();
    state
        .capability_invocations
        .push(CapabilityInvocationDraftState {
            id: "call_123".into(),
            name: "execute".into(),
            args: serde_json::json!({"cmd": "ls"}),
            thought_signature: Some("sig".into()),
        });
    let events = handle_finish("STOP", None, &mut state);
    match events.last().unwrap() {
        StreamEvent::Done { message, .. } => {
            // Capability invocations appear in the content as CapabilityInvocation blocks
            let capability_invocations: Vec<_> = message
                .content
                .iter()
                .filter(|c| c.is_capability_invocation())
                .collect();
            assert_eq!(capability_invocations.len(), 1);
            match &capability_invocations[0] {
                AssistantContent::CapabilityInvocation {
                    name,
                    thought_signature,
                    ..
                } => {
                    assert_eq!(name, "execute");
                    assert_eq!(thought_signature.as_deref(), Some("sig"));
                }
                _ => panic!("Expected CapabilityInvocation"),
            }
        }
        _ => panic!("Expected done"),
    }
}

// ── synthesize_done_event ────────────────────────────────────────

#[test]
fn synthesize_uses_capability_invocation_when_tools_present() {
    let mut state = create_stream_state();
    state
        .capability_invocations
        .push(CapabilityInvocationDraftState {
            id: "call_1".into(),
            name: "test".into(),
            args: serde_json::json!({}),
            thought_signature: None,
        });
    let events = synthesize_done_event(&mut state);
    match events.last().unwrap() {
        StreamEvent::Done { stop_reason, .. } => {
            assert_eq!(stop_reason, "capability_invocation")
        }
        _ => panic!("Expected done"),
    }
}

#[test]
fn synthesize_uses_stop_when_no_tools() {
    let mut state = create_stream_state();
    let events = synthesize_done_event(&mut state);
    match events.last().unwrap() {
        StreamEvent::Done { stop_reason, .. } => assert_eq!(stop_reason, "end_turn"),
        _ => panic!("Expected done"),
    }
}

// ── Stop reason mapping ──────────────────────────────────────────

#[test]
fn stop_reason_mapping() {
    assert_eq!(map_google_stop_reason("STOP"), "end_turn");
    assert_eq!(map_google_stop_reason("MAX_TOKENS"), "max_tokens");
    assert_eq!(map_google_stop_reason("SAFETY"), "end_turn");
    assert_eq!(map_google_stop_reason("RECITATION"), "end_turn");
    assert_eq!(map_google_stop_reason("TOOL_USE"), "capability_invocation");
    assert_eq!(map_google_stop_reason("UNKNOWN"), "end_turn");
}
