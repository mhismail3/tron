//! Dashboard projection DTOs and queries for session list/activity surfaces.

use std::collections::{HashMap, HashSet};

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
/// Lightweight: iOS enriches with its local capability presentation catalog.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySummaryLine {
    /// Discriminator for the line type (for example `"userPrompt"`, `"text"`, `"capability"`).
    pub kind: String,
    /// Plain-text excerpt, present for prompt and assistant-text lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Provider-visible primitive name or resolved capability id for capability lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_primitive_name: Option<String>,
    /// Capability invocation arguments, present for capability lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_args: Option<Value>,
    /// Capability invocation time in milliseconds, present for `capability_invocation` lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    /// Whether the capability invocation produced an error, present for `capability_invocation` lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    /// Number of agent turns, present for `subagent` lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turns: Option<i64>,
}

/// Truncation constants matching iOS `DashboardConstants`.
const MAX_USER_PROMPT_LEN: usize = 100;
const MAX_ASSISTANT_TEXT_LEN: usize = 200;
const MAX_SUBAGENT_TEXT_LEN: usize = 50;
const MAX_ACTIVITY_LINES: usize = 5;

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
    /// iOS enriches each line with its local capability presentation catalog.
    pub fn get_activity_summaries(
        conn: &Connection,
        session_id: &str,
    ) -> Result<Vec<ActivitySummaryLine>> {
        let mut stmt = conn.prepare(
            "SELECT type, payload, invocation_id FROM events
             WHERE session_id = ?1
               AND type IN ('message.user', 'message.assistant', 'capability.invocation.completed',
                            'subagent.spawned', 'subagent.completed', 'subagent.failed')
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

        // Pass 1: collect capability result info by invocationId
        let mut capability_results: HashMap<String, (bool, Option<i64>)> = HashMap::new();
        for (event_type, payload_str, _) in &rows {
            if event_type == "capability.invocation.completed" {
                if let Ok(payload) = serde_json::from_str::<Value>(payload_str) {
                    if let Some(tcid) = payload.get("invocationId").and_then(|v| v.as_str()) {
                        let is_error = payload
                            .get("isError")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        let duration = payload.get("duration").and_then(|v| v.as_i64());
                        let _ = capability_results.insert(tcid.to_string(), (is_error, duration));
                    }
                }
            }
        }

        // Pass 1b: collect hook subagent IDs (spawned with invocation_id IS NULL)
        let mut hook_subagent_ids: HashSet<String> = HashSet::new();
        for (event_type, payload_str, invocation_id) in &rows {
            if event_type == "subagent.spawned" && invocation_id.is_none() {
                if let Ok(payload) = serde_json::from_str::<Value>(payload_str) {
                    if let Some(sub_id) = payload.get("subagentSessionId").and_then(|v| v.as_str())
                    {
                        let _ = hook_subagent_ids.insert(sub_id.to_string());
                    }
                }
            }
        }

        // Pass 2: walk events in order, building activity lines
        let mut lines: Vec<ActivitySummaryLine> = Vec::new();

        for (event_type, payload_str, invocation_id) in &rows {
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
                                    if name == "agent::spawn_subagent" {
                                        continue;
                                    }
                                    let invocation_id = block.get("id").and_then(|id| id.as_str());
                                    let input = block
                                        .get("input")
                                        .cloned()
                                        .or_else(|| block.get("arguments").cloned());
                                    let result =
                                        invocation_id.and_then(|id| capability_results.get(id));

                                    lines.push(ActivitySummaryLine {
                                        kind: "capability".into(),
                                        model_primitive_name: Some(name.to_string()),
                                        capability_args: input,
                                        duration_ms: result.and_then(|(_, d)| *d),
                                        is_error: result.map(|(e, _)| *e),
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
                "subagent.spawned" => {
                    if invocation_id.is_some() {
                        let task = payload
                            .get("task")
                            .and_then(|t| t.as_str())
                            .unwrap_or("Sub-agent task");
                        lines.push(ActivitySummaryLine {
                            kind: "subagentSpawn".into(),
                            text: Some(format!("Agent: {}", truncate(task, MAX_SUBAGENT_TEXT_LEN))),
                            ..Default::default()
                        });
                    }
                }
                "subagent.completed" => {
                    let sub_id = payload.get("subagentSessionId").and_then(|v| v.as_str());
                    if sub_id.is_some_and(|id| hook_subagent_ids.contains(id)) {
                        continue;
                    }
                    let turns = payload
                        .get("totalTurns")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    let duration = payload.get("duration").and_then(|v| v.as_i64());
                    let complete_line = ActivitySummaryLine {
                        kind: "subagentDone".into(),
                        text: Some(format!("Agent complete ({turns} turns)")),
                        duration_ms: duration,
                        turns: Some(turns),
                        ..Default::default()
                    };
                    if let Some(idx) = lines.iter().rposition(|l| l.kind == "subagentSpawn") {
                        lines[idx] = complete_line;
                    } else {
                        lines.push(complete_line);
                    }
                }
                "subagent.failed" => {
                    let sub_id = payload.get("subagentSessionId").and_then(|v| v.as_str());
                    if sub_id.is_some_and(|id| hook_subagent_ids.contains(id)) {
                        continue;
                    }
                    let error = payload
                        .get("error")
                        .and_then(|v| v.as_str())
                        .unwrap_or("Unknown error");
                    let fail_line = ActivitySummaryLine {
                        kind: "subagentFailed".into(),
                        text: Some(format!(
                            "Agent failed: {}",
                            truncate(error, MAX_SUBAGENT_TEXT_LEN)
                        )),
                        ..Default::default()
                    };
                    if let Some(idx) = lines.iter().rposition(|l| l.kind == "subagentSpawn") {
                        lines[idx] = fail_line;
                    } else {
                        lines.push(fail_line);
                    }
                }
                _ => {}
            }
        }

        let start = lines.len().saturating_sub(MAX_ACTIVITY_LINES);
        Ok(lines[start..].to_vec())
    }
}
