//! Session-list projection queries that construct shared protocol DTOs.

use std::collections::HashMap;

use rusqlite::{Connection, params};
use serde_json::Value;

use super::SessionRepo;
use crate::domains::session::event_store::errors::Result;
use crate::shared::protocol::events::ActivitySummaryLine;

/// Message preview for session list display.
#[derive(Clone, Debug, Default)]
pub(crate) struct MessagePreview {
    /// Last user prompt text.
    pub(crate) last_user_prompt: Option<String>,
    /// Last assistant response text.
    pub(crate) last_assistant_response: Option<String>,
}

/// Extract text from a message event payload JSON string.
///
/// Handles both string content (`"content": "hello"`) and array content
/// (`"content": [{"type": "text", "text": "hello"}]`).
pub(super) fn extract_text_from_payload(payload_str: &str) -> String {
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(payload_str) else {
        return String::new();
    };
    match payload.get("content") {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Array(arr)) => {
            let mut texts = Vec::new();
            for block in arr {
                if block.get("type").and_then(|t| t.as_str()) == Some("text")
                    && let Some(text) = block.get("text").and_then(|t| t.as_str())
                {
                    texts.push(text);
                }
            }
            texts.join("")
        }
        _ => String::new(),
    }
}

/// Truncation constants shared with the iOS session list.
const MAX_USER_PROMPT_LEN: usize = 100;
const MAX_ASSISTANT_TEXT_LEN: usize = 200;
const MAX_ACTIVITY_LINES: usize = 5;

#[derive(Clone, Debug, Default)]
struct ToolCompletionSummary {
    is_error: bool,
    duration_ms: Option<i64>,
    tool_name: Option<String>,
    trace_id: Option<String>,
    root_invocation_id: Option<String>,
    theme_color: Option<String>,
    presentation_hints: Option<Value>,
    summary: Option<String>,
}

impl ToolCompletionSummary {
    fn from_payload(payload: &Value) -> Self {
        let details = payload.get("details");
        let presentation_hints = payload
            .get("presentationHints")
            .cloned()
            .or_else(|| details.and_then(|value| value.get("presentationHints").cloned()));
        let summary = presentation_hints
            .as_ref()
            .and_then(|value| value.get("summary"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);

        Self {
            is_error: payload
                .get("isError")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            duration_ms: payload.get("duration").and_then(Value::as_i64),
            tool_name: string_field(payload, "toolName"),
            trace_id: string_field(payload, "traceId")
                .or_else(|| string_field_opt(details, "traceId")),
            root_invocation_id: string_field(payload, "rootInvocationId")
                .or_else(|| string_field_opt(details, "rootInvocationId")),
            theme_color: string_field(payload, "themeColor").or_else(|| {
                presentation_hints
                    .as_ref()
                    .and_then(|value| string_field(value, "themeColor"))
            }),
            presentation_hints,
            summary,
        }
    }
}

/// Extract first non-empty line from text.
fn first_non_empty_line(text: &str) -> String {
    text.split('\n')
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .unwrap_or(text.trim())
        .to_string()
}

/// Truncate string to max length (char-aware).
fn truncate(s: &str, max_len: usize) -> String {
    if s.chars().count() <= max_len {
        s.to_string()
    } else {
        s.chars().take(max_len).collect()
    }
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn string_field_opt(value: Option<&Value>, key: &str) -> Option<String> {
    value.and_then(|value| string_field(value, key))
}

fn display_tool_args(input: Option<Value>) -> Option<Value> {
    let input = input?;
    input
        .get("arguments")
        .cloned()
        .or_else(|| input.get("payload").cloned())
        .or(Some(input))
}

type ActivityEventRow = (String, String, Option<String>);

fn build_activity_summaries(rows: &[ActivityEventRow]) -> Vec<ActivitySummaryLine> {
    let mut tool_results: HashMap<String, ToolCompletionSummary> = HashMap::new();
    for (event_type, payload_str, _) in rows {
        if event_type == "tool.invocation.completed"
            && let Ok(payload) = serde_json::from_str::<Value>(payload_str)
            && let Some(invocation_id) = payload.get("invocationId").and_then(Value::as_str)
        {
            let _ = tool_results.insert(
                invocation_id.to_string(),
                ToolCompletionSummary::from_payload(&payload),
            );
        }
    }

    let mut lines = Vec::new();
    for (event_type, payload_str, _) in rows {
        let payload = serde_json::from_str::<Value>(payload_str).unwrap_or(Value::Null);
        match event_type.as_str() {
            "message.user" => {
                let text = extract_text_from_payload(payload_str);
                if !text.is_empty() {
                    lines.push(ActivitySummaryLine {
                        kind: "userPrompt".into(),
                        text: Some(truncate(&first_non_empty_line(&text), MAX_USER_PROMPT_LEN)),
                        ..Default::default()
                    });
                }
            }
            "message.assistant" => {
                if let Some(Value::Array(blocks)) = payload.get("content") {
                    for block in blocks {
                        match block.get("type").and_then(Value::as_str) {
                            Some("text") => {
                                if let Some(text) = block.get("text").and_then(Value::as_str) {
                                    let trimmed = text.trim();
                                    if !trimmed.is_empty() {
                                        lines.push(ActivitySummaryLine {
                                            kind: "text".into(),
                                            text: Some(truncate(
                                                &first_non_empty_line(trimmed),
                                                MAX_ASSISTANT_TEXT_LEN,
                                            )),
                                            ..Default::default()
                                        });
                                    }
                                }
                            }
                            Some("tool_invocation") => {
                                let name = block
                                    .get("name")
                                    .and_then(Value::as_str)
                                    .unwrap_or("unknown");
                                let completion = block
                                    .get("id")
                                    .and_then(Value::as_str)
                                    .and_then(|id| tool_results.get(id));
                                let display_args = display_tool_args(
                                    block
                                        .get("input")
                                        .cloned()
                                        .or_else(|| block.get("arguments").cloned()),
                                );
                                lines.push(ActivitySummaryLine {
                                    kind: "tool".into(),
                                    tool_name: completion
                                        .and_then(|summary| summary.tool_name.clone())
                                        .or_else(|| Some(name.to_string())),
                                    trace_id: completion
                                        .and_then(|summary| summary.trace_id.clone()),
                                    root_invocation_id: completion
                                        .and_then(|summary| summary.root_invocation_id.clone()),
                                    theme_color: completion
                                        .and_then(|summary| summary.theme_color.clone()),
                                    presentation_hints: completion
                                        .and_then(|summary| summary.presentation_hints.clone()),
                                    summary: completion.and_then(|summary| summary.summary.clone()),
                                    tool_args: display_args,
                                    duration_ms: completion.and_then(|summary| summary.duration_ms),
                                    is_error: completion.map(|summary| summary.is_error),
                                    ..Default::default()
                                });
                            }
                            Some("thinking") => lines.push(ActivitySummaryLine {
                                kind: "thinking".into(),
                                ..Default::default()
                            }),
                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }
    }
    let start = lines.len().saturating_sub(MAX_ACTIVITY_LINES);
    lines[start..].to_vec()
}

impl SessionRepo {
    /// Get message previews (last user prompt and assistant response) for a list of sessions.
    ///
    /// Uses a window function to find the most recent message of each type per session.
    /// Returns a map of `session_id → MessagePreview`.
    pub(crate) fn get_message_previews(
        conn: &Connection,
        session_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, MessagePreview>> {
        let mut result = std::collections::HashMap::new();
        if session_ids.is_empty() {
            return Ok(result);
        }

        // Initialize all sessions with empty previews
        for &sid in session_ids {
            let _ = result.insert(sid.to_string(), MessagePreview::default());
        }

        let placeholders: Vec<String> = (1..=session_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "WITH ranked AS (
               SELECT
                 session_id,
                 type,
                 payload,
                 ROW_NUMBER() OVER (PARTITION BY session_id, type ORDER BY sequence DESC) as rn
               FROM events
               WHERE session_id IN ({})
                 AND type IN ('message.user', 'message.assistant')
             )
             SELECT session_id, type, payload
             FROM ranked
             WHERE rn = 1",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = session_ids
            .iter()
            .map(|s| s as &dyn rusqlite::types::ToSql)
            .collect();
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        for (session_id, event_type, payload_str) in rows {
            let text = extract_text_from_payload(&payload_str);
            if let Some(preview) = result.get_mut(&session_id) {
                match event_type.as_str() {
                    "message.user" => preview.last_user_prompt = Some(text),
                    "message.assistant" => preview.last_assistant_response = Some(text),
                    _ => {}
                }
            }
        }

        Ok(result)
    }

    /// Build activity summary lines for a session list item.
    ///
    /// Walks persisted events to produce a compact summary of recent activity.
    /// iOS renders each line with generic primitive presentation helpers.
    pub(crate) fn get_activity_summaries(
        conn: &Connection,
        session_id: &str,
    ) -> Result<Vec<ActivitySummaryLine>> {
        let mut stmt = conn.prepare(
            "SELECT type, payload, invocation_id FROM events
               WHERE session_id = ?1
                 AND type IN ('message.user', 'message.assistant', 'tool.invocation.completed')
             ORDER BY sequence ASC",
        )?;

        let rows: Vec<(String, String, Option<String>)> = stmt
            .query_map(params![session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(build_activity_summaries(&rows))
    }

    /// Build activity summaries for a bounded session snapshot in one query.
    pub(crate) fn get_activity_summaries_batch(
        conn: &Connection,
        session_ids: &[&str],
    ) -> Result<HashMap<String, Vec<ActivitySummaryLine>>> {
        let mut result: HashMap<String, Vec<ActivitySummaryLine>> = session_ids
            .iter()
            .map(|session_id| ((*session_id).to_string(), Vec::new()))
            .collect();
        if session_ids.is_empty() {
            return Ok(result);
        }

        let encoded_ids = serde_json::to_string(session_ids).expect("string IDs serialize");
        let mut stmt = conn.prepare(
            "SELECT session_id, type, payload, invocation_id FROM events
             WHERE session_id IN (SELECT value FROM json_each(?1))
               AND type IN ('message.user', 'message.assistant', 'tool.invocation.completed')
             ORDER BY session_id ASC, sequence ASC",
        )?;
        let rows = stmt
            .query_map(params![encoded_ids], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        let mut grouped: HashMap<String, Vec<ActivityEventRow>> = HashMap::new();
        for (session_id, event_type, payload, invocation_id) in rows {
            grouped
                .entry(session_id)
                .or_default()
                .push((event_type, payload, invocation_id));
        }
        for (session_id, rows) in grouped {
            let _ = result.insert(session_id, build_activity_summaries(&rows));
        }
        Ok(result)
    }
}
