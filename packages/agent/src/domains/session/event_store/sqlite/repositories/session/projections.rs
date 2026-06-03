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
    /// Resolved capability contract id, present when a wrapper primitive completed a concrete target.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contract_id: Option<String>,
    /// Resolved implementation id, present when the completion event exposed binding metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub implementation_id: Option<String>,
    /// Resolved engine function id, present when the completion event exposed binding metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub function_id: Option<String>,
    /// Source plugin id for the resolved target.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<String>,
    /// Worker id for the resolved target.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    /// Resolved target schema digest.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema_digest: Option<String>,
    /// Catalog revision used for the resolved target.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog_revision: Option<u64>,
    /// Trust tier for the resolved target.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trust_tier: Option<String>,
    /// Risk level for the resolved target.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub risk_level: Option<String>,
    /// Effect class for the resolved target.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effect_class: Option<String>,
    /// Trace id for Inspect/debug surfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Root invocation id for Inspect/debug surfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_invocation_id: Option<String>,
    /// Binding decision id for Inspect/debug surfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binding_decision_id: Option<String>,
    /// Product presentation hints owned by the resolved capability contract.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presentation_hints: Option<Value>,
    /// Plain product summary for the dashboard chip.
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
    /// Number of agent turns, present for `subagent` lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turns: Option<i64>,
}

/// Truncation constants matching iOS `DashboardConstants`.
const MAX_USER_PROMPT_LEN: usize = 100;
const MAX_ASSISTANT_TEXT_LEN: usize = 200;
const MAX_SUBAGENT_TEXT_LEN: usize = 50;
const MAX_ACTIVITY_LINES: usize = 5;

#[derive(Clone, Debug, Default)]
struct CapabilityCompletionSummary {
    is_error: bool,
    duration_ms: Option<i64>,
    model_primitive_name: Option<String>,
    contract_id: Option<String>,
    implementation_id: Option<String>,
    function_id: Option<String>,
    plugin_id: Option<String>,
    worker_id: Option<String>,
    schema_digest: Option<String>,
    catalog_revision: Option<u64>,
    trust_tier: Option<String>,
    risk_level: Option<String>,
    effect_class: Option<String>,
    trace_id: Option<String>,
    root_invocation_id: Option<String>,
    binding_decision_id: Option<String>,
    presentation_hints: Option<Value>,
    summary: Option<String>,
}

impl CapabilityCompletionSummary {
    fn from_payload(payload: &Value) -> Self {
        let details = payload.get("details");
        let binding = details.and_then(|value| value.get("bindingDecision"));
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
            contract_id: string_field(payload, "contractId")
                .or_else(|| string_field_opt(binding, "contractId")),
            implementation_id: string_field(payload, "implementationId")
                .or_else(|| string_field_opt(binding, "selectedImplementation")),
            function_id: string_field(payload, "functionId")
                .or_else(|| string_field_opt(binding, "selectedFunctionId")),
            plugin_id: string_field(payload, "pluginId"),
            worker_id: string_field(payload, "workerId"),
            schema_digest: string_field(payload, "schemaDigest")
                .or_else(|| string_field_opt(binding, "schemaDigest")),
            catalog_revision: u64_field(payload, "catalogRevision")
                .or_else(|| u64_field_opt(binding, "catalogRevision")),
            trust_tier: string_field(payload, "trustTier"),
            risk_level: string_field(payload, "riskLevel"),
            effect_class: string_field(payload, "effectClass"),
            trace_id: string_field(payload, "traceId")
                .or_else(|| string_field_opt(details, "traceId")),
            root_invocation_id: string_field(payload, "rootInvocationId")
                .or_else(|| string_field_opt(details, "rootInvocationId")),
            binding_decision_id: string_field(payload, "bindingDecisionId")
                .or_else(|| string_field_opt(binding, "decisionId")),
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

fn u64_field(value: &Value, key: &str) -> Option<u64> {
    value.get(key).and_then(Value::as_u64)
}

fn u64_field_opt(value: Option<&Value>, key: &str) -> Option<u64> {
    value.and_then(|value| u64_field(value, key))
}

fn display_capability_args(
    model_primitive_name: &str,
    input: Option<Value>,
    completion: Option<&CapabilityCompletionSummary>,
) -> Option<Value> {
    let input = input?;
    let resolved_target = completion
        .and_then(|summary| summary.contract_id.as_deref())
        .is_some_and(|contract_id| contract_id != "capability::execute");
    if model_primitive_name == "execute" || resolved_target {
        input
            .get("arguments")
            .cloned()
            .or_else(|| input.get("payload").cloned())
            .or(Some(input))
    } else {
        Some(input)
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
                                    let completion =
                                        invocation_id.and_then(|id| capability_results.get(id));
                                    let display_args =
                                        display_capability_args(name, input, completion);

                                    lines.push(ActivitySummaryLine {
                                        kind: "capability".into(),
                                        model_primitive_name: completion
                                            .and_then(|summary| {
                                                summary.model_primitive_name.clone()
                                            })
                                            .or_else(|| Some(name.to_string())),
                                        contract_id: completion
                                            .and_then(|summary| summary.contract_id.clone()),
                                        implementation_id: completion
                                            .and_then(|summary| summary.implementation_id.clone()),
                                        function_id: completion
                                            .and_then(|summary| summary.function_id.clone()),
                                        plugin_id: completion
                                            .and_then(|summary| summary.plugin_id.clone()),
                                        worker_id: completion
                                            .and_then(|summary| summary.worker_id.clone()),
                                        schema_digest: completion
                                            .and_then(|summary| summary.schema_digest.clone()),
                                        catalog_revision: completion
                                            .and_then(|summary| summary.catalog_revision),
                                        trust_tier: completion
                                            .and_then(|summary| summary.trust_tier.clone()),
                                        risk_level: completion
                                            .and_then(|summary| summary.risk_level.clone()),
                                        effect_class: completion
                                            .and_then(|summary| summary.effect_class.clone()),
                                        trace_id: completion
                                            .and_then(|summary| summary.trace_id.clone()),
                                        root_invocation_id: completion
                                            .and_then(|summary| summary.root_invocation_id.clone()),
                                        binding_decision_id: completion.and_then(|summary| {
                                            summary.binding_decision_id.clone()
                                        }),
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
