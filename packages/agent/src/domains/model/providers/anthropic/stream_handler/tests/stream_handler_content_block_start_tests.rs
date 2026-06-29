use super::super::*;
use crate::domains::model::providers::anthropic::types::{AnthropicSseEvent, SseContentBlock};
use crate::shared::protocol::events::StreamEvent;

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
    assert_eq!(state.current_block_index, Some(0));
}

#[test]
fn content_block_start_text_with_initial_text_emits_delta() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::ContentBlockStart {
        index: 2,
        content_block: SseContentBlock::Text {
            text: "Hello from start".into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 2);
    assert!(matches!(events[0], StreamEvent::TextStart));
    match &events[1] {
        StreamEvent::TextDelta { delta } => assert_eq!(delta, "Hello from start"),
        _ => panic!("expected TextDelta"),
    }
    assert_eq!(state.current_block_type, Some(BlockType::Text));
    assert_eq!(state.current_block_index, Some(2));
    assert_eq!(state.acc.accumulated_text, "Hello from start");
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
    assert_eq!(state.current_block_index, Some(0));
}

#[test]
fn content_block_start_thinking_with_initial_text_emits_delta() {
    let mut state = create_stream_state();
    let event = AnthropicSseEvent::ContentBlockStart {
        index: 3,
        content_block: SseContentBlock::Thinking {
            thinking: "Initial thought".into(),
        },
    };
    let events = process_sse_event(&event, &mut state);
    assert_eq!(events.len(), 2);
    assert!(matches!(events[0], StreamEvent::ThinkingStart));
    match &events[1] {
        StreamEvent::ThinkingDelta { delta } => assert_eq!(delta, "Initial thought"),
        _ => panic!("expected ThinkingDelta"),
    }
    assert_eq!(state.current_block_type, Some(BlockType::Thinking));
    assert_eq!(state.current_block_index, Some(3));
    assert_eq!(state.acc.accumulated_thinking, "Initial thought");
}
