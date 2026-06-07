//! Message reconstruction from event ancestry.
//!
//! [`reconstruct_from_events`] implements a two-pass algorithm that rebuilds
//! the message list from an ordered sequence of [`SessionEvent`]s:
//!
//! 1. **First pass**: collect deleted event IDs, capability invocation argument
//!    maps, and system prompt.
//! 2. **Second pass**: build messages while handling deletions, compaction,
//!    context clears, capability result injection, and consecutive-role merging.
//!
//! The output is a [`ReconstructionResult`] containing messages with event IDs,
//! aggregate token usage and turn count.
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

/// Prefix for compaction boundary summary messages, matching TypeScript `context/constants.ts`.
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
    /// Reasoning level is no longer a session event surface.
    pub reasoning_level: Option<String>,
    /// System prompt from `session.start`.
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
    system_prompt: Option<String>,
}

/// Pass 1: Collect deleted event IDs and capability invocation arguments.
fn collect_metadata(ancestors: &[SessionEvent]) -> Metadata {
    let mut deleted_event_ids = std::collections::HashSet::new();
    let mut capability_invocation_args_map = std::collections::HashMap::new();
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
            EventType::SessionStart => {
                if let Some(sp) = event.payload.get("systemPrompt").and_then(Value::as_str) {
                    system_prompt = Some(sp.to_string());
                }
            }
            _ => {}
        }
    }

    Metadata {
        deleted_event_ids,
        capability_invocation_args_map,
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
            EventType::CompactBoundary => handle_compact_boundary(event, &mut st),
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
        reasoning_level: None,
        system_prompt: metadata.system_prompt.clone(),
    }
}

/// Handle `compact.boundary`: clear older context and inject the durable summary pair.
fn handle_compact_boundary(event: &SessionEvent, st: &mut BuildState) {
    let Some(summary) = event.payload.get("summary").and_then(Value::as_str) else {
        return;
    };
    inject_compaction_summary_pair(summary, st);
}

fn inject_compaction_summary_pair(summary: &str, st: &mut BuildState) {
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
        .get("modelContextContent")
        .or_else(|| event.payload.get("content"))
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
#[path = "reconstruct/tests.rs"]
mod tests;
