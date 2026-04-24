//! Kimi SSE stream handler — `chat.completion.chunk` → `StreamEvent`.
//!
//! Deserializes OpenAI-format SSE chunks and maps them to Tron's `StreamEvent`
//! types. Handles text, reasoning content, and tool call streaming.

use serde::Deserialize;
use serde_json::{Map, Value};

use crate::core::content::AssistantContent;
use crate::core::events::StreamEvent;
use crate::core::messages::{TokenUsage, ToolCall};

// ─── SSE chunk types ──────────────────────────────────────────────────────

/// Top-level SSE chunk from Kimi's streaming response.
#[derive(Debug, Deserialize)]
pub struct ChatCompletionChunk {
    /// Choices array (usually one element).
    #[serde(default)]
    pub choices: Vec<ChunkChoice>,
    /// Token usage (only in the final chunk when `stream_options.include_usage` is true).
    pub usage: Option<ChunkUsage>,
}

/// A single choice within a streaming chunk.
#[derive(Debug, Deserialize)]
pub struct ChunkChoice {
    /// Incremental content.
    pub delta: ChunkDelta,
    /// Finish reason (present in the final chunk).
    pub finish_reason: Option<String>,
}

/// Delta content within a streaming choice.
#[derive(Debug, Deserialize)]
pub struct ChunkDelta {
    /// Text content.
    pub content: Option<String>,
    /// Reasoning/thinking content (mutually exclusive with `content` per delta).
    pub reasoning_content: Option<String>,
    /// Tool calls being constructed.
    pub tool_calls: Option<Vec<ChunkToolCall>>,
}

/// A tool call delta within a streaming chunk.
#[derive(Debug, Deserialize)]
pub struct ChunkToolCall {
    /// Tool call index (for multiple concurrent tool calls).
    pub index: u32,
    /// Tool call ID (present in the first delta for this tool call).
    pub id: Option<String>,
    /// Function details.
    pub function: Option<ChunkToolCallFunction>,
}

/// Function details within a tool call delta.
#[derive(Debug, Deserialize)]
pub struct ChunkToolCallFunction {
    /// Function name (present in the first delta).
    pub name: Option<String>,
    /// Partial arguments string.
    pub arguments: Option<String>,
}

/// Token usage from the final chunk.
#[derive(Debug, Deserialize)]
pub struct ChunkUsage {
    /// Input tokens consumed.
    pub prompt_tokens: u64,
    /// Output tokens generated.
    pub completion_tokens: u64,
}

// ─── Stream state ──────────────────────────────────────────────────────────

/// Active tool call being accumulated.
#[derive(Debug, Clone)]
struct ActiveToolCall {
    id: String,
    name: String,
    arguments: String,
}

/// Stream processing state for Kimi responses.
#[derive(Debug)]
pub struct KimiStreamState {
    /// Whether we're currently in a thinking block.
    in_thinking: bool,
    /// Whether we're currently in a text block.
    in_text: bool,
    /// Accumulated thinking content.
    thinking_text: String,
    /// Accumulated text content.
    text_content: String,
    /// Active tool calls by index.
    active_tools: Vec<Option<ActiveToolCall>>,
    /// Token usage from the final chunk.
    usage: Option<TokenUsage>,
    /// Stop reason.
    stop_reason: Option<String>,
    /// Accumulated content blocks for the final Done message.
    content_blocks: Vec<AssistantContent>,
}

impl KimiStreamState {
    /// Create a new stream state.
    pub fn new() -> Self {
        Self {
            in_thinking: false,
            in_text: false,
            thinking_text: String::new(),
            text_content: String::new(),
            active_tools: Vec::new(),
            usage: None,
            stop_reason: None,
            content_blocks: Vec::new(),
        }
    }
}

impl Default for KimiStreamState {
    fn default() -> Self {
        Self::new()
    }
}

// ─── Chunk processing ──────────────────────────────────────────────────────

/// Process a single SSE chunk and produce stream events.
pub fn process_chunk(chunk: &ChatCompletionChunk, state: &mut KimiStreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    // Process usage (final chunk)
    if let Some(ref usage) = chunk.usage {
        state.usage = Some(TokenUsage {
            input_tokens: usage.prompt_tokens,
            output_tokens: usage.completion_tokens,
            ..Default::default()
        });
    }

    for choice in &chunk.choices {
        // Process reasoning content
        if let Some(ref reasoning) = choice.delta.reasoning_content
            && !reasoning.is_empty()
        {
            if !state.in_thinking {
                state.in_thinking = true;
                events.push(StreamEvent::ThinkingStart);
            }
            state.thinking_text.push_str(reasoning);
            events.push(StreamEvent::ThinkingDelta {
                delta: reasoning.clone(),
            });
        }

        // Process text content
        if let Some(ref content) = choice.delta.content
            && !content.is_empty()
        {
            // End thinking if transitioning to text
            if state.in_thinking {
                state.in_thinking = false;
                let thinking = std::mem::take(&mut state.thinking_text);
                state.content_blocks.push(AssistantContent::Thinking {
                    thinking: thinking.clone(),
                    signature: None,
                });
                events.push(StreamEvent::ThinkingEnd {
                    thinking,
                    signature: None,
                });
            }
            if !state.in_text {
                state.in_text = true;
                events.push(StreamEvent::TextStart);
            }
            state.text_content.push_str(content);
            events.push(StreamEvent::TextDelta {
                delta: content.clone(),
            });
        }

        // Process tool calls
        if let Some(ref tool_calls) = choice.delta.tool_calls {
            // End thinking/text blocks before tool calls
            if state.in_thinking {
                state.in_thinking = false;
                let thinking = std::mem::take(&mut state.thinking_text);
                state.content_blocks.push(AssistantContent::Thinking {
                    thinking: thinking.clone(),
                    signature: None,
                });
                events.push(StreamEvent::ThinkingEnd {
                    thinking,
                    signature: None,
                });
            }
            if state.in_text {
                state.in_text = false;
                let text = std::mem::take(&mut state.text_content);
                state.content_blocks.push(AssistantContent::text(&text));
                events.push(StreamEvent::TextEnd {
                    text,
                    signature: None,
                });
            }

            for tc in tool_calls {
                let idx = tc.index as usize;
                // Ensure active_tools is large enough
                while state.active_tools.len() <= idx {
                    state.active_tools.push(None);
                }

                if let Some(ref id) = tc.id {
                    // First delta for this tool call — start
                    let name = tc
                        .function
                        .as_ref()
                        .and_then(|f| f.name.clone())
                        .unwrap_or_default();
                    state.active_tools[idx] = Some(ActiveToolCall {
                        id: id.clone(),
                        name: name.clone(),
                        arguments: String::new(),
                    });
                    events.push(StreamEvent::ToolCallStart {
                        tool_call_id: id.clone(),
                        name,
                    });
                }

                // Accumulate arguments
                if let Some(ref func) = tc.function
                    && let Some(ref args) = func.arguments
                    && !args.is_empty()
                    && let Some(ref mut active) = state.active_tools[idx]
                {
                    active.arguments.push_str(args);
                    events.push(StreamEvent::ToolCallDelta {
                        tool_call_id: active.id.clone(),
                        arguments_delta: args.clone(),
                    });
                }
            }
        }

        // Process finish reason
        if let Some(ref reason) = choice.finish_reason {
            state.stop_reason = Some(map_finish_reason(reason));
            finalize_open_blocks(state, &mut events);
        }
    }

    // If this is the final chunk (has usage but no choices), emit Done
    if chunk.choices.is_empty() && state.usage.is_some() && state.stop_reason.is_some() {
        emit_done(state, &mut events);
    }

    // If we got finish_reason and usage in the same chunk
    if state.stop_reason.is_some() && state.usage.is_some() && !chunk.choices.is_empty() {
        emit_done(state, &mut events);
    }

    events
}

/// Map Kimi finish reasons to Tron stop reasons.
fn map_finish_reason(reason: &str) -> String {
    match reason {
        "stop" => "end_turn".into(),
        "tool_calls" => "tool_use".into(),
        "length" => "max_tokens".into(),
        "content_filter" => "content_filter".into(),
        other => other.into(),
    }
}

/// Finalize any open thinking/text/tool blocks.
fn finalize_open_blocks(state: &mut KimiStreamState, events: &mut Vec<StreamEvent>) {
    if state.in_thinking {
        state.in_thinking = false;
        let thinking = std::mem::take(&mut state.thinking_text);
        state.content_blocks.push(AssistantContent::Thinking {
            thinking: thinking.clone(),
            signature: None,
        });
        events.push(StreamEvent::ThinkingEnd {
            thinking,
            signature: None,
        });
    }
    if state.in_text {
        state.in_text = false;
        let text = std::mem::take(&mut state.text_content);
        state.content_blocks.push(AssistantContent::text(&text));
        events.push(StreamEvent::TextEnd {
            text,
            signature: None,
        });
    }

    // End any open tool calls
    for slot in &mut state.active_tools {
        if let Some(active) = slot.take() {
            let arguments: Map<String, Value> =
                serde_json::from_str(&active.arguments).unwrap_or_default();
            state.content_blocks.push(AssistantContent::ToolUse {
                id: active.id.clone(),
                name: active.name.clone(),
                arguments: arguments.clone(),
                thought_signature: None,
            });
            events.push(StreamEvent::ToolCallEnd {
                tool_call: ToolCall::new(active.id, active.name, arguments),
            });
        }
    }
}

/// Emit the Done event.
fn emit_done(state: &mut KimiStreamState, events: &mut Vec<StreamEvent>) {
    let stop_reason = state
        .stop_reason
        .take()
        .unwrap_or_else(|| "end_turn".into());
    let usage = state.usage.take();
    let content = std::mem::take(&mut state.content_blocks);

    events.push(StreamEvent::Done {
        message: crate::core::events::AssistantMessage {
            content,
            token_usage: usage,
        },
        stop_reason,
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn text_chunk(content: &str) -> ChatCompletionChunk {
        ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: Some(content.into()),
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: None,
            }],
            usage: None,
        }
    }

    fn thinking_chunk(content: &str) -> ChatCompletionChunk {
        ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: Some(content.into()),
                    tool_calls: None,
                },
                finish_reason: None,
            }],
            usage: None,
        }
    }

    fn finish_chunk(reason: &str) -> ChatCompletionChunk {
        ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: Some(reason.into()),
            }],
            usage: None,
        }
    }

    fn usage_chunk(prompt: u64, completion: u64) -> ChatCompletionChunk {
        ChatCompletionChunk {
            choices: vec![],
            usage: Some(ChunkUsage {
                prompt_tokens: prompt,
                completion_tokens: completion,
            }),
        }
    }

    #[test]
    fn text_only_stream() {
        let mut state = KimiStreamState::new();
        let events1 = process_chunk(&text_chunk("Hello"), &mut state);
        assert!(matches!(events1[0], StreamEvent::TextStart));
        assert!(matches!(events1[1], StreamEvent::TextDelta { .. }));

        let events2 = process_chunk(&text_chunk(" world"), &mut state);
        assert_eq!(events2.len(), 1); // just delta, no start
        assert!(matches!(events2[0], StreamEvent::TextDelta { .. }));
    }

    #[test]
    fn thinking_stream() {
        let mut state = KimiStreamState::new();
        let events = process_chunk(&thinking_chunk("Let me think"), &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingStart));
        assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
    }

    #[test]
    fn thinking_to_text_transition() {
        let mut state = KimiStreamState::new();
        let _ = process_chunk(&thinking_chunk("thinking..."), &mut state);
        let events = process_chunk(&text_chunk("answer"), &mut state);

        // Should see ThinkingEnd, TextStart, TextDelta
        assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
        assert!(matches!(events[1], StreamEvent::TextStart));
        assert!(matches!(events[2], StreamEvent::TextDelta { .. }));
    }

    #[test]
    fn tool_call_stream() {
        let mut state = KimiStreamState::new();

        // First chunk: tool call start with name
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: Some(vec![ChunkToolCall {
                        index: 0,
                        id: Some("call_abc".into()),
                        function: Some(ChunkToolCallFunction {
                            name: Some("bash".into()),
                            arguments: Some("{\"cm".into()),
                        }),
                    }]),
                },
                finish_reason: None,
            }],
            usage: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(matches!(events[0], StreamEvent::ToolCallStart { .. }));
        assert!(matches!(events[1], StreamEvent::ToolCallDelta { .. }));

        // Second chunk: more arguments
        let chunk2 = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: Some(vec![ChunkToolCall {
                        index: 0,
                        id: None,
                        function: Some(ChunkToolCallFunction {
                            name: None,
                            arguments: Some("d\":\"ls\"}".into()),
                        }),
                    }]),
                },
                finish_reason: None,
            }],
            usage: None,
        };
        let events2 = process_chunk(&chunk2, &mut state);
        assert_eq!(events2.len(), 1);
        assert!(matches!(events2[0], StreamEvent::ToolCallDelta { .. }));
    }

    #[test]
    fn multiple_tool_calls() {
        let mut state = KimiStreamState::new();

        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: Some(vec![
                        ChunkToolCall {
                            index: 0,
                            id: Some("call_1".into()),
                            function: Some(ChunkToolCallFunction {
                                name: Some("bash".into()),
                                arguments: Some("{}".into()),
                            }),
                        },
                        ChunkToolCall {
                            index: 1,
                            id: Some("call_2".into()),
                            function: Some(ChunkToolCallFunction {
                                name: Some("read".into()),
                                arguments: Some("{}".into()),
                            }),
                        },
                    ]),
                },
                finish_reason: None,
            }],
            usage: None,
        };

        let events = process_chunk(&chunk, &mut state);
        let starts: Vec<_> = events
            .iter()
            .filter(|e| matches!(e, StreamEvent::ToolCallStart { .. }))
            .collect();
        assert_eq!(starts.len(), 2);
    }

    #[test]
    fn finish_reason_stop() {
        let mut state = KimiStreamState::new();
        let _ = process_chunk(&text_chunk("hello"), &mut state);

        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: Some("stop".into()),
            }],
            usage: Some(ChunkUsage {
                prompt_tokens: 100,
                completion_tokens: 50,
            }),
        };
        let events = process_chunk(&chunk, &mut state);
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        assert!(done.is_some());
        if let StreamEvent::Done { stop_reason, .. } = done.unwrap() {
            assert_eq!(stop_reason, "end_turn");
        }
    }

    #[test]
    fn finish_reason_tool_calls() {
        let mut state = KimiStreamState::new();
        state.stop_reason = Some("tool_use".into());
        state.usage = Some(TokenUsage::default());
        let events = process_chunk(
            &ChatCompletionChunk {
                choices: vec![],
                usage: None,
            },
            &mut state,
        );
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        assert!(done.is_some());
    }

    #[test]
    fn finish_reason_length() {
        let mut state = KimiStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);
        let events = process_chunk(&finish_chunk("length"), &mut state);
        // TextEnd should be emitted before finish processing
        assert!(
            events
                .iter()
                .any(|e| matches!(e, StreamEvent::TextEnd { .. }))
        );
    }

    #[test]
    fn usage_extraction() {
        let mut state = KimiStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: Some("stop".into()),
            }],
            usage: Some(ChunkUsage {
                prompt_tokens: 500,
                completion_tokens: 200,
            }),
        };
        let events = process_chunk(&chunk, &mut state);
        if let Some(StreamEvent::Done { message, .. }) = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }))
        {
            let usage = message.token_usage.as_ref().unwrap();
            assert_eq!(usage.input_tokens, 500);
            assert_eq!(usage.output_tokens, 200);
        } else {
            panic!("expected Done event");
        }
    }

    #[test]
    fn empty_delta_no_events() {
        let mut state = KimiStreamState::new();
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: None,
            }],
            usage: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(events.is_empty());
    }

    #[test]
    fn empty_content_string_no_events() {
        let mut state = KimiStreamState::new();
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: Some(String::new()),
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: None,
            }],
            usage: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(events.is_empty());
    }

    #[test]
    fn thinking_plus_tool_calls() {
        let mut state = KimiStreamState::new();

        // Thinking
        let _ = process_chunk(&thinking_chunk("planning..."), &mut state);

        // Tool call — should end thinking first
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: Some(vec![ChunkToolCall {
                        index: 0,
                        id: Some("call_1".into()),
                        function: Some(ChunkToolCallFunction {
                            name: Some("bash".into()),
                            arguments: Some("{}".into()),
                        }),
                    }]),
                },
                finish_reason: None,
            }],
            usage: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
        assert!(matches!(events[1], StreamEvent::ToolCallStart { .. }));
    }

    #[test]
    fn tool_call_arguments_accumulation() {
        let mut state = KimiStreamState::new();

        // Start
        let chunk1 = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: Some(vec![ChunkToolCall {
                        index: 0,
                        id: Some("call_1".into()),
                        function: Some(ChunkToolCallFunction {
                            name: Some("bash".into()),
                            arguments: Some("{\"cm".into()),
                        }),
                    }]),
                },
                finish_reason: None,
            }],
            usage: None,
        };
        let _ = process_chunk(&chunk1, &mut state);

        // Continue
        let chunk2 = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: Some(vec![ChunkToolCall {
                        index: 0,
                        id: None,
                        function: Some(ChunkToolCallFunction {
                            name: None,
                            arguments: Some("d\":\"ls\"}".into()),
                        }),
                    }]),
                },
                finish_reason: None,
            }],
            usage: None,
        };
        let _ = process_chunk(&chunk2, &mut state);

        // Finish — should emit ToolCallEnd with complete arguments
        let chunk3 = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: Some("tool_calls".into()),
            }],
            usage: Some(ChunkUsage {
                prompt_tokens: 100,
                completion_tokens: 50,
            }),
        };
        let events = process_chunk(&chunk3, &mut state);

        let tool_end = events
            .iter()
            .find(|e| matches!(e, StreamEvent::ToolCallEnd { .. }));
        assert!(tool_end.is_some());
        if let StreamEvent::ToolCallEnd { tool_call } = tool_end.unwrap() {
            assert_eq!(tool_call.name, "bash");
            assert_eq!(tool_call.arguments["cmd"], "ls");
        }
    }

    #[test]
    fn separate_finish_and_usage_chunks() {
        let mut state = KimiStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);

        // Finish reason in one chunk
        let events1 = process_chunk(&finish_chunk("stop"), &mut state);
        // TextEnd should be emitted
        assert!(
            events1
                .iter()
                .any(|e| matches!(e, StreamEvent::TextEnd { .. }))
        );
        // No Done yet (no usage)

        // Usage in separate chunk
        let events2 = process_chunk(&usage_chunk(100, 50), &mut state);
        let done = events2
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        assert!(done.is_some());
    }

    #[test]
    fn map_finish_reasons() {
        assert_eq!(map_finish_reason("stop"), "end_turn");
        assert_eq!(map_finish_reason("tool_calls"), "tool_use");
        assert_eq!(map_finish_reason("length"), "max_tokens");
        assert_eq!(map_finish_reason("content_filter"), "content_filter");
        assert_eq!(map_finish_reason("unknown_reason"), "unknown_reason");
    }
}
