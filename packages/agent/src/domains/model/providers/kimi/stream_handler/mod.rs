//! Kimi SSE stream handler — `chat.completion.chunk` → `StreamEvent`.
//!
//! Deserializes OpenAI-format SSE chunks and maps them to Tron's `StreamEvent`
//! types. Handles text, reasoning content, and capability invocation streaming.

use serde::Deserialize;
use serde_json::{Map, Value};

use crate::domains::model::protocol::{CapabilityCallContext, parse_capability_call_arguments};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::StreamEvent;
use crate::shared::protocol::messages::{CapabilityInvocationDraft, Provider, TokenUsage};

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
    /// Capability invocations being constructed.
    pub capability_invocations: Option<Vec<ChunkCapabilityInvocationDraft>>,
}

/// A capability invocation delta within a streaming chunk.
#[derive(Debug, Deserialize)]
pub struct ChunkCapabilityInvocationDraft {
    /// Capability invocation index (for multiple concurrent capability invocations).
    pub index: u32,
    /// Capability invocation ID (present in the first delta for this capability invocation).
    pub id: Option<String>,
    /// Function details.
    pub function: Option<ChunkCapabilityInvocationDraftFunction>,
}

/// Function details within a capability invocation delta.
#[derive(Debug, Deserialize)]
pub struct ChunkCapabilityInvocationDraftFunction {
    /// Function name (present in the first delta).
    pub name: Option<String>,
    /// Partial arguments string.
    pub arguments: Option<String>,
}

/// Token usage from the final chunk.
#[derive(Debug, Default, Deserialize)]
pub struct ChunkUsage {
    /// Input tokens consumed.
    pub prompt_tokens: u64,
    /// Output tokens generated.
    pub completion_tokens: u64,
    /// Total tokens reported by the provider.
    #[serde(default)]
    pub total_tokens: Option<u64>,
    /// Cached input tokens reported by Kimi's chat API.
    #[serde(default)]
    pub cached_tokens: Option<u64>,
    /// OpenAI-compatible prompt token details when present.
    #[serde(default)]
    pub prompt_tokens_details: Option<PromptTokensDetails>,
    /// OpenAI-compatible completion token details when present.
    #[serde(default)]
    pub completion_tokens_details: Option<CompletionTokensDetails>,
}

/// Prompt token details from OpenAI-compatible responses.
#[derive(Debug, Default, Deserialize)]
pub struct PromptTokensDetails {
    /// Cached input tokens.
    #[serde(default)]
    pub cached_tokens: u64,
}

/// Completion token details from OpenAI-compatible responses.
#[derive(Debug, Default, Deserialize)]
pub struct CompletionTokensDetails {
    /// Hidden reasoning tokens.
    #[serde(default)]
    pub reasoning_tokens: u64,
}

// ─── Stream state ──────────────────────────────────────────────────────────

/// Active capability invocation being accumulated.
#[derive(Debug, Clone)]
struct ActiveCapabilityInvocationDraft {
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
    /// Active capability invocations by index.
    active_capabilities: Vec<Option<ActiveCapabilityInvocationDraft>>,
    /// Token usage from the final chunk.
    usage: Option<TokenUsage>,
    /// Stop reason.
    stop_reason: Option<String>,
    /// Whether malformed provider arguments have made the stream terminal.
    failed: bool,
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
            active_capabilities: Vec::new(),
            usage: None,
            stop_reason: None,
            failed: false,
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
        let cached_tokens = usage
            .cached_tokens
            .or_else(|| {
                usage
                    .prompt_tokens_details
                    .as_ref()
                    .map(|d| d.cached_tokens)
            })
            .unwrap_or(0);
        let reasoning_tokens = usage
            .completion_tokens_details
            .as_ref()
            .map_or(0, |d| d.reasoning_tokens);
        state.usage = Some(TokenUsage {
            input_tokens: usage.prompt_tokens,
            output_tokens: usage.completion_tokens,
            cache_read_tokens: nonzero(cached_tokens),
            cached_input_tokens: nonzero(cached_tokens),
            reasoning_output_tokens: nonzero(reasoning_tokens),
            total_tokens: usage
                .total_tokens
                .or(Some(usage.prompt_tokens + usage.completion_tokens)),
            provider_type: Some(Provider::Kimi),
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

        // Process capability invocations
        if let Some(ref capability_invocations) = choice.delta.capability_invocations {
            // End thinking/text blocks before capability invocations
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

            for tc in capability_invocations {
                let idx = tc.index as usize;
                // Ensure active_capabilities is large enough
                while state.active_capabilities.len() <= idx {
                    state.active_capabilities.push(None);
                }

                if let Some(ref id) = tc.id {
                    // First delta for this capability invocation — start
                    let name = tc
                        .function
                        .as_ref()
                        .and_then(|f| f.name.clone())
                        .unwrap_or_default();
                    state.active_capabilities[idx] = Some(ActiveCapabilityInvocationDraft {
                        id: id.clone(),
                        name: name.clone(),
                        arguments: String::new(),
                    });
                    events.push(StreamEvent::CapabilityInvocationDraftStart {
                        invocation_id: id.clone(),
                        name,
                    });
                }

                // Accumulate arguments
                if let Some(ref func) = tc.function
                    && let Some(ref args) = func.arguments
                    && !args.is_empty()
                    && let Some(ref mut active) = state.active_capabilities[idx]
                {
                    active.arguments.push_str(args);
                    events.push(StreamEvent::CapabilityInvocationDraftDelta {
                        invocation_id: active.id.clone(),
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
    if !state.failed
        && chunk.choices.is_empty()
        && state.usage.is_some()
        && state.stop_reason.is_some()
    {
        emit_done(state, &mut events);
    }

    // If we got finish_reason and usage in the same chunk
    if !state.failed
        && state.stop_reason.is_some()
        && state.usage.is_some()
        && !chunk.choices.is_empty()
    {
        emit_done(state, &mut events);
    }

    events
}

fn nonzero(value: u64) -> Option<u64> {
    (value > 0).then_some(value)
}

/// Map Kimi finish reasons to Tron stop reasons.
fn map_finish_reason(reason: &str) -> String {
    match reason {
        "stop" => "end_turn".into(),
        "capability_invocations" => "capability_invocation".into(),
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

    // End any open capability invocations
    for slot in &mut state.active_capabilities {
        if let Some(active) = slot.take() {
            let ctx = CapabilityCallContext {
                invocation_id: Some(active.id.clone()),
                model_primitive_name: Some(active.name.clone()),
                provider: Some("kimi".into()),
            };
            let arguments: Map<String, Value> =
                match parse_capability_call_arguments(Some(&active.arguments), Some(&ctx)) {
                    Ok(arguments) => arguments,
                    Err(error) => {
                        state.failed = true;
                        events.push(StreamEvent::Error {
                            error: error.to_string(),
                        });
                        continue;
                    }
                };
            state
                .content_blocks
                .push(AssistantContent::CapabilityInvocation {
                    id: active.id.clone(),
                    name: active.name.clone(),
                    arguments: arguments.clone(),
                    thought_signature: None,
                });
            events.push(StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation: CapabilityInvocationDraft::new(
                    active.id,
                    active.name,
                    arguments,
                ),
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
