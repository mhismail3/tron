//! Bounded text, identity, and ordering helpers for worker-run projection.

use serde_json::Value;

use super::WorkerRunStage;

const PREVIEW_BYTES: usize = 512;

pub(super) fn preview_request(value: &Value) -> String {
    for key in [
        "question", "query", "request", "prompt", "task", "topic", "title", "action",
    ] {
        if let Some(value) = value.get(key).and_then(Value::as_str) {
            return preview_text(value);
        }
    }
    match value {
        Value::String(value) => preview_text(value),
        Value::Object(fields) => format!(
            "Structured worker request · {} field{}",
            fields.len(),
            if fields.len() == 1 { "" } else { "s" }
        ),
        Value::Array(items) => format!(
            "Worker request · {} item{}",
            items.len(),
            if items.len() == 1 { "" } else { "s" }
        ),
        _ => "Worker request".to_owned(),
    }
}

pub(super) fn preview_result(value: &Value) -> String {
    if value.get("kind").and_then(Value::as_str) == Some("worker_result_reference")
        && let Some(preview) = value.get("preview").and_then(Value::as_str)
    {
        return preview_text(preview);
    }
    for key in ["summary", "answer", "report", "result"] {
        if let Some(value) = value.get(key).and_then(Value::as_str) {
            return preview_text(value);
        }
    }
    preview_value(value)
}

fn preview_value(value: &Value) -> String {
    preview_text(&serde_json::to_string(value).unwrap_or_else(|_| "null".to_owned()))
}

pub(super) fn preview_text(value: &str) -> String {
    crate::shared::foundation::text::truncate_with_suffix(value, PREVIEW_BYTES, "...")
}

pub(super) fn invocation_node_id(invocation_id: &str) -> String {
    format!("invocation:{invocation_id}")
}

pub(super) fn agent_node_id(session_id: &str) -> String {
    format!("agent:{session_id}")
}

pub(super) fn model_node_id(session_id: &str, turn: i64) -> String {
    format!("model:{session_id}:{turn}")
}

pub(super) fn friendly_tool_name(value: &str) -> String {
    value
        .trim_start_matches("worker_kernel::")
        .replace(['_', '.'], " ")
}

pub(super) fn is_technical_tool(value: &str) -> bool {
    ["filesystem", "process", "web_fetch", "settings", "surface"]
        .iter()
        .any(|term| value.contains(term))
}

pub(super) fn stage_status(stage: WorkerRunStage) -> &'static str {
    match stage {
        WorkerRunStage::Queued => "queued",
        WorkerRunStage::Completed => "completed",
        WorkerRunStage::Failed => "failed",
        WorkerRunStage::Cancelled => "cancelled",
        WorkerRunStage::Interrupted => "interrupted",
        _ => "running",
    }
}

pub(super) fn is_terminal(status: &str) -> bool {
    matches!(status, "completed" | "failed" | "cancelled")
}

pub(super) fn timeline_order(left: &Value, right: &Value) -> std::cmp::Ordering {
    left["occurredAt"]
        .as_str()
        .unwrap_or_default()
        .cmp(right["occurredAt"].as_str().unwrap_or_default())
        // Admission intentionally records queued and detached at one timestamp
        // in the same transaction. Preserve lifecycle meaning instead of
        // alphabetizing their summaries ("Conversation..." before "Queued...").
        .then_with(|| {
            timeline_stage_rank(left["stage"].as_str().unwrap_or_default()).cmp(
                &timeline_stage_rank(right["stage"].as_str().unwrap_or_default()),
            )
        })
        .then_with(|| {
            left["nodeId"]
                .as_str()
                .unwrap_or_default()
                .cmp(right["nodeId"].as_str().unwrap_or_default())
        })
        .then_with(|| {
            left["summary"]
                .as_str()
                .unwrap_or_default()
                .cmp(right["summary"].as_str().unwrap_or_default())
        })
}

fn timeline_stage_rank(stage: &str) -> u8 {
    match stage {
        "queued" => 0,
        "detached" => 1,
        "specialist_execution" => 2,
        "planning" => 3,
        "retry_repair" => 4,
        "synthesis" => 5,
        "validation" => 6,
        "publication" => 7,
        "interrupted" => 8,
        "failed" => 9,
        "cancelled" => 10,
        "completed" => 11,
        _ => 12,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn request_and_result_previews_prefer_user_facing_fields() {
        assert_eq!(
            preview_request(&json!({"query":"What happened today?","debug":"raw"})),
            "What happened today?"
        );
        assert_eq!(
            preview_request(&json!({
                "budget":"high",
                "citationStyle":"chicago",
                "question":"Compare contradictory reporting without exposing the request as JSON."
            })),
            "Compare contradictory reporting without exposing the request as JSON."
        );
        assert_eq!(
            preview_request(&json!({"budget":"high","depth":"deep"})),
            "Structured worker request · 2 fields"
        );
        assert_eq!(
            preview_result(&json!({"summary":"Three developments","payload":{"raw":true}})),
            "Three developments"
        );
    }

    #[test]
    fn technical_tool_names_are_structured_not_concatenated() {
        assert_eq!(
            friendly_tool_name("worker_kernel::filesystem_list"),
            "filesystem list"
        );
        assert!(is_technical_tool("worker_kernel::filesystem_list"));
        assert!(!is_technical_tool("research_search"));
    }

    #[test]
    fn equal_timestamp_timeline_entries_follow_lifecycle_order() {
        let timestamp = "2026-07-25T00:00:00Z";
        let mut entries = [
            json!({
                "occurredAt":timestamp,
                "nodeId":"invocation:root",
                "stage":"detached",
                "summary":"Conversation released while durable work continues",
            }),
            json!({
                "occurredAt":timestamp,
                "nodeId":"invocation:root",
                "stage":"queued",
                "summary":"Queued for durable worker execution",
            }),
        ];
        entries.sort_by(timeline_order);
        assert_eq!(entries[0]["stage"], "queued");
        assert_eq!(entries[1]["stage"], "detached");
    }
}
