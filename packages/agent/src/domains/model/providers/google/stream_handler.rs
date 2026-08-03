//! SSE stream handler for the Gemini API.
//!
//! Processes streaming chunks from the Gemini API and converts them to unified
//! [`StreamEvent`] values. Handles thinking/text
//! transitions, function call extraction, safety blocks, and token usage.
//!
//! Delegates text/thinking delta accumulation to [`StreamAccumulator`] from the
//! shared `stream_common` module. Final `Done` content is built from Gemini part
//! order rather than aggregate buckets. Tool invocation handling remains
//! provider-specific because Gemini delivers complete function calls (not
//! streamed argument deltas).

use crate::domains::model::protocol::{ToolCallContext, parse_tool_call_arguments};
use crate::domains::model::providers::shared::stream_common::StreamAccumulator;
use crate::shared::protocol::content::{AssistantContent, ThinkingContentKind};
use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
use crate::shared::protocol::messages::{Provider, TokenUsage, ToolInvocationDraft};
use serde_json::Map;

use super::types::{GeminiPart, GeminiStreamChunk, HarmProbability, SafetyRating};

/// Mutable state accumulated across SSE events within a single stream.
pub struct StreamState {
    /// Shared delta accumulator for text, thinking, and token tracking.
    pub acc: StreamAccumulator,
    /// Accumulated tool invocations (Google-specific: complete, not streamed).
    pub tool_invocations: Vec<ToolInvocationDraftState>,
    /// Counter for generating unique tool invocation IDs.
    pub tool_invocation_index: u32,
    /// Unique prefix for tool invocation ID generation (Gemini doesn't provide IDs).
    pub unique_prefix: String,
    /// Token count for tool-use prompt scaffolding.
    pub tool_use_prompt_tokens: u64,
    /// Provider-reported total token count.
    pub total_tokens: u64,
    /// Assistant content in Gemini part order for the final Done event.
    pub ordered_content: Vec<AssistantContent>,
}

/// State for an in-progress tool invocation.
pub struct ToolInvocationDraftState {
    /// Generated tool invocation ID.
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
        tool_invocations: Vec::new(),
        tool_invocation_index: 0,
        unique_prefix: prefix,
        tool_use_prompt_tokens: 0,
        total_tokens: 0,
        ordered_content: Vec::new(),
    }
}

impl StreamState {
    fn append_ordered_text(&mut self, text: &str) {
        if let Some(AssistantContent::Text { text: current }) = self.ordered_content.last_mut() {
            current.push_str(text);
        } else {
            self.ordered_content.push(AssistantContent::text(text));
        }
    }

    fn append_ordered_thinking(&mut self, thinking: &str) {
        if let Some(AssistantContent::Thinking {
            thinking: current, ..
        }) = self.ordered_content.last_mut()
        {
            current.push_str(thinking);
        } else {
            self.ordered_content.push(AssistantContent::Thinking {
                thinking: thinking.to_owned(),
                kind: ThinkingContentKind::Thinking,
                signature: None,
            });
        }
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
    state.append_ordered_thinking(text);
    state.acc.process_thinking_delta(text)
}

/// Process a regular (non-thinking) text part.
fn process_regular_text(text: &str, state: &mut StreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    // Transition from thinking to text
    events.extend(state.acc.close_thinking(None));

    state.append_ordered_text(text);
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

    let id = format!(
        "call_{}_{}",
        state.unique_prefix, state.tool_invocation_index
    );
    state.tool_invocation_index += 1;

    let args_str = serde_json::to_string(&fc.args).unwrap_or_else(|_| "{}".into());
    let ctx = ToolCallContext {
        invocation_id: Some(id.clone()),
        tool_name: Some(fc.name.clone()),
        provider: Some("google".into()),
    };
    let arguments: Map<String, serde_json::Value> =
        match parse_tool_call_arguments(Some(&args_str), Some(&ctx)) {
            Ok(arguments) => arguments,
            Err(error) => {
                return vec![StreamEvent::Error {
                    error: error.to_string(),
                }];
            }
        };

    events.push(StreamEvent::ToolInvocationDraftStart {
        invocation_id: id.clone(),
        name: fc.name.clone(),
    });

    events.push(StreamEvent::ToolInvocationDraftDelta {
        invocation_id: id.clone(),
        arguments_delta: args_str,
    });

    let tool_invocation = ToolInvocationDraft::new(id.clone(), fc.name.clone(), arguments.clone());
    let tool_invocation = if let Some(sig) = thought_signature {
        tool_invocation.with_thought_signature(sig)
    } else {
        tool_invocation
    };

    events.push(StreamEvent::ToolInvocationDraftEnd { tool_invocation });

    let ordered_id = id.clone();
    state.tool_invocations.push(ToolInvocationDraftState {
        id,
        name: fc.name.clone(),
        args: fc.args.clone(),
        thought_signature: thought_signature.map(String::from),
    });
    state
        .ordered_content
        .push(AssistantContent::ToolInvocation {
            id: ordered_id,
            name: fc.name.clone(),
            arguments,
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

    let content = if state.ordered_content.is_empty() {
        build_bucketed_content(state)
    } else {
        state.ordered_content.clone()
    };

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

fn build_bucketed_content(state: &StreamState) -> Vec<AssistantContent> {
    let mut content = Vec::new();
    if !state.acc.accumulated_thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: state.acc.accumulated_thinking.clone(),
            kind: ThinkingContentKind::Thinking,
            signature: None,
        });
    }
    if !state.acc.accumulated_text.is_empty() {
        content.push(AssistantContent::text(&state.acc.accumulated_text));
    }

    for tc in &state.tool_invocations {
        let arguments: Map<String, serde_json::Value> = match &tc.args {
            serde_json::Value::Object(map) => map.clone(),
            _ => Map::new(),
        };
        content.push(AssistantContent::ToolInvocation {
            id: tc.id.clone(),
            name: tc.name.clone(),
            arguments,
            thought_signature: tc.thought_signature.clone(),
        });
    }
    content
}

fn nonzero(value: u64) -> Option<u64> {
    (value > 0).then_some(value)
}

/// Map a Gemini finish reason to a unified stop reason string.
fn map_google_stop_reason(reason: &str) -> &'static str {
    match reason {
        "MAX_TOKENS" => "max_tokens",
        "TOOL_USE" => "tool_invocation",
        _ => "end_turn",
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::domains::model::providers::google::types::{
        FunctionCallData, GeminiApiError, GeminiCandidate, GeminiCandidateContent, HarmCategory,
        UsageMetadata,
    };

    fn empty_chunk() -> GeminiStreamChunk {
        GeminiStreamChunk::default()
    }

    // ── create_stream_state ──────────────────────────────────────────

    #[test]
    fn initial_state_is_empty() {
        let state = create_stream_state();
        assert!(state.acc.accumulated_text.is_empty());
        assert!(state.acc.accumulated_thinking.is_empty());
        assert!(state.tool_invocations.is_empty());
        assert_eq!(state.acc.input_tokens, 0);
        assert_eq!(state.acc.output_tokens, 0);
        assert!(!state.acc.text_started);
        assert!(!state.acc.thinking_started);
        assert_eq!(state.tool_invocation_index, 0);
        assert!(!state.unique_prefix.is_empty());
        assert!(state.ordered_content.is_empty());
    }

    // ── Error handling ───────────────────────────────────────────────

    #[test]
    fn api_error_emits_error_event() {
        let chunk = GeminiStreamChunk {
            error: Some(GeminiApiError {
                code: 429,
                message: "Rate limit".into(),
            }),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        let events = process_stream_chunk(&chunk, &mut state);
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::Error { error } => {
                assert!(error.contains("429"));
                assert!(error.contains("Rate limit"));
            }
            _ => panic!("Expected error event"),
        }
    }

    // ── Token usage ──────────────────────────────────────────────────

    #[test]
    fn updates_token_usage() {
        let chunk = GeminiStreamChunk {
            usage_metadata: Some(UsageMetadata {
                prompt_token_count: 100,
                candidates_token_count: 50,
                total_token_count: 150,
                ..Default::default()
            }),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        let _ = process_stream_chunk(&chunk, &mut state);
        assert_eq!(state.acc.input_tokens, 100);
        assert_eq!(state.acc.output_tokens, 50);
    }

    // ── Text streaming ───────────────────────────────────────────────

    #[test]
    fn emits_text_start_on_first_text() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: Some(GeminiCandidateContent {
                    parts: vec![GeminiPart::Text {
                        text: "hello".into(),
                        thought: None,
                        thought_signature: None,
                    }],
                    role: Some("model".into()),
                }),
                finish_reason: None,
                safety_ratings: None,
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        let events = process_stream_chunk(&chunk, &mut state);
        assert!(matches!(events[0], StreamEvent::TextStart));
        assert!(matches!(&events[1], StreamEvent::TextDelta { delta } if delta == "hello"));
        assert!(state.acc.text_started);
    }

    #[test]
    fn subsequent_text_only_emits_delta() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: Some(GeminiCandidateContent {
                    parts: vec![GeminiPart::Text {
                        text: "more".into(),
                        thought: None,
                        thought_signature: None,
                    }],
                    role: Some("model".into()),
                }),
                finish_reason: None,
                safety_ratings: None,
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        state.acc.text_started = true;
        let events = process_stream_chunk(&chunk, &mut state);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], StreamEvent::TextDelta { .. }));
    }

    // ── Thinking streaming ───────────────────────────────────────────

    #[test]
    fn emits_thinking_start_on_first_thinking() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: Some(GeminiCandidateContent {
                    parts: vec![GeminiPart::Text {
                        text: "thinking...".into(),
                        thought: Some(true),
                        thought_signature: None,
                    }],
                    role: Some("model".into()),
                }),
                finish_reason: None,
                safety_ratings: None,
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        let events = process_stream_chunk(&chunk, &mut state);
        assert!(matches!(events[0], StreamEvent::ThinkingStart));
        assert!(
            matches!(&events[1], StreamEvent::ThinkingDelta { delta, .. } if delta == "thinking...")
        );
    }

    #[test]
    fn thinking_to_text_transition_emits_thinking_end() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: Some(GeminiCandidateContent {
                    parts: vec![GeminiPart::Text {
                        text: "answer".into(),
                        thought: None,
                        thought_signature: None,
                    }],
                    role: Some("model".into()),
                }),
                finish_reason: None,
                safety_ratings: None,
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        state.acc.thinking_started = true;
        state.acc.accumulated_thinking = "prior thinking".into();
        let events = process_stream_chunk(&chunk, &mut state);
        assert!(
            matches!(&events[0], StreamEvent::ThinkingEnd { thinking, .. } if thinking == "prior thinking")
        );
        assert!(matches!(events[1], StreamEvent::TextStart));
    }

    // ── Function calls ───────────────────────────────────────────────

    #[test]
    fn emits_toolcall_events_for_function_call() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: Some(GeminiCandidateContent {
                    parts: vec![GeminiPart::FunctionCall {
                        function_call: FunctionCallData {
                            name: "test_tool".into(),
                            args: serde_json::json!({"command": "ls"}),
                        },
                        thought_signature: Some("sig-123".into()),
                    }],
                    role: Some("model".into()),
                }),
                finish_reason: None,
                safety_ratings: None,
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        let events = process_stream_chunk(&chunk, &mut state);
        assert_eq!(events.len(), 3); // start, delta, end
        assert!(
            matches!(&events[0], StreamEvent::ToolInvocationDraftStart { name, .. } if name == "test_tool")
        );
        assert!(
            matches!(&events[2], StreamEvent::ToolInvocationDraftEnd { tool_invocation } if tool_invocation.thought_signature.as_deref() == Some("sig-123"))
        );
        assert_eq!(state.tool_invocations.len(), 1);
    }

    #[test]
    fn done_content_preserves_part_order() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: Some(GeminiCandidateContent {
                    parts: vec![
                        GeminiPart::Text {
                            text: "before".into(),
                            thought: None,
                            thought_signature: None,
                        },
                        GeminiPart::FunctionCall {
                            function_call: FunctionCallData {
                                name: "test_tool".into(),
                                args: serde_json::json!({"operation": "inspect"}),
                            },
                            thought_signature: None,
                        },
                        GeminiPart::Text {
                            text: "after".into(),
                            thought: None,
                            thought_signature: None,
                        },
                    ],
                    role: Some("model".into()),
                }),
                finish_reason: Some("TOOL_USE".into()),
                safety_ratings: None,
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        state.unique_prefix = "order".into();

        let events = process_stream_chunk(&chunk, &mut state);
        let done = events
            .iter()
            .find_map(|event| match event {
                StreamEvent::Done { message, .. } => Some(message),
                _ => None,
            })
            .expect("done event");

        assert_eq!(done.content.len(), 3);
        assert!(matches!(
            &done.content[0],
            AssistantContent::Text { text } if text == "before"
        ));
        assert!(matches!(
            &done.content[1],
            AssistantContent::ToolInvocation { id, .. } if id == "call_order_0"
        ));
        assert!(matches!(
            &done.content[2],
            AssistantContent::Text { text } if text == "after"
        ));
    }

    #[test]
    fn non_object_function_call_arguments_fail_closed() {
        let mut state = create_stream_state();
        let fc = FunctionCallData {
            name: "test_tool".into(),
            args: serde_json::json!(["not", "an", "object"]),
        };
        let events = process_function_call(&fc, None, &mut state);
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::Error { error } => {
                assert!(error.contains("google tool invocation arguments"));
                assert!(error.contains("received array"));
            }
            _ => panic!("expected Error"),
        }
        assert!(state.tool_invocations.is_empty());
    }

    #[test]
    fn invocation_id_uses_unique_prefix() {
        let mut state = create_stream_state();
        state.unique_prefix = "abcd1234".into();
        let fc = FunctionCallData {
            name: "test".into(),
            args: serde_json::json!({}),
        };
        let events = process_function_call(&fc, None, &mut state);
        match &events[0] {
            StreamEvent::ToolInvocationDraftStart { invocation_id, .. } => {
                assert!(invocation_id.starts_with("call_abcd1234_"));
            }
            _ => panic!("Expected toolcall start"),
        }
    }

    // ── Finish reason ────────────────────────────────────────────────

    #[test]
    fn finish_stop_emits_done_with_end_turn() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: None,
                finish_reason: Some("STOP".into()),
                safety_ratings: None,
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        state.acc.text_started = true;
        state.acc.accumulated_text = "hello".into();
        let events = process_stream_chunk(&chunk, &mut state);
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        assert!(done.is_some());
        match done.unwrap() {
            StreamEvent::Done { stop_reason, .. } => assert_eq!(stop_reason, "end_turn"),
            _ => unreachable!(),
        }
    }

    #[test]
    fn finish_max_tokens_maps_correctly() {
        assert_eq!(map_google_stop_reason("MAX_TOKENS"), "max_tokens");
    }

    #[test]
    fn finish_safety_emits_safety_block() {
        let chunk = GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: None,
                finish_reason: Some("SAFETY".into()),
                safety_ratings: Some(vec![SafetyRating {
                    category: HarmCategory::Harassment,
                    probability: HarmProbability::High,
                }]),
            }]),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        let events = process_stream_chunk(&chunk, &mut state);
        let block_event = events
            .iter()
            .find(|e| matches!(e, StreamEvent::SafetyBlock { .. }));
        assert!(block_event.is_some());
    }

    // ── Done event content ───────────────────────────────────────────

    #[test]
    fn done_includes_thinking_and_text_content() {
        let mut state = create_stream_state();
        state.acc.accumulated_thinking = "thought".into();
        state.acc.accumulated_text = "answer".into();
        state.acc.text_started = true;
        let events = handle_finish("STOP", None, &mut state);
        let done = events
            .iter()
            .find(|e| matches!(e, StreamEvent::Done { .. }));
        match done.unwrap() {
            StreamEvent::Done { message, .. } => {
                assert_eq!(message.content.len(), 2); // thinking + text
                assert!(message.token_usage.is_some());
                assert_eq!(
                    message.token_usage.as_ref().unwrap().provider_type,
                    Some(Provider::Google)
                );
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn done_includes_tool_invocations() {
        let mut state = create_stream_state();
        state.tool_invocations.push(ToolInvocationDraftState {
            id: "call_123".into(),
            name: "test_tool".into(),
            args: serde_json::json!({"cmd": "ls"}),
            thought_signature: Some("sig".into()),
        });
        let events = handle_finish("STOP", None, &mut state);
        match events.last().unwrap() {
            StreamEvent::Done { message, .. } => {
                // Tool invocations appear in the content as ToolInvocation blocks
                let tool_invocations: Vec<_> = message
                    .content
                    .iter()
                    .filter(|c| c.is_tool_invocation())
                    .collect();
                assert_eq!(tool_invocations.len(), 1);
                match &tool_invocations[0] {
                    AssistantContent::ToolInvocation {
                        name,
                        thought_signature,
                        ..
                    } => {
                        assert_eq!(name, "test_tool");
                        assert_eq!(thought_signature.as_deref(), Some("sig"));
                    }
                    _ => panic!("Expected ToolInvocation"),
                }
            }
            _ => panic!("Expected done"),
        }
    }

    // ── Stop reason mapping ──────────────────────────────────────────

    #[test]
    fn stop_reason_mapping() {
        assert_eq!(map_google_stop_reason("STOP"), "end_turn");
        assert_eq!(map_google_stop_reason("MAX_TOKENS"), "max_tokens");
        assert_eq!(map_google_stop_reason("SAFETY"), "end_turn");
        assert_eq!(map_google_stop_reason("RECITATION"), "end_turn");
        assert_eq!(map_google_stop_reason("TOOL_USE"), "tool_invocation");
        assert_eq!(map_google_stop_reason("UNKNOWN"), "end_turn");
    }
}
