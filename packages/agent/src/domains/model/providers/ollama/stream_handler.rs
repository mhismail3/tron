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

use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::StreamEvent;
use crate::shared::protocol::messages::{CapabilityInvocationDraft, Provider, TokenUsage};

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
    #[serde(default)]
    pub tool_calls: Option<Vec<OllamaCapabilityInvocationDraft>>,
}

/// A tool call from the native API (arrives complete, not streamed).
#[derive(Debug, Deserialize)]
pub struct OllamaCapabilityInvocationDraft {
    /// Tool call ID.
    pub id: Option<String>,
    /// Function details.
    pub function: OllamaCapabilityInvocationDraftFunction,
}

/// Function details within a native API tool call.
#[derive(Debug, Deserialize)]
pub struct OllamaCapabilityInvocationDraftFunction {
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

            events.push(StreamEvent::CapabilityInvocationDraftStart {
                invocation_id: id.clone(),
                name: name.clone(),
            });
            events.push(StreamEvent::CapabilityInvocationDraftDelta {
                invocation_id: id.clone(),
                arguments_delta: args_str,
            });

            state
                .content_blocks
                .push(AssistantContent::CapabilityInvocation {
                    id: id.clone(),
                    name: name.clone(),
                    arguments: arguments.clone(),
                    thought_signature: None,
                });
            events.push(StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation: CapabilityInvocationDraft::new(id, name, arguments),
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
                total_tokens: Some(prompt + completion),
                provider_type: Some(Provider::Ollama),
                ..Default::default()
            });
        }

        let stop_reason = map_done_reason(chunk.done_reason.as_deref());
        // Check if tool calls were emitted — override stop reason
        let has_tools = state
            .content_blocks
            .iter()
            .any(|c| matches!(c, AssistantContent::CapabilityInvocation { .. }));
        let stop_reason = if has_tools {
            "capability_invocation".into()
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
        message: crate::shared::protocol::events::AssistantMessage {
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
mod tests;
