//! # `OpenAI` Stream Handler
//!
//! SSE event state machine for the `OpenAI` Responses API.
//!
//! Converts Responses API SSE events into unified [`StreamEvent`]s:
//! - `response.output_text.delta` → `TextStart` + `TextDelta`
//! - `response.output_item.added` (`function_call`) → `CapabilityInvocationDraftStart`
//! - `response.function_call_arguments.delta` → `CapabilityInvocationDraftDelta`
//! - `response.reasoning_text.delta` → `ThinkingStart` + `ThinkingDelta` (full reasoning)
//! - `response.reasoning_summary_text.delta` → `ThinkingStart` + `ThinkingDelta` (summary delta)
//! - `response.completed` → `ThinkingEnd`, `TextEnd`, `CapabilityInvocationDraftEnd`, `Done`
//!
//! Delegates text/thinking delta accumulation to [`StreamAccumulator`] from the
//! shared `stream_common` module. OpenAI-specific reasoning dedup and capability invocation
//! handling (HashMap-based, with fail-closed provider argument parsing) stays here.

use std::collections::{HashMap, HashSet};

use super::types::{OutputItemType, ResponsesSseEvent, SseEventType};
use crate::domains::model::providers::shared::stream_common::StreamAccumulator;
use crate::domains::model::providers::{
    CapabilityArgumentParseError, CapabilityCallContext, parse_capability_call_arguments,
};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
use crate::shared::protocol::messages::{CapabilityInvocationDraft, TokenUsage};

/// State for tracking accumulated stream content.
#[derive(Clone, Debug)]
pub struct StreamState {
    /// Shared delta accumulator for text, thinking, and token tracking.
    pub acc: StreamAccumulator,
    /// Capability invocations by `call_id` → (id, name, `accumulated_args`).
    pub capability_invocations: HashMap<String, CapabilityInvocationDraftState>,
    /// Whether a provider argument parse error has already made the stream terminal.
    pub capability_argument_failed: bool,
    /// Deduplication set for reasoning text.
    pub seen_thinking_texts: HashSet<String>,
    /// Whether we received full reasoning text (vs only summary).
    pub has_reasoning_text: bool,
}

/// State for an individual capability invocation being accumulated.
#[derive(Clone, Debug)]
pub struct CapabilityInvocationDraftState {
    /// Call ID.
    pub id: String,
    /// Capability name.
    pub name: String,
    /// Accumulated JSON arguments string.
    pub args: String,
}

/// Create a fresh stream state.
#[must_use]
pub fn create_stream_state() -> StreamState {
    StreamState {
        acc: StreamAccumulator::new(),
        capability_invocations: HashMap::new(),
        capability_argument_failed: false,
        seen_thinking_texts: HashSet::new(),
        has_reasoning_text: false,
    }
}

/// Process a single SSE event and return corresponding [`StreamEvent`]s.
#[must_use]
pub fn process_stream_event(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    match event.event_type {
        SseEventType::OutputTextDelta => handle_content_part_delta(event, state),
        SseEventType::OutputItemAdded => handle_output_item_added(event, state),
        SseEventType::OutputItemDone => handle_output_item_done(event, state),
        SseEventType::ReasoningSummaryPartAdded => handle_reasoning_summary_part_added(state),
        SseEventType::ReasoningTextDelta => handle_reasoning_text_delta(event, state),
        SseEventType::ReasoningSummaryTextDelta => {
            handle_reasoning_summary_text_delta(event, state)
        }
        SseEventType::FunctionCallArgsDelta => handle_function_call_args_delta(event, state),
        SseEventType::Completed => handle_response_completed(event, state),
        SseEventType::Unknown => Vec::new(),
    }
}

/// Handle `response.output_text.delta` — emit `TextStart` on first delta, then `TextDelta`.
fn handle_content_part_delta(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    if let Some(delta) = &event.delta {
        state.acc.process_text_delta(delta)
    } else {
        Vec::new()
    }
}

/// Handle `response.output_item.added` — start capability invocations or reasoning items.
fn handle_output_item_added(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if let Some(item) = &event.item {
        if item.item_type == OutputItemType::FunctionCall {
            if let Some(call_id) = &item.call_id {
                let name = item.name.clone().unwrap_or_default();
                let initial_args = item.arguments.clone().unwrap_or_default();
                let is_new = !state.capability_invocations.contains_key(call_id.as_str());
                if let Some(existing) = state.capability_invocations.get_mut(call_id.as_str()) {
                    if existing.name.is_empty() {
                        existing.name.clone_from(&name);
                    }
                    if existing.args.is_empty() && !initial_args.is_empty() {
                        existing.args = initial_args;
                    }
                } else {
                    let _ = state.capability_invocations.insert(
                        call_id.clone(),
                        CapabilityInvocationDraftState {
                            id: call_id.clone(),
                            name: name.clone(),
                            args: initial_args,
                        },
                    );
                }
                if is_new {
                    events.push(StreamEvent::CapabilityInvocationDraftStart {
                        invocation_id: call_id.clone(),
                        name,
                    });
                }
            }
        } else if item.item_type == OutputItemType::Reasoning && !state.acc.thinking_started {
            state.acc.thinking_started = true;
            events.push(StreamEvent::ThinkingStart);
        }
    }
    events
}

/// Handle `response.reasoning_summary_part.added` — emit `ThinkingStart` if not yet started.
fn handle_reasoning_summary_part_added(state: &mut StreamState) -> Vec<StreamEvent> {
    state.acc.mark_thinking_started().into_iter().collect()
}

/// Handle `response.reasoning_text.delta` — full reasoning content, preferred over summary.
fn handle_reasoning_text_delta(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if let Some(delta) = &event.delta {
        if !state.has_reasoning_text {
            state.has_reasoning_text = true;
            if !state.acc.accumulated_thinking.is_empty() {
                state.acc.accumulated_thinking.clear();
            }
        }
        events.extend(state.acc.process_thinking_delta(delta));
    }
    events
}

/// Handle `response.reasoning_summary_text.delta` when full reasoning is unavailable.
fn handle_reasoning_summary_text_delta(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    if state.has_reasoning_text {
        return Vec::new();
    }
    if let Some(delta) = &event.delta
        && !state.seen_thinking_texts.contains(delta.as_str())
    {
        let _ = state.seen_thinking_texts.insert(delta.clone());
        state.acc.process_thinking_delta(delta)
    } else {
        Vec::new()
    }
}

/// Handle `response.function_call_arguments.delta` — accumulate capability invocation arguments.
fn handle_function_call_args_delta(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if let (Some(call_id), Some(delta)) = (&event.call_id, &event.delta) {
        let tc = state
            .capability_invocations
            .entry(call_id.clone())
            .or_insert_with(|| CapabilityInvocationDraftState {
                id: call_id.clone(),
                name: String::new(),
                args: String::new(),
            });
        tc.args.push_str(delta);
        events.push(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: call_id.clone(),
            arguments_delta: delta.clone(),
        });
    }
    events
}

/// Handle `response.completed` — delegate to final event processing.
fn handle_response_completed(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    process_completed_response(event, state)
}

/// Handle `response.output_item.done` — extract reasoning summary if not already streamed.
fn handle_output_item_done(event: &ResponsesSseEvent, state: &mut StreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    let Some(item) = &event.item else {
        return events;
    };
    if item.item_type == OutputItemType::FunctionCall {
        merge_function_call_item(item, state);
        match capability_invocation_from_item_state(item, state) {
            Ok(Some(capability_invocation)) => {
                events.push(StreamEvent::CapabilityInvocationDraftEnd {
                    capability_invocation,
                });
            }
            Ok(None) => {}
            Err(error) => {
                state.capability_argument_failed = true;
                events.push(StreamEvent::Error {
                    error: error.to_string(),
                });
            }
        }
        return events;
    }

    // Only process reasoning items with summary content not already streamed.
    if item.item_type != OutputItemType::Reasoning
        || item.summary.is_none()
        || !state.acc.accumulated_thinking.is_empty()
        || state.has_reasoning_text
    {
        return events;
    }
    events.extend(state.acc.mark_thinking_started());
    if let Some(summary) = &item.summary {
        for part in summary {
            if part.content_type == "summary_text"
                && let Some(text) = &part.text
            {
                let _ = state.seen_thinking_texts.insert(text.clone());
                if let Some(error) = state.acc.accumulate_thinking(text) {
                    events.push(error);
                    return events;
                }
                events.push(StreamEvent::ThinkingDelta {
                    delta: text.clone(),
                });
            }
        }
    }
    events
}

fn capability_invocation_from_item_state(
    item: &super::types::ResponsesOutputItem,
    state: &StreamState,
) -> Result<Option<CapabilityInvocationDraft>, CapabilityArgumentParseError> {
    let Some(call_id) = item.call_id.as_ref() else {
        return Ok(None);
    };
    let Some(tc) = state.capability_invocations.get(call_id.as_str()) else {
        return Ok(None);
    };
    if tc.id.is_empty() || tc.name.is_empty() {
        return Ok(None);
    }
    let arguments = parse_openai_capability_arguments(tc)?;
    Ok(Some(CapabilityInvocationDraft::new(
        tc.id.clone(),
        tc.name.clone(),
        arguments,
    )))
}

/// Process the `response.completed` event and emit final events.
fn process_completed_response(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    let Some(response) = &event.response else {
        return events;
    };

    // Extract usage
    if let Some(usage) = &response.usage {
        state.acc.input_tokens = usage.input_tokens;
        state.acc.output_tokens = usage.output_tokens;
        state.acc.cache_read_tokens = usage.input_tokens_details.cached_tokens;
        state.acc.reasoning_output_tokens = usage.output_tokens_details.reasoning_tokens;
        state.acc.total_tokens = usage.total_tokens;
    }

    // Process output items from completed response
    merge_completed_output_items(response, state, &mut events);

    // Emit thinking_end if we had thinking
    events.extend(state.acc.close_thinking(None));

    // Emit text_end if we had text
    events.extend(state.acc.close_text(None));

    // Emit toolcall_end for each capability invocation
    for tc in state.capability_invocations.values() {
        if !tc.id.is_empty() && !tc.name.is_empty() {
            match parse_openai_capability_arguments(tc) {
                Ok(arguments) => {
                    events.push(StreamEvent::CapabilityInvocationDraftEnd {
                        capability_invocation: CapabilityInvocationDraft::new(
                            tc.id.clone(),
                            tc.name.clone(),
                            arguments,
                        ),
                    });
                }
                Err(error) => {
                    state.capability_argument_failed = true;
                    events.push(StreamEvent::Error {
                        error: error.to_string(),
                    });
                }
            }
        }
    }

    // Build final done event
    if !state.capability_argument_failed {
        events.push(build_done_event(state));
    }

    events
}

/// Merge output items from the completed response into stream state.
fn merge_completed_output_items(
    response: &super::types::ResponsesResponse,
    state: &mut StreamState,
    events: &mut Vec<StreamEvent>,
) {
    for item in &response.output {
        match item.item_type {
            OutputItemType::Message => merge_message_item(item, state),
            OutputItemType::Reasoning => merge_reasoning_item(item, state, events),
            OutputItemType::FunctionCall => merge_function_call_item(item, state),
            OutputItemType::Unknown => {}
        }
    }
}

/// Merge a message output item — capture text if not yet started.
fn merge_message_item(item: &super::types::ResponsesOutputItem, state: &mut StreamState) {
    if let Some(content) = &item.content {
        for c in content {
            if c.content_type == "output_text"
                && let Some(text) = &c.text
                && !state.acc.text_started
            {
                state.acc.text_started = true;
                state.acc.accumulated_text.clone_from(text);
            }
        }
    }
}

/// Merge a reasoning output item — use summary if no streaming deltas received.
fn merge_reasoning_item(
    item: &super::types::ResponsesOutputItem,
    state: &mut StreamState,
    events: &mut Vec<StreamEvent>,
) {
    if !state.acc.accumulated_thinking.is_empty() || state.has_reasoning_text {
        return;
    }
    if let Some(summary) = &item.summary {
        for s in summary {
            if s.content_type == "summary_text"
                && let Some(text) = &s.text
            {
                events.extend(state.acc.mark_thinking_started());
                state.acc.accumulated_thinking.clone_from(text);
            }
        }
    }
}

/// Merge a `function_call` output item — update or insert capability invocation state.
fn merge_function_call_item(item: &super::types::ResponsesOutputItem, state: &mut StreamState) {
    let Some(call_id) = &item.call_id else {
        return;
    };
    if let Some(existing) = state.capability_invocations.get_mut(call_id.as_str()) {
        if let Some(arguments) = &item.arguments
            && existing.args.is_empty()
        {
            existing.args.clone_from(arguments);
        }
        if let Some(name) = &item.name
            && existing.name.is_empty()
        {
            existing.name.clone_from(name);
        }
    } else {
        let _ = state.capability_invocations.insert(
            call_id.clone(),
            CapabilityInvocationDraftState {
                id: call_id.clone(),
                name: item.name.clone().unwrap_or_default(),
                args: item.arguments.clone().unwrap_or_default(),
            },
        );
    }
}

/// Build the final `Done` event with the complete message.
fn build_done_event(state: &StreamState) -> StreamEvent {
    let mut content: Vec<AssistantContent> = Vec::new();
    let mut has_valid_capability_invocation = false;

    if !state.acc.accumulated_thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: state.acc.accumulated_thinking.clone(),
            signature: None,
        });
    }

    if !state.acc.accumulated_text.is_empty() {
        content.push(AssistantContent::text(&state.acc.accumulated_text));
    }

    for tc in state.capability_invocations.values() {
        if !tc.id.is_empty() && !tc.name.is_empty() {
            if let Ok(arguments) = parse_openai_capability_arguments(tc) {
                has_valid_capability_invocation = true;
                content.push(AssistantContent::CapabilityInvocation {
                    id: tc.id.clone(),
                    name: tc.name.clone(),
                    arguments,
                    thought_signature: None,
                });
            }
        }
    }

    let stop_reason = if has_valid_capability_invocation {
        "capability_invocation"
    } else {
        "end_turn"
    };

    StreamEvent::Done {
        message: AssistantMessage {
            content,
            token_usage: Some(TokenUsage {
                input_tokens: state.acc.input_tokens,
                output_tokens: state.acc.output_tokens,
                cache_read_tokens: nonzero(state.acc.cache_read_tokens),
                cached_input_tokens: nonzero(state.acc.cache_read_tokens),
                reasoning_output_tokens: nonzero(state.acc.reasoning_output_tokens),
                total_tokens: nonzero(state.acc.total_tokens),
                provider_type: Some(crate::shared::protocol::messages::Provider::OpenAi),
                ..TokenUsage::default()
            }),
        },
        stop_reason: stop_reason.into(),
    }
}

fn nonzero(value: u64) -> Option<u64> {
    (value > 0).then_some(value)
}

fn parse_openai_capability_arguments(
    tc: &CapabilityInvocationDraftState,
) -> Result<serde_json::Map<String, serde_json::Value>, CapabilityArgumentParseError> {
    let ctx = CapabilityCallContext {
        invocation_id: Some(tc.id.clone()),
        model_primitive_name: Some(tc.name.clone()),
        provider: Some("openai".into()),
    };
    parse_capability_call_arguments(Some(&tc.args), Some(&ctx))
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests;
