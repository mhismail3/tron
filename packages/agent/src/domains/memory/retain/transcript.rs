//! Transcript serialization for retain summarization.

use std::collections::HashSet;

use serde_json::Value;

use crate::domains::session::event_store::types::state::Message;

const INTERACTIVE_CAPABILITY_IDS: &[&str] = &["agent::ask_user"];

/// First-pass scan to collect `capability_invocation` block IDs that belong to an
/// interactive capability. Their matching `capability_result` messages are then filtered
/// by [`serialize_for_memory`].
pub(super) fn collect_interactive_capability_invocation_ids(
    messages: &[Message],
) -> HashSet<String> {
    let mut ids = HashSet::new();
    for msg in messages {
        let Some(arr) = msg.content.as_array() else {
            continue;
        };
        for block in arr {
            if block.get("type").and_then(Value::as_str) != Some("capability_invocation") {
                continue;
            }
            let Some(target_id) = capability_target_id(block) else {
                continue;
            };
            if !INTERACTIVE_CAPABILITY_IDS.contains(&target_id.as_str()) {
                continue;
            }
            if let Some(id) = block.get("id").and_then(Value::as_str) {
                let _ = ids.insert(id.to_string());
            }
        }
    }
    ids
}

/// Extract a compact natural-language summary from an interactive-capability
/// `capability_invocation` block so the transcript preserves what the agent asked.
pub(super) fn extract_interactive_capability_summary(block: &Value) -> Option<String> {
    if block.get("type").and_then(Value::as_str) != Some("capability_invocation") {
        return None;
    }
    let target_id = capability_target_id(block)?;
    let input = capability_payload(block)?;

    match target_id.as_str() {
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

fn capability_target_id(block: &Value) -> Option<String> {
    if block.get("type").and_then(Value::as_str) != Some("capability_invocation") {
        return None;
    }
    if let Some(name) = block.get("name").and_then(Value::as_str)
        && INTERACTIVE_CAPABILITY_IDS.contains(&name)
    {
        return Some(name.to_owned());
    }
    let input = block.get("input")?;
    for key in [
        "contractId",
        "capabilityId",
        "functionId",
        "contract_id",
        "capability_id",
        "function_id",
    ] {
        if let Some(value) = input.get(key).and_then(Value::as_str)
            && INTERACTIVE_CAPABILITY_IDS.contains(&value)
        {
            return Some(value.to_owned());
        }
    }
    None
}

fn capability_payload(block: &Value) -> Option<&Value> {
    let input = block.get("input")?;
    if let Some(target_id) = input
        .get("contractId")
        .or_else(|| input.get("capabilityId"))
        .or_else(|| input.get("functionId"))
        .and_then(Value::as_str)
        && INTERACTIVE_CAPABILITY_IDS.contains(&target_id)
    {
        return input.get("payload").or(Some(input));
    }
    Some(input)
}

/// Serialize reconstructed messages to a plain-text transcript for summarization.
pub(super) fn serialize_for_memory(messages: &[Message]) -> String {
    const MAX_TEXT: usize = 300;
    const MAX_CAPABILITY_RESULT: usize = 150;
    const MAX_TOTAL: usize = 20_000;

    let interactive_ids = collect_interactive_capability_invocation_ids(messages);

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
                            } else if let Some(summary) = extract_interactive_capability_summary(b)
                            {
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
            "capability_result" | "capabilityResult" => {
                if let Some(id) = msg.invocation_id.as_deref() {
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
                let t = truncate_str(&text, MAX_CAPABILITY_RESULT);
                let label = if msg.is_error == Some(true) {
                    "[CAPABILITY_ERROR]"
                } else {
                    "[CAPABILITY_RESULT]"
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
