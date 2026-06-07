//! Dashboard projection DTOs and queries for session list/activity surfaces.

use std::collections::HashMap;

use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::SessionRepo;
use crate::domains::session::event_store::errors::Result;

/// Message preview for session list display.
#[derive(Clone, Debug, Default)]
pub struct MessagePreview {
    /// Last user prompt text.
    pub last_user_prompt: Option<String>,
    /// Last assistant response text.
    pub last_assistant_response: Option<String>,
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

/// Activity summary line for dashboard card display.
/// Lightweight: iOS enriches primitive operation lines with generic
/// presentation helpers.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySummaryLine {
    /// Discriminator for the line type (for example `"userPrompt"`, `"text"`, `"capability"`).
    pub kind: String,
    /// Plain-text excerpt, present for prompt and assistant-text lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Provider-visible primitive name for capability lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_primitive_name: Option<String>,
    /// Primitive operation requested inside `execute`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_name: Option<String>,
    /// Trace id for Inspect/debug surfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Root invocation id for Inspect/debug surfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_invocation_id: Option<String>,
    /// Runtime-owned theme color.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub theme_color: Option<String>,
    /// Runtime-owned presentation hints.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presentation_hints: Option<Value>,
    /// Plain summary for the dashboard chip.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// Capability invocation arguments, present for capability lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_args: Option<Value>,
    /// Capability invocation time in milliseconds, present for `capability_invocation` lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    /// Whether the capability invocation produced an error, present for `capability_invocation` lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    /// Number of agent turns for nested activity summaries.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turns: Option<i64>,
}

/// Truncation constants matching iOS `DashboardConstants`.
const MAX_USER_PROMPT_LEN: usize = 100;
const MAX_ASSISTANT_TEXT_LEN: usize = 200;
const MAX_ACTIVITY_LINES: usize = 5;

#[derive(Clone, Debug, Default)]
struct CapabilityCompletionSummary {
    is_error: bool,
    duration_ms: Option<i64>,
    model_primitive_name: Option<String>,
    operation_name: Option<String>,
    trace_id: Option<String>,
    root_invocation_id: Option<String>,
    theme_color: Option<String>,
    presentation_hints: Option<Value>,
    summary: Option<String>,
}

impl CapabilityCompletionSummary {
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
            model_primitive_name: string_field(payload, "modelPrimitiveName"),
            operation_name: string_field(payload, "operationName")
                .or_else(|| string_field_opt(details, "operationName"))
                .or_else(|| string_field_opt(details, "operation")),
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

fn display_capability_args(input: Option<Value>) -> Option<Value> {
    let input = input?;
    input
        .get("arguments")
        .cloned()
        .or_else(|| input.get("payload").cloned())
        .or(Some(input))
}

fn operation_name_from_value(value: &Value) -> Option<String> {
    ["operationName", "operation"].iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|operation| !operation.is_empty())
            .map(ToOwned::to_owned)
    })
}

impl SessionRepo {
    /// Get message previews (last user prompt and assistant response) for a list of sessions.
    ///
    /// Uses a window function to find the most recent message of each type per session.
    /// Returns a map of `session_id → MessagePreview`.
    pub fn get_message_previews(
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

    /// Build activity summary lines for a session's dashboard card.
    ///
    /// Walks persisted events to produce a compact summary of recent activity.
    /// iOS renders each line with generic primitive presentation helpers.
    pub fn get_activity_summaries(
        conn: &Connection,
        session_id: &str,
    ) -> Result<Vec<ActivitySummaryLine>> {
        let mut stmt = conn.prepare(
            "SELECT type, payload, invocation_id FROM events
               WHERE session_id = ?1
                 AND type IN ('message.user', 'message.assistant', 'capability.invocation.completed')
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

        // Pass 1: collect capability result info by invocationId.
        let mut capability_results: HashMap<String, CapabilityCompletionSummary> = HashMap::new();
        for (event_type, payload_str, _) in &rows {
            if event_type == "capability.invocation.completed" {
                if let Ok(payload) = serde_json::from_str::<Value>(payload_str) {
                    if let Some(tcid) = payload.get("invocationId").and_then(|v| v.as_str()) {
                        let _ = capability_results.insert(
                            tcid.to_string(),
                            CapabilityCompletionSummary::from_payload(&payload),
                        );
                    }
                }
            }
        }

        // Pass 2: walk events in order, building activity lines
        let mut lines: Vec<ActivitySummaryLine> = Vec::new();

        for (event_type, payload_str, _invocation_id) in &rows {
            let payload: Value = serde_json::from_str(payload_str).unwrap_or(Value::Null);

            match event_type.as_str() {
                "message.user" => {
                    let text = extract_text_from_payload(payload_str);
                    if !text.is_empty() {
                        let fl = first_non_empty_line(&text);
                        lines.push(ActivitySummaryLine {
                            kind: "userPrompt".into(),
                            text: Some(truncate(&fl, MAX_USER_PROMPT_LEN)),
                            ..Default::default()
                        });
                    }
                }
                "message.assistant" => {
                    if let Some(Value::Array(blocks)) = payload.get("content") {
                        for block in blocks {
                            let bt = block.get("type").and_then(|t| t.as_str());
                            match bt {
                                Some("text") => {
                                    if let Some(text) = block.get("text").and_then(|t| t.as_str()) {
                                        let trimmed = text.trim();
                                        if !trimmed.is_empty() {
                                            let fl = first_non_empty_line(trimmed);
                                            lines.push(ActivitySummaryLine {
                                                kind: "text".into(),
                                                text: Some(truncate(&fl, MAX_ASSISTANT_TEXT_LEN)),
                                                ..Default::default()
                                            });
                                        }
                                    }
                                }
                                Some("capability_invocation") => {
                                    let name = block
                                        .get("name")
                                        .and_then(|n| n.as_str())
                                        .unwrap_or("unknown");
                                    let invocation_id = block.get("id").and_then(|id| id.as_str());
                                    let input = block
                                        .get("input")
                                        .cloned()
                                        .or_else(|| block.get("arguments").cloned());
                                    let completion =
                                        invocation_id.and_then(|id| capability_results.get(id));
                                    let display_args = display_capability_args(input);
                                    let operation_name = completion
                                        .and_then(|summary| summary.operation_name.clone())
                                        .or_else(|| {
                                            display_args
                                                .as_ref()
                                                .and_then(operation_name_from_value)
                                        });

                                    lines.push(ActivitySummaryLine {
                                        kind: "capability".into(),
                                        model_primitive_name: completion
                                            .and_then(|summary| {
                                                summary.model_primitive_name.clone()
                                            })
                                            .or_else(|| Some(name.to_string())),
                                        operation_name,
                                        trace_id: completion
                                            .and_then(|summary| summary.trace_id.clone()),
                                        root_invocation_id: completion
                                            .and_then(|summary| summary.root_invocation_id.clone()),
                                        theme_color: completion
                                            .and_then(|summary| summary.theme_color.clone()),
                                        presentation_hints: completion
                                            .and_then(|summary| summary.presentation_hints.clone()),
                                        summary: completion
                                            .and_then(|summary| summary.summary.clone()),
                                        capability_args: display_args,
                                        duration_ms: completion
                                            .and_then(|summary| summary.duration_ms),
                                        is_error: completion.map(|summary| summary.is_error),
                                        ..Default::default()
                                    });
                                }
                                Some("thinking") => {
                                    lines.push(ActivitySummaryLine {
                                        kind: "thinking".into(),
                                        ..Default::default()
                                    });
                                }
                                _ => {}
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        let start = lines.len().saturating_sub(MAX_ACTIVITY_LINES);
        Ok(lines[start..].to_vec())
    }
}
