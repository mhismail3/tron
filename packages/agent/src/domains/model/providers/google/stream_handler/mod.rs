//! SSE stream handler for the Gemini API.
//!
//! Processes streaming chunks from the Gemini API and converts them to unified
//! [`StreamEvent`] values. Handles thinking/text
//! transitions, function call extraction, safety blocks, and token usage.
//!
//! Delegates text/thinking delta accumulation to [`StreamAccumulator`] from the
//! shared `stream_common` module. Capability invocation handling remains provider-specific
//! because Gemini delivers complete function calls (not streamed argument deltas).

use std::collections::HashSet;

use crate::domains::model::protocol::{CapabilityCallContext, parse_capability_call_arguments};
use crate::domains::model::providers::shared::stream_common::{
    MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES, MAX_PROVIDER_STREAM_TOOL_INVOCATIONS,
    StreamAccumulator, check_stream_field_bytes, stream_limit_error_event,
};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
use crate::shared::protocol::messages::{CapabilityInvocationDraft, Provider, TokenUsage};
use serde_json::Map;

use super::types::{GeminiPart, GeminiStreamChunk, HarmProbability, SafetyRating};

/// Mutable state accumulated across SSE events within a single stream.
pub struct StreamState {
    /// Shared delta accumulator for text, thinking, and token tracking.
    pub acc: StreamAccumulator,
    /// Accumulated capability invocations (Google-specific: complete, not streamed).
    pub capability_invocations: Vec<CapabilityInvocationDraftState>,
    /// Counter for generating unique capability invocation IDs.
    pub capability_invocation_index: u32,
    /// Unique prefix for capability invocation ID generation (Gemini doesn't provide IDs).
    pub unique_prefix: String,
    /// Set of capability invocation IDs already completed (to avoid duplicates).
    pub completed_tool_ids: HashSet<String>,
    /// Token count for tool-use prompt scaffolding.
    pub tool_use_prompt_tokens: u64,
    /// Provider-reported total token count.
    pub total_tokens: u64,
}

/// State for an in-progress capability invocation.
pub struct CapabilityInvocationDraftState {
    /// Generated capability invocation ID.
    pub id: String,
    /// Function name.
    pub name: String,
    /// Parsed arguments.
    pub args: serde_json::Value,
    /// Thought signature from the part.
    pub thought_signature: Option<String>,
}

/// Create a new stream state for processing a Gemini SSE stream.
#[must_use]
pub fn create_stream_state() -> StreamState {
    let prefix = format!("{:08x}", rand_u32());
    StreamState {
        acc: StreamAccumulator::new(),
        capability_invocations: Vec::new(),
        capability_invocation_index: 0,
        unique_prefix: prefix,
        completed_tool_ids: HashSet::new(),
        tool_use_prompt_tokens: 0,
        total_tokens: 0,
    }
}

/// Simple pseudo-random u32 for unique prefix generation.
fn rand_u32() -> u32 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    nanos ^ 0x5DEE_CE1D
}

/// Process a single SSE data line from the Gemini stream.
///
/// Returns a vec of `StreamEvent` values to emit. Most lines produce 0-2 events;
/// the `response.done` / finish reason line produces the final `Done` event.
pub fn process_stream_chunk(
    chunk: &GeminiStreamChunk,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    // Check for API-level error
    if let Some(ref error) = chunk.error {
        events.push(StreamEvent::Error {
            error: format!("Gemini API error ({}): {}", error.code, error.message),
        });
        return events;
    }

    // Update token usage
    if let Some(ref usage) = chunk.usage_metadata {
        state.acc.input_tokens = u64::from(usage.prompt_token_count);
        state.acc.output_tokens = u64::from(usage.candidates_token_count);
        state.acc.cache_read_tokens = u64::from(usage.cached_content_token_count);
        state.acc.reasoning_output_tokens = u64::from(usage.thoughts_token_count);
        state.tool_use_prompt_tokens = u64::from(usage.tool_use_prompt_token_count);
        state.total_tokens = u64::from(usage.total_token_count);
    }

    // Process candidates
    let Some(ref candidates) = chunk.candidates else {
        return events;
    };
    let Some(candidate) = candidates.first() else {
        return events;
    };

    // Process content parts
    if let Some(ref content) = candidate.content {
        for part in &content.parts {
            events.extend(process_part(part, state));
        }
    }

    // Handle finish reason
    if let Some(ref finish_reason) = candidate.finish_reason {
        events.extend(handle_finish(
            finish_reason,
            candidate.safety_ratings.as_deref(),
            state,
        ));
    }

    events
}

/// Process a single content part.
fn process_part(part: &GeminiPart, state: &mut StreamState) -> Vec<StreamEvent> {
    match part {
        GeminiPart::Text {
            text,
            thought,
            thought_signature: _,
        } => {
            if *thought == Some(true) {
                process_thinking_text(text, state)
            } else {
                process_regular_text(text, state)
            }
        }
        GeminiPart::FunctionCall {
            function_call,
            thought_signature,
        } => process_function_call(function_call, thought_signature.as_deref(), state),
        _ => vec![],
    }
}

/// Process a thinking/reasoning text part.
fn process_thinking_text(text: &str, state: &mut StreamState) -> Vec<StreamEvent> {
    state.acc.process_thinking_delta(text)
}

/// Process a regular (non-thinking) text part.
fn process_regular_text(text: &str, state: &mut StreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    // Transition from thinking to text
    events.extend(state.acc.close_thinking(None));

    events.extend(state.acc.process_text_delta(text));

    events
}

/// Process a function call part.
fn process_function_call(
    fc: &super::types::FunctionCallData,
    thought_signature: Option<&str>,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if state.capability_invocations.len() >= MAX_PROVIDER_STREAM_TOOL_INVOCATIONS {
        return vec![StreamEvent::Error {
            error: format!(
                "provider stream capability invocations exceeded {} item limit",
                MAX_PROVIDER_STREAM_TOOL_INVOCATIONS
            ),
        }];
    }

    let id = format!(
        "call_{}_{}",
        state.unique_prefix, state.capability_invocation_index
    );
    state.capability_invocation_index += 1;

    let args_str = serde_json::to_string(&fc.args).unwrap_or_else(|_| "{}".into());
    if let Err(error) = check_stream_field_bytes(
        &args_str,
        MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES,
        "capability arguments",
    ) {
        return vec![stream_limit_error_event(error)];
    }
    let ctx = CapabilityCallContext {
        invocation_id: Some(id.clone()),
        model_primitive_name: Some(fc.name.clone()),
        provider: Some("google".into()),
    };
    let arguments: Map<String, serde_json::Value> =
        match parse_capability_call_arguments(Some(&args_str), Some(&ctx)) {
            Ok(arguments) => arguments,
            Err(error) => {
                return vec![StreamEvent::Error {
                    error: error.to_string(),
                }];
            }
        };

    events.push(StreamEvent::CapabilityInvocationDraftStart {
        invocation_id: id.clone(),
        name: fc.name.clone(),
    });

    events.push(StreamEvent::CapabilityInvocationDraftDelta {
        invocation_id: id.clone(),
        arguments_delta: args_str,
    });

    let capability_invocation =
        CapabilityInvocationDraft::new(id.clone(), fc.name.clone(), arguments.clone());
    let capability_invocation = if let Some(sig) = thought_signature {
        capability_invocation.with_thought_signature(sig)
    } else {
        capability_invocation
    };

    events.push(StreamEvent::CapabilityInvocationDraftEnd {
        capability_invocation,
    });

    state
        .capability_invocations
        .push(CapabilityInvocationDraftState {
            id,
            name: fc.name.clone(),
            args: fc.args.clone(),
            thought_signature: thought_signature.map(String::from),
        });

    events
}

/// Handle a finish reason from the API.
fn handle_finish(
    finish_reason: &str,
    safety_ratings: Option<&[SafetyRating]>,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    // End thinking if still active
    events.extend(state.acc.close_thinking(None));

    // Handle safety block
    if finish_reason == "SAFETY"
        && let Some(ratings) = safety_ratings
    {
        let blocked: Vec<String> = ratings
            .iter()
            .filter(|r| {
                r.probability == HarmProbability::High || r.probability == HarmProbability::Medium
            })
            .map(|r| format!("{:?}", r.category))
            .collect();

        if !blocked.is_empty() {
            events.push(StreamEvent::SafetyBlock {
                blocked_categories: blocked.clone(),
                error: format!("Response blocked by safety filter: {}", blocked.join(", ")),
            });
        }
    }

    // End text if active
    events.extend(state.acc.close_text(None));

    // Build assistant content blocks
    let mut content = Vec::new();
    if !state.acc.accumulated_thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: state.acc.accumulated_thinking.clone(),
            signature: None,
        });
    }
    if !state.acc.accumulated_text.is_empty() {
        content.push(AssistantContent::text(&state.acc.accumulated_text));
    }

    // Add capability invocations as CapabilityInvocation content blocks
    for tc in &state.capability_invocations {
        let arguments: Map<String, serde_json::Value> = match &tc.args {
            serde_json::Value::Object(map) => map.clone(),
            _ => Map::new(),
        };
        content.push(AssistantContent::CapabilityInvocation {
            id: tc.id.clone(),
            name: tc.name.clone(),
            arguments,
            thought_signature: tc.thought_signature.clone(),
        });
    }

    let stop_reason = map_google_stop_reason(finish_reason);

    events.push(StreamEvent::Done {
        message: AssistantMessage {
            content,
            token_usage: Some(TokenUsage {
                input_tokens: state.acc.input_tokens,
                output_tokens: state.acc.output_tokens,
                cache_read_tokens: nonzero(state.acc.cache_read_tokens),
                cached_input_tokens: nonzero(state.acc.cache_read_tokens),
                cache_creation_tokens: None,
                cache_creation_5m_tokens: None,
                cache_creation_1h_tokens: None,
                reasoning_output_tokens: None,
                thought_tokens: nonzero(state.acc.reasoning_output_tokens),
                tool_use_prompt_tokens: nonzero(state.tool_use_prompt_tokens),
                total_tokens: nonzero(state.total_tokens),
                provider_type: Some(Provider::Google),
            }),
        },
        stop_reason: stop_reason.into(),
    });

    events
}

fn nonzero(value: u64) -> Option<u64> {
    (value > 0).then_some(value)
}

/// Synthesize a done event when the stream ends without a finish reason.
pub fn synthesize_done_event(state: &mut StreamState) -> Vec<StreamEvent> {
    let finish_reason = if state.capability_invocations.is_empty() {
        "STOP"
    } else {
        "TOOL_USE"
    };
    handle_finish(finish_reason, None, state)
}

/// Map a Gemini finish reason to a unified stop reason string.
fn map_google_stop_reason(reason: &str) -> &'static str {
    match reason {
        "MAX_TOKENS" => "max_tokens",
        "TOOL_USE" => "capability_invocation",
        _ => "end_turn",
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests;
