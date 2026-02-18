//! Anthropic SSE stream handler.
//!
//! Converts raw Anthropic SSE events (`message_start`, `content_block_delta`, etc.)
//! into unified [`StreamEvent`]s consumed by the agent runtime.
//!
//! The handler maintains a [`StreamState`] that accumulates text, thinking, signature,
//! and tool arguments across delta events, then emits complete blocks on `content_block_stop`.

use serde_json::Map;
use tracing::{info, warn};

use tron_core::content::AssistantContent;
use tron_core::events::{AssistantMessage, StreamEvent};
use tron_core::messages::{TokenUsage, ToolCall};

use super::types::{AnthropicSseEvent, SseContentBlock, SseDelta};

/// Stream state accumulated across SSE events.
#[derive(Clone, Debug, Default)]
pub struct StreamState {
    /// Provider type for token attribution in Done events.
    pub provider_type: tron_core::messages::ProviderType,
    /// Current content block type being accumulated.
    pub current_block_type: Option<BlockType>,
    /// Tool call ID for the current `tool_use` block.
    pub current_tool_call_id: Option<String>,
    /// Tool name for the current `tool_use` block.
    pub current_tool_name: Option<String>,
    /// Accumulated text content.
    pub accumulated_text: String,
    /// Accumulated thinking content.
    pub accumulated_thinking: String,
    /// Accumulated signature.
    pub accumulated_signature: String,
    /// Accumulated tool call JSON arguments.
    pub accumulated_args: String,
    /// Input tokens from `message_start`.
    pub input_tokens: u64,
    /// Output tokens from `message_delta`.
    pub output_tokens: u64,
    /// Cache creation tokens.
    pub cache_creation_tokens: u64,
    /// Cache read tokens.
    pub cache_read_tokens: u64,
    /// 5-minute TTL cache creation tokens.
    pub cache_creation_5m_tokens: u64,
    /// 1-hour TTL cache creation tokens.
    pub cache_creation_1h_tokens: u64,
    /// Content blocks accumulated for the final `Done` event.
    pub content_blocks: Vec<AssistantContent>,
    /// Stop reason from `message_delta`.
    pub stop_reason: Option<String>,
}

/// Type of content block being accumulated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BlockType {
    /// Text response.
    Text,
    /// Extended thinking.
    Thinking,
    /// Tool use (function call).
    ToolUse,
}

/// Create a new stream state for a specific provider.
#[must_use]
pub fn create_stream_state_for(provider_type: tron_core::messages::ProviderType) -> StreamState {
    StreamState {
        provider_type,
        ..StreamState::default()
    }
}

/// Create a new stream state (defaults to Anthropic).
#[must_use]
pub fn create_stream_state() -> StreamState {
    create_stream_state_for(tron_core::messages::ProviderType::Anthropic)
}

/// Process a single Anthropic SSE event and return zero or more [`StreamEvent`]s.
///
/// Call this for each SSE event received. The state is mutated to track
/// accumulated content across events.
pub fn process_sse_event(event: &AnthropicSseEvent, state: &mut StreamState) -> Vec<StreamEvent> {
    match event {
        AnthropicSseEvent::MessageStart { message } => {
            state.input_tokens = message.usage.input_tokens;
            state.cache_creation_tokens = message.usage.cache_creation_input_tokens;
            state.cache_read_tokens = message.usage.cache_read_input_tokens;
            if let Some(ref cc) = message.usage.cache_creation {
                state.cache_creation_5m_tokens = cc.ephemeral_5m_input_tokens;
                state.cache_creation_1h_tokens = cc.ephemeral_1h_input_tokens;
            }

            let cache_hit = state.cache_read_tokens > 0;
            let cache_write = state.cache_creation_tokens > 0;
            info!(
                input_tokens = state.input_tokens,
                cache_read = state.cache_read_tokens,
                cache_write = state.cache_creation_tokens,
                cache_hit,
                cache_write_bool = cache_write,
                "[CACHE] message_start"
            );

            vec![]
        }

        AnthropicSseEvent::ContentBlockStart { content_block, .. } => match content_block {
            SseContentBlock::Text { .. } => {
                state.current_block_type = Some(BlockType::Text);
                vec![StreamEvent::TextStart]
            }
            SseContentBlock::Thinking { .. } => {
                state.current_block_type = Some(BlockType::Thinking);
                vec![StreamEvent::ThinkingStart]
            }
            SseContentBlock::ToolUse { id, name } => {
                state.current_block_type = Some(BlockType::ToolUse);
                state.current_tool_call_id = Some(id.clone());
                state.current_tool_name = Some(name.clone());
                vec![StreamEvent::ToolCallStart {
                    tool_call_id: id.clone(),
                    name: name.clone(),
                }]
            }
        },

        AnthropicSseEvent::ContentBlockDelta { delta, .. } => {
            match delta {
                SseDelta::TextDelta { text } => {
                    state.accumulated_text.push_str(text);
                    vec![StreamEvent::TextDelta {
                        delta: text.clone(),
                    }]
                }
                SseDelta::ThinkingDelta { thinking } => {
                    state.accumulated_thinking.push_str(thinking);
                    vec![StreamEvent::ThinkingDelta {
                        delta: thinking.clone(),
                    }]
                }
                SseDelta::SignatureDelta { signature } => {
                    state.accumulated_signature.push_str(signature);
                    // Signature is not yielded until content_block_stop
                    vec![]
                }
                SseDelta::InputJsonDelta { partial_json } => {
                    state.accumulated_args.push_str(partial_json);
                    if let Some(ref id) = state.current_tool_call_id {
                        vec![StreamEvent::ToolCallDelta {
                            tool_call_id: id.clone(),
                            arguments_delta: partial_json.clone(),
                        }]
                    } else {
                        vec![]
                    }
                }
            }
        }

        AnthropicSseEvent::ContentBlockStop { .. } => handle_content_block_stop(state),

        AnthropicSseEvent::MessageDelta { delta, usage } => {
            state.stop_reason.clone_from(&delta.stop_reason);
            if let Some(u) = usage {
                state.output_tokens = u.output_tokens;
            }
            vec![]
        }

        AnthropicSseEvent::MessageStop => {
            let done_event = build_done_event(state);
            vec![done_event]
        }

        AnthropicSseEvent::Ping => vec![],

        AnthropicSseEvent::Error { error } => {
            warn!(
                error_type = %error.error_type,
                message = %error.message,
                "Anthropic SSE error"
            );
            vec![StreamEvent::Error {
                error: format!("{}: {}", error.error_type, error.message),
            }]
        }
    }
}

/// Handle a `content_block_stop` SSE event by finalizing the current block.
fn handle_content_block_stop(state: &mut StreamState) -> Vec<StreamEvent> {
    match state.current_block_type.take() {
        Some(BlockType::Text) => {
            let text = std::mem::take(&mut state.accumulated_text);
            state
                .content_blocks
                .push(AssistantContent::Text { text: text.clone() });
            vec![StreamEvent::TextEnd {
                text,
                signature: None,
            }]
        }
        Some(BlockType::Thinking) => {
            let thinking = std::mem::take(&mut state.accumulated_thinking);
            let signature = if state.accumulated_signature.is_empty() {
                None
            } else {
                Some(std::mem::take(&mut state.accumulated_signature))
            };
            state.content_blocks.push(AssistantContent::Thinking {
                thinking: thinking.clone(),
                signature: signature.clone(),
            });
            vec![StreamEvent::ThinkingEnd {
                thinking,
                signature,
            }]
        }
        Some(BlockType::ToolUse) => {
            let args_str = std::mem::take(&mut state.accumulated_args);
            let arguments: Map<String, serde_json::Value> =
                serde_json::from_str(&args_str).unwrap_or_default();
            let id = state.current_tool_call_id.take().unwrap_or_default();
            let name = state.current_tool_name.take().unwrap_or_default();

            let tool_call = ToolCall {
                content_type: "tool_use".into(),
                id: id.clone(),
                name: name.clone(),
                arguments: arguments.clone(),
                thought_signature: None,
            };

            state.content_blocks.push(AssistantContent::ToolUse {
                id,
                name,
                arguments,
                thought_signature: None,
            });

            vec![StreamEvent::ToolCallEnd { tool_call }]
        }
        None => vec![],
    }
}

/// Build the final `Done` event from accumulated state.
fn build_done_event(state: &mut StreamState) -> StreamEvent {
    let content = std::mem::take(&mut state.content_blocks);
    let stop_reason = state
        .stop_reason
        .take()
        .unwrap_or_else(|| "end_turn".into());

    let token_usage = if state.input_tokens > 0 || state.output_tokens > 0 {
        Some(TokenUsage {
            input_tokens: state.input_tokens,
            output_tokens: state.output_tokens,
            cache_read_tokens: if state.cache_read_tokens > 0 {
                Some(state.cache_read_tokens)
            } else {
                None
            },
            cache_creation_tokens: if state.cache_creation_tokens > 0 {
                Some(state.cache_creation_tokens)
            } else {
                None
            },
            cache_creation_5m_tokens: if state.cache_creation_5m_tokens > 0 {
                Some(state.cache_creation_5m_tokens)
            } else {
                None
            },
            cache_creation_1h_tokens: if state.cache_creation_1h_tokens > 0 {
                Some(state.cache_creation_1h_tokens)
            } else {
                None
            },
            provider_type: Some(state.provider_type.clone()),
        })
    } else {
        None
    };

    StreamEvent::Done {
        message: AssistantMessage {
            content,
            token_usage,
        },
        stop_reason,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::messages::ProviderType;

    use crate::anthropic::types::{
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
            tron_core::messages::ProviderType::Anthropic
        );
    }

    #[test]
    fn stream_state_for_minimax() {
        let state =
            create_stream_state_for(tron_core::messages::ProviderType::MiniMax);
        assert_eq!(
            state.provider_type,
            tron_core::messages::ProviderType::MiniMax
        );
    }

    #[test]
    fn done_event_uses_state_provider_type() {
        let mut state =
            create_stream_state_for(tron_core::messages::ProviderType::MiniMax);
        state.input_tokens = 100;
        state.output_tokens = 50;
        let event = build_done_event(&mut state);
        match event {
            StreamEvent::Done { message, .. } => {
                let usage = message.token_usage.as_ref().unwrap();
                assert_eq!(
                    usage.provider_type,
                    Some(tron_core::messages::ProviderType::MiniMax)
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
        assert_eq!(state.input_tokens, 100);
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
    fn content_block_start_tool_use() {
        let mut state = create_stream_state();
        let event = AnthropicSseEvent::ContentBlockStart {
            index: 1,
            content_block: SseContentBlock::ToolUse {
                id: "toolu_01abc".into(),
                name: "bash".into(),
            },
        };
        let events = process_sse_event(&event, &mut state);
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::ToolCallStart { tool_call_id, name } => {
                assert_eq!(tool_call_id, "toolu_01abc");
                assert_eq!(name, "bash");
            }
            _ => panic!("expected ToolCallStart"),
        }
        assert_eq!(state.current_tool_call_id, Some("toolu_01abc".into()));
        assert_eq!(state.current_tool_name, Some("bash".into()));
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
        assert_eq!(state.accumulated_text, "Hello ");

        // Second delta
        let event2 = AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::TextDelta {
                text: "world".into(),
            },
        };
        let _ = process_sse_event(&event2, &mut state);
        assert_eq!(state.accumulated_text, "Hello world");
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
        assert_eq!(state.accumulated_thinking, "Let me think");
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
        assert_eq!(state.accumulated_signature, "sig_part1");

        // Second signature delta
        let event2 = AnthropicSseEvent::ContentBlockDelta {
            index: 0,
            delta: SseDelta::SignatureDelta {
                signature: "_part2".into(),
            },
        };
        let _ = process_sse_event(&event2, &mut state);
        assert_eq!(state.accumulated_signature, "sig_part1_part2");
    }

    #[test]
    fn content_block_delta_input_json() {
        let mut state = create_stream_state();
        state.current_block_type = Some(BlockType::ToolUse);
        state.current_tool_call_id = Some("toolu_01abc".into());
        let event = AnthropicSseEvent::ContentBlockDelta {
            index: 1,
            delta: SseDelta::InputJsonDelta {
                partial_json: r#"{"cmd":"#.into(),
            },
        };
        let events = process_sse_event(&event, &mut state);
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::ToolCallDelta {
                tool_call_id,
                arguments_delta,
            } => {
                assert_eq!(tool_call_id, "toolu_01abc");
                assert_eq!(arguments_delta, r#"{"cmd":"#);
            }
            _ => panic!("expected ToolCallDelta"),
        }
    }

    // ── content_block_stop ──────────────────────────────────────────────

    #[test]
    fn content_block_stop_text() {
        let mut state = create_stream_state();
        state.current_block_type = Some(BlockType::Text);
        state.accumulated_text = "Hello world".into();
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
        assert!(state.accumulated_text.is_empty());
        assert_eq!(state.content_blocks.len(), 1);
    }

    #[test]
    fn content_block_stop_thinking_with_signature() {
        let mut state = create_stream_state();
        state.current_block_type = Some(BlockType::Thinking);
        state.accumulated_thinking = "deep thought".into();
        state.accumulated_signature = "sig123".into();
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
        assert!(state.accumulated_thinking.is_empty());
        assert!(state.accumulated_signature.is_empty());
    }

    #[test]
    fn content_block_stop_thinking_without_signature() {
        let mut state = create_stream_state();
        state.current_block_type = Some(BlockType::Thinking);
        state.accumulated_thinking = "display only".into();
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
    fn content_block_stop_tool_use() {
        let mut state = create_stream_state();
        state.current_block_type = Some(BlockType::ToolUse);
        state.current_tool_call_id = Some("toolu_01abc".into());
        state.current_tool_name = Some("bash".into());
        state.accumulated_args = r#"{"cmd":"ls"}"#.into();
        let event = AnthropicSseEvent::ContentBlockStop { index: 1 };
        let events = process_sse_event(&event, &mut state);
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::ToolCallEnd { tool_call } => {
                assert_eq!(tool_call.id, "toolu_01abc");
                assert_eq!(tool_call.name, "bash");
                assert_eq!(tool_call.arguments["cmd"], "ls");
            }
            _ => panic!("expected ToolCallEnd"),
        }
        assert!(state.current_tool_call_id.is_none());
        assert!(state.current_tool_name.is_none());
        assert!(state.accumulated_args.is_empty());
    }

    #[test]
    fn content_block_stop_tool_use_empty_args() {
        let mut state = create_stream_state();
        state.current_block_type = Some(BlockType::ToolUse);
        state.current_tool_call_id = Some("toolu_01abc".into());
        state.current_tool_name = Some("bash".into());
        // Empty args
        let event = AnthropicSseEvent::ContentBlockStop { index: 0 };
        let events = process_sse_event(&event, &mut state);
        match &events[0] {
            StreamEvent::ToolCallEnd { tool_call } => {
                assert!(tool_call.arguments.is_empty());
            }
            _ => panic!("expected ToolCallEnd"),
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
        assert_eq!(state.output_tokens, 42);
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
        state.input_tokens = 100;
        state.output_tokens = 50;
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
                assert_eq!(usage.provider_type, Some(ProviderType::Anthropic));
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
        state.input_tokens = 100;
        state.output_tokens = 50;
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
    fn full_tool_use_stream() {
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

        // Tool use block
        let _ = process_sse_event(
            &AnthropicSseEvent::ContentBlockStart {
                index: 0,
                content_block: SseContentBlock::ToolUse {
                    id: "toolu_01abc".into(),
                    name: "bash".into(),
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
            StreamEvent::ToolCallEnd { tool_call } => {
                assert_eq!(tool_call.id, "toolu_01abc");
                assert_eq!(tool_call.name, "bash");
                assert_eq!(tool_call.arguments["cmd"], "ls");
            }
            _ => panic!("expected ToolCallEnd"),
        }

        // message_delta with tool_use stop reason
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
}
