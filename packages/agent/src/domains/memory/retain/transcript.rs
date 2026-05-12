//! Transcript serialization for retain summarization.

use std::collections::HashSet;

use serde_json::Value;

use crate::domains::session::event_store::types::state::Message;

const INTERACTIVE_TOOL_NAMES: &[&str] = &["agent::ask_user"];

/// First-pass scan to collect `tool_use` block IDs that belong to an
/// interactive tool. Their matching `tool_result` messages are then filtered
/// by [`serialize_for_memory`].
pub(super) fn collect_interactive_tool_use_ids(messages: &[Message]) -> HashSet<String> {
    let mut ids = HashSet::new();
    for msg in messages {
        let Some(arr) = msg.content.as_array() else {
            continue;
        };
        for block in arr {
            if block.get("type").and_then(Value::as_str) != Some("tool_use") {
                continue;
            }
            let Some(name) = block.get("name").and_then(Value::as_str) else {
                continue;
            };
            if !INTERACTIVE_TOOL_NAMES.contains(&name) {
                continue;
            }
            if let Some(id) = block.get("id").and_then(Value::as_str) {
                let _ = ids.insert(id.to_string());
            }
        }
    }
    ids
}

/// Extract a compact natural-language summary from an interactive-tool
/// `tool_use` block so the transcript preserves what the agent asked.
pub(super) fn extract_interactive_tool_summary(block: &Value) -> Option<String> {
    if block.get("type").and_then(Value::as_str) != Some("tool_use") {
        return None;
    }
    let name = block.get("name").and_then(Value::as_str)?;
    let input = block.get("input")?;

    match name {
        "agent::ask_user" => {
            let questions = input.get("questions").and_then(Value::as_array)?;
            let texts: Vec<String> = questions
                .iter()
                .filter_map(|q| q.get("question").and_then(Value::as_str))
                .map(|s| format!("\"{s}\""))
                .collect();
            if texts.is_empty() {
                None
            } else {
                Some(format!("Asked: {}", texts.join("; ")))
            }
        }
        _ => None,
    }
}

/// Serialize reconstructed messages to a plain-text transcript for summarization.
pub(super) fn serialize_for_memory(messages: &[Message]) -> String {
    const MAX_TEXT: usize = 300;
    const MAX_TOOL: usize = 150;
    const MAX_TOTAL: usize = 20_000;

    let interactive_ids = collect_interactive_tool_use_ids(messages);

    let mut lines = Vec::new();
    for msg in messages {
        match msg.role.as_str() {
            "user" => {
                let text = match &msg.content {
                    Value::String(s) => s.clone(),
                    Value::Array(arr) => arr
                        .iter()
                        .filter_map(|b| b.get("text").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join(" "),
                    _ => continue,
                };
                let t = truncate_str(&text, MAX_TEXT);
                if !t.is_empty() {
                    lines.push(format!("[USER] {t}"));
                }
            }
            "assistant" => {
                let mut parts: Vec<String> = Vec::new();
                match &msg.content {
                    Value::String(s) => {
                        if !s.is_empty() {
                            parts.push(s.clone());
                        }
                    }
                    Value::Array(arr) => {
                        for b in arr {
                            if let Some(t) = b.get("text").and_then(Value::as_str) {
                                if !t.is_empty() {
                                    parts.push(t.to_string());
                                }
                            } else if let Some(summary) = extract_interactive_tool_summary(b) {
                                parts.push(summary);
                            }
                        }
                    }
                    _ => continue,
                }
                let text = parts.join(" ");
                let t = truncate_str(&text, MAX_TEXT);
                if !t.is_empty() {
                    lines.push(format!("[ASSISTANT] {t}"));
                }
            }
            "tool_result" | "toolResult" => {
                if let Some(id) = msg.tool_call_id.as_deref() {
                    if interactive_ids.contains(id) {
                        continue;
                    }
                }

                let text = match &msg.content {
                    Value::String(s) => s.clone(),
                    Value::Array(arr) => arr
                        .iter()
                        .filter_map(|b| b.get("text").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join(" "),
                    _ => continue,
                };
                let t = truncate_str(&text, MAX_TOOL);
                let label = if msg.is_error == Some(true) {
                    "[TOOL_ERROR]"
                } else {
                    "[TOOL_RESULT]"
                };
                if !t.is_empty() {
                    lines.push(format!("{label} {t}"));
                }
            }
            _ => {}
        }
    }

    let full = lines.join("\n");
    if full.len() > MAX_TOTAL {
        let half = MAX_TOTAL / 2;
        let start = &full[..half];
        let end = &full[full.len() - half..];
        format!("{start}\n[...omitted for length...]\n{end}")
    } else {
        full
    }
}

fn truncate_str(s: &str, max: usize) -> &str {
    if s.len() <= max {
        s
    } else {
        &s[..s
            .char_indices()
            .map(|(i, _)| i)
            .take_while(|&i| i < max)
            .last()
            .unwrap_or(0)]
    }
}
