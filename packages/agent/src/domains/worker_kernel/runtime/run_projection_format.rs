//! Bounded text, identity, and ordering helpers for worker-run projection.

use serde_json::Value;

use super::WorkerRunStage;

const PREVIEW_BYTES: usize = 512;

pub(super) fn preview_request(value: &Value) -> String {
    for key in ["query", "request", "prompt", "task", "topic"] {
        if let Some(value) = value.get(key).and_then(Value::as_str) {
            return preview_text(value);
        }
    }
    preview_value(value)
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
