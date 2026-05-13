//! Record → Tron event mapping.
//!
//! Transforms [`AssembledItem`]s into [`TronEventSpec`]s ready for
//! appending to the event store. Each assembled item may produce zero
//! or more events (e.g. an assistant message emits `message.assistant`,
//! one `capability.invocation.started` per `tool_use` block, and `stream.turn_end`).

use serde_json::{Value, json};

use crate::domains::agent::runner::pipeline::persistence::build_token_record;
use crate::domains::import::assembler::{AssembledAssistant, AssembledItem};
use crate::domains::import::cost::estimate_cost;
use crate::domains::import::types::ClaudeRecord;
use crate::domains::session::event_store::types::EventType;
use crate::shared::messages::{Provider, TokenUsage};

/// A Tron event to be appended during import.
#[derive(Debug)]
pub struct TronEventSpec {
    /// Event type to append.
    pub event_type: EventType,
    /// Payload JSON (camelCase field names).
    pub payload: Value,
}

/// Result of transforming assembled items into Tron events.
#[derive(Debug)]
pub struct TransformResult {
    /// Events to append in order.
    pub events: Vec<TronEventSpec>,
    /// Session title (from custom-title record).
    pub title: Option<String>,
    /// Primary model used.
    pub model: String,
    /// Aggregate input tokens.
    pub total_input_tokens: i64,
    /// Aggregate output tokens.
    pub total_output_tokens: i64,
    /// Aggregate estimated cost (USD).
    pub total_cost: f64,
    /// Number of turns.
    pub turn_count: i64,
    /// Number of user + assistant messages.
    pub message_count: i64,
}

/// Transform assembled items into Tron event specs.
///
/// Emits exactly one `stream.turn_end` per turn, placed after the last
/// assistant message of that turn. Token usage and cost are accumulated
/// across all assistant messages within the same turn.
pub fn transform(items: Vec<AssembledItem>) -> TransformResult {
    let mut events = Vec::new();
    let mut title: Option<String> = None;
    let mut model = String::new();
    let mut total_input_tokens: i64 = 0;
    let mut total_output_tokens: i64 = 0;
    let mut total_cost: f64 = 0.0;
    let mut max_turn: i64 = 0;
    let mut message_count: i64 = 0;
    let mut last_turn_started: i64 = 0;

    // Cross-turn baseline for tokenRecord context window calculation
    let mut previous_baseline: u64 = 0;

    // Per-turn accumulation for deferred stream.turn_end
    let mut pending_turn: i64 = 0;
    let mut pending_turn_input: i64 = 0;
    let mut pending_turn_output: i64 = 0;
    let mut pending_turn_cache_read: i64 = 0;
    let mut pending_turn_cache_creation: i64 = 0;
    let mut pending_turn_cost: f64 = 0.0;
    let mut has_pending_turn_end = false;

    for item in items {
        match item {
            AssembledItem::UserMessage { record, turn } => {
                let is_meta = record.is_meta == Some(true);
                let is_compact = record.is_compact_summary == Some(true);
                let is_tool_result = record.is_tool_result();

                if is_meta {
                    continue;
                }

                if is_compact {
                    // Flush pending turn_end before compact boundary
                    if has_pending_turn_end {
                        flush_turn_end(
                            &mut events,
                            pending_turn,
                            pending_turn_input,
                            pending_turn_output,
                            pending_turn_cache_read,
                            pending_turn_cache_creation,
                            pending_turn_cost,
                        );
                        has_pending_turn_end = false;
                    }
                    emit_compact_from_user(&record, &mut events);
                    continue;
                }

                if is_tool_result {
                    emit_tool_results(&record, &mut events);
                    continue;
                }

                // Normal user message — flush pending turn_end from previous turn
                if has_pending_turn_end && turn > pending_turn {
                    flush_turn_end(
                        &mut events,
                        pending_turn,
                        pending_turn_input,
                        pending_turn_output,
                        pending_turn_cache_read,
                        pending_turn_cache_creation,
                        pending_turn_cost,
                    );
                    has_pending_turn_end = false;
                }

                if turn > last_turn_started {
                    events.push(TronEventSpec {
                        event_type: EventType::StreamTurnStart,
                        payload: json!({ "turn": turn }),
                    });
                    last_turn_started = turn;
                }

                let mut payload = json!({ "turn": turn });
                if let Some(msg) = &record.message
                    && let Some(content) = &msg.content
                {
                    payload["content"] = content.clone();
                    if let Some(blocks) = content.as_array() {
                        let image_count = blocks
                            .iter()
                            .filter(|b| b.get("type").and_then(Value::as_str) == Some("image"))
                            .count();
                        if image_count > 0 {
                            payload["imageCount"] = json!(image_count);
                        }
                    }
                }

                events.push(TronEventSpec {
                    event_type: EventType::MessageUser,
                    payload,
                });
                message_count += 1;
                if turn > max_turn {
                    max_turn = turn;
                }
            }
            AssembledItem::AssistantMessage(am) => {
                if model.is_empty() && !am.model.is_empty() {
                    model.clone_from(&am.model);
                }

                let cost = estimate_cost(&am.model, &am.usage);
                let has_thinking = am
                    .content_blocks
                    .iter()
                    .any(|b| b.get("type").and_then(Value::as_str) == Some("thinking"));

                // If this assistant is in a new turn, flush the previous turn_end
                if has_pending_turn_end && am.turn > pending_turn {
                    flush_turn_end(
                        &mut events,
                        pending_turn,
                        pending_turn_input,
                        pending_turn_output,
                        pending_turn_cache_read,
                        pending_turn_cache_creation,
                        pending_turn_cost,
                    );
                    has_pending_turn_end = false;
                }

                // Emit turn_start if not already emitted for this turn
                if am.turn > last_turn_started {
                    events.push(TronEventSpec {
                        event_type: EventType::StreamTurnStart,
                        payload: json!({ "turn": am.turn }),
                    });
                    last_turn_started = am.turn;
                }

                // message.assistant
                // Normalize content blocks: Claude Code uses "input" for tool_use
                // but Tron's AssistantContent::ToolUse expects "arguments".
                let normalized_blocks: Vec<Value> = am
                    .content_blocks
                    .iter()
                    .map(|b| normalize_assistant_block(b))
                    .collect();

                // Build tokenRecord (same structure as native sessions) so iOS
                // can read computed.contextWindowTokens for the context pill.
                let usage_for_record = TokenUsage {
                    input_tokens: am.usage.input_tokens.max(0) as u64,
                    output_tokens: am.usage.output_tokens.max(0) as u64,
                    cache_read_tokens: Some(am.usage.cache_read_input_tokens.max(0) as u64),
                    cache_creation_tokens: Some(am.usage.cache_creation_input_tokens.max(0) as u64),
                    cache_creation_5m_tokens: None,
                    cache_creation_1h_tokens: None,
                    provider_type: Some(Provider::Anthropic),
                };
                let token_record = build_token_record(
                    &usage_for_record,
                    Provider::Anthropic,
                    "import",
                    am.turn.max(0) as u32,
                    previous_baseline,
                );
                // Update baseline for next turn's delta calculation
                if let Some(computed) = token_record.get("computed") {
                    if let Some(cwt) = computed.get("contextWindowTokens").and_then(Value::as_u64) {
                        previous_baseline = cwt;
                    }
                }

                let mut assistant_payload = json!({
                    "content": normalized_blocks,
                    "turn": am.turn,
                    "tokenUsage": {
                        "inputTokens": am.usage.input_tokens,
                        "outputTokens": am.usage.output_tokens,
                        "cacheReadTokens": am.usage.cache_read_input_tokens,
                        "cacheCreationTokens": am.usage.cache_creation_input_tokens,
                    },
                    "tokenRecord": token_record,
                    "stopReason": am.stop_reason,
                    "model": am.model,
                });
                if has_thinking {
                    assistant_payload["hasThinking"] = json!(true);
                }

                events.push(TronEventSpec {
                    event_type: EventType::MessageAssistant,
                    payload: assistant_payload,
                });
                message_count += 1;

                // capability.invocation.started events — one per tool_use block
                emit_tool_calls(&am, &mut events);

                // Accumulate into pending turn_end (same turn adds up)
                if has_pending_turn_end && am.turn == pending_turn {
                    pending_turn_input += am.usage.input_tokens;
                    pending_turn_output += am.usage.output_tokens;
                    pending_turn_cache_read += am.usage.cache_read_input_tokens;
                    pending_turn_cache_creation += am.usage.cache_creation_input_tokens;
                    pending_turn_cost += cost;
                } else {
                    pending_turn = am.turn;
                    pending_turn_input = am.usage.input_tokens;
                    pending_turn_output = am.usage.output_tokens;
                    pending_turn_cache_read = am.usage.cache_read_input_tokens;
                    pending_turn_cache_creation = am.usage.cache_creation_input_tokens;
                    pending_turn_cost = cost;
                }
                has_pending_turn_end = true;

                total_input_tokens += am.usage.input_tokens;
                total_output_tokens += am.usage.output_tokens;
                total_cost += cost;
                if am.turn > max_turn {
                    max_turn = am.turn;
                }
            }
            AssembledItem::SystemRecord { record, .. } => {
                // Flush pending turn_end before system records
                if has_pending_turn_end {
                    flush_turn_end(
                        &mut events,
                        pending_turn,
                        pending_turn_input,
                        pending_turn_output,
                        pending_turn_cache_read,
                        pending_turn_cache_creation,
                        pending_turn_cost,
                    );
                    has_pending_turn_end = false;
                }

                let subtype = record.subtype.as_deref().unwrap_or("");
                match subtype {
                    "compact_boundary" => {
                        events.push(TronEventSpec {
                            event_type: EventType::CompactBoundary,
                            payload: json!({
                                "originalTokens": 0,
                                "compactedTokens": 0,
                                // Source logs don't carry the original trigger — tag as
                                // `imported` so reconstruction can distinguish these
                                // from native-emitted boundaries.
                                "reason": "imported",
                            }),
                        });
                    }
                    "api_error" => {
                        let error_msg = record
                            .message
                            .as_ref()
                            .and_then(|m| m.content.as_ref())
                            .and_then(|c| c.as_str())
                            .unwrap_or("Unknown API error")
                            .to_string();
                        events.push(TronEventSpec {
                            event_type: EventType::ErrorProvider,
                            payload: json!({
                                "provider": "anthropic",
                                "error": error_msg,
                                // Imported api_error records don't carry the
                                // original classification — mark as "unknown"
                                // so iOS renders a generic-icon pill instead
                                // of falling back to plain error text.
                                "category": "unknown",
                                "retryable": false,
                            }),
                        });
                    }
                    _ => {
                        // turn_duration, local_command, etc. — no Tron equivalent
                    }
                }
            }
            AssembledItem::CustomTitle(t) => {
                title = Some(t);
            }
        }
    }

    // Flush final pending turn_end
    if has_pending_turn_end {
        flush_turn_end(
            &mut events,
            pending_turn,
            pending_turn_input,
            pending_turn_output,
            pending_turn_cache_read,
            pending_turn_cache_creation,
            pending_turn_cost,
        );
    }

    TransformResult {
        events,
        title,
        model,
        total_input_tokens,
        total_output_tokens,
        total_cost,
        turn_count: max_turn,
        message_count,
    }
}

/// Emit `capability.invocation.started` events for each `tool_use` block in the assistant message.
fn emit_tool_calls(am: &AssembledAssistant, events: &mut Vec<TronEventSpec>) {
    for block in &am.content_blocks {
        if block.get("type").and_then(Value::as_str) != Some("tool_use") {
            continue;
        }
        let tool_call_id = block
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let name = block
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let arguments = block.get("input").cloned().unwrap_or(json!({}));

        events.push(TronEventSpec {
            event_type: EventType::CapabilityInvocationStarted,
            payload: json!({
                "toolCallId": tool_call_id,
                "name": name,
                "arguments": arguments,
                "turn": am.turn,
            }),
        });
    }
}

/// Emit `capability.invocation.completed` events from a `tool_result` user record.
fn emit_tool_results(record: &ClaudeRecord, events: &mut Vec<TronEventSpec>) {
    let Some(msg) = &record.message else { return };
    let Some(content) = &msg.content else { return };
    let Some(blocks) = content.as_array() else {
        return;
    };

    for block in blocks {
        if block.get("type").and_then(Value::as_str) != Some("tool_result") {
            continue;
        }

        let tool_call_id = block
            .get("tool_use_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();

        let content_str = match block.get("content") {
            Some(Value::String(s)) => s.clone(),
            Some(v) => v.to_string(),
            None => String::new(),
        };

        let is_error = block
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        events.push(TronEventSpec {
            event_type: EventType::CapabilityInvocationCompleted,
            payload: json!({
                "toolCallId": tool_call_id,
                "content": content_str,
                "isError": is_error,
                "duration": 0,
            }),
        });
    }
}

/// Normalize an assistant content block into Tron's current import schema.
///
/// Claude Code stores tool_use blocks with `"input"` for arguments and an extra
/// `"caller"` field. Tron's `AssistantContent::ToolUse` expects `"arguments"`
/// and doesn't recognize `"caller"`, so deserialization silently fails without
/// this normalization.
fn normalize_assistant_block(block: &Value) -> Value {
    if block.get("type").and_then(Value::as_str) != Some("tool_use") {
        return block.clone();
    }
    let mut b = block.clone();
    if let Some(obj) = b.as_object_mut() {
        // Rename "input" → "arguments"
        if let Some(input) = obj.remove("input") {
            let _ = obj.insert("arguments".to_string(), input);
        }
        // Strip "caller" (Claude Code internal field, not in Tron schema)
        let _ = obj.remove("caller");
    }
    b
}

/// Emit compact.boundary + compact.summary from a compact summary user record.
fn emit_compact_from_user(record: &ClaudeRecord, events: &mut Vec<TronEventSpec>) {
    events.push(TronEventSpec {
        event_type: EventType::CompactBoundary,
        payload: json!({
            "originalTokens": 0,
            "compactedTokens": 0,
            // Source logs don't carry the original trigger — tag as `imported`.
            "reason": "imported",
        }),
    });

    let summary = record
        .message
        .as_ref()
        .and_then(|m| m.content.as_ref())
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string();

    events.push(TronEventSpec {
        event_type: EventType::CompactSummary,
        payload: json!({
            "summary": summary,
            "boundaryEventId": null,
        }),
    });
}

/// Flush accumulated turn stats as a single `stream.turn_end`.
fn flush_turn_end(
    events: &mut Vec<TronEventSpec>,
    turn: i64,
    input: i64,
    output: i64,
    cache_read: i64,
    cache_creation: i64,
    cost: f64,
) {
    events.push(TronEventSpec {
        event_type: EventType::StreamTurnEnd,
        payload: json!({
            "turn": turn,
            "tokenUsage": {
                "inputTokens": input,
                "outputTokens": output,
                "cacheReadTokens": cache_read,
                "cacheCreationTokens": cache_creation,
            },
            "cost": cost,
        }),
    });
}

#[cfg(test)]
#[path = "transformer_tests.rs"]
mod tests;
