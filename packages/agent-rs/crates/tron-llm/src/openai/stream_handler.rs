//! # `OpenAI` Stream Handler
//!
//! SSE event state machine for the `OpenAI` Responses API.
//!
//! Converts Responses API SSE events into unified [`StreamEvent`]s:
//! - `response.output_text.delta` → `TextStart` + `TextDelta`
//! - `response.output_item.added` (`function_call`) → `ToolCallStart`
//! - `response.function_call_arguments.delta` → `ToolCallDelta`
//! - `response.reasoning_text.delta` → `ThinkingStart` + `ThinkingDelta` (full reasoning)
//! - `response.reasoning_summary_text.delta` → `ThinkingStart` + `ThinkingDelta` (summary fallback)
//! - `response.completed` → `ThinkingEnd`, `TextEnd`, `ToolCallEnd`, `Done`

use std::collections::{HashMap, HashSet};

use crate::{ToolCallContext, parse_tool_call_arguments};
use tron_core::content::AssistantContent;
use tron_core::events::{AssistantMessage, StreamEvent};
use tron_core::messages::TokenUsage;

use super::types::ResponsesSseEvent;

/// State for tracking accumulated stream content.
#[derive(Clone, Debug)]
pub struct StreamState {
    /// Accumulated text content.
    pub accumulated_text: String,
    /// Accumulated thinking/reasoning content.
    pub accumulated_thinking: String,
    /// Tool calls by `call_id` → (id, name, `accumulated_args`).
    pub tool_calls: HashMap<String, ToolCallState>,
    /// Input tokens from usage.
    pub input_tokens: u64,
    /// Output tokens from usage.
    pub output_tokens: u64,
    /// Whether we've emitted `TextStart`.
    pub text_started: bool,
    /// Whether we've emitted `ThinkingStart`.
    pub thinking_started: bool,
    /// Deduplication set for reasoning text.
    pub seen_thinking_texts: HashSet<String>,
    /// Whether we received full reasoning text (vs only summary).
    pub has_reasoning_text: bool,
}

/// State for an individual tool call being accumulated.
#[derive(Clone, Debug)]
pub struct ToolCallState {
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
        accumulated_text: String::new(),
        accumulated_thinking: String::new(),
        tool_calls: HashMap::new(),
        input_tokens: 0,
        output_tokens: 0,
        text_started: false,
        thinking_started: false,
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
    let mut events = Vec::new();

    match event.event_type.as_str() {
        "response.output_text.delta" => {
            if let Some(delta) = &event.delta {
                if !state.text_started {
                    state.text_started = true;
                    events.push(StreamEvent::TextStart);
                }
                state.accumulated_text.push_str(delta);
                events.push(StreamEvent::TextDelta {
                    delta: delta.clone(),
                });
            }
        }

        "response.output_item.added" => {
            if let Some(item) = &event.item {
                if item.item_type == "function_call" {
                    if let Some(call_id) = &item.call_id {
                        let name = item.name.clone().unwrap_or_default();
                        let initial_args = item.arguments.clone().unwrap_or_default();
                        let _ = state.tool_calls.insert(
                            call_id.clone(),
                            ToolCallState {
                                id: call_id.clone(),
                                name: name.clone(),
                                args: initial_args,
                            },
                        );
                        events.push(StreamEvent::ToolCallStart {
                            tool_call_id: call_id.clone(),
                            name,
                        });
                    }
                } else if item.item_type == "reasoning" && !state.thinking_started {
                    state.thinking_started = true;
                    events.push(StreamEvent::ThinkingStart);
                }
            }
        }

        "response.output_item.done" => {
            events.extend(handle_output_item_done(event, state));
        }

        "response.reasoning_summary_part.added" => {
            if !state.thinking_started {
                state.thinking_started = true;
                events.push(StreamEvent::ThinkingStart);
            }
        }

        "response.reasoning_text.delta" => {
            // Full reasoning content — preferred over summary when available.
            if let Some(delta) = &event.delta {
                if !state.has_reasoning_text {
                    // First reasoning_text delta: replace any summary-only content.
                    state.has_reasoning_text = true;
                    if !state.accumulated_thinking.is_empty() {
                        state.accumulated_thinking.clear();
                    }
                }
                if !state.thinking_started {
                    state.thinking_started = true;
                    events.push(StreamEvent::ThinkingStart);
                }
                state.accumulated_thinking.push_str(delta);
                events.push(StreamEvent::ThinkingDelta {
                    delta: delta.clone(),
                });
            }
        }

        "response.reasoning_summary_text.delta" => {
            // Skip summary deltas when we have full reasoning text.
            if state.has_reasoning_text {
                return events;
            }
            if let Some(delta) = &event.delta {
                if !state.seen_thinking_texts.contains(delta.as_str()) {
                    let _ = state.seen_thinking_texts.insert(delta.clone());
                    if !state.thinking_started {
                        state.thinking_started = true;
                        events.push(StreamEvent::ThinkingStart);
                    }
                    state.accumulated_thinking.push_str(delta);
                    events.push(StreamEvent::ThinkingDelta {
                        delta: delta.clone(),
                    });
                }
            }
        }

        "response.function_call_arguments.delta" => {
            if let (Some(call_id), Some(delta)) = (&event.call_id, &event.delta) {
                if let Some(tc) = state.tool_calls.get_mut(call_id.as_str()) {
                    tc.args.push_str(delta);
                    events.push(StreamEvent::ToolCallDelta {
                        tool_call_id: call_id.clone(),
                        arguments_delta: delta.clone(),
                    });
                }
            }
        }

        "response.completed" => {
            events.extend(process_completed_response(event, state));
        }

        _ => {} // Ignore unknown event types
    }

    events
}

/// Handle `response.output_item.done` — extract reasoning summary if not already streamed.
fn handle_output_item_done(event: &ResponsesSseEvent, state: &mut StreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    let Some(item) = &event.item else {
        return events;
    };
    // Only process reasoning items with summary content not already streamed.
    if item.item_type != "reasoning"
        || item.summary.is_none()
        || !state.accumulated_thinking.is_empty()
        || state.has_reasoning_text
    {
        return events;
    }
    if !state.thinking_started {
        state.thinking_started = true;
        events.push(StreamEvent::ThinkingStart);
    }
    if let Some(summary) = &item.summary {
        for part in summary {
            if part.content_type == "summary_text" {
                if let Some(text) = &part.text {
                    let _ = state.seen_thinking_texts.insert(text.clone());
                    state.accumulated_thinking.push_str(text);
                    events.push(StreamEvent::ThinkingDelta {
                        delta: text.clone(),
                    });
                }
            }
        }
    }
    events
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
        state.input_tokens = usage.input_tokens;
        state.output_tokens = usage.output_tokens;
    }

    // Process output items from completed response
    merge_completed_output_items(response, state, &mut events);

    // Emit thinking_end if we had thinking
    if state.thinking_started {
        events.push(StreamEvent::ThinkingEnd {
            thinking: state.accumulated_thinking.clone(),
            signature: None,
        });
    }

    // Emit text_end if we had text
    if state.text_started {
        events.push(StreamEvent::TextEnd {
            text: state.accumulated_text.clone(),
            signature: None,
        });
    }

    // Emit toolcall_end for each tool call
    for tc in state.tool_calls.values() {
        if !tc.id.is_empty() && !tc.name.is_empty() {
            let ctx = ToolCallContext {
                tool_call_id: Some(tc.id.clone()),
                tool_name: Some(tc.name.clone()),
                provider: Some("openai".into()),
            };
            let arguments = parse_tool_call_arguments(Some(&tc.args), Some(&ctx));
            events.push(StreamEvent::ToolCallEnd {
                tool_call: tron_core::messages::ToolCall {
                    content_type: "tool_use".into(),
                    id: tc.id.clone(),
                    name: tc.name.clone(),
                    arguments: arguments.clone(),
                    thought_signature: None,
                },
            });
        }
    }

    // Build final done event
    events.push(build_done_event(state));

    events
}

/// Merge output items from the completed response into stream state.
fn merge_completed_output_items(
    response: &super::types::ResponsesResponse,
    state: &mut StreamState,
    events: &mut Vec<StreamEvent>,
) {
    for item in &response.output {
        match item.item_type.as_str() {
            "message" => merge_message_item(item, state),
            "reasoning" => merge_reasoning_item(item, state, events),
            "function_call" => merge_function_call_item(item, state),
            _ => {}
        }
    }
}

/// Merge a message output item — capture text if not yet started.
fn merge_message_item(item: &super::types::ResponsesOutputItem, state: &mut StreamState) {
    if let Some(content) = &item.content {
        for c in content {
            if c.content_type == "output_text" {
                if let Some(text) = &c.text {
                    if !state.text_started {
                        state.text_started = true;
                        state.accumulated_text.clone_from(text);
                    }
                }
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
    if !state.accumulated_thinking.is_empty() || state.has_reasoning_text {
        return;
    }
    if let Some(summary) = &item.summary {
        for s in summary {
            if s.content_type == "summary_text" {
                if let Some(text) = &s.text {
                    if !state.thinking_started {
                        state.thinking_started = true;
                        events.push(StreamEvent::ThinkingStart);
                    }
                    state.accumulated_thinking.clone_from(text);
                }
            }
        }
    }
}

/// Merge a `function_call` output item — update or insert tool call state.
fn merge_function_call_item(item: &super::types::ResponsesOutputItem, state: &mut StreamState) {
    let Some(call_id) = &item.call_id else {
        return;
    };
    if let Some(existing) = state.tool_calls.get_mut(call_id.as_str()) {
        if let Some(arguments) = &item.arguments {
            if existing.args.is_empty() {
                existing.args.clone_from(arguments);
            }
        }
        if let Some(name) = &item.name {
            if existing.name.is_empty() {
                existing.name.clone_from(name);
            }
        }
    } else {
        let _ = state.tool_calls.insert(
            call_id.clone(),
            ToolCallState {
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

    if !state.accumulated_thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: state.accumulated_thinking.clone(),
            signature: None,
        });
    }

    if !state.accumulated_text.is_empty() {
        content.push(AssistantContent::text(&state.accumulated_text));
    }

    for tc in state.tool_calls.values() {
        if !tc.id.is_empty() && !tc.name.is_empty() {
            let ctx = ToolCallContext {
                tool_call_id: Some(tc.id.clone()),
                tool_name: Some(tc.name.clone()),
                provider: Some("openai".into()),
            };
            let arguments = parse_tool_call_arguments(Some(&tc.args), Some(&ctx));
            content.push(AssistantContent::ToolUse {
                id: tc.id.clone(),
                name: tc.name.clone(),
                arguments,
                thought_signature: None,
            });
        }
    }

    let stop_reason = if state.tool_calls.is_empty() {
        "stop"
    } else {
        "tool_calls"
    };

    StreamEvent::Done {
        message: AssistantMessage {
            content,
            token_usage: Some(TokenUsage {
                input_tokens: state.input_tokens,
                output_tokens: state.output_tokens,
                provider_type: Some(tron_core::messages::ProviderType::OpenAi),
                ..TokenUsage::default()
            }),
        },
        stop_reason: stop_reason.into(),
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::openai::types::{
        OutputContent, ResponsesOutputItem, ResponsesResponse, ResponsesUsage,
    };

    fn text_delta_event(delta: &str) -> ResponsesSseEvent {
        ResponsesSseEvent {
            event_type: "response.output_text.delta".into(),
            delta: Some(delta.into()),
            ..Default::default()
        }
    }

    fn function_call_added_event(call_id: &str, name: &str) -> ResponsesSseEvent {
        ResponsesSseEvent {
            event_type: "response.output_item.added".into(),
            item: Some(ResponsesOutputItem {
                item_type: "function_call".into(),
                call_id: Some(call_id.into()),
                name: Some(name.into()),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn function_args_delta_event(call_id: &str, delta: &str) -> ResponsesSseEvent {
        ResponsesSseEvent {
            event_type: "response.function_call_arguments.delta".into(),
            call_id: Some(call_id.into()),
            delta: Some(delta.into()),
            ..Default::default()
        }
    }

    fn reasoning_added_event() -> ResponsesSseEvent {
        ResponsesSseEvent {
            event_type: "response.output_item.added".into(),
            item: Some(ResponsesOutputItem {
                item_type: "reasoning".into(),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn reasoning_summary_delta_event(delta: &str) -> ResponsesSseEvent {
        ResponsesSseEvent {
            event_type: "response.reasoning_summary_text.delta".into(),
            delta: Some(delta.into()),
            ..Default::default()
        }
    }

    fn completed_event(
        output: Vec<ResponsesOutputItem>,
        usage: Option<ResponsesUsage>,
    ) -> ResponsesSseEvent {
        ResponsesSseEvent {
            event_type: "response.completed".into(),
            response: Some(ResponsesResponse {
                id: Some("resp-123".into()),
                output,
                usage,
            }),
            ..Default::default()
        }
    }

    // ── create_stream_state ────────────────────────────────────────

    #[test]
    fn initial_state_is_empty() {
        let state = create_stream_state();
        assert!(state.accumulated_text.is_empty());
        assert!(state.accumulated_thinking.is_empty());
        assert!(state.tool_calls.is_empty());
        assert_eq!(state.input_tokens, 0);
        assert_eq!(state.output_tokens, 0);
        assert!(!state.text_started);
        assert!(!state.thinking_started);
    }

    // ── Text streaming ─────────────────────────────────────────────

    #[test]
    fn emits_text_start_on_first_delta() {
        let mut state = create_stream_state();
        let events = process_stream_event(&text_delta_event("Hello"), &mut state);

        assert_eq!(events.len(), 2);
        assert_eq!(events[0], StreamEvent::TextStart);
        assert_eq!(
            events[1],
            StreamEvent::TextDelta {
                delta: "Hello".into()
            }
        );
        assert!(state.text_started);
        assert_eq!(state.accumulated_text, "Hello");
    }

    #[test]
    fn emits_only_delta_on_subsequent() {
        let mut state = create_stream_state();
        state.text_started = true;
        state.accumulated_text = "Hello".into();

        let events = process_stream_event(&text_delta_event(" world"), &mut state);

        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0],
            StreamEvent::TextDelta {
                delta: " world".into()
            }
        );
        assert_eq!(state.accumulated_text, "Hello world");
    }

    #[test]
    fn ignores_text_delta_without_content() {
        let mut state = create_stream_state();
        let event = ResponsesSseEvent {
            event_type: "response.output_text.delta".into(),
            ..Default::default()
        };
        let events = process_stream_event(&event, &mut state);
        assert!(events.is_empty());
    }

    // ── Tool call streaming ────────────────────────────────────────

    #[test]
    fn emits_toolcall_start_on_function_call_added() {
        let mut state = create_stream_state();
        let events = process_stream_event(
            &function_call_added_event("call_123", "read_file"),
            &mut state,
        );

        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0],
            StreamEvent::ToolCallStart {
                tool_call_id: "call_123".into(),
                name: "read_file".into(),
            }
        );
        assert!(state.tool_calls.contains_key("call_123"));
    }

    #[test]
    fn accumulates_function_call_arguments() {
        let mut state = create_stream_state();
        state.tool_calls.insert(
            "call_123".into(),
            ToolCallState {
                id: "call_123".into(),
                name: "read_file".into(),
                args: String::new(),
            },
        );

        let events = process_stream_event(
            &function_args_delta_event("call_123", r#"{"path":"/test.txt"}"#),
            &mut state,
        );

        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0],
            StreamEvent::ToolCallDelta {
                tool_call_id: "call_123".into(),
                arguments_delta: r#"{"path":"/test.txt"}"#.into(),
            }
        );
        assert_eq!(state.tool_calls["call_123"].args, r#"{"path":"/test.txt"}"#);
    }

    #[test]
    fn ignores_args_delta_for_unknown_call_id() {
        let mut state = create_stream_state();
        let events = process_stream_event(
            &function_args_delta_event("call_unknown", "data"),
            &mut state,
        );
        assert!(events.is_empty());
    }

    // ── Reasoning streaming ────────────────────────────────────────

    #[test]
    fn emits_thinking_start_on_reasoning_item() {
        let mut state = create_stream_state();
        let events = process_stream_event(&reasoning_added_event(), &mut state);

        assert_eq!(events.len(), 1);
        assert_eq!(events[0], StreamEvent::ThinkingStart);
        assert!(state.thinking_started);
    }

    #[test]
    fn emits_thinking_delta_for_reasoning_summary() {
        let mut state = create_stream_state();
        state.thinking_started = true;

        let events =
            process_stream_event(&reasoning_summary_delta_event("Analyzing..."), &mut state);

        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0],
            StreamEvent::ThinkingDelta {
                delta: "Analyzing...".into()
            }
        );
        assert_eq!(state.accumulated_thinking, "Analyzing...");
    }

    #[test]
    fn deduplicates_reasoning_text() {
        let mut state = create_stream_state();
        state.thinking_started = true;
        state.seen_thinking_texts.insert("Already seen".into());

        let events =
            process_stream_event(&reasoning_summary_delta_event("Already seen"), &mut state);
        assert!(events.is_empty());
    }

    #[test]
    fn handles_reasoning_from_output_item_done() {
        let mut state = create_stream_state();
        let event = ResponsesSseEvent {
            event_type: "response.output_item.done".into(),
            item: Some(ResponsesOutputItem {
                item_type: "reasoning".into(),
                summary: Some(vec![OutputContent {
                    content_type: "summary_text".into(),
                    text: Some("The approach is correct.".into()),
                }]),
                ..Default::default()
            }),
            ..Default::default()
        };

        let events = process_stream_event(&event, &mut state);
        let types: Vec<_> = events
            .iter()
            .map(|e| match e {
                StreamEvent::ThinkingStart => "thinking_start",
                StreamEvent::ThinkingDelta { .. } => "thinking_delta",
                _ => "other",
            })
            .collect();
        assert_eq!(types, vec!["thinking_start", "thinking_delta"]);
        assert_eq!(state.accumulated_thinking, "The approach is correct.");
    }

    #[test]
    fn skips_output_item_done_if_already_accumulated() {
        let mut state = create_stream_state();
        state.accumulated_thinking = "Already accumulated".into();

        let event = ResponsesSseEvent {
            event_type: "response.output_item.done".into(),
            item: Some(ResponsesOutputItem {
                item_type: "reasoning".into(),
                summary: Some(vec![OutputContent {
                    content_type: "summary_text".into(),
                    text: Some("Different text".into()),
                }]),
                ..Default::default()
            }),
            ..Default::default()
        };

        let events = process_stream_event(&event, &mut state);
        assert!(events.is_empty());
        assert_eq!(state.accumulated_thinking, "Already accumulated");
    }

    // ── response.completed ─────────────────────────────────────────

    #[test]
    fn completed_emits_text_end_and_done() {
        let mut state = create_stream_state();
        state.text_started = true;
        state.accumulated_text = "Hello world".into();

        let event = completed_event(
            vec![ResponsesOutputItem {
                item_type: "message".into(),
                content: Some(vec![OutputContent {
                    content_type: "output_text".into(),
                    text: Some("Hello world".into()),
                }]),
                ..Default::default()
            }],
            Some(ResponsesUsage {
                input_tokens: 100,
                output_tokens: 50,
            }),
        );

        let events = process_stream_event(&event, &mut state);
        let types: Vec<&str> = events
            .iter()
            .map(|e| match e {
                StreamEvent::TextEnd { .. } => "text_end",
                StreamEvent::Done { .. } => "done",
                _ => "other",
            })
            .collect();
        assert!(types.contains(&"text_end"));
        assert!(types.contains(&"done"));

        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        if let Some(StreamEvent::Done {
            message,
            stop_reason,
        }) = done
        {
            assert_eq!(message.content.len(), 1);
            assert_eq!(message.token_usage.as_ref().unwrap().input_tokens, 100);
            assert_eq!(message.token_usage.as_ref().unwrap().output_tokens, 50);
            assert_eq!(stop_reason, "stop");
        }
    }

    #[test]
    fn completed_emits_toolcall_end_with_tool_use_stop_reason() {
        let mut state = create_stream_state();
        state.tool_calls.insert(
            "call_abc".into(),
            ToolCallState {
                id: "call_abc".into(),
                name: "read_file".into(),
                args: r#"{"path":"/test.txt"}"#.into(),
            },
        );

        let event = completed_event(
            vec![ResponsesOutputItem {
                item_type: "function_call".into(),
                call_id: Some("call_abc".into()),
                name: Some("read_file".into()),
                arguments: Some(r#"{"path":"/test.txt"}"#.into()),
                ..Default::default()
            }],
            Some(ResponsesUsage {
                input_tokens: 50,
                output_tokens: 30,
            }),
        );

        let events = process_stream_event(&event, &mut state);
        let tool_end = events
            .iter()
            .find(|e| matches!(e, StreamEvent::ToolCallEnd { .. }));
        assert!(tool_end.is_some());

        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        if let Some(StreamEvent::Done { stop_reason, .. }) = done {
            assert_eq!(stop_reason, "tool_calls");
        }
    }

    #[test]
    fn completed_with_thinking_emits_thinking_end_before_done() {
        let mut state = create_stream_state();
        state.thinking_started = true;
        state.accumulated_thinking = "Some reasoning".into();
        state.text_started = true;
        state.accumulated_text = "The answer".into();

        let event = completed_event(
            vec![ResponsesOutputItem {
                item_type: "message".into(),
                content: Some(vec![OutputContent {
                    content_type: "output_text".into(),
                    text: Some("The answer".into()),
                }]),
                ..Default::default()
            }],
            Some(ResponsesUsage {
                input_tokens: 50,
                output_tokens: 30,
            }),
        );

        let events = process_stream_event(&event, &mut state);
        let types: Vec<&str> = events
            .iter()
            .map(|e| match e {
                StreamEvent::ThinkingEnd { .. } => "thinking_end",
                StreamEvent::TextEnd { .. } => "text_end",
                StreamEvent::Done { .. } => "done",
                _ => "other",
            })
            .collect();
        let thinking_idx = types.iter().position(|t| *t == "thinking_end").unwrap();
        let done_idx = types.iter().position(|t| *t == "done").unwrap();
        assert!(thinking_idx < done_idx);

        // Done message should have both thinking and text
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        if let Some(StreamEvent::Done { message, .. }) = done {
            assert_eq!(message.content.len(), 2);
        }
    }

    #[test]
    fn completed_empty_response_is_handled() {
        let mut state = create_stream_state();
        let event = ResponsesSseEvent {
            event_type: "response.completed".into(),
            ..Default::default()
        };
        let events = process_stream_event(&event, &mut state);
        assert!(events.is_empty());
    }

    #[test]
    fn completed_discovers_tool_calls_not_seen_in_deltas() {
        let mut state = create_stream_state();
        let event = completed_event(
            vec![ResponsesOutputItem {
                item_type: "function_call".into(),
                call_id: Some("call_new".into()),
                name: Some("write_file".into()),
                arguments: Some(r#"{"path":"/out.txt","content":"data"}"#.into()),
                ..Default::default()
            }],
            Some(ResponsesUsage {
                input_tokens: 50,
                output_tokens: 30,
            }),
        );

        let events = process_stream_event(&event, &mut state);
        let tool_end = events
            .iter()
            .find(|e| matches!(e, StreamEvent::ToolCallEnd { .. }));
        assert!(tool_end.is_some());
        if let Some(StreamEvent::ToolCallEnd { tool_call }) = tool_end {
            assert_eq!(tool_call.name, "write_file");
        }

        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        if let Some(StreamEvent::Done { stop_reason, .. }) = done {
            assert_eq!(stop_reason, "tool_calls");
        }
    }

    // ── Unknown events ─────────────────────────────────────────────

    #[test]
    fn unknown_event_type_returns_empty() {
        let mut state = create_stream_state();
        let event = ResponsesSseEvent {
            event_type: "response.unknown_event".into(),
            ..Default::default()
        };
        let events = process_stream_event(&event, &mut state);
        assert!(events.is_empty());
    }

    // ── reasoning_summary_part.added ───────────────────────────────

    #[test]
    fn reasoning_summary_part_added_emits_thinking_start() {
        let mut state = create_stream_state();
        let event = ResponsesSseEvent {
            event_type: "response.reasoning_summary_part.added".into(),
            ..Default::default()
        };
        let events = process_stream_event(&event, &mut state);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0], StreamEvent::ThinkingStart);
    }

    #[test]
    fn reasoning_summary_part_added_noop_when_already_started() {
        let mut state = create_stream_state();
        state.thinking_started = true;
        let event = ResponsesSseEvent {
            event_type: "response.reasoning_summary_part.added".into(),
            ..Default::default()
        };
        let events = process_stream_event(&event, &mut state);
        assert!(events.is_empty());
    }

    // ── Token usage in done message ────────────────────────────────

    #[test]
    fn done_event_has_openai_provider_type() {
        let mut state = create_stream_state();
        state.text_started = true;
        state.accumulated_text = "test".into();

        let event = completed_event(
            vec![],
            Some(ResponsesUsage {
                input_tokens: 10,
                output_tokens: 5,
            }),
        );

        let events = process_stream_event(&event, &mut state);
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        if let Some(StreamEvent::Done { message, .. }) = done {
            assert_eq!(
                message.token_usage.as_ref().unwrap().provider_type,
                Some(tron_core::messages::ProviderType::OpenAi)
            );
        }
    }

    // ── Full reasoning text (response.reasoning_text.delta) ───────

    fn reasoning_text_delta_event(delta: &str) -> ResponsesSseEvent {
        ResponsesSseEvent {
            event_type: "response.reasoning_text.delta".into(),
            delta: Some(delta.into()),
            ..Default::default()
        }
    }

    #[test]
    fn reasoning_text_delta_emits_thinking_events() {
        let mut state = create_stream_state();
        let events = process_stream_event(
            &reasoning_text_delta_event("Let me think about this..."),
            &mut state,
        );

        assert_eq!(events.len(), 2);
        assert_eq!(events[0], StreamEvent::ThinkingStart);
        assert_eq!(
            events[1],
            StreamEvent::ThinkingDelta {
                delta: "Let me think about this...".into()
            }
        );
        assert!(state.has_reasoning_text);
        assert!(state.thinking_started);
        assert_eq!(state.accumulated_thinking, "Let me think about this...");
    }

    #[test]
    fn reasoning_text_replaces_prior_summary() {
        let mut state = create_stream_state();
        // First, receive a summary delta
        let _ = process_stream_event(
            &reasoning_summary_delta_event("**Short summary**"),
            &mut state,
        );
        assert_eq!(state.accumulated_thinking, "**Short summary**");

        // Then receive full reasoning text — should replace summary
        let events = process_stream_event(
            &reasoning_text_delta_event("Full reasoning content here..."),
            &mut state,
        );

        assert!(state.has_reasoning_text);
        assert_eq!(state.accumulated_thinking, "Full reasoning content here...");
        // Should emit ThinkingDelta (ThinkingStart already emitted by summary)
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0],
            StreamEvent::ThinkingDelta {
                delta: "Full reasoning content here...".into()
            }
        );
    }

    #[test]
    fn summary_skipped_when_reasoning_text_active() {
        let mut state = create_stream_state();
        // Receive full reasoning text first
        let _ = process_stream_event(&reasoning_text_delta_event("Full reasoning..."), &mut state);

        // Summary delta should be ignored
        let events =
            process_stream_event(&reasoning_summary_delta_event("**Summary**"), &mut state);
        assert!(events.is_empty());
        assert_eq!(state.accumulated_thinking, "Full reasoning...");
    }

    #[test]
    fn reasoning_text_accumulates_multiple_deltas() {
        let mut state = create_stream_state();
        let _ = process_stream_event(&reasoning_text_delta_event("First part. "), &mut state);
        let _ = process_stream_event(&reasoning_text_delta_event("Second part."), &mut state);
        assert_eq!(state.accumulated_thinking, "First part. Second part.");
    }
}
