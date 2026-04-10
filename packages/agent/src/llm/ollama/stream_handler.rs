//! Ollama SSE stream handler — `chat.completion.chunk` → `StreamEvent`.
//!
//! Deserializes OpenAI-format SSE chunks and maps them to Tron's `StreamEvent`
//! types. Handles text, reasoning content, and tool call streaming.
//!
//! Key difference from Kimi: Ollama uses `reasoning` field (not `reasoning_content`).

use serde::Deserialize;
use serde_json::{Map, Value};

use crate::core::content::AssistantContent;
use crate::core::events::StreamEvent;
use crate::core::messages::{TokenUsage, ToolCall};

// ─── SSE chunk types ──────────────────────────────────────────────────────

/// Top-level SSE chunk from Ollama's streaming response.
#[derive(Debug, Deserialize)]
pub struct ChatCompletionChunk {
    /// Choices array (usually one element).
    #[serde(default)]
    pub choices: Vec<ChunkChoice>,
    /// Token usage (present in final chunk).
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
///
/// Ollama uses `reasoning` for thinking content (not `reasoning_content` like Kimi).
/// We deserialize both field names for forward compatibility.
#[derive(Debug, Deserialize)]
pub struct ChunkDelta {
    /// Text content.
    pub content: Option<String>,
    /// Reasoning/thinking content (Ollama field name).
    pub reasoning: Option<String>,
    /// Reasoning/thinking content (Kimi/OpenAI field name — fallback).
    pub reasoning_content: Option<String>,
    /// Tool calls being constructed.
    pub tool_calls: Option<Vec<ChunkToolCall>>,
}

impl ChunkDelta {
    /// Get reasoning content from either field name.
    fn reasoning_text(&self) -> Option<&str> {
        self.reasoning
            .as_deref()
            .or(self.reasoning_content.as_deref())
    }
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

/// Stream processing state for Ollama responses.
#[derive(Debug)]
pub struct OllamaStreamState {
    in_thinking: bool,
    in_text: bool,
    thinking_text: String,
    text_content: String,
    active_tools: Vec<Option<ActiveToolCall>>,
    usage: Option<TokenUsage>,
    stop_reason: Option<String>,
    content_blocks: Vec<AssistantContent>,
}

impl OllamaStreamState {
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

impl Default for OllamaStreamState {
    fn default() -> Self {
        Self::new()
    }
}

// ─── Chunk processing ──────────────────────────────────────────────────────

/// Process a single SSE chunk and produce stream events.
pub fn process_chunk(
    chunk: &ChatCompletionChunk,
    state: &mut OllamaStreamState,
) -> Vec<StreamEvent> {
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
        // Process reasoning content (from either field name)
        if let Some(reasoning) = choice.delta.reasoning_text() {
            if !reasoning.is_empty() {
                if !state.in_thinking {
                    state.in_thinking = true;
                    events.push(StreamEvent::ThinkingStart);
                }
                state.thinking_text.push_str(reasoning);
                events.push(StreamEvent::ThinkingDelta {
                    delta: reasoning.to_string(),
                });
            }
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
                while state.active_tools.len() <= idx {
                    state.active_tools.push(None);
                }

                if let Some(ref id) = tc.id {
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

    // Emit Done when we have a stop reason.
    // Unlike Kimi/OpenAI, Ollama does NOT send usage data in streaming mode,
    // so we emit Done as soon as we have a stop_reason (usage will be None).
    if state.stop_reason.is_some() {
        emit_done(state, &mut events);
    }

    events
}

/// Map Ollama finish reasons to Tron stop reasons.
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
fn finalize_open_blocks(state: &mut OllamaStreamState, events: &mut Vec<StreamEvent>) {
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
fn emit_done(state: &mut OllamaStreamState, events: &mut Vec<StreamEvent>) {
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
                    reasoning: None,
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: None,
            }],
            usage: None,
        }
    }

    fn reasoning_chunk(content: &str) -> ChatCompletionChunk {
        ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: Some(content.into()),
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: None,
            }],
            usage: None,
        }
    }

    fn reasoning_content_chunk(content: &str) -> ChatCompletionChunk {
        ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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
                    reasoning: None,
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
        let mut state = OllamaStreamState::new();
        let events1 = process_chunk(&text_chunk("Hello"), &mut state);
        assert!(matches!(events1[0], StreamEvent::TextStart));
        assert!(matches!(events1[1], StreamEvent::TextDelta { .. }));

        let events2 = process_chunk(&text_chunk(" world"), &mut state);
        assert_eq!(events2.len(), 1);
        assert!(matches!(events2[0], StreamEvent::TextDelta { .. }));
    }

    #[test]
    fn reasoning_field_triggers_thinking() {
        let mut state = OllamaStreamState::new();
        let events = process_chunk(&reasoning_chunk("Let me think"), &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingStart));
        assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
    }

    #[test]
    fn reasoning_content_field_also_triggers_thinking() {
        let mut state = OllamaStreamState::new();
        let events = process_chunk(&reasoning_content_chunk("Let me think"), &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingStart));
        assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
    }

    #[test]
    fn thinking_to_text_transition() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&reasoning_chunk("thinking..."), &mut state);
        let events = process_chunk(&text_chunk("answer"), &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
        assert!(matches!(events[1], StreamEvent::TextStart));
        assert!(matches!(events[2], StreamEvent::TextDelta { .. }));
    }

    #[test]
    fn tool_call_stream() {
        let mut state = OllamaStreamState::new();
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
                    reasoning_content: None,
                    tool_calls: Some(vec![ChunkToolCall {
                        index: 0,
                        id: Some("call_abc".into()),
                        function: Some(ChunkToolCallFunction {
                            name: Some("bash".into()),
                            arguments: Some("{\"cmd\":\"ls\"}".into()),
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
    }

    #[test]
    fn multiple_tool_calls() {
        let mut state = OllamaStreamState::new();
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hello"), &mut state);
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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
        let mut state = OllamaStreamState::new();
        // Ollama emits Done on finish_reason alone (no usage required)
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
                    reasoning_content: None,
                    tool_calls: None,
                },
                finish_reason: Some("tool_calls".into()),
            }],
            usage: None,
        };
        let events = process_chunk(&chunk, &mut state);
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        assert!(done.is_some());
        if let StreamEvent::Done { stop_reason, .. } = done.unwrap() {
            assert_eq!(stop_reason, "tool_use");
        }
    }

    #[test]
    fn finish_reason_length() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);
        let events = process_chunk(&finish_chunk("length"), &mut state);
        assert!(events
            .iter()
            .any(|e| matches!(e, StreamEvent::TextEnd { .. })));
    }

    #[test]
    fn no_usage_in_streaming_is_ok() {
        // Ollama doesn't send usage in streaming mode — Done should have None usage
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);
        let events = process_chunk(&finish_chunk("stop"), &mut state);
        if let Some(StreamEvent::Done { message, .. }) =
            events.iter().find(|e| matches!(e, StreamEvent::Done { .. }))
        {
            assert!(message.token_usage.is_none());
        } else {
            panic!("expected Done event");
        }
    }

    #[test]
    fn empty_delta_no_events() {
        let mut state = OllamaStreamState::new();
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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
        let mut state = OllamaStreamState::new();
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: Some(String::new()),
                    reasoning: None,
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
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&reasoning_chunk("planning..."), &mut state);
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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
        let mut state = OllamaStreamState::new();
        let chunk1 = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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

        let chunk2 = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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

        let chunk3 = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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
    fn done_emits_on_finish_without_usage() {
        // Ollama doesn't send usage in streaming mode — Done fires on finish_reason alone
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);
        let events = process_chunk(&finish_chunk("stop"), &mut state);
        assert!(events
            .iter()
            .any(|e| matches!(e, StreamEvent::TextEnd { .. })));
        // Done should fire immediately (no separate usage chunk needed)
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        assert!(done.is_some());
        if let StreamEvent::Done { message, stop_reason } = done.unwrap() {
            assert_eq!(stop_reason, "end_turn");
            // Usage is None since Ollama doesn't report it in streaming
            assert!(message.token_usage.is_none());
        }
    }

    #[test]
    fn done_includes_usage_when_present() {
        // If Ollama ever adds streaming usage, it should be captured
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);
        let chunk = ChatCompletionChunk {
            choices: vec![ChunkChoice {
                delta: ChunkDelta {
                    content: None,
                    reasoning: None,
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
        if let Some(StreamEvent::Done { message, .. }) =
            events.iter().find(|e| matches!(e, StreamEvent::Done { .. }))
        {
            let usage = message.token_usage.as_ref().unwrap();
            assert_eq!(usage.input_tokens, 100);
            assert_eq!(usage.output_tokens, 50);
        } else {
            panic!("expected Done event");
        }
    }

    #[test]
    fn map_finish_reasons() {
        assert_eq!(map_finish_reason("stop"), "end_turn");
        assert_eq!(map_finish_reason("tool_calls"), "tool_use");
        assert_eq!(map_finish_reason("length"), "max_tokens");
        assert_eq!(map_finish_reason("content_filter"), "content_filter");
        assert_eq!(map_finish_reason("unknown_reason"), "unknown_reason");
    }

    #[test]
    fn no_choices_no_events() {
        let mut state = OllamaStreamState::new();
        let chunk = ChatCompletionChunk {
            choices: vec![],
            usage: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(events.is_empty());
    }
}
