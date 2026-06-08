//! Anthropic SSE stream handler.
//!
//! Converts raw Anthropic SSE events (`message_start`, `content_block_delta`, etc.)
//! into unified [`StreamEvent`]s consumed by the agent runtime.
//!
//! The handler maintains a [`StreamState`] that accumulates text, thinking, signature,
//! and capability arguments across delta events, then emits complete blocks on `content_block_stop`.
//!
//! Delegates mechanical delta accumulation to [`StreamAccumulator`] from the shared
//! `stream_common` module, keeping only Anthropic-specific protocol mapping here.

use tracing::{debug, warn};

use crate::domains::model::providers::stream_common::StreamAccumulator;
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
use crate::shared::protocol::messages::TokenUsage;

use super::types::{AnthropicSseEvent, SseContentBlock, SseDelta};

/// Stream state accumulated across SSE events.
#[derive(Clone, Debug)]
pub struct StreamState {
    /// Provider type for token attribution in Done events.
    pub provider_type: crate::shared::protocol::messages::Provider,
    /// Shared delta accumulator for text, thinking, signature, and tool args.
    pub acc: StreamAccumulator,
    /// Current content block type being accumulated.
    pub current_block_type: Option<BlockType>,
    /// Capability invocation ID for the current Anthropic `tool_use` block.
    pub current_invocation_id: Option<String>,
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

impl Default for StreamState {
    fn default() -> Self {
        Self {
            provider_type: crate::shared::protocol::messages::Provider::Anthropic,
            acc: StreamAccumulator::new(),
            current_block_type: None,
            current_invocation_id: None,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
            cache_creation_5m_tokens: 0,
            cache_creation_1h_tokens: 0,
            content_blocks: Vec::new(),
            stop_reason: None,
        }
    }
}

/// Type of content block being accumulated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BlockType {
    /// Text response.
    Text,
    /// Extended thinking.
    Thinking,
    /// ModelCapability use (function call).
    CapabilityInvocation,
}

/// Create a new stream state for a specific provider.
#[must_use]
pub fn create_stream_state_for(
    provider_type: crate::shared::protocol::messages::Provider,
) -> StreamState {
    StreamState {
        provider_type,
        ..StreamState::default()
    }
}

/// Create a new stream state (defaults to Anthropic).
#[must_use]
pub fn create_stream_state() -> StreamState {
    create_stream_state_for(crate::shared::protocol::messages::Provider::Anthropic)
}

/// Process a single Anthropic SSE event and return zero or more [`StreamEvent`]s.
///
/// Call this for each SSE event received. The state is mutated to track
/// accumulated content across events.
pub fn process_sse_event(event: &AnthropicSseEvent, state: &mut StreamState) -> Vec<StreamEvent> {
    match event {
        AnthropicSseEvent::MessageStart { message } => {
            state.acc.input_tokens = message.usage.input_tokens;
            state.cache_creation_tokens = message.usage.cache_creation_input_tokens;
            state.cache_read_tokens = message.usage.cache_read_input_tokens;
            if let Some(ref cc) = message.usage.cache_creation {
                state.cache_creation_5m_tokens = cc.ephemeral_5m_input_tokens;
                state.cache_creation_1h_tokens = cc.ephemeral_1h_input_tokens;
            }

            let cache_hit = state.cache_read_tokens > 0;
            let cache_write = state.cache_creation_tokens > 0;
            debug!(
                input_tokens = state.acc.input_tokens,
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
                // Anthropic has explicit block starts; use mark_ rather than process_.
                state.acc.text_started = true;
                vec![StreamEvent::TextStart]
            }
            SseContentBlock::Thinking { .. } => {
                state.current_block_type = Some(BlockType::Thinking);
                state.acc.thinking_started = true;
                vec![StreamEvent::ThinkingStart]
            }
            SseContentBlock::CapabilityInvocation { id, name } => {
                state.current_block_type = Some(BlockType::CapabilityInvocation);
                state.current_invocation_id = Some(id.clone());
                state
                    .acc
                    .start_capability_invocation(id.clone(), name.clone())
            }
        },

        AnthropicSseEvent::ContentBlockDelta { delta, .. } => match delta {
            SseDelta::TextDelta { text } => {
                state.acc.accumulate_text(text);
                vec![StreamEvent::TextDelta {
                    delta: text.clone(),
                }]
            }
            SseDelta::ThinkingDelta { thinking } => {
                state.acc.accumulate_thinking(thinking);
                vec![StreamEvent::ThinkingDelta {
                    delta: thinking.clone(),
                }]
            }
            SseDelta::SignatureDelta { signature } => {
                state.acc.accumulate_signature(signature);
                vec![]
            }
            SseDelta::InputJsonDelta { partial_json } => {
                if let Some(ref id) = state.current_invocation_id {
                    state.acc.append_tool_args(id, partial_json)
                } else {
                    vec![]
                }
            }
        },

        AnthropicSseEvent::ContentBlockStop { .. } => handle_content_block_stop(state),

        AnthropicSseEvent::MessageDelta { delta, usage } => {
            state.stop_reason.clone_from(&delta.stop_reason);
            if let Some(u) = usage {
                state.acc.output_tokens = u.output_tokens;
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
            let text = state.acc.take_text();
            state
                .content_blocks
                .push(AssistantContent::Text { text: text.clone() });
            vec![StreamEvent::TextEnd {
                text,
                signature: None,
            }]
        }
        Some(BlockType::Thinking) => {
            let thinking = state.acc.take_thinking();
            let signature = state.acc.take_signature();
            state.content_blocks.push(AssistantContent::Thinking {
                thinking: thinking.clone(),
                signature: signature.clone(),
            });
            vec![StreamEvent::ThinkingEnd {
                thinking,
                signature,
            }]
        }
        Some(BlockType::CapabilityInvocation) => {
            let id = state.current_invocation_id.take().unwrap_or_default();
            let events = state.acc.finish_capability_invocation_with_provider(
                &id,
                Some(state.provider_type.as_str()),
            );
            // Extract the CapabilityInvocationDraft from the event to build the content block.
            if let Some(StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation,
            }) = events.first()
            {
                state
                    .content_blocks
                    .push(AssistantContent::CapabilityInvocation {
                        id: capability_invocation.id.clone(),
                        name: capability_invocation.name.clone(),
                        arguments: capability_invocation.arguments.clone(),
                        thought_signature: None,
                    });
            }
            events
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

    let token_usage = if state.acc.input_tokens > 0 || state.acc.output_tokens > 0 {
        Some(TokenUsage {
            input_tokens: state.acc.input_tokens,
            output_tokens: state.acc.output_tokens,
            cache_read_tokens: if state.cache_read_tokens > 0 {
                Some(state.cache_read_tokens)
            } else {
                None
            },
            cached_input_tokens: if state.cache_read_tokens > 0 {
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
            total_tokens: Some(
                state.acc.input_tokens
                    + state.acc.output_tokens
                    + state.cache_read_tokens
                    + state.cache_creation_tokens,
            ),
            provider_type: Some(state.provider_type),
            ..Default::default()
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
mod tests;
