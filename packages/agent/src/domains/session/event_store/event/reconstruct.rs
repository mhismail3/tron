//! Message reconstruction from event ancestry.
//!
//! [`reconstruct_from_events`] implements a two-pass algorithm that rebuilds
//! the message list from an ordered sequence of [`SessionEvent`]s:
//!
//! 1. **First pass**: collect deleted event IDs, capability invocation argument maps,
//!    reasoning level, and system prompt.
//! 2. **Second pass**: build messages while handling deletions, compaction,
//!    context clears, capability result injection, and consecutive-role merging.
//!
//! The output is a [`ReconstructionResult`] containing messages with event IDs,
//! aggregate token usage, turn count, and config state.
//!
//! ## Size note
//!
//! Both passes share mutable state (deleted IDs, capability invocation maps, message
//! accumulators). Splitting them across files would require passing 8+
//! mutable references through function boundaries with no readability gain.

use serde_json::Value;

use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::base::SessionEvent;
use crate::domains::session::event_store::types::payloads::TokenTotals;
use crate::domains::session::event_store::types::state::{Message, MessageWithEventId};

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
    pub token_usage: TokenTotals,
    /// Highest turn number seen.
    pub turn_count: i64,
    /// Last-seen reasoning level from `config.reasoning_level` events.
    pub reasoning_level: Option<String>,
    /// System prompt from `session.start` or `config.prompt_update`.
    pub system_prompt: Option<String>,
}

/// Pending capability result accumulated between assistant messages.
struct PendingCapabilityResult {
    invocation_id: String,
    content: String,
    is_error: bool,
}

/// Reconstruct messages and state from an ordered list of ancestor events.
///
/// Implements the two-pass reconstruction algorithm matching the TypeScript
/// `reconstructFromEvents` exactly:
///
/// - **Pass 1**: Metadata collection (deletions, capability args, config)
/// - **Pass 2**: Message building (merging, compaction, capability result injection)
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
    capability_invocation_args_map: std::collections::HashMap<String, Value>,
    reasoning_level: Option<String>,
    system_prompt: Option<String>,
}

/// Pass 1: Collect deleted event IDs, capability invocation arguments, and config state.
fn collect_metadata(ancestors: &[SessionEvent]) -> Metadata {
    let mut deleted_event_ids = std::collections::HashSet::new();
    let mut capability_invocation_args_map = std::collections::HashMap::new();
    let mut reasoning_level: Option<String> = None;
    let mut system_prompt: Option<String> = None;

    for event in ancestors {
        match event.event_type {
            EventType::MessageDeleted => {
                if let Some(target) = event.payload.get("targetEventId").and_then(Value::as_str) {
                    let _ = deleted_event_ids.insert(target.to_string());
                }
            }
            EventType::CapabilityInvocationStarted => {
                let tc_id = event.payload.get("invocationId").and_then(Value::as_str);
                let args = event.payload.get("arguments");
                if let (Some(id), Some(a)) = (tc_id, args) {
                    let _ = capability_invocation_args_map.insert(id.to_string(), a.clone());
                }
            }
            EventType::ConfigReasoningLevel => {
                reasoning_level = event
                    .payload
                    .get("newLevel")
                    .and_then(Value::as_str)
                    .map(String::from);
            }
            EventType::SessionStart => {
                if let Some(sp) = event.payload.get("systemPrompt").and_then(Value::as_str) {
                    system_prompt = Some(sp.to_string());
                }
            }
            EventType::ConfigPromptUpdate => {
                if event.payload.get("contentBlobId").is_some()
                    && let Some(hash) = event.payload.get("newHash").and_then(Value::as_str)
                {
                    system_prompt = Some(format!("[Updated prompt - hash: {hash}]"));
                }
            }
            _ => {}
        }
    }

    Metadata {
        deleted_event_ids,
        capability_invocation_args_map,
        reasoning_level,
        system_prompt,
    }
}

/// Pass 2: Build messages from events using metadata from pass 1.
/// Mutable state carried through the message-building pass.
struct BuildState {
    combined: Vec<MessageWithEventId>,
    tokens: TokenTotals,
    turn_count: i64,
    current_turn: i64,
    pending_capability_results: Vec<PendingCapabilityResult>,
}

/// Pass 2: Build messages from events using metadata from pass 1.
fn build_messages(ancestors: &[SessionEvent], metadata: &Metadata) -> ReconstructionResult {
    let mut st = BuildState {
        combined: Vec::new(),
        tokens: TokenTotals::default(),
        turn_count: 0,
        current_turn: 0,
        pending_capability_results: Vec::new(),
    };

    for event in ancestors {
        if metadata.deleted_event_ids.contains(&event.id) {
            continue;
        }
        match event.event_type {
            EventType::CompactSummary => handle_compact_summary(event, &mut st),
            EventType::ContextCleared => handle_context_cleared(&mut st),
            EventType::CapabilityInvocationCompleted => handle_capability_result(event, &mut st),
            EventType::MessageUser => handle_message_user(event, &mut st),
            EventType::MessageAssistant => handle_message_assistant(event, metadata, &mut st),
            _ => {}
        }
    }

    // End-of-stream flush: if last message is assistant with capability_invocation
    if !st.pending_capability_results.is_empty()
        && let Some(last) = st.combined.last()
        && last.message.role == "assistant"
        && content_has_capability_invocation(&last.message.content)
    {
        flush_capability_results(&mut st.combined, &mut st.pending_capability_results);
    }

    // Inject synthetic error results for any unmatched capability invocations.
    // This happens when: (a) a user interrupt discards pending capability results,
    // or (b) the session ended mid-capability-execution before results arrived.
    // Without this, providers like OpenAI reject the history because every
    // function_call must have a corresponding function_call_output.
    inject_missing_capability_results(&mut st.combined);

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
    st.pending_capability_results.clear();

    st.combined.push(MessageWithEventId {
        message: Message {
            role: "user".to_string(),
            content: Value::String(format!("{COMPACTION_SUMMARY_PREFIX}\n\n{summary}")),
            invocation_id: None,
            is_error: None,
        },
        event_ids: vec![None],
    });
    st.combined.push(MessageWithEventId {
        message: Message {
            role: "assistant".to_string(),
            content: serde_json::json!([{ "type": "text", "text": COMPACTION_ACK_TEXT }]),
            invocation_id: None,
            is_error: None,
        },
        event_ids: vec![None],
    });
}

/// Handle `context.cleared`: discard all messages.
fn handle_context_cleared(st: &mut BuildState) {
    st.combined.clear();
    st.pending_capability_results.clear();
}

/// Handle `capability.invocation.completed`: accumulate for later flushing.
fn handle_capability_result(event: &SessionEvent, st: &mut BuildState) {
    let tc_id = event
        .payload
        .get("invocationId")
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

    st.pending_capability_results.push(PendingCapabilityResult {
        invocation_id: tc_id,
        content,
        is_error,
    });
}

/// Handle `message.user`: merge consecutive, discard pending capability results.
fn handle_message_user(event: &SessionEvent, st: &mut BuildState) {
    st.pending_capability_results.clear();

    let content = event.payload.get("content").cloned().unwrap_or(Value::Null);

    if let Some(last) = st.combined.last_mut().filter(|e| e.message.role == "user") {
        last.message.content = merge_message_content(&last.message.content, &content, "user");
        last.event_ids.push(Some(event.id.clone()));
    } else {
        st.combined.push(MessageWithEventId {
            message: Message {
                role: "user".to_string(),
                content,
                invocation_id: None,
                is_error: None,
            },
            event_ids: vec![Some(event.id.clone())],
        });
    }
    accumulate_tokens(&event.payload, &mut st.tokens);
}

/// Handle `message.assistant`: restore truncated inputs, flush capability results,
/// merge consecutive, track turns.
fn handle_message_assistant(event: &SessionEvent, metadata: &Metadata, st: &mut BuildState) {
    let content = event.payload.get("content").cloned().unwrap_or(Value::Null);
    let restored_content =
        restore_truncated_inputs(&content, &metadata.capability_invocation_args_map);
    let has_capability_invocation = content_has_capability_invocation(&restored_content);

    // CASE 1: Last was assistant with pending capability results → flush first
    if st
        .combined
        .last()
        .is_some_and(|e| e.message.role == "assistant")
        && !st.pending_capability_results.is_empty()
    {
        flush_capability_results(&mut st.combined, &mut st.pending_capability_results);
    }

    // Re-check after potential flush — merge consecutive assistant messages
    if let Some(last) = st
        .combined
        .last_mut()
        .filter(|e| e.message.role == "assistant")
    {
        last.message.content =
            merge_message_content(&last.message.content, &restored_content, "assistant");
        last.event_ids.push(Some(event.id.clone()));
    } else {
        st.combined.push(MessageWithEventId {
            message: Message {
                role: "assistant".to_string(),
                content: restored_content,
                invocation_id: None,
                is_error: None,
            },
            event_ids: vec![Some(event.id.clone())],
        });
    }

    // CASE 2: This assistant has capability_invocation and pending results → flush
    if has_capability_invocation && !st.pending_capability_results.is_empty() {
        flush_capability_results(&mut st.combined, &mut st.pending_capability_results);
    }

    accumulate_tokens(&event.payload, &mut st.tokens);

    if let Some(turn) = event.payload.get("turn").and_then(Value::as_i64)
        && turn > st.current_turn
    {
        st.current_turn = turn;
        st.turn_count = turn;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Inject synthetic error `capabilityResult` messages for any assistant `capability_invocation`
/// blocks that lack a corresponding `capabilityResult` in the following messages.
///
/// Scans through the reconstructed message list and, for each assistant message
/// containing `capability_invocation` blocks, checks whether matching `capabilityResult` messages
/// exist before the next non-capabilityResult message. Any unmatched capability invocations get
/// a synthetic error result injected immediately after the assistant message.
fn inject_missing_capability_results(combined: &mut Vec<MessageWithEventId>) {
    let mut insertions: Vec<(usize, Vec<MessageWithEventId>)> = Vec::new();

    let mut i = 0;
    while i < combined.len() {
        if combined[i].message.role == "assistant" {
            let capability_invocation_ids =
                extract_capability_invocation_ids(&combined[i].message.content);
            if !capability_invocation_ids.is_empty() {
                // Collect invocation_ids from following capabilityResult messages
                let mut matched_ids = std::collections::HashSet::new();
                let mut j = i + 1;
                while j < combined.len() && combined[j].message.role == "capabilityResult" {
                    if let Some(ref tc_id) = combined[j].message.invocation_id {
                        let _ = matched_ids.insert(tc_id.clone());
                    }
                    j += 1;
                }

                // Find unmatched capability invocations
                let mut synthetic = Vec::new();
                for tc_id in &capability_invocation_ids {
                    if !matched_ids.contains(tc_id.as_str()) {
                        synthetic.push(MessageWithEventId {
                            message: Message {
                                role: "capabilityResult".to_string(),
                                content: Value::String(
                                    "Capability invocation was interrupted.".to_string(),
                                ),
                                invocation_id: Some(tc_id.clone()),
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

/// Extract all `capability_invocation` block IDs from a message's content.
fn extract_capability_invocation_ids(content: &Value) -> Vec<String> {
    match content {
        Value::Array(arr) => arr
            .iter()
            .filter(|block| {
                block.get("type").and_then(Value::as_str) == Some("capability_invocation")
            })
            .filter_map(|block| block.get("id").and_then(Value::as_str).map(String::from))
            .collect(),
        _ => vec![],
    }
}

/// Flush pending capability results as `capabilityResult` messages.
fn flush_capability_results(
    combined: &mut Vec<MessageWithEventId>,
    pending: &mut Vec<PendingCapabilityResult>,
) {
    for tr in pending.drain(..) {
        combined.push(MessageWithEventId {
            message: Message {
                role: "capabilityResult".to_string(),
                content: Value::String(tr.content),
                invocation_id: Some(tr.invocation_id),
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

/// Check if content contains any `capability_invocation` blocks.
fn content_has_capability_invocation(content: &Value) -> bool {
    match content {
        Value::Array(arr) => arr.iter().any(|block| {
            block.get("type").and_then(Value::as_str) == Some("capability_invocation")
        }),
        _ => false,
    }
}

/// Restore truncated `capability_invocation` inputs from the capability invocation args map.
fn restore_truncated_inputs(
    content: &Value,
    capability_invocation_args_map: &std::collections::HashMap<String, Value>,
) -> Value {
    match content {
        Value::Array(arr) => {
            let restored: Vec<Value> = arr
                .iter()
                .map(|block| {
                    let is_capability_invocation =
                        block.get("type").and_then(Value::as_str) == Some("capability_invocation");
                    let is_truncated = block
                        .get("arguments")
                        .and_then(|i| i.get("_truncated"))
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let block_id = block.get("id").and_then(Value::as_str);

                    if is_capability_invocation
                        && is_truncated
                        && let Some(id) = block_id
                        && let Some(full_args) = capability_invocation_args_map.get(id)
                    {
                        let mut restored_block = block.clone();
                        restored_block["arguments"] = full_args.clone();
                        return restored_block;
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
fn accumulate_tokens(payload: &Value, tokens: &mut TokenTotals) {
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

    // ── Capability result output format ────────────────────────────────────

    #[test]
    fn capability_results_as_capability_result_messages() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use a capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "text", "text": "I will use a capability."},
                        {"type": "capability_invocation", "id": "call_123", "name": "execute", "arguments": {"arg": "value"}}
                    ],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 50, "outputTokens": 25}
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_123", "content": "Capability output", "isError": false}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "The capability returned: Capability output"}],
                    "turn": 2,
                    "tokenUsage": {"inputTokens": 75, "outputTokens": 40}
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant, capabilityResult, assistant
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[3].role, "assistant");

        // Verify capabilityResult format
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_123"));
        assert_eq!(msgs[2].content, "Capability output");
        assert_eq!(msgs[2].is_error, Some(false));
    }

    #[test]
    fn multiple_capability_results_as_separate_messages() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use multiple capabilities"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}},
                        {"type": "capability_invocation", "id": "call_2", "name": "inspect", "arguments": {}}
                    ],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 60, "outputTokens": 30}
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_2", "content": "Result 2", "isError": true}),
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

        // user, assistant, capabilityResult, capabilityResult, assistant
        assert_eq!(msgs.len(), 5);
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].content, "Result 1");
        assert_eq!(msgs[2].is_error, Some(false));

        assert_eq!(msgs[3].role, "capabilityResult");
        assert_eq!(msgs[3].invocation_id.as_deref(), Some("call_2"));
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
            // First capability invocation
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 45, "outputTokens": 20}
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
            ),
            // Second capability invocation (continuation)
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_2", "name": "inspect", "arguments": {}}],
                    "turn": 2,
                    "tokenUsage": {"inputTokens": 65, "outputTokens": 28}
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_2", "content": "Result 2", "isError": false}),
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

        // user, assistant, capabilityResult, assistant, capabilityResult, assistant
        assert_eq!(msgs.len(), 6);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[3].role, "assistant");
        assert_eq!(msgs[4].role, "capabilityResult");
        assert_eq!(msgs[5].role, "assistant");
    }

    #[test]
    fn capability_results_at_end_of_conversation() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run a capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 40, "outputTokens": 18}
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Capability finished", "isError": false}),
            ),
            // No more events — simulates mid-agentic-loop resume
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant, capabilityResult
        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].content, "Capability finished");
    }

    #[test]
    fn reconstructed_capability_history_remains_provider_neutral() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Read this file"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{
                        "type": "capability_invocation",
                        "id": "toolu_01capability",
                        "name": "execute",
                        "arguments": {
                            "mode": "invoke",
                            "contractId": "filesystem::read_file",
                            "payload": {"path": "/tmp/example.txt"}
                        }
                    }],
                    "turn": 1
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({
                    "invocationId": "toolu_01capability",
                    "content": "example contents",
                    "isError": false,
                    "modelPrimitiveName": "execute",
                    "contractId": "filesystem::read_file",
                    "implementationId": "first_party.filesystem.v1.read_file",
                    "functionId": "filesystem::read_file",
                    "pluginId": "first_party.filesystem",
                    "workerId": "filesystem-worker",
                    "schemaDigest": "sha256:read",
                    "catalogRevision": 7,
                    "trustTier": "first_party_signed",
                    "riskLevel": "low",
                    "effectClass": "read",
                    "traceId": "trace-read",
                    "rootInvocationId": "root-read",
                    "bindingDecisionId": "binding-read"
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[1].content[0]["type"], "capability_invocation");
        assert_eq!(msgs[1].content[0]["name"], "execute");
        assert_eq!(
            msgs[1].content[0]["arguments"]["contractId"],
            "filesystem::read_file"
        );
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("toolu_01capability"));
        assert_eq!(msgs[2].content, "example contents");
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
    fn user_interrupt_injects_synthetic_capability_result() {
        // When user interrupts after capability invocations, pending results are discarded
        // but synthetic error results are injected to keep provider capability-invocation
        // state well-formed.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 50, "outputTokens": 25}
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Result", "isError": false}),
            ),
            // User interrupts — pending capability results are discarded, but
            // synthetic error results keep provider capability-invocation state well-formed.
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Actually, never mind"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(capability_invocation), capabilityResult(synthetic), user
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].is_error, Some(true));
        assert_eq!(msgs[2].content, "Capability invocation was interrupted.");
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
        assert!(
            msgs[0]
                .content
                .as_str()
                .unwrap()
                .contains("Context from earlier")
        );
        assert!(
            msgs[0]
                .content
                .as_str()
                .unwrap()
                .contains("Previous conversation summary")
        );
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
    fn compaction_clears_pending_capability_results() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Result", "isError": false}),
            ),
            // Compaction clears everything including pending capability results
            ev(
                EventType::CompactSummary,
                serde_json::json!({"summary": "Summary"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // Only synthetic pair (no lingering capability result)
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
            ev(EventType::ContextCleared, serde_json::json!({})),
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

    // ── Capability argument restoration ────────────────────────────────────

    #[test]
    fn restore_truncated_capability_arguments() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{
                        "type": "capability_invocation",
                        "id": "call_1",
                        "name": "BigTool",
                        "arguments": {"_truncated": true}
                    }],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 55, "outputTokens": 22}
                }),
            ),
            ev(
                EventType::CapabilityInvocationStarted,
                serde_json::json!({
                    "invocationId": "call_1",
                    "name": "BigTool",
                    "arguments": {"largeArg": "Full argument value"}
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Done", "isError": false}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // Assistant message should have restored arguments
        let capability_invocation = &msgs[1].content[0];
        assert_eq!(
            capability_invocation["arguments"]["largeArg"],
            "Full argument value"
        );
        // _truncated should be gone
        assert!(
            capability_invocation["arguments"]
                .get("_truncated")
                .is_none()
        );
    }

    #[test]
    fn non_truncated_capability_invocation_unchanged() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{
                        "type": "capability_invocation",
                        "id": "call_1",
                        "name": "execute",
                        "arguments": {"arg": "value"}
                    }],
                    "turn": 1,
                }),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        let capability_invocation = &msgs[1].content[0];
        assert_eq!(capability_invocation["arguments"]["arg"], "value");
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
                serde_json::json!({"content": "Run multiple capabilities"}),
            ),
            // Assistant calls first capability
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_1", "name": "process::run", "arguments": {"command": "ls"}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::CapabilityInvocationStarted,
                serde_json::json!({"invocationId": "call_1", "name": "process::run", "arguments": {"command": "ls"}}),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "file1.txt", "isError": false}),
            ),
            // Assistant calls second capability
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_2", "name": "filesystem::read_file", "arguments": {"path": "file1.txt"}}],
                    "turn": 2,
                }),
            ),
            ev(
                EventType::CapabilityInvocationStarted,
                serde_json::json!({"invocationId": "call_2", "name": "filesystem::read_file", "arguments": {"path": "file1.txt"}}),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_2", "content": "Hello World", "isError": false}),
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

        // user, assistant(capability_invocation), capabilityResult, assistant(capability_invocation), capabilityResult, assistant(text)
        assert_eq!(msgs.len(), 6);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[3].role, "assistant");
        assert_eq!(msgs[4].role, "capabilityResult");
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
        assert!(
            msgs[0]
                .content
                .as_str()
                .unwrap()
                .contains("Context from earlier")
        );
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].content, "New question");
        assert_eq!(msgs[3].content[0]["text"], "New answer");
    }

    // ── Event IDs for synthetic messages ─────────────────────────────

    #[test]
    fn capability_result_messages_have_none_event_ids() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_1", "name": "T", "arguments": {}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "R", "isError": false}),
            ),
        ];

        let result = reconstruct_from_events(&events);

        // The capabilityResult message should have [None] as event_ids (synthetic)
        let capability_result_entry = &result.messages_with_event_ids[2];
        assert_eq!(capability_result_entry.message.role, "capabilityResult");
        assert_eq!(capability_result_entry.event_ids, vec![None]);
    }

    // ── Ignored event types ──────────────────────────────────────────

    #[test]
    fn irrelevant_events_ignored() {
        let events = vec![
            session_start(),
            ev(EventType::StreamTurnStart, serde_json::json!({})),
            ev(EventType::StreamTurnEnd, serde_json::json!({})),
            ev(EventType::SessionFork, serde_json::json!({})),
            ev(EventType::MetadataUpdate, serde_json::json!({})),
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
        let content =
            serde_json::json!([{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]);
        let blocks = normalize_user_content(&content);
        assert_eq!(blocks.len(), 2);
    }

    #[test]
    fn normalize_user_content_null() {
        let blocks = normalize_user_content(&Value::Null);
        assert!(blocks.is_empty());
    }

    #[test]
    fn content_has_capability_invocation_true() {
        let content = serde_json::json!([
            {"type": "text", "text": "hi"},
            {"type": "capability_invocation", "id": "call_1", "name": "T", "arguments": {}}
        ]);
        assert!(content_has_capability_invocation(&content));
    }

    #[test]
    fn content_has_capability_invocation_false() {
        let content = serde_json::json!([{"type": "text", "text": "hi"}]);
        assert!(!content_has_capability_invocation(&content));
    }

    #[test]
    fn content_has_capability_invocation_non_array() {
        assert!(!content_has_capability_invocation(&Value::String(
            "hello".to_string()
        )));
    }

    #[test]
    fn restore_truncated_inputs_no_truncation() {
        let content = serde_json::json!([
            {"type": "capability_invocation", "id": "call_1", "arguments": {"arg": "val"}}
        ]);
        let map = std::collections::HashMap::new();
        let result = restore_truncated_inputs(&content, &map);
        assert_eq!(result[0]["arguments"]["arg"], "val");
    }

    #[test]
    fn restore_truncated_inputs_with_truncation() {
        let content = serde_json::json!([
            {"type": "capability_invocation", "id": "call_1", "arguments": {"_truncated": true}}
        ]);
        let mut map = std::collections::HashMap::new();
        map.insert(
            "call_1".to_string(),
            serde_json::json!({"fullArg": "restored"}),
        );
        let result = restore_truncated_inputs(&content, &map);
        assert_eq!(result[0]["arguments"]["fullArg"], "restored");
        assert!(result[0]["arguments"].get("_truncated").is_none());
    }

    #[test]
    fn restore_truncated_inputs_missing_from_map() {
        let content = serde_json::json!([
            {"type": "capability_invocation", "id": "call_unknown", "arguments": {"_truncated": true}}
        ]);
        let map = std::collections::HashMap::new();
        let result = restore_truncated_inputs(&content, &map);
        // Should leave as-is when not in map
        assert_eq!(result[0]["arguments"]["_truncated"], true);
    }

    // ── Synthetic capability results for interrupted sessions ──────────────

    #[test]
    fn inject_synthetic_results_on_user_interrupt() {
        // Simulates: assistant makes capability invocations, results arrive, user interrupts.
        // The user interrupt discards pending capability results, leaving unmatched
        // capability_invocation blocks. Synthetic error results should be injected.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}},
                        {"type": "capability_invocation", "id": "call_2", "name": "inspect", "arguments": {}}
                    ],
                    "turn": 1,
                }),
            ),
            // Capability results arrive but will be discarded by user interrupt
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_2", "content": "Result 2", "isError": false}),
            ),
            // User interrupt discards pending capability results
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Never mind"}),
            ),
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(capability_invocation x2), capabilityResult(call_1), capabilityResult(call_2), user
        assert_eq!(msgs.len(), 5);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].is_error, Some(true));
        assert_eq!(msgs[2].content, "Capability invocation was interrupted.");
        assert_eq!(msgs[3].role, "capabilityResult");
        assert_eq!(msgs[3].invocation_id.as_deref(), Some("call_2"));
        assert_eq!(msgs[3].is_error, Some(true));
        assert_eq!(msgs[4].role, "user");
        assert_eq!(msgs[4].content, "Never mind");
    }

    #[test]
    fn inject_synthetic_results_mid_execution() {
        // Session ends after assistant emits capability invocations but before any results arrive.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}
                    ],
                    "turn": 1,
                }),
            ),
            // No capability result events — session interrupted mid-execution
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(capability_invocation), capabilityResult(synthetic error)
        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[2].is_error, Some(true));
        assert_eq!(msgs[2].content, "Capability invocation was interrupted.");
    }

    #[test]
    fn no_synthetic_results_when_all_matched() {
        // Normal flow: all capability invocations have matching results. No synthetics needed.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Done", "isError": false}),
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

        // user, assistant, capabilityResult, assistant — no synthetics
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].content, "Done");
        assert_eq!(msgs[2].is_error, Some(false));
    }

    #[test]
    fn partial_capability_results_injects_only_missing() {
        // One of two capability invocations gets a result, the other doesn't.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Use capabilities"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}},
                        {"type": "capability_invocation", "id": "call_2", "name": "inspect", "arguments": {}}
                    ],
                    "turn": 1,
                }),
            ),
            // Only call_1 gets a result
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
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

        // user, assistant(capability_invocation x2), synthetic(call_2), capabilityResult(call_1), assistant
        // The synthetic is injected right after assistant, before existing capabilityResults
        assert_eq!(msgs.len(), 5);
        assert_eq!(msgs[1].role, "assistant");
        // Synthetic injected first (for unmatched call_2)
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_2"));
        assert_eq!(msgs[2].is_error, Some(true));
        // Real result for call_1
        assert_eq!(msgs[3].role, "capabilityResult");
        assert_eq!(msgs[3].invocation_id.as_deref(), Some("call_1"));
        assert_eq!(msgs[3].is_error, Some(false));
        assert_eq!(msgs[4].role, "assistant");
    }

    #[test]
    fn cross_provider_resume_with_interrupted_capability_invocations() {
        // Realistic scenario: Anthropic capability invocations completed, then GPT capability invocations interrupted.
        let events = vec![
            session_start(),
            // User prompt
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Help me with files"}),
            ),
            // Anthropic assistant uses capability (completed)
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "capability_invocation", "id": "toolu_abc", "name": "filesystem::read_file", "arguments": {"path": "file.txt"}}],
                    "turn": 1,
                }),
            ),
            ev(
                EventType::CapabilityInvocationCompleted,
                serde_json::json!({"invocationId": "toolu_abc", "content": "file contents", "isError": false}),
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
            // GPT assistant uses capabilities (interrupted before results)
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "capability_invocation", "id": "call_gpt_1", "name": "filesystem::write_file", "arguments": {"path": "out.txt"}},
                        {"type": "capability_invocation", "id": "call_gpt_2", "name": "process::run", "arguments": {"command": "echo hi"}}
                    ],
                    "turn": 3,
                }),
            ),
            // Session interrupted — no capability.invocation.completed events for GPT calls
        ];

        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(toolu_abc), capabilityResult(toolu_abc), assistant(text),
        // user, assistant(call_gpt_1, call_gpt_2), capabilityResult(call_gpt_1), capabilityResult(call_gpt_2)
        assert_eq!(msgs.len(), 8);

        // Anthropic calls properly matched
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("toolu_abc"));
        assert_eq!(msgs[2].is_error, Some(false));

        // GPT calls get synthetic error results
        assert_eq!(msgs[6].role, "capabilityResult");
        assert_eq!(msgs[6].invocation_id.as_deref(), Some("call_gpt_1"));
        assert_eq!(msgs[6].is_error, Some(true));
        assert_eq!(msgs[6].content, "Capability invocation was interrupted.");

        assert_eq!(msgs[7].role, "capabilityResult");
        assert_eq!(msgs[7].invocation_id.as_deref(), Some("call_gpt_2"));
        assert_eq!(msgs[7].is_error, Some(true));
    }

    // ── Interrupted session persistence scenarios ─────────────────

    #[test]
    fn interrupted_assistant_with_capability_invocation_gets_synthetic_results() {
        // Server persists partial message.assistant with interrupted=true + capability_invocation.
        // Reconstruction should inject synthetic capability results.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Do something"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "text", "text": "I'll help with"},
                        {"type": "capability_invocation", "id": "tc_1", "name": "execute", "arguments": {"command": "ls"}}
                    ],
                    "turn": 1,
                    "stopReason": "interrupted",
                    "interrupted": true,
                }),
            ),
        ];
        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(text + capability_invocation), synthetic capabilityResult
        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("tc_1"));
        assert_eq!(msgs[2].is_error, Some(true));
    }

    #[test]
    fn interrupted_text_only_assistant_reconstructs() {
        // Interrupted mid-text, no capability invocations — simpler case.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Tell me a story"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [{"type": "text", "text": "Once upon a time"}],
                    "turn": 1,
                    "stopReason": "interrupted",
                    "interrupted": true,
                }),
            ),
        ];
        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(text only) — no synthetic results needed
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[1].content[0]["text"], "Once upon a time");
    }

    #[test]
    fn interrupted_session_resume_reconstructs_full_history() {
        // Session interrupted, notification persisted, then user resumes.
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Run capability"}),
            ),
            ev(
                EventType::MessageAssistant,
                serde_json::json!({
                    "content": [
                        {"type": "capability_invocation", "id": "tc_1", "name": "execute", "arguments": {}}
                    ],
                    "turn": 1,
                    "stopReason": "interrupted",
                    "interrupted": true,
                }),
            ),
            ev(
                EventType::NotificationInterrupted,
                serde_json::json!({
                    "timestamp": "2026-02-17T00:00:00Z",
                    "turn": 1,
                }),
            ),
            // User resumes
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "Try again"}),
            ),
        ];
        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);

        // user, assistant(capability_invocation), synthetic capabilityResult, user
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[2].role, "capabilityResult");
        assert_eq!(msgs[2].is_error, Some(true));
        assert_eq!(msgs[2].invocation_id.as_deref(), Some("tc_1"));
        assert_eq!(msgs[3].role, "user");
        assert_eq!(msgs[3].content, "Try again");
    }

    #[test]
    fn extract_capability_invocation_ids_from_content() {
        let content = serde_json::json!([
            {"type": "text", "text": "hello"},
            {"type": "capability_invocation", "id": "call_1", "name": "T", "arguments": {}},
            {"type": "capability_invocation", "id": "call_2", "name": "T2", "arguments": {}}
        ]);
        let ids = extract_capability_invocation_ids(&content);
        assert_eq!(ids, vec!["call_1", "call_2"]);
    }

    #[test]
    fn extract_capability_invocation_ids_no_capabilities() {
        let content = serde_json::json!([{"type": "text", "text": "hello"}]);
        let ids = extract_capability_invocation_ids(&content);
        assert!(ids.is_empty());
    }

    #[test]
    fn extract_capability_invocation_ids_non_array() {
        let ids = extract_capability_invocation_ids(&Value::String("hello".to_string()));
        assert!(ids.is_empty());
    }

    // ── Multimodal user message reconstruction ──

    #[test]
    fn multimodal_user_message_reconstructs() {
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({
                    "content": [
                        {"type": "text", "text": "look at this"},
                        {"type": "image", "data": "base64img", "mimeType": "image/png"}
                    ],
                    "imageCount": 1
                }),
            ),
        ];
        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].role, "user");
        // Content should be the array, not stringified
        let content = &msgs[0].content;
        let arr = content.as_array().expect("content should be array");
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["type"], "text");
        assert_eq!(arr[1]["type"], "image");
        assert_eq!(arr[1]["data"], "base64img");
    }

    #[test]
    fn multimodal_user_content_merges_with_string() {
        // First user message is multimodal array, second is plain string
        let events = vec![
            session_start(),
            ev(
                EventType::MessageUser,
                serde_json::json!({
                    "content": [
                        {"type": "text", "text": "image here"},
                        {"type": "image", "data": "imgdata", "mimeType": "image/png"}
                    ]
                }),
            ),
            ev(
                EventType::MessageUser,
                serde_json::json!({"content": "follow up"}),
            ),
        ];
        let result = reconstruct_from_events(&events);
        let msgs = get_messages(&result);
        // Consecutive user messages merge
        assert_eq!(msgs.len(), 1);
        let arr = msgs[0]
            .content
            .as_array()
            .expect("merged content should be array");
        // First array's blocks + second normalized to [{type:text, text:...}]
        assert_eq!(arr.len(), 3);
        assert_eq!(arr[0]["type"], "text");
        assert_eq!(arr[0]["text"], "image here");
        assert_eq!(arr[1]["type"], "image");
        assert_eq!(arr[2]["type"], "text");
        assert_eq!(arr[2]["text"], "follow up");
    }

    // ── H16: reconstruction performance guardrail ─────────────────────
    //
    // `reconstruct_from_events` runs a two-pass O(N) walk over every
    // ancestor event. That's fine for today's session sizes (median
    // ~100 events per session in practice), but users have reported
    // tens-of-thousands-of-events sessions. The audit (H16) asked:
    // "is reconstruction linear in event count, and does that matter?"
    //
    // Rather than guess, we measure. The tests below construct
    // synthetic event chains at 100, 1 000, and 10 000 events and
    // assert:
    //
    // 1. Reconstruction completes inside a generous wall-clock budget
    //    (protects against quadratic regressions — e.g. a future
    //    "look up capability args by scanning the full list" refactor).
    // 2. Large chains still produce the expected aggregate message, turn,
    //    and token state. Tiny per-event timing ratios are too scheduler-
    //    sensitive for the full parallel suite, so the algorithmic guard is
    //    the 10k wall-clock budget plus deterministic output assertions.
    //
    // These tests are cheap enough to run in debug (~10ms for 10k
    // events on a local dev machine as of 2026-04-22) and protect the
    // reconstruction hot path from silent algorithmic regressions.
    // When median session size grows past 1k, revisit this guardrail
    // and consider the snapshot-at-compaction-boundary scheme from
    // the audit plan.

    fn build_synthetic_chain(count: usize) -> Vec<SessionEvent> {
        let mut events = Vec::with_capacity(count + 1);
        events.push(session_start());
        // Alternate user / assistant so the test exercises the
        // consecutive-role merging path and capability-arg-lookup path.
        for i in 0..count {
            if i.is_multiple_of(2) {
                events.push(ev(
                    EventType::MessageUser,
                    serde_json::json!({"content": format!("user prompt {i}")}),
                ));
            } else {
                let turn = (i as i64 / 2) + 1;
                events.push(ev(
                    EventType::MessageAssistant,
                    serde_json::json!({
                        "content": [{"type": "text", "text": format!("assistant reply {i}")}],
                        "turn": turn,
                        "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
                    }),
                ));
            }
        }
        events
    }

    #[test]
    fn reconstruct_completes_inside_budget_at_10k_events() {
        let events = build_synthetic_chain(10_000);
        let start = std::time::Instant::now();
        let result = reconstruct_from_events(&events);
        let elapsed = start.elapsed();

        // Generous 5s budget — a debug-mode quadratic regression on
        // 10k events would blow past this by orders of magnitude.
        // Release mode completes in well under 100ms on current
        // hardware; the wide margin is deliberate headroom for CI
        // runners and future event schema complexity.
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "reconstruction of 10k events took {elapsed:?} — possible quadratic regression"
        );
        // Sanity: the walk actually produced the messages we expect
        // so a silently-broken build doesn't pass the timing check.
        assert!(
            result.messages_with_event_ids.len() >= 5_000,
            "expected >=5000 messages, got {}",
            result.messages_with_event_ids.len()
        );
    }

    #[test]
    fn reconstruct_large_chain_preserves_aggregate_state() {
        let small = build_synthetic_chain(100);
        let large = build_synthetic_chain(10_000);

        let small = reconstruct_from_events(&small);
        let large = reconstruct_from_events(&large);

        assert!(
            large.messages_with_event_ids.len() >= small.messages_with_event_ids.len() * 50,
            "large reconstruction should preserve proportional message output (small={}, large={})",
            small.messages_with_event_ids.len(),
            large.messages_with_event_ids.len()
        );
        assert_eq!(large.turn_count, 5_000);
        assert_eq!(large.token_usage.input_tokens, 50_000);
        assert_eq!(large.token_usage.output_tokens, 25_000);
    }

    #[test]
    fn reconstruct_scales_to_1k_events() {
        // Middle-ground test: 1k is the size most real sessions cap
        // out at today; failures here are what a user would actually
        // notice as UI lag on reconnect.
        let events = build_synthetic_chain(1_000);
        let start = std::time::Instant::now();
        let result = reconstruct_from_events(&events);
        let elapsed = start.elapsed();

        assert!(
            elapsed < std::time::Duration::from_millis(500),
            "1k-event reconstruction took {elapsed:?} — user-perceptible"
        );
        assert!(result.messages_with_event_ids.len() >= 500);
    }
}
