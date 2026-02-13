//! SSE stream handler for the Gemini API.
//!
//! Processes streaming chunks from the Gemini API and converts them to unified
//! [`StreamEvent`] values. Handles thinking/text
//! transitions, function call extraction, safety blocks, and token usage.

use std::collections::HashSet;

use serde_json::Map;
use tron_core::content::AssistantContent;
use tron_core::events::{AssistantMessage, StreamEvent};
use tron_core::messages::{ProviderType, TokenUsage, ToolCall};

use crate::types::{GeminiPart, GeminiStreamChunk, HarmProbability, SafetyRating};

/// Mutable state accumulated across SSE events within a single stream.
pub struct StreamState {
    /// Accumulated text content.
    pub accumulated_text: String,
    /// Accumulated thinking/reasoning content.
    pub accumulated_thinking: String,
    /// Accumulated tool calls.
    pub tool_calls: Vec<ToolCallState>,
    /// Input tokens reported by the API.
    pub input_tokens: u64,
    /// Output tokens reported by the API.
    pub output_tokens: u64,
    /// Whether we've emitted a `text_start` event.
    pub text_started: bool,
    /// Whether we've emitted a `thinking_start` event.
    pub thinking_started: bool,
    /// Counter for generating unique tool call IDs.
    pub tool_call_index: u32,
    /// Unique prefix for tool call ID generation (Gemini doesn't provide IDs).
    pub unique_prefix: String,
    /// Set of tool call IDs already completed (to avoid duplicates).
    pub completed_tool_ids: HashSet<String>,
}

/// State for an in-progress tool call.
pub struct ToolCallState {
    /// Generated tool call ID.
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
        accumulated_text: String::new(),
        accumulated_thinking: String::new(),
        tool_calls: Vec::new(),
        input_tokens: 0,
        output_tokens: 0,
        text_started: false,
        thinking_started: false,
        tool_call_index: 0,
        unique_prefix: prefix,
        completed_tool_ids: HashSet::new(),
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
pub fn process_stream_chunk(chunk: &GeminiStreamChunk, state: &mut StreamState) -> Vec<StreamEvent> {
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
        state.input_tokens = u64::from(usage.prompt_token_count);
        state.output_tokens = u64::from(usage.candidates_token_count);
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
    let mut events = Vec::new();

    if !state.thinking_started {
        events.push(StreamEvent::ThinkingStart);
        state.thinking_started = true;
    }

    state.accumulated_thinking.push_str(text);
    events.push(StreamEvent::ThinkingDelta {
        delta: text.to_string(),
    });

    events
}

/// Process a regular (non-thinking) text part.
fn process_regular_text(text: &str, state: &mut StreamState) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    // Transition from thinking to text
    if state.thinking_started {
        events.push(StreamEvent::ThinkingEnd {
            thinking: state.accumulated_thinking.clone(),
            signature: None,
        });
        state.thinking_started = false;
    }

    if !state.text_started {
        events.push(StreamEvent::TextStart);
        state.text_started = true;
    }

    state.accumulated_text.push_str(text);
    events.push(StreamEvent::TextDelta {
        delta: text.to_string(),
    });

    events
}

/// Process a function call part.
fn process_function_call(
    fc: &crate::types::FunctionCallData,
    thought_signature: Option<&str>,
    state: &mut StreamState,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();

    let id = format!("call_{}_{}", state.unique_prefix, state.tool_call_index);
    state.tool_call_index += 1;

    let args_str = serde_json::to_string(&fc.args).unwrap_or_else(|_| "{}".into());

    // Parse args into Map<String, Value>
    let arguments: Map<String, serde_json::Value> = match &fc.args {
        serde_json::Value::Object(map) => map.clone(),
        _ => Map::new(),
    };

    events.push(StreamEvent::ToolCallStart {
        tool_call_id: id.clone(),
        name: fc.name.clone(),
    });

    events.push(StreamEvent::ToolCallDelta {
        tool_call_id: id.clone(),
        arguments_delta: args_str,
    });

    let tool_call = ToolCall {
        content_type: "tool_use".into(),
        id: id.clone(),
        name: fc.name.clone(),
        arguments: arguments.clone(),
        thought_signature: thought_signature.map(String::from),
    };

    events.push(StreamEvent::ToolCallEnd { tool_call });

    state.tool_calls.push(ToolCallState {
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
    if state.thinking_started {
        events.push(StreamEvent::ThinkingEnd {
            thinking: state.accumulated_thinking.clone(),
            signature: None,
        });
        state.thinking_started = false;
    }

    // Handle safety block
    if finish_reason == "SAFETY" {
        if let Some(ratings) = safety_ratings {
            let blocked: Vec<String> = ratings
                .iter()
                .filter(|r| {
                    r.probability == HarmProbability::High
                        || r.probability == HarmProbability::Medium
                })
                .map(|r| format!("{:?}", r.category))
                .collect();

            if !blocked.is_empty() {
                events.push(StreamEvent::SafetyBlock {
                    blocked_categories: blocked.clone(),
                    error: format!(
                        "Response blocked by safety filter: {}",
                        blocked.join(", ")
                    ),
                });
            }
        }
    }

    // End text if active
    if state.text_started {
        events.push(StreamEvent::TextEnd {
            text: state.accumulated_text.clone(),
            signature: None,
        });
        state.text_started = false;
    }

    // Build assistant content blocks
    let mut content = Vec::new();
    if !state.accumulated_thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: state.accumulated_thinking.clone(),
            signature: None,
        });
    }
    if !state.accumulated_text.is_empty() {
        content.push(AssistantContent::text(&state.accumulated_text));
    }

    // Add tool calls as ToolUse content blocks
    for tc in &state.tool_calls {
        let arguments: Map<String, serde_json::Value> = match &tc.args {
            serde_json::Value::Object(map) => map.clone(),
            _ => Map::new(),
        };
        content.push(AssistantContent::ToolUse {
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
                input_tokens: state.input_tokens,
                output_tokens: state.output_tokens,
                cache_read_tokens: None,
                cache_creation_tokens: None,
                cache_creation_5m_tokens: None,
                cache_creation_1h_tokens: None,
                provider_type: Some(ProviderType::Google),
            }),
        },
        stop_reason: stop_reason.into(),
    });

    events
}

/// Synthesize a done event when the stream ends without a finish reason.
pub fn synthesize_done_event(state: &mut StreamState) -> Vec<StreamEvent> {
    let finish_reason = if state.tool_calls.is_empty() {
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
        "TOOL_USE" => "tool_use",
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
    use crate::types::{
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
        assert!(state.accumulated_text.is_empty());
        assert!(state.accumulated_thinking.is_empty());
        assert!(state.tool_calls.is_empty());
        assert_eq!(state.input_tokens, 0);
        assert_eq!(state.output_tokens, 0);
        assert!(!state.text_started);
        assert!(!state.thinking_started);
        assert_eq!(state.tool_call_index, 0);
        assert!(!state.unique_prefix.is_empty());
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
            }),
            ..empty_chunk()
        };
        let mut state = create_stream_state();
        let _ = process_stream_chunk(&chunk, &mut state);
        assert_eq!(state.input_tokens, 100);
        assert_eq!(state.output_tokens, 50);
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
        assert!(state.text_started);
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
        state.text_started = true;
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
        assert!(matches!(&events[1], StreamEvent::ThinkingDelta { delta } if delta == "thinking..."));
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
        state.thinking_started = true;
        state.accumulated_thinking = "prior thinking".into();
        let events = process_stream_chunk(&chunk, &mut state);
        assert!(matches!(&events[0], StreamEvent::ThinkingEnd { thinking, .. } if thinking == "prior thinking"));
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
                            name: "bash".into(),
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
        assert!(matches!(&events[0], StreamEvent::ToolCallStart { name, .. } if name == "bash"));
        assert!(
            matches!(&events[2], StreamEvent::ToolCallEnd { tool_call } if tool_call.thought_signature.as_deref() == Some("sig-123"))
        );
        assert_eq!(state.tool_calls.len(), 1);
    }

    #[test]
    fn tool_call_id_uses_unique_prefix() {
        let mut state = create_stream_state();
        state.unique_prefix = "abcd1234".into();
        let fc = FunctionCallData {
            name: "test".into(),
            args: serde_json::json!({}),
        };
        let events = process_function_call(&fc, None, &mut state);
        match &events[0] {
            StreamEvent::ToolCallStart { tool_call_id, .. } => {
                assert!(tool_call_id.starts_with("call_abcd1234_"));
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
        state.text_started = true;
        state.accumulated_text = "hello".into();
        let events = process_stream_chunk(&chunk, &mut state);
        let done = events.iter().find(|e| matches!(e, StreamEvent::Done { .. }));
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
        state.accumulated_thinking = "thought".into();
        state.accumulated_text = "answer".into();
        state.text_started = true;
        let events = handle_finish("STOP", None, &mut state);
        let done = events.iter().find(|e| matches!(e, StreamEvent::Done { .. }));
        match done.unwrap() {
            StreamEvent::Done { message, .. } => {
                assert_eq!(message.content.len(), 2); // thinking + text
                assert!(message.token_usage.is_some());
                assert_eq!(
                    message.token_usage.as_ref().unwrap().provider_type,
                    Some(ProviderType::Google)
                );
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn done_includes_tool_calls() {
        let mut state = create_stream_state();
        state.tool_calls.push(ToolCallState {
            id: "call_123".into(),
            name: "bash".into(),
            args: serde_json::json!({"cmd": "ls"}),
            thought_signature: Some("sig".into()),
        });
        let events = handle_finish("STOP", None, &mut state);
        match events.last().unwrap() {
            StreamEvent::Done { message, .. } => {
                // Tool calls appear in the content as ToolUse blocks
                let tool_uses: Vec<_> = message
                    .content
                    .iter()
                    .filter(|c| c.is_tool_use())
                    .collect();
                assert_eq!(tool_uses.len(), 1);
                match &tool_uses[0] {
                    AssistantContent::ToolUse {
                        name,
                        thought_signature,
                        ..
                    } => {
                        assert_eq!(name, "bash");
                        assert_eq!(thought_signature.as_deref(), Some("sig"));
                    }
                    _ => panic!("Expected ToolUse"),
                }
            }
            _ => panic!("Expected done"),
        }
    }

    // ── synthesize_done_event ────────────────────────────────────────

    #[test]
    fn synthesize_uses_tool_use_when_tools_present() {
        let mut state = create_stream_state();
        state.tool_calls.push(ToolCallState {
            id: "call_1".into(),
            name: "test".into(),
            args: serde_json::json!({}),
            thought_signature: None,
        });
        let events = synthesize_done_event(&mut state);
        match events.last().unwrap() {
            StreamEvent::Done { stop_reason, .. } => assert_eq!(stop_reason, "tool_use"),
            _ => panic!("Expected done"),
        }
    }

    #[test]
    fn synthesize_uses_stop_when_no_tools() {
        let mut state = create_stream_state();
        let events = synthesize_done_event(&mut state);
        match events.last().unwrap() {
            StreamEvent::Done { stop_reason, .. } => assert_eq!(stop_reason, "end_turn"),
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
        assert_eq!(map_google_stop_reason("TOOL_USE"), "tool_use");
        assert_eq!(map_google_stop_reason("UNKNOWN"), "end_turn");
    }
}
