//! # `OpenAI` Stream Handler
//!
//! SSE event state machine for the `OpenAI` Responses API.
//!
//! Converts Responses API SSE events into unified [`StreamEvent`]s:
//! - `response.output_text.delta` → `TextStart` + `TextDelta`
//! - `response.output_item.added` (`function_call`) → `ToolInvocationDraftStart`
//! - `response.function_call_arguments.delta` → `ToolInvocationDraftDelta`
//! - `response.reasoning_text.delta` → `ThinkingStart` + `ThinkingDelta` (full reasoning)
//! - `response.reasoning_summary_text.delta` → `ThinkingStart` + `ThinkingDelta` (summary delta)
//! - `response.completed` → `ThinkingEnd`, `TextEnd`, `ToolInvocationDraftEnd`, `Done`
//! - `response.incomplete` → the same terminal lifecycle with a normalized incomplete stop reason
//! - `response.failed` / `error` → typed [`ProviderError`] values
//!
//! Delegates text/thinking delta accumulation to [`StreamAccumulator`] from the
//! shared `stream_common` module. OpenAI-specific reasoning dedup and tool invocation
//! handling (first-seen call ordering plus fail-closed provider argument parsing) stays here.

use std::collections::{HashMap, HashSet};

use super::types::{OutputItemType, ResponsesError, ResponsesSseEvent, SseEventType};
use crate::domains::model::providers::shared::provider::{ProviderError, ProviderResult};
use crate::domains::model::providers::shared::stream_common::StreamAccumulator;
use crate::domains::model::providers::{
    ToolArgumentParseError, ToolCallContext, parse_tool_call_arguments,
};
use crate::shared::protocol::content::{AssistantContent, ThinkingContentKind};
use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
use crate::shared::protocol::messages::{TokenUsage, ToolInvocationDraft};

/// State for tracking accumulated stream content.
#[derive(Clone, Debug)]
pub struct StreamState {
    /// Shared delta accumulator for text, thinking, and token tracking.
    pub acc: StreamAccumulator,
    /// Tool invocations by `call_id` → (id, name, `accumulated_args`).
    pub tool_invocations: HashMap<String, ToolInvocationDraftState>,
    /// First-seen order for tool call IDs.
    pub tool_invocation_order: Vec<String>,
    /// Whether a provider argument parse error has already made the stream terminal.
    pub tool_argument_failed: bool,
    /// Deduplication set for reasoning text.
    pub seen_thinking_texts: HashSet<String>,
    /// Whether we received full reasoning text (vs only summary).
    pub has_reasoning_text: bool,
    /// Source contract for the currently accumulated thinking-like content.
    pub thinking_kind: ThinkingContentKind,
    /// Whether the next streamed reasoning-summary delta starts a new summary part.
    pub reasoning_summary_pending_separator: bool,
}

/// State for an individual tool invocation being accumulated.
#[derive(Clone, Debug)]
pub struct ToolInvocationDraftState {
    /// Call ID.
    pub id: String,
    /// Tool name.
    pub name: String,
    /// Accumulated JSON arguments string.
    pub args: String,
}

/// Create a fresh stream state.
#[must_use]
pub fn create_stream_state() -> StreamState {
    StreamState {
        acc: StreamAccumulator::new(),
        tool_invocations: HashMap::new(),
        tool_invocation_order: Vec::new(),
        tool_argument_failed: false,
        seen_thinking_texts: HashSet::new(),
        has_reasoning_text: false,
        thinking_kind: ThinkingContentKind::Thinking,
        reasoning_summary_pending_separator: false,
    }
}

/// Process one provider SSE event, retaining failed terminal responses as
/// provider-native errors instead of transient canonical stream events.
#[must_use]
pub(super) fn process_provider_stream_event(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> ProviderResult<Vec<StreamEvent>> {
    match event.event_type {
        SseEventType::Failed | SseEventType::Error => Err(provider_terminal_error(event)),
        _ => Ok(process_stream_event(event, state)),
    }
}

/// Process a non-failing SSE event and return corresponding [`StreamEvent`]s.
fn process_stream_event(event: &ResponsesSseEvent, state: &mut StreamState) -> Vec<StreamEvent> {
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
        SseEventType::Incomplete => handle_response_incomplete(event, state),
        SseEventType::Failed | SseEventType::Error | SseEventType::Unknown => Vec::new(),
    }
}

fn provider_terminal_error(event: &ResponsesSseEvent) -> ProviderError {
    let (code, message) = match event.event_type {
        SseEventType::Failed => event
            .response
            .as_ref()
            .and_then(|response| response.error.as_ref().map(provider_error_parts)),
        SseEventType::Error => {
            let nested = event.error.as_ref().map(provider_error_parts);
            Some((
                event
                    .code
                    .clone()
                    .or_else(|| nested.as_ref().and_then(|(code, _)| code.clone())),
                event
                    .message
                    .clone()
                    .filter(|message| !message.trim().is_empty())
                    .or_else(|| nested.map(|(_, message)| message))
                    .unwrap_or_default(),
            ))
        }
        _ => None,
    }
    .unwrap_or_else(|| (None, String::new()));
    let message = if message.trim().is_empty() {
        match event.event_type {
            SseEventType::Failed => "OpenAI response failed without error details",
            _ => "OpenAI stream reported an error without details",
        }
        .to_owned()
    } else {
        message
    };
    if code.as_deref() == Some("rate_limit_exceeded") {
        return ProviderError::RateLimited {
            retry_after_ms: 0,
            message,
            code,
        };
    }
    let retryable = matches!(
        code.as_deref(),
        Some("server_error" | "vector_store_timeout")
    );
    ProviderError::StreamApi {
        message,
        code,
        retryable,
    }
}

fn provider_error_parts(error: &ResponsesError) -> (Option<String>, String) {
    (
        error.code.clone().or_else(|| error.error_type.clone()),
        error.message.clone(),
    )
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

/// Handle `response.output_item.added` — start tool invocations or reasoning items.
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
                let is_new = !state.tool_invocations.contains_key(call_id.as_str());
                if is_new {
                    state.tool_invocation_order.push(call_id.clone());
                }
                if let Some(existing) = state.tool_invocations.get_mut(call_id.as_str()) {
                    if existing.name.is_empty() {
                        existing.name.clone_from(&name);
                    }
                    if existing.args.is_empty() && !initial_args.is_empty() {
                        existing.args = initial_args;
                    }
                } else {
                    let _ = state.tool_invocations.insert(
                        call_id.clone(),
                        ToolInvocationDraftState {
                            id: call_id.clone(),
                            name: name.clone(),
                            args: initial_args,
                        },
                    );
                }
                if is_new {
                    events.push(StreamEvent::ToolInvocationDraftStart {
                        invocation_id: call_id.clone(),
                        name,
                    });
                }
            }
        }
    }
    events
}

/// Handle `response.reasoning_summary_part.added` without exposing an empty thinking lifecycle.
fn handle_reasoning_summary_part_added(state: &mut StreamState) -> Vec<StreamEvent> {
    if !state.acc.accumulated_thinking.is_empty() {
        state.reasoning_summary_pending_separator = true;
    }
    Vec::new()
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
            state.thinking_kind = ThinkingContentKind::Thinking;
            state.reasoning_summary_pending_separator = false;
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
        state.thinking_kind = ThinkingContentKind::ReasoningSummary;
        let delta = streamed_reasoning_summary_delta(state, delta);
        state
            .acc
            .process_thinking_delta_with_kind(&delta, ThinkingContentKind::ReasoningSummary)
    } else {
        Vec::new()
    }
}

/// Handle `response.function_call_arguments.delta` — accumulate tool invocation arguments.
fn handle_function_call_args_delta(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if let (Some(call_id), Some(delta)) = (&event.call_id, &event.delta) {
        let tc = state
            .tool_invocations
            .entry(call_id.clone())
            .or_insert_with(|| ToolInvocationDraftState {
                id: call_id.clone(),
                name: String::new(),
                args: String::new(),
            });
        if !state.tool_invocation_order.iter().any(|id| id == call_id) {
            state.tool_invocation_order.push(call_id.clone());
        }
        tc.args.push_str(delta);
        events.push(StreamEvent::ToolInvocationDraftDelta {
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
    process_terminal_response(event, state, None)
}

/// Handle `response.incomplete` as a terminal partial result.
fn handle_response_incomplete(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let stop_reason = event
        .response
        .as_ref()
        .and_then(|response| response.incomplete_details.as_ref())
        .and_then(|details| details.reason.as_deref())
        .map_or("incomplete", |reason| match reason {
            "max_output_tokens" => "max_tokens",
            "content_filter" => "refusal",
            _ => "incomplete",
        });
    process_terminal_response(event, state, Some(stop_reason))
}

/// Handle `response.output_item.done` — extract reasoning summary if not already streamed.
fn handle_output_item_done(event: &ResponsesSseEvent, state: &mut StreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    let Some(item) = &event.item else {
        return events;
    };
    if item.item_type == OutputItemType::FunctionCall {
        merge_function_call_item(item, state);
        match tool_invocation_from_item_state(item, state) {
            Ok(Some(tool_invocation)) => {
                events.push(StreamEvent::ToolInvocationDraftEnd { tool_invocation });
            }
            Ok(None) => {}
            Err(error) => {
                state.tool_argument_failed = true;
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
    if let Some(summary) = &item.summary {
        for part in summary {
            if part.content_type == "summary_text"
                && let Some(text) = &part.text
                && !text.is_empty()
            {
                events.extend(state.acc.mark_thinking_started());
                let _ = state.seen_thinking_texts.insert(text.clone());
                state.thinking_kind = ThinkingContentKind::ReasoningSummary;
                let delta = reasoning_summary_part_delta(&state.acc.accumulated_thinking, text);
                if let Some(error) = state.acc.accumulate_thinking(&delta) {
                    events.push(error);
                    return events;
                }
                events.push(StreamEvent::ThinkingDelta {
                    delta,
                    kind: ThinkingContentKind::ReasoningSummary,
                });
            }
        }
    }
    events
}

fn tool_invocation_from_item_state(
    item: &super::types::ResponsesOutputItem,
    state: &StreamState,
) -> Result<Option<ToolInvocationDraft>, ToolArgumentParseError> {
    let Some(call_id) = item.call_id.as_ref() else {
        return Ok(None);
    };
    let Some(tc) = state.tool_invocations.get(call_id.as_str()) else {
        return Ok(None);
    };
    if tc.id.is_empty() || tc.name.is_empty() {
        return Ok(None);
    }
    let arguments = parse_openai_tool_arguments(tc)?;
    Ok(Some(ToolInvocationDraft::new(
        tc.id.clone(),
        tc.name.clone(),
        arguments,
    )))
}

/// Process the `response.completed` event and emit final events.
fn process_terminal_response(
    event: &ResponsesSseEvent,
    state: &mut StreamState,
    stop_reason_override: Option<&str>,
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
    events.extend(
        state
            .acc
            .close_thinking_with_kind(None, state.thinking_kind),
    );

    // Emit text_end if we had text
    events.extend(state.acc.close_text(None));

    // Emit toolcall_end for each tool invocation
    for call_id in &state.tool_invocation_order {
        if let Some(tc) = state.tool_invocations.get(call_id.as_str())
            && !tc.id.is_empty()
            && !tc.name.is_empty()
        {
            match parse_openai_tool_arguments(tc) {
                Ok(arguments) => {
                    events.push(StreamEvent::ToolInvocationDraftEnd {
                        tool_invocation: ToolInvocationDraft::new(
                            tc.id.clone(),
                            tc.name.clone(),
                            arguments,
                        ),
                    });
                }
                Err(error) => {
                    state.tool_argument_failed = true;
                    events.push(StreamEvent::Error {
                        error: error.to_string(),
                    });
                }
            }
        }
    }

    // Build final done event
    if !state.tool_argument_failed {
        events.push(build_done_event(state, response, stop_reason_override));
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
        let thinking = join_reasoning_summary_parts(summary.iter().filter_map(|part| {
            (part.content_type == "summary_text")
                .then_some(part.text.as_deref())
                .flatten()
        }));
        if !thinking.is_empty() {
            events.extend(state.acc.mark_thinking_started());
            state.acc.accumulated_thinking = thinking;
        }
    }
}

/// Merge a `function_call` output item — update or insert tool invocation state.
fn merge_function_call_item(item: &super::types::ResponsesOutputItem, state: &mut StreamState) {
    let Some(call_id) = &item.call_id else {
        return;
    };
    if !state.tool_invocation_order.iter().any(|id| id == call_id) {
        state.tool_invocation_order.push(call_id.clone());
    }
    if let Some(existing) = state.tool_invocations.get_mut(call_id.as_str()) {
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
        let _ = state.tool_invocations.insert(
            call_id.clone(),
            ToolInvocationDraftState {
                id: call_id.clone(),
                name: item.name.clone().unwrap_or_default(),
                args: item.arguments.clone().unwrap_or_default(),
            },
        );
    }
}

/// Build the final `Done` event with the complete message.
fn build_done_event(
    state: &StreamState,
    response: &super::types::ResponsesResponse,
    stop_reason_override: Option<&str>,
) -> StreamEvent {
    let mut content: Vec<AssistantContent> = Vec::new();
    let mut has_valid_tool_invocation = false;
    let mut saw_reasoning_item = false;
    let mut saw_message_item = false;
    let mut emitted_thinking_snapshots: HashSet<String> = HashSet::new();

    for item in &response.output {
        match item.item_type {
            OutputItemType::Reasoning => {
                saw_reasoning_item = true;
                let thinking = if state.acc.accumulated_thinking.is_empty() {
                    item.summary
                        .as_ref()
                        .map(|summary| {
                            join_reasoning_summary_parts(summary.iter().filter_map(|part| {
                                (part.content_type == "summary_text")
                                    .then_some(part.text.as_deref())
                                    .flatten()
                            }))
                        })
                        .unwrap_or_default()
                } else {
                    state.acc.accumulated_thinking.clone()
                };
                if !thinking.is_empty()
                    && emitted_thinking_snapshots.insert(normalize_thinking_snapshot(&thinking))
                {
                    content.push(AssistantContent::Thinking {
                        thinking,
                        kind: if state.has_reasoning_text {
                            ThinkingContentKind::Thinking
                        } else {
                            ThinkingContentKind::ReasoningSummary
                        },
                        signature: None,
                    });
                }
            }
            OutputItemType::Message => {
                saw_message_item = true;
                let text = item
                    .content
                    .as_ref()
                    .map(|parts| {
                        parts
                            .iter()
                            .filter(|part| part.content_type == "output_text")
                            .filter_map(|part| part.text.as_deref())
                            .collect::<Vec<_>>()
                            .join("")
                    })
                    .unwrap_or_default();
                let text = if text.is_empty() {
                    state.acc.accumulated_text.as_str()
                } else {
                    text.as_str()
                };
                if !text.is_empty() {
                    content.push(AssistantContent::text(text));
                }
            }
            OutputItemType::FunctionCall => {
                if let Some(call_id) = item.call_id.as_ref()
                    && let Some(tc) = state.tool_invocations.get(call_id.as_str())
                    && !tc.id.is_empty()
                    && !tc.name.is_empty()
                    && let Ok(arguments) = parse_openai_tool_arguments(tc)
                {
                    has_valid_tool_invocation = true;
                    content.push(AssistantContent::ToolInvocation {
                        id: tc.id.clone(),
                        name: tc.name.clone(),
                        arguments,
                        thought_signature: None,
                    });
                }
            }
            OutputItemType::Unknown => {}
        }
    }

    if !saw_reasoning_item && !state.acc.accumulated_thinking.is_empty() {
        let thinking = state.acc.accumulated_thinking.clone();
        if emitted_thinking_snapshots.insert(normalize_thinking_snapshot(&thinking)) {
            content.insert(
                0,
                AssistantContent::Thinking {
                    thinking,
                    kind: state.thinking_kind,
                    signature: None,
                },
            );
        }
    }

    if !saw_message_item && !state.acc.accumulated_text.is_empty() {
        content.push(AssistantContent::text(&state.acc.accumulated_text));
    }

    if content.is_empty() {
        if !state.acc.accumulated_thinking.is_empty() {
            content.push(AssistantContent::Thinking {
                thinking: state.acc.accumulated_thinking.clone(),
                kind: state.thinking_kind,
                signature: None,
            });
        }
        if !state.acc.accumulated_text.is_empty() {
            content.push(AssistantContent::text(&state.acc.accumulated_text));
        }
        for call_id in &state.tool_invocation_order {
            if let Some(tc) = state.tool_invocations.get(call_id.as_str())
                && !tc.id.is_empty()
                && !tc.name.is_empty()
                && let Ok(arguments) = parse_openai_tool_arguments(tc)
            {
                has_valid_tool_invocation = true;
                content.push(AssistantContent::ToolInvocation {
                    id: tc.id.clone(),
                    name: tc.name.clone(),
                    arguments,
                    thought_signature: None,
                });
            }
        }
    }

    let stop_reason = if has_valid_tool_invocation {
        "tool_invocation"
    } else {
        stop_reason_override.unwrap_or("end_turn")
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

fn normalize_thinking_snapshot(thinking: &str) -> String {
    thinking.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn streamed_reasoning_summary_delta(state: &mut StreamState, delta: &str) -> String {
    if state.reasoning_summary_pending_separator {
        state.reasoning_summary_pending_separator = false;
        reasoning_summary_part_delta(&state.acc.accumulated_thinking, delta)
    } else {
        delta.to_owned()
    }
}

fn reasoning_summary_part_delta(existing: &str, text: &str) -> String {
    if existing.trim().is_empty() || text.trim().is_empty() || text.starts_with(char::is_whitespace)
    {
        text.to_owned()
    } else {
        format!("\n\n{text}")
    }
}

fn join_reasoning_summary_parts<'a>(parts: impl Iterator<Item = &'a str>) -> String {
    parts
        .filter(|part| !part.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn parse_openai_tool_arguments(
    tc: &ToolInvocationDraftState,
) -> Result<serde_json::Map<String, serde_json::Value>, ToolArgumentParseError> {
    let ctx = ToolCallContext {
        invocation_id: Some(tc.id.clone()),
        tool_name: Some(tc.name.clone()),
        provider: Some("openai".into()),
    };
    parse_tool_call_arguments(Some(&tc.args), Some(&ctx))
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests;
