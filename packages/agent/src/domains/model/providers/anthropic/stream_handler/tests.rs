use super::*;
use crate::shared::protocol::messages::Provider;

use crate::domains::model::providers::anthropic::types::{
    SseCacheCreation, SseError, SseMessage, SseMessageDelta, SseUsage, SseUsageDelta,
};

fn usage(input: u64, output: u64, cache_create: u64, cache_read: u64) -> SseUsage {
    SseUsage {
        input_tokens: input,
        output_tokens: output,
        cache_creation_input_tokens: cache_create,
        cache_read_input_tokens: cache_read,
        cache_creation: None,
    }
}

// ── stream state creation ──────────────────────────────────────────

#[test]
fn stream_state_default_is_anthropic() {
    let state = create_stream_state();
    assert_eq!(
        state.provider_type,
        crate::shared::protocol::messages::Provider::Anthropic
    );
}

#[test]
fn stream_state_for_minimax() {
    let state = create_stream_state_for(crate::shared::protocol::messages::Provider::MiniMax);
    assert_eq!(
        state.provider_type,
        crate::shared::protocol::messages::Provider::MiniMax
    );
}

#[test]
fn done_event_uses_state_provider_type() {
    let mut state = create_stream_state_for(crate::shared::protocol::messages::Provider::MiniMax);
    state.acc.input_tokens = 100;
    state.acc.output_tokens = 50;
    let event = build_done_event(&mut state);
    match event {
        StreamEvent::Done { message, .. } => {
            let usage = message.token_usage.as_ref().unwrap();
            assert_eq!(
                usage.provider_type,
                Some(crate::shared::protocol::messages::Provider::MiniMax)
            );
        }
        _ => panic!("expected Done"),
    }
}

// ── message_start ───────────────────────────────────────────────────

#[test]
fn message_start_extracts_usage() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::MessageStart {
        message: SseMessage {
            id: Some("msg_01abc".into()),
            model: Some("claude-opus-4-6".into()),
            stop_reason: None,
            usage: usage(100, 0, 50, 20),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert!(events.is_empty());
    assert_eq!(state.acc.input_tokens, 100);
    assert_eq!(state.cache_creation_tokens, 50);
    assert_eq!(state.cache_read_tokens, 20);
}

#[test]
fn message_start_extracts_cache_creation_breakdown() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::MessageStart {
        message: SseMessage {
            id: None,
            model: None,
            stop_reason: None,
            usage: SseUsage {
                input_tokens: 100,
                output_tokens: 0,
                cache_creation_input_tokens: 80,
                cache_read_input_tokens: 20,
                cache_creation: Some(SseCacheCreation {
                    ephemeral_5m_input_tokens: 30,
                    ephemeral_1h_input_tokens: 50,
                }),
            },
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert!(events.is_empty());
    assert_eq!(state.cache_creation_5m_tokens, 30);
    assert_eq!(state.cache_creation_1h_tokens, 50);
}

// ── content_block_start ─────────────────────────────────────────────

#[test]
fn content_block_start_text() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::ContentBlockStart {
        index: 0,
        content_block: SseContentBlock::Text {
            text: String::new(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    assert!(matches!(events[0], StreamEvent::TextStart));
    assert_eq!(state.current_block_type, Some(BlockType::Text));
}

#[test]
fn content_block_start_thinking() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::ContentBlockStart {
        index: 0,
        content_block: SseContentBlock::Thinking {
            thinking: String::new(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    assert!(matches!(events[0], StreamEvent::ThinkingStart));
    assert_eq!(state.current_block_type, Some(BlockType::Thinking));
}

#[test]
fn content_block_start_capability_invocation() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::ContentBlockStart {
        index: 1,
        content_block: SseContentBlock::CapabilityInvocation {
            id: "toolu_01abc".into(),
            name: "execute".into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftStart {
            invocation_id,
            name,
        } => {
            assert_eq!(invocation_id, "toolu_01abc");
            assert_eq!(name, "execute");
        }
        _ => panic!("expected CapabilityInvocationDraftStart"),
    }
    assert_eq!(state.current_invocation_id, Some("toolu_01abc".into()));
    assert_eq!(state.acc.capability_invocations()[0].name, "execute");
}

// ── content_block_delta ─────────────────────────────────────────────

#[test]
fn content_block_delta_text() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::Text);
    let event = AnthropicSseEvent::ContentBlockDelta {
        index: 0,
        delta: SseDelta::TextDelta {
            text: "Hello ".into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::TextDelta { delta } => assert_eq!(delta, "Hello "),
        _ => panic!("expected TextDelta"),
    }
    assert_eq!(state.acc.accumulated_text, "Hello ");

    // Second delta
    let second_event = AnthropicSseEvent::ContentBlockDelta {
        index: 0,
        delta: SseDelta::TextDelta {
            text: "world".into(),
        },
    };
    let _ = process_sse_event(&second_event, &mut state);
    assert_eq!(state.acc.accumulated_text, "Hello world");
}

#[test]
fn content_block_delta_thinking() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::Thinking);
    let event = AnthropicSseEvent::ContentBlockDelta {
        index: 0,
        delta: SseDelta::ThinkingDelta {
            thinking: "Let me think".into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::ThinkingDelta { delta } => assert_eq!(delta, "Let me think"),
        _ => panic!("expected ThinkingDelta"),
    }
    assert_eq!(state.acc.accumulated_thinking, "Let me think");
}

#[test]
fn content_block_delta_signature_not_yielded() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::ContentBlockDelta {
        index: 0,
        delta: SseDelta::SignatureDelta {
            signature: "sig_part1".into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert!(events.is_empty()); // Signature not yielded
    assert_eq!(state.acc.accumulated_signature, "sig_part1");

    // Second signature delta
    let second_event = AnthropicSseEvent::ContentBlockDelta {
        index: 0,
        delta: SseDelta::SignatureDelta {
            signature: "_part2".into(),
        },
    };
    let _ = process_sse_event(&second_event, &mut state);
    assert_eq!(state.acc.accumulated_signature, "sig_part1_part2");
}

#[test]
fn content_block_delta_input_json() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::CapabilityInvocation);
    state.current_invocation_id = Some("toolu_01abc".into());
    let _ = state
        .acc
        .start_capability_invocation("toolu_01abc".into(), "execute".into());
    let event = AnthropicSseEvent::ContentBlockDelta {
        index: 1,
        delta: SseDelta::InputJsonDelta {
            partial_json: r#"{"cmd":"#.into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id,
            arguments_delta,
        } => {
            assert_eq!(invocation_id, "toolu_01abc");
            assert_eq!(arguments_delta, r#"{"cmd":"#);
        }
        _ => panic!("expected CapabilityInvocationDraftDelta"),
    }
}

// ── content_block_stop ──────────────────────────────────────────────

#[test]
fn content_block_stop_text() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::Text);
    state.acc.accumulated_text = "Hello world".into();
    let event = AnthropicSseEvent::ContentBlockStop { index: 0 };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::TextEnd { text, signature } => {
            assert_eq!(text, "Hello world");
            assert!(signature.is_none());
        }
        _ => panic!("expected TextEnd"),
    }
    assert!(state.acc.accumulated_text.is_empty());
    assert_eq!(state.content_blocks.len(), 1);
}

#[test]
fn content_block_stop_thinking_with_signature() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::Thinking);
    state.acc.accumulated_thinking = "deep thought".into();
    state.acc.accumulated_signature = "sig123".into();
    let event = AnthropicSseEvent::ContentBlockStop { index: 0 };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::ThinkingEnd {
            thinking,
            signature,
        } => {
            assert_eq!(thinking, "deep thought");
            assert_eq!(signature.as_deref(), Some("sig123"));
        }
        _ => panic!("expected ThinkingEnd"),
    }
    assert!(state.acc.accumulated_thinking.is_empty());
    assert!(state.acc.accumulated_signature.is_empty());
}

#[test]
fn content_block_stop_thinking_without_signature() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::Thinking);
    state.acc.accumulated_thinking = "display only".into();
    let event = AnthropicSseEvent::ContentBlockStop { index: 0 };
    let events = process_sse_event(&event, &mut state);
    match &events[0] {
        StreamEvent::ThinkingEnd { signature, .. } => {
            assert!(signature.is_none());
        }
        _ => panic!("expected ThinkingEnd"),
    }
}

#[test]
fn content_block_stop_capability_invocation() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::CapabilityInvocation);
    state.current_invocation_id = Some("toolu_01abc".into());
    let _ = state
        .acc
        .start_capability_invocation("toolu_01abc".into(), "execute".into());
    let _ = state.acc.append_tool_args("toolu_01abc", r#"{"cmd":"ls"}"#);
    let event = AnthropicSseEvent::ContentBlockStop { index: 1 };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        } => {
            assert_eq!(capability_invocation.id, "toolu_01abc");
            assert_eq!(capability_invocation.name, "execute");
            assert_eq!(capability_invocation.arguments["cmd"], "ls");
        }
        _ => panic!("expected CapabilityInvocationDraftEnd"),
    }
    assert!(state.current_invocation_id.is_none());
    assert!(state.acc.capability_invocations().is_empty());
}

#[test]
fn content_block_stop_capability_invocation_empty_args() {
    let mut state = create_stream_state();
    state.current_block_type = Some(BlockType::CapabilityInvocation);
    state.current_invocation_id = Some("toolu_01abc".into());
    let _ = state
        .acc
        .start_capability_invocation("toolu_01abc".into(), "execute".into());
    // Empty args
    let event = AnthropicSseEvent::ContentBlockStop { index: 0 };
    let events = process_sse_event(&event, &mut state);
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        } => {
            assert!(capability_invocation.arguments.is_empty());
        }
        _ => panic!("expected CapabilityInvocationDraftEnd"),
    }
}

// ── message_delta ───────────────────────────────────────────────────

#[test]
fn message_delta_stop_reason() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::MessageDelta {
        delta: SseMessageDelta {
            stop_reason: Some("end_turn".into()),
        },
        usage: Some(SseUsageDelta { output_tokens: 42 }),
    };
    let events = process_sse_event(&event, &mut state);
    assert!(events.is_empty());
    assert_eq!(state.stop_reason, Some("end_turn".into()));
    assert_eq!(state.acc.output_tokens, 42);
}

#[test]
fn message_delta_tool_use_stop() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::MessageDelta {
        delta: SseMessageDelta {
            stop_reason: Some("tool_use".into()),
        },
        usage: None,
    };
    let events = process_sse_event(&event, &mut state);
    assert!(events.is_empty());
    assert_eq!(state.stop_reason, Some("tool_use".into()));
}

// ── message_stop ────────────────────────────────────────────────────

#[test]
fn message_stop_yields_done() {
    let mut state = create_stream_state();
    state.acc.input_tokens = 100;
    state.acc.output_tokens = 50;
    state.stop_reason = Some("end_turn".into());
    state.content_blocks.push(AssistantContent::Text {
        text: "Hello".into(),
    });

    let event = AnthropicSseEvent::MessageStop;
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::Done {
            message,
            stop_reason,
        } => {
            assert_eq!(stop_reason, "end_turn");
            assert_eq!(message.content.len(), 1);
            let usage = message.token_usage.as_ref().unwrap();
            assert_eq!(usage.input_tokens, 100);
            assert_eq!(usage.output_tokens, 50);
            assert_eq!(usage.provider_type, Some(Provider::Anthropic));
        }
        _ => panic!("expected Done"),
    }
}

#[test]
fn message_stop_default_stop_reason() {
    let mut state = create_stream_state();
    // No stop_reason set
    let event = AnthropicSseEvent::MessageStop;
    let events = process_sse_event(&event, &mut state);
    match &events[0] {
        StreamEvent::Done { stop_reason, .. } => {
            assert_eq!(stop_reason, "end_turn");
        }
        _ => panic!("expected Done"),
    }
}

#[test]
fn message_stop_no_tokens_no_usage() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::MessageStop;
    let events = process_sse_event(&event, &mut state);
    match &events[0] {
        StreamEvent::Done { message, .. } => {
            assert!(message.token_usage.is_none());
        }
        _ => panic!("expected Done"),
    }
}

#[test]
fn message_stop_with_cache_tokens() {
    let mut state = create_stream_state();
    state.acc.input_tokens = 100;
    state.acc.output_tokens = 50;
    state.cache_read_tokens = 80;
    state.cache_creation_tokens = 20;
    state.cache_creation_5m_tokens = 10;
    state.cache_creation_1h_tokens = 10;

    let event = AnthropicSseEvent::MessageStop;
    let events = process_sse_event(&event, &mut state);
    match &events[0] {
        StreamEvent::Done { message, .. } => {
            let usage = message.token_usage.as_ref().unwrap();
            assert_eq!(usage.cache_read_tokens, Some(80));
            assert_eq!(usage.cache_creation_tokens, Some(20));
            assert_eq!(usage.cache_creation_5m_tokens, Some(10));
            assert_eq!(usage.cache_creation_1h_tokens, Some(10));
        }
        _ => panic!("expected Done"),
    }
}

// ── ping ────────────────────────────────────────────────────────────

#[test]
fn ping_yields_nothing() {
    let mut state = create_stream_state();
    let events = process_sse_event(&AnthropicSseEvent::Ping, &mut state);
    assert!(events.is_empty());
}

// ── error ───────────────────────────────────────────────────────────

#[test]
fn error_yields_stream_error() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::Error {
        error: SseError {
            error_type: "overloaded_error".into(),
            message: "Server overloaded".into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 1);
    match &events[0] {
        StreamEvent::Error { error } => {
            assert!(error.contains("overloaded_error"));
            assert!(error.contains("Server overloaded"));
        }
        _ => panic!("expected Error"),
    }
}

// ── Full stream simulation ──────────────────────────────────────────

#[test]
fn full_text_stream() {
    let mut state = create_stream_state();

    // message_start
    let _ = process_sse_event(
        &AnthropicSseEvent::MessageStart {
            message: SseMessage {
                id: Some("msg_01".into()),
                model: Some("claude-opus-4-6".into()),
                stop_reason: None,
                usage: usage(100, 0, 0, 80),
            },
        },
        &mut state,
    );

    // content_block_start (text)
    let events = process_sse_event(
        &AnthropicSseEvent::ContentBlockStart {
            index: 0,
            content_block: SseContentBlock::Text {
                text: String::new(),
            },
        },
        &mut state,
    );
    assert!(matches!(events[0], StreamEvent::TextStart));

    // content_block_delta × 2
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::TextDelta {
                text: "Hello ".into(),
            },
        },
        &mut state,
    );
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::TextDelta {
                text: "world".into(),
            },
        },
        &mut state,
    );

    // content_block_stop
    let events = process_sse_event(
        &AnthropicSseEvent::ContentBlockStop { index: 0 },
        &mut state,
    );
    match &events[0] {
        StreamEvent::TextEnd { text, .. } => assert_eq!(text, "Hello world"),
        _ => panic!("expected TextEnd"),
    }

    // message_delta
    let _ = process_sse_event(
        &AnthropicSseEvent::MessageDelta {
            delta: SseMessageDelta {
                stop_reason: Some("end_turn".into()),
            },
            usage: Some(SseUsageDelta { output_tokens: 10 }),
        },
        &mut state,
    );

    // message_stop
    let events = process_sse_event(&AnthropicSseEvent::MessageStop, &mut state);
    match &events[0] {
        StreamEvent::Done {
            message,
            stop_reason,
        } => {
            assert_eq!(stop_reason, "end_turn");
            assert_eq!(message.content.len(), 1);
            let usage = message.token_usage.as_ref().unwrap();
            assert_eq!(usage.input_tokens, 100);
            assert_eq!(usage.output_tokens, 10);
            assert_eq!(usage.cache_read_tokens, Some(80));
        }
        _ => panic!("expected Done"),
    }
}

#[test]
fn full_thinking_then_text_stream() {
    let mut state = create_stream_state();

    // message_start
    let _ = process_sse_event(
        &AnthropicSseEvent::MessageStart {
            message: SseMessage {
                id: None,
                model: None,
                stop_reason: None,
                usage: usage(50, 0, 0, 0),
            },
        },
        &mut state,
    );

    // Thinking block
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockStart {
            index: 0,
            content_block: SseContentBlock::Thinking {
                thinking: String::new(),
            },
        },
        &mut state,
    );
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::ThinkingDelta {
                thinking: "deep".into(),
            },
        },
        &mut state,
    );
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::SignatureDelta {
                signature: "sig".into(),
            },
        },
        &mut state,
    );
    let events = process_sse_event(
        &AnthropicSseEvent::ContentBlockStop { index: 0 },
        &mut state,
    );
    match &events[0] {
        StreamEvent::ThinkingEnd {
            thinking,
            signature,
        } => {
            assert_eq!(thinking, "deep");
            assert_eq!(signature.as_deref(), Some("sig"));
        }
        _ => panic!("expected ThinkingEnd"),
    }

    // Text block
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockStart {
            index: 1,
            content_block: SseContentBlock::Text {
                text: String::new(),
            },
        },
        &mut state,
    );
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockDelta {
            index: 1,
            delta: SseDelta::TextDelta {
                text: "Answer".into(),
            },
        },
        &mut state,
    );
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockStop { index: 1 },
        &mut state,
    );

    // Done
    let _ = process_sse_event(
        &AnthropicSseEvent::MessageDelta {
            delta: SseMessageDelta {
                stop_reason: Some("end_turn".into()),
            },
            usage: Some(SseUsageDelta { output_tokens: 20 }),
        },
        &mut state,
    );
    let events = process_sse_event(&AnthropicSseEvent::MessageStop, &mut state);
    match &events[0] {
        StreamEvent::Done { message, .. } => {
            assert_eq!(message.content.len(), 2);
            assert!(matches!(
                &message.content[0],
                AssistantContent::Thinking { .. }
            ));
            assert!(matches!(&message.content[1], AssistantContent::Text { .. }));
        }
        _ => panic!("expected Done"),
    }
}

#[test]
fn full_capability_invocation_stream() {
    let mut state = create_stream_state();

    let _ = process_sse_event(
        &AnthropicSseEvent::MessageStart {
            message: SseMessage {
                id: None,
                model: None,
                stop_reason: None,
                usage: usage(50, 0, 0, 0),
            },
        },
        &mut state,
    );

    // ModelCapability use block
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockStart {
            index: 0,
            content_block: SseContentBlock::CapabilityInvocation {
                id: "toolu_01abc".into(),
                name: "execute".into(),
            },
        },
        &mut state,
    );
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::InputJsonDelta {
                partial_json: r#"{"cm"#.into(),
            },
        },
        &mut state,
    );
    let _ = process_sse_event(
        &AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::InputJsonDelta {
                partial_json: r#"d":"ls"}"#.into(),
            },
        },
        &mut state,
    );
    let events = process_sse_event(
        &AnthropicSseEvent::ContentBlockStop { index: 0 },
        &mut state,
    );
    match &events[0] {
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        } => {
            assert_eq!(capability_invocation.id, "toolu_01abc");
            assert_eq!(capability_invocation.name, "execute");
            assert_eq!(capability_invocation.arguments["cmd"], "ls");
        }
        _ => panic!("expected CapabilityInvocationDraftEnd"),
    }

    // message_delta with Anthropic's canonical tool_use stop reason.
    let _ = process_sse_event(
        &AnthropicSseEvent::MessageDelta {
            delta: SseMessageDelta {
                stop_reason: Some("tool_use".into()),
            },
            usage: Some(SseUsageDelta { output_tokens: 30 }),
        },
        &mut state,
    );

    let events = process_sse_event(&AnthropicSseEvent::MessageStop, &mut state);
    match &events[0] {
        StreamEvent::Done { stop_reason, .. } => {
            assert_eq!(stop_reason, "tool_use");
        }
        _ => panic!("expected Done"),
    }
}
