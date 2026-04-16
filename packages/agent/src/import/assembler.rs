//! Chunk reassembly for assistant messages.
//!
//! Claude Code stores one JSONL record per content block for assistant
//! messages. All chunks from one API response share the same `message.id`.
//! This module groups and merges them into single assembled messages.

use serde_json::Value;

use crate::import::types::{ClaudeRecord, ClaudeUsage, RecordKind};
use crate::import::tree::LinearRecord;

/// A fully reassembled assistant message.
#[derive(Debug)]
pub struct AssembledAssistant {
    /// API message ID.
    pub message_id: String,
    /// Merged content blocks (ordered).
    pub content_blocks: Vec<Value>,
    /// Model ID.
    pub model: String,
    /// Stop reason from the final chunk.
    pub stop_reason: String,
    /// Token usage (from the chunk that has it).
    pub usage: ClaudeUsage,
    /// Timestamp of the first chunk.
    pub timestamp: String,
    /// Assigned turn number.
    pub turn: i64,
}

/// Items produced by the assembler, ready for transformation.
#[derive(Debug)]
pub enum AssembledItem {
    /// A user message (may be a tool result, meta, or normal message).
    UserMessage {
        /// The original record.
        record: ClaudeRecord,
        /// Assigned turn number.
        turn: i64,
    },
    /// A fully reassembled assistant message.
    AssistantMessage(AssembledAssistant),
    /// A system record.
    SystemRecord {
        /// The original record.
        record: ClaudeRecord,
        /// Assigned turn number.
        turn: i64,
    },
    /// A session title extracted from a `custom-title` record.
    CustomTitle(String),
}

/// Assemble linearized records into importable items.
///
/// Groups consecutive assistant records by `message.id`, merges their
/// content arrays, and extracts usage/model/`stop_reason` from the final chunk.
pub fn assemble(records: Vec<LinearRecord>) -> Vec<AssembledItem> {
    let mut result = Vec::new();
    let mut assistant_group: Vec<(ClaudeRecord, i64)> = Vec::new();
    let mut current_message_id: Option<String> = None;

    for lr in records {
        let kind = lr.record.kind();

        if kind == RecordKind::Assistant {
            let msg_id = lr
                .record
                .message
                .as_ref()
                .and_then(|m| m.id.clone());

            let should_group = msg_id.is_some()
                && current_message_id.is_some()
                && msg_id == current_message_id;

            if should_group {
                assistant_group.push((lr.record, lr.turn));
            } else {
                // Flush previous group.
                flush_assistant_group(&mut assistant_group, &mut result);
                current_message_id = msg_id;
                assistant_group.push((lr.record, lr.turn));
            }
            continue;
        }

        // Non-assistant record: flush any pending assistant group first.
        flush_assistant_group(&mut assistant_group, &mut result);
        current_message_id = None;

        match kind {
            RecordKind::User => {
                result.push(AssembledItem::UserMessage {
                    record: lr.record,
                    turn: lr.turn,
                });
            }
            RecordKind::System => {
                result.push(AssembledItem::SystemRecord {
                    record: lr.record,
                    turn: lr.turn,
                });
            }
            RecordKind::CustomTitle => {
                if let Some(title) = lr.record.custom_title.clone() {
                    result.push(AssembledItem::CustomTitle(title));
                }
            }
            _ => {
                // Other record types (LastPrompt, AgentName, etc.) are skipped.
            }
        }
    }

    // Flush any trailing assistant group.
    flush_assistant_group(&mut assistant_group, &mut result);

    result
}

fn flush_assistant_group(
    group: &mut Vec<(ClaudeRecord, i64)>,
    result: &mut Vec<AssembledItem>,
) {
    if group.is_empty() {
        return;
    }

    let turn = group[0].1;
    let timestamp = group[0]
        .0
        .timestamp
        .clone()
        .unwrap_or_default();

    let message_id = group[0]
        .0
        .message
        .as_ref()
        .and_then(|m| m.id.clone())
        .unwrap_or_else(|| format!("assembled_{timestamp}"));

    let mut content_blocks = Vec::new();
    let mut model = String::new();
    let mut stop_reason = String::new();
    let mut usage = ClaudeUsage::default();

    for (record, _) in group.iter() {
        let Some(msg) = &record.message else {
            continue;
        };

        if model.is_empty() && let Some(m) = &msg.model {
            model.clone_from(m);
        }

        // Take stop_reason from last chunk that has one.
        if let Some(sr) = &msg.stop_reason {
            stop_reason.clone_from(sr);
        }

        if let Some(u) = &msg.usage && (u.input_tokens > 0 || u.output_tokens > 0) {
            usage = u.clone();
        }

        if let Some(content) = &msg.content && let Some(blocks) = content.as_array() {
            for block in blocks {
                if let Some(b) = process_content_block(block) {
                    content_blocks.push(b);
                }
            }
        }
    }

    result.push(AssembledItem::AssistantMessage(AssembledAssistant {
        message_id,
        content_blocks,
        model,
        stop_reason,
        usage,
        timestamp,
        turn,
    }));

    group.clear();
}

/// Process a content block: strip signatures from thinking blocks,
/// skip empty thinking blocks.
fn process_content_block(block: &Value) -> Option<Value> {
    let block_type = block.get("type").and_then(Value::as_str)?;

    if block_type == "thinking" {
        let thinking_text = block.get("thinking").and_then(Value::as_str).unwrap_or("");
        if thinking_text.is_empty() {
            return None; // Skip empty thinking blocks
        }
        // Strip signature field
        let mut cleaned = block.clone();
        if let Some(obj) = cleaned.as_object_mut() {
            let _ = obj.remove("signature");
        }
        return Some(cleaned);
    }

    Some(block.clone())
}

#[cfg(test)]
#[path = "assembler_tests.rs"]
mod tests;
