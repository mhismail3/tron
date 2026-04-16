//! Record → Tron event mapping.
//!
//! Transforms [`AssembledItem`]s into [`TronEventSpec`]s ready for
//! appending to the event store. Each assembled item may produce zero
//! or more events (e.g. an assistant message emits `message.assistant`,
//! one `tool.call` per `tool_use` block, and `stream.turn_end`).

use serde_json::{json, Value};

use crate::events::types::EventType;
use crate::import::assembler::{AssembledAssistant, AssembledItem};
use crate::import::cost::estimate_cost;
use crate::import::types::ClaudeRecord;

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
                    emit_compact_from_user(&record, &mut events);
                    continue;
                }

                if is_tool_result {
                    emit_tool_results(&record, &mut events);
                    continue;
                }

                // Normal user message
                if turn > last_turn_started {
                    events.push(TronEventSpec {
                        event_type: EventType::StreamTurnStart,
                        payload: json!({ "turn": turn }),
                    });
                    last_turn_started = turn;
                }

                let mut payload = json!({ "turn": turn });
                if let Some(msg) = &record.message && let Some(content) = &msg.content {
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

                // Emit turn_start if not already emitted for this turn
                if am.turn > last_turn_started {
                    events.push(TronEventSpec {
                        event_type: EventType::StreamTurnStart,
                        payload: json!({ "turn": am.turn }),
                    });
                    last_turn_started = am.turn;
                }

                // message.assistant
                let mut assistant_payload = json!({
                    "content": am.content_blocks,
                    "turn": am.turn,
                    "tokenUsage": {
                        "inputTokens": am.usage.input_tokens,
                        "outputTokens": am.usage.output_tokens,
                        "cacheReadTokens": am.usage.cache_read_input_tokens,
                        "cacheCreationTokens": am.usage.cache_creation_input_tokens,
                    },
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

                // tool.call events — one per tool_use block
                emit_tool_calls(&am, &mut events);

                // stream.turn_end
                events.push(TronEventSpec {
                    event_type: EventType::StreamTurnEnd,
                    payload: json!({
                        "turn": am.turn,
                        "tokenUsage": {
                            "inputTokens": am.usage.input_tokens,
                            "outputTokens": am.usage.output_tokens,
                            "cacheReadTokens": am.usage.cache_read_input_tokens,
                            "cacheCreationTokens": am.usage.cache_creation_input_tokens,
                        },
                        "cost": cost,
                    }),
                });

                total_input_tokens += am.usage.input_tokens;
                total_output_tokens += am.usage.output_tokens;
                total_cost += cost;
                if am.turn > max_turn {
                    max_turn = am.turn;
                }
            }
            AssembledItem::SystemRecord { record, .. } => {
                let subtype = record.subtype.as_deref().unwrap_or("");
                match subtype {
                    "compact_boundary" => {
                        events.push(TronEventSpec {
                            event_type: EventType::CompactBoundary,
                            payload: json!({
                                "originalTokens": 0,
                                "compactedTokens": 0,
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

/// Emit `tool.call` events for each `tool_use` block in the assistant message.
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
            event_type: EventType::ToolCall,
            payload: json!({
                "toolCallId": tool_call_id,
                "name": name,
                "arguments": arguments,
                "turn": am.turn,
            }),
        });
    }
}

/// Emit `tool.result` events from a `tool_result` user record.
fn emit_tool_results(
    record: &ClaudeRecord,
    events: &mut Vec<TronEventSpec>,
) {
    let Some(msg) = &record.message else { return };
    let Some(content) = &msg.content else { return };
    let Some(blocks) = content.as_array() else { return };

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
            event_type: EventType::ToolResult,
            payload: json!({
                "toolCallId": tool_call_id,
                "content": content_str,
                "isError": is_error,
                "duration": 0,
            }),
        });

    }
}

/// Emit compact.boundary + compact.summary from a compact summary user record.
fn emit_compact_from_user(
    record: &ClaudeRecord,
    events: &mut Vec<TronEventSpec>,
) {
    events.push(TronEventSpec {
        event_type: EventType::CompactBoundary,
        payload: json!({
            "originalTokens": 0,
            "compactedTokens": 0,
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

#[cfg(test)]
#[path = "transformer_tests.rs"]
mod tests;
