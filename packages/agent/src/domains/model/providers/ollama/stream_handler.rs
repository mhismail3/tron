//! Ollama native API stream handler — NDJSON chunks → `StreamEvent`.
//!
//! Deserializes Ollama's native `/api/chat` streaming format (newline-delimited
//! JSON, NOT SSE) and maps chunks to Tron's `StreamEvent` types. Handles text,
//! thinking content, and tool calls.
//!
//! # Why native API, not OpenAI-compatible?
//!
//! Ollama's `/v1/chat/completions` endpoint ignores `num_ctx` and reloads the
//! model at the default 4K context on every request, destroying thinking output.
//! The native `/api/chat` endpoint is the only way to control context size.
//!
//! # Format differences from OpenAI
//!
//! - No SSE `data:` prefix — raw JSON per line (NDJSON)
//! - Thinking: `message.thinking` (not `reasoning` or `reasoning_content`)
//! - Content: `message.content` (not `choices[].delta.content`)
//! - Tool calls arrive complete in a single chunk (not streamed across chunks)
//! - Done: `"done": true` + `"done_reason"` (not `finish_reason`)
//! - Usage: `prompt_eval_count` / `eval_count` in the final chunk

use serde::Deserialize;
use serde_json::{Map, Value};
use tracing::{debug, info};

use crate::shared::content::AssistantContent;
use crate::shared::events::StreamEvent;
use crate::shared::messages::{TokenUsage, ToolCall};

// ─── Native API chunk types ─────────────────────────────────────────────

/// A single streaming chunk from Ollama's native `/api/chat` endpoint.
///
/// Each line of the NDJSON stream deserializes to this type.
#[derive(Debug, Deserialize)]
pub struct OllamaChatChunk {
    /// The message delta for this chunk.
    #[serde(default)]
    pub message: OllamaMessage,
    /// Whether the stream is complete.
    #[serde(default)]
    pub done: bool,
    /// Reason for completion (present when `done` is true).
    pub done_reason: Option<String>,
    /// Input token count (present when `done` is true).
    pub prompt_eval_count: Option<u64>,
    /// Output token count (present when `done` is true).
    pub eval_count: Option<u64>,
}

/// Message content within a native API chunk.
#[derive(Debug, Default, Deserialize)]
pub struct OllamaMessage {
    /// Text content delta.
    #[serde(default)]
    pub content: String,
    /// Thinking/reasoning content delta.
    pub thinking: Option<String>,
    /// Tool calls (arrive complete in a single chunk).
    pub tool_calls: Option<Vec<OllamaToolCall>>,
}

/// A tool call from the native API (arrives complete, not streamed).
#[derive(Debug, Deserialize)]
pub struct OllamaToolCall {
    /// Tool call ID.
    pub id: Option<String>,
    /// Function details.
    pub function: OllamaToolCallFunction,
}

/// Function details within a native API tool call.
#[derive(Debug, Deserialize)]
pub struct OllamaToolCallFunction {
    /// Function name.
    pub name: String,
    /// Arguments as a parsed JSON object (NOT a string like OpenAI).
    #[serde(default)]
    pub arguments: Map<String, Value>,
}

// ─── Stream state ──────────────────────────────────────────────────────

/// Stream processing state for Ollama native API responses.
#[derive(Debug)]
pub struct OllamaStreamState {
    in_thinking: bool,
    in_text: bool,
    thinking_text: String,
    text_content: String,
    usage: Option<TokenUsage>,
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
            usage: None,
            content_blocks: Vec::new(),
        }
    }
}

impl Default for OllamaStreamState {
    fn default() -> Self {
        Self::new()
    }
}

// ─── Chunk processing ──────────────────────────────────────────────────

/// Process a single native API chunk and produce stream events.
pub fn process_chunk(chunk: &OllamaChatChunk, state: &mut OllamaStreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    // Log first chunk for diagnostics
    if !state.in_thinking && !state.in_text && !chunk.done {
        let content_preview = if chunk.message.content.is_empty() {
            None
        } else {
            Some(&chunk.message.content[..chunk.message.content.len().min(50)])
        };
        info!(
            thinking = ?chunk.message.thinking.as_deref().map(|s| &s[..s.len().min(50)]),
            content_preview = ?content_preview,
            has_tool_calls = chunk.message.tool_calls.is_some(),
            "ollama: first chunk received"
        );
    }

    // Process thinking content
    if let Some(ref thinking) = chunk.message.thinking
        && !thinking.is_empty()
    {
        if !state.in_thinking {
            state.in_thinking = true;
            debug!("ollama: entering thinking state");
            events.push(StreamEvent::ThinkingStart);
        }
        state.thinking_text.push_str(thinking);
        events.push(StreamEvent::ThinkingDelta {
            delta: thinking.clone(),
        });
    }

    // Process text content
    if !chunk.message.content.is_empty() {
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
        state.text_content.push_str(&chunk.message.content);
        events.push(StreamEvent::TextDelta {
            delta: chunk.message.content.clone(),
        });
    }

    // Process tool calls (arrive complete in native API)
    if let Some(ref tool_calls) = chunk.message.tool_calls {
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
            let id = tc
                .id
                .clone()
                .unwrap_or_else(|| format!("call_{:08x}", rand_id()));
            let name = tc.function.name.clone();
            let arguments = tc.function.arguments.clone();
            let args_str = serde_json::to_string(&arguments).unwrap_or_default();

            events.push(StreamEvent::ToolCallStart {
                tool_call_id: id.clone(),
                name: name.clone(),
            });
            events.push(StreamEvent::ToolCallDelta {
                tool_call_id: id.clone(),
                arguments_delta: args_str,
            });

            state.content_blocks.push(AssistantContent::ToolUse {
                id: id.clone(),
                name: name.clone(),
                arguments: arguments.clone(),
                thought_signature: None,
            });
            events.push(StreamEvent::ToolCallEnd {
                tool_call: ToolCall::new(id, name, arguments),
            });
        }
    }

    // Process done
    if chunk.done {
        // Capture usage from the final chunk
        if let (Some(prompt), Some(completion)) = (chunk.prompt_eval_count, chunk.eval_count) {
            state.usage = Some(TokenUsage {
                input_tokens: prompt,
                output_tokens: completion,
                ..Default::default()
            });
        }

        let stop_reason = map_done_reason(chunk.done_reason.as_deref());
        // Check if tool calls were emitted — override stop reason
        let has_tools = state
            .content_blocks
            .iter()
            .any(|c| matches!(c, AssistantContent::ToolUse { .. }));
        let stop_reason = if has_tools {
            "tool_use".into()
        } else {
            stop_reason
        };

        finalize_open_blocks(state, &mut events);
        emit_done(state, &mut events, stop_reason);
    }

    events
}

/// Generate a simple random ID for tool calls without an ID.
fn rand_id() -> u32 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    use std::time::SystemTime;
    let mut h = DefaultHasher::new();
    SystemTime::now().hash(&mut h);
    h.finish() as u32
}

/// Map Ollama done_reason to Tron stop reasons.
fn map_done_reason(reason: Option<&str>) -> String {
    match reason {
        Some("stop") | None => "end_turn".into(),
        Some("length") => "max_tokens".into(),
        Some("load") => "end_turn".into(),
        Some(other) => other.into(),
    }
}

/// Finalize any open thinking/text blocks.
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
}

/// Emit the Done event.
fn emit_done(state: &mut OllamaStreamState, events: &mut Vec<StreamEvent>, stop_reason: String) {
    let usage = state.usage.take();
    let content = std::mem::take(&mut state.content_blocks);

    let thinking_count = content
        .iter()
        .filter(|c| matches!(c, AssistantContent::Thinking { .. }))
        .count();
    let text_count = content
        .iter()
        .filter(|c| matches!(c, AssistantContent::Text { .. }))
        .count();
    info!(
        stop_reason = %stop_reason,
        content_block_count = content.len(),
        thinking_blocks = thinking_count,
        text_blocks = text_count,
        "ollama: emitting Done event"
    );

    events.push(StreamEvent::Done {
        message: crate::shared::events::AssistantMessage {
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

    fn text_chunk(content: &str) -> OllamaChatChunk {
        OllamaChatChunk {
            message: OllamaMessage {
                content: content.into(),
                thinking: None,
                tool_calls: None,
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        }
    }

    fn thinking_chunk(thinking: &str) -> OllamaChatChunk {
        OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: Some(thinking.into()),
                tool_calls: None,
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        }
    }

    fn done_chunk(reason: &str, prompt: u64, completion: u64) -> OllamaChatChunk {
        OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: None,
                tool_calls: None,
            },
            done: true,
            done_reason: Some(reason.into()),
            prompt_eval_count: Some(prompt),
            eval_count: Some(completion),
        }
    }

    fn done_chunk_no_usage() -> OllamaChatChunk {
        OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: None,
                tool_calls: None,
            },
            done: true,
            done_reason: Some("stop".into()),
            prompt_eval_count: None,
            eval_count: None,
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
    fn thinking_triggers_thinking_events() {
        let mut state = OllamaStreamState::new();
        let events = process_chunk(&thinking_chunk("Let me think"), &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingStart));
        assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
    }

    #[test]
    fn thinking_to_text_transition() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&thinking_chunk("thinking..."), &mut state);
        let events = process_chunk(&text_chunk("answer"), &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
        assert!(matches!(events[1], StreamEvent::TextStart));
        assert!(matches!(events[2], StreamEvent::TextDelta { .. }));
    }

    #[test]
    fn tool_call_complete_in_one_chunk() {
        let mut state = OllamaStreamState::new();
        let chunk = OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: None,
                tool_calls: Some(vec![OllamaToolCall {
                    id: Some("call_abc123".into()),
                    function: OllamaToolCallFunction {
                        name: "execute".into(),
                        arguments: {
                            let mut m = Map::new();
                            m.insert("command".into(), Value::String("ls".into()));
                            m
                        },
                    },
                }]),
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(matches!(events[0], StreamEvent::ToolCallStart { .. }));
        assert!(matches!(events[1], StreamEvent::ToolCallDelta { .. }));
        assert!(matches!(events[2], StreamEvent::ToolCallEnd { .. }));
        if let StreamEvent::ToolCallEnd { tool_call } = &events[2] {
            assert_eq!(tool_call.name, "execute");
            assert_eq!(tool_call.arguments["command"], "ls");
        }
    }

    #[test]
    fn multiple_tool_calls_in_one_chunk() {
        let mut state = OllamaStreamState::new();
        let chunk = OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: None,
                tool_calls: Some(vec![
                    OllamaToolCall {
                        id: Some("call_1".into()),
                        function: OllamaToolCallFunction {
                            name: "execute".into(),
                            arguments: Map::new(),
                        },
                    },
                    OllamaToolCall {
                        id: Some("call_2".into()),
                        function: OllamaToolCallFunction {
                            name: "inspect".into(),
                            arguments: Map::new(),
                        },
                    },
                ]),
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        };
        let events = process_chunk(&chunk, &mut state);
        let starts: Vec<_> = events
            .iter()
            .filter(|e| matches!(e, StreamEvent::ToolCallStart { .. }))
            .collect();
        assert_eq!(starts.len(), 2);
    }

    #[test]
    fn done_with_stop_reason() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hello"), &mut state);
        let events = process_chunk(&done_chunk("stop", 100, 50), &mut state);
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        assert!(done.is_some());
        if let StreamEvent::Done {
            stop_reason,
            message,
        } = done.unwrap()
        {
            assert_eq!(stop_reason, "end_turn");
            let usage = message.token_usage.as_ref().unwrap();
            assert_eq!(usage.input_tokens, 100);
            assert_eq!(usage.output_tokens, 50);
        }
    }

    #[test]
    fn done_without_usage() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hi"), &mut state);
        let events = process_chunk(&done_chunk_no_usage(), &mut state);
        if let Some(StreamEvent::Done { message, .. }) = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }))
        {
            assert!(message.token_usage.is_none());
        } else {
            panic!("expected Done event");
        }
    }

    #[test]
    fn done_with_tool_calls_overrides_stop_reason() {
        let mut state = OllamaStreamState::new();
        // Emit tool calls first
        let tc_chunk = OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: None,
                tool_calls: Some(vec![OllamaToolCall {
                    id: Some("call_1".into()),
                    function: OllamaToolCallFunction {
                        name: "execute".into(),
                        arguments: Map::new(),
                    },
                }]),
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        };
        let _ = process_chunk(&tc_chunk, &mut state);
        // Ollama sends done_reason: "stop" even for tool calls
        let events = process_chunk(&done_chunk("stop", 100, 50), &mut state);
        if let Some(StreamEvent::Done { stop_reason, .. }) = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }))
        {
            assert_eq!(stop_reason, "tool_use");
        } else {
            panic!("expected Done event");
        }
    }

    #[test]
    fn thinking_plus_tool_calls() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&thinking_chunk("planning..."), &mut state);
        let chunk = OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: None,
                tool_calls: Some(vec![OllamaToolCall {
                    id: Some("call_1".into()),
                    function: OllamaToolCallFunction {
                        name: "execute".into(),
                        arguments: Map::new(),
                    },
                }]),
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
        assert!(matches!(events[1], StreamEvent::ToolCallStart { .. }));
    }

    #[test]
    fn empty_content_no_events() {
        let mut state = OllamaStreamState::new();
        let chunk = OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: None,
                tool_calls: None,
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(events.is_empty());
    }

    #[test]
    fn empty_thinking_no_events() {
        let mut state = OllamaStreamState::new();
        let chunk = OllamaChatChunk {
            message: OllamaMessage {
                content: String::new(),
                thinking: Some(String::new()),
                tool_calls: None,
            },
            done: false,
            done_reason: None,
            prompt_eval_count: None,
            eval_count: None,
        };
        let events = process_chunk(&chunk, &mut state);
        assert!(events.is_empty());
    }

    #[test]
    fn map_done_reasons() {
        assert_eq!(map_done_reason(Some("stop")), "end_turn");
        assert_eq!(map_done_reason(Some("length")), "max_tokens");
        assert_eq!(map_done_reason(Some("load")), "end_turn");
        assert_eq!(map_done_reason(None), "end_turn");
        assert_eq!(map_done_reason(Some("unknown")), "unknown");
    }

    #[test]
    fn done_finalizes_open_thinking() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&thinking_chunk("deep thoughts"), &mut state);
        let events = process_chunk(&done_chunk("stop", 10, 5), &mut state);
        // Should have ThinkingEnd before Done
        assert!(
            events
                .iter()
                .any(|e| matches!(e, StreamEvent::ThinkingEnd { .. }))
        );
        assert!(events.iter().any(|e| matches!(e, StreamEvent::Done { .. })));
    }

    #[test]
    fn done_finalizes_open_text() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&text_chunk("hello"), &mut state);
        let events = process_chunk(&done_chunk("stop", 10, 5), &mut state);
        assert!(
            events
                .iter()
                .any(|e| matches!(e, StreamEvent::TextEnd { .. }))
        );
        assert!(events.iter().any(|e| matches!(e, StreamEvent::Done { .. })));
    }

    #[test]
    fn done_content_includes_thinking_and_text() {
        let mut state = OllamaStreamState::new();
        let _ = process_chunk(&thinking_chunk("hmm"), &mut state);
        let _ = process_chunk(&text_chunk("answer"), &mut state);
        let events = process_chunk(&done_chunk("stop", 10, 5), &mut state);
        if let Some(StreamEvent::Done { message, .. }) = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }))
        {
            assert_eq!(message.content.len(), 2);
            assert!(matches!(
                message.content[0],
                AssistantContent::Thinking { .. }
            ));
            assert!(matches!(message.content[1], AssistantContent::Text { .. }));
        } else {
            panic!("expected Done event");
        }
    }

    #[test]
    fn deserialization_from_real_ollama_json() {
        // Real chunk from Ollama native API
        let json = r#"{"model":"gemma4:e4b","created_at":"2026-04-10T21:37:05.295794Z","message":{"role":"assistant","content":"","thinking":"Here's"},"done":false}"#;
        let chunk: OllamaChatChunk = serde_json::from_str(json).unwrap();
        assert!(!chunk.done);
        assert_eq!(chunk.message.thinking.as_deref(), Some("Here's"));
        assert!(chunk.message.content.is_empty());

        let mut state = OllamaStreamState::new();
        let events = process_chunk(&chunk, &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingStart));
        assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
    }

    #[test]
    fn deserialization_done_chunk() {
        let json = r#"{"model":"gemma4:e4b","created_at":"2026-04-10T21:37:05.315509Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":269220250,"load_duration":171860917,"prompt_eval_count":22,"prompt_eval_duration":76691917,"eval_count":2,"eval_duration":19558000}"#;
        let chunk: OllamaChatChunk = serde_json::from_str(json).unwrap();
        assert!(chunk.done);
        assert_eq!(chunk.done_reason.as_deref(), Some("stop"));
        assert_eq!(chunk.prompt_eval_count, Some(22));
        assert_eq!(chunk.eval_count, Some(2));
    }

    #[test]
    fn deserialization_tool_call_chunk() {
        let json = r#"{"model":"gemma4:e4b","created_at":"2026-04-10T21:37:18.864432Z","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_ba7d6wq8","function":{"index":0,"name":"get_weather","arguments":{"location":"San Francisco"}}}]},"done":false}"#;
        let chunk: OllamaChatChunk = serde_json::from_str(json).unwrap();
        let tc = chunk.message.tool_calls.as_ref().unwrap();
        assert_eq!(tc.len(), 1);
        assert_eq!(tc[0].function.name, "get_weather");
        assert_eq!(tc[0].function.arguments["location"], "San Francisco");
    }
}
