//! Message reconstruction from event ancestry.
//!
//! [`reconstruct_from_events`] implements a two-pass algorithm that rebuilds
//! the message list from an ordered sequence of [`SessionEvent`]s:
//!
//! 1. **First pass**: collect deleted event IDs, tool call argument maps,
//!    reasoning level, and system prompt.
//! 2. **Second pass**: build messages while handling deletions, compaction,
//!    context clears, tool result injection, and consecutive-role merging.
//!
//! The output is a [`ReconstructionResult`] containing messages with event IDs,
//! aggregate token usage, turn count, and config state.

use serde_json::Value;

use crate::types::base::SessionEvent;
use crate::types::state::{Message, MessageWithEventId};

/// Prefix for compaction summary messages, matching TypeScript `context/constants.ts`.
pub const COMPACTION_SUMMARY_PREFIX: &str = "[Context from earlier in this conversation]";
/// Assistant acknowledgement text after compaction, matching TypeScript `context/constants.ts`.
pub const COMPACTION_ACK_TEXT: &str =
    "I understand the previous context. Let me continue helping you.";

/// Result of reconstructing messages from event ancestry.
#[derive(Clone, Debug)]
pub struct ReconstructionResult {
    /// Reconstructed messages with their source event IDs.
    pub messages_with_event_ids: Vec<MessageWithEventId>,
    /// Aggregate token usage across all message events.
    pub token_usage: ReconstructedTokenUsage,
    /// Highest turn number seen.
    pub turn_count: i64,
    /// Last-seen reasoning level from `config.reasoning_level` events.
    pub reasoning_level: Option<String>,
    /// System prompt from `session.start` or `config.prompt_update`.
    pub system_prompt: Option<String>,
}

/// Aggregate token usage accumulated during reconstruction.
#[derive(Clone, Debug, Default)]
pub struct ReconstructedTokenUsage {
    /// Total input tokens.
    pub input_tokens: i64,
    /// Total output tokens.
    pub output_tokens: i64,
    /// Total cache read tokens.
    pub cache_read_tokens: i64,
    /// Total cache creation tokens.
    pub cache_creation_tokens: i64,
}

/// Pending tool result accumulated between assistant messages.
struct PendingToolResult {
    tool_call_id: String,
    content: String,
    is_error: bool,
}

/// Reconstruct messages and state from an ordered list of ancestor events.
///
/// Implements the two-pass reconstruction algorithm matching the TypeScript
/// `reconstructFromEvents` exactly:
///
/// - **Pass 1**: Metadata collection (deletions, tool args, config)
/// - **Pass 2**: Message building (merging, compaction, tool result injection)
///
/// # Arguments
///
/// * `ancestors` - Ordered events from `session.start` to target event.
pub fn reconstruct_from_events(ancestors: &[SessionEvent]) -> ReconstructionResult {
    let metadata = collect_metadata(ancestors);
    build_messages(ancestors, &metadata)
}

/// Pass 1 output: metadata collected from events.
struct Metadata {
    deleted_event_ids: std::collections::HashSet<String>,
    tool_call_args_map: std::collections::HashMap<String, Value>,
    reasoning_level: Option<String>,
    system_prompt: Option<String>,
}

/// Pass 1: Collect deleted event IDs, tool call arguments, and config state.
fn collect_metadata(ancestors: &[SessionEvent]) -> Metadata {
    let mut deleted_event_ids = std::collections::HashSet::new();
    let mut tool_call_args_map = std::collections::HashMap::new();
    let mut reasoning_level: Option<String> = None;
    let mut system_prompt: Option<String> = None;

    for event in ancestors {
        match event.event_type.as_str() {
            "message.deleted" => {
                if let Some(target) = event.payload.get("targetEventId").and_then(Value::as_str) {
                    let _ = deleted_event_ids.insert(target.to_string());
                }
            }
            "tool.call" => {
                let tc_id = event.payload.get("toolCallId").and_then(Value::as_str);
                let args = event.payload.get("arguments");
                if let (Some(id), Some(a)) = (tc_id, args) {
                    let _ = tool_call_args_map.insert(id.to_string(), a.clone());
                }
            }
            "config.reasoning_level" => {
                reasoning_level = event
                    .payload
                    .get("newLevel")
                    .and_then(Value::as_str)
                    .map(String::from);
            }
            "session.start" => {
                if let Some(sp) = event.payload.get("systemPrompt").and_then(Value::as_str) {
                    system_prompt = Some(sp.to_string());
                }
            }
            "config.prompt_update" => {
                if event.payload.get("contentBlobId").is_some() {
                    if let Some(hash) = event.payload.get("newHash").and_then(Value::as_str) {
                        system_prompt = Some(format!("[Updated prompt - hash: {hash}]"));
                    }
                }
            }
            _ => {}
        }
    }

    Metadata {
        deleted_event_ids,
        tool_call_args_map,
        reasoning_level,
        system_prompt,
    }
}

/// Pass 2: Build messages from events using metadata from pass 1.
/// Mutable state carried through the message-building pass.
struct BuildState {
    combined: Vec<MessageWithEventId>,
    tokens: ReconstructedTokenUsage,
    turn_count: i64,
    current_turn: i64,
    pending_tool_results: Vec<PendingToolResult>,
}

/// Pass 2: Build messages from events using metadata from pass 1.
fn build_messages(ancestors: &[SessionEvent], metadata: &Metadata) -> ReconstructionResult {
    let mut st = BuildState {
        combined: Vec::new(),
        tokens: ReconstructedTokenUsage::default(),
        turn_count: 0,
        current_turn: 0,
        pending_tool_results: Vec::new(),
    };

    for event in ancestors {
        if metadata.deleted_event_ids.contains(&event.id) {
            continue;
        }
        match event.event_type.as_str() {
            "compact.summary" => handle_compact_summary(event, &mut st),
            "context.cleared" => handle_context_cleared(&mut st),
            "tool.result" => handle_tool_result(event, &mut st),
            "message.user" => handle_message_user(event, &mut st),
            "message.assistant" => handle_message_assistant(event, metadata, &mut st),
            _ => {}
        }
    }

    // End-of-stream flush: if last message is assistant with tool_use
    if !st.pending_tool_results.is_empty() {
        if let Some(last) = st.combined.last() {
            if last.message.role == "assistant" && content_has_tool_use(&last.message.content) {
                flush_tool_results(&mut st.combined, &mut st.pending_tool_results);
            }
        }
    }

    // Inject synthetic error results for any unmatched tool calls.
    // This happens when: (a) a user interrupt discards pending tool results,
    // or (b) the session ended mid-tool-execution before results arrived.
    // Without this, providers like OpenAI reject the history because every
    // function_call must have a corresponding function_call_output.
    inject_missing_tool_results(&mut st.combined);

    ReconstructionResult {
        messages_with_event_ids: st.combined,
        token_usage: st.tokens,
        turn_count: st.turn_count,
        reasoning_level: metadata.reasoning_level.clone(),
        system_prompt: metadata.system_prompt.clone(),
    }
}

/// Handle `compact.summary`: clear all state, inject synthetic pair.
fn handle_compact_summary(event: &SessionEvent, st: &mut BuildState) {
    let summary = event
        .payload
        .get("summary")
        .and_then(Value::as_str)
        .unwrap_or("");
    st.combined.clear();
    st.pending_tool_results.clear();

    st.combined.push(MessageWithEventId {
        message: Message {
            role: "user".to_string(),
            content: Value::String(format!("{COMPACTION_SUMMARY_PREFIX}\n\n{summary}")),
            tool_call_id: None,
            is_error: None,
        },
        event_ids: vec![None],
    });
    st.combined.push(MessageWithEventId {
        message: Message {
            role: "assistant".to_string(),
            content: serde_json::json!([{ "type": "text", "text": COMPACTION_ACK_TEXT }]),
            tool_call_id: None,
            is_error: None,
        },
        event_ids: vec![None],
    });
}

/// Handle `context.cleared`: discard all messages.
fn handle_context_cleared(st: &mut BuildState) {
    st.combined.clear();
    st.pending_tool_results.clear();
}

/// Handle `tool.result`: accumulate for later flushing.
fn handle_tool_result(event: &SessionEvent, st: &mut BuildState) {
    let tc_id = event
        .payload
        .get("toolCallId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let content = event
        .payload
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let is_error = event
        .payload
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    st.pending_tool_results.push(PendingToolResult {
        tool_call_id: tc_id,
        content,
        is_error,
    });
}

/// Handle `message.user`: merge consecutive, discard pending tool results.
fn handle_message_user(event: &SessionEvent, st: &mut BuildState) {
    st.pending_tool_results.clear();

    let content = event
        .payload
        .get("content")
        .cloned()
        .unwrap_or(Value::Null);

    if st.combined.last().is_some_and(|e| e.message.role == "user") {
        let last = st.combined.last_mut().unwrap();
        last.message.content = merge_message_content(&last.message.content, &content, "user");
        last.event_ids.push(Some(event.id.clone()));
    } else {
        st.combined.push(MessageWithEventId {
            message: Message {
                role: "user".to_string(),
                content,
                tool_call_id: None,
                is_error: None,
            },
            event_ids: vec![Some(event.id.clone())],
        });
    }
    accumulate_tokens(&event.payload, &mut st.tokens);
}

/// Handle `message.assistant`: restore truncated inputs, flush tool results,
/// merge consecutive, track turns.
fn handle_message_assistant(event: &SessionEvent, metadata: &Metadata, st: &mut BuildState) {
    let content = event
        .payload
        .get("content")
        .cloned()
        .unwrap_or(Value::Null);
    let restored_content = restore_truncated_inputs(&content, &metadata.tool_call_args_map);
    let has_tool_use = content_has_tool_use(&restored_content);

    // CASE 1: Last was assistant with pending tool results → flush first
    if st.combined.last().is_some_and(|e| e.message.role == "assistant")
        && !st.pending_tool_results.is_empty()
    {
        flush_tool_results(&mut st.combined, &mut st.pending_tool_results);
    }

    // Re-check after potential flush — merge consecutive assistant messages
    if st.combined.last().is_some_and(|e| e.message.role == "assistant") {
        let last = st.combined.last_mut().unwrap();
        last.message.content =
            merge_message_content(&last.message.content, &restored_content, "assistant");
        last.event_ids.push(Some(event.id.clone()));
    } else {
        st.combined.push(MessageWithEventId {
            message: Message {
                role: "assistant".to_string(),
                content: restored_content,
                tool_call_id: None,
                is_error: None,
            },
            event_ids: vec![Some(event.id.clone())],
        });
    }

    // CASE 2: This assistant has tool_use and pending results → flush
    if has_tool_use && !st.pending_tool_results.is_empty() {
        flush_tool_results(&mut st.combined, &mut st.pending_tool_results);
    }

    accumulate_tokens(&event.payload, &mut st.tokens);

    if let Some(turn) = event.payload.get("turn").and_then(Value::as_i64) {
        if turn > st.current_turn {
            st.current_turn = turn;
            st.turn_count = turn;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Inject synthetic error `toolResult` messages for any assistant `tool_use`
/// blocks that lack a corresponding `toolResult` in the following messages.
///
/// Scans through the reconstructed message list and, for each assistant message
/// containing `tool_use` blocks, checks whether matching `toolResult` messages
/// exist before the next non-toolResult message. Any unmatched tool calls get
/// a synthetic error result injected immediately after the assistant message.
fn inject_missing_tool_results(combined: &mut Vec<MessageWithEventId>) {
    let mut insertions: Vec<(usize, Vec<MessageWithEventId>)> = Vec::new();

    let mut i = 0;
    while i < combined.len() {
        if combined[i].message.role == "assistant" {
            let tool_use_ids = extract_tool_use_ids(&combined[i].message.content);
            if !tool_use_ids.is_empty() {
                // Collect tool_call_ids from following toolResult messages
                let mut matched_ids = std::collections::HashSet::new();
                let mut j = i + 1;
                while j < combined.len() && combined[j].message.role == "toolResult" {
                    if let Some(ref tc_id) = combined[j].message.tool_call_id {
                        let _ = matched_ids.insert(tc_id.clone());
                    }
                    j += 1;
                }

                // Find unmatched tool calls
                let mut synthetic = Vec::new();
                for tc_id in &tool_use_ids {
                    if !matched_ids.contains(tc_id.as_str()) {
                        synthetic.push(MessageWithEventId {
                            message: Message {
                                role: "toolResult".to_string(),
                                content: Value::String(
                                    "Tool execution was interrupted.".to_string(),
                                ),
                                tool_call_id: Some(tc_id.clone()),
                                is_error: Some(true),
                            },
                            event_ids: vec![None],
                        });
                    }
                }

                if !synthetic.is_empty() {
                    insertions.push((i + 1, synthetic));
                }
            }
        }
        i += 1;
    }

    // Apply insertions in reverse order to preserve indices
    for (idx, msgs) in insertions.into_iter().rev() {
        let _ = combined.splice(idx..idx, msgs.into_iter());
    }
}

/// Extract all `tool_use` block IDs from a message's content.
fn extract_tool_use_ids(content: &Value) -> Vec<String> {
    match content {
        Value::Array(arr) => arr
            .iter()
            .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_use"))
            .filter_map(|block| block.get("id").and_then(Value::as_str).map(String::from))
            .collect(),
        _ => vec![],
    }
}

/// Flush pending tool results as `toolResult` messages.
fn flush_tool_results(
    combined: &mut Vec<MessageWithEventId>,
    pending: &mut Vec<PendingToolResult>,
) {
    for tr in pending.drain(..) {
        combined.push(MessageWithEventId {
            message: Message {
                role: "toolResult".to_string(),
                content: Value::String(tr.content),
                tool_call_id: Some(tr.tool_call_id),
                is_error: Some(tr.is_error),
            },
            event_ids: vec![None],
        });
    }
}

/// Merge content from two messages of the same role.
fn merge_message_content(existing: &Value, incoming: &Value, role: &str) -> Value {
    if role == "user" {
        let existing_blocks = normalize_user_content(existing);
        let incoming_blocks = normalize_user_content(incoming);
        let mut merged = existing_blocks;
        merged.extend(incoming_blocks);
        Value::Array(merged)
    } else {
        // Assistant: both should be arrays, concatenate
        let existing_arr = match existing {
            Value::Array(a) => a.clone(),
            _ => vec![],
        };
        let incoming_arr = match incoming {
            Value::Array(a) => a.clone(),
            _ => vec![],
        };
        let mut merged = existing_arr;
        merged.extend(incoming_arr);
        Value::Array(merged)
    }
}

/// Normalize user content to array of content blocks.
fn normalize_user_content(content: &Value) -> Vec<Value> {
    match content {
        Value::String(s) => {
            vec![serde_json::json!({"type": "text", "text": s})]
        }
        Value::Array(arr) => arr.clone(),
        _ => vec![],
    }
}

/// Check if content contains any `tool_use` blocks.
fn content_has_tool_use(content: &Value) -> bool {
    match content {
        Value::Array(arr) => arr
            .iter()
            .any(|block| block.get("type").and_then(Value::as_str) == Some("tool_use")),
        _ => false,
    }
}

/// Restore truncated `tool_use` inputs from the tool call args map.
fn restore_truncated_inputs(
    content: &Value,
    tool_call_args_map: &std::collections::HashMap<String, Value>,
) -> Value {
    match content {
        Value::Array(arr) => {
            let restored: Vec<Value> = arr
                .iter()
                .map(|block| {
                    let is_tool_use =
                        block.get("type").and_then(Value::as_str) == Some("tool_use");
                    let is_truncated = block
                        .get("input")
                        .and_then(|i| i.get("_truncated"))
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let block_id = block.get("id").and_then(Value::as_str);

                    if is_tool_use && is_truncated {
                        if let Some(id) = block_id {
                            if let Some(full_args) = tool_call_args_map.get(id) {
                                let mut restored_block = block.clone();
                                restored_block["input"] = full_args.clone();
                                return restored_block;
                            }
                        }
                    }
                    block.clone()
                })
                .collect();
            Value::Array(restored)
        }
        other => other.clone(),
    }
}

/// Accumulate token usage from a payload's `tokenUsage` field.
fn accumulate_tokens(payload: &Value, tokens: &mut ReconstructedTokenUsage) {
    if let Some(tu) = payload.get("tokenUsage") {
        tokens.input_tokens += tu.get("inputTokens").and_then(Value::as_i64).unwrap_or(0);
        tokens.output_tokens += tu.get("outputTokens").and_then(Value::as_i64).unwrap_or(0);
        tokens.cache_read_tokens += tu
            .get("cacheReadTokens")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        tokens.cache_creation_tokens += tu
            .get("cacheCreationTokens")
            .and_then(Value::as_i64)
            .unwrap_or(0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::types::EventType;

    /// Helper: create a minimal session event.
    fn ev(event_type: EventType, payload: Value) -> SessionEvent {
        SessionEvent {
            id: format!("evt_{}", uuid::Uuid::now_v7()),
            parent_id: None,
            session_id: "sess_test".to_string(),
            workspace_id: "ws_test".to_string(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            event_type,
            sequence: 0,
            checksum: None,
            payload,
        }
    }

    /// Helper: create a session event with a specific ID.
    fn ev_with_id(id: &str, event_type: EventType, payload: Value) -> SessionEvent {
        SessionEvent {
            id: id.to_string(),
            parent_id: None,
            session_id: "sess_test".to_string(),
            workspace_id: "ws_test".to_string(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            event_type,
            sequence: 0,
            checksum: None,
            payload,
        }
    }

    /// Helper: extract messages from reconstruction result.
    fn get_messages(result: &ReconstructionResult) -> Vec<&Message> {
        result
            .messages_with_event_ids
            .iter()
            .map(|m| &m.message)
            .collect()
    }

    fn session_start() -> SessionEvent {
        ev(
            EventType::SessionStart,
            serde_json::json!({"workingDirectory": "/test", "model": "claude-opus-4-6"}),
        )
    }

    // ── Empty input ──────────────────────────────────────────────────

    #[test]
    fn empty_events_returns_empty() {
        let result = reconstruct_from_events(&[]);
        assert!(result.messages_with_event_ids.is_empty());
        assert_eq!(result.turn_count, 0);
        assert!(result.reasoning_level.is_none());
        assert!(result.system_prompt.is_none());
    }

    #[test]
    fn session_start_only_no_messages() {
        let result = reconstruct_from_events(&[session_start()]);
        assert!(result.messages_with_event_ids.is_empty());
    }

    // ── Basic messages ───────────────────────────────────────────────

    #[test]
    fn single_user_message() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Hello"}),
            ),
        ];
        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[0].content, "Hello");
    }

    #[test]
    fn user_and_assistant() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Hello"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Hi there"}],
                    "turn": 1,
                }),
            ),
        ];
        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[1].content[0]["text"], "Hi there");
        assert_eq!(result.turn_count, 1);
    }

    // ── Tool result output format ────────────────────────────────────

    #[test]
    fn tool_results_as_tool_result_messages() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use a tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "text", "text": "I will use a tool."},
                        {"type": "tool_use", "id": "call_123", "name": "TestTool", "input": {"arg": "value"}}
                    ],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 50, "outputTokens": 25}
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_123", "content": "Tool output", "isError": false}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "The tool returned: Tool output"}],
                    "turn": 2,
                    "tokenUsage": {"inputTokens": 75, "outputTokens": 40}
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant, toolResult, assistant
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[3].role, "assistant");

        // Verify toolResult format
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("call_123"));
        assert_eq!(msgs[2].content, "Tool output");
        assert_eq!(msgs[2].is_error, Some(false));
    }

    #[test]
    fn multiple_tool_results_as_separate_messages() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use multiple tools"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "tool_use", "id": "call_1", "name": "Tool1", "input": {}},
                        {"type": "tool_use", "id": "call_2", "name": "Tool2", "input": {}}
                    ],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 60, "outputTokens": 30}
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Result 1", "isError": false}),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_2", "content": "Result 2", "isError": true}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Done"}],
                    "turn": 2,
                    "tokenUsage": {"inputTokens": 80, "outputTokens": 35}
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant, toolResult, toolResult, assistant
        assert_eq!(msgs.len(), 5);
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].content, "Result 1");
        assert_eq!(msgs[2].is_error, Some(false));

        assert_eq!(msgs[3].role, "toolResult");
        assert_eq!(msgs[3].tool_call_id.as_deref(), Some("call_2"));
        assert_eq!(msgs[3].content, "Result 2");
        assert_eq!(msgs[3].is_error, Some(true));
    }

    #[test]
    fn agentic_loop_flushes_between_turns() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Start agentic loop"}),
            ),
            // First tool call
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_1", "name": "Tool1", "input": {}}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 45, "outputTokens": 20}
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Result 1", "isError": false}),
            ),
            // Second tool call (continuation)
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_2", "name": "Tool2", "input": {}}],
                    "turn": 2,
                    "tokenUsage": {"inputTokens": 65, "outputTokens": 28}
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_2", "content": "Result 2", "isError": false}),
            ),
            // Final response
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "All done!"}],
                    "turn": 3,
                    "tokenUsage": {"inputTokens": 85, "outputTokens": 42}
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant, toolResult, assistant, toolResult, assistant
        assert_eq!(msgs.len(), 6);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[3].role, "assistant");
        assert_eq!(msgs[4].role, "toolResult");
        assert_eq!(msgs[5].role, "assistant");
    }

    #[test]
    fn tool_results_at_end_of_conversation() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run a tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_1", "name": "Tool", "input": {}}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 40, "outputTokens": 18}
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Tool finished", "isError": false}),
            ),
            // No more events — simulates mid-agentic-loop resume
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant, toolResult
        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].content, "Tool finished");
    }

    // ── Message merging ──────────────────────────────────────────────

    #[test]
    fn merge_consecutive_user_messages() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "First message"}),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Second message"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].role, "user");

        // Content should be merged into array
        let content = msgs[0].content.as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["text"], "First message");
        assert_eq!(content[1]["text"], "Second message");
    }

    #[test]
    fn merge_consecutive_user_messages_tracks_event_ids() {
        let e1 = ev_with_id(
            "evt_user_1",
            EventType::MessageUser,
            serde_json::json!({"content": "First"}),
        );
        let e2 = ev_with_id(
            "evt_user_2",
            EventType::MessageUser,
            serde_json::json!({"content": "Second"}),
        );
        let events = vec![session_start(), e1, e2];

        let result = reconstruct_from_events(&events);

        assert_eq!(result.messages_with_event_ids.len(), 1);
        let entry = &result.messages_with_event_ids[0];
        assert_eq!(entry.event_ids.len(), 2);
        assert_eq!(entry.event_ids[0].as_deref(), Some("evt_user_1"));
        assert_eq!(entry.event_ids[1].as_deref(), Some("evt_user_2"));
    }

    #[test]
    fn merge_user_messages_with_array_content() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": [{"type": "text", "text": "Block A"}]}),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": [{"type": "text", "text": "Block B"}]}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        assert_eq!(msgs.len(), 1);
        let content = msgs[0].content.as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["text"], "Block A");
        assert_eq!(content[1]["text"], "Block B");
    }

    #[test]
    fn user_interrupt_injects_synthetic_tool_result() {
        // When user interrupts after tool calls, pending results are discarded
        // but synthetic error results are injected to maintain provider compatibility.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_1", "name": "Tool", "input": {}}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 50, "outputTokens": 25}
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Result", "isError": false}),
            ),
            // User interrupts — pending tool results are discarded, but
            // synthetic error results are injected for provider compatibility.
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Actually, never mind"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(tool_use), toolResult(synthetic), user
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].is_error, Some(true));
        assert_eq!(msgs[2].content, "Tool execution was interrupted.");
        assert_eq!(msgs[3].role, "user");
    }

    // ── Compaction ───────────────────────────────────────────────────

    #[test]
    fn compaction_clears_and_injects_synthetic_pair() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Old message"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Old response"}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 30, "outputTokens": 15}
                }),
            ),
            ev(
                EventType::CompactSummary,
                serde_json::json!({"summary": "Previous conversation summary"}),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "New message"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // synthetic user (summary), synthetic assistant, real user
        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[0].role, "user");
        assert!(msgs[0].content.as_str().unwrap().contains("Context from earlier"));
        assert!(msgs[0]
            .content
            .as_str()
            .unwrap()
            .contains("Previous conversation summary"));
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "user");
        assert_eq!(msgs[2].content, "New message");
    }

    #[test]
    fn compaction_synthetic_messages_have_none_event_ids() {
        let events = vec![
            session_start(),
            ev(
                EventType::CompactSummary,
                serde_json::json!({"summary": "Summary text"}),
            ),
        ];

        let result = reconstruct_from_events(&events);

        assert_eq!(result.messages_with_event_ids.len(), 2);
        assert_eq!(result.messages_with_event_ids[0].event_ids, vec![None]);
        assert_eq!(result.messages_with_event_ids[1].event_ids, vec![None]);
    }

    #[test]
    fn compaction_clears_pending_tool_results() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_1", "name": "Tool", "input": {}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Result", "isError": false}),
            ),
            // Compaction clears everything including pending tool results
            ev(
                EventType::CompactSummary,
                serde_json::json!({"summary": "Summary"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // Only synthetic pair (no lingering tool result)
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
    }

    // ── Context cleared ──────────────────────────────────────────────

    #[test]
    fn context_cleared_discards_all_messages() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Old message"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Old response"}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::ContextCleared,
                serde_json::json!({}),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Fresh start"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // Only the post-clear message
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[0].content, "Fresh start");
    }

    // ── Message deletion ─────────────────────────────────────────────

    #[test]
    fn deleted_message_excluded() {
        let user_evt = ev_with_id(
            "evt_user",
            EventType::MessageUser,
            serde_json::json!({"content": "Delete me"}),
        );
        let events = vec![
            session_start(),
            user_evt,
            ev(
                EventType::MessageDeleted,
                serde_json::json!({"targetEventId": "evt_user"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert!(result.messages_with_event_ids.is_empty());
    }

    #[test]
    fn deletion_only_affects_targeted_event() {
        let e1 = ev_with_id(
            "evt_keep",
            EventType::MessageUser,
            serde_json::json!({"content": "Keep me"}),
        );
        let e2 = ev_with_id(
            "evt_delete",
            EventType::MessageUser,
            serde_json::json!({"content": "Delete me"}),
        );
        let events = vec![
            session_start(),
            e1,
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Response"}],
                    "turn": 1,
                }),
            ),
            e2,
            ev(
                EventType::MessageDeleted,
                serde_json::json!({"targetEventId": "evt_delete"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user (kept), assistant — the second user msg is deleted
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].content, "Keep me");
    }

    // ── Token usage ──────────────────────────────────────────────────

    #[test]
    fn token_usage_accumulation() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Hello"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Hi"}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 100, "outputTokens": 50, "cacheReadTokens": 10}
                }),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "More"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "More response"}],
                    "turn": 2,
                    "tokenUsage": {"inputTokens": 150, "outputTokens": 75, "cacheCreationTokens": 20}
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);

        assert_eq!(result.token_usage.input_tokens, 250);
        assert_eq!(result.token_usage.output_tokens, 125);
        assert_eq!(result.token_usage.cache_read_tokens, 10);
        assert_eq!(result.token_usage.cache_creation_tokens, 20);
    }

    #[test]
    fn token_usage_from_user_messages() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({
                    "content": "Hello",
                    "tokenUsage": {"inputTokens": 5, "outputTokens": 0}
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert_eq!(result.token_usage.input_tokens, 5);
    }

    #[test]
    fn token_usage_defaults_to_zero() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Hello"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert_eq!(result.token_usage.input_tokens, 0);
        assert_eq!(result.token_usage.output_tokens, 0);
        assert_eq!(result.token_usage.cache_read_tokens, 0);
        assert_eq!(result.token_usage.cache_creation_tokens, 0);
    }

    // ── Tool argument restoration ────────────────────────────────────

    #[test]
    fn restore_truncated_tool_arguments() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{
                        "type": "tool_use",
                        "id": "call_1",
                        "name": "BigTool",
                        "input": {"_truncated": true}
                    }],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 55, "outputTokens": 22}
                }),
            ),
            ev(
                EventType::ToolCall,
                serde_json::json!({
                    "toolCallId": "call_1",
                    "name": "BigTool",
                    "arguments": {"largeArg": "Full argument value"}
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Done", "isError": false}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // Assistant message should have restored arguments
        let tool_use = &msgs[1].content[0];
        assert_eq!(tool_use["input"]["largeArg"], "Full argument value");
        // _truncated should be gone
        assert!(tool_use["input"].get("_truncated").is_none());
    }

    #[test]
    fn non_truncated_tool_use_unchanged() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{
                        "type": "tool_use",
                        "id": "call_1",
                        "name": "Tool",
                        "input": {"arg": "value"}
                    }],
                    "turn": 1,
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        let tool_use = &msgs[1].content[0];
        assert_eq!(tool_use["input"]["arg"], "value");
    }

    // ── Reasoning level ──────────────────────────────────────────────

    #[test]
    fn reasoning_level_from_config() {
        let events = vec![
            session_start(),
            ev(
                EventType::ConfigReasoningLevel,
                serde_json::json!({"newLevel": "high"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert_eq!(result.reasoning_level.as_deref(), Some("high"));
    }

    #[test]
    fn reasoning_level_last_wins() {
        let events = vec![
            session_start(),
            ev(
                EventType::ConfigReasoningLevel,
                serde_json::json!({"newLevel": "low"}),
            ),
            ev(
                EventType::ConfigReasoningLevel,
                serde_json::json!({"newLevel": "medium"}),
            ),
            ev(
                EventType::ConfigReasoningLevel,
                serde_json::json!({"newLevel": "xhigh"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert_eq!(result.reasoning_level.as_deref(), Some("xhigh"));
    }

    // ── System prompt ────────────────────────────────────────────────

    #[test]
    fn system_prompt_from_session_start() {
        let events = vec![ev(
            EventType::SessionStart,
            serde_json::json!({
                "workingDirectory": "/test",
                "model": "claude-opus-4-6",
                "systemPrompt": "You are a helpful assistant."
            }),
        )];

        let result = reconstruct_from_events(&events);
        assert_eq!(
            result.system_prompt.as_deref(),
            Some("You are a helpful assistant.")
        );
    }

    #[test]
    fn system_prompt_from_config_prompt_update() {
        let events = vec![
            session_start(),
            ev(
                EventType::ConfigPromptUpdate,
                serde_json::json!({"newHash": "abc123", "contentBlobId": "blob_1"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert_eq!(
            result.system_prompt.as_deref(),
            Some("[Updated prompt - hash: abc123]")
        );
    }

    #[test]
    fn system_prompt_not_updated_without_blob_id() {
        let events = vec![
            ev(
                EventType::SessionStart,
                serde_json::json!({
                    "workingDirectory": "/test",
                    "model": "claude-opus-4-6",
                    "systemPrompt": "Original"
                }),
            ),
            ev(
                EventType::ConfigPromptUpdate,
                serde_json::json!({"newHash": "abc123"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert_eq!(result.system_prompt.as_deref(), Some("Original"));
    }

    // ── Turn count ───────────────────────────────────────────────────

    #[test]
    fn turn_count_highest_turn_seen() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Hello"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Hi"}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "More"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "More response"}],
                    "turn": 5,
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        assert_eq!(result.turn_count, 5);
    }

    // ── Complex agentic loop ─────────────────────────────────────────

    #[test]
    fn complex_agentic_loop() {
        let events = vec![
            session_start(),
            // User asks
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run multiple tools"}),
            ),
            // Assistant calls first tool
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_1", "name": "Bash", "input": {"command": "ls"}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::ToolCall,
                serde_json::json!({"toolCallId": "call_1", "name": "Bash", "arguments": {"command": "ls"}}),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "file1.txt", "isError": false}),
            ),
            // Assistant calls second tool
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_2", "name": "Read", "input": {"path": "file1.txt"}}],
                    "turn": 2,
                }),
            ),
            ev(
                EventType::ToolCall,
                serde_json::json!({"toolCallId": "call_2", "name": "Read", "arguments": {"path": "file1.txt"}}),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_2", "content": "Hello World", "isError": false}),
            ),
            // Assistant gives final answer
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "The file contains Hello World."}],
                    "turn": 3,
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(tool_use), toolResult, assistant(tool_use), toolResult, assistant(text)
        assert_eq!(msgs.len(), 6);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[3].role, "assistant");
        assert_eq!(msgs[4].role, "toolResult");
        assert_eq!(msgs[5].role, "assistant");
        assert_eq!(msgs[5].content[0]["text"], "The file contains Hello World.");
    }

    // ── Compaction followed by new messages ──────────────────────────

    #[test]
    fn compaction_then_new_messages() {
        let events = vec![
            session_start(),
            // Pre-compaction messages
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Old question"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Old answer"}],
                    "turn": 1,
                }),
            ),
            // Compaction
            ev(
                EventType::CompactSummary,
                serde_json::json!({"summary": "User asked a question. Assistant answered."}),
            ),
            // Post-compaction new conversation
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "New question"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "New answer"}],
                    "turn": 2,
                    "tokenUsage": {"inputTokens": 200, "outputTokens": 100}
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // synthetic user, synthetic assistant, new user, new assistant
        assert_eq!(msgs.len(), 4);
        assert!(msgs[0].content.as_str().unwrap().contains("Context from earlier"));
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].content, "New question");
        assert_eq!(msgs[3].content[0]["text"], "New answer");
    }

    // ── Event IDs for synthetic messages ─────────────────────────────

    #[test]
    fn tool_result_messages_have_none_event_ids() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_1", "name": "T", "input": {}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "R", "isError": false}),
            ),
        ];

        let result = reconstruct_from_events(&events);

        // The toolResult message should have [None] as event_ids (synthetic)
        let tool_result_entry = &result.messages_with_event_ids[2];
        assert_eq!(tool_result_entry.message.role, "toolResult");
        assert_eq!(tool_result_entry.event_ids, vec![None]);
    }

    // ── Ignored event types ──────────────────────────────────────────

    #[test]
    fn irrelevant_events_ignored() {
        let events = vec![
            session_start(),
            ev(
                EventType::StreamTurnStart,
                serde_json::json!({}),
            ),
            ev(
                EventType::StreamTurnEnd,
                serde_json::json!({}),
            ),
            ev(
                EventType::SessionFork,
                serde_json::json!({}),
            ),
            ev(
                EventType::MetadataUpdate,
                serde_json::json!({}),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Hello"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].content, "Hello");
    }

    // ── Helper function tests ────────────────────────────────────────

    #[test]
    fn normalize_user_content_string() {
        let content = Value::String("hello".to_string());
        let blocks = normalize_user_content(&content);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0]["type"], "text");
        assert_eq!(blocks[0]["text"], "hello");
    }

    #[test]
    fn normalize_user_content_array() {
        let content = serde_json::json!([{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]);
        let blocks = normalize_user_content(&content);
        assert_eq!(blocks.len(), 2);
    }

    #[test]
    fn normalize_user_content_null() {
        let blocks = normalize_user_content(&Value::Null);
        assert!(blocks.is_empty());
    }

    #[test]
    fn content_has_tool_use_true() {
        let content = serde_json::json!([
            {"type": "text", "text": "hi"},
            {"type": "tool_use", "id": "call_1", "name": "T", "input": {}}
        ]);
        assert!(content_has_tool_use(&content));
    }

    #[test]
    fn content_has_tool_use_false() {
        let content = serde_json::json!([{"type": "text", "text": "hi"}]);
        assert!(!content_has_tool_use(&content));
    }

    #[test]
    fn content_has_tool_use_non_array() {
        assert!(!content_has_tool_use(&Value::String("hello".to_string())));
    }

    #[test]
    fn restore_truncated_inputs_no_truncation() {
        let content = serde_json::json!([
            {"type": "tool_use", "id": "call_1", "input": {"arg": "val"}}
        ]);
        let map = std::collections::HashMap::new();
        let result = restore_truncated_inputs(&content, &map);
        assert_eq!(result[0]["input"]["arg"], "val");
    }

    #[test]
    fn restore_truncated_inputs_with_truncation() {
        let content = serde_json::json!([
            {"type": "tool_use", "id": "call_1", "input": {"_truncated": true}}
        ]);
        let mut map = std::collections::HashMap::new();
        map.insert(
            "call_1".to_string(),
            serde_json::json!({"fullArg": "restored"}),
        );
        let result = restore_truncated_inputs(&content, &map);
        assert_eq!(result[0]["input"]["fullArg"], "restored");
        assert!(result[0]["input"].get("_truncated").is_none());
    }

    #[test]
    fn restore_truncated_inputs_missing_from_map() {
        let content = serde_json::json!([
            {"type": "tool_use", "id": "call_unknown", "input": {"_truncated": true}}
        ]);
        let map = std::collections::HashMap::new();
        let result = restore_truncated_inputs(&content, &map);
        // Should leave as-is when not in map
        assert_eq!(result[0]["input"]["_truncated"], true);
    }

    // ── Synthetic tool results for interrupted sessions ──────────────

    #[test]
    fn inject_synthetic_results_on_user_interrupt() {
        // Simulates: assistant makes tool calls, results arrive, user interrupts.
        // The user interrupt discards pending tool results, leaving unmatched
        // tool_use blocks. Synthetic error results should be injected.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "tool_use", "id": "call_1", "name": "Tool1", "input": {}},
                        {"type": "tool_use", "id": "call_2", "name": "Tool2", "input": {}}
                    ],
                    "turn": 1,
                }),
            ),
            // Tool results arrive but will be discarded by user interrupt
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Result 1", "isError": false}),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_2", "content": "Result 2", "isError": false}),
            ),
            // User interrupt discards pending tool results
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Never mind"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(tool_use x2), toolResult(call_1), toolResult(call_2), user
        assert_eq!(msgs.len(), 5);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].is_error, Some(true));
        assert_eq!(msgs[2].content, "Tool execution was interrupted.");
        assert_eq!(msgs[3].role, "toolResult");
        assert_eq!(msgs[3].tool_call_id.as_deref(), Some("call_2"));
        assert_eq!(msgs[3].is_error, Some(true));
        assert_eq!(msgs[4].role, "user");
        assert_eq!(msgs[4].content, "Never mind");
    }

    #[test]
    fn inject_synthetic_results_mid_execution() {
        // Session ends after assistant emits tool calls but before any results arrive.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "tool_use", "id": "call_1", "name": "Tool", "input": {}}
                    ],
                    "turn": 1,
                }),
            ),
            // No tool result events — session interrupted mid-execution
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(tool_use), toolResult(synthetic error)
        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].is_error, Some(true));
        assert_eq!(msgs[2].content, "Tool execution was interrupted.");
    }

    #[test]
    fn no_synthetic_results_when_all_matched() {
        // Normal flow: all tool calls have matching results. No synthetics needed.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use tool"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "call_1", "name": "Tool", "input": {}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Done", "isError": false}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "All done"}],
                    "turn": 2,
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant, toolResult, assistant — no synthetics
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].content, "Done");
        assert_eq!(msgs[2].is_error, Some(false));
    }

    #[test]
    fn partial_tool_results_injects_only_missing() {
        // One of two tool calls gets a result, the other doesn't.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use tools"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "tool_use", "id": "call_1", "name": "Tool1", "input": {}},
                        {"type": "tool_use", "id": "call_2", "name": "Tool2", "input": {}}
                    ],
                    "turn": 1,
                }),
            ),
            // Only call_1 gets a result
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "call_1", "content": "Result 1", "isError": false}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Continuing"}],
                    "turn": 2,
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(tool_use x2), synthetic(call_2), toolResult(call_1), assistant
        // The synthetic is injected right after assistant, before existing toolResults
        assert_eq!(msgs.len(), 5);
        assert_eq!(msgs[1].role, "assistant");
        // Synthetic injected first (for unmatched call_2)
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("call_2"));
        assert_eq!(msgs[2].is_error, Some(true));
        // Real result for call_1
        assert_eq!(msgs[3].role, "toolResult");
        assert_eq!(msgs[3].tool_call_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[3].is_error, Some(false));
        assert_eq!(msgs[4].role, "assistant");
    }

    #[test]
    fn cross_provider_resume_with_interrupted_tool_calls() {
        // Realistic scenario: Anthropic tool calls completed, then GPT tool calls interrupted.
        let events = vec![
            session_start(),
            // User prompt
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Help me with files"}),
            ),
            // Anthropic assistant uses tool (completed)
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "tool_use", "id": "toolu_abc", "name": "Read", "input": {"path": "file.txt"}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::ToolResult,
                serde_json::json!({"toolCallId": "toolu_abc", "content": "file contents", "isError": false}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Here are the contents."}],
                    "turn": 2,
                }),
            ),
            // User switches model, sends new prompt
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Now use GPT to do more"}),
            ),
            // GPT assistant uses tools (interrupted before results)
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "tool_use", "id": "call_gpt_1", "name": "Write", "input": {"path": "out.txt"}},
                        {"type": "tool_use", "id": "call_gpt_2", "name": "Bash", "input": {"command": "echo hi"}}
                    ],
                    "turn": 3,
                }),
            ),
            // Session interrupted — no tool.result events for GPT calls
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(toolu_abc), toolResult(toolu_abc), assistant(text),
        // user, assistant(call_gpt_1, call_gpt_2), toolResult(call_gpt_1), toolResult(call_gpt_2)
        assert_eq!(msgs.len(), 8);

        // Anthropic calls properly matched
        assert_eq!(msgs[2].role, "toolResult");
        assert_eq!(msgs[2].tool_call_id.as_deref(), Some("toolu_abc"));
        assert_eq!(msgs[2].is_error, Some(false));

        // GPT calls get synthetic error results
        assert_eq!(msgs[6].role, "toolResult");
        assert_eq!(msgs[6].tool_call_id.as_deref(), Some("call_gpt_1"));
        assert_eq!(msgs[6].is_error, Some(true));
        assert_eq!(msgs[6].content, "Tool execution was interrupted.");

        assert_eq!(msgs[7].role, "toolResult");
        assert_eq!(msgs[7].tool_call_id.as_deref(), Some("call_gpt_2"));
        assert_eq!(msgs[7].is_error, Some(true));
    }

    #[test]
    fn extract_tool_use_ids_from_content() {
        let content = serde_json::json!([
            {"type": "text", "text": "hello"},
            {"type": "tool_use", "id": "call_1", "name": "T", "input": {}},
            {"type": "tool_use", "id": "call_2", "name": "T2", "input": {}}
        ]);
        let ids = extract_tool_use_ids(&content);
        assert_eq!(ids, vec!["call_1", "call_2"]);
    }

    #[test]
    fn extract_tool_use_ids_no_tools() {
        let content = serde_json::json!([{"type": "text", "text": "hello"}]);
        let ids = extract_tool_use_ids(&content);
        assert!(ids.is_empty());
    }

    #[test]
    fn extract_tool_use_ids_non_array() {
        let ids = extract_tool_use_ids(&Value::String("hello".to_string()));
        assert!(ids.is_empty());
    }
}
